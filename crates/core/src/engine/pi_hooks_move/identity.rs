//! Which registration in a document is the one a record names.
//!
//! Every field the lock kept is part of that identity — the command, and
//! the event when it kept one — never the command alone: a command found
//! under an event the record does not name is not this registration, and
//! removing by the recorded event would take nothing while the one
//! somebody moved kept firing.

/// What the identity the lock recorded for one hook's legacy
/// registration resolves to in a parsed registry.
///
/// The identity is every field the record kept — the command, and the
/// event when it kept one — never the command alone. A command found
/// under an event the record does not name is not this registration: it
/// is one somebody moved, and removing by the recorded event would take
/// nothing while the moved one kept firing.
pub(super) enum Registered {
    /// Exactly one registration answers to the recorded identity.
    Ours,
    /// The recorded command is nowhere in this document.
    Absent,
    /// It is here, but not under the identity the record kept.
    Elsewhere,
    /// More than one registration answers to it; none can be told from
    /// the others.
    Ambiguous,
}

pub(super) fn registered(
    entries: &[crate::scan::RawEntry],
    event: Option<&str>,
    command: &str,
) -> Registered {
    // The reader names an entry `event:matcher:stem` and carries the
    // command itself as the description.
    let carrying: Vec<&crate::scan::RawEntry> = entries
        .iter()
        .filter(|entry| entry.description.as_deref() == Some(command))
        .collect();
    let Some(only) = carrying.first() else {
        return Registered::Absent;
    };
    // Asked before the event, and of the whole document: a command
    // carried twice is one kendex cannot tell its own copy of, however
    // the two are spread across events. Resolving it by taking the one
    // under the expected event would retire that entry and the script
    // with it, leaving the other pointing at nothing.
    if carrying.len() > 1 {
        return Registered::Ambiguous;
    }
    match event {
        // The record kept an event, and the one entry carrying the
        // command is not under it: what is there is not this
        // registration.
        Some(event) if only.name.split(':').next() != Some(event) => Registered::Elsewhere,
        // Either the identity names no event — nothing to contradict —
        // or the one entry is under the one it names.
        _ => Registered::Ours,
    }
}
