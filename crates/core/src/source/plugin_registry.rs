//! Plugin-registry-shaped catalogs: a repository that carries
//! `.claude-plugin/marketplace.json`. Each plugin names a local source
//! directory and can select individual skill folders there.
//!
//! Recognition is the registry file and nothing else. A `plugins/`
//! directory is a guess, and guessing wrong renames every item in the
//! catalog — so the file's presence is what says "read me this way", and
//! whether it parses and validates is what decides how much of it can be
//! read. Every problem is a finding with a fix; nothing here panics and
//! nothing is skipped in silence.
//!
//! Only entries pointing at a directory inside the repository are consumed.
//! An entry that names another repository (`git-subdir`, or a URL) is
//! skipped with a finding: fetching it would be a second, unpinned download
//! behind the one the user asked for.

use std::fmt;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::error::Result;
use crate::names;
use crate::source_read::SealedSource;

/// The file that declares a catalog plugin-registry-shaped.
pub const REGISTRY: &str = ".claude-plugin/marketplace.json";
/// A plugin's own manifest — the one file that can disagree with the
/// registry about what the plugin is called and which version it is.
pub const PLUGIN_MANIFEST: &str = ".claude-plugin/plugin.json";

/// Something wrong with a catalog, said in the catalog author's terms.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, specta::Type)]
pub struct CatalogFinding {
    /// Where in the catalog, repository-relative and `/`-spelled — the
    /// catalog author reads it beside the `/`-spelled roots the search
    /// table names, and it is one string on every host.
    pub location: String,
    pub problem: String,
    pub fix: String,
    /// Whether this alone means the catalog would not install something it
    /// declares — carried from where that is known, never re-read from text.
    pub breakage: bool,
}

impl fmt::Display for CatalogFinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {} — fix: {}", self.location, self.problem, self.fix)
    }
}

impl CatalogFinding {
    pub(super) fn new(
        location: impl Into<String>,
        problem: impl Into<String>,
        fix: impl Into<String>,
    ) -> Self {
        CatalogFinding {
            location: location.into(),
            problem: problem.into(),
            fix: fix.into(),
            breakage: false,
        }
    }

    /// The same finding, as something the catalog cannot install past.
    pub(super) fn breaking(self) -> Self {
        CatalogFinding {
            breakage: true,
            ..self
        }
    }
}

/// One plugin the catalog offers, as the registry describes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginEntry {
    pub name: String,
    /// Relative to the source root, always beneath it.
    pub dir: PathBuf,
    /// Declared skill folders relative to the plugin; absence uses `skills/`.
    pub skills: Option<Vec<PathBuf>>,
    pub(super) offers: super::catalog::Offers,
    pub description: Option<String>,
    pub version: Option<String>,
    pub author: Option<String>,
    pub license: Option<String>,
    pub category: Option<String>,
    pub homepage: Option<String>,
    pub keywords: Vec<String>,
}

/// The registry as read: the entries that can be consumed, and everything
/// wrong with the ones that cannot.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Registry {
    pub name: String,
    pub owner: Option<String>,
    pub description: Option<String>,
    pub version: Option<String>,
    pub plugins: Vec<PluginEntry>,
    pub findings: Vec<CatalogFinding>,
}

impl Registry {
    pub fn entry(&self, name: &str) -> Option<&PluginEntry> {
        self.plugins.iter().find(|entry| entry.name == name)
    }
}

/// The registry of a plugin-registry-shaped source, or `None` when the
/// source carries no registry at all and is read the plain way.
pub fn read(sealed: &SealedSource) -> Result<Option<Registry>> {
    let Some(text) = sealed.read_if_exists(&sealed.root().join(REGISTRY))? else {
        return Ok(None);
    };
    Ok(Some(parse(sealed, &text)))
}

fn parse(sealed: &SealedSource, text: &str) -> Registry {
    let mut registry = Registry::default();
    let root: Value = match serde_json::from_str(text) {
        Ok(value) => value,
        Err(problem) => {
            registry.findings.push(CatalogFinding::new(
                REGISTRY,
                format!("this catalog's registry is not readable JSON — {problem}"),
                "fix the JSON, or delete the file to have the catalog read as a plain one",
            ));
            return registry;
        }
    };
    registry.name = string(&root, "name").unwrap_or_default();
    if registry.name.is_empty() {
        registry.findings.push(CatalogFinding::new(
            REGISTRY,
            "the catalog has no name".to_owned(),
            "add `\"name\": \"<catalog>\"` at the top of the registry",
        ));
    }
    registry.owner = root.get("owner").and_then(owner_name);
    if registry.owner.is_none() {
        registry.findings.push(CatalogFinding::new(
            REGISTRY,
            "the catalog says who owns it nowhere, and some tools refuse a catalog without an owner"
                .to_owned(),
            "add `\"owner\": {\"name\": \"…\"}` to the registry",
        ));
    }
    let metadata = root.get("metadata");
    registry.description = metadata.and_then(|m| string(m, "description"));
    registry.version = metadata.and_then(|m| string(m, "version"));

    let Some(entries) = root.get("plugins").and_then(Value::as_array) else {
        registry.findings.push(CatalogFinding::new(
            REGISTRY,
            "the registry lists no plugins".to_owned(),
            "add a `\"plugins\": [ … ]` array naming each plugin directory",
        ));
        return registry;
    };
    let mut skill_allowance = Some(super::discover::MAX_SKILLS);
    for (index, entry) in entries.iter().enumerate() {
        read_entry(sealed, index, entry, &mut registry, &mut skill_allowance);
    }
    registry
}

fn read_entry(
    sealed: &SealedSource,
    index: usize,
    entry: &Value,
    registry: &mut Registry,
    skill_allowance: &mut Option<usize>,
) {
    let at = format!("{REGISTRY}: plugins[{index}]");
    let Some(name) = string(entry, "name") else {
        registry.findings.push(CatalogFinding::new(
            at,
            "this entry has no name".to_owned(),
            "give every entry a `\"name\"` — it is what the items are installed under",
        ));
        return;
    };
    // The name is a downloaded catalog's own text, and every finding below
    // carries it to a terminal: it is shown, never acted on.
    let at = format!("{REGISTRY}: {}", names::shown(&name));
    if let Some(problem) = names::segment_problem(&name) {
        registry.findings.push(CatalogFinding::new(
            at,
            format!("this plugin cannot be installed under its name: {problem}"),
            "rename the plugin in the registry and in its directory",
        ));
        return;
    }
    if let Some(other) = registry
        .plugins
        .iter()
        .find(|other| names::fold(&other.name) == names::fold(&name))
    {
        let (problem, fix) = match other.name == name {
            true => (
                format!("`{name}` is listed twice"),
                "keep one entry per plugin",
            ),
            false => (
                format!(
                    "`{name}` and `{}` are the same name once a filesystem has folded case and trailing dots — one would overwrite the other",
                    other.name
                ),
                "give the two plugins names that differ by more than case",
            ),
        };
        registry
            .findings
            .push(CatalogFinding::new(at, problem, fix));
        return;
    }
    let Some(dir) = local_dir(&at, &name, entry, registry) else {
        return;
    };
    if !sealed.is_dir(&sealed.root().join(&dir)) {
        registry.findings.push(CatalogFinding::new(
            at,
            format!(
                "`{}` is not a directory in this catalog",
                names::shown(&crate::paths::slashed(&dir))
            ),
            "point the entry at a directory that exists, or drop the entry",
        ));
        return;
    }
    let skills = skill_dirs(
        sealed,
        &at,
        &name,
        &dir,
        entry.get("skills"),
        registry,
        skill_allowance,
    );
    let mut plugin = PluginEntry {
        name,
        dir,
        skills,
        offers: super::catalog::Offers::default(),
        description: string(entry, "description"),
        version: string(entry, "version"),
        author: entry.get("author").and_then(owner_name),
        license: string(entry, "license"),
        category: string(entry, "category"),
        homepage: string(entry, "homepage"),
        keywords: entry
            .get("keywords")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|k| k.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
    };
    plugin.offers = super::catalog::read_offers(sealed, &plugin, &mut registry.findings);
    registry.plugins.push(plugin);
}

/// The directory inside this catalog an entry points at. Anything else —
/// another repository, a URL, a path that climbs out — is refused here,
/// named, and never resolved.
fn local_dir(at: &str, name: &str, entry: &Value, registry: &mut Registry) -> Option<PathBuf> {
    let source = entry.get("source");
    let elsewhere = |kind: &str, registry: &mut Registry| {
        registry.findings.push(CatalogFinding::new(
            at,
            format!("`{name}` lives in {kind}, which this version does not fetch"),
            "install it from its own repository, or ask the catalog to vendor it in",
        ));
    };
    match source {
        None => {
            registry.findings.push(CatalogFinding::new(
                at,
                format!("`{name}` says nowhere where its files are"),
                format!("add `\"source\": \"./plugins/{name}\"` to the entry"),
            ));
            None
        }
        Some(Value::Object(_)) => {
            elsewhere("another repository", registry);
            None
        }
        Some(Value::String(path)) if path.contains("://") => {
            elsewhere("another location on the web", registry);
            None
        }
        Some(Value::String(path)) => match relative_dir(at, name, path) {
            Ok(dir) => Some(dir),
            Err(finding) => {
                registry.findings.push(finding);
                None
            }
        },
        Some(_) => {
            registry.findings.push(CatalogFinding::new(
                at,
                format!("`{name}` describes where its files are in a shape nothing can read"),
                format!("write `\"source\": \"./plugins/{name}\"`"),
            ));
            None
        }
    }
}

fn relative_dir(at: &str, name: &str, path: &str) -> std::result::Result<PathBuf, CatalogFinding> {
    if path.is_empty() {
        return Err(CatalogFinding::new(
            at,
            format!("`{name}` declares an empty directory path"),
            "name a local directory; use `./` for the repository root",
        ));
    }
    let hostile = Path::new(path).is_absolute()
        || Path::new(path).components().any(|c| {
            !matches!(
                c,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )
        });
    if hostile {
        return Err(CatalogFinding::new(
            at,
            format!(
                "`{name}` points at `{}`, which leads out of the catalog",
                names::shown(path)
            ),
            format!("point it at a directory inside the catalog, such as `./plugins/{name}`"),
        ));
    }
    Ok(Path::new(path)
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(part) => Some(part),
            std::path::Component::CurDir
            | std::path::Component::ParentDir
            | std::path::Component::RootDir
            | std::path::Component::Prefix(_) => None,
        })
        .collect())
}

fn skill_dirs(
    sealed: &SealedSource,
    at: &str,
    name: &str,
    dir: &Path,
    value: Option<&Value>,
    registry: &mut Registry,
    skill_allowance: &mut Option<usize>,
) -> Option<Vec<PathBuf>> {
    let value = value?;
    // Claude marketplaces emit strings; HeyGen also emits objects with `path`.
    let declarations: &[Value] = match value {
        Value::Array(list) => list,
        _ => std::slice::from_ref(value),
    };
    let mut skills = Vec::new();
    for declaration in declarations {
        // Foreign registries can repeat valid or refused paths. Count their
        // work before any read or retained per-declaration diagnostic.
        match skill_allowance {
            Some(remaining) if *remaining > 0 => *remaining -= 1,
            Some(_) => {
                registry.findings.push(
                    CatalogFinding::new(
                        format!("{REGISTRY}: skills"),
                        format!(
                            "more than {} skill declarations; the rest are not read",
                            super::discover::MAX_SKILLS
                        ),
                        "reduce the registry's skill declarations",
                    )
                    .breaking(),
                );
                *skill_allowance = None;
                break;
            }
            None => break,
        }
        let resolved: std::result::Result<PathBuf, CatalogFinding> = (|| {
            let path = declaration
                .as_str()
                .or_else(|| declaration.get("path").and_then(Value::as_str))
                .ok_or_else(|| {
                    CatalogFinding::new(
                        at,
                        "a skill declaration has no string path",
                        "name a skill folder with a string or an object containing `path`",
                    )
                })?;
            let at = format!("{at}: skills[{}]", names::shown(path));
            let relative = relative_dir(&at, name, path)?;
            let marker = sealed.root().join(dir).join(&relative).join("SKILL.md");
            sealed.read_to_string(&marker).map_err(|problem| {
                CatalogFinding::new(
                    &at,
                    format!(
                        "skill path `{}` has no readable SKILL.md: {problem}",
                        names::shown(path)
                    ),
                    "point the declaration at a skill folder with a readable SKILL.md",
                )
            })?;
            Ok(relative)
        })();
        match resolved {
            Ok(relative) => skills.push(relative),
            Err(finding) => registry.findings.push(finding.breaking()),
        }
    }
    Some(skills)
}

fn string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// An `owner` or `author` is a table with a name, and some catalogs write it
/// as a plain string.
fn owner_name(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_owned()),
        Value::Object(_) => string(value, "name"),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
