use std::fs;
use std::path::PathBuf;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

mod common;
pub mod journal;
mod op;
mod pre;

pub use common::{common_key, execute_common, recover_common_journals};
pub use op::{Op, Plan, PlannedOp, read_git_config};
pub use pre::Pre;

/// Filesystem-safe key naming a scope's journal dir and lock file. Keys off
/// the canonical scope so two spellings of one root can never hold two
/// locks (invariant 8 depends on this, not on callers normalizing paths).
pub fn scope_key(scope: &Scope) -> String {
    match scope.canonical() {
        Scope::Global => "global".to_owned(),
        Scope::Project { root } => {
            let text = root.display().to_string();
            let base = root
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "project".to_owned());
            format!("{base}-{}", crate::hash::fnv1a_hex(text.as_bytes()))
        }
    }
}

/// Exclusive writer lock over one journal key (invariant 8) — a scope, or
/// a repository's common dir. Held for the whole journal → mutate → clear
/// window; recovery runs under the same lock.
pub struct ScopeGuard {
    _file: fs::File,
}

fn lock_scope(env: &Env, scope: &Scope) -> Result<ScopeGuard> {
    lock_key(env, &scope_key(scope))
}

pub(crate) fn lock_key(env: &Env, key: &str) -> Result<ScopeGuard> {
    let dir = env.scope_locks_dir();
    fs::create_dir_all(&dir).map_err(|e| CoreError::io(&dir, e))?;
    let path = dir.join(format!("{key}.lock"));
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| CoreError::io(&path, e))?;
    let mut lock = fd_lock::RwLock::new(file);
    // fd-lock ties its guard lifetime to the RwLock borrow; the OS lock is
    // really held by the open fd, so forget the guard and keep the file —
    // the lock releases when ScopeGuard drops (closing the fd). Only
    // contention is "busy": a filesystem that cannot lock at all must say
    // so, or every launch pass would skip recovery there in silence.
    match lock.try_write() {
        Ok(guard) => std::mem::forget(guard),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
            return Err(CoreError::ScopeBusy { lock: path });
        }
        Err(error) => return Err(CoreError::io(&path, error)),
    }
    Ok(ScopeGuard {
        _file: lock.into_inner(),
    })
}

/// Recovery under the scope lock, for callers outside an apply (launch
/// passes). A busy scope has a live writer that will recover it itself.
pub fn recover_locked(env: &Env, scope: &Scope) -> Result<bool> {
    let _guard = lock_scope(env, scope)?;
    recover(env, scope)
}

/// Roll back an interrupted apply, if one left a journal. Returns whether
/// recovery ran. Called under the scope lock on every apply, and at app
/// launch for every known scope.
pub fn recover(env: &Env, scope: &Scope) -> Result<bool> {
    recover_key(env, &scope_key(scope))
}

fn recover_key(env: &Env, key: &str) -> Result<bool> {
    let dir = journal::journal_dir_for(&env.journal_dir(), key);
    if journal::pending(&dir) {
        journal::rollback(&dir)?;
        return Ok(true);
    }
    journal::clear(&dir)?;
    Ok(false)
}

#[derive(Debug)]
pub struct ApplyOutcome {
    pub applied: usize,
    pub recovered_first: bool,
    /// What this scope's manifest is now, read before the lock this apply
    /// holds is let go. After that moment the answer can already be
    /// somebody else's: a caller that writes a whole manifest and then
    /// reads the file back is pairing its own copy with whatever landed in
    /// between, and the next write carrying that pair is accepted over
    /// that writer.
    ///
    /// `None` where it could not be read. By then every op has run and the
    /// journal is clear, so there is nothing left to roll back: an apply
    /// that reported failure here would be reporting a committed change as
    /// undone, and someone would run it again. Not knowing what the file
    /// is now is a smaller thing than that, and it is sayable.
    pub manifest_base: Option<crate::manifest::Base>,
}

/// Execute a plan transactionally. If recovery runs first, the plan
/// predates it and preconditions do the talking. `fail_after` is
/// test-only fault injection: simulate a crash after N ops to exercise
/// every boundary.
pub fn execute(env: &Env, plan: &Plan, fail_after: Option<usize>) -> Result<ApplyOutcome> {
    let _guard = lock_scope(env, &plan.scope)?;
    let recovered_first = recover(env, &plan.scope)?;
    let applied = run_journaled(env, &plan.ops, &scope_key(&plan.scope), fail_after)?;
    // The scope just changed; a drift snapshot describing the old state
    // would send the next session chasing drift that no longer exists.
    // Invalidation is the cheap honest move: the check reads "not yet
    // evaluated" and its background job re-derives. Verbs that already do
    // the deep work re-record right after this returns. Best-effort — a
    // failure here leaves a stale snapshot, which the refs-state check and
    // the next deep pass both correct.
    if !plan.ops.is_empty() {
        let _ = crate::drift::snapshot::invalidate(env, &plan.scope);
    }
    Ok(ApplyOutcome {
        applied,
        recovered_first,
        // Still under `_guard`, which is the closest this can get: the lock
        // serialises kendex's own writers, so no other apply is between
        // the write and this read. It does not serialise anything else —
        // an editor saving kendex.toml in that window would be read here
        // as though this apply had left it, and the base handed back would
        // describe bytes this apply never wrote. Deriving it from the
        // bytes the manifest op actually wrote is the way to close that,
        // and it needs the executor to report them: KEN-513. Its own
        // failure is not this apply's — the ops are committed either way.
        manifest_base: manifest_base(env, &plan.scope),
    })
}

/// The scope's manifest as it stands, for an apply that still holds the
/// lock. Derived from the bytes read here, like every other base, and
/// `None` where they could not be read — every caller of this is past the
/// point of undoing anything, so a read that fails costs the answer and
/// never the apply.
///
/// "As it stands" is the honest phrasing: this reads the file rather than
/// being told what was written, so it describes whatever is there now.
/// Under kendex's own lock that is what this apply left; against a writer
/// that does not take the lock it is not (KEN-513).
pub(super) fn manifest_base(env: &Env, scope: &Scope) -> Option<crate::manifest::Base> {
    let path = crate::manifest::manifest_path(env, scope);
    match crate::fs::read_if_exists(&path) {
        Ok(Some(text)) => Some(crate::manifest::Base::of(&text)),
        Ok(None) => Some(crate::manifest::Base::absent()),
        Err(_) => None,
    }
}

/// The one transaction engine, under a lock the caller already holds for
/// `key` and after it recovered: journal every pre-image, run the ops in
/// order, roll back on the first failure. Returns how many ops ran.
fn run_journaled(
    env: &Env,
    ops: &[PlannedOp],
    key: &str,
    fail_after: Option<usize>,
) -> Result<usize> {
    // Nothing to do leaves nothing behind: an empty journal would read as
    // an interrupted apply to the next recovery pass.
    if ops.is_empty() {
        return Ok(0);
    }
    let journal_dir = journal::journal_dir_for(&env.journal_dir(), key);
    let mut touched: Vec<PathBuf> = ops.iter().flat_map(|p| p.op.touched()).collect();
    touched.extend(created_dir_roots(&touched));
    journal::write(&journal_dir, &touched)?;

    for (index, planned) in ops.iter().enumerate() {
        if fail_after == Some(index) {
            journal::rollback(&journal_dir)?;
            return Err(CoreError::RolledBack {
                reason: format!("injected fault before '{}'", planned.description),
                cause: Box::new(CoreError::Injected),
            });
        }
        if let Err(error) = planned.op.run(env) {
            journal::rollback(&journal_dir)?;
            return Err(CoreError::RolledBack {
                reason: format!("'{}' failed: {error}", planned.description),
                cause: Box::new(error),
            });
        }
    }
    journal::clear(&journal_dir)?;
    Ok(ops.len())
}

/// The top of every directory chain the plan's `create_dir_all` calls will
/// bring into being. Journaled as absent, so rollback deletes the whole
/// chain — an empty `.codex/` left behind is not cosmetic, it is what
/// harness and project detection read as "installed here".
fn created_dir_roots(touched: &[PathBuf]) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    for path in touched {
        let mut topmost_missing = None;
        let mut ancestor = path.parent();
        while let Some(dir) = ancestor {
            if dir.as_os_str().is_empty() || dir.exists() {
                break;
            }
            topmost_missing = Some(dir.to_path_buf());
            ancestor = dir.parent();
        }
        if let Some(root) = topmost_missing
            && !touched.contains(&root)
            && !roots.contains(&root)
        {
            roots.push(root);
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use std::path::Path;

    fn env_in(dir: &Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    fn write_plan(scope: Scope, path: PathBuf, content: &str, pre: Pre) -> Plan {
        Plan {
            scope,
            ops: vec![PlannedOp {
                description: format!("write {}", path.display()),
                op: Op::WriteFile {
                    path,
                    bytes: content.as_bytes().to_vec(),
                    pre,
                },
            }],
        }
    }

    #[test]
    fn fault_at_every_boundary_leaves_disk_untouched() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let target = tmp.path().join("a/file.md");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, "before").unwrap();

        let plan = Plan {
            scope: Scope::Global,
            ops: vec![
                PlannedOp {
                    description: "first".into(),
                    op: Op::WriteFile {
                        path: target.clone(),
                        bytes: b"after".to_vec(),
                        pre: Pre::Any,
                    },
                },
                PlannedOp {
                    description: "second".into(),
                    op: Op::WriteFile {
                        path: tmp.path().join("b/new.md"),
                        bytes: b"new".to_vec(),
                        pre: Pre::Absent,
                    },
                },
            ],
        };

        for boundary in 0..=1 {
            let error = execute(&env, &plan, Some(boundary)).unwrap_err();
            assert!(matches!(error, CoreError::RolledBack { .. }));
            assert_eq!(fs::read_to_string(&target).unwrap(), "before");
            assert!(!tmp.path().join("b/new.md").exists());
        }

        let outcome = execute(&env, &plan, None).unwrap();
        assert_eq!(outcome.applied, 2);
        assert_eq!(fs::read_to_string(&target).unwrap(), "after");
    }

    #[test]
    fn stale_precondition_aborts_and_rolls_back() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let target = tmp.path().join("file.md");
        fs::write(&target, "changed since plan").unwrap();

        let plan = write_plan(Scope::Global, target.clone(), "overwrite", Pre::Absent);
        let error = execute(&env, &plan, None).unwrap_err();
        assert!(matches!(error, CoreError::RolledBack { .. }));
        assert_eq!(fs::read_to_string(&target).unwrap(), "changed since plan");
    }

    #[test]
    fn interrupted_apply_recovers_on_next_run() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let target = tmp.path().join("file.md");
        fs::write(&target, "before").unwrap();

        // Simulate a crash: journal written, mutation done, journal never
        // cleared.
        let journal_dir = journal::journal_dir_for(&env.journal_dir(), &scope_key(&Scope::Global));
        journal::write(&journal_dir, std::slice::from_ref(&target)).unwrap();
        fs::write(&target, "torn write").unwrap();

        assert!(recover(&env, &Scope::Global).unwrap());
        assert_eq!(fs::read_to_string(&target).unwrap(), "before");
        assert!(!recover(&env, &Scope::Global).unwrap());
    }

    #[test]
    fn second_writer_gets_a_busy_error() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let _guard = lock_scope(&env, &Scope::Global).unwrap();
        assert!(matches!(
            lock_scope(&env, &Scope::Global),
            Err(CoreError::ScopeBusy { .. })
        ));
    }

    /// Two spellings of one project root are one scope: the lock key comes
    /// from the canonical root, never from the caller's path text.
    #[test]
    fn scope_identity_survives_path_spelling() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let root = tmp.path().join("proj");
        fs::create_dir_all(root.join("sub")).unwrap();
        let plain = Scope::Project { root: root.clone() };
        let dotted = Scope::Project {
            root: root.join("sub").join(".."),
        };
        assert_eq!(scope_key(&plain), scope_key(&dotted));
        let _guard = lock_scope(&env, &plain).unwrap();
        assert!(matches!(
            lock_scope(&env, &dotted),
            Err(CoreError::ScopeBusy { .. })
        ));
    }

    #[test]
    fn trash_receives_removals() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let victim = tmp.path().join("skill");
        fs::create_dir_all(&victim).unwrap();
        fs::write(victim.join("SKILL.md"), "content").unwrap();

        let plan = Plan {
            scope: Scope::Global,
            ops: vec![PlannedOp {
                description: "remove skill".into(),
                op: Op::Trash {
                    path: victim.clone(),
                    pre: Pre::Any,
                },
            }],
        };
        execute(&env, &plan, None).unwrap();
        assert!(!victim.exists());
        let trashed: Vec<_> = fs::read_dir(env.trash_dir()).unwrap().flatten().collect();
        assert_eq!(trashed.len(), 1);
        assert!(trashed[0].path().join("SKILL.md").is_file());
    }
}
