//! The package page's queries: every file the package ships, any one of
//! them capped for preview, the readme when there is one, and the
//! provenance line — where it came from, which version, since when.

use std::path::{Path, PathBuf};

use serde::Serialize;
use specta::Type;

use crate::engine::ItemSource;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source_read::SealedSource;

/// One file inside the package, path relative to the package root with
/// forward slashes whatever the platform.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, serde::Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageFile {
    pub path: String,
    pub size: u32,
    pub is_readme: bool,
}

/// The catalog's own claims about the plugin an item ships in — read-side
/// display only, never intent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CatalogGroupMeta {
    pub version: Option<String>,
    pub description: Option<String>,
    pub author: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageMeta {
    pub source: String,
    /// `owner/repo`, when the source is remote.
    pub repo: Option<String>,
    /// A safe https link to the repository, when one can be formed.
    pub repo_url: Option<String>,
    /// The declaration's hold, when it has one.
    pub rev: Option<String>,
    /// The content revision installed now.
    pub current: Option<super::updates::VersionRef>,
    pub installed_at: Option<String>,
    pub harnesses: Vec<HarnessId>,
    pub enabled: bool,
    pub fork: Option<crate::manifest::ForkProvenance>,
    pub catalog: Option<CatalogGroupMeta>,
}

/// The sealed root and item path the declaration reads right now — its own
/// hold when it has one, the source's resolution otherwise. Forks and other
/// local items read the local source; every read stays sealed either way.
///
/// The manifest is loaded here rather than passed in: a project whose
/// manifest is still v1, or any other manifest that fails to load, must not
/// stop the preview for an item that kendex never touched — it falls
/// through to the on-disk installation exactly as an undeclared item does.
fn effective_item(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Result<(SealedSource, PathBuf)> {
    let declared = crate::engine::ops::manifest_for_mutation(env, scope)
        .ok()
        .and_then(|manifest| {
            manifest
                .declared(kind)
                .get(name)
                .cloned()
                .map(|decl| (manifest, decl))
        });
    let Some((manifest, decl)) = declared else {
        return effective_item_on_disk(env, scope, kind, name);
    };
    let state =
        crate::source::resolve_at(env, scope, &decl.source, &manifest, decl.rev.as_deref())?;
    let crate::source::SourceState::Ready(ready) = state else {
        return Err(CoreError::SourcePending {
            name: decl.source.clone(),
        });
    };
    let sealed = SealedSource::open(&ready.root)?;
    let config =
        crate::source::source_config(&sealed, crate::source::repo_leaf(&ready.provenance))?;
    let Some(item_path) = crate::source::find_item(&sealed, &config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: decl.source.clone(),
        });
    };
    Ok((sealed, item_path))
}

/// The installation behind an item the manifest cannot vouch for, found the
/// same way the drift scan finds every unmanaged item: by walking the
/// harnesses' real surfaces rather than a declaration. Reused rather than
/// reimplemented — this is the only place scope+kind+name already resolves
/// to a real path.
fn effective_item_on_disk(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Result<(SealedSource, PathBuf)> {
    let scope = scope.canonical();
    let harness_roots = crate::settings::load(env)
        .map(|settings| settings.harness_roots)
        .unwrap_or_default();
    let Some(item) = crate::scan::find_installed(env, &harness_roots, &scope, kind, name) else {
        return Err(CoreError::PackageNotFound {
            kind,
            name: name.to_owned(),
        });
    };
    // The seal canonicalizes its own root, so the item has to be resolved
    // the same way: two tools sharing one folder reach it through a symlink,
    // and an unresolved path never sits beneath the resolved root.
    let resolved = item
        .path
        .canonicalize()
        .map_err(|e| CoreError::io(&item.path, e))?;
    let (root, item_path) = if resolved.is_dir() {
        (resolved.clone(), resolved)
    } else {
        let parent = resolved
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| resolved.clone());
        (parent, resolved)
    };
    let sealed = SealedSource::open(&root)?;
    Ok((sealed, item_path))
}

fn is_readme(path: &str) -> bool {
    let base = path.rsplit('/').next().unwrap_or(path);
    base.eq_ignore_ascii_case("README.md") || base.eq_ignore_ascii_case("README")
}

/// Every file the package ships at its effective revision, sorted by path.
pub fn package_files(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Result<Vec<PackageFile>> {
    let (sealed, item_path) = effective_item(env, scope, kind, name)?;
    let mut files = Vec::new();
    if sealed.is_dir(&item_path) {
        for (rel, bytes) in sealed.collect_tree(&item_path, &[])? {
            let path = slashed(&rel);
            files.push(PackageFile {
                is_readme: is_readme(&path) && !rel.to_string_lossy().contains('/'),
                size: bytes.len().min(u32::MAX as usize) as u32,
                path,
            });
        }
    } else {
        let bytes = sealed.read(&item_path)?;
        let path = item_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| name.to_owned());
        files.push(PackageFile {
            is_readme: false,
            size: bytes.len().min(u32::MAX as usize) as u32,
            path,
        });
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// One file's content, capped for preview. The relative path is validated
/// before it is joined — no absolute paths, no `..` — and the read still
/// goes through the sealed root, so a hostile catalog cannot serve host
/// files through a crafted name.
pub fn package_file(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    rel: &str,
) -> Result<ItemSource> {
    let (sealed, item_path) = effective_item(env, scope, kind, name)?;
    super::item_file::item_file(&sealed, &item_path, rel)
}

/// The package's readme, when it ships one at its root: exact `README.md`
/// first, then `README`, then the first case-insensitive match in path
/// order — one deterministic winner whatever the filesystem's case rules.
pub fn package_readme(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Result<Option<ItemSource>> {
    let (sealed, item_path) = effective_item(env, scope, kind, name)?;
    if !sealed.is_dir(&item_path) {
        return Ok(None);
    }
    let mut candidates: Vec<PathBuf> = sealed
        .list_dir(&item_path)?
        .into_iter()
        .filter(|path| {
            path.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .is_some_and(|n| is_readme(&n))
        })
        .collect();
    candidates.sort();
    let exact = |wanted: &str| {
        candidates
            .iter()
            .find(|path| path.file_name().is_some_and(|n| n == wanted))
            .cloned()
    };
    let Some(readme) = exact("README.md")
        .or_else(|| exact("README"))
        .or_else(|| candidates.first().cloned())
    else {
        return Ok(None);
    };
    let bytes = sealed.read(&readme)?;
    Ok(Some(capped(&readme, bytes)))
}

/// Provenance and standing for the package page, in one query.
pub fn package_meta(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<PackageMeta> {
    let manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let repo = manifest
        .sources
        .get(&decl.source)
        .and_then(|s| s.repo.clone());
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let entries: Vec<&crate::lock::LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
        .collect();
    let current = entries
        .iter()
        .find_map(|entry| entry.source_commit.clone())
        .map(|commit| labeled_version(env, scope, &manifest, kind, name, commit));
    Ok(PackageMeta {
        repo_url: repo.as_deref().and_then(safe_repo_url),
        repo,
        rev: decl.rev.clone(),
        current,
        installed_at: entries.iter().map(|entry| entry.installed_at.clone()).min(),
        harnesses: entries.iter().map(|entry| entry.harness).collect(),
        enabled: decl.enabled,
        fork: manifest
            .forks
            .get(&kind)
            .and_then(|forks| forks.get(name))
            .cloned(),
        catalog: catalog_meta(env, scope, &manifest, kind, name),
        source: decl.source,
    })
}

/// The installed commit with the label and date its timeline gives it —
/// best effort: a mirror that cannot answer leaves a bare commit.
fn labeled_version(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    commit: String,
) -> super::updates::VersionRef {
    let row = super::package_ref(env, scope, manifest, kind, name)
        .ok()
        .and_then(|package| {
            let content = crate::remote::history::last_content_commit(
                &package.mirror,
                &commit,
                &package.subtree,
            )
            .ok()
            .flatten()?;
            crate::remote::history::subtree_log(&package.mirror, &package.tip, &package.subtree)
                .ok()?
                .into_iter()
                .find(|row| row.commit == content)
        });
    match row {
        Some(row) => super::updates::VersionRef {
            commit,
            label: row.tags.first().cloned(),
            date: Some(row.date),
        },
        None => super::updates::VersionRef {
            commit,
            label: None,
            date: None,
        },
    }
}

/// A repository link safe to open: https, no embedded credentials. A
/// shorthand becomes its GitHub page; anything else must already be a
/// clean https URL or it gets no link at all.
fn safe_repo_url(repo: &str) -> Option<String> {
    if !repo.contains("://") && !repo.starts_with("git@") {
        return Some(format!("https://github.com/{repo}"));
    }
    let rest = repo.strip_prefix("https://")?;
    (!rest.contains('@')).then(|| repo.to_owned())
}

/// The plugin's own claims, when the item came from a plugin-registry catalog
/// (its name carries the plugin: `<plugin>/<item>`).
fn catalog_meta(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
) -> Option<CatalogGroupMeta> {
    let (plugin, _) = crate::names::split(name)?;
    let decl = manifest.declared(kind).get(name)?;
    let state =
        crate::source::resolve_at(env, scope, &decl.source, manifest, decl.rev.as_deref()).ok()?;
    let crate::source::SourceState::Ready(ready) = state else {
        return None;
    };
    let sealed = SealedSource::open(&ready.root).ok()?;
    let metadata = crate::source::catalog_metadata(&sealed).ok()??;
    let group = metadata.groups.into_iter().find(|g| g.name == plugin)?;
    Some(CatalogGroupMeta {
        version: group.version,
        description: group.description,
        author: group.author,
        license: group.license,
        homepage: group.homepage.filter(|url| {
            url.starts_with("https://") && !url.trim_start_matches("https://").contains('@')
        }),
        category: group.category,
    })
}

pub(crate) fn capped(path: &Path, bytes: Vec<u8>) -> ItemSource {
    const MAX: usize = 64 * 1024;
    let taken = {
        let mut at = bytes.len().min(MAX);
        while at > 0 && at < bytes.len() && bytes[at] & 0xC0 == 0x80 {
            at -= 1;
        }
        at
    };
    ItemSource {
        path: path.display().to_string(),
        content: String::from_utf8_lossy(&bytes[..taken]).into_owned(),
        truncated: bytes.len() > taken,
    }
}

fn slashed(rel: &Path) -> String {
    rel.components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}
