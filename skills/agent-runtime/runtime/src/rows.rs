//! The session rows a harness's hooks write, one JSON object per line, read
//! for what the harness itself said of its session: up, walled, gone; and
//! the one writer of those rows and of the two stamps a Jarvis launch takes.
//! orch's `lib/session-rows.sh` writes the same files beside this writer,
//! under the same locks, and this reader keeps its verdict tables
//! (`session_rows_verdict` for an overseer's rows,
//! `session_rows_lane_verdict` for a Pi lane's); the row shapes follow
//! Claude Code's hook inputs, Pi's carrier and Copilot's camelCase payloads
//! as that library names them.
//!
//! Every read is three-valued: `Live(row)` is the last row, `Gone` a file
//! that is absent or holds no row, `Unreadable` a file or a last row that
//! could not be read. A verdict is read from the last row alone, as the
//! library reads it, over the last `SPAN` lines.

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
use crate::observe::{self, WallKind};
use crate::process;
use crate::reading::Reading;
use crate::record::{self, Locking, Wait};

/// The rows a reader looks back over for the last one: a session appends a
/// start, an end, a failure per wall and a Stop per turn
/// (`SESSION_ROWS_SPAN`).
pub const SPAN: usize = 64;

/// The harness's own text for a request refused for its prompt's length
/// (`SESSION_ROWS_PROMPT_TOO_LONG`), matched lowercased as a substring over
/// the row's `message` and `error_details`.
const PROMPT_TOO_LONG: [&str; 1] = ["prompt is too long"];

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
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub event: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub error_details: Option<String>,
    #[serde(default)]
    pub stop_reason: Option<String>,
    /// The carrier's count of working agents on a Pi Stop row; `null` is
    /// the carrier's failed task read, kept apart from an absent key as
    /// the library's `has("working_agents")` keeps it.
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

/// What an overseer's last row says of its session (`session_rows_verdict`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum SessionVerdict {
    /// The row carries no evidence this verdict reads: a harness other than
    /// Claude Code or Pi, or a Pi row that is neither a SessionEnd nor a
    /// StopFailure with a `message`.
    Unsupported,
    /// A SessionEnd for any reason but `clear` and `resume`.
    Ended,
    /// A StopFailure the account refused: the error kinds that refuse every
    /// turn until a person acts (`auth`), or a usage limit (`usage`).
    Walled { kind: WallKind },
    /// A StopFailure for a prompt too long: every turn fails the same way
    /// while the harness stays up.
    Wedged,
    /// Any other Claude Code row, a SessionEnd for `clear` or `resume`, or a
    /// Pi StopFailure whose message names neither a limit nor a prompt too
    /// long.
    Live,
}

/// What a Pi lane's last row says (`session_rows_lane_verdict`).
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "kebab-case")]
pub enum LaneVerdict {
    /// A PreToolUse row, or a Stop whose carrier counts working agents.
    Working,
    /// A Stop row that ended no error, or an error that is no limit;
    /// `cause` is the row's `stop_reason` word where the harness wrote
    /// one that is not its ordinary end ([`ORDINARY_END`]; Pi's `length`
    /// is a turn its output limit cut), so the stop's cause reaches the
    /// line the overseer reads and a finished round carries none.
    Idle { cause: Option<String> },
    /// A Stop row whose error message is the account's limit.
    Walled,
}

/// The last row of `file`, from the last [`SPAN`] lines: `Gone` where the
/// file is absent or holds no row, `Unreadable` where it, or the row, could
/// not be read.
pub fn last_row(file: &Path) -> Reading<Row> {
    match fs::read_to_string(file) {
        Ok(text) => last_row_in(&text),
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
    let Some(last) = lines[start..].iter().rev().find(|l| !l.trim().is_empty()) else {
        return Reading::Gone;
    };
    match serde_json::from_str::<Value>(last) {
        Ok(Value::Object(_)) => match serde_json::from_str::<Row>(last) {
            Ok(row) => Reading::Live(row),
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

/// The overseer verdict of `file`'s last row.
pub fn session_verdict(file: &Path) -> Reading<SessionVerdict> {
    last_row(file).map(|row| judge_session(&row))
}

/// The verdict table of `session_rows_verdict`, over one row.
pub fn judge_session(row: &Row) -> SessionVerdict {
    let harness = row.harness.as_deref().unwrap_or("");
    let event = row.event.as_deref().unwrap_or("");
    let message = row.message.as_deref().unwrap_or("");
    if harness == "claude"
        && event == "StopFailure"
        && observe::is_auth_failure("", row.error.as_deref())
    {
        return SessionVerdict::Walled {
            kind: WallKind::Auth,
        };
    }
    if harness != "claude" && harness != "pi" {
        return SessionVerdict::Unsupported;
    }
    if event == "SessionEnd" {
        return match row.reason.as_deref() {
            Some("clear" | "resume") => SessionVerdict::Live,
            Some(_) | None => SessionVerdict::Ended,
        };
    }
    if event == "StopFailure" && harness == "claude" && row.error.as_deref() == Some("rate_limit") {
        return SessionVerdict::Walled {
            kind: WallKind::Usage,
        };
    }
    if harness == "pi" && (event != "StopFailure" || message.is_empty()) {
        return SessionVerdict::Unsupported;
    }
    if event == "StopFailure" {
        let text =
            format!("{message}\n{}", row.error_details.as_deref().unwrap_or("")).to_lowercase();
        if PROMPT_TOO_LONG.iter().any(|p| text.contains(p)) {
            return SessionVerdict::Wedged;
        }
    }
    if harness == "pi" {
        return match observe::limit_banner(message) {
            Some(_) => SessionVerdict::Walled {
                kind: WallKind::Usage,
            },
            None => SessionVerdict::Live,
        };
    }
    SessionVerdict::Live
}

/// The Pi lane verdict of `file`'s last row: a row the table cannot judge
/// is `Unreadable`, as the library exits 2 on it.
pub fn lane_verdict(file: &Path) -> Reading<LaneVerdict> {
    match last_row(file) {
        Reading::Live(row) => judge_lane(&row),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// The verdict table of `session_rows_lane_verdict`, over one row.
pub fn judge_lane(row: &Row) -> Reading<LaneVerdict> {
    let event = row.event.as_deref().unwrap_or("");
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
        ("PreToolUse", _) => Reading::Live(LaneVerdict::Working),
        ("Stop", Some("error")) => {
            match observe::limit_banner(row.message.as_deref().unwrap_or("")) {
                Some(_) => Reading::Live(LaneVerdict::Walled),
                None => idle(),
            }
        }
        ("Stop", Some(_) | None) => idle(),
        (_, _) => Reading::Unreadable {
            cause: "lane-row-unjudged",
        },
    }
}

// ---------------------------------------------------------------------------
// The writer
// ---------------------------------------------------------------------------

/// How long an append or a stamp waits for its lock (`SESSION_ROWS_WAIT`):
/// below the least `timeout:` a hook that writes a row declares,
/// session-end-row's 3 s, so a writer that loses the lock says so before
/// its harness kills it.
pub const WAIT: Duration = Duration::from_secs(2);

/// The rows file of the session on `pane` of the tmux server `server`, in
/// the overseer mailbox directory `dir`. The pane id's `%` is dropped, so
/// the name holds no character a shell or a glob reads.
pub fn session_file(dir: &Path, server: u32, pane: &str) -> PathBuf {
    let pane = pane.strip_prefix('%').unwrap_or(pane);
    dir.join(format!("session-{server}-{pane}.jsonl"))
}

/// The lock this host's writers take: [`WAIT`], with the `mkdir` mutex
/// where the shell writers beside this one find no `flock(1)` on `PATH`.
pub fn host_locking() -> Locking {
    Locking {
        wait: Wait {
            limit: WAIT,
            poll: Duration::from_millis(100),
            timer: &SystemClock,
        },
        mkdir_mutex: !record::flock_on_path(std::env::var_os("PATH").as_deref()),
    }
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
    /// The Jarvis record could not be read as one object.
    RecordUnread { record: PathBuf, cause: String },
    /// No account could be read from this session's environment.
    AccountUnread,
    /// The start is not recorded as the launch the record awaits.
    Identity { verdict: Identity, record: PathBuf },
}

/// Why a Jarvis start is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Identity {
    /// The launch preassigned an id and the harness names another, or none.
    Mismatch,
    /// The harness names neither its session nor its session file.
    Unnamed,
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
            Unwritten::RecordUnread { record, cause } => {
                write!(f, "record-unread record={} {cause}", record.display())
            }
            Unwritten::AccountUnread => f.write_str("account-unread"),
            Unwritten::Identity { verdict, record } => {
                let word = match verdict {
                    Identity::Mismatch => "mismatch",
                    Identity::Unnamed => "unnamed",
                };
                write!(
                    f,
                    "jarvis-identity={word} record={}\nthe start is not recorded as the launch the record awaits",
                    record.display()
                )
            }
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

/// The shell writers' `mkdir` mutex beside a rows file, `<file>.d`
/// (mailbox's `file-lock.sh` on the file itself), removed on drop.
struct Mutex(PathBuf);

impl Drop for Mutex {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.0);
    }
}

/// Add `line` to `file` under the lock every writer of that file takes: a
/// `flock` on the file itself, and its `<file>.d` mutex where the policy
/// says the host's shell writers take one, both within `locking.wait`. A
/// fragment a killed writer left is closed first, so the line lands whole.
/// `guard`, where given, judges the file under the lock and refuses the
/// line with `false`: `Ok(false)`, nothing written.
fn append(
    file: &Path,
    line: &str,
    locking: Locking,
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
    let deadline = locking.wait.timer.now() + locking.wait.limit;
    let mut rw = fd_lock::RwLock::new(handle);
    loop {
        match rw.try_write() {
            Ok(mut held) => {
                let _mutex = if locking.mkdir_mutex {
                    let mut name = file.as_os_str().to_owned();
                    name.push(".d");
                    let dir = PathBuf::from(name);
                    loop {
                        match fs::create_dir(&dir) {
                            Ok(()) => break Some(Mutex(dir)),
                            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                                pause(&locking.wait, deadline, &dir)?;
                            }
                            Err(e) => return Err(io("mkdir-lock", e)),
                        }
                    }
                } else {
                    None
                };
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
                pause(&locking.wait, deadline, file)?;
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
pub fn write_session(file: &Path, row: &SessionRow, locking: Locking) -> Result<(), Unwritten> {
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
    append(file, &Value::Object(line).to_string(), locking, None).map(|_| ())
}

/// A Pi lane's rows file inside the lane's mailbox directory.
pub const LANE_FILE: &str = "session-rows.jsonl";

/// The transcript tail a Pi Stop row reads its turn's end from: a session
/// file grows without limit and its last assistant message is at its end.
const TRANSCRIPT_TAIL: u64 = 1_048_576;

/// The two events a Pi lane's rows and a Jarvis launch's taken stamp take.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnEvent {
    /// A turn end.
    Stop,
    /// A tool call, written only where it opens a turn.
    PreToolUse,
}

/// One Pi lane row.
#[derive(Debug, Clone, Copy)]
pub struct LaneRow<'a> {
    pub event: TurnEvent,
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
/// a PreToolUse at a tool call only over a Stop row or an empty file, so a
/// turn of many tool calls opens one. `Ok(false)` where nothing is written:
/// no mailbox directory, or a turn already open.
pub fn write_lane(dir: &Path, row: &LaneRow, locking: Locking) -> Result<bool, Unwritten> {
    if !dir.is_dir() {
        return Ok(false);
    }
    let file = dir.join(LANE_FILE);
    let mut line = Map::new();
    line.insert("at".to_owned(), Value::from(row.at));
    let event = match row.event {
        TurnEvent::Stop => "Stop",
        TurnEvent::PreToolUse => "PreToolUse",
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
            append(&file, &Value::Object(line).to_string(), locking, None)
        }
        TurnEvent::PreToolUse => append(
            &file,
            &Value::Object(line).to_string(),
            locking,
            Some(&turn_open),
        ),
    }
}

/// Whether `file`'s last row is a turn end, or the file holds none: the one
/// state a PreToolUse row opens a turn over. A file this cannot read
/// answers yes, so the append itself meets the fault and reports it.
fn turn_open(file: &Path) -> bool {
    last_object(file).map_or(true, |last| last.is_none_or(|row| event_of(&row) == "Stop"))
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

/// The launch a Jarvis runtime record's `pending` row awaits, as this
/// session names it: the record and the generation its launch handed over
/// (`JARVIS_RECORD`, `JARVIS_GENERATION`), this session's tmux server pid
/// and pane, and the harness the hook's install names.
#[derive(Debug, Clone, Copy)]
pub struct Launch<'a> {
    pub record: &'a Path,
    pub generation: &'a str,
    pub server: u32,
    pub pane: &'a str,
    pub harness: &'a str,
}

/// The stamp a Jarvis launch worker reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stamp {
    /// `brief_taken`: the session took the Start brief the record says was
    /// delivered.
    BriefTaken,
    /// `kickoff_ended`: a Codex or Copilot session's kickoff turn ended
    /// before the brief, which the worker pastes only then.
    KickoffEnded,
}

/// jq's `tostring`: a string as it stands, any other value as JSON.
fn to_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
        None => "null".to_owned(),
    }
}

/// A field of the record's `pending` row that is present and not `null`.
fn pending_field<'d>(doc: &'d Map<String, Value>, key: &str) -> Option<&'d Value> {
    doc.get("pending")
        .and_then(|pending| pending.get(key))
        .filter(|value| !value.is_null())
}

/// Whether the record's `pending` row is this session's launch: the
/// record's harness, and the row's generation, server and pane, against
/// the launch as this session names it (`SESSION_ROWS_JARVIS_BOUND`).
fn bound(doc: &Map<String, Value>, launch: &Launch) -> bool {
    let Some(Value::Object(pending)) = doc.get("pending") else {
        return false;
    };
    doc.get("harness").and_then(Value::as_str) == Some(launch.harness)
        && !launch.generation.is_empty()
        && to_text(pending.get("generation")) == launch.generation
        && to_text(pending.get("server")) == launch.server.to_string()
        && pending.get("pane").and_then(Value::as_str) == Some(launch.pane)
}

fn read_record(record: &Path) -> Result<Map<String, Value>, Unwritten> {
    let unread = |cause: String| Unwritten::RecordUnread {
        record: record.to_path_buf(),
        cause,
    };
    match record::read_value(record) {
        Ok(Some(Value::Object(doc))) => Ok(doc),
        Ok(Some(_)) => Err(unread("not an object".to_owned())),
        Ok(None) => Err(unread("absent".to_owned())),
        Err(e) => Err(unread(e.to_string())),
    }
}

/// `pending` patched by `patch` and the whole record renamed over the
/// file, as every writer of the record replaces it.
fn patch_pending(
    record: &Path,
    mut doc: Map<String, Value>,
    patch: impl FnOnce(&mut Map<String, Value>),
) -> Result<(), Unwritten> {
    if let Some(Value::Object(pending)) = doc.get_mut("pending") {
        patch(pending);
    }
    record::replace_atomically(record, &Value::Object(doc)).map_err(|e| Unwritten::Io {
        op: "write",
        path: record.to_path_buf(),
        cause: e.to_string(),
    })
}

/// Run `f` under the lock every writer of the record takes, `<record>.lock`
/// with its `mkdir` mutex where the policy says so.
fn under_record_lock<R>(
    record: &Path,
    locking: Locking,
    f: impl FnOnce() -> Result<R, Unwritten>,
) -> Result<R, Unwritten> {
    let held: Result<Result<R, Unwritten>, crate::error::Error> =
        record::locked(record, locking, || Ok(f()));
    held.unwrap_or_else(|e| {
        let lock = record::lock_path(record);
        Err(if e.key() == "lock-timeout" {
            Unwritten::Locked {
                lock,
                wait_s: locking.wait.limit.as_secs(),
            }
        } else {
            Unwritten::Io {
                op: "lock",
                path: lock,
                cause: e.to_string(),
            }
        })
    })
}

/// A Jarvis launch's start stamp: this SessionStart's native identity, the
/// harness's own session id as `native_session_id` and its session file as
/// `session_file` where it names them, `started_at` and the account the
/// session runs on as `observed_account`, into the record's `pending` row.
/// A row naming another launch, or one already started, is another
/// session's: `Ok(false)`, nothing written. A launch that preassigned the
/// id refuses a start the harness names by any other id or by none: the
/// identity is the harness's own word, never a guess.
pub fn jarvis_start(
    launch: &Launch,
    session_id: Option<&str>,
    session_file: Option<&str>,
    account: &str,
    at: u64,
    locking: Locking,
) -> Result<bool, Unwritten> {
    if account.is_empty() {
        return Err(Unwritten::AccountUnread);
    }
    let id = session_id.filter(|s| !s.is_empty());
    let file = session_file.filter(|s| !s.is_empty());
    under_record_lock(launch.record, locking, || {
        let doc = read_record(launch.record)?;
        if !bound(&doc, launch) || pending_field(&doc, "started_at").is_some() {
            return Ok(false);
        }
        let preassigned = pending_field(&doc, "native_session_id")
            .filter(|value| **value != Value::Bool(false))
            .cloned();
        let named = id.map(Value::from);
        let refused = |verdict| Unwritten::Identity {
            verdict,
            record: launch.record.to_path_buf(),
        };
        if preassigned.or_else(|| named.clone()) != named {
            return Err(refused(Identity::Mismatch));
        }
        if id.is_none() && file.is_none() {
            return Err(refused(Identity::Unnamed));
        }
        patch_pending(launch.record, doc, |pending| {
            if let Some(id) = id {
                pending.insert("native_session_id".to_owned(), Value::from(id));
            }
            if let Some(file) = file {
                pending.insert("session_file".to_owned(), Value::from(file));
            }
            pending.insert("started_at".to_owned(), Value::from(at));
            pending.insert("observed_account".to_owned(), Value::from(account));
        })?;
        Ok(true)
    })
}

/// Which stamp a session's event may take on its harness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Due {
    /// A tool call, or a turn end that takes the brief: `brief_taken`.
    Own,
    /// A Codex or Copilot turn end: `brief_taken`, or before the brief
    /// `kickoff_ended`.
    Turn,
}

/// What the record says of this session's launch (`session_rows_jarvis_due`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Launched {
    /// The launch takes neither stamp.
    Other,
    /// The brief was delivered and is not yet taken.
    Delivered,
    /// The brief is not yet delivered and the kickoff's end not stamped.
    Undelivered,
    /// The kickoff's end is stamped and the brief not yet delivered.
    Ended,
}

fn launched(doc: &Map<String, Value>, launch: &Launch, session: &str) -> Launched {
    let started = bound(doc, launch)
        && pending_field(doc, "started_at").is_some()
        && pending_field(doc, "native_session_id").and_then(Value::as_str) == Some(session)
        && doc.get("state").and_then(Value::as_str) == Some("starting")
        && pending_field(doc, "brief_taken").is_none();
    if !started {
        Launched::Other
    } else if doc.get("brief_delivered") == Some(&Value::Bool(true)) {
        Launched::Delivered
    } else if pending_field(doc, "kickoff_ended").is_some() {
        Launched::Ended
    } else {
        Launched::Undelivered
    }
}

/// A Jarvis launch's taken stamp, once, for this session's tool call or
/// turn end: `brief_taken` where the record says the brief was delivered,
/// on a tool call, or a turn end on Claude Code, Codex, Copilot CLI and a
/// Pi run whose outcome is `completed` (Pi dispatches Stop on errored and
/// aborted runs too); `kickoff_ended` at a Codex or Copilot turn end before
/// the brief. Only a launch this session started under `session_id` and
/// still `starting` takes either. The record is read first without the
/// lock, since every writer renames a whole record into place, so a running
/// session's later calls take no lock and write nothing.
pub fn jarvis_taken(
    launch: &Launch,
    event: TurnEvent,
    session_id: Option<&str>,
    pi_outcome: Option<&str>,
    locking: Locking,
) -> Result<Option<Stamp>, Unwritten> {
    let due = match (event, launch.harness) {
        (TurnEvent::PreToolUse, _) | (TurnEvent::Stop, "claude") => Due::Own,
        (TurnEvent::Stop, "pi") if pi_outcome == Some("completed") => Due::Own,
        (TurnEvent::Stop, "codex" | "copilot") => Due::Turn,
        (TurnEvent::Stop, _) => return Ok(None),
    };
    let Some(session) = session_id.filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    let worth_the_lock = match (due, launched(&read_record(launch.record)?, launch, session)) {
        (Due::Own, Launched::Delivered | Launched::Undelivered | Launched::Ended)
        | (Due::Turn, Launched::Delivered | Launched::Undelivered) => true,
        (Due::Own | Due::Turn, Launched::Other) | (Due::Turn, Launched::Ended) => false,
    };
    if !worth_the_lock {
        return Ok(None);
    }
    under_record_lock(launch.record, locking, || {
        let doc = read_record(launch.record)?;
        let stamp = match (due, launched(&doc, launch, session)) {
            (Due::Own | Due::Turn, Launched::Delivered) => Stamp::BriefTaken,
            (Due::Turn, Launched::Undelivered) => Stamp::KickoffEnded,
            (Due::Own, Launched::Undelivered)
            | (Due::Own | Due::Turn, Launched::Other | Launched::Ended) => return Ok(None),
        };
        let key = match stamp {
            Stamp::BriefTaken => "brief_taken",
            Stamp::KickoffEnded => "kickoff_ended",
        };
        patch_pending(launch.record, doc, |pending| {
            pending.insert(key.to_owned(), Value::Bool(true));
        })?;
        Ok(Some(stamp))
    })
}

/// Whether the session this process's parent `from` serves is its pane's
/// top-level harness: exactly one process that is no shell stands between
/// `from` and the pane's own process, the child of the tmux server
/// `server` (tmux forks every pane's process from its server). A harness
/// nested under another, which the other one's tool shell started, counts
/// two; a harness that is the pane's process itself counts none. Codex's
/// installed Node launcher and its native child count as one, which
/// `launcher` judges of the parent of a `codex`. A process under no pane of
/// `server` never reaches one, and the walk refuses past 64 steps.
pub fn top_level(
    rows: &[process::Row],
    from: u32,
    server: u32,
    launcher: &dyn Fn(u32) -> bool,
) -> bool {
    let by_pid: HashMap<u32, &process::Row> = rows.iter().map(|row| (row.pid, row)).collect();
    let mut pid = from;
    let mut child: Option<&str> = None;
    let mut harnesses = 0u32;
    for _ in 0..64 {
        let Some(row) = by_pid.get(&pid).filter(|_| pid > 1) else {
            return false;
        };
        if row.ppid == server {
            return harnesses == 1;
        }
        let uncounted = process::is_shell(&row.name) || (child == Some("codex") && launcher(pid));
        if !uncounted {
            harnesses += 1;
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
        &codex_launcher,
    ))
}

/// Whether `pid` is the installed `@openai/codex` Node launcher.
fn codex_launcher(pid: u32) -> bool {
    argv(pid).is_some_and(|words| is_codex_launcher(&words))
}

/// Whether a process's argument words are the installed `@openai/codex`
/// Node launcher's: `node` running an absolute script that resolves,
/// through every link, to its `bin/codex.js`.
fn is_codex_launcher(words: &[String]) -> bool {
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
    fs::canonicalize(script)
        .is_ok_and(|real| real.is_file() && real.ends_with("@openai/codex/bin/codex.js"))
}

/// The argument words process `pid` was started with.
#[cfg(target_os = "linux")]
fn argv(pid: u32) -> Option<Vec<String>> {
    let bytes = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(
        bytes
            .split(|byte| *byte == 0)
            .filter(|word| !word.is_empty())
            .map(|word| String::from_utf8_lossy(word).into_owned())
            .collect(),
    )
}

/// The argument words process `pid` was started with, as `ps` prints them.
#[cfg(not(target_os = "linux"))]
fn argv(pid: u32) -> Option<Vec<String>> {
    let env: [(&str, &std::ffi::OsStr); 1] = [("LC_ALL", std::ffi::OsStr::new("C"))];
    let pid = pid.to_string();
    let output = crate::host::run_with(
        "ps",
        "ps-args",
        &["-o", "args=", "-p", &pid],
        &env,
        None,
        Duration::from_secs(15),
    )
    .ok()?;
    output.status.success().then(|| {
        String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(str::to_owned)
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(json: &str) -> Row {
        serde_json::from_str(json).unwrap()
    }

    /// The overseer verdict table, one row per form the library judges:
    /// each harness's SessionEnd and StopFailure shapes, a Pi row with and
    /// without a limit message, a Copilot row, and the too-long prompt. The
    /// library reads the same file for the same decision, so the two
    /// verdicts agree.
    #[test]
    fn the_session_verdict_follows_the_library_s_table_per_harness_form() {
        let rows: [(&str, SessionVerdict); 11] = [
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
        ];
        for (json, expected) in rows {
            assert_eq!(judge_session(&row(json)), expected, "{json}");
        }
    }

    /// The Pi lane verdict table. A carrier's null count and a row the table
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
        let rows: [(&str, Reading<LaneVerdict>); 11] = [
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
                Reading::Live(LaneVerdict::Walled),
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

    /// A lock that waits a test's own bound: the flock alone, or with the
    /// shell writers' mutex.
    fn locking(mutex: bool) -> Locking {
        Locking {
            wait: Wait {
                limit: Duration::from_millis(300),
                poll: Duration::from_millis(20),
                timer: &SystemClock,
            },
            mkdir_mutex: mutex,
        }
    }

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
        write_session(&file, &row("SessionStart", start), locking(false)).unwrap();
        write_session(&file, &row("Stop", stop), locking(false)).unwrap();
        write_session(&file, &row("StopFailure", failure), locking(false)).unwrap();
        write_session(&file, &row("Stop", stop), locking(false)).unwrap();
        let mut text = fs::read_to_string(&file).unwrap();
        text.push_str(r#"{"at":101,"event":"Sto"#);
        fs::write(&file, &text).unwrap();
        write_session(&file, &row("Stop", stop), locking(false)).unwrap();
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
        write_session(&fresh, &row("Stop", stop), locking(false)).unwrap();
        assert_eq!(
            lines(&fresh),
            [r#"{"at":100,"event":"Stop","harness":"claude","session_id":"s1"}"#]
        );
    }

    /// The pane's own top-level harness alone writes a row: a harness under
    /// the pane's shell, through any shells between, counts one; a harness
    /// another harness's tool shell started counts two; a harness that is
    /// the pane's process counts none; Codex's installed Node launcher and
    /// its native child count one, any other parent of a `codex` its own;
    /// a process under no pane of the server, a parent the table lacks, or
    /// a cycle the walk's bound ends, is no top-level session. Every pid is
    /// synthetic.
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
        let launcher = |pid: u32| pid == 31;
        let cases: [(&str, Vec<process::Row>, bool); 7] = [
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
                "a harness that is the pane's process",
                table(&[(21, SERVER, "claude"), (22, 21, "bash")]),
                false,
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
            let _ = tx.send(top_level(&cycle, 22, SERVER, &|_| false));
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
        assert_eq!(write_lane(&dir, &tool, locking(false)), Ok(false));
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
        .map(|row| write_lane(&dir, row, locking(false)).unwrap())
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

    /// A Jarvis launch is stamped started once, by the session whose
    /// generation, server, pane and harness the record's `pending` row
    /// names, and taken once: a Codex turn end before the brief stamps the
    /// kickoff's end, a tool call after the delivery the brief taken; any
    /// other session, a started row and a stamped one take nothing. A
    /// preassigned id refuses a start naming another or none; a start that
    /// names nothing is refused; a Pi turn end counts only a completed run;
    /// a launch past `starting` or never started takes nothing, read
    /// without its lock.
    #[test]
    fn a_jarvis_launch_is_stamped_started_then_taken_once() {
        let root = tempfile::tempdir().unwrap();
        let plant = |name: &str, record: Value| {
            let path = root.path().join(name).join("jarvis-session.json");
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, record.to_string()).unwrap();
            path
        };
        let pending = serde_json::json!({"generation": "g7", "server": 4242, "pane": "%3"});
        let record = plant(
            "codex",
            serde_json::json!({"v": 1, "harness": "codex", "state": "starting", "pending": pending}),
        );
        let own = Launch {
            record: &record,
            generation: "g7",
            server: 4242,
            pane: "%3",
            harness: "codex",
        };
        let start = |launch: &Launch| {
            jarvis_start(
                launch,
                Some("sid"),
                Some("/t/sid.jsonl"),
                "/h/.codex",
                9,
                locking(false),
            )
        };
        let before = fs::read(&record).unwrap();
        for other in [
            Launch {
                generation: "g8",
                ..own
            },
            Launch {
                generation: "",
                ..own
            },
            Launch {
                server: 4243,
                ..own
            },
            Launch { pane: "%4", ..own },
            Launch {
                harness: "claude",
                ..own
            },
        ] {
            assert_eq!(start(&other), Ok(false), "{other:?}");
        }
        assert_eq!(fs::read(&record).unwrap(), before);
        assert_eq!(
            jarvis_start(&own, Some("sid"), None, "", 9, locking(false)),
            Err(Unwritten::AccountUnread)
        );
        let lock = record::lock_path(&record);
        let mut holder = fd_lock::RwLock::new(
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(&lock)
                .unwrap(),
        );
        let held = holder.write().unwrap();
        assert_eq!(start(&own), Err(Unwritten::Locked { lock, wait_s: 0 }));
        drop(held);
        assert_eq!(fs::read(&record).unwrap(), before);
        assert_eq!(start(&own), Ok(true));
        assert_eq!(start(&own), Ok(false));
        let read = || -> Value { serde_json::from_slice(&fs::read(&record).unwrap()).unwrap() };
        assert_eq!(
            read()["pending"],
            serde_json::json!({"generation": "g7", "server": 4242, "pane": "%3",
                "native_session_id": "sid", "session_file": "/t/sid.jsonl",
                "started_at": 9, "observed_account": "/h/.codex"})
        );
        let taken = |event, session| jarvis_taken(&own, event, Some(session), None, locking(false));
        assert_eq!(taken(TurnEvent::PreToolUse, "other"), Ok(None));
        assert_eq!(taken(TurnEvent::PreToolUse, "sid"), Ok(None));
        assert_eq!(taken(TurnEvent::Stop, "sid"), Ok(Some(Stamp::KickoffEnded)));
        assert_eq!(taken(TurnEvent::Stop, "sid"), Ok(None));
        let mut delivered = read();
        delivered["brief_delivered"] = Value::Bool(true);
        fs::write(&record, delivered.to_string()).unwrap();
        assert_eq!(
            taken(TurnEvent::PreToolUse, "sid"),
            Ok(Some(Stamp::BriefTaken))
        );
        assert_eq!(taken(TurnEvent::PreToolUse, "sid"), Ok(None));
        assert_eq!(read()["pending"]["kickoff_ended"], Value::Bool(true));
        assert_eq!(read()["pending"]["brief_taken"], Value::Bool(true));

        let preassigned = plant(
            "preassigned",
            serde_json::json!({"harness": "codex", "state": "starting",
                "pending": {"generation": "g7", "server": "4242", "pane": "%3", "native_session_id": "pre"}}),
        );
        let refused = Err(Unwritten::Identity {
            verdict: Identity::Mismatch,
            record: preassigned.clone(),
        });
        let launch = Launch {
            record: &preassigned,
            ..own
        };
        assert_eq!(start(&launch), refused);
        assert_eq!(
            jarvis_start(&launch, None, Some("/t/x"), "/h", 9, locking(false)),
            refused
        );
        let unnamed = plant(
            "unnamed",
            serde_json::json!({"harness": "codex", "pending": pending}),
        );
        let launch = Launch {
            record: &unnamed,
            ..own
        };
        assert_eq!(
            jarvis_start(&launch, None, Some(""), "/h", 9, locking(false)),
            Err(Unwritten::Identity {
                verdict: Identity::Unnamed,
                record: unnamed.clone()
            })
        );

        let pi = plant(
            "pi",
            serde_json::json!({"harness": "pi", "state": "starting", "brief_delivered": true,
                "pending": {"generation": "g7", "server": 4242, "pane": "%3",
                    "native_session_id": "sid", "started_at": 1}}),
        );
        let launch = Launch {
            record: &pi,
            harness: "pi",
            ..own
        };
        let pi_stop = |outcome| {
            jarvis_taken(
                &launch,
                TurnEvent::Stop,
                Some("sid"),
                outcome,
                locking(false),
            )
        };
        assert_eq!(pi_stop(Some("error")), Ok(None));
        assert_eq!(pi_stop(None), Ok(None));
        assert_eq!(pi_stop(Some("completed")), Ok(Some(Stamp::BriefTaken)));

        // A launch past `starting`, and one its start never stamped, take
        // nothing, read without the lock: a lock another writer holds
        // neither stalls the call nor changes the answer.
        let delivered = |state: &str, started: Option<u64>| {
            let mut pending = serde_json::json!({"generation": "g7", "server": 4242,
                "pane": "%3", "native_session_id": "sid"});
            if let Some(at) = started {
                pending["started_at"] = Value::from(at);
            }
            serde_json::json!({"harness": "codex", "state": state, "brief_delivered": true,
                "pending": pending})
        };
        for (name, doc) in [
            ("running", delivered("running", Some(1))),
            ("unstarted", delivered("starting", None)),
        ] {
            let record = plant(name, doc);
            let launch = Launch {
                record: &record,
                ..own
            };
            let lock = record::lock_path(&record);
            let mut holder = fd_lock::RwLock::new(
                OpenOptions::new()
                    .create(true)
                    .truncate(false)
                    .write(true)
                    .open(&lock)
                    .unwrap(),
            );
            let held = holder.write().unwrap();
            let before = fs::read(&record).unwrap();
            assert_eq!(
                jarvis_taken(
                    &launch,
                    TurnEvent::PreToolUse,
                    Some("sid"),
                    None,
                    locking(false)
                ),
                Ok(None),
                "{name}"
            );
            drop(held);
            assert_eq!(fs::read(&record).unwrap(), before, "{name}");
        }
    }

    /// Codex's installed Node launcher is known by its argument words: an
    /// executable named `node` and an absolute script that resolves,
    /// through a link, to `@openai/codex/bin/codex.js`; a relative script,
    /// another executable, another script and a missing one are not it.
    #[test]
    fn codexs_installed_node_launcher_is_known_by_its_resolved_script() {
        let root = tempfile::tempdir().unwrap();
        let real = root
            .path()
            .join("lib/node_modules/@openai/codex/bin/codex.js");
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::write(&real, "").unwrap();
        let other = root.path().join("lib/other.js");
        fs::write(&other, "").unwrap();
        let link = root.path().join("bin/codex");
        fs::create_dir_all(link.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink("../lib/node_modules/@openai/codex/bin/codex.js", &link)
            .unwrap();
        let link = link.display().to_string();
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
        let cases: [(&[&str], bool); 7] = [
            (&["/usr/bin/node", &link], true),
            (&["node", &link, "--yolo"], true),
            (&["node", "bin/codex"], false),
            (&["node", &relative], false),
            (&["/usr/bin/bun", &link], false),
            (&["node", &other], false),
            (&["node", &gone], false),
        ];
        for (words, want) in cases {
            let words: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
            assert_eq!(is_codex_launcher(&words), want, "{words:?}");
        }
    }

    /// A row whose lock another writer holds past the wait is refused
    /// naming the lock, with the file as it stood: the flock on the rows
    /// file itself, and the `<file>.d` mutex where the host's shell writers
    /// take one, never a `<file>.lock` beside it. The append returns within
    /// a bound of its own.
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
        let bounded = |mutex: bool| {
            let (tx, rx) = std::sync::mpsc::channel();
            let file = file.clone();
            std::thread::spawn(move || {
                let _ = tx.send(write_session(&file, &row, locking(mutex)));
            });
            rx.recv_timeout(Duration::from_secs(10))
                .expect("the append returned within its bound")
        };
        let mut holder = fd_lock::RwLock::new(OpenOptions::new().append(true).open(&file).unwrap());
        let held = holder.write().unwrap();
        assert_eq!(
            bounded(false),
            Err(Unwritten::Locked {
                lock: file.clone(),
                wait_s: 0
            })
        );
        drop(held);
        let mutex = dir.path().join("session-1-2.jsonl.d");
        fs::create_dir(&mutex).unwrap();
        assert_eq!(
            bounded(true),
            Err(Unwritten::Locked {
                lock: mutex.clone(),
                wait_s: 0
            })
        );
        assert_eq!(lines(&file), [r#"{"event":"SessionStart"}"#]);
        fs::remove_dir(&mutex).unwrap();
        bounded(true).unwrap();
        assert_eq!(lines(&file).len(), 2);
        assert!(!dir.path().join("session-1-2.jsonl.lock").exists());
        assert!(!mutex.exists());
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
