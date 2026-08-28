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
///
/// A basic key decodes its escapes, because TOML reads `"MO\u0044E"` and
/// `MODE` as one key and seeding beside one of them would put that key in
/// the file twice. A literal key processes no escapes at all — TOML says
/// so — so only the basic form is decoded, and `'MO\u0044E'` is a
/// different key from `MODE`, exactly as the loaders and the parser both
/// read it.
pub fn key_of(key: &str) -> Option<Key> {
    let trimmed = key.trim();
    if let Some(inner) = trimmed.strip_prefix('"').and_then(|r| r.strip_suffix('"')) {
        return Some(Key {
            name: unescape(inner),
            quoted: true,
        });
    }
    if let Some(inner) = trimmed
        .strip_prefix('\'')
        .and_then(|r| r.strip_suffix('\''))
    {
        return Some(Key {
            name: inner.to_owned(),
            quoted: true,
        });
    }
    (!trimmed.is_empty()).then(|| Key {
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
