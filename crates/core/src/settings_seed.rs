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
//! Two kinds of newline meet in a seeded block and only one is the file's.
//! The terminators between entries and around the block belong to the
//! destination and take its spelling; the ones INSIDE a value are the
//! value's own content and go out exactly as the template wrote them. Both
//! spelled the destination's way, an LF template seeded into a CRLF file
//! hands the consumer a different string from the one it declared.
//!
//! Seeded comments stay current ([`refresh`]): the lock keeps, per key, the
//! FNV-1a hash of the comment block last written by seeding, and a key's
//! comment is rewritten to the template's revision only while its on-disk
//! text still hashes to that record — anything else is a hand edit,
//! preserved forever. Value lines are never touched, and every write here
//! is byte-faithful: comment-block bytes (and the inserted block on a
//! merge) are the only bytes that change, so CRLF files and
//! missing-terminator state survive untouched.

use crate::lock::SettingsSeed;
use crate::settings_toml::{Line, Row};

mod env;
mod notes;
mod refresh;
mod write;
pub use env::{EnvBlocked, env_blocked};
pub use notes::{conflict_notes, seed_notes, unterminated_notes};
pub use refresh::refresh_comments;
pub use write::{merge, record_seeds};

pub const SETTINGS_FILE: &str = "kendex.settings.toml";
pub const SETTINGS_TEMPLATE: &str = "kendex.settings.toml.example";
/// What a template writes after a value to mark the key as one the
/// consumer must answer: `LINEAR_TEAM = "" # required`. Cut off before the
/// assignment is written, so the word never reaches a consumer's file.
pub const REQUIRED_MARKER: &str = "required";
/// The settings file seeding targets in this project.
pub fn settings_file_path(project_root: &std::path::Path) -> std::path::PathBuf {
    project_root.join(SETTINGS_FILE)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvEntry {
    pub key: String,
    /// The comment block above the assignment, in file order.
    pub comment: Vec<String>,
    /// The whole assignment as the template spells it, from the `=` line
    /// through the line closing the value, with the newlines BETWEEN its
    /// lines exactly as written and none after the last. Empty where the
    /// template's value is not complete text seeding could copy.
    ///
    /// One string rather than a list of lines because a multiline value's
    /// newlines are its own content: re-joined in the destination file's
    /// terminator they would change the string the consumer reads. Held
    /// apart from the comment because which lines are the value is the
    /// walk's answer, not a count off one end of a list of both.
    pub assignment: String,
    /// Whether the template marks this key as one the consumer has to
    /// decide, which is the only reason an install writes a key into
    /// their file. Every other key ships a value its own code already
    /// reads, so writing it would put a line in a tracked file that
    /// changes nothing.
    pub required: bool,
}

impl EnvEntry {
    /// Whether the template spells this value out in full, which is
    /// whether there is anything here to write. Not the same as ending: a
    /// value can close, carry on, or break off mid-string, and only the
    /// first is text seeding may copy. A key with nothing complete behind
    /// it is refused by name rather than written half-finished.
    pub fn complete(&self) -> bool {
        !self.assignment.is_empty()
    }

    /// The line carrying the `=`, without its terminator. Empty for an
    /// entry with no complete value.
    pub fn opening(&self) -> &str {
        self.assignment.lines().next().unwrap_or("")
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
                // The marker is the template's own word and never the
                // consumer's: where it is there, the assignment is cut
                // back to its closing quote before anything is written.
                // Only a value that closes on this line can carry one, so
                // a multiline value has none to find.
                let marker = row.assignment().and_then(|(_, value, at)| {
                    let (offset, said) = crate::settings_toml::trailing_comment(value)?;
                    (said == REQUIRED_MARKER).then_some(at - row.at + offset)
                });
                // The assignment runs to wherever its value closes. Every
                // line under an open value is one the walk called
                // `InValue`, so the run is exactly this entry's.
                // Taken as raw bytes, terminators included: the newlines
                // between a value's lines are INSIDE the value, and a
                // reader that kept only the text would hand the writer
                // lines to re-join in the destination file's terminator,
                // rewriting the string's own content.
                let mut assignment = String::from(row.raw);
                let mut open = row.carries;
                let mut broken = row.broken;
                while open && index < rows.len() {
                    assignment.push_str(rows[index].raw);
                    open = rows[index].carries;
                    broken |= rows[index].broken;
                    index += 1;
                }
                // The terminator after the LAST line is not part of the
                // value — it separates this entry from the next, and the
                // destination file supplies it.
                assignment.truncate(crate::settings_toml::content_of(&assignment).len());
                // Complete means BOTH: the value closed, and no line of it
                // left a container the grammar cannot continue. Neither
                // implies the other — `TOKEN = "` carries nothing and is
                // still unfinished — and either alone would seed text that
                // does not parse.
                if open || broken {
                    assignment.clear();
                }
                if let Some(cut) = marker.filter(|_| !assignment.is_empty()) {
                    assignment.truncate(assignment[..cut].trim_end().len());
                }
                entries.push(EnvEntry {
                    key,
                    comment,
                    assignment,
                    required: marker.is_some(),
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

/// Every declaration seeding could write for this key, in declaration
/// order. The one gate on `complete()` for the purpose of choosing: no
/// consumer filters entries itself, so none can be left behind when the
/// rule changes.
///
/// Four consumers must agree on which declarations count — the bytes
/// `merge` writes, the owner [`record_seeds`] records, the template a
/// later comment refresh is gated on, and the defaults
/// [`conflict_notes`] compares. Derived separately, the rule was changed
/// in one and missed in the rest: a broken template declaring a key
/// before a valid one had the valid skill's bytes written under the
/// broken skill's name, and the notes reported a conflict between a
/// skill's real default and a broken one's empty one.
pub fn writable_all<'a>(
    entries: &'a [SeededEnv],
    key: &str,
) -> impl Iterator<Item = &'a SeededEnv> {
    entries
        .iter()
        .filter(move |seeded| seeded.entry.key == key && seeded.entry.complete())
}

/// The declaration that speaks for a key: the first one seeding can write
/// whole. `None` where no installed template spells the key's value out in
/// full, which is the case [`unterminated_notes`] owns.
pub fn writable_for<'a>(entries: &'a [SeededEnv], key: &str) -> Option<&'a SeededEnv> {
    writable_all(entries, key).next()
}

/// Why this pass may put a key in the consumer's file, which is the whole
/// of what an install writes there.
///
/// A template applies ONCE, when its skill arrives. What it writes then is
/// the keys it marks `# required` — the ones the consumer has to decide,
/// which have no answer a default could stand in for. Every later pass
/// over the same scope writes none of it, so a refresh leaves the file as
/// it found it and a key the consumer deleted stays deleted.
///
/// A save is the other reason. The app writes values for keys no seed ever
/// wrote, and a value needs an assignment to land on, so the keys one save
/// names are inserted by the same pass that then sets them.
#[derive(Debug, Default, Clone)]
pub struct Seeding {
    /// Skills whose template this pass applies: the ones arriving now.
    arriving: std::collections::BTreeSet<String>,
    /// Keys this pass is about to set a value on.
    edited: std::collections::BTreeSet<String>,
}

impl Seeding {
    pub fn new(
        arriving: impl IntoIterator<Item = String>,
        edited: impl IntoIterator<Item = String>,
    ) -> Self {
        Seeding {
            arriving: arriving.into_iter().collect(),
            edited: edited.into_iter().collect(),
        }
    }

    /// What one pass over a scope may write. A skill is arriving when the
    /// lock does not carry it yet: a name already there is one an earlier
    /// pass installed, so this pass is that skill's refresh and its
    /// template writes nothing.
    pub fn for_pass(
        entries: &[SeededEnv],
        installed: &std::collections::BTreeSet<String>,
        edited: impl IntoIterator<Item = String>,
    ) -> Self {
        Seeding::new(
            entries
                .iter()
                .map(|seeded| seeded.owner.clone())
                .filter(|owner| !installed.contains(owner)),
            edited,
        )
    }

    /// Whether this declaration is one the pass writes. The one statement
    /// of the rule: `merge` writes exactly what this admits and
    /// [`record_seeds`] records exactly what it chose, so the bytes and
    /// the ledger cannot come to different answers.
    fn writes(&self, seeded: &SeededEnv) -> bool {
        (seeded.entry.required && self.arriving.contains(&seeded.owner))
            || self.edited.contains(&seeded.entry.key)
    }
}

/// The declaration this pass writes for a key, or `None` where it writes
/// none. [`writable_all`] still supplies the candidates and their order,
/// so the choice stays the one chooser every consumer asks.
pub fn seeding_for<'a>(
    entries: &'a [SeededEnv],
    key: &str,
    seeding: &Seeding,
) -> Option<&'a SeededEnv> {
    writable_all(entries, key).find(|seeded| seeding.writes(seeded))
}

#[cfg(test)]
mod tests;
