//! The per-item planning pass and the refusal pass — the two walks over
//! the desired state that turn it into drift rows and ops.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::model::{ItemKind, Scope};

use super::item_plan::plan_item;
use super::{
    DriftCause, DriftRow, DriftState, DriftSubject, PlanOptions, config_edits, desired, holds,
    item_plan, removal, tree_plan,
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
    legacy_pi: &super::pi_hooks_move::Preflight,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
    written: &mut tree_plan::Written,
    // What this pass planned a rendering for. A caller acting on one
    // package cannot read that off the op list: a scope brings its own
    // maintenance along, so ops exist whether or not the package it named
    // got one, and every reason a package is skipped above leaves the
    // same silence behind.
    rendered: &mut BTreeSet<(ItemKind, String)>,
) -> Result<()> {
    // A package can target several tools, and each is its own item here.
    // The set below is asked per package, so a package counts as rendered
    // only when every item under it was: one tool refused while another
    // installs leaves edited files exactly where they are, and a caller
    // told the package was restored would be reading one tool's success
    // as all of them.
    let mut wanted: BTreeMap<(ItemKind, String), usize> = BTreeMap::new();
    let mut done: BTreeMap<(ItemKind, String), usize> = BTreeMap::new();
    for item in &state.items {
        let mut sink = item_plan::PlanSink {
            drift,
            ops,
            config_edits,
            new_lock,
            written,
        };
        // Not this plan's package: its record carries forward and nothing
        // is planned for it, the same way a held item's does. Dropping the
        // record instead would write a lock that forgets what is installed.
        *wanted.entry((item.kind, item.name.clone())).or_default() += 1;
        if !state.acts_on(item.kind, &item.name) {
            if let Some(entry) = lock.entries.get(&item.key) {
                sink.new_lock
                    .entries
                    .insert(item.key.clone(), entry.clone());
            }
            continue;
        }
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
        // Not gated on `discard`: the preflight already took the discard
        // into account, so a hold that survives it is one discarding
        // cannot settle — a copy kendex cannot read, or a registration it
        // cannot take out.
        if holds::hold_legacy_copy(item, scope, lock, legacy_pi, &mut sink) {
            continue;
        }
        // Only when the rendering is actually accounted for: `plan_item`
        // returns without one when the target conflicts, and recording it
        // anyway would tell a caller its package was put back.
        if plan_item(env, item, scope, lock, emitted_paths, &mut sink)? {
            *done.entry((item.kind, item.name.clone())).or_default() += 1;
        }
    }
    for (key, count) in wanted {
        if done.get(&key) == Some(&count) {
            rendered.insert(key);
        }
    }
    // A tool the gate refused never reached the loop above: the refusal
    // takes it out of `items` and records it in `refused`, so counting
    // items alone cannot see it and the package's other tools would speak
    // for it. `plan_refusals` keeps its edited files exactly where they
    // are, which is the state a caller must not be told is restored.
    for refusal in &state.refused {
        if state.acts_on(refusal.kind, &refusal.name) {
            rendered.remove(&(refusal.kind, refusal.name.clone()));
        }
    }
    Ok(())
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
            // A refused rendering takes its previous installation off disk,
            // and three things keep it there. It may not be this plan's
            // package: taking a sibling's files is not a command about
            // another package's to do, and the next unrestricted pass —
            // every audit, every apply — takes them. Or the user's edits
            // are in it, and edited bytes are never an automatic casualty
            // (that is the exact promise of edit protection). Or the
            // reserved-name move holds it, and what it holds is still what
            // runs. Either way the record stays with the files it
            // describes.
            let edited = removal::edit_holds(env, scope, entry);
            let legacy_hold = (refusal.kind == crate::model::ItemKind::Hook
                && refusal.harness == crate::model::HarnessId::Pi)
                .then(|| legacy_pi.hold(&refusal.name))
                .flatten();
            if !state.acts_on(refusal.kind, &refusal.name) {
                new_lock.entries.insert(key.clone(), entry.clone());
            } else if edited || legacy_hold.is_some() {
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
                    subject: DriftSubject::Package,
                    detail: format!("{} — {why}", refusal.reason),
                    cause,
                });
                // The files stay, so the record of them stays. Dropping it
                // would leave kendex's own rendering on disk with nothing
                // saying kendex wrote it, and the next pass would read it as
                // a stranger's directory — refusing, forever, to write the
                // accepted content over it.
                new_lock.entries.insert(key, entry.clone());
                // The conflict says why; nothing else is planned for it.
                continue;
            } else {
                guard.extend(
                    &mut removals,
                    removal::removal_ops(env, scope, entry, config_edits)?,
                );
            }
        }
        drift.push(DriftRow {
            kind: refusal.kind,
            name: refusal.name.clone(),
            harness: refusal.harness,
            scope: scope.clone(),
            state: DriftState::Conflict,
            subject: DriftSubject::Package,
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
