//! Recovery proves installed bytes and writes only their install record.

use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::apply::{Op, Plan};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

use super::{DeclarationStatus, DriftState, EngineReport, PlanOptions, owned, plan_scope, targets};

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

/// One declaration whose position holds files kendex never wrote, and
/// how those files compare with the render its source produces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DifferingCopy {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    /// How many files on disk are not the render's, a file only one side
    /// has included.
    pub files: u32,
    /// What the render was built from, for the line that names it: the
    /// source's provenance at the commit this pass resolved, or at the
    /// revision the declaration pins; a source with no commit to name is
    /// named by its declared name.
    pub rendered_from: String,
}

/// The record write for the copies that are the render byte for byte.
#[derive(Debug)]
pub struct Claim {
    /// The installations the record gains, whose files stay as they are.
    pub installations: Vec<(ItemKind, String, HarnessId)>,
    /// The write, bound to each file's hash so a copy that moves between
    /// the plan and the write refuses the record rather than misfiling
    /// the change.
    pub record: Plan,
}

/// What one plan learned about the declarations whose positions hold
/// files kendex never wrote — the state the session check cannot judge
/// from a stat, answered by the pass that holds both sides.
#[derive(Debug)]
pub struct UnmanagedCopies {
    /// The record write for the copies the render matches, or `None`
    /// when nothing on disk proved itself.
    pub claim: Option<Claim>,
    /// The copies that are not the render: the take-over is their fix.
    pub differing: Vec<DifferingCopy>,
}

/// Plan the scope once and sort the copies kendex never wrote by what the
/// plan measured: a copy the render matches is claimed into the record,
/// a copy it does not is reported with the count. A record that already
/// exists keeps every entry it holds; only installations it has no entry
/// for are added, and only where the pass would write nothing for them —
/// no manifest, no file of theirs — so the record says exactly what a
/// full apply would have said about them without doing the rest of the
/// apply.
pub fn compare_unmanaged_copies(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    disk: &Lock,
) -> Result<UnmanagedCopies> {
    let scope = &scope.canonical();
    let report = plan_scope(env, scope, manifest, disk, &PlanOptions::default())?;
    let planned = planned_record(&report);
    let differing = report
        .drift
        .iter()
        .filter_map(|row| {
            // A link is never taken over and a shape the plan could not
            // read as content has no count: neither gets the take-over
            // as its fix.
            let cause = row.cause.filter(|cause| cause.can_replace())?;
            debug_assert!(
                cause.in_the_way(),
                "a replaceable cause is files in the way"
            );
            let files = row.compared.as_ref()?.differing_total;
            (files > 0).then(|| DifferingCopy {
                kind: row.kind,
                name: row.name.clone(),
                harness: row.harness,
                files,
                rendered_from: rendered_from(manifest, &report, row.kind, &row.name),
            })
        })
        .collect();
    let claim = match planned {
        Some(planned) => claim(env, scope, manifest, disk, &report, planned)?,
        None => None,
    };
    Ok(UnmanagedCopies { claim, differing })
}

/// The render's origin as the report names it. A seven-character commit,
/// cut on a character boundary because a lock is a file anyone can edit.
fn rendered_from(manifest: &Manifest, report: &EngineReport, kind: ItemKind, name: &str) -> String {
    let Some(decl) = manifest.declared(kind).get(name) else {
        return "its source".to_owned();
    };
    let revision = report.resolved_sources.get(&decl.source);
    let base = revision
        .map(|revision| revision.repo.clone())
        .unwrap_or_else(|| format!("source '{}'", decl.source));
    let at = decl
        .rev
        .clone()
        .or_else(|| revision.map(|revision| revision.commit.chars().take(7).collect()));
    match at {
        Some(at) => format!("{base}@{at}"),
        None => base,
    }
}

/// The record write for the installations the pass proved on disk, or
/// nothing when the pass proved none it could record on its own.
fn claim(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    disk: &Lock,
    report: &EngineReport,
    planned: Lock,
) -> Result<Option<Claim>> {
    // A pass that would rewrite the manifest — an agent's skill list
    // merged from upstream, a reserved name moved — records entries built
    // from a manifest nobody has written yet. That apply is the person's
    // to confirm, and the record waits for it.
    if report
        .plan
        .ops
        .iter()
        .any(|planned| matches!(planned.op, Op::WriteManifest { .. }))
    {
        return Ok(None);
    }
    let touched: BTreeSet<PathBuf> = report
        .plan
        .ops
        .iter()
        .filter(|planned| !matches!(planned.op, Op::WriteLock { .. }))
        .flat_map(|planned| planned.op.touched())
        .collect();
    let mut fresh = proven_entries(report, planned);
    fresh.entries.retain(|key, entry| {
        !disk.entries.contains_key(key) && untouched(env, scope, entry, &touched)
    });
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
    // The resolutions behind the entries just added; a resolution the
    // record already holds stays, since the entries recorded under it
    // were not re-read this pass.
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
    bind_reads(env, scope, &fresh, &mut record)?;
    let installations = fresh
        .entries
        .values()
        .map(|entry| (entry.kind, entry.name.clone(), entry.harness))
        .collect();
    Ok(Some(Claim {
        installations,
        record,
    }))
}

/// Whether the pass would leave every position this entry records alone.
/// An entry with no drift row can still have an op against its files — a
/// toggle between its two spellings — and a record of it as installed
/// would then describe the tree the apply was about to change.
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
    bind_reads(env, scope, &recovered.matching, &mut recovered.report.plan)?;
    Ok(recovered.report)
}

fn bind_reads(env: &Env, scope: &Scope, matching: &Lock, plan: &mut Plan) -> Result<()> {
    use crate::apply::{Pre, ReadCheck};
    let manifest_path = manifest::manifest_path(env, scope);
    plan.reads.push(ReadCheck::File {
        pre: Pre::observed(&manifest_path)?,
        path: manifest_path,
    });
    for entry in matching.entries.values() {
        let owned = owned::installed(env, scope, entry);
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
            for candidate in [targets::disabled_name(&path), path] {
                let pre = if candidate.exists() || candidate.is_symlink() {
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
