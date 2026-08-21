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

/// What the identity the lock recorded for one hook's legacy
/// registration resolves to in a parsed registry.
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
        Some(recorded) => Identity {
            event: Some(recorded.event.clone()),
            matcher: recorded.matcher.clone(),
            command: recorded.command.clone(),
        },
        None => {
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

pub(super) fn registered(entries: &[crate::scan::RawEntry], identity: &Identity) -> Registered {
    // The reader names an entry `event:matcher:stem` and carries the
    // command itself as the description.
    let carrying: Vec<&crate::scan::RawEntry> = entries
        .iter()
        .filter(|entry| entry.description.as_deref() == Some(&identity.command))
        .collect();
    let Some(only) = carrying.first() else {
        return Registered::Absent;
    };
    // Asked before the rest, and of the whole document: a command carried
    // twice is one kendex cannot tell its own copy of, however the two
    // are spread across events. Resolving it by taking the one where the
    // record points would retire that entry and the script with it,
    // leaving the other pointing at nothing.
    if carrying.len() > 1 {
        return Registered::Ambiguous;
    }
    let mut named = only.name.splitn(3, ':');
    let event = named.next();
    let matcher = named.next();
    let differs = |kept: &Option<String>, found: Option<&str>| {
        kept.as_deref().is_some_and(|kept| found != Some(kept))
    };
    match differs(&identity.event, event) || differs(&identity.matcher, matcher) {
        // The one entry carrying the command is not where the record
        // says kendex left it: what is there is somebody's own doing,
        // whether they moved the event or narrowed the matcher.
        true => Registered::Elsewhere,
        // Either it is where the record says, or the record kept nothing
        // to contradict.
        false => Registered::Ours,
    }
}
