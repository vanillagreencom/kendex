//! Why a whole-manifest write did not happen, and which file it was about.
//!
//! Two questions, and each must not be answered with the other's answer. A
//! file that became something else is a stale copy and the editor has a
//! reload for it; a file that could not be read is a failure, and the
//! reload cannot fix it — offering it sends someone to a remedy for a
//! permission or an encoding. And the file a refusal names is not always
//! the one the caller asked about: a scope still under the old product
//! name renames its manifest first, and every write planned against the
//! old name is retargeted with it.

use std::path::{Path, PathBuf};

use kendex_core::apply::Op;
use kendex_core::error::CoreError;

use super::WriteRefused;

/// What a failed check of the base means to the person holding the copy.
///
/// A file that became something else is a stale copy, and the reload is the
/// way out. A file that could not be read at all is neither: offering the
/// reload for a permission or an encoding sends them to a remedy that
/// cannot fix it, and hides the one thing that would have told them what
/// went wrong.
pub(super) fn refusal(error: CoreError) -> WriteRefused {
    match error {
        CoreError::PlanStale { .. } => WriteRefused::Stale,
        other => WriteRefused::Failed {
            message: other.to_string(),
        },
    }
}

/// Every name this plan's manifest write may answer to: the one the caller
/// read, and the one a rename generation moves it to. A scope still under
/// the old product name renames first and retargets every write planned
/// against the old name, so a refusal from one of them names a file the
/// caller never asked about — the same path-for-identity mistake that
/// missed the binding, arriving in the refusal.
pub(super) fn targets(plan: &kendex_core::apply::Plan, read_at: &Path) -> Vec<PathBuf> {
    let mut targets = vec![read_at.to_path_buf()];
    targets.extend(plan.ops.iter().filter_map(|planned| match &planned.op {
        Op::Rename { from, to, .. } if from == read_at => Some(to.clone()),
        _ => None,
    }));
    targets
}

/// Whether an apply refused because this file moved under it. The write is
/// bound to the file the copy on screen came from, so a rollback with that
/// precondition underneath is the same answer `check_base` gives a moment
/// earlier — and it reaches the person the same way, as a reload to take,
/// rather than as an apply error they can do nothing with.
pub(super) fn stale_at(error: &CoreError, targets: &[PathBuf]) -> bool {
    match error {
        CoreError::PlanStale { path: moved } => targets.contains(moved),
        CoreError::RolledBack { cause, .. } => stale_at(cause, targets),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::apply::{Plan, PlannedOp, Pre};
    use kendex_core::manifest;
    use kendex_core::model::Scope;

    /// The write is bound to the file the copy on screen came from, so a
    /// rollback with that precondition underneath is the same refusal the
    /// check gives — and the editor already knows what to do with it. Told
    /// as an apply failure it reaches the person as a message with no
    /// choice in it.
    #[test]
    fn a_rollback_on_this_file_is_the_refusal_the_editor_can_offer() {
        let path = std::path::PathBuf::from("/w/app/kendex.toml");
        let moved = CoreError::PlanStale { path: path.clone() };
        assert!(stale_at(&moved, std::slice::from_ref(&path)));
        assert!(stale_at(
            &CoreError::RolledBack {
                reason: "'Save kendex.toml' failed".into(),
                cause: Box::new(moved),
            },
            &[path]
        ));
    }

    /// A scope still under the old product name renames its manifest first,
    /// and the write planned against the old name is retargeted with it. The
    /// refusal then names a file the caller never asked about, and matched
    /// against the name it started from it reads as some other failure — so
    /// the reload is not offered and the draft is left unmarked.
    #[test]
    fn a_refusal_after_the_rename_is_still_this_file_moving() {
        let legacy = std::path::PathBuf::from("/w/app/vstack.toml");
        let renamed = std::path::PathBuf::from("/w/app/kendex.toml");
        let plan = Plan {
            scope: Scope::Project {
                root: "/w/app".into(),
            },
            ops: vec![PlannedOp {
                description: "Rename vstack.toml to kendex.toml".into(),
                op: Op::Rename {
                    from: legacy.clone(),
                    to: renamed.clone(),
                    to_pre: Pre::Absent,
                },
            }],
        };
        let targets = targets(&plan, &legacy);

        assert!(stale_at(&CoreError::PlanStale { path: renamed }, &targets));
        assert!(stale_at(&CoreError::PlanStale { path: legacy }, &targets));
        // And still nothing else.
        assert!(!stale_at(
            &CoreError::PlanStale {
                path: "/w/app/.claude/settings.json".into()
            },
            &targets
        ));
    }

    /// A file that cannot be read is not a copy that went stale, and the
    /// reload cannot fix it. Told as one, the person is sent to a remedy
    /// that does nothing and never sees what actually stopped the write.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_manifest_that_cannot_be_read_is_a_failure_and_says_what_it_was() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        // There, and not readable as text — what an editor replacing the
        // file leaves for an instant, or a mode nobody can read.
        std::fs::create_dir(&path).unwrap();

        let error = manifest::check_base(&path, &manifest::Base::absent()).unwrap_err();
        match refusal(error) {
            WriteRefused::Failed { message } => assert!(message.contains("kendex.toml")),
            other => panic!("a reload cannot fix this: {other:?}"),
        }
    }

    /// The copy really did go stale: that is the reload's case.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_file_that_became_something_else_is_the_reload() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        std::fs::write(&path, "schema = 5\n").unwrap();

        let error = manifest::check_base(&path, &manifest::Base::absent()).unwrap_err();
        assert!(matches!(refusal(error), WriteRefused::Stale));
    }

    /// Everything else is a failure, and says so. A precondition that
    /// found another file changed is not this file's story, and neither is
    /// a disk that would not take the write.
    #[test]
    fn every_other_rollback_stays_a_failure() {
        let path = std::path::PathBuf::from("/w/app/kendex.toml");
        assert!(!stale_at(
            &CoreError::PlanStale {
                path: "/w/app/.claude/settings.json".into()
            },
            std::slice::from_ref(&path)
        ));
        assert!(!stale_at(
            &CoreError::RolledBack {
                reason: "'Write skill gh's files' failed".into(),
                cause: Box::new(CoreError::io(
                    &path,
                    std::io::Error::other("read-only file system")
                )),
            },
            &[path]
        ));
    }
}
