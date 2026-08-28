//! Reading one line's characters: which of them are inside a string, how
//! deep the arrays are, and where a value's quotes sit.
//!
//! Split from the row model above it because the two answer different
//! questions. This one never decides what a line IS — it only says what a
//! line leaves open and where its pieces are, which is the state every
//! classification depends on and none of them is allowed to compute for
//! itself.

use std::ops::Range;

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

/// What a value has left open across a line boundary — every container
/// the grammar can carry over one, in one value, so a walk cannot answer
/// for one and forget the other.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct Carry {
    /// The multiline string still open, if any.
    string: Option<Open>,
    /// How many arrays are open. Counted rather than flagged: arrays nest.
    arrays: usize,
}

impl Carry {
    /// Whether a line starting here is inside a value rather than being
    /// structure of its own.
    pub(super) fn inside(self) -> bool {
        self.string.is_some() || self.arrays > 0
    }
}

/// The byte offset of the first `=` no string encloses. `None` where the
/// line holds no such `=` — including a string opened where a key belongs,
/// which is not an assignment this reader will hand out a span for.
pub(super) fn top_level_equals(content: &str) -> Option<usize> {
    let bytes = content.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'=' => return Some(index),
            // A comment before any `=`: there is no assignment here.
            b'#' => return None,
            // A quoted key, stepped over whole.
            b'"' | b'\'' => index = string_at(content, index)?,
            _ => index += 1,
        }
    }
    None
}

/// Walk one line and return what it leaves open.
///
/// The one place a line's containers are read, so no classification arm
/// can drop them: an open string first, then the brackets and strings the
/// rest of the line opens and closes. A `#` outside a string ends the
/// line, and a stray `]` cannot take the depth below zero — an unbalanced
/// file is not TOML, and underflowing here would read the whole rest of
/// it as one value.
pub(super) fn advance(content: &str, carry: Carry) -> Carry {
    let mut carry = carry;
    let mut index = 0;
    if let Some(kind) = carry.string {
        match closes_at(content, kind) {
            Some(end) => {
                carry.string = None;
                index = end;
            }
            None => return carry,
        }
    }
    let bytes = content.as_bytes();
    while index < bytes.len() {
        match bytes[index] {
            b'#' => break,
            b'[' => {
                carry.arrays += 1;
                index += 1;
            }
            b']' => {
                carry.arrays = carry.arrays.saturating_sub(1);
                index += 1;
            }
            b'"' | b'\'' => match string_at(content, index) {
                Some(end) => index = end,
                None => {
                    carry.string = opened_at(content, index);
                    break;
                }
            },
            _ => index += 1,
        }
    }
    carry
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

/// A table header line, read once for everyone who asks about one.
///
/// Two questions live here and they have different answers, which is why
/// the two facts travel together: TOML says `[env] # note` opens the `env`
/// table, and the shell loaders — which match a lone `[name]` — refuse a
/// whole file that holds one. A caller taking the wrong fact either writes
/// into the wrong table or reports a key nothing reads as one that works.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header<'a> {
    /// The name between the brackets, as TOML reads it.
    pub name: &'a str,
    /// Whether the loaders read a header of this shape.
    pub lone: bool,
}

/// The header this line opens, or `None` where it opens none. The name is
/// read even from a shape the loaders refuse, so a table whose header has
/// a typo is still that table and a seed still lands inside it rather than
/// creating a second one beside it.
pub fn header_of(text: &str) -> Option<Header<'_>> {
    let trimmed = text.trim();
    let (name, after) = trimmed.strip_prefix('[')?.split_once(']')?;
    let named = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    named.then_some(Header {
        name,
        lone: after.trim().is_empty(),
    })
}
