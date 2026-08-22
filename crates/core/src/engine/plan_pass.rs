//! The per-item planning pass and the refusal pass — the two walks over
//! the desired state that turn it into drift rows and ops.

use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::model::Scope;

use super::item_plan::plan_item;
use super::{
    DriftCause, DriftRow, DriftState, PlanOptions, config_edits, desired, holds, item_plan,
    removal, tree_plan,
};

/// One pass over the desired items, with the two holds that outrank
/// planning: a revision conflict writes nothing, and an edited install
/// writes nothing unless the caller asked for edits to be discarded.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_items(
    env: &Env,
    state: &desired::DesiredState,
    scope: &Scope,
    lock: &Lock,
    options: &PlanOptions,
    owned_paths: &BTreeSet<PathBuf>,
    legacy_pi: &super::pi_hooks_move::Preflight,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
    written: &mut tree_plan::Written,
) -> Result<()> {
    for item in &state.items {
        let mut sink = item_plan::PlanSink {
            drift,
            ops,
            config_edits,
            new_lock,
            written,
        };
        if holds::hold_rev_conflict(item, scope, lock, &state.rev_conflicts, &mut sink) {
            continue;
        }
        let discard = named(
            item,
            options.overwrite_edited,
            &options.overwrite_edited_names,
        );
        if !discard && holds::hold_local_edit(env, item, scope, lock, &mut sink) {
            continue;
        }
        // Not gated on `discard`: the preflight already took the discard
        // into account, so a hold that survives it is one discarding
        // cannot settle — a copy kendex cannot read, or a registration it
        // cannot take out.
        if holds::hold_legacy_copy(item, scope, lock, legacy_pi, &mut sink) {
            continue;
        }
        let replace = named(
            item,
            options.replace_unmanaged,
            &options.replace_unmanaged_names,
        );
        plan_item(env, item, scope, lock, owned_paths, replace, &mut sink)?;
    }
    Ok(())
}

/// Whether an override reaches this item: the scope-wide form, or the
/// per-item list naming exactly it. Kind and name both, so a same-named
/// item of another kind is never taken along.
fn named(
    item: &desired::Desired,
    scope_wide: bool,
    names: &Option<Vec<(crate::model::ItemKind, String)>>,
) -> bool {
    scope_wide
        || names.as_ref().is_some_and(|names| {
            names
                .iter()
                .any(|(kind, name)| *kind == item.kind && name == &item.name)
        })
}

/// What a refused rendering leaves behind when the person's own edits are
/// in the installation it would have replaced.
const EDITS_KEPT: &str =
    "its files were edited on disk and were kept; keep them as a fork or remove the item by name";

/// A refusal is a conflict the user must resolve, and any previous, wider
/// rendering comes off disk on the default path — leaving it live would
/// keep exactly the access the refusal exists to prevent. Only what this
/// installation alone holds comes off: the tree a refused tool shares with
/// a tool that still installs stays exactly where it is.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_refusals(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    state: &desired::DesiredState,
    legacy_pi: &super::pi_hooks_move::Preflight,
    guard: &mut removal::TrashGuard,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
) -> Result<BTreeSet<String>> {
    let refused_keys: BTreeSet<String> = state
        .refused
        .iter()
        .map(|r| crate::lock::entry_key(r.kind, &r.name, r.harness))
        .collect();
    for refusal in &state.refused {
        let key = crate::lock::entry_key(refusal.kind, &refusal.name, refusal.harness);
        let mut removals = Vec::new();
        if let Some(entry) = lock.entries.get(&key) {
            // A refused rendering takes its previous installation off disk
            // — unless the user's edits are in it. Edited bytes are never
            // an automatic casualty of an upstream change (that is the
            // exact promise of edit protection), so they hold and the
            // conflict says why.
            // The reserved-name move's hold counts here too: what it is
            // holding is still what runs, and its record is the only
            // thing a later pass can claim it with.
            let edited = removal::edit_holds(env, scope, entry);
            let legacy_hold = (refusal.kind == crate::model::ItemKind::Hook
                && refusal.harness == crate::model::HarnessId::Pi)
                .then(|| legacy_pi.hold(&refusal.name))
                .flatten();
            if edited || legacy_hold.is_some() {
                // The refusal says why nothing new was written; the hold
                // says why the old copy is still running, in the same
                // words every other path says it in. Edits in the files
                // outrank it — that is the half a discard can settle.
                let (why, cause) = match legacy_hold.filter(|_| !edited) {
                    Some(hold) => hold.row(EDITS_KEPT),
                    None => (EDITS_KEPT.to_owned(), Some(DriftCause::LocalEdit)),
                };
                drift.push(DriftRow {
                    kind: refusal.kind,
                    name: refusal.name.clone(),
                    harness: refusal.harness,
                    scope: scope.clone(),
                    state: DriftState::Conflict,
                    detail: format!("{} — {why}", refusal.reason),
                    cause,
                });
                // The files stay, so the record of them stays. Dropping it
                // would leave kendex's own rendering on disk with nothing
                // saying kendex wrote it, and the next pass would read it as
                // a stranger's directory — refusing, forever, to write the
                // accepted content over it.
                new_lock.entries.insert(key, entry.clone());
                continue;
            }
            guard.extend(
                &mut removals,
                removal::removal_ops(env, scope, entry, config_edits)?,
            );
        }
        drift.push(DriftRow {
            kind: refusal.kind,
            name: refusal.name.clone(),
            harness: refusal.harness,
            scope: scope.clone(),
            state: DriftState::Conflict,
            detail: match removals.is_empty() {
                false => format!(
                    "{} — the previous installation will be moved to the trash",
                    refusal.reason
                ),
                true => refusal.reason.clone(),
            },
            cause: None,
        });
        ops.append(&mut removals);
    }
    Ok(refused_keys)
}
