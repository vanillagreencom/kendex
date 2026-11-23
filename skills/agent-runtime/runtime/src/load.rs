//! What a session loaded into its model's context, read from the file its
//! harness writes for it: the tokens its Start left, the context by
//! source, and each rule section it read. The rows are read through
//! [`session::entries`] and the usage through [`context::response`], the
//! readers every other caller uses; this module knows no harness's rows.
//!
//! Start is the first user turn, up to the second: its tokens are the
//! context the turn's last response left, as the harness counted it.
//!
//! The four sources are the first user turn (the thread's first delivery),
//! later user turns, rule reads (a tool call that reads a Markdown file, a
//! `jarvis-section` section or a skill) and every other tool result.
//! Harness-added text joins the item before it in the record.
//!
//! A source's bytes are measured from the record. Its tokens are measured
//! where the harness counts each result itself, and otherwise attributed
//! from the responses around it: the prompt of a response, less the prompt
//! and output of the response before it, is what the record between them
//! added. That growth goes to a source only where everything between the
//! two responses belongs to it, and to one item or section only where it is
//! alone there; any other share is unclear, and is printed as such. The
//! first response's prompt also holds the harness's own prompt and tools,
//! which no record names apart, so the first delivery's tokens are
//! unsupported.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::context::{self, Response, Split};
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::session::{self, Action, Entry};

/// One figure of the reading, with how it was had.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "basis", rename_all = "kebab-case")]
pub enum Figure {
    /// Read from the record as the harness wrote it.
    Measured { value: u64 },
    /// Derived from measured figures by this module's attribution rule.
    Attributed { value: u64 },
    /// The record holds the figure only inside a share with others.
    Unclear { cause: &'static str },
    /// The harness's record never carries the figure.
    Unsupported { cause: &'static str },
    /// The harness writes the figure and this record holds none yet.
    Absent,
    /// The record holds the figure in a form this reader cannot take.
    Unread { cause: &'static str },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    FirstDelivery,
    LaterTurns,
    RuleReads,
    ToolResults,
}

const SOURCES: [Source; 4] = [
    Source::FirstDelivery,
    Source::LaterTurns,
    Source::RuleReads,
    Source::ToolResults,
];

/// What one rule read names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Read {
    /// A `jarvis-section FILE HEADING` command.
    Section {
        file: String,
        heading: String,
    },
    /// A whole Markdown file, or the part a read's range names.
    File {
        file: String,
    },
    Skill {
        name: Option<String>,
    },
    /// A `jarvis-section` command whose words this reader cannot settle.
    Unreadable {
        cause: &'static str,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Start {
    /// The first turn's native id, where the harness writes one.
    pub turn: Option<String>,
    pub tokens: Figure,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SourceReading {
    pub source: Source,
    pub items: usize,
    pub bytes: Figure,
    /// The tokens of every item whose share was had; `unattributed` counts
    /// the items left out.
    pub tokens: Figure,
    pub unattributed: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SectionReading {
    pub turn: Option<String>,
    pub call: String,
    pub read: Read,
    pub bytes: Figure,
    pub tokens: Figure,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Report {
    pub harness: Harness,
    pub turns: usize,
    pub start: Start,
    pub context: Vec<SourceReading>,
    pub sections: Vec<SectionReading>,
    /// Lines that held no JSON object: a line the harness is still writing,
    /// or one whose entries this reading is missing.
    pub unparsed_lines: u64,
}

/// The reading of the session file `file` of `harness`: Copilot CLI's
/// `events.jsonl`, every other harness's transcript. `Err` where the file
/// cannot be read, a usage field holds no whole count, or a Pi file holds
/// a branch, which a walk in file order would mix with the path the session
/// took.
pub fn read(harness: Harness, file: &Path) -> Result<Report> {
    let opened = File::open(file).map_err(|e| Error::io("open", file, e))?;
    let mut reader = BufReader::new(opened);
    let mut walk = Walk::new(harness);
    let mut line = Vec::new();
    let mut previous: Option<String> = None;
    loop {
        line.clear();
        let read = reader
            .read_until(b'\n', &mut line)
            .map_err(|e| Error::io("read", file, e))?;
        if read == 0 {
            break;
        }
        let text = String::from_utf8_lossy(&line);
        if text.trim().is_empty() {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Value>(&text) else {
            walk.unparsed += 1;
            continue;
        };
        let Some(object) = row.as_object() else {
            walk.unparsed += 1;
            continue;
        };
        if let Some((id, parent)) = session::tree_link(harness, &row) {
            if parent != previous.as_deref() {
                return Err(Error::refused(
                    "session-branched",
                    &[("file", &file.display().to_string()), ("entry", id)],
                ));
            }
            previous = Some(id.to_owned());
        }
        if !session::lead_row(harness, &row) {
            continue;
        }
        for entry in session::entries(harness, &row) {
            walk.entry(entry);
        }
        let usage = context::response(harness, object).map_err(|cause| {
            Error::refused(
                "session-usage-unread",
                &[("file", &file.display().to_string()), ("cause", &cause)],
            )
        })?;
        if let Some(response) = usage {
            walk.response(response);
        }
    }
    Ok(walk.report())
}

/// How one item's tokens were had.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Share {
    /// Its gap is still open.
    Pending,
    /// The harness counted it.
    Own(u64),
    /// Alone in its gap, it took the gap's whole growth.
    Whole(u64),
    /// Its gap held only its own source's items, which shared the growth.
    Source,
    Unclear(&'static str),
    Unsupported(&'static str),
}

struct Item {
    source: Source,
    bytes: u64,
    share: Share,
}

/// A call the record named: the turn it fell in and what it read.
struct Call {
    turn: Option<String>,
    reads: Vec<Read>,
}

/// A rule read's result, resolved once its item's share is known.
struct Section {
    item: usize,
    call: String,
    turn: Option<String>,
    read: Read,
    shared: bool,
}

/// The response the gap after it opens from.
struct Open {
    id: Option<String>,
    split: Option<Split>,
}

struct Walk {
    harness: Harness,
    turns: usize,
    turn: Option<String>,
    start: Start,
    open: Option<Open>,
    /// The items since the open response.
    gap: Vec<usize>,
    items: Vec<Item>,
    calls: HashMap<String, Call>,
    sections: Vec<Section>,
    /// Growth each source took whole, across gaps of several of its items.
    source_growth: HashMap<Source, u64>,
    unparsed: u64,
}

impl Walk {
    fn new(harness: Harness) -> Self {
        Walk {
            harness,
            turns: 0,
            turn: None,
            start: Start {
                turn: None,
                tokens: Figure::Absent,
            },
            open: None,
            gap: Vec::new(),
            items: Vec::new(),
            calls: HashMap::new(),
            sections: Vec::new(),
            source_growth: HashMap::new(),
            unparsed: 0,
        }
    }

    fn turn_source(&self) -> Source {
        if self.turns <= 1 {
            Source::FirstDelivery
        } else {
            Source::LaterTurns
        }
    }

    fn push(&mut self, source: Source, bytes: u64, share: Share) -> usize {
        self.items.push(Item {
            source,
            bytes,
            share,
        });
        self.gap.push(self.items.len() - 1);
        self.items.len() - 1
    }

    fn entry(&mut self, entry: Entry) {
        match entry {
            Entry::Turn { id, bytes } => {
                self.turns += 1;
                if self.turns == 1 {
                    self.start.turn.clone_from(&id);
                }
                self.turn = id;
                self.push(self.turn_source(), bytes, Share::Pending);
            }
            Entry::Text { bytes } => match self.gap.last() {
                Some(&last) => self.items[last].bytes += bytes,
                None => {
                    self.push(self.turn_source(), bytes, Share::Pending);
                }
            },
            Entry::Call { id, action } => {
                let reads = rule_reads(&action);
                self.calls.insert(
                    id,
                    Call {
                        turn: self.turn.clone(),
                        reads,
                    },
                );
            }
            Entry::Result {
                call,
                bytes,
                tokens,
                loaded,
            } => {
                let share = tokens.map_or(Share::Pending, Share::Own);
                let (turn, mut reads) = match self.calls.get(&call) {
                    Some(named) => (named.turn.clone(), named.reads.clone()),
                    None => (self.turn.clone(), Vec::new()),
                };
                // A result that names what it loaded is that skill's read,
                // whether or not the record kept its call.
                if let Some(name) = loaded {
                    reads.retain(|read| !matches!(read, Read::Skill { .. }));
                    reads.push(Read::Skill { name: Some(name) });
                }
                let source = if reads.is_empty() {
                    Source::ToolResults
                } else {
                    Source::RuleReads
                };
                let item = self.push(source, bytes, share);
                let shared = reads.len() > 1;
                for read in reads {
                    self.sections.push(Section {
                        item,
                        call: call.clone(),
                        turn: turn.clone(),
                        read,
                        shared,
                    });
                }
            }
        }
    }

    fn response(&mut self, response: Response) {
        let (id, split, context) = match response {
            Response::Spent(spent) => (spent.id, spent.split, Some(spent.context)),
            Response::Unread => (None, None, None),
        };
        if self.turns == 1 {
            self.start.tokens = context.map_or(
                Figure::Unread {
                    cause: "usage-unread",
                },
                |value| Figure::Measured { value },
            );
        }
        // A response spanning several lines: its last line's usage stands,
        // and the gap after it stays open.
        if let Some(open) = &mut self.open
            && id.is_some()
            && open.id == id
        {
            open.split = split;
            return;
        }
        self.close(split);
        self.open = Some(Open { id, split });
    }

    /// Settle each item of the gap the open response began, now that the
    /// response with `next` closes it.
    fn close(&mut self, next: Option<Split>) {
        let gap = std::mem::take(&mut self.gap);
        let pending: Vec<usize> = gap
            .into_iter()
            .filter(|&i| self.items[i].share == Share::Pending)
            .collect();
        if pending.is_empty() {
            return;
        }
        let Some(open) = &self.open else {
            self.settle(
                &pending,
                Share::Unsupported("first-call-holds-harness-prompt"),
            );
            return;
        };
        let (Some(before), Some(after)) = (open.split, next) else {
            self.settle(&pending, Share::Unsupported("response-names-no-split"));
            return;
        };
        let carried = u128::from(before.prompt) + u128::from(before.output);
        let Some(growth) = u128::from(after.prompt)
            .checked_sub(carried)
            .and_then(|g| u64::try_from(g).ok())
        else {
            self.settle(&pending, Share::Unclear("context-shrank"));
            return;
        };
        let source = self.items[pending[0]].source;
        if pending.len() == 1 {
            self.settle(&pending, Share::Whole(growth));
        } else if pending.iter().all(|&i| self.items[i].source == source) {
            *self.source_growth.entry(source).or_default() += growth;
            self.settle(&pending, Share::Source);
        } else {
            self.settle(&pending, Share::Unclear("shared-gap"));
        }
    }

    fn settle(&mut self, items: &[usize], share: Share) {
        for &i in items {
            self.items[i].share = share;
        }
    }

    fn report(mut self) -> Report {
        let open: Vec<usize> = std::mem::take(&mut self.gap);
        self.settle(&open, Share::Unclear("no-later-response"));
        let context = SOURCES
            .iter()
            .map(|&source| self.source_reading(source))
            .collect();
        let sections = self
            .sections
            .iter()
            .map(|section| {
                let item = &self.items[section.item];
                let (bytes, tokens) = if section.shared {
                    let unclear = Figure::Unclear {
                        cause: "shared-call",
                    };
                    (unclear.clone(), unclear)
                } else {
                    (
                        Figure::Measured { value: item.bytes },
                        item_tokens(item.share),
                    )
                };
                SectionReading {
                    turn: section.turn.clone(),
                    call: section.call.clone(),
                    read: section.read.clone(),
                    bytes,
                    tokens,
                }
            })
            .collect();
        Report {
            harness: self.harness,
            turns: self.turns,
            start: self.start,
            context,
            sections,
            unparsed_lines: self.unparsed,
        }
    }

    fn source_reading(&self, source: Source) -> SourceReading {
        let items: Vec<&Item> = self.items.iter().filter(|i| i.source == source).collect();
        let bytes = items.iter().map(|i| i.bytes).sum();
        let (mut measured, mut attributed, mut had) = (0u64, false, 0usize);
        let mut cause = None;
        for item in &items {
            match item.share {
                Share::Own(n) => {
                    measured += n;
                    had += 1;
                }
                Share::Whole(n) => {
                    measured += n;
                    attributed = true;
                    had += 1;
                }
                Share::Source => {
                    attributed = true;
                    had += 1;
                }
                Share::Pending | Share::Unclear(_) | Share::Unsupported(_) => {
                    cause.get_or_insert(item_tokens(item.share));
                }
            }
        }
        let value = measured + self.source_growth.get(&source).copied().unwrap_or(0);
        let tokens = match cause {
            Some(cause) if had == 0 => cause,
            _ if attributed => Figure::Attributed { value },
            _ => Figure::Measured { value },
        };
        SourceReading {
            source,
            items: items.len(),
            bytes: Figure::Measured { value: bytes },
            tokens,
            unattributed: items.len() - had,
        }
    }
}

/// One item's tokens, alone: a share of its source's growth is unclear for
/// the item itself.
fn item_tokens(share: Share) -> Figure {
    match share {
        Share::Own(value) => Figure::Measured { value },
        Share::Whole(value) => Figure::Attributed { value },
        Share::Source => Figure::Unclear {
            cause: "shared-gap",
        },
        Share::Pending => Figure::Unclear {
            cause: "no-later-response",
        },
        Share::Unclear(cause) => Figure::Unclear { cause },
        Share::Unsupported(cause) => Figure::Unsupported { cause },
    }
}

/// The programs whose Markdown operands are file reads: each prints the
/// file, or the range it names, as its output.
const PRINTERS: [&str; 6] = ["cat", "head", "tail", "sed", "nl", "less"];

/// The one table of what a call reads as rules: a read of a Markdown file,
/// a skill load, and in a shell command each `jarvis-section` and each
/// Markdown operand of a [`PRINTERS`] program.
fn rule_reads(action: &Action) -> Vec<Read> {
    match action {
        Action::Read(path) if path.ends_with(".md") => vec![Read::File { file: path.clone() }],
        Action::Skill(name) => vec![Read::Skill { name: name.clone() }],
        Action::Shell(command) => shell_reads(command),
        Action::Read(_) | Action::Other => Vec::new(),
    }
}

fn shell_reads(command: &str) -> Vec<Read> {
    let Some(commands) = simple_commands(command) else {
        return if command.contains("jarvis-section") {
            vec![Read::Unreadable {
                cause: "command-unsplit",
            }]
        } else {
            Vec::new()
        };
    };
    let mut reads = Vec::new();
    for words in commands {
        let mut words = words
            .into_iter()
            .skip_while(|w| matches!(w, Word::Text(t) if is_assignment(t)));
        let Some(Word::Text(program)) = words.next() else {
            continue;
        };
        let operands: Vec<Word> = words.collect();
        match program.rsplit('/').next().unwrap_or_default() {
            "jarvis-section" => reads.push(match operands.as_slice() {
                [Word::Text(file), Word::Text(heading)] => Read::Section {
                    file: file.clone(),
                    heading: heading.clone(),
                },
                [_, _] => Read::Unreadable {
                    cause: "word-expands",
                },
                _ => Read::Unreadable { cause: "operands" },
            }),
            name if PRINTERS.contains(&name) => {
                for operand in operands {
                    if let Word::Text(file) = operand
                        && !file.starts_with('-')
                        && file.ends_with(".md")
                    {
                        reads.push(Read::File { file });
                    }
                }
            }
            _ => {}
        }
    }
    reads
}

fn is_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && !name.starts_with(|c: char| c.is_ascii_digit())
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Word {
    Text(String),
    /// A word the shell expands, whose text the record does not hold.
    Expands,
}

/// The simple commands of a shell command's text, each its words in order:
/// split at an unquoted `;`, `&`, `|`, newline or parenthesis, words at
/// unquoted blanks, quotes and backslashes removed, a redirection and its
/// target dropped, a `#` comment skipped. A word holding an unquoted or
/// double-quoted `$` or backquote expands. `None` where the text cannot be
/// split: an open quote, or a here-document, whose body would read as
/// commands.
fn simple_commands(text: &str) -> Option<Vec<Vec<Word>>> {
    let mut commands = Vec::new();
    let mut words: Vec<Word> = Vec::new();
    let mut word = String::new();
    let (mut started, mut expands, mut target) = (false, false, false);
    let mut chars = text.chars().peekable();
    let finish = |words: &mut Vec<Word>,
                  word: &mut String,
                  started: &mut bool,
                  expands: &mut bool,
                  target: &mut bool| {
        if *started {
            if !*target {
                words.push(if *expands {
                    Word::Expands
                } else {
                    Word::Text(std::mem::take(word))
                });
            }
            *target = false;
        }
        word.clear();
        *started = false;
        *expands = false;
    };
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' => finish(
                &mut words,
                &mut word,
                &mut started,
                &mut expands,
                &mut target,
            ),
            ';' | '&' | '|' | '\n' | '(' | ')' => {
                finish(
                    &mut words,
                    &mut word,
                    &mut started,
                    &mut expands,
                    &mut target,
                );
                target = false;
                if !words.is_empty() {
                    commands.push(std::mem::take(&mut words));
                }
            }
            '#' if !started => {
                while chars.peek().is_some_and(|&n| n != '\n') {
                    chars.next();
                }
            }
            '<' | '>' => {
                if chars.peek() == Some(&'<') && c == '<' {
                    return None;
                }
                if started && word.bytes().all(|b| b.is_ascii_digit()) && !expands {
                    word.clear();
                    started = false;
                } else {
                    finish(
                        &mut words,
                        &mut word,
                        &mut started,
                        &mut expands,
                        &mut target,
                    );
                }
                while chars.peek().is_some_and(|&n| n == '>' || n == '&') {
                    chars.next();
                }
                target = true;
            }
            '\'' => {
                started = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        q => word.push(q),
                    }
                }
            }
            '"' => {
                started = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => match chars.next()? {
                            e @ ('"' | '\\' | '$' | '`') => word.push(e),
                            '\n' => {}
                            other => {
                                word.push('\\');
                                word.push(other);
                            }
                        },
                        '$' | '`' => expands = true,
                        q => word.push(q),
                    }
                }
            }
            '\\' => match chars.next() {
                Some('\n') | None => {}
                Some(escaped) => {
                    started = true;
                    word.push(escaped);
                }
            },
            '$' | '`' | '*' | '?' | '[' => {
                started = true;
                expands = true;
            }
            other => {
                started = true;
                word.push(other);
            }
        }
    }
    finish(
        &mut words,
        &mut word,
        &mut started,
        &mut expands,
        &mut target,
    );
    if !words.is_empty() {
        commands.push(words);
    }
    Some(commands)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(word: &str) -> Word {
        Word::Text(word.to_owned())
    }

    #[test]
    fn a_shell_command_splits_into_its_simple_commands_and_their_words() {
        let rows: [(&str, Option<Vec<Vec<Word>>>); 8] = [
            ("", Some(vec![])),
            (
                "a 'b c' \"d e\" f\\ g",
                Some(vec![vec![text("a"), text("b c"), text("d e"), text("f g")]]),
            ),
            (
                "a && b; c | d\ne",
                Some(vec![
                    vec![text("a")],
                    vec![text("b")],
                    vec![text("c")],
                    vec![text("d")],
                    vec![text("e")],
                ]),
            ),
            (
                "a x >out 2>&1 < in y",
                Some(vec![vec![text("a"), text("x"), text("y")]]),
            ),
            (
                "a \"$X\" $Y 'lit$' b*",
                Some(vec![vec![
                    text("a"),
                    Word::Expands,
                    Word::Expands,
                    text("lit$"),
                    Word::Expands,
                ]]),
            ),
            ("a # b c\nd", Some(vec![vec![text("a")], vec![text("d")]])),
            ("a 'open", None),
            ("cat <<EOF\nb\nEOF", None),
        ];
        for (command, want) in rows {
            assert_eq!(simple_commands(command), want, "{command:?}");
        }
    }

    #[test]
    fn a_call_reads_as_rules_by_the_one_table() {
        let section = |file: &str, heading: &str| Read::Section {
            file: file.to_owned(),
            heading: heading.to_owned(),
        };
        let file = |file: &str| Read::File {
            file: file.to_owned(),
        };
        let shell = |command: &str| Action::Shell(command.to_owned());
        let rows: Vec<(Action, Vec<Read>)> = vec![
            (
                Action::Read("a/SKILL.md".to_owned()),
                vec![file("a/SKILL.md")],
            ),
            (Action::Read("a/main.rs".to_owned()), vec![]),
            (Action::Other, vec![]),
            (
                Action::Skill(Some("jarvis".to_owned())),
                vec![Read::Skill {
                    name: Some("jarvis".to_owned()),
                }],
            ),
            (
                shell(".agents/skills/jarvis/scripts/jarvis-section persona.md 'Conduct'"),
                vec![section("persona.md", "Conduct")],
            ),
            (
                shell(
                    "X=1 jarvis-section a.md 'One' && .agents/skills/jarvis/scripts/jarvis-section b.md \"Two words\"",
                ),
                vec![section("a.md", "One"), section("b.md", "Two words")],
            ),
            (
                shell("jarvis-section \"$F\" 'One'"),
                vec![Read::Unreadable {
                    cause: "word-expands",
                }],
            ),
            (
                shell("jarvis-section a.md"),
                vec![Read::Unreadable { cause: "operands" }],
            ),
            (
                shell("jarvis-section a.md 'open"),
                vec![Read::Unreadable {
                    cause: "command-unsplit",
                }],
            ),
            (
                shell("sed -n '1,40p' docs/a.md | head -5 && cat b.md c.txt"),
                vec![file("docs/a.md"), file("b.md")],
            ),
            (shell("git log -1 -- notes.md"), vec![]),
        ];
        for (action, want) in rows {
            assert_eq!(rule_reads(&action), want, "{action:?}");
        }
    }
}
