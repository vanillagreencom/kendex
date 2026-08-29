//! Seeded comments stay current: a key's comment block is rewritten to the
//! template's revision only while its on-disk text still hashes to what
//! seeding last wrote (the lock's ledger) *and* the template belongs to
//! the key's recorded owner. Everything else — a hand edit, another
//! skill's template, a record imported from v1 with no owner — is
//! preserved forever. Value lines are never touched, and comment-block
//! bytes are the only bytes a refresh may change.

use std::collections::{BTreeMap, BTreeSet};

use crate::lock::SettingsSeed;

use super::{
    SeededEnv, assignment_key, comment_hash, env_section, file_eol, table_row, trim_blank_edges,
};
use crate::settings_toml::Line;

/// Rewrite `[env]` comment blocks whose upstream template text changed,
/// gated by the ledger. A block already matching the incoming template is
/// adopted into the ledger without a file change — how installs predating
/// the ledger, and v1 imports whose comment is provably unedited, pick up
/// provenance — but never over another owner's record. Returns the
/// (possibly rewritten) content and the refreshed keys.
pub fn refresh_comments(
    original: &str,
    entries: &[SeededEnv],
    seeds: &mut BTreeMap<String, SettingsSeed>,
) -> (String, Vec<String>) {
    let rows = crate::settings_toml::rows(original);
    let Some((env_start, env_end)) = env_section(&rows) else {
        return (original.to_owned(), Vec::new());
    };
    let eol = file_eol(&rows);

    // (start, end, replacement-lines) spans over `lines`, in file order,
    // reassembled by one forward pass below.
    let mut replacements: Vec<(usize, usize, Vec<String>)> = Vec::new();
    let mut updated = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut pending: Vec<usize> = Vec::new();
    for index in env_start + 1..env_end {
        let row = &rows[index];
        // A value's own lines are the value: a `#` inside one is not a
        // comment to rewrite, and an assignment-shaped line inside one is
        // not a key. Neither may the block splice across them.
        if row.kind == Line::InValue {
            pending.clear();
            continue;
        }
        if matches!(row.kind, Line::Blank | Line::Comment) {
            pending.push(index);
            continue;
        }
        let key = assignment_key(row);
        let block = std::mem::take(&mut pending);
        // A line that is neither comment, blank, nor assignment breaks the
        // block: never splice across it (the drained run is discarded).
        let Some(key) = key else {
            continue;
        };
        // Uniqueness is file-wide when seeding writes a key; a hand-made
        // duplicate is judged once, at its first site, like `merge` would.
        if !seen.insert(key.clone()) {
            continue;
        }
        let Some(seeded) = template_for(&key, entries, seeds.get(&key)) else {
            continue;
        };
        let contents: Vec<String> = block.iter().map(|&i| rows[i].text.to_owned()).collect();
        let current = trim_blank_edges(&contents);
        let skipped = contents
            .iter()
            .take_while(|line| line.trim().is_empty())
            .count();
        let incoming = seeded.comment();
        if current == incoming {
            adopt(&key, seeded, current, seeds);
            continue;
        }
        // Only the recorded owner's template may rewrite, and only while
        // the on-disk text is provably what seeding last wrote.
        let permits = seeds.get(&key).is_some_and(|record| {
            record.owner.as_deref() == Some(seeded.owner.as_str())
                && record.hash == comment_hash(current)
        });
        if !permits {
            continue;
        }
        let (start, end) = match current.is_empty() {
            // No existing comment: insert directly above the assignment.
            true => (index, index),
            false => (block[skipped], block[skipped + current.len() - 1] + 1),
        };
        seeds.insert(key.clone(), seeded.seed_record());
        replacements.push((start, end, incoming.to_vec()));
        updated.push(key);
    }

    if replacements.is_empty() {
        return (original.to_owned(), updated);
    }
    // Reassemble: untouched lines re-emitted byte-for-byte, replaced
    // comment lines written in the file's own terminator.
    let mut out = String::with_capacity(original.len());
    let mut cursor = 0;
    for (start, end, replacement) in replacements {
        for row in &rows[cursor..start] {
            out.push_str(row.raw);
        }
        if start == end
            && start > 0
            && !rows[start - 1].text.trim().is_empty()
            && !table_row(&rows[start - 1])
        {
            out.push_str(eol);
        }
        for line in replacement {
            out.push_str(&line);
            out.push_str(eol);
        }
        cursor = end;
    }
    for row in &rows[cursor..] {
        out.push_str(row.raw);
    }
    (out, updated)
}

/// The template that speaks for a key: the recorded owner's when several
/// skills ship the key — declaration order must not shadow the ledger —
/// else the one [`super::writable_for`] chose.
///
/// Only a template that supplies a complete value is a candidate, on
/// either path. A template seeding could not write is not the one whose
/// comment belongs beside the key, and taking it here would let a broken
/// skill rewrite the prose above bytes another skill supplied.
fn template_for<'a>(
    key: &str,
    entries: &'a [SeededEnv],
    record: Option<&SettingsSeed>,
) -> Option<&'a SeededEnv> {
    let first = super::writable_for(entries, key)?;
    let Some(owner) = record.and_then(|record| record.owner.as_deref()) else {
        return Some(first);
    };
    if first.owner == owner {
        return Some(first);
    }
    entries
        .iter()
        .find(|seeded| seeded.entry.key == key && seeded.entry.complete() && seeded.owner == owner)
        .or(Some(first))
}

/// Adoption, not takeover: a block already matching the template enters
/// the ledger under this owner. Never over another owner's record; over a
/// v1 import (no owner) only while the text is provably what v1 seeded;
/// and never for an empty block — a bare key says nothing about who
/// wrote it, and claiming it would let a later template revision write
/// prose above a line the user typed.
fn adopt(
    key: &str,
    seeded: &SeededEnv,
    current: &[String],
    seeds: &mut BTreeMap<String, SettingsSeed>,
) {
    if current.is_empty() {
        return;
    }
    let claimable = match seeds.get(key) {
        None => true,
        Some(existing) => match existing.owner.as_deref() {
            Some(owner) => owner == seeded.owner,
            None => existing.hash == comment_hash(current),
        },
    };
    if claimable {
        seeds.insert(key.to_owned(), seeded.seed_record());
    }
}
