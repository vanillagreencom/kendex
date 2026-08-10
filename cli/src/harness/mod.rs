pub mod claude;
pub mod codex;
pub mod cursor;
pub mod opencode;
pub mod pi;

use crate::agent::Agent;
use crate::skill::Skill;
use anyhow::{Result, bail};
use std::path::{Path, PathBuf};

pub(super) fn checked_agent_path(dir: &Path, name: &str, extension: &str) -> Result<PathBuf> {
    crate::path_safety::validate_item_name(name)?;
    let path = dir.join(format!("{name}.{extension}"));
    if !path.starts_with(dir) {
        bail!(
            "refusing agent path outside expected directory: {}",
            path.display()
        );
    }
    Ok(path)
}

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
        // Every generated agent body points at the canonical failure-reporting
        // reference; make sure the scope's copy exists and is current, then
        // substitute the scope-resolved path for the source body's placeholder.
        crate::agent::install_failure_reporting_reference(global)?;
        let agent = crate::agent::resolve_failure_reference(agent, global);
        let agent = &agent;
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
    use crate::agent::{Agent, AgentRole};

    fn agent_fixture(name: &str) -> Agent {
        Agent {
            name: name.into(),
            description: "Test agent".into(),
            model: "sonnet".into(),
            role: AgentRole::Engineer,
            color: None,
            effort: None,
            body: format!("# {name}\n\nIntro.\n\n## Capabilities\n\n- Testing\n"),
            source_path: Default::default(),
        }
    }

    #[test]
    fn generate_agent_installs_failure_reporting_reference() {
        let root = std::env::temp_dir().join(format!(
            "vstack_failure_reporting_ref_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();

        crate::test_util::with_project_root(&project, || {
            Harness::ClaudeCode
                .generate_agent(
                    &agent_fixture("rust"),
                    false,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();
        });

        let reference = project.join(".agents").join("skill-failure-reporting.md");
        let content = std::fs::read_to_string(&reference).expect("reference installed");
        assert_eq!(content, crate::agent::FAILURE_REPORTING_DOC);
        assert!(
            content.contains("provenly incorrect guidance"),
            "canonical doc must carry the full decision tree"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn generate_agent_renders_shared_and_specific_instructions_in_order() {
        let root = std::env::temp_dir().join(format!(
            "vstack_shared_key_render_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();

        let config: crate::project_config::ProjectConfig = toml::from_str(
            "[agent-launch-instructions]\nall = \"Shared launch.\"\nrust = \"Rust launch.\"\n\
             [agent-additional-instructions]\nall = \"Shared extra.\"\n",
        )
        .unwrap();
        let agent = agent_fixture("rust");
        let extras = crate::resolve::build_agent_extras(&config, &agent.name, &agent.role, None);

        let content = crate::test_util::with_project_root(&project, || {
            let path = Harness::ClaudeCode
                .generate_agent(&agent, false, &[], &[], &extras)
                .unwrap();
            std::fs::read_to_string(path).unwrap()
        });

        let marked_launch = crate::project_config::ProjectConfig::mark_shared("Shared launch.");
        assert!(
            content.contains(&format!(
                "## Launch Instructions\n\n{marked_launch}\n\nRust launch."
            )),
            "merged launch instructions render marked shared first: {content}"
        );
        let marked_extra = crate::project_config::ProjectConfig::mark_shared("Shared extra.");
        assert!(
            content.contains(&format!("## Additional Instructions\n\n{marked_extra}")),
            "shared-only additional instructions render marked: {content}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn generate_agent_substitutes_failure_reference_token_per_scope() {
        let root = std::env::temp_dir().join(format!(
            "vstack_failure_ref_token_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let project = root.join("project");
        let home = root.join("home");
        let config_dir = root.join("config");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&config_dir).unwrap();

        let mut agent = agent_fixture("rust");
        agent.body = format!(
            "# rust\n\nIntro. Full rules: `{}`.\n\n## Capabilities\n\n- Testing\n",
            crate::agent::FAILURE_REF_TOKEN
        );

        // Project scope: the token becomes the project-relative path.
        let content = crate::test_util::with_project_root(&project, || {
            let path = Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    false,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();
            std::fs::read_to_string(path).unwrap()
        });
        assert!(
            content.contains("`.agents/skill-failure-reporting.md`"),
            "project scope substitutes the relative path: {content}"
        );
        assert!(
            !content.contains("{{"),
            "no unsubstituted placeholder may leak: {content}"
        );

        // Global scope: the token becomes the resolved config-dir path.
        let content = crate::test_util::with_home_and_config(&home, &config_dir, || {
            let path = Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    true,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();
            std::fs::read_to_string(path).unwrap()
        });
        let expected = crate::config::display_path(
            &config_dir.join("vstack").join("skill-failure-reporting.md"),
        );
        assert!(
            content.contains(&format!("`{expected}`")),
            "global scope substitutes the config-dir path {expected}: {content}"
        );
        assert!(
            !content.contains("{{"),
            "no unsubstituted placeholder may leak: {content}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn generate_agent_skips_reference_install_through_symlinked_agents_ancestor() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_failure_ref_symlink_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let project = root.join("project");
        let outside_agents = root.join("outside-agents");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&outside_agents).unwrap();
        symlink(&outside_agents, project.join(".agents")).unwrap();

        // Generation itself is not `.agents`-routed for claude-code and must
        // still succeed; only the reference write is withheld, so nothing
        // lands outside the project.
        let path = crate::test_util::with_project_root(&project, || {
            Harness::ClaudeCode
                .generate_agent(
                    &agent_fixture("rust"),
                    false,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap()
        });

        assert!(path.exists(), "agent file generated at {path:?}");
        assert!(
            !outside_agents.join("skill-failure-reporting.md").exists(),
            "reference must not be written outside the project"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

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

    #[cfg(unix)]
    #[test]
    fn generate_agent_rejects_final_symlink() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack-agent-symlink-{}-{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let outside = root.join("outside.md");
        let link = project.join(".claude").join("agents").join("rust.md");
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        std::fs::write(&outside, "keep").unwrap();
        symlink(&outside, &link).unwrap();

        let agent = Agent {
            name: "rust".into(),
            description: "Rust".into(),
            model: "sonnet".into(),
            role: AgentRole::Engineer,
            color: None,
            effort: None,
            body: "# Rust\n".into(),
            source_path: std::path::PathBuf::new(),
        };

        let err = crate::test_util::with_project_root(&project, || {
            Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    false,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap_err()
        });
        assert!(
            err.to_string()
                .contains("refusing to write through symlink")
        );
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep");

        let _ = std::fs::remove_dir_all(&root);
    }
}
