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

mod notices;
mod offer;
use notices::notice_files;
use offer::offered;

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

/// One place a provenance row's bytes were found, as the wizard may offer
/// it.
pub(super) struct OriginRead {
    pub group: CandidateGroup,
    /// The bytes, or `None` where there are none to offer: a marketplace
    /// nobody fetched, or an origin [`offered`] refuses.
    pub bytes: Option<Bytes>,
    /// Where the bytes were read from, said the way kendex says a path:
    /// [`crate::paths::slashed`], because callers match on it
    /// (`.agents/skills/…`) and a `\` there matches nothing.
    pub location: String,
    /// Why these bytes are not on offer, when [`offered`] refuses them.
    /// Its own field rather than prose folded into `location`, which every
    /// reader takes for a place.
    pub problem: Option<String>,
    pub read_from: Option<PathBuf>,
}

/// Every origin one provenance row offers, each judged by [`offered`].
///
/// Possibly two, when the installed copy of a marketplace package differs
/// from the marketplace's own bytes. Empty for rows import cannot carry
/// (config-entry kinds have no file of their own to copy).
pub(super) fn origins_of(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    reads(env, row, observed)
        .into_iter()
        .map(|read| offered(row.kind, read))
        .collect()
}

/// Where the bytes are, before anything asks whether they may be copied.
fn reads(
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
                Some((bytes, location, read_from)) => vec![OriginRead {
                    group: CandidateGroup::Own,
                    bytes: Some(bytes),
                    location,
                    problem: None,
                    read_from: Some(read_from),
                }],
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
            vec![OriginRead {
                group: CandidateGroup::Unmanaged,
                bytes: Some(bytes),
                location: crate::paths::slashed(path),
                problem: None,
                read_from: Some(path.clone()),
            }]
        }
    }
}

/// A marketplace row's origins: the marketplace's own bytes, and — when
/// the installed copy no longer matches them — the edited copy beside the
/// original, so the choice pass 3 requires is a real choice.
fn marketplace_origins(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    source: &str,
    repo: &str,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    let manifest = scope_manifest(env, &row.scope);
    let unreachable = |license: Option<String>| {
        vec![OriginRead {
            group: CandidateGroup::Marketplace {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            bytes: None,
            location: format!("{repo} (not fetched)"),
            problem: None,
            read_from: None,
        }]
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
    let mut origins = vec![OriginRead {
        group: CandidateGroup::Marketplace {
            source: source.to_owned(),
            repo: repo.to_owned(),
            license: license.clone(),
            license_recognized: license.as_deref().is_some_and(license_recognized),
        },
        bytes: Some(bytes),
        location: format!("{repo}:{}", rel(&sealed, &path)),
        problem: None,
        read_from: Some(path.clone()),
    }];
    // The installed copy, when it diverged: read at its observed path.
    if let Some(installed) = observed.get(&(row.scope.clone(), row.kind, row.name.clone()))
        && let Some(edited) = installed
            .parent()
            .and_then(|parent| SealedSource::open(parent).ok())
            .and_then(|sealed| read_bytes(&sealed, row.kind, installed))
        && edited.hash() != source_hash
    {
        // An agent installs as the file its harness reads, so the edited
        // copy of a marketplace agent under Codex is the TOML rendering —
        // the same bytes a catalog cannot store, reaching `offered` by the
        // other door.
        origins.push(OriginRead {
            group: CandidateGroup::Edited {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            bytes: Some(edited),
            location: crate::paths::slashed(installed),
            problem: None,
            read_from: Some(installed.clone()),
        });
    }
    origins
}

fn catalog_bytes(
    root: &Path,
    provenance: &str,
    row: &crate::library::ProvenanceRow,
) -> Option<(Bytes, String, PathBuf)> {
    let sealed = SealedSource::open(root).ok()?;
    let config = crate::source::source_config_for(&sealed, provenance).ok()?;
    let path = crate::source::find_item(&sealed, &config, row.kind, &row.name)?;
    let bytes = read_bytes(&sealed, row.kind, &path)?;
    let location = crate::paths::slashed(&root.join(rel_path(&sealed, &path)));
    Some((bytes, location, path))
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
    // Where the bytes were, for a selection nothing matches, and whether
    // any origin was selectable at all. `selectable` is what tells the two
    // refusals apart: with a usable origin in the list, a hash matching
    // none of them is a stale preview, and naming the other origins would
    // name what was never the problem. `super::no_importable_bytes` writes
    // the sentence; this caller takes the one-line layout, because a
    // `CoreError` that does not own its breaks has them escaped where the
    // CLI prints it.
    let mut unusable: Vec<(String, Option<String>)> = Vec::new();
    let mut selectable = false;
    for row in crate::library::provenance(env, scopes)? {
        if row.kind != selection.kind || row.name != selection.name {
            continue;
        }
        for read in origins_of(env, &row, &observed) {
            let Some(bytes) = read.bytes else {
                unusable.push((read.location, read.problem));
                continue;
            };
            selectable = true;
            if bytes.hash() != selection.hash {
                continue;
            }
            let notices = match read.group.licensed_source() {
                Some((source, _, _)) => notice_files(env, &row.scope, source)?,
                None => Vec::new(),
            };
            return Ok(ResolvedSelection {
                bytes,
                group: read.group,
                notices,
                read_from: read.read_from,
            });
        }
    }
    if !selectable && !unusable.is_empty() {
        return Err(CoreError::Authoring {
            message: super::no_importable_bytes(
                selection.kind,
                &selection.name,
                &unusable,
                super::Places::OneLine,
            ),
        });
    }
    Err(CoreError::Authoring {
        message: format!(
            "the bytes of {} '{}' changed since the preview — re-open the import to re-preview",
            selection.kind.name(),
            selection.name
        ),
    })
}
