use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind};

/// Antigravity CLI (`agy`). Customizations live under one root per scope,
/// `~/.gemini/config` and the workspace's `.agents/`, in the same layout:
/// `agents/<name>.md`, `skills/<name>/SKILL.md`, `rules/*.md`,
/// `hooks.json`, `mcp_config.json`, `plugins/<name>/plugin.json` (the
/// CLI's embedded customization guide and
/// <https://antigravity.google/docs/cli/subagents/>). Settings sit apart
/// under `~/.gemini/antigravity-cli/`.
pub struct Antigravity;

fn surfaces(kind: ItemKind, root: &Path, shared: Option<&Path>) -> Vec<Surface> {
    match kind {
        ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
        ItemKind::Skill => super::shared_first(shared, root.join("skills")),
        // `mcp_config.json` carries the `mcpServers` map every other tool
        // reads; a remote server is keyed `serverUrl`, so it is read here
        // and never written.
        ItemKind::McpServer => vec![Surface::Structured {
            path: root.join("mcp_config.json"),
            reader: Reader::McpServersJson,
        }],
        // A plugin is a directory carrying its manifest under the root.
        ItemKind::Plugin => vec![Surface::SubdirPerItem {
            dir: root.join("plugins"),
            marker: "plugin.json",
        }],
        // Skills are the slash commands; hooks run from `hooks.json`, a
        // registry kendex neither reads nor writes yet.
        ItemKind::Command | ItemKind::Hook | ItemKind::PiExtension => vec![],
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
            ProjectMarker::Dir(".agents/agents"),
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
            other => surfaces(other, &root, None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn both_scopes_share_one_layout_and_the_project_skills_are_the_shared_tree() {
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
        assert_eq!(
            Antigravity.project_surfaces(ItemKind::Agent, Path::new("/p"), &env),
            [Surface::files(PathBuf::from("/p/.agents/agents"), &["md"])]
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
            []
        );
    }
}
