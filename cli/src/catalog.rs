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
    // A candidate directory nobody can read yields neither a name nor a parse
    // failure, so it would look like an item that is simply gone — and the
    // entry would be reported "removed upstream" while its files sit right
    // there behind a permission bit.
    for unreadable in unreadable_candidate_dirs(&roots.paths) {
        inv.failures
            .push(format!("{}: permission denied", unreadable.display()));
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
            empty.readable().unwrap().names_are_complete(),
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
    fn a_directory_that_parsed_under_a_new_name_does_not_shelter_the_old_one() {
        // A skill renamed in its own SKILL.md while the directory keeps the
        // old basename. The old name is GONE — refresh is keyed on the
        // declared name and could never find it again — so a directory that
        // parsed cleanly must not answer for a name it does not declare.
        let root = sandbox("renamed-in-manifest");
        skill_at(&root, "skills/alpha", "renamed-alpha");
        let catalog = crate::mapping::CatalogConfig::default();
        let inventory = inv(&root, &catalog);
        let readable = inventory.readable().unwrap();
        assert_eq!(readable.names, vec!["renamed-alpha".to_string()]);
        assert!(
            readable.names_are_complete(),
            "a clean parse leaves nothing unaccounted for, so `alpha` is removed"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_unparseable_candidate_shelters_every_name_of_its_kind() {
        // A directory need not be named after the item it declares, so an
        // unparseable manifest could be ANY locked item's — including one
        // whose directory name matches nothing.
        let root = sandbox("unparseable-candidate");
        let catalog = crate::mapping::CatalogConfig::default();
        skill_at(&root, "skills/keeper", "keeper");
        fs::create_dir_all(root.join("skills").join("mystery")).unwrap();
        fs::write(root.join("skills/mystery/SKILL.md"), "no frontmatter\n").unwrap();
        let inventory = inv(&root, &catalog);
        let readable = inventory.readable().unwrap();
        assert!(
            !readable.names_are_complete(),
            "an unparseable candidate makes the name list incomplete"
        );

        // A candidate named after the locked item behaves the same way — it is
        // the parse failure, not the name, that carries the evidence.
        fs::remove_dir_all(root.join("skills").join("mystery")).unwrap();
        fs::create_dir_all(root.join("skills").join("gone")).unwrap();
        fs::write(root.join("skills/gone/SKILL.md"), "no frontmatter\n").unwrap();
        assert!(
            !inv(&root, &catalog)
                .readable()
                .unwrap()
                .names_are_complete()
        );

        // Control: once discovery is clean, absence is provable again.
        fs::remove_dir_all(root.join("skills").join("gone")).unwrap();
        assert!(
            inv(&root, &catalog)
                .readable()
                .unwrap()
                .names_are_complete()
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn one_missing_configured_root_makes_the_whole_kind_unverifiable() {
        // Two configured roots, one gone: the readable one cannot vouch for
        // the items the missing one used to supply, so the kind is a layout
        // problem to inspect — never a list of removals to run.
        let root = sandbox("partial-roots");
        let two_roots = crate::mapping::CatalogConfig {
            skills: Some(vec!["skills".into(), "packages/skills".into()]),
            ..Default::default()
        };
        skill_at(&root, "skills/keeper", "keeper");
        assert!(matches!(inv(&root, &two_roots), KindInventory::MissingRoot));

        // Control: with both roots present the kind is readable as before.
        skill_at(&root, "packages/skills/extra", "extra");
        assert!(matches!(
            inv(&root, &two_roots),
            KindInventory::Readable(inv) if inv.names == ["extra".to_string(), "keeper".to_string()]
        ));

        // Control: a single configured root that is missing is unchanged.
        let one_missing = crate::mapping::CatalogConfig {
            skills: Some(vec!["nowhere".into()]),
            ..Default::default()
        };
        assert!(matches!(
            inv(&root, &one_missing),
            KindInventory::MissingRoot
        ));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_explicitly_empty_catalog_list_is_a_readable_empty_kind() {
        // `skills = []` is positive evidence the source ships no skills, so a
        // lock entry against it is removed upstream — unlike an ABSENT key,
        // which expands to `skills/` and is a missing root when that is gone.
        let root = sandbox("empty-catalog-list");
        let declared_empty = crate::mapping::CatalogConfig {
            skills: Some(Vec::new()),
            ..Default::default()
        };
        assert!(matches!(
            inv(&root, &declared_empty),
            KindInventory::Readable(inv) if inv.names.is_empty()
        ));
        assert!(
            inv(&root, &declared_empty)
                .readable()
                .unwrap()
                .names_are_complete(),
            "an explicitly empty list proves absence"
        );

        // Control: the absent key is still a missing root.
        assert!(matches!(
            inv(&root, &crate::mapping::CatalogConfig::default()),
            KindInventory::MissingRoot
        ));

        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn an_unreadable_item_directory_is_a_discovery_failure_not_a_removal() {
        use std::os::unix::fs::PermissionsExt;
        // SAFETY: `geteuid` reads the calling process's effective uid; it
        // takes no arguments and cannot fail.
        if unsafe { libc::geteuid() } == 0 {
            return; // root ignores the permission bits this test relies on
        }
        let root = sandbox("unreadable-dir");
        skill_at(&root, "skills/keeper", "keeper");
        let locked_dir = root.join("skills").join("secret");
        fs::create_dir_all(&locked_dir).unwrap();
        fs::write(locked_dir.join("SKILL.md"), "---\nname: secret\n---\n").unwrap();
        fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o000)).unwrap();

        let catalog = crate::mapping::CatalogConfig::default();
        let inventory = inv(&root, &catalog);
        let readable = inventory.readable().expect("the ROOT is readable");
        fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o700)).unwrap();

        assert!(
            !readable.names_are_complete(),
            "files behind a permission bit are still files: {readable:?}"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_package_renamed_in_its_manifest_is_removed_under_its_old_name() {
        // The lock names `@vg/pi-hooks` and the directory is still
        // `pi-hooks`, but its manifest now declares a different package. The
        // directory name is not evidence: `vstack refresh` resolves the locked
        // name against declared names and would never find this package again.
        let root = sandbox("renamed-package");
        let dir = root.join("pi-extensions").join("pi-hooks");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("package.json"),
            "{\"name\":\"@vg/pi-hooks-renamed\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{\"extensions\":[]}}",
        )
        .unwrap();
        let catalog = crate::mapping::CatalogConfig::default();
        let inventory = inventory(&root, crate::config::ItemKind::PiExtension, &catalog);
        let readable = inventory.readable().expect("root exists and was read");
        assert_eq!(readable.names, vec!["@vg/pi-hooks-renamed".to_string()]);
        assert!(
            readable.names_are_complete(),
            "the manifest parsed, so the declared name is the whole truth"
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
