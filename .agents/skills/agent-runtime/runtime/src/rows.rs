//! The session rows a harness's hooks write, one JSON object per line, read
//! for what the harness itself said of its session: up, walled, gone; and
//! the one writer of those rows, which takes a `flock` on the file itself.
//! This reader holds the verdict tables, one for
//! an overseer's rows and one for a lane's, which `agent-runtime rows
//! verdict --kind session|lane` prints; the row shapes follow Claude Code's
//! hook inputs, Pi's carrier and Copilot's camelCase payloads as that
//! library names them. Codex and Copilot write no failure row: their
//! failed turn is read from their own session record
//! (`session::last_failure`) and judged as the row [`failure_row`] makes.
//!
//! Every read is three-valued: `Live(row)` is the last row, `Gone` a file
//! that is absent or holds no row, `Unreadable` a file or a last row that
//! could not be read. A verdict is read from the last row alone, over the
//! last `SPAN` lines.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::HashMap;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::clock::SystemClock;
use crate::harness::Harness;
use crate::observe::{self, WallKind};
use crate::process;
use crate::reading::Reading;
use crate::record::Wait;
use crate::session::Failure;
use crate::stop::{self, Kind};

/// The rows a reader looks back over for the last one: a session appends a
/// start, an end, a failure per wall and a Stop per turn
/// (`SESSION_ROWS_SPAN`).
pub const SPAN: usize = 64;

/// The harness's own text for a request refused for its prompt's length,
/// matched lowercased as a substring over
/// the row's `message` and `error_details`.
const PROMPT_TOO_LONG: [&str; 1] = ["prompt is too long"];

/// The words a Codex or Copilot record types a request refused for its
/// context's length with, the same refusal as [`PROMPT_TOO_LONG`]: Codex
/// 0.172.0's `codex_error_info` variant `context_window_exceeded`, which its
/// binary names, and Copilot CLI 1.0.116's `errorType` `context_limit`, which
/// its SDK's `ErrorData.errorType` names.
const FULL_CONTEXT: [(Harness, &str); 2] = [
    (Harness::Codex, "context_window_exceeded"),
    (Harness::Copilot, "context_limit"),
];

/// A Pi lane's ordinary turn end, which an idle verdict carries no cause
/// for: Pi's own `stop`, which both providers write for a finished turn
/// (`pi-claude-bridge/src/assistant-stream.ts` `mapStopReason`,
/// `pi-codex-minimal-tools/src/providers/openai-responses-shared.ts`
/// `mapStopReason`), and Anthropic's raw `end_turn` the bridge maps to it.
/// Every other word is carried as the harness wrote it.
const ORDINARY_END: [&str; 2] = ["stop", "end_turn"];

/// One session row as this reader takes it: the fields the two verdicts
/// read, each absent where the row carries none.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Row {
    /// The one-based line read from the rows file, never a payload field.
    #[serde(skip)]
    pub position: usize,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub event: Option<String>,
    #[serde(default)]
    pub digest: Option<u32>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub error_details: Option<String>,
    /// The HTTP status of a failure read from a Copilot session record.
    #[serde(default)]
    pub status: Option<u16>,
    #[serde(default)]
    pub stop_reason: Option<String>,
    /// The carrier's count of working agents on a Pi Stop row; `null` is
    /// the carrier's failed task read, kept apart from an absent key.
    #[serde(default, deserialize_with = "present")]
    pub working_agents: Option<Value>,
    #[serde(default)]
    pub session_id: Option<String>,
    /// The epoch second the row was written at.
    #[serde(default)]
    pub at: Option<u64>,
}

/// A key that is present, whatever its value: `Some(Null)` for a written
/// `null`, where serde's own `Option` reads `None`.
fn present<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

/// What an overseer's last row says of its session (`rows verdict --kind
/// session`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum SessionVerdict {
    /// The row carries no evidence this verdict reads: an unknown harness, a
    /// Codex or Copilot row that is no failure, or a Pi row that is neither a
    /// SessionEnd nor a StopFailure with a `message`.
    Unsupported,
    /// A SessionEnd for any reason but `clear` and `resume`.
    Ended,
    /// A StopFailure the account refused: an ended or refused sign-in
    /// (`auth`), or a usage limit or spent credit (`usage`).
    Walled { kind: WallKind },
    /// A StopFailure for a prompt too long: every turn fails the same way
    /// while the harness stays up.
    Wedged,
    /// Any other Claude Code row, a SessionEnd for `clear` or `resume`, a Pi
    /// StopFailure whose message names no limit, no sign-in and no prompt too
    /// long, or a Codex or Copilot failure the provider made.
    Live,
}

/// Turn-end evidence carried by an overseer's session row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionIdle {
    Returned,
    Failed { cause: String },
}

/// A single judgment of the row, with the position of its turn evidence.
#[must_use]
pub struct SessionObservation {
    pub verdict: SessionVerdict,
    pub idle: Option<SessionIdle>,
    pub harness: Option<String>,
    pub position: usize,
    pub message: Option<String>,
}

pub fn observe_session(row: Row) -> SessionObservation {
    let verdict = judge_session(&row);
    let idle = if matches!(verdict, SessionVerdict::Live | SessionVerdict::Unsupported) {
        match row.event.as_deref() {
            Some("Stop") => Some(SessionIdle::Returned),
            _ => failure_cause(&row).map(|cause| SessionIdle::Failed {
                cause: cause.to_owned(),
            }),
        }
    } else {
        None
    };
    SessionObservation {
        verdict,
        idle,
        harness: row.harness,
        position: row.position,
        message: row.message,
    }
}

/// Claude's StopFailure, and the one a Codex or Copilot record gives,
/// carries the error kind. Claude's safety refusal shares
/// `invalid_request` with refusals no continuation clears, so it carries
/// [`stop::REFUSAL`]. Pi's StopFailure comes from the carrier only for an
/// error, with no separate kind.
fn failure_cause(row: &Row) -> Option<&str> {
    match (row.harness.as_deref(), row.event.as_deref()) {
        (Some("claude"), Some("StopFailure")) => {
            stop::claude_failure_word(row.error.as_deref(), row.message.as_deref().unwrap_or(""))
        }
        (Some("codex" | "copilot"), Some("StopFailure")) => row.error.as_deref(),
        (Some("pi"), Some("StopFailure")) => Some("error"),
        _ => None,
    }
}

/// The wall a failed Pi turn's message names: a refused sign-in, or the
/// account's limit banner. Pi names no error kind of its own.
fn pi_wall(message: &str) -> Option<WallKind> {
    if observe::pi_auth_failure(message) {
        Some(WallKind::Auth)
    } else {
        observe::limit_banner(message).map(|_| WallKind::Usage)
    }
}

/// The kind of stop a failed turn's row names: its word and status
/// ([`stop::of_failure`]) on Claude, Codex and Copilot, its message on Pi.
fn failed_kind(harness: Harness, row: &Row) -> Option<Kind> {
    match harness {
        Harness::Pi => {
            Some(pi_wall(row.message.as_deref().unwrap_or("")).map_or(Kind::Provider, Kind::from))
        }
        Harness::Claude | Harness::Codex | Harness::Copilot => {
            stop::of_failure(harness, failure_cause(row), row.status)
        }
    }
}

/// The kind of stop an overseer's last row names, read from the verdict
/// table: a wall's kind, an ended session as an exited harness, and a
/// failed turn's kind ([`failed_kind`]). A prompt too long, an ordinary
/// turn and a row no verdict reads name none.
pub fn stop_of(row: &Row) -> Option<Kind> {
    match judge_session(row) {
        SessionVerdict::Walled { kind } => Some(kind.into()),
        SessionVerdict::Ended => Some(Kind::Exited),
        SessionVerdict::Wedged => None,
        SessionVerdict::Live | SessionVerdict::Unsupported => {
            if row.event.as_deref() != Some("StopFailure") {
                return None;
            }
            failed_kind(Harness::parse(row.harness.as_deref()?)?, row)
        }
    }
}

/// The StopFailure row a failed turn in a Codex or Copilot session record
/// stands for, judged by the same table as a hook's row.
pub fn failure_row(harness: Harness, failure: &Failure) -> Row {
    Row {
        harness: Some(harness.name().to_owned()),
        event: Some("StopFailure".to_owned()),
        error: failure.error.clone(),
        message: Some(failure.message.clone()),
        status: failure.status,
        at: failure.at,
        ..Row::default()
    }
}

/// What a lane's last row says (`rows verdict --kind lane`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum LaneVerdict {
    /// A prompt, a PreToolUse row, or a Stop whose carrier counts working agents.
    Working,
    /// A Stop row that ended no error, or an error that is no limit;
    /// `cause` is the row's `stop_reason` word where the harness wrote
    /// one that is not its ordinary end ([`ORDINARY_END`]; Pi's `length`
    /// is a turn its output limit cut), so the stop's cause reaches the
    /// line the overseer reads and a finished round carries none.
    Idle { cause: Option<String> },
    /// A Stop row whose error message is the account's limit or a refused
    /// sign-in, or a Claude failure whose error word names either; `kind`
    /// is which.
    Walled { kind: WallKind },
}

/// The last row of `file`, from the last [`SPAN`] lines: `Gone` where the
/// file is absent or holds no row, `Unreadable` where it, or the row, could
/// not be read.
pub fn last_row(file: &Path) -> Reading<Row> {
    read_file(file, last_row_in)
}

/// The launch boundary, in the same one-based line positions as [`Row`].
/// Count even an unfinished line: an append closes it before adding a row.
pub fn last_position(file: &Path) -> Reading<usize> {
    read_file(file, |text| Reading::Live(text.lines().count()))
}

fn read_file<T>(file: &Path, read: impl FnOnce(&str) -> Reading<T>) -> Reading<T> {
    match fs::read_to_string(file) {
        Ok(text) => read(&text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
        Err(_) => Reading::Unreadable {
            cause: "rows-file-unreadable",
        },
    }
}

/// The last row of a rows file's text, read as [`last_row`] reads the file:
/// for a file read elsewhere, as through a lane's provider.
pub fn last_row_in(text: &str) -> Reading<Row> {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(SPAN);
    let Some((index, last)) = lines[start..]
        .iter()
        .enumerate()
        .rev()
        .find(|(_, l)| !l.trim().is_empty())
    else {
        return Reading::Gone;
    };
    row_in(last, start + index + 1)
}

fn row_in(line: &str, position: usize) -> Reading<Row> {
    match serde_json::from_str::<Value>(line) {
        Ok(Value::Object(_)) => match serde_json::from_str::<Row>(line) {
            Ok(mut row) => {
                row.position = position;
                Reading::Live(row)
            }
            Err(_) => Reading::Unreadable {
                cause: "rows-row-unparsed",
            },
        },
        // A fragment a killed writer left, or a line that is no object,
        // is a row this reader cannot judge, never an absent one.
        Ok(
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_),
        )
        | Err(_) => Reading::Unreadable {
            cause: "rows-row-unparsed",
        },
    }
}

/// A cursor excludes only terminated lines: a writer may still complete
/// the final fragment after this read.
pub fn complete_line_count(text: &str) -> u64 {
    text.bytes().filter(|b| *b == b'\n').count() as u64
}

/// A caller can stop on decisive evidence without parsing later rows.
pub fn rows_after_in(text: &str, cursor: u64) -> impl Iterator<Item = Reading<Row>> + '_ {
    text.split_inclusive('\n')
        .enumerate()
        .filter(move |(index, line)| {
            line.ends_with('\n') && (*index + 1) as u64 > cursor && !line.trim().is_empty()
        })
        .map(|(index, line)| row_in(line, index + 1))
}

/// The overseer verdict of `file`'s last row.
pub fn session_verdict(file: &Path) -> Reading<SessionVerdict> {
    last_row(file).map(|row| judge_session(&row))
}

/// The overseer verdict table, over one row.
pub fn judge_session(row: &Row) -> SessionVerdict {
    let event = row.event.as_deref().unwrap_or("");
    let message = row.message.as_deref().unwrap_or("");
    let Some(harness) = row.harness.as_deref().and_then(Harness::parse) else {
        return SessionVerdict::Unsupported;
    };
    let failed = event == "StopFailure";
    let wall = match harness {
        Harness::Claude | Harness::Codex | Harness::Copilot if failed => {
            failed_kind(harness, row).and_then(Kind::wall)
        }
        Harness::Claude | Harness::Codex | Harness::Copilot | Harness::Pi => None,
    };
    if let Some(kind) = wall {
        return SessionVerdict::Walled { kind };
    }
    match harness {
        Harness::Codex | Harness::Copilot => {
            return if !failed {
                SessionVerdict::Unsupported
            } else if row
                .error
                .as_deref()
                .is_some_and(|word| FULL_CONTEXT.contains(&(harness, word)))
            {
                SessionVerdict::Wedged
            } else {
                SessionVerdict::Live
            };
        }
        Harness::Claude | Harness::Pi => {}
    }
    if event == "SessionEnd" {
        return match row.reason.as_deref() {
            Some("clear" | "resume") => SessionVerdict::Live,
            Some(_) | None => SessionVerdict::Ended,
        };
    }
    if harness == Harness::Pi && (!failed || message.is_empty()) {
        return SessionVerdict::Unsupported;
    }
    if event == "StopFailure" {
        let text =
            format!("{message}\n{}", row.error_details.as_deref().unwrap_or("")).to_lowercase();
        if PROMPT_TOO_LONG.iter().any(|p| text.contains(p)) {
            return SessionVerdict::Wedged;
        }
    }
    if harness == Harness::Pi {
        return pi_wall(message)
            .map_or(SessionVerdict::Live, |kind| SessionVerdict::Walled { kind });
    }
    SessionVerdict::Live
}

/// The lane verdict of `file`'s last row: a row the table cannot judge
/// is `Unreadable`, never a verdict.
pub fn lane_verdict(file: &Path) -> Reading<LaneVerdict> {
    match last_row(file) {
        Reading::Live(row) => judge_lane(&row),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// The lane verdict table, over one row.
pub fn judge_lane(row: &Row) -> Reading<LaneVerdict> {
    let event = row.event.as_deref().unwrap_or("");
    if event == "StopFailure" && row.harness.as_deref() == Some("claude") {
        return Reading::Live(
            match failed_kind(Harness::Claude, row).and_then(Kind::wall) {
                Some(kind) => LaneVerdict::Walled { kind },
                None => LaneVerdict::Idle {
                    cause: failure_cause(row).map(str::to_owned),
                },
            },
        );
    }
    if event == "Stop"
        && let Some(count) = &row.working_agents
    {
        // Null is the carrier's failed task read, never evidence of an
        // idle lane; so is a count that is no whole number.
        let Some(n) = count.as_u64() else {
            return Reading::Unreadable {
                cause: "working-agents-unread",
            };
        };
        if n > 0 {
            return Reading::Live(LaneVerdict::Working);
        }
    }
    let idle = || {
        Reading::Live(LaneVerdict::Idle {
            cause: row
                .stop_reason
                .as_deref()
                .filter(|word| !ORDINARY_END.contains(word))
                .map(str::to_owned),
        })
    };
    match (event, row.stop_reason.as_deref()) {
        ("UserPromptSubmit" | "PreToolUse", _) => Reading::Live(LaneVerdict::Working),
        ("Stop", Some("error")) => match pi_wall(row.message.as_deref().unwrap_or("")) {
            Some(kind) => Reading::Live(LaneVerdict::Walled { kind }),
            None => idle(),
        },
        ("Stop", Some(_) | None) => idle(),
        (_, _) => Reading::Unreadable {
            cause: "lane-row-unjudged",
        },
    }
}

// ---------------------------------------------------------------------------
// The writer
// ---------------------------------------------------------------------------

/// How long an append waits for its lock: below the least `timeout:` a
/// hook that writes a row declares, session-end-row's 3 s, so a writer that
/// loses the lock says so before its harness kills it.
pub const WAIT: Wait = Wait {
    limit: Duration::from_secs(2),
    poll: Duration::from_millis(100),
    timer: &SystemClock,
};

/// The rows file of the session on `pane` of the tmux server `server`, in
/// the overseer mailbox directory `dir`. The pane id's `%` is dropped, so
/// the name holds no character a shell or a glob reads.
pub fn session_file(dir: &Path, server: u32, pane: &str) -> PathBuf {
    let pane = pane.strip_prefix('%').unwrap_or(pane);
    dir.join(format!("session-{server}-{pane}.jsonl"))
}

/// Why a row or a stamp was not written. The text is the cause a hook's
/// report carries under its own key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unwritten {
    /// The lock stayed held past the wait.
    Locked { lock: PathBuf, wait_s: u64 },
    /// A read or a write of `path` failed.
    Io {
        op: &'static str,
        path: PathBuf,
        cause: String,
    },
    /// The payload names no event and its hook named none.
    EventUnnamed,
    /// The process table could not be read, so whether this session is its
    /// pane's top-level harness is unknown.
    TableUnread(&'static str),
}

impl fmt::Display for Unwritten {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Unwritten::Locked { lock, wait_s } => {
                write!(
                    f,
                    "lock-timeout lock-file={} wait-s={wait_s}",
                    lock.display()
                )
            }
            Unwritten::Io { op, path, cause } => {
                write!(f, "{op}-failed path={} {cause}", path.display())
            }
            Unwritten::EventUnnamed => f.write_str("the payload names no hook_event_name"),
            Unwritten::TableUnread(cause) => write!(f, "process-table={cause}"),
        }
    }
}

/// Pause before the next attempt on `lock`, or refuse once `deadline` has
/// passed: a pause is one poll, clamped to the time left.
fn pause(wait: &Wait, deadline: Instant, lock: &Path) -> Result<(), Unwritten> {
    let now = wait.timer.now();
    if now >= deadline {
        return Err(Unwritten::Locked {
            lock: lock.to_path_buf(),
            wait_s: wait.limit.as_secs(),
        });
    }
    wait.timer.sleep(wait.poll.min(deadline - now));
    Ok(())
}

/// Add `line` to `file` under a `flock` on the file itself, taken within
/// `wait`. A fragment a killed writer left is closed first, so the line
/// lands whole. `guard`, where given, judges the file under the lock and
/// refuses the line with `false`: `Ok(false)`, nothing written.
fn append(
    file: &Path,
    line: &str,
    wait: Wait,
    guard: Option<&dyn Fn(&Path) -> bool>,
) -> Result<bool, Unwritten> {
    let io = |op, e: std::io::Error| Unwritten::Io {
        op,
        path: file.to_path_buf(),
        cause: e.to_string(),
    };
    let handle = OpenOptions::new()
        .create(true)
        .append(true)
        .read(true)
        .open(file)
        .map_err(|e| io("open", e))?;
    let deadline = wait.timer.now() + wait.limit;
    let mut rw = fd_lock::RwLock::new(handle);
    loop {
        match rw.try_write() {
            Ok(mut held) => {
                let len = held.metadata().map_err(|e| io("read", e))?.len();
                if len > 0 {
                    let mut last = [0u8; 1];
                    held.read_exact_at(&mut last, len - 1)
                        .map_err(|e| io("read", e))?;
                    if last[0] != b'\n' {
                        held.write_all(b"\n").map_err(|e| io("write", e))?;
                    }
                }
                if let Some(guard) = guard
                    && !guard(file)
                {
                    return Ok(false);
                }
                held.write_all(format!("{line}\n").as_bytes())
                    .map_err(|e| io("write", e))?;
                return Ok(true);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                pause(&wait, deadline, file)?;
            }
            Err(e) => return Err(io("flock", e)),
        }
    }
}

/// The last object row of `file` over its last [`SPAN`] lines, `None`
/// where the file is absent or holds none. A line that is no object is a
/// fragment a killed writer left, which the next append closes, and is
/// passed over as the mailbox reader passes one (`session_rows_last`).
fn last_object(file: &Path) -> Result<Option<Map<String, Value>>, Unwritten> {
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(Unwritten::Io {
                op: "read",
                path: file.to_path_buf(),
                cause: e.to_string(),
            });
        }
    };
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(SPAN);
    Ok(lines[start..]
        .iter()
        .rev()
        .find_map(|line| match serde_json::from_str::<Value>(line) {
            Ok(Value::Object(row)) => Some(row),
            Ok(_) | Err(_) => None,
        }))
}

fn event_of(row: &Map<String, Value>) -> &str {
    row.get("event").and_then(Value::as_str).unwrap_or("")
}

/// What a session's harness said of one event, as its hook payload names
/// it, each field carried only where it is a non-empty string.
#[derive(Debug, Default, Clone, Copy)]
pub struct Fields<'a> {
    pub session_id: Option<&'a str>,
    pub transcript_path: Option<&'a str>,
    pub cwd: Option<&'a str>,
    pub source: Option<&'a str>,
    pub model: Option<&'a str>,
    pub reason: Option<&'a str>,
    pub error: Option<&'a str>,
    pub error_details: Option<&'a str>,
    /// `last_assistant_message`, carried as `message` wherever the payload
    /// holds a string, an empty one included.
    pub message: Option<&'a str>,
}

/// One session row: its event, the harness the hook's install names, the
/// account the session runs on (none where empty), its epoch second and
/// what the payload said.
#[derive(Debug, Clone, Copy)]
pub struct SessionRow<'a> {
    pub event: &'a str,
    pub harness: &'a str,
    pub account: &'a str,
    pub at: u64,
    pub fields: Fields<'a>,
}

/// `value` under `key` where it is a non-empty string.
fn put(row: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|v| !v.is_empty()) {
        row.insert(key.to_owned(), Value::String(value.to_owned()));
    }
}

/// Append one session row to `file`. A Stop row is compact, its time,
/// event, harness and session alone, so the file takes one per turn,
/// except over a standing StopFailure, which it lifts carrying the turn's
/// last message.
pub fn write_session(file: &Path, row: &SessionRow, wait: Wait) -> Result<(), Unwritten> {
    let mut line = Map::new();
    line.insert("at".to_owned(), Value::from(row.at));
    line.insert("event".to_owned(), Value::from(row.event));
    line.insert("harness".to_owned(), Value::from(row.harness));
    let fields = &row.fields;
    put(&mut line, "session_id", fields.session_id);
    let compact = row.event == "Stop"
        && last_object(file)?.is_none_or(|last| event_of(&last) != "StopFailure");
    if !compact {
        put(&mut line, "transcript_path", fields.transcript_path);
        put(&mut line, "cwd", fields.cwd);
        put(&mut line, "source", fields.source);
        put(&mut line, "model", fields.model);
        put(&mut line, "reason", fields.reason);
        put(&mut line, "error", fields.error);
        put(&mut line, "error_details", fields.error_details);
        if let Some(message) = fields.message {
            line.insert("message".to_owned(), Value::from(message));
        }
        put(&mut line, "account", Some(row.account));
    }
    append(file, &Value::Object(line).to_string(), wait, None).map(|_| ())
}

/// A lane's rows file inside the lane's mailbox directory.
pub const LANE_FILE: &str = "session-rows.jsonl";

/// The transcript tail a Pi Stop row reads its turn's end from: a session
/// file grows without limit and its last assistant message is at its end.
const TRANSCRIPT_TAIL: u64 = 1_048_576;

/// The events a lane's rows take.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnEvent<'a> {
    /// A turn end.
    Stop,
    /// A tool call, written only where it opens a turn.
    PreToolUse,
    /// A submitted prompt, including one before the first tool call.
    Prompt { digest: Option<u32> },
    /// Claude's failed turn, which emits no Stop afterward.
    StopFailure { error: Option<&'a str> },
}

/// One lane row.
#[derive(Debug, Clone, Copy)]
pub struct LaneRow<'a> {
    pub event: TurnEvent<'a>,
    pub harness: &'a str,
    pub at: u64,
    /// The session file a Stop row reads its turn's last assistant message
    /// from.
    pub transcript: Option<&'a Path>,
    /// The carrier's working-agent count on a Stop payload that holds the
    /// key, `null` included: the carrier's failed task read.
    pub working_agents: Option<&'a Value>,
}

/// Append one row for the lane whose mailbox directory is `dir`: a Stop at
/// a turn end, carrying the `stopReason` of the turn's last assistant
/// message in the transcript (Pi's `AssistantMessage`), its `errorMessage`
/// as `message` where that reason is `error`, and the working-agent count;
/// a PreToolUse at a tool call only over an ended turn or an empty file, so a
/// turn of many tool calls opens one. A prompt always opens a new turn and
/// a Claude failure closes it with the harness's error word.
/// `Ok(false)` where nothing is written:
/// no mailbox directory, or a turn already open.
pub fn write_lane(dir: &Path, row: &LaneRow, wait: Wait) -> Result<bool, Unwritten> {
    if !dir.is_dir() {
        return Ok(false);
    }
    let file = dir.join(LANE_FILE);
    let mut line = Map::new();
    line.insert("at".to_owned(), Value::from(row.at));
    let event = match row.event {
        TurnEvent::Stop => "Stop",
        TurnEvent::PreToolUse => "PreToolUse",
        TurnEvent::Prompt { .. } => "UserPromptSubmit",
        TurnEvent::StopFailure { .. } => "StopFailure",
    };
    line.insert("event".to_owned(), Value::from(event));
    line.insert("harness".to_owned(), Value::from(row.harness));
    match row.event {
        TurnEvent::Stop => {
            if let Some(transcript) = row.transcript.filter(|t| t.is_file()) {
                turn_end(transcript, &mut line)?;
            }
            if let Some(count) = row.working_agents {
                line.insert("working_agents".to_owned(), count.clone());
            }
            append(&file, &Value::Object(line).to_string(), wait, None)
        }
        TurnEvent::PreToolUse => append(
            &file,
            &Value::Object(line).to_string(),
            wait,
            Some(&turn_open),
        ),
        TurnEvent::Prompt { digest } => {
            if let Some(digest) = digest {
                line.insert("digest".to_owned(), Value::from(digest));
            }
            append(&file, &Value::Object(line).to_string(), wait, None)
        }
        TurnEvent::StopFailure { error } => {
            if let Some(error) = error {
                line.insert("error".to_owned(), Value::from(error));
            }
            append(&file, &Value::Object(line).to_string(), wait, None)
        }
    }
}

/// Whether `file`'s last row is a turn end, or the file holds none: the
/// state a PreToolUse row opens a turn over. A file this cannot read
/// answers yes, so the append itself meets the fault and reports it.
fn turn_open(file: &Path) -> bool {
    last_object(file).map_or(true, |last| {
        last.is_none_or(|row| matches!(event_of(&row), "Stop" | "StopFailure"))
    })
}

/// The turn's end from the last assistant message in the transcript's
/// tail, into `line`. A line that is no JSON, the tail's cut first line
/// among them, is passed over.
fn turn_end(transcript: &Path, line: &mut Map<String, Value>) -> Result<(), Unwritten> {
    let io = |e: std::io::Error| Unwritten::Io {
        op: "read",
        path: transcript.to_path_buf(),
        cause: e.to_string(),
    };
    let mut file = File::open(transcript).map_err(io)?;
    let len = file.metadata().map_err(io)?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(TRANSCRIPT_TAIL)))
        .map_err(io)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(io)?;
    let text = String::from_utf8_lossy(&bytes);
    let last = text
        .lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|entry| {
            entry.get("type").and_then(Value::as_str) == Some("message")
                && entry.pointer("/message/role").and_then(Value::as_str) == Some("assistant")
        })
        .and_then(|entry| entry.get("message").cloned());
    let Some(message) = last else {
        return Ok(());
    };
    if let Some(reason) = message.get("stopReason").and_then(Value::as_str) {
        line.insert("stop_reason".to_owned(), Value::from(reason));
        if reason == "error"
            && let Some(error) = message.get("errorMessage").and_then(Value::as_str)
        {
            line.insert("message".to_owned(), Value::from(error));
        }
    }
    Ok(())
}

/// Whether the session this process's parent `from` serves is its pane's
/// top-level harness: exactly one process that is no shell stands from
/// `from` up to the pane's own process, the child of the tmux server
/// `server` (tmux forks every pane's process from its server), that
/// process included. A harness nested under another, which the other one's
/// tool shell started, counts two; a harness that is the pane's process
/// itself, as a launch's `exec` leaves it, counts one. A harness's
/// installed Node launcher ([`NODE_LAUNCHERS`]) and its native child count
/// as one, which `launcher` judges of the native process's parent. A
/// process under no pane of `server` never reaches one, and the walk
/// refuses past 64 steps.
pub fn top_level(
    rows: &[process::Row],
    from: u32,
    server: u32,
    launcher: &dyn Fn(u32, Harness) -> bool,
) -> bool {
    let by_pid: HashMap<u32, &process::Row> = rows.iter().map(|row| (row.pid, row)).collect();
    let mut pid = from;
    let mut child: Option<&str> = None;
    let mut harnesses = 0u32;
    for _ in 0..64 {
        let Some(row) = by_pid.get(&pid).filter(|_| pid > 1) else {
            return false;
        };
        let launched = child
            .and_then(launched_by_node)
            .is_some_and(|harness| launcher(pid, harness));
        let uncounted = process::is_shell(&row.name) || launched;
        if !uncounted {
            harnesses += 1;
        }
        if row.ppid == server {
            return harnesses == 1;
        }
        child = Some(&row.name);
        pid = row.ppid;
    }
    false
}

/// [`top_level`] for this process's own parent, over one read of the
/// process table.
pub fn top_level_here(server: u32) -> Result<bool, Unwritten> {
    let rows = process::table().map_err(|unread| Unwritten::TableUnread(unread.cause))?;
    Ok(top_level(
        &rows,
        std::os::unix::process::parent_id(),
        server,
        &node_launcher,
    ))
}

/// Whether the call this process's parent `from` serves runs under the
/// recorded harness process `recorded`: `recorded` stands on `from`'s
/// ancestor chain, `from` included, and no other process `is_harness`
/// names stands between them, so a job a lane lead's tool shell started
/// under a harness of its own is told apart from the lead. A harness's
/// native process directly under a recorded installed Node launcher
/// ([`NODE_LAUNCHERS`]), which `launcher` judges, is the launcher's own. A
/// chain that ends first, or a cycle the walk's bound of 64 steps ends, is
/// not served by `recorded`.
pub fn served_by(
    rows: &[process::Row],
    from: u32,
    recorded: u32,
    is_harness: &dyn Fn(&str) -> bool,
    launcher: &dyn Fn(u32, Harness) -> bool,
) -> bool {
    let by_pid: HashMap<u32, &process::Row> = rows.iter().map(|row| (row.pid, row)).collect();
    let mut pid = from;
    for _ in 0..64 {
        if pid == recorded {
            return true;
        }
        let Some(row) = by_pid.get(&pid).filter(|_| pid > 1) else {
            return false;
        };
        let launched = row.ppid == recorded
            && launched_by_node(&row.name).is_some_and(|harness| launcher(recorded, harness));
        if is_harness(&row.name) && !launched {
            return false;
        }
        pid = row.ppid;
    }
    false
}

/// [`served_by`] for this process's own parent, over one read of the
/// process table.
pub fn served_by_here(
    recorded: u32,
    is_harness: &dyn Fn(&str) -> bool,
) -> Result<bool, crate::reading::Unreadable> {
    let rows = process::table()?;
    Ok(served_by(
        &rows,
        std::os::unix::process::parent_id(),
        recorded,
        is_harness,
        &node_launcher,
    ))
}

/// The harnesses whose npm install puts a Node launcher on `PATH` that
/// spawns the native binary and stays as its parent, each with the
/// launcher's script under its package: Codex's `bin/codex.js`, and
/// Copilot CLI's `npm-loader.js`, which runs `spawn(<platform binary>,
/// argv, {stdio: "inherit"})`.
const NODE_LAUNCHERS: [(Harness, &str); 2] = [
    (Harness::Codex, "@openai/codex/bin/codex.js"),
    (Harness::Copilot, "@github/copilot/npm-loader.js"),
];

/// The harness of [`NODE_LAUNCHERS`] that owns the process named `name`
/// (`Harness::owns_process`), whose parent may be that harness's launcher.
fn launched_by_node(name: &str) -> Option<Harness> {
    NODE_LAUNCHERS
        .iter()
        .map(|(harness, _)| *harness)
        .find(|harness| harness.owns_process(name))
}

/// Whether `pid` is `harness`'s installed Node launcher.
fn node_launcher(pid: u32, harness: Harness) -> bool {
    process::command_lines().is_ok_and(|lines| {
        lines
            .iter()
            .any(|(p, words)| *p == pid && is_node_launcher(words, harness))
    })
}

/// Whether a process's argument words are `harness`'s installed Node
/// launcher's: `node` running an absolute script that resolves, through
/// every link, to that harness's script under its package
/// ([`NODE_LAUNCHERS`]).
fn is_node_launcher(words: &[String], harness: Harness) -> bool {
    let Some((_, script_in_package)) = NODE_LAUNCHERS.iter().find(|(h, _)| *h == harness) else {
        return false;
    };
    let (Some(executable), Some(script)) = (words.first(), words.get(1)) else {
        return false;
    };
    // Node can rename its command name; its argument words still name it.
    if Path::new(executable).file_name().and_then(|n| n.to_str()) != Some("node") {
        return false;
    }
    let script = Path::new(script);
    if !script.is_absolute() {
        return false;
    }
    fs::canonicalize(script).is_ok_and(|real| real.is_file() && real.ends_with(script_in_package))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(json: &str) -> Row {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn rows_after_a_complete_line_cursor_keep_positions_and_prompt_digests() {
        let prefix = "{\"event\":\"Stop\"}\n\n";
        let prompt = "{\"event\":\"UserPromptSubmit\",\"digest\":42}";
        let partial = format!("{prefix}{prompt}");
        let cursor = complete_line_count(&partial);
        assert_eq!(cursor, 2);
        assert!(rows_after_in(&partial, cursor).next().is_none());
        let text = format!("{partial}\n{{\"event\":\"UserPromptSubmit\"}}\n{{");
        let rows = rows_after_in(&text, cursor)
            .map(|reading| {
                let Reading::Live(row) = reading else {
                    panic!("completed rows must read");
                };
                row
            })
            .collect::<Vec<_>>();
        assert_eq!(
            rows.iter()
                .map(|r| (r.position, r.event.as_deref(), r.digest))
                .collect::<Vec<_>>(),
            vec![
                (3, Some("UserPromptSubmit"), Some(42)),
                (4, Some("UserPromptSubmit"), None)
            ]
        );
        for text in ["not-json\n", "[]\n", "null\n"] {
            assert!(matches!(
                rows_after_in(text, 0).next(),
                Some(Reading::Unreadable { .. })
            ));
        }
        let text = format!("{prompt}\nnot-json\n");
        let mut rows = rows_after_in(&text, 0);
        assert!(matches!(
            rows.next(),
            Some(Reading::Live(Row {
                digest: Some(42),
                ..
            }))
        ));
        assert!(matches!(rows.next(), Some(Reading::Unreadable { .. })));
    }

    /// The overseer verdict table, one row per form it judges: each
    /// harness's SessionEnd and StopFailure shapes, a Pi row with and
    /// without a limit message, a Copilot row, and the too-long prompt.
    #[test]
    fn the_session_verdict_reads_each_harness_s_end_failure_and_stop_forms() {
        let rows: [(&str, SessionVerdict); 17] = [
            (
                r#"{"harness":"claude","event":"SessionEnd","reason":"exit"}"#,
                SessionVerdict::Ended,
            ),
            (
                r#"{"harness":"claude","event":"SessionEnd","reason":"clear"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"SessionEnd","reason":"resume"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"rate_limit","message":"You've hit your weekly limit"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Usage,
                },
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"authentication_failed"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Auth,
                },
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"other","message":"Prompt is too long"}"#,
                SessionVerdict::Wedged,
            ),
            (
                r#"{"harness":"claude","event":"Stop","session_id":"s"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"StopFailure","message":"429 Usage limit reached for this model"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Usage,
                },
            ),
            (
                r#"{"harness":"pi","event":"StopFailure","message":"connection reset"}"#,
                SessionVerdict::Live,
            ),
            (
                r#"{"harness":"pi","event":"Stop"}"#,
                SessionVerdict::Unsupported,
            ),
            (
                r#"{"harness":"copilot","event":"SessionEnd","reason":"exit"}"#,
                SessionVerdict::Unsupported,
            ),
            // The failure rows a Codex or Copilot record stands for
            // (`failure_row`): a sign-in each harness names, and a word the
            // table does not list, which is still a failed turn.
            (
                r#"{"harness":"codex","event":"StopFailure","error":"unauthorized","message":"401"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Auth,
                },
            ),
            (
                r#"{"harness":"copilot","event":"StopFailure","error":"query","status":401,"message":"401 Unauthorized"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Auth,
                },
            ),
            (
                r#"{"harness":"copilot","event":"StopFailure","error":"authentication","message":"no account"}"#,
                SessionVerdict::Walled {
                    kind: WallKind::Auth,
                },
            ),
            (
                r#"{"harness":"codex","event":"StopFailure","error":"internal_server_error","message":"500"}"#,
                SessionVerdict::Live,
            ),
            // A full context, which no continuation clears.
            (
                r#"{"harness":"codex","event":"StopFailure","error":"context_window_exceeded","message":"full"}"#,
                SessionVerdict::Wedged,
            ),
            (
                r#"{"harness":"copilot","event":"StopFailure","error":"context_limit","message":"full"}"#,
                SessionVerdict::Wedged,
            ),
        ];
        for (json, expected) in rows {
            assert_eq!(judge_session(&row(json)), expected, "{json}");
        }
    }

    /// A carrier's null count and a row the table
    /// cannot judge are no idle lane; an idle verdict carries the row's
    /// `stop_reason`, so a turn the output limit cut (`length`) reads as cut,
    /// and never the harness's ordinary end (`stop`, `end_turn`), so a
    /// finished round carries no cause.
    #[test]
    fn the_lane_verdict_reads_working_idle_and_walled_and_refuses_what_it_cannot_judge() {
        let idle = |cause: Option<&str>| {
            Reading::Live(LaneVerdict::Idle {
                cause: cause.map(str::to_owned),
            })
        };
        let walled = |kind| Reading::Live(LaneVerdict::Walled { kind });
        let rows = [
            (
                r#"{"harness":"claude","event":"UserPromptSubmit"}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"codex","event":"UserPromptSubmit"}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"copilot","event":"UserPromptSubmit"}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"model_not_found"}"#,
                idle(Some("model_not_found")),
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"rate_limit"}"#,
                walled(WallKind::Usage),
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"authentication_failed"}"#,
                walled(WallKind::Auth),
            ),
            // Claude Code 2.1.332 types a full context `invalid_request`,
            // which no continuation clears; its safety refusal, which carries
            // the policy link, is a refusal.
            (
                r#"{"harness":"claude","event":"StopFailure","error":"invalid_request","message":"Prompt is too long"}"#,
                idle(Some("invalid_request")),
            ),
            (
                r#"{"harness":"claude","event":"StopFailure","error":"invalid_request","message":"API Error: Sonnet 4.5 can't help with this. Start a new session to continue.\n\nLearn more: https://www.anthropic.com/legal/aup"}"#,
                idle(Some("refusal")),
            ),
            (
                r#"{"harness":"pi","event":"PreToolUse"}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":2}"#,
                Reading::Live(LaneVerdict::Working),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":0}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"stop","working_agents":0}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"end_turn"}"#,
                idle(None),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"length","working_agents":0}"#,
                idle(Some("length")),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"toolUse","working_agents":0}"#,
                idle(Some("toolUse")),
            ),
            (
                r#"{"harness":"pi","event":"Stop","working_agents":null}"#,
                Reading::Unreadable {
                    cause: "working-agents-unread",
                },
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"429 Usage limit reached for this model"}"#,
                walled(WallKind::Usage),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}"}"#,
                walled(WallKind::Auth),
            ),
            (
                r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"tool failed"}"#,
                idle(Some("error")),
            ),
            (
                r#"{"harness":"pi","event":"SessionStart"}"#,
                Reading::Unreadable {
                    cause: "lane-row-unjudged",
                },
            ),
        ];
        for (json, expected) in rows {
            assert_eq!(judge_lane(&row(json)), expected, "{json}");
        }
    }

    /// Claude Code 2.1.332 writes `invalid_request` for a full context and
    /// for its safety refusal alike. Only the refusal's cause names a
    /// provider stop, which a continuation can clear.
    #[test]
    fn a_claude_lane_s_safety_refusal_names_a_provider_stop_and_a_full_context_none() {
        for (message, kind) in [
            ("Prompt is too long", None),
            (
                "API Error: Sonnet 4.5 can't help with this. Start a new session to continue.\n\nLearn more: https://www.anthropic.com/legal/aup",
                Some(Kind::Provider),
            ),
            (
                "This model's safeguards flagged this message. This sometimes happens with safe, normal conversations.",
                Some(Kind::Provider),
            ),
        ] {
            let failure = Row {
                harness: Some("claude".to_owned()),
                event: Some("StopFailure".to_owned()),
                error: Some("invalid_request".to_owned()),
                message: Some(message.to_owned()),
                ..Row::default()
            };
            let Reading::Live(LaneVerdict::Idle { cause: Some(cause) }) = judge_lane(&failure)
            else {
                panic!("{message}: no idle cause");
            };
            assert_eq!(stop::of_cause(Harness::Claude, &cause), kind, "{message}");
        }
    }

    #[test]
    fn lane_rows_keep_each_prompt_and_failure_position_without_a_stop() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join(LANE_FILE);
        let row = |event| LaneRow {
            event,
            harness: "claude",
            at: 7,
            transcript: None,
            working_agents: None,
        };
        let failure = TurnEvent::StopFailure {
            error: Some("model_not_found"),
        };
        for (index, event) in [
            TurnEvent::Prompt { digest: Some(42) },
            TurnEvent::Prompt { digest: None },
            failure,
            TurnEvent::Prompt { digest: Some(42) },
            failure,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(write_lane(root.path(), &row(event), BOUND), Ok(true));
            let Reading::Live(last) = last_row(&file) else {
                panic!("last row unread");
            };
            assert_eq!(last.position, index + 1);
            assert_eq!(
                last.digest,
                match event {
                    TurnEvent::Prompt { digest } => digest,
                    TurnEvent::Stop | TurnEvent::PreToolUse | TurnEvent::StopFailure { .. } => None,
                }
            );
            assert_eq!(
                judge_lane(&last),
                if matches!(event, TurnEvent::Prompt { .. }) {
                    Reading::Live(LaneVerdict::Working)
                } else {
                    Reading::Live(LaneVerdict::Idle {
                        cause: Some("model_not_found".into()),
                    })
                }
            );
            if matches!(event, TurnEvent::Prompt { .. }) {
                assert_eq!(
                    write_lane(root.path(), &row(TurnEvent::PreToolUse), BOUND),
                    Ok(false)
                );
            }
        }
        let text = format!("{}\n\n", fs::read_to_string(&file).unwrap());
        let Reading::Live(last) = last_row_in(&text) else {
            panic!("last row unread");
        };
        assert_eq!(last.position, 5);
        assert!(
            serde_json::to_value(last)
                .unwrap()
                .get("position")
                .is_none()
        );
        let padding = "\n".repeat(SPAN + 3);
        let Reading::Live(last) = last_row_in(&format!("{padding}{text}")) else {
            panic!("last row unread past span");
        };
        assert_eq!(last.position, SPAN + 8);
        assert_eq!(
            write_lane(root.path(), &row(TurnEvent::PreToolUse), BOUND),
            Ok(true)
        );
    }

    /// A lock wait of a test's own bound, short of [`WAIT`].
    const BOUND: Wait = Wait {
        limit: Duration::from_millis(300),
        poll: Duration::from_millis(20),
        timer: &SystemClock,
    };

    fn lines(file: &Path) -> Vec<String> {
        fs::read_to_string(file)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// A session row carries the payload's fields that are non-empty
    /// strings, the message even where empty, and the account; a Stop row
    /// is compact until a StopFailure stands, which the next Stop lifts
    /// with its message kept; a fragment a killed writer left is closed, so
    /// the next row lands whole. The expected lines are the shell writer's
    /// own output on these payloads.
    #[test]
    fn a_session_row_carries_the_payloads_fields_and_a_stop_over_a_stopfailure_keeps_its_message() {
        let dir = tempfile::tempdir().unwrap();
        let file = session_file(dir.path(), 4242, "%7");
        assert_eq!(file, dir.path().join("session-4242-7.jsonl"));
        let row = |event, fields| SessionRow {
            event,
            harness: "claude",
            account: "/h/.claude",
            at: 100,
            fields,
        };
        let start = Fields {
            session_id: Some("s1"),
            transcript_path: Some("/t/s1.jsonl"),
            cwd: Some("/w"),
            source: Some("startup"),
            model: Some(""),
            ..Fields::default()
        };
        let stop = Fields {
            session_id: Some("s1"),
            transcript_path: Some("/t/s1.jsonl"),
            message: Some("done"),
            ..Fields::default()
        };
        let failure = Fields {
            session_id: Some("s1"),
            error: Some("rate_limit"),
            message: Some(""),
            ..Fields::default()
        };
        write_session(&file, &row("SessionStart", start), BOUND).unwrap();
        write_session(&file, &row("Stop", stop), BOUND).unwrap();
        write_session(&file, &row("StopFailure", failure), BOUND).unwrap();
        write_session(&file, &row("Stop", stop), BOUND).unwrap();
        let mut text = fs::read_to_string(&file).unwrap();
        text.push_str(r#"{"at":101,"event":"Sto"#);
        fs::write(&file, &text).unwrap();
        write_session(&file, &row("Stop", stop), BOUND).unwrap();
        assert_eq!(
            lines(&file),
            [
                r#"{"at":100,"event":"SessionStart","harness":"claude","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"/w","source":"startup","account":"/h/.claude"}"#,
                r#"{"at":100,"event":"Stop","harness":"claude","session_id":"s1"}"#,
                r#"{"at":100,"event":"StopFailure","harness":"claude","session_id":"s1","error":"rate_limit","message":"","account":"/h/.claude"}"#,
                r#"{"at":100,"event":"Stop","harness":"claude","session_id":"s1","transcript_path":"/t/s1.jsonl","message":"done","account":"/h/.claude"}"#,
                r#"{"at":101,"event":"Sto"#,
                r#"{"at":100,"event":"Stop","harness":"claude","session_id":"s1"}"#,
            ]
        );
        let fresh = session_file(dir.path(), 4242, "%8");
        write_session(&fresh, &row("Stop", stop), BOUND).unwrap();
        assert_eq!(
            lines(&fresh),
            [r#"{"at":100,"event":"Stop","harness":"claude","session_id":"s1"}"#]
        );
    }

    /// The pane's own top-level harness alone writes a row: a harness under
    /// the pane's shell, through any shells between, counts one; a harness
    /// another harness's tool shell started counts two, under the pane's
    /// shell or under the pane's own harness; a harness that is the pane's
    /// process, as a launch's `exec` leaves it, counts one; Codex's and
    /// Copilot CLI's installed Node launchers and their native child count
    /// one, under the pane's shell or as the pane's process, and any other
    /// parent of a native process, another harness's launcher included,
    /// its own; a process under no pane of the server,
    /// a parent the table lacks, or a cycle the walk's bound ends, is no
    /// top-level session. Every pid is synthetic.
    #[test]
    fn only_the_panes_top_level_harness_writes_a_row() {
        const SERVER: u32 = 10;
        let table = |chain: &[(u32, u32, &str)]| -> Vec<process::Row> {
            chain
                .iter()
                .map(|&(pid, ppid, name)| process::Row {
                    pid,
                    ppid,
                    pgrp: pid,
                    name: name.to_owned(),
                })
                .collect()
        };
        let launcher = |pid: u32, harness: Harness| {
            matches!(
                (pid, harness),
                (31, Harness::Codex) | (41, Harness::Copilot)
            )
        };
        let cases: [(&str, Vec<process::Row>, bool); 12] = [
            (
                "a harness under the pane's shell",
                table(&[(20, SERVER, "bash"), (21, 20, "claude"), (22, 21, "bash")]),
                true,
            ),
            (
                "a harness nested under another",
                table(&[
                    (20, SERVER, "zsh"),
                    (21, 20, "claude"),
                    (23, 21, "bash"),
                    (24, 23, "codex"),
                    (22, 24, "sh"),
                ]),
                false,
            ),
            (
                "a harness nested under the pane's own harness",
                table(&[
                    (21, SERVER, "claude"),
                    (23, 21, "bash"),
                    (24, 23, "codex"),
                    (22, 24, "sh"),
                ]),
                false,
            ),
            (
                "a harness that is the pane's process",
                table(&[(21, SERVER, "claude"), (22, 21, "bash")]),
                true,
            ),
            (
                "codex under its installed node launcher as the pane's process",
                table(&[(31, SERVER, "node"), (32, 31, "codex"), (22, 32, "bash")]),
                true,
            ),
            (
                "codex under its installed node launcher",
                table(&[
                    (20, SERVER, "bash"),
                    (31, 20, "node"),
                    (32, 31, "codex"),
                    (22, 32, "bash"),
                ]),
                true,
            ),
            (
                "codex under another node",
                table(&[
                    (20, SERVER, "bash"),
                    (33, 20, "node"),
                    (32, 33, "codex"),
                    (22, 32, "bash"),
                ]),
                false,
            ),
            (
                "copilot under its installed node launcher as the pane's process",
                table(&[
                    (41, SERVER, "node-MainThread"),
                    (42, 41, "MainThread"),
                    (23, 42, "sh"),
                    (22, 23, "bash"),
                ]),
                true,
            ),
            (
                "copilot under its installed node launcher",
                table(&[
                    (20, SERVER, "bash"),
                    (41, 20, "node"),
                    (42, 41, "copilot"),
                    (22, 42, "bash"),
                ]),
                true,
            ),
            (
                "copilot under codex's node launcher",
                table(&[
                    (31, SERVER, "node"),
                    (42, 31, "MainThread"),
                    (22, 42, "bash"),
                ]),
                false,
            ),
            (
                "a process under no pane of the server",
                table(&[(2, 1, "systemd"), (21, 2, "claude"), (22, 21, "bash")]),
                false,
            ),
            (
                "a parent the table lacks",
                table(&[(21, 99, "claude"), (22, 21, "bash")]),
                false,
            ),
        ];
        for (what, rows, want) in cases {
            assert_eq!(top_level(&rows, 22, SERVER, &launcher), want, "{what}");
        }
        // A table read across a pid's reuse can name a cycle: the walk ends
        // at its bound, within a bound of the row's own.
        let cycle = table(&[(21, 22, "claude"), (22, 21, "bash")]);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(top_level(&cycle, 22, SERVER, &|_, _| false));
        });
        assert_eq!(rx.recv_timeout(Duration::from_secs(10)), Ok(false));
    }

    /// A call is served by the recorded harness process where that process
    /// stands on its chain with only shells, hook runners and the native
    /// child of a recorded Codex or Copilot CLI launcher between; a job the
    /// lead's tool shell
    /// started under a harness of its own is not, nor is a chain that never
    /// reaches the record, a parent the table lacks, or a cycle the walk's
    /// bound ends. Every pid is synthetic.
    #[test]
    fn served_by_reads_the_recorded_harness_through_shells_and_codexs_launcher_and_refuses_a_nested_harness()
     {
        let table = |chain: &[(u32, u32, &str)]| -> Vec<process::Row> {
            chain
                .iter()
                .map(|&(pid, ppid, name)| process::Row {
                    pid,
                    ppid,
                    pgrp: pid,
                    name: name.to_owned(),
                })
                .collect()
        };
        let harness = |name: &str| matches!(name, "claude" | "codex" | "pi" | "MainThread");
        let launcher = |pid: u32, harness: Harness| {
            matches!(
                (pid, harness),
                (31, Harness::Codex) | (41, Harness::Copilot)
            )
        };
        let cases: [(&str, Vec<process::Row>, u32, bool); 9] = [
            (
                "the lead's hook under shells",
                table(&[(21, 10, "claude"), (22, 21, "sh"), (23, 22, "bash")]),
                21,
                true,
            ),
            (
                "the call's parent is the recorded harness",
                table(&[(23, 10, "pi")]),
                23,
                true,
            ),
            (
                "a job under the lead's tool shell",
                table(&[
                    (21, 10, "claude"),
                    (24, 21, "bash"),
                    (25, 24, "claude"),
                    (23, 25, "sh"),
                ]),
                21,
                false,
            ),
            (
                "codex under its recorded installed node launcher",
                table(&[(31, 10, "node"), (32, 31, "codex"), (23, 32, "bash")]),
                31,
                true,
            ),
            (
                "copilot under its recorded installed node launcher",
                table(&[(41, 10, "node"), (42, 41, "MainThread"), (23, 42, "bash")]),
                41,
                true,
            ),
            (
                "codex under another recorded node",
                table(&[(33, 10, "node"), (32, 33, "codex"), (23, 32, "bash")]),
                33,
                false,
            ),
            (
                "a recorded process off the chain",
                table(&[(21, 10, "claude"), (26, 10, "bash"), (23, 26, "sh")]),
                21,
                false,
            ),
            (
                "a parent the table lacks",
                table(&[(23, 99, "sh")]),
                21,
                false,
            ),
            (
                "a chain that ends at the first process",
                table(&[(2, 1, "systemd"), (23, 2, "sh")]),
                21,
                false,
            ),
        ];
        for (what, rows, recorded, want) in cases {
            assert_eq!(
                served_by(&rows, 23, recorded, &harness, &launcher),
                want,
                "{what}"
            );
        }
        let cycle = table(&[(22, 23, "bash"), (23, 22, "sh")]);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(served_by(&cycle, 23, 21, &|_| false, &|_, _| false));
        });
        assert_eq!(rx.recv_timeout(Duration::from_secs(10)), Ok(false));
    }

    /// A Pi lane's tool call opens a turn once, over an empty file or a
    /// Stop row; a Stop carries the turn's last assistant message's stop
    /// reason, its error text where the reason is `error`, and the
    /// carrier's count, a written `null` kept; a lane with no mailbox
    /// directory writes nothing. The expected lines are the shell writer's
    /// own output on these inputs.
    #[test]
    fn a_pi_lanes_rows_open_one_turn_per_tool_call() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("tmp/lane-mail/ken-1");
        let file = dir.join(LANE_FILE);
        let transcript = root.path().join("session.jsonl");
        fs::write(
            &transcript,
            [
                r#"{"type":"message","message":{"role":"user","content":"go"}}"#,
                r#"{"type":"message","message":{"role":"assistant","stopReason":"toolUse"}}"#,
                "{\"type\":\"mess",
                r#"{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"429 Usage limit reached"}}"#,
                r#"{"type":"custom","message":{"role":"assistant","stopReason":"stop"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let zero = Value::from(0);
        let row = |event, transcript, working_agents| LaneRow {
            event,
            harness: "pi",
            at: 7,
            transcript,
            working_agents,
        };
        let tool = row(TurnEvent::PreToolUse, None, None);
        assert_eq!(write_lane(&dir, &tool, BOUND), Ok(false));
        assert!(!dir.exists());
        fs::create_dir_all(&dir).unwrap();
        let written: Vec<bool> = [
            tool,
            tool,
            row(TurnEvent::Stop, Some(transcript.as_path()), Some(&zero)),
            tool,
            row(TurnEvent::Stop, None, Some(&Value::Null)),
        ]
        .iter()
        .map(|row| write_lane(&dir, row, BOUND).unwrap())
        .collect();
        assert_eq!(written, [true, false, true, true, true]);
        assert_eq!(
            lines(&file),
            [
                r#"{"at":7,"event":"PreToolUse","harness":"pi"}"#,
                r#"{"at":7,"event":"Stop","harness":"pi","stop_reason":"error","message":"429 Usage limit reached","working_agents":0}"#,
                r#"{"at":7,"event":"PreToolUse","harness":"pi"}"#,
                r#"{"at":7,"event":"Stop","harness":"pi","working_agents":null}"#,
            ]
        );
    }

    /// An installed Node launcher is known by its argument words: an
    /// executable named `node` and an absolute script that resolves,
    /// through a link as npm installs it on `PATH`, to that harness's
    /// launcher script under its package; a relative script, another
    /// executable, another script, another harness's launcher and a missing
    /// script are not it.
    #[test]
    fn an_installed_node_launcher_is_known_by_its_resolved_script() {
        let root = tempfile::tempdir().unwrap();
        let installed = |script: &str, bin: &str| {
            let real = root.path().join("lib/node_modules").join(script);
            fs::create_dir_all(real.parent().unwrap()).unwrap();
            fs::write(&real, "").unwrap();
            let link = root.path().join("bin").join(bin);
            fs::create_dir_all(link.parent().unwrap()).unwrap();
            std::os::unix::fs::symlink(Path::new("../lib/node_modules").join(script), &link)
                .unwrap();
            link.display().to_string()
        };
        let link = installed("@openai/codex/bin/codex.js", "codex");
        let loader = installed("@github/copilot/npm-loader.js", "copilot");
        let other = root.path().join("lib/other.js");
        fs::write(&other, "").unwrap();
        let other = other.display().to_string();
        let gone = root.path().join("gone.js").display().to_string();
        // The link as a path relative to this process's directory: it names
        // the launcher only from where the launcher itself started.
        let cwd = std::env::current_dir().unwrap();
        let relative = format!(
            "{}{}",
            "../".repeat(cwd.components().count() - 1),
            link.trim_start_matches('/')
        );
        let cases: [(&[&str], Harness, bool); 10] = [
            (&["/usr/bin/node", &link], Harness::Codex, true),
            (&["node", &link, "--yolo"], Harness::Codex, true),
            (&["node", &loader, "--help"], Harness::Copilot, true),
            (&["node", &loader], Harness::Codex, false),
            (&["node", &link], Harness::Copilot, false),
            (&["node", "bin/codex"], Harness::Codex, false),
            (&["node", &relative], Harness::Codex, false),
            (&["/usr/bin/bun", &link], Harness::Codex, false),
            (&["node", &other], Harness::Codex, false),
            (&["node", &gone], Harness::Codex, false),
        ];
        for (words, harness, want) in cases {
            let words: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
            assert_eq!(
                is_node_launcher(&words, harness),
                want,
                "{words:?} {harness:?}"
            );
        }
    }

    /// A row whose lock another writer holds past the wait is refused
    /// naming the lock, with the file as it stood: the flock on the rows
    /// file itself, never a `<file>.lock` beside it. The append returns
    /// within a bound of its own.
    #[test]
    fn a_row_the_lock_holds_past_its_wait_is_reported_rows_unwritten() {
        let dir = tempfile::tempdir().unwrap();
        let file = session_file(dir.path(), 1, "%2");
        fs::write(&file, "{\"event\":\"SessionStart\"}\n").unwrap();
        let row = SessionRow {
            event: "SessionEnd",
            harness: "codex",
            account: "",
            at: 5,
            fields: Fields::default(),
        };
        let bounded = || {
            let (tx, rx) = std::sync::mpsc::channel();
            let file = file.clone();
            std::thread::spawn(move || {
                let _ = tx.send(write_session(&file, &row, BOUND));
            });
            rx.recv_timeout(Duration::from_secs(10))
                .expect("the append returned within its bound")
        };
        let mut holder = fd_lock::RwLock::new(OpenOptions::new().append(true).open(&file).unwrap());
        let held = holder.write().unwrap();
        assert_eq!(
            bounded(),
            Err(Unwritten::Locked {
                lock: file.clone(),
                wait_s: 0
            })
        );
        assert_eq!(lines(&file), [r#"{"event":"SessionStart"}"#]);
        drop(held);
        bounded().unwrap();
        assert_eq!(lines(&file).len(), 2);
        assert!(!dir.path().join("session-1-2.jsonl.lock").exists());
    }

    /// The file read is three-valued and reads the last row alone: an
    /// absent file and an empty one are `Gone`, the last object within the
    /// span decides over every earlier row, and a trailing fragment a killed
    /// writer left is unreadable, never the row before it and never absent.
    #[test]
    fn the_last_row_is_read_three_valued_over_the_span() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("session-7-9.jsonl");
        assert_eq!(last_row(&file), Reading::Gone);
        fs::write(&file, "\n\n").unwrap();
        assert_eq!(last_row(&file), Reading::Gone);
        let mut text = String::new();
        for _ in 0..(SPAN + 5) {
            text.push_str(r#"{"harness":"claude","event":"StopFailure","error":"rate_limit"}"#);
            text.push('\n');
        }
        text.push_str(r#"{"harness":"claude","event":"SessionEnd","reason":"exit"}"#);
        text.push('\n');
        fs::write(&file, &text).unwrap();
        assert_eq!(session_verdict(&file), Reading::Live(SessionVerdict::Ended));
        text.push_str(r#"{"harness":"claude","event":"Sto"#);
        fs::write(&file, &text).unwrap();
        assert_eq!(
            last_row(&file),
            Reading::Unreadable {
                cause: "rows-row-unparsed"
            }
        );
    }
}
