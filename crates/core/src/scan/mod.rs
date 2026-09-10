use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::harness::{HarnessAdapter, Surface, all_adapters};
use crate::model::{DetectedHarness, FileState, HarnessId, ItemKind, ObservedItem, Scope};
use crate::settings::AppSettings;

pub use standing::WarningStanding;

pub(crate) mod antigravity;
pub(crate) mod copilot;
mod files;
pub(crate) mod hooks;
pub(crate) mod jsonc;
pub mod metadata;
mod pi_packages;
mod plugins;
mod provenance;
mod readers;
mod standing;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub harnesses: Vec<DetectedHarness>,
    pub items: Vec<ObservedItem>,
    /// Registered projects whose directory the scan could not read as one
    /// — flagged, never dropped.
    pub missing_projects: Vec<MissingProject>,
    /// The registered project folders this scan opened.
    ///
    /// Positive evidence, because absence from `missing_projects` is not
    /// evidence at all: a path this scan never met — a project registered
    /// since it ran — is missing from that list exactly as a folder that
    /// was read is. Whether a place may be written to rests on this, and
    /// nothing may rest on a silence.
    pub read_projects: Vec<PathBuf>,
    /// Unreadable or unparsable surfaces; truth the scan could not reach.
    pub warnings: Vec<ScanWarning>,
}

/// A registered project the scan could not read at its recorded path,
/// with what stood in the way. A folder that is gone and a folder the
/// account may not read are one empty reading and two different remedies:
/// one is reconnected to where it moved, the other is read again once the
/// machine can reach it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MissingProject {
    pub root: PathBuf,
    pub why: MissingWhy,
}

/// Why a recorded project path is not a folder this scan can read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum MissingWhy {
    /// Nothing is at the path.
    Gone,
    /// Something is at the path and it is not a folder.
    NotAFolder,
    /// The path could not be read at all, in the words the system gave —
    /// a permission the account lacks, a mount that is not there. Not a
    /// claim that the project is gone, which is what a reading of "no
    /// packages here" over one of these would be.
    Unreadable { said: String },
}

/// Why a registered project's folder cannot be read as one, or `None`
/// where it can. One judge for the whole product: the scan flags a place
/// with it, the CLI's project list prints it, and the app's card offers
/// the recovery it names.
pub fn missing_why(root: &Path) -> Option<MissingWhy> {
    match std::fs::metadata(root) {
        Ok(found) if found.is_dir() => opens(root),
        Ok(_) => Some(MissingWhy::NotAFolder),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(MissingWhy::Gone),
        Err(e) => Some(MissingWhy::Unreadable {
            said: e.to_string(),
        }),
    }
}

/// Whether the directory can be read, asked by reading it.
///
/// A stat is not a read. A directory the account may not open still
/// answers `metadata` — a mode or an ACL that denies it binds the open,
/// not the stat — so a scan that stopped at the stat would go on to read
/// nothing out of the place and report it as a project holding nothing.
/// The answer everything here rests on is "kendex read this folder", and
/// only opening it establishes that.
fn opens(root: &Path) -> Option<MissingWhy> {
    match std::fs::read_dir(root) {
        Ok(_) => None,
        Err(e) => Some(MissingWhy::Unreadable {
            said: e.to_string(),
        }),
    }
}

/// One surface the scan could not read as the document it expects, with
/// the tool and kind the surface belongs to: a reader deciding what to do
/// about a broken file needs to know whose file it is, and the path alone
/// says that only to someone who already knows every tool's layout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ScanWarning {
    pub harness: HarnessId,
    pub kind: ItemKind,
    pub path: PathBuf,
    pub problem: ScanProblem,
    /// Whether the reader has to do anything about it. Every warning
    /// leaves the surface that raised it actionable; only
    /// [`standing::classify`], with the whole machine read, takes that
    /// away, and only on evidence that nothing is missing.
    pub standing: WarningStanding,
}

/// What kept a surface from being read, by shape rather than by parser
/// message: an empty file and a file with a stray comma are one parser
/// error and two different remedies.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum ScanProblem {
    /// A document was expected and the file holds nothing: zero bytes,
    /// whitespace, or comments alone. Another tool leaves such a file
    /// behind when it creates its config before writing to it.
    EmptyFile,
    /// The text is not the format the surface reads; the parser's own
    /// message says where it stopped.
    InvalidJson {
        message: String,
    },
    InvalidToml {
        message: String,
    },
    /// A directory or file the scan could not read at all.
    Unreadable {
        message: String,
    },
    /// A word in a document's tags that names no tag.
    UnknownTag {
        message: String,
    },
}

impl std::fmt::Display for ScanProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScanProblem::EmptyFile => f.write_str("the file is empty"),
            ScanProblem::InvalidJson { message } => write!(f, "not valid JSON: {message}"),
            ScanProblem::InvalidToml { message } => write!(f, "not valid TOML: {message}"),
            ScanProblem::Unreadable { message } => write!(f, "unreadable — {message}"),
            ScanProblem::UnknownTag { message } => f.write_str(message),
        }
    }
}

impl std::fmt::Display for ScanWarning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} {} {}: {}",
            self.harness.display_name(),
            self.kind.name(),
            self.path.display(),
            self.problem
        )
    }
}

/// Say a warning once per file. Several surfaces read one file — Claude's
/// settings.json is a hook surface and a plugin surface, `~/.claude.json`
/// is the MCP surface of the personal scope and of every project, and a
/// skill under `.agents/skills` is read again through each tool's link to
/// it — and a file that cannot be read fails every one of them the same
/// way. The first surface to say so names the file, under the spelling it
/// read; a second saying of the same file and problem is the same fact,
/// and dropped. Files are the same when they resolve to one place, so a
/// link and its target count once; a path that cannot be resolved is
/// compared as spelled.
pub(crate) fn push_warning(warnings: &mut Vec<ScanWarning>, warning: ScanWarning) {
    let file = resolved(&warning.path);
    let said = warnings
        .iter()
        .any(|known| known.problem == warning.problem && resolved(&known.path) == file);
    if !said {
        warnings.push(warning);
    }
}

/// One spelling for one file: a link and its target are the same file, and
/// a path nothing can resolve is compared as spelled (invariant 17).
fn resolved(path: &std::path::Path) -> PathBuf {
    crate::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf())
}

/// The tool and kind a surface is scanned for, stamped on every warning
/// the surface's files raise.
#[derive(Debug, Clone, Copy)]
pub(crate) struct SurfaceOwner {
    pub(crate) harness: HarnessId,
    pub(crate) kind: ItemKind,
}

impl SurfaceOwner {
    pub(crate) fn warning(self, path: PathBuf, problem: ScanProblem) -> ScanWarning {
        ScanWarning {
            harness: self.harness,
            kind: self.kind,
            path,
            problem,
            standing: WarningStanding::Actionable,
        }
    }
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
    let mut pass = Pass::default();
    let mut provenance = provenance::OriginCache::default();

    for scope in scopes {
        scan_scope(
            env,
            harness_roots,
            scope,
            &ItemKind::ALL,
            &mut provenance,
            &mut pass,
        );
    }

    standing::classify(env, &pass.containers, &mut pass.result.warnings);
    pass.result
}

/// What one scan accumulates. The result is what leaves; the containers are
/// what deciding a warning's standing needs and no reader of the result
/// does — which surfaces read one file, and at which scopes.
#[derive(Default)]
struct Pass {
    result: ScanResult,
    containers: standing::Containers,
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
    let mut pass = Pass::default();
    let mut provenance = provenance::OriginCache::default();
    scan_scope(
        env,
        harness_roots,
        scope,
        &[kind],
        &mut provenance,
        &mut pass,
    );
    // No standing pass: this answers about one installation and drops the
    // warnings, so nothing here reads a standing.
    pass.result.items.into_iter().find(|item| item.name == name)
}

fn scan_scope(
    env: &Env,
    harness_roots: &std::collections::BTreeMap<String, PathBuf>,
    scope: &Scope,
    kinds: &[ItemKind],
    provenance: &mut provenance::OriginCache,
    pass: &mut Pass,
) {
    match scope {
        Scope::Global => {
            for adapter in all_adapters() {
                let root = harness_roots
                    .get(adapter.id().name())
                    .cloned()
                    .unwrap_or_else(|| adapter.default_global_root(env));
                if let Some(found) = adapter.detect(env, &root) {
                    pass.result.harnesses.push(found);
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
                            pass,
                        );
                    }
                }
            }
        }
        Scope::Project { root: project } => {
            match missing_why(project) {
                Some(why) => {
                    pass.result.missing_projects.push(MissingProject {
                        root: project.clone(),
                        why,
                    });
                    return;
                }
                None => pass.result.read_projects.push(project.clone()),
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
                            pass,
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
    pass: &mut Pass,
) {
    let owner = SurfaceOwner {
        harness: adapter.id(),
        kind,
    };
    match surface {
        Surface::FileDir {
            dir,
            exts,
            prefixes,
        } => {
            for found in files::scan_file_dir(dir, exts, prefixes, owner, &mut pass.result.warnings)
            {
                warn_unknown_tags(&found, owner, &mut pass.result.warnings);
                pass.result.items.push(ObservedItem {
                    kind,
                    name: found.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    file_state: files::state_of(&found.path),
                    origin: provenance.origin_of(&found.path),
                    at: crate::model::observed_at(
                        &found.path,
                        &files::state_of(&found.path),
                        found.meta.description.as_deref(),
                    ),
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
            for found in files::scan_subdirs(dir, marker, owner, &mut pass.result.warnings) {
                warn_unknown_tags(&found, owner, &mut pass.result.warnings);
                pass.result.items.push(ObservedItem {
                    kind,
                    name: found.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    file_state: files::state_of(&found.path),
                    origin: provenance.origin_of(&found.path),
                    at: crate::model::observed_at(
                        &found.path,
                        &files::state_of(&found.path),
                        found.meta.description.as_deref(),
                    ),
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
                scan_structured_file(adapter, owner, &scope, path, reader, env, pass);
            }
        }
        Surface::StructuredDir { dir, ext, reader } => {
            for path in files::scan_documents(dir, ext, owner, &mut pass.result.warnings) {
                scan_structured_file(adapter, owner, &scope, &path, reader, env, pass);
            }
        }
    }
}

// A tag nobody recognises is almost always a near-miss for one that
// exists — `tests` for `testing`. Silently dropping it leaves the author
// thinking the item is tagged when it is not, so the scan says so and names
// the vocabulary.

fn warn_unknown_tags(
    found: &files::FoundFile,
    owner: SurfaceOwner,
    warnings: &mut Vec<ScanWarning>,
) {
    let Some(message) = found.meta.unknown_warning() else {
        return;
    };
    push_warning(
        warnings,
        owner.warning(found.path.clone(), ScanProblem::UnknownTag { message }),
    );
}

fn scan_structured_file(
    adapter: &dyn HarnessAdapter,
    owner: SurfaceOwner,
    scope: &Scope,
    path: &std::path::Path,
    reader: &crate::harness::Reader,
    env: &Env,
    pass: &mut Pass,
) {
    let kind = owner.kind;
    pass.containers
        .read(resolved(path), owner.harness, kind, scope);
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
                let file_state = match entry.source_path {
                    Some(_) => FileState::Dir,
                    None => FileState::ConfigEntry,
                };
                let at_path = entry.source_path.unwrap_or_else(|| path.to_path_buf());
                pass.result.items.push(ObservedItem {
                    kind,
                    name: entry.name,
                    harness: adapter.id(),
                    scope: scope.clone(),
                    at: crate::model::observed_at(
                        &at_path,
                        &file_state,
                        entry.description.as_deref(),
                    ),
                    file_state,
                    path: at_path,
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
        Err(problem) => push_warning(
            &mut pass.result.warnings,
            owner.warning(path.to_path_buf(), problem),
        ),
    }
}

// What a structured reader hands back for one entry it found in a file.

/// One parsed entry from a structured surface, before it becomes an
/// `ObservedItem`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawEntry {
    pub name: String,
    pub enabled: Option<bool>,
    pub description: Option<String>,
    /// Where this entry's own files live, when the reader knows and that is
    /// somewhere other than the file it was read from. A plugin cache lists
    /// every plugin in one place but each one has a directory of its own,
    /// and scoring a plugin against its neighbours' files is not scoring
    /// that plugin. `None` for entries that really do only exist as a line
    /// in a config file.
    pub source_path: Option<PathBuf>,
}

#[cfg(test)]
mod tests;
