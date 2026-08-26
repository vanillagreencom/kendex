use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind};

pub struct Cursor;

impl HarnessAdapter for Cursor {
    fn id(&self) -> HarnessId {
        HarnessId::Cursor
    }

    fn default_global_root(&self, env: &Env) -> PathBuf {
        env.home.join(".cursor")
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[ProjectMarker::Dir(".cursor")]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        match kind {
            // v1 manages cursor project-only; there is no global rules dir.
            ItemKind::Agent | ItemKind::Skill | ItemKind::PiExtension => vec![],
            ItemKind::Hook => vec![Surface::Structured {
                path: root.join("hooks.json"),
                reader: Reader::HooksObject,
            }],
            ItemKind::Command => vec![Surface::files(root.join("commands"), &["md"])],
            ItemKind::McpServer => vec![Surface::Structured {
                path: root.join("mcp.json"),
                reader: Reader::McpServersJson,
            }],
            ItemKind::Plugin => vec![Surface::Structured {
                path: root.join("plugins"),
                reader: Reader::CursorPluginDirs,
            }],
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let dot = project.join(".cursor");
        match kind {
            ItemKind::Agent => vec![Surface::files(dot.join("rules"), &["mdc"])],
            // Cursor reads the shared tree in a project (its own skills
            // documentation names no directory of its own, and the rules dir
            // cannot tell a skill from an agent). Shared physical target with
            // codex and pi — scan dedupe couples them.
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: project.join(".agents/skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Plugin | ItemKind::PiExtension => vec![],
            ItemKind::Hook => vec![Surface::Structured {
                path: dot.join("hooks.json"),
                reader: Reader::HooksObject,
            }],
            ItemKind::Command => vec![Surface::files(dot.join("commands"), &["md"])],
            ItemKind::McpServer => vec![Surface::Structured {
                path: dot.join("mcp.json"),
                reader: Reader::McpServersJson,
            }],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn rules_are_project_only_mdc_files() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            let root = Cursor.default_global_root(&env);
            assert!(
                Cursor
                    .global_surfaces(ItemKind::Agent, &root, &env)
                    .is_empty()
            );
            assert_eq!(
                Cursor.project_surfaces(ItemKind::Agent, Path::new("/p"), &env),
                [Surface::files(PathBuf::from("/p/.cursor/rules"), &["mdc"])]
            );
        }
    }

    #[test]
    fn global_command_and_mcp_surfaces_exist() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Cursor.default_global_root(&env);
        assert_eq!(
            Cursor.global_surfaces(ItemKind::Command, &root, &env),
            [Surface::files(
                PathBuf::from("/h/.cursor/commands"),
                &["md"]
            )]
        );
        assert_eq!(
            Cursor.global_surfaces(ItemKind::McpServer, &root, &env),
            [Surface::Structured {
                path: PathBuf::from("/h/.cursor/mcp.json"),
                reader: Reader::McpServersJson,
            }]
        );
    }
}
