use std::path::PathBuf;

use super::{Finding, frontmatter_map};
use crate::frontmatter::Value;
use crate::model::HarnessId;

/// Codex's documented ceiling on a skill's frontmatter `description`
/// (developers.openai.com/codex/skills): characters, not bytes.
const CODEX_DESCRIPTION_MAX_CHARS: usize = 1024;

/// The tree's SKILL.md under either name — a disabled skill keeps the same
/// content parked under `.disabled`, and it is validated all the same so
/// enabling it later cannot install something broken.
fn skill_md(files: &[(PathBuf, Vec<u8>)]) -> Option<&[u8]> {
    files.iter().find_map(|(rel, bytes)| {
        crate::render::skill::carries_name(rel).then_some(bytes.as_slice())
    })
}

/// `declared` is the name the user wrote down and `name` the one this tool
/// installs it under: they differ when the item carries the plugin it came
/// from, and then a fix that asks for either name to be changed is a fix
/// nobody can apply.
pub(super) fn findings(
    harness: HarnessId,
    declared: &str,
    name: &str,
    files: &[(PathBuf, Vec<u8>)],
) -> Vec<Finding> {
    let tool = harness.display_name();
    let Some(bytes) = skill_md(files) else {
        return vec![Finding::breakage(
            format!(
                "the tree for `{name}` has no SKILL.md, which is the only file {tool} looks for"
            ),
            "add SKILL.md to the skill's directory in the catalog",
        )];
    };
    let text = String::from_utf8_lossy(bytes);
    let map = match frontmatter_map(&text, tool) {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let mut findings = Vec::new();
    let in_file = map
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if in_file.is_empty() {
        findings.push(Finding::breakage(
            format!("SKILL.md has no `name:`, so {tool} has nothing to list `{name}` under"),
            format!("add `name: {name}` to the skill's SKILL.md in the catalog"),
        ));
    } else if in_file != name {
        findings.push(Finding::breakage(
            format!(
                "SKILL.md calls the skill `{in_file}` but it installs as `{name}`, so {tool} offers a name nobody declared"
            ),
            match declared == name {
                true => format!(
                    "set `name: {name}` in the skill's SKILL.md, or declare the skill as `{in_file}`"
                ),
                // The installed name carries the plugin the item lives in,
                // which no catalog file knows and no declaration can spell.
                // kendex writes it into its own copy, and the one shape it
                // cannot write into is frontmatter that is not a plain
                // `---` block.
                false => format!(
                    "give this skill's SKILL.md a plain `---` frontmatter block — that is what kendex writes `name: {name}` into when it installs `{declared}`"
                ),
            },
        ));
    }
    let described = map
        .get("description")
        .and_then(Value::as_str)
        .is_some_and(|text| !text.trim().is_empty());
    if !described {
        findings.push(Finding::advisory(
            format!("SKILL.md has no description, so {tool} has nothing to decide when to use `{name}` on"),
            "add a one-line `description:` saying when the skill applies",
        ));
    }
    // Codex bounds the frontmatter `description` — the one hard limit its
    // skill loader documents — and rejects the skill outright past it. The
    // body has no cap: Codex reads the whole file.
    if harness == HarnessId::Codex
        && let Some(description) = map.get("description").and_then(Value::as_str)
        && description.chars().count() > CODEX_DESCRIPTION_MAX_CHARS
    {
        findings.push(Finding::breakage(
            format!(
                "`{name}`'s description is {} characters and {tool} rejects a skill whose description runs past {CODEX_DESCRIPTION_MAX_CHARS}",
                description.chars().count()
            ),
            "shorten the `description:` in the skill's SKILL.md — say when the skill applies, and leave the how to the body",
        ));
    }
    findings
}
