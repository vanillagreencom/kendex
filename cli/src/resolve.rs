use crate::agent::{AgentExtras, AgentRole};
use crate::harness::Harness;
use crate::project_config::ProjectConfig;
use crate::skill::Skill;
use std::path::Path;

/// Map skill names to (name, description) pairs using the available skill list.
/// Falls back to the skill name itself when no matching Skill is found.
pub fn resolve_skill_pairs(names: &[String], available: &[Skill]) -> Vec<(String, String)> {
    names
        .iter()
        .map(|name| {
            let desc = available
                .iter()
                .find(|s| s.name == *name)
                .map(|s| s.description.clone())
                .unwrap_or_else(|| name.clone());
            (name.clone(), desc)
        })
        .collect()
}

/// Read guidance/instructions from an existing agent file on disk.
/// Returns empty extras if the file doesn't exist.
pub fn read_existing_extras(path: &Path, harness: Harness) -> AgentExtras {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Default::default();
    };
    let body = if matches!(harness, Harness::Codex) {
        crate::agent::extract_body_from_codex_toml(&content).unwrap_or(content)
    } else {
        content
    };
    crate::agent::extract_user_sections(&body)
}

/// Build AgentExtras by merging project config values with file-extracted fallbacks.
pub fn build_agent_extras(
    project_config: &ProjectConfig,
    agent_name: &str,
    agent_role: &AgentRole,
    file_extras: Option<&AgentExtras>,
) -> AgentExtras {
    let file_guidance = file_extras.and_then(|e| e.guidance.as_deref());
    let file_instructions = file_extras.and_then(|e| e.instructions.as_deref());
    let file_color = file_extras.and_then(|e| e.color.as_deref());
    AgentExtras {
        color: project_config
            .color_for(agent_name)
            .or(file_color)
            .map(String::from),
        guidance: project_config
            .guidance_for(agent_name)
            .or(file_guidance)
            .map(String::from),
        instructions: project_config
            .instructions_for(agent_name)
            .or(file_instructions)
            .map(String::from),
        frontmatter: Default::default(),
        frontmatter_by_harness: project_config
            .agent_frontmatter_by_harness
            .iter()
            .filter_map(|(harness, entries)| {
                entries
                    .get(agent_name)
                    .cloned()
                    .map(|overrides| (harness.clone(), overrides))
            })
            .collect(),
        custom_hooks: project_config.custom_hooks_for(agent_name, agent_role),
    }
}

/// Check if a directory looks like a vstack source repo (has 2+ source item dirs).
pub fn is_vstack_source(dir: &Path) -> bool {
    if dir
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.starts_with('.'))
    {
        return false;
    }
    let count = [
        dir.join("agents").is_dir(),
        dir.join("skills").is_dir(),
        dir.join("hooks").is_dir(),
        dir.join("pi-extensions").is_dir(),
        dir.join("extras").is_dir(),
    ]
    .iter()
    .filter(|&&b| b)
    .count();
    count >= 2
}
