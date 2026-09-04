use super::*;

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
    let seed = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
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
    let recovered = audit_without_record(env, scope, &manifest)?;
    let every_declaration_recorded =
        planned_declarations(env, scope, &manifest)
            .iter()
            .all(|declared| {
                recovered
                    .matching
                    .entries
                    .values()
                    .any(|entry| entry.kind == declared.kind && entry.name == declared.name)
            });
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
    if blocked || !only_lock || !every_declaration_recorded {
        return Err(crate::error::CoreError::RecordExistingRefused {
            path,
            reason: "the declared installs do not exactly match current source and disk bytes; no file was changed".to_owned(),
        });
    }
    Ok(recovered.report)
}
