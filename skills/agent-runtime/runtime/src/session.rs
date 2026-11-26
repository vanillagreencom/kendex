//! Native session identity: where each harness records its own session and
//! how a lead session for one working directory is found. Only documented
//! or measured store layouts are read, as data; nothing here is decrypted
//! or scraped from terminal text.
//!
//! - Claude Code: `<home>/projects/<cwd slug>/<id>.jsonl`, one row per
//!   event; rows carry `sessionId` and most carry `cwd`. A subagent's file
//!   sits under a `subagents/` directory and is never a lead.
//! - Codex: `<home>/sessions/YYYY/MM/DD/rollout-<stamp>-<id>.jsonl`, whose
//!   first row is `session_meta` with `payload.id`, `payload.cwd` and
//!   `payload.parent_thread_id` (null for a lead).
//! - Copilot CLI: `<home>/session-state/<id>/workspace.yaml` with plain
//!   `id:` and `cwd:` lines, written as the session opens, and
//!   `events.jsonl` beside it, written only at its first turn (see
//!   [`Written`]).
//! - Pi: `<sessions root>/<cwd slug>/<stamp>_<id>.jsonl`, whose first row
//!   is `{"type":"session","id":...,"cwd":...}`.
//!
//! A session is bound by the id its launch fixed, or as the one lead that
//! appeared for its directory after the launch and stood in no baseline
//! read before it. No reader here picks a file by its age: a lookup that
//! can name a neighbour's file is not an API.
//!
//! The same files record each user turn, which is how a delivery is
//! confirmed: a turn the harness itself wrote down arrived, whatever the
//! pane paste returned. These are the user-turn rows in each harness's
//! session file.
//!
//! - Claude Code: a `user` row whose `message.content` is a string; a tool
//!   result is a `user` row too, with an array.
//! - Codex: an `event_msg` row completing a `UserMessage` item.
//! - Copilot CLI: a `user.message` row in `events.jsonl`.
//! - Pi: a `message` row whose `message.role` is `user`.

use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::reading::{Reading, Unreadable};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRef {
    pub harness: Harness,
    pub id: String,
    pub file: PathBuf,
    pub cwd: PathBuf,
}

/// The home a harness reads when the caller names none.
pub fn default_home(harness: Harness) -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(default_home_at(harness, &home))
}

/// The home a harness reads under the home directory `home` when it is
/// named none.
pub(crate) fn default_home_at(harness: Harness, home: &Path) -> PathBuf {
    match harness {
        Harness::Claude => home.join(".claude"),
        Harness::Codex => home.join(".codex"),
        Harness::Copilot => home.join(".copilot"),
        Harness::Pi => home.join(".pi").join("agent"),
    }
}

/// A fresh version 4 UUID for a launch that fixes its session id
/// (`Harness::session_id_words`), from the host's random device; a device
/// that cannot be read is an error, never a predictable id.
pub fn fresh_session_id() -> Result<String> {
    let device = Path::new("/dev/urandom");
    let mut bytes = [0u8; 16];
    fs::File::open(device)
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| Error::io("read", device, e))?;
    Ok(uuid_v4(bytes))
}

/// The RFC 9562 version 4 spelling of sixteen random bytes.
fn uuid_v4(mut bytes: [u8; 16]) -> String {
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: Vec<String> = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        hex[0..4].concat(),
        hex[4..6].concat(),
        hex[6..8].concat(),
        hex[8..10].concat(),
        hex[10..16].concat()
    )
}

/// The file a harness writes for a session whose id the launch fixed, under
/// `home` for `cwd`, knowable before the harness writes it; `None` for a
/// harness whose launch fixes no id. Claude Code names the file by the id
/// in the project's directory.
pub fn fixed_file(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Option<PathBuf> {
    match harness {
        Harness::Claude => Some(
            home.join("projects")
                .join(claude_slug(cwd))
                .join(format!("{id}.jsonl")),
        ),
        Harness::Codex | Harness::Copilot | Harness::Pi => None,
    }
}

/// The directory the session `id` under `home` was recorded in, read by
/// the session's own file so a relaunch tells absent from unreadable and
/// its own session from another directory's: `Live(cwd)` where the file
/// the id names is a lead session recording `cwd` (`None` where it records
/// none), `Gone` where the home holds no file for the id or a file that is
/// no lead, `Unreadable` where the store or the file could not be read.
/// Every resumable harness is read by the path its id gives
/// ([`fixed_id_file`]); Pi resumes by file, not id, so it reads absent.
pub fn resume_owner(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    id: &str,
) -> Reading<Option<PathBuf>> {
    if harness == Harness::Pi {
        return Reading::Gone;
    }
    let file = match fixed_id_file(harness, home, cwd, id) {
        Reading::Live(file) => file,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    match identify(harness, &file, None, Written::Turned) {
        Ok(Some(lead)) => Reading::Live(Some(lead.cwd)),
        Ok(None) => match harness {
            // A Claude file under the project's directory records its
            // directory in its rows; one too short to carry a row yet is
            // the directory's own.
            Harness::Claude => Reading::Live(None),
            Harness::Codex | Harness::Copilot | Harness::Pi => Reading::Gone,
        },
        Err(_) => Reading::Unreadable {
            cause: FILE_UNREADABLE.cause,
        },
    }
}

/// The one session file the id `id` names for `cwd` under `home`, read
/// three-valued: `Live(path)` where the harness has written it, `Gone`
/// where no file carries the id yet, `Unreadable` where a listing or a
/// metadata read failed. Each harness names the file by its id (module
/// doc): Claude by the path its fixed id gives, Copilot by its session-state
/// directory, Codex and Pi by the id in the file name under their store. A
/// file is found by the id its launch bound and never by its age, so a
/// neighbour's or a subagent's file is never named in its place.
pub fn fixed_id_file(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Reading<PathBuf> {
    let present = |file: PathBuf| match fs::metadata(&file) {
        Ok(meta) if meta.is_file() => Reading::Live(file),
        Ok(_) => Reading::Gone,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
        Err(_) => Reading::Unreadable {
            cause: STORE_UNREADABLE.cause,
        },
    };
    match harness {
        Harness::Claude => match fixed_file(harness, home, cwd, id) {
            Some(file) => present(file),
            None => Reading::Gone,
        },
        Harness::Codex => {
            // The id is the tail of the rollout file name
            // `rollout-<stamp>-<id>.jsonl`, under `sessions/YYYY/MM/DD/`. The
            // store's root is read three-valued through the one listing: no
            // root is a cold home, an absent session; a
            // root that cannot be listed is unreadable, never absent.
            let root = home.join("sessions");
            match listed(&root) {
                Reading::Live(_) => {}
                Reading::Gone => return Reading::Gone,
                Reading::Unreadable { cause } => return Reading::Unreadable { cause },
            }
            let suffix = format!("-{id}.jsonl");
            let mut found = Vec::new();
            if let Err(Unreadable { cause }) = walk(&root, &mut found, 3) {
                return Reading::Unreadable { cause };
            }
            match found.into_iter().find(|c| {
                c.path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(&suffix))
            }) {
                Some(found) => Reading::Live(found.path),
                None => Reading::Gone,
            }
        }
        Harness::Copilot => present(home.join("session-state").join(id).join("workspace.yaml")),
        Harness::Pi => {
            // `<stamp>_<id>.jsonl` under the cwd's slug directory.
            let dir = home.join("sessions").join(pi_slug(cwd));
            let paths = match listed(&dir) {
                Reading::Live(paths) => paths,
                Reading::Gone => return Reading::Gone,
                Reading::Unreadable { cause } => return Reading::Unreadable { cause },
            };
            let suffix = format!("_{id}.jsonl");
            match paths.into_iter().find(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.ends_with(&suffix))
            }) {
                Some(file) => present(file),
                None => Reading::Gone,
            }
        }
    }
}

/// Claude Code and Pi name a project directory by its path with every `/`
/// and `.` replaced by `-`.
pub fn claude_slug(cwd: &Path) -> String {
    cwd.display()
        .to_string()
        .chars()
        .map(|c| if c == '/' || c == '.' { '-' } else { c })
        .collect()
}

/// Pi's slug keeps the path's own characters and wraps it in `--`.
pub fn pi_slug(cwd: &Path) -> String {
    let inner: String = cwd
        .display()
        .to_string()
        .chars()
        .map(|c| if c == '/' { '-' } else { c })
        .collect();
    format!("-{inner}--")
}

fn first_rows(file: &Path, limit: usize) -> Result<Vec<Value>> {
    let f = fs::File::open(file).map_err(|e| Error::io("open", file, e))?;
    let reader = BufReader::new(f);
    let mut rows = Vec::new();
    for line in reader.lines().take(limit) {
        let line = line.map_err(|e| Error::io("read", file, e))?;
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line) {
            rows.push(value);
        }
    }
    Ok(rows)
}

/// How far a session must have gone to count as a lead. Copilot CLI writes
/// its workspace.yaml as a session opens and `events.jsonl` only at the
/// session's first turn: a start launched with no prompt stands at its
/// composer with no events file (Copilot CLI 1.0.112), and one that ended
/// before its first turn, a failed sign-in among them, leaves no events
/// file and `copilot --resume=<id>` on it exits 1. Every other harness's
/// session file reads the same under both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Written {
    /// Opened: the session a launch started, bound as it opens so its
    /// brief can be typed into it; a baseline is read the same way, so the
    /// set that appeared is told against a set of the same kind.
    Opened,
    /// Took its first turn: a session a resume can continue, and the one a
    /// reader holding no launch of its own names.
    Turned,
}

/// Read the identity a session file carries, or `None` when the file is not
/// a lead session for `cwd` (or any cwd when `cwd` is `None`) that has gone
/// as far as `written`.
pub fn identify(
    harness: Harness,
    file: &Path,
    cwd: Option<&Path>,
    written: Written,
) -> Result<Option<SessionRef>> {
    match harness {
        Harness::Claude => {
            if file.components().any(|c| c.as_os_str() == "subagents") {
                return Ok(None);
            }
            let rows = first_rows(file, 64)?;
            let id = rows
                .iter()
                .find_map(|r| r.get("sessionId").and_then(Value::as_str))
                .map(str::to_owned)
                .or_else(|| file.file_stem().and_then(|s| s.to_str()).map(str::to_owned));
            let row_cwd = rows.iter().find(|r| r.get("cwd").is_some()).and_then(|r| {
                if r.get("isSidechain").and_then(Value::as_bool) == Some(true) {
                    None
                } else {
                    r.get("cwd").and_then(Value::as_str).map(PathBuf::from)
                }
            });
            let (Some(id), Some(row_cwd)) = (id, row_cwd) else {
                return Ok(None);
            };
            if cwd.is_some_and(|c| c != row_cwd) {
                return Ok(None);
            }
            Ok(Some(SessionRef {
                harness,
                id,
                file: file.to_path_buf(),
                cwd: row_cwd,
            }))
        }
        Harness::Codex => {
            let rows = first_rows(file, 4)?;
            let Some(meta) = rows
                .iter()
                .find(|r| r.get("type").and_then(Value::as_str) == Some("session_meta"))
                .and_then(|r| r.get("payload"))
            else {
                return Ok(None);
            };
            if !meta.get("parent_thread_id").is_none_or(Value::is_null) {
                return Ok(None);
            }
            let source = meta.get("source");
            let lead_source = match source {
                None => true,
                Some(Value::String(s)) => s == "cli" || s == "vscode",
                Some(_) => false,
            };
            if !lead_source {
                return Ok(None);
            }
            let (Some(id), Some(row_cwd)) = (
                meta.get("id").and_then(Value::as_str),
                meta.get("cwd").and_then(Value::as_str),
            ) else {
                return Ok(None);
            };
            let row_cwd = PathBuf::from(row_cwd);
            if cwd.is_some_and(|c| c != row_cwd) {
                return Ok(None);
            }
            Ok(Some(SessionRef {
                harness,
                id: id.to_owned(),
                file: file.to_path_buf(),
                cwd: row_cwd,
            }))
        }
        Harness::Pi => {
            let rows = first_rows(file, 2)?;
            let Some(session) = rows
                .iter()
                .find(|r| r.get("type").and_then(Value::as_str) == Some("session"))
            else {
                return Ok(None);
            };
            let (Some(id), Some(row_cwd)) = (
                session.get("id").and_then(Value::as_str),
                session.get("cwd").and_then(Value::as_str),
            ) else {
                return Ok(None);
            };
            let row_cwd = PathBuf::from(row_cwd);
            if cwd.is_some_and(|c| c != row_cwd) {
                return Ok(None);
            }
            Ok(Some(SessionRef {
                harness,
                id: id.to_owned(),
                file: file.to_path_buf(),
                cwd: row_cwd,
            }))
        }
        Harness::Copilot => {
            // `file` is the session's workspace.yaml.
            let text = match fs::read_to_string(file) {
                Ok(t) => t,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(Error::io("read", file, e)),
            };
            let mut id = None;
            let mut row_cwd = None;
            for line in text.lines() {
                if let Some(v) = line.strip_prefix("id: ") {
                    id = Some(v.trim().to_owned());
                } else if let Some(v) = line.strip_prefix("cwd: ") {
                    row_cwd = Some(PathBuf::from(v.trim()));
                }
            }
            let (Some(id), Some(row_cwd)) = (id, row_cwd) else {
                return Ok(None);
            };
            // A session with no event yet has not taken a turn; an events
            // file that cannot be read is no evidence of either.
            match written {
                Written::Opened => {}
                Written::Turned => {
                    let events = file.with_file_name("events.jsonl");
                    match fs::metadata(&events) {
                        Ok(meta) if meta.len() > 0 => {}
                        Ok(_) => return Ok(None),
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                        Err(e) => return Err(Error::io("stat", &events, e)),
                    }
                }
            }
            if cwd.is_some_and(|c| c != row_cwd) {
                return Ok(None);
            }
            Ok(Some(SessionRef {
                harness,
                id,
                file: file.to_path_buf(),
                cwd: row_cwd,
            }))
        }
    }
}

/// The user turns a session file records, counted the way its harness
/// writes them (module doc). `file` is the session's own file, the one
/// [`SessionRef::file`] names: Copilot's workspace.yaml, whose events sit
/// beside it.
pub fn user_turns(harness: Harness, file: &Path) -> Result<usize> {
    Ok(user_texts_after(harness, file, 0)?.len())
}

pub fn normalize_user_text(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim_end()
        .to_owned()
}

pub fn text_digest(text: &str) -> u32 {
    crate::record::cksum(normalize_user_text(text).as_bytes())
}

pub fn user_texts_after(harness: Harness, file: &Path, cursor: u64) -> Result<Vec<String>> {
    let rows_file = match harness {
        Harness::Copilot => file.with_file_name("events.jsonl"),
        Harness::Claude | Harness::Codex | Harness::Pi => file.to_path_buf(),
    };
    let f = match fs::File::open(&rows_file) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(Error::io("open", &rows_file, e)),
    };
    let mut turns = 0_u64;
    let mut texts = Vec::new();
    for line in BufReader::new(f).lines() {
        let line = line.map_err(|e| Error::io("read", &rows_file, e))?;
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(text) = user_text(harness, &row) {
            turns += 1;
            if turns > cursor {
                texts.push(normalize_user_text(&text));
            }
        }
    }
    Ok(texts)
}

/// A turn a harness's own session record ends on a failure: its typed
/// word, its HTTP status where the record gives one, its text and the epoch
/// second the record wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub error: Option<String>,
    pub status: Option<u16>,
    pub message: String,
    pub at: Option<u64>,
}

/// How the last turn in a Codex rollout or a Copilot `events.jsonl` ended:
/// `Live(Some)` on a failure, `Live(None)` for a turn that ended otherwise,
/// is still running or never began. `file` names a Copilot session by any
/// file in its directory, as [`user_texts_after`] takes it. Claude Code and
/// Pi write their failure as a hook row instead, so their records are
/// refused, never read as holding none.
///
/// - Codex: an `event_msg` `task_complete` whose `error` carries
///   `codex_error_info` and `message`; a `task_started` opens the next turn.
/// - Copilot CLI: a `session.error` with `errorType`, `statusCode` and
///   `message`, written after the failed turn's `assistant.turn_end`; a
///   `user.message` opens the next turn.
pub fn last_failure(harness: Harness, file: &Path) -> Reading<Option<Failure>> {
    let (rows_file, marks): (PathBuf, &[&str]) = match harness {
        Harness::Codex => (
            file.to_path_buf(),
            &["\"task_started\"", "\"task_complete\""],
        ),
        Harness::Copilot => (
            file.with_file_name("events.jsonl"),
            &["\"user.message\"", "\"session.error\""],
        ),
        Harness::Claude | Harness::Pi => {
            return Reading::Unreadable {
                cause: "record-no-failure-rows",
            };
        }
    };
    let f = match fs::File::open(&rows_file) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: "record-unreadable",
            };
        }
    };
    let mut last = None;
    for line in BufReader::new(f).lines() {
        let Ok(line) = line else {
            return Reading::Unreadable {
                cause: "record-unreadable",
            };
        };
        // Only a turn's opening and closing rows decide; the rest of a long
        // rollout is never parsed.
        if !marks.iter().any(|mark| line.contains(mark)) {
            continue;
        }
        // A row the harness is still writing is a partial line.
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        // A subagent's turn is not the lead's: its failure is no stop of the
        // session, and its prompt opens no lead turn.
        if !lead_row(harness, &row) {
            continue;
        }
        if let Some(end) = turn_end(harness, &row) {
            last = end;
        }
    }
    Reading::Live(last)
}

/// The word of a Codex `codex_error_info`: a unit variant is its name, a
/// variant that carries data, such as `{"http_connection_failed":
/// {"http_status_code": 502}}`, is an object with that name as its one key.
fn codex_error_word(info: Option<&Value>) -> Option<String> {
    match info? {
        Value::String(word) => Some(word.clone()),
        Value::Object(map) if map.len() == 1 => map.keys().next().cloned(),
        Value::Object(_) | Value::Null | Value::Bool(_) | Value::Number(_) | Value::Array(_) => {
            None
        }
    }
}

/// A row that opens a turn (`Some(None)`) or ends one on a failure
/// (`Some(Some)`); `None` for a row that does neither.
fn turn_end(harness: Harness, row: &Value) -> Option<Option<Failure>> {
    let text = |value: Option<&Value>| value.and_then(Value::as_str).map(str::to_owned);
    let at = text(row.get("timestamp"))
        .and_then(|stamp| stamp.parse::<jiff::Timestamp>().ok())
        .and_then(|stamp| u64::try_from(stamp.as_second()).ok());
    match harness {
        Harness::Codex => {
            if row.get("type")?.as_str()? != "event_msg" {
                return None;
            }
            let payload = row.get("payload")?;
            match payload.get("type")?.as_str()? {
                "task_started" => Some(None),
                "task_complete" => {
                    Some(
                        payload
                            .get("error")
                            .filter(|e| !e.is_null())
                            .map(|e| Failure {
                                error: codex_error_word(e.get("codex_error_info")),
                                status: None,
                                message: text(e.get("message")).unwrap_or_default(),
                                at,
                            }),
                    )
                }
                _ => None,
            }
        }
        Harness::Copilot => match row.get("type")?.as_str()? {
            "user.message" => Some(None),
            "session.error" => {
                let data = row.get("data")?;
                Some(Some(Failure {
                    error: text(data.get("errorType")),
                    status: data
                        .get("statusCode")
                        .and_then(Value::as_u64)
                        .and_then(|code| u16::try_from(code).ok()),
                    message: text(data.get("message")).unwrap_or_default(),
                    at,
                }))
            }
            _ => None,
        },
        Harness::Claude | Harness::Pi => None,
    }
}

fn user_text(harness: Harness, row: &Value) -> Option<String> {
    let kind = row.get("type").and_then(Value::as_str);
    match harness {
        Harness::Claude => {
            if kind != Some("user") || row.get("isSidechain").and_then(Value::as_bool) == Some(true)
            {
                return None;
            }
            row.get("message")?
                .get("content")?
                .as_str()
                .map(claude_user_text)
        }
        Harness::Codex => {
            let payload = row.get("payload")?;
            let item = payload.get("item")?;
            if kind != Some("event_msg")
                || payload.get("type")?.as_str()? != "item_completed"
                || item.get("type")?.as_str()? != "UserMessage"
            {
                return None;
            }
            text_parts(item.get("content")?)
        }
        Harness::Copilot => {
            if kind != Some("user.message") {
                return None;
            }
            row.get("data")?.get("content")?.as_str().map(str::to_owned)
        }
        Harness::Pi => {
            let message = row.get("message")?;
            if kind != Some("message") || message.get("role")?.as_str()? != "user" {
                return None;
            }
            text_parts(message.get("content")?)
        }
    }
}

fn claude_user_text(text: &str) -> String {
    if let Some(command) = claude_command_text(text) {
        return command;
    }
    let mut remaining = text;
    let mut unwrapped = String::new();
    while let Some(start) = remaining.find("<pasted_content") {
        let Some((id, body)) = remaining[start..]
            .strip_prefix("<pasted_content id=\"")
            .and_then(|tag| tag.split_once("\">\n"))
        else {
            return text.to_owned();
        };
        if id.is_empty() || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return text.to_owned();
        }
        let closing = format!("\n</pasted_content id=\"{id}\">");
        let Some((inner, after)) = body.split_once(&closing) else {
            return text.to_owned();
        };
        let before = &remaining[..start];
        unwrapped.push_str(before.strip_suffix("\n\n").unwrap_or(before));
        unwrapped.push_str(inner);
        remaining = after.strip_prefix('\n').unwrap_or(after);
    }
    unwrapped.push_str(remaining);
    unwrapped
}

/// The slash command a row records as typed, `/name args`. Claude Code
/// (2.1.325, its command record) writes a typed command as three tags
/// joined by a newline: `command-message` holding the name,
/// `command-name` holding `/` and the name, and `command-args` holding the
/// arguments, absent where it took none. Only a row that is that record
/// whole reads as the command; any other text is `None`.
fn claude_command_text(text: &str) -> Option<String> {
    let rest = text.strip_prefix("<command-message>")?;
    let (name, rest) = rest.split_once("</command-message>\n<command-name>/")?;
    if name.is_empty() {
        return None;
    }
    let rest = rest.strip_prefix(name)?.strip_prefix("</command-name>")?;
    if rest.is_empty() {
        return Some(format!("/{name}"));
    }
    let args = rest
        .strip_prefix("\n<command-args>")?
        .strip_suffix("</command-args>")?;
    Some(format!("/{name} {args}"))
}

fn text_parts(content: &Value) -> Option<String> {
    let parts: Vec<_> = content
        .as_array()?
        .iter()
        .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n"))
}

/// What one row of a session's file adds to the model's context, as the
/// row's harness records it. A row adds what its harness sends on, never
/// what only its interface shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    /// A user turn, the one [`user_turns`] counts, with the turn's native
    /// id where the row carries one. Its bytes are the text the row
    /// records, not the text [`user_text`] reads from it.
    Turn { id: Option<String>, bytes: u64 },
    /// Text the harness added to the context beside a turn or a result:
    /// each text block of a Claude Code `user` row that is not a turn,
    /// such as a skill body a slash command expands to, marked `isMeta`
    /// (measured on Claude Code 2.1.330).
    Text { bytes: u64 },
    /// Text that enters the context and belongs to no item beside it: a Pi
    /// `custom_message`, an extension's message, which a steer delivers
    /// after whatever tool result came last.
    Foreign,
    /// A tool call the model made.
    Call { id: String, action: Action },
    /// A tool result sent back: its bytes, `None` where the text it added
    /// is not the row's; the tokens the harness counted for it where it
    /// counts them; and the name of what it loaded where the harness names
    /// that only on the result (a Copilot skill).
    Result {
        call: String,
        bytes: Option<u64>,
        tokens: Option<u64>,
        loaded: Option<String>,
    },
}

/// What a tool call does, in the terms its harness's own tools are named.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// A file read: the path the call names.
    Read(String),
    /// A shell command's text.
    Shell(String),
    /// A skill load, with the skill's name where the call names it.
    Skill(Option<String>),
    Other,
}

/// Whether `row` is the lead session's own: a Claude Code sidechain row and
/// a Copilot row carrying a sub-agent's `agentId` (Copilot SDK
/// `session-events.ts`: absent for the root agent) are another agent's.
pub fn lead_row(harness: Harness, row: &Value) -> bool {
    match harness {
        Harness::Claude => row.get("isSidechain").and_then(Value::as_bool) != Some(true),
        Harness::Copilot => row
            .get("agentId")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty),
        Harness::Codex | Harness::Pi => true,
    }
}

/// A Pi entry's own id and its parent's, by which Pi's file holds a tree
/// (Pi 1.6.0's session format documentation): `None` for the header and on
/// every other harness, whose rows a reader takes in file order.
pub fn tree_link(harness: Harness, row: &Value) -> Option<(&str, Option<&str>)> {
    if harness != Harness::Pi || row.get("type").and_then(Value::as_str) == Some("session") {
        return None;
    }
    let id = row.get("id")?.as_str()?;
    Some((id, row.get("parentId").and_then(Value::as_str)))
}

/// What `row` adds to the context, each harness's rows as its own record
/// writes them:
///
/// - Claude Code (2.1.330, a recorded transcript): a turn's `promptId`;
///   an assistant message's `tool_use` blocks, `Read` naming `file_path`,
///   `Bash` `command` and `Skill` `skill`; a `user` row's `tool_result`
///   blocks, by `tool_use_id`, and its text blocks.
/// - Codex (rust-v0.171.0, `codex-rs/protocol/src/{models,items,protocol}.rs`
///   and `core/src/tools/handlers/shell_spec.rs`): a turn's `turn_id`; a
///   `function_call` or `custom_tool_call` by `call_id`, the shell being
///   `exec_command` with its JSON `arguments`' `cmd`; its output by
///   `call_id`, a string or `input_text` items.
/// - Copilot CLI (Copilot SDK `session-events.ts`, the CLI's reference
///   tool table, a recorded 1.0.112 log, and the tool-call classifier in
///   1.0.114's `cli-main.js`): a `user.message`'s `interactionId`; a
///   `tool.execution_start` by `toolCallId`, `bash` naming
///   `arguments.command`, `view` (and `str_replace_editor` whose
///   `command` is `view`) `arguments.path`, and `skill` its skill only on
///   the result's `toolTelemetry.restrictedProperties.skillName`; a
///   `tool.execution_complete`'s `result.content`, or a failure's
///   `error.message`. A skill's result is not its body: the log records
///   `skillContentLength` 30809 beside `result_token_count` 27, so the
///   body reaches the context apart from the result, and the result
///   counts neither its bytes nor its tokens.
/// - Pi (Pi 1.6.0's session format and message type documentation):
///   a turn's entry `id`; an assistant message's `toolCall` blocks,
///   `read` naming `path` and `bash` `command`; a `toolResult` message's
///   text by `toolCallId`; a `custom_message`, as no item's text.
pub fn entries(harness: Harness, row: &Value) -> Vec<Entry> {
    fn text(value: Option<&Value>) -> &str {
        value.and_then(Value::as_str).unwrap_or_default()
    }
    let turn = |id: Option<&Value>| {
        user_text(harness, row).map(|_| Entry::Turn {
            id: id.and_then(Value::as_str).map(str::to_owned),
            bytes: turn_bytes(harness, row),
        })
    };
    let kind = text(row.get("type"));
    match harness {
        Harness::Claude => {
            if let Some(turn) = turn(row.get("promptId")) {
                return vec![turn];
            }
            let Some(Value::Array(blocks)) = row.get("message").and_then(|m| m.get("content"))
            else {
                return Vec::new();
            };
            let mut found = Vec::new();
            for block in blocks {
                match (kind, text(block.get("type"))) {
                    ("assistant", "tool_use") => {
                        let input = |key: &str| text(block.get("input").and_then(|i| i.get(key)));
                        let action = match text(block.get("name")) {
                            "Read" => Action::Read(input("file_path").to_owned()),
                            "Bash" => Action::Shell(input("command").to_owned()),
                            "Skill" => Action::Skill(
                                Some(input("skill"))
                                    .filter(|n| !n.is_empty())
                                    .map(str::to_owned),
                            ),
                            _ => Action::Other,
                        };
                        found.push(Entry::Call {
                            id: text(block.get("id")).to_owned(),
                            action,
                        });
                    }
                    ("user", "tool_result") => found.push(Entry::Result {
                        call: text(block.get("tool_use_id")).to_owned(),
                        bytes: Some(text_bytes(block.get("content"), "text")),
                        tokens: None,
                        loaded: None,
                    }),
                    ("user", "text") => found.push(Entry::Text {
                        bytes: text(block.get("text")).len() as u64,
                    }),
                    _ => {}
                }
            }
            found
        }
        Harness::Codex => {
            let payload = row.get("payload");
            if let Some(turn) = turn(payload.and_then(|p| p.get("turn_id"))) {
                return vec![turn];
            }
            let Some(payload) = payload.filter(|_| kind == "response_item") else {
                return Vec::new();
            };
            let call = text(payload.get("call_id")).to_owned();
            match text(payload.get("type")) {
                "function_call" | "custom_tool_call" => {
                    let action = match text(payload.get("name")) {
                        "exec_command" => {
                            serde_json::from_str::<Value>(text(payload.get("arguments")))
                                .ok()
                                .and_then(|args| args.get("cmd")?.as_str().map(str::to_owned))
                                .map_or(Action::Other, Action::Shell)
                        }
                        _ => Action::Other,
                    };
                    vec![Entry::Call { id: call, action }]
                }
                "function_call_output" | "custom_tool_call_output" => vec![Entry::Result {
                    call,
                    bytes: Some(text_bytes(payload.get("output"), "input_text")),
                    tokens: None,
                    loaded: None,
                }],
                _ => Vec::new(),
            }
        }
        Harness::Copilot => {
            let data = row.get("data");
            let field = |key: &str| data.and_then(|d| d.get(key));
            if let Some(turn) = turn(field("interactionId")) {
                return vec![turn];
            }
            let call = text(field("toolCallId")).to_owned();
            match kind {
                "tool.execution_start" => {
                    let argument = |key: &str| text(field("arguments").and_then(|a| a.get(key)));
                    let action = match text(field("toolName")) {
                        "bash" => Action::Shell(argument("command").to_owned()),
                        "view" => Action::Read(argument("path").to_owned()),
                        "str_replace_editor" if argument("command") == "view" => {
                            Action::Read(argument("path").to_owned())
                        }
                        "skill" => Action::Skill(None),
                        _ => Action::Other,
                    };
                    vec![Entry::Call { id: call, action }]
                }
                "tool.execution_complete" => {
                    let sent = match field("result") {
                        Some(result) => result.get("content"),
                        None => field("error").and_then(|e| e.get("message")),
                    };
                    let loaded = field("toolTelemetry")
                        .and_then(|t| t.get("restrictedProperties"))
                        .and_then(|p| p.get("skillName"))
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let (bytes, tokens) = match loaded {
                        Some(_) => (None, None),
                        None => (
                            Some(text(sent).len() as u64),
                            row.as_object()
                                .and_then(crate::context::copilot_result_tokens),
                        ),
                    };
                    vec![Entry::Result {
                        call,
                        bytes,
                        tokens,
                        loaded,
                    }]
                }
                _ => Vec::new(),
            }
        }
        Harness::Pi => {
            if let Some(turn) = turn(row.get("id")) {
                return vec![turn];
            }
            if kind == "custom_message" {
                return vec![Entry::Foreign];
            }
            let Some(message) = row.get("message").filter(|_| kind == "message") else {
                return Vec::new();
            };
            match text(message.get("role")) {
                "assistant" => message
                    .get("content")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|block| text(block.get("type")) == "toolCall")
                    .map(|block| {
                        let argument =
                            |key: &str| text(block.get("arguments").and_then(|a| a.get(key)));
                        let action = match text(block.get("name")) {
                            "read" => Action::Read(argument("path").to_owned()),
                            "bash" => Action::Shell(argument("command").to_owned()),
                            _ => Action::Other,
                        };
                        Entry::Call {
                            id: text(block.get("id")).to_owned(),
                            action,
                        }
                    })
                    .collect(),
                "toolResult" => vec![Entry::Result {
                    call: text(message.get("toolCallId")).to_owned(),
                    bytes: Some(text_bytes(message.get("content"), "text")),
                    tokens: None,
                    loaded: None,
                }],
                _ => Vec::new(),
            }
        }
    }
}

/// The bytes a user turn's row records for the model: the content before
/// [`user_text`] rewrites a Claude Code command record or unwraps pasted
/// content, and on Copilot CLI the `transformedContent` the CLI sent, its
/// augmentations included (the CLI's `schemas/session-events.schema.json`,
/// 1.0.114), where the row carries it.
fn turn_bytes(harness: Harness, row: &Value) -> u64 {
    let content = match harness {
        Harness::Claude | Harness::Pi => row.get("message").and_then(|m| m.get("content")),
        Harness::Codex => row
            .get("payload")
            .and_then(|p| p.get("item"))
            .and_then(|i| i.get("content")),
        Harness::Copilot => {
            let data = row.get("data");
            data.and_then(|d| d.get("transformedContent"))
                .filter(|sent| sent.is_string())
                .or_else(|| data.and_then(|d| d.get("content")))
        }
    };
    text_bytes(content, "text")
}

/// The bytes of a content value: a string whole, or the `text` of each part
/// of type `part` in an array; anything else, an image among them, adds none.
fn text_bytes(content: Option<&Value>, part: &str) -> u64 {
    match content {
        Some(Value::String(text)) => text.len() as u64,
        Some(Value::Array(parts)) => parts
            .iter()
            .filter(|p| p.get("type").and_then(Value::as_str) == Some(part))
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .map(|text| text.len() as u64)
            .sum(),
        _ => 0,
    }
}

/// A session file a store lists for a cwd, with the modification time read
/// beside it, so the floor a launch binds above costs no second read.
struct Candidate {
    path: PathBuf,
    modified: SystemTime,
}

const STORE_UNREADABLE: Unreadable = Unreadable {
    cause: "session-store-unreadable",
};
const FILE_UNREADABLE: Unreadable = Unreadable {
    cause: "session-file-unreadable",
};
const MTIME_UNREADABLE: Unreadable = Unreadable {
    cause: "session-mtime-unreadable",
};

/// The entries of `dir`, every one read: a listing or an entry that fails
/// is `Unreadable`, since a candidate dropped is a session that may be
/// bound to its neighbour. `Gone` is a directory that does
/// not exist.
fn listed(dir: &Path) -> Reading<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
        Err(_) => {
            return Reading::Unreadable {
                cause: STORE_UNREADABLE.cause,
            };
        }
    };
    let mut paths = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => paths.push(entry.path()),
            Err(_) => {
                return Reading::Unreadable {
                    cause: STORE_UNREADABLE.cause,
                };
            }
        }
    }
    Reading::Live(paths)
}

/// `path` as a candidate where it is a regular file, read once for its
/// kind and its modification time; `None` for a directory or anything
/// else that is no session file.
fn candidate(path: PathBuf) -> std::result::Result<Option<Candidate>, Unreadable> {
    let meta = fs::metadata(&path).map_err(|_| STORE_UNREADABLE)?;
    if !meta.is_file() {
        return Ok(None);
    }
    let modified = meta.modified().map_err(|_| MTIME_UNREADABLE)?;
    Ok(Some(Candidate { path, modified }))
}

/// Every file under `dir` to `depth` directories down, every listing and
/// every entry read; the Codex store is `sessions/YYYY/MM/DD/`.
fn walk(dir: &Path, out: &mut Vec<Candidate>, depth: usize) -> std::result::Result<(), Unreadable> {
    let paths = match listed(dir) {
        Reading::Live(paths) => paths,
        // A directory the listing named and then could not enter is a
        // store changing under the read, not an empty one.
        Reading::Gone => return Err(STORE_UNREADABLE),
        Reading::Unreadable { cause } => return Err(Unreadable { cause }),
    };
    for path in paths {
        let meta = fs::metadata(&path).map_err(|_| STORE_UNREADABLE)?;
        if meta.is_dir() {
            if depth > 0 {
                walk(&path, out, depth - 1)?;
            }
        } else if meta.is_file() {
            let modified = meta.modified().map_err(|_| MTIME_UNREADABLE)?;
            out.push(Candidate { path, modified });
        }
    }
    Ok(())
}

/// The session files the harness's store holds for `cwd` under `home`,
/// every one read: `Gone` where the store's root for that cwd does not
/// exist (a cold directory, an empty set), `Unreadable` where any listing,
/// entry or file metadata failed. Nothing is filtered by a failed read.
fn candidates(harness: Harness, home: &Path, cwd: &Path) -> Reading<Vec<Candidate>> {
    let jsonl_files = |dir: PathBuf| -> Reading<Vec<Candidate>> {
        let paths = match listed(&dir) {
            Reading::Live(paths) => paths,
            Reading::Gone => return Reading::Gone,
            Reading::Unreadable { cause } => return Reading::Unreadable { cause },
        };
        let mut files = Vec::new();
        for path in paths {
            if path.extension().is_none_or(|e| e != "jsonl") {
                continue;
            }
            match candidate(path) {
                Ok(Some(found)) => files.push(found),
                Ok(None) => {}
                Err(Unreadable { cause }) => return Reading::Unreadable { cause },
            }
        }
        Reading::Live(files)
    };
    match harness {
        Harness::Claude => jsonl_files(home.join("projects").join(claude_slug(cwd))),
        Harness::Pi => jsonl_files(home.join("sessions").join(pi_slug(cwd))),
        Harness::Codex => {
            let root = home.join("sessions");
            let mut files = Vec::new();
            match listed(&root) {
                Reading::Live(paths) => {
                    for path in paths {
                        let meta = match fs::metadata(&path) {
                            Ok(meta) => meta,
                            Err(_) => {
                                return Reading::Unreadable {
                                    cause: STORE_UNREADABLE.cause,
                                };
                            }
                        };
                        if meta.is_dir()
                            && let Err(Unreadable { cause }) = walk(&path, &mut files, 3)
                        {
                            return Reading::Unreadable { cause };
                        }
                    }
                }
                Reading::Gone => return Reading::Gone,
                Reading::Unreadable { cause } => return Reading::Unreadable { cause },
            }
            files.retain(|c| {
                c.path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(".jsonl"))
            });
            Reading::Live(files)
        }
        Harness::Copilot => {
            let paths = match listed(&home.join("session-state")) {
                Reading::Live(paths) => paths,
                Reading::Gone => return Reading::Gone,
                Reading::Unreadable { cause } => return Reading::Unreadable { cause },
            };
            let mut files = Vec::new();
            for dir in paths {
                // A session directory with no workspace.yaml is no session;
                // one whose file cannot be read is unread, not absent.
                let ws = dir.join("workspace.yaml");
                match fs::metadata(&ws) {
                    Ok(meta) if meta.is_file() => match meta.modified() {
                        Ok(modified) => files.push(Candidate { path: ws, modified }),
                        Err(_) => {
                            return Reading::Unreadable {
                                cause: MTIME_UNREADABLE.cause,
                            };
                        }
                    },
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => {
                        return Reading::Unreadable {
                            cause: STORE_UNREADABLE.cause,
                        };
                    }
                }
            }
            Reading::Live(files)
        }
    }
}

/// Every lead session the harness recorded for `cwd` under `home`, oldest
/// or newest alike: the baseline a launch reads before its window opens, so
/// the session that appears after it can be told from every neighbour that
/// stood before, every session that opened counted as [`new_leads`] counts
/// one. `Gone` is a store with no root for the cwd,
/// an empty baseline read; `Unreadable` is a baseline not read, which binds
/// nothing by appearance later.
pub fn lead_ids(harness: Harness, home: &Path, cwd: &Path) -> Reading<Vec<String>> {
    let found = match candidates(harness, home, cwd) {
        Reading::Live(found) => found,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let mut ids = Vec::new();
    for candidate in found {
        match identify(harness, &candidate.path, Some(cwd), Written::Opened) {
            Ok(Some(lead)) => ids.push(lead.id),
            Ok(None) => {}
            Err(_) => {
                return Reading::Unreadable {
                    cause: FILE_UNREADABLE.cause,
                };
            }
        }
    }
    Reading::Live(ids)
}

/// The lead session for `cwd` under `home` a reader with no id binds by
/// time: with `since`, the earliest that appeared at or after it, the
/// session the launch at `since` started (a later one in the same
/// directory is a second session, run from the first); without, the
/// newest. Only a session that took its first turn qualifies, so one that
/// ended before it is never named in the running session's place. `Gone`
/// where none qualifies; `Unreadable` where the store or a candidate could
/// not be read, which binds nothing.
pub fn lead_at(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    since: Option<SystemTime>,
) -> Reading<SessionRef> {
    let found = match candidates(harness, home, cwd) {
        Reading::Live(found) => found,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let mut best: Option<(SystemTime, SessionRef)> = None;
    for candidate in found {
        if since.is_some_and(|since| candidate.modified < since) {
            continue;
        }
        match identify(harness, &candidate.path, Some(cwd), Written::Turned) {
            Ok(Some(lead)) => {
                let better = match &best {
                    None => true,
                    Some((at, _)) if since.is_some() => candidate.modified < *at,
                    Some((at, _)) => candidate.modified > *at,
                };
                if better {
                    best = Some((candidate.modified, lead));
                }
            }
            Ok(None) => {}
            Err(_) => {
                return Reading::Unreadable {
                    cause: FILE_UNREADABLE.cause,
                };
            }
        }
    }
    match best {
        Some((_, lead)) => Reading::Live(lead),
        None => Reading::Gone,
    }
}

/// The lead sessions for `cwd` under `home` that appeared since a launch's
/// window opened: opened ([`Written::Opened`]), modified at or after
/// `since` and absent from the `baseline` read before the window opened,
/// so a harness that writes its first event only at its first turn is
/// bound before the brief that makes that turn. One is the launch's own; two
/// or more cannot be told apart, and none has appeared yet. A set is read
/// whole or not at all: any candidate that could not be read makes the
/// reading `Unreadable`, so one readable lead beside an unreadable one binds
/// nothing.
pub fn new_leads(
    harness: Harness,
    home: &Path,
    cwd: &Path,
    since: SystemTime,
    baseline: &[String],
) -> Reading<Vec<SessionRef>> {
    let found = match candidates(harness, home, cwd) {
        Reading::Live(found) => found,
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    };
    let mut appeared = Vec::new();
    for candidate in found {
        if candidate.modified < since {
            continue;
        }
        match identify(harness, &candidate.path, Some(cwd), Written::Opened) {
            Ok(Some(lead)) if !baseline.contains(&lead.id) => appeared.push(lead),
            Ok(_) => {}
            Err(_) => {
                return Reading::Unreadable {
                    cause: FILE_UNREADABLE.cause,
                };
            }
        }
    }
    Reading::Live(appeared)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_codex_subagent_rollout_is_not_a_lead() {
        let dir = tempfile::tempdir().unwrap();
        let lead = dir.path().join("rollout-a-1.jsonl");
        fs::write(
            &lead,
            r#"{"type":"session_meta","payload":{"id":"L","cwd":"/w","parent_thread_id":null,"source":"cli"}}"#,
        )
        .unwrap();
        let child = dir.path().join("rollout-b-2.jsonl");
        fs::write(
            &child,
            r#"{"type":"session_meta","payload":{"id":"C","cwd":"/w","parent_thread_id":"L","source":{"subagent":{}}}}"#,
        )
        .unwrap();
        assert_eq!(
            identify(
                Harness::Codex,
                &lead,
                Some(Path::new("/w")),
                Written::Opened
            )
            .unwrap()
            .unwrap()
            .id,
            "L"
        );
        assert!(
            identify(
                Harness::Codex,
                &child,
                Some(Path::new("/w")),
                Written::Opened
            )
            .unwrap()
            .is_none()
        );
        assert!(
            identify(
                Harness::Codex,
                &lead,
                Some(Path::new("/other")),
                Written::Opened
            )
            .unwrap()
            .is_none()
        );
    }

    /// A Copilot launch binds the session it opened before that session
    /// takes a turn: its workspace.yaml in the launch's cwd, written since
    /// the window opened and absent from the baseline, with no events file
    /// yet. A turnless folder of another cwd, or one written before the
    /// window opened, never binds; one that stood in the baseline is
    /// counted there. A resume and a reader with no launch of its own name
    /// a session only once it took its first turn.
    #[test]
    fn a_copilot_launch_binds_the_session_it_opened_before_its_first_turn() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let cwd = Path::new("/w");
        let open = |id: &str, cwd: &str| {
            let s = home.join("session-state").join(id);
            fs::create_dir_all(&s).unwrap();
            fs::write(s.join("workspace.yaml"), format!("id: {id}\ncwd: {cwd}\n")).unwrap();
            s
        };
        open("BEFORE", "/w");
        let Reading::Live(baseline) = lead_ids(Harness::Copilot, home, cwd) else {
            panic!("the baseline reads")
        };
        assert_eq!(baseline, vec!["BEFORE".to_owned()]);
        std::thread::sleep(std::time::Duration::from_millis(20));
        let since = SystemTime::now();
        // File stamps come from the kernel's coarse clock, which can trail
        // the precise one by a tick, so the writes follow a pause.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let own = open("OWN", "/w");
        open("ELSEWHERE", "/other");
        let leads =
            |baseline: &[String]| match new_leads(Harness::Copilot, home, cwd, since, baseline) {
                Reading::Live(found) => found.into_iter().map(|s| s.id).collect::<Vec<_>>(),
                other => panic!("the leads read: {other:?}"),
            };
        assert_eq!(leads(&baseline), vec!["OWN".to_owned()]);
        assert_eq!(
            leads(&[]),
            vec!["OWN".to_owned()],
            "a folder written before the window opened never binds, baseline or not"
        );
        assert_eq!(
            lead_at(Harness::Copilot, home, cwd, Some(since)),
            Reading::Gone
        );
        assert_eq!(
            resume_owner(Harness::Copilot, home, cwd, "OWN"),
            Reading::Gone
        );
        fs::write(own.join("events.jsonl"), "{\"type\":\"user.message\"}\n").unwrap();
        assert_eq!(
            lead_at(Harness::Copilot, home, cwd, Some(since)).map(|s| s.id),
            Reading::Live("OWN".to_owned())
        );
        assert_eq!(
            resume_owner(Harness::Copilot, home, cwd, "OWN"),
            Reading::Live(Some(cwd.to_path_buf()))
        );
    }

    /// A read that fails is `Unreadable`, never a candidate
    /// dropped. A Copilot session directory the reader cannot enter beside a
    /// readable lead makes the whole reading unreadable, for the baseline
    /// and for the leads that appeared alike; a Codex day directory the
    /// reader cannot list does the same; a store with no root for the cwd
    /// reads `Gone`, an empty set, on every harness.
    #[test]
    #[cfg(unix)]
    fn an_unreadable_candidate_makes_the_whole_reading_unreadable() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let cwd = Path::new("/w");
        for harness in Harness::ALL {
            assert_eq!(lead_ids(harness, home, cwd), Reading::Gone, "{harness:?}");
            assert_eq!(
                new_leads(harness, home, cwd, SystemTime::UNIX_EPOCH, &[]),
                Reading::Gone,
                "{harness:?}"
            );
        }
        let readable = home.join("session-state").join("S1");
        fs::create_dir_all(&readable).unwrap();
        fs::write(readable.join("workspace.yaml"), "id: S1\ncwd: /w\n").unwrap();
        fs::write(readable.join("events.jsonl"), "{\"type\":\"x\"}\n").unwrap();
        let dark = home.join("session-state").join("S2");
        fs::create_dir_all(&dark).unwrap();
        fs::set_permissions(&dark, fs::Permissions::from_mode(0o000)).unwrap();
        let denied = matches!(
            fs::read_dir(&dark),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied
        );
        let ids = lead_ids(Harness::Copilot, home, cwd);
        let leads = new_leads(Harness::Copilot, home, cwd, SystemTime::UNIX_EPOCH, &[]);
        fs::set_permissions(&dark, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            denied,
            "the fixture needs a directory this process cannot enter; a root run reads everything"
        );
        const UNREADABLE: &str = "session-store-unreadable";
        assert_eq!(ids, Reading::Unreadable { cause: UNREADABLE });
        assert_eq!(
            leads,
            Reading::Unreadable { cause: UNREADABLE },
            "one readable lead beside an unreadable directory binds nothing"
        );
        assert_eq!(
            lead_ids(Harness::Copilot, home, cwd),
            Reading::Live(vec!["S1".to_owned()]),
            "readable again, the one lead reads"
        );
        let day = home.join("sessions").join("2026").join("10").join("27");
        fs::create_dir_all(&day).unwrap();
        fs::write(
            day.join("rollout-a-R.jsonl"),
            r#"{"type":"session_meta","payload":{"id":"R","cwd":"/w","parent_thread_id":null,"source":"cli"}}"#,
        )
        .unwrap();
        let month = home.join("sessions").join("2026").join("09");
        fs::create_dir_all(&month).unwrap();
        fs::set_permissions(&month, fs::Permissions::from_mode(0o000)).unwrap();
        let ids = lead_ids(Harness::Codex, home, cwd);
        fs::set_permissions(&month, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(ids, Reading::Unreadable { cause: UNREADABLE });
        assert_eq!(
            lead_ids(Harness::Codex, home, cwd),
            Reading::Live(vec!["R".to_owned()])
        );
        // A session file that cannot be opened is unread, not a non-lead.
        let project = home.join("projects").join(claude_slug(cwd));
        fs::create_dir_all(&project).unwrap();
        let sealed = project.join("sealed.jsonl");
        fs::write(
            &sealed,
            r#"{"type":"user","sessionId":"sealed","cwd":"/w"}"#,
        )
        .unwrap();
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
        assert_eq!(
            lead_ids(Harness::Claude, home, cwd),
            Reading::Unreadable {
                cause: "session-file-unreadable"
            }
        );
    }

    /// One row per harness, each a cut of the native probe's own session
    /// file: the rows that are user turns and the neighbours that are not.
    #[test]
    fn user_turns_counts_each_harness_s_own_user_rows() {
        let dir = tempfile::tempdir().unwrap();
        let rows: [(Harness, &str, &str, usize); 4] = [
            (
                Harness::Claude,
                "s.jsonl",
                concat!(
                    r#"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"fe7d"}"#,
                    "
",
                    r#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Create probe-1.txt"},"uuid":"4944","timestamp":"2026-10-26T02:06:34.777Z","sessionId":"fe7d","cwd":"/w"}"#,
                    "
",
                    r#"{"parentUuid":"4944","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"sessionId":"fe7d"}"#,
                    "
",
                    r#"{"parentUuid":"4e00","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"0000004"}]},"sessionId":"fe7d"}"#,
                    "
",
                    r#"{"parentUuid":"1a32","isSidechain":true,"type":"user","message":{"role":"user","content":"a subagent's prompt"},"sessionId":"fe7d"}"#,
                    "
",
                    r#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Now create probe-2.txt"},"sessionId":"fe7d","cwd":"/w"}"#,
                    "
",
                ),
                2,
            ),
            (
                Harness::Codex,
                "rollout-a.jsonl",
                concat!(
                    r#"{"timestamp":"2026-10-26T02:07:04.408Z","ordinal":0,"type":"session_meta","payload":{"id":"01a1","cwd":"/w","parent_thread_id":null,"source":"cli"}}"#,
                    "
",
                    r#"{"timestamp":"2026-10-26T02:07:06.076Z","ordinal":7,"type":"response_item","payload":{"type":"message","id":"msg_1","role":"user","content":[{"type":"input_text","text":"<environment_context>…</environment_context>"}]}}"#,
                    "
",
                    r#"{"timestamp":"2026-10-26T02:07:06.079Z","ordinal":11,"type":"response_item","payload":{"type":"message","id":"msg_2","role":"user","content":[{"type":"input_text","text":"Create probe-1.txt"}]}}"#,
                    "
",
                    r#"{"timestamp":"2026-10-26T02:07:06.080Z","ordinal":12,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01a1","item":{"type":"UserMessage","id":"01a1-um","content":[{"type":"text","text":"Create probe-1.txt"}]}}}"#,
                    "
",
                    r#"{"timestamp":"2026-10-26T02:07:11.069Z","ordinal":13,"type":"event_msg","payload":{"type":"item_completed","thread_id":"01a1","item":{"type":"Reasoning","id":"rs_1","summary_text":[]}}}"#,
                    "
",
                ),
                1,
            ),
            (
                Harness::Copilot,
                "workspace.yaml",
                concat!(
                    r#"{"type":"session.start","data":{"sessionId":"76c3","version":1},"id":"ac01","timestamp":"2026-10-26T02:07:49.923Z"}"#,
                    "
",
                    r#"{"type":"user.message","data":{"content":"Create probe-1.txt"},"id":"5440","timestamp":"2026-10-26T02:07:52.504Z","parentId":"1709"}"#,
                    "
",
                    r#"{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"bacd","timestamp":"2026-10-26T02:07:52.507Z","parentId":"5440"}"#,
                    "
",
                    r#"{"type":"assistant.message","data":{"messageId":"cc98","content":"done"},"id":"d6cf","timestamp":"2026-10-26T02:07:55.000Z"}"#,
                    "
",
                    r#"{"type":"user.message","data":{"content":"Now create probe-2.txt"},"id":"7777","timestamp":"2026-10-26T02:08:10.000Z","parentId":"d6cf"}"#,
                    "
",
                ),
                2,
            ),
            (
                Harness::Pi,
                "2026-10-26T02-08-44-396Z_01a1.jsonl",
                concat!(
                    r#"{"type":"session","version":3,"id":"01a1","timestamp":"2026-10-26T02:08:44.396Z","cwd":"/w"}"#,
                    "
",
                    r#"{"type":"message","id":"5ad7","parentId":"49d7","timestamp":"2026-10-26T02:08:44.463Z","message":{"role":"system","content":""}}"#,
                    "
",
                    r#"{"type":"message","id":"0859","parentId":"5ad7","timestamp":"2026-10-26T02:08:44.463Z","message":{"role":"user","content":[{"type":"text","text":"Create probe-1.txt"}],"timestamp":1792980524461}}"#,
                    "
",
                    r#"{"type":"message","id":"315d","parentId":"0859","timestamp":"2026-10-26T02:08:47.317Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
                    "
",
                    r#"{"type":"message","id":"b0e7","parentId":"315d","timestamp":"2026-10-26T02:08:47.322Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"(no output)"}]}}"#,
                    "
",
                ),
                1,
            ),
        ];
        for (harness, name, text, expected) in rows {
            let file = dir.path().join(harness.name()).join(name);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            // Copilot's turns sit in events.jsonl beside the named file.
            let rows_file = match harness {
                Harness::Copilot => file.with_file_name("events.jsonl"),
                _ => file.clone(),
            };
            fs::write(&rows_file, text).unwrap();
            assert_eq!(user_turns(harness, &file).unwrap(), expected, "{harness:?}");
            let prompts = ["Create probe-1.txt", "Now create probe-2.txt"];
            for cursor in 0..=expected {
                assert_eq!(
                    user_texts_after(harness, &file, cursor as u64).unwrap(),
                    prompts[cursor..expected],
                    "{harness:?} cursor={cursor}"
                );
            }
            assert!(user_texts_after(harness, &file, 99).unwrap().is_empty());
        }
        // A session whose file is not written yet has no turns.
        assert_eq!(
            user_turns(Harness::Claude, &dir.path().join("none.jsonl")).unwrap(),
            0
        );
    }

    #[test]
    fn user_text_normalization_keeps_leading_space_and_normalizes_line_ends() {
        for (text, expected) in [
            (
                "  first  \r\nsecond\t\rthird \n\n",
                "  first\nsecond\nthird",
            ),
            ("first\nsecond", "first\nsecond"),
            ("\r\n \t", ""),
            ("", ""),
        ] {
            assert_eq!(normalize_user_text(text), expected);
        }
    }

    #[test]
    fn prompt_digests_normalize_before_the_checksum() {
        for text in ["work", "work  \r\n", "work\t\r\n\n"] {
            assert_eq!(text_digest(text), crate::record::cksum(b"work"));
        }
        assert_ne!(text_digest(" work"), text_digest("work"));
    }

    #[test]
    fn a_fresh_session_id_is_a_version_4_uuid() {
        let id = fresh_session_id().unwrap();
        let parts: Vec<&str> = id.split('-').collect();
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
        assert!(id.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
        assert!(parts[2].starts_with('4'));
        assert!(matches!(
            parts[3].chars().next(),
            Some('8' | '9' | 'a' | 'b')
        ));
        assert_ne!(fresh_session_id().unwrap(), id);
        assert_eq!(uuid_v4([0xff; 16]), "ffffffff-ffff-4fff-bfff-ffffffffffff");
        assert_eq!(
            fixed_file(Harness::Claude, Path::new("/h"), Path::new("/w/x"), &id),
            Some(PathBuf::from(format!("/h/projects/-w-x/{id}.jsonl")))
        );
        assert_eq!(
            fixed_file(Harness::Codex, Path::new("/h"), Path::new("/w"), &id),
            None
        );
    }

    #[test]
    fn claude_paste_wrappers_are_removed_only_when_well_formed() {
        let rows = [
            (
                "whole row",
                "\n\n<pasted_content id=\"634f\">\nfirst\r\n second \t\n</pasted_content id=\"634f\">\n",
                "first\n second",
            ),
            (
                "between typed text",
                "before \n\n<pasted_content id=\"a1\">\npasted\n</pasted_content id=\"a1\">\n after",
                "before pasted after",
            ),
            (
                "multiple blocks",
                "\n\n<pasted_content id=\"a1\">\nfirst\n</pasted_content id=\"a1\">\n + \n\n<pasted_content id=\"b2\">\nsecond\n</pasted_content id=\"b2\">\n",
                "first + second",
            ),
            (
                "no outer newlines",
                "<pasted_content id=\"a1\">\npasted\n</pasted_content id=\"a1\">",
                "pasted",
            ),
            (
                "unclosed block",
                "\n\n<pasted_content id=\"a1\">\npasted",
                "\n\n<pasted_content id=\"a1\">\npasted",
            ),
            (
                "different closing id",
                "\n\n<pasted_content id=\"a1\">\npasted\n</pasted_content id=\"b2\">\n",
                "\n\n<pasted_content id=\"a1\">\npasted\n</pasted_content id=\"b2\">",
            ),
            (
                "missing opening LF",
                "\n\n<pasted_content id=\"a1\">pasted\n</pasted_content id=\"a1\">\n",
                "\n\n<pasted_content id=\"a1\">pasted\n</pasted_content id=\"a1\">",
            ),
            (
                "missing closing LF",
                "\n\n<pasted_content id=\"a1\">\npasted</pasted_content id=\"a1\">\n",
                "\n\n<pasted_content id=\"a1\">\npasted</pasted_content id=\"a1\">",
            ),
            (
                "nonhex id",
                "\n\n<pasted_content id=\"word\">\npasted\n</pasted_content id=\"word\">\n",
                "\n\n<pasted_content id=\"word\">\npasted\n</pasted_content id=\"word\">",
            ),
            (
                "empty id",
                "\n\n<pasted_content id=\"\">\npasted\n</pasted_content id=\"\">\n",
                "\n\n<pasted_content id=\"\">\npasted\n</pasted_content id=\"\">",
            ),
            (
                "malformed block after a valid block",
                "\n\n<pasted_content id=\"a1\">\nfirst\n</pasted_content id=\"a1\">\n\n\n<pasted_content id=\"b2\">\nsecond",
                "\n\n<pasted_content id=\"a1\">\nfirst\n</pasted_content id=\"a1\">\n\n\n<pasted_content id=\"b2\">\nsecond",
            ),
        ];
        for (name, text, expected) in rows {
            let row = serde_json::json!({"type":"user", "message":{"content":text}});
            assert_eq!(
                normalize_user_text(&user_text(Harness::Claude, &row).unwrap()),
                expected,
                "{name}"
            );
        }
    }

    /// A row reads as the typed command only when it is Claude Code's
    /// command record whole; any other text stays as written.
    #[test]
    fn claude_command_records_read_as_the_typed_command_only_when_whole() {
        let record = "<command-message>orch</command-message>\n<command-name>/orch</command-name>\n<command-args>oversee</command-args>";
        let rows = [
            ("with arguments", record.to_owned(), "/orch oversee"),
            (
                "no arguments",
                "<command-message>orch</command-message>\n<command-name>/orch</command-name>"
                    .to_owned(),
                "/orch",
            ),
            (
                "name unlike the message",
                record.replace("/orch<", "/other<"),
                "<command-message>orch</command-message>\n<command-name>/other</command-name>\n<command-args>oversee</command-args>",
            ),
            (
                "text after the record",
                format!("{record}\nmore"),
                "<command-message>orch</command-message>\n<command-name>/orch</command-name>\n<command-args>oversee</command-args>\nmore",
            ),
            (
                "text before the record",
                format!("typed {record}"),
                "typed <command-message>orch</command-message>\n<command-name>/orch</command-name>\n<command-args>oversee</command-args>",
            ),
            (
                "empty name",
                "<command-message></command-message>\n<command-name>/</command-name>".to_owned(),
                "<command-message></command-message>\n<command-name>/</command-name>",
            ),
        ];
        for (name, text, expected) in rows {
            let row = serde_json::json!({"type":"user", "message":{"content":text}});
            assert_eq!(
                normalize_user_text(&user_text(Harness::Claude, &row).unwrap()),
                expected,
                "{name}"
            );
        }
    }

    #[test]
    fn other_harnesses_keep_paste_wrapper_text() {
        let text = "\n\n<pasted_content id=\"634f\">\npasted\n</pasted_content id=\"634f\">\n";
        let rows = [
            (
                Harness::Codex,
                serde_json::json!({"type":"event_msg", "payload":{"type":"item_completed", "item":{"type":"UserMessage", "content":[{"type":"text", "text":text}]}}}),
            ),
            (
                Harness::Copilot,
                serde_json::json!({"type":"user.message", "data":{"content":text}}),
            ),
            (
                Harness::Pi,
                serde_json::json!({"type":"message", "message":{"role":"user", "content":[{"type":"text", "text":text}]}}),
            ),
        ];
        for (harness, row) in rows {
            assert_eq!(user_text(harness, &row).unwrap(), text, "{harness:?}");
        }
    }

    /// The sessions that appeared since the window opened are
    /// the leads for the cwd modified since then and absent from the
    /// baseline; a neighbour that stood before is excluded however recently
    /// it was written, and another cwd's session never counts.
    #[test]
    fn new_leads_are_those_absent_from_the_baseline_and_written_since() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let day = home.join("sessions").join("2026").join("10").join("26");
        fs::create_dir_all(&day).unwrap();
        let meta = |id: &str, cwd: &str| {
            format!(
                r#"{{"type":"session_meta","payload":{{"id":"{id}","cwd":"{cwd}","parent_thread_id":null,"source":"cli"}}}}"#
            )
        };
        let neighbour = day.join("rollout-a-N.jsonl");
        fs::write(&neighbour, meta("N", "/w")).unwrap();
        let Reading::Live(baseline) = lead_ids(Harness::Codex, home, Path::new("/w")) else {
            panic!("the baseline reads")
        };
        assert_eq!(baseline, vec!["N".to_owned()]);
        std::thread::sleep(std::time::Duration::from_millis(20));
        let since = SystemTime::now();
        // File stamps come from the kernel's coarse clock, which can trail
        // the precise one by a tick, so the writes follow a pause.
        std::thread::sleep(std::time::Duration::from_millis(20));
        // The neighbour takes a row after the window opened, so it is the
        // newest file; the runner's own file and another cwd's appear.
        let grown = format!("{}\n{}\n", meta("N", "/w"), r#"{"type":"x"}"#);
        fs::write(&neighbour, grown).unwrap();
        fs::write(day.join("rollout-b-R.jsonl"), meta("R", "/w")).unwrap();
        fs::write(day.join("rollout-c-O.jsonl"), meta("O", "/other")).unwrap();
        let leads = |baseline: &[String]| match new_leads(
            Harness::Codex,
            home,
            Path::new("/w"),
            since,
            baseline,
        ) {
            Reading::Live(found) => found.into_iter().map(|s| s.id).collect::<Vec<_>>(),
            other => panic!("the leads read: {other:?}"),
        };
        assert_eq!(leads(&baseline), vec!["R".to_owned()]);
        // With no baseline the neighbour counts too, and nothing tells them
        // apart.
        assert_eq!(leads(&[]).len(), 2);
        // Nothing has appeared when every lead stood in the baseline.
        assert!(leads(&["N".to_owned(), "R".to_owned()]).is_empty());
    }

    /// The file an id names, per harness, found by the id and never by the
    /// file's age: the newest file in the store is another session's and is
    /// not named; an absent file is `Gone`, never a neighbour's, so no
    /// delivery is confirmed on a subagent's or a neighbour's file.
    #[test]
    fn a_fixed_id_names_its_own_file_and_never_the_newest_one() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let cwd = Path::new("/w");
        let rows: [(Harness, &str, &str); 4] = [
            (
                Harness::Claude,
                "projects/-w/own.jsonl",
                "projects/-w/newer.jsonl",
            ),
            (
                Harness::Codex,
                "sessions/2026/10/26/rollout-a-own.jsonl",
                "sessions/2026/10/27/rollout-b-newer.jsonl",
            ),
            (
                Harness::Copilot,
                "session-state/own/workspace.yaml",
                "session-state/newer/workspace.yaml",
            ),
            (
                Harness::Pi,
                "sessions/--w--/2026-10-26T02-08-44-396Z_own.jsonl",
                "sessions/--w--/2026-10-27T02-08-44-396Z_newer.jsonl",
            ),
        ];
        for (harness, own, newer) in rows {
            assert_eq!(
                fixed_id_file(harness, home, cwd, "own"),
                Reading::Gone,
                "{harness:?}: nothing written yet"
            );
            let own_path = home.join(own);
            fs::create_dir_all(own_path.parent().unwrap()).unwrap();
            fs::write(&own_path, "{}\n").unwrap();
            std::thread::sleep(std::time::Duration::from_millis(20));
            let newer_path = home.join(newer);
            fs::create_dir_all(newer_path.parent().unwrap()).unwrap();
            fs::write(&newer_path, "{}\n").unwrap();
            assert_eq!(
                fixed_id_file(harness, home, cwd, "own"),
                Reading::Live(own_path.clone()),
                "{harness:?}: the id's own file"
            );
            assert_eq!(
                fixed_id_file(harness, home, cwd, "absent"),
                Reading::Gone,
                "{harness:?}: an id with no file"
            );
        }
        // A subagent's file under Claude's `subagents/` carries no id of
        // the lead's, whatever it is named.
        let sub = home.join("projects/-w/subagents/own.jsonl");
        fs::create_dir_all(sub.parent().unwrap()).unwrap();
        fs::write(&sub, "{}\n").unwrap();
        assert_eq!(
            fixed_id_file(Harness::Claude, home, cwd, "own"),
            Reading::Live(home.join("projects/-w/own.jsonl"))
        );
    }

    /// Every Claude lead for the cwd counts, oldest and newest alike, and a
    /// subagent's file under `subagents/` never does.
    #[test]
    fn claude_leads_are_every_lead_file_and_never_a_subagent_s() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir
            .path()
            .join("projects")
            .join(claude_slug(Path::new("/w")));
        fs::create_dir_all(project.join("subagents")).unwrap();
        let old = project.join("aaaa.jsonl");
        fs::write(&old, r#"{"type":"user","sessionId":"aaaa","cwd":"/w"}"#).unwrap();
        let sub = project.join("subagents").join("agent-x.jsonl");
        fs::write(&sub, r#"{"type":"user","sessionId":"sub","cwd":"/w"}"#).unwrap();
        let new = project.join("bbbb.jsonl");
        fs::write(&new, r#"{"type":"user","sessionId":"bbbb","cwd":"/w"}"#).unwrap();
        let Reading::Live(mut ids) = lead_ids(Harness::Claude, dir.path(), Path::new("/w")) else {
            panic!("the leads read")
        };
        ids.sort();
        assert_eq!(ids, vec!["aaaa".to_owned(), "bbbb".to_owned()]);
        assert!(
            identify(
                Harness::Claude,
                &sub,
                Some(Path::new("/w")),
                Written::Opened
            )
            .unwrap()
            .is_none()
        );
    }

    /// Pi resumes by file, which no record carries, so it reads absent.
    #[test]
    fn a_bound_session_is_read_by_its_path_and_owned_by_its_recorded_directory() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let cwd = Path::new("/w/KEN-7");
        let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let claude = home.join("projects").join(claude_slug(cwd));
        fs::create_dir_all(&claude).unwrap();
        fs::write(
            claude.join(format!("{id}.jsonl")),
            format!(r#"{{"type":"user","sessionId":"{id}","cwd":"/w/KEN-7"}}"#),
        )
        .unwrap();
        let day = home.join("sessions").join("2026").join("11").join("03");
        fs::create_dir_all(&day).unwrap();
        fs::write(
            day.join(format!("rollout-a-{id}.jsonl")),
            format!(
                r#"{{"type":"session_meta","payload":{{"id":"{id}","cwd":"/w/OTHER","parent_thread_id":null,"source":"cli"}}}}"#
            ),
        )
        .unwrap();
        let copilot = home.join("session-state").join(id);
        fs::create_dir_all(&copilot).unwrap();
        fs::write(
            copilot.join("workspace.yaml"),
            format!("id: {id}\ncwd: /w/KEN-7\n"),
        )
        .unwrap();
        fs::write(
            copilot.join("events.jsonl"),
            "{\"type\":\"user.message\"}\n",
        )
        .unwrap();
        assert_eq!(
            resume_owner(Harness::Claude, &home, cwd, id),
            Reading::Live(Some(cwd.to_path_buf()))
        );
        assert_eq!(
            resume_owner(Harness::Codex, &home, Path::new(""), id),
            Reading::Live(Some(PathBuf::from("/w/OTHER"))),
            "the rollout names the directory that owns it"
        );
        assert_eq!(
            resume_owner(Harness::Copilot, &home, Path::new(""), id),
            Reading::Live(Some(cwd.to_path_buf()))
        );
        assert_eq!(resume_owner(Harness::Pi, &home, cwd, id), Reading::Gone);
        assert_eq!(
            resume_owner(Harness::Codex, &home, Path::new(""), "other-id"),
            Reading::Gone
        );
        fs::write(
            day.join("rollout-b-child.jsonl"),
            r#"{"type":"session_meta","payload":{"id":"child","cwd":"/w/KEN-7","parent_thread_id":"L","source":"cli"}}"#,
        )
        .unwrap();
        assert_eq!(
            resume_owner(Harness::Codex, &home, Path::new(""), "child"),
            Reading::Gone,
            "a file that is no lead is no session to resume"
        );
        fs::write(claude.join("short.jsonl"), "{}\n").unwrap();
        assert_eq!(
            resume_owner(Harness::Claude, &home, cwd, "short"),
            Reading::Live(None),
            "a Claude file with no row yet is the directory's own"
        );
    }
}
