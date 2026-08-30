use std::collections::BTreeMap;

use crate::apply::{Plan, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;

pub mod adopt;
mod agent_carry;
mod agent_skills;
pub(crate) mod bundles;
mod catalog;
mod config_edits;
mod copilot;
pub mod deps;
pub mod desired;
mod desired_agent;
mod desired_command;
mod desired_custom_hooks;
mod desired_item;
mod desired_kinds;
mod desired_mcp;
mod desired_skill;
mod desired_source;
pub mod detach;
pub mod exits;
mod expansion;
mod file_plan;
pub mod fork;
mod gemini;
mod holds;
mod item_plan;
mod item_record;
mod item_source;
mod observed;
pub mod ops;
mod owned;
mod plan_pass;
mod planned;
pub mod posture;
mod removal;
mod scope_skills;
pub use scope_skills::ScopeSkills;
mod scope_writes;
mod settings_scan;
pub use settings_scan::settings_templates;
mod scoring;
mod set_change;
mod stale;
mod takeover;
mod targets;
mod tree_plan;
mod unmanaged;
pub use unmanaged::unmanaged_here;
mod written;

pub(crate) use desired_agent::contributes_to_agent;
pub use expansion::{NO_PER_PACKAGE_UPDATE, plans_per_package};
pub use item_source::{ItemSource, item_source};
pub use observed::observed_rows;
pub use planned::{PlannedDeclaration, planned_declarations};
pub use scoring::ItemSafety;

/// The conservative "cannot prove these bytes are our render" hold.
pub use removal::edit_holds;
pub(crate) use targets::hook_target;

/// Every file path one lock entry put on this machine — what a cheap
/// existence check can stat without reading any source.
pub fn installed_paths(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    entry: &crate::lock::LockEntry,
) -> Vec<std::path::PathBuf> {
    owned::installed(env, scope, entry).files
}

use desired::desired_state;
pub use scope_writes::persists_manifest;
use scope_writes::{
    bundle_revisions, plan_config_edits, plan_lock_write, plan_manifest_write, plan_settings_seed,
    source_revisions,
};
pub use set_change::{KeptInstall, SetChange, SetDirection};
use set_change::{kept_members, set_changes};
pub(crate) use unmanaged::declared_over_existing_files;
use unmanaged::unmanaged_rows;

mod compared;
pub use compared::Comparison;
mod repo_effects;
mod report_types;
pub use report_types::{DriftCause, DriftRow, DriftState, EngineReport, ItemWarning, PlanOptions};

/// Compute drift and the plan that would fix it — the Audit page and
/// `apply` both consume this.
pub fn plan_scope(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<EngineReport> {
    let report = plan_scope_once(env, scope, manifest, lock, options)?;
    takeover::hold_back_sweep(options, report, |sweep| {
        plan_scope_once(env, scope, manifest, lock, sweep)
    })
}

fn plan_scope_once(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<EngineReport> {
    // Identity first: derived paths and the scope lock key off canonical.
    let scope = &scope.canonical();
    let disk_lock = lock;
    // What the person declared, as this build reads it: the manifest any
    // write this plan carries is built from.
    let declared = manifest;
    // A single-package update reads from a copy of the manifest with every
    // other follower pinned at its installed commit — the pins steer this
    // pass and never reach the file.
    let (manifest, state) = desired_pass(env, scope, declared, lock, options)?;
    // Advisory scoring over what this plan would write, before the ops are
    // planned: the rows ride out on the report beside the plan.
    let safety = scoring::run(scope, &state);
    let mut drift = Vec::new();
    let mut ops: Vec<PlannedOp> = Vec::new();
    let mut new_lock = fresh_lock(&manifest, lock, &state);
    let mut written = written::Written::default();
    let mut config_edits = config_edits::ConfigEditPlan::default();

    let base = options.manifest_base.as_ref();
    plan_manifest_write(env, scope, base, &state, &mut ops)?;

    plan_pass::plan_items(
        env,
        &state,
        scope,
        lock,
        options,
        &owned::paths(env, scope, lock),
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
        &mut written,
    )?;

    // Notes about the scope rather than about any one item: what the
    // settings seed found, what the git posture changed.
    let mut scope_notes =
        plan_settings_seed(scope, &state, options, &mut new_lock, &mut ops, &mut drift)?;

    // Trash ops all pass one guard: writes for this pass are already
    // planned, so anything still wanted is known, and no path goes to the
    // trash twice.
    let mut guard = removal::TrashGuard::new(&state.items);

    stale::stale_emitted(lock, &new_lock, &mut guard, &mut ops)?;

    let refused_keys = plan_pass::plan_refusals(
        env,
        scope,
        lock,
        &state,
        &mut guard,
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
    )?;

    let sweepable = removal::orphans(
        env,
        scope,
        &manifest,
        lock,
        &state,
        options,
        &refused_keys,
        &mut guard,
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
    )?;

    stale::stale_instruction_rows(env, scope, lock, &new_lock, &mut config_edits)?;
    plan_config_edits(env, scope, config_edits, &mut ops)?;
    let set_changes = set_changes(lock, &new_lock);
    let kept = kept_members(lock, &new_lock, &options.uninstalled_bundles);
    let repo_effects_leaving = repo_effects::leaving(env, scope, lock, &new_lock)?;
    plan_lock_write(env, scope, disk_lock, new_lock, &mut ops)?;
    scope_notes.extend(scope_wide(scope, &mut ops)?);

    let mut report = EngineReport {
        // Ahead of the moves out of `state` below, and read before `drift`
        // moves in: an effect belongs to a package this pass adds to what
        // the scope carries, and to no other.
        repo_effects: repo_effects::run(&state, &drift, &set_changes, lock),
        repo_effects_leaving,
        drift,
        plan: Plan::landed(scope.clone(), ops)?,
        notes: state.notes,
        warnings: state.warnings,
        set_changes,
        sweepable,
        kept,
        safety,
    };
    report.notes.extend(scope_notes);
    unmanaged_rows(env, scope, &manifest, lock, &state.items, &mut report.drift)?;
    takeover::refuse_unsettled_takeover(options, &report.drift)?;
    Ok(report)
}

/// The writes a pass owes the scope as a whole rather than any one item:
/// the git posture. It runs after every item is planned, so it sees the
/// finished op list.
fn scope_wide(scope: &Scope, ops: &mut Vec<PlannedOp>) -> Result<Vec<String>> {
    let mut notes = Vec::new();
    posture::plan_posture(scope, ops, &mut notes)?;
    Ok(notes)
}

/// The manifest this pass reads from and the state it derives: `declared`
/// itself, or — under `update_only` — a copy with every other follower
/// pinned at the commit its lock entries agree on.
///
/// The synthetic holds come back out of the manifest this pass computed
/// before anything can write it: that manifest is a copy of the pinned
/// one, and no written manifest may carry a pin as if the person had
/// chosen it.
fn desired_pass<'a>(
    env: &Env,
    scope: &Scope,
    declared: &'a Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<(std::borrow::Cow<'a, Manifest>, desired::DesiredState)> {
    let (planning, held_pins) = desired::hold::planning_manifest(declared, lock, options);
    let mut state = desired_state(
        env,
        scope,
        planning.as_ref(),
        lock,
        options.hold_upstream_skills,
        held_pins.as_ref(),
    )?;
    if let (Some(pins), Some(update)) = (&held_pins, state.manifest_update.as_mut()) {
        pins.unpin(update);
    }
    Ok((planning, state))
}

/// The record this pass will write, before any of it is filled in: the
/// per-source and per-set resolutions it just made, and the seeding
/// evidence carried forward — only seeding and refresh may move that.
fn fresh_lock(manifest: &Manifest, lock: &Lock, state: &desired::DesiredState) -> Lock {
    Lock {
        version: crate::lock::LOCK_VERSION,
        root: lock.root.clone(),
        entries: BTreeMap::new(),
        sources: source_revisions(manifest, lock, state),
        bundles: bundle_revisions(manifest, lock, state),
        settings_seeds: lock.settings_seeds.clone(),
    }
}

/// Read-only audit for a scope. A scope with no manifest still reports
/// unmanaged items; one whose manifest or lock this build cannot read is
/// refused at the door, so this answers for it with the refusal rather
/// than with an empty report.
pub fn audit(env: &Env, scope: &Scope) -> Result<EngineReport> {
    plan_apply(env, scope, &PlanOptions::default())
}

/// What a refresh would do: regenerate everything declared, and re-derive
/// the closure in both directions — a dependency that appeared upstream is
/// an addition, one that went away leaves an installation nothing needs. The
/// caller previews the set changes before any of it is applied.
pub fn plan_refresh(env: &Env, scope: &Scope) -> Result<EngineReport> {
    plan_apply(
        env,
        scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
}

/// Plan what disk needs to match declaration, from the manifest as it sits
/// on disk. This is the loader the audit view AND the confirmed apply both
/// use: a mutation-normalized copy already looks current, so planning from
/// one would slip a file past the floor that the audit and every other
/// read refuse.
pub fn plan_apply(env: &Env, scope: &Scope, options: &PlanOptions) -> Result<EngineReport> {
    let scope = &scope.canonical();
    let manifest_file = manifest::load(&manifest::manifest_path(env, scope))?;
    // Absent reads as an empty lock — a fresh scope — so a first-ever
    // install still plans through the normal path.
    let lock = match crate::lock::load_file(&lock_path(env, scope))? {
        LockFile::Current(lock) => lock,
        LockFile::Absent => Lock {
            version: crate::lock::LOCK_VERSION,
            ..Lock::default()
        },
    };
    if let ManifestFile::Current(manifest) = &manifest_file {
        return plan_scope(env, scope, manifest, &lock, options);
    }

    // Nothing is declared here: the scope reads as observation-only rather
    // than failing the whole audit, so a stranger's files still get a row.
    let mut report = EngineReport {
        drift: Vec::new(),
        plan: Plan::landed(scope.clone(), Vec::new())?,
        notes: Vec::new(),
        warnings: Vec::new(),
        set_changes: Vec::new(),
        sweepable: Vec::new(),
        kept: Vec::new(),
        safety: Vec::new(),
        repo_effects: Vec::new(),
        repo_effects_leaving: Vec::new(),
    };
    let empty = Manifest::default();
    unmanaged_rows(env, scope, &empty, &lock, &[], &mut report.drift)?;
    Ok(report)
}
