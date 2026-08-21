use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::harness::{HarnessAdapter, Surface, all_adapters};
use crate::model::{DetectedHarness, FileState, ItemKind, ObservedItem, Scope};
use crate::settings::AppSettings;

pub(crate) mod copilot;
mod entry;
pub use entry::RawEntry;
mod files;
pub(crate) mod hooks;
pub(crate) mod jsonc;
pub mod metadata;
mod pi_packages;
mod plugins;
mod provenance;
mod readers;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub harnesses: Vec<DetectedHarness>,
    pub items: Vec<ObservedItem>,
    /// Registered projects whose directory is gone — flagged, never dropped.
    pub missing_projects: Vec<PathBuf>,
    /// Unreadable or unparsable surfaces; truth the scan could not reach.
    pub warnings: Vec<String>,
}

/// Read-only truth of this machine: every kind, every harness, global scope
/// plus every registered project.
pub fn scan(env: &Env, settings: &AppSettings) -> ScanResult {
    let mut scopes = vec![Scope::Global];
    scopes.extend(
        settings
            .projects
            .iter()
            .map(|p| Scope::Project { root: p.clone() }),
    );
    scan_scopes(env, &settings.harness_roots, &scopes)
}

/// The same engine over an explicit scope list — the CLI scans the current
/// project + global, the app scans everything registered.
pub fn scan_scopes(
    env: &Env,
    harness_roots: &std::collections::BTreeMap<String, PathBuf>,
    scopes: &[Scope],
) -> ScanResult {
    let mut result = ScanResult {
        harnesses: Vec::new(),
        items: Vec::new(),
        missing_projects: Vec::new(),
        warnings: Vec::new(),
    };
    let mut provenance = provenance::OriginCache::default();

    for scope in scopes {
        scan_scope(
            env,
            harness_roots,
            scope,
            &ItemKind::ALL,
            &mut provenance,
            &mut result,
        );
    }

    result
}

/// The installation behind one scope + kind + name, found by walking only
/// the surfaces that could hold it. A full scan answers the same question,
/// but a file preview asks it several times a page and has no use for the
/// other kinds, the other scopes, or the frontmatter of every unrelated
/// document those would parse on the way past.
pub fn find_installed(
    env: &Env,
    harness_roots: &std::collections::BTreeMap<String, PathBuf>,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
) -> Option<ObservedItem> {
    let mut result = ScanResult {
        harnesses: Vec::new(),
        items: Vec::new(),
        missing_projects: Vec::new(),
        warnings: Vec::new(),
    };
    let mut provenance = provenance::OriginCache::default();
    scan_scope(
        env,
        harness_roots,
        scope,
        &[kind],
        &mut provenance,
        &mut result,
    );
    result.items.into_iter().find(|item| item.name == name)
}

fn scan_scope(
    env: &Env,
    harness_roots: &std::collections::BTreeMap<String, PathBuf>,
    scope: &Scope,
    kinds: &[ItemKind],
    provenance: &mut provenance::OriginCache,
    result: &mut ScanResult,
) {
    match scope {
        Scope::Global => {
            for adapter in all_adapters() {
                let root = harness_roots
                    .get(adapter.id().name())
                    .cloned()
                    .unwrap_or_else(|| adapter.default_global_root(env));
                if let Some(found) = adapter.detect(env, &root) {
                    result.harnesses.push(found);
                }
                for kind in kinds.iter().copied() {
                    for surface in adapter.global_surfaces(kind, &root, env) {
                        scan_surface(
                            adapter,
                            kind,
                            Scope::Global,
                            &surface,
                            env,
                            provenance,
                            result,
                        );
                    }
                }
            }
        }
        Scope::Project { root: project } => {
            if !project.is_dir() {
                result.missing_projects.push(project.clone());
                return;
            }
            for adapter in all_adapters() {
                for kind in kinds.iter().copied() {
                    for surface in adapter.project_surfaces(kind, project, env) {
                        scan_surface(
                            adapter,
                            kind,
                            scope.clone(),
                            &surface,
                            env,
                            provenance,
                            result,
                        );
                    }
                }
            }
        }
    }
}

fn scan_surface(
    adapter: &dyn HarnessAdapter,
    kind: ItemKind,
    scope: Scope,
    surface: &Surface,
    env: &Env,
    provenance: &mut provenance::OriginCache,
    result: &mut ScanResult,
) {
    match surface {
        Surface::FileDir {
            dir,
            exts,
            prefixes,
        } => {
            for found in files::scan_file_dir(dir, exts, prefixes, &mut result.warnings) {
                warn_unknown_tags(&found, result);
                result.items.push(ObservedItem {
                    kind,
                    name: found.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    file_state: files::state_of(&found.path),
                    origin: provenance.origin_of(&found.path),
                    path: found.path,
                    enabled: Some(found.enabled),
                    tags: found.meta.tags,
                    description: found.meta.description,
                    modified_at: found.modified_at,
                    vendor: None,
                });
            }
        }
        Surface::SubdirPerItem { dir, marker } => {
            for found in files::scan_subdirs(dir, marker, &mut result.warnings) {
                warn_unknown_tags(&found, result);
                result.items.push(ObservedItem {
                    kind,
                    name: found.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    file_state: files::state_of(&found.path),
                    origin: provenance.origin_of(&found.path),
                    path: found.path,
                    enabled: Some(found.enabled),
                    tags: found.meta.tags,
                    description: found.meta.description,
                    modified_at: found.modified_at,
                    vendor: None,
                });
            }
        }
        Surface::Structured { path, reader } => {
            if path.exists() {
                scan_structured_file(adapter, kind, &scope, path, reader, env, result);
            }
        }
        Surface::StructuredDir { dir, ext, reader } => {
            for path in files::scan_documents(dir, ext, &mut result.warnings) {
                scan_structured_file(adapter, kind, &scope, &path, reader, env, result);
            }
        }
    }
}

// A tag nobody recognises is almost always a near-miss for one that
// exists — `tests` for `testing`. Silently dropping it leaves the author
// thinking the item is tagged when it is not, so the scan says so and names
// the vocabulary.
fn warn_unknown_tags(found: &files::FoundFile, result: &mut ScanResult) {
    let Some(message) = found.meta.unknown_warning() else {
        return;
    };
    // One file read through two tools' folders is one mistake, not two: the
    // paths differ (each tool links to the shared folder its own way) and
    // the complaint is identical, so it is said once.
    let warning = format!("{}: {message}", found.path.display());
    if !result.warnings.contains(&warning) {
        result.warnings.push(warning);
    }
}

#[allow(clippy::too_many_arguments)]
fn scan_structured_file(
    adapter: &dyn HarnessAdapter,
    kind: ItemKind,
    scope: &Scope,
    path: &std::path::Path,
    reader: &crate::harness::Reader,
    env: &Env,
    result: &mut ScanResult,
) {
    match readers::read_structured(path, reader, env) {
        Ok(entries) => {
            for entry in entries {
                // An entry that resolved to its own directory has an mtime
                // that describes only itself. One that did not lives inside
                // a config file shared with every other entry of its kind,
                // whose mtime would describe all of them at once.
                let modified_at = entry.source_path.as_deref().and_then(files::mtime_unix);
                let vendor =
                    crate::vendor::vendor_of(kind, &entry.name, adapter.id()).map(str::to_owned);
                result.items.push(ObservedItem {
                    kind,
                    name: entry.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    file_state: match entry.source_path {
                        Some(_) => FileState::Dir,
                        None => FileState::ConfigEntry,
                    },
                    path: entry.source_path.unwrap_or_else(|| path.to_path_buf()),
                    enabled: entry.enabled,
                    origin: None,
                    // Nothing to read: a structured reader hands back an
                    // entry, not a document, and the entry's own files (a
                    // plugin's directory) are not in a format with a header.
                    tags: Vec::new(),
                    description: entry.description,
                    modified_at,
                    vendor,
                });
            }
        }
        Err(message) => result
            .warnings
            .push(format!("{}: {message}", path.display())),
    }
}

#[cfg(test)]
mod tests;
