//! Where each candidate's bytes actually live: the provenance join, the
//! per-row origin reads (marketplace beside its edited install), and the
//! apply-time re-resolution that revalidates the previewed hash.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::library::Origin;
use crate::manifest::{INPLACE_SOURCE_NAME, Manifest, ManifestFile};
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

use super::{Bytes, CandidateGroup, ImportSelection, ResolvedSelection, license_recognized};

/// The observed on-disk path of every installation — provenance rows carry
/// no path, so the scan is asked once and joined here. Managed installs
/// are included: their observed bytes are what an "edited copy" is.
pub(super) fn unmanaged_paths(
    env: &Env,
    scopes: &[Scope],
) -> BTreeMap<(Scope, ItemKind, String), PathBuf> {
    let Ok(settings) = crate::settings::load(env) else {
        return BTreeMap::new();
    };
    let scopes: Vec<Scope> = scopes.iter().map(Scope::canonical).collect();
    let observed = crate::scan::scan_scopes(env, &settings.harness_roots, &scopes);
    let mut paths = BTreeMap::new();
    for item in observed.items {
        if item.vendor.is_some() {
            continue;
        }
        paths
            .entry((item.scope, item.kind, item.name))
            .or_insert(item.path);
    }
    paths
}

/// Where one provenance row's bytes live — possibly two answers, when the
/// installed copy of a marketplace package differs from the marketplace's
/// own bytes. Empty for rows import cannot carry (config-entry kinds have
/// no file of their own to copy).
/// The `String` is where the bytes were read from, said the way kendex
/// says a path: [`crate::paths::slashed`], because callers match on it
/// (`.agents/skills/…`) and a `\` there matches nothing.
type OriginRead = (CandidateGroup, Option<Bytes>, String, Option<PathBuf>);

pub(super) fn origins_of(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    match &row.origin {
        Origin::Own { source, .. } => {
            // The reserved source names where the bytes live: the local
            // capture, or the shared tree an in-place skill is read from
            // (a scope with no such tree holds no in-place rows).
            let root = if source == INPLACE_SOURCE_NAME {
                match crate::source::inplace_source_root(&row.scope) {
                    Some(root) => root,
                    None => return Vec::new(),
                }
            } else {
                crate::source::local_source_root(env, &row.scope)
            };
            match catalog_bytes(&root, source, row) {
                Some((bytes, location, read_from)) => {
                    vec![(CandidateGroup::Own, bytes, location, Some(read_from))]
                }
                None => Vec::new(),
            }
        }
        Origin::Marketplace { source, repo } => {
            marketplace_origins(env, row, source, repo, observed)
        }
        Origin::Unmanaged => {
            if !matches!(
                row.kind,
                ItemKind::Skill | ItemKind::Agent | ItemKind::Command
            ) {
                return Vec::new();
            }
            let Some(path) = observed.get(&(row.scope.clone(), row.kind, row.name.clone())) else {
                return Vec::new();
            };
            let Some(bytes) = path
                .parent()
                .and_then(|parent| SealedSource::open(parent).ok())
                .and_then(|sealed| read_bytes(&sealed, row.kind, path))
            else {
                return Vec::new();
            };
            vec![(
                CandidateGroup::Unmanaged,
                Some(bytes),
                crate::paths::slashed(path),
                Some(path.clone()),
            )]
        }
    }
}

/// A marketplace row's origins: the marketplace's own bytes, and — when
/// the installed copy no longer matches them — the edited copy beside the
/// original, so the choice pass 3 requires is a real choice.
pub(super) fn marketplace_origins(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    source: &str,
    repo: &str,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    let manifest = scope_manifest(env, &row.scope);
    let unreachable = |license: Option<String>| {
        vec![(
            CandidateGroup::Marketplace {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            None,
            format!("{repo} (not fetched)"),
            None,
        )]
    };
    let resolved = match crate::source::resolve(env, &row.scope, source, &manifest) {
        Ok(crate::source::SourceState::Ready(resolved)) => resolved,
        // Unreachable provenance is listed, not guessed: the row shows
        // with no bytes and selecting it refuses.
        _ => return unreachable(None),
    };
    let Ok(sealed) = SealedSource::open(&resolved.root) else {
        return unreachable(None);
    };
    let Ok(config) = crate::source::source_config_for(&sealed, &resolved.provenance) else {
        return unreachable(None);
    };
    let license = config
        .marketplace
        .as_ref()
        .and_then(|meta| meta.license.clone());
    let Some(path) = crate::source::find_item(&sealed, &config, row.kind, &row.name) else {
        return unreachable(license);
    };
    let Some(bytes) = read_bytes(&sealed, row.kind, &path) else {
        return unreachable(license);
    };
    let source_hash = bytes.hash();
    let mut origins = vec![(
        CandidateGroup::Marketplace {
            source: source.to_owned(),
            repo: repo.to_owned(),
            license: license.clone(),
            license_recognized: license.as_deref().is_some_and(license_recognized),
        },
        Some(bytes),
        format!("{repo}:{}", rel(&sealed, &path)),
        Some(path.clone()),
    )];
    // The installed copy, when it diverged: read at its observed path.
    if let Some(installed) = observed.get(&(row.scope.clone(), row.kind, row.name.clone()))
        && let Some(edited) = installed
            .parent()
            .and_then(|parent| SealedSource::open(parent).ok())
            .and_then(|sealed| read_bytes(&sealed, row.kind, installed))
        && edited.hash() != source_hash
    {
        origins.push((
            CandidateGroup::Edited {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            Some(edited),
            crate::paths::slashed(installed),
            Some(installed.clone()),
        ));
    }
    origins
}

pub(super) fn catalog_bytes(
    root: &Path,
    provenance: &str,
    row: &crate::library::ProvenanceRow,
) -> Option<(Option<Bytes>, String, PathBuf)> {
    let sealed = SealedSource::open(root).ok()?;
    let config = crate::source::source_config_for(&sealed, provenance).ok()?;
    let path = crate::source::find_item(&sealed, &config, row.kind, &row.name)?;
    let bytes = read_bytes(&sealed, row.kind, &path)?;
    let location = crate::paths::slashed(&root.join(rel_path(&sealed, &path)));
    Some((Some(bytes), location, path))
}

pub(super) fn read_bytes(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Option<Bytes> {
    match kind {
        ItemKind::Skill => {
            let dir = match sealed.is_dir(path) {
                true => path.to_path_buf(),
                // A one-skill repo hands the SKILL.md itself.
                false => path.parent()?.to_path_buf(),
            };
            let files = sealed.collect_skill_tree(&dir).ok()?;
            Some(Bytes::Tree(files))
        }
        _ => Some(Bytes::File(sealed.read(path).ok()?)),
    }
}

/// Where `path` sits inside the catalog, as text a caller can match: an
/// origin's location is read back against catalog paths, and those are
/// `/`-spelled wherever they are written down.
pub(super) fn rel(sealed: &SealedSource, path: &Path) -> String {
    crate::paths::slashed(rel_path(sealed, path))
}

/// The same as a path, for a caller that has more to join on before the
/// spelling is settled — spelling a path in two halves leaves the seam in
/// whichever spelling the platform joined with.
fn rel_path<'a>(sealed: &SealedSource, path: &'a Path) -> &'a Path {
    path.strip_prefix(sealed.root()).unwrap_or(path)
}

pub(super) fn scope_manifest(env: &Env, scope: &Scope) -> Manifest {
    crate::manifest::load(&crate::manifest::manifest_path(env, scope))
        .ok()
        .and_then(|file| match file {
            ManifestFile::Current(manifest) => Some(*manifest),
            _ => None,
        })
        .unwrap_or_default()
}

/// The bytes behind one selection, re-read now so the hash the person saw
/// is revalidated against what is on disk at apply time — along with the
/// provenance that governs it and its licence evidence files.
pub(super) fn resolve_selection(
    env: &Env,
    scopes: &[Scope],
    selection: &ImportSelection,
) -> Result<ResolvedSelection> {
    let observed = unmanaged_paths(env, scopes);
    for row in crate::library::provenance(env, scopes)? {
        if row.kind != selection.kind || row.name != selection.name {
            continue;
        }
        for (group, bytes, _, read_from) in origins_of(env, &row, &observed) {
            let Some(bytes) = bytes else { continue };
            if bytes.hash() != selection.hash {
                continue;
            }
            let notices = match group.licensed_source() {
                Some((source, _, _)) => notice_files(env, &row.scope, source),
                None => Vec::new(),
            };
            return Ok(ResolvedSelection {
                bytes,
                group,
                notices,
                read_from,
            });
        }
    }
    Err(CoreError::Authoring {
        message: format!(
            "the bytes of {} '{}' changed since the preview — re-open the import to re-preview",
            selection.kind.name(),
            selection.name
        ),
    })
}

/// Root-level licence and attribution files of one catalog — the evidence
/// that must travel with copied bytes.
pub(super) fn notice_files(env: &Env, scope: &Scope, source: &str) -> Vec<(String, Vec<u8>)> {
    let manifest = scope_manifest(env, scope);
    let Ok(crate::source::SourceState::Ready(resolved)) =
        crate::source::resolve(env, scope, source, &manifest)
    else {
        return Vec::new();
    };
    let Ok(sealed) = SealedSource::open(&resolved.root) else {
        return Vec::new();
    };
    let Ok(entries) = sealed.entries(&resolved.root) else {
        return Vec::new();
    };
    let mut notices = Vec::new();
    for entry in entries {
        let Some(name) = entry.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let stem = name.split('.').next().unwrap_or(name).to_ascii_uppercase();
        if matches!(stem.as_str(), "LICENSE" | "LICENCE" | "NOTICE" | "COPYING")
            && sealed.is_file(&entry)
            && let Ok(bytes) = sealed.read(&entry)
        {
            notices.push((name.to_owned(), bytes));
        }
    }
    notices.sort();
    notices
}
