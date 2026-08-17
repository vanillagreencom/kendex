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
            "sonnet" => "anthropic/claude-sonnet-5".into(),
            "haiku" => "anthropic/claude-haiku-4-5-20251001".into(),
            other => other.into(),
        },
        "openai" => match base.as_str() {
            "opus" => "openai/gpt-5.6-sol".into(),
            "sonnet" => "openai/gpt-5.6-sol".into(),
            "haiku" => "openai/gpt-5.6-sol".into(),
            other => format!("openai/{other}"),
        },
        "claude-code" => match base.as_str() {
            "opus" => "inherit".into(),
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
        AgentRole::Reviewer => &["dev"],
        AgentRole::Analyst => &["linear", "github"],
        AgentRole::Engineer => &["dev", "github", "worktree"],
        AgentRole::Manager => &["project-management", "linear", "dev", "github", "worktree"],
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
    /// Codex display nickname candidates. Codex still identifies the
    /// subagent by `name`; nicknames are presentation-only.
    #[serde(
        default,
        alias = "nicknameCandidates",
        alias = "nickname_candidates",
        deserialize_with = "deserialize_optional_tools"
    )]
    pub nickname_candidates: Option<Vec<String>>,
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
            nickname_candidates: harness
                .nickname_candidates
                .clone()
                .or_else(|| self.nickname_candidates.clone()),
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
    let start = find_outside_marked(content, header)?;
    let after_header = &content[start + header.len()..];
    // Find the body text (skip leading whitespace)
    let trimmed = after_header.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let text = trimmed[..section_end(trimmed)].trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

/// End of a section body: the next `\n## ` heading, or end of content.
/// Headings inside a marked shared-instructions region never terminate the
/// section — a shared `all` value may itself contain `## ` headings, and
/// splitting the region there would leave an unmatched start marker that
/// `ProjectConfig::strip_shared_block` cannot drop, persisting a truncated
/// shared fragment as item-specific text on re-extraction.
fn section_end(text: &str) -> usize {
    let mut from = 0;
    loop {
        let Some(rel) = text[from..].find("\n## ") else {
            return text.len();
        };
        let candidate = from + rel;
        match enclosing_marked_region_end(text, candidate) {
            Some(region_end) => from = region_end,
            None => return candidate,
        }
    }
}

/// First occurrence of `needle` that does not fall inside a marked
/// shared-instructions region. The section header lookup needs this too:
/// shared text may contain a literal `## Additional Instructions` line, and
/// selecting that nested occurrence would extract the tail of the shared
/// block as item-specific text.
fn find_outside_marked(text: &str, needle: &str) -> Option<usize> {
    let mut from = 0;
    loop {
        let pos = from + text[from..].find(needle)?;
        match enclosing_marked_region_end(text, pos) {
            Some(region_end) => from = region_end,
            None => return Some(pos),
        }
    }
}

/// If `pos` falls inside a `SHARED_INSTRUCTIONS_START`..`SHARED_INSTRUCTIONS_END`
/// region of `text`, return the offset just past that region's end marker.
fn enclosing_marked_region_end(text: &str, pos: usize) -> Option<usize> {
    use crate::project_config::{SHARED_INSTRUCTIONS_END, SHARED_INSTRUCTIONS_START};
    let mut from = 0;
    while let Some(rel_start) = text[from..].find(SHARED_INSTRUCTIONS_START) {
        let start = from + rel_start;
        if start > pos {
            return None;
        }
        let end =
            start + text[start..].find(SHARED_INSTRUCTIONS_END)? + SHARED_INSTRUCTIONS_END.len();
        if pos > start && pos < end {
            return Some(end);
        }
        from = end;
    }
    None
}

/// The `developer_instructions` body of a Codex TOML agent file, decoded.
///
/// Parsed, because which key this is and where its value ends are TOML
/// questions. The substring search this replaces took the first occurrence of
/// the assignment TEXT anywhere in the file — inside a comment, inside another
/// field's own string, inside any table — and ran it to the next `'''`.
pub fn extract_body_from_codex_toml(content: &str) -> Option<String> {
    let doc = content.parse::<toml_edit::DocumentMut>().ok()?;
    Some(doc.get("developer_instructions")?.as_str()?.to_string())
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

/// Canonical skill-failure routing rules referenced by the short reporting
/// directive in every agent body. One copy per install scope replaces the
/// former ~300-word blockquote repeated in every generated agent file.
pub const FAILURE_REPORTING_DOC: &str = include_str!("../../docs/skill-failure-reporting.md");

/// Where the failure-reporting reference lives for a scope: next to the
/// skills install root (`.agents/` for projects, the platform config dir's
/// `vstack/` for global installs).
pub fn failure_reporting_reference_path(global: bool) -> std::path::PathBuf {
    if global {
        crate::config::global_state_dir().join("skill-failure-reporting.md")
    } else {
        crate::config::project_root()
            .join(".agents")
            .join("skill-failure-reporting.md")
    }
}

/// Placeholder carried by source agent bodies where the failure-reporting
/// reference path belongs; [`resolve_failure_reference`] substitutes the real
/// scope-resolved path at generation time so the sources stay platform- and
/// scope-agnostic.
pub const FAILURE_REF_TOKEN: &str = "{{VSTACK_FAILURE_REF}}";

/// The path substituted for [`FAILURE_REF_TOKEN`]: project-root-anchored for
/// project scope, the resolved platform config-dir path for global scope.
/// The project spelling stays relative on purpose — generated agent files are
/// committed and synced across machines, so an absolute path would embed one
/// machine's checkout location. The `<project-root>/` anchor tells sessions
/// started in a subdirectory where to resolve it from.
pub fn failure_reference_display(global: bool) -> String {
    if global {
        crate::config::display_path(&failure_reporting_reference_path(true))
    } else {
        "<project-root>/.agents/skill-failure-reporting.md".to_string()
    }
}

/// Resolve [`FAILURE_REF_TOKEN`] in an agent body for the scope being
/// generated.
pub fn resolve_failure_reference(agent: &Agent, global: bool) -> Agent {
    let mut resolved = agent.clone();
    resolved.body = resolved
        .body
        .replace(FAILURE_REF_TOKEN, &failure_reference_display(global));
    resolved
}

/// Install or refresh the canonical failure-reporting reference for a scope.
/// Idempotent: only writes when the on-disk copy is missing or stale.
///
/// Returns the scope generated bodies must point at: normally the requested
/// scope, but a project `.agents` that resolves outside the project falls
/// back to the global copy — the global config dir cannot be redirected by a
/// project symlink — so the substituted path never dangles.
pub fn install_failure_reporting_reference(global: bool) -> Result<bool> {
    // The project-scope reference lands under `.agents`; a symlinked `.agents`
    // ancestor must not let the write (or the freshness read) escape the
    // project, no matter which command path triggered generation. Fall back
    // rather than fail: installs that never write through `.agents` (e.g.
    // claude-code copy-method) stay allowed with an escaped `.agents`, and
    // only the `.agents`-routed write is withheld.
    if !global
        && let Err(err) =
            crate::path_safety::ensure_agents_dir_within_project(&crate::config::project_root())
    {
        eprintln!(
            "Warning: skipping project skill-failure reference install ({err}); \
             generated agents will point at the global copy instead"
        );
        return install_failure_reporting_reference(true);
    }
    let path = failure_reporting_reference_path(global);
    if reference_is_fresh(&path) {
        return Ok(global);
    }
    crate::path_safety::write_file_no_follow(&path, FAILURE_REPORTING_DOC)
        .with_context(|| format!("installing {}", path.display()))?;
    Ok(global)
}

/// Freshness fast path for the on-disk reference copy. Never follows a
/// symlink: a link whose target currently matches the expected text would
/// bypass `write_file_no_follow`'s rejection and leave the reference
/// externally mutable after generation.
fn reference_is_fresh(path: &std::path::Path) -> bool {
    let is_symlink = std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink());
    !is_symlink
        && std::fs::read_to_string(path).is_ok_and(|existing| existing == FAILURE_REPORTING_DOC)
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
mod tests;
