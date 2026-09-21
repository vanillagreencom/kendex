//! Recovery proves installed bytes and writes only their install record.

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
    Registrations, owned, plan_scope, targets,
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
        crate::pi_ext::RecordBasis::MatchedBytes,
    )?;
    let mut report = plan_scope(env, scope, manifest, &seed, &PlanOptions::default())?;
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
        .filter(|(key, _)| proven.entries.contains_key(*key))
        .map(|(key, edits)| (key.clone(), edits.clone()))
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
    /// from. `take_over_settles` says whether the scope-wide take-over
    /// answers for the scope this copy sits in: it is withheld where the
    /// sweep would refuse, where a position it would take was left
    /// unmeasured, and where a row's take-over moves a second position
    /// the line never named — one answer for every row, since the sweep
    /// is one command over all of them.
    Differs {
        files: u32,
        rendered_from: String,
        take_over_settles: bool,
    },
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
    let report = plan_scope(env, scope, manifest, disk, &PlanOptions::default())?;
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
    proven.entries.retain(|key, entry| {
        !rewrites_manifest
            && !disk.entries.contains_key(key)
            && untouched(env, scope, entry, &touched)
    });
    let take_over_settles = take_over_settles(&report.drift);
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
                            take_over_settles,
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
    })
}

/// Whether the scope-wide take-over answers for the scope: it settles
/// every position it sweeps up or none of them, so it is named only
/// where the sweep would not refuse, every position it would take was
/// measured as differing content — a position it would take without a
/// count is one the reader never saw judged — and no row's take-over
/// moves a second position the line never named.
fn take_over_settles(drift: &[DriftRow]) -> bool {
    !super::takeover::sweep_would_refuse(drift)
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
    super::plan_lock_write(env, scope, manifest, disk, claimed, &mut ops)?;
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
) -> bool {
    let owned = owned::installed(env, scope, entry);
    owned
        .files
        .iter()
        .chain(owned.edits.iter().map(|(path, _)| path))
        .all(|position| {
            !touched
                .iter()
                .any(|path| path.starts_with(position) || position.starts_with(path))
        })
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
    let mut recovered = audit_without_record(env, scope, &manifest)?;
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
        let proven = registrations
            .get(key)
            .map(Vec::as_slice)
            .unwrap_or_default();
        for (path, _) in &owned.edits {
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
        for (path, _) in owned.edits {
            plan.reads.push(ReadCheck::File {
                pre: Pre::observed(&path)?,
                path,
            });
        }
    }
    Ok(())
}
