//! One reader for the settings grammar, under every scan over it.
//!
//! Three readers walk these files — the strict template check
//! ([`crate::settings_template`]), seeding and its comment refresh
//! ([`crate::settings_seed`]), and the consumer-file view
//! ([`crate::settings_file`]). Each asks a different question, and all
//! three used to answer it a line at a time with no memory. A multiline
//! value carries its content on the lines after the one that opens it, and
//! a line-at-a-time reader calls that content structure: the interior of
//!
//! ```toml
//! [env]
//! BLOB = """
//! MODE = "shadow"
//! """
//! ```
//!
//! reads as an assignment of `MODE`. The check named a key that is not
//! there; seeding suppressed a key on the strength of it; and the view
//! showed `shadow` as a current value and handed an editor a byte span
//! inside `BLOB` to write over. That last one damages a file somebody
//! owns, which is why the memory lives here now instead of three times.
//!
//! What this settles is exactly one thing: **which lines are structure and
//! which are inside a value**, and where a structure line's top-level `=`
//! falls. What a table means, what a finding is, and which values the
//! shell loaders will read stay with the three callers, because they
//! differ on purpose — the check is strict where seeding is lenient.
//!
//! String state is what it tracks, in all four spellings, because a string
//! is the only thing that can put a byte offset inside a value. It does
//! not track array nesting: a multi-line array can make a `[` look like a
//! table header, and the worst that does is read a key as sitting outside
//! `[env]` — which refuses the edit. Nothing there can produce a span to
//! write into, so nothing there can damage a file.

use std::ops::Range;

/// What a line is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line<'a> {
    /// Empty, or only whitespace.
    Blank,
    /// Nothing but a comment.
    Comment,
    /// Opens with `[`. Callers judge the shape themselves; the reader only
    /// says the line is not an assignment.
    Table,
    /// A top-level assignment: the text either side of the first `=` that
    /// no string encloses, untrimmed, plus where the value starts within
    /// the line — carried rather than re-derived, so a span handed to an
    /// editor is measured from the same split that produced the value.
    Assignment {
        key: &'a str,
        value: &'a str,
        value_at: usize,
    },
    /// Inside a multiline value opened on an earlier line, or the line
    /// that closes one. Never structure, whatever it looks like.
    InValue,
    /// Structure the grammar has no name for — no `=`, no bracket.
    Other,
}

/// One line, with what it is and where it sits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row<'a> {
    /// 1-based.
    pub line: u32,
    /// The line as read, terminator included — what a byte-faithful
    /// splice re-emits for every line it does not touch.
    pub raw: &'a str,
    /// The same line without its terminator.
    pub text: &'a str,
    /// Byte offset of `text` in the source.
    pub at: usize,
    pub kind: Line<'a>,
}

impl Row<'_> {
    /// An assignment's key, its value, and the value's byte offset in the
    /// source. `None` for every other line.
    pub fn assignment(&self) -> Option<(&str, &str, usize)> {
        match self.kind {
            Line::Assignment {
                key,
                value,
                value_at,
            } => Some((key, value, self.at + value_at)),
            _ => None,
        }
    }
}

/// Which multiline string is open across a line boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Open {
    Basic,
    Literal,
}

impl Open {
    fn quote(self) -> u8 {
        match self {
            Open::Basic => b'"',
            Open::Literal => b'\'',
        }
    }

    /// Whether a backslash escapes the next byte in this kind of string.
    fn escapes(self) -> bool {
        self == Open::Basic
    }
}

/// Every line of the text, classified, in file order. One row per physical
/// line, so a caller that splices by index can index this instead.
pub fn rows(text: &str) -> Vec<Row<'_>> {
    let mut out = Vec::new();
    let mut at = 0;
    let mut open: Option<Open> = None;
    for (index, raw) in text.split_inclusive('\n').enumerate() {
        let content = content_of(raw);
        let kind = match open {
            // The line that closes a multiline is still part of the
            // assignment that opened it, so what follows the terminator on
            // it is that value's tail and never a new structure line.
            Some(kind) => {
                open = closes_at(content, kind).map_or(Some(kind), |_| None);
                Line::InValue
            }
            None => {
                let (kind, still) = classify(content);
                open = still;
                kind
            }
        };
        out.push(Row {
            line: line_number(index),
            raw,
            text: content,
            at,
            kind,
        });
        at += raw.len();
    }
    out
}

/// A line's content without its terminator.
pub fn content_of(line: &str) -> &str {
    line.strip_suffix('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .unwrap_or(line)
}

/// A 0-based index as the 1-based line a reader is shown. The app reads
/// these, and its boundary counts in 32 bits.
pub fn line_number(index: usize) -> u32 {
    u32::try_from(index + 1).unwrap_or(u32::MAX)
}

/// Classify one line that starts outside every string, and say which
/// multiline it leaves open.
fn classify(content: &str) -> (Line<'_>, Option<Open>) {
    let trimmed = content.trim_start();
    if trimmed.is_empty() {
        return (Line::Blank, None);
    }
    if trimmed.starts_with('#') {
        return (Line::Comment, None);
    }
    // A header opens no value: everything after the bracket is the
    // header's own business or a comment.
    if trimmed.starts_with('[') {
        return (Line::Table, None);
    }
    let Some((equals, open)) = top_level_equals(content) else {
        // A line with no `=` outside a string: junk, or the interior of an
        // array. Either way not an assignment — but a string it opened
        // still carries.
        return (Line::Other, scan(content, 0).1);
    };
    let (key, rest) = content.split_at(equals);
    (
        Line::Assignment {
            key,
            value: &rest[1..],
            value_at: equals + 1,
        },
        open,
    )
}

/// One line's assignment, for a caller holding a line rather than a file.
/// A line read on its own has no memory of a multiline opened above it, so
/// this is only for lines a [`rows`] walk already called an assignment.
pub fn assignment_of(content: &str) -> Option<(&str, &str)> {
    match classify(content_of(content)).0 {
        Line::Assignment { key, value, .. } => Some((key, value)),
        _ => None,
    }
}

/// The value with its quotes off, where the shell loaders read one. The
/// same judgment [`quoted_span`] makes, so the bytes an edit replaces and
/// the value a view shows can never be different characters.
pub fn decoded(value: &str) -> Option<String> {
    quoted_span(value, 0).map(|inner| value[inner].to_owned())
}

/// The byte offset of the first `=` no string encloses, and whatever
/// multiline the rest of the line leaves open. `None` where the line holds
/// no such `=`.
fn top_level_equals(content: &str) -> Option<(usize, Option<Open>)> {
    let bytes = content.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'=' => return Some((index, scan(content, index + 1).1)),
            // A comment before any `=`: there is no assignment here.
            b'#' => return None,
            b'"' | b'\'' => match string_at(content, index) {
                // A quoted key, stepped over whole.
                Some(end) => index = end,
                // A multiline opened where a key belongs, or a string with
                // no close: neither is an assignment this reader will hand
                // out a span for, and the state still has to carry.
                None => return None,
            },
            _ => index += 1,
        }
    }
    None
}

/// Walk from `from` to the end of the line, returning where it stopped and
/// which multiline it left open.
fn scan(content: &str, from: usize) -> (usize, Option<Open>) {
    let bytes = content.as_bytes();
    let mut index = from;
    while index < bytes.len() {
        match bytes[index] {
            b'#' => return (bytes.len(), None),
            b'"' | b'\'' => match string_at(content, index) {
                Some(end) => index = end,
                None => return (bytes.len(), opened_at(content, index)),
            },
            _ => index += 1,
        }
    }
    (bytes.len(), None)
}

/// The byte just past the string starting at `index`, or `None` where it
/// does not close on this line — a multiline that carries, or a single-line
/// string somebody left unterminated. An unterminated single-line string
/// is not TOML at all; it ends with its line here rather than swallowing
/// the rest of the file, which is what the grep-shaped shell loaders do
/// with it too.
fn string_at(content: &str, index: usize) -> Option<usize> {
    let bytes = content.as_bytes();
    let quote = bytes[index];
    let kind = match quote {
        b'"' => Open::Basic,
        _ => Open::Literal,
    };
    if bytes[index..].starts_with(&[quote, quote, quote]) {
        return closes_at(&content[index + 3..], kind).map(|end| index + 3 + end);
    }
    let mut cursor = index + 1;
    while cursor < bytes.len() {
        if kind.escapes() && bytes[cursor] == b'\\' {
            cursor += 2;
            continue;
        }
        if bytes[cursor] == quote {
            return Some(cursor + 1);
        }
        cursor += 1;
    }
    None
}

/// Which multiline the quote run at `index` opens, if it opens one.
fn opened_at(content: &str, index: usize) -> Option<Open> {
    let bytes = content.as_bytes();
    let quote = bytes[index];
    let kind = match quote {
        b'"' => Open::Basic,
        _ => Open::Literal,
    };
    bytes[index..]
        .starts_with(&[quote, quote, quote])
        .then_some(kind)
}

/// Where a multiline string of this kind closes within `content`, as the
/// byte just past its delimiter. A run of three to five quotes ends the
/// string — the last three are the delimiter and the extras are content —
/// so the whole run is stepped over.
fn closes_at(content: &str, kind: Open) -> Option<usize> {
    let bytes = content.as_bytes();
    let quote = kind.quote();
    let mut index = 0;
    while index < bytes.len() {
        if kind.escapes() && bytes[index] == b'\\' {
            index += 2;
            continue;
        }
        if bytes[index] != quote {
            index += 1;
            continue;
        }
        let run = bytes[index..].iter().take_while(|b| **b == quote).count();
        if run >= 3 {
            return Some(index + run);
        }
        index += run;
    }
    None
}

/// A key's two facts: the name two spellings of it share, and whether it
/// was written bare.
///
/// TOML reads `MODE`, `"MODE"` and `'MODE'` as one key, so all three block
/// a seed of `MODE` — inserting beside one of them would put the same key
/// in the file twice and stop it loading at all. The shell loaders match
/// the text as written, so only the bare spelling is one they read, and
/// the two facts have to travel together or a caller picks the wrong one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub name: String,
    pub quoted: bool,
}

/// The key an assignment's left-hand side names.
pub fn key_of(key: &str) -> Option<Key> {
    let trimmed = key.trim();
    let quoted = trimmed.strip_prefix('"').and_then(|r| r.strip_suffix('"'));
    let literal = trimmed
        .strip_prefix('\'')
        .and_then(|r| r.strip_suffix('\''));
    match quoted.or(literal) {
        Some(inner) => Some(Key {
            name: inner.to_owned(),
            quoted: true,
        }),
        None => (!trimmed.is_empty()).then(|| Key {
            name: trimmed.to_owned(),
            quoted: false,
        }),
    }
}

/// The byte range between the quotes of a value the shell loaders read —
/// one double-quoted string on one line, free of `"` and `\`, optionally
/// followed by a `#` comment. `at` is where `value` sits in the source.
/// `None` for every other shape, so a span is only ever produced for a
/// value this reader has already proven is a plain single-line string.
pub fn quoted_span(value: &str, at: usize) -> Option<Range<usize>> {
    let open = value.find('"')?;
    let rest = &value[open + 1..];
    let close = rest.find('"')?;
    let after = rest[close + 1..].trim_start();
    let closed = after.is_empty() || after.starts_with('#');
    let inner = &rest[..close];
    // Everything before the opening quote must be whitespace: a value that
    // starts with anything else is not a string the loaders read.
    (closed && value[..open].trim().is_empty() && !inner.contains('\\'))
        .then(|| at + open + 1..at + open + 1 + close)
}

#[cfg(test)]
mod tests;
