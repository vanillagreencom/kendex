//! A declared command as each harness's own file. Every harness with a
//! commands directory of its own reads the author's file untouched; the two
//! that do not — Codex, which retired prompts for skills, and Gemini, which
//! reads a TOML table — get a generated one.

use crate::frontmatter::Value;
use crate::render::agent::GENERATED_BANNER;
use crate::render::yaml_scalar;

/// The prompt Gemini runs, from the command's prose. A body is written in
/// Claude's spelling of the argument placeholder, `$ARGUMENTS`, and Gemini
/// expands nothing but `{{args}}` (matrix §1): left alone, the token
/// reaches the model as literal text and the arguments the user typed go
/// nowhere the prompt refers to. The catalog holds one body per command, so
/// the token is translated where it enters Gemini's file.
///
/// Callers comparing an installed `.toml` against its catalog source use
/// this rather than restating the translation.
pub fn gemini_prompt(prose: &str) -> String {
    prose
        .trim_start_matches('\n')
        .replace("$ARGUMENTS", "{{args}}")
}

/// The command as Gemini reads one: a table carrying the prompt it runs and
/// the description it lists, written through the TOML serializer so a body
/// full of quotes cannot break out of the value (matrix §1). The command's
/// own frontmatter stays out — it describes the file, not the prompt.
pub fn gemini(bytes: &[u8], name: &str) -> Result<String, String> {
    let body = String::from_utf8_lossy(bytes);
    let (front, prose) = split(&body);
    let mut table = toml::Table::new();
    table.insert(
        "description".to_owned(),
        toml::Value::String(description(front, prose, name)),
    );
    table.insert(
        "prompt".to_owned(),
        toml::Value::String(gemini_prompt(prose)),
    );
    let banner = GENERATED_BANNER.trim_start_matches("> ");
    toml::to_string(&table)
        .map(|table| format!("# {banner}\n\n{table}"))
        .map_err(|problem| format!("the command cannot be written as Gemini TOML — {problem}"))
}

/// The generated SKILL.md a command becomes on Codex: the frontmatter the
/// loader needs, the banner every generated file carries, then the command's
/// prose. The command's own frontmatter stays out — carried through,
/// `argument-hint` and `allowed-tools` would read as literal text inside the
/// skill.
pub fn codex_skill(emitted: &str, body: &str, name: &str) -> String {
    let (front, prose) = split(body);
    format!(
        "---\nname: {}\ndescription: {}\n---\n\n{GENERATED_BANNER}\n\n{}",
        yaml_scalar(emitted),
        yaml_scalar(&description(front, prose, name)),
        prose.trim_start_matches('\n'),
    )
}

fn split(body: &str) -> (Option<&str>, &str) {
    match crate::frontmatter::split(body) {
        Ok((front, prose)) => (Some(front), prose),
        Err(_) => (None, body),
    }
}

/// One line saying what the command does: the `description` its own
/// frontmatter declares, else its first line of prose. The frontmatter is
/// parsed, not scanned — a `description` nested under another key describes
/// that key, not the command.
fn description(front: Option<&str>, prose: &str, name: &str) -> String {
    let declared = front
        .and_then(|yaml| crate::frontmatter::parse_tolerant(yaml).ok())
        .and_then(|parsed| {
            parsed
                .map
                .get("description")
                .and_then(Value::as_str)
                .map(str::trim)
                .map(str::to_owned)
        })
        .filter(|text| !text.is_empty());
    if let Some(declared) = declared {
        return declared;
    }
    for line in prose.lines() {
        let line = line.trim().trim_start_matches('#').trim();
        if !line.is_empty() {
            return line.to_owned();
        }
    }
    format!("command {name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn described(body: &str, name: &str) -> String {
        let (front, prose) = split(body);
        description(front, prose, name)
    }

    #[test]
    fn a_description_comes_from_frontmatter_then_prose_then_the_name() {
        assert_eq!(
            described(
                "---\ndescription: Ship it\nmodel: opus\n---\n\n# Ship\n",
                "ship"
            ),
            "Ship it"
        );
        assert_eq!(
            described("\n# Ship the branch\n\nSteps.\n", "ship"),
            "Ship the branch"
        );
        assert_eq!(described("---\nmodel: opus\n---\n", "ship"), "command ship");
        assert_eq!(described("", "ship"), "command ship");
    }

    /// A `description` indented under another key describes that key. Taking
    /// it as the command's own is how a scanner reads frontmatter; a parser
    /// sees the nesting.
    #[test]
    fn a_nested_description_never_beats_the_command_s_own() {
        let text = codex_skill(
            "ship",
            "---\nallowed-tools:\n  description: NESTED WINS\ndescription: Ship the branch\n---\n\nBody.\n",
            "ship",
        );
        assert!(
            text.starts_with("---\nname: ship\ndescription: Ship the branch\n---\n"),
            "{text}"
        );
    }

    #[test]
    fn the_generated_skill_keeps_the_prose_and_drops_the_command_s_frontmatter() {
        let text = codex_skill(
            "ship",
            "---\ndescription: do: it\nargument-hint: <branch>\n---\n\nBody.\n",
            "ship",
        );
        assert!(
            text.starts_with("---\nname: ship\ndescription: \"do: it\"\n---\n"),
            "{text}"
        );
        assert!(text.contains(GENERATED_BANNER));
        assert!(!text.contains("argument-hint"), "{text}");
        assert!(text.ends_with("Body.\n"));
    }

    /// The prompt is what Gemini sends to the model, so the banner sits
    /// outside it as a comment rather than being read aloud every run.
    #[test]
    fn a_gemini_command_is_a_table_whose_prompt_carries_only_the_body() {
        let text = gemini(
            b"---\ndescription: Ship it\n---\n\nRun \"the\" checklist for {{args}}.\n",
            "ship",
        )
        .unwrap();
        assert!(text.starts_with("# Generated by kendex"), "{text}");
        let table: toml::Table = text.parse().unwrap();
        assert_eq!(table["description"].as_str(), Some("Ship it"));
        assert_eq!(
            table["prompt"].as_str(),
            Some("Run \"the\" checklist for {{args}}.\n")
        );
        assert!(!text.contains("---"), "{text}");
    }

    /// The author writes Claude's placeholder; Gemini expands only its own,
    /// so an untranslated body sends the typed arguments nowhere.
    #[test]
    fn a_gemini_command_carries_geminis_argument_placeholder() {
        let text = gemini(
            b"---\ndescription: Ship it\n---\n\nShip the package named in $ARGUMENTS.\n",
            "ship",
        )
        .unwrap();
        let table: toml::Table = text.parse().unwrap();
        assert_eq!(
            table["prompt"].as_str(),
            Some("Ship the package named in {{args}}.\n")
        );
        assert!(!text.contains("$ARGUMENTS"), "{text}");
    }
}
