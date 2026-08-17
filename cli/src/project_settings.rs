use crate::skill::Skill;
use anyhow::{Context, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

const SETTINGS_FILE: &str = "vstack.settings.toml";
const SETTINGS_TEMPLATE: &str = "vstack.settings.toml.example";

#[derive(Debug, Clone)]
pub struct SettingsMergeResult {
    pub path: PathBuf,
    pub created: bool,
    pub added_keys: Vec<String>,
    /// Keys whose seeded comment block was refreshed to the template's
    /// revised text (the key's value line is never touched).
    pub updated_keys: Vec<String>,
}

impl SettingsMergeResult {
    pub fn summary(&self) -> String {
        if self.created {
            return format!(
                "created {} with {} setting(s): {}",
                self.path.display(),
                self.added_keys.len(),
                self.added_keys.join(", ")
            );
        }
        let mut parts = Vec::new();
        if !self.added_keys.is_empty() {
            parts.push(format!(
                "{} setting(s): {}",
                self.added_keys.len(),
                self.added_keys.join(", ")
            ));
        }
        if !self.updated_keys.is_empty() {
            parts.push(format!(
                "{} refreshed comment(s): {}",
                self.updated_keys.len(),
                self.updated_keys.join(", ")
            ));
        }
        format!("updated {} with {}", self.path.display(), parts.join("; "))
    }
}

#[derive(Debug, Clone)]
struct EnvEntry {
    key: String,
    lines: Vec<String>,
}

/// Seed missing skill-settings keys into `<project>/vstack.settings.toml` and
/// refresh seeded comment blocks whose upstream template text changed.
///
/// `seeds` is the provenance ledger (normally the project lock's
/// `settings_seeds`): per key, the hash of the comment block last written by
/// seeding. A comment is rewritten only while its current text still hashes
/// to that value — any other text is a user edit and is preserved. The map
/// can change even when the file does not (a block matching the incoming
/// template is recorded so the next upstream revision can propagate); callers
/// persist it when it changed.
pub fn ensure_skill_settings(
    project_root: &Path,
    skills: &[Skill],
    seeds: &mut BTreeMap<String, String>,
) -> Result<Option<SettingsMergeResult>> {
    let entries = settings_entries_from_skills(skills)?;
    if entries.is_empty() {
        return Ok(None);
    }

    let path = project_root.join(SETTINGS_FILE);

    if !path.exists() {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        std::fs::write(&path, render_new_settings_file(&entries))
            .with_context(|| format!("writing {}", path.display()))?;
        record_seeds(seeds, &entries);
        return Ok(Some(SettingsMergeResult {
            path,
            created: true,
            added_keys: entries.iter().map(|entry| entry.key.clone()).collect(),
            updated_keys: Vec::new(),
        }));
    }

    let original =
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let (refreshed, updated_keys) = refresh_seeded_comments(&original, &entries, seeds);
    // File-wide, not [env]-scoped: the review-gate settings contract enforces key
    // uniqueness across the whole file (its shell-side reader is not TOML-table-aware),
    // so a key assigned under any table must block a duplicate append just the same.
    let existing_keys = assigned_keys(&refreshed);
    let missing: Vec<EnvEntry> = entries
        .into_iter()
        .filter(|entry| !existing_keys.contains(&entry.key))
        .collect();

    let added_keys: Vec<String> = missing.iter().map(|entry| entry.key.clone()).collect();
    let merged = if missing.is_empty() {
        refreshed
    } else {
        merge_missing_entries(&refreshed, &missing)
    };
    record_seeds(seeds, &missing);
    if merged != original {
        std::fs::write(&path, merged).with_context(|| format!("writing {}", path.display()))?;
    }

    if added_keys.is_empty() && updated_keys.is_empty() {
        return Ok(None);
    }
    Ok(Some(SettingsMergeResult {
        path,
        created: false,
        added_keys,
        updated_keys,
    }))
}

fn record_seeds(seeds: &mut BTreeMap<String, String>, entries: &[EnvEntry]) {
    for entry in entries {
        let Some((_, comment)) = entry.lines.split_last() else {
            continue;
        };
        seeds.insert(entry.key.clone(), comment_hash(trim_blank_edges(comment)));
    }
}

/// Blank separators around a comment block are layout, not content: trim
/// them off both edges before comparing or hashing. Interior blanks stay.
fn trim_blank_edges(lines: &[String]) -> &[String] {
    let mut lo = 0;
    let mut hi = lines.len();
    while lo < hi && lines[lo].trim().is_empty() {
        lo += 1;
    }
    while hi > lo && lines[hi - 1].trim().is_empty() {
        hi -= 1;
    }
    &lines[lo..hi]
}

fn comment_hash(lines: &[String]) -> String {
    format!("{:016x}", crate::config::fnv1a(lines.join("\n").as_bytes()))
}

/// Rewrite `[env]` comment blocks whose upstream template text changed,
/// gated by the `seeds` ledger (see [`ensure_skill_settings`]). A block
/// already matching the incoming template is recorded in the ledger without
/// a file change, which is how installs predating the ledger pick up
/// provenance. Returns the (possibly rewritten) content and the refreshed
/// keys. Assignment lines are never touched.
fn refresh_seeded_comments(
    original: &str,
    entries: &[EnvEntry],
    seeds: &mut BTreeMap<String, String>,
) -> (String, Vec<String>) {
    let lines: Vec<String> = original.lines().map(str::to_string).collect();
    let Some(env_start) = lines.iter().position(|line| is_env_header(line)) else {
        return (original.to_string(), Vec::new());
    };
    let env_end = lines
        .iter()
        .enumerate()
        .skip(env_start + 1)
        .find_map(|(idx, line)| is_table_header(line).then_some(idx))
        .unwrap_or(lines.len());

    // (start, end, replacement) line spans, spliced back-to-front below so
    // earlier spans keep their indices.
    let mut replacements: Vec<(usize, usize, Vec<String>)> = Vec::new();
    let mut updated_keys = Vec::new();
    let mut pending: Vec<usize> = Vec::new();
    for idx in env_start + 1..env_end {
        let line = &lines[idx];
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            pending.push(idx);
            continue;
        }
        let key = assignment_key(line);
        let block = std::mem::take(&mut pending);
        // A line that is neither comment, blank, nor assignment breaks the
        // block: never splice across it (the drained run is discarded).
        let Some(key) = key else {
            continue;
        };
        let Some(template) = entries.iter().find(|entry| entry.key == key) else {
            continue;
        };
        let mut lo = 0;
        let mut hi = block.len();
        while lo < hi && lines[block[lo]].trim().is_empty() {
            lo += 1;
        }
        while hi > lo && lines[block[hi - 1]].trim().is_empty() {
            hi -= 1;
        }
        let current: Vec<String> = block[lo..hi].iter().map(|&i| lines[i].clone()).collect();
        let Some((_, incoming)) = template.lines.split_last() else {
            continue;
        };
        let incoming = trim_blank_edges(incoming);
        if current == incoming {
            seeds.insert(key, comment_hash(&current));
            continue;
        }
        if seeds.get(&key).map(String::as_str) != Some(comment_hash(&current).as_str()) {
            continue;
        }
        let (start, end) = if lo < hi {
            (block[lo], block[hi - 1] + 1)
        } else {
            // No existing comment: insert directly above the assignment.
            (idx, idx)
        };
        seeds.insert(key.clone(), comment_hash(incoming));
        replacements.push((start, end, incoming.to_vec()));
        updated_keys.push(key);
    }

    if replacements.is_empty() {
        return (original.to_string(), updated_keys);
    }
    let mut lines = lines;
    for (start, end, mut block) in replacements.into_iter().rev() {
        if start == end
            && start > 0
            && !lines[start - 1].trim().is_empty()
            && !is_table_header(&lines[start - 1])
        {
            block.insert(0, String::new());
        }
        lines.splice(start..end, block);
    }
    let mut out = lines.join("\n");
    out.push('\n');
    (out, updated_keys)
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

/// Keys assigned anywhere in the file, regardless of which table (or no
/// table) they fall under. Mirrors the file-wide uniqueness the settings
/// contract enforces, rather than the TOML-scoped view `env_keys` uses for
/// locating the `[env]` table.
fn assigned_keys(content: &str) -> BTreeSet<String> {
    // Mirror the shell reader's matcher exactly (`^[[:space:]]*NAME[[:space:]]*=`,
    // bare identifier keys only): what counts as "assigned" here must be
    // precisely what that line-oriented reader would match, no more (a
    // quoted `"KEY" = ...` is invisible to it and must not block the
    // template append) and no less (a key-shaped line anywhere in the file
    // — the reader is not TOML string-state-aware, so neither are we;
    // appending a "missing" default the reader can see elsewhere would trip
    // its file-wide uniqueness guard).
    content
        .lines()
        .filter(|line| !is_table_header(line))
        .filter_map(|line| {
            // Same bare-identifier rule as assignment_key, spelled out here
            // so the mirrored shell-reader semantics stay in one screenful.
            let trimmed = line.trim_start();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                return None;
            }
            let (key, _) = trimmed.split_once('=')?;
            let key = key.trim();
            (!key.is_empty() && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
                .then(|| key.to_string())
        })
        .collect()
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
    if !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(key.to_string())
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
SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-5.6-sol"
"#,
        )
        .unwrap();

        let project = root.join("project");
        let result = ensure_skill_settings(
            &project,
            &[skill("second-opinion", skill_dir)],
            &mut BTreeMap::new(),
        )
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
        assert!(settings.contains("SECOND_OPINION_CODEX_CMD = \"codex exec -m gpt-5.6-sol\""));
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
SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-5.6-sol"
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

        let result = ensure_skill_settings(
            &project,
            &[skill("second-opinion", skill_dir)],
            &mut BTreeMap::new(),
        )
        .unwrap()
        .unwrap();

        assert!(!result.created);
        assert_eq!(result.added_keys, vec!["SECOND_OPINION_CODEX_CMD"]);
        let settings = std::fs::read_to_string(project.join(SETTINGS_FILE)).unwrap();
        assert!(settings.contains("SECOND_OPINION_TIMEOUT = \"42\""));
        assert!(settings.contains("SECOND_OPINION_CODEX_CMD = \"codex exec -m gpt-5.6-sol\""));
        assert!(settings.contains("[other]\nvalue = true"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn skips_key_already_assigned_outside_the_env_table() {
        // Regression for VST-67 / #1071 (drovr#433): a consumer's hand-set
        // value for a settings key must never gain a duplicate assignment
        // from the template's default, even when that hand-set value sits
        // under a different table than [env] — the settings contract
        // enforces uniqueness file-wide, not per-table.
        let root = temp_root("outside_env");
        let skill_dir = root.join("source").join("skills").join("review-gate");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join(SETTINGS_TEMPLATE),
            r#"[env]

# REVIEW GATE
REVIEW_GATE_STATUS_PUBLISHER_REJECT = ""
REVIEW_GATE_CONTEXT = "Review gate"
"#,
        )
        .unwrap();
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            project.join(SETTINGS_FILE),
            r#"# Existing settings

[other]
REVIEW_GATE_STATUS_PUBLISHER_REJECT = "github-actions[bot]"

[env]
"#,
        )
        .unwrap();

        let result = ensure_skill_settings(
            &project,
            &[skill("review-gate", skill_dir)],
            &mut BTreeMap::new(),
        )
        .unwrap()
        .unwrap();

        assert!(!result.created);
        assert_eq!(result.added_keys, vec!["REVIEW_GATE_CONTEXT"]);
        let settings = std::fs::read_to_string(project.join(SETTINGS_FILE)).unwrap();
        // Count ASSIGNMENT lines (the shell reader's matcher shape), not raw
        // substring hits — a comment mentioning the key must not count.
        assert_eq!(
            settings
                .lines()
                .filter(|l| {
                    l.trim_start()
                        .strip_prefix("REVIEW_GATE_STATUS_PUBLISHER_REJECT")
                        .is_some_and(|rest| rest.trim_start().starts_with('='))
                })
                .count(),
            1
        );
        assert!(settings.contains("REVIEW_GATE_STATUS_PUBLISHER_REJECT = \"github-actions[bot]\""));
        assert!(settings.contains("REVIEW_GATE_CONTEXT = \"Review gate\""));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn leaves_project_untouched_when_no_skill_templates_exist() {
        let root = temp_root("none");
        let skill_dir = root.join("source").join("skills").join("plain");
        std::fs::create_dir_all(&skill_dir).unwrap();
        let project = root.join("project");

        let result =
            ensure_skill_settings(&project, &[skill("plain", skill_dir)], &mut BTreeMap::new())
                .unwrap();

        assert!(result.is_none());
        assert!(!project.join(SETTINGS_FILE).exists());
        let _ = std::fs::remove_dir_all(root);
    }

    const TUNER_V1: &str = r#"[env]

# Used by: tuner. Old guidance about the knob.
TUNER_MODE = "ask"
"#;

    const TUNER_V2: &str = r#"[env]

# Used by: tuner. Revised guidance: the knob now also
# governs merges.
TUNER_MODE = "ask"
"#;

    fn write_template(skill_dir: &Path, content: &str) {
        std::fs::create_dir_all(skill_dir).unwrap();
        std::fs::write(skill_dir.join(SETTINGS_TEMPLATE), content).unwrap();
    }

    #[test]
    fn refreshes_unedited_seeded_comment_when_template_revises_it() {
        let root = temp_root("comment_refresh");
        let skill_dir = root.join("source").join("skills").join("tuner");
        write_template(&skill_dir, TUNER_V1);
        let project = root.join("project");
        let mut seeds = BTreeMap::new();

        ensure_skill_settings(&project, &[skill("tuner", skill_dir.clone())], &mut seeds)
            .unwrap()
            .unwrap();
        // A hand-set VALUE must survive a comment refresh untouched.
        let path = project.join(SETTINGS_FILE);
        let hand_valued = std::fs::read_to_string(&path)
            .unwrap()
            .replace("TUNER_MODE = \"ask\"", "TUNER_MODE = \"auto\"");
        std::fs::write(&path, hand_valued).unwrap();

        write_template(&skill_dir, TUNER_V2);
        let result = ensure_skill_settings(&project, &[skill("tuner", skill_dir)], &mut seeds)
            .unwrap()
            .unwrap();

        assert_eq!(result.updated_keys, vec!["TUNER_MODE"]);
        assert!(result.added_keys.is_empty());
        let settings = std::fs::read_to_string(&path).unwrap();
        assert!(
            settings.contains("Revised guidance") && !settings.contains("Old guidance"),
            "stale seeded comment survived the template revision: {settings}"
        );
        assert!(
            settings.contains("TUNER_MODE = \"auto\""),
            "comment refresh touched the value line: {settings}"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn never_rewrites_hand_edited_comment() {
        let root = temp_root("comment_hand_edit");
        let skill_dir = root.join("source").join("skills").join("tuner");
        write_template(&skill_dir, TUNER_V1);
        let project = root.join("project");
        let mut seeds = BTreeMap::new();

        ensure_skill_settings(&project, &[skill("tuner", skill_dir.clone())], &mut seeds)
            .unwrap()
            .unwrap();
        let path = project.join(SETTINGS_FILE);
        let edited = std::fs::read_to_string(&path).unwrap().replace(
            "Old guidance about the knob.",
            "our fork pins this to ask — do not change.",
        );
        std::fs::write(&path, &edited).unwrap();

        write_template(&skill_dir, TUNER_V2);
        let result =
            ensure_skill_settings(&project, &[skill("tuner", skill_dir)], &mut seeds).unwrap();

        assert!(result.is_none(), "hand-edited comment reported as changed");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            edited,
            "hand-edited comment was rewritten"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn matching_comment_without_ledger_gains_provenance_then_updates() {
        // Installs that predate the settings_seeds ledger: a refresh that
        // finds the comment still matching its template records provenance
        // without touching the file, and template revisions from that point
        // propagate.
        let root = temp_root("comment_bootstrap");
        let skill_dir = root.join("source").join("skills").join("tuner");
        write_template(&skill_dir, TUNER_V1);
        let project = root.join("project");

        ensure_skill_settings(
            &project,
            &[skill("tuner", skill_dir.clone())],
            &mut BTreeMap::new(),
        )
        .unwrap()
        .unwrap();
        let path = project.join(SETTINGS_FILE);
        let seeded = std::fs::read_to_string(&path).unwrap();

        let mut seeds = BTreeMap::new();
        let result =
            ensure_skill_settings(&project, &[skill("tuner", skill_dir.clone())], &mut seeds)
                .unwrap();
        assert!(result.is_none());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), seeded);
        assert!(
            seeds.contains_key("TUNER_MODE"),
            "matching comment did not bootstrap provenance: {seeds:?}"
        );

        write_template(&skill_dir, TUNER_V2);
        let result = ensure_skill_settings(&project, &[skill("tuner", skill_dir)], &mut seeds)
            .unwrap()
            .unwrap();
        assert_eq!(result.updated_keys, vec!["TUNER_MODE"]);
        assert!(
            std::fs::read_to_string(&path)
                .unwrap()
                .contains("Revised guidance")
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn stale_comment_without_ledger_is_preserved() {
        // No provenance and the comment differs from the incoming template:
        // indistinguishable from a hand edit, so it must stay.
        let root = temp_root("comment_no_ledger");
        let skill_dir = root.join("source").join("skills").join("tuner");
        write_template(&skill_dir, TUNER_V2);
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let existing =
            "[env]\n\n# Guidance from an older template revision.\nTUNER_MODE = \"ask\"\n";
        let path = project.join(SETTINGS_FILE);
        std::fs::write(&path, existing).unwrap();

        let mut seeds = BTreeMap::new();
        let result =
            ensure_skill_settings(&project, &[skill("tuner", skill_dir)], &mut seeds).unwrap();

        assert!(result.is_none());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), existing);
        assert!(!seeds.contains_key("TUNER_MODE"));
        let _ = std::fs::remove_dir_all(root);
    }
}
