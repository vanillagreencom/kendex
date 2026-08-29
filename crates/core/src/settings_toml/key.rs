//! What a key names, and which spellings of it are the same key.
//!
//! Two questions with different answers, and a caller that takes one for
//! the other writes a defect. TOML reads `MODE`, `"MODE"`, `'MODE'` and
//! `"MO\u0044E"` as one key, so all four block a seed of `MODE` —
//! inserting beside any of them puts the key in the file twice and stops
//! it loading at all. The shell loaders match the text as written against
//! a shell identifier, so only the bare spelling is one they read. Both
//! facts travel together on [`Key`] rather than a caller picking whichever
//! it happened to have.
//!
//! A key's left-hand side is a PATH, not a name: `env.MODE` declares the
//! table `env` and puts `MODE` inside it, so the name it occupies where it
//! sits is `env` and a seed of `env` beside it defines that name twice.
//! Read as one literal name the path occupies neither `env` nor `MODE`,
//! and a seed lands beside it and stops the file parsing. So the path is
//! parsed here, once, and every caller reads the part of it that answers
//! its own question.

use super::walk::string_at;

/// One segment of a key's path: the name it decodes to, and whether it
/// was written between quotes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Segment {
    pub(super) name: String,
    pub(super) quoted: bool,
}

/// A key's two facts: the name two spellings of it share, and whether it
/// was written bare — plus the path hanging below that name.
///
/// TOML reads `MODE`, `"MODE"` and `'MODE'` as one key, so all three block
/// a seed of `MODE` — inserting beside one of them would put the same key
/// in the file twice and stop it loading at all. The shell loaders match
/// the text as written, so only the bare spelling is one they read, and
/// the two facts have to travel together or a caller picks the wrong one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    /// The first segment's name: what this key declares where it sits. A
    /// dotted key declares a table under that name, so it occupies the
    /// name exactly as a plain assignment of it would.
    pub name: String,
    /// Whether the first segment was written between quotes.
    pub quoted: bool,
    /// The segments below the first, in order, each decoded. Empty unless
    /// the key is dotted, and never what a name is matched on: what a
    /// path holds below its own name is that table's business.
    pub under: Vec<String>,
}

impl Key {
    /// Whether this key is a dotted path. A dotted key is a table
    /// declaration, so neither the shell loaders — which read no dotted
    /// key at all — nor a value edit has anything to say about it.
    pub fn dotted(&self) -> bool {
        !self.under.is_empty()
    }
}

/// The key an assignment's left-hand side names.
///
/// A basic key decodes its escapes, because TOML reads `"MO\u0044E"` and
/// `MODE` as one key and seeding beside one of them would put that key in
/// the file twice. A literal key processes no escapes at all — TOML says
/// so — so only the basic form is decoded, and `'MO\u0044E'` is a
/// different key from `MODE`, exactly as the loaders and the parser both
/// read it.
pub fn key_of(key: &str) -> Option<Key> {
    let mut path = segments(key)?.into_iter();
    let first = path.next()?;
    Some(Key {
        name: first.name,
        quoted: first.quoted,
        under: path.map(|segment| segment.name).collect(),
    })
}

/// A dotted key's segments, in order, each decoded by its own spelling
/// rules. `None` where any segment is not a key TOML would accept, since
/// half a path names nothing.
///
/// The separator is a `.` no string encloses: `"a.b"` is one segment whose
/// name holds a dot, and `a.b` is two. TOML holds those apart and so does
/// this, or a quoted name would silently occupy somebody else's.
pub(super) fn segments(key: &str) -> Option<Vec<Segment>> {
    let mut out = Vec::new();
    let bytes = key.as_bytes();
    let mut start = 0;
    let mut index = 0;
    while index <= bytes.len() {
        if index == bytes.len() || bytes[index] == b'.' {
            out.push(segment_of(&key[start..index])?);
            start = index + 1;
            index += 1;
            continue;
        }
        index = match bytes[index] {
            b'"' | b'\'' => string_at(key, index)?,
            _ => index + 1,
        };
    }
    Some(out)
}

/// One segment, with its quotes off and its escapes decoded where its
/// spelling decodes them.
fn segment_of(text: &str) -> Option<Segment> {
    let trimmed = text.trim();
    if let Some(inner) = trimmed.strip_prefix('"').and_then(|r| r.strip_suffix('"')) {
        return Some(Segment {
            name: unescape(inner),
            quoted: true,
        });
    }
    if let Some(inner) = trimmed
        .strip_prefix('\'')
        .and_then(|r| r.strip_suffix('\''))
    {
        return Some(Segment {
            name: inner.to_owned(),
            quoted: true,
        });
    }
    (!trimmed.is_empty()).then(|| Segment {
        name: trimmed.to_owned(),
        quoted: false,
    })
}

/// A basic string's escapes, decoded. An escape TOML does not define is
/// kept as it was written: the file does not parse either way, and
/// dropping it would let a key stop blocking the seed of its own spelling.
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let Some(escape) = chars.next() else {
            out.push('\\');
            break;
        };
        match escape {
            'b' => out.push('\u{8}'),
            't' => out.push('\t'),
            'n' => out.push('\n'),
            'f' => out.push('\u{c}'),
            'r' => out.push('\r'),
            '"' => out.push('"'),
            '\\' => out.push('\\'),
            'u' | 'U' => match code_point(&mut chars, if escape == 'u' { 4 } else { 8 }) {
                Some(decoded) => out.push(decoded),
                None => {
                    out.push('\\');
                    out.push(escape);
                }
            },
            other => {
                out.push('\\');
                out.push(other);
            }
        }
    }
    out
}

/// The character `width` hex digits spell, consuming them only when they
/// spell one.
fn code_point(chars: &mut std::str::Chars, width: usize) -> Option<char> {
    let rest = chars.as_str();
    let digits = rest.get(..width)?;
    let decoded = char::from_u32(u32::from_str_radix(digits, 16).ok()?)?;
    *chars = rest[width..].chars();
    Some(decoded)
}
