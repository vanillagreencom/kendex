//! The one transaction engine: journal every pre-image, run the ops in
//! order, roll back on the first failure — restoring only what this
//! transaction actually mutated. Who may run it, and under which lock, is
//! the parent module's concern.

use std::path::PathBuf;

use super::{PlannedOp, journal};
use crate::env::Env;
use crate::error::{CoreError, Result};

/// Execute ops under a lock the caller already holds for `key` and after
/// it recovered. Returns how many ops ran.
pub(super) fn run_journaled(env: &Env, ops: &[PlannedOp], key: &str) -> Result<usize> {
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
        if let Err(error) = planned.op.run(env) {
            journal::rollback_mutated(&journal_dir, &mutated_before_failure(ops, index, &error))?;
            return Err(CoreError::RolledBack {
                reason: format!("'{}' failed: {error}", planned.line()),
                cause: Box::new(error),
            });
        }
    }
    journal::clear(&journal_dir)?;
    Ok(ops.len())
}

/// The paths this transaction mutated by the time op `index` failed with
/// `error` — the restore set for the in-process rollback. Every op checks
/// its precondition before touching anything, so a `PlanStale` failure
/// means op `index` mutated nothing: restoring its paths anyway would put
/// the journal's snapshot over the very bytes the refusal protected, when
/// a writer outside the transaction landed them after the journal was
/// taken. Any other failure may have left op `index` half-done, so its
/// paths are restored too.
fn mutated_before_failure(ops: &[PlannedOp], index: usize, error: &CoreError) -> Vec<PathBuf> {
    let ran = match error {
        CoreError::PlanStale { .. } => &ops[..index],
        _ => &ops[..=index],
    };
    ran.iter().flat_map(|p| p.op.touched()).collect()
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
    use crate::apply::{Op, Pre};
    use crate::env::FakeOs;
    use std::fs;

    /// The restore-set split behind the filtered rollback: a refusal that
    /// provably mutated nothing keeps its own paths out of the restore, so
    /// the bytes it refused to overwrite survive the rollback too; a
    /// failure that may have half-run restores them.
    #[test]
    fn a_refusal_keeps_its_own_paths_out_of_the_restore_set() {
        let a = PathBuf::from("/w/a.md");
        let b = PathBuf::from("/w/kendex.toml");
        let op = |path: &PathBuf| PlannedOp {
            description: "write".into(),
            op: Op::WriteFile {
                pre: Pre::Any,
                path: path.clone(),
                bytes: Vec::new(),
            },
        };
        let ops = [op(&a), op(&b)];

        let refused = CoreError::PlanStale { path: b.clone() };
        assert_eq!(
            mutated_before_failure(&ops, 1, &refused),
            std::slice::from_ref(&a)
        );

        let half_done = CoreError::io(&b, std::io::Error::other("disk full"));
        assert_eq!(mutated_before_failure(&ops, 1, &half_done), [a, b]);
    }

    /// The legacy-manifest hazard: the journal snapshots the rename's
    /// source, a writer outside the transaction lands on it, and a
    /// completed rename would carry those bytes to the destination — where
    /// a later refusal's rollback would delete them and put the old
    /// snapshot back over the source. The source precondition refuses
    /// before the move, so the outside edit stands untouched.
    #[test]
    fn a_rename_source_edited_after_journal_capture_refuses_before_moving() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let old = tmp.path().join("agents/orch.md");
        let new = tmp.path().join("agents/lead.md");
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        fs::write(&old, "planned bytes").unwrap();
        let ops = [PlannedOp {
            description: "Rename orch.md to lead.md".into(),
            op: Op::Rename {
                from_pre: Pre::observed(&old).unwrap(),
                from: old.clone(),
                to: new.clone(),
                to_pre: Pre::Absent,
            },
        }];
        let journal_dir = journal::journal_dir_for(&env.journal_dir(), "global");
        journal::write(&journal_dir, &[old.clone(), new.clone()]).unwrap();
        // The outside edit lands after the journal captured its snapshot
        // and before the rename runs.
        fs::write(&old, "external edit").unwrap();

        let error = ops[0].op.run(&env).unwrap_err();
        assert!(matches!(error, CoreError::PlanStale { .. }));
        journal::rollback_mutated(&journal_dir, &mutated_before_failure(&ops, 0, &error)).unwrap();

        assert_eq!(fs::read_to_string(&old).unwrap(), "external edit");
        assert!(!new.exists());
    }
}
