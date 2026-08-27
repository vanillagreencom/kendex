use std::fs;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;

mod common;
pub mod journal;
mod op;
mod pre;
mod transaction;

pub use common::{common_key, execute_common, recover_common_journals};
pub use op::{Op, Plan, PlannedOp, Pre, read_git_config};
use transaction::run_journaled;

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
    _file: crate::fs::LockedFile,
}

fn lock_scope(env: &Env, scope: &Scope) -> Result<ScopeGuard> {
    lock_key(env, &scope_key(scope))
}

pub(crate) fn lock_key(env: &Env, key: &str) -> Result<ScopeGuard> {
    let dir = env.scope_locks_dir();
    fs::create_dir_all(&dir).map_err(|e| CoreError::io(&dir, e))?;
    let path = dir.join(format!("{key}.lock"));
    // Only contention is "busy": a filesystem that cannot lock at all must
    // say so, or every launch pass would skip recovery there in silence.
    match crate::fs::LockedFile::try_exclusive(&path) {
        Ok(Some(file)) => Ok(ScopeGuard { _file: file }),
        Ok(None) => Err(CoreError::ScopeBusy { lock: path }),
        Err(error) => Err(CoreError::io(&path, error)),
    }
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
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use std::path::{Path, PathBuf};

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

    /// A concurrently spawned child holds a copy of every parent fd's open
    /// file description between fork and exec — O_CLOEXEC closes at exec,
    /// not at fork — so a release that relied on closing the fd left flock
    /// held for the length of any other thread's spawn window, and this
    /// process was refused its own lock back with no writer alive. The
    /// try_clone here is that fork copy at the description level: dropping
    /// the guard must release the lock while the copy still exists.
    #[cfg(unix)]
    #[test]
    fn drop_releases_the_lock_while_a_description_copy_exists() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let guard = lock_scope(&env, &Scope::Global).unwrap();
        let copy = guard._file.file().try_clone().unwrap();
        drop(guard);
        let relock = lock_scope(&env, &Scope::Global);
        drop(copy);
        relock.unwrap();
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

    /// An installation whose harness copies are only partly present: the
    /// plan named a copy that is no longer there. The removal reaches the
    /// end state that copy was planned for, so the rest of it lands
    /// instead of rolling back and leaving the item half-present with no
    /// way forward.
    #[test]
    fn a_copy_already_gone_does_not_take_the_removal_with_it() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let present = tmp.path().join("here/SKILL.md");
        fs::create_dir_all(present.parent().unwrap()).unwrap();
        fs::write(&present, "content").unwrap();

        let plan = Plan {
            scope: Scope::Global,
            ops: vec![
                PlannedOp {
                    description: "remove the copy that is gone".into(),
                    op: Op::Trash {
                        path: tmp.path().join("gone"),
                        pre: Pre::HashIs {
                            hash: "whatever the plan saw".into(),
                        },
                    },
                },
                PlannedOp {
                    description: "remove the copy that is here".into(),
                    op: Op::Trash {
                        path: present.clone(),
                        pre: Pre::Any,
                    },
                },
            ],
        };

        assert_eq!(execute(&env, &plan, None).unwrap().applied, 2);
        assert!(!present.exists());
    }

    /// The other half of the same rule: a copy that is still there, and
    /// not the bytes the plan proved it could take, stops the apply.
    #[test]
    fn a_copy_that_changed_still_stops_the_removal() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let edited = tmp.path().join("edited.md");
        fs::write(&edited, "not what the plan read").unwrap();

        let plan = Plan {
            scope: Scope::Global,
            ops: vec![PlannedOp {
                description: "remove the edited copy".into(),
                op: Op::Trash {
                    path: edited.clone(),
                    pre: Pre::HashIs {
                        hash: "what the plan read".into(),
                    },
                },
            }],
        };

        let error = execute(&env, &plan, None).unwrap_err();
        assert!(matches!(error, CoreError::RolledBack { .. }));
        assert_eq!(
            fs::read_to_string(&edited).unwrap(),
            "not what the plan read"
        );
    }
}
