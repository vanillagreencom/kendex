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
/// it. `merge` writes one declaration and says nothing about the others,
/// so a disagreement about what a key should be is invisible anywhere
/// else — and packages agreeing on a shared key, which is the ordinary
/// case, say nothing at all.
///
/// The groups are built from the writable declarations, the same
/// selection `merge` seeds from, so the defaults compared here are the
/// ones that could actually land. A declaration whose value its template
/// never completes ships no default to disagree with and is reported by
/// [`unterminated_notes`] instead.
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
    //
    // The declarations come from `writable_all`, the same selection every
    // other consumer takes, rather than from a filter of this loop's own.
    // An incomplete declaration ships no default to disagree with — it
    // grouped as an empty one and reported two skills as conflicting when
    // only one of them had said anything.
    let mut by_key: BTreeMap<&str, Vec<Shipped>> = BTreeMap::new();
    for key in entries.iter().map(|seeded| seeded.entry.key.as_str()) {
        let defaults = by_key.entry(key).or_default();
        if !defaults.is_empty() {
            continue;
        }
        for seeded in super::writable_all(entries, key) {
            let identity = seeded.default_key();
            match defaults.iter_mut().find(|had| had.identity == identity) {
                Some(had) => had.owners.push(&seeded.owner),
                None => defaults.push(Shipped {
                    identity,
                    shown: seeded.default_shown(),
                    owners: vec![&seeded.owner],
                }),
            }
        }
    }
    by_key
        .into_iter()
        .filter(|(_, defaults)| defaults.len() > 1)
        .filter_map(|(key, defaults)| {
            // Whose value lands is `writable_for`'s answer, never the
            // first declaration: naming a skill whose template seeding
            // could not write would point at bytes that never arrived.
            // With no writable declaration nothing is seeded at all, and
            // `unterminated_notes` is the note that belongs to that key.
            let lands = &super::writable_for(entries, key)?.owner;
            let shown: Vec<String> = defaults
                .iter()
                .map(|had| format!("{} ({})", had.shown, had.owners.join(", ")))
                .collect();
            Some(crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: packages ship different defaults — {} — where this file does not already assign it, {lands}'s is the one seeded, so set the value yourself if that is not the one you want",
                shown.join(", ")
            )))
        })
        .collect()
}

/// One distinct default under a key: what tells it apart, what a person
/// reads, and everyone who ships it. Identity and display are held apart
/// because they answer different questions — see
/// [`SeededEnv::default_key`].
struct Shipped<'a> {
    identity: String,
    shown: String,
    owners: Vec<&'a str>,
}

/// What the plan says about a key seeding will not write at all: a
/// template that never finishes the value. That is an unterminated
/// template, not a multiline one — a value that closes is seeded whole,
/// however many lines it takes.
///
/// Which delimiter was left open is deliberately not named. Completeness
/// comes off the enumerated grammar in [`crate::settings_toml`], so a form
/// added there would leave a list here stale, and the message would send
/// somebody to the wrong part of their template. The key name is what
/// tells them where to look. There is no complete text to copy whatever
/// the shape, and writing what there is would leave the consumer's file
/// unparseable from that line down, so the key is refused and named
/// rather than dropped in silence.
///
/// Only a key NO installed template can supply is named: where one skill
/// ships it broken and another ships it whole, [`super::merge`] seeds the whole
/// one and there is nothing for a person to do.
///
/// Key and owners are catalog text a download supplied, so the finished
/// line goes through [`crate::names::shown`] like every other note.
pub fn unterminated_notes(entries: &[SeededEnv]) -> Vec<String> {
    // Per key: whether any declaration is complete, and who ships the
    // ones that are not. Key order is the file's, so notes read stably.
    let mut by_key: BTreeMap<&str, (bool, Vec<&str>)> = BTreeMap::new();
    for seeded in entries {
        let (complete, owners) = by_key.entry(&seeded.entry.key).or_default();
        match seeded.entry.complete() {
            true => *complete = true,
            false => owners.push(&seeded.owner),
        }
    }
    by_key
        .into_iter()
        .filter(|(_, (complete, _))| !complete)
        .map(|(key, (_, owners))| {
            crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: {}'s template never finishes this value — it opens something that is never closed — so there is no complete default to seed and nothing was written for this key; fix the template, or set the key yourself",
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

/// How a default reads and how two are told apart. Here rather than
/// beside the entry itself because a note is the only thing that asks:
/// seeding writes the template's own lines and never a rendering of
/// them.
impl SeededEnv {
    /// The default this entry ships, spelled the way a note shows it: the
    /// decoded value in quotes, or the assignment's right-hand side
    /// verbatim where the strict reader cannot decode it. Every entry
    /// `merge` seeds has one, so a note can never drop an owner and then
    /// name the wrong package as the one whose value lands.
    ///
    /// A value spanning lines is shown on the note's one line, its lines
    /// joined by a space. Shown from the `=` line alone every multiline
    /// value would read as its bare opening delimiter, and two packages
    /// shipping different ones would be grouped as agreeing — the note
    /// exists to say they disagree.
    pub(super) fn default_shown(&self) -> String {
        match self.decoded() {
            Some(value) => format!("\"{value}\""),
            None => self
                .raw_default()
                .map(str::trim)
                .collect::<Vec<&str>>()
                .join(" "),
        }
    }

    /// What tells two defaults apart. [`SeededEnv::default_shown`] is for
    /// reading and collapses a value's lines onto one, which two different
    /// values can share: a multiline holding `a\nb` and one holding `a b`
    /// display alike. Grouped on that text, two skills shipping genuinely
    /// different values are reported as agreeing — the one disagreement
    /// [`conflict_notes`] exists to catch. So comparison keeps the value
    /// as the template spells it, and only the display collapses.
    ///
    /// A decodable value still compares decoded, so `X = "a"` and
    /// `X = "a" # note` stay one default rather than two.
    pub(super) fn default_key(&self) -> String {
        match self.decoded() {
            Some(value) => format!("\"{value}\""),
            None => self.raw_default().collect::<Vec<&str>>().join("\n"),
        }
    }

    /// The default where the strict reader can read one: a plain one-line
    /// double-quoted string.
    fn decoded(&self) -> Option<String> {
        crate::settings_template::decoded_value(self.entry.opening())
    }

    /// The assignment's right-hand side, line by line, as written. The
    /// opening line's is trimmed of the space after its `=`; every line
    /// after it is the value's own text and is left alone.
    fn raw_default(&self) -> impl Iterator<Item = &str> {
        let mut lines = self.entry.assignment.lines();
        let opening = lines.next().unwrap_or("");
        let right = opening.split_once('=').map_or(opening, |(_, value)| value);
        std::iter::once(right.trim()).chain(lines)
    }
}
