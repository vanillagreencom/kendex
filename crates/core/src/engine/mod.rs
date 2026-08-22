use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::apply::{Plan, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;

pub mod adopt;
mod adopt_shared;
pub(crate) mod bundles;
mod catalog;
mod config_edits;
mod copilot;
pub mod decisions;
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
mod expansion;
pub use expansion::plans_kind;
mod edited;
pub mod fork;
mod gate;
mod gemini;
mod holds;
mod item_plan;
pub use edited::{EditedHere, edited_here};
mod item_record;
mod manifest_write;
pub use manifest_write::persists_manifest;
mod item_source;
mod observed;
pub mod ops;
mod owned;
pub(crate) mod pi_hooks_move;
mod plan_pass;
mod plan_writes;
mod planned;
mod removal;
mod review_hash;
pub mod reviewable;
mod scope_writes;
mod set_change;
mod targets;
mod tree_plan;
mod unmanaged;

pub(crate) use desired::harnesses_for;
pub(crate) use desired_agent::contributes_to_agent;
pub(crate) use gate::content_hash;
pub use gate::{ItemSafety, allow_unsafe_flag, refuse_unmatched_grants};
pub use item_source::{ItemSource, item_source};
pub use observed::{observed_rows, observed_safety};
pub use planned::{PlannedDeclaration, planned_declarations};

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
use scope_writes::{plan_config_edits, plan_lock_write, plan_settings_seed, source_revisions};
pub use set_change::{KeptInstall, SetChange, SetDirection};
use set_change::{kept_members, set_changes};
use unmanaged::unmanaged_rows;

mod report_types;
pub use report_types::{
    DriftCause, DriftRow, DriftState, DriftSubject, EngineReport, ItemWarning, PlanOptions,
};

/// Compute drift and the plan that would fix it, in one pass — the Audit
/// page and `apply` both consume this.
pub fn plan_scope(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<EngineReport> {
    // Identity first: derived paths and the scope lock key off canonical.
    let scope = &scope.canonical();
    // The default catalog moved repositories: everything plans against the
    // moved strings, so the move never reads as a per-package source rebind
    // (a conflict per installed item). Only the lock write still compares
    // against the on-disk record — that difference is what makes the plan
    // carry the rewritten lock even when nothing else changed.
    let moved_manifest = crate::repo_move::migrate_manifest(manifest);
    let moved_lock = crate::repo_move::migrate_lock(lock);
    let repo_moved = moved_manifest.is_some();
    let disk_lock = lock;
    let manifest = moved_manifest.as_ref().unwrap_or(manifest);
    let lock = moved_lock.as_ref().unwrap_or(lock);
    let mut state = desired_state(env, scope, manifest, lock, options)?;
    // The gate runs before anything is planned for these items: a blocked
    // rendering must never reach the op list, and an override it grants has
    // to ride out on the manifest write this same plan performs.
    let safety = gate::pass(env, scope, manifest, options, &mut state)?;
    let state = state;
    let mut drift = Vec::new();
    let mut ops: Vec<PlannedOp> = Vec::new();
    let mut new_lock = fresh_lock(manifest, lock, &state);
    let mut written = tree_plan::Written::default();
    let mut config_edits = config_edits::ConfigEditPlan::default();

    // Every pass below that writes or removes, and what each does with a
    // restricted plan. They ask `DesiredState::acts_on`, never `only_names`
    // directly: "one package" means that package and everything it needs,
    // resolved once against the expansion, so no two passes can disagree
    // about it. Asked, in order:
    // `plan_items` (writes for the named items, others carried forward),
    // `plan_settings_seed` (seeds only what the named packages ship),
    // `stale_emitted` (sweeps only their old paths), `plan_refusals` (takes
    // only their refused renderings off disk).
    //
    // `plan_manifest_write` is asked once removed. Its scope maintenance —
    // a schema upgrade, a repository move — belongs to no package and
    // always runs. What it writes *for* packages does not: an agent's
    // upstream skill additions are merged in `desired_state`, which leaves
    // out everything a restricted plan will not render, so the file never
    // records an install that did not happen. That and the closure above
    // are the same rule from both ends — a restricted plan installs
    // everything the named package needs, and records exactly what it
    // installed.
    //
    // `orphans` is not asked, deliberately: it removes only under
    // `remove_orphans` or `sweep_unneeded` — a verb asking for exactly
    // that, and never a restricted plan, which passes neither.
    // `plan_lock_write` records what the passes above decided.
    manifest_write::plan_manifest_write(
        env, scope, repo_moved, manifest, &state, options, &mut ops,
    )?;

    // Answered before anything is planned, and read again when the move
    // is planned: a pi hook whose copy under the name pi reserved is not
    // this pass's to take holds whole, so the fresh rendering never
    // quietly takes over from bytes the person kept.
    let legacy_pi = pi_hooks_move::preflight(env, scope, lock, options, &state);
    let rendered = plan_writes::plan_item_writes(
        env,
        scope,
        lock,
        &state,
        options,
        &legacy_pi,
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
        &mut written,
    )?;

    plan_settings_seed(scope, &state, &mut new_lock, &mut ops, &mut drift)?;

    // Trash ops all pass one guard: writes for this pass are already
    // planned, so anything still wanted is known, and no path goes to the
    // trash twice.
    let mut guard = removal::TrashGuard::new(&state.items);

    let mut moved_notes = Vec::new();
    let moved_out = plan_writes::plan_reserved_name_move(
        env,
        scope,
        manifest,
        lock,
        &state,
        &legacy_pi,
        &mut ops,
        &mut guard,
        &mut config_edits,
        &mut moved_notes,
    )?;
    removal::stale_emitted(&state, lock, &mut guard, &mut ops)?;

    let refused_keys = plan_pass::plan_refusals(
        env,
        scope,
        lock,
        &state,
        &legacy_pi,
        &mut guard,
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
    )?;

    let sweepable = removal::orphans(
        env,
        scope,
        manifest,
        lock,
        &state,
        options,
        &legacy_pi,
        &refused_keys,
        &mut guard,
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
    )?;

    // Written here and nowhere else: every entry this pass keeps is in
    // the record by now, the sweep's carry-forwards included.
    pi_hooks_move::record_finished(&mut new_lock, &moved_out);
    plan_config_edits(env, scope, config_edits, &mut ops)?;
    let set_changes = set_changes(scope, lock, &new_lock);
    let kept = kept_members(scope, lock, &new_lock, &options.uninstalled_bundles);
    plan_lock_write(env, scope, disk_lock, new_lock, &mut ops)?;

    prepend_rename_generation(env, scope, &mut ops)?;

    let mut report = EngineReport {
        drift,
        plan: Plan {
            scope: scope.clone(),
            ops,
        },
        notes: state.notes,
        warnings: state.warnings,
        set_changes,
        sweepable,
        kept,
        safety,
        unmeasured: state.unmeasured,
        rendered,
        acting: state.acting.clone().unwrap_or_default(),
    };
    report.notes.extend(moved_notes);
    unmanaged_rows(env, scope, manifest, lock, &state.items, &mut report.drift);
    Ok(report)
}

/// The record this pass will write, before any of it is filled in: the
/// per-source resolutions it just made, and the seeding evidence carried
/// forward — only seeding and refresh may move that.
fn fresh_lock(manifest: &Manifest, lock: &Lock, state: &desired::DesiredState) -> Lock {
    Lock {
        version: crate::lock::LOCK_VERSION,
        entries: BTreeMap::new(),
        sources: source_revisions(manifest, lock, state),
        settings_seeds: lock.settings_seeds.clone(),
    }
}

/// What earlier installs put on disk under another kind's name. A path
/// one of them wrote is ours to replace, whichever entry holds it now.
fn emitted_paths(lock: &Lock) -> BTreeSet<PathBuf> {
    lock.entries
        .values()
        .filter_map(|entry| entry.emitted.as_ref())
        .flat_map(|emitted| emitted.paths.iter().cloned())
        .collect()
}

/// A scope still under the old product name renames first: everything
/// planned so far read from — and bound its preconditions to — the
/// old-name files, and a rename preserves bytes, so retargeting the paths
/// is all the rest of the plan needs to run after the move.
fn prepend_rename_generation(env: &Env, scope: &Scope, ops: &mut Vec<PlannedOp>) -> Result<()> {
    let renames = crate::rename::rename_ops(env, scope)?;
    if !renames.is_empty() {
        crate::rename::retarget(env, scope, ops);
        ops.splice(0..0, renames);
    }
    Ok(())
}

/// Read-only audit for a scope. A legacy or absent manifest still reports
/// unmanaged items; nothing is planned that would touch a legacy file.
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
/// use — planning an apply from a mutation-normalized manifest would drop
/// the schema-upgrade op the preview promised, leaving a v0.1 manifest
/// beside a current lock forever.
pub fn plan_apply(env: &Env, scope: &Scope, options: &PlanOptions) -> Result<EngineReport> {
    let scope = &scope.canonical();
    let manifest_file = manifest::load(&manifest::manifest_path(env, scope))?;
    let lock_file = crate::lock::load_file(&lock_path(env, scope))?;
    // Absent reads as an empty current lock — a fresh scope, not a legacy
    // one — so a first-ever install still plans through the normal path.
    let fresh_lock = match &lock_file {
        LockFile::Current(lock) => Some(lock.clone()),
        LockFile::Absent => Some(Lock {
            version: crate::lock::LOCK_VERSION,
            ..Lock::default()
        }),
        LockFile::Legacy { .. } => None,
    };
    if let (ManifestFile::Current(manifest), Some(lock)) = (&manifest_file, &fresh_lock) {
        return plan_scope(env, scope, manifest, lock, options);
    }

    // Either file can't be planned against as-is (a v1 lock, or a v1
    // manifest paired with an already-migrated lock and vice versa) — the
    // scope reads as observation-only rather than failing the whole audit,
    // matching the manifest's existing legacy posture: nothing is planned
    // that would touch a file this build won't write to.
    let mut report = EngineReport {
        drift: Vec::new(),
        plan: Plan {
            scope: scope.clone(),
            ops: Vec::new(),
        },
        notes: Vec::new(),
        warnings: Vec::new(),
        set_changes: Vec::new(),
        sweepable: Vec::new(),
        kept: Vec::new(),
        safety: Vec::new(),
        // Nothing is planned on this path, so nothing is rendered and the
        // plan is about nothing.
        rendered: BTreeSet::new(),
        acting: BTreeSet::new(),
        unmeasured: BTreeSet::new(),
    };
    // One fact, said once: files this build will read but not write. Which
    // of the two is legacy is kendex's problem, not the reader's.
    if matches!(manifest_file, ManifestFile::Legacy { .. })
        || matches!(lock_file, LockFile::Legacy { .. })
    {
        report.notes.push(
            "This scope's vstack files are from version 1 — kendex reads them, but changes nothing here until they are migrated"
                .into(),
        );
    }
    let empty = Manifest::default();
    let lock = fresh_lock.unwrap_or_else(|| Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    });
    unmanaged_rows(env, scope, &empty, &lock, &[], &mut report.drift);
    Ok(report)
}
