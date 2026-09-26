use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, ProjectPath, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind};

pub struct Claude;

impl HarnessAdapter for Claude {
    fn id(&self) -> HarnessId {
        HarnessId::Claude
    }

    fn default_global_root(&self, env: &Env) -> PathBuf {
        env.home.join(".claude")
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[
            ProjectMarker::Dir(".claude"),
            ProjectMarker::File(".mcp.json"),
        ]
    }

    fn project_reads(&self) -> &'static [ProjectPath] {
        &[]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, env: &Env) -> Vec<Surface> {
        match kind {
            ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: root.join("skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Hook => vec![Surface::Structured {
                path: root.join("settings.json"),
                reader: Reader::HooksObject,
            }],
            ItemKind::Command => vec![Surface::files(root.join("commands"), &["md"])],
            ItemKind::McpServer => vec![Surface::Structured {
                path: env.home.join(".claude.json"),
                reader: Reader::ClaudeUserMcp,
            }],
            ItemKind::Plugin => vec![Surface::Structured {
                path: root.join("plugins/installed_plugins.json"),
                reader: Reader::ClaudePluginRegistry,
            }],
            ItemKind::PiExtension => vec![],
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, env: &Env) -> Vec<Surface> {
        let dot = project.join(".claude");
        match kind {
            ItemKind::Agent => vec![Surface::files(dot.join("agents"), &["md"])],
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: dot.join("skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Hook => vec![
                Surface::Structured {
                    path: dot.join("settings.json"),
                    reader: Reader::HooksObject,
                },
                Surface::Structured {
                    path: dot.join("settings.local.json"),
                    reader: Reader::HooksObject,
                },
            ],
            ItemKind::Command => vec![Surface::files(dot.join("commands"), &["md"])],
            ItemKind::McpServer => vec![
                Surface::Structured {
                    path: project.join(".mcp.json"),
                    reader: Reader::McpServersJson,
                },
                Surface::Structured {
                    path: env.home.join(".claude.json"),
                    reader: Reader::ClaudeUserProjectMcp {
                        project: project.to_path_buf(),
                    },
                },
            ],
            ItemKind::Plugin => vec![
                Surface::Structured {
                    path: dot.join("settings.json"),
                    reader: Reader::ClaudeSettingsPlugins,
                },
                Surface::Structured {
                    path: dot.join("settings.local.json"),
                    reader: Reader::ClaudeSettingsPlugins,
                },
            ],
            ItemKind::PiExtension => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn paths_are_home_anchored_on_every_os() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            let root = Claude.default_global_root(&env);
            assert_eq!(root, PathBuf::from("/h/.claude"));

            let agents = Claude.global_surfaces(ItemKind::Agent, &root, &env);
            assert_eq!(
                agents,
                [Surface::files(PathBuf::from("/h/.claude/agents"), &["md"])]
            );

            let mcp = Claude.global_surfaces(ItemKind::McpServer, &root, &env);
            assert_eq!(
                mcp,
                [Surface::Structured {
                    path: PathBuf::from("/h/.claude.json"),
                    reader: Reader::ClaudeUserMcp,
                }]
            );
        }
    }

    #[test]
    fn project_mcp_reads_both_repo_file_and_user_file() {
        let env = Env::fake("/h", FakeOs::Linux);
        let surfaces = Claude.project_surfaces(ItemKind::McpServer, Path::new("/h/dev/p"), &env);
        assert_eq!(
            surfaces,
            [
                Surface::Structured {
                    path: PathBuf::from("/h/dev/p/.mcp.json"),
                    reader: Reader::McpServersJson,
                },
                Surface::Structured {
                    path: PathBuf::from("/h/.claude.json"),
                    reader: Reader::ClaudeUserProjectMcp {
                        project: PathBuf::from("/h/dev/p"),
                    },
                },
            ]
        );
    }
}
