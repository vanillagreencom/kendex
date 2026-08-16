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

fn configured_paths(source_root: &Path, kind: CatalogKind) -> Vec<String> {
    crate::mapping::MappingConfig::load(source_root)
        .catalog
        .paths_for(kind)
}

fn expand_configured_paths(source_root: &Path, kind: CatalogKind) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for raw in configured_paths(source_root, kind) {
        for path in expand_catalog_entry(source_root, &raw)? {
            let key = normalize_lexical(&path);
            if seen.insert(key) {
                out.push(path);
            }
        }
    }
    Ok(out)
}

fn expand_catalog_entry(source_root: &Path, raw: &str) -> Result<Vec<PathBuf>> {
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
        return Ok(vec![source_root.join(parts.iter().collect::<PathBuf>())]);
    }

    let parent_rel: PathBuf = parts[..parts.len() - 1].iter().collect();
    let parent = source_root.join(parent_rel);
    if !parent.exists() {
        return Ok(Vec::new());
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
    Ok(matches)
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
    let mut files = Vec::new();
    for candidate in expand_configured_paths(source_root, kind)? {
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
    let mut dirs = Vec::new();
    for candidate in expand_configured_paths(source_root, kind)? {
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
    /// True when a candidate path is named after `name` — the physical
    /// footprint of an item independent of whether it parsed.
    pub fn has_candidate_named(&self, name: &str) -> bool {
        self.candidates.iter().any(|path| {
            path.file_stem()
                .and_then(|stem| stem.to_str())
                .is_some_and(|stem| stem == name)
                || path
                    .file_name()
                    .and_then(|file| file.to_str())
                    .is_some_and(|file| file == name)
        })
    }
}

/// Discover `kind` in `source_root` without printing. Errors only when the
/// catalog configuration itself is unusable (bad `[catalog]` path, unreadable
/// root); per-item parse failures land in [`Inventory::failures`].
pub(crate) fn inventory(source_root: &Path, kind: crate::config::ItemKind) -> Result<Inventory> {
    use crate::config::ItemKind;
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
    match kind {
        ItemKind::Agent => {
            for path in discover_files(source_root, CatalogKind::Agents, "md")? {
                let parsed = Agent::from_file(&path).map(|a| a.name);
                record(path, parsed);
            }
        }
        ItemKind::Skill => {
            for dir in discover_manifest_dirs(source_root, CatalogKind::Skills, "SKILL.md")? {
                let parsed = Skill::from_file(&dir.join("SKILL.md")).map(|s| s.name);
                record(dir, parsed);
            }
        }
        ItemKind::Hook => {
            for path in discover_files(source_root, CatalogKind::Hooks, "sh")? {
                let parsed = Hook::from_file(&path).map(|h| h.name);
                record(path, parsed);
            }
        }
        ItemKind::PiExtension => {
            for dir in
                discover_manifest_dirs(source_root, CatalogKind::PiExtensions, "package.json")?
            {
                let parsed = PiExtension::from_dir(&dir).map(|e| e.name);
                record(dir, parsed);
            }
        }
        ItemKind::Extra => {
            for dir in discover_manifest_dirs(source_root, CatalogKind::Extras, "extra.toml")? {
                let parsed = Extra::from_dir(&dir).map(|e| e.name().to_string());
                record(dir, parsed);
            }
        }
    }
    inv.names.sort();
    Ok(inv)
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
