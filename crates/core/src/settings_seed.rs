//! `kendex.settings.toml` seeding — skills ship a
//! `kendex.settings.toml.example` and their `[env]` entries merge into the
//! project's settings file, write-if-absent per key: comment blocks travel
//! with their key. The shell-side readers consume the `[env]` table only,
//! but the presence check here stays file-wide, conservatively: seeding
//! must never add a key that some assignment outside `[env]` already
//! names.
//!
//! An entry is written whole or not at all. A value TOML lets span lines
//! carries every one of them; a value nothing closes has no complete text
//! to copy and is refused by name ([`unterminated_notes`]), because its
//! opening delimiter alone would leave the consumer's file unparseable
//! from that line down. Neither case is ever silent.
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

mod env;
mod notes;
mod refresh;
pub use env::{EnvBlocked, env_blocked};
pub use notes::{conflict_notes, seed_notes, unterminated_notes};
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
    /// The comment block above the assignment, in file order.
    pub comment: Vec<String>,
    /// Every physical line of the assignment, from the one carrying the
    /// `=` through the one that closes the value — a value TOML lets span
    /// lines is seeded whole or not at all. Empty where the template's
    /// value is not complete text seeding could copy.
    /// Held apart from the comment because which lines are the value is
    /// the walk's answer: a reader taking all-but-the-last off one list
    /// calls a multiline value's opening line part of the comment.
    pub assignment: Vec<String>,
}

impl EnvEntry {
    /// The lines seeding writes for this entry, comment first.
    fn lines(&self) -> impl Iterator<Item = &String> {
        self.comment.iter().chain(&self.assignment)
    }

    /// Whether the template spells this value out in full, which is
    /// whether there is anything here to write. Not the same as ending: a
    /// value can close, carry on, or break off mid-string, and only the
    /// first is text seeding may copy. A key with nothing complete behind
    /// it is refused by name rather than written half-finished.
    pub fn complete(&self) -> bool {
        !self.assignment.is_empty()
    }
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
        trim_blank_edges(&self.entry.comment)
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

/// The name one row's assignment declares, by the spelling every reading
/// of it shares. That name is what blocks a seed: inserting beside
/// `'MODE'` because the bare spelling was not found would put one key in
/// the file twice and stop it loading at all. A dotted key declares its
/// first segment as a table, so `MODE.part` occupies `MODE` and blocks a
/// seed of it exactly as a plain `MODE` would.
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

/// Every `[env]` entry the template declares, each holding all of its own
/// lines: the walk says where a value ends, so one spanning lines is taken
/// whole. An entry whose value nothing closes comes back with no
/// assignment lines — still an entry, because [`unterminated_notes`] has
/// to name it.
pub fn extract_env_entries(template: &str) -> Vec<EnvEntry> {
    let rows = crate::settings_toml::rows(template);
    let mut entries = Vec::new();
    let mut in_env = false;
    let mut pending: Vec<String> = Vec::new();
    let mut index = 0;
    while index < rows.len() {
        let row = &rows[index];
        index += 1;
        // A value's own lines go with the assignment that opened them,
        // taken below. Reaching here they belong to a value opened
        // outside `[env]`: read as structure they seed keys the template
        // never declared.
        if row.kind == Line::InValue {
            continue;
        }
        if table_row(row) {
            if opens_env(row) {
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
                let Some(key) = assignment_key(row) else {
                    continue;
                };
                let comment = std::mem::take(&mut pending);
                // The assignment runs to wherever its value closes. Every
                // line under an open value is one the walk called
                // `InValue`, so the run is exactly this entry's.
                let mut assignment = vec![row.text.to_owned()];
                let mut open = row.carries;
                let mut broken = row.broken;
                while open && index < rows.len() {
                    assignment.push(rows[index].text.to_owned());
                    open = rows[index].carries;
                    broken |= rows[index].broken;
                    index += 1;
                }
                // Complete means BOTH: the value closed, and no line of it
                // left a string nothing closes. Neither implies the other
                // — `TOKEN = "` carries nothing and is still unfinished —
                // and either alone would seed text that does not parse.
                if open || broken {
                    assignment.clear();
                }
                entries.push(EnvEntry {
                    key,
                    comment,
                    assignment,
                });
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
        // Every line of the entry, the value's continuation lines
        // included: a value is written whole or the entry never got here.
        for line in seeded.entry.lines() {
            out.push_str(line);
            out.push_str(eol);
        }
    }
    out
}

/// The declaration that speaks for a key: the first one seeding can write
/// whole, in declaration order. `None` where no installed template spells
/// the key's value out in full.
///
/// The one answer to "whose value lands", because four things must agree
/// on it: the bytes `merge` writes, the owner [`record_seeds`] records,
/// the template a later comment refresh is gated on, and the skill
/// [`conflict_notes`] names. Derived four times it was changed in one, and
/// a broken template declaring a key before a valid one had the valid
/// skill's bytes written under the broken skill's name — which stops the
/// real owner's comments refreshing and lets the broken one overwrite
/// them.
pub fn writable_for<'a>(entries: &'a [SeededEnv], key: &str) -> Option<&'a SeededEnv> {
    entries
        .iter()
        .find(|seeded| seeded.entry.key == key && seeded.entry.complete())
}

/// Merge missing entries into the settings text, byte-faithfully: the
/// inserted block is the only change, spelled in the file's own line
/// terminator. `None` = nothing to add. Returns the new text plus the keys
/// that were added.
pub fn merge(original: Option<&str>, entries: &[SeededEnv]) -> Option<(String, Vec<String>)> {
    // Nowhere to write: the plan reports the shape, and no byte moves.
    if original.is_some_and(|text| env_blocked(text).is_some()) {
        return None;
    }
    let existing: BTreeSet<String> = original
        .map(assigned_keys)
        .unwrap_or_default()
        .into_iter()
        .collect();
    // Each distinct key once, in declaration order, taken from the one
    // declaration that speaks for it. The winner comes from `writable_for`
    // rather than being re-derived here, so the bytes written, the ledger
    // and the notes cannot name three different skills.
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let missing: Vec<&SeededEnv> = entries
        .iter()
        .filter(|seeded| seen.insert(seeded.entry.key.as_str()))
        .filter(|seeded| !existing.contains(&seeded.entry.key))
        .filter_map(|seeded| writable_for(entries, &seeded.entry.key))
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

/// The ledger records the added entries were seeded, each under the owner
/// whose lines were written — asked of [`writable_for`], the same question
/// `merge` asked, so the record names the skill that actually supplied the
/// bytes.
pub fn record_seeds(
    seeds: &mut BTreeMap<String, SettingsSeed>,
    entries: &[SeededEnv],
    added: &[String],
) {
    for key in added {
        if let Some(seeded) = writable_for(entries, key) {
            seeds.insert(key.clone(), seeded.seed_record());
        }
    }
}

#[cfg(test)]
mod tests;
