//! Whether an attached agent the lead launched may still be out: the agent
//! reserve an attached launch keeps applies only then, and a Claude lane's
//! handoff instruction names each one. Claude's Stop payload carries its
//! task registry; otherwise, and on every tool call, the lead's own
//! transcript is scanned for the records that move a child. Codex's rollout
//! is scanned the same way. A roster neither read can classify is unknown,
//! which no caller reads as none.
//!
//! A helper reads ended only where a record proves its end: a completion,
//! a failure, a stop or an idle notice the record carries. A helper last put
//! out by a record of another session than the payload names reads unknown:
//! no record of this session proves it still runs, and none proves it
//! ended, so the reserve is kept and no wait is named for it.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use agent_runtime::clock::Clock;
use regex::Regex;
use serde_json::{Map, Value};

use super::answer::Harness;
use super::payload::Payload;

/// A turn end's whole budget, counted from its start: the hook's own
/// timeout leaves no answer at all past it.
const DEADLINE: Duration = Duration::from_secs(30);
/// The part of the budget kept for writing the answer once the scan ends.
const EMIT: Duration = Duration::from_secs(3);

/// Whether any attached agent may be out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    None,
    Out,
    Unknown,
}

/// The roster: its state and the keyed rows naming each child still out
/// or why the roster is unknown, a line each.
pub struct Roster {
    pub state: State,
    pub rows: String,
}

impl Roster {
    fn unknown(rows: String) -> Roster {
        Roster {
            state: State::Unknown,
            rows,
        }
    }
}

const UNKNOWN: &str = "lane-mail-check: agents=unknown";

/// The attached-launch read: Claude's roster, Codex's rollout scan, and
/// unknown for a harness neither reads.
pub fn roster(harness: Harness, payload: &Payload, deadline: &Deadline) -> Roster {
    match harness {
        Harness::Claude => claude_roster(payload, deadline),
        Harness::Codex => codex_roster(payload, deadline),
        Harness::Pi | Harness::Copilot | Harness::Unlisted => {
            let name = match harness {
                Harness::Pi => "pi",
                Harness::Copilot => "copilot",
                Harness::Claude | Harness::Codex | Harness::Unlisted => "",
            };
            Roster::unknown(format!(
                "{UNKNOWN}\nlane-mail-check: agent-roster=unread harness={name}"
            ))
        }
    }
}

/// A turn end's deadline: its start, read once from agent-runtime's one
/// clock, and every later check against it on that same clock.
#[derive(Clone, Copy)]
pub struct Deadline<'a> {
    clock: &'a dyn Clock,
    started: Instant,
}

/// The moment `clock` reads.
#[allow(
    clippy::disallowed_methods,
    reason = "the turn end's own deadline: its start and every check against it, on the one clock"
)]
fn moment(clock: &dyn Clock) -> Instant {
    clock.now()
}

impl<'a> Deadline<'a> {
    pub fn start(clock: &'a dyn Clock) -> Deadline<'a> {
        Deadline {
            clock,
            started: moment(clock),
        }
    }

    /// The end of a scan's budget, `None` once the budget less the answer's
    /// share is spent.
    fn scan_end(&self) -> Option<Instant> {
        let end = self.started + DEADLINE - EMIT;
        (moment(self.clock) < end).then_some(end)
    }

    /// Whether `end` has come.
    fn passed(&self, end: Instant) -> bool {
        moment(self.clock) >= end
    }

    /// What is left of the budget less the answer's share, `None` once it
    /// is spent: the bound of any other wait a turn end takes.
    pub fn left(&self) -> Option<Duration> {
        let end = self.scan_end()?;
        Some(end - moment(self.clock))
    }

    /// A pause within the deadline, on the same clock.
    #[allow(
        clippy::disallowed_methods,
        reason = "the turn end's one wait, a bounded poll within its own deadline, on the one clock"
    )]
    pub fn pause(&self, d: Duration) {
        self.clock.sleep(d);
    }
}

/// The lines of the transcript at `path`, read until `end`: `Err` with the
/// value of `agent-scan` and the cause where the file cannot be read, a
/// line is no JSON, or the deadline passes first.
fn transcript_records(
    path: &Path,
    deadline: &Deadline,
    end: Instant,
) -> Result<Vec<Value>, (String, String)> {
    let file = std::fs::File::open(path)
        .map_err(|e| ("unreadable".to_owned(), format!("{}: {e}", path.display())))?;
    let mut values = Vec::new();
    for (n, line) in BufReader::new(file).split(b'\n').enumerate() {
        if deadline.passed(end) {
            return Err((
                "timeout".to_owned(),
                format!("the scan passed its deadline at line {}", n + 1),
            ));
        }
        let line = line.map_err(|e| ("unreadable".to_owned(), e.to_string()))?;
        let value = serde_json::from_slice::<Value>(&line).map_err(|e| {
            (
                "unreadable".to_owned(),
                format!("line {} is no JSON: {e}", n + 1),
            )
        })?;
        values.push(value);
    }
    Ok(values)
}

fn readable_transcript(path: &str) -> bool {
    !path.is_empty()
        && std::fs::metadata(path).is_ok_and(|meta| meta.is_file())
        && std::fs::File::open(path).is_ok()
}

// --- Claude --------------------------------------------------------------

/// A Claude child's state as the records move it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Child {
    Running,
    Completed,
    Failed,
    Killed,
    /// A message reached a child that had ended; its next turn is due.
    Queued,
    /// A message reached a child still in its turn.
    QueuedActive,
    Unconfirmed,
    UnconfirmedActive,
    Unknown,
}

impl Child {
    fn parse(word: &str) -> Child {
        match word {
            "running" => Child::Running,
            "completed" => Child::Completed,
            "failed" => Child::Failed,
            "killed" => Child::Killed,
            _ => Child::Unknown,
        }
    }

    fn terminal(self) -> bool {
        matches!(self, Child::Completed | Child::Failed | Child::Killed)
    }

    fn awaiting(self) -> bool {
        matches!(self, Child::QueuedActive | Child::UnconfirmedActive)
    }

    fn queued(self) -> bool {
        self.awaiting() || matches!(self, Child::Queued | Child::Unconfirmed)
    }

    /// The state a record that cannot settle the child leaves it in.
    fn uncertain(self) -> Child {
        if self.terminal() {
            self
        } else if self.awaiting() {
            Child::UnconfirmedActive
        } else if self.queued() {
            Child::Unconfirmed
        } else {
            Child::Unknown
        }
    }

    /// A teammate's idle notice over its prior state.
    fn after_idle_notice(self, notice: &Map<String, Value>) -> Child {
        let field = |key: &str| notice.get(key).and_then(Value::as_str);
        if self.terminal() {
            self
        } else if field("completedStatus") == Some("failed") {
            Child::Failed
        } else if field("idleReason") == Some("available") {
            if self.awaiting() {
                self.uncertain()
            } else {
                Child::Completed
            }
        } else if field("idleReason") == Some("interrupted") && !self.queued() {
            Child::Completed
        } else {
            self.uncertain()
        }
    }

    /// The word the roster's row carries.
    fn word(self) -> &'static str {
        match self {
            Child::Running | Child::Queued | Child::QueuedActive => "running",
            Child::Completed => "completed",
            Child::Failed => "failed",
            Child::Killed => "killed",
            Child::Unconfirmed | Child::UnconfirmedActive | Child::Unknown => "unknown",
        }
    }
}

/// A tool call the lead made that a later result settles.
#[derive(Debug, Clone)]
enum Call {
    /// An `Agent` or `Task` launch; `sync` where it runs in the foreground
    /// and its result is the child's finished output.
    Launch { pending: bool, sync: bool },
    /// A `SendMessage` or `TaskStop` to a child, and the state it moves the
    /// child to.
    To {
        pending: bool,
        to: String,
        status: Child,
    },
    /// A `ListAgents` call, the generation it saw and whether a call was
    /// still pending.
    List { generation: u64, overlap: bool },
}

impl Call {
    fn pending(&self) -> bool {
        match self {
            Call::Launch { pending, .. } | Call::To { pending, .. } => *pending,
            Call::List { .. } => false,
        }
    }

    fn settle(&mut self) {
        match self {
            Call::Launch { pending, .. } | Call::To { pending, .. } => *pending = false,
            Call::List { .. } => {}
        }
    }
}

#[derive(Default)]
struct Scan {
    call: std::collections::HashMap<String, Call>,
    /// Each child in the order it was first launched, with its state and
    /// the session of the record that last put it out.
    agents: Vec<(String, Child, String)>,
    names: std::collections::HashMap<String, String>,
    generation: u64,
    unclassified: bool,
}

impl Scan {
    fn child_state(&self, id: &str) -> Option<Child> {
        self.agents
            .iter()
            .find(|(a, ..)| a == id)
            .map(|(_, s, _)| *s)
    }

    fn changed(&mut self, id: &str, status: Child, session: &str) {
        self.generation += 1;
        match self.agents.iter_mut().find(|(a, ..)| a == id) {
            Some(entry) => {
                entry.1 = status;
                if !status.terminal() && status != Child::Unknown {
                    session.clone_into(&mut entry.2);
                }
            }
            None => self
                .agents
                .push((id.to_owned(), status, session.to_owned())),
        }
    }
}

static TASK_NOTIFICATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"<task-notification>[\s\S]*?<task-id>([A-Za-z0-9_-]+)</task-id>[\s\S]*?<status>([a-z_]+)</status>[\s\S]*?</task-notification>").expect("the task notification pattern")
});
static TEAMMATE_IDLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"<teammate-message teammate_id="([^"]+)"[^>]*>\s*(\{\s*"type"\s*:\s*"idle_notification"[\s\S]*?)\s*</teammate-message>"#).expect("the teammate idle pattern")
});
static ASYNC_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"agentId: ([A-Za-z0-9_-]+)").expect("the async launch pattern"));
static SPAWNED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\nagent_id: ([A-Za-z0-9_-]+)\nname: ([^\n]+)").expect("the spawn pattern")
});
static RESUMED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"^Teammate "[^"]+" was not running; resumed it as an in-process teammate with [0-9]+ prior messages and your message as its next prompt\.$"#).expect("the resume pattern")
});
static TASK_ID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_-]+$").expect("the task id pattern"));
static TASK_STATUS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-z_]+$").expect("the task status pattern"));

/// A content value's text: itself where a string, its text blocks joined
/// where a list, nothing otherwise.
fn content_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .map(|b| b.get("text").map(jq_text).unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// A JSON value as jq's string interpolation spells it.
fn jq_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => "null".to_owned(),
        other => other.to_string(),
    }
}

/// Every text a message says: its own, then each tool result's.
fn said_texts(content: &Value) -> Vec<String> {
    let mut out = vec![content_text(content)];
    if let Value::Array(blocks) = content {
        for block in blocks {
            if block.get("type").and_then(Value::as_str) == Some("tool_result") {
                out.push(content_text(block.get("content").unwrap_or(&Value::Null)));
            }
        }
    }
    out
}

/// The child a launch result names: an async launch's id, or a spawned
/// teammate's id and name.
fn launch_named(said: &str) -> Option<(String, Option<String>)> {
    if said.starts_with("Async agent launched successfully") {
        return ASYNC_ID.captures(said).map(|c| (c[1].to_owned(), None));
    }
    if said.starts_with("Spawned successfully") {
        return SPAWNED
            .captures(said)
            .map(|c| (c[1].to_owned(), Some(c[2].to_owned())));
    }
    None
}

fn tool_results(content: &Value) -> Vec<&Value> {
    match content {
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
            .collect(),
        _ => Vec::new(),
    }
}

/// The notifications a message carries, applied before its call results:
/// a notification arrived before or during the calls it rides with.
fn notices_applied(scan: &mut Scan, content: &Value, session: &str) {
    let texts = said_texts(content);
    for text in &texts {
        for n in TASK_NOTIFICATION.captures_iter(text) {
            let id = &n[1];
            if let Some(prior) = scan.child_state(id) {
                let status = Child::parse(&n[2]);
                let next = if status.terminal() {
                    status
                } else {
                    prior.uncertain()
                };
                scan.changed(id, next, session);
            }
        }
    }
    for text in &texts {
        for n in TEAMMATE_IDLE.captures_iter(text) {
            let Some(id) = scan.names.get(&n[1]).cloned() else {
                continue;
            };
            let prior = scan.child_state(&id).unwrap_or(Child::Unknown);
            let next = match serde_json::from_str::<Value>(&n[2]) {
                Ok(Value::Object(notice)) => prior.after_idle_notice(&notice),
                _ => prior.uncertain(),
            };
            scan.changed(&id, next, session);
        }
    }
}

fn assistant_calls(scan: &mut Scan, content: &Value) {
    let Value::Array(blocks) = content else {
        return;
    };
    for c in blocks {
        let Some(id) = c.get("id").and_then(Value::as_str) else {
            continue;
        };
        if c.get("type").and_then(Value::as_str) != Some("tool_use") {
            continue;
        }
        let input = c.get("input").unwrap_or(&Value::Null);
        let field = |key: &str| input.get(key).filter(|v| !v.is_null());
        match c.get("name").and_then(Value::as_str).unwrap_or_default() {
            "Agent" | "Task" => {
                scan.generation += 1;
                let background = field("run_in_background").map(jq_text).as_deref() == Some("true");
                let named = matches!(field("name"), Some(Value::String(n)) if !n.is_empty());
                scan.call.insert(
                    id.to_owned(),
                    Call::Launch {
                        pending: true,
                        sync: !background && !named,
                    },
                );
            }
            "SendMessage" => {
                let Some(Value::String(to)) = field("to") else {
                    continue;
                };
                scan.generation += 1;
                let status = match field("message") {
                    Some(Value::String(_)) => Child::Running,
                    Some(Value::Object(m))
                        if m.get("type").and_then(Value::as_str) == Some("shutdown_request") =>
                    {
                        Child::Completed
                    }
                    _ => continue,
                };
                scan.call.insert(
                    id.to_owned(),
                    Call::To {
                        pending: true,
                        to: to.clone(),
                        status,
                    },
                );
            }
            "TaskStop" => {
                let Some(Value::String(task)) = field("task_id") else {
                    continue;
                };
                scan.generation += 1;
                scan.call.insert(
                    id.to_owned(),
                    Call::To {
                        pending: true,
                        to: task.clone(),
                        status: Child::Killed,
                    },
                );
            }
            "ListAgents" => {
                let overlap = scan.call.values().any(Call::pending);
                scan.call.insert(
                    id.to_owned(),
                    Call::List {
                        generation: scan.generation,
                        overlap,
                    },
                );
            }
            _ => {}
        }
    }
}

fn user_results(scan: &mut Scan, content: &Value, result: &Value, session: &str) {
    let rs = tool_results(content);
    for r in &rs {
        let said = content_text(r.get("content").unwrap_or(&Value::Null));
        if let Some((id, name)) = launch_named(&said) {
            scan.changed(&id, Child::Running, session);
            if let Some(name) = name {
                scan.names.insert(name, id);
            }
        }
    }
    notices_applied(scan, content, session);
    for r in &rs {
        let key = r
            .get("tool_use_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let call = scan.call.get(&key).cloned();
        if let Some(c) = &call {
            if c.pending() {
                scan.generation += 1;
            }
            if let Some(stored) = scan.call.get_mut(&key) {
                stored.settle();
            }
        }
        let content = r.get("content").unwrap_or(&Value::Null);
        let Some(call) = call else { continue };
        if launch_named(&content_text(content)).is_some()
            || r.get("is_error") == Some(&Value::Bool(true))
        {
            continue;
        }
        match call {
            Call::List {
                generation,
                overlap,
            } => {
                if overlap || generation != scan.generation {
                    continue;
                }
                let sections = result.get("sections").and_then(Value::as_array);
                match (rs.len(), sections) {
                    (1, Some(sections)) => {
                        for section in sections {
                            if section.get("kind").and_then(Value::as_str) != Some("teammates") {
                                continue;
                            }
                            let rows = section.get("rows").and_then(Value::as_array);
                            for row in rows.into_iter().flatten() {
                                let name = row.get("name").map(jq_text).unwrap_or_default();
                                let Some(id) = scan.names.get(&name).cloned() else {
                                    continue;
                                };
                                let prior = scan.child_state(&id).unwrap_or(Child::Unknown);
                                let status = row.get("status").and_then(Value::as_str);
                                let next = if prior.queued() {
                                    match status {
                                        Some("idle" | "running") => continue,
                                        _ => prior.uncertain(),
                                    }
                                } else {
                                    match status {
                                        Some("idle") => Child::Completed,
                                        Some("running") => Child::Running,
                                        _ => prior.uncertain(),
                                    }
                                };
                                scan.changed(&id, next, session);
                            }
                        }
                    }
                    _ => {
                        let out: Vec<(String, Child)> = scan
                            .agents
                            .iter()
                            .filter(|(_, s, _)| *s == Child::Running || s.queued())
                            .map(|(id, s, _)| (id.clone(), *s))
                            .collect();
                        for (id, s) in out {
                            scan.changed(&id, s.uncertain(), session);
                        }
                    }
                }
            }
            Call::To { to, status, .. } => {
                let target = scan.names.get(&to).cloned().unwrap_or(to);
                let Some(prior) = scan.child_state(&target) else {
                    continue;
                };
                let next = if status == Child::Running && prior == Child::Killed {
                    let sent = if rs.len() == 1 && result.is_object() {
                        result.clone()
                    } else {
                        serde_json::from_str::<Value>(&content_text(content)).unwrap_or(Value::Null)
                    };
                    let message = sent.get("message").and_then(Value::as_str).unwrap_or("");
                    if sent.get("success") == Some(&Value::Bool(true)) && RESUMED.is_match(message)
                    {
                        Child::Queued
                    } else {
                        Child::Unconfirmed
                    }
                } else if status != Child::Running {
                    status
                } else if prior.terminal() {
                    Child::Queued
                } else if matches!(
                    prior,
                    Child::Unknown | Child::Unconfirmed | Child::UnconfirmedActive
                ) {
                    Child::UnconfirmedActive
                } else {
                    Child::QueuedActive
                };
                scan.changed(&target, next, session);
            }
            Call::Launch { sync: true, .. } => {}
            Call::Launch { sync: false, .. } => scan.unclassified = true,
        }
    }
}

/// The children the lead's transcript records, each with its row word,
/// and whether a result was one no rule classifies. A child last put out
/// by a record of a session other than `session` reads unknown.
fn claude_scan(records: &[Value], session: &str) -> (Vec<(String, &'static str)>, bool) {
    let mut scan = Scan::default();
    for record in records {
        let Value::Object(record) = record else {
            continue;
        };
        let at = record
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match record.get("type").and_then(Value::as_str) {
            Some("queue-operation") => {
                if record.get("operation").and_then(Value::as_str) != Some("enqueue") {
                    continue;
                }
                let Some(content @ Value::String(_)) = record.get("content") else {
                    continue;
                };
                user_results(&mut scan, content, &Value::Null, at);
            }
            Some("assistant" | "user") => {
                let Some(Value::Object(message)) = record.get("message") else {
                    continue;
                };
                let content = message.get("content").unwrap_or(&Value::Null);
                let result = record.get("toolUseResult").unwrap_or(&Value::Null);
                match message.get("role").and_then(Value::as_str) {
                    Some("assistant") => assistant_calls(&mut scan, content),
                    Some("user") => user_results(&mut scan, content, result, at),
                    _ => {}
                }
            }
            _ => {}
        }
    }
    let rows = scan
        .agents
        .iter()
        .map(|(id, state, put_out)| {
            let word = state.word();
            let foreign = word == "running"
                && !session.is_empty()
                && !put_out.is_empty()
                && put_out != session;
            (id.clone(), if foreign { "unknown" } else { word })
        })
        .collect();
    (rows, scan.unclassified)
}

/// The rows Claude's task registry in the Stop payload names: each
/// subagent or teammate with its status, `?` for a type that may be an
/// agent and is neither. `Err` with the cause where the registry is not
/// in its documented form.
fn task_registry(tasks: &Value) -> Result<Vec<(String, String)>, String> {
    let Value::Array(tasks) = tasks else {
        return Err("task list is not an array".to_owned());
    };
    let mut rows = Vec::new();
    for task in tasks {
        let Some(kind) = task
            .as_object()
            .and_then(|t| t.get("type"))
            .and_then(Value::as_str)
        else {
            return Err("task type is invalid".to_owned());
        };
        match kind {
            "shell" | "monitor" | "MCP task" => continue,
            "subagent" | "teammate" => {}
            _ => {
                rows.push(("?".to_owned(), "task-type".to_owned()));
                continue;
            }
        }
        let word = |key: &str, pattern: &Regex| {
            task.get(key)
                .and_then(Value::as_str)
                .filter(|s| pattern.is_match(s))
                .map(str::to_owned)
        };
        match (word("id", &TASK_ID), word("status", &TASK_STATUS)) {
            (Some(id), Some(status)) => rows.push((id, status)),
            _ => return Err("subagent id or status is invalid".to_owned()),
        }
    }
    Ok(rows)
}

/// Claude's roster: the Stop payload's task registry where it carries one,
/// else the scan of the lead's transcript, else unknown. Each child still
/// out is named with its transcript where the measured layout holds one.
pub fn claude_roster(payload: &Payload, deadline: &Deadline) -> Roster {
    let transcript = payload.transcript.as_str();
    let rows: Vec<(String, String)> = if let Some(tasks) = payload.field("background_tasks") {
        match task_registry(tasks) {
            Ok(rows) => rows,
            Err(cause) => return Roster::unknown(format!("{UNKNOWN}\n{cause}")),
        }
    } else if readable_transcript(transcript) {
        let Some(end) = deadline.scan_end() else {
            return Roster::unknown(format!(
                "{UNKNOWN}\nlane-mail-check: agent-scan=budget-exhausted"
            ));
        };
        let records = match transcript_records(Path::new(transcript), deadline, end) {
            Ok(records) => records,
            Err((value, cause)) => {
                return Roster::unknown(format!(
                    "{UNKNOWN}\nlane-mail-check: agent-scan={value}\n{cause}"
                ));
            }
        };
        let (agents, unclassified) = claude_scan(&records, &payload.session);
        let mut rows: Vec<(String, String)> = agents
            .into_iter()
            .map(|(id, word)| (id, word.to_owned()))
            .collect();
        if unclassified {
            rows.push(("?".to_owned(), "agent-result".to_owned()));
        }
        rows
    } else {
        return Roster::unknown(UNKNOWN.to_owned());
    };
    let mut state = State::None;
    let mut unclassified = String::new();
    let mut lines: Vec<String> = Vec::new();
    for (id, status) in rows {
        if id == "?" {
            unclassified = status;
            continue;
        }
        match status.as_str() {
            "completed" | "failed" | "killed" => continue,
            "unknown" => "agent-status".clone_into(&mut unclassified),
            _ => {}
        }
        state = State::Out;
        let child = transcript
            .strip_suffix(".jsonl")
            .unwrap_or(transcript)
            .to_owned()
            + &format!("/subagents/agent-{id}.jsonl");
        let output = if !transcript.is_empty()
            && std::fs::metadata(&child).is_ok_and(|meta| meta.is_file())
        {
            child
        } else {
            "unknown".to_owned()
        };
        lines.push(format!(
            "lane-mail-check: attached-agent={id} status={status} output={output}"
        ));
    }
    if !unclassified.is_empty() {
        let mut rows = format!("{UNKNOWN}\nlane-mail-check: agent-unclassified={unclassified}");
        for line in &lines {
            rows.push('\n');
            rows.push_str(line);
        }
        return Roster::unknown(rows);
    }
    Roster {
        state,
        rows: lines.join("\n"),
    }
}

// --- Codex ---------------------------------------------------------------

/// A Codex agent path: the lead `/root` and its children under it.
fn codex_agent_name(value: &Value) -> Result<String, String> {
    static NAME: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^/root(/[A-Za-z0-9_-]+)*$").expect("the agent path pattern"));
    match value {
        Value::String(name) if NAME.is_match(name) => Ok(name.clone()),
        other => Err(format!("invalid agent name: {other}")),
    }
}

/// A Codex agent status as the roster reads it (`AgentStatus`).
fn codex_agent_status(status: &Value) -> &'static str {
    let word = match status {
        Value::Object(o) => {
            let only = |key: &str| o.len() == 1 && o.contains_key(key);
            if only("completed")
                && matches!(o.get("completed"), Some(Value::Null | Value::String(_)))
            {
                "completed"
            } else if only("errored") && matches!(o.get("errored"), Some(Value::String(_))) {
                "errored"
            } else {
                "unknown"
            }
        }
        Value::String(s) => s.as_str(),
        _ => "unknown",
    };
    match word {
        "idle" | "completed" | "errored" | "shutdown" | "not_found" | "interrupted" => "completed",
        "running" | "pending_init" => "running",
        _ => "unknown",
    }
}

/// A function call's arguments or output, decoded where it is JSON text.
fn decoded_json(value: &Value) -> Result<Value, String> {
    match value {
        Value::String(text) => serde_json::from_str(text).map_err(|e| e.to_string()),
        other => Ok(other.clone()),
    }
}

struct CodexCall {
    tool: String,
    full: bool,
    overlap: bool,
    target: Option<String>,
}

/// The children Codex's rollout records, each with its status word, `?`
/// rows for what the scan could not settle. `current` is the call being
/// judged, never an earlier launch. `Err` where a record breaks the
/// rollout's form.
fn codex_scan(records: &[Value], current: &str) -> Result<Vec<(String, String)>, String> {
    let mut calls: Vec<(String, CodexCall)> = Vec::new();
    let mut agents: Vec<(String, &'static str)> = Vec::new();
    let mut observed = false;
    let mut unread = false;
    let set =
        |agents: &mut Vec<(String, &'static str)>, id: String, status: &'static str| match agents
            .iter_mut()
            .find(|(a, _)| *a == id)
        {
            Some(entry) => entry.1 = status,
            None => agents.push((id, status)),
        };
    for record in records {
        let Value::Object(record) = record else {
            continue;
        };
        let payload = record.get("payload").unwrap_or(&Value::Null);
        let kind = record.get("type").and_then(Value::as_str);
        let item = payload.get("item").unwrap_or(&Value::Null);
        let completed = kind == Some("event_msg")
            && payload.get("type").and_then(Value::as_str) == Some("item_completed")
            && item.get("type").and_then(Value::as_str) == Some("SubAgentActivity")
            && item.get("kind").and_then(Value::as_str) == Some("completed");
        if kind != Some("response_item") && !completed {
            continue;
        }
        let call_id = payload.get("call_id");
        if !current.is_empty() && call_id.and_then(Value::as_str) == Some(current) {
            continue;
        }
        let call_id = call_id.map(jq_text).unwrap_or_default();
        match payload.get("type").and_then(Value::as_str) {
            Some("function_call") => {
                let name = match payload.get("name") {
                    Some(Value::String(name)) => name.as_str(),
                    other => return Err(format!("function name is no string: {other:?}")),
                };
                let last = name.rsplit('.').next().unwrap_or(name);
                let tool = last.strip_prefix("collaboration").unwrap_or(last);
                if !matches!(tool, "list_agents" | "spawn_agent" | "followup_task") {
                    continue;
                }
                let args = decoded_json(payload.get("arguments").unwrap_or(&Value::Null))?;
                let full = match args.get("path_prefix") {
                    None | Some(Value::Null | Value::Bool(false)) => true,
                    Some(Value::String(prefix)) => prefix.is_empty() || prefix == "/root",
                    Some(_) => false,
                };
                let overlap = calls.iter().any(|(_, c)| c.tool != "list_agents");
                if tool != "list_agents" {
                    for (_, c) in &mut calls {
                        if c.tool == "list_agents" {
                            c.overlap = true;
                        }
                    }
                }
                let target = if tool == "followup_task" {
                    let Some(Value::String(target)) = args.get("target") else {
                        return Err("followup target is no string".to_owned());
                    };
                    let target = if target.starts_with('/') {
                        target.clone()
                    } else {
                        format!("/root/{target}")
                    };
                    Some(codex_agent_name(&Value::String(target))?)
                } else {
                    None
                };
                let entry = CodexCall {
                    tool: tool.to_owned(),
                    full,
                    overlap,
                    target,
                };
                match calls.iter_mut().find(|(id, _)| *id == call_id) {
                    Some(slot) => slot.1 = entry,
                    None => calls.push((call_id, entry)),
                }
            }
            Some("function_call_output") => {
                let Some(at) = calls.iter().position(|(id, _)| *id == call_id) else {
                    continue;
                };
                let (_, call) = calls.remove(at);
                let output = payload.get("output").unwrap_or(&Value::Null);
                let blocked = output
                    .as_str()
                    .is_some_and(|o| o.starts_with("Tool call blocked by PreToolUse hook: "));
                if blocked {
                    continue;
                }
                let before = (agents.clone(), observed);
                let applied: Result<(), String> = (|| {
                    match call.tool.as_str() {
                        "list_agents" if call.full && !call.overlap => {
                            let out = decoded_json(output)?;
                            let Some(listed) = out.get("agents").and_then(Value::as_array) else {
                                return Err("agent list is unreadable".to_owned());
                            };
                            let mut fresh = Vec::new();
                            for agent in listed {
                                let id = codex_agent_name(
                                    agent.get("agent_name").unwrap_or(&Value::Null),
                                )?;
                                if id != "/root" {
                                    let status = codex_agent_status(
                                        agent.get("agent_status").unwrap_or(&Value::Null),
                                    );
                                    set(&mut fresh, id, status);
                                }
                            }
                            agents = fresh;
                            unread = false;
                            observed = true;
                        }
                        "list_agents" if call.full => unread = true,
                        "list_agents" => {}
                        "spawn_agent" => {
                            let out = decoded_json(output)?;
                            let id =
                                codex_agent_name(out.get("task_name").unwrap_or(&Value::Null))?;
                            set(&mut agents, id, "running");
                            observed = true;
                        }
                        _ => {
                            let status = if output.as_str() == Some("") {
                                "running"
                            } else {
                                "unknown"
                            };
                            set(&mut agents, call.target.clone().unwrap_or_default(), status);
                            observed = true;
                        }
                    }
                    Ok(())
                })();
                if applied.is_err() {
                    (agents, observed) = before;
                    unread = true;
                }
            }
            Some("item_completed") => {
                let id = codex_agent_name(item.get("agent_path").unwrap_or(&Value::Null))?;
                if let Some(entry) = agents.iter_mut().find(|(a, _)| *a == id) {
                    entry.1 = "completed";
                }
            }
            _ => {}
        }
    }
    let mut rows: Vec<(String, String)> = agents
        .into_iter()
        .map(|(id, status)| {
            if status == "unknown" {
                ("?".to_owned(), "agent-status".to_owned())
            } else {
                (id, status.to_owned())
            }
        })
        .collect();
    if !observed || unread {
        rows.push(("?".to_owned(), "unread".to_owned()));
    }
    for _ in &calls {
        rows.push(("?".to_owned(), "pending".to_owned()));
    }
    Ok(rows)
}

/// Codex's roster from the lead's rollout: unknown wherever the rollout,
/// the call being judged or any child cannot be read.
fn codex_roster(payload: &Payload, deadline: &Deadline) -> Roster {
    let unread = format!("{UNKNOWN}\nlane-mail-check: agent-roster=unread harness=codex");
    if !readable_transcript(&payload.transcript) {
        return Roster::unknown(unread);
    }
    let current = match payload.field("tool_use_id") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(id)) => id.clone(),
        Some(_) => {
            return Roster::unknown(format!(
                "{unread}\nlane-mail-check: agent-scan=tool-use-id\ntool_use_id is not a string"
            ));
        }
    };
    let Some(end) = deadline.scan_end() else {
        return Roster::unknown(format!(
            "{unread}\nlane-mail-check: agent-scan=budget-exhausted"
        ));
    };
    let read = transcript_records(Path::new(&payload.transcript), deadline, end);
    let rows = match read.and_then(|records| {
        codex_scan(&records, &current).map_err(|e| ("unreadable".to_owned(), e))
    }) {
        Ok(rows) => rows,
        Err((value, cause)) => {
            return Roster::unknown(format!(
                "{unread}\nlane-mail-check: agent-scan={value}\n{cause}"
            ));
        }
    };
    let mut lines = Vec::new();
    for (id, status) in rows {
        if id == "?" {
            return Roster::unknown(unread);
        }
        if status == "completed" {
            continue;
        }
        lines.push(format!(
            "lane-mail-check: attached-agent={id} status={status} output=unknown"
        ));
    }
    Roster {
        state: if lines.is_empty() {
            State::None
        } else {
            State::Out
        },
        rows: lines.join("\n"),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    /// A row of records, the roster they leave and whether a result went
    /// unclassified.
    type Row = (
        Vec<Vec<Value>>,
        &'static [(&'static str, &'static str)],
        bool,
    );

    /// Claude's measured tool call and its result record.
    fn claude_call(
        id: &str,
        tool: &str,
        input: Value,
        result: &str,
        structured: Value,
    ) -> Vec<Value> {
        vec![
            json!({"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": id, "name": tool, "input": input}]}}),
            json!({"type": "user", "toolUseResult": structured, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": id, "content": result, "is_error": false}]}}),
        ]
    }

    fn claude_teammate() -> Vec<Value> {
        claude_call(
            "spawn",
            "Agent",
            json!({"name": "reviewer"}),
            "Spawned successfully. (This tool result is internal metadata.)\nagent_id: areviewer-t1\nname: reviewer\nThe agent is now running and will receive instructions via mailbox.",
            Value::Null,
        )
    }

    fn claude_idle(fields: &str) -> Vec<Value> {
        vec![
            json!({"type": "user", "message": {"role": "user", "content": format!(
            "Another Claude session sent a message:\n<teammate-message teammate_id=\"reviewer\" color=\"blue\">\n{{\"type\":\"idle_notification\",\"from\":\"reviewer\"{fields}}}\n</teammate-message>")}}),
        ]
    }

    fn claude_send(id: &str, message: Value, structured: Value) -> Vec<Value> {
        claude_call(
            id,
            "SendMessage",
            json!({"to": "reviewer", "message": message}),
            "sent",
            structured,
        )
    }

    /// The records that move a child, each row's roster as the scan reads
    /// it: a launch puts a child out, a notice or a stop ends it, a message
    /// to an ended child puts it out again, and a resume after a stop
    /// counts only on its measured result.
    #[test]
    fn each_record_moves_the_child_it_names() {
        let launch = claude_call(
            "a",
            "Agent",
            json!({"run_in_background": true}),
            "Async agent launched successfully. agentId: a1",
            Value::Null,
        );
        let notified = |status: &str| {
            claude_call(
                "b",
                "Bash",
                json!({"command": "true"}),
                &format!(
                    "done\n<task-notification><task-id>a1</task-id><status>{status}</status></task-notification>"
                ),
                Value::Null,
            )
        };
        let stop = claude_call(
            "stop",
            "TaskStop",
            json!({"task_id": "reviewer"}),
            "stopped",
            Value::Null,
        );
        let resumed = json!({"success": true, "message": "Teammate \"reviewer\" was not running; resumed it as an in-process teammate with 3 prior messages and your message as its next prompt."});
        let listed = |status: &str| {
            claude_call(
                "list",
                "ListAgents",
                json!({}),
                "listed",
                json!({"sections": [{"kind": "teammates", "rows": [{"name": "reviewer", "status": status}]}]}),
            )
        };
        let rows: Vec<Row> = vec![
            (vec![launch.clone()], &[("a1", "running")], false),
            (
                vec![launch.clone(), notified("completed")],
                &[("a1", "completed")],
                false,
            ),
            (
                vec![launch.clone(), notified("running")],
                &[("a1", "unknown")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    claude_idle(",\"idleReason\":\"available\""),
                ],
                &[("areviewer-t1", "completed")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    claude_idle(",\"idleReason\":\"available\""),
                    claude_send("m", json!("again"), Value::Null),
                ],
                &[("areviewer-t1", "running")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    claude_send("m", json!({"type": "shutdown_request"}), Value::Null),
                ],
                &[("areviewer-t1", "completed")],
                false,
            ),
            (
                vec![claude_teammate(), stop.clone()],
                &[("areviewer-t1", "killed")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    stop.clone(),
                    claude_send("m", json!("on"), resumed),
                ],
                &[("areviewer-t1", "running")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    stop.clone(),
                    claude_send("m", json!("on"), json!({"success": false})),
                ],
                &[("areviewer-t1", "unknown")],
                false,
            ),
            (
                vec![
                    claude_teammate(),
                    stop,
                    claude_send(
                        "m",
                        json!("on"),
                        json!({"success": true, "message": "queued"}),
                    ),
                ],
                &[("areviewer-t1", "unknown")],
                false,
            ),
            (
                vec![claude_teammate(), listed("idle")],
                &[("areviewer-t1", "completed")],
                false,
            ),
            (
                vec![claude_call(
                    "n",
                    "Agent",
                    json!({"name": "x"}),
                    "something else",
                    Value::Null,
                )],
                &[],
                true,
            ),
            (
                vec![claude_call(
                    "f",
                    "Agent",
                    json!({}),
                    "the child's answer",
                    Value::Null,
                )],
                &[],
                false,
            ),
        ];
        for (n, (records, want, unclassified)) in rows.into_iter().enumerate() {
            let records: Vec<Value> = records.into_iter().flatten().collect();
            let (agents, odd) = claude_scan(&records, "s1");
            let agents: Vec<(&str, &str)> =
                agents.iter().map(|(id, w)| (id.as_str(), *w)).collect();
            assert_eq!((agents.as_slice(), odd), (want, unclassified), "row {n}");
        }
    }

    /// The one clock with its moments planted: each read is `base` plus
    /// the next of `steps`, the last one held.
    struct Steps {
        base: Instant,
        steps: Vec<Duration>,
        read: std::sync::atomic::AtomicUsize,
    }

    impl Clock for Steps {
        fn now(&self) -> Instant {
            let n = self.read.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.base + self.steps[n.min(self.steps.len() - 1)]
        }
        fn wall(&self) -> std::time::SystemTime {
            std::time::UNIX_EPOCH
        }
        fn sleep(&self, _: Duration) {}
    }

    /// A scan that meets the turn end's deadline leaves the roster unknown,
    /// never read as no agent out: before it starts, and between two lines.
    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the planted clock's base instant, and the transcript the scan reads"
    )]
    fn a_scan_past_the_turn_ends_deadline_reads_the_roster_unknown() {
        let dir = tempfile::tempdir().unwrap();
        let transcript = dir.path().join("lead.jsonl");
        std::fs::write(&transcript, "{}\n{}\n").unwrap();
        let payload = json!({"session_id": "s1", "transcript_path": transcript}).to_string();
        let Ok(payload) = Payload::decode(payload.as_bytes(), false) else {
            panic!("the planted payload decodes");
        };
        let rows: &[(&[u64], &str)] = &[(&[0, 28], "budget-exhausted"), (&[0, 20, 28], "timeout")];
        for (steps, word) in rows {
            let clock = Steps {
                base: Instant::now(),
                steps: steps.iter().map(|s| Duration::from_secs(*s)).collect(),
                read: std::sync::atomic::AtomicUsize::new(0),
            };
            let roster = claude_roster(&payload, &Deadline::start(&clock));
            assert_eq!(roster.state, State::Unknown, "{word}");
            let line = format!("lane-mail-check: agent-scan={word}");
            assert!(
                roster.rows.lines().any(|l| l == line),
                "{word}: {}",
                roster.rows
            );
        }
    }
}
