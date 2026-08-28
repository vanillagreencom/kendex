//! Strict diagnostic reading of a `kendex.settings.toml.example`.
//!
//! [`crate::settings_seed::extract_env_entries`] is the lenient reader
//! seeding runs: it takes whatever it recognizes and says nothing about the
//! rest, which is what seeding needs and what leaves an author's mistake to
//! surface in somebody else's shell. This is the other reader — same bytes,
//! every defect located, nothing printed. `kendex marketplace check` turns
//! its findings into rows, and the app's settings view reads its decoded
//! entries.
//!
//! The scan is line-based because comments are content here: a key's
//! comment block is what seeding writes beside it, and a TOML parser drops
//! comments on the floor. TOML parsing is the catch-all underneath — run
//! only when the line scan is clean, so a precise finding always beats
//! "does not parse".

use std::collections::BTreeMap;

use crate::settings_seed::SETTINGS_TEMPLATE;

/// A defect at a place in the template, with what to do about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateFinding {
    /// 1-based line; 0 where the whole file is the subject.
    pub line: usize,
    pub problem: String,
    pub fix: String,
}

/// One well-formed `[env]` row, decoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateEntry {
    pub key: String,
    /// The comment block above the key, `#` markers stripped, in order.
    pub comment: Vec<String>,
    /// The default with its quotes removed. There are no escapes to
    /// decode: a value carrying `"` or `\` is a finding, not a row.
    pub value: String,
    /// 1-based first and last line of the comment block.
    pub comment_span: (usize, usize),
    /// 1-based line the assignment sits on.
    pub line: usize,
}

/// What one template amounts to: every row that decoded, and every defect.
/// A clean file has an empty `findings`; the two are reported together so a
/// reader with one bad key still sees the others.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TemplateRead {
    pub entries: Vec<TemplateEntry>,
    pub findings: Vec<TemplateFinding>,
}

/// The default a seeded assignment line carries, or `None` where the line
/// is not a single-line double-quoted string. The one decoder — the strict
/// scan below and the seeding conflict notes both read values through it,
/// so they can never disagree about what a template's default is.
pub fn decoded_value(line: &str) -> Option<String> {
    let (_, value) = line.split_once('=')?;
    let value = value.trim();
    let inner = value.strip_prefix('"')?.strip_suffix('"')?;
    // `""` strips to nothing, but `"` strips to `"` — a lone quote is not a
    // string, and the interior must carry neither delimiter nor escape.
    match value.len() >= 2 && !inner.contains(['"', '\\']) {
        true => Some(inner.to_owned()),
        false => None,
    }
}

/// A key's spelling, bare or quoted.
fn key_of(line: &str) -> Option<String> {
    let (key, _) = line.split_once('=')?;
    let key = key.trim().trim_matches('"').trim();
    (!key.is_empty()).then(|| key.to_owned())
}

fn is_table_header(line: &str) -> bool {
    line.starts_with('[') && line.ends_with(']')
}

/// Strip a comment line down to its text.
fn comment_text(line: &str) -> String {
    line.trim().trim_start_matches('#').trim().to_owned()
}

/// Read one template strictly. Findings, then rows for whatever decoded.
pub fn read(text: &str) -> TemplateRead {
    let mut read = scan(text);
    if read.findings.is_empty()
        && let Err(error) = text.parse::<toml::Table>()
    {
        read.findings.push(TemplateFinding {
            line: error.span().map_or(0, |span| line_at(text, span.start)),
            problem: format!("this is not valid TOML: {}", error.message()),
            fix: format!("fix the syntax so {SETTINGS_TEMPLATE} parses"),
        });
    }
    read
}

/// The 1-based line a byte offset falls on.
fn line_at(text: &str, offset: usize) -> usize {
    text[..offset.min(text.len())].lines().count().max(1)
}

/// The line scan: everything an author can be told precisely.
fn scan(text: &str) -> TemplateRead {
    let mut read = TemplateRead::default();
    let mut env_header: Option<usize> = None;
    let mut in_env = false;
    let mut comment: Vec<(usize, String)> = Vec::new();
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    for (index, raw) in text.lines().enumerate() {
        let line = index + 1;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            comment.clear();
            continue;
        }
        if trimmed.starts_with('#') {
            comment.push((line, comment_text(trimmed)));
            continue;
        }
        if is_table_header(trimmed) {
            in_env = trimmed == "[env]";
            if in_env {
                match env_header {
                    Some(first) => read.findings.push(TemplateFinding {
                        line,
                        problem: format!("a second [env] header; the first is on line {first}"),
                        fix: "keep one [env] table and move these keys into it".to_owned(),
                    }),
                    None => env_header = Some(line),
                }
            }
            comment.clear();
            continue;
        }
        // Anything else with no `=` is a continuation of a value the strict
        // reader has already refused; the refusal is the finding.
        let Some(key) = key_of(trimmed) else {
            continue;
        };
        let taken = std::mem::take(&mut comment);
        if let Some(first) = seen.insert(key.clone(), line) {
            read.findings.push(TemplateFinding {
                line,
                problem: format!("{key} is assigned again; it is already on line {first}"),
                fix: format!("delete one of the two {key} assignments"),
            });
            continue;
        }
        if !in_env {
            read.findings.push(TemplateFinding {
                line,
                problem: format!("{key} is assigned outside [env]"),
                fix: "move it under the [env] header; nothing else is seeded".to_owned(),
            });
            continue;
        }
        if taken.is_empty() {
            read.findings.push(TemplateFinding {
                line,
                problem: format!("{key} has no comment block above it"),
                fix: "write the # lines that say what the key does; seeding carries them"
                    .to_owned(),
            });
            continue;
        }
        let Some(value) = decoded_value(trimmed) else {
            read.findings.push(TemplateFinding {
                line,
                problem: format!(
                    "{key}'s default is not a one-line double-quoted string free of \" and \\"
                ),
                fix: "spell every default as a plain \"...\" string on one line".to_owned(),
            });
            continue;
        };
        read.entries.push(TemplateEntry {
            key,
            comment_span: (taken[0].0, taken[taken.len() - 1].0),
            comment: taken.into_iter().map(|(_, text)| text).collect(),
            value,
            line,
        });
    }
    read
}

#[cfg(test)]
mod tests;
