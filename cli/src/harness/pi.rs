use crate::agent::{self, Agent, AgentRole};
use crate::hook::Hook;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Generate a Pi agent file (`<scope>/agents/<name>.md`).
///
/// Pi has no built-in subagents; agent files only act as agent definitions when
/// a Pi package that loads `agents/*.md` is also installed. Even then, the
/// markdown body is the canonical place for vstack-managed prose, so we emit
/// the same skill preamble / hook prose / additional instructions sections
/// that other harnesses use.
///
/// Frontmatter format:
/// ```yaml
/// ---
/// name: rust
/// description: "..."
/// deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question
/// model: claude-opus-4-5
/// color: green
/// pane: true
/// ---
/// ```
pub fn generate_agent(
    agent: &Agent,
    dir: &Path,
    skills: &[(String, String)],
    optional_skills: &[(String, String)],
    _hooks: &[Hook],
    extras: &agent::AgentExtras,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;

    let path = dir.join(format!("{}.md", agent.name));

    let frontmatter = extras.frontmatter_for("pi");
    let model = frontmatter
        .model
        .as_deref()
        .map(|model| pi_model_for_with_effort(model, pi_effort_for(agent, &frontmatter)))
        .unwrap_or_else(|| {
            pi_model_for_with_effort(&agent.model, pi_effort_for(agent, &frontmatter))
        });
    let deny_tools = pi_deny_tools_for(agent, &frontmatter);

    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!("name: {}\n", agent.name));

    let desc = agent.description.replace('\\', "\\\\").replace('"', "\\\"");
    output.push_str(&format!("description: \"{}\"\n", desc));
    if !deny_tools.is_empty() {
        output.push_str(&format!("deny-tools: {}\n", deny_tools.join(", ")));
    }
    output.push_str(&format!("model: {}\n", model));
    if let Some(color) = frontmatter
        .color
        .as_ref()
        .or(extras.color.as_ref())
        .or(agent.color.as_ref())
    {
        output.push_str(&format!("color: {}\n", color));
    }
    let pane = frontmatter.pane.unwrap_or_else(|| {
        matches!(agent.role, AgentRole::Engineer) || agent.name.eq_ignore_ascii_case("planner")
    });
    if pane {
        output.push_str("pane: true\n");
    }
    output.push_str("---\n\n");

    output.push_str("> **Never edit this file directly.** To make additions or modifications, edit the appropriate section in `./vstack.toml`. Then run `vstack refresh`.\n\n");

    let guidance = agent::guidance_section(extras.guidance.as_deref());
    let skills_section = agent::load_skills_section(skills, optional_skills);
    let combined = format!("{}{}", guidance, skills_section);
    let body = agent::insert_after_intro(&agent.body, &combined);
    let hooks_prose = agent::custom_hooks_section(&extras.custom_hooks);
    let instructions = agent::instructions_section(extras.instructions.as_deref());
    let body = agent::append_section(&body, &hooks_prose);
    let body = agent::append_section(&body, &instructions);
    output.push_str(&body);

    if !output.ends_with('\n') {
        output.push('\n');
    }

    std::fs::write(&path, &output)?;
    Ok(path)
}

/// Map vstack canonical model names to Pi model identifiers.
///
/// Pi defaults to OpenAI models for vstack-managed agents. Pi accepts
/// `provider/model` and an optional `:thinking` shorthand (per the Pi
/// `--model` flag), so when an effort is configured we encode it alongside
/// the model id.
fn pi_model_for_with_effort(model: &str, effort: Option<String>) -> String {
    let effort_suffix = effort
        .filter(|effort| !is_none_value(effort))
        .map(|effort| format!(":{effort}"))
        .unwrap_or_default();
    match model.to_lowercase().as_str() {
        "opus" | "sonnet" | "haiku" => format!("openai-codex/gpt-5.5{effort_suffix}"),
        other => other.into(),
    }
}

fn pi_effort_for(agent: &Agent, frontmatter: &agent::AgentFrontmatterOverrides) -> Option<String> {
    frontmatter
        .model_reasoning_effort
        .clone()
        .or_else(|| frontmatter.effort.clone())
        .or_else(|| agent.effort.clone())
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

fn pi_deny_tools_for(agent: &Agent, frontmatter: &agent::AgentFrontmatterOverrides) -> Vec<String> {
    let mut tools = pi_default_deny_tools_for(agent);
    if let Some(deny_tools) = &frontmatter.deny_tools {
        tools.extend(deny_tools.clone());
    }
    dedupe_pi_tool_names(tools)
}

fn pi_default_deny_tools_for(agent: &Agent) -> Vec<String> {
    let mut tools = vec![
        "subagent".into(),
        "get_subagent_result".into(),
        "steer_subagent".into(),
        "stop_subagent".into(),
    ];
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("question".into());
    }
    tools
}

fn dedupe_pi_tool_names(tools: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    tools
        .into_iter()
        .filter(|tool| !tool.trim().is_empty())
        .filter(|tool| seen.insert(normalize_pi_tool_name(tool)))
        .collect()
}

fn normalize_pi_tool_name(tool: &str) -> String {
    tool.trim().to_ascii_lowercase().replace('-', "_")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{Agent, AgentExtras, AgentRole};

    fn agent_fixture(name: &str, role: AgentRole, model: &str) -> Agent {
        Agent {
            name: name.into(),
            description: "Pi test agent".into(),
            model: model.into(),
            role,
            color: Some("green".into()),
            effort: None,
            body: format!("# {name}\n\nIntro.\n\n## Capabilities\n\nDoes work.\n"),
            source_path: PathBuf::new(),
        }
    }

    #[test]
    fn pi_model_mapping() {
        assert_eq!(
            pi_model_for_with_effort("opus", Some("xhigh".into())),
            "openai-codex/gpt-5.5:xhigh"
        );
        assert_eq!(
            pi_model_for_with_effort("sonnet", Some("high".into())),
            "openai-codex/gpt-5.5:high"
        );
        assert_eq!(
            pi_model_for_with_effort("haiku", Some("medium".into())),
            "openai-codex/gpt-5.5:medium"
        );
        assert_eq!(
            pi_model_for_with_effort("opus", None),
            "openai-codex/gpt-5.5"
        );
        assert_eq!(pi_model_for_with_effort("custom-id", None), "custom-id");
    }

    #[test]
    fn generate_agent_writes_pi_frontmatter_and_body() {
        let dir = std::env::temp_dir().join(format!("vstack_pi_agent_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        agent.effort = Some("xhigh".into());
        let extras = AgentExtras {
            color: Some("magenta".into()),
            guidance: Some("Read open issues and start.".into()),
            instructions: Some("Run clippy before commits.".into()),
            ..AgentExtras::default()
        };
        let skills = vec![(
            "rust-arch".into(),
            "Architecture patterns for Rust: more details.".into(),
        )];
        let path = generate_agent(&agent, &dir, &skills, &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("name: rust"));
        assert!(content.contains("model: openai-codex/gpt-5.5:xhigh"));
        assert!(content.contains("color: magenta"));
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question"
        ));
        assert!(content.contains("pane: true"));
        assert!(content.contains("## Launch Instructions"));
        assert!(content.contains("Read open issues and start."));
        // vstack: body skill table cut; replaced by a one-line preamble.
        assert!(content.contains("## Skills"));
        assert!(content.contains("Load any skill whose name or description matches"));
        assert!(content.contains("## Additional Instructions"));
        assert!(content.contains("Never edit this file directly"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_planner_runs_in_pane_and_keeps_question_available() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_agent_planner_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("planner", AgentRole::Engineer, "sonnet");
        let extras = AgentExtras::default();
        let path = generate_agent(&agent, &dir, &[], &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("pane: true"));
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(deny_line.contains("subagent"));
        assert!(deny_line.contains("get_subagent_result"));
        assert!(deny_line.contains("steer_subagent"));
        assert!(deny_line.contains("stop_subagent"));
        assert!(!deny_line.contains("question"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_applies_effort_override_to_pi_model_suffix() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_agent_effort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst, "haiku");
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                effort: Some("xhigh".into()),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model: openai-codex/gpt-5.5:xhigh"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_omits_suffix_when_no_effort() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_agent_no_effort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst, "opus");
        let path = generate_agent(&agent, &dir, &[], &[], &[], &AgentExtras::default())
            .expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model: openai-codex/gpt-5.5\n"));
        assert!(!content.contains("model: openai-codex/gpt-5.5:"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_ignores_explicit_tools_override_and_applies_deny_tools() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_agent_deny_tools_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                tools: Some(vec![
                    "read".into(),
                    "bash".into(),
                    "write".into(),
                    "apply_patch".into(),
                ]),
                deny_tools: Some(vec!["bash".into(), "apply-patch".into()]),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question, bash, apply-patch"
        ));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_reviewer_omits_pane_and_can_write_reports() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_agent_reviewer_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut agent = agent_fixture("reviewer-arch", AgentRole::Reviewer, "sonnet");
        agent.effort = Some("high".into());
        let extras = AgentExtras::default();
        let path = generate_agent(&agent, &dir, &[], &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model: openai-codex/gpt-5.5:high"));
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question"
        ));
        assert!(!content.contains("pane: true"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
