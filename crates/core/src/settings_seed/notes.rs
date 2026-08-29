//! What the plan says about a set of entries before a byte is written.
//!
//! Split from the seeding beside it because the two answer different
//! questions. Nothing here decides what to write or where — it only says
//! what a person has to know about what seeding is about to do, or
//! decline to do, and every note is read on a terminal.

use std::collections::BTreeMap;

use super::{SETTINGS_FILE, SeededEnv};

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

/// What the plan says about a key seeding will not write at all: a
/// template whose value opens something nothing closes. That is an
/// unterminated template, not a multiline one — a value that closes is
/// seeded whole, however many lines it takes. There is no complete text to
/// copy here, and the opening line alone would leave the consumer's file
/// unparseable from there down, so the key is refused and named rather
/// than dropped in silence.
///
/// Only a key NO installed template can supply is named: where one skill
/// ships it broken and another ships it whole, [`super::merge`] seeds the whole
/// one and there is nothing for a person to do.
///
/// Key and owners are catalog text a download supplied, so the finished
/// line goes through [`crate::names::shown`] like every other note.
pub fn unterminated_notes(entries: &[SeededEnv]) -> Vec<String> {
    // Per key: whether any declaration closes, and who ships the ones
    // that do not. Key order is the file's, so the notes read stably.
    let mut by_key: BTreeMap<&str, (bool, Vec<&str>)> = BTreeMap::new();
    for seeded in entries {
        let (closes, owners) = by_key.entry(&seeded.entry.key).or_default();
        match seeded.entry.closes() {
            true => *closes = true,
            false => owners.push(&seeded.owner),
        }
    }
    by_key
        .into_iter()
        .filter(|(_, (closes, _))| !closes)
        .map(|(key, (_, owners))| {
            crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: {}'s template opens a value nothing closes, so there is no complete default to seed and nothing was written for this key — fix the template, or set the key yourself",
                owners.join(", ")
            ))
        })
        .collect()
}

/// Everything the plan says about these entries before a byte is written:
/// keys several packages ship with different defaults, and keys no
/// template can supply whole. One call so a caller cannot take half the
/// answer — a note nobody asked for is a key silently left out.
pub fn seed_notes(entries: &[SeededEnv]) -> Vec<String> {
    let mut notes = conflict_notes(entries);
    notes.extend(unterminated_notes(entries));
    notes
}
