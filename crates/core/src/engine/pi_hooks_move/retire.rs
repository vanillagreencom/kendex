//! Is a replacement coming? Read off the declaration and this pass's own
//! output, never off whatever happens to sit at the new path.

use crate::apply::{Op, PlannedOp};
use crate::env::Env;
use crate::lock::LockEntry;
use crate::model::{HarnessId, ItemKind, Scope};

use super::super::config_edits::ConfigEditPlan;
use super::super::desired::{Artifact, Desired, DesiredState};
use super::{Found, look};

/// Whether this hook's legacy copy may be retired at all — the "is a
/// replacement coming" question. Nothing asks for it: no replacement is
/// coming and the plan is already dropping it. Asked for and rendered:
/// retired against that rendering. Asked for, resolved, and rendered
/// nothing for pi: the declaration's own answer is that pi gets nothing,
/// so the old copy goes too. A hook still asked for waits whenever this
/// pass did not put its replacement in place — the source did not
/// resolve, or the script or the registration could not be written —
/// the one case where holding on is repair rather than abandonment.
/// What the move should do with one hook's copy under the reserved name.
pub(super) enum Retire {
    /// Nothing asks for this hook any more: the copy goes, and with it
    /// whatever it was still running.
    Unwanted,
    /// Its replacement is in place, so the copy has been superseded.
    Replaced,
    /// Its replacement is not in place yet: the copy is what runs.
    Wait,
}

pub(super) fn retirable(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    manifest: &crate::manifest::Manifest,
    state: &DesiredState,
    ops: &[PlannedOp],
    config_edits: &ConfigEditPlan,
) -> Retire {
    if !asked_for(env, scope, entry, manifest, state) {
        return Retire::Unwanted;
    }
    let key = crate::lock::entry_key(ItemKind::Hook, &entry.name, HarnessId::Pi);
    let Some(item) = state.items.iter().find(|item| item.key == key) else {
        return match state
            .processed
            .contains(&(ItemKind::Hook, entry.name.clone()))
        {
            true => Retire::Unwanted,
            false => Retire::Wait,
        };
    };
    match script_ready(item, ops) && registration_ready(item, config_edits) {
        true => Retire::Replaced,
        false => Retire::Wait,
    }
}

/// Whether anything still asks for this hook — the same question the
/// orphan sweep asks, because the same installations are at stake. A
/// manifest key is one way in. A declaration this pass resolved is the
/// other, and it is how everything the manifest does not key arrives: a
/// bundle member, a dependency, a `[[custom-hooks]]` entry. And an
/// install nobody requested, whose catalog cannot be read right now, is
/// one this pass cannot account for either way — the reason it exists
/// lives in that catalog.
fn asked_for(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    manifest: &crate::manifest::Manifest,
    state: &DesiredState,
) -> bool {
    // A declaration the expansion deliberately drops has been answered,
    // not deferred: the legacy drift-hook spelling standing beside the new
    // one is superseded, and no pass will ever render it.
    if crate::drift::hook::superseded(manifest, &entry.name) {
        return false;
    }
    manifest.hooks.contains_key(&entry.name)
        || state
            .processed
            .contains(&(ItemKind::Hook, entry.name.clone()))
        || (super::super::removal::derived_only(entry)
            && !super::super::removal::origin_readable(env, scope, manifest, state, &entry.source))
}

/// Whether this hook's own script is at its new path — kendex's bytes at
/// kendex's own path, or a write this plan performs. A stranger's file or
/// a link there is a conflict, never a replacement.
fn script_ready(item: &Desired, ops: &[PlannedOp]) -> bool {
    let Artifact::Registration {
        script: Some((path, bytes)),
        ..
    } = &item.artifact
    else {
        return true;
    };
    let planned = ops.iter().any(|planned| match &planned.op {
        Op::WriteFile { path: written, .. } => written == path,
        _ => false,
    });
    planned
        || (matches!(look(path), Found::Plain(_))
            && crate::hash::hash_tree(path)
                .is_ok_and(|disk| disk == crate::hash::hash_bytes(bytes)))
}

/// Whether this hook's own registration is in place — every edit it wants
/// already satisfied on disk, or queued in this same plan as that exact
/// edit. Another hook's edit to the same file proves nothing about this
/// one; no reachable state tells the two apart today, and the narrower
/// question is the one worth asking.
fn registration_ready(item: &Desired, config_edits: &ConfigEditPlan) -> bool {
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return true;
    };
    edits.iter().all(|(path, edit)| {
        let queued = config_edits
            .by_file
            .get(path)
            .is_some_and(|(_, edits)| edits.contains(edit));
        let current = crate::fs::read_if_exists(path)
            .ok()
            .flatten()
            .unwrap_or_default();
        queued || edit.apply(&current).is_ok_and(|updated| updated == current)
    })
}
