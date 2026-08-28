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
use crate::settings_toml::{Line, Row};

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

/// MEMBERSHIP — whether the shell loaders read the assignments under this
/// header. They match a lone `[env]`, and the grammar corpus records that
/// they refuse a whole file holding any other shape
/// (`header-with-comment`), so a key under one is a key nothing reads.
/// Never the answer to where a table's text ends.
pub(crate) fn loaders_read_env(line: &str) -> bool {
    crate::settings_toml::header_of(line).is_some_and(|header| header.opens("env") && header.lone)
}

/// BOUNDARY — whether this row opens the `env` table, as TOML reads it.
/// What a splice is measured against, so it must not inherit the loaders'
/// blind spots: missing `[env] # note` here would send a seed past it and
/// append a second `[env]`, turning a file with a typo in its header into
/// one with two of the same table, which no reader survives.
pub(crate) fn opens_env(row: &Row) -> bool {
    table_row(row) && crate::settings_toml::header_of(row.text).is_some_and(|h| h.opens("env"))
}

/// The key one row assigns, by the name every spelling of it shares. That
/// name is what blocks a seed: inserting beside `'MODE'` because the bare
/// spelling was not found would put one key in the file twice and stop it
/// loading at all.
pub(crate) fn assignment_key(row: &Row) -> Option<String> {
    let (key, _, _) = row.assignment()?;
    crate::settings_toml::key_of(key).map(|key| key.name)
}

/// Whether this row is a table header the section walk ends on. The
/// reader's own answer: a line only reads as a table where nothing is
/// open above it, so a bracket nested in an array is not one, and a
/// header carrying a trailing comment still is.
pub(crate) fn table_row(row: &Row) -> bool {
    row.kind == Line::Table
}

pub fn extract_env_entries(template: &str) -> Vec<EnvEntry> {
    let mut entries = Vec::new();
    let mut in_env = false;
    let mut pending: Vec<String> = Vec::new();
    for row in crate::settings_toml::rows(template) {
        // A value's own lines are the value: read as structure they seed
        // keys the template never declared.
        if row.kind == Line::InValue {
            continue;
        }
        if table_row(&row) {
            if opens_env(&row) {
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
        match row.kind {
            Line::Blank => pending.clear(),
            Line::Comment => pending.push(row.text.to_owned()),
            _ => {
                if let Some(key) = assignment_key(&row) {
                    let mut lines = std::mem::take(&mut pending);
                    lines.push(row.text.to_owned());
                    entries.push(EnvEntry { key, lines });
                }
            }
        }
    }
    entries
}

/// Every key the file assigns anywhere, which is the presence check
/// seeding is held to — deliberately wider than what the loaders read.
pub fn assigned_keys(text: &str) -> Vec<String> {
    crate::settings_toml::rows(text)
        .iter()
        .filter_map(assignment_key)
        .collect()
}

/// The terminator new lines are written with: whatever the file's first
/// terminated line uses, `\n` where it has nothing to say.
fn file_eol(rows: &[Row]) -> &'static str {
    match rows
        .iter()
        .find(|row| row.raw.ends_with('\n'))
        .is_some_and(|row| row.raw.ends_with("\r\n"))
    {
        true => "\r\n",
        false => "\n",
    }
}

/// The `[env]` section's line span: the header's index and the index of
/// the first line after the section (the next table header, or the end
/// of the file). `None` = no `[env]` header. Seeding and refresh both
/// splice inside this span, so they cannot disagree about where it ends.
fn env_section(rows: &[Row]) -> Option<(usize, usize)> {
    let start = rows.iter().position(opens_env)?;
    let end = rows
        .iter()
        .enumerate()
        .skip(start + 1)
        .find_map(|(index, row)| table_row(row).then_some(index))
        .unwrap_or(rows.len());
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

    let rows = crate::settings_toml::rows(original);
    let eol = file_eol(&rows);
    let env = env_section(&rows);
    // Where the new block lands: the end of the `[env]` section, or the end
    // of the file (with a header) when there is none.
    let insert_at = env.map_or(rows.len(), |(_, end)| end);

    let mut block = String::new();
    // A final line with no terminator gets one — the once-only repair that
    // makes inserting after it possible at all.
    if insert_at == rows.len()
        && rows
            .last()
            .is_some_and(|row| row.text.len() == row.raw.len() && !row.raw.is_empty())
    {
        block.push_str(eol);
    }
    if env.is_none() {
        if !rows.is_empty() && insert_at > 0 && !rows[insert_at - 1].text.trim().is_empty() {
            block.push_str(eol);
        }
        block.push_str("[env]");
        block.push_str(eol);
    } else if insert_at > 0 && !rows[insert_at - 1].text.trim().is_empty() {
        block.push_str(eol);
    }
    block.push_str(&render_entries(&missing, eol));
    if insert_at < rows.len() && !rows[insert_at].text.trim().is_empty() {
        block.push_str(eol);
    }

    let mut out = String::with_capacity(original.len() + block.len());
    for row in &rows[..insert_at] {
        out.push_str(row.raw);
    }
    out.push_str(&block);
    for row in &rows[insert_at..] {
        out.push_str(row.raw);
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
/// The note is raised before the settings file is even read, because the
/// disagreement is worth saying either way. So it says which default
/// seeding WOULD write, under the condition seeding writes at all: a key
/// the file already assigns is left alone, and a note claiming a value
/// landed would be false exactly there.
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
                "{SETTINGS_FILE} {key}: packages ship different defaults — {} — where this file does not already assign it, {lands}'s is the one seeded, so set the value yourself if that is not the one you want",
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
