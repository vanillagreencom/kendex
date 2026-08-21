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
    emitted_paths: &BTreeSet<PathBuf>,
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
        let discard = options.overwrite_edited
            || options
                .overwrite_edited_names
                .as_ref()
                .is_some_and(|names| {
                    names
                        .iter()
                        .any(|(k, n)| *k == item.kind && n == &item.name)
                });
        if !discard && holds::hold_local_edit(env, item, scope, lock, &mut sink) {
            continue;
        }
        plan_item(
            env,
            item,
            scope,
            lock,
            emitted_paths,
            options.replace_unmanaged,
            &mut sink,
        )?;
    }
    Ok(())
}

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
            if removal::edit_holds(env, scope, entry) {
                drift.push(DriftRow {
                    kind: refusal.kind,
                    name: refusal.name.clone(),
                    harness: refusal.harness,
                    scope: scope.clone(),
                    state: DriftState::Conflict,
                    detail: format!(
                        "{} — its files were edited on disk and were kept; keep them as a fork or remove the item by name",
                        refusal.reason
                    ),
                    cause: Some(DriftCause::LocalEdit),
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
