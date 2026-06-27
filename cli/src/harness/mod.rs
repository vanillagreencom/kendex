pub mod claude;
pub mod codex;
pub mod cursor;
pub mod opencode;
pub mod pi;

use crate::agent::Agent;
use crate::skill::Skill;
use anyhow::{Result, bail};
use std::path::PathBuf;

/// Supported AI coding harnesses
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Harness {
    ClaudeCode,
    Cursor,
    OpenCode,
    Codex,
    Pi,
}

impl Harness {
    pub const ALL: &[Harness] = &[
        Harness::ClaudeCode,
        Harness::Cursor,
        Harness::OpenCode,
        Harness::Codex,
        Harness::Pi,
    ];

    pub fn name(&self) -> &'static str {
        match self {
            Harness::ClaudeCode => "Claude Code",
            Harness::Cursor => "Cursor",
            Harness::OpenCode => "OpenCode",
            Harness::Codex => "Codex",
            Harness::Pi => "Pi",
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Harness::ClaudeCode => "claude-code",
            Harness::Cursor => "cursor",
            Harness::OpenCode => "opencode",
            Harness::Codex => "codex",
            Harness::Pi => "pi",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "claude-code" | "claude" => Some(Harness::ClaudeCode),
            "cursor" => Some(Harness::Cursor),
            "opencode" => Some(Harness::OpenCode),
            "codex" => Some(Harness::Codex),
            "pi" => Some(Harness::Pi),
            _ => None,
        }
    }

    pub fn supports_global_scope(&self) -> bool {
        !matches!(self, Harness::Cursor)
    }

    pub fn global_support_reason(&self) -> Option<&'static str> {
        match self {
            Harness::Cursor => {
                Some("Cursor user rules are configured in settings, not a global rules directory.")
            }
            _ => None,
        }
    }

    /// Directory for agents relative to project/home root
    pub fn agents_dir(&self, global: bool) -> PathBuf {
        match self {
            Harness::ClaudeCode => {
                if global {
                    crate::config::claude_global_dir().join("agents")
                } else {
                    crate::config::project_root().join(".claude").join("agents")
                }
            }
            Harness::Cursor => {
                if global {
                    crate::config::cursor_global_dir().join("rules")
                } else {
                    crate::config::project_root().join(".cursor").join("rules")
                }
            }
            Harness::OpenCode => {
                if global {
                    crate::config::opencode_global_dir().join("agents")
                } else {
                    crate::config::project_root()
                        .join(".opencode")
                        .join("agents")
                }
            }
            Harness::Codex => {
                if global {
                    crate::config::codex_home_dir().join("agents")
                } else {
                    crate::config::project_root().join(".codex").join("agents")
                }
            }
            Harness::Pi => {
                if global {
                    crate::config::pi_global_dir().join("agents")
                } else {
                    crate::config::pi_project_dir().join("agents")
                }
            }
        }
    }

    /// Directory for skills relative to project/home root
    pub fn skills_dir(&self, global: bool) -> PathBuf {
        match self {
            Harness::ClaudeCode => {
                if global {
                    crate::config::claude_global_dir().join("skills")
                } else {
                    crate::config::project_root().join(".claude").join("skills")
                }
            }
            Harness::Cursor => {
                if global {
                    crate::config::cursor_global_dir().join("rules")
                } else {
                    crate::config::project_root().join(".cursor").join("rules")
                }
            }
            Harness::OpenCode => {
                if global {
                    crate::config::opencode_global_dir().join("skills")
                } else {
                    crate::config::project_root()
                        .join(".opencode")
                        .join("skills")
                }
            }
            Harness::Codex => {
                if global {
                    crate::config::codex_home_dir().join("skills")
                } else {
                    crate::config::project_root().join(".agents").join("skills")
                }
            }
            Harness::Pi => {
                // Pi loads skills from ~/.pi/agent/skills (global) and from
                // .agents/skills (project, also picked up by Codex). Sharing
                // the project skill location keeps the skill-tree single-rooted.
                if global {
                    crate::config::pi_global_dir().join("skills")
                } else {
                    crate::config::project_root().join(".agents").join("skills")
                }
            }
        }
    }

    pub fn hooks_dir(&self, global: bool) -> Option<PathBuf> {
        match self {
            Harness::ClaudeCode => Some(if global {
                crate::config::claude_global_dir().join("hooks")
            } else {
                crate::config::project_root().join(".claude").join("hooks")
            }),
            _ => None,
        }
    }

    pub fn install_root(&self, global: bool) -> PathBuf {
        match self {
            Harness::ClaudeCode => {
                if global {
                    crate::config::claude_global_dir()
                } else {
                    crate::config::project_root().join(".claude")
                }
            }
            Harness::Cursor => {
                if global {
                    crate::config::cursor_global_dir()
                } else {
                    crate::config::project_root().join(".cursor")
                }
            }
            Harness::OpenCode => {
                if global {
                    crate::config::opencode_global_dir()
                } else {
                    crate::config::project_root().join(".opencode")
                }
            }
            Harness::Codex => {
                if global {
                    crate::config::codex_home_dir()
                } else {
                    crate::config::project_root().join(".codex")
                }
            }
            Harness::Pi => {
                if global {
                    crate::config::pi_global_dir()
                } else {
                    crate::config::pi_project_dir()
                }
            }
        }
    }

    pub fn summary_paths(&self, global: bool) -> Vec<PathBuf> {
        let mut paths = vec![self.install_root(global)];
        if matches!(self, Harness::OpenCode) {
            let config_path = if global {
                crate::config::opencode_global_config_path()
            } else {
                crate::config::opencode_project_config_path()
            };
            if !paths.contains(&config_path) {
                paths.push(config_path);
            }
        }
        if matches!(self, Harness::Pi) {
            let settings_path = crate::config::pi_settings_path(global);
            if !paths.contains(&settings_path) {
                paths.push(settings_path);
            }
        }
        paths
    }

    /// Filename for a generated agent in this harness
    pub fn agent_filename(&self, name: &str) -> String {
        match self {
            Harness::ClaudeCode | Harness::OpenCode | Harness::Pi => format!("{name}.md"),
            Harness::Cursor => format!("{name}.mdc"),
            Harness::Codex => format!("{name}.toml"),
        }
    }

    /// Generate a harness-specific agent file and return the output path
    pub fn generate_agent(
        &self,
        agent: &Agent,
        global: bool,
        skills: &[(String, String)],
        hooks: &[crate::hook::Hook],
        extras: &crate::agent::AgentExtras,
    ) -> Result<PathBuf> {
        if global && !self.supports_global_scope() {
            bail!(
                "{}",
                self.global_support_reason()
                    .unwrap_or("Global scope is unsupported")
            );
        }
        let dir = self.agents_dir(global);
        match self {
            Harness::ClaudeCode => claude::generate_agent(agent, &dir, skills, hooks, extras),
            Harness::Cursor => cursor::generate_agent(agent, &dir, skills, hooks, extras),
            Harness::OpenCode => opencode::generate_agent(agent, &dir, skills, hooks, extras),
            Harness::Codex => codex::generate_agent(agent, global, &dir, skills, hooks, extras),
            Harness::Pi => pi::generate_agent(agent, &dir, skills, hooks, extras),
        }
    }

    /// Install a skill directory to the harness-specific location
    pub fn install_skill(&self, skill: &Skill, global: bool) -> Result<PathBuf> {
        if global && !self.supports_global_scope() {
            bail!(
                "{}",
                self.global_support_reason()
                    .unwrap_or("Global scope is unsupported")
            );
        }
        let dest = self.skills_dir(global).join(&skill.name);
        Ok(dest)
    }

    /// Check if this harness is detected on the system
    pub fn is_detected(&self) -> bool {
        let project = crate::config::project_root();
        match self {
            Harness::ClaudeCode => crate::config::claude_global_dir().exists(),
            Harness::Cursor => crate::config::cursor_global_dir().exists(),
            Harness::OpenCode => {
                crate::config::opencode_global_dir().exists()
                    || crate::config::opencode_global_config_path().exists()
                    || project.join("opencode.json").exists()
                    || project.join("opencode.jsonc").exists()
            }
            Harness::Codex => crate::config::codex_home_dir().exists(),
            Harness::Pi => {
                crate::config::pi_global_dir().exists()
                    || project.join(".pi").is_dir()
                    || pi_binary_on_path()
            }
        }
    }
}

/// Best-effort `pi` binary detection used by `Harness::Pi.is_detected()`.
fn pi_binary_on_path() -> bool {
    let Some(path_var) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join("pi");
        if candidate.is_file() {
            return true;
        }
    }
    false
}

impl std::fmt::Display for Harness {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

#[cfg(test)]
mod tests {
    use super::Harness;

    #[test]
    fn cursor_is_project_scope_only() {
        assert!(!Harness::Cursor.supports_global_scope());
        assert!(Harness::ClaudeCode.supports_global_scope());
        assert!(Harness::OpenCode.supports_global_scope());
        assert!(Harness::Codex.supports_global_scope());
        assert!(Harness::Pi.supports_global_scope());
    }

    #[test]
    fn pi_id_round_trip() {
        assert_eq!(Harness::Pi.id(), "pi");
        assert_eq!(Harness::Pi.name(), "Pi");
        assert_eq!(Harness::from_id("pi"), Some(Harness::Pi));
    }

    #[test]
    fn pi_in_all() {
        assert!(Harness::ALL.contains(&Harness::Pi));
    }

    #[test]
    fn pi_agent_filename_uses_md() {
        assert_eq!(Harness::Pi.agent_filename("rust"), "rust.md");
    }

    #[test]
    fn pi_paths_use_pi_dir() {
        // Project paths go under .pi/ — independent of any environment overrides
        let proj_agents = Harness::Pi.agents_dir(false);
        assert!(
            proj_agents.ends_with(".pi/agents"),
            "expected .pi/agents, got {proj_agents:?}"
        );
        let proj_root = Harness::Pi.install_root(false);
        assert!(
            proj_root.ends_with(".pi"),
            "expected .pi, got {proj_root:?}"
        );
        // Project skills location is shared with Codex (.agents/skills) so Pi
        // can pick them up via its `~/.agents/skills` discovery path too.
        let proj_skills = Harness::Pi.skills_dir(false);
        assert!(
            proj_skills.ends_with(".agents/skills"),
            "expected .agents/skills, got {proj_skills:?}"
        );
    }

    #[test]
    fn pi_global_paths_honor_env_override() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_env_override_{}", std::process::id()));

        crate::test_util::with_pi_dir(&sandbox, || {
            let agents_dir = Harness::Pi.agents_dir(true);
            let skills_dir = Harness::Pi.skills_dir(true);
            let install_root = Harness::Pi.install_root(true);

            assert!(
                agents_dir.starts_with(&sandbox),
                "expected agents under {sandbox:?}, got {agents_dir:?}"
            );
            assert!(
                skills_dir.starts_with(&sandbox),
                "expected skills under {sandbox:?}, got {skills_dir:?}"
            );
            assert_eq!(install_root, sandbox);
        });
    }
}
