//! Strict diagnostic reading of a `kendex.settings.toml.example`.
//!
//! [`crate::settings_seed::extract_env_entries`] is the lenient reader
//! seeding runs: it takes whatever it recognizes and says nothing about the
//! rest, which is what seeding needs and what leaves an author's mistake to
//! surface in somebody else's shell. This is the other reader over the same
//! bytes, locating every defect and printing nothing. `kendex marketplace
//! check` reads its findings; the app's settings view
//! ([`crate::settings_view`]) reads both.
//!
//! The grammar is the shell loaders', not this reader's opinion. A
//! template's `[env]` table is judged against what
//! `skills/*/scripts/lib/kendex-env.sh` and
//! `skills/*/scripts/lib/settings.sh` read, wherever its keys land: a lone
//! `[name]` header, a key spelled as a shell identifier, a value that is
//! one double-quoted string free of `"` and `\`, and after that value
//! nothing but the required marker. A line those loaders refuse or
//! silently skip is a finding here, as are the rules only a template has —
//! a comment block over every key, nothing assigned outside `[env]`, and
//! that marker, whose spelling `crate::settings_seed::marks_required`
//! decides for seeder and check alike. The corpus in
//! `crates/core/tests/fixtures/settings-grammar.tsv` runs reader and
//! loaders against the same samples, so the two cannot drift apart unseen.
//!
//! The line walk that finds the defects is [`mod@scan`]; here are the types it
//! reports in and the read that runs it. It is line-based because comments
//! are content: a key's comment block is what seeding writes beside it, and
//! a TOML parser drops comments on the floor. TOML parsing is the catch-all
//! underneath, and both are reported: where the two land on one line they are one defect
//! said twice, and the scan's telling — which names the key — is the one
//! kept; anywhere else they are two defects, and reporting one would send
//! the author back for the other.
//!
//! One limit, and it is the parser's: `toml::de::Error` holds a single
//! message and a single span, and the crate exposes no way to ask for
//! more, so a file with two independent syntax errors gives up the second
//! only once the first is fixed. Everything the scan owns — every key, and
//! every way one key is wrong — comes out in one read.

use crate::settings_seed::SETTINGS_TEMPLATE;

/// Where a skill's template stands for one scope: the bytes it ships, that
/// it ships none, or why nothing there could read one. Whether there is a
/// template to read is a different question from what one says, and only a
/// scope pass can answer it — [`crate::engine::settings_templates`] does,
/// and [`crate::settings_view`] reads the answer through this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateSource {
    /// The template's bytes, as the skill's source ships them.
    Text(String),
    /// The skill ships no `kendex.settings.toml.example`.
    Absent,
    /// Nothing there could read one, and why.
    Unreadable(String),
}

/// A defect at a place in the template, with what to do about it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct TemplateFinding {
    /// 1-based line; 0 where the whole file is the subject.
    pub line: u32,
    pub problem: String,
    pub fix: String,
}

/// One well-formed `[env]` row, decoded — what the app's settings view
/// shows beside a key. The catalog check reads findings only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateEntry {
    pub key: String,
    /// The comment block above the key, `#` markers stripped, in order.
    pub comment: Vec<String>,
    /// The default with its quotes removed. There are no escapes to
    /// decode: a value carrying `"` or `\` is a finding, not a row.
    pub value: String,
    /// 1-based first and last line of the comment block.
    pub comment_span: (u32, u32),
    /// 1-based line the assignment sits on.
    pub line: u32,
}

/// What one template amounts to: every row that decoded, and every defect.
/// A clean file has an empty `findings`; the two are reported together so a
/// reader with one bad key still sees the others.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TemplateRead {
    pub entries: Vec<TemplateEntry>,
    pub findings: Vec<TemplateFinding>,
}

/// The default one assignment line carries, or `None` where the value is a
/// shape the shell loaders refuse. Both halves are
/// [`crate::settings_toml`]'s — where the line's top-level `=` falls, and
/// which values are readable — so the seeding conflict notes, the strict
/// scan and the editor's span can never disagree about a default.
pub fn decoded_value(line: &str) -> Option<String> {
    let (_, value) = crate::settings_toml::assignment_of(line)?;
    crate::settings_toml::decoded(value)
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
fn line_at(text: &str, offset: usize) -> u32 {
    line_number(
        text.as_bytes()[..offset.min(text.len())]
            .iter()
            .filter(|byte| **byte == b'\n')
            .count(),
    )
}

/// A 0-based index as the 1-based line a finding names. Line numbers cross
/// into the app, where the boundary counts in 32 bits; a file long enough
/// to saturate one is past anything a person reads a finding about.
fn line_number(index: usize) -> u32 {
    u32::try_from(index + 1).unwrap_or(u32::MAX)
}

mod scan;
use scan::scan;

#[cfg(test)]
mod tests;
