//! What a session loaded into its model's context, read from the file its
//! harness writes for it: the tokens its Start left, the context by
//! source, and each rule section it read. The rows are read through
//! [`session::entries`] and the usage through [`context::response`]; this
//! module knows no harness's rows.
//!
//! Start is the first user turn, up to the second: its tokens are the
//! context the turn's last response left, as the harness counted it.
//!
//! The four sources are the first user turn (the thread's first delivery),
//! later user turns, rule reads (a tool call that reads a Markdown file, a
//! `jarvis-section` section or a skill) and every other tool result.
//! Harness-added text joins the item before it where the record holds it
//! apart as [`Entry::Text`] names it, on Claude Code; Copilot CLI's is
//! inside the turn's own text. Codex records its own
//! (`<environment_context>` and the like) as `message` items that also
//! repeat each user turn, and Pi an extension's as `custom_message`
//! entries, which need not belong to the item before them; this reader
//! leaves both out of the bytes, and a Pi extension's text is no item's.
//!
//! A source's bytes are measured from the record, and unclear where a
//! result's text is not its row's (a Copilot skill's body). Its tokens are
//! measured where the harness counts each result itself, and otherwise
//! attributed from the responses around it: the prompt of a response, less
//! the prompt and output of the response before it, is what the record
//! between them added. That growth goes to a source only where everything
//! between the two responses belongs to it, and to one item or section only
//! where it is alone there, the call having run nothing else; any other
//! share is unclear. A gap that also holds text no item owns gives its
//! growth only to turns; beside a result the share is unclear. The first
//! response's prompt
//! also holds the harness's own prompt and tools, which no record names
//! apart, so the first delivery's tokens are unsupported.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
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
    /// The record holds the figure only inside a share this reader cannot
    /// settle to one source, item or section, or does not hold the text
    /// the item added, such as a Copilot skill's body: never zero.
    Unclear,
    /// The harness gives no reading of the figure: never zero.
    Unsupported,
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
    /// A `jarvis-section` command whose operands [`SECTION`] cannot settle.
    Unreadable,
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
/// a branch (Pi's `/tree` writes one into the same file), which a walk in
/// file order would mix with the path the session took.
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
    Unclear,
    Unsupported,
}

struct Item {
    source: Source,
    /// `None` where the text the item added is not its row's.
    bytes: Option<u64>,
    share: Share,
}

/// A call the record named: the turn it fell in and what it read.
struct Call {
    turn: Option<String>,
    rules: Rules,
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
    /// Whether the gap also holds text that is no item's.
    foreign: bool,
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
                tokens: Figure::Unsupported,
            },
            open: None,
            gap: Vec::new(),
            foreign: false,
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

    fn push(&mut self, source: Source, bytes: Option<u64>, share: Share) -> usize {
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
                self.push(self.turn_source(), Some(bytes), Share::Pending);
            }
            Entry::Text { bytes } => match self.gap.last() {
                Some(&last) => {
                    if let Some(held) = &mut self.items[last].bytes {
                        *held += bytes;
                    }
                }
                None => {
                    self.push(self.turn_source(), Some(bytes), Share::Pending);
                }
            },
            Entry::Foreign => self.foreign = true,
            Entry::Call { id, action } => {
                let rules = rule_reads(&action);
                self.calls.insert(
                    id,
                    Call {
                        turn: self.turn.clone(),
                        rules,
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
                let (turn, Rules { mut reads, more }) = match self.calls.get(&call) {
                    Some(named) => (named.turn.clone(), named.rules.clone()),
                    None => (self.turn.clone(), Rules::default()),
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
                let shared = reads.len() > 1 || more;
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
            self.start.tokens =
                context.map_or(Figure::Unsupported, |value| Figure::Measured { value });
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
        let foreign = std::mem::take(&mut self.foreign);
        let pending: Vec<usize> = gap
            .into_iter()
            .filter(|&i| self.items[i].share == Share::Pending)
            .collect();
        if pending.is_empty() {
            return;
        }
        // With no response before the gap, its growth also holds the
        // harness's own prompt.
        let (Some(before), Some(after)) = (self.open.as_ref().and_then(|open| open.split), next)
        else {
            self.settle(&pending, Share::Unsupported);
            return;
        };
        let carried = u128::from(before.prompt) + u128::from(before.output);
        let Some(growth) = u128::from(after.prompt)
            .checked_sub(carried)
            .and_then(|g| u64::try_from(g).ok())
        else {
            self.settle(&pending, Share::Unclear);
            return;
        };
        let source = self.items[pending[0]].source;
        let turn = |i: &usize| {
            matches!(
                self.items[*i].source,
                Source::FirstDelivery | Source::LaterTurns
            )
        };
        if foreign && !pending.iter().all(turn) {
            self.settle(&pending, Share::Unclear);
        } else if pending.len() == 1 {
            self.settle(&pending, Share::Whole(growth));
        } else if pending.iter().all(|&i| self.items[i].source == source) {
            *self.source_growth.entry(source).or_default() += growth;
            self.settle(&pending, Share::Source);
        } else {
            self.settle(&pending, Share::Unclear);
        }
    }

    fn settle(&mut self, items: &[usize], share: Share) {
        for &i in items {
            self.items[i].share = share;
        }
    }

    fn report(mut self) -> Report {
        let open: Vec<usize> = std::mem::take(&mut self.gap);
        self.settle(&open, Share::Unclear);
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
                    (Figure::Unclear, Figure::Unclear)
                } else {
                    (item_bytes(item.bytes), item_tokens(item.share))
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
        let bytes = items
            .iter()
            .map(|i| i.bytes)
            .sum::<Option<u64>>()
            .map_or(Figure::Unclear, |value| Figure::Measured { value });
        let (mut value, mut attributed, mut had) = (0u64, false, 0usize);
        let mut unsupported = false;
        for item in &items {
            match item.share {
                Share::Own(n) => {
                    value += n;
                    had += 1;
                }
                Share::Whole(n) => {
                    value += n;
                    attributed = true;
                    had += 1;
                }
                Share::Source => {
                    attributed = true;
                    had += 1;
                }
                Share::Unsupported => unsupported = true,
                Share::Pending | Share::Unclear => {}
            }
        }
        value += self.source_growth.get(&source).copied().unwrap_or(0);
        // An item the harness gives no reading of leaves its source none.
        let tokens = if had == 0 && unsupported {
            Figure::Unsupported
        } else if had == 0 && !items.is_empty() {
            Figure::Unclear
        } else if attributed {
            Figure::Attributed { value }
        } else {
            Figure::Measured { value }
        };
        SourceReading {
            source,
            items: items.len(),
            bytes,
            tokens,
            unattributed: items.len() - had,
        }
    }
}

fn item_bytes(bytes: Option<u64>) -> Figure {
    bytes.map_or(Figure::Unclear, |value| Figure::Measured { value })
}

/// One item's tokens, alone: a share of its source's growth is unclear for
/// the item itself.
fn item_tokens(share: Share) -> Figure {
    match share {
        Share::Own(value) => Figure::Measured { value },
        Share::Whole(value) => Figure::Attributed { value },
        Share::Source | Share::Pending | Share::Unclear => Figure::Unclear,
        Share::Unsupported => Figure::Unsupported,
    }
}

/// The programs whose Markdown operands are file reads, each printing the
/// file or the range it names: Codex has no read tool, so its file reads
/// are shell commands.
const PRINTERS: [&str; 5] = ["cat", "head", "tail", "sed", "nl"];

/// A `jarvis-section FILE HEADING` command, each operand single-quoted,
/// double-quoted or bare, with nothing the shell expands.
static SECTION: LazyLock<Regex> = LazyLock::new(|| {
    let operand = r#"(?:'([^']*)'|"([^"$`\\]*)"|([^\s'"$`\\<>*?\[\]#(){}]+))"#;
    Regex::new(&format!(
        r"^\s*\S*jarvis-section\s+{operand}\s+{operand}(?:\s|$)"
    ))
    .unwrap()
});

/// What a call reads as rules, and whether its result may also hold the
/// output of something else the call ran, which no read owns.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Rules {
    reads: Vec<Read>,
    more: bool,
}

/// The one table of what a call reads as rules: a read of a Markdown file,
/// a skill load, and in a shell command each `jarvis-section` and each
/// Markdown operand of a [`PRINTERS`] program. A command splits at each
/// `;`, `&`, `|` and newline, quoted or not, so a heading holding one reads
/// as [`Read::Unreadable`]; `>&` and `&>` redirect and split nothing. An
/// output redirection's target and a heredoc's or here-string's word are
/// no operand; an input redirection's file is one. A printer whose
/// standard output goes to a file reads nothing into the result; one sent
/// to another descriptor (`>&2`) still does. A segment that reads no rule,
/// and a `cat` operand that is not Markdown, is more output; another
/// printer's other operands are taken for its script or count.
fn rule_reads(action: &Action) -> Rules {
    let command = match action {
        Action::Read(path) if path.ends_with(".md") => {
            return Rules {
                reads: vec![Read::File { file: path.clone() }],
                more: false,
            };
        }
        Action::Skill(name) => {
            return Rules {
                reads: vec![Read::Skill { name: name.clone() }],
                more: false,
            };
        }
        Action::Shell(command) => command.replace(">&", ">").replace("&>", ">"),
        Action::Read(_) | Action::Other => return Rules::default(),
    };
    let mut rules = Rules::default();
    for segment in command.split([';', '&', '|', '\n']) {
        let mut words = segment.split_whitespace();
        let Some(program) = words.next() else {
            continue;
        };
        let before = rules.reads.len();
        match program.rsplit('/').next().unwrap_or(program) {
            "jarvis-section" => {
                rules
                    .reads
                    .push(SECTION.captures(segment).map_or(Read::Unreadable, |found| {
                        let operand = |first: usize| {
                            (first..first + 3)
                                .find_map(|i| found.get(i))
                                .map_or_else(String::new, |m| m.as_str().to_owned())
                        };
                        Read::Section {
                            file: operand(1),
                            heading: operand(4),
                        }
                    }))
            }
            name if PRINTERS.contains(&name) => {
                // A file the printer's standard output goes to, after the
                // rewrite above leaves `>&2` as `>2`.
                let away = |stdout: bool, target: &str| {
                    stdout && !target.bytes().all(|b| b.is_ascii_digit())
                };
                let (mut reads, mut moved) = (Vec::new(), false);
                // Some(stdout) while the next word is a redirection's target.
                let mut target: Option<bool> = None;
                for word in words.map(|word| word.trim_matches(['\'', '"'])) {
                    if let Some(stdout) = target.take() {
                        moved |= away(stdout, word);
                        continue;
                    }
                    if word.starts_with('-') {
                        continue;
                    }
                    if let Some((fd, rest)) = word.split_once('>') {
                        let stdout = matches!(fd, "" | "1");
                        match rest.trim_start_matches('>') {
                            "" => target = Some(stdout),
                            rest => moved |= away(stdout, rest),
                        }
                        continue;
                    }
                    if word.contains("<<") {
                        target = word.ends_with('<').then_some(false);
                        continue;
                    }
                    let word = word.strip_prefix('<').unwrap_or(word);
                    if word.is_empty() {
                        continue;
                    }
                    if word.ends_with(".md") {
                        reads.push(Read::File {
                            file: word.to_owned(),
                        });
                    } else if name == "cat" {
                        rules.more = true;
                    }
                }
                if !moved {
                    rules.reads.extend(reads);
                }
            }
            _ => {}
        }
        rules.more |= rules.reads.len() == before;
    }
    rules
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each row: the call, what it reads, and whether its result may hold
    /// output no read owns.
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
        let rows: Vec<(Action, Vec<Read>, bool)> = vec![
            (
                Action::Read("a/SKILL.md".to_owned()),
                vec![file("a/SKILL.md")],
                false,
            ),
            (Action::Read("a/main.rs".to_owned()), vec![], false),
            (
                shell(".agents/skills/jarvis/scripts/jarvis-section persona.md 'Conduct'"),
                vec![section("persona.md", "Conduct")],
                false,
            ),
            (
                shell("jarvis-section a.md One && jarvis-section b.md \"Two words\" 2>&1"),
                vec![section("a.md", "One"), section("b.md", "Two words")],
                false,
            ),
            (
                shell("jarvis-section \"$F\" 'One'"),
                vec![Read::Unreadable],
                false,
            ),
            (
                shell("sed -n '1,40p' docs/a.md | head -5 && cat b.md c.txt"),
                vec![file("docs/a.md"), file("b.md")],
                true,
            ),
            (
                shell("sed -n '1,200p' a/SKILL.md && ls -R"),
                vec![file("a/SKILL.md")],
                true,
            ),
            (shell("cat b.md c.txt"), vec![file("b.md")], true),
            (shell("cat a.md 2>/dev/null"), vec![file("a.md")], false),
            (shell("cat a.md &>/dev/null"), vec![], true),
            (shell("cat a.md > b.md"), vec![], true),
            (shell("cat a.md >> b.md"), vec![], true),
            (shell("cat a.md >&2"), vec![file("a.md")], false),
            (shell("cat < a.md"), vec![file("a.md")], false),
            (
                shell("sed -n '1,80p' <docs/a.md"),
                vec![file("docs/a.md")],
                false,
            ),
            (shell("git log -1 -- notes.md"), vec![], true),
        ];
        for (action, reads, more) in rows {
            assert_eq!(rule_reads(&action), Rules { reads, more }, "{action:?}");
        }
    }
}
