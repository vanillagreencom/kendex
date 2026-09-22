use crate::apply::{Plan, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;
use crate::source::SourceState;
use std::collections::{BTreeMap, BTreeSet};

pub mod adopt;
mod agent_carry;
mod agent_skills;
mod antigravity;
pub(crate) mod bundles;
mod catalog;
mod config_edits;
mod copilot;
pub mod deps;
pub mod desired;
pub(crate) mod desired_agent;
mod desired_command;
mod desired_custom_hooks;
mod desired_item;
pub(crate) mod desired_kinds;
mod desired_mcp;
mod desired_skill;
mod desired_source;
pub mod detach;
pub mod exits;
mod expansion;
mod file_plan;
pub mod fork;
mod gemini;
pub mod generated_paths;
pub use generated_paths::GeneratedPaths;
mod holds;
mod installed;
mod recovery;
pub(crate) use recovery::planned_record;
pub use recovery::{
    Measured, RecordlessAudit, UnmanagedCopies, audit_without_record, claim_plan,
    compare_unmanaged_copies, plan_record_existing,
};
mod instruction_shims;
pub use instruction_shims::{
    CLAUDE_SHIM, ShimStanding, ShimState, observe as observe_instruction_shims,
};
mod item_plan;
mod item_record;
mod item_source;
mod observed;
mod opencode;
pub mod ops;
mod origin;
pub(crate) mod owned;
mod plan_pass;
mod planned;
pub mod posture;
mod removal;
mod scope_skills;
pub use scope_skills::ScopeSkills;
mod scope_writes;
mod secrets_write;
mod settings_scan;
mod settings_write;
pub use settings_scan::settings_templates;
mod scoring;
mod set_change;
mod stale;
pub mod takeover;
pub(crate) mod targets;
pub(crate) use targets::disabled_name;
mod tree_plan;
mod unmanaged;
pub use unmanaged::unmanaged_here;
mod written;

pub use desired::{CatalogSource, Owns, Position};
pub(crate) use desired_agent::contributes_to_agent;
pub use expansion::{NO_PER_PACKAGE_UPDATE, plans_per_package};
pub use item_source::ItemSource;
pub use observed::observed_rows;
pub use planned::{PlannedDeclaration, planned_closure, planned_declarations};
pub use scoring::{ItemSafety, SafetyTarget};

/// The conservative "cannot prove these bytes are our render" hold.
pub use removal::edit_holds;
pub(crate) use targets::{hook_target, mcp_registry};

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
    bundle_revisions, plan_config_edits, plan_lock_write, plan_manifest_write, resolved_revisions,
    source_revisions,
};
pub use set_change::{KeptInstall, SetChange, SetDirection};
use set_change::{kept_members, set_changes};
use settings_write::plan_project_files;
pub use unmanaged::Occupied;
pub use unmanaged::declared_over_existing_files;
use unmanaged::unmanaged_rows;

mod compared;
pub use compared::Comparison;
pub(crate) use compared::digest as position_digest;
mod repo_effects;
pub use repo_effects::{InstalledDeclaration, installed_declaration, installed_declarations};
mod report_types;
pub use report_types::{
    DeclarationStatus, DriftCause, DriftRow, DriftState, EngineReport, ForkEdit, Installation,
    ItemWarning, PlanOptions, Registrations,
};

/// Compute drift and the plan that would fix it — the Audit page and
/// `apply` both consume this.
pub fn plan_scope(
    env: &Env,
    scope: &Scope,
    declared: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
) -> Result<EngineReport> {
    // Identity first: derived paths and the scope lock key off canonical.
    let scope = &scope.canonical();
    // `declared` is what the person declared, as this build reads it: the
    // manifest any write this plan carries is built from. A single-package
    // update reads from a copy with every other follower pinned at its
    // installed commit — the pins steer this pass and never reach the file.
    let (manifest, state) = desired_pass(env, scope, declared, lock, options)?;
    // Advisory scoring over what this plan would write, before the ops are
    // planned: the rows ride out on the report beside the plan.
    let safety = scoring::run(scope, &state);
    let (mut drift, mut ops) = (Vec::new(), Vec::<PlannedOp>::new());
    let mut new_lock = fresh_lock(&manifest, lock, &state);
    drift.extend(crate::pi_ext::record_matching_manifest(
        env,
        scope,
        &manifest,
        &mut new_lock,
        crate::pi_ext::RecordBasis::Recorded,
    )?);
    let mut written = written::Written::default();
    let mut config_edits = config_edits::ConfigEditPlan::default();

    plan_manifest_write(env, scope, options.manifest_base.as_ref(), &state, &mut ops)?;

    let (fork_edits, recorded_gone) = plan_pass::plan_items(
        env,
        &state,
        scope,
        lock,
        &manifest,
        options,
        &owned::paths(env, scope, lock),
        &mut drift,
        &mut ops,
        &mut config_edits,
        &mut new_lock,
        &mut written,
    )?;

    // Notes about the scope rather than about any one item: what the
    // settings seed found, what the reserved-name move did, what the git
    // posture changed.
    // The order between them is not this caller's to choose, so one entry
    // point plans all three: `settings_write.rs` says why.
    let (mut scope_notes, settings_drift) = plan_project_files(scope, &state, options, &mut ops)?;
    drift.extend(settings_drift);
    // The shims a project owes its instruction files, read off the
    // harness list the manifest declares: committed files, never lock
    // entries, so they are planned beside the settings file rather than
    // through the item model.
    let (instruction_shims, shim_drift) = instruction_shims::plan_instruction_shims(
        env,
        scope,
        &manifest.install.harnesses,
        options,
        &mut ops,
        &mut config_edits,
    )?;
    drift.extend(shim_drift);

    // Trash ops all pass one guard: writes for this pass are already
    // planned, so anything still wanted is known, and no path goes to the
    // trash twice.
    let mut guard = removal::TrashGuard::new(&state.items, owned::paths(env, scope, &new_lock));

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
        &mut scope_notes,
    )?;

    stale::stale_instruction_rows(env, scope, lock, &new_lock, &state.items, &mut config_edits)?;
    plan_config_edits(config_edits, &mut ops)?;
    let set_changes = set_changes(lock, &new_lock);
    let kept = kept_members(lock, &new_lock, &options.uninstalled_bundles);
    let repo_effects_leaving = repo_effects::leaving(env, scope, lock, &new_lock)?;
    // Read off before the record moves into its write: a pass that
    // writes no record still says which commit each revision resolved to.
    let resolved_sources = resolved_revisions(&new_lock, &state);
    let (installations, sources_from_record) = derived(env, scope, &manifest, &state)?;
    plan_lock_write(env, scope, declared, lock, new_lock, &mut ops)?;
    let generated = generated_paths::plan(scope, &state, &instruction_shims, &drift, &mut ops)?;

    let mut report = EngineReport {
        declaration_status: DeclarationStatus::of(&state),
        // Ahead of the moves out of `state` below, and read before `drift`
        // moves in: an effect belongs to a package this pass adds to what
        // the scope carries, and to no other.
        repo_effects: repo_effects::run(&state, &drift, &set_changes, lock),
        registrations: registrations(&state),
        repo_effects_leaving,
        drift,
        plan: Plan::landed(scope.clone(), ops)?,
        notes: state.notes,
        warnings: state.warnings,
        set_changes,
        sweepable,
        kept,
        safety,
        instruction_shims,
        fork_edits,
        resolved_sources,
        recorded_gone,
        generated,
        installations,
        sources_from_record,
    };
    report.notes.extend(scope_notes);
    settled(env, scope, &manifest, lock, options, &state.items, report)
}

/// The report with the rows about content nothing manages added, refused
/// where the options ask for a take-over or a sweep the rows cannot
/// settle whole.
fn settled(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    options: &PlanOptions,
    items: &[desired::Desired],
    mut report: EngineReport,
) -> Result<EngineReport> {
    unmanaged_rows(env, scope, manifest, lock, items, &mut report.drift)?;
    takeover::refuse_unsettled_takeover(options, &report.drift)?;
    takeover::refuse_unsettleable_sweep(options, &report.drift)?;
    Ok(report)
}

/// The settings edits each registration this pass plans is, by entry key,
/// read off the artifacts the pass planned from. What `plan_registration`
/// holds in place for an entry the record does not hold is exactly this
/// list; the retirement of a moved entry it puts in front is planned only
/// against an entry the record holds, which is never one a record write
/// proves.
fn registrations(state: &desired::DesiredState) -> Registrations {
    state
        .items
        .iter()
        .filter_map(|item| match &item.artifact {
            desired::Artifact::Registration { edits, .. } => {
                Some((item.key.clone(), edits.clone()))
            }
            desired::Artifact::File { .. } | desired::Artifact::Tree { .. } => None,
        })
        .collect()
}

/// What the report says about this pass's own derivation: every
/// installation with its positions, and the sources reached through the
/// record's last-resolved commit rather than through the declared revision.
fn derived(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &desired::DesiredState,
) -> Result<(BTreeMap<String, Installation>, BTreeSet<String>)> {
    let from_record = state
        .sources
        .iter()
        .filter(
            |(_, resolution)| matches!(resolution, SourceState::Ready(ready) if ready.from_record),
        )
        .map(|(name, _)| name.clone())
        .collect();
    Ok((installations(env, scope, manifest, state)?, from_record))
}

/// Every installation this pass derived, with its positions, by entry
/// key: the items the plan built, read off their artifacts, and each Pi
/// extension the manifest declares, at the package directory the carrier
/// installs it under. The carrier plans no item, so its position is asked
/// of the one function that places a package rather than derived here.
///
/// A name the placer refuses — the manifest accepts any usable path
/// segment, `package_path` also wants npm's shape — is a declaration with
/// no installation: it reaches the reader as a gap, the way a declaration
/// the record does not hold does, and the rest of the scope keeps its
/// rows. The refusal is the carrier's to say when it is asked to install
/// that name; this derivation does not say it a second time.
fn installations(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &desired::DesiredState,
) -> Result<BTreeMap<String, Installation>> {
    let mut installations: BTreeMap<String, Installation> = state
        .items
        .iter()
        .map(|item| {
            (
                item.key.clone(),
                Installation {
                    kind: item.kind,
                    name: item.name.clone(),
                    harness: item.harness,
                    positions: item.artifact.positions(),
                },
            )
        })
        .collect();
    if manifest.pi_extensions.is_empty() {
        return Ok(installations);
    }
    let root = crate::pi_ext::scope_root(env, scope)?;
    for name in manifest.pi_extensions.keys() {
        let Ok(path) = crate::pi_ext::package_path(&root, name) else {
            continue;
        };
        let kind = crate::model::ItemKind::PiExtension;
        let harness = crate::model::HarnessId::Pi;
        installations.insert(
            crate::lock::entry_key(kind, name, harness),
            Installation {
                kind,
                name: name.clone(),
                harness,
                positions: vec![desired::Position {
                    path,
                    owns: desired::Owns::Tree,
                }],
            },
        );
    }
    Ok(installations)
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
/// per-source and per-set resolutions it just made. Nothing about seeding
/// is recorded here — a template applies once, on the arrival, and what
/// says an arrival happened is the manifest gaining the declaration.
fn fresh_lock(manifest: &Manifest, lock: &Lock, state: &desired::DesiredState) -> Lock {
    Lock {
        version: crate::lock::LOCK_VERSION,
        entries: lock
            .entries
            .iter()
            .filter(|(_, entry)| {
                entry.kind == crate::model::ItemKind::PiExtension
                    && manifest.pi_extensions.contains_key(&entry.name)
            })
            .map(|(key, entry)| (key.clone(), entry.clone()))
            .collect(),
        sources: source_revisions(manifest, lock, state),
        bundles: bundle_revisions(manifest, lock, state),
    }
}

/// Read-only audit for a scope. A scope with no manifest still reports
/// unmanaged items; one whose manifest or lock this build cannot read is
/// refused at the door, so this answers for it with the refusal rather
/// than with an empty report.
pub fn audit(env: &Env, scope: &Scope) -> Result<EngineReport> {
    plan_apply(env, scope, &PlanOptions::default())
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
    let mut report = EngineReport::observed(Plan::landed(scope.clone(), Vec::new())?);
    let empty = Manifest::default();
    unmanaged_rows(env, scope, &empty, &lock, &[], &mut report.drift)?;
    Ok(report)
}
