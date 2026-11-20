//! `agent-runtime session model` through the executable, over session
//! records each row plants under its own root: the record a harness writes
//! for the session, the launch's declaration in the environment, and the
//! harness home the record is found under.

#[path = "isolation.rs"]
mod isolation;

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use isolation::*;

/// One row's world: what it plants and the answer it expects.
struct Row {
    name: &'static str,
    harness: &'static str,
    session: &'static str,
    /// The variables the row's child gets beyond the cleared environment,
    /// each a path under the root where it starts with `/`.
    env: &'static [(&'static str, &'static str)],
    /// Removed after the isolation's own (`HOME`).
    unset: &'static [&'static str],
    /// The `--transcript` the row names, under the root.
    transcript: Option<&'static str>,
    plant: fn(&Path),
    lines: [&'static str; 3],
    exit: i32,
}

const LAUNCH: [(&str, &str); 2] = [
    ("AGENT_RUNTIME_LAUNCH_MODEL", "gpt-6.1-launch"),
    ("AGENT_RUNTIME_LAUNCH_AGENT", "KEN-7"),
];

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// A rollout in the shape measured on Codex 0.167.2 for session `x1`: one
/// `turn_context` naming `gpt-6.1-sol` at effort `high`, near the head of
/// four megabytes of other lines.
fn measured_rollout(root: &Path) {
    let pad = |kind: &str| {
        format!(
            r#"{{"type":"{kind}","payload":{{"text":"{}"}}}}"#,
            "x".repeat(4096)
        )
    };
    let mut lines = vec![r#"{"type":"session_meta","payload":{"id":"x1","cwd":"/w"}}"#.to_owned()];
    lines.extend((0..32).map(|_| pad("response_item")));
    lines.push(r#"{"type":"turn_context","payload":{"approval_policy":"never","cwd":"/w","effort":"high","model":"gpt-6.1-sol","summary":"auto","turn_id":"t1"}}"#.to_owned());
    lines.extend((0..1000).map(|_| pad("event_msg")));
    lines.push(r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":264601},"model_context_window":400000}}}"#.to_owned());
    write(
        &root.join("codex/sessions/2026/11/12/rollout-2026-11-12T20-22-41-x1.jsonl"),
        &lines.join("\n"),
    );
}

fn claude_transcript(root: &Path) {
    write(
        &root.join("claude.jsonl"),
        r#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":7}}}"#,
    );
}

fn pi_session_without_usage(root: &Path) {
    write(
        &root.join("pi.jsonl"),
        r#"{"type":"message","message":{"role":"user","content":"hi"}}"#,
    );
}

/// A fresh status-line record for Copilot session `c1` under the account
/// directory `root/copilot`, in the form `copilot-statusline` writes.
fn copilot_record(root: &Path) {
    let home = root.join("copilot");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let record = serde_json::json!({"session_id": "c1", "transcript_path": "",
        "copilot_home": home.display().to_string(), "written_at": now,
        "status": {"model": {"id": "claude-opus-5"},
            "context_window": {"current_context_tokens": 1000, "context_window_size": 200_000}}});
    write(&home.join("lane-status/c1.json"), &record.to_string());
}

fn copilot_home_only(root: &Path) {
    std::fs::create_dir_all(root.join("copilot")).unwrap();
}

fn codex_store_without_the_session(root: &Path) {
    std::fs::create_dir_all(root.join("codex/sessions/2026/11/12")).unwrap();
}

fn codex_store_unlisted(root: &Path) {
    let store = root.join("codex/sessions");
    std::fs::create_dir_all(&store).unwrap();
    std::fs::set_permissions(&store, std::fs::Permissions::from_mode(0o000)).unwrap();
}

fn a_directory_as_transcript(root: &Path) {
    std::fs::create_dir_all(root.join("claude.jsonl")).unwrap();
}

fn nothing(_: &Path) {}

const ROWS: &[Row] = &[
    Row {
        name: "the codex session's own turn context names both before the tail",
        harness: "codex",
        session: "x1",
        env: &[("CODEX_HOME", "/codex"), LAUNCH[0], LAUNCH[1]],
        unset: &[],
        transcript: None,
        plant: measured_rollout,
        lines: [
            "model=gpt-6.1-sol source=session",
            "effort=high source=session",
            "agent=KEN-7 source=launch",
        ],
        exit: 0,
    },
    Row {
        name: "a claude transcript names the model, never the effort",
        harness: "claude",
        session: "k1",
        env: &[LAUNCH[0], LAUNCH[1]],
        unset: &[],
        transcript: Some("claude.jsonl"),
        plant: claude_transcript,
        lines: [
            "model=claude-opus-5-5 source=session",
            "session-effort-unrecorded harness=claude session=k1",
            "agent=KEN-7 source=launch",
        ],
        exit: 1,
    },
    Row {
        name: "a pi file naming no model takes the launch's, and no effort",
        harness: "pi",
        session: "p1",
        env: &[LAUNCH[0]],
        unset: &[],
        transcript: Some("pi.jsonl"),
        plant: pi_session_without_usage,
        lines: [
            "model=gpt-6.1-launch source=launch",
            "session-effort-unrecorded harness=pi session=p1",
            "session-agent-unrecorded harness=pi session=p1",
        ],
        exit: 1,
    },
    Row {
        name: "a copilot status-line record names the model",
        harness: "copilot",
        session: "c1",
        env: &[("COPILOT_HOME", "/copilot")],
        unset: &[],
        transcript: None,
        plant: copilot_record,
        lines: [
            "model=claude-opus-5 source=session",
            "session-effort-unrecorded harness=copilot session=c1",
            "session-agent-unrecorded harness=copilot session=c1",
        ],
        exit: 1,
    },
    Row {
        name: "a missing copilot record is unread, never the launch's model",
        harness: "copilot",
        session: "c1",
        env: &[("COPILOT_HOME", "/copilot"), LAUNCH[0], LAUNCH[1]],
        unset: &[],
        transcript: None,
        plant: copilot_home_only,
        lines: [
            "session-record-unread harness=copilot session=c1 cause=missing",
            "session-effort-unrecorded harness=copilot session=c1",
            "agent=KEN-7 source=launch",
        ],
        exit: 2,
    },
    Row {
        name: "a codex session with no rollout is absent",
        harness: "codex",
        session: "x1",
        env: &[("CODEX_HOME", "/codex"), LAUNCH[0]],
        unset: &[],
        transcript: None,
        plant: codex_store_without_the_session,
        lines: [
            "session-file-absent harness=codex session=x1",
            "session-file-absent harness=codex session=x1",
            "session-agent-unrecorded harness=codex session=x1",
        ],
        exit: 2,
    },
    Row {
        name: "a codex store that cannot be listed is unreadable",
        harness: "codex",
        session: "x1",
        env: &[("CODEX_HOME", "/codex"), LAUNCH[0]],
        unset: &[],
        transcript: None,
        plant: codex_store_unlisted,
        lines: [
            "session-file-unreadable harness=codex session=x1 cause=",
            "session-file-unreadable harness=codex session=x1 cause=",
            "session-agent-unrecorded harness=codex session=x1",
        ],
        exit: 2,
    },
    Row {
        name: "a transcript that cannot be read is unreadable",
        harness: "claude",
        session: "k1",
        env: &[LAUNCH[0]],
        unset: &[],
        transcript: Some("claude.jsonl"),
        plant: a_directory_as_transcript,
        lines: [
            "session-file-unreadable harness=claude session=k1 cause=",
            "session-effort-unrecorded harness=claude session=k1",
            "session-agent-unrecorded harness=claude session=k1",
        ],
        exit: 2,
    },
    Row {
        name: "no harness home and no HOME names no record",
        harness: "codex",
        session: "x1",
        env: &[LAUNCH[0]],
        unset: &["HOME"],
        transcript: None,
        plant: nothing,
        lines: [
            "harness-home-unnamed harness=codex session=x1",
            "harness-home-unnamed harness=codex session=x1",
            "session-agent-unrecorded harness=codex session=x1",
        ],
        exit: 2,
    },
];

/// Each row's three lines and exit. A line ending in `cause=` is matched as a
/// prefix: the cause is the operating system's words.
#[test]
fn session_model_answers_from_the_session_first_and_tells_a_refusal_from_an_unread_record() {
    for row in ROWS {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let work = root.join("work");
        std::fs::create_dir_all(&work).unwrap();
        (row.plant)(&root);
        let mut command = program(env!("CARGO_BIN_EXE_agent-runtime"));
        command
            .current_dir(&work)
            .env("HOME", root.join("home"))
            .args(["session", "model", "--harness", row.harness])
            .args(["--session", row.session]);
        for (name, value) in row.env {
            match value.strip_prefix('/') {
                Some(under) => command.env(name, root.join(under)),
                None => command.env(name, value),
            };
        }
        for name in row.unset {
            command.env_remove(name);
        }
        if let Some(transcript) = row.transcript {
            command.arg("--transcript").arg(root.join(transcript));
        }
        let out = command.output().unwrap();
        let store = root.join("codex/sessions");
        if store.is_dir() {
            std::fs::set_permissions(&store, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        let matched = lines.len() == 3
            && row.lines.iter().zip(&lines).all(|(want, got)| {
                if want.ends_with("cause=") {
                    got.starts_with(want) && got.len() > want.len()
                } else {
                    got == want
                }
            });
        assert!(
            matched && out.status.code() == Some(row.exit),
            "{}: {:?} exit {:?}\n{}",
            row.name,
            lines,
            out.status.code(),
            stderr(&out)
        );
    }
}
