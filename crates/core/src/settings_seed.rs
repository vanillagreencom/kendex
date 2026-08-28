//! `kendex.settings.toml` seeding — skills ship a
//! `kendex.settings.toml.example` and their `[env]` entries merge into the
//! project's settings file, write-if-absent per key: comment blocks travel
//! with their key. The shell-side readers consume the `[env]` table only,
//! but the presence check here stays file-wide, conservatively: seeding
//! must never add a key that some assignment outside `[env]` already
//! names.
//!
//! Seeded comments stay current ([`refresh`]): the lock keeps, per key, the
//! FNV-1a hash of the comment block last written by seeding, and a key's
//! comment is rewritten to the template's revision only while its on-disk
//! text still hashes to that record — anything else is a hand edit,
//! preserved forever. Value lines are never touched, and every write here
//! is byte-faithful: comment-block bytes (and the inserted block on a
//! merge) are the only bytes that change, so CRLF files and
//! missing-terminator state survive untouched.

use std::collections::{BTreeMap, BTreeSet};

use crate::lock::SettingsSeed;

mod refresh;
pub use refresh::refresh_comments;

pub const SETTINGS_FILE: &str = "kendex.settings.toml";
pub const SETTINGS_TEMPLATE: &str = "kendex.settings.toml.example";
/// The settings file seeding targets in this project.
pub fn settings_file_path(project_root: &std::path::Path) -> std::path::PathBuf {
    project_root.join(SETTINGS_FILE)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvEntry {
    pub key: String,
    pub lines: Vec<String>,
}

/// One entry as a scope plans it: the template's lines plus the skill that
/// ships them — the owner every later comment refresh is gated on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeededEnv {
    pub entry: EnvEntry,
    /// The declared skill whose template this came from.
    pub owner: String,
}

impl SeededEnv {
    /// The comment block this entry would write, trimmed the way the
    /// ledger hashes it.
    fn comment(&self) -> &[String] {
        let Some((_, comment)) = self.entry.lines.split_last() else {
            return &[];
        };
        trim_blank_edges(comment)
    }

    /// The default this entry ships, spelled the way a note shows it: the
    /// decoded value in quotes, or the assignment's right-hand side
    /// verbatim where the strict reader cannot decode it. Every entry
    /// `merge` seeds has one, so a note can never drop an owner and then
    /// name the wrong package as the one whose value lands.
    fn default_shown(&self) -> String {
        let line = self.entry.lines.last().map_or("", String::as_str);
        match crate::settings_template::decoded_value(line) {
            Some(value) => format!("\"{value}\""),
            None => line
                .split_once('=')
                .map_or(line, |(_, value)| value)
                .trim()
                .to_owned(),
        }
    }

    /// The ledger record seeding this entry writes.
    pub fn seed_record(&self) -> SettingsSeed {
        SettingsSeed {
            owner: Some(self.owner.clone()),
            hash: comment_hash(self.comment()),
        }
    }
}

/// The seeded comment block's hash: 64-bit FNV-1a over the block's lines
/// joined with `\n`.
pub fn comment_hash(lines: &[String]) -> String {
    crate::hash::fnv1a_hex(lines.join("\n").as_bytes())
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

fn is_table_header(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with('[') && trimmed.ends_with(']')
}

fn is_env_header(line: &str) -> bool {
    line.trim() == "[env]"
}

fn assignment_key(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.starts_with('#') || trimmed.is_empty() || is_table_header(trimmed) {
        return None;
    }
    trimmed
        .split_once('=')
        .map(|(key, _)| key.trim().trim_matches('"').to_owned())
        .filter(|k| !k.is_empty())
}

pub fn extract_env_entries(template: &str) -> Vec<EnvEntry> {
    let mut entries = Vec::new();
    let mut in_env = false;
    let mut pending: Vec<String> = Vec::new();
    for line in template.lines() {
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
        if line.trim().is_empty() {
            pending.clear();
            continue;
        }
        if line.trim().starts_with('#') {
            pending.push(line.to_owned());
            continue;
        }
        if let Some(key) = assignment_key(line) {
            let mut lines = std::mem::take(&mut pending);
            lines.push(line.to_owned());
            entries.push(EnvEntry { key, lines });
        }
    }
    entries
}

pub fn assigned_keys(text: &str) -> Vec<String> {
    text.lines().filter_map(assignment_key).collect()
}

/// One line of the original with its terminator kept — the unit the
/// byte-faithful editors splice between. Untouched lines are re-emitted
/// exactly as read, terminator included, so CRLF files and a final line
/// with no terminator survive every edit they are not part of.
fn lines_keepends(text: &str) -> Vec<&str> {
    text.split_inclusive('\n').collect()
}

/// A line's content without its terminator.
fn content_of(line: &str) -> &str {
    line.strip_suffix('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .unwrap_or(line)
}

/// The terminator new lines are written with: whatever the file's first
/// terminated line uses, `\n` where it has nothing to say.
fn file_eol(lines: &[&str]) -> &'static str {
    match lines
        .iter()
        .find(|line| line.ends_with('\n'))
        .is_some_and(|line| line.ends_with("\r\n"))
    {
        true => "\r\n",
        false => "\n",
    }
}

/// The `[env]` section's line span: the header's index and the index of
/// the first line after the section (the next table header, or the end
/// of the file). `None` = no `[env]` header. Seeding and refresh both
/// splice inside this span, so they cannot disagree about where it ends.
fn env_section(lines: &[&str]) -> Option<(usize, usize)> {
    let start = lines
        .iter()
        .position(|line| is_env_header(content_of(line)))?;
    let end = lines
        .iter()
        .enumerate()
        .skip(start + 1)
        .find_map(|(index, line)| is_table_header(content_of(line)).then_some(index))
        .unwrap_or(lines.len());
    Some((start, end))
}

fn render_entries(entries: &[&SeededEnv], eol: &str) -> String {
    let mut out = String::new();
    for seeded in entries {
        if !out.is_empty() {
            out.push_str(eol);
        }
        for line in &seeded.entry.lines {
            out.push_str(line);
            out.push_str(eol);
        }
    }
    out
}

/// Merge missing entries into the settings text, byte-faithfully: the
/// inserted block is the only change, spelled in the file's own line
/// terminator. `None` = nothing to add. Returns the new text plus the keys
/// that were added.
pub fn merge(original: Option<&str>, entries: &[SeededEnv]) -> Option<(String, Vec<String>)> {
    let mut existing: BTreeSet<String> = original
        .map(assigned_keys)
        .unwrap_or_default()
        .into_iter()
        .collect();
    // First declaration wins a key that several skills ship.
    let missing: Vec<&SeededEnv> = entries
        .iter()
        .filter(|seeded| existing.insert(seeded.entry.key.clone()))
        .collect();
    if missing.is_empty() {
        return None;
    }
    let added: Vec<String> = missing.iter().map(|s| s.entry.key.clone()).collect();

    let Some(original) = original else {
        let mut out = String::from(
            "# Public kendex settings seeded from installed skill defaults.\n# Skill scripts read this [env] table; process env and .env.local override it.\n# Keep secrets, tokens, and personal overrides in .env.local.\n\n[env]\n",
        );
        out.push_str(&render_entries(&missing, "\n"));
        return Some((out, added));
    };

    let lines = lines_keepends(original);
    let eol = file_eol(&lines);
    let env = env_section(&lines);
    // Where the new block lands: the end of the `[env]` section, or the end
    // of the file (with a header) when there is none.
    let insert_at = env.map_or(lines.len(), |(_, end)| end);

    let mut block = String::new();
    // A final line with no terminator gets one — the once-only repair that
    // makes inserting after it possible at all.
    if insert_at == lines.len()
        && lines
            .last()
            .is_some_and(|line| content_of(line).len() == line.len() && !line.is_empty())
    {
        block.push_str(eol);
    }
    if env.is_none() {
        if !lines.is_empty() && insert_at > 0 && !content_of(lines[insert_at - 1]).trim().is_empty()
        {
            block.push_str(eol);
        }
        block.push_str("[env]");
        block.push_str(eol);
    } else if insert_at > 0 && !content_of(lines[insert_at - 1]).trim().is_empty() {
        block.push_str(eol);
    }
    block.push_str(&render_entries(&missing, eol));
    if insert_at < lines.len() && !content_of(lines[insert_at]).trim().is_empty() {
        block.push_str(eol);
    }

    let mut out = String::with_capacity(original.len() + block.len());
    for line in &lines[..insert_at] {
        out.push_str(line);
    }
    out.push_str(&block);
    for line in &lines[insert_at..] {
        out.push_str(line);
    }
    Some((out, added))
}

/// What the plan says about keys several packages ship with different
/// defaults: one line per key, naming every default and everyone who ships
/// it. `merge` takes the first declaration and writes nothing about the
/// others, so a disagreement about what a key should be is invisible
/// anywhere else — and packages agreeing on a shared key, which is the
/// ordinary case, say nothing at all.
///
/// Every entry counts, whatever shape its value is in. `merge` reads the
/// same lenient list, so an entry this dropped would be one the note left
/// out of a key it does seed — and with it the owner named as the one
/// whose value lands.
///
/// Key, owners and defaults are all catalog text a download supplied, so
/// the finished line goes through [`crate::names::shown`]: a note is read
/// on a terminal, and nothing in it is a sequence to act on.
pub fn conflict_notes(entries: &[SeededEnv]) -> Vec<String> {
    // Distinct defaults per key, each with its owners, both in declaration
    // order; the key order is the file's, so the notes read stably.
    let mut by_key: BTreeMap<&str, Vec<(String, Vec<&str>)>> = BTreeMap::new();
    for seeded in entries {
        let default = seeded.default_shown();
        let defaults = by_key.entry(&seeded.entry.key).or_default();
        match defaults.iter_mut().find(|(seen, _)| seen == &default) {
            Some((_, owners)) => owners.push(&seeded.owner),
            None => defaults.push((default, vec![&seeded.owner])),
        }
    }
    by_key
        .into_iter()
        .filter(|(_, defaults)| defaults.len() > 1)
        .map(|(key, defaults)| {
            let lands = defaults[0].1[0];
            let shown: Vec<String> = defaults
                .iter()
                .map(|(value, owners)| format!("{value} ({})", owners.join(", ")))
                .collect();
            crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: packages ship different defaults — {} — only {lands}'s is seeded, so set the value yourself if that is not the one you want",
                shown.join(", ")
            ))
        })
        .collect()
}

/// The ledger records the added entries were seeded, each under the owner
/// whose lines were written — the first declaration, as `merge` chose.
pub fn record_seeds(
    seeds: &mut BTreeMap<String, SettingsSeed>,
    entries: &[SeededEnv],
    added: &[String],
) {
    for key in added {
        if let Some(seeded) = entries.iter().find(|seeded| &seeded.entry.key == key) {
            seeds.insert(key.clone(), seeded.seed_record());
        }
    }
}

#[cfg(test)]
mod tests;
