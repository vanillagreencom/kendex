//! Is a replacement coming? Read off the declaration and this pass's own
//! output, never off whatever happens to sit at the new path.

use crate::apply::{Op, PlannedOp};
use crate::lock::LockEntry;
use crate::model::{HarnessId, ItemKind};

use super::super::config_edits::ConfigEditPlan;
use super::super::desired::{Artifact, Desired, DesiredState};
use super::{Found, look};

/// Whether this hook's legacy copy may be retired at all — the "is a
/// replacement coming" question, read off the declaration rather than off
/// this pass's output. Nothing declares it: no replacement is coming and
/// the plan is already dropping it. Declared and rendered: retired against
/// that rendering. Declared, resolved, and rendered nothing for pi: the
/// declaration's own answer is that pi gets nothing, so the old copy goes
/// too. Only a declaration this pass could not resolve waits — the one
/// case where holding on is repair rather than abandonment.
pub(super) fn retirable(
    entry: &LockEntry,
    manifest: &crate::manifest::Manifest,
    state: &DesiredState,
    ops: &[PlannedOp],
    config_edits: &ConfigEditPlan,
) -> bool {
    if !manifest.hooks.contains_key(&entry.name) {
        return true;
    }
    let key = crate::lock::entry_key(ItemKind::Hook, &entry.name, HarnessId::Pi);
    let Some(item) = state.items.iter().find(|item| item.key == key) else {
        return state
            .processed
            .contains(&(ItemKind::Hook, entry.name.clone()));
    };
    script_ready(item, ops) && registration_ready(item, config_edits)
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
        Op::Rename { to, .. } => to == path,
        _ => false,
    });
    planned
        || (matches!(look(path), Found::Plain(_))
            && crate::hash::hash_tree(path)
                .is_ok_and(|disk| disk == crate::hash::hash_bytes(bytes)))
}

/// Whether this hook's own registration is in place — every edit it wants
/// already satisfied on disk, or queued in this same plan. Another hook's
/// edit to the same file proves nothing about this one.
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
