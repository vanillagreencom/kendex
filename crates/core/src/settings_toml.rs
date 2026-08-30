//! One reader for the settings grammar, under every scan over it.
//!
//! Three readers walk these files — the strict template check
//! ([`crate::settings_template`]), seeding ([`crate::settings_seed`]),
//! and the consumer-file view
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
//! What this settles is **which lines are structure and which are inside a
//! value**, where a structure line's top-level `=` falls, and **whether a
//! line left a value unfinished**. What a table means, what a finding is,
//! and which values the shell loaders will read stay with the three
//! callers, because they differ on purpose — the check is strict where
//! seeding is lenient.
//!
//! ## Where every value form can end
//!
//! Enumerated from the value grammar of the spec the workspace's `toml`
//! dependency implements — the root `Cargo.toml` is where that is chosen,
//! and this table has to be re-read against it whenever it moves. Written
//! out whole rather than a form at a time: a form left off it reads as
//! finished and is copied into somebody's file, and one filed in the wrong
//! column is refused though the parser accepts it. A value is exactly one
//! of string, integer, float, boolean, one of the five date-time forms,
//! array, or inline table. Each either has delimiters or does not, and each
//! delimited one may cross a newline or may not:
//!
//! | Form                      | Delimiter | Crosses a newline |
//! |---------------------------|-----------|-------------------|
//! | Multi-line basic string   | `"""`     | yes, carried      |
//! | Multi-line literal string | `'''`     | yes, carried      |
//! | Array                     | `[` `]`   | yes, carried      |
//! | Inline table              | `{` `}`   | yes, carried      |
//! | Single-line string        | `"` `'`   | no, breaks        |
//! | Integer, float, boolean   | none      | cannot be open    |
//! | The five date-time forms  | none      | cannot be open    |
//!
//! Arrays and inline tables are carried by depth rather than by a flag,
//! because a flag cannot say how deep and a nested `[` is not a table
//! header. Depth is also why nothing here is a rule per form: an array
//! inside an inline table, or a table inside an array, closes when its own
//! delimiter does, like any other. A scalar is one token holding none of
//! `[`, `]`, `{`, `}`, `"`, `'`, `#` or `=`, so none can be mistaken for
//! structure, conceal it, or be left open.
//!
//! That is the whole of the value grammar, so both sets are closed: four
//! forms carry, one breaks where its line ends, and the scalars cannot be
//! open at all. A value is COMPLETE only where the line it ended on left
//! neither kind open — which is why a row carries the two as separate
//! facts and neither is the other's negation. A container the file never
//! closes carries to the end and is incomplete there. A form this table
//! cannot answer for is a gap to name here, never a silent default of
//! complete.
//!
//! Every claim in this table has a control in `tests.rs`. This file goes
//! wrong in a comment before it goes wrong in code, so the table is the
//! thing to re-read against the spec first.
//!
//! What a line leaves open is read off it once, apart from the decision
//! about what the line is, because the two are independent — a line can
//! open a table and a string at the same time. Answering the second inside
//! the arms that answer the first is how the interior of a value came back
//! as an assignment with a writable span.
//!
//! Not closed: a hard link is a file here as everywhere, and an
//! unterminated container leaves the rest of the file reading as one
//! value — which is what an unparseable file is.

mod key;
mod walk;
pub use key::{Key, key_of};
use walk::{Carry, advance, top_level_equals};
pub use walk::{Header, header_of, quoted_span};

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
    /// Whether this line leaves a value open — the same fact
    /// [`Line::InValue`] tells about the lines below it, told from the
    /// line that opened it. Both tellings are needed: a caller holding an
    /// assignment cannot ask the line under it whether the value closed
    /// when the file ends there.
    pub carries: bool,
    /// Whether this line ends inside a delimiter no later line may close.
    /// Only a single-line string can be one: the grammar ends it with its
    /// line, so nothing below it can finish it. Every other container
    /// carries instead, and one the file never closes carries to the end
    /// of the file — [`Row::carries`] is what answers for those.
    ///
    /// The complement of [`Row::carries`], never its negation: both are
    /// false for a value that simply ended, and `TOKEN = "` carries
    /// nothing and is not finished either. A value is complete only where
    /// neither is true of it.
    pub broken: bool,
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

/// Every line of the text, classified, in file order. One row per physical
/// line, so a caller that splices by index can index this instead.
pub fn rows(text: &str) -> Vec<Row<'_>> {
    let mut out = Vec::new();
    let mut at = 0;
    let mut carry = Carry::default();
    for (index, raw) in text.split_inclusive('\n').enumerate() {
        let content = content_of(raw);
        // What the line is, and what it leaves open, are answered apart:
        // a line inside a value is never classified at all, and every
        // line advances the carry whatever it turned out to be.
        let kind = match carry.inside() {
            true => Line::InValue,
            false => kind_of(content),
        };
        let ends = advance(content, carry);
        carry = ends.carry;
        out.push(Row {
            line: line_number(index),
            raw,
            text: content,
            at,
            kind,
            carries: carry.inside(),
            broken: ends.broken,
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

/// What the line is, given that nothing is open above it.
fn kind_of(content: &str) -> Line<'_> {
    let trimmed = content.trim_start();
    if trimmed.is_empty() {
        return Line::Blank;
    }
    // A `#` out here comments the rest of the line, so nothing after it
    // is read — which is also why a `#` inside a multiline never reaches
    // this arm: a line inside one is [`Line::InValue`] and never
    // classified at all.
    if trimmed.starts_with('#') {
        return Line::Comment;
    }
    if trimmed.starts_with('[') {
        return Line::Table;
    }
    let Some(equals) = top_level_equals(content) else {
        // No `=` outside a string: junk, or the interior of an array.
        return Line::Other;
    };
    let (key, rest) = content.split_at(equals);
    Line::Assignment {
        key,
        value: &rest[1..],
        value_at: equals + 1,
    }
}

/// One line's assignment, for a caller holding a line rather than a file.
/// A line read on its own has no memory of a multiline opened above it, so
/// this is only for lines a [`rows`] walk already called an assignment.
pub fn assignment_of(content: &str) -> Option<(&str, &str)> {
    match kind_of(content_of(content)) {
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

/// What a readable value carries after itself, without the `#`, and where
/// on the line it starts. `None` where the line ends at the closing quote,
/// or where the value is not one [`quoted_span`] reads at all.
///
/// The offset comes back with the text because a caller that strips the
/// comment has to cut the line, and re-finding the `#` would find the
/// first one on the line — which, in `KEY = "a # b" # note`, sits inside
/// the value.
pub fn trailing_comment(value: &str) -> Option<(usize, &str)> {
    let inner = quoted_span(value, 0)?;
    let after = &value[inner.end + 1..];
    let at = after.find('#')?;
    Some((inner.end + 1 + at, after[at + 1..].trim()))
}

#[cfg(test)]
mod tests;
