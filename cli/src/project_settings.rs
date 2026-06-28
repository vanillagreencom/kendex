use crate::skill::Skill;
use anyhow::{Context, Result};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const SETTINGS_FILE: &str = "vstack.settings.toml";
const SETTINGS_TEMPLATE: &str = "vstack.settings.toml.example";

#[derive(Debug, Clone)]
pub struct SettingsMergeResult {
    pub path: PathBuf,
    pub created: bool,
    pub added_keys: Vec<String>,
}

impl SettingsMergeResult {
    pub fn summary(&self) -> String {
        let action = if self.created { "created" } else { "updated" };
        format!(
            "{action} {} with {} setting(s): {}",
            self.path.display(),
            self.added_keys.len(),
            self.added_keys.join(", ")
        )
    }
}

#[derive(Debug, Clone)]
struct EnvEntry {
    key: String,
    lines: Vec<String>,
}

pub fn ensure_skill_settings(
    project_root: &Path,
    skills: &[Skill],
) -> Result<Option<SettingsMergeResult>> {
    let entries = settings_entries_from_skills(skills)?;
    if entries.is_empty() {
        return Ok(None);
    }

    let path = project_root.join(SETTINGS_FILE);
    let added_keys: Vec<String> = entries.iter().map(|entry| entry.key.clone()).collect();

    if !path.exists() {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        std::fs::write(&path, render_new_settings_file(&entries))
            .with_context(|| format!("writing {}", path.display()))?;
        return Ok(Some(SettingsMergeResult {
            path,
            created: true,
            added_keys,
        }));
    }

    let original =
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let existing_keys = env_keys(&original);
    let missing: Vec<EnvEntry> = entries
        .into_iter()
        .filter(|entry| !existing_keys.contains(&entry.key))
        .collect();
    if missing.is_empty() {
        return Ok(None);
    }

    let added_keys: Vec<String> = missing.iter().map(|entry| entry.key.clone()).collect();
    let merged = merge_missing_entries(&original, &missing);
    if merged != original {
        std::fs::write(&path, merged).with_context(|| format!("writing {}", path.display()))?;
    }

    Ok(Some(SettingsMergeResult {
        path,
        created: false,
        added_keys,
    }))
}

fn settings_entries_from_skills(skills: &[Skill]) -> Result<Vec<EnvEntry>> {
    let mut entries = Vec::new();
    let mut seen = BTreeSet::new();
    for skill in skills {
        let template = skill.source_dir.join(SETTINGS_TEMPLATE);
        if !template.exists() {
            continue;
        }
        let content = std::fs::read_to_string(&template)
            .with_context(|| format!("reading {}", template.display()))?;
        for entry in extract_env_entries(&content) {
            if seen.insert(entry.key.clone()) {
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

fn render_new_settings_file(entries: &[EnvEntry]) -> String {
    let mut out = String::new();
    out.push_str("# Public vstack settings seeded from installed skill defaults.\n");
    out.push_str(
        "# vstack skill scripts read this [env] table after .env and before .env.local.\n",
    );
    out.push_str("# Keep secrets, tokens, and personal overrides in .env.local.\n\n");
    out.push_str("[env]\n");
    out.push_str(&render_entries(entries));
    out
}

fn merge_missing_entries(original: &str, entries: &[EnvEntry]) -> String {
    let mut lines: Vec<String> = original.lines().map(str::to_string).collect();
    let Some(env_start) = lines.iter().position(|line| is_env_header(line)) else {
        let mut out = original.to_string();
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        out.push_str("[env]\n");
        out.push_str(&render_entries(entries));
        return out;
    };

    let env_end = lines
        .iter()
        .enumerate()
        .skip(env_start + 1)
        .find_map(|(idx, line)| is_table_header(line).then_some(idx))
        .unwrap_or(lines.len());

    let mut block: Vec<String> = render_entries(entries)
        .trim_end_matches('\n')
        .lines()
        .map(str::to_string)
        .collect();

    if env_end > 0 && !lines[env_end - 1].trim().is_empty() {
        block.insert(0, String::new());
    }
    if env_end < lines.len() && !block.last().is_some_and(|line| line.trim().is_empty()) {
        block.push(String::new());
    }

    lines.splice(env_end..env_end, block);
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn render_entries(entries: &[EnvEntry]) -> String {
    let mut out = String::new();
    for entry in entries {
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        let mut entry_lines = entry.lines.as_slice();
        while entry_lines
            .first()
            .is_some_and(|line| line.trim().is_empty())
        {
            entry_lines = &entry_lines[1..];
        }
        for line in entry_lines {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn extract_env_entries(content: &str) -> Vec<EnvEntry> {
    let mut entries = Vec::new();
    let mut in_env = false;
    let mut pending = Vec::new();

    for line in content.lines() {
        if is_table_header(line) {
            if is_env_header(line) {
                in_env = true;
                pending.clear();
                continue;
            }
            if in_env {
                break;
            }
        }

        if !in_env {
            continue;
        }

        if let Some(key) = assignment_key(line) {
            let mut lines = Vec::new();
            lines.append(&mut pending);
            lines.push(line.to_string());
            entries.push(EnvEntry { key, lines });
            continue;
        }

        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            pending.push(line.to_string());
        }
    }

    entries
}

fn env_keys(content: &str) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let mut in_env = false;

    for line in content.lines() {
        if is_table_header(line) {
            if is_env_header(line) {
                in_env = true;
                continue;
            }
            if in_env {
                break;
            }
        }

        if !in_env {
            continue;
        }
        if let Some(key) = assignment_key(line) {
            keys.insert(key);
        }
    }

    keys
}

fn is_env_header(line: &str) -> bool {
    line.trim() == "[env]"
}

fn is_table_header(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with('[') && trimmed.ends_with(']')
}

fn assignment_key(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let (key, _) = trimmed.split_once('=')?;
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    Some(key.trim_matches('"').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skill::SkillDep;

    fn temp_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "vstack_project_settings_{name}_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn skill(name: &str, source_dir: PathBuf) -> Skill {
        Skill {
            name: name.to_string(),
            description: String::new(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir,
            resolved_deps: Vec::<SkillDep>::new(),
        }
    }

    #[test]
    fn creates_settings_file_from_skill_template() {
        let root = temp_root("creates");
        let skill_dir = root.join("source").join("skills").join("second-opinion");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join(SETTINGS_TEMPLATE),
            r#"[env]

# SECOND OPINION
SECOND_OPINION_TIMEOUT = "300"
SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-5.5"
"#,
        )
        .unwrap();

        let project = root.join("project");
        let result = ensure_skill_settings(&project, &[skill("second-opinion", skill_dir)])
            .unwrap()
            .unwrap();

        assert!(result.created);
        assert_eq!(
            result.added_keys,
            vec!["SECOND_OPINION_TIMEOUT", "SECOND_OPINION_CODEX_CMD"]
        );
        let settings = std::fs::read_to_string(project.join(SETTINGS_FILE)).unwrap();
        assert!(settings.contains("[env]"));
        assert!(settings.contains("SECOND_OPINION_TIMEOUT = \"300\""));
        assert!(settings.contains("SECOND_OPINION_CODEX_CMD = \"codex exec -m gpt-5.5\""));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn merges_missing_keys_without_overwriting_existing_values() {
        let root = temp_root("merges");
        let skill_dir = root.join("source").join("skills").join("second-opinion");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join(SETTINGS_TEMPLATE),
            r#"[env]

# SECOND OPINION
SECOND_OPINION_TIMEOUT = "300"
SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-5.5"
"#,
        )
        .unwrap();
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            project.join(SETTINGS_FILE),
            r#"# Existing settings

[env]
SECOND_OPINION_TIMEOUT = "42"

[other]
value = true
"#,
        )
        .unwrap();

        let result = ensure_skill_settings(&project, &[skill("second-opinion", skill_dir)])
            .unwrap()
            .unwrap();

        assert!(!result.created);
        assert_eq!(result.added_keys, vec!["SECOND_OPINION_CODEX_CMD"]);
        let settings = std::fs::read_to_string(project.join(SETTINGS_FILE)).unwrap();
        assert!(settings.contains("SECOND_OPINION_TIMEOUT = \"42\""));
        assert!(settings.contains("SECOND_OPINION_CODEX_CMD = \"codex exec -m gpt-5.5\""));
        assert!(settings.contains("[other]\nvalue = true"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn leaves_project_untouched_when_no_skill_templates_exist() {
        let root = temp_root("none");
        let skill_dir = root.join("source").join("skills").join("plain");
        std::fs::create_dir_all(&skill_dir).unwrap();
        let project = root.join("project");

        let result = ensure_skill_settings(&project, &[skill("plain", skill_dir)]).unwrap();

        assert!(result.is_none());
        assert!(!project.join(SETTINGS_FILE).exists());
        let _ = std::fs::remove_dir_all(root);
    }
}
