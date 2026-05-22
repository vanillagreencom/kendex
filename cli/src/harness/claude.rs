use crate::agent::{self, Agent, AgentRole};
use crate::hook::Hook;
use anyhow::Result;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Generate a Claude Code agent file (.claude/agents/<name>.md)
///
/// Format: YAML frontmatter with name, description, model, disallowedTools,
/// color, skills, hooks followed by markdown body.
pub fn generate_agent(
    agent: &Agent,
    dir: &Path,
    skills: &[(String, String)],
    hooks: &[Hook],
    extras: &agent::AgentExtras,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;

    let path = dir.join(format!("{}.md", agent.name));

    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!("name: {}\n", agent.name));
    // Quote description to handle YAML-special chars (colons, hashes, etc.)
    let desc = agent.description.replace('"', "\\\"");
    output.push_str(&format!("description: \"{}\"\n", desc));

    let frontmatter = extras.frontmatter_for("claude-code");
    // Map model to Claude Code format unless project config supplies an exact id.
    let model = frontmatter
        .model
        .as_deref()
        .map(|model| agent::model_id_for("claude-code", model))
        .unwrap_or_else(|| agent.model_id("claude-code"));
    output.push_str(&format!("model: {}\n", model));

    if let Some(effort) = claude_effort_for(agent, &frontmatter) {
        output.push_str(&format!("effort: {}\n", effort));
    }
    output.push_str(&format!(
        "background: {}\n",
        claude_background_for(agent, extras, &frontmatter)
    ));
    if let Some(isolation) = claude_isolation_for(&frontmatter) {
        output.push_str(&format!("isolation: {}\n", isolation));
    }
    if let Some(memory) = claude_memory_for(&frontmatter) {
        output.push_str(&format!("memory: {}\n", memory));
    }

    let disallowed_tools = claude_disallowed_tools_for(agent, frontmatter.deny_tools.as_deref());
    if !disallowed_tools.is_empty() {
        output.push_str(&format!(
            "disallowedTools: {}\n",
            disallowed_tools.join(", ")
        ));
    }

    if let Some(color) = frontmatter
        .color
        .as_ref()
        .or(extras.color.as_ref())
        .or(agent.color.as_ref())
    {
        output.push_str(&format!("color: {}\n", color));
    }

    // Skills frontmatter
    if !skills.is_empty() {
        let names: Vec<&str> = skills.iter().map(|(n, _)| n.as_str()).collect();
        output.push_str(&format!("skills: {}\n", names.join(", ")));
    }

    // Hooks frontmatter (Claude Code native format)
    if !hooks.is_empty() || !extras.custom_hooks.is_empty() {
        output.push_str(&format_hooks_yaml_with_custom(hooks, &extras.custom_hooks));
    }

    output.push_str("---\n\n");
    output.push_str("> **Never edit this file directly.** To make additions or modifications, edit the appropriate section in `./vstack.toml`. Then run `vstack refresh`.\n\n");

    // Insert guidance + skills after first heading's intro
    let guidance = agent::guidance_section(extras.guidance.as_deref());
    let skills_section = agent::load_skills_section();
    let combined = format!("{}{}", guidance, skills_section);
    let body = agent::insert_after_intro(&agent.body, &combined);

    // Append custom hook descriptions + additional instructions at the bottom
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

fn claude_effort_for(
    agent: &Agent,
    frontmatter: &agent::AgentFrontmatterOverrides,
) -> Option<String> {
    frontmatter
        .effort
        .clone()
        .or_else(|| agent.effort.clone())
        .filter(|effort| !is_none_value(effort))
}

fn claude_background_for(
    agent: &Agent,
    extras: &agent::AgentExtras,
    frontmatter: &agent::AgentFrontmatterOverrides,
) -> bool {
    frontmatter
        .background
        .unwrap_or_else(|| !effective_pi_pane(agent, extras))
}

fn effective_pi_pane(agent: &Agent, extras: &agent::AgentExtras) -> bool {
    extras
        .frontmatter_for("pi")
        .pane
        .unwrap_or_else(|| default_pi_pane(agent))
}

fn default_pi_pane(agent: &Agent) -> bool {
    matches!(agent.role, AgentRole::Engineer) || agent.name.eq_ignore_ascii_case("planner")
}

fn claude_isolation_for(frontmatter: &agent::AgentFrontmatterOverrides) -> Option<String> {
    frontmatter
        .isolation
        .clone()
        .filter(|isolation| !is_none_value(isolation))
}

fn claude_memory_for(frontmatter: &agent::AgentFrontmatterOverrides) -> Option<String> {
    frontmatter
        .memory
        .clone()
        .filter(|memory| !is_none_value(memory))
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

fn claude_disallowed_tools_for(agent: &Agent, deny_tools: Option<&[String]>) -> Vec<String> {
    let mut tools = claude_default_deny_tools_for(agent);
    if let Some(deny_tools) = deny_tools {
        tools.extend(deny_tools.iter().map(|tool| claude_tool_name(tool)));
    }
    dedupe_tools(tools)
}

fn claude_default_deny_tools_for(agent: &Agent) -> Vec<String> {
    // Claude Code agents should not recursively spawn other agents by default.
    // Keep planner able to ask the user; all other vstack agents should return to parent instead.
    let mut tools = vec!["Agent".into()];
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("AskUserQuestion".into());
    }
    tools
}

fn claude_tool_name(tool: &str) -> String {
    match tool
        .trim()
        .to_ascii_lowercase()
        .replace(['_', '-'], "")
        .as_str()
    {
        "read" => "Read".into(),
        "grep" => "Grep".into(),
        "glob" | "find" => "Glob".into(),
        "ls" | "list" => "LS".into(),
        "bash" => "Bash".into(),
        "edit" => "Edit".into(),
        "multiedit" => "MultiEdit".into(),
        "write" => "Write".into(),
        "webfetch" => "WebFetch".into(),
        "websearch" => "WebSearch".into(),
        "todowrite" => "TodoWrite".into(),
        "todoread" => "TodoRead".into(),
        "task" | "agent" | "subagent" | "spawnagent" | "spawnagentsoncsv" => "Agent".into(),
        "question" | "askuserquestion" => "AskUserQuestion".into(),
        "notebookread" => "NotebookRead".into(),
        "notebookedit" => "NotebookEdit".into(),
        _ => tool.trim().to_string(),
    }
}

fn dedupe_tools(tools: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for tool in tools {
        if !tool.is_empty() && seen.insert(tool.clone()) {
            out.push(tool);
        }
    }
    out
}

/// Format installed hooks and custom hooks into Claude Code YAML frontmatter.
fn format_hooks_yaml_with_custom(hooks: &[Hook], custom: &[agent::CustomHookEntry]) -> String {
    // Group by event → matcher → list of commands
    let mut by_event: BTreeMap<String, BTreeMap<String, Vec<String>>> = BTreeMap::new();

    for hook in hooks {
        let matcher = hook.matcher.clone().unwrap_or_else(|| "*".to_string());
        by_event
            .entry(hook.event.clone())
            .or_default()
            .entry(matcher)
            .or_default()
            .push(format!(
                "$CLAUDE_PROJECT_DIR/.claude/hooks/{}.sh",
                hook.name
            ));
    }

    for hook in custom {
        let matcher = hook.matcher.clone().unwrap_or_else(|| "*".to_string());
        by_event
            .entry(hook.event.clone())
            .or_default()
            .entry(matcher)
            .or_default()
            .push(hook.command.clone());
    }

    let mut yaml = String::from("hooks:\n");

    for (event, matchers) in &by_event {
        yaml.push_str(&format!("  {}:\n", event));
        for (matcher, commands) in matchers {
            yaml.push_str(&format!("    - matcher: \"{}\"\n", matcher));
            yaml.push_str("      hooks:\n");
            for cmd in commands {
                yaml.push_str("        - type: command\n");
                yaml.push_str(&format!("          command: \"{}\"\n", cmd));
            }
        }
    }

    yaml
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{AgentExtras, AgentFrontmatterOverrides, AgentRole};

    fn agent_fixture(name: &str, role: AgentRole) -> Agent {
        Agent {
            name: name.into(),
            description: "Claude test agent".into(),
            model: "sonnet".into(),
            role,
            color: Some("green".into()),
            effort: None,
            body: format!("# {name}\n\nIntro.\n"),
            source_path: Default::default(),
        }
    }

    #[test]
    fn generate_agent_writes_default_role_disallowed_tools() {
        let dir =
            std::env::temp_dir().join(format!("vstack_claude_agent_tools_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut agent = agent_fixture("reviewer-arch", AgentRole::Reviewer);
        agent.effort = Some("high".into());
        let path =
            generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("\ntools:"));
        assert!(content.contains("effort: high"));
        assert!(content.contains("background: true"));
        assert!(!content.contains("isolation:"));
        assert!(!content.contains("memory:"));
        assert!(content.contains("disallowedTools: Agent, AskUserQuestion"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_ignores_tools_override_and_keeps_deny_only_defaults() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_tools_override_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let extras = AgentExtras {
            frontmatter: AgentFrontmatterOverrides {
                tools: Some(vec![
                    "read".into(),
                    "grep".into(),
                    "find".into(),
                    "bash".into(),
                    "web_search".into(),
                    "mcp__custom".into(),
                ]),
                ..Default::default()
            },
            ..Default::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("\ntools:"));
        assert!(content.contains("disallowedTools: Agent, AskUserQuestion"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_emits_native_disallowed_tools() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_deny_tools_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let extras = AgentExtras {
            frontmatter: AgentFrontmatterOverrides {
                deny_tools: Some(vec![
                    "bash".into(),
                    "task".into(),
                    "write".into(),
                    "question".into(),
                ]),
                ..Default::default()
            },
            ..Default::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("\ntools:"));
        assert!(content.contains("disallowedTools: Agent, AskUserQuestion, Bash, Write"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_emits_claude_runtime_frontmatter() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_runtime_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut agent = agent_fixture("planner", AgentRole::Analyst);
        agent.model = "opus".into();
        agent.effort = Some("max".into());
        let extras = AgentExtras {
            frontmatter: AgentFrontmatterOverrides {
                memory: Some("project".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model: opus[1m]"));
        assert!(content.contains("effort: max"));
        assert!(content.contains("background: false"));
        assert!(!content.contains("isolation:"));
        assert!(content.contains("memory: project"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_derives_background_from_pi_pane() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_pi_pane_background_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst);
        let mut extras = AgentExtras::default();
        extras.frontmatter_by_harness.insert(
            "pi".into(),
            AgentFrontmatterOverrides {
                pane: Some(false),
                ..Default::default()
            },
        );

        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("background: true"));

        extras.frontmatter_by_harness.insert(
            "pi".into(),
            AgentFrontmatterOverrides {
                pane: Some(true),
                ..Default::default()
            },
        );
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("background: false"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_allows_disabling_claude_runtime_defaults() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_runtime_disable_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer);
        let extras = AgentExtras {
            frontmatter: AgentFrontmatterOverrides {
                effort: Some("none".into()),
                background: Some(false),
                isolation: Some("none".into()),
                memory: Some("none".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.contains("effort:"));
        assert!(content.contains("background: false"));
        assert!(!content.contains("isolation:"));
        assert!(!content.contains("memory:"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_agent_honors_explicit_claude_runtime_overrides() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_claude_agent_runtime_override_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("planner", AgentRole::Analyst);
        let extras = AgentExtras {
            frontmatter: AgentFrontmatterOverrides {
                background: Some(true),
                isolation: Some("worktree".into()),
                memory: Some("local".into()),
                ..Default::default()
            },
            ..Default::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("background: true"));
        assert!(content.contains("isolation: worktree"));
        assert!(content.contains("memory: local"));
        assert!(content.contains("disallowedTools: Agent"));
        assert!(!content.contains("AskUserQuestion"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
