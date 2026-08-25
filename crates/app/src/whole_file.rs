//! The one answer shape for a whole-file write that did not happen.
//!
//! Two whole-file surfaces exist — the Customize tab's manifest and the
//! Settings page's `kendex.settings.toml` — and both refuse a copy of a
//! file that is no longer there. The refusal is one type so the pages
//! render one choice for it, and so the next whole-file surface returns
//! it too instead of inventing a message the UI would have to recognise
//! by its words.

use std::path::{Path, PathBuf};

use kendex_core::apply::Op;
use kendex_core::error::CoreError;
use serde::Serialize;
use specta::Type;

/// Why a whole-file write did not happen. Refusing is a normal answer
/// here, not a failure, so it is a shape the page can act on rather than
/// a message it would have to recognise by its words.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum WriteRefused {
    /// The file is no longer the one this copy was read from. Something
    /// else wrote it — a fork, a hold, a dismissal, an install, another
    /// window — and writing this copy would put that back.
    Stale,
    Failed {
        message: String,
    },
}

impl From<String> for WriteRefused {
    fn from(message: String) -> WriteRefused {
        WriteRefused::Failed { message }
    }
}

/// What a failed base check means to the person holding the copy.
///
/// A file that became something else is a stale copy, and the reload is
/// the way out. A file that could not be read at all is neither: offering
/// the reload for a permission or an encoding sends them to a remedy that
/// cannot fix it, and hides the one thing that would have told them what
/// went wrong.
pub fn refusal(error: CoreError) -> WriteRefused {
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
/// caller never asked about.
pub fn targets(plan: &kendex_core::apply::Plan, read_at: &Path) -> Vec<PathBuf> {
    let mut targets = vec![read_at.to_path_buf()];
    targets.extend(plan.ops.iter().filter_map(|planned| match &planned.op {
        Op::Rename { from, to, .. } if from == read_at => Some(to.clone()),
        _ => None,
    }));
    targets
}

/// Whether an apply refused because this file moved under it. The write is
/// bound to the file the copy on screen came from, so a rollback with that
/// precondition underneath is the same answer the base check gives a
/// moment earlier — and it reaches the person the same way, as a reload to
/// take, rather than as an apply error they can do nothing with.
pub fn stale_at(error: &CoreError, targets: &[PathBuf]) -> bool {
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
    use kendex_core::model::Scope;

    #[test]
    fn a_stale_base_is_the_reload_choice_and_any_other_failure_is_not() {
        let path = PathBuf::from("/w/app/kendex.toml");
        assert!(matches!(
            refusal(CoreError::PlanStale { path }),
            WriteRefused::Stale
        ));
        assert!(matches!(
            refusal(CoreError::LegacyManifest {
                path: PathBuf::from("/w/app/kendex.toml")
            }),
            WriteRefused::Failed { .. }
        ));
    }

    /// The write is bound to the file the copy on screen came from, so a
    /// rollback with that precondition underneath is the same refusal the
    /// check gives — and the page already knows what to do with it. Told
    /// as an apply failure it reaches the person as a message with no
    /// choice in it.
    #[test]
    fn a_rollback_on_this_file_is_the_refusal_the_page_can_offer() {
        let path = PathBuf::from("/w/app/kendex.toml");
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

    /// A scope still under the old product name renames its manifest first
    /// and the write planned against the old name is retargeted with it.
    /// The refusal then names a file the caller never asked about, and
    /// matched against only the name it started from it would read as some
    /// other failure — so the reload would not be offered.
    #[test]
    fn a_refusal_after_the_rename_is_still_this_file_moving() {
        let legacy = PathBuf::from("/w/app/vstack.toml");
        let renamed = PathBuf::from("/w/app/kendex.toml");
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
        assert!(!stale_at(
            &CoreError::PlanStale {
                path: "/w/app/.claude/settings.json".into()
            },
            &targets
        ));
    }
}
