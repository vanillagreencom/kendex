use crate::agent::{self, Agent};
use crate::hook::Hook;
use anyhow::Result;
use std::path::{Path, PathBuf};

/// Generate a Cursor rule file (.cursor/rules/<name>.mdc)
///
/// Format: YAML frontmatter with description, alwaysApply
/// followed by markdown body content.
pub fn generate_agent(
    agent: &Agent,
    dir: &Path,
    _skills: &[(String, String)],
    _hooks: &[Hook],
    extras: &agent::AgentExtras,
) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;

    let path = super::checked_agent_path(dir, &agent.name, "mdc")?;

    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!(
        "description: \"{} — {}\"\n",
        agent.name, agent.description
    ));
    output.push_str("alwaysApply: false\n");
    output.push_str("---\n\n");
    output.push_str("> **Never edit this file directly.** To make additions or modifications, edit the appropriate section in `vstack.toml` at the repository root. Then run `vstack refresh`.\n\n");

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
