use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::HarnessId;

mod file;
mod validate;
pub use file::{
    ManifestFile, is_source_catalog, load, load_for_mutation, manifest_path, observed, parse_text,
    read_for_mutation, seed,
};
// Crate-only: the apply op is `save`'s one sanctioned caller — it checks
// its precondition first. Anywhere else, a direct save is a whole-file
// write with no base check, the exact door `read_for_mutation` closes.
pub(crate) use file::save;
pub use validate::{Finding, validate};

/// Current manifest schema, and the only one that loads. Nothing converts
/// an older file: each schema changed what a table means — schema 3 added
/// per-item `rev` and `[forks]`, schemas 4 and 5 carried the recorded
/// safety decisions schema 6 retired — so reading one under this build's
/// rules answers wrongly rather than incompletely, and the write that
/// follows makes it durable over the person's own bytes. A schema newer
/// than this build refuses too; downgrades must never corrupt. Either way
/// the file is left as written and the refusal names the way out.
pub const MANIFEST_SCHEMA: u32 = 6;
pub const DEFAULT_SOURCE_NAME: &str = "kendex";
pub const DEFAULT_SOURCE_REPO: &str = "vanillagreencom/kendex";
/// The reserved source name for content adopted into this scope.
pub const LOCAL_SOURCE_NAME: &str = "local";
/// The reserved source name for content whose record of truth is the shared
/// `.agents` tree itself. An item declared from it is not rendered from a
/// copy kept somewhere else: the installed tree *is* the source, so a
/// refresh keeps the links and the layout right and never rewrites a byte
/// the person owns.
pub const INPLACE_SOURCE_NAME: &str = "in-place";
/// The directory that source reads, inside a project.
pub const INPLACE_SOURCE_DIR: &str = ".agents";
/// The manifest file a scope carries.
pub const MANIFEST_FILE: &str = "kendex.toml";
/// The manifest a source catalog keeps its own install state in, so the
/// file it publishes stays the definition and nothing else.
pub const LOCAL_MANIFEST_FILE: &str = "kendex-local.toml";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum Method {
    #[default]
    Symlink,
    Copy,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct SourceDecl {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Which revision of a remote to read. A full commit id is a pin: that
    /// commit and no other, forever, and it works offline once cached. A
    /// tag or branch tracks — every refresh re-resolves it and the new
    /// content is previewed before anything is written. Absent tracks the
    /// repository's default branch.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct InstallDefaults {
    #[serde(default)]
    pub harnesses: Vec<HarnessId>,
    #[serde(default)]
    pub method: Method,
}

/// One declared item: `[agents.<name>]` / `[skills.<name>]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct ItemDecl {
    pub source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harnesses: Option<Vec<HarnessId>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<Method>,
    /// Which revision of the source this item reads, outranking the
    /// source-level `rev`. Same semantics: a full commit id pins, a tag or
    /// branch tracks. Present means the item holds here while the source
    /// moves — this is what "manual updates" is; absent means the item
    /// follows the source.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl ItemDecl {
    pub fn from_source(source: &str) -> ItemDecl {
        ItemDecl {
            source: source.to_owned(),
            harnesses: None,
            method: None,
            rev: None,
            enabled: true,
        }
    }
}

/// Typed `[agent-frontmatter.<harness>.<agent>]` overrides — v1's field set.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct FrontmatterOverrides {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deny_tools: Option<Vec<String>>,
    /// Allow-only tool intent: replaces a source-side `tools:` allowlist for
    /// this harness. Distinct from `deny_tools`, which only narrows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allow_tools: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allowed_subagents: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub isolation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nickname_candidates: Option<Vec<String>>,
}

/// One declared plugin. The harness is part of the declaration because more
/// than one tool reads an `enabledPlugins` map of its own: without it, a
/// plugin meant for one tool would be switched on in every tool's settings,
/// which is a claim about software the user never installed there.
///
/// A declaration written before the harness was part of it belongs to Claude
/// Code — the only tool whose plugin switch kendex ever wrote — so that is
/// what an older manifest reads back as, and the next write records it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct PluginDecl {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_plugin_harness")]
    pub harness: HarnessId,
}

fn default_plugin_harness() -> HarnessId {
    HarnessId::Claude
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct CustomHook {
    /// Stable identity: the registry key, the lock key, the UI row. Absent
    /// in a hand-written entry until the editor's first save writes the
    /// derived slug back (`hook::name_custom_hooks`); derivation is
    /// deterministic, so an unnamed entry still plans consistently.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub matcher: Option<String>,
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Seconds; harnesses that count milliseconds convert on render.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout: Option<u32>,
    /// Harness allowlist; `None` = every declared harness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harnesses: Option<Vec<String>>,
    #[serde(default = "default_true", skip_serializing_if = "is_true")]
    pub enabled: bool,
    #[serde(default = "default_hook_agents")]
    pub agents: HookAgents,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(untagged)]
pub enum HookAgents {
    /// `"all"`, a role name, or a single agent name.
    One(String),
    Many(Vec<String>),
}

fn default_hook_agents() -> HookAgents {
    HookAgents::One("all".to_owned())
}

fn is_true(value: &bool) -> bool {
    *value
}

/// Where a fork came from. A fork keeps the item's installed name — the
/// declaration just switches to the local source, so nothing that depends
/// on the name breaks — and this records what it replaced. A fork made
/// beside the original takes a new name and records the same provenance:
/// what it was copied from, and at which commit. Manifest, not lock,
/// because the package page keeps reading it after any cache loss.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct ForkProvenance {
    /// Declared source name the original installed from.
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    /// The source commit the edited install was based on, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    pub forked_at: String,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct Manifest {
    pub schema: u32,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub sources: BTreeMap<String, SourceDecl>,
    #[serde(default)]
    pub install: InstallDefaults,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agents: BTreeMap<String, ItemDecl>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub skills: BTreeMap<String, ItemDecl>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub hooks: BTreeMap<String, ItemDecl>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub commands: BTreeMap<String, ItemDecl>,
    #[serde(
        default,
        skip_serializing_if = "BTreeMap::is_empty",
        rename = "mcp-servers"
    )]
    pub mcp_servers: BTreeMap<String, ItemDecl>,
    /// Plugins are observe + enable/disable only; the key is
    /// `name@marketplace`, provenance lives in the lock.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub plugins: BTreeMap<String, PluginDecl>,
    /// Installed bundles: a curated set the catalog offers under one name.
    /// What the set holds is the catalog's to say and derives on every plan;
    /// this records only that the set is installed, and how its members
    /// install — the same choices any declaration makes.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub bundles: BTreeMap<String, ItemDecl>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pi_extensions: BTreeMap<String, ItemDecl>,
    /// Items the user removed and wants kept removed, by kind: a dependency
    /// another item requires, or a member of an installed bundle. A refresh
    /// honors these instead of re-deriving what was taken away, and the item
    /// that wanted them says so in the audit.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub suppressed: BTreeMap<crate::model::ItemKind, Vec<String>>,
    /// Optional dependencies taken at install time, per item that offers
    /// them. A choice, so it belongs here and survives refresh, cache loss,
    /// and other machines; what those choices pull in does not.
    #[serde(
        default,
        skip_serializing_if = "BTreeMap::is_empty",
        rename = "optional-dependencies"
    )]
    pub optional_dependencies: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_skills: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_launch_instructions: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_additional_instructions: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub skill_instructions: BTreeMap<String, String>,
    /// `[agent-frontmatter.<harness>.<agent>]`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_frontmatter: BTreeMap<String, BTreeMap<String, FrontmatterOverrides>>,
    #[serde(
        default,
        skip_serializing_if = "Vec::is_empty",
        rename = "custom-hooks"
    )]
    pub custom_hooks: Vec<CustomHook>,
    /// Forked items by kind and name — `[forks.skill.<name>]`. The name is
    /// the item's installed name: the original's for a fork in place, the
    /// user's choice for one made beside the original.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub forks: BTreeMap<crate::model::ItemKind, BTreeMap<String, ForkProvenance>>,
}

impl Manifest {
    pub fn declared(&self, kind: crate::model::ItemKind) -> &BTreeMap<String, ItemDecl> {
        static EMPTY: std::sync::LazyLock<BTreeMap<String, ItemDecl>> =
            std::sync::LazyLock::new(BTreeMap::new);
        match kind {
            crate::model::ItemKind::Agent => &self.agents,
            crate::model::ItemKind::Skill => &self.skills,
            crate::model::ItemKind::Hook => &self.hooks,
            crate::model::ItemKind::Command => &self.commands,
            crate::model::ItemKind::McpServer => &self.mcp_servers,
            crate::model::ItemKind::PiExtension => &self.pi_extensions,
            crate::model::ItemKind::Plugin => &EMPTY,
        }
    }

    pub fn is_suppressed(&self, kind: crate::model::ItemKind, name: &str) -> bool {
        self.suppressed
            .get(&kind)
            .is_some_and(|names| names.iter().any(|held| held == name))
    }

    /// Whether this item stays out of the plan. A recorded removal only ever
    /// speaks for an item that would otherwise be derived — it is what keeps
    /// a dependency or a bundle member from coming back on its own. A
    /// declaration by name outranks it, the same way asking for the item
    /// again does, so a declared item installs and reports nothing missing.
    pub fn is_held_back(&self, kind: crate::model::ItemKind, name: &str) -> bool {
        self.is_suppressed(kind, name) && !self.declared(kind).contains_key(name)
    }

    /// Record that this item stays removed. Re-suppressing is a no-op, so a
    /// second removal of the same name writes nothing new.
    pub fn suppress(&mut self, kind: crate::model::ItemKind, name: &str) {
        if self.is_suppressed(kind, name) {
            return;
        }
        let names = self.suppressed.entry(kind).or_default();
        names.push(name.to_owned());
        names.sort();
    }

    pub fn declared_mut(
        &mut self,
        kind: crate::model::ItemKind,
    ) -> &mut BTreeMap<String, ItemDecl> {
        match kind {
            crate::model::ItemKind::Agent => &mut self.agents,
            crate::model::ItemKind::Skill => &mut self.skills,
            crate::model::ItemKind::Hook => &mut self.hooks,
            crate::model::ItemKind::Command => &mut self.commands,
            crate::model::ItemKind::McpServer => &mut self.mcp_servers,
            crate::model::ItemKind::PiExtension => &mut self.pi_extensions,
            crate::model::ItemKind::Plugin => {
                unreachable!("plugins declare through [plugins.<key>] with only an enabled flag")
            }
        }
    }
}

#[cfg(test)]
mod tests;
