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

/// The item paths a kind's configured roots expand to, and whether any of
/// those roots exists at all.
#[derive(Debug)]
struct ExpandedRoots {
    paths: Vec<PathBuf>,
    /// A configured root is present. A glob whose parent directory exists
    /// counts: it is a readable root that currently matches nothing, which is
    /// evidence the source ships no such item — not evidence the layout moved.
    root_present: bool,
}

fn expand_configured_paths(
    source_root: &Path,
    kind: CatalogKind,
    catalog: &crate::mapping::CatalogConfig,
) -> Result<ExpandedRoots> {
    let mut out = ExpandedRoots {
        paths: Vec::new(),
        root_present: false,
    };
    let mut seen = HashSet::new();
    for raw in catalog.paths_for(kind) {
        let expanded = expand_catalog_entry(source_root, &raw)?;
        out.root_present |= expanded.root_present;
        for path in expanded.paths {
            let key = normalize_lexical(&path);
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
        let root_present = path.exists();
        return Ok(ExpandedRoots {
            paths: vec![path],
            root_present,
        });
    }

    let parent_rel: PathBuf = parts[..parts.len() - 1].iter().collect();
    let parent = source_root.join(parent_rel);
    if !parent.exists() {
        return Ok(ExpandedRoots {
            paths: Vec::new(),
            root_present: false,
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
        root_present: true,
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

fn normalize_lexical(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
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
/// about, and every candidate path is kept so a caller can tell "the item's
/// files are gone" from "the item's files are there but unparseable".
#[derive(Debug, Default, Clone)]
pub(crate) struct Inventory {
    /// Parsed item names, deduplicated, sorted.
    pub names: Vec<String>,
    /// `path: reason` for every candidate that failed to parse.
    pub failures: Vec<String>,
    /// Every candidate item path (file for agents/hooks, directory for the
    /// packaged kinds), parseable or not.
    pub candidates: Vec<PathBuf>,
}

impl Inventory {
    /// True when this item may still have a physical footprint in the source,
    /// so "removed upstream" is not proven.
    ///
    /// Two independent ways it can be present without appearing in
    /// [`names`](Self::names):
    ///
    /// 1. a candidate path named after it whose manifest no longer parses —
    ///    the name is unknown but the files are right there;
    /// 2. ANY unparseable candidate, because a directory need not be named
    ///    after the item it declares (`pi-extensions/pi-hooks` ships
    ///    `@vanillagreen/pi-hooks`), so an unreadable manifest could be this
    ///    item's under a directory name that matches nothing.
    ///
    /// Each clause is load-bearing on its own; the tests exercise them
    /// separately so neither can quietly stop mattering.
    pub fn may_still_be_present(&self, name: &str) -> bool {
        self.has_unreadable_candidate() || self.has_candidate_named(name)
    }

    /// Clause 2: discovery of this kind was incomplete.
    pub fn has_unreadable_candidate(&self) -> bool {
        !self.failures.is_empty()
    }

    /// Clause 1: a candidate path carries this item's name. Directories are
    /// never named with the npm scope, so a scoped package name compares on
    /// its last component.
    pub fn has_candidate_named(&self, name: &str) -> bool {
        let basename = name.rsplit('/').next().unwrap_or(name);
        !basename.is_empty()
            && self.candidates.iter().any(|path| {
                path.file_stem()
                    .and_then(|stem| stem.to_str())
                    .is_some_and(|stem| stem == basename)
                    || path
                        .file_name()
                        .and_then(|file| file.to_str())
                        .is_some_and(|file| file == basename)
            })
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
    if !roots.root_present {
        return KindInventory::MissingRoot;
    }
    let mut inv = Inventory::default();
    let mut record = |path: PathBuf, parsed: Result<String>| {
        match parsed {
            Ok(name) => {
                if !inv.names.contains(&name) {
                    inv.names.push(name);
                }
            }
            Err(err) => inv.failures.push(format!("{}: {err:#}", path.display())),
        }
        inv.candidates.push(path);
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
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sandbox(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "vstack-catalog-{label}-{}-{nanos}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn custom_catalog_roots_discover_each_item_kind() {
        let root = sandbox("custom-roots");
        fs::write(
            root.join("vstack.toml"),
            r#"[catalog]
agents = ["pkgs/agent-defs"]
skills = ["pkgs/skill-*", "single/custom-skill"]
hooks = ["pkgs/hook-defs"]
pi_extensions = ["apps/pi-*"]
extras = ["theme-packs"]
"#,
        )
        .unwrap();

        fs::create_dir_all(root.join("pkgs/agent-defs")).unwrap();
        fs::write(
            root.join("pkgs/agent-defs/rust.md"),
            "---\nname: rust\ndescription: Rust\nrole: engineer\n---\n# Rust\n",
        )
        .unwrap();

        fs::create_dir_all(root.join("pkgs/skill-demo")).unwrap();
        fs::write(
            root.join("pkgs/skill-demo/SKILL.md"),
            "---\nname: demo\ndescription: Demo\n---\n# Demo\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("single/custom-skill")).unwrap();
        fs::write(
            root.join("single/custom-skill/SKILL.md"),
            "---\nname: custom\ndescription: Custom\n---\n# Custom\n",
        )
        .unwrap();

        fs::create_dir_all(root.join("pkgs/hook-defs")).unwrap();
        fs::write(
            root.join("pkgs/hook-defs/guard.sh"),
            "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: Guard\n# ---\n",
        )
        .unwrap();

        fs::create_dir_all(root.join("apps/pi-demo")).unwrap();
        fs::write(
            root.join("apps/pi-demo/package.json"),
            "{\"name\":\"@example/pi-demo\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[]}}\n",
        )
        .unwrap();

        fs::create_dir_all(root.join("theme-packs/method")).unwrap();
        fs::write(
            root.join("theme-packs/method/extra.toml"),
            "name = \"method\"\nkind = \"theme-pack\"\ndescription = \"Theme\"\ndefault-theme = \"dark\"\n",
        )
        .unwrap();

        assert_eq!(discover_agents(&root).unwrap()[0].name, "rust");
        let skills: Vec<String> = discover_skills(&root)
            .unwrap()
            .into_iter()
            .map(|skill| skill.name)
            .collect();
        assert_eq!(skills, vec!["custom".to_string(), "demo".to_string()]);
        assert_eq!(discover_hooks(&root).unwrap()[0].name, "guard");
        assert_eq!(
            discover_pi_extensions(&root).unwrap()[0].name,
            "@example/pi-demo"
        );
        assert_eq!(discover_extras(&root).unwrap()[0].name(), "method");

        let _ = fs::remove_dir_all(root);
    }

    fn skill_at(root: &Path, rel: &str, name: &str) {
        fs::create_dir_all(root.join(rel)).unwrap();
        fs::write(
            root.join(rel).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: {name}\n---\nbody\n"),
        )
        .unwrap();
    }

    fn inv(root: &Path, catalog: &crate::mapping::CatalogConfig) -> KindInventory {
        inventory(root, crate::config::ItemKind::Skill, catalog)
    }

    #[test]
    fn kind_states_separate_readable_empty_from_missing_root_and_error() {
        let root = sandbox("kind-states");
        let default_catalog = crate::mapping::CatalogConfig::default();

        // No `skills/` at all: the layout moved, nothing can be concluded.
        assert!(matches!(
            inv(&root, &default_catalog),
            KindInventory::MissingRoot
        ));

        // The root exists but is empty: that is POSITIVE evidence the source
        // ships no skills — the last one really was removed.
        fs::create_dir_all(root.join("skills")).unwrap();
        let empty = inv(&root, &default_catalog);
        assert!(matches!(&empty, KindInventory::Readable(inv) if inv.names.is_empty()));
        assert!(
            !empty.readable().unwrap().may_still_be_present("gone"),
            "an empty readable root proves absence"
        );

        // A zero-match glob whose PARENT exists is the same story: readable,
        // currently shipping nothing.
        let globbed = crate::mapping::CatalogConfig {
            skills: Some(vec!["pkgs/skill-*".into()]),
            ..Default::default()
        };
        fs::create_dir_all(root.join("pkgs")).unwrap();
        assert!(matches!(
            inv(&root, &globbed),
            KindInventory::Readable(inv) if inv.names.is_empty()
        ));
        // Control: the same glob with no parent directory is a missing root.
        let elsewhere = crate::mapping::CatalogConfig {
            skills: Some(vec!["nowhere/skill-*".into()]),
            ..Default::default()
        };
        assert!(matches!(inv(&root, &elsewhere), KindInventory::MissingRoot));

        // A configuration that cannot be expanded at all is an error, never a
        // silent empty inventory.
        let bad = crate::mapping::CatalogConfig {
            skills: Some(vec!["../escape".into()]),
            ..Default::default()
        };
        assert!(matches!(inv(&root, &bad), KindInventory::Error(_)));
        assert!(
            inv(&root, &bad)
                .unverifiable(crate::config::ItemKind::Skill)
                .is_some()
        );
        assert!(
            inv(&root, &globbed)
                .unverifiable(crate::config::ItemKind::Skill)
                .is_none(),
            "a readable kind is verifiable"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn each_may_still_be_present_clause_is_load_bearing_on_its_own() {
        let root = sandbox("presence-clauses");
        // Clause 1 alone: a candidate directory named after the item, whose
        // manifest parses fine under a DIFFERENT name (so `names` cannot be
        // what saves it) and no failures anywhere.
        skill_at(&root, "skills/alpha", "renamed-alpha");
        let catalog = crate::mapping::CatalogConfig::default();
        let inventory = inv(&root, &catalog);
        let readable = inventory.readable().unwrap();
        assert!(readable.failures.is_empty(), "clause 2 must not apply");
        assert!(
            readable.has_candidate_named("alpha"),
            "clause 1 must carry this case"
        );
        assert!(readable.may_still_be_present("alpha"));

        // Clause 2 alone: an unparseable candidate whose directory name
        // matches NOTHING the lock names, so only "discovery was incomplete"
        // can save the entry.
        let root = sandbox("presence-clause-2");
        skill_at(&root, "skills/keeper", "keeper");
        fs::create_dir_all(root.join("skills").join("mystery")).unwrap();
        fs::write(root.join("skills/mystery/SKILL.md"), "no frontmatter\n").unwrap();
        let inventory = inv(&root, &catalog);
        let readable = inventory.readable().unwrap();
        assert!(
            !readable.has_candidate_named("@scope/pkg"),
            "clause 1 must not apply"
        );
        assert!(
            readable.has_unreadable_candidate(),
            "clause 2 must carry this case"
        );
        assert!(readable.may_still_be_present("@scope/pkg"));

        // And the same name IS provably absent once discovery is clean and no
        // directory matches.
        fs::remove_dir_all(root.join("skills").join("mystery")).unwrap();
        let inventory = inv(&root, &catalog);
        assert!(
            !inventory
                .readable()
                .unwrap()
                .may_still_be_present("@scope/pkg")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn glob_is_restricted_to_last_segment() {
        let root = sandbox("bad-glob");
        let err = expand_catalog_entry(&root, "*/skills").unwrap_err();
        assert!(
            err.to_string()
                .contains("only supported on the last path segment")
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn wildcard_match_backtracks_to_later_suffix() {
        assert!(wildcard_match("*a", "aa"));
        assert!(wildcard_match("a*a", "ababa"));
        assert!(wildcard_match("pi-*-hooks", "pi-hooks-hooks"));
        assert!(!wildcard_match("a*b", "a"));
    }
}
