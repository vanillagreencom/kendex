//! Process-protocol tests of the `orch-runtime` executable: they run the
//! built binary against the legacy-shaped fixtures beside this file.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const FLEET: &str = include_str!("fixtures/workflow-state-oversee.json");
const NEWER: &str = include_str!("fixtures/workflow-state-newer.json");

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_orch-runtime"))
}

fn run(args: &[&str], paths: &[&Path]) -> Output {
    let mut command = Command::new(binary());
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
    assert_eq!(answer["result"]["record_version"], 1);
}

#[test]
fn inspect_reads_a_legacy_file_as_legacy_without_writing() {
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
    assert_eq!(result["stamp"]["kind"], "legacy");
    assert_eq!(result["state"]["issue_id"], "KEN-4687");
    assert_eq!(result["state"]["dev_round_id"], "1769600000123456789-1837");
    assert_eq!(fs::read_to_string(&path).unwrap(), ITEM);
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn migrate_stamps_a_legacy_fleet_file_and_keeps_the_original_beside_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-oversee.json", FLEET);
    let out = run(&["state", "migrate", "--file"], &[&path]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let answer = reply(&out);
    let result = &answer["result"];
    assert_eq!(result["kind"], "fleet");
    assert_eq!(result["migrated"], true);
    assert_eq!(result["stamp"]["record_version"], 1);
    assert_eq!(result["stamp"]["revision"], 1);
    let original = PathBuf::from(result["original"].as_str().unwrap());
    assert_eq!(
        original,
        dir.path().join("workflow-state-oversee.json.pre-migration")
    );
    assert_eq!(fs::read_to_string(&original).unwrap(), FLEET);

    let stamped: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let before: serde_json::Value = serde_json::from_str(FLEET).unwrap();
    assert_eq!(stamped["record_version"], 1);
    assert_eq!(stamped["revision"], 1);
    let keys: Vec<&String> = stamped.as_object().unwrap().keys().collect();
    assert_eq!(keys[0], "record_version");
    assert_eq!(keys[1], "revision");
    let before_keys: Vec<&String> = before.as_object().unwrap().keys().collect();
    assert_eq!(keys[2..].to_vec(), before_keys);
    for (key, value) in before.as_object().unwrap() {
        assert_eq!(&stamped[key], value, "{key}");
    }

    let out = run(&["state", "inspect", "--file"], &[&path]);
    let answer = reply(&out);
    assert_eq!(answer["result"]["stamp"]["kind"], "stamped");
    assert_eq!(answer["result"]["stamp"]["revision"], 1);
    assert_eq!(answer["result"]["state"]["overseer"]["generation"], 3);

    // Running it again changes nothing and reports so.
    let out = run(&["state", "migrate", "--file"], &[&path]);
    assert!(out.status.success());
    let answer = reply(&out);
    assert_eq!(answer["result"]["migrated"], false);
    assert!(answer["result"].get("original").is_none());
    assert_eq!(fs::read_to_string(&original).unwrap(), FLEET);
}

/// Unparsable bytes are `json-invalid`; a shape this build cannot read is
/// `record-shape` with the field named, never `json-invalid`, so a caller
/// routing on the key tells a corrupt file from an older shape.
#[test]
fn migrate_refuses_a_newer_version_and_malformed_input_without_touching_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let rows: [(&str, String, &str, Option<&str>); 5] = [
        (
            "workflow-state-KEN-9999.json",
            NEWER.to_owned(),
            "record-version",
            None,
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
        let out = run(&["state", "migrate", "--file"], &[&path]);
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
        assert!(
            !dir.path().join(format!("{name}.pre-migration")).exists(),
            "{name}"
        );
    }
    let out = run(
        &["state", "inspect", "--file"],
        &[&dir.path().join("workflow-state-KEN-9999.json")],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "record-version");
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

#[test]
fn a_missing_file_refuses_as_record_missing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("workflow-state-KEN-1.json");
    for verb in [
        ["state", "inspect", "--file"],
        ["state", "migrate", "--file"],
    ] {
        let out = run(&verb, &[&path]);
        assert_eq!(out.status.code(), Some(1));
        assert!(first_stderr_line(&out).starts_with("orch-runtime: record-missing path="));
        assert_eq!(reply(&out)["refusal"]["key"], "record-missing");
    }
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}

/// An operation on an unstamped file leaves it unstamped and patches only
/// the keys it writes; after `migrate` the same operation moves the
/// revision.
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
    assert_eq!(result["stamp"]["kind"], "legacy");
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
    // The legacy fields the type does not name are still there.
    assert_eq!(
        state["round_prunes"]["1769600000123456789-1837"]["action"],
        "below-mark"
    );

    let out = run(&["state", "migrate", "--file"], &[&path]);
    assert!(out.status.success());
    let out = run(
        &["op", "--file"],
        &[&path, Path::new("--request"), &request],
    );
    assert!(out.status.success());
    let answer = reply(&out);
    assert_eq!(answer["result"]["stamp"]["kind"], "stamped");
    assert_eq!(answer["result"]["stamp"]["revision"], 2);
    let state: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["revision"], 2);
    let keys: Vec<&String> = state.as_object().unwrap().keys().collect();
    assert_eq!(keys[..2], ["record_version", "revision"]);
    assert_eq!(keys[2..].to_vec(), before_keys);

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

/// Two launches of one lane through the binary, a failed outcome between
/// them, on an unstamped file: each process mints its own stamp, so the
/// second intent gets its own id and its confirmation runs the lane. The
/// revision-based id R-U10 found would have given both the same id.
#[test]
fn op_mints_a_distinct_intent_id_per_process_on_an_unstamped_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-oversee.json", FLEET);
    let launch = write(
        dir.path(),
        "launch.json",
        r#"{"op": "launch-lane", "item": "KEN-4468", "harness": "claude", "mail_root": "/w/KEN-4468"}"#,
    );
    let op = |request: &Path| {
        let out = run(&["op", "--file"], &[&path, Path::new("--request"), request]);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        reply(&out)["result"]["report"].clone()
    };
    let first = op(&launch)["effect"]["intent"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(first.starts_with("launch-lane:KEN-4468:"), "{first}");
    let outcome = |id: &str, word: &str| {
        write(
            dir.path(),
            &format!("{word}.json"),
            &format!(r#"{{"op": "record-outcome", "intent_id": "{id}", "outcome": "{word}"}}"#),
        )
    };
    assert_eq!(op(&outcome(&first, "failed"))["lane"]["status"], "stopped");
    let second = op(&launch)["effect"]["intent"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(second, first);
    assert_eq!(
        op(&outcome(&second, "confirmed"))["lane"]["status"],
        "running"
    );
    let state: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert!(state.get("record_version").is_none(), "still unstamped");
    let intents = state["intents"].as_array().unwrap();
    assert_eq!(intents.len(), 2);
    assert_eq!(intents[0]["outcome"], "failed");
    assert_eq!(intents[1]["outcome"], "confirmed");
}
