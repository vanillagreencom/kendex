//! Reading a Rust file as far as one question goes: which bytes of a line
//! the file names a switch in, and which it runs or emits.
//!
//! A comment names its text: a line comment, a doc comment, and a block
//! comment, which nests. Every other byte of shipped code counts, and a
//! string literal above all: Rust hands a process its arguments as string
//! literals, so a literal in shipped code is what the package runs or
//! emits.
//!
//! Test code is told by where it stands. The item under the exact
//! attribute `#[cfg(test)]` is compiled into tests alone, from the
//! attribute to the `}` closing its body or the `;` ending it before any
//! body, and every line of a file under a test directory is test code.
//! There the reader cannot tell a literal a test hands a stub from one it
//! hands a process, so all of it is the test's data.
//!
//! Strings, raw and byte strings and char literals are read so that a
//! `//`, a `"` or a `}` inside one opens or closes nothing; a `'` that
//! starts no char literal is a lifetime or a label.
//!
//! Every reading errs toward the code. Any other spelling of the attribute
//! (`cfg(not(test))`, `cfg(all(test, ..))`, one with spaces) is code, and a
//! file that ends inside a comment, a string or a test item, closes a
//! bracket it never opened inside one, or holds a char literal the reader
//! cannot close names nothing at all.

use super::{Quotation, Span};

/// The one spelling of the attribute that makes an item test code.
const TEST_ATTRIBUTE: &[u8] = b"#[cfg(test)]";

/// The literal prefixes that open a raw string.
const RAW: &[&[u8]] = &[b"r", b"br", b"cr"];

/// Each line's named ranges, one list per line of `lines`: in a file under
/// a test directory every line whole, as a test's data; in any other file
/// each comment, and each `#[cfg(test)]` item as a test's data.
pub fn quoted(lines: &[&str], tests: bool) -> Vec<Vec<Span>> {
    if tests {
        return lines
            .iter()
            .map(|line| {
                vec![Span {
                    start: 0,
                    end: line.len(),
                    by: Quotation::Fixture,
                }]
            })
            .collect();
    }
    read(lines).unwrap_or_else(|| vec![Vec::new(); lines.len()])
}

/// Where the lexer stands between two bytes.
#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Code,
    /// Inside a block comment, at this nesting depth.
    Block(usize),
    /// Inside a string, a byte string or a C string, where `\` escapes.
    Str,
    /// Inside a raw string closed by `"` and this many `#`.
    Raw(usize),
}

/// A `#[cfg(test)]` item being read: where its attribute stands, how deep
/// its brackets are open, and whether its body's `{` has opened.
struct Item {
    from: (usize, usize),
    depth: usize,
    body: bool,
}

/// The spans of a file that lexes to its end, or `None` where it does not.
fn read(lines: &[&str]) -> Option<Vec<Vec<Span>>> {
    let mut found: Vec<Vec<Span>> = vec![Vec::new(); lines.len()];
    let mut state = State::Code;
    let mut item: Option<Item> = None;
    for (number, line) in lines.iter().enumerate() {
        let s = line.as_bytes();
        let mut comment = matches!(state, State::Block(_)).then_some(0);
        let mut i = 0;
        while i < s.len() {
            let rest = &s[i..];
            match state {
                State::Block(depth) if rest.starts_with(b"/*") => {
                    state = State::Block(depth + 1);
                    i += 2;
                }
                State::Block(depth) if rest.starts_with(b"*/") => {
                    i += 2;
                    state = match depth {
                        1 => {
                            if let Some(start) = comment.take() {
                                found[number].push(Span {
                                    start,
                                    end: i,
                                    by: Quotation::Comment,
                                });
                            }
                            State::Code
                        }
                        _ => State::Block(depth - 1),
                    };
                }
                State::Block(_) => i += 1,
                State::Str => match s[i] {
                    b'\\' => i += 2,
                    b'"' => {
                        state = State::Code;
                        i += 1;
                    }
                    _ => i += 1,
                },
                State::Raw(hashes) => {
                    let closes = s[i] == b'"'
                        && s.len() > i + hashes
                        && s[i + 1..=i + hashes].iter().all(|b| *b == b'#');
                    match closes {
                        true => {
                            state = State::Code;
                            i += 1 + hashes;
                        }
                        false => i += 1,
                    }
                }
                State::Code if rest.starts_with(b"//") => {
                    found[number].push(Span {
                        start: i,
                        end: s.len(),
                        by: Quotation::Comment,
                    });
                    i = s.len();
                }
                State::Code if rest.starts_with(b"/*") => {
                    state = State::Block(1);
                    comment = Some(i);
                    i += 2;
                }
                State::Code if item.is_none() && rest.starts_with(TEST_ATTRIBUTE) => {
                    item = Some(Item {
                        from: (number, i),
                        depth: 0,
                        body: false,
                    });
                    i += TEST_ATTRIBUTE.len();
                }
                State::Code => match s[i] {
                    b'"' => {
                        state = State::Str;
                        i += 1;
                    }
                    b'\'' => i = past_quote(line, i)?,
                    b if b.is_ascii_alphanumeric() || b == b'_' => {
                        let start = i;
                        while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'_') {
                            i += 1;
                        }
                        let hashes = s[i..].iter().take_while(|b| **b == b'#').count();
                        if RAW.contains(&&s[start..i]) && s.get(i + hashes) == Some(&b'"') {
                            state = State::Raw(hashes);
                            i += hashes + 1;
                        }
                    }
                    b'{' | b'(' | b'[' => {
                        if let Some(open) = item.as_mut() {
                            open.body |= open.depth == 0 && s[i] == b'{';
                            open.depth += 1;
                        }
                        i += 1;
                    }
                    b'}' | b')' | b']' => {
                        i += 1;
                        if let Some(open) = item.as_mut() {
                            open.depth = open.depth.checked_sub(1)?;
                            if open.depth == 0 && open.body && s[i - 1] == b'}' {
                                let from = open.from;
                                mark(&mut found, lines, from, (number, i));
                                item = None;
                            }
                        }
                    }
                    b';' => {
                        i += 1;
                        if let Some(open) =
                            item.as_ref().filter(|open| open.depth == 0 && !open.body)
                        {
                            let from = open.from;
                            mark(&mut found, lines, from, (number, i));
                            item = None;
                        }
                    }
                    _ => i += 1,
                },
            }
        }
        if let Some(start) = comment {
            found[number].push(Span {
                start,
                end: s.len(),
                by: Quotation::Comment,
            });
        }
    }
    (state == State::Code && item.is_none()).then_some(found)
}

/// Past the `'` at `at`: a char literal's closing quote, or the `'` alone
/// where it starts a lifetime or a label. `None` for an escape that does
/// not close on its line.
fn past_quote(line: &str, at: usize) -> Option<usize> {
    let s = line.as_bytes();
    if s.get(at + 1) == Some(&b'\\') {
        let close = s.get(at + 3..)?.iter().position(|b| *b == b'\'')?;
        return Some(at + 3 + close + 1);
    }
    let width = line[at + 1..].chars().next().map_or(0, char::len_utf8);
    match width > 0 && s.get(at + 1 + width) == Some(&b'\'') {
        true => Some(at + 2 + width),
        false => Some(at + 1),
    }
}

/// Mark the bytes from `from` to `to`, each a line and a byte offset, as a
/// test's data.
fn mark(found: &mut [Vec<Span>], lines: &[&str], from: (usize, usize), to: (usize, usize)) {
    for number in from.0..=to.0 {
        let start = if number == from.0 { from.1 } else { 0 };
        let end = if number == to.0 {
            to.1
        } else {
            lines[number].len()
        };
        found[number].push(Span {
            start,
            end,
            by: Quotation::Fixture,
        });
    }
}
