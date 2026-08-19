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
/// the identity the lock still records.
///
/// Only for a path that IS the entry, though. A repository identity names the
/// repository, and a source recorded at `<entry>/<subdir>` named one directory
/// inside it — the same reason migration never rewrites a subpath onto a
/// remote spec. Offering the identity there installs the repository ROOT over
/// the subtree the lock recorded: it fails outright when the root carries no
/// catalog, and when the root happens to carry a same-named item it exits 0,
/// rewrites `source` to the repository and reports green, with the item now
/// propagating from a subtree the user never chose. That is the silent
/// under-propagation this whole issue is about, so no command is offered.
pub(crate) fn restore_source_argument(source: &str, source_repo: Option<&str>) -> Option<String> {
    // A lock that recorded no source names nothing to re-add: `vstack add ''`
    // is not a command, and the pre-1.0 placeholder shapes reach here.
    if source.trim().is_empty() {
        return None;
    }
    let argument = match remote_cache_entry_for_path(Path::new(source)) {
        Some((_, below)) if below.as_os_str().is_empty() => source_repo.map(str::to_string),
        Some(_) => None,
        None => Some(source.to_string()),
    };
    // The last word on whether a string may be handed back as a COMMAND, for
    // every surface — a report field and a printed line alike. A pasteable
    // argument is the raw string, so a spelling whose display has to hide part
    // of itself would print in the remedy exactly what the cause took care
    // not to. This lived in `absent_source_note`, which is why `check` — which
    // composes the argument itself — leaked a token two of three surfaces
    // withheld.
    argument.filter(|arg| remote_source_display(arg) == *arg)
}

/// The scope flag a printed command needs.
///
/// One place, because a remedy without it is not the same command: pasted from
/// a global entry's report, `vstack add <source>` installs into the PROJECT
/// scope, exits 0, and leaves the global entry exactly as broken. `check`
/// carried the flag from the start; the two surfaces that began prescribing
/// commands this round did not.
pub(crate) fn scope_flag(global: bool) -> &'static str {
    if global { " -g" } else { "" }
}

/// The cause AND the command that repairs it, as one sentence.
///
/// For a surface that prints a LINE — `verify`'s per-row note, `refresh`'s
/// missing-item summary. `check` builds a report instead, carrying the two in
/// separate fields so it can spend its own budget on them and offer the
/// `vstack remove` alternative beside them; it composes the same two pieces.
/// Before this, only `check` named a command at all, so one state had three
/// different answers across the three surfaces.
///
/// The remedy is meant to be pasted, so the source arrives as a shell WORD and
/// not as prose spliced into one: `https://host/team/$(id).git` is a source
/// `RemoteSource` accepts, and interpolating its display form handed the
/// reader a command that runs the substitution.
///
/// And no command at all for a source the CAUSE had to redact. A pasteable
/// argument is the raw string, so emitting one for a spelling whose display
/// hides part of itself — a query carrying a token, a userinfo secret
/// malformed enough that credential scrubbing does not recognise it — would
/// print in the remedy exactly what the cause took care not to. Withholding
/// the command is the same answer this module already gives wherever no
/// command can be both correct and safe.
pub(crate) fn absent_source_note(source: &str, source_repo: Option<&str>, global: bool) -> String {
    let cause = absent_source_reason(source);
    match restore_source_argument(source, source_repo) {
        Some(arg) => format!(
            "{cause} — run `vstack add{} {}`",
            scope_flag(global),
            crate::display::command_arg(&arg)
        ),
        None => cause,
    }
}

/// Why a recorded source produced nothing, for a caller holding no refusal map
/// of its own. One wording for the CAUSE, so `refresh`, `check` and `verify`
/// name the same one for the same state.
///
/// The remedy is [`restore_source_argument`]'s, because it depends on what the
/// lock records and not on the source string alone; each surface composes the
/// two.
pub(crate) fn absent_source_reason(source: &str) -> String {
    if looks_like_remote_source(source) {
        "remote cache not present".to_string()
    } else if source.trim().is_empty() {
        "source not found (none recorded)".to_string()
    } else {
        // Named so the user can see WHICH source vanished, through the same
        // redacting display every other source diagnostic uses: a credential
        // URL malformed enough to evade `parse_remote_url` classifies as a
        // local path and reaches here, and a lock file records the string
        // verbatim.
        let named = format!("source not found: {}", remote_source_display(source));
        match remote_cache_entry_for_path(Path::new(source)) {
            // Otherwise the reader is left wondering why the identity their
            // lock plainly records was not offered as the repair.
            Some((_, below)) if !below.as_os_str().is_empty() => format!(
                "{named} — a directory inside a vstack cache entry, which no repository identity restores"
            ),
            _ => named,
        }
    }
}

#[cfg(test)]
mod tests;
