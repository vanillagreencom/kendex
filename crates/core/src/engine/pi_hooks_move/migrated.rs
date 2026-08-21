//! Has this hook's installation finished moving, and is what runs it
//! still where kendex put it? Both questions read the new path and the
//! new registry, and both are answered through one reading of the
//! registry so they can never disagree about it.

use super::super::desired::{Artifact, DesiredState};
use super::{Found, Identity, Registered, legacy_registration, look, registered};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::{HarnessId, ItemKind, Scope};

/// Whether this hook's installation has finished moving out of the
/// reserved name — the record first, and only then the reading.
///
/// The record is the whole answer where there is one: a pass that
/// finished the move said so, and nothing that happens on disk
/// afterwards can un-say it. Deriving it from the present is what let an
/// edit to the new copy, or a catalog changing the hook's event, re-open
/// a move that was over — and a re-opened move reads whatever the person
/// has since put under the reserved name as the copy it is owed.
///
/// The reading below is for the installations that finished before there
/// was anywhere to write it down, and it has to be right in the same
/// direction the record is: a wrong "not finished" costs one more derived
/// pass, and a wrong "finished" is written down and cannot be taken back.
/// So it asks for everything a finished move means — the copy apply
/// last wrote is at the new path, nothing of this hook's is registered
/// under the reserved name any more, and what runs it at the new path is
/// what the record says should. Anything it cannot establish reads as
/// unfinished, and a registry it may not read is one of those things.
pub(super) fn moved(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
    linked: bool,
) -> bool {
    // The record settles the reserved name and goes on settling it
    // whatever the registry at the new path has since become. A link
    // there is a question about what may be written, answered where the
    // holds are; it is no evidence about a move that is already over.
    entry.left_pi_reserved_name
        // Without the record there is only the reading, and the reading
        // is of that very document — which is one nothing is read
        // through, so nothing can be proven from it.
        || (!linked
            && lives_at_the_new_path(root, entry)
            && legacy_registration_gone(scope, root, entry)
            && new_registration_stands(env, scope, root, entry, state))
}

fn lives_at_the_new_path(root: &std::path::Path, entry: &LockEntry) -> bool {
    let Some(rendered) = entry.rendered_hash.as_ref() else {
        return false;
    };
    let path = pi::hook_path(root, &entry.name);
    [super::disabled_name(&path), path].iter().any(|path| {
        matches!(look(path), Found::Plain(_))
            && crate::hash::hash_tree(path).is_ok_and(|disk| &disk == rendered)
    })
}

/// Whether nothing of this hook's is registered under the reserved name
/// any more — proven, never assumed. A registry kendex cannot read, or
/// one that is a link it will not read through, may be running the old
/// copy this second; a move whose old registration might still be live is
/// not one to call finished, and calling it finished is permanent.
fn legacy_registration_gone(scope: &Scope, root: &std::path::Path, entry: &LockEntry) -> bool {
    let path = pi::legacy_hook_registry(root);
    match look(&path) {
        Found::Absent => true,
        Found::Plain(_) => crate::scan::hooks::read_registrations(&path).is_ok_and(|entries| {
            matches!(
                registered(&entries, &legacy_registration(entry, scope, root)),
                Registered::Absent
            )
        }),
        Found::Linked(_) | Found::Unreadable(..) => false,
    }
}

/// Whether what runs this hook at the new path is what the record says
/// should. A hook installed disabled registers nothing anywhere — that
/// absence is the installation, not a move half done — so it is asked for
/// explicitly here; read as an unfinished move it would leave every
/// disabled hook migrating for ever.
fn new_registration_stands(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> bool {
    let here = new_registration(env, scope, root, entry, state);
    match entry.enabled {
        true => matches!(here, Registered::Ours),
        false => matches!(here, Registered::Absent),
    }
}

/// Whether the registry every pi hook in a scope registers in is a link
/// kendex did not create.
///
/// A property of the scope and its file, never of one hook's history, so
/// it is asked once before anything reads that document: a link is read
/// through no more than it is written through, and editing one would
/// rewrite a file outside the directory kendex manages.
pub(super) fn linked_registry(root: &std::path::Path) -> bool {
    matches!(look(&pi::hook_registry(root)), Found::Linked(_))
}

/// What is at the new path that this pass would run into.
pub(super) enum Moved {
    /// Nothing: the entry is kendex's own to act on, or there is none.
    No,
    /// An entry somebody moved: registering again would leave the hook
    /// firing under two events.
    Elsewhere,
    /// An entry kendex's own edits step over: registering again would add
    /// a second beside it, and retiring it would take nothing.
    Unreachable,
}

/// Whether this pass can act on what is at the new path at all. Somebody
/// moved the entry, or wrote it in a shape kendex's edits step over —
/// either way what the pass would write lands somewhere other than on
/// what is there, so the installation holds instead.
pub(super) fn moved_by_hand(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Moved {
    match new_registration(env, scope, root, entry, state) {
        Registered::Ours | Registered::Absent => Moved::No,
        Registered::Unreachable => Moved::Unreachable,
        Registered::Elsewhere | Registered::Ambiguous => Moved::Elsewhere,
    }
}

/// What the new registry says about this hook, under the identity the
/// record names. Asked once for both questions that ask it — whether the
/// move has finished, and whether this pass could act on what is there —
/// so the two can never disagree, and neither can be answered without the
/// proof below.
fn new_registration(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Registered {
    let here = installed(env, scope, root, entry, state);
    let registry = pi::hook_registry(root);
    let found = match crate::scan::hooks::read_registrations(&registry) {
        Ok(entries) => registered(&entries, &here),
        // A registry that is not there, or cannot be read, carries no
        // registration of this hook's that anything could act on.
        Err(_) => Registered::Absent,
    };
    match found {
        // Found where the record says is not the same as kendex's to act
        // on. Proven, not assumed — the same reading the old path gets,
        // in the one place every question about the new one comes
        // through, whichever direction the pass is going.
        Registered::Ours if !reaches(env, scope, &registry, entry, &here, state) => {
            Registered::Unreachable
        }
        found => found,
    }
}

/// Whether this pass's own edits reach the entry it just matched, in
/// whichever direction the pass is going.
///
/// An upsert refreshes a handler standing inside a matcher group and
/// steps over one written directly under its event — a shape a person
/// writes and kendex never does. A removal steps over the same shape. The
/// document reads the same either way, so the entry answers to the record
/// while the edit meant to act on it does nothing: a refresh adds a
/// second beside it, and a removal takes the script and the record and
/// leaves it running with nothing left to find it by.
///
/// Asked by applying what this pass would apply and counting what carries
/// the command afterwards. Installing means one, removing means none, and
/// anything else is an edit that missed what it was aimed at. The
/// retirement of a moved identity is applied too, or an ordinary catalog
/// event change would read as unreachable.
///
/// A document that refuses the edit is a conflict the item pass raises on
/// its own, and is not this question's to answer.
fn reaches(
    env: &Env,
    scope: &Scope,
    registry: &std::path::Path,
    entry: &LockEntry,
    here: &Identity,
    state: &DesiredState,
) -> bool {
    let key = crate::lock::entry_key(ItemKind::Hook, &entry.name, HarnessId::Pi);
    let item = state.items.iter().find(|item| item.key == key);
    // Nothing rendered for it means nothing is being installed: what this
    // pass would do with it is take it away, and that is simulated from
    // the same record every removal is built from.
    let (edits, wanted) = match item {
        Some(item) => match &item.artifact {
            Artifact::Registration { edits, .. } => (
                super::super::item_record::retire_previous(item, Some(entry))
                    .into_iter()
                    .chain(edits.iter().cloned())
                    .collect::<Vec<_>>(),
                usize::from(registers(edits, &here.command)),
            ),
            _ => return true,
        },
        None => (super::super::owned::installed(env, scope, entry).edits, 0),
    };
    let Ok(Some(text)) = crate::fs::read_if_exists(registry) else {
        return true;
    };
    let mut after = text;
    for (_, edit) in edits.iter().filter(|(path, _)| path == registry) {
        match edit.apply(&after) {
            Ok(updated) => after = updated,
            Err(_) => return true,
        }
    }
    crate::scan::hooks::registrations_text(&after).is_ok_and(|entries| {
        entries
            .iter()
            .filter(|entry| entry.command == here.command)
            .count()
            == wanted
    })
}

/// Whether this item's edits put the command into the registry, rather
/// than take it out — a hook installed disabled renders the removal of
/// its own entry, and wants none there afterwards.
fn registers(edits: &[(std::path::PathBuf, ConfigEdit)], command: &str) -> bool {
    edits.iter().any(|(_, edit)| match edit {
        ConfigEdit::UpsertHook { command: put, .. }
        | ConfigEdit::UpsertCopilotHook { command: put, .. } => put == command,
        _ => false,
    })
}

/// The entry this hook has at the new path, as the record names it.
///
/// The record is the whole answer where there is one, and it is kept for
/// every hook that registers anything now: what a later pass has to find
/// is what an earlier one wrote. Reading it off the current rendering
/// instead is how a catalog moving a hook to another event came to look
/// like the person moving it by hand — the same mistake this module had
/// to unlearn about the old path, made again about the new one.
///
/// An entry from before the record was kept has no such answer, and
/// nothing invents one: it keeps the reading it always had, which errs
/// towards holding, and earns the record on the first pass that does not
/// hold it.
fn installed(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Identity {
    if let Some(recorded) = &entry.registration {
        return Identity {
            event: Some(recorded.event.clone()),
            matcher: recorded.matcher.clone(),
            command: recorded.command.clone(),
        };
    }
    let command = match crate::engine::targets::hook_target(env, scope, HarnessId::Pi, &entry.name)
    {
        Some(crate::engine::targets::HookTarget::Script { command, .. }) => command,
        _ => legacy_registration(entry, scope, root).command,
    };
    Identity {
        event: rendered_event(state, &entry.name),
        matcher: None,
        command,
    }
}

/// The event this pass registers one hook under, off the registration it
/// renders — the same edit the item pass writes, so the two cannot name
/// different events. A hook this pass does not render has none.
fn rendered_event(state: &DesiredState, name: &str) -> Option<String> {
    let key = crate::lock::entry_key(ItemKind::Hook, name, HarnessId::Pi);
    let item = state.items.iter().find(|item| item.key == key)?;
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return None;
    };
    edits.iter().find_map(|(_, edit)| match edit {
        // A disabled hook renders the reversed registration, which names
        // the same event the enabled one would have been written under.
        ConfigEdit::UpsertHook { event, .. } => Some(event.clone()),
        ConfigEdit::RemoveHook { event, .. } => event.clone(),
        _ => None,
    })
}
