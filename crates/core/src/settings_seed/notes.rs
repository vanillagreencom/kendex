//! What the plan says about a set of entries before a byte is written.
//!
//! Split from the seeding beside it because the two answer different
//! questions. Nothing here decides what to write or where — it only says
//! what a person has to know about what seeding is about to do, or
//! decline to do, and every note is read on a terminal.

use std::collections::{BTreeMap, BTreeSet};

use crate::settings_file::{Current, current_of, lines_phrase};

use super::{SETTINGS_FILE, SeededEnv, Seeding};

/// What the consumer's file already says about the declared keys, in the
/// two views the notes need for the two different questions they ask.
///
/// Seeding's presence check is file-wide on purpose: a key some assignment
/// anywhere already names is a key nothing may add a second time. Whether
/// a person still has to ANSWER that key is a different question, and the
/// wide view answers it wrongly in one direction only — silently. An
/// assignment under `[other]`, spelled quoted or dotted, written twice, or
/// holding a value the loaders refuse occupies the name without answering
/// the key. Read as an answer it takes the note away from the one case
/// that needs it most: a required key nothing writes, because the name is
/// taken, and no script reads, because that line is not one they read.
///
/// So the notes never take a bare set of names. They take this, where each
/// view is labelled with the question it settles.
pub struct Answered {
    /// Where each declared key stands as a script reads it — the narrow
    /// view, and the only one that says whether the key is answered. Built
    /// through [`crate::settings_file::sites`] and [`current_of`], which
    /// is where the loaders' rules are already written down, rather than
    /// spelled a second time here to drift from them.
    reads: BTreeMap<String, Current>,
    /// Every key the file assigns anywhere — the wide view, which is what
    /// says whether a write can land on the name at all.
    occupied: BTreeSet<String>,
}

impl Answered {
    /// What this file says about every key the installed templates
    /// declare. A file kendex could not read answers nothing and occupies
    /// nothing, which is the true thing to say about one it cannot see
    /// into: every required key is reported unanswered.
    pub fn read(text: Option<&str>, entries: &[SeededEnv]) -> Self {
        let sites = text.map(crate::settings_file::sites).unwrap_or_default();
        Answered {
            reads: entries
                .iter()
                .map(|seeded| {
                    let key = seeded.entry.key.clone();
                    let stands = current_of(&sites, &key);
                    (key, stands)
                })
                .collect(),
            occupied: text
                .map(super::assigned_keys)
                .unwrap_or_default()
                .into_iter()
                .collect(),
        }
    }

    /// Where one key stands, for a key some template declares. `None` is
    /// a key nothing declares, which no note asks about — every note here
    /// is built from the declarations themselves.
    fn of(&self, key: &str) -> Option<&Current> {
        self.reads.get(key)
    }
}

/// What an assignment no script reads is worth saying, once: the reason
/// the loaders pass over it and the lines to look at. Both notes say it,
/// and a person reading either has the same thing to go and fix.
fn unread_at(problem: &str, lines: &[u32]) -> String {
    format!("{problem} ({})", lines_phrase(lines))
}

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
/// What the note says about the consequence depends on whether this pass
/// would write the key at all, and it asks [`super::written_for`] — the
/// same question `merge` asks — rather than deciding again. Most passes
/// write nothing, and a note claiming a seed on one of those names a value
/// that never arrives; where a pass does write, naming a different
/// declaration than the bytes came from names the wrong package.
///
/// Writing nothing has three consequences, not one, and which it is turns
/// on where the key stands in the file. An `[env]` line the loaders read
/// is the ordinary case on every pass after the consumer has set it: their
/// line is what their scripts read and no shipped default reaches them at
/// all, so telling them the scripts read whichever default they carry
/// sends them looking for a default to change instead of the line they
/// already own. An assignment the loaders pass over is neither of those —
/// the scripts fall back on their own defaults AND the line the person can
/// see does nothing, and only saying so sends them to the right one.
///
/// Key, owners and defaults are all catalog text a download supplied, so
/// the finished line goes through [`crate::names::shown`]: a note is read
/// on a terminal, and nothing in it is a sequence to act on.
pub fn conflict_notes(
    entries: &[SeededEnv],
    answered: &Answered,
    seeding: &Seeding,
) -> Vec<String> {
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
        .map(|(key, defaults)| {
            let shown: Vec<String> = defaults
                .iter()
                .map(|had| format!("{} ({})", had.shown, had.owners.join(", ")))
                .collect();
            // Whose value lands, where one does, is the chooser's answer
            // and never the first declaration: naming a skill whose bytes
            // this pass would not write points at a value that never
            // arrives. Where the pass writes none of them, what a person
            // reads instead is their own line if the loaders read one, and
            // only a package's carried default if they do not.
            let consequence = match super::written_for(entries, key, seeding, &answered.occupied) {
                Some(seeded) => format!(
                    "{}'s is the one written, so set the value yourself if that is not the one you want",
                    seeded.owner
                ),
                None => match answered.of(key) {
                    Some(Current::Value { .. }) => "this file already assigns it, so that value is what your scripts read and none of these defaults reaches them".to_owned(),
                    Some(Current::Ambiguous { problem, lines }) => format!(
                        "this file's assignment is not one your scripts read — {} — so what they read is whichever default they carry, and nothing here writes over the line that is there",
                        unread_at(problem, lines)
                    ),
                    _ => "nothing here writes this key, so what your scripts read is whichever default they carry, so set the value yourself if that is not the one you want".to_owned(),
                },
            };
            crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: packages ship different defaults — {} — {consequence}",
                shown.join(", ")
            ))
        })
        .collect()
}

/// What the plan says about a key a template marks `# required` that this
/// file does not answer and this pass will not write.
///
/// A template applies once, when its skill arrives, so a template that
/// gains a marked key after release reaches no consumer that already has
/// the skill. Nothing writes it into their file — that is the whole point
/// of the rule — so the gap is named on every pass instead, and it is
/// named for a key they deleted on purpose too, which is the honest thing
/// to say about a key the skill still wants answered.
///
/// Silent for two reasons and no third. The key has an answer the loaders
/// actually read, or this pass is about to write it — the arrival that
/// writes it has nothing to report, and neither does a save setting it.
///
/// Both halves are asked of the file rather than of the pass's intent. A
/// key the file names somewhere is a key seeding will not add, whatever
/// the pass meant to do, so an arrival that treated its own admission as
/// the answer would go quiet about the very key it is skipping. And a name
/// the file takes is not the same as a key it answers: an assignment under
/// another table, spelled quoted or dotted, written twice, or holding a
/// value the loaders refuse leaves the key as undecided as an empty file
/// does, so the note is still owed — and it says which line to go and fix
/// rather than claiming nothing assigns the key.
///
/// Key and owners are catalog text a download supplied, so the finished
/// line goes through [`crate::names::shown`] like every other note.
pub(super) fn unanswered_notes(
    entries: &[SeededEnv],
    answered: &Answered,
    seeding: &Seeding,
) -> Vec<String> {
    let mut by_key: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for seeded in entries {
        let key = seeded.entry.key.as_str();
        if !seeded.entry.required || matches!(answered.of(key), Some(Current::Value { .. })) {
            continue;
        }
        if super::written_for(entries, key, seeding, &answered.occupied).is_some() {
            continue;
        }
        by_key.entry(key).or_default().push(&seeded.owner);
    }
    by_key
        .into_iter()
        .map(|(key, owners)| {
            let standing = match answered.of(key) {
                Some(Current::Ambiguous { problem, lines }) => format!(
                    "this file's assignment is not one — {} — so set it yourself",
                    unread_at(problem, lines)
                ),
                _ => "nothing here assigns it — no default stands in for it, so set it yourself"
                    .to_owned(),
            };
            crate::names::shown(&format!(
                "{SETTINGS_FILE} {key}: {} needs this key decided and {standing}",
                owners.join(", ")
            ))
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
/// template, not a multiline one: a value that closes is complete text and
/// this note says nothing about it. Complete is not the same as written,
/// though. The marker can only follow a value that closes on its line, so
/// no arrival ever writes a multiline key, and a save naming one is
/// refused by the reader that sees no value in that shape.
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
/// keys several packages ship with different defaults, keys no template
/// can supply whole, and keys a template says the project must decide that
/// this file does not answer. One call so a caller cannot take part of the
/// answer — a note nobody asked for is a key silently left out.
pub fn seed_notes(entries: &[SeededEnv], answered: &Answered, seeding: &Seeding) -> Vec<String> {
    let mut notes = conflict_notes(entries, answered, seeding);
    notes.extend(unterminated_notes(entries));
    notes.extend(unanswered_notes(entries, answered, seeding));
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
