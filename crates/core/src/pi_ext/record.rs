use super::*;

/// One declared Pi package resolved to the catalog bytes and provenance that
/// installation, verification, recovery, and report routing share.
#[derive(Debug, Clone)]
pub struct DeclaredPackage {
    pub source_dir: PathBuf,
    pub source: String,
    pub source_repo: String,
    pub source_commit: Option<String>,
}

pub fn resolve_declared(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    name: &str,
    decl: &crate::manifest::ItemDecl,
) -> Result<DeclaredPackage> {
    let ready = crate::source::require_ready(env, scope, &decl.source, manifest)?;
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

/// Build a durable record only when installed bytes equal declared source
/// bytes. A mismatch is not ownership evidence.
pub fn matching_lock_entry(
    scope_root: &Path,
    name: &str,
    package: &DeclaredPackage,
    existing: Option<&crate::lock::LockEntry>,
) -> Result<Option<crate::lock::LockEntry>> {
    check_origin(name, package, existing)?;
    let Some(source_hash) = package_hash(&package.source_dir)? else {
        return Ok(None);
    };
    let Some(rendered_hash) = installed_hash(scope_root, name)? else {
        return Ok(None);
    };
    if source_hash != rendered_hash {
        return Ok(None);
    }
    let installed_at = existing
        .filter(|entry| {
            entry.kind == crate::model::ItemKind::PiExtension
                && entry.name == name
                && entry.source_hash == source_hash
                && entry.rendered_hash.as_deref() == Some(rendered_hash.as_str())
        })
        .map(|entry| entry.installed_at.clone())
        .unwrap_or_else(crate::clock::timestamp);
    let dest = package_path(scope_root, name)?;
    Ok(Some(crate::lock::LockEntry {
        name: name.to_owned(),
        kind: crate::model::ItemKind::PiExtension,
        harness: crate::model::HarnessId::Pi,
        source: package.source.clone(),
        source_repo: package.source_repo.clone(),
        method: crate::manifest::Method::Copy,
        installed_at,
        source_hash,
        source_commit: package.source_commit.clone(),
        rendered_hash: Some(rendered_hash),
        enabled: true,
        upstream_skills: None,
        emitted: Some(crate::lock::EmittedArtifact {
            kind: crate::model::ItemKind::PiExtension,
            name: name.to_owned(),
            paths: vec![dest],
        }),
        registration: None,
        reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
    }))
}

/// Compare each declared carrier package and preserve durable provenance.
/// Missing or unreadable bytes produce drift rather than an omitted row.
pub fn record_matching_manifest(
    env: &Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    lock: &mut crate::lock::Lock,
) -> Result<Vec<crate::engine::DriftRow>> {
    use crate::engine::{DriftRow, DriftState};
    use crate::model::{HarnessId, ItemKind};
    let root = scope_root(env, scope)?;
    let mut drift = Vec::new();
    for (name, decl) in &manifest.pi_extensions {
        let key = crate::lock::entry_key(ItemKind::PiExtension, name, HarnessId::Pi);
        let result = resolve_declared(env, scope, manifest, name, decl)
            .and_then(|package| matching_lock_entry(&root, name, &package, lock.entries.get(&key)));
        let detail = match result {
            Ok(Some(entry)) => {
                lock.entries.insert(key, entry);
                continue;
            }
            Ok(None) => {
                "carrier package does not match its declared source; update-pi must settle it"
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
    Ok(drift)
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

pub fn scope_root(env: &Env, scope: &crate::model::Scope) -> Result<PathBuf> {
    use crate::harness::HarnessAdapter;
    let settings = crate::settings::load(env)?;
    let pi = crate::harness::pi::Pi;
    Ok(match scope {
        crate::model::Scope::Global => settings
            .harness_roots
            .get(pi.id().name())
            .cloned()
            .unwrap_or_else(|| pi.default_global_root(env)),
        crate::model::Scope::Project { root } => root.join(".pi"),
    })
}
