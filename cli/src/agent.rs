#![allow(dead_code)]

use anyhow::{Context, Result};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// Canonical agent definition — harness-agnostic.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    pub name: String,
    pub description: String,
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default)]
    pub role: AgentRole,
    #[serde(default)]
    pub color: Option<String>,
    /// Reasoning effort. Written verbatim by each harness; no cross-harness
    /// translation. Valid values depend on the target harness — Claude accepts
    /// `low|medium|high|xhigh|max`; OpenAI-style harnesses cap at `xhigh`.
    #[serde(default)]
    pub effort: Option<String>,
    /// Body markdown (everything after frontmatter)
    #[serde(skip)]
    pub body: String,
    /// Path to the source .md file
    #[serde(skip)]
    pub source_path: std::path::PathBuf,
}

fn default_model() -> String {
    "sonnet".into()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AgentRole {
    Reviewer,
    #[default]
    Engineer,
    Analyst,
    Manager,
}

impl AgentRole {
    /// Whether this role writes code
    pub fn writes_code(&self) -> bool {
        matches!(self, AgentRole::Engineer)
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            AgentRole::Reviewer => "reviewer",
            AgentRole::Engineer => "engineer",
            AgentRole::Analyst => "analyst",
            AgentRole::Manager => "manager",
        }
    }
}

impl std::fmt::Display for AgentRole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl Agent {
    /// Parse a canonical agent file (YAML frontmatter + markdown body)
    pub fn from_file(path: &Path) -> Result<Self> {
        let content =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let mut agent = Self::parse(&content)?;
        agent.source_path = path.to_path_buf();
        Ok(agent)
    }

    /// Parse from string content
    pub fn parse(content: &str) -> Result<Self> {
        let (frontmatter, body) = crate::frontmatter::split_yaml_frontmatter(content)?;
        let mut agent: Agent =
            serde_yaml::from_str(&frontmatter).context("parsing agent frontmatter")?;
        agent.body = body;
        Ok(agent)
    }

    /// Map model name to provider-specific model ID
    pub fn model_id(&self, provider: &str) -> String {
        model_id_for(provider, &self.model)
    }
}

/// Map a canonical or exact model name to a provider-specific model ID.
/// Canonical vstack tiers (`opus`, `sonnet`, `haiku`) translate per harness;
/// all other values pass through as exact provider ids.
pub fn model_id_for(provider: &str, model: &str) -> String {
    let base = model.to_lowercase();
    if base.contains('/') {
        return model.into();
    }
    match provider {
        "anthropic" => match base.as_str() {
            "opus" => "anthropic/claude-opus-4-20250514".into(),
            "sonnet" => "anthropic/claude-sonnet-4-20250514".into(),
            "haiku" => "anthropic/claude-haiku-4-5-20251001".into(),
            other => other.into(),
        },
        "openai" => match base.as_str() {
            "opus" => "openai/gpt-5.5".into(),
            "sonnet" => "openai/gpt-5.5".into(),
            "haiku" => "openai/gpt-5.5".into(),
            other => format!("openai/{other}"),
        },
        "claude-code" => match base.as_str() {
            "opus" => "opus[1m]".into(),
            "sonnet" => "sonnet".into(),
            "haiku" => "haiku".into(),
            other => other.into(),
        },
        _ => base,
    }
}

/// Discover all agent files in a directory
pub fn discover_agents(dir: &Path) -> Result<Vec<Agent>> {
    let mut agents = Vec::new();
    if !dir.exists() {
        return Ok(agents);
    }
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "md") {
            match Agent::from_file(&path) {
                Ok(agent) => agents.push(agent),
                Err(e) => eprintln!("Warning: skipping {}: {e}", path.display()),
            }
        }
    }
    agents.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(agents)
}

pub fn skill_match_prefix(agent_name: &str) -> &str {
    agent_name.strip_prefix("reviewer-").unwrap_or(agent_name)
}

pub fn prefixed_skill_matches(agent_name: &str, available: &[String]) -> Vec<String> {
    let mut matched = Vec::new();
    let name = agent_name.to_lowercase();
    let prefix = skill_match_prefix(&name);

    for skill in available {
        if skill.starts_with(&format!("{prefix}-")) || skill == prefix {
            matched.push(skill.clone());
        }
    }

    matched
}

fn default_role_skills(agent_role: &AgentRole) -> &'static [&'static str] {
    match agent_role {
        AgentRole::Reviewer => &["linear-dev"],
        AgentRole::Analyst => &["linear", "github"],
        AgentRole::Engineer => &["linear-dev", "github", "worktree"],
        AgentRole::Manager => &[
            "project-management",
            "linear",
            "linear-dev",
            "github",
            "worktree",
        ],
    }
}

/// Match skills to an agent by name prefix and role
pub fn match_skills(agent_name: &str, agent_role: &AgentRole, available: &[String]) -> Vec<String> {
    let mut matched = prefixed_skill_matches(agent_name, available);

    for skill_name in default_role_skills(agent_role) {
        if available.iter().any(|skill| skill == skill_name)
            && !matched.iter().any(|skill| skill == skill_name)
        {
            matched.push((*skill_name).to_string());
        }
    }

    matched.sort();
    matched.dedup();
    matched
}

/// Match hooks to an agent based on role
pub fn match_hooks<'a>(
    agent_role: &AgentRole,
    hooks: &'a [crate::hook::Hook],
) -> Vec<&'a crate::hook::Hook> {
    hooks
        .iter()
        .filter(|h| {
            match agent_role {
                AgentRole::Engineer => true,
                AgentRole::Reviewer | AgentRole::Analyst | AgentRole::Manager => {
                    // Get Bash safety hooks and lifecycle hooks, not edit/write hooks
                    h.event == "PostCompact"
                        || h.event == "TaskCompleted"
                        || (h.event == "PreToolUse" && h.matcher.as_deref() == Some("Bash"))
                        || (h.event == "PostToolUse" && h.matcher.as_deref() == Some("Bash"))
                }
            }
        })
        .collect()
}

/// Per-agent customization from project-level config
#[derive(Debug, Clone, Default)]
pub struct AgentExtras {
    pub color: Option<String>,
    pub guidance: Option<String>,
    pub instructions: Option<String>,
    /// User-controlled frontmatter overrides from project `vstack.toml`.
    /// The top-level override applies to every harness; entries in
    /// `frontmatter_by_harness` apply only to the matching harness id and win.
    pub frontmatter: AgentFrontmatterOverrides,
    pub frontmatter_by_harness: HashMap<String, AgentFrontmatterOverrides>,
    /// Custom hooks from vstack.toml (Claude Code only — command paths)
    pub custom_hooks: Vec<CustomHookEntry>,
}

/// Typed subset of generated agent frontmatter that project users may override.
/// Fields that are not meaningful for a harness are ignored by that harness.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "kebab-case")]
pub struct AgentFrontmatterOverrides {
    pub color: Option<String>,
    /// Exact harness model id to write. Prefer harness-specific overrides when
    /// providers use different model id formats.
    pub model: Option<String>,
    /// Legacy tool allowlist override parsed for old project configs. Current
    /// harness generators ignore it; use `deny-tools` for portable restrictions.
    #[serde(default, deserialize_with = "deserialize_optional_tools")]
    pub tools: Option<Vec<String>>,
    /// Tool denylist applied after harness defaults.
    /// Generators either emit a native deny field (for example Claude Code
    /// `disallowedTools`) or preserve the denylist for the harness extension.
    #[serde(default, deserialize_with = "deserialize_optional_tools")]
    pub deny_tools: Option<Vec<String>>,
    /// Pi restricted-delegation allowlist for `delegate_subagent`. Names must
    /// match a discovered agent (no fuzzy matching). An explicit empty list
    /// disables the engineer-role default. Accepts the canonical kebab key
    /// plus camelCase / snake_case / `subagent-agents` aliases for
    /// compatibility with the upstream `pi-subagents` convention.
    #[serde(
        default,
        alias = "allowedSubagents",
        alias = "subagent-agents",
        alias = "subagent_agents",
        deserialize_with = "deserialize_optional_tools"
    )]
    pub allowed_subagents: Option<Vec<String>>,
    /// Pi persistent pane flag.
    pub pane: Option<bool>,
    /// Claude Code background subagent flag.
    pub background: Option<bool>,
    /// Claude Code effort level override.
    pub effort: Option<String>,
    /// Claude Code isolation mode, for example `worktree`.
    pub isolation: Option<String>,
    /// Claude Code persistent memory scope: `user`, `project`, or `local`.
    pub memory: Option<String>,
    /// OpenCode mode override.
    pub mode: Option<String>,
    /// Codex sandbox mode override.
    pub sandbox_mode: Option<String>,
    /// Codex reasoning effort override.
    pub model_reasoning_effort: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ToolsValue {
    String(String),
    List(Vec<String>),
}

fn deserialize_optional_tools<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<ToolsValue>::deserialize(deserializer)?;
    Ok(value.map(|value| match value {
        ToolsValue::String(s) => s
            .split(',')
            .map(|tool| tool.trim().to_string())
            .filter(|tool| !tool.is_empty())
            .collect(),
        ToolsValue::List(list) => list
            .into_iter()
            .map(|tool| tool.trim().to_string())
            .filter(|tool| !tool.is_empty())
            .collect(),
    }))
}

impl AgentFrontmatterOverrides {
    pub fn merge(&self, harness: &Self) -> Self {
        Self {
            color: harness.color.clone().or_else(|| self.color.clone()),
            model: harness.model.clone().or_else(|| self.model.clone()),
            tools: harness.tools.clone().or_else(|| self.tools.clone()),
            deny_tools: merge_optional_tool_lists(&self.deny_tools, &harness.deny_tools),
            allowed_subagents: harness
                .allowed_subagents
                .clone()
                .or_else(|| self.allowed_subagents.clone()),
            pane: harness.pane.or(self.pane),
            background: harness.background.or(self.background),
            effort: harness.effort.clone().or_else(|| self.effort.clone()),
            isolation: harness.isolation.clone().or_else(|| self.isolation.clone()),
            memory: harness.memory.clone().or_else(|| self.memory.clone()),
            mode: harness.mode.clone().or_else(|| self.mode.clone()),
            sandbox_mode: harness
                .sandbox_mode
                .clone()
                .or_else(|| self.sandbox_mode.clone()),
            model_reasoning_effort: harness
                .model_reasoning_effort
                .clone()
                .or_else(|| self.model_reasoning_effort.clone()),
        }
    }

    pub fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

fn merge_optional_tool_lists(
    base: &Option<Vec<String>>,
    harness: &Option<Vec<String>>,
) -> Option<Vec<String>> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for tool in base
        .iter()
        .chain(harness.iter())
        .flat_map(|tools| tools.iter())
    {
        let trimmed = tool.trim();
        if !trimmed.is_empty() && seen.insert(trimmed.to_string()) {
            out.push(trimmed.to_string());
        }
    }
    if base.is_some() || harness.is_some() {
        Some(out)
    } else {
        None
    }
}

impl AgentExtras {
    pub fn frontmatter_for(&self, harness_id: &str) -> AgentFrontmatterOverrides {
        let harness = self
            .frontmatter_by_harness
            .get(harness_id)
            .cloned()
            .unwrap_or_default();
        self.frontmatter.merge(&harness)
    }
}

/// A custom hook entry for agent frontmatter
#[derive(Debug, Clone)]
pub struct CustomHookEntry {
    pub event: String,
    pub matcher: Option<String>,
    pub command: String,
    pub description: Option<String>,
}

/// Generate a "Launch Instructions" markdown section
pub fn guidance_section(text: Option<&str>) -> String {
    match text {
        Some(t) if !t.is_empty() => format!("## Launch Instructions\n\n{}\n\n", t.trim()),
        _ => String::new(),
    }
}

/// Generate an "Additional Instructions" markdown section
pub fn instructions_section(text: Option<&str>) -> String {
    match text {
        Some(t) if !t.is_empty() => format!("## Additional Instructions\n\n{}\n", t.trim()),
        _ => String::new(),
    }
}

/// Append a section to the end of a markdown body
pub fn append_section(body: &str, section: &str) -> String {
    if section.is_empty() {
        return body.to_string();
    }
    let trimmed = body.trim_end();
    format!("{}\n\n{}\n", trimmed, section.trim_end())
}

/// Extract user-edited "When to Use" and "Additional Instructions" sections
/// from an existing generated agent file so they can be preserved across regeneration.
pub fn extract_user_sections(content: &str) -> AgentExtras {
    AgentExtras {
        color: extract_frontmatter_color(content),
        guidance: extract_section(content, "## Launch Instructions")
            .or_else(|| extract_section(content, "## When to Use")),
        instructions: extract_section(content, "## Additional Instructions"),
        ..Default::default()
    }
}

/// Extract an agent `color:` value from YAML frontmatter, if present.
pub fn extract_frontmatter_color(content: &str) -> Option<String> {
    let (frontmatter, _) = crate::frontmatter::split_yaml_frontmatter(content).ok()?;
    let value: serde_yaml::Value = serde_yaml::from_str(&frontmatter).ok()?;
    value
        .get("color")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// Extract a markdown section's body text between its heading and the next `## ` heading.
fn extract_section(content: &str, header: &str) -> Option<String> {
    let start = content.find(header)?;
    let after_header = &content[start + header.len()..];
    // Find the body text (skip leading whitespace)
    let trimmed = after_header.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    // End at next ## heading or end of content
    let end = trimmed.find("\n## ").unwrap_or(trimmed.len());
    let text = trimmed[..end].trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

/// Extract the developer_instructions body from a Codex TOML agent file.
pub fn extract_body_from_codex_toml(content: &str) -> Option<String> {
    let marker = "developer_instructions = '''\n";
    let start = content.find(marker)?;
    let after = &content[start + marker.len()..];
    let end = after.find("'''")?;
    Some(after[..end].to_string())
}

/// Generate a "Hook Rules" section from custom hooks that have descriptions.
/// Harnesses that can't run scripts natively get this as inline instructions.
pub fn custom_hooks_section(hooks: &[CustomHookEntry]) -> String {
    let with_desc: Vec<&CustomHookEntry> =
        hooks.iter().filter(|h| h.description.is_some()).collect();
    if with_desc.is_empty() {
        return String::new();
    }
    let mut section = String::from("## Hook Rules\n\n");
    for hook in with_desc {
        let matcher_info = hook
            .matcher
            .as_deref()
            .map(|m| format!(" ({})", m))
            .unwrap_or_default();
        section.push_str(&format!(
            "**{}{}**: {}\n\n",
            hook.event,
            matcher_info,
            hook.description.as_deref().unwrap_or("")
        ));
    }
    section
}

/// Emit the load-skills preamble injected into every generated agent body.
/// Each harness (pi, codex, opencode, claude) already auto-exposes skill
/// name+description through its native discovery surface (`<available_skills>`
/// for pi/codex, the `skill` tool description for opencode, the Skill tool
/// for claude). The agent body just needs the directive to load by description
/// match — the actual catalog comes from the harness.
pub fn load_skills_section() -> String {
    String::from(
        "## Skills\n\n\
         Load any skill whose name or description matches the task before acting on that domain. Skill descriptions are listed by the harness; do not guess commands or improvise — load the skill first.\n\n",
    )
}

/// Insert a section after the first heading block in markdown body.
/// Finds the first `## ` line and inserts before it.
/// If no `## ` found, appends to the end.
pub fn insert_after_intro(body: &str, section: &str) -> String {
    if section.is_empty() {
        return body.to_string();
    }
    // Find second heading (first ## after the opening # title)
    if let Some(pos) = body.find("\n## ") {
        let insert_at = pos + 1; // after the newline
        format!(
            "{}\n{}\n{}",
            &body[..insert_at],
            section,
            &body[insert_at..]
        )
    } else {
        // No ## found, append with spacing
        format!("{}\n\n{}\n", body.trim_end(), section)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_agent() {
        let content = r#"---
name: test-agent
description: A test agent
model: opus
role: reviewer
color: red
---

# Test Agent

Does testing things.
"#;
        let agent = Agent::parse(content).unwrap();
        assert_eq!(agent.name, "test-agent");
        assert_eq!(agent.role, AgentRole::Reviewer);
        assert!(agent.body.contains("# Test Agent"));
    }

    #[test]
    fn match_skills_by_prefix() {
        let available = vec![
            "rust-tooling".into(),
            "rust-runtime".into(),
            "python-web".into(),
            "linear-dev".into(),
            "github".into(),
            "worktree".into(),
        ];
        let matched = match_skills("rust", &AgentRole::Engineer, &available);
        assert!(matched.contains(&"rust-tooling".to_string()));
        assert!(matched.contains(&"rust-runtime".to_string()));
        assert!(!matched.contains(&"python-web".to_string()));
        // Engineer gets workflow skills
        assert!(matched.contains(&"linear-dev".to_string()));
        assert!(matched.contains(&"github".to_string()));
        assert!(matched.contains(&"worktree".to_string()));
    }

    #[test]
    fn match_skills_reviewer_prefix_strip() {
        let available = vec![
            "rust-tooling".into(),
            "rust-runtime".into(),
            "linear-dev".into(),
        ];
        let matched = match_skills("reviewer-rust", &AgentRole::Reviewer, &available);
        assert!(matched.contains(&"rust-tooling".to_string()));
        assert!(matched.contains(&"rust-runtime".to_string()));
        assert!(matched.contains(&"linear-dev".to_string()));
    }

    #[test]
    fn match_hooks_engineer_gets_all() {
        let hooks = vec![
            crate::hook::Hook {
                name: "h1".into(),
                event: "PreToolUse".into(),
                matcher: Some("Bash".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
            crate::hook::Hook {
                name: "h2".into(),
                event: "PostToolUse".into(),
                matcher: Some("Edit|Write".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
        ];
        let matched = match_hooks(&AgentRole::Engineer, &hooks);
        assert_eq!(matched.len(), 2);
    }

    #[test]
    fn match_hooks_reviewer_filters() {
        let hooks = vec![
            crate::hook::Hook {
                name: "h1".into(),
                event: "PreToolUse".into(),
                matcher: Some("Bash".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
            crate::hook::Hook {
                name: "h2".into(),
                event: "PostToolUse".into(),
                matcher: Some("Edit|Write".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
            crate::hook::Hook {
                name: "h3".into(),
                event: "PostCompact".into(),
                matcher: None,
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
        ];
        let matched = match_hooks(&AgentRole::Reviewer, &hooks);
        // Should get h1 (Bash PreToolUse) and h3 (PostCompact), but not h2 (Edit|Write)
        assert_eq!(matched.len(), 2);
        assert!(matched.iter().any(|h| h.name == "h1"));
        assert!(matched.iter().any(|h| h.name == "h3"));
    }

    #[test]
    fn load_skills_section_emits_directive_only() {
        // The preamble is emitted unconditionally because the harness
        // injects available skill name+description into the agent's context
        // (pi `<available_skills>`, codex initial list, opencode `skill`
        // tool description, claude Skill tool description). The body just
        // needs the one-line directive to load by description match.
        let section = load_skills_section();
        assert!(section.contains("## Skills"));
        assert!(section.contains("Load any skill whose name or description matches"));
        assert!(section.contains("Skill descriptions are listed by the harness"));
    }

    #[test]
    fn guidance_section_renders() {
        let section = guidance_section(Some("Read the open issues and start working."));
        assert!(section.contains("## Launch Instructions"));
        assert!(section.contains("Read the open issues and start working."));
    }

    #[test]
    fn guidance_section_empty_on_none() {
        assert_eq!(guidance_section(None), String::new());
        assert_eq!(guidance_section(Some("")), String::new());
    }

    #[test]
    fn instructions_section_renders() {
        let section = instructions_section(Some("Always run clippy."));
        assert!(section.contains("## Additional Instructions"));
        assert!(section.contains("Always run clippy."));
    }

    #[test]
    fn instructions_section_empty_on_none() {
        assert_eq!(instructions_section(None), String::new());
        assert_eq!(instructions_section(Some("")), String::new());
    }

    #[test]
    fn append_section_adds_to_end() {
        let body = "# Title\n\nSome content.\n";
        let section = "## Extra\n\nMore stuff.\n";
        let result = append_section(body, section);
        assert!(result.ends_with("More stuff.\n"));
        assert!(result.contains("Some content."));
    }

    #[test]
    fn append_section_noop_when_empty() {
        let body = "# Title\n\nContent.\n";
        assert_eq!(append_section(body, ""), body.to_string());
    }

    #[test]
    fn extract_user_sections_both() {
        let content = r#"# Agent

Some intro.

## When to Use

Use for backend services.

## Load These Skills

- **Skill** → `skill-name`

## Capabilities

Does stuff.

## Additional Instructions

Always run clippy.
"#;
        let extras = extract_user_sections(content);
        assert_eq!(
            extras.guidance.as_deref(),
            Some("Use for backend services.")
        );
        assert_eq!(extras.instructions.as_deref(), Some("Always run clippy."));
    }

    #[test]
    fn extract_user_sections_none() {
        let content = "# Agent\n\nJust an intro.\n\n## Capabilities\n\nDoes stuff.\n";
        let extras = extract_user_sections(content);
        assert!(extras.guidance.is_none());
        assert!(extras.instructions.is_none());
    }

    #[test]
    fn frontmatter_overrides_merge_allowed_subagents_with_harness_winning() {
        let base = AgentFrontmatterOverrides {
            allowed_subagents: Some(vec!["base-target".into()]),
            ..Default::default()
        };
        let harness = AgentFrontmatterOverrides {
            allowed_subagents: Some(vec!["harness-target".into()]),
            ..Default::default()
        };
        let merged = base.merge(&harness);
        assert_eq!(
            merged.allowed_subagents,
            Some(vec!["harness-target".to_string()]),
            "harness override should win, including its full list"
        );
    }

    #[test]
    fn frontmatter_overrides_merge_preserves_explicit_empty_allowed_subagents() {
        // An explicit empty list at either layer must survive — that's how
        // users opt out of engineer-role defaults.
        let base = AgentFrontmatterOverrides::default();
        let harness = AgentFrontmatterOverrides {
            allowed_subagents: Some(Vec::new()),
            ..Default::default()
        };
        let merged = base.merge(&harness);
        assert_eq!(
            merged.allowed_subagents,
            Some(Vec::new()),
            "explicit empty list must override unset/default state"
        );
    }

    #[test]
    fn frontmatter_overrides_merge_falls_through_when_harness_unset() {
        let base = AgentFrontmatterOverrides {
            allowed_subagents: Some(vec!["scout".into()]),
            ..Default::default()
        };
        let harness = AgentFrontmatterOverrides::default();
        let merged = base.merge(&harness);
        assert_eq!(merged.allowed_subagents, Some(vec!["scout".to_string()]));
    }

    #[test]
    fn frontmatter_overrides_parses_allowed_subagents_aliases() {
        let canonical: AgentFrontmatterOverrides =
            serde_yaml::from_str("allowed-subagents: scout, researcher").unwrap();
        assert_eq!(
            canonical.allowed_subagents,
            Some(vec!["scout".to_string(), "researcher".to_string()])
        );

        let camel: AgentFrontmatterOverrides =
            serde_yaml::from_str("allowedSubagents:\n  - scout\n  - researcher").unwrap();
        assert_eq!(
            camel.allowed_subagents,
            Some(vec!["scout".to_string(), "researcher".to_string()])
        );

        let snake: AgentFrontmatterOverrides =
            serde_yaml::from_str("subagent_agents: scout").unwrap();
        assert_eq!(snake.allowed_subagents, Some(vec!["scout".to_string()]));

        let dashed: AgentFrontmatterOverrides =
            serde_yaml::from_str("subagent-agents: scout").unwrap();
        assert_eq!(dashed.allowed_subagents, Some(vec!["scout".to_string()]));
    }

    #[test]
    fn extract_body_from_codex() {
        let content = r#"name = "rust"
developer_instructions = '''
# Rust Agent

## Additional Instructions

Use zero-copy APIs.
'''
"#;
        let body = extract_body_from_codex_toml(content).unwrap();
        let extras = extract_user_sections(&body);
        assert_eq!(extras.instructions.as_deref(), Some("Use zero-copy APIs."));
    }
}
