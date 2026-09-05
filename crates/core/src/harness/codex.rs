use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind};

pub struct Codex;

impl HarnessAdapter for Codex {
    fn id(&self) -> HarnessId {
        HarnessId::Codex
    }

    fn default_global_root(&self, env: &Env) -> PathBuf {
        match env.var("CODEX_HOME") {
            Some(home) => PathBuf::from(home),
            None => env.home.join(".codex"),
        }
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[ProjectMarker::Dir(".codex"), ProjectMarker::Dir(".agents")]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        match kind {
            ItemKind::Agent => vec![Surface::files(root.join("agents"), &["toml"])],
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: root.join("skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Hook => vec![Surface::Structured {
                path: root.join("hooks.json"),
                reader: Reader::HooksObject,
            }],
            // Codex removed custom prompts in 0.118, so `~/.codex/prompts`
            // is read by nothing and a command is a skill (see caps).
            ItemKind::Command => vec![],
            ItemKind::McpServer => vec![Surface::Structured {
                path: root.join("config.toml"),
                reader: Reader::McpServersToml,
            }],
            ItemKind::Plugin => vec![Surface::Structured {
                path: root.join("plugins"),
                reader: Reader::CodexPluginCache,
            }],
            ItemKind::PiExtension => vec![],
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let dot = project.join(".codex");
        match kind {
            ItemKind::Agent => vec![Surface::files(dot.join("agents"), &["toml"])],
            // Shared physical target with pi — scan dedupe couples them.
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: project.join(".agents/skills"),
                marker: "SKILL.md",
            }],
            ItemKind::Hook => vec![Surface::Structured {
                path: dot.join("hooks.json"),
                reader: Reader::HooksObject,
            }],
            ItemKind::McpServer => vec![Surface::Structured {
                path: dot.join("config.toml"),
                reader: Reader::McpServersToml,
            }],
            ItemKind::Command | ItemKind::Plugin | ItemKind::PiExtension => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn codex_home_var_relocates_the_root() {
        let env = Env::fake("/h", FakeOs::Linux);
        assert_eq!(Codex.default_global_root(&env), PathBuf::from("/h/.codex"));

        let env = env.with_var("CODEX_HOME", "/elsewhere/codex");
        assert_eq!(
            Codex.default_global_root(&env),
            PathBuf::from("/elsewhere/codex")
        );
    }

    #[test]
    fn agents_are_toml_and_skills_share_the_agents_tree() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            let surfaces = Codex.project_surfaces(ItemKind::Agent, Path::new("/p"), &env);
            assert_eq!(
                surfaces,
                [Surface::files(PathBuf::from("/p/.codex/agents"), &["toml"])]
            );
            let skills = Codex.project_surfaces(ItemKind::Skill, Path::new("/p"), &env);
            assert_eq!(
                skills,
                [Surface::SubdirPerItem {
                    dir: PathBuf::from("/p/.agents/skills"),
                    marker: "SKILL.md",
                }]
            );
        }
    }
}
