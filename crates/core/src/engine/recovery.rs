//! Recovery proves installed bytes and writes only their install record.

use crate::apply::Plan;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::Scope;

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
    let mut matching = report
        .plan
        .ops
        .iter()
        .find_map(|planned| match &planned.op {
            crate::apply::Op::WriteLock { lock, .. } => Some(lock.as_ref().clone()),
            _ => None,
        })
        .unwrap_or_else(|| seed.clone());
    matching.entries.retain(|_, entry| {
        !report.drift.iter().any(|row| {
            row.kind == entry.kind
                && row.name == entry.name
                && row.harness == entry.harness
                && row.state != DriftState::Unmanaged
        })
    });
    for planned in &mut report.plan.ops {
        if let crate::apply::Op::WriteLock { lock, .. } = &mut planned.op {
            **lock = matching.clone();
        }
    }
    Ok(RecordlessAudit { report, matching })
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
    let blocked = recovered
        .report
        .drift
        .iter()
        .any(|row| row.state != DriftState::Unmanaged);
    let only_lock = !recovered.report.plan.ops.is_empty()
        && recovered
            .report
            .plan
            .ops
            .iter()
            .all(|planned| matches!(planned.op, crate::apply::Op::WriteLock { .. }));
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
                let hash = entry.rendered_hash.clone().ok_or_else(|| {
                    crate::error::CoreError::RecordExistingRefused {
                        path: path.clone(),
                        reason: "the Pi package has no measured render hash".to_owned(),
                    }
                })?;
                plan.reads.push(ReadCheck::PiPackage { path, hash });
            }
            continue;
        }
        for path in owned.files {
            for candidate in [targets::disabled_name(&path), path] {
                let pre = if candidate.exists() || candidate.is_symlink() {
                    let hash = crate::hash::hash_tree(&candidate)?;
                    if entry
                        .rendered_hash
                        .as_ref()
                        .is_some_and(|expected| expected != &hash)
                    {
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
