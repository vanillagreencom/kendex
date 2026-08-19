//! What a caller is told about a recorded source that produced nothing: why,
//! and what to run about it.
//!
//! One wording and one remedy, so `refresh`, `check` and `verify` name the
//! same cause and the same command for the same state — and so the command
//! they name is one that works.

use super::*;
use std::path::Path;

/// The argument `vstack add` must be given to restore an absent source, or
/// `None` when no `add` can restore it.
///
/// For every ordinary source that is the source itself — re-adding what went
/// missing is the repair. A path into vstack's OWN cache is the exception:
/// that directory is a clone vstack mints, not a source a user keeps, so
/// `vstack add <that path>` has nothing to read and fails outright. Under the
/// same-tree migration rule a legacy-key entry keeps its cache path in the
/// lock permanently, which makes a wiped cache the durable steady state for
/// exactly the population this defect was found on — so the remedy comes from
/// the identity the lock still records, and when it records none, no command
/// is offered rather than one that cannot work.
pub(crate) fn restore_source_argument(source: &str, source_repo: Option<&str>) -> Option<String> {
    if is_remote_cache_entry_path(Path::new(source)) {
        return source_repo.map(str::to_string);
    }
    Some(source.to_string())
}

/// Why a recorded source produced nothing, for a caller holding no refusal map
/// of its own. One wording, so `refresh`, `check` and `verify` name the same
/// cause and the same command for the same state.
pub(crate) fn absent_source_reason(source: &str) -> String {
    if looks_like_remote_source(source) {
        // The remedy is meant to be pasted, so the source arrives as a shell
        // WORD, not as prose spliced into one: `https://host/team/$(id).git`
        // is a source `RemoteSource` accepts, and interpolating its display
        // form handed the reader a command that runs the substitution.
        format!(
            "remote cache not present — run `vstack add {}`",
            crate::display::command_arg(source)
        )
    } else if source.trim().is_empty() {
        "source not found (none recorded)".to_string()
    } else {
        // Named so the user can see WHICH source vanished, through the same
        // redacting display every other source diagnostic uses: a credential
        // URL malformed enough to evade `parse_remote_url` classifies as a
        // local path and reaches here, and a lock file records the string
        // verbatim.
        format!("source not found: {}", remote_source_display(source))
    }
}
