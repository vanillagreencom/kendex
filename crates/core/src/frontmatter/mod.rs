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

/// Why the top-level `name` entry cannot be rewritten as one scalar.
#[derive(Debug, PartialEq, Eq)]
pub enum NameProblem {
    /// No frontmatter block to carry a name.
    NoFrontmatter,
    /// Frontmatter with no `name` entry; `insert_at` is where a first line
    /// would go.
    Missing { insert_at: usize },
    /// Two top-level `name` entries: no single scalar to stand in for.
    Twice,
    /// The value is a block scalar, a flow collection, an anchor, a tag,
    /// or continues on the next line — not one inline scalar.
    NotAScalar,
}

impl std::fmt::Display for NameProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            NameProblem::NoFrontmatter => "the file has no frontmatter",
            NameProblem::Missing { .. } => "the frontmatter has no `name`",
            NameProblem::Twice => "the frontmatter names it twice",
            NameProblem::NotAScalar => "the frontmatter's `name` is not one plain value",
        })
    }
}

/// The byte span of the top-level `name` entry's inline value — what a
/// rename replaces, leaving every other byte, the opener and terminator
/// lines, and each line's own ending as they were. Exactly one entry, its
/// whole value on its own line, or the problem says why not.
pub fn name_value_span(text: &str) -> Result<std::ops::Range<usize>, NameProblem> {
    let (yaml, _) = split(text).map_err(|_| NameProblem::NoFrontmatter)?;
    let yaml_start = yaml.as_ptr() as usize - text.as_ptr() as usize;
    let lines: Vec<&str> = yaml.split_inclusive('\n').collect();
    let mut found: Option<std::ops::Range<usize>> = None;
    let mut offset = yaml_start;
    for (index, line) in lines.iter().enumerate() {
        let start = offset;
        offset += line.len();
        let starts_entry = line
            .chars()
            .next()
            .is_some_and(|c| c != ' ' && c != '\t' && c != '#');
        if !starts_entry {
            continue;
        }
        let Some((key, rest)) = line.split_once(':') else {
            continue;
        };
        if key.trim() != "name" {
            continue;
        }
        if found.is_some() {
            return Err(NameProblem::Twice);
        }
        let lead = rest.len() - rest.trim_start_matches([' ', '\t']).len();
        let value = rest.trim_end();
        let value = value.get(lead..).unwrap_or_default();
        let value_len = match value.chars().next() {
            None => return Err(NameProblem::NotAScalar),
            Some(quote @ ('"' | '\'')) => match quoted_len(value, quote) {
                Some(len) => len,
                None => return Err(NameProblem::NotAScalar),
            },
            Some(_) if is_plain_inline(value) => value.len(),
            Some(_) => return Err(NameProblem::NotAScalar),
        };
        // Blank and comment-only lines attach to the entry without
        // extending its value (YAML ignores them); only real indented
        // content continues the scalar onto another line.
        let continued = lines[index + 1..]
            .iter()
            .map(|line| (line.starts_with([' ', '\t']), line.trim()))
            .find(|(_, text)| !text.is_empty() && !text.starts_with('#'))
            .is_some_and(|(indented, _)| indented);
        if continued {
            return Err(NameProblem::NotAScalar);
        }
        let value_start = start + key.len() + 1 + lead;
        found = Some(value_start..value_start + value_len);
    }
    found.ok_or(NameProblem::Missing {
        insert_at: yaml_start,
    })
}

#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub map: Map,
    pub warnings: Vec<String>,
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

/// Byte length of the quoted scalar opening `text`, when nothing follows
/// its closing quote but whitespace and a comment — the shapes YAML itself
/// accepts there. Single quotes escape themselves (`''`); double quotes
/// escape with `\`. `None` when the quote never closes or real content
/// follows it: not one inline scalar to replace.
fn quoted_len(text: &str, quote: char) -> Option<usize> {
    let mut end = None;
    let mut chars = text.char_indices().skip(1);
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
    let end = end?;
    let after = &text[end..];
    let trimmed = after.trim_start_matches([' ', '\t']);
    (trimmed.is_empty() || (trimmed.starts_with('#') && trimmed.len() < after.len())).then_some(end)
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

#[cfg(test)]
mod name_span_tests {
    use super::{NameProblem, name_value_span};

    fn span_of(text: &str) -> Result<&str, NameProblem> {
        name_value_span(text).map(|span| &text[span])
    }

    #[test]
    fn finds_the_inline_value_and_only_it() {
        assert_eq!(span_of("---\nname: gh\n---\nBody.\n"), Ok("gh"));
        assert_eq!(span_of("---\nname : gh\n---\n"), Ok("gh"));
        assert_eq!(span_of("---\nname:   gh  \n---\n"), Ok("gh"));
        assert_eq!(span_of("---\r\nname: gh\r\n---\r\n"), Ok("gh"));
        assert_eq!(span_of("---\nname: gh #edited\n...\n"), Ok("gh #edited"));
        assert_eq!(span_of("---\nname: \"gh\"\n---\n"), Ok("\"gh\""));
        assert_eq!(span_of("---\nname: 'gh'\n---\n"), Ok("'gh'"));
        // A comment after a quoted value belongs to the line, not the
        // value; an escaped quote does not close the scalar.
        assert_eq!(span_of("---\nname: \"gh\" # package\n---\n"), Ok("\"gh\""));
        assert_eq!(span_of("---\nname: 'it''s' # x\n---\n"), Ok("'it''s'"));
        assert_eq!(
            span_of("---\nname: \"a\\\"b\" # c\n---\n"),
            Ok("\"a\\\"b\"")
        );
        // A comment-only or blank line after the entry is not a
        // continuation of its value, indented or not.
        assert_eq!(span_of("---\nname: gh\n  # note\n---\n"), Ok("gh"));
        assert_eq!(span_of("---\nname: gh\n\ndesc: d\n---\n"), Ok("gh"));
        // Not a top-level entry, and not the `name` key.
        assert_eq!(
            span_of("---\nmeta:\n  name: inner\nname: outer\n---\n"),
            Ok("outer")
        );
        assert_eq!(
            span_of("---\nnames: many\n---\n"),
            Err(NameProblem::Missing { insert_at: 4 })
        );
    }

    #[test]
    fn refuses_what_is_not_one_scalar() {
        assert_eq!(span_of("Body.\n"), Err(NameProblem::NoFrontmatter));
        assert_eq!(
            span_of("---\nname: a\nname: b\n---\n"),
            Err(NameProblem::Twice)
        );
        for text in [
            "---\nname: [copy]\n---\n",
            "---\nname: |\n  gh\n---\n",
            "---\nname: >\n  gh\n---\n",
            "---\nname: &anchor gh\n---\n",
            "---\nname: gh\n  continued\n---\n",
            "---\nname: gh\n  # note\n  continued\n---\n",
            "---\nname:\n---\n",
            "---\nname: \"gh\n---\n",
            "---\nname: \"gh\" trailing\n---\n",
            "---\nname: \"gh\"#glued\n---\n",
        ] {
            assert_eq!(span_of(text), Err(NameProblem::NotAScalar), "{text:?}");
        }
    }
}
