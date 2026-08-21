use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::model::{DetectedHarness, HarnessId, ItemKind};

pub mod claude;
pub mod codex;
pub mod copilot;
pub mod cursor;
pub mod gemini;
pub mod opencode;
pub mod pi;

mod caps;
pub mod models;
pub use caps::{
    CANONICAL_SEPARATOR, Enforcement, FormatCaps, KindCaps, McpTransport, NameRule, OpSupport,
    canonical_name, capabilities, format_caps, installable, installs_here, namespace_separator,
    pi_listener, rendered_name,
};

/// What a hook label may claim for this harness at this scope. The static
/// row says what the mechanism supports; Pi's enforcement is real only
/// while the pi-hooks carrier is registered somewhere Pi loads, so every
/// surface that labels an installation reads this instead of the row.
pub fn hook_enforcement(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    harness: HarnessId,
) -> Enforcement {
    match harness {
        HarnessId::Pi => crate::pi_ext::carrier::enforcement(env, scope),
        _ => capabilities(harness, crate::model::ItemKind::Hook).enforcement,
    }
}

/// What marks a directory as a project for this harness during discovery.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectMarker {
    Dir(&'static str),
    File(&'static str),
}

/// A place the scanner reads one kind from, plus how items are stored there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Surface {
    /// `<dir>/<name>.<ext>` — one item per file, one folder level of
    /// namespacing included (`ns/name.md` → item `ns/name`). A `.disabled`
    /// suffix on the full filename marks a disabled item. A non-empty
    /// `prefixes` restricts to filenames starting with one of them —
    /// opencode hook instructions, where files written before the product
    /// rename carry the old spelling and must stay owned.
    FileDir {
        dir: PathBuf,
        exts: &'static [&'static str],
        prefixes: &'static [&'static str],
    },
    /// `<dir>/<name>/<marker>` — one item per subdirectory holding the
    /// marker file (`<marker>.disabled` marks a disabled item).
    SubdirPerItem { dir: PathBuf, marker: &'static str },
    /// Items are entries inside a structured file or tree; the reader names
    /// the harness-specific format the scanner must parse.
    Structured { path: PathBuf, reader: Reader },
    /// `<dir>/*.<ext>` — every file in the directory is a document of its
    /// own holding entries, all read by the same reader. Copilot's hook
    /// files work this way: what the file is called says nothing, and the
    /// entries inside it are the items.
    StructuredDir {
        dir: PathBuf,
        ext: &'static str,
        reader: Reader,
    },
}

impl Surface {
    pub fn files(dir: PathBuf, exts: &'static [&'static str]) -> Surface {
        Surface::FileDir {
            dir,
            exts,
            prefixes: &[],
        }
    }
}

/// Harness-specific structured formats. One variant per real on-disk format;
/// the scanner owns the parsing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reader {
    /// `{"mcpServers": {...}}` — claude `.mcp.json`, cursor `mcp.json`
    McpServersJson,
    /// `~/.claude.json` top-level `mcpServers`
    ClaudeUserMcp,
    /// `~/.claude.json` `projects.<root>.mcpServers`
    ClaudeUserProjectMcp { project: PathBuf },
    /// gemini settings `mcpServers`, joined with the global file recording
    /// whether each server is switched on and the settings `mcp.excluded`
    /// list
    GeminiMcp,
    /// codex `config.toml` `[mcp_servers.<name>]`
    McpServersToml,
    /// opencode config `mcp` key — jsonc tolerated, per-entry `enabled`
    OpencodeMcp,
    /// opencode config `plugin` array — npm plugin refs
    OpencodePluginRefs,
    /// `{"hooks": {"<Event>": [{matcher?, hooks: [{command}]} | {command}]}}`
    /// — claude settings.json, codex/cursor hooks.json
    HooksObject,
    /// `{version, disableAllHooks, hooks: {<event>: [{type, bash|powershell|
    /// command|url|prompt, matcher, timeoutSec}]}}` — copilot's hook files
    /// and the `hooks` key of its settings. Its entries carry the command
    /// themselves, so reading them as `HooksObject` would name every one of
    /// them after nothing (matrix §2, §7).
    CopilotHooks,
    /// copilot settings `enabledPlugins` — `{"<plugin>@<marketplace>": bool}`
    CopilotPlugins,
    /// `~/.claude/plugins/installed_plugins.json` joined with settings
    /// `enabledPlugins`
    ClaudePluginRegistry,
    /// project `.claude/settings.json` + `.claude/settings.local.json`
    /// `enabledPlugins` entries
    ClaudeSettingsPlugins,
    /// `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` tree with
    /// `.codex-plugin/plugin.json`, toggles in config.toml `[plugins]`
    CodexPluginCache,
    /// `~/.cursor/plugins/{local,cache}` tree with `.cursor-plugin/plugin.json`
    CursorPluginDirs,
    /// pi `settings.json` `packages[]` entries
    PiPackages,
}

pub trait HarnessAdapter: Send + Sync {
    fn id(&self) -> HarnessId;

    /// Where the harness keeps global state when no settings override is set.
    fn default_global_root(&self, env: &Env) -> PathBuf;

    fn detect(&self, env: &Env, global_root: &Path) -> Option<DetectedHarness> {
        let _ = env;
        global_root.is_dir().then(|| DetectedHarness {
            harness: self.id(),
            root: global_root.to_path_buf(),
            version: None,
        })
    }

    fn project_markers(&self) -> &'static [ProjectMarker];

    /// Every read surface for `kind` at global scope. Empty = unsupported.
    fn global_surfaces(&self, kind: ItemKind, root: &Path, env: &Env) -> Vec<Surface>;

    /// Every read surface for `kind` inside a project. Empty = unsupported.
    fn project_surfaces(&self, kind: ItemKind, project: &Path, env: &Env) -> Vec<Surface>;
}

pub fn all_adapters() -> [&'static dyn HarnessAdapter; 7] {
    [
        &claude::Claude,
        &codex::Codex,
        &opencode::Opencode,
        &cursor::Cursor,
        &pi::Pi,
        &gemini::Gemini,
        &copilot::Copilot,
    ]
}

pub fn adapter(id: HarnessId) -> &'static dyn HarnessAdapter {
    match id {
        HarnessId::Claude => &claude::Claude,
        HarnessId::Codex => &codex::Codex,
        HarnessId::Opencode => &opencode::Opencode,
        HarnessId::Cursor => &cursor::Cursor,
        HarnessId::Pi => &pi::Pi,
        HarnessId::Gemini => &gemini::Gemini,
        HarnessId::Copilot => &copilot::Copilot,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn adapter_registry_is_complete_and_ordered() {
        let ids: Vec<_> = all_adapters().iter().map(|a| a.id()).collect();
        assert_eq!(ids, HarnessId::ALL);
        for id in HarnessId::ALL {
            assert_eq!(adapter(id).id(), id);
        }
    }

    /// The capability table's observe column must mirror what the adapters
    /// actually declare — UI gating and scan behavior cannot drift apart.
    #[test]
    fn observe_capabilities_match_declared_surfaces() {
        let env = Env::fake("/home/user", FakeOs::Linux);
        let project = Path::new("/home/user/dev/proj");
        for a in all_adapters() {
            let root = a.default_global_root(&env);
            for kind in ItemKind::ALL {
                let caps = capabilities(a.id(), kind);
                assert_eq!(
                    caps.observe.global,
                    !a.global_surfaces(kind, &root, &env).is_empty(),
                    "{}/{} global observe",
                    a.id().name(),
                    kind.name(),
                );
                assert_eq!(
                    caps.observe.project,
                    !a.project_surfaces(kind, project, &env).is_empty(),
                    "{}/{} project observe",
                    a.id().name(),
                    kind.name(),
                );
            }
        }
    }

    /// One kind stored as another is the whole of the cross-kind mapping:
    /// a renderer exists for exactly this pair, so a new entry in the
    /// table must arrive with the renderer that serves it.
    #[test]
    fn the_only_kind_stored_as_another_is_a_codex_command() {
        for harness in HarnessId::ALL {
            for kind in ItemKind::ALL {
                if let Some(emitted) = capabilities(harness, kind).installs_as {
                    assert_eq!(
                        (harness, kind, emitted),
                        (HarnessId::Codex, ItemKind::Command, ItemKind::Skill)
                    );
                }
            }
        }
    }

    /// A hook the tool merely reads must never be presented as one it runs.
    /// Every harness with a hook surface says which it is, and the harnesses
    /// without one are exactly the rows that say nothing.
    #[test]
    fn every_hook_row_says_whether_the_tool_runs_it() {
        for harness in HarnessId::ALL {
            let hook = capabilities(harness, ItemKind::Hook);
            let observed = hook.observe.project || hook.observe.global;
            assert_eq!(
                hook.enforcement == Enforcement::NotApplicable,
                !observed,
                "{} hook enforcement",
                harness.name(),
            );
            for kind in ItemKind::ALL.into_iter().filter(|k| *k != ItemKind::Hook) {
                assert_eq!(
                    capabilities(harness, kind).enforcement,
                    Enforcement::NotApplicable,
                    "{}/{} claims enforcement",
                    harness.name(),
                    kind.name(),
                );
            }
        }
    }

    /// The transport list and the MCP row describe one fact from two sides:
    /// a harness that reads no servers has no way to reach one.
    #[test]
    fn mcp_transports_agree_with_the_mcp_row() {
        for harness in HarnessId::ALL {
            let mcp = capabilities(harness, ItemKind::McpServer);
            assert_eq!(
                format_caps(harness).mcp_transports.is_empty(),
                mcp.observe == caps::NONE,
                "{} mcp transports",
                harness.name(),
            );
        }
    }

    /// Copilot is managed where its own documentation gives kendex a surface
    /// to write, and nowhere else: it has no file-backed command kind at all,
    /// and installing a plugin needs a marketplace kendex cannot resolve yet.
    #[test]
    fn copilot_manages_only_the_surfaces_it_documents() {
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Hook,
            ItemKind::McpServer,
        ] {
            let c = capabilities(HarnessId::Copilot, kind);
            assert_eq!(c.install, caps::BOTH, "{} install", kind.name());
            assert_eq!(c.remove, caps::BOTH, "{} remove", kind.name());
        }
        assert_eq!(
            capabilities(HarnessId::Copilot, ItemKind::Hook).enforcement,
            Enforcement::Enforced,
        );
        let command = capabilities(HarnessId::Copilot, ItemKind::Command);
        assert_eq!((command.observe, command.install), (caps::NONE, caps::NONE));
        let plugin = capabilities(HarnessId::Copilot, ItemKind::Plugin);
        assert_eq!((plugin.toggle, plugin.install), (caps::BOTH, caps::NONE));
    }

    /// Gemini declares an MCP server per scope but records whether it is on
    /// in one global file, so the switch exists only where that file lives.
    /// Everything else it manages works the same at both scopes.
    #[test]
    fn a_gemini_server_installs_per_scope_and_switches_off_globally() {
        let mcp = capabilities(HarnessId::Gemini, ItemKind::McpServer);
        assert_eq!(mcp.install, caps::BOTH);
        assert_eq!(mcp.remove, caps::BOTH);
        assert_eq!(mcp.toggle, caps::GLOBAL);
        for kind in [
            ItemKind::Agent,
            ItemKind::Skill,
            ItemKind::Command,
            ItemKind::Hook,
        ] {
            let c = capabilities(HarnessId::Gemini, kind);
            assert_eq!(c.install, caps::BOTH, "{} install", kind.name());
            assert_eq!(c.toggle, caps::BOTH, "{} toggle", kind.name());
        }
        // Extensions install globally only and their enablement is an
        // undocumented path-rule file, so they stay read-only (matrix §R1).
        assert_eq!(
            capabilities(HarnessId::Gemini, ItemKind::Plugin).install,
            caps::NONE
        );
    }

    /// Nothing may be mutable where what it writes cannot be observed. A
    /// kind the harness stores as another one is checked against that
    /// kind's surfaces, because that is where its artifact lands.
    #[test]
    fn no_capability_exceeds_observation() {
        for harness in HarnessId::ALL {
            for kind in ItemKind::ALL {
                let c = capabilities(harness, kind);
                let written = match c.installs_as {
                    Some(emitted) => capabilities(harness, emitted).observe,
                    None => c.observe,
                };
                for (op, sup, observe) in [
                    ("adopt", c.adopt, c.observe),
                    ("install", c.install, written),
                    ("toggle", c.toggle, written),
                    ("remove", c.remove, written),
                    ("refresh", c.refresh, written),
                ] {
                    assert!(
                        (!sup.project || observe.project) && (!sup.global || observe.global),
                        "{}/{}: {op} exceeds observe",
                        harness.name(),
                        kind.name(),
                    );
                }
            }
        }
    }
}
