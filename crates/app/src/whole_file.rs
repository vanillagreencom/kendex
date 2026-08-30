//! The one answer shape for a whole-file write that did not happen.
//!
//! Two whole-file surfaces exist — the Customize tab's manifest and the
//! Settings page's app-settings file — and both refuse a copy of a
//! file that is no longer there. The refusal is one type so the pages
//! render one choice for it, and so the next whole-file surface returns
//! it too instead of inventing a message the UI would have to recognise
//! by its words.

use std::path::PathBuf;

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
    /// else wrote it — a fork, a hold, an install, another window — and
    /// writing this copy would put that back.
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

    #[test]
    fn a_stale_base_is_the_reload_choice_and_any_other_failure_is_not() {
        let path = PathBuf::from("/w/app/kendex.toml");
        assert!(matches!(
            refusal(CoreError::PlanStale { path }),
            WriteRefused::Stale
        ));
        assert!(matches!(
            refusal(CoreError::LegacyManifest {
                path: PathBuf::from("/w/app/kendex.toml"),
                message: "it names no schema".to_owned(),
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

    /// A refusal can name only the path core lists for the scope — and
    /// nothing else.
    #[test]
    fn a_refusal_matches_the_name_the_scope_manifest_answers_to() {
        let targets = [PathBuf::from("/w/app/kendex.toml")];
        for name in &targets {
            assert!(stale_at(
                &CoreError::PlanStale { path: name.clone() },
                &targets
            ));
        }
        assert!(!stale_at(
            &CoreError::PlanStale {
                path: "/w/app/.claude/settings.json".into()
            },
            &targets
        ));
    }
}
