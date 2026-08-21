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
/// unfinished.
pub(super) fn moved(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> bool {
    entry.left_pi_reserved_name
        || (lives_at_the_new_path(root, entry)
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

/// What is at the new path that a fresh registration would run into.
pub(super) enum Moved {
    /// Nothing: the entry is kendex's own to keep up to date, or there is
    /// none.
    No,
    /// An entry somebody moved: registering again would leave the hook
    /// firing under two events.
    Elsewhere,
    /// An entry kendex's own edit cannot reach: registering again would
    /// add a second beside it.
    Unreachable,
}

/// Whether registering this hook again would leave two of it. Somebody
/// moved the entry, or wrote it in a shape kendex's edits step over —
/// either way the fresh rendering lands beside what is there instead of
/// on it, and the installation holds instead.
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
        // Found where the record says is not the same as ours to keep up
        // to date. Proven, not assumed — the same reading the old path
        // gets, in the one place both questions about the new one come
        // through.
        Registered::Ours if !reachable(&registry, entry, &here, state) => Registered::Unreachable,
        found => found,
    }
}

/// Whether this pass's own edits reach the entry it just matched.
///
/// An upsert refreshes a handler standing inside a matcher group and
/// steps over one written directly under its event — a shape a person
/// writes and kendex never does. The document reads the same either way,
/// so the entry answers to the record while the edit meant to keep it
/// current would add a second beside it, and the hook would fire twice
/// for ever after.
///
/// Asked by applying what this pass would apply — the retirement of a
/// moved identity included, or an ordinary catalog event change would
/// read as unreachable — and counting what carries the command
/// afterwards. More than one is an edit that added where it meant to
/// amend.
///
/// A pass that renders nothing for this hook writes nothing, and an edit
/// the document refuses is a conflict the item pass raises on its own;
/// neither is this question's to answer.
fn reachable(
    registry: &std::path::Path,
    entry: &LockEntry,
    here: &Identity,
    state: &DesiredState,
) -> bool {
    let key = crate::lock::entry_key(ItemKind::Hook, &entry.name, HarnessId::Pi);
    let Some(item) = state.items.iter().find(|item| item.key == key) else {
        return true;
    };
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return true;
    };
    let Ok(Some(text)) = crate::fs::read_if_exists(registry) else {
        return true;
    };
    let mut after = text;
    let planned = super::super::item_record::retire_previous(item, Some(entry))
        .into_iter()
        .chain(edits.iter().cloned())
        .filter(|(path, _)| path == registry);
    for (_, edit) in planned {
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
            <= 1
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
