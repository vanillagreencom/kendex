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
//! failed call's result counts to its source, and a read of it stands only
//! where the result's text holds the line that read's output begins with
//! ([`printed`]): a Bash command that exits nonzero still returns what it
//! printed on Claude Code and Pi, so a read before the part that failed
//! may stand, and one the shell never ran does not. A read whose output
//! begins with no line of its own (a `cat`, `sed` or `nl` read, a `head`
//! or `tail` of one file, a read tool's or a skill's) never stands in a
//! failed call, nor do reads that share a line the result holds fewer
//! times than they do; a read that stands has unclear figures.
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
                let shared = reads.len() > 1 || more || failed.is_some();
                if let Some(text) = failed {
                    reads = stood(reads, &text);
                }
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

/// The reads of a failed call that the result's `text` shows ran: each
/// whose [`Marker`] it holds on at least as many lines as the call has
/// reads with that marker, since a line the result holds once cannot tell
/// two such reads apart.
fn stood(reads: Vec<Read>, text: &str) -> Vec<Read> {
    let markers: Vec<Option<Marker>> = reads.iter().map(marker).collect();
    let stands: Vec<bool> = markers
        .iter()
        .map(|own| {
            own.is_some_and(|own| {
                let sharing = markers.iter().filter(|other| **other == Some(own)).count();
                printed(own, text) >= sharing
            })
        })
        .collect();
    reads
        .into_iter()
        .zip(stands)
        .filter_map(|(read, stands)| stands.then_some(read))
        .collect()
}

/// The line a read's output begins with, where it has one of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Marker<'a> {
    /// `jarvis-section` prints the section from its ATX heading line on
    /// (skills/jarvis/scripts/jarvis-section, its heading rule in the
    /// jarvis lib's `sections.py`).
    Heading(&'a str),
    /// `head` and `tail` of several files print `==> FILE <==` before each
    /// file they open, and only those (GNU coreutils 9.4, measured; a
    /// printer that writes no such header leaves the read unshown).
    Header(&'a str),
}

fn marker(read: &Read) -> Option<Marker<'_>> {
    match read {
        Read::Section { heading, .. } => Some(Marker::Heading(heading)),
        Read::File { file } => Some(Marker::Header(file)),
        Read::Skill { .. } | Read::Unreadable => None,
    }
}

/// The lines of `text` that begin a read's output by `marker`.
fn printed(marker: Marker, text: &str) -> usize {
    text.lines()
        .filter(|line| match marker {
            Marker::Heading(heading) => heading_title(line) == Some(heading),
            Marker::Header(file) => {
                line.strip_prefix("==> ")
                    .and_then(|l| l.strip_suffix(" <=="))
                    == Some(file)
            }
        })
        .count()
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
/// standard output goes to a file reads nothing into the result, nor does
/// a `sed` that edits its files in place; one whose output goes to another
/// descriptor (`>&2`) still does. A segment that reads no rule, and a
/// `cat` operand that is not Markdown, is more output; another printer's
/// other operands are taken for its script or count.
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
                        moved |= name == "sed" && sed_in_place(word);
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
            (shell("sed -n '1,40p' a.md"), vec![file("a.md")], false),
            (shell("sed -i 's/a/b/' a.md"), vec![], true),
            (shell("sed -Ei 's/a/b/' a.md"), vec![], true),
            (shell("sed --in-place=.bak 's/a/b/' a.md"), vec![], true),
        ];
        for (action, reads, more) in rows {
            assert_eq!(rule_reads(&action), Rules { reads, more }, "{action:?}");
        }
    }

    /// Each row: a failed call's reads, the text its result sent, and the
    /// reads that stand. A row naming its command holds what that command
    /// printed under bash with GNU coreutils 9.4 and the jarvis
    /// `jarvis-section`.
    #[test]
    fn a_failed_calls_read_stands_only_where_its_result_holds_the_reads_output() {
        let section = |file: &str, heading: &str| Read::Section {
            file: file.to_owned(),
            heading: heading.to_owned(),
        };
        let file = |file: &str| Read::File {
            file: file.to_owned(),
        };
        let rows: Vec<(Vec<Read>, &str, Vec<Read>)> = vec![
            // ls /nonexistent && jarvis-section persona.md Role
            (
                vec![section("persona.md", "Role")],
                "ls: cannot access '/nonexistent': No such file or directory\n",
                vec![],
            ),
            // jarvis-section persona.md Role; ls missing
            (
                vec![section("persona.md", "Role")],
                "## Role\n\nThe role text.\n\nls: cannot access 'missing': No such file or directory\n",
                vec![section("persona.md", "Role")],
            ),
            // A heading written with indent, a tab and a closing run.
            (
                vec![section("persona.md", "Role")],
                "   ##\tRole ##\r\nThe role text.\n",
                vec![section("persona.md", "Role")],
            ),
            // jarvis-section persona.md Gone; false
            (
                vec![section("persona.md", "Gone")],
                "jarvis-section: {\"error\": \"unknown-heading\", \"heading\": \"Gone\", \"candidates\": [{\"heading\": \"Persona\", \"line\": 1}]}\n",
                vec![],
            ),
            // Two sections of one heading, one heading line printed.
            (
                vec![section("a.md", "Role"), section("b.md", "Role")],
                "## Role\n\nThe role text.\njarvis-section: {\"error\": \"read-failed\", \"file\": \"b.md\"}\n",
                vec![],
            ),
            // A longer title, marks with no space after them and seven
            // marks are no Role heading.
            (
                vec![section("a.md", "Role")],
                "## Roles\n#Role\n####### Role\n",
                vec![],
            ),
            // cat AGENTS.md CLAUDE.md: no line of AGENTS.md's own.
            (
                vec![file("AGENTS.md"), file("CLAUDE.md")],
                "# Rules\n\nThe rules.\ncat: CLAUDE.md: No such file or directory\n",
                vec![],
            ),
            // head -5 AGENTS.md CLAUDE.md
            (
                vec![file("AGENTS.md"), file("CLAUDE.md")],
                "==> AGENTS.md <==\n# Rules\n\nThe rules.\nhead: cannot open 'CLAUDE.md' for reading: No such file or directory\n",
                vec![file("AGENTS.md")],
            ),
            // head -3 AGENTS.md; ls missing: one file prints no header.
            (
                vec![file("AGENTS.md")],
                "# Rules\n\nThe rules.\nls: cannot access 'missing': No such file or directory\n",
                vec![],
            ),
            // A failed read tool's result and a failed skill's.
            (vec![file("/h/gone.md")], "File does not exist.", vec![]),
            (
                vec![Read::Skill {
                    name: Some("x".to_owned()),
                }],
                "x",
                vec![],
            ),
            (vec![Read::Unreadable], "", vec![]),
        ];
        for (reads, text, want) in rows {
            assert_eq!(stood(reads.clone(), text), want, "{reads:?} in {text:?}");
        }
    }
}
