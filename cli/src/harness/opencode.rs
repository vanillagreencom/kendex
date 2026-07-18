use crate::agent::{self, Agent};
use crate::hook::Hook;
use anyhow::Result;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Generate an OpenCode agent as a markdown file in `.opencode/agents/<name>.md`.
///
/// Format: YAML frontmatter (description, mode, model, permission)
/// followed by the agent body as the system prompt.
pub fn generate_agent(
    agent: &Agent,
    dir: &Path,
    _skills: &[(String, String)],
    _hooks: &[Hook],
    extras: &agent::AgentExtras,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;

    let path = super::checked_agent_path(dir, &agent.name, "md")?;

    let frontmatter = extras.frontmatter_for("opencode");
    let mode = opencode_mode_for(&frontmatter);

    let model = frontmatter
        .model
        .as_deref()
        .map(|model| agent::model_id_for("openai", model))
        .unwrap_or_else(|| agent.model_id("openai"));
    let reasoning_effort = opencode_reasoning_effort_for(agent, &frontmatter);
    let color = opencode_color_for(agent, extras, &frontmatter);

    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!("description: {}\n", yaml_str(&agent.description)));
    output.push_str(&format!("mode: {mode}\n"));
    output.push_str(&format!("model: {model}\n"));
    if let Some(color) = color {
        output.push_str(&format!("color: {}\n", yaml_str(&color)));
    }
    if let Some(reasoning_effort) = reasoning_effort {
        output.push_str("options:\n");
        output.push_str(&format!("  reasoningEffort: {reasoning_effort}\n"));
        output.push_str("  reasoningSummary: auto\n");
        output.push_str("  textVerbosity: medium\n");
    }

    let denied_permissions = opencode_denied_permissions_for(agent, &frontmatter, mode);
    if !denied_permissions.is_empty() {
        output.push_str("permission:\n");
        for permission in denied_permissions {
            output.push_str(&format!("  {permission}: deny\n"));
        }
    }

    output.push_str("---\n\n");
    output.push_str("> **Never edit this file directly.** To make additions or modifications, edit the appropriate section in `./vstack.toml`. Then run `vstack refresh`.\n\n");

    let guidance = agent::guidance_section(extras.guidance.as_deref());
    let skills_section = agent::load_skills_section();
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

    crate::path_safety::write_file_no_follow(&path, &output)?;
    Ok(path)
}

/// Escape a YAML string value — quote if it contains special characters
fn yaml_str(s: &str) -> String {
    if s.contains(':') || s.contains('#') || s.contains('"') || s.contains('\'') || s.contains('\n')
    {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

fn opencode_reasoning_effort_for(
    agent: &Agent,
    frontmatter: &agent::AgentFrontmatterOverrides,
) -> Option<String> {
    frontmatter
        .model_reasoning_effort
        .clone()
        .or_else(|| frontmatter.effort.clone())
        .or_else(|| agent.effort.clone())
        .filter(|effort| !is_none_value(effort))
}

fn opencode_mode_for(frontmatter: &agent::AgentFrontmatterOverrides) -> &str {
    match frontmatter.mode.as_deref() {
        Some(mode) if mode.trim().eq_ignore_ascii_case("all") => "subagent",
        Some(mode) if !mode.trim().is_empty() => mode,
        _ => "subagent",
    }
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

fn opencode_color_for(
    agent: &Agent,
    extras: &agent::AgentExtras,
    frontmatter: &agent::AgentFrontmatterOverrides,
) -> Option<String> {
    frontmatter
        .color
        .as_ref()
        .or(extras.color.as_ref())
        .or(agent.color.as_ref())
        .and_then(|color| opencode_color_name(color))
}

fn opencode_color_name(color: &str) -> Option<String> {
    let trimmed = color.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('#')
        && trimmed.len() == 7
        && trimmed.chars().skip(1).all(|c| c.is_ascii_hexdigit())
    {
        return Some(trimmed.to_string());
    }
    let mapped = match trimmed.to_ascii_lowercase().as_str() {
        "red" | "error" => "#ef4444",
        "green" | "success" => "#22c55e",
        "yellow" | "warning" => "#eab308",
        "orange" => "#f97316",
        "blue" | "primary" | "info" => "#3b82f6",
        "cyan" | "teal" => "#06b6d4",
        "purple" | "violet" | "magenta" | "accent" => "#a855f7",
        "pink" => "#ec4899",
        "secondary" => "#64748b",
        _ => return None,
    };
    Some(mapped.to_string())
}

fn opencode_denied_permissions_for(
    agent: &Agent,
    frontmatter: &agent::AgentFrontmatterOverrides,
    mode: &str,
) -> Vec<String> {
    let mut tools = opencode_default_deny_tools_for(agent, mode);
    if let Some(deny_tools) = &frontmatter.deny_tools {
        tools.extend(deny_tools.clone());
    }
    dedupe_permissions(
        tools
            .iter()
            .filter_map(|tool| opencode_permission_name(tool))
            .collect(),
    )
}

fn opencode_default_deny_tools_for(agent: &Agent, mode: &str) -> Vec<String> {
    if !mode.eq_ignore_ascii_case("subagent") {
        return Vec::new();
    }
    let mut tools = vec!["task".into()];
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("question".into());
    }
    tools
}

fn opencode_permission_name(tool: &str) -> Option<String> {
    let normalized = tool.trim().to_ascii_lowercase().replace(['_', '-'], "");
    let permission = match normalized.as_str() {
        "read" => "read",
        "edit" | "write" | "patch" | "applypatch" | "multiedit" | "notebookedit" => "edit",
        "glob" | "find" | "ls" | "list" => "glob",
        "grep" => "grep",
        "bash" | "shell" => "bash",
        "task" | "agent" | "subagent" | "spawnagent" | "spawnagentsoncsv" => "task",
        "skill" => "skill",
        "lsp" => "lsp",
        "question" => "question",
        "webfetch" | "websearch" | "web" | "webresearch" | "webanswer" | "codesearch" => "webfetch",
        other if !other.is_empty() => return Some(tool.trim().to_string()),
        _ => return None,
    };
    Some(permission.into())
}

fn dedupe_permissions(permissions: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for permission in permissions {
        if !permission.is_empty() && seen.insert(permission.clone()) {
            out.push(permission);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{Agent, AgentExtras, AgentRole};

    fn agent_fixture(name: &str, role: AgentRole, model: &str) -> Agent {
        Agent {
            name: name.into(),
            description: "OpenCode test agent".into(),
            model: model.into(),
            role,
            color: Some("green".into()),
            effort: None,
            body: format!("# {name}\n\nIntro.\n"),
            source_path: PathBuf::new(),
        }
    }

    #[test]
    fn generate_agent_writes_default_deny_permissions() {
        let dir =
            std::env::temp_dir().join(format!("vstack_opencode_agent_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut agent = agent_fixture("reviewer", AgentRole::Reviewer, "sonnet");
        agent.effort = Some("high".into());
        let path = generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("mode: subagent\n"));
        assert!(content.contains("color: \"#22c55e\"\n"));
        assert!(content.contains("options:\n"));
        assert!(content.contains("  reasoningEffort: high\n"));
        assert!(content.contains("  reasoningSummary: auto\n"));
        assert!(content.contains("  textVerbosity: medium\n"));
        assert!(content.contains("permission:\n"));
        assert!(content.contains("  task: deny\n"));
        assert!(content.contains("  question: deny\n"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_defaults_engineers_to_subagent_mode_and_honors_override() {
        let dir =
            std::env::temp_dir().join(format!("vstack_opencode_agent_mode_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        let path = generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("mode: subagent\n"));

        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                mode: Some("primary".into()),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("mode: primary\n"));
        assert!(!content.contains("permission:\n"));
        assert!(!content.contains("  task: deny\n"));
        assert!(!content.contains("  question: deny\n"));

        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                mode: Some("all".into()),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("mode: subagent\n"));
        assert!(content.contains("  task: deny\n"));
        assert!(content.contains("  question: deny\n"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_maps_deny_tools_to_opencode_permissions() {
        let dir =
            std::env::temp_dir().join(format!("vstack_opencode_agent_deny_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("engineer", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                deny_tools: Some(vec![
                    "bash".into(),
                    "write".into(),
                    "apply_patch".into(),
                    "subagent".into(),
                ]),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("  bash: deny\n"));
        assert!(content.contains("  edit: deny\n"));
        assert!(content.contains("  task: deny\n"));
        assert!(content.contains("  question: deny\n"));
        assert_eq!(content.matches("  edit: deny\n").count(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_honors_opencode_reasoning_and_color_overrides() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_opencode_agent_options_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("researcher", AgentRole::Analyst, "haiku");
        let extras = AgentExtras {
            frontmatter: agent::AgentFrontmatterOverrides {
                color: Some("#336699".into()),
                effort: Some("low".into()),
                model_reasoning_effort: Some("high".into()),
                ..Default::default()
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("color: \"#336699\"\n"));
        assert!(content.contains("  reasoningEffort: high\n"));
        assert!(!content.contains("  reasoningEffort: low\n"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_writes_effort_override_verbatim() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_opencode_agent_effort_{}",
            std::process::id()
        ));
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
        let path = generate_agent(&agent, &dir, &[], &[], &extras).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("  reasoningEffort: xhigh\n"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_omits_options_when_no_effort_configured() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_opencode_agent_no_effort_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst, "haiku");
        let path = generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("  reasoningEffort:"));
        assert!(!content.contains("options:\n"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
