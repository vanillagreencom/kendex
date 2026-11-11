//! Process-protocol tests of the `orch-runtime` executable: they run the
//! built binary against the released-shape fixtures beside this file.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests run the built binary"
)]

use std::fs;
use std::path::{Path, PathBuf};
mod support;

use std::process::Output;

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const FLEET: &str = include_str!("fixtures/workflow-state-oversee.json");
const NEWER: &str = include_str!("fixtures/workflow-state-newer.json");

fn run(args: &[&str], paths: &[&Path]) -> Output {
    let mut command = support::isolated();
    command.args(args);
    for path in paths {
        command.arg(path);
    }
    command.output().unwrap()
}

fn reply(out: &Output) -> serde_json::Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

fn first_stderr_line(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn version_prints_the_protocol_reply() {
    let out = run(&["version"], &[]);
    assert!(out.status.success());
    let answer = reply(&out);
    assert_eq!(answer["protocol"], "orch-runtime-v1");
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["result"]["protocol"], "orch-runtime-v1");
    assert_eq!(
        answer["result"]["agent_runtime_protocol"],
        "agent-runtime-v1"
    );
}

#[test]
fn inspect_reads_an_unstamped_file_as_an_item_without_writing() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let out = run(&["state", "inspect", "--file"], &[&path]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let answer = reply(&out);
    assert_eq!(answer["ok"], true);
    let result = &answer["result"];
    assert_eq!(result["kind"], "item");
    assert_eq!(result["state"]["issue_id"], "KEN-4687");
    assert_eq!(result["state"]["dev_round_id"], "1769600000123456789-1837");
    assert_eq!(fs::read_to_string(&path).unwrap(), ITEM);
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

/// Unparsable bytes are `json-invalid`; a shape this build cannot read is
/// `record-shape` with the field named, never `json-invalid`, so a caller
/// routing on the key tells a corrupt file from an older shape; a file
/// stamped with record meta keys is `record-stamped` naming the key.
#[test]
fn inspect_refuses_a_stamped_file_and_malformed_input_without_touching_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let rows: [(&str, String, &str, Option<&str>); 5] = [
        (
            "workflow-state-KEN-9999.json",
            NEWER.to_owned(),
            "record-stamped",
            Some("key=record_version"),
        ),
        (
            "workflow-state-KEN-7.json",
            "{\"issue_id\": \"KEN-7\",".to_owned(),
            "json-invalid",
            None,
        ),
        (
            "workflow-state-KEN-8.json",
            "\"a string\"".to_owned(),
            "record-shape",
            Some("field= reason=not-object"),
        ),
        (
            "workflow-state-KEN-6.json",
            ITEM.replacen("\"start\": 1769600000", "\"start\": \"soon\"", 1),
            "record-shape",
            Some("field=stages reason=type-mismatch"),
        ),
        (
            "workflow-state-oversee.json",
            FLEET.replacen("\"done\"", "\"closing\"", 1),
            "record-shape",
            Some("field=lanes reason=type-mismatch"),
        ),
    ];
    for (name, text, key, fields) in rows {
        let path = write(dir.path(), name, &text);
        let out = run(&["state", "inspect", "--file"], &[&path]);
        assert_eq!(out.status.code(), Some(1), "{name}");
        let line = first_stderr_line(&out);
        assert!(
            line.starts_with(&format!("orch-runtime: {key} path=")),
            "{name}: {line}"
        );
        if let Some(fields) = fields {
            assert!(line.ends_with(fields), "{name}: {line}");
        }
        let answer = reply(&out);
        assert_eq!(answer["protocol"], "orch-runtime-v1");
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["refusal"]["key"], key, "{name}");
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{name}");
    }
}

/// A usage error is clap's, not a refusal: the keyed usage line, clap's
/// message, exit 2 and no JSON reply, as agent-runtime answers one.
#[test]
fn a_usage_error_prints_the_usage_key_exits_2_and_gives_no_reply() {
    let rows: [&[&str]; 3] = [
        &["state", "inspect"],
        &["op", "--file", "x.json"],
        &["frobnicate"],
    ];
    for args in rows {
        let out = run(args, &[]);
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert_eq!(first_stderr_line(&out), "orch-runtime: usage", "{args:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.lines().count() >= 2, "{args:?}: {stderr}");
        assert!(out.stdout.is_empty(), "{args:?}");
    }
    let out = run(&["--help"], &[]);
    assert!(out.status.success());
    assert!(out.stderr.is_empty());
}

/// A key a consumer's settings still set that no verb reads is named on
/// stderr, once per load, with the key that does its job where one does,
/// whether a settings file or the caller's environment sets it; the verb
/// still runs. A key that was never a setting, or one set empty, gets no
/// notice.
#[test]
fn a_retired_setting_still_set_is_named_once_and_the_verb_runs() {
    let notices = |out: &Output| -> Vec<String> {
        assert!(out.status.success(), "{}", support::stderr(out));
        support::stderr(out)
            .lines()
            .filter(|line| line.starts_with("settings-retired "))
            .map(str::to_owned)
            .collect()
    };
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("project");
    fs::create_dir_all(&project).unwrap();
    write(
        &project,
        "kendex.settings.toml",
        "[env]\nORCH_WORKTREE_BIN = \"/opt/worktree\"\nORCH_OVERSEER_SEAT_RESERVE_PCT = \"25\"\nORCH_ENV = \"ci\"\n",
    );
    let from_file = support::program(support::binary())
        .current_dir(&project)
        .args(["state", "path", "--fleet"])
        .output()
        .unwrap();
    assert_eq!(
        notices(&from_file),
        [
            "settings-retired key=ORCH_OVERSEER_SEAT_RESERVE_PCT stand-in=ORCH_OVERSEER_HEADROOM_PCT",
            "settings-retired key=ORCH_WORKTREE_BIN stand-in=WORKTREE_CLI",
        ]
    );
    let rows: [(&str, &str, Option<&str>); 12] = [
        (
            "CI_WAIT_NO_CHECKS_GRACE",
            "600",
            Some("settings-retired key=CI_WAIT_NO_CHECKS_GRACE"),
        ),
        (
            "ORCH_LANE_SSH_PROMPT_SECS",
            "60",
            Some("settings-retired key=ORCH_LANE_SSH_PROMPT_SECS"),
        ),
        (
            "ORCH_MERGE_BYPASS",
            "fast-path",
            Some("settings-retired key=ORCH_MERGE_BYPASS"),
        ),
        (
            "ORCH_OVERSEER_SEAT_RESERVE_PCT",
            "25",
            Some(
                "settings-retired key=ORCH_OVERSEER_SEAT_RESERVE_PCT stand-in=ORCH_OVERSEER_HEADROOM_PCT",
            ),
        ),
        (
            "ORCH_OVERSEER_SUCCESSOR_ACCOUNTS",
            "1",
            Some("settings-retired key=ORCH_OVERSEER_SUCCESSOR_ACCOUNTS"),
        ),
        (
            "ORCH_OVERSEER_SYNC_TIMEOUT_S",
            "60",
            Some("settings-retired key=ORCH_OVERSEER_SYNC_TIMEOUT_S"),
        ),
        (
            "ORCH_WORKTREE_BIN",
            "/opt/worktree",
            Some("settings-retired key=ORCH_WORKTREE_BIN stand-in=WORKTREE_CLI"),
        ),
        ("ORCH_WORKTREE_BIN", "", None),
        ("ORCH_ENV", "ci", None),
        ("ORCH_THREAD_PAGE_MAX", "50", None),
        ("ORCH_THREADS_QUERY", "query", None),
        ("ORCH_OVERSEER_HEADROOM_PCT", "5", None),
    ];
    for (key, value, want) in rows {
        let out = support::isolated()
            .args(["state", "path", "--fleet"])
            .env(key, value)
            .output()
            .unwrap();
        assert_eq!(
            notices(&out),
            want.into_iter().collect::<Vec<_>>(),
            "{key}={value:?}"
        );
    }
}

#[test]
fn a_missing_file_refuses_as_record_missing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workflow-state-KEN-1.json");
    let out = run(&["state", "inspect", "--file"], &[&path]);
    assert_eq!(out.status.code(), Some(1));
    assert!(first_stderr_line(&out).starts_with("orch-runtime: record-missing path="));
    assert_eq!(reply(&out)["refusal"]["key"], "record-missing");
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}

/// An operation patches only the keys it writes and adds no meta keys.
#[test]
fn op_applies_a_request_and_prints_the_committed_transition() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let request = write(
        dir.path(),
        "begin.json",
        r#"{"op": "begin-round", "kind": "dev"}"#,
    );
    let out = run(
        &["op", "--file"],
        &[&path, Path::new("--request"), &request],
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let answer = reply(&out);
    let result = &answer["result"];
    assert_eq!(result["kind"], "item");
    assert_eq!(result["report"]["op"], "begin-round");
    assert_eq!(
        result["report"]["superseded"],
        serde_json::json!(["1769600000123456789-1837"])
    );
    let round_id = result["report"]["round_id"].as_str().unwrap().to_owned();
    let state: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let before: serde_json::Value = serde_json::from_str(ITEM).unwrap();
    assert!(state.get("record_version").is_none());
    assert!(state.get("revision").is_none());
    assert_eq!(state["dev_round_id"], round_id);
    assert_eq!(state["stages"][1]["round_id"], round_id);
    assert_eq!(state["stages"][0]["superseded"], true);
    let keys: Vec<&String> = state.as_object().unwrap().keys().collect();
    let before_keys: Vec<&String> = before.as_object().unwrap().keys().collect();
    assert_eq!(keys, before_keys, "the key sequence is the file's");
    // The released fields the type does not name are still there.
    assert_eq!(
        state["round_prunes"]["1769600000123456789-1837"]["action"],
        "below-mark"
    );

    let bad = write(
        dir.path(),
        "bad.json",
        r#"{"op": "launch-lane", "item": "KEN-1"}"#,
    );
    let out = run(&["op", "--file"], &[&path, Path::new("--request"), &bad]);
    assert_eq!(out.status.code(), Some(1));
    let line = first_stderr_line(&out);
    assert_eq!(
        line,
        format!("orch-runtime: request-invalid path={}", bad.display()),
        "the parser's message is not a field"
    );

    let fleet_only = write(
        dir.path(),
        "close.json",
        r#"{"op": "close-owned-resources", "item": "KEN-1"}"#,
    );
    let out = run(
        &["op", "--file"],
        &[&path, Path::new("--request"), &fleet_only],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "op-kind");
}

/// Decision 52: `record-verification` through the binary writes
/// `.verification` and reports it; a word that is no verdict refuses on the
/// keyed line with the word, and the file keeps its bytes.
#[test]
fn op_records_a_verification_verdict_and_refuses_a_word_that_is_none() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let head = "f".repeat(40);
    let request = write(
        dir.path(),
        "verify.json",
        &format!(
            r#"{{"op": "record-verification", "head": "{head}", "verdict": "none", "reason": "no CI configured: no active workflows and no required checks on main", "source": "ci-wait --required-only"}}"#
        ),
    );
    let out = run(
        &["op", "--file"],
        &[&path, Path::new("--request"), &request],
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = &reply(&out)["result"]["report"];
    assert_eq!(report["op"], "record-verification");
    assert_eq!(report["verdict"], "none");
    assert_eq!(report["replaced"], false);
    let state: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["verification"]["head"], head);
    assert_eq!(state["verification"]["verdict"], "none");
    assert_eq!(state["verification"]["source"], "ci-wait --required-only");
    assert!(state["verification"]["at"].as_str().is_some());

    let text = fs::read_to_string(&path).unwrap();
    let pending = write(
        dir.path(),
        "pending.json",
        &format!(
            r#"{{"op": "record-verification", "head": "{head}", "verdict": "pending", "reason": "checks still running", "source": "ci-wait --required-only"}}"#
        ),
    );
    let out = run(
        &["op", "--file"],
        &[&path, Path::new("--request"), &pending],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        first_stderr_line(&out),
        "orch-runtime: verdict-invalid verdict=pending"
    );
    assert_eq!(reply(&out)["refusal"]["key"], "verdict-invalid");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
}
