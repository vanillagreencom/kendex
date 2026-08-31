//! The line walk: every defect an author can be told precisely, and where
//! it sits.
//!
//! Apart from the types and [`super::read`] because it answers a different
//! question. Those say what a template amounts to; this decides what is
//! wrong with one, line by line, which is the half that grows every time
//! the grammar gains a rule.

use std::collections::{BTreeMap, BTreeSet};

use super::{TemplateEntry, TemplateFinding, TemplateRead};

/// Whether a shell can export this key. The loaders skip everything else in
/// silence, so a key outside this shape seeds and is then never read.
fn is_env_name(key: &str) -> bool {
    let mut chars = key.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Whether a `[`-leading line opens `[env]`, and whether it is a header
/// the loaders read. Both read through
/// [`crate::settings_toml::header_of`], which is the one place a header is
/// parsed: a check with its own copy is a check that can come to disagree
/// with what seeding splices against.
fn table_header(line: &str) -> (bool, bool) {
    crate::settings_toml::header_of(line)
        .map_or((false, false), |header| (header.opens("env"), header.lone))
}

/// Strip a comment line down to its text.
fn comment_text(line: &str) -> String {
    line.trim().trim_start_matches('#').trim().to_owned()
}

/// The line scan: everything an author can be told precisely, plus the
/// lines whose SYNTAX it already judged. TOML will complain about those
/// same lines in its own words, and the scan's words are better; every
/// other finding is about something the parser has no opinion on.
pub(super) fn scan(text: &str) -> (TemplateRead, BTreeSet<u32>) {
    let mut read = TemplateRead::default();
    let mut syntax: BTreeSet<u32> = BTreeSet::new();
    // Whether the table is there at all is settled before any key is
    // judged. With no `[env]` the file seeds nothing whatever it holds, so
    // that is said once, in place of saying it again under every key. The
    // name is enough: a header spelled `[env] # note` is a shape finding of
    // its own, and reporting an absent table over it would name one typo
    // twice.
    let rows = crate::settings_toml::rows(text);
    let has_env = rows.iter().any(|row| {
        row.kind == crate::settings_toml::Line::Table && table_header(row.text.trim()).0
    });
    if !has_env {
        read.findings.push(TemplateFinding {
            line: 0,
            problem: "there is no [env] table, so this template seeds nothing".to_owned(),
            fix: "open the table with a lone [env] header and put the keys under it".to_owned(),
        });
    }
    let mut env_header: Option<u32> = None;
    let mut in_env = false;
    let mut comment: Vec<(u32, String)> = Vec::new();
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    for row in &rows {
        let line = row.line;
        let trimmed = row.text.trim();
        use crate::settings_toml::Line;
        // A value's own lines are the value. Judged as syntax they name
        // keys that do not exist, and send an author to fix them.
        if matches!(row.kind, Line::InValue) {
            continue;
        }
        if matches!(row.kind, Line::Blank) {
            comment.clear();
            continue;
        }
        if matches!(row.kind, Line::Comment) {
            let said = comment_text(trimmed);
            read.findings.extend(marker_alone(line, &said));
            comment.push((line, said));
            continue;
        }
        if matches!(row.kind, Line::Table) {
            in_env = header(trimmed, line, &mut env_header, &mut read, &mut syntax);
            comment.clear();
            continue;
        }
        // A line with no `=` is one the loaders read past in silence, so
        // this scan does too and TOML below is what refuses it.
        let Some((written, value, _)) = row.assignment() else {
            continue;
        };
        // A quoted key is one TOML reads and no shell exports. Both facts
        // are said below; here it is the name that matters, so two
        // spellings of one key report as the duplicate they are.
        let Some(spelled) = crate::settings_toml::key_of(written) else {
            continue;
        };
        let key = spelled.name.as_str();
        let taken = std::mem::take(&mut comment);
        // Being assigned twice is one defect; whatever else is wrong with
        // this same assignment is another. Stopping here would tell the
        // author about the duplicate, take their fix, and only then admit
        // the value was never readable either.
        let duplicate = seen.insert(key.to_owned(), line);
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
        let marker = crate::settings_toml::trailing_comment(value).map(|(_, said)| said);
        read.findings
            .extend(marker.and_then(|said| marker_after_value(line, key, said)));
        // A value the strict reader cannot decode is this line's syntax,
        // and TOML will refuse the same line in its own generic words.
        // Every other check here is a template rule the parser has no
        // opinion about, so a line can carry both kinds at once.
        let decoded = crate::settings_toml::decoded(value);
        if decoded.is_none() {
            syntax.insert(line);
        }
        let (value, problems) = decode_entry(written.trim(), spelled.quoted, line, decoded, &taken);
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

/// What a header line settles — whether the keys under it are `[env]`'s —
/// and whatever is wrong with the header itself.
fn header(
    trimmed: &str,
    line: u32,
    env_header: &mut Option<u32>,
    read: &mut TemplateRead,
    syntax: &mut BTreeSet<u32>,
) -> bool {
    let (in_env, exact) = table_header(trimmed);
    if !exact {
        syntax.insert(line);
        read.findings.push(TemplateFinding {
            line,
            problem: "this is not a table header the settings loaders read".to_owned(),
            fix: "write the header as a lone [name] with nothing after the bracket".to_owned(),
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
            None => *env_header = Some(line),
        }
    }
    in_env
}

/// The marker is only a marker after a value. On a comment line of its own
/// it is an ordinary comment: both readers see no marker, the loaders have
/// no opinion on a comment at all, and the key an author declared the
/// consumer must decide is then never written AND never reported as
/// unanswered, because nothing downstream knows it was marked.
///
/// Read the way a person reads it, which is the opposite of the rule
/// after a value and deliberately so. There the exact spelling is what is
/// honoured, so anything else is refused; here nothing is being honoured
/// at all and the only question is whether the line is the marker word. So
/// the comparison folds what changes the word's presentation and not the
/// word: its case, and everything that is not a letter or a digit at
/// either end of the line. `# Required`, `# required.`, `# (required)`,
/// `# "required"` and a marker trailed by an ellipsis or a zero-width
/// character all mean it as plainly as `# required` does. Naming a closed
/// list of trailing ASCII marks left every other presentation of the word
/// silent, which is one keystroke away in a set nobody can enumerate; what
/// the fold trims is instead everything the word is NOT. The text arrives
/// trimmed of its `#` and its spacing, so those need no answer of their
/// own.
///
/// Only the ends are folded, so the word has to be the whole line. A
/// comment that merely contains it, `# required for CI` or the sentence
/// every shipped template heads a marked key with, keeps a letter at both
/// ends and is no finding.
///
/// This is the one comparison here that does not ask
/// [`crate::settings_seed::marks_required`], and the folding is why: that
/// predicate says what the seeder honours, and a line of its own honours
/// nothing. Widening it to match this would make `# Required` after a
/// value a marker the seeder writes on, which is the opposite of what
/// `marker_after_value` is for.
///
/// What this deliberately does not reach is a misspelling: `# requried`
/// and `# requireds` on a line of their own stay silent, because telling
/// those from an ordinary comment means guessing at what the author meant,
/// and a line of free prose is what it would guess against. Presentation
/// is a closed set; misspelling is not, and a rule that tried to cover it
/// would be back next round one keystroke further out.
///
/// Every mention of the word in a shipped template is inside a sentence,
/// so a line that is nothing but the word is the mistake and only the
/// mistake.
fn marker_alone(line: u32, said: &str) -> Option<TemplateFinding> {
    let marker = crate::settings_seed::REQUIRED_MARKER;
    let word = said.trim_matches(|c: char| !c.is_alphanumeric());
    word.eq_ignore_ascii_case(marker).then(|| TemplateFinding {
        line,
        problem: format!("this comment line is just `{said}`, which marks nothing"),
        fix: format!("write the marker after the value it marks, as `KEY = \"\" # {marker}`"),
    })
}

/// After a value the marker is the only thing a template may write. A
/// misspelling loads exactly as a correct marker does, so the loaders have
/// no opinion on it either and the key quietly stops being one an install
/// writes.
///
/// What counts as the marker is [`crate::settings_seed::marks_required`],
/// the same predicate the seeder writes a key on, asked negated: this
/// check is there so a spelling the seeder does not honour cannot ship,
/// and it can only say that while the two cannot disagree about which
/// spelling that is.
fn marker_after_value(line: u32, key: &str, said: &str) -> Option<TemplateFinding> {
    let marker = crate::settings_seed::REQUIRED_MARKER;
    (!crate::settings_seed::marks_required(said)).then(|| TemplateFinding {
        line,
        problem: format!(
            "{key} carries `#{said}` after its value, and the only marker a template writes there is `# {marker}`"
        ),
        fix: format!(
            "write `# {marker}` where the consumer must decide the key, and nothing after the value otherwise"
        ),
    })
}

/// Everything wrong with one `[env]` assignment, and the decoded default
/// where nothing is. Every check runs rather than the first one winning: an
/// author told about the comment block, and only on the next run about the
/// value, has made a round trip for a defect that was always there.
///
/// Everything here needs the line and its comment block and nothing else
/// about the file.
fn decode_entry(
    shown: &str,
    quoted: bool,
    line: u32,
    value: Option<String>,
    comment: &[(u32, String)],
) -> (Option<String>, Vec<TemplateFinding>) {
    let mut problems = Vec::new();
    // A quoted key is one TOML reads and the loaders do not: they match
    // the text as written against a shell identifier, so the quotes are as
    // disqualifying as a hyphen.
    if quoted || !is_env_name(shown) {
        problems.push(TemplateFinding {
            line,
            problem: format!("{shown} is not a name a shell can export, so nothing reads it"),
            fix: "spell keys bare, with letters, digits and underscores, starting with a letter or underscore"
                .to_owned(),
        });
    }
    if comment.is_empty() {
        problems.push(TemplateFinding {
            line,
            problem: format!("{shown} has no comment block above it"),
            fix: "write the # lines that say what the key does; seeding carries them".to_owned(),
        });
    }
    if value.is_none() {
        problems.push(TemplateFinding {
            line,
            problem: format!(
                "{shown}'s default is not a one-line double-quoted string free of \" and \\"
            ),
            fix: "spell every default as a plain \"...\" string on one line".to_owned(),
        });
    }
    match problems.is_empty() {
        true => (value, problems),
        false => (None, problems),
    }
}
