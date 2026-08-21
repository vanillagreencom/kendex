//! Which registration in a document is the one a record names.
//!
//! Every field the lock kept is part of that identity — the command, and
//! the event and matcher where it kept them — never the command alone: an
//! entry found where the record does not point is not this registration,
//! and removing by the recorded identity would take nothing while the one
//! somebody moved kept firing. What the record did not keep is unknown,
//! and unknown is never filled in from what this pass would render: a
//! catalog is free to have changed either since the entry was written.

use std::path::Path;

use super::LEGACY_DIR;
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::Scope;

/// What the identity the lock recorded for one hook's registration
/// resolves to in a registry.
///
/// The first four are what identity matching alone can say. The last is
/// an answer about what kendex may do with what it found — a shape its
/// own edits step over — which the caller that reads the document adds.
pub(super) enum Registered {
    /// Exactly one registration answers to the recorded identity.
    Ours,
    /// The recorded command is nowhere in this document.
    Absent,
    /// It is here, but not where the identity the record kept points.
    Elsewhere,
    /// More than one registration answers to it; none can be told from
    /// the others.
    Ambiguous,
    /// It is exactly where the record says — and written in a shape
    /// kendex's own edit cannot reach, so applying that edit would put a
    /// second entry beside it rather than keep it up to date, or leave it
    /// running when the pass meant to take it out.
    Unreachable,
}

/// What the record kept of one registration — everything the identity has
/// to go on, and nothing derived from what this pass would write. A field
/// left `None` is one the record never held: unknown, which is not the
/// same as "none", and is never compared.
pub(super) struct Identity {
    pub(super) event: Option<String>,
    pub(super) matcher: Option<String>,
    pub(super) command: String,
}

/// The registry entry one hook left behind, as the identity that names
/// it: the event it fires on and the command that runs.
///
/// The record carries both for a script-less custom hook, whose command
/// is the person's own and cannot be re-derived. A script-backed hook
/// keeps no record of either, so the command is re-derived from the old
/// layout and the event is left unsaid — because the event the older
/// kendex registered it under is not knowable here. It is not the event
/// this pass renders: a catalog is free to change a hook's event, and
/// then the registration waiting to be migrated sits under the event the
/// previous version installed. Reading the new event onto the old entry
/// would call an ordinary catalog change tampering and hold the
/// installation with nothing the person could do about it.
///
/// What keeps that honest is the uniqueness rule the identity applies:
/// with no event to check, a command carried once in the document is
/// kendex's own, and a command carried twice is nobody's to take.
pub(super) fn legacy_registration(entry: &LockEntry, scope: &Scope, root: &Path) -> Identity {
    match &entry.registration {
        // A hook with no script of its own is one registry entry and
        // nothing else — the person's own command, which says nothing
        // about a path and so reads the same wherever the entry lives.
        // The record names it under the reserved name as surely as at the
        // new one.
        Some(recorded) if entry.rendered_hash.is_none() => Identity {
            event: Some(recorded.event.clone()),
            matcher: recorded.matcher.clone(),
            command: recorded.command.clone(),
        },
        // A script-backed hook's record describes the entry at the new
        // path: its command spells that path, and its event is the one
        // this install registered there — neither of them evidence about
        // what an older kendex wrote under the reserved name. So the
        // command is derived from the old layout and the rest stays
        // unsaid, which is where it was left when reading the new event
        // onto the old entry turned a catalog's own change into
        // tampering.
        _ => {
            let file = pi::hook_file(&entry.name);
            let command = match scope {
                Scope::Global => {
                    format!("bash \"{}\"", root.join(LEGACY_DIR).join(&file).display())
                }
                Scope::Project { .. } => {
                    format!("bash \"$(git rev-parse --show-toplevel)/.pi/{LEGACY_DIR}/{file}\"")
                }
            };
            Identity {
                event: None,
                matcher: None,
                command,
            }
        }
    }
}

pub(super) fn registered(
    entries: &[crate::scan::hooks::Registration],
    identity: &Identity,
) -> Registered {
    // Everything the record can tell this registration by: its command,
    // and the event and matcher wherever it kept them. The parts as the
    // document keys them, never a name taken apart again — the character
    // that joins those parts for display is legal inside two of them.
    let answering: Vec<&crate::scan::hooks::Registration> = entries
        .iter()
        .filter(|entry| {
            entry.command == identity.command
                && identity
                    .event
                    .as_deref()
                    .is_none_or(|event| entry.event == event)
                && identity
                    .matcher
                    .as_deref()
                    .is_none_or(|matcher| entry.matcher == matcher)
        })
        .collect();
    match answering.len() {
        // Exactly one thing in the document is what the record describes.
        1 => Registered::Ours,
        // More than one, and every field the record kept is the same
        // across them: kendex cannot tell its own from the others, and
        // taking one by guess would leave the rest running a script it
        // had taken away. A record naming an event and a matcher can tell
        // two such entries apart, and two entries it can tell apart are
        // two registrations rather than one puzzle.
        2.. => Registered::Ambiguous,
        // Nothing answers to the record. Whether that is because there is
        // nothing of this hook's here at all, or because somebody moved
        // what is here, is what the command alone can still say.
        0 => match entries
            .iter()
            .any(|entry| entry.command == identity.command)
        {
            true => Registered::Elsewhere,
            false => Registered::Absent,
        },
    }
}
