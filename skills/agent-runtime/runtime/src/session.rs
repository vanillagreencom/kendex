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

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::harness::Harness;

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

fn mtime(path: &Path) -> SystemTime {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH)
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
            let events = file.with_file_name("events.jsonl");
            let has_events = fs::metadata(&events).map(|m| m.len() > 0).unwrap_or(false);
            if !has_events {
                return Ok(None);
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

fn candidates(harness: Harness, home: &Path, cwd: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    match harness {
        Harness::Claude => {
            let dir = home.join("projects").join(claude_slug(cwd));
            if let Ok(entries) = fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().is_some_and(|e| e == "jsonl") && path.is_file() {
                        files.push(path);
                    }
                }
            }
        }
        Harness::Codex => {
            let root = home.join("sessions");
            walk(&root, &mut files, 4)?;
            files.retain(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(".jsonl"))
            });
        }
        Harness::Pi => {
            let dir = home.join("sessions").join(pi_slug(cwd));
            if let Ok(entries) = fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().is_some_and(|e| e == "jsonl") && path.is_file() {
                        files.push(path);
                    }
                }
            }
        }
        Harness::Copilot => {
            let root = home.join("session-state");
            if let Ok(entries) = fs::read_dir(&root) {
                for entry in entries.flatten() {
                    let ws = entry.path().join("workspace.yaml");
                    if ws.is_file() {
                        files.push(ws);
                    }
                }
            }
        }
    }
    Ok(files)
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) -> Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(Error::io("read-dir", dir, e)),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if depth > 0 {
                walk(&path, out, depth - 1)?;
            }
        } else if path.is_file() {
            out.push(path);
        }
    }
    Ok(())
}

/// The newest lead session the harness recorded for `cwd` under `home`.
pub fn find_lead(harness: Harness, home: &Path, cwd: &Path) -> Result<Option<SessionRef>> {
    let mut best: Option<(SystemTime, SessionRef)> = None;
    for file in candidates(harness, home, cwd)? {
        if let Some(found) = identify(harness, &file, Some(cwd))? {
            let at = mtime(&file);
            if best.as_ref().is_none_or(|(t, _)| at > *t) {
                best = Some((at, found));
            }
        }
    }
    Ok(best.map(|(_, s)| s))
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
        assert!(
            find_lead(Harness::Copilot, home, Path::new("/w"))
                .unwrap()
                .is_none()
        );
        fs::write(s.join("events.jsonl"), "{\"type\":\"x\"}\n").unwrap();
        assert_eq!(
            find_lead(Harness::Copilot, home, Path::new("/w"))
                .unwrap()
                .unwrap()
                .id,
            "S1"
        );
    }

    #[test]
    fn the_newest_claude_lead_for_the_cwd_wins_and_subagents_are_skipped() {
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
        std::thread::sleep(std::time::Duration::from_millis(20));
        let new = project.join("bbbb.jsonl");
        fs::write(&new, r#"{"type":"user","sessionId":"bbbb","cwd":"/w"}"#).unwrap();
        let found = find_lead(Harness::Claude, dir.path(), Path::new("/w"))
            .unwrap()
            .unwrap();
        assert_eq!(found.id, "bbbb");
    }
}
