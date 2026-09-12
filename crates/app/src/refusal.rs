//! The one shape a content read hands back when it did not land, so a
//! source nothing has downloaded yet reaches the pages as an answer rather
//! than as words they would have to recognise.

use kendex_core::error::CoreError;
use serde::Serialize;
use specta::Type;

/// Why a read of a source's content did not land. A source no fetch has
/// downloaded yet is an answer here, not a failure: the read found the
/// declaration and an empty mirror, asking again answers the same, and only
/// a download lifts it. A page holding the shape can name that state in its
/// own neutral words, drop the retry that would answer the same, and keep
/// its critical text for a read that really went wrong.
///
/// One type for every command that answers it, rather than one per page:
/// telling [`CoreError::SourcePending`] apart from every other refusal is a
/// single question, and a second spelling of it is a page that answers
/// differently about the same source.
///
/// Which commands answer it, and the property deciding that, are
/// `crates/app/AGENTS.md`'s.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum SourceReadRefused {
    /// Nothing has downloaded this source. Names it, which is what the
    /// person downloads.
    SourcePending { source: String },
    /// Anything else that stopped the read, in core's words.
    Failed { message: String },
}

/// The shell around every command: `env()?` refuses with a string, which
/// carries no shape to tell apart.
impl From<String> for SourceReadRefused {
    fn from(message: String) -> SourceReadRefused {
        SourceReadRefused::Failed { message }
    }
}

impl From<CoreError> for SourceReadRefused {
    fn from(error: CoreError) -> SourceReadRefused {
        match error {
            CoreError::SourcePending { name } => SourceReadRefused::SourcePending { source: name },
            other => SourceReadRefused::Failed {
                message: other.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // An undownloaded source reaches the page as its own shape, naming the
    // source, and every other refusal keeps core's words.
    #[test]
    fn an_undownloaded_source_is_its_own_shape() {
        assert!(matches!(
            SourceReadRefused::from(CoreError::SourcePending {
                name: "tools".to_owned(),
            }),
            SourceReadRefused::SourcePending { ref source } if source == "tools"
        ));
        let failed = CoreError::LockCorrupt {
            path: "lock".into(),
            message: "unparsable".to_owned(),
        };
        let words = failed.to_string();
        assert!(matches!(
            SourceReadRefused::from(failed),
            SourceReadRefused::Failed { ref message } if *message == words
        ));
    }
}
