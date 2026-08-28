//! Strict diagnostic reading of a `kendex.settings.toml.example`.
//!
//! [`crate::settings_seed::extract_env_entries`] is the lenient reader
//! seeding runs: it takes whatever it recognizes and says nothing about the
//! rest, which is what seeding needs and what leaves an author's mistake to
//! surface in somebody else's shell. This is the other reader over the same
//! bytes, locating every defect and printing nothing. `kendex marketplace
//! check` reads its findings; no production caller reads
//! [`TemplateEntry`] yet.
//!
//! The grammar is the shell loaders', not this reader's opinion. What a
//! template's `[env]` table says is copied into a consumer's
//! `kendex.settings.toml`, where `skills/*/scripts/lib/kendex-env.sh` and
//! `skills/*/scripts/lib/settings.sh` read it: a lone `[name]` header, a
//! key spelled as a shell identifier, a value that is one double-quoted
//! string free of `"` and `\` with an optional trailing `#` comment. A
//! line those loaders refuse or silently skip is a finding here, as are
//! the two rules only a template has — a comment block over every key, and
//! nothing assigned outside `[env]`. The corpus in
//! `crates/core/tests/fixtures/settings-grammar.tsv` runs reader and
//! loaders against the same samples, so the two cannot drift apart unseen.
//!
//! The scan is line-based because comments are content here: a key's
//! comment block is what seeding writes beside it, and a TOML parser drops
//! comments on the floor. TOML parsing is the catch-all underneath, and
//! both are reported: where the two land on one line they are one defect
//! said twice, and the scan's telling — which names the key — is the one
//! kept; anywhere else they are two defects, and reporting one would send
//! the author back for the other.

use std::collections::{BTreeMap, BTreeSet};

use crate::settings_seed::SETTINGS_TEMPLATE;

/// A defect at a place in the template, with what to do about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateFinding {
    /// 1-based line; 0 where the whole file is the subject.
    pub line: usize,
    pub problem: String,
    pub fix: String,
}

/// One well-formed `[env]` row, decoded. Shaped for the app settings view
/// planned in KEN-705; the catalog check reads findings only.
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

/// The default a seeded assignment line carries, or `None` where the value
/// is a shape the shell loaders refuse. One double-quoted string with no
/// `"` and no `\`, optionally followed by a `#` comment — the loaders'
/// `^"[^"\\]*"[[:space:]]*(#.*)?$`, spelled in Rust. The one decoder: the
/// strict scan below and the seeding conflict notes both read values
/// through it, so they can never disagree about a template's default.
pub fn decoded_value(line: &str) -> Option<String> {
    let (_, value) = line.split_once('=')?;
    let (inner, after) = value.trim().strip_prefix('"')?.split_once('"')?;
    let after = after.trim_start();
    let closed = after.is_empty() || after.starts_with('#');
    (closed && !inner.contains('\\')).then(|| inner.to_owned())
}

/// The key an assignment names, verbatim. Never unquoted: the loaders match
/// the key text against a shell identifier, so `"WAIT"` is a key they skip
/// rather than a spelling of `WAIT`.
fn key_of(line: &str) -> Option<&str> {
    let (key, _) = line.split_once('=')?;
    let key = key.trim();
    (!key.is_empty()).then_some(key)
}

/// Whether a shell can export this key. The loaders skip everything else in
/// silence, so a key outside this shape seeds and is then never read.
fn is_env_name(key: &str) -> bool {
    let mut chars = key.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A `[`-leading line's table name and whether it is a header the loaders
/// accept — a lone `[name]`, nothing after the bracket. The name is read
/// even from a line they refuse, so `[other] # note` classifies what
/// follows it as another table's rather than cascading onto every key.
fn table_header(line: &str) -> (&str, bool) {
    let Some((name, after)) = line.strip_prefix('[').and_then(|rest| rest.split_once(']')) else {
        return ("", false);
    };
    let named = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    (name, named && after.trim().is_empty())
}

/// Strip a comment line down to its text.
fn comment_text(line: &str) -> String {
    line.trim().trim_start_matches('#').trim().to_owned()
}

/// Read one template strictly. Findings, then rows for whatever decoded.
pub fn read(text: &str) -> TemplateRead {
    let (mut read, syntax) = scan(text);
    let Err(error) = text.parse::<toml::Table>() else {
        return read;
    };
    // The scan and the parser often describe one defect from two sides: a
    // duplicate key is a TOML error too, and the scan's version names the
    // key where the parser's is generic. The precise telling is the one to
    // keep — but only where the scan's finding is about this line's SYNTAX.
    //
    // A line carries more than one finding now, and most of them are not
    // syntax at all: a key with no comment block above it is a template
    // rule, and a line can be badly commented AND badly spelled at once.
    // Keying on the line alone would take the second defect away, which is
    // the round it was meant to save.
    let line = error.span().map(|span| line_at(text, span.start));
    if line.is_some_and(|line| syntax.contains(&line)) {
        return read;
    }
    read.findings.push(TemplateFinding {
        line: line.unwrap_or(0),
        problem: format!("this is not valid TOML: {}", error.message()),
        fix: format!("fix the syntax so {SETTINGS_TEMPLATE} parses"),
    });
    // Findings read in file order, wherever the parser's landed.
    read.findings.sort_by_key(|finding| finding.line);
    read
}

/// The 1-based line a byte offset falls on. Counted from terminators, not
/// from `lines()`: an offset at the very start of a line has a prefix
/// ending in `\n`, which `lines()` does not count as a line of its own.
fn line_at(text: &str, offset: usize) -> usize {
    text.as_bytes()[..offset.min(text.len())]
        .iter()
        .filter(|byte| **byte == b'\n')
        .count()
        + 1
}

/// The line scan: everything an author can be told precisely, plus the
/// lines whose SYNTAX it already judged. TOML will complain about those
/// same lines in its own words, and the scan's words are better; every
/// other finding is about something the parser has no opinion on.
fn scan(text: &str) -> (TemplateRead, BTreeSet<usize>) {
    let mut read = TemplateRead::default();
    let mut syntax: BTreeSet<usize> = BTreeSet::new();
    // Whether the table is there at all is settled before any key is
    // judged. With no `[env]` the file seeds nothing whatever it holds, so
    // that is said once, in place of saying it again under every key. The
    // name is enough: a header spelled `[env] # note` is a shape finding of
    // its own, and reporting an absent table over it would name one typo
    // twice.
    let has_env = text
        .lines()
        .any(|line| table_header(line.trim()).0 == "env");
    if !has_env {
        read.findings.push(TemplateFinding {
            line: 0,
            problem: "there is no [env] table, so this template seeds nothing".to_owned(),
            fix: "open the table with a lone [env] header and put the keys under it".to_owned(),
        });
    }
    let mut env_header: Option<usize> = None;
    let mut in_env = false;
    let mut comment: Vec<(usize, String)> = Vec::new();
    let mut seen: BTreeMap<&str, usize> = BTreeMap::new();
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
        if trimmed.starts_with('[') {
            let (name, exact) = table_header(trimmed);
            in_env = name == "env";
            if !exact {
                syntax.insert(line);
                read.findings.push(TemplateFinding {
                    line,
                    problem: "this is not a table header the settings loaders read".to_owned(),
                    fix: "write the header as a lone [name] with nothing after the bracket"
                        .to_owned(),
                });
            } else if in_env {
                match env_header {
                    Some(first) => {
                        syntax.insert(line);
                        read.findings.push(TemplateFinding {
                            line,
                            problem: format!("a second [env] header; the first is on line {first}"),
                            fix: "keep one [env] table and move these keys into it".to_owned(),
                        });
                    }
                    None => env_header = Some(line),
                }
            }
            comment.clear();
            continue;
        }
        // A line with no `=` is one the loaders read past in silence, so
        // this scan does too and TOML below is what refuses it.
        let Some(key) = key_of(trimmed) else {
            continue;
        };
        let taken = std::mem::take(&mut comment);
        // Being assigned twice is one defect; whatever else is wrong with
        // this same assignment is another. Stopping here would tell the
        // author about the duplicate, take their fix, and only then admit
        // the value was never readable either.
        let duplicate = seen.insert(key, line);
        if let Some(first) = duplicate {
            syntax.insert(line);
            read.findings.push(TemplateFinding {
                line,
                problem: format!("{key} is assigned again; it is already on line {first}"),
                fix: format!("delete one of the two {key} assignments"),
            });
        }
        if !in_env {
            if has_env {
                read.findings.push(TemplateFinding {
                    line,
                    problem: format!("{key} is assigned outside [env]"),
                    fix: "move it under the [env] header; nothing else is seeded".to_owned(),
                });
            }
            continue;
        }
        // A value the strict reader cannot decode is this line's syntax,
        // and TOML will refuse the same line in its own generic words.
        // Every other check here is a template rule the parser has no
        // opinion about, so a line can carry both kinds at once.
        if decoded_value(trimmed).is_none() {
            syntax.insert(line);
        }
        let (value, problems) = decode_entry(key, line, trimmed, &taken);
        read.findings.extend(problems);
        // The first assignment of this key is already the row; a later one
        // that happens to decode is still a line to delete.
        if let Some(value) = value
            && duplicate.is_none()
        {
            read.entries.push(TemplateEntry {
                key: key.to_owned(),
                comment_span: (taken[0].0, taken[taken.len() - 1].0),
                comment: taken.into_iter().map(|(_, text)| text).collect(),
                value,
                line,
            });
        }
    }
    (read, syntax)
}

/// Everything wrong with one `[env]` assignment, and the decoded default
/// where nothing is. Every check runs rather than the first one winning: an
/// author told about the comment block, and only on the next run about the
/// value, has made a round trip for a defect that was always there.
///
/// Everything here needs the line and its comment block and nothing else
/// about the file.
fn decode_entry(
    key: &str,
    line: usize,
    trimmed: &str,
    comment: &[(usize, String)],
) -> (Option<String>, Vec<TemplateFinding>) {
    let mut problems = Vec::new();
    if !is_env_name(key) {
        problems.push(TemplateFinding {
            line,
            problem: format!("{key} is not a name a shell can export, so nothing reads it"),
            fix: "spell keys with letters, digits and underscores, starting with a letter or underscore"
                .to_owned(),
        });
    }
    if comment.is_empty() {
        problems.push(TemplateFinding {
            line,
            problem: format!("{key} has no comment block above it"),
            fix: "write the # lines that say what the key does; seeding carries them".to_owned(),
        });
    }
    let value = decoded_value(trimmed);
    if value.is_none() {
        problems.push(TemplateFinding {
            line,
            problem: format!(
                "{key}'s default is not a one-line double-quoted string free of \" and \\"
            ),
            fix: "spell every default as a plain \"...\" string on one line".to_owned(),
        });
    }
    match problems.is_empty() {
        true => (value, problems),
        false => (None, problems),
    }
}

#[cfg(test)]
mod tests;
