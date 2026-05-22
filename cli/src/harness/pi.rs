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
/// allowed-subagents: scout
/// model: claude-opus-4-5
/// color: green
/// pane: true
/// ---
/// ```
pub fn generate_agent(
    agent: &Agent,
    dir: &Path,
    _skills: &[(String, String)],
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
    let allowed_subagents = pi_allowed_subagents_for(agent, &frontmatter);
    let deny_tools = pi_deny_tools_for(agent, &frontmatter, &allowed_subagents);

    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!("name: {}\n", agent.name));

    let desc = agent.description.replace('\\', "\\\\").replace('"', "\\\"");
    output.push_str(&format!("description: \"{}\"\n", desc));
    if !deny_tools.is_empty() {
        output.push_str(&format!("deny-tools: {}\n", deny_tools.join(", ")));
    }
    if !allowed_subagents.is_empty() {
        output.push_str(&format!(
            "allowed-subagents: {}\n",
            allowed_subagents.join(", ")
        ));
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

fn pi_deny_tools_for(
    agent: &Agent,
    frontmatter: &agent::AgentFrontmatterOverrides,
    allowed_subagents: &[String],
) -> Vec<String> {
    let user_denies_delegate = frontmatter
        .deny_tools
        .as_deref()
        .is_some_and(|denies| {
            denies
                .iter()
                .any(|tool| normalize_pi_tool_name(tool) == "delegate_subagent")
        });
    let mut tools = pi_default_deny_tools_for(agent, allowed_subagents);
    if let Some(deny_tools) = &frontmatter.deny_tools {
        tools.extend(deny_tools.clone());
    }
    let mut tools = dedupe_pi_tool_names(tools);
    if !allowed_subagents.is_empty() && !user_denies_delegate {
        // Engineer agents ship with the scout-style allowlist by default,
        // which implies the default `delegate_subagent` deny is no longer
        // appropriate. Strip it so the child process actually inherits the
        // active tool. If the user *explicitly* listed `delegate_subagent`
        // in `deny-tools`, the explicit policy wins — keep the deny and
        // accept that the allowlist will never resolve targets at runtime.
        tools.retain(|tool| normalize_pi_tool_name(tool) != "delegate_subagent");
    }
    tools
}

fn pi_default_deny_tools_for(agent: &Agent, allowed_subagents: &[String]) -> Vec<String> {
    let mut tools = vec![
        "subagent".into(),
        "get_subagent_result".into(),
        "steer_subagent".into(),
        "stop_subagent".into(),
    ];
    if allowed_subagents.is_empty() {
        // Agents without an allowlist must not see the restricted delegation
        // tool either; deny it at install time so the child LLM never even
        // sees the description.
        tools.push("delegate_subagent".into());
    }
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("question".into());
    }
    if matches!(agent.role, AgentRole::Reviewer) {
        tools.push("tasks_write".into());
    }
    tools
}

/// Resolve the effective `allowed-subagents` list for an agent.
///
/// Order: explicit override (including empty list) wins; otherwise the
/// engineer-role default is `["scout"]`. Non-engineer roles default to an
/// empty list so reviewers/analysts/managers cannot delegate further.
fn pi_allowed_subagents_for(
    agent: &Agent,
    frontmatter: &agent::AgentFrontmatterOverrides,
) -> Vec<String> {
    if let Some(list) = &frontmatter.allowed_subagents {
        return dedupe_allowed_subagent_names(list.clone());
    }
    pi_default_allowed_subagents_for(agent)
}

pub(crate) fn pi_default_allowed_subagents_for(agent: &Agent) -> Vec<String> {
    if !matches!(agent.role, AgentRole::Engineer) {
        return Vec::new();
    }
    // Engineer agents get scout-style exploratory delegation by default so
    // dev agents can shed reconnaissance work without absorbing the context
    // hit. Other potential targets stay opt-in via vstack.toml overrides.
    vec!["scout".into()]
}

fn dedupe_allowed_subagent_names(names: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    names
        .into_iter()
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .filter(|name| seen.insert(name.to_ascii_lowercase()))
        .collect()
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
            "rust-tooling".into(),
            "Architecture patterns for Rust: more details.".into(),
        )];
        let path = generate_agent(&agent, &dir, &skills, &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("name: rust"));
        assert!(content.contains("model: openai-codex/gpt-5.5:xhigh"));
        assert!(content.contains("color: magenta"));
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        // Engineer default: subagent-family stays denied, but delegate_subagent
        // does NOT appear in deny-tools because the engineer ships with an
        // allowed-subagents list (scout).
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question"
        ));
        assert!(
            !content
                .lines()
                .find(|line| line.starts_with("deny-tools:"))
                .unwrap()
                .contains("delegate_subagent")
        );
        assert!(content.contains("allowed-subagents: scout"));
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
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");

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
        // Planner is engineer-role, so it gets the default scout allowlist
        // and delegate_subagent stays available.
        assert!(!deny_line.contains("delegate_subagent"));
        assert!(content.contains("allowed-subagents: scout"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_engineer_default_allows_scout_delegation() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_engineer_default_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("generalist", AgentRole::Engineer, "sonnet");
        let path =
            generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("allowed-subagents: scout"));
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(deny_line.contains("subagent"));
        assert!(!deny_line.contains("delegate_subagent"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_engineer_with_empty_allowed_disables_delegation() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_engineer_disabled_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter_by_harness: {
                let mut map = std::collections::HashMap::new();
                map.insert(
                    "pi".into(),
                    agent::AgentFrontmatterOverrides {
                        allowed_subagents: Some(vec![]),
                        ..Default::default()
                    },
                );
                map
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(
            !content
                .lines()
                .any(|line| line.starts_with("allowed-subagents:"))
        );
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(deny_line.contains("delegate_subagent"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_engineer_with_custom_allowed_list_emits_comma_separated() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_engineer_custom_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("iced", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter_by_harness: {
                let mut map = std::collections::HashMap::new();
                map.insert(
                    "pi".into(),
                    agent::AgentFrontmatterOverrides {
                        allowed_subagents: Some(vec!["scout".into(), "researcher".into()]),
                        ..Default::default()
                    },
                );
                map
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("allowed-subagents: scout, researcher"));
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(!deny_line.contains("delegate_subagent"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generate_non_engineer_default_denies_delegation() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_non_engineer_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("scout", AgentRole::Analyst, "haiku");
        let path =
            generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(
            !content
                .lines()
                .any(|line| line.starts_with("allowed-subagents:"))
        );
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(deny_line.contains("delegate_subagent"));

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
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");

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
        let path =
            generate_agent(&agent, &dir, &[], &[], &AgentExtras::default()).expect("generate ok");

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
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        // Engineer keeps the default scout allowlist, so delegate_subagent is
        // not denied alongside the orchestration tools.
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question, bash, apply-patch"
        ));
        assert!(content.contains("allowed-subagents: scout"));

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
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");

        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("model: openai-codex/gpt-5.5:high"));
        assert!(!content.lines().any(|line| line.starts_with("tools:")));
        // Reviewer role keeps the empty allowlist default, so
        // delegate_subagent is denied and not exposed at all.
        assert!(content.contains(
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, delegate_subagent, question, tasks_write"
        ));
        assert!(
            !content
                .lines()
                .any(|line| line.starts_with("allowed-subagents:"))
        );
        assert!(!content.contains("pane: true"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explicit_delegate_subagent_deny_wins_over_engineer_default_allowlist() {
        // Pre-PR review round-1 blocker 2: an engineer's default
        // `allowed-subagents: scout` must not silently override an explicit
        // user policy that denies `delegate_subagent`. The user's intent is
        // authoritative — keep the deny even though the allowlist is
        // non-empty, and accept that runtime delegation will refuse.
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_explicit_delegate_deny_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter_by_harness: {
                let mut map = std::collections::HashMap::new();
                map.insert(
                    "pi".into(),
                    agent::AgentFrontmatterOverrides {
                        deny_tools: Some(vec!["delegate_subagent".into()]),
                        ..Default::default()
                    },
                );
                map
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(
            deny_line.contains("delegate_subagent"),
            "explicit user deny must survive the allowlist strip: {deny_line}"
        );
        // Engineer default allowlist still emitted so users see what the
        // allowlist looks like, even though deny-tools makes it inert.
        assert!(content.contains("allowed-subagents: scout"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explicit_delegate_subagent_deny_with_dash_alias_wins() {
        // Same as above, exercising the normalize_pi_tool_name path that
        // collapses dashes — `delegate-subagent` from the user must be
        // detected as the same deny token.
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_agent_explicit_delegate_deny_alias_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        let extras = AgentExtras {
            frontmatter_by_harness: {
                let mut map = std::collections::HashMap::new();
                map.insert(
                    "pi".into(),
                    agent::AgentFrontmatterOverrides {
                        deny_tools: Some(vec!["delegate-subagent".into()]),
                        ..Default::default()
                    },
                );
                map
            },
            ..AgentExtras::default()
        };
        let path = generate_agent(&agent, &dir, &[], &[], &extras).expect("generate ok");
        let content = std::fs::read_to_string(&path).unwrap();
        let deny_line = content
            .lines()
            .find(|line| line.starts_with("deny-tools:"))
            .expect("deny-tools line");
        assert!(deny_line.contains("delegate-subagent"), "{deny_line}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pi_default_allowed_subagents_engineer_is_scout() {
        let agent = agent_fixture("rust", AgentRole::Engineer, "opus");
        assert_eq!(
            pi_default_allowed_subagents_for(&agent),
            vec!["scout".to_string()]
        );
    }

    #[test]
    fn pi_default_allowed_subagents_non_engineer_is_empty() {
        for role in [AgentRole::Analyst, AgentRole::Reviewer, AgentRole::Manager] {
            let agent = agent_fixture("any", role, "sonnet");
            assert!(pi_default_allowed_subagents_for(&agent).is_empty());
        }
    }
}
