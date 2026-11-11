//! Recovery proves installed bytes against what records them: a record
//! rebuilt from matching renders, and a version 10 project record planned
//! over as a fresh scope.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::apply::{Op, Plan};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::Scope;

use super::{
    DeclarationStatus, DriftCause, DriftRow, DriftState, EngineReport, Occupied, PlanOptions,
    Registrations, owned, targets,
};

/// A read-only audit and the ownership entries proven by current source and
/// disk bytes when no readable lock is available.
pub struct RecordlessAudit {
    pub report: EngineReport,
    pub matching: Lock,
}

pub fn audit_without_record(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    judge_pins: bool,
) -> Result<RecordlessAudit> {
    let mut seed = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
    crate::pi_ext::record_matching_manifest(
        env,
        scope,
        manifest,
        &mut seed,
        None,
        crate::pi_ext::RecordBasis::MatchedBytes,
        None,
    )?;
    let options = PlanOptions {
        judge_pins,
        ..PlanOptions::current()
    };
    let mut report = super::plan_scope_with_lock_base(
        env,
        scope,
        manifest,
        &seed,
        &seed,
        &options,
        super::CommandAssessment::Report,
    )?;
    let matching = proven_entries(
        &report,
        planned_record(&report).unwrap_or_else(|| seed.clone()),
    );
    for planned in &mut report.plan.ops {
        if let Op::WriteLock { lock, .. } = &mut planned.op {
            **lock = matching.clone();
        }
    }
    Ok(RecordlessAudit { report, matching })
}

/// The settings edits the pass held in place for the entries it proved,
/// by entry key: what the record write holds in place again.
fn proven_registrations(report: &EngineReport, proven: &Lock) -> Registrations {
    report
        .registrations
        .iter()
        .filter(|(key, _)| proven.entries.contains_key(key))
        .cloned()
        .collect()
}

/// The record a plan would write, when it writes one.
fn planned_record(report: &EngineReport) -> Option<Lock> {
    report
        .plan
        .ops
        .iter()
        .find_map(|planned| match &planned.op {
            Op::WriteLock { lock, .. } => Some(lock.as_ref().clone()),
            _ => None,
        })
}

/// The planned record narrowed to the installations the pass found on
/// disk exactly as their source renders: every entry with a drift row is
/// out, whatever the row says, since a row is the pass saying the disk
/// and the render disagree. An `Unmanaged` row is about a stranger's
/// files at some other position, never about the entry's own.
fn proven_entries(report: &EngineReport, mut planned: Lock) -> Lock {
    planned.entries.retain(|_, entry| {
        !report.drift.iter().any(|row| {
            row.kind == entry.kind
                && row.name == entry.name
                && row.harness == entry.harness
                && row.state != DriftState::Unmanaged
        })
    });
    planned
}

/// What one plan measured for one declaration sitting on files no record
/// accounts for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "measured", rename_all = "kebab-case")]
pub enum Measured {
    /// The render byte for byte, and nothing else the pass would do
    /// touches it: the record gains the entry the apply would have
    /// written, carried in `UnmanagedCopies::proven`.
    Proven,
    /// Not the render: how many files on disk are not the render's, a
    /// file only one side has included, and what the render was built
    /// from. Whether the take-over is its fix is the scope's answer, not
    /// this copy's: [`UnmanagedCopies::completion`].
    Differs { files: u32, rendered_from: String },
    /// What sits at the position would not read, so nothing was judged:
    /// the plan's own reason, naming the position and the read's error.
    Uncompared { reason: String },
    /// The plan leaves the position as it is and says why itself: a link,
    /// a shape it will not read as content, a copy it matched but cannot
    /// record on its own because the same pass would rewrite the manifest
    /// or move the copy's own files, or a record that already holds the
    /// entry under other positions.
    Left,
}

/// What one plan learned about the declarations whose positions hold
/// files kendex never wrote — the state the session check cannot judge
/// from a stat, answered by the pass that holds both sides.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct UnmanagedCopies {
    /// One verdict per occupied installation, by lock entry key.
    pub measured: BTreeMap<String, Measured>,
    /// Every entry the pass proved on disk and can record on its own —
    /// the occupied installations it matched and, beside them, the
    /// installations a stat cannot see (a hook's script) that the same
    /// pass found as their render — with the resolutions behind them. A
    /// clone carrying renders and no record is settled whole or not at
    /// all, and a record naming the skills but not the hooks would leave
    /// the next apply reading the hook scripts as a stranger's.
    pub proven: Lock,
    /// The settings edits the pass held in place for each proven entry
    /// that registers one, by entry key. The record write holds them in
    /// place again: a registration taken out of its settings file since
    /// the plan is not recorded as installed.
    pub registrations: Registrations,
    /// The plan's one completion ([`completion`]): the take-over every
    /// differing copy names as its fix where it settles the whole scope.
    /// One answer for the scope, since the take-over is one command over
    /// every conflict in it.
    pub completion: Option<Completion>,
}

/// Plan the scope once and judge every occupied installation by what the
/// plan measured: a copy the render matches is proven, a copy it does not
/// is measured by the count, a position that would not read is
/// uncompared, and everything the plan leaves as it is says so. A record
/// that already exists keeps every entry it holds; only installations it
/// has no entry for are proven, and only where the pass would write
/// nothing else for them — no manifest, no file of theirs — so the
/// record says exactly what a full apply would have said about them
/// without doing the rest of the apply.
pub fn compare_unmanaged_copies(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    disk: &Lock,
    occupied: &BTreeMap<String, Occupied>,
) -> Result<UnmanagedCopies> {
    let scope = &scope.canonical();
    let report = super::plan_scope_with_lock_base(
        env,
        scope,
        manifest,
        disk,
        disk,
        &PlanOptions::current(),
        super::CommandAssessment::Omit,
    )?;
    let planned = planned_record(&report);
    // A pass that would rewrite the manifest — an agent's skill list
    // merged from upstream, a reserved name moved — records entries built
    // from a manifest nobody has written yet. That apply is the person's
    // to confirm, and the record waits for it.
    let rewrites_manifest = report
        .plan
        .ops
        .iter()
        .any(|planned| matches!(planned.op, Op::WriteManifest { .. }));
    let touched: BTreeSet<PathBuf> = report
        .plan
        .ops
        .iter()
        .filter(|planned| !matches!(planned.op, Op::WriteLock { .. }))
        .flat_map(|planned| planned.op.touched())
        .collect();
    let mut proven = planned
        .map(|planned| proven_entries(&report, planned))
        .unwrap_or_default();
    proven.version = crate::lock::LOCK_VERSION;
    let mut kept = BTreeMap::new();
    for (key, entry) in proven.entries {
        if !rewrites_manifest
            && !disk.entries.contains_key(&key)
            && untouched(env, scope, &entry, &touched)?
        {
            kept.insert(key, entry);
        }
    }
    proven.entries = kept;
    let mut measured = BTreeMap::new();
    for (key, install) in occupied {
        let refused = report.drift.iter().find(|row| {
            row.state == DriftState::Conflict
                && row.kind == install.kind
                && row.name == install.name
                && row.harness == install.harness
        });
        let verdict = match refused {
            Some(row) => match row.cause {
                Some(DriftCause::Uncompared) => Measured::Uncompared {
                    reason: row.detail.clone(),
                },
                Some(cause) if cause.can_replace() => {
                    match row
                        .compared
                        .as_ref()
                        .map(|compared| compared.differing_total)
                    {
                        Some(files) if files > 0 => Measured::Differs {
                            files,
                            rendered_from: rendered_from(manifest, &report, install),
                        },
                        // A shape the plan could not read as content has
                        // no count, and nothing prescribes an exit for
                        // what was not measured.
                        _ => Measured::Left,
                    }
                }
                Some(_) | None => Measured::Left,
            },
            None => match proven.entries.contains_key(key) {
                true => Measured::Proven,
                false => Measured::Left,
            },
        };
        measured.insert(key.clone(), verdict);
    }
    let registrations = proven_registrations(&report, &proven);
    Ok(UnmanagedCopies {
        measured,
        proven,
        registrations,
        completion: completion(&report),
    })
}

/// Plan a scope whose project record is version 10 as a fresh scope, with
/// the old record moved aside as the plan's first op.
///
/// No read converts the record (rule 15): the new one is built from the
/// declarations and their sources over no record, and the old one
/// contributes only the existing byte proof of which renders kendex wrote
/// (`unmanaged::version_10_proof`). Every other file stays what the plan
/// makes of a stranger's file, a conflict.
///
/// The move and the record write land in one transaction: the move is
/// bound to the hash of the bytes the caller read, and the record write to
/// the path standing empty once the move has run. A refusal at any op
/// rolls back to the version 10 record where it was. Where an earlier
/// recovery already left these bytes aside (`moved`), the move replaces
/// that aside bound to the same hash, so its bytes are unchanged.
///
/// What the old record carried is not news to the person: its packages
/// are no addition the consent claims, and this plan's own write offers
/// none of their repository effects again, since the scope carried them
/// before the record lost its readable form. A carried package this plan
/// leaves on a replaceable conflict is installed later by the take-over,
/// which offers its effect as every install into a checkout does
/// (`EngineReport::repo_effects_held`).
pub(super) fn plan_version_10(
    env: &Env,
    scope: &Scope,
    recoverable: super::Version10Recoverable<'_>,
    options: &PlanOptions,
) -> Result<EngineReport> {
    use crate::apply::{Description, PlannedOp, Pre};
    let super::Version10Recoverable {
        hash,
        moved,
        manifest,
    } = recoverable;
    let path = lock_path(env, scope);
    let aside = path.with_file_name(crate::lock::VERSION_10_LOCK_FILE);
    let carried = super::unmanaged::version_10_keys(&path)?;
    let fresh = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
    let mut report = super::plan_scope(env, scope, manifest, &fresh, options)?;
    for planned in &mut report.plan.ops {
        if let Op::WriteLock { pre, .. } = &mut planned.op {
            *pre = Pre::Absent;
        }
    }
    // The aside is the destination either way, so the record path stands
    // empty after the move even where the fresh plan writes no record. An
    // aside an earlier recovery left holds these bytes, and the move over
    // it is bound to them.
    let to_pre = match moved {
        true => Pre::HashIs { hash: hash.clone() },
        false => Pre::Absent,
    };
    report.plan.insert(
        0,
        PlannedOp {
            description: Description::around(
                "Move the version 10 install record ",
                format!(
                    " to {}, where it keeps proving which renders kendex wrote",
                    crate::lock::VERSION_10_LOCK_FILE
                ),
            ),
            op: Op::Rename {
                from: path,
                to: aside.clone(),
                from_pre: Pre::HashIs { hash },
                to_pre,
            },
        },
    )?;
    report.set_changes.retain(|change| {
        change.direction != super::SetDirection::Add
            || !carried.contains(&crate::lock::entry_key(
                change.kind,
                &change.name,
                change.harness,
            ))
    });
    let carried_skills: BTreeSet<String> = carried
        .iter()
        .filter_map(|key| crate::lock::parse_entry_key(key))
        .filter(|(kind, _, _)| *kind == crate::model::ItemKind::Skill)
        .map(|(_, name, _)| name.to_owned())
        .collect();
    report
        .repo_effects
        .retain(|effects| !carried_skills.contains(&effects.name));
    report.recovers = Some(aside);
    Ok(report)
}

/// The one action that finishes what a plan leaves, where one command
/// does: an apply that replaces the files in the way, or `update-pi` for
/// the Pi packages an apply's write never installs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum Completion {
    /// The take-over settles every conflict. It installs a package whose
    /// repository effect then needs its own yes, so the action carries
    /// that permission as a parameter.
    TakeOver { allow_repo_effects: bool },
    /// No conflict is left, and `update-pi` installs every declared Pi
    /// package the plan leaves.
    UpdatePi,
}

/// The completion for what a plan leaves, or `None` where no single
/// action finishes it. Never one beside a declared Pi package neither
/// action settles (`DriftRow::pi_unsettled`): the take-over installs no Pi
/// package, and `update-pi` leaves that one where it stands. With a
/// conflict, the take-over, where it can replace every one and answers
/// for the whole scope (`take_over_settles`); never one beside a conflict
/// an edit, a link or a revision clash holds. With none, `update-pi`,
/// where it installs every Pi package left (`update_pi_settles`). `apply`
/// and `refresh` name what this returns, and `check` reads it off the
/// plan that judged its unmanaged copies
/// ([`UnmanagedCopies::completion`]); none of them has a reading of its
/// own.
pub fn completion(report: &EngineReport) -> Option<Completion> {
    if report.drift.iter().any(|row| row.pi_unsettled.is_some()) {
        return None;
    }
    let mut conflicts = report
        .drift
        .iter()
        .filter(|row| row.state == DriftState::Conflict)
        .peekable();
    if conflicts.peek().is_none() {
        return update_pi_settles(&report.drift).then_some(Completion::UpdatePi);
    }
    let replaceable = conflicts.all(|row| row.cause.is_some_and(DriftCause::can_replace));
    (replaceable && take_over_settles(&report.drift)).then_some(Completion::TakeOver {
        allow_repo_effects: !report.repo_effects_held.is_empty(),
    })
}

/// Whether the scope-wide take-over answers for the scope: it settles
/// every position it sweeps up or none of them, so it is named only
/// where the sweep would not refuse, every position it would take was
/// measured as differing content — a position it would take without a
/// count is one the reader never saw judged — no row's take-over moves
/// a second position the line never named, and no Pi package is left for
/// `update-pi`, which the take-over does not install.
fn take_over_settles(drift: &[DriftRow]) -> bool {
    !super::takeover::sweep_would_refuse(drift)
        && drift
            .iter()
            .all(|row| row.remedy != Some(super::RowRemedy::UpdatePi))
        && drift.iter().all(|row| row.also_in_the_way.is_empty())
        && drift
            .iter()
            .filter(|row| row.cause.is_some_and(DriftCause::can_replace))
            .all(|row| {
                row.compared
                    .as_ref()
                    .is_some_and(|compared| compared.differing_total > 0)
            })
}

/// Whether `update-pi` finishes the declared Pi packages a plan with no
/// conflict leaves: at least one is left for it (`pi_ext::admit` admitted
/// it), and every other one is a row whose cause this plan's own write
/// settles. Any other row is one no verb named here settles.
fn update_pi_settles(drift: &[DriftRow]) -> bool {
    let mut left = false;
    for row in drift
        .iter()
        .filter(|row| row.kind == crate::model::ItemKind::PiExtension)
    {
        match row.state {
            // A record of a package no longer declared, or a stranger's
            // files beside the declared ones: not a declaration update-pi
            // installs.
            DriftState::Orphaned | DriftState::Unmanaged => {}
            DriftState::Missing | DriftState::Stale | DriftState::Conflict => {
                use super::RowRemedy;
                match (row.remedy, row.cause) {
                    (Some(RowRemedy::UpdatePi), _) => left = true,
                    (None, Some(cause)) if !cause.holds_the_write() => {}
                    // Settled by another verb, or by none.
                    (
                        None
                        | Some(
                            RowRemedy::Remove | RowRemedy::RemoveEdited | RowRemedy::PruneOrRemove,
                        ),
                        _,
                    ) => return false,
                }
            }
        }
    }
    left
}

/// The render's origin as the report names it: the source's provenance at
/// the commit the declaration's revision resolved to this pass — the pin
/// it names, else the source's own — as a seven-character commit cut on
/// a character boundary because a lock is a file anyone can edit; or the
/// declared source name where that resolved to no commit.
fn rendered_from(manifest: &Manifest, report: &EngineReport, install: &Occupied) -> String {
    let rev = manifest
        .declared(install.kind)
        .get(&install.name)
        .and_then(|decl| decl.rev.clone());
    match report.resolved_sources.get(&(install.source.clone(), rev)) {
        Some(revision) => format!(
            "{}@{}",
            revision.repo,
            revision.commit.chars().take(7).collect::<String>()
        ),
        None => format!("source '{}'", install.source),
    }
}

/// The record write for the proven copies, bound to each file's hash so a
/// copy that moves between the plan and the write refuses the record
/// rather than misfiling the change; `None` where nothing is proven. The
/// record keeps every entry it already holds and gains the proven ones,
/// which the pass proved against this same record (a record that moved
/// since retires the pass: `apply::execute` drops the memo with every
/// record write); a resolution it already holds stays, since the entries
/// recorded under it were not re-read by the pass that proved these.
pub fn claim_plan(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    disk: &Lock,
    copies: &UnmanagedCopies,
) -> Result<Option<Plan>> {
    let scope = &scope.canonical();
    let fresh = &copies.proven;
    if fresh.entries.is_empty() {
        return Ok(None);
    }
    let mut claimed = disk.clone();
    claimed.version = crate::lock::LOCK_VERSION;
    claimed.entries.extend(
        fresh
            .entries
            .iter()
            .map(|(key, entry)| (key.clone(), entry.clone())),
    );
    for (name, revision) in &fresh.sources {
        claimed
            .sources
            .entry(name.clone())
            .or_insert_with(|| revision.clone());
    }
    for (name, revision) in &fresh.bundles {
        claimed
            .bundles
            .entry(name.clone())
            .or_insert_with(|| revision.clone());
    }
    let mut ops = Vec::new();
    super::plan_lock_write(env, scope, manifest, disk, &claimed, &mut ops)?;
    let mut record = Plan::landed(scope.clone(), ops)?;
    bind_reads(env, scope, fresh, &copies.registrations, &mut record)?;
    Ok(Some(record))
}

/// Whether the pass would leave every position this entry records alone.
/// An entry with no drift row can still have an op against its files — a
/// toggle between its two spellings, a link the pass would create beside
/// a copy it matched — and a record of it as installed would then
/// describe the tree the apply was about to change.
fn untouched(
    env: &Env,
    scope: &Scope,
    entry: &crate::lock::LockEntry,
    touched: &BTreeSet<PathBuf>,
) -> Result<bool> {
    let owned = owned::installed(env, scope, entry);
    let edits = owned.edits?;
    Ok(owned
        .files
        .iter()
        .chain(edits.iter().map(|(path, _)| path))
        .all(|position| {
            !touched
                .iter()
                .any(|path| path.starts_with(position) || position.starts_with(path))
        }))
}

/// Record matching committed renders after the unreadable lock has been moved
/// aside. Any drift leaves every file unchanged.
pub fn plan_record_existing(env: &Env, scope: &Scope) -> Result<EngineReport> {
    let scope = &scope.canonical();
    let path = lock_path(env, scope);
    let manifest =
        manifest::load_current(&manifest::manifest_path(env, scope))?.ok_or_else(|| {
            crate::error::CoreError::RecordExistingRefused {
                path: path.clone(),
                reason: "this scope has no manifest to rebuild from".to_owned(),
            }
        })?;
    match crate::lock::load_file(&path)? {
        LockFile::Absent => {}
        LockFile::Current(_) => {
            return Err(crate::error::CoreError::RecordExistingRefused {
                path,
                reason: "a readable install record already exists".to_owned(),
            });
        }
    }
    let mut recovered = audit_without_record(env, scope, &manifest, false)?;
    // CI metadata can be regenerated after the durable record is restored.
    if let Scope::Project { root } = scope {
        let inventory = root.join(".kendex-generated.json");
        recovered.report.plan.ops.retain(|planned| {
            !matches!(&planned.op,
            crate::apply::Op::WriteFile { path, .. } if path == &inventory)
        });
    }
    // Nor is the housekeeping kendex owes the repository evidence about
    // the installs, but it stays in the plan: the managed ignore block a
    // project carries from an earlier build names the record itself, and
    // a recovery that wrote the record without refreshing the block left
    // it ignored — recorded and invisible to every clone — with the note
    // that would have said so silenced, since the posture pass reports
    // the rules that stand after its own write. So the block is written
    // in the same run as the record, and only the judgement below leaves
    // it out. Asked of the one function that plans the block, so there
    // is no second list of what counts as housekeeping.
    let housekeeping = super::posture::planned(scope)?;
    let blocked = recovered
        .report
        .drift
        .iter()
        .any(|row| row.state != DriftState::Unmanaged);
    let mut evidence = recovered
        .report
        .plan
        .ops
        .iter()
        .filter(|planned| !housekeeping.contains(planned))
        .peekable();
    let only_lock = evidence.peek().is_some()
        && evidence.all(|planned| matches!(planned.op, crate::apply::Op::WriteLock { .. }));
    if blocked || !only_lock || recovered.report.declaration_status == DeclarationStatus::Incomplete
    {
        return Err(crate::error::CoreError::RecordExistingRefused {
            path,
            reason: "the declared installs do not exactly match current source and disk bytes; no file was changed".to_owned(),
        });
    }
    let registrations = proven_registrations(&recovered.report, &recovered.matching);
    bind_reads(
        env,
        scope,
        &recovered.matching,
        &registrations,
        &mut recovered.report.plan,
    )?;
    Ok(recovered.report)
}

/// Bind the record write to what it records: the manifest, each entry's
/// files by hash under whichever of its two spellings holds them, and each
/// entry's registration as the settings edits the plan held in place, in
/// the settings file the harness reads now. An entry the record claims
/// installed must have bytes at one of them and its edits still in sync;
/// what the plan proved and is gone since — the memo carries a proven set
/// across sessions, a hook's script is proven without ever being keyed,
/// and no settings file is keyed at all — refuses the record as stale,
/// since a record naming a file would hand the next write to that
/// position the stranger's bytes as kendex's own, and one naming a
/// registration the person took out would put it back at the next apply.
/// A settings file the harness reads now that the plan never held (its
/// target moved: OpenCode reads `opencode.jsonc` as soon as one appears)
/// refuses the same way when it exists, since the proven file is then one
/// the harness no longer reads; absent, it is the state the plan proved
/// by listing no edit for it, as Gemini's enablement record is for a
/// server that is on. `registrations` is the plan's own list for the
/// entries it proved (`proven_registrations`), so an entry with none
/// registers nothing.
fn bind_reads(
    env: &Env,
    scope: &Scope,
    matching: &Lock,
    registrations: &Registrations,
    plan: &mut Plan,
) -> Result<()> {
    use crate::apply::{Pre, ReadCheck};
    let manifest_path = manifest::manifest_path(env, scope);
    plan.reads.push(ReadCheck::File {
        pre: Pre::observed(&manifest_path)?,
        path: manifest_path,
    });
    for (key, entry) in &matching.entries {
        let owned = owned::installed(env, scope, entry);
        let edits = owned.edits?;
        let proven = registrations
            .iter()
            .find(|(held, _)| held == key)
            .map(|(_, edits)| edits.as_slice())
            .unwrap_or_default();
        for (path, _) in &edits {
            if path.exists() && !proven.iter().any(|(held, _)| held == path) {
                return Err(crate::error::CoreError::PlanStale { path: path.clone() });
            }
        }
        for (path, edit) in proven {
            let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
            let in_sync =
                edit.in_sync(&current)
                    .map_err(|message| crate::error::CoreError::ConfigEdit {
                        path: path.clone(),
                        message,
                    })?;
            if !in_sync {
                return Err(crate::error::CoreError::PlanStale { path: path.clone() });
            }
        }
        if entry.kind == crate::model::ItemKind::PiExtension {
            for path in owned.files {
                let rendered = entry.rendered_hash.as_deref().ok_or_else(|| {
                    crate::error::CoreError::RecordExistingRefused {
                        path: path.clone(),
                        reason: "the Pi package has no measured render hash".to_owned(),
                    }
                })?;
                let observed = crate::pi_ext::owned_package_identity(&path)?.ok_or_else(|| {
                    crate::error::CoreError::RecordExistingRefused {
                        path: path.clone(),
                        reason: "the Pi package is missing".to_owned(),
                    }
                })?;
                if !observed.matches(rendered) {
                    return Err(crate::error::CoreError::PlanStale { path });
                }
                let hash = observed.exact().to_owned();
                plan.reads.push(ReadCheck::PiPackage { path, hash });
            }
            continue;
        }
        for path in owned.files {
            let disabled = targets::disabled_name(&path);
            let present = |candidate: &PathBuf| candidate.exists() || candidate.is_symlink();
            // The one move the binding exists to refuse: a proven file
            // gone since the plan. `Pre::Absent` below is the other
            // spelling the entry may sit under, never both at once.
            if !present(&disabled) && !present(&path) {
                return Err(crate::error::CoreError::PlanStale { path });
            }
            for candidate in [disabled, path] {
                let pre = if present(&candidate) {
                    let hash = crate::hash::hash_tree(&candidate)?;
                    if entry.rendered_hash.as_ref().is_some_and(|expected| {
                        crate::hash::RenderedIdentity::from_path(&candidate, true)
                            .map(|identity| !identity.matches(expected))
                            .unwrap_or(true)
                    }) {
                        return Err(crate::error::CoreError::PlanStale { path: candidate });
                    }
                    if candidate.is_symlink() {
                        let target = std::fs::read_link(&candidate)
                            .map_err(|error| crate::error::CoreError::io(&candidate, error))?;
                        plan.reads.push(ReadCheck::File {
                            path: candidate.clone(),
                            pre: Pre::SymlinkTo { target },
                        });
                    }
                    Pre::HashIs { hash }
                } else {
                    Pre::Absent
                };
                plan.reads.push(ReadCheck::File {
                    path: candidate,
                    pre,
                });
            }
        }
        for (path, _) in edits {
            plan.reads.push(ReadCheck::File {
                pre: Pre::observed(&path)?,
                path,
            });
        }
    }
    Ok(())
}
