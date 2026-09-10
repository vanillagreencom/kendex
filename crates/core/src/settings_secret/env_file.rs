//! The project's private env file, as data.
//!
//! Two loaders read this file and neither is this one. Linear's shared
//! `kendex-env.sh` `source`s it, so every byte of it is shell. Deep
//! Research's `loadEnvFile` matches `NAME=rest` per line and strips one
//! matching pair of surrounding quotes. kendex reads it a third way, as
//! text, and never runs it: sourcing a file to find out what is in it
//! would execute whatever somebody put there, on the app's own account,
//! to answer a question about presence.
//!
//! So the writing shape is chosen to mean the same thing to all three.
//! `KEY='value'` is a POSIX single-quoted string — bash takes every byte
//! inside it literally, Deep Research strips the pair and takes the rest
//! literally, and this module reads it back the same way. A single quote
//! is the one byte such a string cannot hold, and a value carrying one is
//! refused rather than escaped: the escape spellings the two loaders
//! accept are not the same set, so there is no encoding of it that both
//! read as written.
//!
//! What kendex may rewrite is narrower than what it can read. A line this
//! module did not write — an `export`, an expansion, a value carrying a
//! comment — means something to the shell that the replacement would drop,
//! so the key is reported and left alone rather than rewritten into
//! kendex's own shape.

use std::ops::Range;

/// The bytes a value may not contain, and why. Checked before any write,
/// so a value that reaches the file reads back as itself under every
/// loader.
pub fn check_value(value: &str) -> std::result::Result<(), String> {
    if value.is_empty() {
        return Err("an empty value is not a credential — clear the key instead".to_owned());
    }
    if value.contains('\n') || value.contains('\r') {
        return Err("a value is one line, and this one has a line break in it".to_owned());
    }
    if value.contains('\'') {
        return Err(
            "kendex writes a secret between single quotes, and a single-quoted string cannot hold one"
                .to_owned(),
        );
    }
    if let Some(control) = value.chars().find(|c| c.is_control()) {
        return Err(format!(
            "a value cannot hold a control character, and this one holds {}",
            control.escape_debug()
        ));
    }
    Ok(())
}

/// One assignment, written the way every reader of this file agrees on.
/// Callers check the value first; a value this cannot encode faithfully
/// would be a silent difference between what was typed and what loads.
pub fn assignment(key: &str, value: &str) -> String {
    format!("{key}='{value}'")
}

/// One line of the file that assigns a name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assignment {
    pub key: String,
    /// 1-based.
    pub line: u32,
    /// Byte range of the whole line, its terminator included.
    pub span: Range<usize>,
    /// What kendex may do with this line.
    pub shape: Shape,
}

/// What one assignment line is, to kendex.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// A single-quoted value kendex may write over.
    Holds,
    /// A single-quoted empty value kendex may write over. No loader ends
    /// with a credential: Deep Research assigns the empty string and
    /// takes it as missing, the shell leaves the name holding nothing,
    /// and [`check_value`] refuses writing one. So the key stands where a
    /// key no line assigns stands.
    Empty,
    /// A shape kendex does not itself write — an `export`, an expansion,
    /// a double-quoted or bare value, a trailing comment. Replacing one
    /// would change what the shell does with the line, not only what the
    /// value is.
    Foreign,
}

/// Every assignment the file makes, in file order.
///
/// Read the way both loaders find a key: a name at the head of a line,
/// an `=`, and whatever follows. Deep Research allows leading whitespace
/// and the shell allows a leading `export`, so both are recognised here —
/// a key kendex failed to see would be appended a second time, and the
/// later line is what wins in both loaders.
pub fn assignments(text: &str) -> Vec<Assignment> {
    let mut out = Vec::new();
    let mut at = 0usize;
    for (index, raw) in text.split_inclusive('\n').enumerate() {
        let span = at..at + raw.len();
        at = span.end;
        let content = raw.strip_suffix('\n').unwrap_or(raw);
        let content = content.strip_suffix('\r').unwrap_or(content);
        let Some((key, rest, plain)) = split_assignment(content) else {
            continue;
        };
        out.push(Assignment {
            key: key.to_owned(),
            line: u32::try_from(index + 1).unwrap_or(u32::MAX),
            span,
            shape: shape_of(plain, rest),
        });
    }
    out
}

/// The name a line assigns, what it assigns to it, and whether the line
/// carries nothing but that assignment — no leading whitespace and no
/// `export`, which are the two shapes both loaders read and kendex does
/// not write.
fn split_assignment(content: &str) -> Option<(&str, &str, bool)> {
    let trimmed = content.trim_start_matches([' ', '\t']);
    let plain = trimmed.len() == content.len();
    let (rest, plain) = match trimmed.strip_prefix("export") {
        Some(after) if after.starts_with([' ', '\t']) => {
            (after.trim_start_matches([' ', '\t']), false)
        }
        _ => (trimmed, plain),
    };
    let (key, value) = rest.split_once('=')?;
    // Deep Research allows whitespace between the name and the `=`; the
    // shell does not, and neither does kendex.
    let named = key.trim_end_matches([' ', '\t']);
    if !crate::settings_template::is_env_name(named) {
        return None;
    }
    Some((named, value, plain && named.len() == key.len()))
}

/// What one line is, given whether the line around the `=` is one this
/// module writes and the text after it.
fn shape_of(plain: bool, value: &str) -> Shape {
    if !plain {
        return Shape::Foreign;
    }
    match single_quoted(value) {
        Some("") => Shape::Empty,
        Some(_) => Shape::Holds,
        None => Shape::Foreign,
    }
}

/// The text a single-quoted value holds, where the text after the `=` is
/// one this module could have written: a single-quoted string holding no
/// quote of its own, and nothing after it. Every other shape — an
/// expansion, a double-quoted string, a bare word, a trailing comment —
/// is something the shell acts on, and replacing it with a quoted literal
/// would change the line's meaning rather than its value.
fn single_quoted(value: &str) -> Option<&str> {
    value
        .strip_prefix('\'')
        .and_then(|rest| rest.strip_suffix('\''))
        .filter(|inside| !inside.contains('\''))
}

/// Where one key stands in the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Standing {
    /// No line assigns it.
    Absent,
    /// One line assigns it a value, in a shape kendex may write over.
    At(Assignment),
    /// One line assigns it nothing, in a shape kendex may write over. No
    /// loader reads a credential out of it, so presence is answered as it
    /// is for a key no line assigns; the line is still carried, so a write
    /// replaces it rather than appending a second assignment under it.
    Empty(Assignment),
    /// Something assigns it and kendex cannot write it: more than one
    /// line, or one shape it does not write. The lines are what a person
    /// has to look at to settle it.
    Blocked { problem: String, lines: Vec<u32> },
}

impl Standing {
    /// The line kendex may write over, where there is one. Both shapes it
    /// writes answer here: a write over an empty assignment replaces that
    /// line, rather than appending a second one the loaders would then
    /// disagree about.
    pub fn writable_line(&self) -> Option<&Assignment> {
        match self {
            Standing::At(at) | Standing::Empty(at) => Some(at),
            Standing::Absent | Standing::Blocked { .. } => None,
        }
    }
}

/// Where one key stands, given the file's assignments.
pub fn standing(assignments: &[Assignment], key: &str) -> Standing {
    let mine: Vec<&Assignment> = assignments.iter().filter(|one| one.key == key).collect();
    match mine.as_slice() {
        [] => Standing::Absent,
        // Both loaders take the last assignment of a key, so a second one
        // decides what loads and a third could be added under it forever.
        // Reported instead, with every line, so the person deletes the
        // ones they did not mean.
        [one] => match one.shape {
            Shape::Holds => Standing::At((*one).clone()),
            Shape::Empty => Standing::Empty((*one).clone()),
            Shape::Foreign => Standing::Blocked {
                problem: "it is assigned in a shape kendex does not write, and rewriting the line would change what the shell does with it".to_owned(),
                lines: vec![one.line],
            },
        },
        many => Standing::Blocked {
            problem: "it is assigned more than once, and the last assignment is the one that loads"
                .to_owned(),
            lines: many.iter().map(|one| one.line).collect(),
        },
    }
}

/// The file with one key set to one value: the assignment replaced where
/// there is one, appended where there is none.
///
/// Byte-faithful everywhere else. The terminator the appended line takes
/// is the file's own, so a CRLF file stays one, and a file that did not
/// end in a terminator gains one before the new line rather than joining
/// it to the last.
pub fn with_value(text: &str, key: &str, value: &str) -> String {
    let line = assignment(key, value);
    let assignments = assignments(text);
    let standing = standing(&assignments, key);
    if let Some(at) = standing.writable_line() {
        let terminator = terminator_of(&text[at.span.clone()]);
        let mut out = String::with_capacity(text.len() + line.len());
        out.push_str(&text[..at.span.start]);
        out.push_str(&line);
        out.push_str(terminator);
        out.push_str(&text[at.span.end..]);
        return out;
    }
    let terminator = file_terminator(text);
    let mut out = String::with_capacity(text.len() + line.len() + 2 * terminator.len());
    out.push_str(text);
    if !text.is_empty() && !text.ends_with('\n') {
        out.push_str(terminator);
    }
    out.push_str(&line);
    out.push_str(terminator);
    out
}

/// The file with one key's assignment gone, and every other byte where it
/// was.
pub fn without_key(text: &str, key: &str) -> String {
    let assignments = assignments(text);
    let standing = standing(&assignments, key);
    let Some(at) = standing.writable_line() else {
        return text.to_owned();
    };
    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..at.span.start]);
    out.push_str(&text[at.span.end..]);
    out
}

/// The terminator one line ends with, empty where the file ended there.
fn terminator_of(raw: &str) -> &str {
    if let Some(rest) = raw.strip_suffix("\r\n") {
        return &raw[rest.len()..];
    }
    match raw.ends_with('\n') {
        true => "\n",
        false => "",
    }
}

/// The terminator a line appended to this file takes: the one its last
/// complete line uses, and `\n` for a file with none.
fn file_terminator(text: &str) -> &'static str {
    match text.contains("\r\n") {
        true => "\r\n",
        false => "\n",
    }
}
