//! Carrier provenance and byte comparisons share one record builder.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};

use super::{PackageState, RecordBasis, declared_state, find_by_package_name};

/// One declared Pi package resolved to the catalog bytes and provenance that
/// installation, verification, recovery, and report routing share.
#[derive(Debug, Clone)]
pub struct DeclaredPackage {
    pub source_dir: PathBuf,
    pub source: String,
    pub source_repo: String,
    pub source_commit: Option<String>,
}

/// Preserve provenance but clear completion before replacement destroys the
/// installed package. The caller holds the scope lock until installation ends.
pub fn clear_install_completion(env: &Env, scope: &crate::model::Scope, name: &str) -> Result<()> {
    let path = crate::lock::lock_path(env, scope);
    let mut lock = crate::lock::load(&path)?;
    let key = crate::lock::entry_key(
        crate::model::ItemKind::PiExtension,
        name,
        crate::model::HarnessId::Pi,
    );
    if let Some(entry) = lock.entries.get_mut(&key)
        && entry.rendered_hash.take().is_some()
    {
        crate::lock::save(&path, &lock)?;
    }
    Ok(())
}

pub fn resolve_declared(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    name: &str,
    decl: &crate::manifest::ItemDecl,
) -> Result<DeclaredPackage> {
    let ready =
        crate::source::require_ready_at(env, scope, &decl.source, manifest, decl.rev.as_deref())?;
    let sealed = crate::source_read::SealedSource::open(&ready.root)?;
    let direct = sealed.root().join("pi-extensions").join(name);
    let source_dir = if sealed.is_file(&direct.join("package.json")) {
        direct
    } else {
        find_by_package_name(&sealed, name)?.ok_or_else(|| CoreError::PiPackage {
            name: name.to_owned(),
            message: format!(
                "source '{}' no longer ships pi-extensions/{name}",
                decl.source
            ),
        })?
    };
    Ok(DeclaredPackage {
        source_dir,
        source: decl.source.clone(),
        source_repo: ready.provenance,
        source_commit: ready.commit,
    })
}

/// Build a durable record only when the installed copy matches the declared
/// source byte for byte or under the destination path's Git text policy.
/// Any other difference is not ownership evidence. The entry's enabled flag
/// records the native extension filter, not an assumed installation default.
pub fn matching_lock_entry(
    scope_root: &Path,
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
    basis: RecordBasis,
) -> Result<Option<crate::lock::LockEntry>> {
    check_origin(name, package, existing)?;
    let PackageState::Current {
        source_hash,
        rendered_hash,
    } = declared_state(scope_root, name, package, existing, basis)?
    else {
        return Ok(None);
    };
    let installed_at = existing
        .filter(|entry| super::state::matches_record(entry, name, &source_hash, &rendered_hash))
        .and_then(|entry| entry.machine.as_ref())
        .map_or_else(crate::clock::timestamp, |machine| {
            machine.installed_at.clone()
        });
    Ok(Some(crate::lock::LockEntry {
        name: name.to_owned(),
        kind: crate::model::ItemKind::PiExtension,
        harness: crate::model::HarnessId::Pi,
        source: package.source.clone(),
        source_repo: package.source_repo.clone(),
        machine: Some(crate::lock::MachineRecord {
            method: crate::manifest::Method::Copy,
            installed_at,
        }),
        source_hash,
        source_commit: package.source_commit.clone(),
        rendered_hash: Some(rendered_hash),
        enabled: super::settings::package_enabled(&super::settings_path(scope_root), name)?
            .ok_or_else(|| CoreError::PiPackage {
                name: name.to_owned(),
                message: "matching package lost its settings registration".to_owned(),
            })?,
        upstream_skills: None,
        emitted: None,
        registration: None,
        output_style: None,
        reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
    }))
}

/// Where a planning pass collects what switching a declaration changes: the
/// native switches' settings write, and each switched package's
/// `APPEND_SYSTEM.md` edit with its label, which the plan composes with the
/// file's other edits into one mutation.
pub struct SwitchPlan<'a> {
    pub ops: &'a mut Vec<crate::apply::PlannedOp>,
    pub edits: &'a mut Vec<(PathBuf, String, crate::configedit::ConfigEdit)>,
}

/// Compare each declared carrier package and preserve durable provenance.
/// Missing or unreadable bytes produce drift rather than an omitted row.
/// With `plan`, plan native switches and record their intended state.
/// Without it, retain the observed switch for read-only recovery and
/// installation.
pub fn record_matching_manifest(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    basis: RecordBasis,
    plan: Option<SwitchPlan<'_>>,
) -> Result<Vec<crate::engine::DriftRow>> {
    record_matching(
        env,
        scope,
        manifest,
        lock,
        manifest.pi_extensions.iter(),
        basis,
        plan,
    )
}

/// Compare one declaration after its carrier install completed.
pub fn record_matching_name(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    name: &str,
) -> Result<Vec<crate::engine::DriftRow>> {
    record_matching(
        env,
        scope,
        manifest,
        lock,
        manifest.pi_extensions.get_key_value(name).into_iter(),
        RecordBasis::MatchedBytes,
        None,
    )
}

fn record_matching<'a>(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
    declarations: impl Iterator<Item = (&'a String, &'a crate::manifest::ItemDecl)>,
    basis: RecordBasis,
    mut plan: Option<SwitchPlan<'_>>,
) -> Result<Vec<crate::engine::DriftRow>> {
    use crate::engine::{DriftRow, DriftState};
    use crate::model::{HarnessId, ItemKind};
    let root = scope_root(env, scope)?;
    let mut drift = Vec::new();
    let mut switches = Vec::new();
    for (name, decl) in declarations {
        let key = crate::lock::entry_key(ItemKind::PiExtension, name, HarnessId::Pi);
        let result = resolve_declared(env, scope, manifest, name, decl).and_then(|package| {
            matching_lock_entry(&root, name, &package, lock.entries.get(&key), basis)
        });
        let detail = match result {
            Ok(Some(mut entry)) => {
                let differs = entry.enabled != decl.enabled;
                if differs && let Some(plan) = plan.as_mut() {
                    switches.push((name.as_str(), decl.enabled));
                    entry.enabled = decl.enabled;
                    let (path, edit) = super::append_system_edit(&root, name, decl.enabled)?;
                    plan.edits.push((path, format!("switch {name}"), edit));
                }
                lock.entries.insert(key, entry);
                if !differs {
                    continue;
                }
                "native extension filter does not match the enabled declaration".to_owned()
            }
            Ok(None) => {
                "carrier package or completed install record does not match; update-pi must settle it"
                    .to_owned()
            }
            Err(error) => format!("carrier package could not be compared: {error}"),
        };
        drift.push(DriftRow {
            kind: ItemKind::PiExtension,
            name: name.clone(),
            harness: HarnessId::Pi,
            scope: scope.clone(),
            state: DriftState::Stale,
            detail,
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        });
    }
    if let Some(plan) = plan
        && !switches.is_empty()
    {
        let path = super::settings_path(&root);
        let pre = crate::apply::Pre::observed(&path)?;
        let text = super::settings::toggled_packages(&path, switches.into_iter())?;
        plan.ops.push(crate::apply::PlannedOp {
            description: "Set Pi package extension filters".into(),
            op: crate::apply::Op::WriteFile {
                path,
                bytes: text.into_bytes(),
                pre,
            },
        });
    }
    Ok(drift)
}

/// Refuse a toggle that the carrier comparison cannot plan. A manifest-only
/// toggle must not claim it changed what Pi loads.
pub(crate) fn ensure_toggle_ready(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &crate::lock::Lock,
    name: &str,
) -> Result<()> {
    let decl = &manifest.pi_extensions[name];
    let root = scope_root(env, scope)?;
    let package = resolve_declared(env, scope, manifest, name, decl)?;
    let key = crate::lock::entry_key(
        crate::model::ItemKind::PiExtension,
        name,
        crate::model::HarnessId::Pi,
    );
    if matching_lock_entry(
        &root,
        name,
        &package,
        lock.entries.get(&key),
        RecordBasis::Recorded,
    )?
    .is_none()
    {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: "carrier package or completed install record does not match; update-pi before toggling".to_owned(),
        });
    }
    Ok(())
}

/// Refuse a source rebind before the carrier changes any installed bytes.
pub fn check_origin(
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
) -> Result<()> {
    if let Some(existing) = existing
        && crate::source_ref::repo_identity(&existing.source_repo)
            != crate::source_ref::repo_identity(&package.source_repo)
    {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: format!(
                "recorded source {} conflicts with declared source {}",
                existing.source_repo, package.source_repo
            ),
        });
    }
    Ok(())
}

/// Where a scope's packages install.
pub fn scope_root(env: &Env, scope: &crate::model::Scope) -> Result<PathBuf> {
    let settings = crate::settings::load(env)?;
    Ok(match scope {
        crate::model::Scope::Global => global_root(env, &settings),
        crate::model::Scope::Project { root } => root.join(".pi"),
    })
}

/// Where a scope's packages install, and every root an install there
/// must be checked against before writing: Pi loads the global root and
/// a project's together, and which project comes later, so a guard that
/// refuses a package registered twice looks at every project this
/// machine knows, the registered ones and the one the command runs in.
/// For a project that is the global root alone.
pub fn paired_roots(
    env: &Env,
    settings: &crate::settings::AppSettings,
    scope: &crate::model::Scope,
) -> (PathBuf, Vec<PathBuf>) {
    let global = global_root(env, settings);
    match scope {
        crate::model::Scope::Global => {
            let mut projects = settings.projects.clone();
            if let Some(here) = crate::discover::current_project(env)
                && !projects.contains(&here)
            {
                projects.push(here);
            }
            (
                global,
                projects.iter().map(|project| project.join(".pi")).collect(),
            )
        }
        crate::model::Scope::Project { root } => (root.join(".pi"), vec![global]),
    }
}

/// Where a scope's packages install, and the one other root Pi loads
/// beside it in the session a command runs in: the global root and the
/// current project's `.pi`, registered or not, and nothing else. A report
/// of what Pi loads twice reads these; the install guard reads
/// [`paired_roots`].
pub fn session_roots(
    env: &Env,
    settings: &crate::settings::AppSettings,
    scope: &crate::model::Scope,
) -> (PathBuf, Vec<PathBuf>) {
    let global = global_root(env, settings);
    match scope {
        crate::model::Scope::Global => (
            global,
            crate::discover::current_project(env)
                .map(|here| here.join(".pi"))
                .into_iter()
                .collect(),
        ),
        crate::model::Scope::Project { root } => (root.join(".pi"), vec![global]),
    }
}

fn global_root(env: &Env, settings: &crate::settings::AppSettings) -> PathBuf {
    use crate::harness::HarnessAdapter;
    let pi = crate::harness::pi::Pi;
    settings
        .harness_roots
        .get(pi.id().name())
        .cloned()
        .unwrap_or_else(|| pi.default_global_root(env))
}
