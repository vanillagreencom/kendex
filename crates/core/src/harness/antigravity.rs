use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::hook::{HookSpec, Registration};
use crate::model::{HarnessId, ItemKind};

/// Antigravity CLI (`agy`). Customizations live under one root per scope,
/// `~/.gemini/config` and the workspace's `.agents/`, in the same layout
/// but for agents: `skills/<name>/SKILL.md`, `rules/*.md`, `hooks.json`,
/// `mcp_config.json`, `plugins/<name>/plugin.json` at either scope, and
/// `agents/<name>.md` at the global root alone (the CLI's embedded
/// customization guide, which names no agent customization type). Settings
/// sit apart under `~/.gemini/antigravity-cli/`.
pub struct Antigravity;

/// Antigravity's own hook events, and the fleet event each one answers to
/// (the CLI's embedded hooks guide, <https://antigravity.google/docs/hooks>).
/// The three it shares with the fleet are spelled the same way;
/// `PreInvocation` and `PostInvocation` wrap a model call, which no fleet
/// event means, so they stay unmapped rather than hung on a near-miss.
pub(crate) fn event(fleet: &str) -> Option<&'static str> {
    match fleet {
        "PreToolUse" => Some("PreToolUse"),
        "PostToolUse" => Some("PostToolUse"),
        "Stop" => Some("Stop"),
        _ => None,
    }
}

/// The same hook said in Antigravity's words: its own event name and its
/// matcher in its own tool names. `None` when it has no event that means
/// what this one means.
pub fn hook_for(hook: &HookSpec) -> Option<Registration> {
    Some(Registration::new(
        hook,
        HarnessId::Antigravity,
        event(&hook.event)?,
    ))
}

fn surfaces(kind: ItemKind, root: &Path, shared: Option<&Path>) -> Vec<Surface> {
    match kind {
        ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
        ItemKind::Skill => super::shared_first(shared, root.join("skills")),
        // `mcp_config.json` carries the `mcpServers` map every other tool
        // reads, a remote server keyed `serverUrl`.
        ItemKind::McpServer => vec![Surface::Structured {
            path: root.join("mcp_config.json"),
            reader: Reader::McpServersJson,
        }],
        // A plugin is a directory carrying its manifest under the root.
        ItemKind::Plugin => vec![Surface::SubdirPerItem {
            dir: root.join("plugins"),
            marker: "plugin.json",
        }],
        // One registry per scope, keyed by hook name; the scripts kendex
        // writes sit in a `hooks/` beside it that the loader never scans.
        ItemKind::Hook => vec![Surface::Structured {
            path: root.join("hooks.json"),
            reader: Reader::AntigravityHooks,
        }],
        // Skills are the slash commands.
        ItemKind::Command | ItemKind::PiExtension => vec![],
    }
}

impl HarnessAdapter for Antigravity {
    fn id(&self) -> HarnessId {
        HarnessId::Antigravity
    }

    /// No documented variable relocates the customization root.
    fn default_global_root(&self, env: &Env) -> PathBuf {
        env.home.join(".gemini").join("config")
    }

    /// `.agents/` alone is Codex's and Pi's too; only the entries the
    /// Antigravity loader is the sole reader of mark a workspace.
    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[
            ProjectMarker::Dir(".agents/rules"),
            ProjectMarker::File(".agents/hooks.json"),
            ProjectMarker::File(".agents/mcp_config.json"),
        ]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        surfaces(kind, root, None)
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let root = project.join(".agents");
        // The workspace root is the shared tree: one `.agents/skills` serves
        // Codex, Pi and Antigravity, so there is no second directory to
        // list.
        match kind {
            ItemKind::Skill => vec![Surface::skills(root.join("skills"))],
            // `agy` reads agents from the global root alone, so a workspace
            // `agents/` is nothing kendex writes or scans.
            ItemKind::Agent => vec![],
            other => surfaces(other, &root, None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn the_scopes_share_one_layout_but_for_agents_which_the_global_root_holds_alone() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Antigravity.default_global_root(&env);
        assert_eq!(root, PathBuf::from("/h/.gemini/config"));
        assert_eq!(
            Antigravity.global_surfaces(ItemKind::Agent, &root, &env),
            [Surface::files(
                PathBuf::from("/h/.gemini/config/agents"),
                &["md"]
            )]
        );
        assert!(
            Antigravity
                .project_surfaces(ItemKind::Agent, Path::new("/p"), &env)
                .is_empty()
        );
        assert_eq!(
            Antigravity.project_surfaces(ItemKind::Skill, Path::new("/p"), &env),
            [Surface::skills(PathBuf::from("/p/.agents/skills"))]
        );
        assert_eq!(
            Antigravity.global_surfaces(ItemKind::Plugin, &root, &env),
            [Surface::SubdirPerItem {
                dir: PathBuf::from("/h/.gemini/config/plugins"),
                marker: "plugin.json",
            }]
        );
        assert_eq!(
            Antigravity.project_surfaces(ItemKind::Plugin, Path::new("/p"), &env),
            [Surface::SubdirPerItem {
                dir: PathBuf::from("/p/.agents/plugins"),
                marker: "plugin.json",
            }]
        );
        assert_eq!(
            Antigravity.project_surfaces(ItemKind::Hook, Path::new("/p"), &env),
            [Surface::Structured {
                path: PathBuf::from("/p/.agents/hooks.json"),
                reader: Reader::AntigravityHooks,
            }]
        );
    }

    #[test]
    fn only_the_events_antigravity_documents_are_registered() {
        assert_eq!(event("PreToolUse"), Some("PreToolUse"));
        assert_eq!(event("Stop"), Some("Stop"));
        assert_eq!(event("SessionStart"), None);
    }
}
