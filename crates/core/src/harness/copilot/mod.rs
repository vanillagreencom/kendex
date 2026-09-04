use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::hook::{HookSpec, Registration};
use crate::model::{HarnessId, ItemKind};

pub mod settings;

pub struct Copilot;

/// Copilot's own hook events, and the fleet event each one answers to
/// ([hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference),
/// matrix §2, §D9). Copilot accepts a PascalCase
/// spelling of each name too; the camelCase one is what its reference
/// writes, so that is what kendex registers. An event with no counterpart
/// stays unmapped rather than hung on a near-miss — a safety hook on the
/// wrong event is worse than one the user is told did not install.
pub(crate) fn event(fleet: &str) -> Option<&'static str> {
    match fleet {
        "PreToolUse" => Some("preToolUse"),
        "PostToolUse" => Some("postToolUse"),
        "PermissionRequest" => Some("permissionRequest"),
        "UserPromptSubmit" => Some("userPromptSubmitted"),
        "SessionStart" => Some("sessionStart"),
        "SessionEnd" => Some("sessionEnd"),
        "PreCompact" => Some("preCompact"),
        "Notification" => Some("notification"),
        "Stop" => Some("agentStop"),
        "SubagentStop" => Some("subagentStop"),
        _ => None,
    }
}

/// The fleet event a name read out of Copilot's own registry answers to —
/// the inverse of [`event`], for reading a registration back. Copilot also
/// accepts a PascalCase spelling of each name, so both are recognised.
pub(crate) fn fleet_event(native: &str) -> Option<&'static str> {
    crate::hook::EVENTS
        .iter()
        .map(|held| held.name)
        .find(|fleet| event(fleet).is_some_and(|own| own.eq_ignore_ascii_case(native)))
}

/// The same hook said in Copilot's words: its own event name and its matcher
/// in its own tool names. `timeoutSec` is the seconds the source already
/// declares, so the timeout travels as written. `None` when Copilot has no
/// event that means what this one means.
pub fn hook_for(hook: &HookSpec) -> Option<Registration> {
    Some(Registration::new(
        hook,
        HarnessId::Copilot,
        event(&hook.event)?,
    ))
}

/// Copilot claims its own namespace and nothing else. It genuinely reads
/// `.claude/` and `.agents/` files too, but those belong to the harnesses
/// they are named for — claiming them would count one file on disk as two
/// installations (matrix §R6). The same rule keeps `.mcp.json` at a repo
/// root out of this list: it is evidence of MCP, not of Copilot (matrix §3).
impl HarnessAdapter for Copilot {
    fn id(&self) -> HarnessId {
        HarnessId::Copilot
    }

    /// `COPILOT_HOME` relocates the whole config root; hardcoding the home
    /// directory scans the wrong machine state for anyone who sets it
    /// (matrix §3, §R4).
    fn default_global_root(&self, env: &Env) -> PathBuf {
        match env.var("COPILOT_HOME") {
            Some(home) => PathBuf::from(home),
            None => env.home.join(".copilot"),
        }
    }

    /// `.github/` alone marks nearly every repository, so only the files and
    /// directories Copilot itself creates count (matrix §3).
    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[
            ProjectMarker::File(".github/copilot-instructions.md"),
            ProjectMarker::Dir(".github/agents"),
            ProjectMarker::Dir(".github/skills"),
            ProjectMarker::Dir(".github/hooks"),
        ]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        let settings = root.join("settings.json");
        match kind {
            ItemKind::Agent => vec![Surface::files(root.join("agents"), &["agent.md"])],
            ItemKind::Skill => vec![Surface::SubdirPerItem {
                dir: root.join("skills"),
                marker: "SKILL.md",
            }],
            // Each file under `hooks/` is a whole `{version, hooks}`
            // document, and the settings file carries a `hooks` key of the
            // same entries. Both are read; only the files are written, since
            // an inline entry has no per-hook switch to flip (matrix §R5).
            ItemKind::Hook => vec![
                Surface::StructuredDir {
                    dir: root.join("hooks"),
                    ext: "json",
                    reader: Reader::CopilotHooks,
                },
                Surface::Structured {
                    path: settings.clone(),
                    reader: Reader::CopilotHooks,
                },
            ],
            ItemKind::McpServer => vec![Surface::Structured {
                path: root.join("mcp-config.json"),
                reader: Reader::McpServersJson,
            }],
            ItemKind::Plugin => vec![Surface::Structured {
                path: settings,
                reader: Reader::CopilotPlugins,
            }],
            // Copilot has no file-backed slash-command surface in any of its
            // products: prompt files are IDE-only (matrix §D8).
            ItemKind::Command | ItemKind::PiExtension => vec![],
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, env: &Env) -> Vec<Surface> {
        let github = project.join(".github");
        // A repository keeps its settings in a shared file and a personal one
        // beside it, and Copilot reads both (matrix §2).
        let repo_settings = |reader: Reader| {
            settings::repo_settings_files(project)
                .into_iter()
                .map(move |path| Surface::Structured {
                    path,
                    reader: reader.clone(),
                })
        };
        match kind {
            ItemKind::McpServer => vec![Surface::Structured {
                path: github.join("mcp.json"),
                reader: Reader::McpServersJson,
            }],
            ItemKind::Hook => {
                let mut surfaces = vec![Surface::StructuredDir {
                    dir: github.join("hooks"),
                    ext: "json",
                    reader: Reader::CopilotHooks,
                }];
                surfaces.extend(repo_settings(Reader::CopilotHooks));
                surfaces
            }
            ItemKind::Plugin => repo_settings(Reader::CopilotPlugins).collect(),
            // Copilot reads the project's shared tree as well as
            // `.github/skills`, so an install is the shared one and its own
            // directory is what a per-tool copy writes (matrix §2).
            ItemKind::Skill => {
                super::shared_first(Some(&project.join(".agents/skills")), github.join("skills"))
            }
            other => self.global_surfaces(other, &github, env),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn copilot_home_var_relocates_the_root() {
        let env = Env::fake("/h", FakeOs::Linux);
        assert_eq!(
            Copilot.default_global_root(&env),
            PathBuf::from("/h/.copilot")
        );

        let env = env.with_var("COPILOT_HOME", "/elsewhere/copilot");
        assert_eq!(
            Copilot.default_global_root(&env),
            PathBuf::from("/elsewhere/copilot")
        );
    }

    #[test]
    fn agents_carry_the_double_extension_and_projects_live_under_github() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            let root = Copilot.default_global_root(&env);
            assert_eq!(
                Copilot.global_surfaces(ItemKind::Agent, &root, &env),
                [Surface::files(
                    PathBuf::from("/h/.copilot/agents"),
                    &["agent.md"]
                )]
            );
            assert_eq!(
                Copilot.project_surfaces(ItemKind::Agent, Path::new("/p"), &env),
                [Surface::files(
                    PathBuf::from("/p/.github/agents"),
                    &["agent.md"]
                )]
            );
        }
    }

    #[test]
    fn each_scope_reads_its_own_mcp_file() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Copilot.default_global_root(&env);
        assert_eq!(
            Copilot.global_surfaces(ItemKind::McpServer, &root, &env),
            [Surface::Structured {
                path: PathBuf::from("/h/.copilot/mcp-config.json"),
                reader: Reader::McpServersJson,
            }]
        );
        assert_eq!(
            Copilot.project_surfaces(ItemKind::McpServer, Path::new("/p"), &env),
            [Surface::Structured {
                path: PathBuf::from("/p/.github/mcp.json"),
                reader: Reader::McpServersJson,
            }]
        );
    }

    /// Hook files come first: they are the ones kendex writes, and the dir
    /// they live in is the one a hook target has to agree with.
    #[test]
    fn hooks_are_read_from_files_and_from_the_settings_they_can_also_live_in() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Copilot.default_global_root(&env);
        assert_eq!(
            Copilot.global_surfaces(ItemKind::Hook, &root, &env),
            [
                Surface::StructuredDir {
                    dir: PathBuf::from("/h/.copilot/hooks"),
                    ext: "json",
                    reader: Reader::CopilotHooks,
                },
                Surface::Structured {
                    path: PathBuf::from("/h/.copilot/settings.json"),
                    reader: Reader::CopilotHooks,
                },
            ]
        );
        assert_eq!(
            Copilot.project_surfaces(ItemKind::Hook, Path::new("/p"), &env),
            [
                Surface::StructuredDir {
                    dir: PathBuf::from("/p/.github/hooks"),
                    ext: "json",
                    reader: Reader::CopilotHooks,
                },
                Surface::Structured {
                    path: PathBuf::from("/p/.github/copilot/settings.json"),
                    reader: Reader::CopilotHooks,
                },
                Surface::Structured {
                    path: PathBuf::from("/p/.github/copilot/settings.local.json"),
                    reader: Reader::CopilotHooks,
                },
            ]
        );
    }

    #[test]
    fn plugins_are_the_enabled_map_in_whichever_settings_file_a_scope_has() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Copilot.default_global_root(&env);
        assert_eq!(
            Copilot.global_surfaces(ItemKind::Plugin, &root, &env),
            [Surface::Structured {
                path: PathBuf::from("/h/.copilot/settings.json"),
                reader: Reader::CopilotPlugins,
            }]
        );
        let project = Copilot.project_surfaces(ItemKind::Plugin, Path::new("/p"), &env);
        assert_eq!(project.len(), 2);
        assert!(project.contains(&Surface::Structured {
            path: PathBuf::from("/p/.github/copilot/settings.json"),
            reader: Reader::CopilotPlugins,
        }));
    }

    #[test]
    fn only_the_events_copilot_documents_are_registered() {
        assert_eq!(event("PreToolUse"), Some("preToolUse"));
        assert_eq!(event("Stop"), Some("agentStop"));
        assert_eq!(event("TaskCompleted"), None);
    }
}
