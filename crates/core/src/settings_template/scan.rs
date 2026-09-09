//! The line walk: every defect an author can be told precisely, and where
//! it sits.
//!
//! Apart from the types and [`super::read`] because it answers a different
//! question. Those say what a template amounts to; this decides what is
//! wrong with one, line by line, which is the half that grows every time
//! the grammar gains a rule.

use std::collections::{BTreeMap, BTreeSet};

use super::{SecretEntry, TemplateEntry, TemplateFinding, TemplateRead};

/// The table a template declares its credentials under. Named once: the
/// scan, the findings it writes and the authoring guide all spell it from
/// here.
pub(crate) const SECRETS_TABLE: &str = "secrets";

/// The table a line sits under. A template declares two and the walk
/// judges an assignment by which one it is in: a `[env]` key ships a
/// default the consumer's file receives, a `[secrets]` key ships none and
/// never reaches that file at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Table {
    Env,
    Secrets,
    /// Somebody else's table, or none opened yet.
    Other,
}

impl Table {
    /// How a finding names this table.
    fn name(self) -> &'static str {
        match self {
            Table::Env => "[env]",
            Table::Secrets => "[secrets]",
            // Only two declared tables ever reach a finding that names
            // one; `disagrees` keeps this out of the sensitivity message.
            Table::Other => "no table a template declares",
        }
    }
}

/// The table a header opens for this walk, where it opens one the walk
/// tracks.
fn declared_table(line: &str) -> Option<Table> {
    let (env, secrets) = table_header(line);
    match (env, secrets) {
        (true, _) => Some(Table::Env),
        (_, true) => Some(Table::Secrets),
        _ => None,
    }
}

/// Which of the two tables a template may declare this `[`-leading line
/// opens. Read through [`crate::settings_toml::header_of`], which is the
/// one place a header is parsed: a check with its own copy is a check
/// that can come to disagree with what seeding splices against.
fn table_header(line: &str) -> (bool, bool) {
    crate::settings_toml::header_of(line).map_or((false, false), |header| {
        (header.opens("env"), header.opens(SECRETS_TABLE))
    })
}

/// Whether a `[`-leading line is a header shape the shell loaders read.
/// `[env]` is spliced into a consumer's file, where those loaders match
/// the exact text, so a shape they refuse is a defect wherever it sits.
fn lone_header(line: &str) -> bool {
    crate::settings_toml::header_of(line).is_some_and(|header| header.lone)
}

/// Strip a comment line down to its text.
fn comment_text(line: &str) -> String {
    line.trim().trim_start_matches('#').trim().to_owned()
}

/// What the walk accumulates across lines.
struct Walk {
    read: TemplateRead,
    /// Lines whose SYNTAX the scan already judged.
    syntax: BTreeSet<u32>,
    /// Where each of the two tables was first opened.
    headers: BTreeMap<&'static str, u32>,
    /// Where each key was first assigned, and under which table.
    seen: BTreeMap<String, (u32, Table)>,
    /// Keys one template declares both public and secret. Neither
    /// declaration becomes a row: choosing between them is what could send
    /// a credential down the public write route.
    conflicted: BTreeSet<String>,
}

/// The line scan: everything an author can be told precisely, plus the
/// lines whose SYNTAX it already judged. TOML will complain about those
/// same lines in its own words, and the scan's words are better; every
/// other finding is about something the parser has no opinion on.
pub(super) fn scan(text: &str) -> (TemplateRead, BTreeSet<u32>) {
    let mut walk = Walk {
        read: TemplateRead::default(),
        syntax: BTreeSet::new(),
        headers: BTreeMap::new(),
        seen: BTreeMap::new(),
        conflicted: BTreeSet::new(),
    };
    let rows = crate::settings_toml::rows(text);
    // Whether a table is there at all is settled before any key is judged.
    // With neither the file declares nothing whatever it holds, so that is
    // said once, in place of saying it again under every key. The name is
    // enough: a header spelled `[env] # note` is a shape finding of its
    // own, and reporting an absent table over it would name one typo
    // twice.
    let any_table = rows
        .iter()
        .filter(|row| row.kind == crate::settings_toml::Line::Table)
        .any(|row| declared_table(row.text.trim()).is_some());
    if !any_table {
        walk.read.findings.push(TemplateFinding {
            line: 0,
            problem: format!(
                "there is neither an [env] table nor a [{SECRETS_TABLE}] table, so this template declares nothing"
            ),
            fix: format!(
                "open a lone [env] header for the keys a consumer sets, or a lone [{SECRETS_TABLE}] header for the credentials this package reads"
            ),
        });
    }
    let mut at = Table::Other;
    let mut comment: Vec<(u32, String)> = Vec::new();
    for row in &rows {
        let trimmed = row.text.trim();
        use crate::settings_toml::Line;
        match row.kind {
            // A value's own lines are the value. Judged as syntax they
            // name keys that do not exist, and send an author to fix them.
            Line::InValue => continue,
            Line::Blank => {
                comment.clear();
                continue;
            }
            Line::Comment => {
                let said = comment_text(trimmed);
                walk.read.findings.extend(marker_alone(row.line, &said));
                comment.push((row.line, said));
                continue;
            }
            Line::Table => {
                at = walk.header(trimmed, row.line);
                comment.clear();
                continue;
            }
            // A line with no `=` is one the loaders read past in silence,
            // so this scan does too and TOML below is what refuses it.
            Line::Other => continue,
            Line::Assignment { .. } => {}
        }
        let taken = std::mem::take(&mut comment);
        walk.assignment(row, at, taken, any_table);
    }
    // A key the template says two different things about becomes neither
    // kind of row. The first declaration is dropped here rather than at
    // the line that met it: which one it disagrees with is only known once
    // the second has been read.
    let conflicted = std::mem::take(&mut walk.conflicted);
    walk.read
        .entries
        .retain(|entry| !conflicted.contains(&entry.key));
    walk.read
        .secrets
        .retain(|secret| !conflicted.contains(&secret.key));
    (walk.read, walk.syntax)
}

impl Walk {
    /// What a header line settles — which table the keys under it belong
    /// to — and whatever is wrong with the header itself.
    fn header(&mut self, trimmed: &str, line: u32) -> Table {
        let opened = declared_table(trimmed);
        if !lone_header(trimmed) {
            self.syntax.insert(line);
            self.read.findings.push(TemplateFinding {
                line,
                problem: "this is not a table header the settings loaders read".to_owned(),
                fix: "write the header as a lone [name] with nothing after the bracket".to_owned(),
            });
        } else if let Some(table) = opened {
            let name = table.name();
            match self.headers.get(name) {
                Some(first) => {
                    self.syntax.insert(line);
                    self.read.findings.push(TemplateFinding {
                        line,
                        problem: format!("a second {name} header; the first is on line {first}"),
                        fix: format!("keep one {name} table and move these keys into it"),
                    });
                }
                None => {
                    self.headers.insert(name, line);
                }
            }
        }
        opened.unwrap_or(Table::Other)
    }

    /// One assignment line: what is wrong with it, and the row it becomes
    /// where nothing is.
    fn assignment(
        &mut self,
        row: &crate::settings_toml::Row<'_>,
        at: Table,
        taken: Vec<(u32, String)>,
        any_table: bool,
    ) {
        let line = row.line;
        let Some((written, value, _)) = row.assignment() else {
            return;
        };
        // A quoted key is one TOML reads and no shell exports. Both facts
        // are said below; here it is the name that matters, so two
        // spellings of one key report as the duplicate they are.
        let Some(spelled) = crate::settings_toml::key_of(written) else {
            return;
        };
        let key = spelled.name.as_str();
        // Being assigned twice is one defect; whatever else is wrong with
        // this same assignment is another. Stopping here would tell the
        // author about the duplicate, take their fix, and only then admit
        // the value was never readable either.
        let duplicate = self.seen.insert(key.to_owned(), (line, at));
        if let Some(before) = duplicate {
            self.syntax.insert(line);
            if disagrees(before.1, at) {
                self.conflicted.insert(key.to_owned());
            }
            self.read
                .findings
                .push(duplicate_finding(key, line, before, at));
        }
        if at == Table::Other {
            if any_table {
                self.read.findings.push(TemplateFinding {
                    line,
                    problem: format!("{key} is assigned outside [env] and [{SECRETS_TABLE}]"),
                    fix: format!(
                        "move it under [env] to declare a setting, or under [{SECRETS_TABLE}] to declare a credential; nothing else is read"
                    ),
                });
            }
            return;
        }
        let marker = crate::settings_toml::trailing_comment(value).map(|(_, said)| said);
        self.read
            .findings
            .extend(marker.and_then(|said| marker_after_value(line, key, said)));
        // A value the strict reader cannot decode is this line's syntax,
        // and TOML will refuse the same line in its own generic words.
        // Every other check here is a template rule the parser has no
        // opinion about, so a line can carry both kinds at once.
        let decoded = crate::settings_toml::decoded(value);
        if decoded.is_none() {
            self.syntax.insert(line);
        }
        let (value, problems) =
            decode_entry(written.trim(), spelled.quoted, line, decoded, &taken, at);
        self.read.findings.extend(problems);
        // The first assignment of this key is already the row; a later one
        // that happens to decode is still a line to delete.
        let Some(value) = value.filter(|_| duplicate.is_none()) else {
            return;
        };
        match at {
            Table::Env => self.read.entries.push(TemplateEntry {
                key: key.to_owned(),
                comment_span: (taken[0].0, taken[taken.len() - 1].0),
                comment: taken.into_iter().map(|(_, text)| text).collect(),
                value,
                line,
            }),
            // Nothing of the value survives into a secret row: the only
            // value `decode_entry` admits here is the empty string, and a
            // row carrying one would be a place a credential could sit.
            Table::Secrets => self.read.secrets.push(SecretEntry {
                key: key.to_owned(),
                comment: taken.into_iter().map(|(_, text)| text).collect(),
                required: marker.is_some_and(crate::settings_seed::marks_required),
                line,
            }),
            Table::Other => unreachable!("an assignment under no declared table returned above"),
        }
    }
}

/// Whether two assignments of one key say different things about whether
/// it holds a credential. A key assigned under a table this template does
/// not declare says nothing about sensitivity at all — it is a plain
/// duplicate, already reported as one — so only two DECLARED tables can
/// disagree.
fn disagrees(before: Table, at: Table) -> bool {
    before != at && before != Table::Other && at != Table::Other
}

/// How a key assigned twice is reported. Two spellings under one table is
/// a duplicate; one under each declared table is a disagreement about
/// whether the key holds a credential, and nothing downstream may choose
/// between them — the reader that did could send a secret through the
/// public write route.
fn duplicate_finding(key: &str, line: u32, before: (u32, Table), at: Table) -> TemplateFinding {
    let (first, before) = before;
    if !disagrees(before, at) {
        return TemplateFinding {
            line,
            problem: format!("{key} is assigned again; it is already on line {first}"),
            fix: format!("delete one of the two {key} assignments"),
        };
    }
    TemplateFinding {
        line,
        problem: format!(
            "{key} is declared under {} here and under {} on line {first}, so nothing can say whether it is a secret",
            at.name(),
            before.name()
        ),
        fix: format!(
            "declare {key} under one table: [env] for a value that is safe to commit, [{SECRETS_TABLE}] for a credential"
        ),
    }
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

/// Everything wrong with one assignment, and the decoded value where
/// nothing is. Every check runs rather than the first one winning: an
/// author told about the comment block, and only on the next run about the
/// value, has made a round trip for a defect that was always there.
///
/// Everything here needs the line, its comment block and the table it
/// sits under, and nothing else about the file.
fn decode_entry(
    shown: &str,
    quoted: bool,
    line: u32,
    value: Option<String>,
    comment: &[(u32, String)],
    at: Table,
) -> (Option<String>, Vec<TemplateFinding>) {
    let mut problems = Vec::new();
    // A quoted key is one TOML reads and the loaders do not: they match
    // the text as written against a shell identifier, so the quotes are as
    // disqualifying as a hyphen.
    if quoted || !super::is_env_name(shown) {
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
            fix: match at {
                Table::Secrets => "write the # lines that say what the key lets this package do; the app shows them beside the field".to_owned(),
                _ => "write the # lines that say what the key does; seeding carries them".to_owned(),
            },
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
    // A credential declaration publishes metadata and nothing else. A
    // value here would ship in the catalog, reach every consumer, and
    // stand as the answer the app offers to write — which is the whole
    // shape this table exists to keep out of public configuration.
    if at == Table::Secrets && value.as_deref().is_some_and(|value| !value.is_empty()) {
        problems.push(TemplateFinding {
            line,
            problem: format!("{shown} is declared under [{SECRETS_TABLE}] with a value"),
            fix: format!(
                "write it as {shown} = \"\", and say in the comment above it what a consumer has to supply"
            ),
        });
    }
    match problems.is_empty() {
        true => (value, problems),
        false => (None, problems),
    }
}
