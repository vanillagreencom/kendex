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

/// `orch-runtime ready` in `root` under `env`, its stdout lines and exit.
fn ready_in(root: &Path, args: &[&str], env: &[(&str, &std::ffi::OsStr)]) -> (Vec<String>, i32) {
    let mut command = support::isolated();
    command.arg("ready").args(args).current_dir(root);
    for (name, value) in env {
        command.env(name, value);
    }
    let out = command.output().unwrap();
    let lines = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect();
    (lines, out.status.code().unwrap_or(-1))
}

/// `orch-runtime ready` judges every duty's programs on this computer:
/// agent-runtime's real wrapper finding its key unbuilt names orch's setup,
/// a mailbox program and a worktree program that are gone name the
/// packages' install, a missing `tmux` names its install for every duty
/// that opens or reads a pane, and a duty that lacks nothing reads `ready`;
/// it exits 1 while any is unready, 0 once every one stands, and a duty
/// asked by name is answered alone.
#[test]
fn ready_names_what_each_duty_lacks_and_its_fix() {
    let dir = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let packages = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let wrapper = packages.join("agent-runtime/scripts/agent-runtime");
    let no_tmux = std::ffi::OsString::from(support::path_without(&root.join("bin"), "tmux"));
    let cache = root.join("cache");
    let gone = root.join("gone");
    let (lines, code) = ready_in(
        &root,
        &[],
        &[
            ("PATH", &no_tmux),
            ("ORCH_AGENT_RUNTIME", wrapper.as_os_str()),
            ("AGENT_RUNTIME_CACHE", cache.as_os_str()),
            ("LANE_MAIL_CLI", gone.as_os_str()),
            ("WORKTREE_CLI", gone.as_os_str()),
        ],
    );
    assert_eq!(code, 1, "{lines:?}");
    let setup = lines
        .first()
        .and_then(|l| l.strip_prefix("unready duty=watch program=agent-runtime cause=unbuilt fix="))
        .unwrap_or_else(|| panic!("{lines:?}"));
    assert!(
        setup.ends_with("/.agents/skills/orch/scripts/setup"),
        "the fix is orch's one setup: {setup}"
    );
    assert_eq!(
        lines[1..],
        [
            "unready duty=watch program=lane-mail cause=absent fix=kendex-apply",
            "unready duty=watch program=tmux cause=absent fix=install-tmux",
            "unready duty=launch program=tmux cause=absent fix=install-tmux",
            "unready duty=controller program=tmux cause=absent fix=install-tmux",
            "unready duty=job program=tmux cause=absent fix=install-tmux",
            "unready duty=register program=tmux cause=absent fix=install-tmux",
            "ready duty=ci-proof",
            "ready duty=reconcile-items",
            "unready duty=prune program=worktree cause=absent fix=kendex-apply",
        ]
    );
    let path = std::ffi::OsString::from(support::tool_path(&[]));
    let lane_mail = packages.join("mailbox/scripts/lane-mail");
    let worktree = packages.join("worktree/scripts/worktree");
    let ready_env = [
        ("PATH", path.as_os_str()),
        ("ORCH_AGENT_RUNTIME", support::agent_runtime().as_os_str()),
        ("LANE_MAIL_CLI", lane_mail.as_os_str()),
        ("WORKTREE_CLI", worktree.as_os_str()),
    ];
    let (lines, code) = ready_in(&root, &[], &ready_env);
    assert_eq!(code, 0, "{lines:?}");
    assert_eq!(
        lines,
        [
            "ready duty=watch",
            "ready duty=launch",
            "ready duty=controller",
            "ready duty=job",
            "ready duty=register",
            "ready duty=ci-proof",
            "ready duty=reconcile-items",
            "ready duty=prune",
        ]
    );
    let (lines, code) = ready_in(&root, &["--duty", "prune"], &ready_env);
    assert_eq!((lines, code), (vec!["ready duty=prune".to_owned()], 0));
}

/// The judge's other answers, each a duty asked alone: a runtime whose
/// wrapper is gone names the packages' install; a wrapper that answers
/// neither built nor unbuilt reads `unanswered` and names orch's setup; a
/// mailbox program that is not executable names the packages' install; and
/// a job on a computer with neither `systemd-run` nor `setsid` names the
/// one its launcher falls to.
#[test]
fn ready_names_a_gone_or_silent_runtime_a_closed_program_and_no_job_runner() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let packages = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let lane_mail = packages.join("mailbox/scripts/lane-mail");
    let built = support::fixtures().join("agent-runtime-built/agent-runtime");
    let path = std::ffi::OsString::from(support::tool_path(&[]));
    let watch = |runtime: &Path, mail: &Path| {
        ready_in(
            &root,
            &["--duty", "watch"],
            &[
                ("PATH", path.as_os_str()),
                ("ORCH_AGENT_RUNTIME", runtime.as_os_str()),
                ("LANE_MAIL_CLI", mail.as_os_str()),
            ],
        )
    };
    let (lines, code) = watch(&root.join("gone"), &lane_mail);
    assert_eq!(
        (lines, code),
        (
            vec![
                "unready duty=watch program=agent-runtime cause=absent fix=kendex-apply".to_owned()
            ],
            1
        )
    );
    let silent = root.join("silent");
    support::write_executable(&silent, "#!/bin/sh\nexit 2\n");
    let (lines, code) = watch(&silent, &lane_mail);
    assert_eq!(code, 1, "{lines:?}");
    let [line] = lines.as_slice() else {
        panic!("one line: {lines:?}")
    };
    assert!(
        line.strip_prefix("unready duty=watch program=agent-runtime cause=unanswered fix=")
            .is_some_and(|fix| fix.ends_with("/.agents/skills/orch/scripts/setup")),
        "{line}"
    );
    let closed = root.join("closed-lane-mail");
    fs::write(&closed, "#!/bin/sh\n").unwrap();
    fs::set_permissions(&closed, fs::Permissions::from_mode(0o644)).unwrap();
    let (lines, code) = watch(&built, &closed);
    assert_eq!(
        (lines, code),
        (
            vec![
                "unready duty=watch program=lane-mail cause=not-executable fix=kendex-apply"
                    .to_owned()
            ],
            1
        )
    );
    let bin = root.join("no-runner");
    let no_runner = std::ffi::OsString::from(support::path_without(&bin, "setsid"));
    let _ = fs::remove_file(bin.join("systemd-run"));
    let (lines, code) = ready_in(&root, &["--duty", "job"], &[("PATH", &no_runner)]);
    assert_eq!(
        (lines, code),
        (
            vec!["unready duty=job program=setsid cause=absent fix=install-setsid".to_owned()],
            1
        )
    );
}

/// `args` run in a fresh `root` on a search path without `absent`.
fn without(absent: &str, args: &[&str]) -> (PathBuf, tempfile::TempDir, Output) {
    let dir = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let path = support::path_without(&root.join("bin"), absent);
    let mut command = support::isolated();
    command
        .args(["--state-dir", &root.display().to_string()])
        .args(args)
        .current_dir(&root)
        .env("PATH", path);
    let out = command.output().unwrap();
    (root, dir, out)
}

/// Each duty that reads before it acts asks first: `register` with no
/// `tmux` refuses before it makes the fleet's file, and `ci-proof` and
/// `reconcile-items` with no `gh` refuse before any read, each naming the
/// program and its install.
#[test]
fn a_duty_whose_program_is_missing_refuses_before_it_reads_or_writes() {
    let (root, _dir, out) = without("tmux", &["register", "--fleet"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        first_stderr_line(&out),
        "orch-runtime: unready duty=register program=tmux cause=absent fix=install-tmux"
    );
    assert!(
        fs::symlink_metadata(root.join(agent_runtime::record::FLEET_FILE_NAME)).is_err(),
        "register made the fleet's file before it asked"
    );
    let (_root, _dir, out) = without(
        "gh",
        &["ci-proof", "7", &"a".repeat(40), "--repo", "owner/repo"],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        first_stderr_line(&out),
        "orch-runtime: unready duty=ci-proof program=gh cause=absent fix=install-gh"
    );
    let (_root, _dir, out) = without("gh", &["reconcile-items"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        first_stderr_line(&out),
        "orch-runtime: unready duty=reconcile-items program=gh cause=absent fix=install-gh"
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
