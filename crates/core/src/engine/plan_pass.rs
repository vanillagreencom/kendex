//! The per-item planning pass, the refusal pass and the withheld pass —
//! the walks over the desired state that turn it into drift rows and ops.

use std::collections::BTreeSet;

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, entry_key};
use crate::manifest::Manifest;
use crate::model::Scope;

use super::item_plan::plan_item;
use super::{
    DriftCause, DriftRow, DriftState, PlanOptions, config_edits, desired, holds, item_plan,
    removal, written,
};

/// One pass over the desired items, with the two holds that outrank
/// planning: a revision conflict writes nothing, and an edited install
/// writes nothing unless the caller asked for edits to be discarded.
/// Returns the fork edits this pass took into their own local sources
/// and the installations whose Missing row is a deletion of what the
/// record says stood there; both are this pass's alone and are not drift.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_items(
    env: &Env,
    state: &desired::DesiredState,
    scope: &Scope,
    lock: &Lock,
    manifest: &crate::manifest::Manifest,
    options: &PlanOptions,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
    written: &mut written::Written,
) -> Result<(Vec<super::ForkEdit>, Vec<super::report_types::RecordedGone>)> {
    let ownership = super::ownership_for_plan(env, scope, lock, &state.items)?;
    let mut absorbed = std::collections::BTreeMap::new();
    let mut fork_edits = Vec::new();
    let mut recorded_gone = Vec::new();
    for item in &state.items {
        let before = drift.len();
        let mut sink = item_plan::PlanSink {
            drift,
            fork_edits: &mut fork_edits,
            absorbed: &mut absorbed,
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
        if !discard && holds::hold_local_edit(env, item, scope, lock, manifest, &mut sink) {
            continue;
        }
        let replace = named(
            item,
            options.replace_unmanaged,
            &options.replace_unmanaged_names,
        );
        plan_item(env, item, scope, lock, &ownership, replace, &mut sink)?;
        let missing = drift[before..]
            .iter()
            .any(|row| row.state == DriftState::Missing);
        if missing && gone_from_record(lock.entries.get(&item.key), item) {
            recorded_gone.push((item.kind, item.name.clone()));
        }
    }
    Ok((fork_edits, recorded_gone))
}

/// Whether a Missing row of this item is a file kendex wrote that is gone:
/// the record says a rendering stood here (`rendered_hash` is set exactly
/// when kendex wrote one) and this pass wants no position the record does
/// not carry — a new one is a layout move between kendex versions, whose
/// recorded file may still be on disk for `stale` to sweep. A record with
/// no positions (a hook's script, an agent) reads on `rendered_hash` alone.
fn gone_from_record(existing: Option<&crate::lock::LockEntry>, item: &desired::Desired) -> bool {
    existing.is_some_and(|entry| {
        entry.rendered_hash.is_some()
            && match (&entry.emitted, &item.emitted) {
                (Some(recorded), Some(wanted)) => wanted
                    .paths
                    .iter()
                    .all(|path| recorded.paths.contains(path)),
                _ => true,
            }
    })
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
fn plan_refusals(
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
            // — unless the user's edits are in it, or the record cannot
            // prove they are not (`edit_holds` draws that line). Edited
            // bytes are not an automatic casualty of an upstream change,
            // so they hold and the conflict says why.
            if removal::edit_holds(env, scope, entry) {
                drift.push(DriftRow {
                    kind: refusal.kind,
                    name: refusal.name.clone(),
                    harness: refusal.harness,
                    scope: scope.clone(),
                    state: DriftState::Conflict,
                    detail: format!("{} — {EDITS_KEPT}", refusal.reason),
                    cause: Some(DriftCause::LocalEdit),
                    compared: None,
                    also_in_the_way: Vec::new(),
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
            compared: None,
            also_in_the_way: Vec::new(),
        });
        ops.append(&mut removals);
    }
    Ok(refused_keys)
}

/// The records planned for outside the item pass, because no item is
/// written for them: what a refusal takes or keeps, then what a
/// withholding takes or keeps. Returns their keys, so the orphan pass asks
/// about none of them.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_not_written(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    guard: &mut removal::TrashGuard,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
) -> Result<BTreeSet<String>> {
    let mut decided = plan_refusals(
        env,
        scope,
        lock,
        state,
        guard,
        drift,
        ops,
        config_edits,
        new_lock,
    )?;
    decided.extend(plan_withheld(
        env,
        scope,
        manifest,
        lock,
        state,
        guard,
        drift,
        ops,
        config_edits,
        new_lock,
    )?);
    Ok(decided)
}

/// The row a withheld hook's installed copy leaves as it goes.
const WITHHELD: &str = "withheld: a hook it runs with will not run here — will be removed";

/// A hook withheld from a tool is written there by nothing, and a copy
/// already installed comes out whatever the options: leaving it would
/// leave a wrapper armed beside a judge that will not run, which is what
/// withholding is for, so it takes the person's edits with it into the
/// trash, and the finding the dependency walk pushed says why. A record
/// under the hook's key that is another declaration's — installed from one
/// catalog, now set to come from another — is invariant 4's conflict, as
/// it would be for a hook the plan writes: the record stays, the row says
/// to remove it first, and nothing of it is taken. Returns the keys of the
/// records this pass decided.
#[allow(clippy::too_many_arguments)]
fn plan_withheld(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    guard: &mut removal::TrashGuard,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
) -> Result<BTreeSet<String>> {
    let mut decided = BTreeSet::new();
    for landing in &state.withheld {
        let key = entry_key(landing.kind, &landing.name, landing.harness);
        let Some(entry) = lock.entries.get(&key) else {
            continue;
        };
        decided.insert(key.clone());
        let row = |state, detail| DriftRow {
            kind: landing.kind,
            name: landing.name.clone(),
            harness: landing.harness,
            scope: scope.clone(),
            state,
            detail,
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        };
        let recorded_fork = manifest.recorded_fork(landing.kind, &landing.name);
        if let Some(detail) = item_plan::rebound(entry, &landing.provenance, recorded_fork) {
            drift.push(row(DriftState::Conflict, detail));
            new_lock.entries.insert(key, entry.clone());
            continue;
        }
        drift.push(row(DriftState::Orphaned, WITHHELD.into()));
        guard.extend(ops, removal::removal_ops(env, scope, entry, config_edits)?);
    }
    Ok(decided)
}
