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

/// Whether this hook's registration in the new registry sits under an
/// event kendex did not put it under. Upserting beside it would register
/// the same hook twice, under two events, and the second one is the
/// person's own doing — so the installation holds instead.
pub(super) fn moved_by_hand(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> bool {
    matches!(
        new_registration(env, scope, root, entry, state),
        Registered::Elsewhere | Registered::Ambiguous
    )
}

/// What the new registry says about this hook, under the identity this
/// pass would render it with. Asked once for both questions that ask it —
/// whether the move has finished, and whether a fresh registration would
/// double one the person moved — so the two can never disagree.
///
/// This is the one place the rendered event belongs: what goes into the
/// new registry this pass is exactly what this pass renders, whatever a
/// previous version of the hook was installed under.
fn new_registration(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Registered {
    let here = installed(env, scope, root, entry, state);
    match crate::scan::hooks::read_registrations(&pi::hook_registry(root)) {
        Ok(entries) => registered(&entries, &here),
        // A registry that is not there, or cannot be read, carries no
        // registration of this hook's that anything could act on.
        Err(_) => Registered::Absent,
    }
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
