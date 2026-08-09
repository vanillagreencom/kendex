use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// Resolve the path where project install state (`[agent-skills]`,
/// `[agent-launch-instructions]`, `[agent-frontmatter.<harness>]`, etc.)
/// should be read from and written to for the given project root.
///
/// Normally returns `<root>/vstack.toml`. If the project root's
/// `vstack.toml` is a source-catalog file (top-level `is_source_catalog = true`),
/// returns `<root>/vstack-local.toml` instead so self-installs in the
/// vstack source repo never mutate the canonical catalog that downstream
/// projects clone and read.
pub fn project_config_path(project_root: &Path) -> PathBuf {
    let catalog = project_root.join("vstack.toml");
    if is_source_catalog(&catalog) {
        project_root.join("vstack-local.toml")
    } else {
        catalog
    }
}

fn is_source_catalog(vstack_toml: &Path) -> bool {
    let Ok(content) = std::fs::read_to_string(vstack_toml) else {
        return false;
    };
    let Ok(parsed) = toml::from_str::<toml::Value>(&content) else {
        return false;
    };
    parsed
        .get("is_source_catalog")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// Project-level agent customization config.
///
/// Loaded from `vstack.toml` at the project root. These sections are
/// independent of the source repo's mapping sections and survive updates.
///
/// `[agent-skills]` is the single source of truth for which skills appear
/// in each agent's frontmatter. Users can add or remove entries and run
/// `vstack refresh` to apply.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ProjectConfig {
    /// Skills attached to each agent's frontmatter.  This is the
    /// authoritative list — editing it and running `vstack refresh`
    /// updates the generated agent files.
    #[serde(rename = "agent-skills")]
    pub agent_skills: HashMap<String, Vec<String>>,
    /// Per-agent display colors written to agent frontmatter when supported.
    /// Empty values are ignored and fall back to source frontmatter.
    #[serde(rename = "agent-colors")]
    pub agent_colors: HashMap<String, String>,
    /// Typed frontmatter overrides parsed from `[agent-frontmatter]` and
    /// `[agent-frontmatter.<harness>]`. Parsed manually in `load()` so nested
    /// TOML tables can coexist with per-agent inline tables.
    #[serde(skip)]
    pub agent_frontmatter: HashMap<String, crate::agent::AgentFrontmatterOverrides>,
    #[serde(skip)]
    pub agent_frontmatter_by_harness:
        HashMap<String, HashMap<String, crate::agent::AgentFrontmatterOverrides>>,
    #[serde(rename = "agent-launch-instructions", alias = "agent-guidance")]
    pub agent_guidance: HashMap<String, String>,
    #[serde(rename = "agent-additional-instructions", alias = "agent-instructions")]
    pub agent_instructions: HashMap<String, String>,
    #[serde(rename = "skill-instructions")]
    pub skill_instructions: HashMap<String, String>,
    /// Directory holding project-owned skills that live OUTSIDE `.agents`,
    /// relative to the project root (e.g. `project-skills`). Refresh links each
    /// `<dir>/<name>` into `.agents/skills/<name>`.
    ///
    /// The point is to keep `.agents` free of tracked content. A project that
    /// commits its own skills *inside* `.agents` makes that directory a hybrid
    /// tracked/untracked tree, and a rebase then materializes the symlink into
    /// a real directory holding only the tracked subset — silently dropping
    /// every vstack-installed skill under it (#856). Relocating the tracked
    /// half removes the cause rather than detecting the damage.
    #[serde(rename = "project-skills-dir", default)]
    pub project_skills_dir: Option<String>,
    #[serde(rename = "custom-hooks", default)]
    pub custom_hooks: Vec<CustomHook>,
}

/// A user-defined hook from project config
#[derive(Debug, Clone, Deserialize)]
pub struct CustomHook {
    pub event: String,
    #[serde(default)]
    pub matcher: Option<String>,
    pub command: String,
    /// What this hook does — inlined as instruction text in harnesses
    /// that can't run scripts (Cursor, OpenCode, Codex).
    #[serde(default)]
    pub description: Option<String>,
    /// Which agents to apply to: "all", a role name ("engineer"),
    /// or a list of agent names (["rust", "iced"])
    #[serde(default = "default_hook_agents")]
    pub agents: CustomHookTarget,
}

fn default_hook_agents() -> CustomHookTarget {
    CustomHookTarget::All("all".into())
}

/// Key in `[agent-launch-instructions]`, `[agent-additional-instructions]`,
/// and `[skill-instructions]` whose value applies to every agent/skill.
/// `"*"` is accepted as an alias. The name is reserved: no installable item
/// may be called `all` (enforced in `path_safety::validate_item_name`).
pub const SHARED_INSTRUCTIONS_KEY: &str = "all";
const SHARED_INSTRUCTIONS_KEY_ALIAS: &str = "*";

fn shared_instruction_entry(map: &HashMap<String, String>) -> Option<&str> {
    map.get(SHARED_INSTRUCTIONS_KEY)
        .or_else(|| map.get(SHARED_INSTRUCTIONS_KEY_ALIAS))
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
}

fn is_agent_frontmatter_override(value: &toml::Value) -> bool {
    let Some(table) = value.as_table() else {
        return false;
    };
    [
        "color",
        "model",
        "deny-tools",
        "allowed-subagents",
        "allowedSubagents",
        "subagent-agents",
        "subagent_agents",
        "tools",
        "pane",
        "background",
        "effort",
        "isolation",
        "memory",
        "mode",
        "sandbox-mode",
        "model-reasoning-effort",
        "nickname-candidates",
        "nickname_candidates",
        "nicknameCandidates",
    ]
    .iter()
    .any(|key| table.contains_key(*key))
}

/// Parse `[agent-frontmatter]` and `[agent-frontmatter.<harness>]` tables out
/// of arbitrary `vstack.toml` content. Used by both `ProjectConfig` and
/// `MappingConfig` so the source repo and the project share parsing logic.
pub fn parse_agent_frontmatter_tables(
    content: &str,
) -> (
    HashMap<String, crate::agent::AgentFrontmatterOverrides>,
    HashMap<String, HashMap<String, crate::agent::AgentFrontmatterOverrides>>,
) {
    let mut legacy: HashMap<String, crate::agent::AgentFrontmatterOverrides> = HashMap::new();
    let mut by_harness: HashMap<String, HashMap<String, crate::agent::AgentFrontmatterOverrides>> =
        HashMap::new();
    let Ok(value) = toml::from_str::<toml::Value>(content) else {
        return (legacy, by_harness);
    };
    let Some(table) = value
        .get("agent-frontmatter")
        .and_then(|value| value.as_table())
    else {
        return (legacy, by_harness);
    };
    for (key, value) in table {
        if is_agent_frontmatter_override(value) {
            if let Ok(overrides) = value.clone().try_into() {
                legacy.insert(key.clone(), overrides);
            }
            continue;
        }
        let Some(agent_table) = value.as_table() else {
            continue;
        };
        let harness_key = crate::harness::Harness::from_id(key)
            .map(|harness| harness.id().to_string())
            .unwrap_or_else(|| key.clone());
        for (agent_name, override_value) in agent_table {
            if !is_agent_frontmatter_override(override_value) {
                continue;
            }
            if let Ok(overrides) = override_value.clone().try_into() {
                by_harness
                    .entry(harness_key.clone())
                    .or_default()
                    .insert(agent_name.clone(), overrides);
            }
        }
    }
    (legacy, by_harness)
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum CustomHookTarget {
    All(String),
    List(Vec<String>),
}

impl ProjectConfig {
    /// Load project config from a directory's `vstack.toml`.
    /// Returns default (empty) if the file is missing or unparseable.
    pub fn load(project_root: &Path) -> Self {
        Self::load_strict(project_root).unwrap_or_default()
    }

    /// Load project config without hiding read or parse failures.
    ///
    /// Mutating workflows must use this entry point so a damaged config
    /// cannot be mistaken for an intentional empty configuration. A missing
    /// config remains equivalent to the default configuration.
    pub fn load_strict(project_root: &Path) -> Result<Self> {
        let path = project_config_path(project_root);
        let content = match std::fs::read_to_string(&path) {
            Ok(content) => content,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => {
                return Err(err).with_context(|| format!("reading {}", path.display()));
            }
        };
        let mut parsed: Self =
            toml::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;
        parsed.load_agent_frontmatter_tables(&content);
        Ok(parsed)
    }

    fn load_agent_frontmatter_tables(&mut self, content: &str) {
        let (legacy, by_harness) = parse_agent_frontmatter_tables(content);
        for (key, value) in legacy {
            self.agent_frontmatter.insert(key, value);
        }
        for (harness_key, entries) in by_harness {
            self.agent_frontmatter_by_harness
                .entry(harness_key)
                .or_default()
                .extend(entries);
        }
    }

    /// Overlay frontmatter defaults from a source `MappingConfig` so that
    /// values it defines act as defaults beneath the project's own entries.
    /// Project entries always win for any field set on both sides.
    pub fn overlay_source_frontmatter(&mut self, mapping: &crate::mapping::MappingConfig) {
        for (name, source) in &mapping.agent_frontmatter {
            let entry = self.agent_frontmatter.entry(name.clone()).or_default();
            *entry = source.merge(entry);
        }
        for (harness, entries) in &mapping.agent_frontmatter_by_harness {
            let target = self
                .agent_frontmatter_by_harness
                .entry(harness.clone())
                .or_default();
            for (name, source) in entries {
                let current = target.entry(name.clone()).or_default();
                *current = source.merge(current);
            }
        }
    }

    /// Get the project-level skill list for an agent, if one exists.
    /// Returns `None` when the agent has no `[agent-skills]` entry,
    /// which tells callers to fall back to source mapping.
    pub fn agent_skills_for(&self, agent_name: &str) -> Option<&Vec<String>> {
        self.agent_skills.get(agent_name)
    }

    /// Get the project-level color override for an agent, if one exists.
    pub fn color_for(&self, agent_name: &str) -> Option<&str> {
        self.agent_colors
            .get(agent_name)
            .map(|s| s.as_str())
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                self.agent_frontmatter
                    .get(agent_name)
                    .and_then(|entry| entry.color.as_deref())
                    .filter(|s| !s.trim().is_empty())
            })
    }

    /// Get harness-specific frontmatter overrides for an agent. The legacy
    /// top-level `[agent-frontmatter]` table is returned only when callers pass
    /// an empty harness id; normal harness generation does not merge it.
    pub fn frontmatter_for(
        &self,
        agent_name: &str,
        harness_id: &str,
    ) -> crate::agent::AgentFrontmatterOverrides {
        if harness_id.is_empty() {
            return self
                .agent_frontmatter
                .get(agent_name)
                .cloned()
                .unwrap_or_default();
        }
        self.agent_frontmatter_by_harness
            .get(harness_id)
            .and_then(|entries| entries.get(agent_name))
            .cloned()
            .unwrap_or_default()
    }

    /// Get guidance text for an agent (per-agent entry only; the shared
    /// `all` entry is merged in by [`Self::merge_shared_and_specific`]).
    pub fn guidance_for(&self, agent_name: &str) -> Option<&str> {
        self.agent_guidance.get(agent_name).map(|s| s.as_str())
    }

    /// Get additional instructions for an agent (per-agent entry only).
    pub fn instructions_for(&self, agent_name: &str) -> Option<&str> {
        self.agent_instructions.get(agent_name).map(|s| s.as_str())
    }

    /// Shared `[agent-launch-instructions]` value applied to every agent.
    pub fn shared_guidance(&self) -> Option<&str> {
        shared_instruction_entry(&self.agent_guidance)
    }

    /// Shared `[agent-additional-instructions]` value applied to every agent.
    pub fn shared_instructions(&self) -> Option<&str> {
        shared_instruction_entry(&self.agent_instructions)
    }

    /// Get project-specific instructions for a skill: the shared `all` entry
    /// (if any) followed by the skill's own entry, blank-line separated.
    pub fn skill_instructions_for(&self, skill_name: &str) -> Option<String> {
        let specific = self
            .skill_instructions
            .get(skill_name)
            .map(|s| s.as_str())
            .filter(|s| !s.is_empty());
        Self::merge_shared_and_specific(
            shared_instruction_entry(&self.skill_instructions),
            specific,
        )
    }

    /// Merge a shared (`all`) instruction value with an item-specific one:
    /// both render, shared first, separated by a blank line.
    pub fn merge_shared_and_specific(
        shared: Option<&str>,
        specific: Option<&str>,
    ) -> Option<String> {
        match (shared, specific) {
            (Some(shared), Some(specific)) => {
                Some(format!("{}\n\n{}", shared.trim(), specific.trim()))
            }
            (Some(text), None) | (None, Some(text)) => Some(text.trim().to_string()),
            (None, None) => None,
        }
    }

    /// Remove the shared (`all`) portion from text extracted out of a
    /// generated agent file. Generated files render the merged value, so
    /// re-extraction must not persist or re-merge the shared part as an
    /// item-specific entry — that would paste the fleet-wide text into every
    /// per-agent key on the next refresh.
    pub fn strip_shared_prefix<'a>(shared: Option<&str>, extracted: &'a str) -> Option<&'a str> {
        let Some(shared) = shared.map(str::trim).filter(|s| !s.is_empty()) else {
            return Some(extracted);
        };
        match extracted.trim().strip_prefix(shared) {
            Some(rest) => {
                let rest = rest.trim();
                (!rest.is_empty()).then_some(rest)
            }
            None => Some(extracted),
        }
    }

    /// Get custom hooks that apply to a specific agent, as CustomHookEntry for agent frontmatter
    pub fn custom_hooks_for(
        &self,
        agent_name: &str,
        agent_role: &crate::agent::AgentRole,
    ) -> Vec<crate::agent::CustomHookEntry> {
        let role_str = agent_role.as_str();
        self.custom_hooks
            .iter()
            .filter(|h| match &h.agents {
                CustomHookTarget::All(s) => s == "all",
                CustomHookTarget::List(names) => {
                    names.iter().any(|n| n == agent_name || n == role_str)
                }
            })
            .map(|h| crate::agent::CustomHookEntry {
                event: h.event.clone(),
                matcher: h.matcher.clone(),
                command: h.command.clone(),
                description: h.description.clone(),
            })
            .collect()
    }

    /// Merge extracted agent sections into vstack.toml, preserving existing entries.
    /// Only writes new entries — never overwrites user-set values.
    pub fn save_extracted(
        &mut self,
        project_root: &Path,
        agent_name: &str,
        extracted: &crate::agent::AgentExtras,
    ) {
        // A generated file renders the merged shared+specific value; only the
        // specific remainder may be persisted as this agent's own entry.
        let extracted_guidance = extracted
            .guidance
            .as_deref()
            .and_then(|text| Self::strip_shared_prefix(self.shared_guidance(), text))
            .map(String::from);
        let extracted_instructions = extracted
            .instructions
            .as_deref()
            .and_then(|text| Self::strip_shared_prefix(self.shared_instructions(), text))
            .map(String::from);

        let needs_guidance =
            extracted_guidance.is_some() && self.guidance_for(agent_name).is_none();
        let needs_instructions =
            extracted_instructions.is_some() && self.instructions_for(agent_name).is_none();
        if !needs_guidance && !needs_instructions {
            return;
        }

        if let Some(ref text) = extracted_guidance
            && needs_guidance
        {
            self.agent_guidance
                .insert(agent_name.to_string(), text.clone());
        }
        if let Some(ref text) = extracted_instructions
            && needs_instructions
        {
            self.agent_instructions
                .insert(agent_name.to_string(), text.clone());
        }

        // Write back to vstack.toml surgically — preserve comments and structure
        let path = project_config_path(project_root);
        let existing = std::fs::read_to_string(&path).unwrap_or_default();
        let mut out = existing.clone();

        if needs_guidance && let Some(ref text) = extracted_guidance {
            out = upsert_agent_value_in_section(
                &out,
                "[agent-launch-instructions]",
                agent_name,
                text,
            );
        }

        if needs_instructions && let Some(ref text) = extracted_instructions {
            out = upsert_agent_value_in_section(
                &out,
                "[agent-additional-instructions]",
                agent_name,
                text,
            );
        }

        out = dedupe_agent_frontmatter_sections(&out);

        if !same_ignoring_trailing_newline(&out, &existing) {
            let _ = std::fs::write(&path, out);
        }
    }
}

/// Set `<agent_name> = "<text>"` inside `[section_header]`:
///
/// - if the section has any line starting with `<agent_name> =` (any value),
///   replace the FIRST such line and drop any duplicate trailing siblings;
/// - otherwise append the entry to the section.
///
/// This is duplicate-safe even if the file got corrupted by a prior bug —
/// running it always leaves exactly one `<agent_name> = ...` line in the
/// section.
fn upsert_agent_value_in_section(
    content: &str,
    section_header: &str,
    agent_name: &str,
    text: &str,
) -> String {
    let new_line = format!("{} = {}", agent_name, format_toml_string_value(text));
    let key_prefix = format!("{} =", agent_name);
    let key_prefix_tight = format!("{}=", agent_name);

    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut result: Vec<String> = Vec::with_capacity(lines.len());
    let mut in_section = false;
    let mut wrote_replacement = false;
    let mut found_any = false;

    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();

        if is_section_header_line(trimmed, string_content[i]) {
            // Section transition
            in_section = trimmed == section_header;
            result.push(line.to_string());
            i += 1;
            continue;
        }

        if in_section
            && !string_content[i]
            && (trimmed.starts_with(&key_prefix) || trimmed.starts_with(&key_prefix_tight))
        {
            // First occurrence: replace; subsequent: drop
            found_any = true;
            if !wrote_replacement {
                result.push(new_line.clone());
                wrote_replacement = true;
            }
            if starts_toml_multiline_value(trimmed) {
                i += 1;
                while i < lines.len() {
                    if closes_toml_multiline_value(lines[i].trim()) {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            i += 1;
            continue;
        }

        result.push(line.to_string());
        i += 1;
    }

    let mut out = result.join("\n");
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }

    if !found_any {
        // Section didn't have an entry yet — append one.
        let entry = format!("{}\n", new_line);
        out = insert_entries_into_section(&out, section_header, &entry);
    }
    out
}

fn format_toml_string_value(text: &str) -> String {
    if text.contains('\n') {
        let escaped = text.replace('\\', "\\\\").replace("\"\"\"", "\\\"\\\"\\\"");
        format!("\"\"\"\n{}\"\"\"", escaped.trim_end_matches('\n'))
    } else {
        let escaped = text
            .replace('\\', "\\\\")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
            .replace('"', "\\\"");
        format!("\"{}\"", escaped)
    }
}

fn starts_toml_multiline_value(trimmed_line: &str) -> bool {
    let Some((_, value)) = trimmed_line.split_once('=') else {
        return false;
    };
    let value = value.trim_start();
    if let Some(rest) = value.strip_prefix("\"\"\"") {
        return !rest.contains("\"\"\"");
    }
    if let Some(rest) = value.strip_prefix("'''") {
        return !rest.contains("'''");
    }
    false
}

fn closes_toml_multiline_value(trimmed_line: &str) -> bool {
    closes_multiline_delimiter(trimmed_line, "\"\"\"")
        || closes_multiline_delimiter(trimmed_line, "'''")
}

/// A multi-line string close may be followed by whitespace and a `#` comment
/// on the same line; anything else after the delimiter keeps the line inside
/// the string.
fn closes_multiline_delimiter(trimmed_line: &str, delimiter: &str) -> bool {
    let Some(position) = trimmed_line.rfind(delimiter) else {
        return false;
    };
    let after = trimmed_line[position + delimiter.len()..].trim_start();
    after.is_empty() || after.starts_with('#')
}

/// Per-line flags: true when the line BEGINS inside a TOML multi-line string
/// value (`"""` basic or `'''` literal). The opening `key = """` line is
/// structure (false); every following line through the one carrying the
/// closing delimiter is string content (true).
///
/// The line-based passes in this file must treat flagged lines as opaque
/// content: prose inside a string may mention `[section-name]` — even alone
/// at the start of a line — or look like `key = value` without being TOML
/// structure. Matching those shapes inside a string rewrites the consumer's
/// prose (vstack#1006).
fn toml_multiline_string_content_lines(content: &str) -> Vec<bool> {
    let mut flags = Vec::with_capacity(content.lines().count());
    let mut open_delimiter: Option<&'static str> = None;
    for line in content.lines() {
        flags.push(open_delimiter.is_some());
        let trimmed = line.trim();
        match open_delimiter {
            Some(delimiter) => {
                if closes_multiline_delimiter(trimmed, delimiter) {
                    open_delimiter = None;
                }
            }
            None => {
                // Comment lines can quote opener shapes as prose — the
                // launch-instructions heading itself contains `# iced = """`.
                if !trimmed.starts_with('#')
                    && let Some((_, value)) = trimmed.split_once('=')
                {
                    let value = value.trim_start();
                    for delimiter in ["\"\"\"", "'''"] {
                        if let Some(rest) = value.strip_prefix(delimiter) {
                            if !rest.contains(delimiter) {
                                open_delimiter = Some(delimiter);
                            }
                            break;
                        }
                    }
                }
            }
        }
    }
    flags
}

/// A trimmed line is a structural TOML section header only outside any
/// multi-line string value (see `toml_multiline_string_content_lines`).
fn is_section_header_line(trimmed: &str, inside_multiline_string: bool) -> bool {
    !inside_multiline_string && trimmed.starts_with('[') && !trimmed.starts_with("# [")
}

/// Replace occurrences of `old` in one physical line, skipping any occurrence
/// that sits inside a single-line TOML string value (vstack#1006).
fn replace_outside_inline_strings(line: &str, old: &str, new: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut cursor = 0;
    while let Some(found) = line[cursor..].find(old) {
        let idx = cursor + found;
        out.push_str(&line[cursor..idx]);
        if index_is_inside_inline_string(line, idx) {
            out.push_str(old);
        } else {
            out.push_str(new);
        }
        cursor = idx + old.len();
    }
    out.push_str(&line[cursor..]);
    out
}

/// True when byte offset `target` in `line` falls inside a single-line TOML
/// string (`"..."` with backslash escapes, or `'...'`). Prose inside such a
/// value may mention `[section-name]` without being structure (vstack#1006).
fn index_is_inside_inline_string(line: &str, target: usize) -> bool {
    let bytes = line.as_bytes();
    let mut delimiter: Option<u8> = None;
    let mut i = 0;
    while i < bytes.len() && i < target {
        let byte = bytes[i];
        match delimiter {
            Some(b'"') => {
                if byte == b'\\' {
                    i += 2;
                    continue;
                }
                if byte == b'"' {
                    delimiter = None;
                }
            }
            Some(_) => {
                if byte == b'\'' {
                    delimiter = None;
                }
            }
            None => {
                if byte == b'"' || byte == b'\'' {
                    delimiter = Some(byte);
                }
            }
        }
        i += 1;
    }
    delimiter.is_some()
}

fn toml_inline_string(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('\r', "\\r")
            .replace('\n', "\\n")
            .replace('\t', "\\t")
            .replace('"', "\\\"")
    )
}

fn toml_inline_array(values: &[String]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(|value| toml_inline_string(value))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn split_top_level_commas(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut bracket_depth = 0usize;
    let mut escaped = false;

    for ch in input.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        if ch == '\\' {
            current.push(ch);
            escaped = true;
            continue;
        }
        if let Some(q) = quote {
            current.push(ch);
            if ch == q {
                quote = None;
            }
            continue;
        }
        if ch == '"' || ch == '\'' {
            quote = Some(ch);
            current.push(ch);
            continue;
        }
        if ch == '[' {
            bracket_depth += 1;
        } else if ch == ']' {
            bracket_depth = bracket_depth.saturating_sub(1);
        }
        if ch == ',' && bracket_depth == 0 {
            if !current.trim().is_empty() {
                out.push(current.trim().to_string());
            }
            current.clear();
            continue;
        }
        current.push(ch);
    }
    if !current.trim().is_empty() {
        out.push(current.trim().to_string());
    }
    out
}

fn parse_inline_table_fields(value: &str) -> Vec<(String, String)> {
    let trimmed = value
        .trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .trim();
    split_top_level_commas(trimmed)
        .into_iter()
        .filter_map(|part| {
            let (key, value) = part.split_once('=')?;
            Some((key.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

fn parse_toml_array_strings(value: &str) -> Vec<String> {
    let trimmed = value.trim().trim_start_matches('[').trim_end_matches(']');
    split_top_level_commas(trimmed)
        .into_iter()
        .map(|part| part.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|part| !part.is_empty())
        .collect()
}

fn toml_scalar_string_value(value: &str) -> String {
    value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim()
        .to_string()
}

fn is_legacy_pi_extra_deny_tools(tools: &[String]) -> bool {
    tools == ["get_subagent_result", "steer_subagent", "stop_subagent"]
}

fn is_generated_opencode_subagent_deny_tools(tools: &[String]) -> bool {
    tools == ["task"] || tools == ["task", "question"]
}

fn inline_mode_is_primary(fields: &[(String, String)]) -> bool {
    fields
        .iter()
        .find(|(field, _)| field == "mode")
        .map(|(_, value)| {
            value
                .trim()
                .trim_matches('"')
                .eq_ignore_ascii_case("primary")
        })
        .unwrap_or(false)
}

fn render_inline_table_fields(fields: &[(String, String)]) -> String {
    let preferred = [
        "color",
        "model",
        "effort",
        "deny-tools",
        "allowed-subagents",
        "pane",
        "background",
        "isolation",
        "memory",
        "mode",
        "sandbox-mode",
        "model-reasoning-effort",
    ];
    let mut ordered: Vec<(String, String)> = Vec::new();
    for key in preferred {
        if let Some((k, v)) = fields.iter().find(|(k, _)| k == key) {
            ordered.push((k.clone(), v.clone()));
        }
    }
    let mut rest: Vec<(String, String)> = fields
        .iter()
        .filter(|(k, _)| !preferred.contains(&k.as_str()))
        .cloned()
        .collect();
    rest.sort_by(|a, b| a.0.cmp(&b.0));
    ordered.extend(rest);
    format!(
        "{{ {} }}",
        ordered
            .into_iter()
            .map(|(key, value)| format!("{} = {}", key, value))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn upsert_agent_frontmatter_field(
    content: &str,
    agent_name: &str,
    field: &str,
    value: &str,
) -> String {
    let field_value = toml_inline_string(value);
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut result: Vec<String> = Vec::with_capacity(lines.len() + 4);
    let mut i = 0;
    let mut found_section = false;
    let mut inserted_or_updated = false;
    let key_prefix = format!("{} =", agent_name);
    let key_prefix_tight = format!("{}=", agent_name);

    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();
        result.push(line.to_string());

        if !string_content[i] && trimmed == "[agent-frontmatter]" {
            found_section = true;
            i += 1;
            while i < lines.len() {
                let next = lines[i];
                let next_trimmed = next.trim();
                if string_content[i] {
                    result.push(next.to_string());
                    i += 1;
                    continue;
                }
                if next_trimmed.starts_with('[') && !next_trimmed.starts_with("# [") {
                    break;
                }
                if next_trimmed.starts_with(&key_prefix)
                    || next_trimmed.starts_with(&key_prefix_tight)
                {
                    let existing_value = next.split_once('=').map(|(_, v)| v).unwrap_or("{}");
                    let mut fields = parse_inline_table_fields(existing_value);
                    if let Some((_, existing)) = fields.iter_mut().find(|(k, _)| k == field) {
                        *existing = field_value.clone();
                    } else {
                        fields.push((field.to_string(), field_value.clone()));
                    }
                    result.push(format!(
                        "{} = {}",
                        agent_name,
                        render_inline_table_fields(&fields)
                    ));
                    inserted_or_updated = true;
                    i += 1;
                    continue;
                }
                result.push(next.to_string());
                i += 1;
            }
            if !inserted_or_updated {
                result.push(format!(
                    "{} = {{ {} = {} }}",
                    agent_name, field, field_value
                ));
                inserted_or_updated = true;
            }
            continue;
        }
        i += 1;
    }

    if !found_section {
        result.push(String::new());
        result.push("[agent-frontmatter]".to_string());
        result.push(format!(
            "{} = {{ {} = {} }}",
            agent_name, field, field_value
        ));
    }

    let mut out = result.join("\n");
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// Write computed agent→skill mappings into the project vstack.toml.
///
/// Merge upstream skill additions into existing `[agent-skills]` entries.
///
/// For each agent in `updates`, if the project toml already has an entry,
/// replace it with the updated list (which includes upstream additions).
/// Agents without an existing entry are ignored — `write_agent_skills`
/// handles those.
pub fn merge_upstream_agent_skills(project_root: &Path, updates: &HashMap<String, Vec<String>>) {
    if updates.is_empty() {
        return;
    }
    let path = project_config_path(project_root);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut out = content.clone();
    for (agent, skills) in updates {
        // Build the replacement value
        let new_value = if skills.is_empty() {
            "[]".to_string()
        } else {
            let mut v = "[\n".to_string();
            for s in skills {
                v.push_str(&format!("    \"{}\",\n", s));
            }
            v.push(']');
            v
        };

        // Replace the existing entry using regex-like line matching.
        // Handles both inline arrays and multi-line arrays.
        out = replace_toml_array_value(&out, "[agent-skills]", agent, &new_value);
    }

    out = ensure_value_section_entry_spacing(&out);
    if !same_ignoring_trailing_newline(&out, &content) {
        let _ = std::fs::write(&path, out);
    }
}

/// Replace a TOML array value for a key within a specific section.
/// Handles both `key = [...]` (inline) and multi-line arrays.
fn replace_toml_array_value(
    content: &str,
    section_header: &str,
    key: &str,
    new_value: &str,
) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut result: Vec<String> = Vec::new();
    let mut i = 0;
    let mut in_section = false;

    while i < lines.len() {
        let trimmed = lines[i].trim();

        // Track which section we're in
        if is_section_header_line(trimmed, string_content[i]) {
            in_section = trimmed == section_header;
        }

        if in_section && !string_content[i] {
            // Check if this line starts the key we want to replace
            let key_prefix = format!("{} = ", key);
            let key_prefix_tight = format!("{}= ", key);
            if trimmed.starts_with(&key_prefix) || trimmed.starts_with(&key_prefix_tight) {
                // Check if it's a multi-line array (value starts with [ but doesn't close)
                if let Some(after_eq) = trimmed.split_once('=').map(|(_, v)| v.trim()) {
                    if after_eq.starts_with('[') && !after_eq.contains(']') {
                        // Multi-line array — skip until closing ]
                        i += 1;
                        while i < lines.len() && !lines[i].trim().starts_with(']') {
                            i += 1;
                        }
                        // Skip the closing ] line too
                        if i < lines.len() {
                            i += 1;
                        }
                    } else {
                        // Single-line — skip just this line
                        i += 1;
                    }
                } else {
                    i += 1;
                }
                // Write replacement
                result.push(format!("{} = {}", key, new_value));
                continue;
            }
        }

        result.push(lines[i].to_string());
        i += 1;
    }

    let mut out = result.join("\n");
    // Preserve trailing newline if original had one
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// For each agent: if the project toml already has an `[agent-skills]` entry,
/// preserve it (the user may have added or removed skills).  For agents that
/// have NO entry yet, write the computed list from source mapping.
///
/// This must be called AFTER `ensure_project_config` and AFTER the skill
/// mapping is computed.
pub fn write_agent_skills(project_root: &Path, agent_skill_map: &HashMap<String, Vec<String>>) {
    let path = project_config_path(project_root);
    let existing = std::fs::read_to_string(&path).unwrap_or_default();

    // Parse the existing file to discover which agents already have entries.
    // We only ADD agents that are missing — never clobber user edits.
    let parsed: ProjectConfig = toml::from_str(&existing).unwrap_or_default();

    // Sort agents for deterministic output
    let mut agents: Vec<&String> = agent_skill_map.keys().collect();
    agents.sort();

    let mut new_entries = String::new();
    for agent in agents {
        if parsed.agent_skills.contains_key(agent.as_str()) {
            continue; // User's list is authoritative — don't overwrite
        }
        let skills = &agent_skill_map[agent];
        new_entries.push_str(&format!("{} = [", agent));
        if skills.is_empty() {
            new_entries.push_str("]\n");
        } else {
            new_entries.push('\n');
            for s in skills {
                new_entries.push_str(&format!("    \"{}\",\n", s));
            }
            new_entries.push_str("]\n");
        }
    }

    if new_entries.is_empty() {
        return;
    }

    // Insert the new entries into the [agent-skills] section
    let out = ensure_value_section_entry_spacing(&insert_entries_into_section(
        &existing,
        "[agent-skills]",
        &new_entries,
    ));
    if !same_ignoring_trailing_newline(&out, &existing) {
        let _ = std::fs::write(&path, out);
    }
}

/// Deprecated compatibility shim. Default colors now live in each
/// harness-specific frontmatter section, so this must not create a shared
/// `[agent-frontmatter]` block.
pub fn write_agent_colors(
    _project_root: &Path,
    _agent_color_map: &HashMap<String, Option<String>>,
) {
}

/// Write the generated frontmatter defaults into `vstack.toml` as real,
/// editable entries. Existing user-set fields are preserved; missing fields are
/// filled so users can inspect and modify the values that drive regeneration.
pub fn write_agent_frontmatter_defaults(
    project_root: &Path,
    agents: &[crate::agent::Agent],
    harnesses_by_agent: &HashMap<String, Vec<crate::harness::Harness>>,
    mapping: &crate::mapping::MappingConfig,
) {
    if agents.is_empty() || harnesses_by_agent.is_empty() {
        return;
    }

    let path = project_config_path(project_root);
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let mut content = ensure_agent_frontmatter_scaffold(&existing);
    let mut existing_config = project_config_from_content(&content);
    existing_config.overlay_source_frontmatter(mapping);
    content = remove_agent_frontmatter_base_section(&content);
    content = remove_agent_colors_section(&content);

    let mut agents_sorted: Vec<&crate::agent::Agent> = agents
        .iter()
        .filter(|agent| harnesses_by_agent.contains_key(&agent.name))
        .collect();
    agents_sorted.sort_by(|a, b| a.name.cmp(&b.name));

    for (harness, section) in [
        (
            crate::harness::Harness::ClaudeCode,
            "[agent-frontmatter.claude]",
        ),
        (
            crate::harness::Harness::OpenCode,
            "[agent-frontmatter.opencode]",
        ),
        (crate::harness::Harness::Codex, "[agent-frontmatter.codex]"),
        (crate::harness::Harness::Pi, "[agent-frontmatter.pi]"),
    ] {
        let entries: Vec<(String, Vec<(String, String)>)> = agents_sorted
            .iter()
            .filter(|agent| {
                harnesses_by_agent
                    .get(&agent.name)
                    .is_some_and(|harnesses| harnesses.contains(&harness))
            })
            .map(|agent| {
                (
                    agent.name.clone(),
                    harness_frontmatter_defaults(agent, harness, &existing_config),
                )
            })
            .filter(|(_, fields)| !fields.is_empty())
            .collect();
        content = merge_frontmatter_defaults_into_section(&content, section, &entries);
    }

    content = ensure_value_section_entry_spacing(&dedupe_agent_frontmatter_sections(&content));
    if !same_ignoring_trailing_newline(&content, &existing) {
        let _ = std::fs::write(path, content);
    }
}

fn project_config_from_content(content: &str) -> ProjectConfig {
    let mut parsed: ProjectConfig = toml::from_str(content).unwrap_or_default();
    parsed.load_agent_frontmatter_tables(content);
    parsed
}

fn remove_agent_frontmatter_base_section(content: &str) -> String {
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::new();
    let mut in_base = false;

    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            if trimmed == "[agent-frontmatter]" {
                in_base = true;
                continue;
            }
            in_base = false;
        }
        if !in_base {
            out.push(line.to_string());
        }
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') && !rendered.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn remove_agent_colors_section(content: &str) -> String {
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::new();
    let mut in_colors = false;

    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            if trimmed == "[agent-colors]" {
                in_colors = true;
                continue;
            }
            in_colors = false;
        }
        if !in_colors {
            out.push(line.to_string());
        }
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') && !rendered.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn harness_frontmatter_defaults(
    agent: &crate::agent::Agent,
    harness: crate::harness::Harness,
    config: &ProjectConfig,
) -> Vec<(String, String)> {
    let frontmatter = legacy_effective_frontmatter(agent, harness, config);
    match harness {
        crate::harness::Harness::ClaudeCode => {
            claude_frontmatter_defaults(agent, &frontmatter, config)
        }
        crate::harness::Harness::OpenCode => opencode_frontmatter_defaults(agent, &frontmatter),
        crate::harness::Harness::Codex => codex_frontmatter_defaults(agent, &frontmatter),
        crate::harness::Harness::Pi => pi_frontmatter_defaults(agent, &frontmatter),
        crate::harness::Harness::Cursor => Vec::new(),
    }
}

fn legacy_effective_frontmatter(
    agent: &crate::agent::Agent,
    harness: crate::harness::Harness,
    config: &ProjectConfig,
) -> crate::agent::AgentFrontmatterOverrides {
    let mut base = config
        .agent_frontmatter
        .get(&agent.name)
        .cloned()
        .unwrap_or_default();
    if base.color.is_none() {
        base.color = config
            .agent_colors
            .get(&agent.name)
            .filter(|color| !color.trim().is_empty())
            .cloned();
    }
    let harness = config
        .agent_frontmatter_by_harness
        .get(harness.id())
        .and_then(|entries| entries.get(&agent.name))
        .cloned()
        .unwrap_or_default();
    base.merge(&harness)
}

fn claude_frontmatter_defaults(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
    config: &ProjectConfig,
) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    push_color_field(&mut fields, agent, frontmatter, false);
    fields.push((
        "model".into(),
        toml_inline_string(&claude_model_default(agent, frontmatter)),
    ));
    let effort = frontmatter.effort.clone().or_else(|| agent.effort.clone());
    if let Some(effort) = effort.filter(|effort| !is_none_value(effort)) {
        fields.push(("effort".into(), toml_inline_string(&effort)));
    }
    fields.push((
        "deny-tools".into(),
        toml_inline_array(&claude_default_deny_tools(agent)),
    ));
    fields.push((
        "background".into(),
        default_claude_background(agent, config).to_string(),
    ));
    fields
}

fn opencode_frontmatter_defaults(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    push_color_field(&mut fields, agent, frontmatter, true);
    fields.push((
        "model".into(),
        toml_inline_string(&crate::agent::model_id_for(
            "openai",
            frontmatter.model.as_deref().unwrap_or(&agent.model),
        )),
    ));
    if let Some(effort) = openai_reasoning_effort(agent, frontmatter) {
        fields.push(("model-reasoning-effort".into(), toml_inline_string(&effort)));
    }
    let mode = opencode_mode_default(frontmatter);
    fields.push((
        "deny-tools".into(),
        toml_inline_array(&opencode_default_deny_tools(agent, &mode)),
    ));
    fields.push(("mode".into(), toml_inline_string(&mode)));
    fields
}

fn codex_frontmatter_defaults(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    fields.push((
        "nickname-candidates".into(),
        toml_inline_array(&crate::harness::codex::default_nickname_candidates(
            &agent.name,
        )),
    ));
    fields.push((
        "model".into(),
        toml_inline_string(&codex_model_name(
            frontmatter.model.as_deref().unwrap_or(&agent.model),
        )),
    ));
    if let Some(effort) = openai_reasoning_effort(agent, frontmatter) {
        fields.push(("model-reasoning-effort".into(), toml_inline_string(&effort)));
    }
    fields.push((
        "sandbox-mode".into(),
        toml_inline_string(match agent.role {
            crate::agent::AgentRole::Engineer => "danger-full-access",
            crate::agent::AgentRole::Analyst
            | crate::agent::AgentRole::Reviewer
            | crate::agent::AgentRole::Manager => "workspace-write",
        }),
    ));
    fields
}

fn pi_frontmatter_defaults(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> Vec<(String, String)> {
    let allowed_subagents = pi_default_allowed_subagents_with_override(agent, frontmatter);
    let mut fields = Vec::new();
    push_color_field(&mut fields, agent, frontmatter, false);
    fields.push((
        "model".into(),
        toml_inline_string(&pi_model_default(agent, frontmatter)),
    ));
    fields.push((
        "deny-tools".into(),
        toml_inline_array(&pi_default_deny_tools(agent, &allowed_subagents)),
    ));
    fields.push((
        "allowed-subagents".into(),
        toml_inline_array(&allowed_subagents),
    ));
    fields.push(("pane".into(), default_pi_pane(agent).to_string()));
    fields
}

fn pi_default_allowed_subagents_with_override(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> Vec<String> {
    if let Some(list) = &frontmatter.allowed_subagents {
        return list
            .iter()
            .map(|name| name.trim().to_string())
            .filter(|name| !name.is_empty())
            .collect();
    }
    crate::harness::pi::pi_default_allowed_subagents_for(agent)
}

fn pi_extra_default_deny_tools() -> Vec<String> {
    vec![
        "get_subagent_result".into(),
        "steer_subagent".into(),
        "stop_subagent".into(),
    ]
}

fn push_color_field(
    fields: &mut Vec<(String, String)>,
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
    opencode_hex: bool,
) {
    let Some(color) = frontmatter
        .color
        .as_deref()
        .or(agent.color.as_deref())
        .filter(|color| !color.trim().is_empty())
    else {
        return;
    };
    let color = if opencode_hex {
        opencode_color_name(color).unwrap_or_else(|| color.trim().to_string())
    } else {
        color.trim().to_string()
    };
    fields.push(("color".into(), toml_inline_string(&color)));
}

fn openai_reasoning_effort(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> Option<String> {
    frontmatter
        .model_reasoning_effort
        .clone()
        .or_else(|| frontmatter.effort.clone())
        .or_else(|| agent.effort.clone())
        .filter(|effort| !is_none_value(effort))
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

fn claude_default_deny_tools(agent: &crate::agent::Agent) -> Vec<String> {
    let mut tools = vec!["Agent".into()];
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("AskUserQuestion".into());
    }
    tools
}

fn opencode_mode_default(frontmatter: &crate::agent::AgentFrontmatterOverrides) -> String {
    match frontmatter.mode.as_deref() {
        Some(mode) if mode.trim().eq_ignore_ascii_case("all") => "subagent".into(),
        Some(mode) if !mode.trim().is_empty() => mode.trim().into(),
        _ => "subagent".into(),
    }
}

fn opencode_default_deny_tools(agent: &crate::agent::Agent, mode: &str) -> Vec<String> {
    if !mode.eq_ignore_ascii_case("subagent") {
        return Vec::new();
    }
    let mut tools = vec!["task".into()];
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("question".into());
    }
    tools
}

fn pi_default_deny_tools(agent: &crate::agent::Agent, allowed_subagents: &[String]) -> Vec<String> {
    let mut tools = vec![
        "subagent".into(),
        "get_subagent_result".into(),
        "steer_subagent".into(),
        "stop_subagent".into(),
    ];
    if allowed_subagents.is_empty() {
        tools.push("delegate_subagent".into());
    }
    if !agent.name.eq_ignore_ascii_case("planner") {
        tools.push("question".into());
    }
    if matches!(agent.role, crate::agent::AgentRole::Reviewer) {
        tools.push("tasks_write".into());
    }
    tools
}

fn opencode_color_name(color: &str) -> Option<String> {
    let trimmed = color.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('#') {
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
        _ => return Some(trimmed.to_string()),
    };
    Some(mapped.to_string())
}

fn codex_model_name(model: &str) -> String {
    match model.trim().to_ascii_lowercase().as_str() {
        "opus" | "sonnet" | "haiku" => "gpt-5.6-sol".into(),
        other => other.into(),
    }
}

fn claude_model_default(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> String {
    let model = frontmatter.model.as_deref().unwrap_or(&agent.model);
    if agent.model.trim().eq_ignore_ascii_case("opus")
        && model.trim().eq_ignore_ascii_case("opus[1m]")
    {
        return crate::agent::model_id_for("claude-code", &agent.model);
    }
    crate::agent::model_id_for("claude-code", model)
}

fn pi_model_default(
    agent: &crate::agent::Agent,
    frontmatter: &crate::agent::AgentFrontmatterOverrides,
) -> String {
    let model = frontmatter.model.as_deref().unwrap_or(&agent.model);
    let effort = openai_reasoning_effort(agent, frontmatter);
    if matches!(
        model.trim().to_ascii_lowercase().as_str(),
        "inherit" | "current" | "parent"
    ) {
        return "inherit".into();
    }
    if agent.model.trim().eq_ignore_ascii_case("opus") {
        let model = model.trim().to_ascii_lowercase();
        if model == "opus"
            || model == "openai-codex/gpt-5.6-sol"
            || model.starts_with("openai-codex/gpt-5.6-sol:")
        {
            return "inherit".into();
        }
    }
    match model.trim().to_ascii_lowercase().as_str() {
        "opus" | "sonnet" | "haiku" => effort
            .map(|effort| format!("openai-codex/gpt-5.6-sol:{effort}"))
            .unwrap_or_else(|| "openai-codex/gpt-5.6-sol".into()),
        other => other.into(),
    }
}

fn default_pi_pane(agent: &crate::agent::Agent) -> bool {
    matches!(agent.role, crate::agent::AgentRole::Engineer)
        || agent.name.eq_ignore_ascii_case("planner")
}

fn effective_pi_pane(agent: &crate::agent::Agent, config: &ProjectConfig) -> bool {
    config
        .frontmatter_for(&agent.name, "pi")
        .pane
        .unwrap_or_else(|| default_pi_pane(agent))
}

fn default_claude_background(agent: &crate::agent::Agent, config: &ProjectConfig) -> bool {
    !effective_pi_pane(agent, config)
}

fn merge_frontmatter_defaults_into_section(
    content: &str,
    section: &str,
    entries: &[(String, Vec<(String, String)>)],
) -> String {
    if entries.is_empty() {
        return content.to_string();
    }
    let content = ensure_frontmatter_section(content, section);
    let mut out = content.clone();
    for (agent, fields) in entries {
        out = upsert_missing_inline_table_fields(&out, section, agent, fields);
    }
    out
}

fn ensure_frontmatter_section(content: &str, section: &str) -> String {
    if section_start(content, section).is_some() {
        return content.to_string();
    }
    let mut out = content.trim_end().to_string();
    out.push_str("\n\n");
    if section != "[agent-frontmatter]" && section != "[agent-frontmatter.pi]" {
        out.push_str(&format!(
            "# {} frontmatter values generated by vstack. Edit fields, then run `vstack refresh`.\n",
            section
                .trim_start_matches("[agent-frontmatter.")
                .trim_end_matches(']')
        ));
    }
    out.push_str(section);
    out.push('\n');
    out
}

fn upsert_missing_inline_table_fields(
    content: &str,
    section: &str,
    agent_name: &str,
    defaults: &[(String, String)],
) -> String {
    let string_content = toml_multiline_string_content_lines(content);
    let mut result = Vec::new();
    let mut active_section = "";
    let mut inserted = false;
    let mut section_found = false;
    let key_prefix = format!("{} =", agent_name);
    let key_prefix_tight = format!("{}=", agent_name);

    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            if active_section == section && !inserted {
                result.push(format!(
                    "{} = {}",
                    agent_name,
                    render_inline_table_fields(defaults)
                ));
                inserted = true;
            }
            active_section = trimmed;
            section_found |= active_section == section;
            result.push(line.to_string());
            continue;
        }

        if active_section == section
            && !inside_string
            && (trimmed.starts_with(&key_prefix) || trimmed.starts_with(&key_prefix_tight))
        {
            let existing_value = line.split_once('=').map(|(_, value)| value).unwrap_or("{}");
            let mut fields = parse_inline_table_fields(existing_value);
            let existing_keys: HashSet<String> =
                fields.iter().map(|(key, _)| key.clone()).collect();
            for (key, value) in defaults {
                if section == "[agent-frontmatter.opencode]" && key == "mode" {
                    if let Some((_, existing_value)) =
                        fields.iter_mut().find(|(field, _)| field == key)
                    {
                        if existing_value
                            .trim()
                            .trim_matches('"')
                            .eq_ignore_ascii_case("all")
                        {
                            *existing_value = value.clone();
                        }
                    } else {
                        fields.push((key.clone(), value.clone()));
                    }
                    continue;
                }
                if section == "[agent-frontmatter.pi]" && key == "deny-tools" {
                    if let Some((_, existing_value)) =
                        fields.iter_mut().find(|(field, _)| field == key)
                    {
                        let existing_tools = parse_toml_array_strings(existing_value);
                        if is_legacy_pi_extra_deny_tools(&existing_tools) {
                            *existing_value = value.clone();
                        }
                    } else {
                        fields.push((key.clone(), value.clone()));
                    }
                    continue;
                }
                if section == "[agent-frontmatter.opencode]" && key == "deny-tools" {
                    let mode_is_primary = inline_mode_is_primary(&fields);
                    if let Some((_, existing_value)) =
                        fields.iter_mut().find(|(field, _)| field == key)
                    {
                        let existing_tools = parse_toml_array_strings(existing_value);
                        let replacement_tools = parse_toml_array_strings(value);
                        if mode_is_primary
                            && replacement_tools.is_empty()
                            && is_generated_opencode_subagent_deny_tools(&existing_tools)
                        {
                            *existing_value = value.clone();
                        }
                    } else {
                        fields.push((key.clone(), value.clone()));
                    }
                    continue;
                }
                if key == "model" {
                    if !existing_keys.contains(key) {
                        fields.push((key.clone(), value.clone()));
                    }
                    continue;
                }
                if !existing_keys.contains(key) {
                    fields.push((key.clone(), value.clone()));
                }
            }
            result.push(format!(
                "{} = {}",
                agent_name,
                render_inline_table_fields(&fields)
            ));
            inserted = true;
            continue;
        }

        if active_section == section && !inserted && !inside_string && trimmed.starts_with('#') {
            result.push(format!(
                "{} = {}",
                agent_name,
                render_inline_table_fields(defaults)
            ));
            inserted = true;
        }

        result.push(line.to_string());
    }

    if section_found && !inserted {
        result.push(format!(
            "{} = {}",
            agent_name,
            render_inline_table_fields(defaults)
        ));
    }

    let mut rendered = result.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

/// Create or update vstack.toml at the project root.
///
/// - If the file doesn't exist, generates a full template with commented placeholders.
/// - If the file exists, appends commented placeholders for any new agents/skills
///   not already mentioned. Never modifies existing user content.
pub fn ensure_project_config(project_root: &Path, agents: &[String], skills: &[String]) {
    let path = project_config_path(project_root);

    if path.exists() {
        migrate_section_names(&path);
        repair_project_config_structure(&path);
        update_project_config(&path, agents, skills);
    } else {
        create_project_config(&path, agents, skills);
    }
}

fn project_config_header() -> String {
    let mut out = String::new();
    out.push_str("# ─────────────────────────────────────────────────────\n");
    out.push_str("# vstack.toml — project-level agent customization\n");
    out.push_str("#\n");
    out.push_str("# Customize agent behavior for this project. These\n");
    out.push_str("# settings are merged into generated agent files on\n");
    out.push_str("# every install and refresh.\n");
    out.push_str("#\n");
    out.push_str("# Skills live in [agent-skills]. Generated frontmatter\n");
    out.push_str("# overrides like model, effort, deny-tools, color, pane,\n");
    out.push_str("# and Claude background/isolation/memory live in\n");
    out.push_str("# harness-specific [agent-frontmatter.<harness>] tables.\n");
    out.push_str("#\n");
    out.push_str("# After editing, run:  vstack refresh\n");
    out.push_str("# ─────────────────────────────────────────────────────\n");
    out
}

fn repair_project_config_structure(path: &Path) {
    let Ok(existing) = std::fs::read_to_string(path) else {
        return;
    };
    // vstack-local.toml is the self-install state redirect for source-catalog
    // repos (see `project_config_path`): its header is hand-authored and
    // deliberately different from the generic vstack.toml template, never
    // generated by this CLI. Rewriting it on every refresh clobbered that
    // documentation (VST-40) — only the ordinary vstack.toml banner is
    // ours to keep in sync.
    let preserve_header = path.file_name().and_then(|n| n.to_str()) == Some("vstack-local.toml");
    let out = repair_project_config_content(&existing, preserve_header);
    if !same_ignoring_trailing_newline(&out, &existing) {
        let _ = std::fs::write(path, out);
    }
}

fn repair_project_config_content(existing: &str, preserve_header: bool) -> String {
    let mut out = existing.to_string();
    out = normalize_attached_section_headers(&out);
    out = repair_instruction_multiline_values(&out);
    out = ensure_value_section_entry_spacing(&out);
    out = dedupe_agent_frontmatter_sections(&out);
    if !preserve_header {
        out = sync_project_config_header(&out);
    }
    out = ensure_launch_instructions_heading(&out);
    out = ensure_agent_frontmatter_scaffold(&out);
    out
}

/// Refresh the canonical banner at the top of `vstack.toml`.
///
/// This USED TO splice `header + content[launch_instructions_marker..]`, which
/// silently deleted everything between the banner and that marker (vstack#896).
/// That region is not spare space: TOML requires top-level keys to appear BEFORE
/// the first table header, so `project-skills-dir` — and any comment explaining
/// it — has to live exactly there. A consumer that set it lost the key on the
/// first refresh that rewrote the file, which then made refresh refuse that
/// project's own skills and exit non-zero on every subsequent run.
///
/// Replace only the leading comment block, and keep the rest verbatim.
fn sync_project_config_header(content: &str) -> String {
    // Only touch files that look like a vstack.toml: a leading `# ─` banner and
    // a recognizable body. Both guards are the pre-existing preconditions.
    if !content.trim_start().starts_with("# ─") {
        return content.to_string();
    }
    if content
        .find("# ── Launch Instructions")
        .or_else(|| content.find("# ── Execute on Launch"))
        .or_else(|| section_start(content, "[agent-launch-instructions]"))
        .is_none()
    {
        return content.to_string();
    }

    let header = project_config_header();
    let rest = content[leading_comment_block_end(content)..].trim_start_matches('\n');
    if rest.is_empty() {
        let mut out = header.trim_end().to_string();
        if content.ends_with('\n') {
            out.push('\n');
        }
        return out;
    }
    format!("{}\n\n\n{}", header.trim_end(), rest)
}

/// Byte offset just past the leading run of comment lines. Blank lines and
/// anything else end the block, so only the banner itself is consumed.
fn leading_comment_block_end(content: &str) -> usize {
    let mut offset = 0;
    for line in content.split_inclusive('\n') {
        if !line.trim_start().starts_with('#') {
            break;
        }
        offset += line.len();
    }
    offset
}

fn launch_instructions_heading() -> String {
    let mut out = String::new();
    out.push_str("# ── Launch Instructions ───────────────────────────────\n");
    out.push_str("# Adds a \"## Launch Instructions\" section near the top\n");
    out.push_str("# of each agent file. Use this for startup tasks, required\n");
    out.push_str("# reading, or project-specific operating notes.\n");
    out.push_str("# The reserved key `all` applies to every agent, rendered\n");
    out.push_str("# before that agent's own entry.\n");
    out.push_str("# Examples:\n");
    out.push_str("# all = \"Run `just setup` before anything else.\"\n");
    out.push_str("# rust = \"Read docs/architecture.md before coding.\"\n");
    out.push_str("# iced = \"\"\"\n");
    out.push_str("# Read docs/ui.md.\n");
    out.push_str("# Update docs when UI architecture changes.\n");
    out.push_str("# \"\"\"\n");
    out.push_str("#\n");
    out
}

fn ensure_launch_instructions_heading(content: &str) -> String {
    let Some(section_at) = section_start(content, "[agent-launch-instructions]") else {
        return content.to_string();
    };
    let prefix = &content[..section_at];
    let heading_at = prefix
        .rfind("# ── Launch Instructions")
        .or_else(|| prefix.rfind("# ── Execute on Launch"));
    let mut out = String::new();
    if let Some(heading_at) = heading_at {
        out.push_str(content[..heading_at].trim_end());
    } else {
        out.push_str(content[..section_at].trim_end());
    }
    out.push_str("\n\n\n");
    out.push_str(&launch_instructions_heading());
    out.push_str(content[section_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn normalize_attached_section_headers(content: &str) -> String {
    const HEADERS: &[&str] = &[
        "[agent-launch-instructions]",
        "[agent-additional-instructions]",
        "[skill-instructions]",
        "[agent-skills]",
        "[agent-frontmatter]",
        "[agent-frontmatter.claude]",
        "[agent-frontmatter.opencode]",
        "[agent-frontmatter.codex]",
        "[agent-frontmatter.pi]",
        "[agent-colors]",
        "[[custom-hooks]]",
    ];

    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::new();
    for (line, inside_string) in content.lines().zip(string_content) {
        // vstack: a line that is entirely a comment (starts with `#` after
        // optional leading whitespace) can mention any section header as
        // prose. Splitting it on the header substring would slice the
        // comment in two and emit the header as TOML, then leave the
        // remainder as an orphaned line at column 1 — invalid TOML at the
        // next parse. Keep comment lines verbatim. The same holds for lines
        // inside a multi-line string value: prose there may mention a
        // section name in backticks (vstack#1006).
        if inside_string || line.trim_start().starts_with('#') {
            out.push(line.to_string());
            continue;
        }
        let mut pending = line.to_string();
        loop {
            let found = HEADERS
                .iter()
                .filter_map(|header| pending.find(header).map(|idx| (idx, *header)))
                .filter(|(idx, _)| {
                    *idx > 0 && !index_is_inside_inline_string(&pending, *idx)
                })
                .min_by_key(|(idx, _)| *idx);
            let Some((idx, header)) = found else {
                out.push(pending);
                break;
            };
            let prefix = pending[..idx].trim_end().to_string();
            // Leave pure commented placeholder examples like `# [agent-frontmatter.pi]` alone.
            if prefix.trim() == "#" {
                out.push(pending);
                break;
            }
            if !prefix.is_empty() {
                out.push(prefix);
            }
            out.push(header.to_string());
            pending = pending[idx + header.len()..].trim_start().to_string();
            if pending.is_empty() {
                break;
            }
        }
    }
    let mut rendered = out.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn repair_instruction_multiline_values(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::with_capacity(lines.len());
    let mut active_section = "";
    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if is_section_header_line(trimmed, string_content[i]) {
            active_section = trimmed;
            out.push(lines[i].to_string());
            i += 1;
            continue;
        }

        let is_instruction_section = active_section == "[agent-launch-instructions]"
            || active_section == "[agent-additional-instructions]";
        if is_instruction_section
            && !string_content[i]
            && let Some((key, raw_value)) = trimmed.split_once('=')
        {
            let value = raw_value.trim();
            if starts_toml_multiline_value(trimmed) {
                let mut block_lines = vec![lines[i].to_string()];
                i += 1;
                while i < lines.len() {
                    block_lines.push(lines[i].to_string());
                    let just_pushed = lines[i].trim();
                    i += 1;
                    if closes_toml_multiline_value(just_pushed) {
                        break;
                    }
                }
                let block = block_lines.join("\n");
                let value = block.split_once('=').map(|(_, v)| v.trim()).unwrap_or("");
                let mini = format!("value = {}", value);
                if let Ok(parsed) = toml::from_str::<toml::Value>(&mini) {
                    if let Some(text) = parsed.get("value").and_then(|value| value.as_str()) {
                        out.push(format!(
                            "{} = {}",
                            key.trim(),
                            format_toml_string_value(text)
                        ));
                    } else {
                        out.extend(block_lines);
                    }
                } else {
                    out.extend(block_lines);
                }
                i = skip_orphan_duplicate_multiline_body(&lines, i);
                continue;
            }
            if value.starts_with('"') && value.ends_with('"') && value.contains("\\n") {
                let mini = format!("value = {}", value);
                if let Ok(parsed) = toml::from_str::<toml::Value>(&mini)
                    && let Some(text) = parsed.get("value").and_then(|value| value.as_str())
                {
                    out.push(format!(
                        "{} = {}",
                        key.trim(),
                        format_toml_string_value(text)
                    ));
                    i += 1;
                    i = skip_orphan_duplicate_multiline_body(&lines, i);
                    continue;
                }
            }
            out.push(lines[i].to_string());
            i += 1;
            i = skip_orphan_duplicate_multiline_body(&lines, i);
            continue;
        }

        out.push(lines[i].to_string());
        i += 1;
    }
    let mut rendered = out.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn ensure_value_section_entry_spacing(content: &str) -> String {
    const SPACED_SECTIONS: &[&str] = &[
        "[agent-launch-instructions]",
        "[agent-additional-instructions]",
        "[skill-instructions]",
        "[agent-skills]",
        "[agent-frontmatter]",
        "[agent-frontmatter.pi]",
    ];

    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::with_capacity(lines.len());
    let mut active_section = "";
    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if is_section_header_line(trimmed, string_content[i]) {
            active_section = trimmed;
            out.push(lines[i].to_string());
            i += 1;
            continue;
        }

        if (SPACED_SECTIONS.contains(&active_section)
            || is_agent_frontmatter_section(active_section))
            && !string_content[i]
            && looks_like_toml_key_line(trimmed)
        {
            out.push(lines[i].to_string());
            let multiline = starts_toml_multiline_value(trimmed);
            let array = starts_multiline_array_value(trimmed);
            i += 1;
            if multiline {
                while i < lines.len() {
                    out.push(lines[i].to_string());
                    let just_pushed = lines[i].trim();
                    i += 1;
                    if closes_toml_multiline_value(just_pushed) {
                        break;
                    }
                }
            } else if array {
                while i < lines.len() {
                    out.push(lines[i].to_string());
                    let just_pushed = lines[i].trim();
                    i += 1;
                    if closes_multiline_array_value(just_pushed) {
                        break;
                    }
                }
            }
            if i < lines.len() && looks_like_toml_key_line(lines[i].trim()) {
                out.push(String::new());
            }
            continue;
        }

        out.push(lines[i].to_string());
        i += 1;
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    ensure_blank_line_before_section_headers(&rendered)
}

fn ensure_blank_line_before_section_headers(content: &str) -> String {
    let string_content = toml_multiline_string_content_lines(content);
    let mut out: Vec<String> = Vec::new();
    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string)
            && out.last().is_some_and(|previous| {
                !previous.trim().is_empty() && !previous.trim_start().starts_with('#')
            })
        {
            out.push(String::new());
        }
        out.push(line.to_string());
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn starts_multiline_array_value(trimmed_line: &str) -> bool {
    let Some((_, value)) = trimmed_line.split_once('=') else {
        return false;
    };
    let value = value.trim_start();
    value.starts_with('[') && !value.contains(']')
}

fn closes_multiline_array_value(trimmed_line: &str) -> bool {
    trimmed_line.ends_with(']')
}

fn is_agent_frontmatter_section(section: &str) -> bool {
    section == "[agent-frontmatter]" || section.starts_with("[agent-frontmatter.")
}

fn dedupe_agent_frontmatter_sections(content: &str) -> String {
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::new();
    let mut active_section = "";
    let mut seen_keys: HashSet<String> = HashSet::new();

    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            active_section = trimmed;
            seen_keys.clear();
            out.push(line.to_string());
            continue;
        }

        if is_agent_frontmatter_section(active_section)
            && !inside_string
            && looks_like_toml_key_line(trimmed)
            && let Some((key, _)) = trimmed.split_once('=')
        {
            let key = key.trim().to_string();
            if !seen_keys.insert(key) {
                continue;
            }
        }

        out.push(line.to_string());
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') {
        rendered.push('\n');
    }
    rendered
}

fn skip_orphan_duplicate_multiline_body(lines: &[&str], i: usize) -> usize {
    if i >= lines.len() || lines[i].trim().is_empty() || lines[i].trim().starts_with('[') {
        return i;
    }

    let mut j = i;
    while j < lines.len() {
        let trimmed = lines[j].trim();
        if j > i && trimmed.starts_with('[') && !trimmed.starts_with("# [") {
            return i;
        }
        if j > i && looks_like_toml_key_line(trimmed) {
            return i;
        }
        if closes_toml_multiline_value(trimmed) {
            return j + 1;
        }
        j += 1;
    }
    i
}

fn looks_like_toml_key_line(trimmed: &str) -> bool {
    let Some((key, _)) = trimmed.split_once('=') else {
        return false;
    };
    let key = key.trim();
    !key.is_empty()
        && key
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == '"')
}

fn migrate_agent_colors_to_frontmatter(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut out = Vec::with_capacity(lines.len());
    let mut colors: Vec<(String, String)> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if !string_content[i] && trimmed == "[agent-colors]" {
            i += 1;
            while i < lines.len() {
                let next = lines[i].trim();
                if is_section_header_line(next, string_content[i]) {
                    break;
                }
                if let Some((name, raw_value)) = next.split_once('=') {
                    let value = raw_value.trim().trim_matches('"').trim().to_string();
                    if !name.trim().is_empty() && !value.is_empty() {
                        colors.push((name.trim().to_string(), value));
                    }
                }
                i += 1;
            }
            continue;
        }
        out.push(lines[i].to_string());
        i += 1;
    }

    let mut rendered = out.join("\n");
    if content.ends_with('\n') && !rendered.ends_with('\n') {
        rendered.push('\n');
    }

    for (agent, color) in colors {
        if !agent_frontmatter_has_field(&rendered, &agent, "color") {
            rendered = upsert_agent_frontmatter_field(&rendered, &agent, "color", &color);
        }
    }
    rendered
}

fn agent_frontmatter_has_field(content: &str, agent: &str, field: &str) -> bool {
    let string_content = toml_multiline_string_content_lines(content);
    let mut in_section = false;
    let key_prefix = format!("{} =", agent);
    let key_prefix_tight = format!("{}=", agent);
    for (line, inside_string) in content.lines().zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            in_section = trimmed == "[agent-frontmatter]";
            continue;
        }
        if in_section
            && !inside_string
            && (trimmed.starts_with(&key_prefix) || trimmed.starts_with(&key_prefix_tight))
        {
            let existing_value = trimmed.split_once('=').map(|(_, v)| v).unwrap_or("{}");
            return parse_inline_table_fields(existing_value)
                .iter()
                .any(|(key, value)| key == field && !value.trim_matches('"').trim().is_empty());
        }
    }
    false
}

fn agent_frontmatter_scaffold() -> String {
    agent_frontmatter_heading()
}

fn agent_frontmatter_heading() -> String {
    let mut out = String::new();
    out.push_str("# ── Agent Frontmatter ────────────────────────────────\n");
    out.push_str("# vstack writes active defaults here for every installed agent.\n");
    out.push_str("# Edit fields, then run `vstack refresh` to regenerate harness files.\n");
    out.push_str("# Harness-specific entries apply only to that harness.\n");
    out.push_str("# Fields: color, model, effort, deny-tools, allowed-subagents,\n");
    out.push_str("# pane, background, isolation, memory, mode, sandbox-mode,\n");
    out.push_str("# model-reasoning-effort, nickname-candidates.\n");
    out.push_str("# Claude background is seeded from Pi pane on first install (pane=true -> false, pane=false -> true), then preserved on refresh.\n");
    out.push_str("# Pi allowed-subagents is the restricted delegation allowlist for delegate_subagent (engineer default ['scout']; set [] to disable).\n");
    out.push_str(
        "# OpenCode maps colors to hex. Effort values are written verbatim per harness.\n",
    );
    out.push_str("#\n");
    out
}

fn ensure_agent_frontmatter_heading(content: &str) -> String {
    let Some(insert_at) = first_agent_frontmatter_section_start(content) else {
        return content.to_string();
    };
    if content.contains("# ── Agent Frontmatter") {
        return content.to_string();
    }
    let mut out = String::new();
    out.push_str(content[..insert_at].trim_end());
    out.push_str("\n\n");
    out.push_str(&agent_frontmatter_heading());
    out.push_str(content[insert_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn sync_agent_frontmatter_heading(content: &str) -> String {
    let Some(section_at) = first_agent_frontmatter_section_start(content) else {
        return content.to_string();
    };
    let Some(heading_at) = content[..section_at].rfind("# ── Agent Frontmatter") else {
        return content.to_string();
    };
    let mut out = String::new();
    out.push_str(content[..heading_at].trim_end());
    out.push_str("\n\n");
    out.push_str(&agent_frontmatter_heading());
    out.push_str(content[section_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn first_agent_frontmatter_section_start(content: &str) -> Option<usize> {
    let string_content = toml_multiline_string_content_lines(content);
    let mut offset = 0usize;
    for (line, inside_string) in content.split_inclusive('\n').zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string)
            && (trimmed == "[agent-frontmatter]" || trimmed.starts_with("[agent-frontmatter."))
        {
            return Some(offset);
        }
        offset += line.len();
    }
    None
}

fn agent_frontmatter_pi_heading() -> String {
    let mut out = String::new();
    out.push_str("# Pi-specific frontmatter values. The Pi /agents popup edits\n");
    out.push_str("# vstack-managed entries in this file, then `vstack refresh` applies them.\n");
    out
}

fn ensure_agent_frontmatter_pi_heading(content: &str) -> String {
    let Some(insert_at) = section_start(content, "[agent-frontmatter.pi]") else {
        return content.to_string();
    };
    if content.contains("# Pi-specific frontmatter values")
        || content.contains("# Pi-specific frontmatter overrides")
        || content.contains("# Pi-specific model/tool/color overrides")
    {
        return content.to_string();
    }
    let mut out = String::new();
    out.push_str(content[..insert_at].trim_end());
    out.push_str("\n\n");
    out.push_str(&agent_frontmatter_pi_heading());
    out.push_str(content[insert_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn sync_agent_frontmatter_pi_heading(content: &str) -> String {
    let Some(section_at) = section_start(content, "[agent-frontmatter.pi]") else {
        return content.to_string();
    };
    let Some(heading_at) = content[..section_at]
        .rfind("# Pi-specific frontmatter values")
        .or_else(|| content[..section_at].rfind("# Pi-specific frontmatter overrides"))
        .or_else(|| content[..section_at].rfind("# Pi-specific model/tool/color overrides"))
    else {
        return content.to_string();
    };
    let mut out = String::new();
    out.push_str(content[..heading_at].trim_end());
    out.push_str("\n\n");
    out.push_str(&agent_frontmatter_pi_heading());
    out.push_str(content[section_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn section_start(content: &str, section_header: &str) -> Option<usize> {
    let string_content = toml_multiline_string_content_lines(content);
    let mut offset = 0usize;
    for (line, inside_string) in content.split_inclusive('\n').zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) && trimmed == section_header {
            return Some(offset);
        }
        offset += line.len();
    }
    None
}

fn section_end(content: &str, section_header: &str) -> Option<usize> {
    let string_content = toml_multiline_string_content_lines(content);
    let mut offset = 0usize;
    let mut in_section = false;
    for (line, inside_string) in content.split_inclusive('\n').zip(string_content) {
        let trimmed = line.trim();
        if is_section_header_line(trimmed, inside_string) {
            if in_section {
                return Some(offset);
            }
            in_section = trimmed == section_header;
        }
        offset += line.len();
    }
    if in_section {
        Some(content.len())
    } else {
        None
    }
}

fn ensure_agent_frontmatter_scaffold(content: &str) -> String {
    let normalized = ensure_agent_frontmatter_heading(content);
    let normalized = sync_agent_frontmatter_heading(&normalized);
    let normalized = ensure_agent_frontmatter_pi_heading(&normalized);
    let normalized = sync_agent_frontmatter_pi_heading(&normalized);
    let normalized = collapse_duplicate_agent_frontmatter_pi_headings(&normalized);
    let content = normalized.as_str();
    if first_agent_frontmatter_section_start(content).is_some()
        || content.contains("# ── Agent Frontmatter")
    {
        return content.to_string();
    }
    let block = agent_frontmatter_scaffold();
    // Anchor only on structural headers: a `\n[agent-frontmatter.pi]` substring
    // match could sit inside a multi-line string value (vstack#1006).
    let insert_at = section_start(content, "[agent-frontmatter.pi]")
        .or_else(|| content.find("\n# ── Optional Skills"))
        .or_else(|| content.find("\n# ── Custom Hooks"))
        .unwrap_or(content.len());
    let mut out = String::new();
    out.push_str(content[..insert_at].trim_end());
    out.push('\n');
    out.push_str(&block);
    out.push('\n');
    out.push_str(content[insert_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn collapse_duplicate_agent_frontmatter_pi_headings(content: &str) -> String {
    let Some(section_at) = section_start(content, "[agent-frontmatter.pi]") else {
        return content.to_string();
    };
    let heading = agent_frontmatter_pi_heading();
    let prefix = &content[..section_at];
    if prefix.matches(&heading).count() <= 1 {
        return content.to_string();
    }
    let mut out = String::new();
    out.push_str(prefix.replace(&heading, "").trim_end());
    out.push_str("\n\n");
    out.push_str(&heading);
    out.push_str(content[section_at..].trim_start_matches('\n'));
    if content.ends_with('\n') && !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// Migrate old TOML section names to new ones (one-time, idempotent).
fn migrate_section_names(path: &Path) {
    let Ok(content) = std::fs::read_to_string(path) else {
        return;
    };
    let mut out = content.clone();
    let migrations = [
        ("[agent-guidance]", "[agent-launch-instructions]"),
        ("[agent-instructions]", "[agent-additional-instructions]"),
    ];
    let mut changed = false;
    for (old, new) in &migrations {
        // Only rename if the old name exists and the new name does NOT
        if out.contains(old) && !out.contains(new) {
            // Rename headers and comments, but never prose inside a string
            // value — multi-line or single-line (vstack#1006). Splice per
            // physical line so the file keeps its own separators (CRLF
            // stays CRLF).
            let string_content = toml_multiline_string_content_lines(&out);
            let mut rendered = String::with_capacity(out.len());
            for (segment, inside_string) in out.split_inclusive('\n').zip(string_content) {
                if inside_string {
                    rendered.push_str(segment);
                } else if segment.trim_start().starts_with('#') {
                    rendered.push_str(&segment.replace(old, new));
                } else {
                    rendered.push_str(&replace_outside_inline_strings(segment, old, new));
                }
            }
            if rendered != out {
                out = rendered;
                changed = true;
            }
        }
    }
    if changed {
        let _ = std::fs::write(path, out);
    }
}

fn create_project_config(path: &Path, agents: &[String], skills: &[String]) {
    let mut out = String::new();

    out.push_str(&project_config_header());
    out.push_str("\n\n\n");

    // ── agent-launch-instructions ──
    out.push_str(&launch_instructions_heading());
    out.push_str("[agent-launch-instructions]\n\n");
    for (i, name) in agents.iter().enumerate() {
        out.push_str(&format!("{} = \"\"\n", name));
        if i + 1 < agents.len() {
            out.push('\n');
        }
    }

    // ── agent-additional-instructions ──
    out.push_str("\n\n# ── Additional Instructions ──────────────────────────\n");
    out.push_str("# Adds a \"## Additional Instructions\" section at the\n");
    out.push_str("# bottom of each agent file. Project-specific rules,\n");
    out.push_str("# conventions, or reminders for this agent. The reserved\n");
    out.push_str("# key `all` applies to every agent, rendered before that\n");
    out.push_str("# agent's own entry.\n");
    out.push_str("#\n");
    out.push_str("[agent-additional-instructions]\n\n");
    for (i, name) in agents.iter().enumerate() {
        out.push_str(&format!("{} = \"\"\n", name));
        if i + 1 < agents.len() {
            out.push('\n');
        }
    }

    // ── skill-instructions ──
    out.push_str("\n\n# ── Skill Instructions ────────────────────────────────\n");
    out.push_str("# Adds a \"## Project Instructions\" section at the\n");
    out.push_str("# top of each skill's SKILL.md. Project-specific\n");
    out.push_str("# context for how this skill applies to your codebase.\n");
    out.push_str("# Won't overwrite the skill author's own instructions.\n");
    out.push_str("# The reserved key `all` applies to every skill,\n");
    out.push_str("# rendered before that skill's own entry.\n");
    out.push_str("#\n");
    out.push_str("[skill-instructions]\n\n");
    for (i, name) in skills.iter().enumerate() {
        out.push_str(&format!("{} = \"\"\n", name));
        if i + 1 < skills.len() {
            out.push('\n');
        }
    }

    // ── agent-skills ──
    out.push_str("\n\n# ── Agent Skills ─────────────────────────────────────\n");
    out.push_str("# Skills attached to each agent's frontmatter.\n");
    out.push_str("# This is the single source of truth — add or remove\n");
    out.push_str("# skills here and run `vstack refresh` to apply.\n");
    out.push_str("#\n");
    out.push_str("# Populated automatically at install time from source\n");
    out.push_str("# mappings. You can freely add your own skills to any\n");
    out.push_str("# agent's list (they don't need to be in the vstack\n");
    out.push_str("# repo — local skill directories work too).\n");
    out.push_str("#\n");
    out.push_str("[agent-skills]\n");
    // Actual skill lists are written by write_agent_skills() after
    // the mapping is computed, so we just emit the section header here.

    out.push('\n');
    out.push_str(&agent_frontmatter_scaffold());

    // ── custom-hooks ──
    out.push_str("\n\n# ── Custom Hooks ─────────────────────────────────────\n");
    out.push_str("# Project-local hooks not from the vstack source repo.\n");
    out.push_str("# Each hook needs: event, command, and optional matcher.\n");
    out.push_str("#\n");
    out.push_str("# [[custom-hooks]]\n");
    out.push_str(
        "# event = \"PreToolUse\"      # PreToolUse | PostToolUse | PostCompact | TaskCompleted | Stop | SessionStart | UserPromptSubmit | PermissionRequest\n",
    );
    out.push_str("# matcher = \"Bash\"           # optional: Bash | Edit|Write | (omit for all)\n");
    out.push_str("# command = \"./scripts/my-hook.sh\"\n");
    out.push_str("# description = \"What this hook does\"     # inlined as instructions in non-Claude-Code harnesses\n");
    out.push_str("# agents = \"all\"             # \"all\", a role (\"engineer\"), or a list [\"rust\", \"iced\"]\n");

    let _ = std::fs::write(path, out);
}

fn update_project_config(path: &Path, agents: &[String], skills: &[String]) {
    let Ok(existing) = std::fs::read_to_string(path) else {
        return;
    };

    // Find agents not already mentioned as a TOML key (commented or active).
    let new_agents: Vec<&String> = agents
        .iter()
        .filter(|name| is_new_key(&existing, name))
        .collect();

    // Find skills not already mentioned
    let new_skills: Vec<&String> = skills
        .iter()
        .filter(|name| is_new_key(&existing, name))
        .collect();

    // Strip any legacy installed-skills reference block left by older vstack
    // versions so existing project configs lose the bloat on next write.
    let content = strip_skills_reference(&existing);
    let mut out = content.trim_end().to_string();
    out.push('\n');

    let mut all_new_keys: Vec<(&str, Vec<&String>)> = Vec::new();
    if !new_agents.is_empty() {
        all_new_keys.push(("[agent-launch-instructions]", new_agents.clone()));
        all_new_keys.push(("[agent-additional-instructions]", new_agents));
    }
    if !new_skills.is_empty() {
        all_new_keys.push(("[skill-instructions]", new_skills));
    }

    for (section, keys) in all_new_keys {
        out = insert_keys_into_section(&out, section, &keys);
    }

    out = ensure_value_section_entry_spacing(&out);
    out = ensure_agent_frontmatter_scaffold(&out);

    // Only write if content actually changed to avoid bumping mtime,
    // which would make staleness checks flag everything as outdated.
    if !same_ignoring_trailing_newline(&out, &existing) {
        let _ = std::fs::write(path, out);
    }
}

/// True when the two contents differ at most by the presence of a single
/// trailing newline. Refresh writers must skip the write in that case:
/// consumers commit `vstack.toml` without a final newline, and a write whose
/// only effect is normalizing that newline dirties their working tree on
/// every refresh (vstack#987). A real content change still writes — and may
/// normalize the newline along the way.
fn same_ignoring_trailing_newline(a: &str, b: &str) -> bool {
    a.strip_suffix('\n').unwrap_or(a) == b.strip_suffix('\n').unwrap_or(b)
}

/// Returns true if a name does NOT appear as a TOML key in the file.
fn is_new_key(content: &str, name: &str) -> bool {
    let patterns = [
        format!("{} =", name),
        format!("{}=", name),
        format!("# {} =", name),
        format!("# {}=", name),
    ];
    !patterns.iter().any(|p| content.contains(p))
}

/// Insert new keys into a specific TOML section, preserving all other content.
fn insert_keys_into_section(content: &str, section_header: &str, new_keys: &[&String]) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut result: Vec<String> = Vec::new();
    let mut i = 0;
    let mut found = false;

    while i < lines.len() {
        let trimmed = lines[i].trim();
        result.push(lines[i].to_string());

        if !string_content[i] && trimmed == section_header {
            found = true;
            // Scan forward past existing keys in this section
            i += 1;
            while i < lines.len() {
                // String content is never a section boundary, a key, or a
                // comment — carry it through verbatim (vstack#1006).
                if string_content[i] {
                    result.push(lines[i].to_string());
                    i += 1;
                    continue;
                }
                let next = lines[i].trim();
                let is_key_line = next.contains(" = ") || next.contains("= ");
                let is_comment = next.starts_with('#');

                if next.starts_with('[') && !next.starts_with("# [") {
                    break;
                }
                if next.is_empty() || (is_comment && next.starts_with("# ──")) {
                    break;
                }

                result.push(lines[i].to_string());

                if !is_key_line && !is_comment {
                    i += 1;
                    break;
                }
                i += 1;
            }

            if !new_keys.is_empty() {
                // Blank line before new entries if section already had content
                if result
                    .last()
                    .is_some_and(|l| !l.trim().is_empty() && l.trim() != section_header)
                {
                    result.push(String::new());
                }
                for name in new_keys {
                    result.push(format!("{} = \"\"", name));
                }
            }
            continue;
        }

        i += 1;
    }

    // If the section didn't exist, create it at the end
    if !found {
        result.push(String::new());
        result.push(section_header.to_string());
        for name in new_keys {
            result.push(format!("{} = \"\"", name));
        }
    }

    result.join("\n")
}

/// Insert raw TOML text after existing keys in a `[section]`, preserving all
/// comments and surrounding content.  If the section doesn't exist, appends it.
fn insert_entries_into_section(content: &str, section_header: &str, entries: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let string_content = toml_multiline_string_content_lines(content);
    let mut result: Vec<String> = Vec::new();
    let mut i = 0;
    let mut inserted = false;

    while i < lines.len() {
        let trimmed = lines[i].trim();
        result.push(lines[i].to_string());

        if !string_content[i] && trimmed == section_header {
            // Scan to the end of this logical section, preserving spaced entries.
            i += 1;
            while i < lines.len() {
                let next = lines[i].trim();
                // Stop at next section header or section-separator comment,
                // but never inside a multi-line string value (vstack#1006).
                if !string_content[i] {
                    if next.starts_with('[') && !next.starts_with("# [") {
                        break;
                    }
                    if next.starts_with("# ──") {
                        break;
                    }
                }
                result.push(lines[i].to_string());
                i += 1;
            }
            // Insert new entries here, right after existing keys
            if result.last().is_some_and(|line| !line.trim().is_empty()) {
                result.push(String::new());
            }
            for line in entries.lines() {
                result.push(line.to_string());
            }
            inserted = true;
            continue;
        }

        i += 1;
    }

    if !inserted {
        result.push(String::new());
        result.push(section_header.to_string());
        for line in entries.lines() {
            result.push(line.to_string());
        }
    }

    result.join("\n")
}

fn strip_skills_reference(content: &str) -> String {
    // The reference block is always pure comments: a `# ── Installed skills...`
    // header followed by `#   <name>` lines. Strip the contiguous comment run
    // (and any trailing blank lines that belonged to it) starting at the
    // header. Anything after that run — including TOML the user added below —
    // is preserved verbatim.
    let markers = [
        "# ── Installed skills (reference)",
        "# Installed skills (for reference",
    ];

    for marker in markers {
        let Some(header_byte) = content.find(marker) else {
            continue;
        };

        // Anchor strip start at the start of the header line, including any
        // blank lines that immediately precede it (those typically belong to
        // the section gap our writer emits).
        let mut start = header_byte;
        let prefix = &content[..start];
        let trimmed_prefix = prefix.trim_end_matches([' ', '\t']);
        let consumed = prefix.len() - trimmed_prefix.len();
        start = start.saturating_sub(consumed);
        // Pull in the leading newlines too (one per `\n`).
        while start > 0 && content.as_bytes()[start - 1] == b'\n' {
            start -= 1;
        }

        // Walk forward consuming the contiguous comment block.
        let mut cursor = header_byte;
        loop {
            let line_end = content[cursor..]
                .find('\n')
                .map(|i| cursor + i + 1)
                .unwrap_or(content.len());
            let line = &content[cursor..line_end];
            let trimmed = line.trim_start();
            if trimmed.starts_with('#') || line.trim().is_empty() {
                cursor = line_end;
                if cursor >= content.len() {
                    break;
                }
            } else {
                break;
            }
        }

        let mut out = String::with_capacity(content.len());
        out.push_str(&content[..start]);
        if !out.is_empty() && !out.ends_with('\n') && cursor < content.len() {
            out.push('\n');
        }
        out.push_str(&content[cursor..]);
        return out;
    }
    content.to_string()
}

#[cfg(test)]
mod tests {
    // ── vstack#896: the banner sync must not eat the preamble ──────────────
    //
    // `sync_project_config_header` used to splice
    // `header + content[launch_instructions_marker..]`, deleting everything
    // between. TOML requires top-level keys to precede the first table header,
    // so `project-skills-dir` lives exactly in that region — it was destroyed on
    // the first refresh that rewrote the file, which then made refresh refuse
    // that project's own skills and exit non-zero forever after.

    fn header_sync_fixture(body: &str) -> String {
        format!(
            "{}\n\n\n{}",
            super::project_config_header().trim_end(),
            body
        )
    }

    const LAUNCH_BODY: &str = "# ── Launch Instructions ───────────────────────────────\n#\n[agent-launch-instructions]\nresearcher = \"x\"\n";

    #[test]
    fn sync_header_preserves_a_top_level_key_before_the_first_table() {
        let content = header_sync_fixture(&format!(
            "# ── Project-Owned Skills ──\n# why this key exists\nproject-skills-dir = \"project-skills\"\n\n\n{LAUNCH_BODY}"
        ));
        let out = super::sync_project_config_header(&content);
        assert!(
            out.contains("project-skills-dir = \"project-skills\""),
            "the key must survive a header sync:\n{out}"
        );
        assert!(
            out.contains("# why this key exists"),
            "its explanatory comment must survive too:\n{out}"
        );
        assert!(out.contains("[agent-launch-instructions]"));
    }

    #[test]
    fn sync_header_is_idempotent_with_a_top_level_key_present() {
        let content = header_sync_fixture(&format!(
            "project-skills-dir = \"project-skills\"\n\n\n{LAUNCH_BODY}"
        ));
        let once = super::sync_project_config_header(&content);
        let twice = super::sync_project_config_header(&once);
        assert_eq!(once, twice, "a second sync must change nothing");
        assert_eq!(
            content, once,
            "a file already in canonical shape must be left byte-identical"
        );
    }

    #[test]
    fn sync_header_still_replaces_a_stale_banner() {
        // The sync must keep doing its job: an outdated banner is refreshed,
        // and only the banner is refreshed.
        let content = format!(
            "# ─ old banner line\n# another stale line\n\n\nproject-skills-dir = \"p\"\n\n\n{LAUNCH_BODY}"
        );
        let out = super::sync_project_config_header(&content);
        assert!(out.starts_with(super::project_config_header().trim_end()));
        assert!(!out.contains("old banner line"), "stale banner must go:\n{out}");
        assert!(
            out.contains("project-skills-dir = \"p\""),
            "user content after the banner must stay:\n{out}"
        );
    }

    #[test]
    fn repair_project_config_content_preserves_header_when_flagged() {
        // VST-40: vstack-local.toml's header is hand-authored and never
        // generated by this CLI. Even a banner that looks stale by the
        // ordinary vstack.toml rules must survive when preserve_header=true.
        let content = format!(
            "# ─────────────────────────\n# vstack-local.toml — vstack's OWN agent customization\n# hand-written, not generated\n# ─────────────────────────\n\n\nproject-skills-dir = \"p\"\n\n\n{LAUNCH_BODY}"
        );
        let out = super::repair_project_config_content(&content, true);
        assert!(
            out.contains("vstack-local.toml — vstack's OWN agent customization"),
            "hand-authored header must survive when preserve_header is set:\n{out}"
        );
        assert!(
            !out.contains("vstack.toml — project-level agent customization"),
            "the generic template header must not be stamped in:\n{out}"
        );
    }

    #[test]
    fn repair_project_config_structure_preserves_vstack_local_toml_header_by_filename() {
        // Integration-level check that the filename alone routes the
        // preserve/rewrite decision, matching project_config_path()'s
        // vstack.toml vs vstack-local.toml split (VST-40).
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_repair_header_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let hand_header = "# ─────────────────────────\n# vstack-local.toml — vstack's OWN agent customization\n# hand-written, not generated\n# ─────────────────────────\n";
        let body = format!("\n\nproject-skills-dir = \"p\"\n\n\n{LAUNCH_BODY}");

        let local_path = dir.join("vstack-local.toml");
        std::fs::write(&local_path, format!("{hand_header}{body}")).unwrap();
        super::repair_project_config_structure(&local_path);
        let local_after = std::fs::read_to_string(&local_path).unwrap();
        assert!(
            local_after.contains("vstack-local.toml — vstack's OWN agent customization"),
            "refresh must not rewrite vstack-local.toml's hand-maintained header:\n{local_after}"
        );

        let normal_path = dir.join("vstack.toml");
        std::fs::write(
            &normal_path,
            format!("# ─ old banner line\n# another stale line\n{body}"),
        )
        .unwrap();
        super::repair_project_config_structure(&normal_path);
        let normal_after = std::fs::read_to_string(&normal_path).unwrap();
        assert!(
            normal_after.contains("vstack.toml — project-level agent customization"),
            "an ordinary vstack.toml's stale banner must still refresh:\n{normal_after}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sync_header_leaves_a_non_vstack_file_alone() {
        // No leading `# ─` banner: not ours to rewrite.
        let content = format!("# some other file\n\nproject-skills-dir = \"p\"\n\n{LAUNCH_BODY}");
        assert_eq!(super::sync_project_config_header(&content), content);
        // Banner but no recognizable body: also untouched.
        let no_body = format!("{}\n\n\nkey = 1\n", super::project_config_header().trim_end());
        assert_eq!(super::sync_project_config_header(&no_body), no_body);
    }

    #[test]
    fn leading_comment_block_end_stops_at_the_first_non_comment_line() {
        let content = "# a\n# b\n\nkey = 1\n";
        let end = super::leading_comment_block_end(content);
        assert_eq!(&content[end..], "\nkey = 1\n");
        // An all-comment file consumes everything rather than running past the end.
        let all = "# a\n# b\n";
        assert_eq!(super::leading_comment_block_end(all), all.len());
    }

    use super::*;

    #[test]
    fn shared_instruction_key_parses_in_all_three_tables() {
        let toml = r#"
[agent-launch-instructions]
all = "Run just setup first."
rust = "Read docs/architecture.md."

[agent-additional-instructions]
all = "Fleet-wide rule."

[skill-instructions]
all = "Shared skill rule."
trading-design = "Dark theme."
"#;
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        assert_eq!(config.shared_guidance(), Some("Run just setup first."));
        assert_eq!(config.shared_instructions(), Some("Fleet-wide rule."));
        // Per-agent accessors stay item-specific.
        assert_eq!(
            config.guidance_for("rust"),
            Some("Read docs/architecture.md.")
        );
        assert_eq!(config.guidance_for("iced"), None);
        // Skill lookup merges shared-first with the skill's own entry.
        assert_eq!(
            config.skill_instructions_for("trading-design").as_deref(),
            Some("Shared skill rule.\n\nDark theme.")
        );
        // Skills without their own entry still get the shared value.
        assert_eq!(
            config.skill_instructions_for("github").as_deref(),
            Some("Shared skill rule.")
        );
    }

    #[test]
    fn shared_instruction_key_accepts_star_alias() {
        let toml = "[agent-launch-instructions]\n\"*\" = \"Star rule.\"\n";
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        assert_eq!(config.shared_guidance(), Some("Star rule."));
        // `all` wins over the alias when both are present.
        let toml = "[agent-launch-instructions]\nall = \"All rule.\"\n\"*\" = \"Star rule.\"\n";
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        assert_eq!(config.shared_guidance(), Some("All rule."));
    }

    #[test]
    fn merge_shared_and_specific_orders_shared_first() {
        assert_eq!(
            ProjectConfig::merge_shared_and_specific(Some("shared"), Some("specific")).as_deref(),
            Some("shared\n\nspecific")
        );
        assert_eq!(
            ProjectConfig::merge_shared_and_specific(Some("shared"), None).as_deref(),
            Some("shared")
        );
        assert_eq!(
            ProjectConfig::merge_shared_and_specific(None, Some("specific")).as_deref(),
            Some("specific")
        );
        assert_eq!(ProjectConfig::merge_shared_and_specific(None, None), None);
    }

    #[test]
    fn strip_shared_prefix_removes_merged_render_remainder() {
        // Extracted text that IS the shared value: nothing agent-specific.
        assert_eq!(
            ProjectConfig::strip_shared_prefix(Some("shared"), "shared"),
            None
        );
        // Merged render round-trips back to the specific remainder.
        assert_eq!(
            ProjectConfig::strip_shared_prefix(Some("shared"), "shared\n\nmine"),
            Some("mine")
        );
        // Unrelated text passes through untouched.
        assert_eq!(
            ProjectConfig::strip_shared_prefix(Some("shared"), "custom"),
            Some("custom")
        );
        // No shared value configured: extraction is untouched.
        assert_eq!(
            ProjectConfig::strip_shared_prefix(None, "anything"),
            Some("anything")
        );
    }

    #[test]
    fn save_extracted_never_persists_shared_text_as_per_agent_entry() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_shared_save_extracted_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("vstack.toml"),
            "[agent-launch-instructions]\nall = \"shared\"\n",
        )
        .unwrap();
        let mut config = ProjectConfig::load(&dir);

        // Re-extraction of a shared-only render must not create a per-agent key.
        let extracted = crate::agent::AgentExtras {
            guidance: Some("shared".into()),
            ..Default::default()
        };
        config.save_extracted(&dir, "rust", &extracted);
        assert_eq!(config.guidance_for("rust"), None);

        // Re-extraction of a merged render persists only the specific remainder.
        let extracted = crate::agent::AgentExtras {
            guidance: Some("shared\n\nmine".into()),
            ..Default::default()
        };
        config.save_extracted(&dir, "rust", &extracted);
        assert_eq!(config.guidance_for("rust"), Some("mine"));
        let on_disk = std::fs::read_to_string(dir.join("vstack.toml")).unwrap();
        assert!(on_disk.contains("rust = \"mine\""), "on disk: {on_disk}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // vstack: regression. `normalize_attached_section_headers` used to
    // split any line containing a known section header substring, including
    // pure-comment lines that merely mentioned a header as prose. When the
    // bootstrap encountered a comment like:
    //
    //   # writes those changes into `[agent-frontmatter.pi]` automatically.
    //
    // it sliced the line at the header, emitted the header as a TOML table
    // header on its own line, and left the suffix `\` automatically.` as an
    // orphaned line starting at column 1 — invalid TOML. Subsequent
    // `MappingConfig::load` then silently fell back to default, every
    // `[agent-skills]` entry disappeared, and generated agents lost all
    // `skills:` frontmatter. Comment lines must be preserved verbatim.
    #[test]
    fn normalize_attached_section_headers_leaves_comment_lines_alone() {
        let input = "# writes those changes into `[agent-frontmatter.pi]` automatically.\n";
        let out = normalize_attached_section_headers(input);
        assert_eq!(out, input);
        assert!(!out.contains("\n[agent-frontmatter.pi]\n"));
        assert!(!out.contains("\n` automatically."));
    }

    #[test]
    fn normalize_attached_section_headers_still_splits_non_comment_attached_headers() {
        // Non-comment line with a header attached after content: real bootstrap
        // case where two TOML tables ended up on the same line. Must still split.
        let input = "foo = 1[agent-frontmatter.pi]\nbar = \"x\"\n";
        let out = normalize_attached_section_headers(input);
        assert!(out.contains("foo = 1\n[agent-frontmatter.pi]\n"));
    }

    #[test]
    fn project_config_load_survives_comment_with_inline_header_after_bootstrap_repair() {
        // End-to-end shape: a vstack.toml whose comment block mentions a
        // header inline; after `repair_project_config_structure` runs (which
        // calls `normalize_attached_section_headers`), the file must still
        // parse as valid TOML and `[agent-skills]` entries must survive.
        let dir =
            std::env::temp_dir().join(format!("vstack_norm_comment_header_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        let content = concat!(
            "# Pi `/agents` writes changes into `[agent-frontmatter.pi]` automatically.\n",
            "\n",
            "[agent-skills]\n",
            "reviewer-error = [\"reviewer\"]\n",
            "\n",
            "[agent-frontmatter.pi]\n",
            "reviewer-error = { model = \"openai-codex/gpt-5.6-sol:xhigh\" }\n",
        );
        std::fs::write(&path, content).unwrap();
        repair_project_config_structure(&path);
        let read_back = std::fs::read_to_string(&path).unwrap();
        let parsed: ProjectConfig =
            toml::from_str(&read_back).expect("vstack.toml must remain valid TOML after repair");
        assert_eq!(
            parsed.agent_skills_for("reviewer-error"),
            Some(&vec!["reviewer".to_string()])
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn project_config_parses_all_sections() {
        let toml = r#"
[agent-skills]
rust = ["rust-tooling", "rust-runtime", "my-custom-skill"]

[agent-colors]
rust = "green"
generalist = ""

[agent-launch-instructions]
rust = "Use when working on backend Rust services."

[agent-additional-instructions]
rust = "Always run clippy before committing."
"#;
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        let skills = config.agent_skills_for("rust").unwrap();
        assert_eq!(skills.len(), 3);
        assert_eq!(skills[0], "rust-tooling");
        assert_eq!(skills[2], "my-custom-skill");

        assert_eq!(config.color_for("rust"), Some("green"));
        assert_eq!(config.color_for("generalist"), None);

        assert_eq!(
            config.guidance_for("rust"),
            Some("Use when working on backend Rust services.")
        );
        assert_eq!(
            config.instructions_for("rust"),
            Some("Always run clippy before committing.")
        );

        // Unknown agent returns None
        assert!(config.agent_skills_for("unknown").is_none());
        assert!(config.color_for("unknown").is_none());
        assert!(config.guidance_for("unknown").is_none());
        assert!(config.instructions_for("unknown").is_none());
    }

    #[test]
    fn project_config_missing_file_returns_default() {
        let config = ProjectConfig::load(std::path::Path::new("/nonexistent/path"));
        assert!(config.agent_skills.is_empty());
        assert!(config.agent_colors.is_empty());
        assert!(config.agent_guidance.is_empty());
        assert!(config.agent_instructions.is_empty());
    }

    #[test]
    fn project_config_parses_frontmatter_overrides() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("vstack.toml"),
            r#"
[agent-frontmatter]
researcher = { color = "purple", model = "generic-model", effort = "high", background = false, isolation = "none", memory = "project" }

[agent-frontmatter.pi]
researcher = { model = "openai-codex/gpt-5.6-sol:xhigh", deny-tools = "bash, question" }

[agent-frontmatter.codex]
researcher = { nickname-candidates = "Researcher-One, Researcher-Two" }

[agent-frontmatter.claude]
researcher = { model = "opus[1m]", effort = "xhigh", background = true, isolation = "worktree" }
"#,
        )
        .unwrap();

        let config = ProjectConfig::load(&dir);
        let shared = config.frontmatter_for("researcher", "");
        assert_eq!(shared.color.as_deref(), Some("purple"));
        assert_eq!(shared.model.as_deref(), Some("generic-model"));
        let pi = config.frontmatter_for("researcher", "pi");
        assert_eq!(pi.color.as_deref(), None);
        assert_eq!(pi.model.as_deref(), Some("openai-codex/gpt-5.6-sol:xhigh"));
        assert_eq!(pi.deny_tools, Some(vec!["bash".into(), "question".into()]));
        let codex = config.frontmatter_for("researcher", "codex");
        assert_eq!(
            codex.nickname_candidates,
            Some(vec!["Researcher-One".into(), "Researcher-Two".into()])
        );
        let claude = config.frontmatter_for("researcher", "claude-code");
        assert_eq!(claude.model.as_deref(), Some("opus[1m]"));
        assert_eq!(claude.effort.as_deref(), Some("xhigh"));
        assert_eq!(claude.background, Some(true));
        assert_eq!(claude.isolation.as_deref(), Some("worktree"));
        assert_eq!(claude.memory.as_deref(), None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_preserves_existing_claude_background() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pane_background_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        // Scout: Pi pane=false would derive background=true, but user set
        // background=false explicitly. Planner: pane=true would derive
        // background=false, but user set background=true explicitly. Both
        // user edits must survive refresh.
        std::fs::write(
            &path,
            r#"
[agent-frontmatter.pi]
scout = { pane = false }
planner = { pane = true }

[agent-frontmatter.claude]
scout = { background = false }
planner = { background = true }
"#,
        )
        .unwrap();

        let scout = crate::agent::Agent {
            name: "scout".into(),
            description: "Scout agent".into(),
            model: "haiku".into(),
            role: crate::agent::AgentRole::Analyst,
            color: None,
            effort: Some("medium".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let planner = crate::agent::Agent {
            name: "planner".into(),
            description: "Planner agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Analyst,
            color: None,
            effort: Some("max".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert(
            "scout".into(),
            vec![
                crate::harness::Harness::ClaudeCode,
                crate::harness::Harness::Pi,
            ],
        );
        harnesses.insert(
            "planner".into(),
            vec![
                crate::harness::Harness::ClaudeCode,
                crate::harness::Harness::Pi,
            ],
        );

        write_agent_frontmatter_defaults(
            &dir,
            &[scout, planner],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let scout_line = updated
            .lines()
            .find(|line| line.starts_with("scout =") && line.contains("background"))
            .expect("scout claude line");
        assert!(
            scout_line.contains("background = false"),
            "scout background should stay false: {scout_line}"
        );
        let planner_line = updated
            .lines()
            .find(|line| line.starts_with("planner =") && line.contains("background"))
            .expect("planner claude line");
        assert!(
            planner_line.contains("background = true"),
            "planner background should stay true: {planner_line}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_pi_engineer_seeds_allowed_subagents_scout() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pi_allowed_engineer_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-frontmatter.pi]\n").unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("rust".into(), vec![crate::harness::Harness::Pi]);

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let rust_line = updated
            .lines()
            .find(|line| line.starts_with("rust =") && line.contains("allowed-subagents"))
            .expect("rust pi frontmatter line missing allowed-subagents");
        assert!(
            rust_line.contains("allowed-subagents = [\"scout\"]"),
            "{rust_line}"
        );
        assert!(rust_line.contains("model = \"inherit\""), "{rust_line}");
        assert!(
            !rust_line.contains("delegate_subagent"),
            "engineer with allowed-subagents must not deny delegate_subagent: {rust_line}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_pi_engineer_explicit_empty_disables_default() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pi_allowed_empty_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        // User explicitly opts out by setting allowed-subagents = [].
        std::fs::write(
            &path,
            "[agent-frontmatter.pi]\nrust = { allowed-subagents = [] }\n",
        )
        .unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("rust".into(), vec![crate::harness::Harness::Pi]);

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let rust_line = updated
            .lines()
            .find(|line| line.starts_with("rust =") && line.contains("allowed-subagents"))
            .expect("rust pi frontmatter line");
        // User's empty list is preserved.
        assert!(rust_line.contains("allowed-subagents = []"), "{rust_line}");
        // And the seeded deny-tools must include delegate_subagent so the
        // engineer with explicit empty allowlist cannot delegate.
        assert!(
            rust_line.contains("delegate_subagent"),
            "engineer with empty allowed list must deny delegate_subagent: {rust_line}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_pi_analyst_skips_allowed_subagents() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pi_allowed_analyst_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-frontmatter.pi]\n").unwrap();

        let scout = crate::agent::Agent {
            name: "scout".into(),
            description: "Scout agent".into(),
            model: "haiku".into(),
            role: crate::agent::AgentRole::Analyst,
            color: None,
            effort: Some("medium".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("scout".into(), vec![crate::harness::Harness::Pi]);

        write_agent_frontmatter_defaults(
            &dir,
            &[scout],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let scout_line = updated
            .lines()
            .find(|line| line.starts_with("scout ="))
            .expect("scout pi frontmatter line");
        // Analyst gets allowed-subagents = [] (engineer-only default), and
        // delegate_subagent shows up in deny-tools.
        assert!(
            scout_line.contains("allowed-subagents = []"),
            "scout should record empty allowed-subagents: {scout_line}"
        );
        assert!(
            scout_line.contains("model = \"openai-codex/gpt-5.6-sol:medium\""),
            "scout should keep an explicit cheaper Pi model: {scout_line}"
        );
        assert!(
            scout_line.contains("delegate_subagent"),
            "non-engineer must deny delegate_subagent: {scout_line}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn project_config_parses_allowed_subagents_aliases() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_allowed_aliases_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("vstack.toml"),
            r#"
[agent-frontmatter.pi]
rust = { allowed-subagents = ["scout", "researcher"] }
iced = { allowedSubagents = ["scout"] }
generalist = { subagent-agents = ["scout"] }
tpm = { subagent_agents = ["scout"] }
"#,
        )
        .unwrap();

        let config = ProjectConfig::load(&dir);
        let rust_pi = config.frontmatter_for("rust", "pi");
        assert_eq!(
            rust_pi.allowed_subagents.as_deref(),
            Some(&["scout".to_string(), "researcher".to_string()][..])
        );
        let iced_pi = config.frontmatter_for("iced", "pi");
        assert_eq!(
            iced_pi.allowed_subagents.as_deref(),
            Some(&["scout".to_string()][..])
        );
        let generalist_pi = config.frontmatter_for("generalist", "pi");
        assert_eq!(
            generalist_pi.allowed_subagents.as_deref(),
            Some(&["scout".to_string()][..])
        );
        let tpm_pi = config.frontmatter_for("tpm", "pi");
        assert_eq!(
            tpm_pi.allowed_subagents.as_deref(),
            Some(&["scout".to_string()][..])
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_pi_reviewer_denies_tasks_write() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pi_reviewer_deny_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-frontmatter.pi]\n").unwrap();

        let reviewer = crate::agent::Agent {
            name: "reviewer-test".into(),
            description: "Reviewer agent".into(),
            model: "sonnet".into(),
            role: crate::agent::AgentRole::Reviewer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("reviewer-test".into(), vec![crate::harness::Harness::Pi]);

        write_agent_frontmatter_defaults(
            &dir,
            &[reviewer],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let deny_line = updated
            .lines()
            .find(|line| line.starts_with("reviewer-test =") && line.contains("deny-tools"))
            .expect("reviewer pi frontmatter line");
        assert!(deny_line.contains("tasks_write"), "{deny_line}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_preserves_existing_model_overrides() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_model_inherit_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(
            &path,
            r#"
[agent-frontmatter.claude]
rust = { model = "opus[1m]", effort = "xhigh", background = false }

[agent-frontmatter.pi]
rust = { model = "openai-codex/gpt-5.6-sol:xhigh", allowed-subagents = ["scout"], pane = true }
"#,
        )
        .unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert(
            "rust".into(),
            vec![
                crate::harness::Harness::ClaudeCode,
                crate::harness::Harness::Pi,
            ],
        );

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let claude_line = updated
            .lines()
            .find(|line| line.starts_with("rust =") && line.contains("background"))
            .expect("rust claude frontmatter line");
        assert!(
            claude_line.contains("model = \"opus[1m]\""),
            "{claude_line}"
        );
        let pi_line = updated
            .lines()
            .find(|line| line.starts_with("rust =") && line.contains("allowed-subagents"))
            .expect("rust pi frontmatter line");
        assert!(
            pi_line.contains("model = \"openai-codex/gpt-5.6-sol:xhigh\""),
            "{pi_line}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_seeds_claude_background_from_pi_pane_on_first_install() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_pane_seed_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        // No prior [agent-frontmatter.claude] entries — the section is empty,
        // so background is seeded from Pi pane (scout pane=false → bg=true).
        std::fs::write(
            &path,
            r#"
[agent-frontmatter.pi]
scout = { pane = false }

[agent-frontmatter.claude]
"#,
        )
        .unwrap();

        let scout = crate::agent::Agent {
            name: "scout".into(),
            description: "Scout agent".into(),
            model: "haiku".into(),
            role: crate::agent::AgentRole::Analyst,
            color: None,
            effort: Some("medium".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert(
            "scout".into(),
            vec![
                crate::harness::Harness::ClaudeCode,
                crate::harness::Harness::Pi,
            ],
        );

        write_agent_frontmatter_defaults(
            &dir,
            &[scout],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(updated.contains("background = true"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_sets_opencode_subagent_mode_for_engineers() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_opencode_mode_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(
            &path,
            "[agent-frontmatter.opencode]\nrust = { mode = \"all\" }\n",
        )
        .unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("rust".into(), vec![crate::harness::Harness::OpenCode]);

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(updated.contains("rust = { model = \"openai/gpt-5.6-sol\", deny-tools = [\"task\", \"question\"], mode = \"subagent\", model-reasoning-effort = \"xhigh\" }"));

        std::fs::write(
            &path,
            "[agent-frontmatter.opencode]\nrust = { mode = \"primary\" }\n",
        )
        .unwrap();
        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );
        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(updated.contains("rust = { model = \"openai/gpt-5.6-sol\", deny-tools = [], mode = \"primary\", model-reasoning-effort = \"xhigh\" }"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_seeds_codex_nickname_candidates() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_codex_nicknames_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-frontmatter.codex]\n").unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: Some("xhigh".into()),
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert("rust".into(), vec![crate::harness::Harness::Codex]);

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        let rust_line = updated
            .lines()
            .find(|line| line.starts_with("rust =") && line.contains("nickname-candidates"))
            .expect("rust codex frontmatter line missing nickname-candidates");
        assert!(rust_line.contains("nickname-candidates = [\"Rust-Atlas\", \"Rust-Delta\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_frontmatter_defaults_migrates_legacy_agent_colors() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_agent_frontmatter_color_migration_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-colors]\nrust = \"blue\"\n").unwrap();

        let rust = crate::agent::Agent {
            name: "rust".into(),
            description: "Rust agent".into(),
            model: "opus".into(),
            role: crate::agent::AgentRole::Engineer,
            color: Some("orange".into()),
            effort: None,
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        };
        let mut harnesses = HashMap::new();
        harnesses.insert(
            "rust".into(),
            vec![
                crate::harness::Harness::ClaudeCode,
                crate::harness::Harness::OpenCode,
            ],
        );

        write_agent_frontmatter_defaults(
            &dir,
            &[rust],
            &harnesses,
            &crate::mapping::MappingConfig::default(),
        );

        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(!updated.contains("[agent-colors]"));
        assert!(updated.contains("[agent-frontmatter.claude]"));
        assert!(updated.contains("rust = { color = \"blue\""));
        assert!(updated.contains("[agent-frontmatter.opencode]"));
        assert!(updated.contains("color = \"#3b82f6\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_agent_colors_does_not_create_or_change_frontmatter() {
        let dir =
            std::env::temp_dir().join(format!("vstack_test_agent_colors_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(
            &path,
            "[agent-colors]\nrust = \"blue\"\n\n[agent-skills]\nrust = []\n",
        )
        .unwrap();

        let mut colors = HashMap::new();
        colors.insert("rust".to_string(), Some("green".to_string()));
        colors.insert("iced".to_string(), Some("magenta".to_string()));
        write_agent_colors(&dir, &colors);

        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(updated.contains("rust = \"blue\""));
        assert!(!updated.contains("[agent-frontmatter]"));
        assert!(!updated.contains("iced = { color = \"magenta\" }"));

        let config = ProjectConfig::load(&dir);
        assert_eq!(config.color_for("rust"), Some("blue"));
        assert_eq!(config.frontmatter_for("iced", "pi").color.as_deref(), None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn project_config_agent_skills_authoritative() {
        // Project [agent-skills] is the single source of truth
        let toml = r#"
[agent-skills]
iced = ["iced-rs", "trading-design", "my-custom"]

[agent-launch-instructions]
rust = "Use for Rust work."
"#;
        let config: ProjectConfig = toml::from_str(toml).unwrap();
        assert_eq!(config.guidance_for("rust"), Some("Use for Rust work."));
        let iced_skills = config.agent_skills_for("iced").unwrap();
        assert_eq!(iced_skills, &["iced-rs", "trading-design", "my-custom"]);
        // Agent without entry → None (falls back to source mapping)
        assert!(config.agent_skills_for("rust").is_none());
    }

    #[test]
    fn update_project_config_appends_new_agents() {
        let dir =
            std::env::temp_dir().join(format!("vstack_test_update_config_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("vstack.toml");

        // Create initial config with "rust" agent
        create_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        let initial = std::fs::read_to_string(&path).unwrap();
        assert!(initial.contains("rust = \"\""));
        // Legacy installed-skills reference block no longer emitted
        assert!(!initial.contains("Installed skills (reference)"));

        // Update with "rust" + new "iced" agent and new skill
        update_project_config(
            &path,
            &["rust".into(), "iced".into()],
            &["rust-tooling".into(), "trading-design".into()],
        );
        let updated = std::fs::read_to_string(&path).unwrap();

        // Original rust placeholders preserved
        assert!(updated.contains("rust = \"\""));
        // New iced agent added (uncommented, empty value)
        assert!(updated.contains("iced = \"\""));
        assert!(!updated.contains("Installed skills (reference)"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_project_config_preserves_user_edits() {
        let dir =
            std::env::temp_dir().join(format!("vstack_test_preserve_edits_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("vstack.toml");

        // Simulate user-edited file with active (uncommented) config
        let user_content = r#"[agent-launch-instructions]
rust = "Use for my backend services."

[agent-additional-instructions]
rust = "Always use thiserror for errors."
"#;
        std::fs::write(&path, user_content).unwrap();

        // Update with rust (already present) + new iced
        update_project_config(
            &path,
            &["rust".into(), "iced".into()],
            &["trading-design".into()],
        );
        let updated = std::fs::read_to_string(&path).unwrap();

        // User content preserved
        assert!(updated.contains("rust = \"Use for my backend services.\""));
        assert!(updated.contains("rust = \"Always use thiserror for errors.\""));
        // New agent added (uncommented, empty value)
        assert!(updated.contains("iced = \"\""));
        // Rust not duplicated
        let iced_section = updated.find("iced = \"\"").unwrap();
        assert!(
            !updated[iced_section..].contains("rust = \"\""),
            "rust should not appear in new agents section"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn repair_project_config_preserves_legacy_colors_and_adds_frontmatter_scaffold() {
        let dir =
            std::env::temp_dir().join(format!("vstack_test_repair_colors_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(
            &path,
            "# ─────────────────────────────────────────────────────\n# old header\n# ─────────────────────────────────────────────────────\n\n# ── Execute on Launch ─────────────────────────────────\n[agent-launch-instructions]\nrust = \"first line\\nsecond line\"\nfirst line\nsecond line\n\"\"\"\n\n[agent-additional-instructions]\niced = \"\"\"\nalpha\nbeta\n\"\"\"\n\n# ── Custom Hooks ─────────────────────────────────────\n# agents = \"all\"\n[agent-colors]\nrust = \"orange\"\niced = \"cyan\"\n\n[agent-frontmatter]\nrust = { color = \"orange\" }\nrust = { color = \"orange\" }\n",
        )
        .unwrap();

        ensure_project_config(&dir, &["rust".into(), "iced".into()], &[]);
        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(updated.contains("[agent-colors]"));
        assert!(updated.contains("[agent-frontmatter]"));
        assert!(!updated.contains("[agent-frontmatter.pi]"));
        assert!(updated.contains("rust = \"orange\""));
        assert!(updated.contains("iced = \"cyan\""));
        assert!(updated.contains("rust = \"\"\"\nfirst line\nsecond line\"\"\""));
        assert_eq!(updated.matches("first line").count(), 1);
        assert!(updated.contains("iced = \"\"\"\nalpha\nbeta\"\"\""));
        assert!(!updated.contains("beta\n\"\"\""));
        assert!(updated.contains("Agent Frontmatter"));
        assert!(!updated.contains("Pi-specific frontmatter values"));
        assert!(updated.contains("Generated frontmatter"));
        assert!(
            updated.find("Agent Frontmatter").unwrap()
                < updated.find("\n[agent-frontmatter]").unwrap()
        );
        toml::from_str::<toml::Value>(&updated).expect("repaired TOML parses");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── vstack#1006: prose inside a multi-line string is not structure ──────
    //
    // A consumer's instruction prose mentioned `[agent-additional-instructions]`
    // in backticks inside a `"""` value. `normalize_attached_section_headers`
    // matched the bracketed substring inside the string, reflowed it onto its
    // own line as a real section header, and the spacing pass then padded it —
    // splitting the prose and injecting a duplicate table header mid-file.
    // Section-header and key-line detection must ignore lines that sit inside
    // multi-line string values.

    /// A vstack.toml already in the exact shape every repair pass emits, so
    /// the whole pipeline must be a byte-identical no-op on it.
    fn canonical_repair_fixture(rust_additional_instructions: &str) -> String {
        format!(
            "{header}\n\n\n{launch}[agent-launch-instructions]\n\nrust = \"\"\n\n[agent-additional-instructions]\n\nrust = {value}\n\n{frontmatter}[agent-frontmatter.claude]\n\nrust = {{ model = \"opus\" }}\n",
            header = project_config_header().trim_end(),
            launch = launch_instructions_heading(),
            value = format_toml_string_value(rust_additional_instructions),
            frontmatter = agent_frontmatter_heading(),
        )
    }

    #[test]
    fn toml_multiline_string_content_lines_flags_string_bodies() {
        let content = "a = \"\"\"\nprose [x]\nend\"\"\"\nb = 1\nc = '''\nlit\n'''\n[real]\n";
        assert_eq!(
            toml_multiline_string_content_lines(content),
            [false, true, true, false, false, true, true, false]
        );
    }

    #[test]
    fn multiline_scanner_exits_on_closing_delimiter_with_trailing_comment() {
        // A close followed by whitespace and a `#` comment is a valid TOML
        // close; the scanner must not stay opaque past it.
        let content = "a = \"\"\"\nprose\n\"\"\" # rationale\n[real]\nb = 1\n";
        assert_eq!(
            toml_multiline_string_content_lines(content),
            [false, true, true, false, false]
        );
        assert!(section_start(content, "[real]").is_some());
    }

    #[test]
    fn multiline_scanner_ignores_commented_opener_examples() {
        // The launch-instructions heading itself contains `# iced = """` as a
        // commented example; a comment must never open string state.
        let content = "# iced = \"\"\"\n[agent-skills]\nrust = []\n";
        assert_eq!(
            toml_multiline_string_content_lines(content),
            [false, false, false]
        );
        assert!(section_start(content, "[agent-skills]").is_some());
    }

    #[test]
    fn migrate_section_names_preserves_bracketed_prose_in_inline_strings() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_migrate_prose_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(
            &path,
            "[agent-guidance]\nrust = \"See [agent-instructions] for details\"\n",
        )
        .unwrap();

        migrate_section_names(&path);
        let updated = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            updated,
            "[agent-launch-instructions]\nrust = \"See [agent-instructions] for details\"\n"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_section_names_preserves_crlf_line_endings() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_migrate_crlf_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        std::fs::write(&path, "[agent-guidance]\r\nrust = \"x\"\r\n").unwrap();

        migrate_section_names(&path);
        let updated = std::fs::read_to_string(&path).unwrap();
        assert_eq!(updated, "[agent-launch-instructions]\r\nrust = \"x\"\r\n");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn repair_canonical_fixture_is_byte_stable() {
        let fixture = canonical_repair_fixture("Plain prose.\nSecond line of prose.");
        assert_eq!(repair_project_config_content(&fixture, false), fixture);
    }

    #[test]
    fn repair_preserves_backticked_section_mention_inside_multiline_prose() {
        // Exact shape from vstack#1006: prose inside a multi-line value that
        // names a section in backticks must survive every pass untouched.
        let fixture = canonical_repair_fixture(
            "which every agent also carries as a one-bullet\nbinder in `[agent-additional-instructions]` (asserted by `tools/agent-tooling-verify`).\nRest of the prose.",
        );
        assert_eq!(repair_project_config_content(&fixture, false), fixture);
        assert_eq!(
            fixture.matches("[agent-additional-instructions]").count(),
            2,
            "fixture holds the real header plus the prose mention"
        );
    }

    #[test]
    fn repair_ignores_line_start_section_header_inside_multiline_prose() {
        // Worst case: the prose line IS a bracketed section name at column 0.
        let fixture = canonical_repair_fixture(
            "Prose before.\n[agent-additional-instructions]\nProse after.",
        );
        assert_eq!(repair_project_config_content(&fixture, false), fixture);
    }

    #[test]
    fn repair_preserves_bracketed_section_mention_inside_single_line_string() {
        // Same flaw, single-line variant: the mention sits inside a `"..."`
        // value rather than a `"""` block.
        let input = "[agent-additional-instructions]\n\nrust = \"binder in `[agent-additional-instructions]` (see docs).\"\n";
        assert_eq!(normalize_attached_section_headers(input), input);
    }

    #[test]
    fn repair_still_splits_real_attached_section_headers() {
        let input =
            "[agent-launch-instructions]\nrust = \"\" [agent-additional-instructions]\niced = \"\"\n";
        let out = normalize_attached_section_headers(input);
        assert!(out.contains("rust = \"\"\n[agent-additional-instructions]\niced = \"\"\n"));

        let spaced = ensure_blank_line_before_section_headers("x = 1\n[agent-skills]\n");
        assert_eq!(spaced, "x = 1\n\n[agent-skills]\n");
    }

    #[test]
    fn ensure_project_config_leaves_bracketed_prose_untouched_end_to_end() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_prose_brackets_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");
        let fixture = canonical_repair_fixture(
            "binder in `[agent-additional-instructions]` (asserted by `tools/agent-tooling-verify`).",
        );
        std::fs::write(&path, &fixture).unwrap();

        ensure_project_config(&dir, &["rust".into()], &[]);
        let updated = std::fs::read_to_string(&path).unwrap();
        assert_eq!(updated, fixture);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_project_config_no_change_when_all_present() {
        let dir =
            std::env::temp_dir().join(format!("vstack_test_no_change_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("vstack.toml");

        create_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        let before = std::fs::read_to_string(&path).unwrap();

        // Same agents/skills — should not add "New agents" section
        update_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        let after = std::fs::read_to_string(&path).unwrap();

        assert!(!after.contains("── New agents"));
        // Content should remain semantically stable.
        toml::from_str::<toml::Value>(&before).expect("before TOML parses");
        toml::from_str::<toml::Value>(&after).expect("after TOML parses");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn upsert_agent_value_replaces_empty_placeholder() {
        let toml = "[agent-launch-instructions]\nrust = \"\"\ngeneralist = \"\"\n";
        let out = upsert_agent_value_in_section(
            toml,
            "[agent-launch-instructions]",
            "rust",
            "Pick the highest-priority backend task.",
        );
        assert!(out.contains("rust = \"Pick the highest-priority backend task.\""));
        assert!(out.contains("generalist = \"\""));
        // Exactly one rust line
        assert_eq!(out.lines().filter(|l| l.starts_with("rust = ")).count(), 1);
    }

    #[test]
    fn upsert_agent_value_collapses_duplicates() {
        // Simulate corruption: section has the same key 3 times
        let toml = "[agent-launch-instructions]\n\
rust = \"first\"\n\
rust = \"second\"\n\
rust = \"third\"\n\
generalist = \"\"\n";
        let out =
            upsert_agent_value_in_section(toml, "[agent-launch-instructions]", "rust", "canonical");
        // Duplicates collapsed to a single line with the new value
        let rust_lines: Vec<&str> = out.lines().filter(|l| l.starts_with("rust = ")).collect();
        assert_eq!(
            rust_lines.len(),
            1,
            "expected a single rust line, got {rust_lines:?}"
        );
        assert_eq!(rust_lines[0], "rust = \"canonical\"");
        // Other agent untouched
        assert!(out.contains("generalist = \"\""));
    }

    #[test]
    fn upsert_agent_value_only_touches_target_section() {
        let toml = "[agent-launch-instructions]\nrust = \"\"\n\n[agent-additional-instructions]\nrust = \"DO NOT TOUCH\"\n";
        let out = upsert_agent_value_in_section(
            toml,
            "[agent-launch-instructions]",
            "rust",
            "launch text",
        );
        assert!(out.contains("[agent-launch-instructions]\nrust = \"launch text\""));
        assert!(
            out.contains("[agent-additional-instructions]\nrust = \"DO NOT TOUCH\""),
            "additional-instructions section corrupted: {out}"
        );
    }

    #[test]
    fn upsert_agent_value_escapes_newlines() {
        // Regression: a multi-line value used to be written with literal
        // newlines inside a single double-quoted string, producing invalid
        // TOML. On the next run the parser would fail, ProjectConfig::load
        // would return default, save_extracted would think the value was
        // missing, and upsert would write again — leaving the previous
        // body lines as orphans and compounding the corruption every run.
        let toml = "[agent-launch-instructions]\nrust = \"\"\n";
        let multiline = "first line\nsecond line\nthird line";
        let out =
            upsert_agent_value_in_section(toml, "[agent-launch-instructions]", "rust", multiline);

        // Result must parse as valid TOML
        let parsed: toml::Value = toml::from_str(&out)
            .unwrap_or_else(|e| panic!("upsert produced invalid TOML: {e}\n---\n{out}"));

        // The value round-trips correctly
        let value = parsed
            .get("agent-launch-instructions")
            .and_then(|t| t.get("rust"))
            .and_then(|v| v.as_str())
            .expect("missing rust value");
        assert_eq!(value, multiline);

        // Rendered in user-friendly triple-quoted form, not a single-line blob
        // with escaped `\n` sequences.
        assert!(
            out.contains("rust = \"\"\"\nfirst line\nsecond line\nthird line\"\"\""),
            "expected triple-quoted multiline value, got: {out}"
        );
    }

    #[test]
    fn upsert_agent_value_replaces_existing_multiline_block() {
        let toml = "[agent-additional-instructions]\nrust = \"\"\"\nold line\nold second\"\"\"\niced = \"\"\n";
        let out = upsert_agent_value_in_section(
            toml,
            "[agent-additional-instructions]",
            "rust",
            "new line\nnew second",
        );
        assert!(out.contains("rust = \"\"\"\nnew line\nnew second\"\"\""));
        assert!(!out.contains("old line"));
        toml::from_str::<toml::Value>(&out).expect("valid TOML after multiline replacement");
    }

    #[test]
    fn upsert_agent_value_appends_when_missing() {
        let toml = "[agent-launch-instructions]\ngeneralist = \"\"\n";
        let out = upsert_agent_value_in_section(
            toml,
            "[agent-launch-instructions]",
            "rust",
            "new launch",
        );
        assert!(out.contains("rust = \"new launch\""));
    }

    #[test]
    fn strip_skills_reference_handles_trailing_active_toml() {
        // Simulates a vstack.toml where the user appended a real `[[custom-hooks]]`
        // block AFTER the reference block. The previous logic refused to strip
        // (because the tail was not pure comments), causing each refresh to
        // append a fresh duplicate reference block. The fix strips the
        // contiguous comment run only, leaving any later TOML intact.
        let content = "[agent-skills]\nrust = []\n\n\
# ── Installed skills (reference) ─────────────────────\n\
#   rust-tooling\n\
#   rust-runtime\n\
\n\
[[custom-hooks]]\n\
event = \"PreToolUse\"\n\
command = \"./scripts/x.sh\"\n";

        let stripped = strip_skills_reference(content);
        assert!(
            !stripped.contains("Installed skills (reference)"),
            "reference block should be gone, got: {stripped}"
        );
        assert!(
            stripped.contains("[[custom-hooks]]"),
            "user-added TOML should be preserved, got: {stripped}"
        );
        assert!(
            stripped.contains("event = \"PreToolUse\""),
            "user-added TOML body should be preserved, got: {stripped}"
        );
    }

    #[test]
    fn strip_skills_reference_keeps_newline_before_trailing_toml() {
        let content = "# agents = \"all\"\n\n# ── Installed skills (reference) ─────────────────────\n#   rust\n[agent-frontmatter.pi]\nresearcher = { model = \"m\" }\n";
        let stripped = strip_skills_reference(content);
        assert!(
            stripped.contains("# agents = \"all\"\n[agent-frontmatter.pi]"),
            "active TOML should remain on its own line, got: {stripped:?}"
        );
    }

    #[test]
    fn update_project_config_idempotent_with_trailing_active_toml() {
        // Even with active TOML below the reference block, repeated refreshes
        // must not grow the file (no duplicate reference blocks).
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_idempotent_refresh_{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("vstack.toml");

        create_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        // Manually append an active block AFTER the auto-generated reference
        let mut current = std::fs::read_to_string(&path).unwrap();
        current.push_str(
            "\n\n[[custom-hooks]]\nevent = \"PreToolUse\"\ncommand = \"./scripts/x.sh\"\n",
        );
        std::fs::write(&path, &current).unwrap();

        // First update may reorder (moves regenerated reference to end).
        // The test we care about: subsequent updates are byte-stable.
        update_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        let after_first = std::fs::read_to_string(&path).unwrap();

        for _ in 0..3 {
            update_project_config(&path, &["rust".into()], &["rust-tooling".into()]);
        }
        let after_n = std::fs::read_to_string(&path).unwrap();

        assert_eq!(
            after_first, after_n,
            "file should be byte-stable across repeated refreshes"
        );
        // Legacy installed-skills reference block must not reappear
        assert!(!after_n.contains("Installed skills (reference)"));
        // Custom hooks block preserved
        assert!(
            after_n.contains("[[custom-hooks]]"),
            "custom-hooks block lost: {after_n}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_project_config_drops_legacy_skills_reference_block() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_skills_ref_drop_{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("vstack.toml");

        let legacy = "[agent-launch-instructions]\nrust = \"\"\n\n# ── Installed skills (reference) ─────────────────────\n#   rust-tooling\n#   rust-interop\n";
        std::fs::write(&path, legacy).unwrap();

        update_project_config(
            &path,
            &["rust".into()],
            &["rust-tooling".into(), "rust-interop".into()],
        );
        let updated = std::fs::read_to_string(&path).unwrap();
        assert!(!updated.contains("Installed skills (reference)"));
        assert!(!updated.contains("#   rust-tooling"));
        assert!(updated.contains("rust = \"\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_skips_write_when_only_trailing_newline_differs() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_newline_only_skip_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");

        let agents = vec!["rust".to_string()];
        let skills = vec!["rust-tooling".to_string()];
        create_project_config(&path, &agents, &skills);
        // Stabilize through one full ensure pass so the only remaining
        // difference we introduce is the missing final newline.
        ensure_project_config(&dir, &agents, &skills);
        let stable = std::fs::read_to_string(&path).unwrap();

        let no_newline = stable.strip_suffix('\n').unwrap().to_string();
        std::fs::write(&path, &no_newline).unwrap();
        let mtime_before = std::fs::metadata(&path).unwrap().modified().unwrap();

        ensure_project_config(&dir, &agents, &skills);

        let after = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            after, no_newline,
            "newline-only normalization must not touch the file"
        );
        let mtime_after = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(mtime_before, mtime_after, "no write should have occurred");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_skips_write_when_identical_with_trailing_newline() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_identical_skip_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");

        let agents = vec!["rust".to_string()];
        let skills = vec!["rust-tooling".to_string()];
        create_project_config(&path, &agents, &skills);
        ensure_project_config(&dir, &agents, &skills);
        let stable = std::fs::read_to_string(&path).unwrap();
        assert!(stable.ends_with('\n'));
        let mtime_before = std::fs::metadata(&path).unwrap().modified().unwrap();

        ensure_project_config(&dir, &agents, &skills);

        let after = std::fs::read_to_string(&path).unwrap();
        assert_eq!(after, stable, "identical content must not be rewritten");
        let mtime_after = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(mtime_before, mtime_after, "no write should have occurred");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_still_writes_real_changes_to_no_newline_file() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_test_real_change_writes_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vstack.toml");

        let agents = vec!["rust".to_string()];
        let skills = vec!["rust-tooling".to_string()];
        create_project_config(&path, &agents, &skills);
        ensure_project_config(&dir, &agents, &skills);
        let stable = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, stable.strip_suffix('\n').unwrap()).unwrap();

        // A new skill is a real payload: the write must happen.
        let skills_plus = vec!["rust-tooling".to_string(), "extra-skill".to_string()];
        ensure_project_config(&dir, &agents, &skills_plus);

        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("extra-skill"),
            "new skill entry missing: {after}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
