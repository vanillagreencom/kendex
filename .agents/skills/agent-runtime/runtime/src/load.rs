//! What a session loaded into its model's context, read from the file its
//! harness writes for it: the tokens its Start left, the context by
//! source, and each rule section it read. The rows are read through
//! [`session::entries`] and the usage through [`context::response`]; this
//! module knows no harness's rows.
//!
//! Start is the first user turn, up to the second: its tokens are the
//! context the turn's last response left, as the harness counted it.
//!
//! The five sources are the first user turn (the thread's first delivery),
//! later user turns, rule reads (a tool call that reads a Markdown file, a
//! `jarvis-section` section or a skill), every other tool result, and
//! injected text, which the record holds apart from every item beside it
//! as [`Entry::Foreign`] names it: a Pi extension's `custom_message`, which
//! need not belong to the item before it, and a Claude Code Stop hook's
//! reply. Other harness-added text joins the item before it where the
//! record holds it apart as [`Entry::Text`] names it, on Claude Code;
//! Copilot CLI's is inside the turn's own text. Codex records its own
//! (`<environment_context>` and the like) as `message` items that also
//! repeat each user turn; this reader leaves those out of the bytes. A
//! failed call's result counts to its source, and a shell read of it
//! stands unless the result shows it printed nothing ([`stood`]): a Bash
//! command that exits nonzero still returns what it printed on Claude Code
//! and Pi, so a read before the part that failed may stand, and one the
//! shell never ran does not. No read stands where the result does not show
//! the shell ran to its exit status ([`Failed::Unshown`]), as a hook's
//! block, a refusal, or a timeout or an abort that cut the shell short
//! leaves it, nor in a call that turns on errexit or pipefail through
//! `set`, whose shell stops or fails where these rules do not follow it.
//! Otherwise a read is dropped where its program's own error line names
//! its operand, where the result shows the shell skipped its command
//! ([`skipped`]), and, for a `jarvis-section` read, where the result holds
//! its heading line fewer times than the call has reads of that heading.
//! A command shows it failed by an error line of its own, and that it
//! succeeded by the lack of one only where its standard error reaches the
//! result as its own redirections leave it ([`words`]); any other command
//! shows neither. The
//! shell skipped a command after `&&` whose command before shows it
//! failed, and after `||` one that shows it succeeded; where the command
//! before shows neither, whether the shell ran it is open. Since the call
//! failed, its last list ended on a pipeline that failed: walking back from
//! that list's end, each pipeline whose running is open and that would show
//! it succeeded did not run either, up to the first that ran or would not
//! show it succeeded. A read whose running stays open stands. A read
//! tool's or a skill's read never stands in a failed call; a read that
//! stands has unclear figures.
//!
//! A source's bytes are measured from the record, and unclear where a
//! result's text is not its row's (a Copilot skill's body). Its tokens are
//! measured where the harness counts each result itself, and otherwise
//! attributed from the responses around it: the prompt of a response, less
//! the prompt and output of the response before it, is what the record
//! between them added. That growth goes to a source only where everything
//! between the two responses belongs to it, and to one item or section only
//! where it is alone there, the call having run nothing else; any other
//! share is unclear. So a gap that holds injected text beside a turn or a
//! result leaves each share in it unclear, and so does a gap that also
//! holds a result the harness counted: that count is the harness's own,
//! not shown to be in the provider's tokens, so the growth less it is no
//! figure for the rest. A response whose usage its writer never counted
//! ([`Response::Uncounted`]) closes no gap: the next response's growth
//! also holds its output, and every share of that gap is unclear. The
//! first response's prompt also holds the harness's own prompt and tools,
//! which no record names apart, so the first delivery's tokens are
//! unsupported.

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
use crate::session::{self, Action, Entry, Failed};

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
    InjectedText,
}

const SOURCES: [Source; 5] = [
    Source::FirstDelivery,
    Source::LaterTurns,
    Source::RuleReads,
    Source::ToolResults,
    Source::InjectedText,
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
    /// Whether the gap also holds an uncounted response's output.
    uncounted: bool,
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
            uncounted: false,
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
            Entry::Foreign { bytes } => {
                self.push(Source::InjectedText, Some(bytes), Share::Pending);
            }
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
                failed,
            } => {
                let share = tokens.map_or(Share::Pending, Share::Own);
                let (turn, mut rules) = match self.calls.get(&call) {
                    Some(named) => (named.turn.clone(), named.rules.clone()),
                    None => (self.turn.clone(), Rules::default()),
                };
                // A result that names what it loaded is that skill's read,
                // whether or not the record kept its call.
                if let Some(name) = loaded {
                    rules
                        .reads
                        .retain(|rule| !matches!(rule.read, Read::Skill { .. }));
                    rules.reads.push(Rule {
                        read: Read::Skill { name: Some(name) },
                        by: None,
                    });
                }
                let source = if rules.reads.is_empty() {
                    Source::ToolResults
                } else {
                    Source::RuleReads
                };
                let item = self.push(source, bytes, share);
                let shared = rules.reads.len() > 1 || rules.more || failed.is_some();
                let reads = match &failed {
                    Some(failed) => stood(rules, failed),
                    None => rules.reads.into_iter().map(|rule| rule.read).collect(),
                };
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
            Response::Uncounted { .. } => {
                if self.turns == 1 {
                    self.start.tokens = Figure::Unsupported;
                }
                self.uncounted = true;
                return;
            }
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
        let uncounted = std::mem::take(&mut self.uncounted);
        let pending = self.pending(&gap);
        if pending.is_empty() {
            return;
        }
        let counted = pending.len() < gap.len();
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
        if uncounted || counted {
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

    /// The items of `gap` whose share is still open: every item but one
    /// the harness counted.
    fn pending(&self, gap: &[usize]) -> Vec<usize> {
        gap.iter()
            .copied()
            .filter(|&i| self.items[i].share == Share::Pending)
            .collect()
    }

    fn settle(&mut self, items: &[usize], share: Share) {
        for &i in items {
            self.items[i].share = share;
        }
    }

    fn report(mut self) -> Report {
        let gap = std::mem::take(&mut self.gap);
        let open = self.pending(&gap);
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

/// The reads of a failed call that its result does not show printed
/// nothing: none where it does not show the shell ran to its exit status,
/// nor where the call turns on errexit or pipefail ([`Rules::options`]),
/// under which a failed command stops the shell, or fails a pipeline its
/// last command does not. A shell read is dropped where its command's own
/// error line names its operand, or where the shell skipped that command
/// ([`skipped`]). A `jarvis-section` read is also dropped where its
/// command failed, and stands only where `text` holds its heading line on
/// at least as many lines as the call has standing reads of that heading,
/// since a line the result holds once cannot tell two such reads apart, and
/// a child heading another read printed is no line of its own.
fn stood(rules: Rules, failed: &Failed) -> Vec<Read> {
    let text = match failed {
        Failed::Exited(text) if !rules.options => text.as_str(),
        Failed::Exited(_) | Failed::Unshown => return Vec::new(),
    };
    let skipped = skipped(&rules.commands, text, !rules.incomplete);
    let shown: Vec<Rule> = rules
        .reads
        .into_iter()
        .filter(|rule| {
            let Some(by) = rule.by else {
                return false;
            };
            let command = &rules.commands[by];
            !skipped[by]
                && match &rule.read {
                    Read::File { file } => !command.complains(file, text),
                    Read::Section { .. } => command.status(text) != Status::Failed,
                    Read::Skill { .. } | Read::Unreadable => false,
                }
        })
        .collect();
    let headings: Vec<Option<&str>> = shown
        .iter()
        .map(|rule| match &rule.read {
            Read::Section { heading, .. } => Some(heading.as_str()),
            Read::File { .. } | Read::Skill { .. } | Read::Unreadable => None,
        })
        .collect();
    let stands: Vec<bool> = headings
        .iter()
        .map(|own| match own {
            Some(own) => {
                let sharing = headings
                    .iter()
                    .filter(|other| *other == &Some(*own))
                    .count();
                printed(own, text) >= sharing
            }
            None => true,
        })
        .collect();
    shown
        .into_iter()
        .zip(stands)
        .filter_map(|(rule, stands)| stands.then_some(rule.read))
        .collect()
}

/// The lines of `text` that are the ATX heading `heading`, which
/// `jarvis-section` prints its section from (skills/jarvis/scripts/
/// jarvis-section, its heading rule in the jarvis lib's `sections.py`).
fn printed(heading: &str, text: &str) -> usize {
    text.lines()
        .filter(|line| heading_title(line) == Some(heading))
        .count()
}

/// The status a command ends with where it runs, as its result shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Ok,
    Failed,
    Unknown,
}

/// The pipelines of a failed call, in order: the commands each spans, how
/// it joins the one before, and the status of its last command, which is
/// the pipeline's.
struct Pipeline {
    join: Join,
    commands: std::ops::Range<usize>,
    status: Status,
}

/// Whether the shell skipped each of `commands`, as far as the failed
/// call's result `text` shows. A pipeline after `&&` runs only where the
/// one before ended `Ok`, and one after `||` only where it ended `Failed`;
/// a skipped pipeline leaves that status as it was. If the last list
/// failed, a trailing pipeline that would end `Ok` did not run.
fn skipped(commands: &[Command], text: &str, last_list_failed: bool) -> Vec<bool> {
    let mut pipelines: Vec<Pipeline> = Vec::new();
    for (i, command) in commands.iter().enumerate() {
        let status = command.status(text);
        match (command.join, pipelines.last_mut()) {
            (Join::Pipe, Some(last)) => {
                last.commands.end = i + 1;
                last.status = status;
            }
            (join, _) => pipelines.push(Pipeline {
                join,
                commands: i..i + 1,
                status,
            }),
        }
    }
    // Some(true) where the pipeline ran, Some(false) where the shell
    // skipped it, None where the result cannot tell.
    let mut ran: Vec<Option<bool>> = Vec::with_capacity(pipelines.len());
    let (mut so_far, mut last_list) = (Status::Unknown, 0);
    for (i, pipeline) in pipelines.iter().enumerate() {
        let runs = match (pipeline.join, so_far) {
            // A call that opens with `|` joins nothing before it.
            (Join::List | Join::Pipe, _) => {
                last_list = i;
                Some(true)
            }
            (Join::And, Status::Ok) | (Join::Or, Status::Failed) => Some(true),
            (Join::And, Status::Failed) | (Join::Or, Status::Ok) => Some(false),
            (Join::And | Join::Or, Status::Unknown) => None,
        };
        so_far = match runs {
            Some(true) => pipeline.status,
            Some(false) => so_far,
            None => Status::Unknown,
        };
        ran.push(runs);
    }
    if !last_list_failed {
        last_list = ran.len();
    }
    for (runs, pipeline) in ran[last_list..]
        .iter_mut()
        .zip(&pipelines[last_list..])
        .rev()
    {
        match (*runs, pipeline.status) {
            (Some(false), _) => {}
            (None, Status::Ok) => *runs = Some(false),
            (Some(true), _) | (None, Status::Failed | Status::Unknown) => break,
        }
    }
    let mut skipped = vec![false; commands.len()];
    for (pipeline, runs) in pipelines.iter().zip(ran) {
        if runs == Some(false) {
            skipped[pipeline.commands.clone()].fill(true);
        }
    }
    skipped
}

/// The title of an ATX heading line, as `sections.py` reads one: up to
/// three spaces, one to six `#`, then the title after a space or tab, less
/// a closing run of `#` after one.
fn heading_title(line: &str) -> Option<&str> {
    let rest = line.strip_suffix('\r').unwrap_or(line);
    let marks = rest.trim_start_matches(' ');
    if rest.len() - marks.len() > 3 {
        return None;
    }
    let title = marks.trim_start_matches('#');
    if !(1..=6).contains(&(marks.len() - title.len())) {
        return None;
    }
    if !title.is_empty() && !title.starts_with([' ', '\t']) {
        return None;
    }
    let title = title.trim_matches([' ', '\t']);
    let open = title.trim_end_matches('#');
    let title = match open.strip_suffix([' ', '\t']) {
        Some(_) if open.len() < title.len() => open,
        _ => title,
    };
    Some(title.trim_matches([' ', '\t']))
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

/// What a call reads as rules, whether its result may also hold the output
/// of something else the call ran, which no read owns, and, for a shell
/// command, each command it names.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Rules {
    reads: Vec<Rule>,
    more: bool,
    commands: Vec<Command>,
    incomplete: bool,
    /// Whether a `set` command of the call turns on errexit or pipefail
    /// ([`sets_failure_options`]), which [`skipped`] does not follow.
    options: bool,
}

/// One rule read, and the index in [`Rules::commands`] of the shell
/// command that makes it: `None` for a read tool's or a skill's.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Rule {
    read: Read,
    by: Option<usize>,
}

/// The operator before a command of a shell call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Join {
    /// None, or `;`, `&` or a newline: the command opens a list.
    List,
    And,
    Or,
    /// `|` or `|&`.
    Pipe,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Command {
    join: Join,
    /// `None` for a program whose status its result cannot show.
    reader: Option<Reader>,
}

/// A read program: each of its error lines begins with its prefix and
/// names the operand it failed on, and it prints none where it succeeds.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Reader {
    /// The program word as the call writes it, which GNU coreutils begins
    /// its error lines with (`/usr/bin/cat: F: ...`, 9.4, measured);
    /// `jarvis-section` begins each of its own with its name.
    prefix: String,
    operands: Vec<String>,
    /// Whether its standard error reaches the result ([`words`]), so that
    /// an error line it wrote is there.
    stderr: bool,
}

impl Command {
    /// Its status as the result shows it: an error line of its own shows
    /// it failed, and the lack of one shows it succeeded only where its
    /// standard error reaches the result.
    fn status(&self, text: &str) -> Status {
        match &self.reader {
            None => Status::Unknown,
            Some(reader) if reader.operands.iter().any(|o| self.complains(o, text)) => {
                Status::Failed
            }
            Some(reader) if !reader.stderr => Status::Unknown,
            Some(_) => Status::Ok,
        }
    }

    /// Whether `text` holds an error line of this command's own naming
    /// `operand`: bare or quoted, then a colon or the closing quote. GNU
    /// coreutils 9.4 writes `cat: F: ...`, `nl: F: ...`, `sed: can't read
    /// F: ...`, `head: cannot open 'F' for reading: ...` (measured);
    /// `jarvis-section` writes `jarvis-section: {"file": "F", ...}`.
    fn complains(&self, operand: &str, text: &str) -> bool {
        let Some(reader) = &self.reader else {
            return false;
        };
        !operand.is_empty()
            && text
                .lines()
                .filter_map(|line| {
                    line.strip_prefix(reader.prefix.as_str())?
                        .strip_prefix(": ")
                })
                .any(|rest| {
                    rest.match_indices(operand).any(|(at, _)| {
                        let before = rest[..at].chars().next_back();
                        let after = rest[at + operand.len()..].chars().next();
                        matches!(before, None | Some(' ' | '\'' | '"'))
                            && matches!(after, Some(':' | '\'' | '"'))
                    })
                })
    }
}

/// Where a command's standard output or standard error goes, a pipe
/// after it aside: only a pipeline's last command shows the pipeline's
/// status, and a printer that writes into a pipe still reads its file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sink {
    /// The call's result.
    Result,
    /// A file, a descriptor this reader does not follow, or nowhere
    /// (`>&-`).
    Away,
}

/// A command's words, less its redirections and a heredoc's or
/// here-string's word, an input redirection's file being one of them, and
/// where its standard output and standard error go.
struct Words<'a> {
    words: Vec<&'a str>,
    stdout: Sink,
    stderr: Sink,
}

/// The words of `segment`, with each redirection applied in order as the
/// shell applies it: `N>F`, `N>>F` and `N>|F` send descriptor N (1 where
/// none is written) to a file, `&>F`, `&>>F` and `>&F` send both, `N>&M`
/// sends N where M goes at that point, and `N>&-` closes N. A `>` inside a
/// word that opens no redirection, as in a quoted script, makes no word.
fn words(segment: &str) -> Words<'_> {
    let (mut stdout, mut stderr) = (Sink::Result, Sink::Result);
    let digits = |word: &str| !word.is_empty() && word.bytes().all(|b| b.is_ascii_digit());
    let mut words = Vec::new();
    let mut all = segment
        .split_whitespace()
        .map(|word| word.trim_matches(['\'', '"']));
    while let Some(word) = all.next() {
        if let Some((fd, rest)) = word.split_once('>') {
            let (out, err) = match fd {
                "" | "1" => (true, false),
                "2" => (false, true),
                "&" => (true, true),
                fd if digits(fd) => (false, false),
                _ => continue,
            };
            let rest = rest.strip_prefix(['>', '|']).unwrap_or(rest);
            let (dup, rest) = rest
                .strip_prefix('&')
                .map_or((false, rest), |rest| (true, rest));
            let target = if rest.is_empty() {
                all.next().unwrap_or_default()
            } else {
                rest
            };
            let (sink, out, err) = match (dup, target) {
                (true, "1") => (stdout, out, err),
                (true, "2") => (stderr, out, err),
                (true, target) if fd.is_empty() && !digits(target) && target != "-" => {
                    (Sink::Away, true, true)
                }
                _ => (Sink::Away, out, err),
            };
            if out {
                stdout = sink;
            }
            if err {
                stderr = sink;
            }
            continue;
        }
        if word.contains("<<") {
            if word.ends_with('<') {
                all.next();
            }
            continue;
        }
        let word = word.strip_prefix('<').unwrap_or(word);
        if !word.is_empty() {
            words.push(word);
        }
    }
    Words {
        words,
        stdout,
        stderr,
    }
}

/// Whether the words after `set` turn on errexit (`-e`, `-o errexit`) or
/// pipefail (`-o pipefail`), alone or in a cluster such as `-euo
/// pipefail`, before `--` or the first positional word.
fn sets_failure_options(words: &[&str]) -> bool {
    // Some(on) while the next word names the option a `-o` or `+o` sets.
    let mut named: Option<bool> = None;
    for word in words {
        if let Some(on) = named.take() {
            if on && matches!(*word, "errexit" | "pipefail") {
                return true;
            }
            continue;
        }
        let (on, flags) = match (word.strip_prefix('-'), word.strip_prefix('+')) {
            (Some("" | "-"), _) | (None, None) => return false,
            (Some(flags), _) => (true, flags),
            (None, Some(flags)) => (false, flags),
        };
        if on && flags.contains('e') {
            return true;
        }
        if flags.contains('o') {
            named = Some(on);
        }
    }
    false
}

enum ShellFrame {
    Single,
    Double,
    AnsiC,
    Substitution(usize),
    Parenthesis,
}

/// The segments of a shell command, each with the operator before it: a
/// `;`, `&`, `&&`, `|`, `||`, `|&` or newline outside quotes and not
/// escaped, the `&` of a redirection (`2>&1`, `>&2`, `&>F`) being none. A
/// newline right after `&&`, `||` or `|` continues the list, as the shell
/// reads it. A comment, from a `#` that opens a word to the end of its
/// line, and a heredoc's body, from the newline after `<<WORD` or
/// `<<-WORD` to the line that is its word, are in no segment; a `<<` with
/// no such line after it opens no body. An unclosed quote prevents Bash
/// from executing any segment of the incomplete input line, reported by
/// the second return value.
fn segments(command: &str) -> (Vec<(Join, &str)>, bool) {
    let bytes = command.as_bytes();
    let (mut out, mut join, mut start, mut i) = (Vec::new(), Join::List, 0, 0);
    let mut complete = 0;
    let mut frames = Vec::new();
    let mut word_start = true;
    // Where a comment ends the current segment.
    let mut cut: Option<usize> = None;
    // A substitution's newlines open only its own pending heredocs.
    let (mut heredocs, mut heredoc_base) = (Vec::new(), 0);
    while i < bytes.len() {
        let byte = bytes[i];
        let after = bytes.get(i + 1).copied();
        let starts_word = word_start;
        word_start = breaks(byte) || (byte, after) == (b'\\', Some(b'\n')) && starts_word;
        let consumed = match (frames.last(), byte, after) {
            (Some(ShellFrame::Double | ShellFrame::AnsiC), b'\\', _) => 2,
            (Some(frame), b'$', Some(b'('))
                if !matches!(frame, ShellFrame::Single | ShellFrame::AnsiC) =>
            {
                frames.push(ShellFrame::Substitution(heredoc_base));
                heredoc_base = heredocs.len();
                word_start = true;
                2
            }
            (Some(ShellFrame::Substitution(base)), b')', _) => {
                heredocs.truncate(heredoc_base);
                heredoc_base = *base;
                frames.pop();
                word_start = false;
                1
            }
            (Some(ShellFrame::Single | ShellFrame::AnsiC), b'\'', _)
            | (Some(ShellFrame::Double), b'"', _)
            | (Some(ShellFrame::Parenthesis), b')', _) => {
                frames.pop();
                1
            }
            (Some(ShellFrame::Single | ShellFrame::Double | ShellFrame::AnsiC), _, _) => 1,
            (_, b'$', Some(b'\'')) => {
                frames.push(ShellFrame::AnsiC);
                2
            }
            (_, b'\'', _) => {
                frames.push(ShellFrame::Single);
                1
            }
            (_, b'"', _) => {
                frames.push(ShellFrame::Double);
                1
            }
            (Some(ShellFrame::Substitution(_) | ShellFrame::Parenthesis), b'(', _) => {
                frames.push(ShellFrame::Parenthesis);
                1
            }
            (_, b'\\', _) => 2,
            _ => 0,
        };
        if consumed != 0 {
            i += consumed;
            continue;
        }
        if byte == b'#' && starts_word {
            if frames.is_empty() {
                cut = Some(i);
            }
            i = command[i..].find('\n').map_or(bytes.len(), |n| i + n);
            continue;
        }
        if byte == b'<' && after == Some(b'<') {
            if bytes.get(i + 2) == Some(&b'<') {
                i += 3;
                continue;
            }
            match heredoc_word(bytes, i + 2, &mut heredocs) {
                Some(end) => i = end,
                None => break,
            }
            word_start = false;
            continue;
        }
        let mut body = i + 1;
        if byte == b'\n' {
            for (word, strip) in heredocs.drain(heredoc_base..) {
                body = body_end(command, body, &word, strip).unwrap_or(body);
            }
        }
        if !frames.is_empty() {
            i = body;
            continue;
        }
        let redirect =
            byte == b'&' && (after == Some(b'>') || (i > 0 && matches!(bytes[i - 1], b'>' | b'<')));
        let (next, width) = match (byte, after) {
            (b'&', _) if redirect => {
                i += 1;
                continue;
            }
            (b'&', Some(b'&')) => (Join::And, 2),
            (b'|', Some(b'|')) => (Join::Or, 2),
            (b'|', Some(b'&')) => (Join::Pipe, 2),
            (b'|', _) => (Join::Pipe, 1),
            (b';' | b'&' | b'\n', _) => (Join::List, 1),
            _ => {
                i += 1;
                continue;
            }
        };
        let segment = &command[start..cut.take().unwrap_or(i)];
        if !segment.trim().is_empty() {
            out.push((join, segment));
            join = next;
        } else if byte != b'\n' {
            join = next;
        }
        i = (i + width).max(body);
        if byte == b'\n' && join == Join::List {
            complete = out.len();
        }
        start = i;
    }
    if i < bytes.len() || !frames.is_empty() {
        out.truncate(complete);
        return (out, true);
    }
    let rest = &command[start..cut.unwrap_or(bytes.len())];
    if !rest.trim().is_empty() {
        out.push((join, rest));
    }
    (out, false)
}

/// Whether `byte` is a shell metacharacter, which ends a word.
fn breaks(byte: u8) -> bool {
    matches!(
        byte,
        b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>'
    )
}

/// Queue the delimiter of a heredoc with its quotes and escapes removed.
/// An unclosed quote leaves the whole input unfinished.
fn heredoc_word(bytes: &[u8], at: usize, pending: &mut Vec<(Vec<u8>, bool)>) -> Option<usize> {
    let strip = bytes.get(at) == Some(&b'-');
    let mut i = at + usize::from(strip);
    while matches!(bytes.get(i), Some(b' ' | b'\t')) {
        i += 1;
    }
    let start = i;
    let mut word = Vec::new();
    let mut quote = None;
    while let Some(&byte) = bytes.get(i) {
        match (quote, byte) {
            (None, byte) if breaks(byte) => break,
            (None, b'\'' | b'"') => quote = Some(byte),
            (Some(open), byte) if byte == open => quote = None,
            (None | Some(b'"'), b'\\')
                if quote.is_none() || bytes.get(i + 1).is_some_and(|b| b"\\\"$`\n".contains(b)) =>
            {
                i += 1;
                word.extend(bytes.get(i).filter(|&&b| b != b'\n'));
            }
            _ => word.push(byte),
        }
        i += 1;
    }
    if quote.is_none() && i != start {
        pending.push((word, strip));
    }
    quote.is_none().then_some(i.min(bytes.len()))
}

/// The index after the line from `at` on that is the heredoc word `word`,
/// its leading tabs stripped where `strip`: `None` where no line is.
fn body_end(command: &str, at: usize, word: &[u8], strip: bool) -> Option<usize> {
    let mut i = at;
    while i < command.len() {
        let end = command[i..].find('\n').map_or(command.len(), |n| i + n);
        let line = &command[i..end];
        let line = if strip {
            line.trim_start_matches('\t')
        } else {
            line
        };
        i = (end + 1).min(command.len());
        if line.as_bytes() == word {
            return Some(i);
        }
    }
    None
}

/// How a `head` or `tail` option word sets the count: its value, or the
/// next word's.
enum Count<'a> {
    Is(&'a str),
    Next,
}

/// The count an option word of `head` or `tail` sets: `-n N`, `-nN`, `-c
/// N`, `-cN`, `--lines[=]N`, `--bytes[=]N`, and the obsolete `-N`.
fn count(word: &str) -> Option<Count<'_>> {
    if let Some(long) = word.strip_prefix("--") {
        return match long.split_once('=') {
            Some(("lines" | "bytes", value)) => Some(Count::Is(value)),
            None if matches!(long, "lines" | "bytes") => Some(Count::Next),
            Some(_) | None => None,
        };
    }
    let short = word.strip_prefix('-')?;
    match short.bytes().next() {
        Some(b'n' | b'c') if short.len() > 1 => Some(Count::Is(&short[1..])),
        Some(b'n' | b'c') => Some(Count::Next),
        Some(b'0'..=b'9') => Some(Count::Is(short)),
        Some(_) | None => None,
    }
}

/// The one table of what a call reads as rules: a read of a Markdown file,
/// a skill load, and in a shell command each `jarvis-section` and each
/// Markdown operand of a [`PRINTERS`] program. A command splits where
/// [`segments`] splits it, into the words [`words`] reads. A printer whose
/// standard output goes to a file reads nothing into the result, nor does
/// a `sed` that edits its files in place, nor a `head` or `tail` of zero
/// lines or bytes, which prints at most a file's header (GNU coreutils
/// 9.4, measured); one whose output goes where its standard error goes
/// (`>&2`) still does, unless that is a file. A segment that reads no
/// rule, and a `cat` operand that is not Markdown, is more output; another
/// printer's other operands are taken for its script or count.
fn rule_reads(action: &Action) -> Rules {
    let command = match action {
        Action::Read(path) if path.ends_with(".md") => {
            return Rules {
                reads: vec![Rule {
                    read: Read::File { file: path.clone() },
                    by: None,
                }],
                ..Rules::default()
            };
        }
        Action::Skill(name) => {
            return Rules {
                reads: vec![Rule {
                    read: Read::Skill { name: name.clone() },
                    by: None,
                }],
                ..Rules::default()
            };
        }
        Action::Shell(command) => command,
        Action::Read(_) | Action::Other => return Rules::default(),
    };
    let mut rules = Rules::default();
    let (segments, incomplete) = segments(command);
    for (join, segment) in segments {
        let shape = words(segment);
        let Some((&program, args)) = shape.words.split_first() else {
            continue;
        };
        let stderr = shape.stderr == Sink::Result;
        let by = rules.commands.len();
        let before = rules.reads.len();
        let reader = match program.rsplit('/').next().unwrap_or(program) {
            "jarvis-section" => {
                let found = SECTION.captures(segment);
                let read = found.as_ref().map_or(Read::Unreadable, |found| {
                    let operand = |first: usize| {
                        (first..first + 3)
                            .find_map(|i| found.get(i))
                            .map_or_else(String::new, |m| m.as_str().to_owned())
                    };
                    Read::Section {
                        file: operand(1),
                        heading: operand(4),
                    }
                });
                let reader = match &read {
                    Read::Section { file, heading } => Some(Reader {
                        prefix: "jarvis-section".to_owned(),
                        operands: vec![file.clone(), heading.clone()],
                        stderr,
                    }),
                    Read::File { .. } | Read::Skill { .. } | Read::Unreadable => None,
                };
                rules.reads.push(Rule { read, by: Some(by) });
                reader
            }
            "set" => {
                rules.options |= sets_failure_options(args);
                None
            }
            name if PRINTERS.contains(&name) => {
                let counted = matches!(name, "head" | "tail");
                let (mut reads, mut operands) = (Vec::new(), Vec::new());
                let mut moved = shape.stdout == Sink::Away;
                let (mut zero, mut count_next) = (false, false);
                let is_zero = |value: &str| !value.is_empty() && value.bytes().all(|b| b == b'0');
                for &word in args {
                    if std::mem::take(&mut count_next) {
                        zero = is_zero(word);
                        continue;
                    }
                    if word.starts_with('-') {
                        moved |= name == "sed" && sed_in_place(word);
                        match count(word).filter(|_| counted) {
                            Some(Count::Is(value)) => zero = is_zero(value),
                            Some(Count::Next) => count_next = true,
                            None => {}
                        }
                        continue;
                    }
                    operands.push(word.to_owned());
                    if word.ends_with(".md") {
                        reads.push(Rule {
                            read: Read::File {
                                file: word.to_owned(),
                            },
                            by: Some(by),
                        });
                    } else if name == "cat" {
                        rules.more = true;
                    }
                }
                if !moved && !zero {
                    rules.reads.extend(reads);
                }
                Some(Reader {
                    prefix: program.to_owned(),
                    operands,
                    stderr,
                })
            }
            _ => None,
        };
        rules.commands.push(Command { join, reader });
        rules.more |= rules.reads.len() == before;
    }
    rules.incomplete = incomplete;
    rules
}

/// Whether a `sed` option word edits the files in place, printing none of
/// them: GNU's `-i[SUFFIX]` and `--in-place[=SUFFIX]`, BSD's `-i` and `-I`,
/// alone or in a short option cluster (`-Ei`).
fn sed_in_place(word: &str) -> bool {
    match word.strip_prefix("--") {
        Some(long) => long == "in-place" || long.starts_with("in-place="),
        None => word.contains(['i', 'I']),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn section(file: &str, heading: &str) -> Read {
        Read::Section {
            file: file.to_owned(),
            heading: heading.to_owned(),
        }
    }

    fn file(file: &str) -> Read {
        Read::File {
            file: file.to_owned(),
        }
    }

    fn shell(command: &str) -> Action {
        Action::Shell(command.to_owned())
    }

    fn exited(text: &str) -> Failed {
        Failed::Exited(text.to_owned())
    }

    /// Each row: the call, what it reads, and whether its result may hold
    /// output no read owns.
    #[test]
    fn a_call_reads_as_rules_by_the_one_table() {
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
            (shell("sed -n '1,40p' a.md"), vec![file("a.md")], false),
            // A quoted `;` splits nothing.
            (shell("sed -n '1,5p;10p' a.md"), vec![file("a.md")], false),
            (shell("sed -i 's/a/b/' a.md"), vec![], true),
            (shell("sed -Ei 's/a/b/' a.md"), vec![], true),
            (shell("sed --in-place=.bak 's/a/b/' a.md"), vec![], true),
            // A count of zero, in each form that names one, and `+0`,
            // which is the whole file.
            (shell("head -n 0 a.md b.md"), vec![], true),
            (shell("tail -c0 a.md"), vec![], true),
            (shell("head --lines=0 a.md"), vec![], true),
            (shell("head -0 a.md"), vec![], true),
            (shell("tail -n +0 a.md"), vec![file("a.md")], false),
            // A comment and a heredoc's body hold no operator, no quote
            // and no operand.
            (
                shell("# Check the skill's header\nhead -20 SKILL.md"),
                vec![file("SKILL.md")],
                false,
            ),
            (
                shell("printf '%s\\n' begin # don't include rules in this line\nhead -1 AGENTS.md"),
                vec![file("AGENTS.md")],
                true,
            ),
            (shell("cat a.md # then b.md"), vec![file("a.md")], false),
            // A `#` inside a word opens no comment.
            (shell("echo ${#x}; cat a.md"), vec![file("a.md")], true),
            (
                shell("gh pr comment 1 -F - <<'EOF'\nDon't ship\nEOF\ncat AGENTS.md"),
                vec![file("AGENTS.md")],
                true,
            ),
            (
                shell("cat <<-EOF > notes.txt\n\tit's b.md\n\tEOF\ncat a.md"),
                vec![file("a.md")],
                true,
            ),
            // A `<<` with no line of its word after it opens no body.
            (shell("echo $((1<<2))\ncat a.md"), vec![file("a.md")], true),
        ];
        let a_only = [
            r#"printf '%s\n' "$(printf '%s' "
cat AGENTS.md
it's done
")"
cat a.md"#,
            "echo $'it\\'s'; cat a.md",
            "printf '%s\\n' \"$(cat <<'END'\nit's done\nEND\n)\"\ncat a.md",
            "printf '%s\\n' \"$(printf %s hello\\ #tag)\"\ncat a.md",
        ]
        .map(|command| (shell(command), vec![file("a.md")], true));
        for (action, reads, more) in rows.into_iter().chain(a_only) {
            let rules = rule_reads(&action);
            let got: Vec<Read> = rules.reads.into_iter().map(|rule| rule.read).collect();
            assert_eq!((got, rules.more), (reads, more), "{action:?}");
        }
    }

    /// Each row: a failed call, what its result shows, and the reads that
    /// stand. An exited row's text is what its command printed under bash
    /// with GNU coreutils 9.4 and the jarvis `jarvis-section`, except a
    /// heading row's, which is built.
    #[test]
    fn a_failed_calls_read_stands_unless_its_result_shows_it_printed_nothing() {
        let unfinished = [
            ("echo it's done\ncat a.md", 1, false),
            ("cat a.md\necho it's\ncat b.md", 2, true),
            ("gh pr comment 1 -b 'Don't ship'\ncat AGENTS.md", 1, false),
            // A separator can end a segment before Bash can execute its line.
            ("cat a.md\ncat b.md; echo it's\ncat AGENTS.md", 2, true),
            ("cat a.md\ncat b.md |\necho it's\ncat AGENTS.md", 3, true),
            ("true && cat a.md\necho it's done\ncat b.md", 2, true),
            ("cat a.md; cat <<'END\ncat b.md", 1, false),
        ]
        .map(|(command, line, read)| {
            let stdout = if read { "# A\n" } else { "" };
            let failed = exited(&format!(
                "{stdout}bash: -c: line {line}: unexpected EOF while looking for matching `''\n"
            ));
            let want = read.then(|| file("a.md")).into_iter().collect();
            (shell(command), failed, want)
        });
        let rows: Vec<(Action, Failed, Vec<Read>)> = vec![
            // The read before the failed part printed.
            (
                shell("cat README.md && cat missing.md"),
                exited("# Readme\n\nThe readme.\ncat: missing.md: No such file or directory\n"),
                vec![file("README.md")],
            ),
            (
                shell("cat AGENTS.md CLAUDE.md"),
                exited("# Rules\n\nThe rules.\ncat: CLAUDE.md: No such file or directory\n"),
                vec![file("AGENTS.md")],
            ),
            // An error line names an operand only whole.
            (
                shell("cat AGENTS.md crates/AGENTS.md"),
                exited("# Rules\n\nThe rules.\ncat: crates/AGENTS.md: No such file or directory\n"),
                vec![file("AGENTS.md")],
            ),
            (
                shell("sed -n '1,200p' SKILL.md && grep -n nomatch src/lib.rs"),
                exited("---\nname: x\n---\n\n# X\n"),
                vec![file("SKILL.md")],
            ),
            // head quotes the operand it failed on.
            (
                shell("head -5 AGENTS.md CLAUDE.md"),
                exited(
                    "==> AGENTS.md <==\n# Rules\n\nThe rules.\nhead: cannot open 'CLAUDE.md' for reading: No such file or directory\n",
                ),
                vec![file("AGENTS.md")],
            ),
            // `||` runs the right side where the left failed.
            (
                shell("cat missing.md || cat AGENTS.md CLAUDE.md"),
                exited(
                    "cat: missing.md: No such file or directory\n# Rules\n\nThe rules.\ncat: CLAUDE.md: No such file or directory\n",
                ),
                vec![file("AGENTS.md")],
            ),
            // A pipeline's status is its last command's: cat failed on
            // missing.md, grep matched, so `&&` ran b.md's cat.
            (
                shell("cat a.md missing.md | grep -c Rule && cat b.md; ls gone"),
                exited(
                    "cat: missing.md: No such file or directory\n1\n# B\nls: cannot access 'gone': No such file or directory\n",
                ),
                vec![file("a.md"), file("b.md")],
            ),
            // The call failed, so a read that would have succeeded last in
            // it never ran, a newline after `&&` continuing the list.
            (shell("grep -q nomatch f && cat a.md"), exited(""), vec![]),
            (
                shell("grep -q nomatch f && cat a.md && cat b.md"),
                exited(""),
                vec![],
            ),
            (
                shell("grep -q nomatch f && cat a.md | head -3"),
                exited(""),
                vec![],
            ),
            (shell("grep -q nomatch f &&\ncat a.md"), exited(""), vec![]),
            (
                shell("ls /nonexistent && jarvis-section persona.md Role"),
                exited("ls: cannot access '/nonexistent': No such file or directory\n"),
                vec![],
            ),
            // A command whose standard error is moved shows neither that
            // it failed nor that it succeeded, so no read after it is
            // skipped and no read of it is dropped.
            (
                shell("grep -q Rules AGENTS.md && cat AGENTS.md missing.md 2>/dev/null"),
                exited("# Rules\n\nThe rules.\n"),
                vec![file("AGENTS.md"), file("missing.md")],
            ),
            (
                shell("cat missing.md 2>/dev/null || cat b.md; ls gone"),
                exited("# B\nls: cannot access 'gone': No such file or directory\n"),
                vec![file("missing.md"), file("b.md")],
            ),
            // A quoted `;` opens no list, and `2>&1` joins nothing: the
            // `&&` after each still skips.
            (
                shell("cat missing.md && sed -n '1;2p' f && cat a.md; ls gone"),
                exited(
                    "cat: missing.md: No such file or directory\nls: cannot access 'gone': No such file or directory\n",
                ),
                vec![],
            ),
            (
                shell("cat missing.md 2>&1 && cat a.md; ls gone"),
                exited(
                    "cat: missing.md: No such file or directory\nls: cannot access 'gone': No such file or directory\n",
                ),
                vec![],
            ),
            // `2>&1` keeps an error line in the result, so the read that
            // shows none succeeded and, last in a failed call, never ran;
            // `>& F` moves it, so the `&&` after it stays open.
            (
                shell("cd sub && cat AGENTS.md 2>&1"),
                exited("/bin/bash: line 1: cd: sub: No such file or directory\n"),
                vec![],
            ),
            (
                shell("test -f x && head -40 SKILL.md 2>&1"),
                exited(""),
                vec![],
            ),
            (
                shell("cat AGENTS.md 2>&1 || cat skills/AGENTS.md; false"),
                exited("# Rules\n\nThe rules.\n"),
                vec![file("AGENTS.md")],
            ),
            (
                shell("cat missing.md >& log && cat AGENTS.md"),
                exited(""),
                vec![],
            ),
            // Under errexit or pipefail no shell rule holds, so no read
            // stands; another option leaves the rules.
            (
                shell("set -e; cat missing.md; cat AGENTS.md"),
                exited("cat: missing.md: No such file or directory\n"),
                vec![],
            ),
            (
                shell("set -euo pipefail\ncat missing.md\ncat AGENTS.md"),
                exited("cat: missing.md: No such file or directory\n"),
                vec![],
            ),
            (
                shell(
                    "set -o pipefail; cat AGENTS.md missing.md | head -n 1 && cat NEVER.md; false",
                ),
                exited("# Rules\ncat: missing.md: No such file or directory\n"),
                vec![],
            ),
            (
                shell("set -u; cat README.md && cat missing.md"),
                exited("# Readme\n\nThe readme.\ncat: missing.md: No such file or directory\n"),
                vec![file("README.md")],
            ),
            // With no exit status shown, the shell may never have run.
            (
                shell("cat SKILL.md && make deploy"),
                Failed::Unshown,
                vec![],
            ),
            // A zero count reads nothing; head still prints the header.
            (
                shell("head -n 0 A.md missing.md"),
                exited(
                    "==> A.md <==\nhead: cannot open 'missing.md' for reading: No such file or directory\n",
                ),
                vec![],
            ),
            // persona.md's child heading is no line of the Role section,
            // which `&&` skipped once cat failed.
            (
                shell("cat persona.md missing.md && jarvis-section persona.md Role; ls gone"),
                exited(
                    "# Persona\n\n## Role\n\nThe role.\ncat: missing.md: No such file or directory\nls: cannot access 'gone': No such file or directory\n",
                ),
                vec![file("persona.md")],
            ),
            // a.md's Role heading is no line of b.md's failed section.
            (
                shell("cat a.md; jarvis-section b.md Role"),
                exited(
                    "# A\n\n## Role\n\nA's role.\njarvis-section: {\"error\": \"read-failed\", \"file\": \"b.md\", \"cause\": \"[Errno 2] No such file or directory: 'b.md'\"}\n",
                ),
                vec![file("a.md")],
            ),
            (
                shell("jarvis-section persona.md Role; ls missing"),
                exited(
                    "## Role\n\nThe role text.\n\nls: cannot access 'missing': No such file or directory\n",
                ),
                vec![section("persona.md", "Role")],
            ),
            // Two sections of one heading: where one failed, the line is
            // the other's; where neither shows it failed, one line is
            // neither's.
            (
                shell("jarvis-section a.md Role; jarvis-section b.md Role"),
                exited(
                    "## Role\n\nThe role text.\njarvis-section: {\"error\": \"read-failed\", \"file\": \"b.md\", \"cause\": \"[Errno 2] No such file or directory: 'b.md'\"}\n",
                ),
                vec![section("a.md", "Role")],
            ),
            (
                shell("jarvis-section a.md Role && grep -q x f && jarvis-section b.md Role; false"),
                exited("## Role\n\nThe role text.\n"),
                vec![],
            ),
            // A heading written with indent, a tab and a closing run.
            (
                shell("jarvis-section persona.md Role; false"),
                exited("   ##\tRole ##\r\nThe role text.\n"),
                vec![section("persona.md", "Role")],
            ),
            // A longer title, marks with no space after them and seven
            // marks are no Role heading.
            (
                shell("jarvis-section a.md Role; false"),
                exited("## Roles\n#Role\n####### Role\n"),
                vec![],
            ),
            (shell("jarvis-section \"$F\" 'One'"), exited(""), vec![]),
            // A failed read tool's result and a failed skill's.
            (
                Action::Read("/h/gone.md".to_owned()),
                Failed::Unshown,
                vec![],
            ),
            (Action::Skill(Some("x".to_owned())), Failed::Unshown, vec![]),
        ];
        for (action, failed, want) in unfinished.into_iter().chain(rows) {
            assert_eq!(
                stood(rule_reads(&action), &failed),
                want,
                "{action:?} in {failed:?}"
            );
        }
    }
}
