//! Reading one line's characters: which of them are inside a string, how
//! deep the arrays and inline tables are, and where a value's quotes sit.
//!
//! Split from the row model above it because the two answer different
//! questions. This one never decides what a line IS — it only says what a
//! line leaves open, what it left unfinished, and where its pieces are,
//! which is the state every classification depends on and none of them is
//! allowed to compute for itself.

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

/// What one line leaves behind. Two facts, because the grammar splits its
/// containers in two: those a later line may close, and those it may not.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct Ends {
    /// What a line below this one starts inside — the containers a later
    /// line is allowed to close.
    pub(super) carry: Carry,
    /// Whether a container the grammar does NOT let cross a newline was
    /// still open at the end of this line: a single-line string, or an
    /// inline table. No later line may close either, so the value is
    /// broken where it stands and nothing about it is pending.
    ///
    /// The complement of [`Carry`], not its negation. Read closure from
    /// the absence of a carry alone and `TOKEN = "` and `MAP = {` both
    /// answer the same as a value that simply ended: closed.
    pub(super) broken: bool,
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

/// Walk one line and return what it leaves behind: the containers a later
/// line may close, and whether one it may not was left open.
///
/// The one place a line's containers are read, so no classification arm
/// can drop them: an open string first, then the brackets, braces and
/// strings the rest of the line opens and closes. A `#` outside a string
/// ends the line, and a stray `]` or `}` cannot take a depth below zero —
/// an unbalanced file is not TOML, and underflowing here would read the
/// whole rest of it as one value.
///
/// Every delimited form in the grammar is opened here and closed here, so
/// "was anything left open" is answered for all of them at once rather
/// than for the ones somebody remembered. See the module doc's table.
pub(super) fn advance(content: &str, carry: Carry) -> Ends {
    let mut carry = carry;
    let mut index = 0;
    if let Some(kind) = carry.string {
        match closes_at(content, kind) {
            Some(end) => {
                carry.string = None;
                index = end;
            }
            None => {
                return Ends {
                    carry,
                    broken: false,
                };
            }
        }
    }
    // Inline tables may not hold a newline, so their depth is counted for
    // this line alone and never joins the carry: one still open where the
    // line ends can never be closed.
    let mut tables = 0usize;
    let mut string_broken = false;
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
            b'{' => {
                tables += 1;
                index += 1;
            }
            b'}' => {
                tables = tables.saturating_sub(1);
                index += 1;
            }
            b'"' | b'\'' => match string_at(content, index) {
                Some(end) => index = end,
                None => {
                    // Opens a multiline, which carries — or a single-line
                    // string that never closes, which cannot.
                    carry.string = opened_at(content, index);
                    string_broken = carry.string.is_none();
                    break;
                }
            },
            _ => index += 1,
        }
    }
    Ends {
        carry,
        broken: string_broken || tables > 0,
    }
}

/// The byte just past the string starting at `index`, or `None` where it
/// does not close on this line — a multiline that carries, or a single-line
/// string somebody left unterminated. An unterminated single-line string
/// is not TOML at all; it ends with its line here rather than swallowing
/// the rest of the file, which is what the grep-shaped shell loaders do
/// with it too.
pub(super) fn string_at(content: &str, index: usize) -> Option<usize> {
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
/// the two facts travel together: TOML says `[env] # note`, `["env"]` and
/// `[ env ]` all open the `env` table, and the shell loaders — which grep
/// for the exact text `[env]` — read none of them but the first spelling.
/// A caller taking the wrong fact either writes into the wrong table or
/// reports a key nothing reads as one that works.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    /// The dotted key this header names, one entry per part, each
    /// decoded. `[a.b]` is two parts and `["a.b"]` is one, which TOML
    /// holds apart and so does this.
    pub path: Vec<String>,
    /// Whether the shell loaders read a header of this shape.
    pub lone: bool,
    /// An array-of-tables header, `[[name]]`. Not the table of that name:
    /// its assignments belong to an element, so a seed meant for `[env]`
    /// does not go under `[[env]]`.
    pub array: bool,
}

impl Header {
    /// Whether this header opens the top-level table with this name.
    pub fn opens(&self, name: &str) -> bool {
        !self.array && self.path.len() == 1 && self.path[0] == name
    }
}

/// The header this line opens, or `None` where it opens none.
///
/// Every spelling TOML gives a header, because the set is small and
/// closed and enumerating it is cheaper than meeting the next one as a
/// defect: brackets around a dotted key, each part written bare, in a
/// basic string or in a literal string, with whitespace allowed around
/// the parts and the dots, and the whole doubled for an array of tables.
/// A header holds a key and nothing else — no values, no `=` — so once
/// the key grammar is right there is nothing left to miss.
///
/// The name is read even from a shape the loaders refuse, so a table
/// whose header has a typo is still that table and a seed lands inside it
/// rather than creating a second one beside it.
pub fn header_of(text: &str) -> Option<Header> {
    let trimmed = text.trim();
    let rest = trimmed.strip_prefix('[')?;
    let (array, rest) = match rest.strip_prefix('[') {
        Some(rest) => (true, rest),
        None => (false, rest),
    };
    let (inside, after) = close_at(rest, array)?;
    let path = dotted_key(inside)?;
    let bare = !array && path.len() == 1 && inside == path[0];
    Some(Header {
        path,
        lone: bare && after.trim().is_empty(),
        array,
    })
}

/// Split a header's inside from what follows its closing bracket. The
/// close is found outside any string, so a `]` inside a quoted key part
/// does not end the header early.
fn close_at(rest: &str, array: bool) -> Option<(&str, &str)> {
    let bytes = rest.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'"' | b'\'' => index = string_at(rest, index)?,
            b']' => {
                let after = rest.get(index + 1..)?;
                return match array {
                    true => after.strip_prefix(']').map(|after| (&rest[..index], after)),
                    false => Some((&rest[..index], after)),
                };
            }
            _ => index += 1,
        }
    }
    None
}

/// A header's dotted key: its parts in order, each decoded. `None` where
/// any part is not a key TOML would accept. Split by the same reader an
/// assignment's key goes through, so a header and an assignment can never
/// disagree about where one name ends and the next begins.
fn dotted_key(inside: &str) -> Option<Vec<String>> {
    super::key::segments(inside)?
        .into_iter()
        .map(header_part)
        .collect()
}

/// One part of a dotted key. A quoted part is whatever it decoded to; a
/// bare one is held to TOML's bare key: letters, digits, underscore and
/// hyphen, and nothing else.
fn header_part(part: super::key::Segment) -> Option<String> {
    let bare_ok = part
        .name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'));
    (part.quoted || (bare_ok && !part.name.is_empty())).then_some(part.name)
}
