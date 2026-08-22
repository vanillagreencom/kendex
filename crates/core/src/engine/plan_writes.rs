//! The two passes that put writes in a plan: what every declared item
//! renders, and what the reserved-name move takes with it. Both carry a
//! long line of sinks — the drift list, the op list, the config edits, the
//! lock being built — and gathering the calls here keeps `plan_scope` a
//! readable sequence of steps rather than their arguments.

use std::collections::BTreeSet;

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

use super::{
    DriftRow, PlanOptions, config_edits, desired, emitted_paths, pi_hooks_move, plan_pass, removal,
    tree_plan,
};

/// Every declared item this pass renders, and which packages it rendered
/// whole. A caller acting on one package reads that set rather than the op
/// list: a scope carries its own maintenance, so ops exist whether or not
/// the package it named got one.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_item_writes(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    state: &desired::DesiredState,
    options: &PlanOptions,
    legacy_pi: &pi_hooks_move::Preflight,
    drift: &mut Vec<DriftRow>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut config_edits::ConfigEditPlan,
    new_lock: &mut Lock,
    written: &mut tree_plan::Written,
) -> Result<BTreeSet<(ItemKind, String)>> {
    let emitted = emitted_paths(lock);
    let mut rendered: BTreeSet<(ItemKind, String)> = BTreeSet::new();
    plan_pass::plan_items(
        env,
        state,
        scope,
        lock,
        options,
        &emitted,
        legacy_pi,
        drift,
        ops,
        config_edits,
        new_lock,
        written,
        &mut rendered,
    )?;
    Ok(rendered)
}

/// The reserved-name move reads both records: the lock says what kendex
/// may take, and the desired state says whether a replacement is coming —
/// a hook nothing declares any more is retired outright, one this pass
/// could not render keeps what it has.
#[allow(clippy::too_many_arguments)]
pub(super) fn plan_reserved_name_move(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    state: &desired::DesiredState,
    legacy_pi: &pi_hooks_move::Preflight,
    ops: &mut Vec<PlannedOp>,
    guard: &mut removal::TrashGuard,
    config_edits: &mut config_edits::ConfigEditPlan,
    notes: &mut Vec<String>,
) -> Result<BTreeSet<String>> {
    pi_hooks_move::plan_move(
        env,
        scope,
        manifest,
        lock,
        state,
        legacy_pi,
        &mut pi_hooks_move::Sink {
            ops,
            guard,
            config_edits,
            notes,
        },
    )
}
