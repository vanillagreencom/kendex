//! Reading items out of a plugin-registry-shaped catalog, and describing
//! what it offers.
//!
//! An item's name carries the plugin it came from — `<plugin>/<item>` — so
//! two plugins can each ship an `analyzer` without one hiding the other.
//! The metadata here is read-side only: it feeds a browse view and the
//! groups a plugin installs as. None of it belongs in `kendex.toml`, which
//! records what the user chose, not what a catalog says about itself.

use std::path::PathBuf;

use serde_json::Value;

use crate::error::Result;
use crate::model::ItemKind;
use crate::names;
use crate::source_read::SealedSource;

use super::plugin_registry::{CatalogFinding, PLUGIN_MANIFEST, PluginEntry, Registry};

/// The directory a plugin keeps this kind in, and the file that marks one
/// item. Everything else a plugin may carry (hooks, servers) is left alone
/// until kendex can install it from here.
fn kind_dir(kind: ItemKind) -> Option<(&'static str, Option<&'static str>)> {
    match kind {
        ItemKind::Agent => Some(("agents", None)),
        ItemKind::Command => Some(("commands", None)),
        ItemKind::Skill => Some(("skills", Some("SKILL.md"))),
        _ => None,
    }
}

/// The path an item of this kind takes inside a plugin, whether or not it
/// exists.
fn item_path(sealed: &SealedSource, entry: &PluginEntry, kind: ItemKind, leaf: &str) -> PathBuf {
    let (dir, marker) = kind_dir(kind).unwrap_or_default();
    let base = sealed.root().join(&entry.dir).join(dir);
    match marker {
        Some(_) => base.join(leaf),
        None => base.join(format!("{leaf}.md")),
    }
}

/// Whether that path is really an item of this kind.
fn exists(sealed: &SealedSource, path: &std::path::Path, kind: ItemKind) -> bool {
    match kind_dir(kind).and_then(|(_, marker)| marker) {
        Some(marker) => sealed.is_file(&path.join(marker)),
        None => sealed.is_file(path),
    }
}

/// Where a `<plugin>/<item>` name resolves to, or `None` when this catalog
/// carries no such item. A name whose plugin the registry never validated
/// resolves nowhere — that is what makes the registry, not the directory
/// listing, the thing that decides what a plugin-registry catalog offers.
pub fn find(
    sealed: &SealedSource,
    registry: &Registry,
    kind: ItemKind,
    name: &str,
) -> Option<PathBuf> {
    let (plugin, leaf) = names::split(name)?;
    let entry = registry.entry(plugin)?;
    kind_dir(kind)?;
    let path = item_path(sealed, entry, kind, leaf);
    exists(sealed, &path, kind).then_some(path)
}

/// Every item of this kind the catalog offers, named as it is declared. A
/// leaf a filesystem cannot hold is left out here and reported by
/// [`metadata`], which is where a catalog's problems are read.
pub fn items(sealed: &SealedSource, registry: &Registry, kind: ItemKind) -> Vec<String> {
    let mut names = Vec::new();
    for entry in &registry.plugins {
        for leaf in leaves(sealed, entry, kind) {
            if names::segment_problem(&leaf).is_none() {
                names.push(format!("{}/{leaf}", entry.name));
            }
        }
    }
    names.sort();
    names
}

/// The item names one plugin's kind directory holds, whether or not each is
/// a name that can be installed.
fn leaves(sealed: &SealedSource, entry: &PluginEntry, kind: ItemKind) -> Vec<String> {
    let Some((dir, marker)) = kind_dir(kind) else {
        return Vec::new();
    };
    let Ok(paths) = sealed.entries(&sealed.root().join(&entry.dir).join(dir)) else {
        return Vec::new();
    };
    let mut leaves = Vec::new();
    for path in paths {
        let leaf = match marker {
            Some(marker) if sealed.is_file(&path.join(marker)) => path.file_name(),
            Some(_) => None,
            None if path.extension().is_some_and(|e| e == "md") && sealed.is_file(&path) => {
                path.file_stem()
            }
            None => None,
        };
        if let Some(leaf) = leaf.and_then(|leaf| leaf.to_str()) {
            leaves.push(leaf.to_owned());
        }
    }
    leaves
}

/// One item a plugin ships.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogItem {
    pub kind: ItemKind,
    /// The declared name, plugin segment included.
    pub name: String,
}

/// A plugin as an installable set. Phase 4 installs one of these as a unit;
/// today it is what the browse view lists and what says which items came
/// from the same place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogGroup {
    pub name: String,
    pub version: Option<String>,
    pub description: Option<String>,
    pub category: Option<String>,
    pub author: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
    pub keywords: Vec<String>,
    pub members: Vec<CatalogItem>,
}

/// What a plugin-registry-shaped catalog offers, and everything wrong with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogMetadata {
    pub name: String,
    pub owner: Option<String>,
    pub description: Option<String>,
    pub version: Option<String>,
    pub groups: Vec<CatalogGroup>,
    pub findings: Vec<CatalogFinding>,
}

/// The items one plugin ships, named the way they install. What it cannot
/// ship is reported by [`metadata`], which is where a catalog's problems are
/// read; here the question is only what a plugin installed as a set brings.
pub(super) fn plugin_members(
    sealed: &SealedSource,
    entry: &PluginEntry,
) -> Result<Vec<CatalogItem>> {
    Ok(group(sealed, entry, &mut Vec::new())?.members)
}

/// The full read: the registry, every plugin's own manifest, and the items
/// on disk, checked against each other. `None` when the source is not
/// plugin-registry-shaped.
pub fn metadata(sealed: &SealedSource) -> Result<Option<CatalogMetadata>> {
    let Some(registry) = super::plugin_registry::read(sealed)? else {
        return Ok(None);
    };
    let mut findings = registry.findings.clone();
    let mut groups = Vec::new();
    for entry in &registry.plugins {
        groups.push(group(sealed, entry, &mut findings)?);
    }
    Ok(Some(CatalogMetadata {
        name: registry.name,
        owner: registry.owner,
        description: registry.description,
        version: registry.version,
        groups,
        findings,
    }))
}

fn group(
    sealed: &SealedSource,
    entry: &PluginEntry,
    findings: &mut Vec<CatalogFinding>,
) -> Result<CatalogGroup> {
    let at = crate::paths::slashed(&entry.dir);
    check_manifest(sealed, entry, &at, findings)?;
    let mut members = Vec::new();
    for kind in [ItemKind::Agent, ItemKind::Command, ItemKind::Skill] {
        let mut seen: Vec<String> = Vec::new();
        for leaf in leaves(sealed, entry, kind) {
            let at = format!("{at}/{}", kind.name());
            if let Some(problem) = names::segment_problem(&leaf) {
                findings.push(CatalogFinding::new(
                    at,
                    format!("`{}` cannot be installed: {problem}", names::shown(&leaf)),
                    "rename it in the catalog",
                ));
                continue;
            }
            if let Some(other) = seen
                .iter()
                .find(|other| names::fold(other) == names::fold(&leaf))
            {
                findings.push(CatalogFinding::new(
                    at,
                    format!(
                        "`{leaf}` and `{other}` are the same name once a filesystem has folded case and trailing dots — one would overwrite the other"
                    ),
                    "rename one of them so they differ by more than case",
                ));
                continue;
            }
            seen.push(leaf.clone());
            members.push(CatalogItem {
                kind,
                name: format!("{}/{leaf}", entry.name),
            });
        }
    }
    Ok(CatalogGroup {
        name: entry.name.clone(),
        version: entry.version.clone(),
        description: entry.description.clone(),
        category: entry.category.clone(),
        author: entry.author.clone(),
        license: entry.license.clone(),
        homepage: entry.homepage.clone(),
        keywords: entry.keywords.clone(),
        members,
    })
}

/// The plugin's own manifest, read against what the registry claims. A
/// catalog whose two files disagree has already lost track of what it
/// ships, and the version is the half users act on.
fn check_manifest(
    sealed: &SealedSource,
    entry: &PluginEntry,
    at: &str,
    findings: &mut Vec<CatalogFinding>,
) -> Result<()> {
    let path = sealed.root().join(&entry.dir).join(PLUGIN_MANIFEST);
    let Some(text) = sealed.read_if_exists(&path)? else {
        return Ok(());
    };
    let manifest: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(problem) => {
            findings.push(CatalogFinding::new(
                format!("{at}/{PLUGIN_MANIFEST}"),
                format!("this plugin's own manifest is not readable JSON — {problem}"),
                "fix the JSON, or delete the file and let the registry speak for the plugin",
            ));
            return Ok(());
        }
    };
    // A plugin's own manifest is a downloaded file whose text reaches a
    // terminal, so what it says is read as words and never acted on.
    let field = |key: &str| {
        manifest
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(names::shown)
    };
    if let Some(name) = field("name")
        && name != entry.name
    {
        findings.push(CatalogFinding::new(
            format!("{at}/{PLUGIN_MANIFEST}"),
            format!(
                "the catalog lists this plugin as `{}` and the plugin calls itself `{name}`",
                entry.name
            ),
            format!(
                "make both say the same name — `{}` is where it installs from",
                entry.name
            ),
        ));
    }
    if let (Some(listed), Some(own)) = (&entry.version, field("version"))
        && listed != &own
    {
        findings.push(CatalogFinding::new(
            format!("{at}/{PLUGIN_MANIFEST}"),
            format!("the catalog offers version {listed} and the plugin says it is {own}"),
            "publish one version number in both files",
        ));
    }
    for key in ["agents", "commands", "skills", "hooks", "mcpServers"] {
        for declared in paths_of(manifest.get(key)) {
            check_component(sealed, entry, at, key, &declared, findings);
        }
    }
    // A plugin's hooks and MCP servers are declared here but not yet installed
    // from a plugin registry — only its skills, agents and commands are. Say so
    // rather than drop them in silence, so installing the plugin is never
    // mistaken for installing all of it.
    let carried: Vec<&str> = [("hooks", "hooks"), ("mcpServers", "MCP servers")]
        .into_iter()
        .filter(|(key, _)| manifest.get(key).is_some_and(|value| !value.is_null()))
        .map(|(_, label)| label)
        .collect();
    if !carried.is_empty() {
        findings.push(CatalogFinding::new(
            format!("{at}/{PLUGIN_MANIFEST}"),
            format!(
                "this plugin also ships {} that kendex does not install from a plugin registry yet — its skills, agents and commands install, the rest do not",
                carried.join(" and ")
            ),
            "install those from a marketplace that declares kendex's layout, or wait for plugin hook and server support",
        ));
    }
    Ok(())
}

fn paths_of(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::String(path)) => vec![path.clone()],
        Some(Value::Array(list)) => list
            .iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}

/// A plugin may say where its parts live. Every one of those paths must land
/// inside the plugin's own directory: a catalog that reaches sideways into
/// another plugin, or up and out of the repository, is describing files it
/// does not own.
fn check_component(
    sealed: &SealedSource,
    entry: &PluginEntry,
    at: &str,
    key: &str,
    declared: &str,
    findings: &mut Vec<CatalogFinding>,
) {
    let trimmed = declared.trim_start_matches("./").trim_end_matches('/');
    let inside = !trimmed.is_empty()
        && !std::path::Path::new(trimmed).is_absolute()
        && std::path::Path::new(trimmed)
            .components()
            .all(|c| matches!(c, std::path::Component::Normal(_)));
    let resolved = sealed.root().join(&entry.dir).join(trimmed);
    if !inside {
        findings.push(CatalogFinding::new(
            format!("{at}/{PLUGIN_MANIFEST}"),
            format!(
                "`{key}` points at `{}`, which is outside this plugin",
                names::shown(declared)
            ),
            "point it at a directory inside the plugin, such as `./skills`",
        ));
        return;
    }
    // The sealed reader refuses symlinks, so a path that exists but cannot
    // be opened is one dressed up to reach somewhere else.
    if !sealed.is_dir(&resolved) && !sealed.is_file(&resolved) {
        findings.push(CatalogFinding::new(
            format!("{at}/{PLUGIN_MANIFEST}"),
            format!(
                "`{key}` points at `{}`, which is not a readable part of this plugin",
                names::shown(declared)
            ),
            "point it at a directory or file the plugin really ships, or drop the key",
        ));
    }
}

#[cfg(test)]
mod tests;
