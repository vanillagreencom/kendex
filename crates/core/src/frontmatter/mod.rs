//! Bounded YAML frontmatter parsing for source items. Foreign catalogs are
//! adversarial input, not just untidy input: parsing refuses aliases and
//! duplicate keys, caps input size, nesting depth, and node count, and keeps
//! every scalar a string — type coercion is the consumer's decision.
//!
//! Tolerance is deliberate and narrow: catalogs are written for harnesses
//! whose own frontmatter readers take a plain `key: value` line verbatim,
//! colons, `#` and all. `parse_tolerant` mirrors that for single-line plain
//! values so real catalogs keep loading — while structured values (blocks,
//! lists, nested maps) and access-shaping keys (`tools:`, `role:`) get real,
//! strict YAML with no salvage path.

/// Frontmatter is metadata, not content; a block this large is an attack or
/// a mistake, and either deserves a loud error over a slow parse.
const MAX_YAML_BYTES: usize = 64 * 1024;
const MAX_NODES: usize = 4096;

/// Keys whose values shape access. They get no verbatim salvage: a value
/// real YAML cannot parse is an error, never a guess.
const STRICT_KEYS: &[&str] = &["tools", "role"];

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// An explicitly empty value (`key:` or `key: null`) — distinct from an
    /// absent key; the permission model depends on that distinction.
    Null,
    Scalar(String),
    List(Vec<Value>),
    Map(Map),
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Scalar(text) => Some(text),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Map {
    entries: Vec<(String, Value)>,
}

impl Map {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn entries(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().map(|(k, v)| (k.as_str(), v))
    }

    fn insert(&mut self, key: String, value: Value) -> Result<(), String> {
        if self.get(&key).is_some() {
            return Err(format!("duplicate frontmatter key `{key}`"));
        }
        self.entries.push((key, value));
        Ok(())
    }

    /// A list-valued key in either YAML form: a sequence of scalars or a
    /// comma-separated scalar. `Null` and `[]` are the empty list — present
    /// but empty, unlike an absent key which returns `None`.
    pub fn string_list(&self, key: &str) -> Option<Vec<String>> {
        match self.get(key)? {
            Value::Null => Some(Vec::new()),
            Value::Scalar(text) => Some(
                text.split(',')
                    .map(str::trim)
                    .filter(|part| !part.is_empty())
                    .map(str::to_owned)
                    .collect(),
            ),
            Value::List(items) => Some(
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                    .map(str::to_owned)
                    .collect(),
            ),
            Value::Map(_) => None,
        }
    }
}

/// The text after a frontmatter opener line, or `None` where the file
/// opens no block. Its own step because "no block at all" and "a block
/// that never ends" are different answers for a reader deciding whether a
/// declaration is absent or unreadable, and [`split`] reports one error
/// for both.
fn opened(text: &str) -> Option<&str> {
    let after_marker = text.strip_prefix("---")?;
    let opener_rest = after_marker.trim_start_matches([' ', '\t']);
    opener_rest
        .strip_prefix('\r')
        .unwrap_or(opener_rest)
        .strip_prefix('\n')
}

/// Whether the file opens a frontmatter block, whatever follows it.
pub fn opens(text: &str) -> bool {
    opened(text).is_some()
}

/// Split a `---` frontmatter block from the body. The terminator is a line
/// holding exactly `---` (or `...`) plus optional trailing whitespace.
pub fn split(text: &str) -> Result<(&str, &str), String> {
    let rest = opened(text).ok_or("file has no frontmatter")?;
    let mut offset = 0;
    for line in rest.split_inclusive('\n') {
        let trimmed = line.trim_end();
        if trimmed == "---" || trimmed == "..." {
            return Ok((&rest[..offset], &rest[offset + line.len()..]));
        }
        offset += line.len();
    }
    Err("unterminated frontmatter".to_owned())
}

#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub map: Map,
    pub warnings: Vec<String>,
    /// Top-level lines that opened no entry, verbatim. A warning says the
    /// same thing in prose; this says it in a form a reader can act on,
    /// because "the key is absent" and "the key lost its colon" are the
    /// same missing key to [`Map::get`] and different answers to anything
    /// deciding what a package declares.
    pub ignored: Vec<String>,
}

/// Parse frontmatter entry by entry: strict YAML wherever the value has
/// structure, verbatim single-line plain scalars everywhere else (matching
/// what harness loaders themselves do), hard errors for `STRICT_KEYS`.
pub fn parse_tolerant(yaml: &str) -> Result<Parsed, String> {
    if yaml.len() > MAX_YAML_BYTES {
        return Err(format!(
            "frontmatter is {} bytes — the limit is {MAX_YAML_BYTES}",
            yaml.len()
        ));
    }
    let mut parsed = Parsed::default();
    for block in entry_blocks(yaml) {
        let first = block.lines().next().unwrap_or_default();
        let Some((key, inline)) = first.split_once(':') else {
            parsed
                .warnings
                .push(format!("frontmatter line without a key ignored: `{first}`"));
            parsed.ignored.push(first.to_owned());
            continue;
        };
        let key = key.trim().to_owned();
        let inline = inline.trim();
        let multiline = block
            .lines()
            .skip(1)
            .any(|line| !line.trim().is_empty() && !line.trim_start().starts_with('#'));
        let strict = STRICT_KEYS.contains(&key.as_str());
        if multiline || strict || !is_plain_inline(inline) {
            match parse(&block) {
                Ok(map) => {
                    for (k, v) in map.entries {
                        parsed.map.insert(k, v)?;
                    }
                    continue;
                }
                // A blown resource bound is adversarial input, never a
                // stylistic quirk — no salvage anywhere for those.
                Err(problem) if multiline || strict || is_bounds_error(&problem) => {
                    return Err(format!("`{key}`: {problem}"));
                }
                Err(problem) => {
                    parsed.warnings.push(format!(
                        "`{key}`: not valid YAML ({problem}) — value taken verbatim"
                    ));
                }
            }
        }
        let value = match inline.is_empty() {
            true => Value::Null,
            false => Value::Scalar(inline.to_owned()),
        };
        parsed.map.insert(key, value)?;
    }
    Ok(parsed)
}

/// Whether this inline value is the whole of its node: a plain scalar
/// opening no construct, or a quoted one whose closing quote is on the
/// same line with nothing after it but whitespace or a comment.
///
/// Asked as an allowlist rather than as a list of ways a value can run
/// on, because that list has been wrong three times: a block scalar
/// continues indented, a flow collection continues at column 0, and so
/// does an indentless block sequence. What a caller replacing one line
/// needs is not "does this continue" but "is this bounded", and only the
/// two shapes above are.
///
/// An empty value is not one of them: an entry with nothing after its
/// colon takes its value from the lines below.
pub fn value_is_whole(value: &str) -> bool {
    match value.chars().next() {
        None => false,
        Some(quote @ ('"' | '\'')) => quoted_closes(value, quote),
        Some(_) => is_plain_inline(value),
    }
}

/// Whether the quoted scalar opening `text` closes on it, with nothing
/// following but whitespace and a comment — the shapes YAML itself
/// accepts there. Single quotes escape themselves (`''`); double quotes
/// escape with `\`.
fn quoted_closes(text: &str, quote: char) -> bool {
    let mut chars = text.char_indices().skip(1);
    let mut end = None;
    while let Some((at, c)) = chars.next() {
        if quote == '"' && c == '\\' {
            chars.next();
            continue;
        }
        if c == quote {
            if quote == '\'' && text[at + 1..].starts_with('\'') {
                chars.next();
                continue;
            }
            end = Some(at + c.len_utf8());
            break;
        }
    }
    let Some(end) = end else {
        return false;
    };
    let after = &text[end..];
    let trimmed = after.trim_start_matches([' ', '\t']);
    trimmed.is_empty() || (trimmed.starts_with('#') && trimmed.len() < after.len())
}

/// A plain inline value is one where verbatim capture and YAML agree apart
/// from comment stripping — no quoting, no flow collections, no block
/// indicators, no anchors/aliases/tags.
fn is_plain_inline(inline: &str) -> bool {
    !inline.starts_with(['"', '\'', '[', '{', '|', '>', '&', '*', '!'])
}

fn is_bounds_error(problem: &str) -> bool {
    problem.contains("nests deeper") || problem.contains("YAML nodes") || problem.contains("bytes")
}

/// Top-level frontmatter entries: a new entry starts at a line whose first
/// character is not whitespace (comments and blanks attach to the current
/// entry, where YAML ignores them anyway).
fn entry_blocks(yaml: &str) -> Vec<String> {
    let mut blocks: Vec<String> = Vec::new();
    for line in yaml.lines() {
        let starts_entry = line
            .chars()
            .next()
            .is_some_and(|c| c != ' ' && c != '\t' && c != '#');
        if starts_entry {
            blocks.push(line.to_owned());
        } else if let Some(last) = blocks.last_mut() {
            last.push('\n');
            last.push_str(line);
        }
    }
    blocks
}

mod strict;
pub use strict::parse;

#[cfg(test)]
mod tests;
