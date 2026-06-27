use crate::agent::{self, Agent, AgentRole};
use crate::hook::Hook;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Generate a Codex agent file (.codex/agents/<name>.toml)
///
/// Format: TOML with name, description, model, sandbox_mode,
/// and developer_instructions (the agent body).
///
/// Hooks are NOT rendered here — codex hooks install as native shell hooks via
/// `installer::install_hook_codex` (which writes `<scope>/.codex/hooks/*.sh`,
/// merges `<scope>/.codex/hooks.json`, and toggles `[features] hooks = true`).
/// The `_hooks` parameter exists only to keep the harness trait shape
/// uniform.
pub fn generate_agent(
    agent: &Agent,
    global: bool,
    dir: &Path,
    skills: &[(String, String)],
    _hooks: &[Hook],
    extras: &agent::AgentExtras,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;

    let path = dir.join(format!("{}.toml", agent.name));

    let frontmatter = extras.frontmatter_for("codex");

    // Map role to sandbox_mode unless project config supplies an exact value.
    let sandbox_mode = frontmatter
        .sandbox_mode
        .as_deref()
        .unwrap_or(match agent.role {
            // Analysts/reviewers still need to write report artifacts; prompts constrain them to report-only work.
            AgentRole::Analyst | AgentRole::Reviewer | AgentRole::Manager => "workspace-write",
            AgentRole::Engineer => "danger-full-access",
        });

    let lower = agent.model.to_lowercase();
    let model = match lower.as_str() {
        "opus" | "sonnet" | "haiku" => "gpt-5.5",
        other => other,
    };
    let model_override = frontmatter.model.as_deref().map(codex_model_for_override);
    let model = model_override.as_deref().unwrap_or(model);
    let reasoning_effort = frontmatter
        .model_reasoning_effort
        .clone()
        .or_else(|| frontmatter.effort.clone())
        .or_else(|| agent.effort.clone())
        .filter(|effort| !is_none_value(effort));
    let nickname_candidates = frontmatter
        .nickname_candidates
        .clone()
        .map(|candidates| {
            candidates
                .into_iter()
                .map(|candidate| candidate.trim().to_string())
                .filter(|candidate| !candidate.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|candidates| !candidates.is_empty())
        .unwrap_or_else(|| default_nickname_candidates(&agent.name));

    // Build TOML manually to control format (triple-quoted developer_instructions)
    let mut output = String::new();
    output.push_str("# Never edit this file directly. To make additions or modifications, edit the appropriate section in ./vstack.toml. Then run `vstack refresh`.\n\n");
    output.push_str(&format!("name = \"{}\"\n", escape_toml(&agent.name)));
    output.push_str(&format!(
        "nickname_candidates = {}\n",
        toml_string_array(&nickname_candidates)
    ));
    output.push_str(&format!(
        "description = \"{}\"\n",
        escape_toml(&agent.description)
    ));
    output.push_str(&format!("model = \"{model}\"\n"));
    if let Some(effort) = &reasoning_effort {
        output.push_str(&format!("model_reasoning_effort = \"{effort}\"\n"));
    }
    output.push_str(&format!("sandbox_mode = \"{sandbox_mode}\"\n"));

    // Developer instructions as multiline TOML string
    output.push_str("developer_instructions = '''\n");

    let guidance = agent::guidance_section(extras.guidance.as_deref());
    let skills_section = agent::load_skills_section();
    let required_skills = required_skills_section(skills, global);
    let combined = format!("{}{}{}", guidance, skills_section, required_skills);
    let body = agent::insert_after_intro(&agent.body, &combined);
    let hooks_prose = agent::custom_hooks_section(&extras.custom_hooks);
    let instructions = agent::instructions_section(extras.instructions.as_deref());
    let body = agent::append_section(&body, &hooks_prose);
    let body = agent::append_section(&body, &instructions);
    output.push_str(&body);

    if !output.ends_with('\n') {
        output.push('\n');
    }
    output.push_str("'''\n");

    std::fs::write(&path, &output)?;
    Ok(path)
}

fn required_skills_section(skills: &[(String, String)], global: bool) -> String {
    if skills.is_empty() {
        return String::new();
    }

    let mut section = String::from("## Required Skills\n\n");
    section.push_str(
        "Load these skills before using their workflows. Prefer the listed local path when it exists; if a path is missing, report the missing install instead of substituting a stale global path.\n\n",
    );
    for (name, description) in skills {
        section.push_str(&format!(
            "- `{}`: {} (`{}`)\n",
            name,
            description.trim(),
            codex_skill_md_path(name, global)
        ));
    }
    section.push('\n');
    section
}

fn codex_skill_md_path(name: &str, global: bool) -> String {
    if global {
        crate::config::codex_home_dir()
            .join("skills")
            .join(name)
            .join("SKILL.md")
            .display()
            .to_string()
    } else {
        format!(".agents/skills/{name}/SKILL.md")
    }
}

fn escape_toml(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn default_nickname_candidates(agent_name: &str) -> Vec<String> {
    const SUFFIXES: &[&str] = &["Atlas", "Delta", "Echo", "Nova", "Orion", "Vector"];
    let prefix = display_agent_name(agent_name);
    SUFFIXES
        .iter()
        .map(|suffix| format!("{prefix}-{suffix}"))
        .collect()
}

fn display_agent_name(agent_name: &str) -> String {
    let parts = agent_name
        .trim()
        .split(|ch: char| ch == '-' || ch == '_' || ch.is_whitespace())
        .filter(|part| !part.is_empty())
        .map(display_agent_name_part)
        .collect::<Vec<_>>();
    if parts.is_empty() {
        "Agent".into()
    } else {
        parts.join("-")
    }
}

fn display_agent_name_part(part: &str) -> String {
    if part.eq_ignore_ascii_case("tpm") {
        return "TPM".into();
    }
    let mut chars = part.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };
    let mut out = String::new();
    out.extend(first.to_uppercase());
    for ch in chars {
        out.extend(ch.to_lowercase());
    }
    out
}

fn toml_string_array(values: &[String]) -> String {
    let values = values
        .iter()
        .map(|value| format!("\"{}\"", escape_toml(value)))
        .collect::<Vec<_>>()
        .join(", ");
    format!("[{values}]")
}

fn codex_model_for_override(model: &str) -> String {
    match model.to_lowercase().as_str() {
        "opus" | "sonnet" | "haiku" => "gpt-5.5".into(),
        other => other.into(),
    }
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{AgentExtras, AgentRole};

    fn agent_fixture(name: &str, role: AgentRole) -> Agent {
        Agent {
            name: name.into(),
            description: "Codex test agent".into(),
            model: "sonnet".into(),
            role,
            color: None,
            effort: None,
            body: format!("# {name}\n\nIntro.\n"),
            source_path: PathBuf::new(),
        }
    }

    #[test]
    fn manager_defaults_to_workspace_write() {
        let dir = std::env::temp_dir().join(format!("vstack_codex_manager_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("tpm", AgentRole::Manager);
        let path = generate_agent(&agent, false, &dir, &[], &[], &AgentExtras::default())
            .expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("sandbox_mode = \"workspace-write\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_name_prefixed_nickname_candidates() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_codex_nickname_default_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("reviewer-arch", AgentRole::Reviewer);
        let path = generate_agent(&agent, false, &dir, &[], &[], &AgentExtras::default())
            .expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(
            content.contains(
                "nickname_candidates = [\"Reviewer-Arch-Atlas\", \"Reviewer-Arch-Delta\""
            )
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn default_nickname_candidates_preserve_known_acronyms() {
        assert_eq!(
            default_nickname_candidates("tpm")[0],
            "TPM-Atlas".to_string()
        );
    }

    #[test]
    fn nickname_candidates_can_be_overridden() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_codex_nickname_override_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                nickname_candidates: Some(vec!["Rust-One".into(), "Rust-Two".into()]),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, false, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("nickname_candidates = [\"Rust-One\", \"Rust-Two\"]"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn shared_effort_override_is_written_verbatim() {
        let dir = std::env::temp_dir().join(format!("vstack_codex_effort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst);
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                effort: Some("xhigh".into()),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, false, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model_reasoning_effort = \"xhigh\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn omits_effort_when_unset() {
        let dir =
            std::env::temp_dir().join(format!("vstack_codex_no_effort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst);
        let path = generate_agent(&agent, false, &dir, &[], &[], &AgentExtras::default())
            .expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("model_reasoning_effort"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writes_project_local_required_skills_without_unsupported_top_level_field() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_codex_skills_project_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let skills = vec![
            (
                "dev".into(),
                "Delegated implementation and review-fix workflows.".into(),
            ),
            ("github".into(), "GitHub workflow helpers.".into()),
        ];
        let path = generate_agent(&agent, false, &dir, &skills, &[], &AgentExtras::default())
            .expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("\nskills = "));
        assert!(content.contains("## Required Skills"));
        assert!(content.contains("`.agents/skills/dev/SKILL.md`"));
        assert!(!content.contains(".codex/skills/dev/SKILL.md"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn global_inventory_uses_codex_home_skills() {
        let dir =
            std::env::temp_dir().join(format!("vstack_codex_skills_global_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let skills = vec![("dev".into(), "Delegated implementation.".into())];
        let path = generate_agent(&agent, true, &dir, &skills, &[], &AgentExtras::default())
            .expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        let expected = crate::config::codex_home_dir()
            .join("skills")
            .join("dev")
            .join("SKILL.md")
            .display()
            .to_string();
        assert!(content.contains(&format!("`{expected}`")));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
