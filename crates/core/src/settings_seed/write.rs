//! Writing entries into the consumer's settings file.
//!
//! Split from the reading beside it because the two answer different
//! questions. Everything here is byte-faithful: the inserted block is the
//! only change, and inside it the comment lines take the destination
//! file's terminator while a value's own newlines are copied as the
//! template wrote them.

use std::collections::BTreeSet;

use crate::settings_toml::Row;

use super::{SeededEnv, Seeding, assigned_keys, env_blocked, opens_env, table_row, written_for};

/// The terminator new lines are written with: whatever the file's first
/// terminated line uses, `\n` where it has nothing to say.
pub(super) fn file_eol(rows: &[Row]) -> &'static str {
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
/// of the file). `None` = no `[env]` header. The one splice there is
/// takes its insertion point from the end this returns.
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
        // Two kinds of newline, and only one of them is the file's. The
        // comment lines are the file's own structure and take its
        // terminator; the value goes out byte for byte, because the
        // newlines inside it are content the template chose.
        for line in &seeded.entry.comment {
            out.push_str(line);
            out.push_str(eol);
        }
        out.push_str(&seeded.entry.assignment);
        out.push_str(eol);
    }
    out
}

/// Merge into the settings text the entries `seeding` admits, byte-
/// faithfully: the inserted block is the only change, spelled in the
/// file's own line terminator. `None` = nothing to add. Returns the new
/// text plus the keys that were added.
///
/// What is written is [`Seeding`]'s answer, not "every key the file does
/// not have". A template's other keys ship values their own code already
/// reads, so writing them would put lines in a tracked file that change
/// nothing and come back after every deletion.
pub fn merge(
    original: Option<&str>,
    entries: &[SeededEnv],
    seeding: &Seeding,
) -> Option<(String, Vec<String>)> {
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
    // declaration that speaks for it. The winner comes from `written_for`
    // rather than being re-derived here, so the bytes written and the skill
    // a note names cannot be two different answers — and the file-wide
    // presence check goes into that same answer, so a note cannot count a
    // key as written that this filter was going to drop.
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let missing: Vec<&SeededEnv> = entries
        .iter()
        .filter(|seeded| seen.insert(seeded.entry.key.as_str()))
        .filter_map(|seeded| written_for(entries, &seeded.entry.key, seeding, &existing))
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
