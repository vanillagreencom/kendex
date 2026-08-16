use crate::agent::Agent;
use crate::extra::Extra;
use crate::hook::Hook;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CatalogKind {
    Agents,
    Skills,
    Hooks,
    PiExtensions,
    Extras,
}

impl CatalogKind {
    pub fn default_paths(self) -> &'static [&'static str] {
        match self {
            Self::Agents => &["agents"],
            Self::Skills => &["skills"],
            Self::Hooks => &["hooks"],
            Self::PiExtensions => &["pi-extensions"],
            Self::Extras => &["extras"],
        }
    }
}

pub(crate) fn has_catalog_table(source_root: &Path) -> bool {
    let Ok(raw) = std::fs::read_to_string(source_root.join("vstack.toml")) else {
        return false;
    };
    let Ok(parsed) = raw.parse::<toml::Value>() else {
        return false;
    };
    parsed
        .get("catalog")
        .and_then(|value| value.as_table())
        .is_some()
}

/// The item paths a kind's configured roots expand to, and whether EVERY one
/// of those roots exists.
#[derive(Debug)]
struct ExpandedRoots {
    paths: Vec<PathBuf>,
    /// Every configured root is present. A glob whose parent directory exists
    /// counts: it is a readable root that currently matches nothing, which is
    /// evidence the source ships no such item — not evidence the layout moved.
    ///
    /// This is an AND, never an OR: one readable root cannot vouch for a
    /// sibling that is missing, or the items the missing root used to supply
    /// would classify as removed upstream and `check` would tell the user to
    /// uninstall a still-valid install. A missing root instead makes the kind
    /// [`KindInventory::MissingRoot`] — "inspect the source layout", which is
    /// the safe direction to be wrong in.
    ///
    /// An explicitly empty `[catalog]` list has no roots to check and so is
    /// vacuously present: an empty list is positive evidence the source ships
    /// no items of that kind. An ABSENT key is not empty — it expands to the
    /// kind's default root and fails this test when that root is gone.
    all_roots_present: bool,
}

fn expand_configured_paths(
    source_root: &Path,
    kind: CatalogKind,
    catalog: &crate::mapping::CatalogConfig,
) -> Result<ExpandedRoots> {
    let mut out = ExpandedRoots {
        paths: Vec::new(),
        all_roots_present: true,
    };
    let mut seen = HashSet::new();
    for raw in catalog.paths_for(kind) {
        let expanded = expand_catalog_entry(source_root, &raw)?;
        out.all_roots_present &= expanded.all_roots_present;
        for path in expanded.paths {
            let key = crate::config::normalize_path_lexical(&path);
            if seen.insert(key) {
                out.paths.push(path);
            }
        }
    }
    Ok(out)
}

/// The forgiving path for the `discover_*` family, which is used by install
/// paths that must not fail over a mapping table.
fn expand_paths_forgiving(source_root: &Path, kind: CatalogKind) -> Result<Vec<PathBuf>> {
    Ok(expand_configured_paths(
        source_root,
        kind,
        &crate::mapping::MappingConfig::load(source_root).catalog,
    )?
    .paths)
}

fn expand_catalog_entry(source_root: &Path, raw: &str) -> Result<ExpandedRoots> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        anyhow::bail!("catalog path must not be empty");
    }

    let rel = Path::new(trimmed);
    if rel.is_absolute() {
        anyhow::bail!("catalog path must be relative to the source root: {trimmed}");
    }

    let mut parts: Vec<String> = Vec::new();
    for component in rel.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
            Component::ParentDir | Component::Prefix(_) | Component::RootDir => {
                anyhow::bail!("catalog path must stay inside the source root: {trimmed}");
            }
        }
    }
    if parts.is_empty() {
        anyhow::bail!("catalog path must name a file or directory: {trimmed}");
    }
    if parts[..parts.len().saturating_sub(1)]
        .iter()
        .any(|part| part.contains('*'))
    {
        anyhow::bail!("catalog glob is only supported on the last path segment: {trimmed}");
    }

    let last = parts.last().expect("non-empty parts");
    if !last.contains('*') {
        let path = source_root.join(parts.iter().collect::<PathBuf>());
        let all_roots_present = path.exists();
        return Ok(ExpandedRoots {
            paths: vec![path],
            all_roots_present,
        });
    }

    let parent_rel: PathBuf = parts[..parts.len() - 1].iter().collect();
    let parent = source_root.join(parent_rel);
    if !parent.exists() {
        return Ok(ExpandedRoots {
            paths: Vec::new(),
            all_roots_present: false,
        });
    }
    let mut matches = Vec::new();
    for entry in std::fs::read_dir(&parent)
        .with_context(|| format!("reading catalog glob parent {}", parent.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if wildcard_match(last, name) {
            matches.push(path);
        }
    }
    matches.sort();
    Ok(ExpandedRoots {
        paths: matches,
        all_roots_present: true,
    })
}

fn wildcard_match(pattern: &str, candidate: &str) -> bool {
    let pattern = pattern.as_bytes();
    let candidate = candidate.as_bytes();
    let mut pattern_index = 0;
    let mut candidate_index = 0;
    let mut star_index = None;
    let mut star_match_index = 0;

    while candidate_index < candidate.len() {
        if pattern_index < pattern.len()
            && pattern[pattern_index] != b'*'
            && pattern[pattern_index] == candidate[candidate_index]
        {
            pattern_index += 1;
            candidate_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            star_index = Some(pattern_index);
            pattern_index += 1;
            star_match_index = candidate_index;
        } else if let Some(index) = star_index {
            pattern_index = index + 1;
            star_match_index += 1;
            candidate_index = star_match_index;
        } else {
            return false;
        }
    }

    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }

    pattern_index == pattern.len()
}

fn discover_files(source_root: &Path, kind: CatalogKind, extension: &str) -> Result<Vec<PathBuf>> {
    discover_files_in(expand_paths_forgiving(source_root, kind)?, extension)
}

fn discover_files_in(roots: Vec<PathBuf>, extension: &str) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for candidate in roots {
        if !candidate.exists() {
            continue;
        }
        if candidate.is_file() {
            if candidate.extension().is_some_and(|ext| ext == extension) {
                files.push(candidate);
            }
            continue;
        }
        if !candidate.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&candidate)
            .with_context(|| format!("reading catalog directory {}", candidate.display()))?
        {
            let path = entry?.path();
            if path.is_file() && path.extension().is_some_and(|ext| ext == extension) {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}

fn discover_manifest_dirs(
    source_root: &Path,
    kind: CatalogKind,
    manifest: &str,
) -> Result<Vec<PathBuf>> {
    discover_manifest_dirs_in(expand_paths_forgiving(source_root, kind)?, manifest)
}

fn discover_manifest_dirs_in(roots: Vec<PathBuf>, manifest: &str) -> Result<Vec<PathBuf>> {
    let mut dirs = Vec::new();
    for candidate in roots {
        if !candidate.exists() || !candidate.is_dir() {
            continue;
        }
        if candidate.join(manifest).is_file() {
            dirs.push(candidate);
            continue;
        }
        for entry in std::fs::read_dir(&candidate)
            .with_context(|| format!("reading catalog directory {}", candidate.display()))?
        {
            let path = entry?.path();
            if path.is_dir() && path.join(manifest).is_file() {
                dirs.push(path);
            }
        }
    }
    dirs.sort();
    Ok(dirs)
}

pub(crate) fn discover_agents(source_root: &Path) -> Result<Vec<Agent>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for path in discover_files(source_root, CatalogKind::Agents, "md")? {
        match Agent::from_file(&path) {
            Ok(agent) if seen.insert(agent.name.clone()) => out.push(agent),
            Ok(agent) => eprintln!(
                "Warning: skipping duplicate agent {} from {}",
                agent.name,
                path.display()
            ),
            Err(err) => eprintln!("Warning: skipping {}: {err}", path.display()),
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub(crate) fn discover_skills(source_root: &Path) -> Result<Vec<Skill>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for dir in discover_manifest_dirs(source_root, CatalogKind::Skills, "SKILL.md")? {
        let skill_file = dir.join("SKILL.md");
        match Skill::from_file(&skill_file) {
            Ok(skill) if seen.insert(skill.name.clone()) => out.push(skill),
            Ok(skill) => eprintln!(
                "Warning: skipping duplicate skill {} from {}",
                skill.name,
                skill_file.display()
            ),
            Err(err) => eprintln!("Warning: skipping {}: {err}", skill_file.display()),
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub(crate) fn discover_hooks(source_root: &Path) -> Result<Vec<Hook>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for path in discover_files(source_root, CatalogKind::Hooks, "sh")? {
        match Hook::from_file(&path) {
            Ok(hook) if seen.insert(hook.name.clone()) => out.push(hook),
            Ok(hook) => eprintln!(
                "Warning: skipping duplicate hook {} from {}",
                hook.name,
                path.display()
            ),
            Err(err) => eprintln!("Warning: skipping hook {}: {err}", path.display()),
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub(crate) fn discover_pi_extensions(source_root: &Path) -> Result<Vec<PiExtension>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for dir in discover_manifest_dirs(source_root, CatalogKind::PiExtensions, "package.json")? {
        match PiExtension::from_dir(&dir) {
            Ok(ext) if seen.insert(ext.name.clone()) => out.push(ext),
            Ok(ext) => eprintln!(
                "Warning: skipping duplicate pi-package {} from {}",
                ext.name,
                dir.display()
            ),
            Err(err) => eprintln!("Warning: skipping {}: {err}", dir.display()),
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub(crate) fn discover_extras(source_root: &Path) -> Result<Vec<Extra>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for dir in discover_manifest_dirs(source_root, CatalogKind::Extras, "extra.toml")? {
        match Extra::from_dir(&dir) {
            Ok(extra) if seen.insert(extra.name().to_string()) => out.push(extra),
            Ok(extra) => eprintln!(
                "Warning: skipping duplicate extra {} from {}",
                extra.name(),
                dir.display()
            ),
            Err(err) => eprintln!("Warning: skipping {}: {err}", dir.display()),
        }
    }
    out.sort_by(|a, b| a.name().cmp(b.name()));
    Ok(out)
}

/// Name-only view of one item kind in a source, for callers that must not
/// print and must know when discovery was incomplete. Unlike the
/// `discover_*` functions, a parse failure is recorded rather than warned
/// about, so a caller can tell "the item's files are gone" from "the item's
/// files are there but unparseable".
#[derive(Debug, Default, Clone)]
pub(crate) struct Inventory {
    /// Parsed item names, deduplicated, sorted.
    pub names: Vec<String>,
    /// `path: reason` for every candidate whose manifest could not be parsed
    /// or whose directory could not be read.
    pub failures: Vec<String>,
}

impl Inventory {
    /// Every candidate parsed, so [`names`](Self::names) is the whole truth
    /// about what this kind ships — the precondition for calling anything
    /// absent from it removed upstream.
    ///
    /// The one way an item can be present without appearing in `names` is a
    /// candidate whose manifest never parsed, and that evidence cannot be
    /// keyed on the item's name: a directory need not be named after the item
    /// it declares (`pi-extensions/pi-hooks` ships `@vanillagreen/pi-hooks`),
    /// so ANY unparseable candidate could be this item's under a directory
    /// name matching nothing.
    ///
    /// A candidate that parsed cleanly already contributed its declared name
    /// and never answers for a different one — an item renamed in its own
    /// manifest really is gone under its old name, and a `refresh` keyed on
    /// that old name could never find it again.
    pub fn names_are_complete(&self) -> bool {
        self.failures.is_empty()
    }
}

/// What a source's configured roots for one kind actually yielded. The three
/// states answer three different questions, and conflating them is how a
/// deleted item reads as current or a moved layout reads as "run refresh".
#[derive(Debug, Clone)]
pub(crate) enum KindInventory {
    /// A configured root exists and was read. An EMPTY readable root is
    /// positive evidence: the source ships no item of this kind, so an entry
    /// recorded against it was removed upstream.
    Readable(Inventory),
    /// No configured root for this kind exists in the source. Discovery
    /// returned nothing because the layout moved, not because items were
    /// removed — and `refresh` cannot fix that.
    MissingRoot,
    /// A root exists but could not be read, or the catalog configuration is
    /// unusable. Nothing about this kind can be verified.
    Error(String),
}

impl KindInventory {
    pub fn readable(&self) -> Option<&Inventory> {
        match self {
            Self::Readable(inventory) => Some(inventory),
            _ => None,
        }
    }

    /// Why entries of this kind cannot be verified, if they cannot.
    pub fn unverifiable(&self, kind: crate::config::ItemKind) -> Option<String> {
        match self {
            Self::Readable(_) => None,
            Self::MissingRoot => Some(format!(
                "{}: no configured source directory exists",
                kind.label_plural()
            )),
            Self::Error(reason) => Some(format!("{}: {reason}", kind.label_plural())),
        }
    }
}

/// Discover `kind` in `source_root` without printing, against an
/// already-loaded catalog configuration — strictness is the caller's single
/// boundary and the config is parsed once per source, not once per kind.
pub(crate) fn inventory(
    source_root: &Path,
    kind: crate::config::ItemKind,
    catalog: &crate::mapping::CatalogConfig,
) -> KindInventory {
    use crate::config::ItemKind;
    let roots = match expand_configured_paths(source_root, catalog_kind_for(kind), catalog) {
        Ok(roots) => roots,
        Err(err) => return KindInventory::Error(format!("{err:#}")),
    };
    if !roots.all_roots_present {
        return KindInventory::MissingRoot;
    }
    let mut inv = Inventory::default();
    // Skills, Pi extensions and extras are DIRECTORIES under a root: one
    // nobody can read yields neither a name nor a parse failure, so it would
    // look like an item that is simply gone — and the entry would be reported
    // "removed upstream" while its files sit right there behind a permission
    // bit. Agents and hooks are files read from the root itself, so no
    // subdirectory of theirs can hide one, and probing them would turn an
    // unrelated protected directory into drift for a source that is whole.
    if candidates_are_directories(kind) {
        for unreadable in unreadable_candidate_dirs(&roots.paths) {
            inv.failures
                .push(format!("{}: permission denied", unreadable.display()));
        }
    }
    let mut record = |path: PathBuf, parsed: Result<String>| match parsed {
        Ok(name) => {
            if !inv.names.contains(&name) {
                inv.names.push(name);
            }
        }
        Err(err) => inv.failures.push(format!("{}: {err:#}", path.display())),
    };
    let discovered = match kind {
        ItemKind::Agent => discover_files_in(roots.paths, "md").map(|paths| {
            paths
                .into_iter()
                .map(|path| {
                    let parsed = Agent::from_file(&path).map(|a| a.name);
                    (path, parsed)
                })
                .collect::<Vec<_>>()
        }),
        ItemKind::Hook => discover_files_in(roots.paths, "sh").map(|paths| {
            paths
                .into_iter()
                .map(|path| {
                    let parsed = Hook::from_file(&path).map(|h| h.name);
                    (path, parsed)
                })
                .collect::<Vec<_>>()
        }),
        ItemKind::Skill => discover_manifest_dirs_in(roots.paths, "SKILL.md").map(|dirs| {
            dirs.into_iter()
                .map(|dir| {
                    let parsed = Skill::from_file(&dir.join("SKILL.md")).map(|s| s.name);
                    (dir, parsed)
                })
                .collect::<Vec<_>>()
        }),
        ItemKind::PiExtension => {
            discover_manifest_dirs_in(roots.paths, "package.json").map(|dirs| {
                dirs.into_iter()
                    .map(|dir| {
                        let parsed = PiExtension::from_dir(&dir).map(|e| e.name);
                        (dir, parsed)
                    })
                    .collect::<Vec<_>>()
            })
        }
        ItemKind::Extra => discover_manifest_dirs_in(roots.paths, "extra.toml").map(|dirs| {
            dirs.into_iter()
                .map(|dir| {
                    let parsed = Extra::from_dir(&dir).map(|e| e.name().to_string());
                    (dir, parsed)
                })
                .collect::<Vec<_>>()
        }),
    };
    let discovered = match discovered {
        Ok(discovered) => discovered,
        Err(err) => return KindInventory::Error(format!("{err:#}")),
    };
    for (path, parsed) in discovered {
        record(path, parsed);
    }
    inv.names.sort();
    KindInventory::Readable(inv)
}

/// Is an item of this kind a directory under its root, rather than a file
/// read from the root itself?
fn candidates_are_directories(kind: crate::config::ItemKind) -> bool {
    use crate::config::ItemKind;
    match kind {
        ItemKind::Skill | ItemKind::PiExtension | ItemKind::Extra => true,
        ItemKind::Agent | ItemKind::Hook => false,
    }
}

/// Candidate directories under `roots` that cannot be listed. Only a real
/// permission failure counts: a missing directory is absence, not a fault.
fn unreadable_candidate_dirs(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            if std::fs::read_dir(&path)
                .err()
                .is_some_and(|err| err.kind() == std::io::ErrorKind::PermissionDenied)
            {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn catalog_kind_for(kind: crate::config::ItemKind) -> CatalogKind {
    match kind {
        crate::config::ItemKind::Agent => CatalogKind::Agents,
        crate::config::ItemKind::Skill => CatalogKind::Skills,
        crate::config::ItemKind::Hook => CatalogKind::Hooks,
        crate::config::ItemKind::PiExtension => CatalogKind::PiExtensions,
        crate::config::ItemKind::Extra => CatalogKind::Extras,
    }
}

pub(crate) fn find_item_path(
    source_root: &Path,
    kind: crate::config::ItemKind,
    name: &str,
) -> Option<PathBuf> {
    match kind {
        crate::config::ItemKind::Agent => discover_agents(source_root)
            .ok()?
            .into_iter()
            .find(|agent| agent.name == name)
            .map(|agent| agent.source_path),
        crate::config::ItemKind::Skill => discover_skills(source_root)
            .ok()?
            .into_iter()
            .find(|skill| skill.name == name)
            .map(|skill| skill.source_dir),
        crate::config::ItemKind::Hook => discover_hooks(source_root)
            .ok()?
            .into_iter()
            .find(|hook| hook.name == name)
            .map(|hook| hook.source_path),
        crate::config::ItemKind::PiExtension => discover_pi_extensions(source_root)
            .ok()?
            .into_iter()
            .find(|ext| {
                ext.name == name || crate::pi_extension::legacy_names_for(&ext.name).contains(&name)
            })
            .map(|ext| ext.source_dir),
        crate::config::ItemKind::Extra => discover_extras(source_root)
            .ok()?
            .into_iter()
            .find(|extra| extra.name() == name)
            .map(|extra| extra.source_dir),
    }
}

pub(crate) fn find_source_root_for_item_path(item_path: &Path) -> Option<PathBuf> {
    let mut dir = if item_path.is_dir() {
        item_path.to_path_buf()
    } else {
        item_path.parent()?.to_path_buf()
    };
    loop {
        if crate::resolve::is_vstack_source(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

#[cfg(test)]
mod tests;
