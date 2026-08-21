//! Has this hook's installation finished moving, and is what runs it
//! still where kendex put it? Both questions read the new path and the
//! new registry, and both are answered through one reading of the
//! registry so they can never disagree about it.

use super::super::desired::DesiredState;
use super::{Found, Registered, legacy_registration, look, registered};
use crate::env::Env;
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::{HarnessId, Scope};

/// Whether this hook's installation has already finished moving. Two
/// things have to be true, and bytes are only the first: the copy apply
/// last wrote is at the new path, AND the new registration is the one
/// that runs it — either the new registry names it, or nothing of
/// kendex's is registered under the reserved name any more. A clean copy
/// at the new path while the old registration still runs is a migration
/// half done, not one finished.
///
/// Once both hold, a same-named file under the reserved name is a
/// stranger's, and a stranger must never freeze a working installation.
pub(super) fn moved(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> bool {
    lives_at_the_new_path(root, entry) && new_registration_runs_it(env, scope, root, entry, state)
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

/// Whether execution has moved with the bytes: the new registry carries
/// this hook's registration, or the legacy one carries nothing of its.
fn new_registration_runs_it(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> bool {
    let (event, command) = legacy_registration(entry, scope, root, state);
    matches!(
        new_registration(env, scope, root, entry, state),
        Registered::Ours
    ) || !matches!(
        look(&pi::legacy_hook_registry(root)),
        Found::Plain(_) | Found::Linked(_)
    ) || crate::scan::hooks::read(&pi::legacy_hook_registry(root)).is_ok_and(|entries| {
        matches!(
            registered(&entries, event.as_deref(), &command),
            Registered::Absent
        )
    })
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
fn new_registration(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Registered {
    let (event, legacy) = legacy_registration(entry, scope, root, state);
    let rendered = match crate::engine::targets::hook_target(env, scope, HarnessId::Pi, &entry.name)
    {
        Some(crate::engine::targets::HookTarget::Script { command, .. }) => command,
        _ => legacy.clone(),
    };
    // A script-less hook registered the person's own command, which the
    // new path does not change; a script-backed one registered the
    // command its new path spells.
    let command = entry
        .registration
        .as_ref()
        .map_or(rendered, |recorded| recorded.command.clone());
    match crate::scan::hooks::read(&pi::hook_registry(root)) {
        Ok(entries) => registered(&entries, event.as_deref(), &command),
        // A registry that is not there, or cannot be read, carries no
        // registration of this hook's that anything could act on.
        Err(_) => Registered::Absent,
    }
}
