//! The one answer shape for a whole-file write that did not happen.
//!
//! Two whole-file surfaces exist — the Customize tab's manifest and the
//! Settings page's app-settings file — and both refuse a copy of a
//! file that is no longer there. The refusal is one type so the pages
//! render one choice for it, and so the next whole-file surface returns
//! it too instead of inventing a message the UI would have to recognise
//! by its words.

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
    /// Anything else that stopped the write, in the words the person gets.
    Failed { message: String },
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

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
}
