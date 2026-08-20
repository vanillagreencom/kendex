//! A catalog's own configuration — `kendex.toml` (or the pre-rename
//! `vstack.toml`) plus a Claude plugin registry where one exists — and the
//! item lookups that read it.
//!
//! Presence selects the mode and breakage never falls through to a
//! different one: a control file that exists but cannot be read makes the
//! source unusable with a finding, because serving defaults instead would
//! silently offer a different catalog than the author published.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::source_read::SealedSource;

use super::bundles::{self, CatalogBundle};
use super::catalog;
use super::discover::{self, CatalogMode, Discovery};
use super::meta::MarketplaceMeta;
use super::plugin_registry::{self, CatalogFinding, Registry};

/// Source-side layout + mapping tables, read leniently — source catalogs are
/// v1-format repos (no schema key) and stay valid forever. What is not
/// lenient is the control file itself: see the module note.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceConfig {
    pub agent_dirs: Vec<String>,
    pub skill_dirs: Vec<String>,
    pub agent_skills: BTreeMap<String, Vec<String>>,
    pub role_skills: BTreeMap<String, Vec<String>>,
    pub frontmatter: BTreeMap<String, BTreeMap<String, crate::manifest::FrontmatterOverrides>>,
    /// The curated sets this catalog offers by name. Empty for a
    /// plugin-registry-shaped catalog, whose plugins are its sets.
    pub bundles: BTreeMap<String, CatalogBundle>,
    /// What the catalog says about itself in `[marketplace]`, capped.
    pub marketplace: Option<MarketplaceMeta>,
    /// Set when the source carries a plugin registry: its items live
    /// one plugin deep and are named `<plugin>/<item>`. The kind directories
    /// at the root are not read in that case — the registry says what the
    /// catalog offers, and reading both would offer the same file twice.
    pub plugin_registry: Option<Registry>,
    /// The precedence's verdict for this source.
    pub mode: CatalogMode,
    /// What the search table found, in [`CatalogMode::Discovered`] only.
    pub discovery: Discovery,
    /// What is wrong with the control file itself.
    pub config_findings: Vec<CatalogFinding>,
}

impl SourceConfig {
    /// Everything wrong with the catalog, wherever it was read from.
    pub fn findings(&self) -> impl Iterator<Item = &CatalogFinding> {
        self.config_findings
            .iter()
            .chain(
                self.plugin_registry
                    .iter()
                    .flat_map(|registry| registry.findings.iter()),
            )
            .chain(self.discovery.findings.iter())
    }

    fn unusable(&mut self, file: &'static str, problem: String, fix: &str) {
        self.config_findings
            .push(CatalogFinding::new(file, problem, fix));
        self.mode = CatalogMode::Unusable;
        self.agent_dirs.clear();
        self.skill_dirs.clear();
        self.bundles.clear();
    }
}

/// The control file governing this catalog, chosen across both generations.
enum Control {
    None,
    Broken { file: &'static str, problem: String },
    Parsed { table: toml::Table },
}

/// Read the catalog's layout and mapping tables — and, when neither a
/// registry nor a control file declares the layout, run the search table.
/// `display` names a one-skill repo whose SKILL.md does not name itself:
/// pass the repository leaf, since the store directory is a commit id.
pub fn source_config(sealed: &SealedSource, display: &str) -> Result<SourceConfig> {
    let mut config = SourceConfig {
        agent_dirs: vec!["agents".to_owned()],
        skill_dirs: vec!["skills".to_owned()],
        plugin_registry: plugin_registry::read(sealed)?,
        ..SourceConfig::default()
    };
    match control_file(sealed)? {
        Control::None => {}
        Control::Broken { file, problem } => match config.plugin_registry.is_some() {
            // The registry outranks the control file, so its breakage is a
            // finding rather than the whole source's verdict.
            true => config.config_findings.push(CatalogFinding::new(
                file,
                format!("this catalog's own config is not readable TOML — {problem}"),
                "fix the TOML, or delete the file",
            )),
            false => config.unusable(
                file,
                format!("this catalog's own config is not readable TOML — {problem}"),
                "fix the TOML, or delete the file to have the layout discovered",
            ),
        },
        Control::Parsed { table } => {
            // A parsed control file declares kendex's layout: the fixed kind
            // dirs govern, `[catalog]` overriding which ones, and the search
            // table stays out — discovery exists for repos that never
            // declared anything.
            config.mode = CatalogMode::Explicit;
            read_tables(&mut config, &table);
        }
    }
    if config.plugin_registry.is_some() && config.mode != CatalogMode::Unusable {
        config.mode = CatalogMode::PluginRegistry;
    }
    if config.mode == CatalogMode::Discovered {
        config.discovery = discover::discover(sealed, display)?;
    }
    Ok(config)
}

/// The catalog behind one resolved source, told apart by its provenance. The
/// reserved local source is kendex's own authored area — adopt and fork lay it
/// out in kendex's fixed dirs, so it is an explicit catalog even with no marker
/// file, and its hooks, commands and MCP servers resolve by name the way a
/// discovered third-party repo's never do.
pub fn source_config_for(sealed: &SealedSource, provenance: &str) -> Result<SourceConfig> {
    let mut config = source_config(sealed, crate::source::repo_leaf(provenance))?;
    if provenance == crate::manifest::LOCAL_SOURCE_NAME && config.mode == CatalogMode::Discovered {
        config.mode = CatalogMode::Explicit;
    }
    Ok(config)
}

/// Which of the two file generations governs. Catalogs are foreign repos we
/// cannot rename: `kendex.toml` is preferred while the two agree, or while
/// only it parses — but two files that would each govern differently are an
/// ambiguity error naming both, never an arbitration.
fn control_file(sealed: &SealedSource) -> Result<Control> {
    let root = sealed.root();
    let new = sealed.read_if_exists(&root.join(crate::rename::MANIFEST_FILE))?;
    let old = sealed.read_if_exists(&root.join(crate::rename::LEGACY_MANIFEST_FILE))?;
    let (file, text) = match (new, old) {
        (None, None) => return Ok(Control::None),
        (Some(text), None) => (crate::rename::MANIFEST_FILE, text),
        (None, Some(text)) => (crate::rename::LEGACY_MANIFEST_FILE, text),
        (Some(new), Some(old)) => {
            let agree = new == old
                || match (new.parse::<toml::Table>(), old.parse::<toml::Table>()) {
                    (Ok(new), Ok(old)) => new == old,
                    (Ok(_), Err(_)) => true,
                    _ => false,
                };
            if !agree {
                return Err(CoreError::CatalogAmbiguous {
                    new: root.join(crate::rename::MANIFEST_FILE),
                    old: root.join(crate::rename::LEGACY_MANIFEST_FILE),
                });
            }
            (crate::rename::MANIFEST_FILE, new)
        }
    };
    match text.parse::<toml::Table>() {
        Ok(table) => Ok(Control::Parsed { table }),
        Err(problem) => Ok(Control::Broken {
            file,
            problem: problem.to_string(),
        }),
    }
}

fn read_tables(config: &mut SourceConfig, table: &toml::Table) {
    match table.get("catalog") {
        None => {}
        Some(toml::Value::Table(catalog)) => {
            for key in ["agents", "skills"] {
                let Some(value) = catalog.get(key) else {
                    continue;
                };
                let Some(list) = string_list(Some(value)) else {
                    config.unusable(
                        crate::rename::MANIFEST_FILE,
                        format!("`[catalog] {key}` is not a list of directory names"),
                        "write it as an array of strings, or remove the key",
                    );
                    return;
                };
                match key {
                    "agents" => config.agent_dirs = list,
                    _ => config.skill_dirs = list,
                }
            }
        }
        Some(_) => {
            config.unusable(
                crate::rename::MANIFEST_FILE,
                "`catalog` is not a table".to_owned(),
                "write `[catalog]` with `skills`/`agents` arrays, or remove it",
            );
            return;
        }
    }
    match table.get("marketplace") {
        None => {}
        Some(value) => match value.clone().try_into::<MarketplaceMeta>() {
            Ok(meta) => config.marketplace = Some(meta.capped()),
            // Metadata never gates installs, so bad metadata is a finding
            // and the catalog keeps working without it.
            Err(problem) => config.config_findings.push(CatalogFinding::new(
                crate::rename::MANIFEST_FILE,
                format!("`[marketplace]` could not be read — {problem}"),
                "write string fields (name, description, author, license, homepage) and a string list `tags`",
            )),
        },
    }
    config.bundles = bundles::declared(table);
    if let Some(mapping) = table.get("agent-skills").and_then(|t| t.as_table()) {
        for (agent, skills) in mapping {
            if let Some(list) = string_list(Some(skills)) {
                config.agent_skills.insert(agent.clone(), list);
            }
        }
    }
    if let Some(mapping) = table.get("role-skills").and_then(|t| t.as_table()) {
        for (role, skills) in mapping {
            if let Some(list) = string_list(Some(skills)) {
                config.role_skills.insert(role.clone(), list);
            }
        }
    }
    if let Some(frontmatter) = table.get("agent-frontmatter").and_then(|t| t.as_table()) {
        for (harness, agents) in frontmatter {
            let Some(agents) = agents.as_table() else {
                continue;
            };
            let mut per_agent = BTreeMap::new();
            for (agent, overrides) in agents {
                if let Ok(parsed) = overrides.clone().try_into() {
                    per_agent.insert(agent.clone(), parsed);
                }
            }
            config.frontmatter.insert(harness.clone(), per_agent);
        }
    }
}

/// A list of strings and nothing else — a member of any other type makes
/// the whole value unreadable rather than a shorter list.
fn string_list(value: Option<&toml::Value>) -> Option<Vec<String>> {
    let list = value?.as_array()?;
    list.iter().map(|v| v.as_str().map(str::to_owned)).collect()
}

pub fn find_item(
    sealed: &SealedSource,
    config: &SourceConfig,
    kind: ItemKind,
    name: &str,
) -> Option<PathBuf> {
    // A name that cannot be a file is not on offer, whoever asks — a bundle
    // member or a dependency is not checked anywhere else.
    if crate::names::item_problem(name).is_some() {
        return None;
    }
    if config.mode == CatalogMode::Unusable {
        return None;
    }
    if let Some(registry) = &config.plugin_registry {
        return catalog::find(sealed, registry, kind, name);
    }
    let root = sealed.root();
    match kind {
        ItemKind::Skill => match config.mode {
            CatalogMode::Explicit => config
                .skill_dirs
                .iter()
                .map(|d| root.join(d).join(name))
                .find(|p| sealed.is_file(&p.join("SKILL.md"))),
            _ => config
                .discovery
                .skills
                .iter()
                .find(|skill| skill.name == name)
                .map(|skill| match skill.rel.as_os_str().is_empty() {
                    true => root.to_path_buf(),
                    false => root.join(&skill.rel),
                }),
        },
        ItemKind::Agent => config
            .agent_dirs
            .iter()
            .map(|d| root.join(d).join(format!("{name}.md")))
            .find(|p| sealed.is_file(p)),
        // Executable kinds resolve only where the catalog declared kendex's
        // layout, the same gate `list_items` applies. Without it a discovered
        // repo — one the About report says offers no hooks — would still hand
        // over and run `hooks/<name>.sh` when asked for it by name, the exact
        // "executable content is never guessed into existence" rule §5.6 sets.
        ItemKind::Hook | ItemKind::Command | ItemKind::McpServer
            if config.mode == CatalogMode::Explicit =>
        {
            let (dir, ext) = super::layout::fixed_kind_dir(kind);
            catalog_file(sealed, dir, &format!("{name}.{ext}"))
        }
        ItemKind::Hook | ItemKind::Command | ItemKind::McpServer => None,
        // A declared Pi package resolves like update-pi resolves it: the
        // literal directory, else whichever directory's package.json
        // registers the name — kendex's own catalog shelves scoped names
        // in short directories. Without this, every declared Pi package
        // reads as "no longer offered" the moment it is declared.
        ItemKind::PiExtension => {
            let base = root.join("pi-extensions");
            let literal = base.join(name);
            if sealed.is_file(&literal.join("package.json")) {
                return Some(literal);
            }
            crate::pi_ext::find_by_package_name(&base, name)
                .ok()
                .flatten()
        }
        ItemKind::Plugin => None,
    }
}

fn catalog_file(sealed: &SealedSource, dir: &str, file: &str) -> Option<PathBuf> {
    let path = sealed.root().join(dir).join(file);
    sealed.is_file(&path).then_some(path)
}

pub fn list_items(sealed: &SealedSource, config: &SourceConfig, kind: ItemKind) -> Vec<String> {
    if config.mode == CatalogMode::Unusable {
        return Vec::new();
    }
    if let Some(registry) = &config.plugin_registry {
        return catalog::items(sealed, registry, kind);
    }
    let mut names = Vec::new();
    match kind {
        ItemKind::Skill => match config.mode {
            CatalogMode::Explicit => {
                for dir in &config.skill_dirs {
                    names.extend(super::layout::flat_skills(sealed, dir));
                }
            }
            _ => names.extend(config.discovery.skills.iter().map(|s| s.name.clone())),
        },
        ItemKind::Agent => {
            for dir in &config.agent_dirs {
                names.extend(super::layout::agent_stems(sealed, dir));
            }
        }
        // Executable kinds are offered only where the catalog declared
        // kendex's layout — a `hooks/` folder in a repo that never declared
        // anything is repository tooling, not installable content.
        ItemKind::Hook | ItemKind::Command | ItemKind::McpServer
            if config.mode == CatalogMode::Explicit =>
        {
            let (dir, ext) = super::layout::fixed_kind_dir(kind);
            names.extend(super::layout::ext_stems(sealed, dir, ext));
        }
        _ => {}
    }
    names.sort();
    names.dedup();
    names
}
