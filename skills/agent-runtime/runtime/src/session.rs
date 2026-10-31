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
//!   `id:` and `cwd:` lines, and `events.jsonl` beside it.
//! - Pi: `<sessions root>/<cwd slug>/<stamp>_<id>.jsonl`, whose first row
//!   is `{"type":"session","id":...,"cwd":...}`.
//!
//! A session is bound by the id its launch fixed, or as the one lead that
//! appeared for its directory after the launch and stood in no baseline
//! read before it (decision 65). No reader here picks a file by its age: a
//! lookup that can name a neighbour's file is not an API (decision 92).
//!
//! The same files record each user turn, which is how a delivery is
//! confirmed: a turn the harness itself wrote down arrived, whatever the
//! pane paste returned. The shapes are the native probe's
//! (`tmp/orch-rebuild/native/run2/<harness>/home`):
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
    Some(match harness {
        Harness::Claude => home.join(".claude"),
        Harness::Codex => home.join(".codex"),
        Harness::Copilot => home.join(".copilot"),
        Harness::Pi => home.join(".pi").join("agent"),
    })
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

/// Whether the destination home holds a session with the fixed id `id` for
/// `cwd`, read three-valued so a relaunch tells absent from unreadable
/// (decision 115 (G)). `Live(())` is present, `Gone` absent, `Unreadable`
/// a read that failed. Every resumable harness has a lookup: Claude by the
/// file its fixed id names; Codex by the rollout under its store whose name
/// ends in the id; Copilot by its session-state directory for the id; Pi
/// resumes by file, not id, so it reads absent and the relaunch starts
/// fresh.
pub fn resume_present(harness: Harness, home: &Path, cwd: &Path, id: &str) -> Reading<()> {
    match harness {
        Harness::Claude => {
            let Some(file) = fixed_file(harness, home, cwd, id) else {
                return Reading::Gone;
            };
            match fs::metadata(&file) {
                Ok(_) => Reading::Live(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
                Err(_) => Reading::Unreadable {
                    cause: STORE_UNREADABLE.cause,
                },
            }
        }
        Harness::Codex => {
            // The id is the tail of the rollout file name
            // `rollout-<stamp>-<id>.jsonl`, under `sessions/YYYY/MM/DD/`. The
            // store's root is read three-valued through the one listing
            // (decision 120, L2): no root is a cold home, an absent session; a
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
            if found.iter().any(|c| {
                c.path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(&suffix))
            }) {
                Reading::Live(())
            } else {
                Reading::Gone
            }
        }
        Harness::Copilot => {
            let dir = home.join("session-state").join(id);
            match fs::metadata(dir.join("workspace.yaml")) {
                Ok(_) => Reading::Live(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
                Err(_) => Reading::Unreadable {
                    cause: STORE_UNREADABLE.cause,
                },
            }
        }
        Harness::Pi => Reading::Gone,
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

/// Read the identity a session file carries, or `None` when the file is not
/// a lead session for `cwd` (or any cwd when `cwd` is `None`).
pub fn identify(harness: Harness, file: &Path, cwd: Option<&Path>) -> Result<Option<SessionRef>> {
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
            // A session with no event yet is not a lead; an events file
            // that cannot be read is no evidence of either (decision 95).
            let events = file.with_file_name("events.jsonl");
            match fs::metadata(&events) {
                Ok(meta) if meta.len() > 0 => {}
                Ok(_) => return Ok(None),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(Error::io("stat", &events, e)),
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
    let rows_file = match harness {
        Harness::Copilot => file.with_file_name("events.jsonl"),
        Harness::Claude | Harness::Codex | Harness::Pi => file.to_path_buf(),
    };
    let f = match fs::File::open(&rows_file) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(Error::io("open", &rows_file, e)),
    };
    let mut turns = 0;
    for line in BufReader::new(f).lines() {
        let line = line.map_err(|e| Error::io("read", &rows_file, e))?;
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if is_user_turn(harness, &row) {
            turns += 1;
        }
    }
    Ok(turns)
}

fn is_user_turn(harness: Harness, row: &Value) -> bool {
    let kind = row.get("type").and_then(Value::as_str);
    match harness {
        Harness::Claude => {
            kind == Some("user")
                && row.get("isSidechain").and_then(Value::as_bool) != Some(true)
                && row
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .is_some_and(Value::is_string)
        }
        Harness::Codex => {
            kind == Some("event_msg")
                && row.get("payload").is_some_and(|p| {
                    p.get("type").and_then(Value::as_str) == Some("item_completed")
                        && p.get("item")
                            .and_then(|i| i.get("type"))
                            .and_then(Value::as_str)
                            == Some("UserMessage")
                })
        }
        Harness::Copilot => kind == Some("user.message"),
        Harness::Pi => {
            kind == Some("message")
                && row
                    .get("message")
                    .and_then(|m| m.get("role"))
                    .and_then(Value::as_str)
                    == Some("user")
        }
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
/// bound to its neighbour (decision 95). `Gone` is a directory that does
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
/// stood before (decision 65). `Gone` is a store with no root for the cwd,
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
        match identify(harness, &candidate.path, Some(cwd)) {
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

/// The lead sessions for `cwd` under `home` that appeared since a launch's
/// window opened: modified at or after `since` and absent from the
/// `baseline` read before the window opened. One is the launch's own; two
/// or more cannot be told apart, and none has appeared yet. A set is read
/// whole or not at all: any candidate that could not be read makes the
/// reading `Unreadable`, so one readable lead beside an unreadable one binds
/// nothing (decision 95).
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
        match identify(harness, &candidate.path, Some(cwd)) {
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
    fn slugs_follow_each_store_spelling() {
        assert_eq!(
            claude_slug(Path::new("/home/x/dev/.worktrees/k")),
            "-home-x-dev--worktrees-k"
        );
        assert_eq!(
            pi_slug(Path::new("/home/x/dev/kendex")),
            "--home-x-dev-kendex--"
        );
    }

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
            identify(Harness::Codex, &lead, Some(Path::new("/w")))
                .unwrap()
                .unwrap()
                .id,
            "L"
        );
        assert!(
            identify(Harness::Codex, &child, Some(Path::new("/w")))
                .unwrap()
                .is_none()
        );
        assert!(
            identify(Harness::Codex, &lead, Some(Path::new("/other")))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_copilot_session_needs_events_before_it_counts() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("session-state").join("S1");
        fs::create_dir_all(&s).unwrap();
        fs::write(s.join("workspace.yaml"), "id: S1\ncwd: /w\n").unwrap();
        let home = dir.path();
        assert_eq!(
            lead_ids(Harness::Copilot, home, Path::new("/w")),
            Reading::Live(Vec::new())
        );
        fs::write(s.join("events.jsonl"), "{\"type\":\"x\"}\n").unwrap();
        assert_eq!(
            lead_ids(Harness::Copilot, home, Path::new("/w")),
            Reading::Live(vec!["S1".to_owned()])
        );
    }

    /// Decision 108 (8): a read that fails is `Unreadable`, never a candidate
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
        assert!(
            matches!(
                fs::read_dir(&dark),
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied
            ),
            "the fixture needs a directory this process cannot enter; a root run reads everything"
        );
        const UNREADABLE: &str = "session-store-unreadable";
        assert_eq!(
            lead_ids(Harness::Copilot, home, cwd),
            Reading::Unreadable { cause: UNREADABLE }
        );
        assert_eq!(
            new_leads(Harness::Copilot, home, cwd, SystemTime::UNIX_EPOCH, &[]),
            Reading::Unreadable { cause: UNREADABLE },
            "one readable lead beside an unreadable directory binds nothing"
        );
        fs::set_permissions(&dark, fs::Permissions::from_mode(0o755)).unwrap();
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
        assert_eq!(
            lead_ids(Harness::Codex, home, cwd),
            Reading::Unreadable { cause: UNREADABLE }
        );
        fs::set_permissions(&month, fs::Permissions::from_mode(0o755)).unwrap();
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
        }
        // A session whose file is not written yet has no turns.
        assert_eq!(
            user_turns(Harness::Claude, &dir.path().join("none.jsonl")).unwrap(),
            0
        );
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

    /// Decision 65: the sessions that appeared since the window opened are
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
            identify(Harness::Claude, &sub, Some(Path::new("/w")))
                .unwrap()
                .is_none()
        );
    }
}
