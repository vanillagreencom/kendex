//! Process-protocol tests of the `agent-runtime` executable: they run the
//! built binary against fixtures this harness owns.

use std::path::PathBuf;
use std::process::Command;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_agent-runtime"))
}

#[test]
fn version_prints_the_protocol_reply() {
    let out = Command::new(binary()).arg("version").output().unwrap();
    assert!(out.status.success());
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["protocol"], "agent-runtime-v1");
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["result"]["protocol"], "agent-runtime-v1");
}

#[test]
fn a_refusal_prints_one_keyed_line_and_a_refused_reply() {
    let dir = tempfile::tempdir().unwrap();
    let out = Command::new(binary())
        .args(["inspect", "--record"])
        .arg(dir.path().join("none.json"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.lines()
            .next()
            .unwrap()
            .starts_with("agent-runtime: record-missing path="),
        "{err}"
    );
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["refusal"]["key"], "record-missing");
}

/// A usage error is clap's, not a refusal: the keyed usage line, clap's
/// message, exit 2 and no JSON reply. orch-runtime answers the same way, so
/// a wrapper routing on the exit status reads both alike.
#[test]
fn a_usage_error_prints_the_usage_key_exits_2_and_gives_no_reply() {
    let rows: [&[&str]; 3] = [
        &["inspect"],
        &["judge", "--harness", "claude"],
        &["frobnicate"],
    ];
    for args in rows {
        let out = Command::new(binary()).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(
            stderr.lines().next().unwrap_or_default(),
            "agent-runtime: usage",
            "{args:?}"
        );
        assert!(stderr.lines().count() >= 2, "{args:?}: {stderr}");
        assert!(out.stdout.is_empty(), "{args:?}");
    }
    let out = Command::new(binary()).arg("--help").output().unwrap();
    assert!(out.status.success());
    assert!(out.stderr.is_empty());
}

#[test]
fn judge_reads_a_screen_fixture_through_the_one_judge() {
    let dir = tempfile::tempdir().unwrap();
    let screen = dir.path().join("screen.txt");
    std::fs::write(&screen, "❯ do it\n✻ Churned for 6s · done\n❯\u{a0}\n").unwrap();
    let out = Command::new(binary())
        .args(["judge", "--harness", "claude", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "idle");
    let out = Command::new(binary())
        .args([
            "judge",
            "--harness",
            "claude",
            "--process",
            "shells-only",
            "--screen",
        ])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "exited");
}

/// The bypass posture is the one place a harness's permission flag is
/// spelled; a native posture never carries it.
#[test]
fn a_bypass_launch_spells_the_claude_bypass_flag_and_a_native_one_does_not() {
    use agent_runtime::Harness;
    use agent_runtime::launch::{Brief, Compaction, LaunchIntent, Permission, QuestionTool, build};
    let intent = |permission: Permission| LaunchIntent {
        harness: Harness::Claude,
        home: Some("/home/x/.1claude".into()),
        cwd: "/work/tree".into(),
        model: Some("opus".into()),
        effort: None,
        permission,
        question_tool: QuestionTool::Off,
        compaction: Compaction::Native,
        brief: Brief::None,
        resume: None,
        env: Default::default(),
        env_remove: Vec::new(),
        extra_args: Vec::new(),
    };
    let flag = "--dangerously-skip-permissions".to_owned();
    let bypass = build(&intent(Permission::Bypass)).unwrap();
    assert_eq!(bypass.args.iter().filter(|a| **a == flag).count(), 1);
    let native = build(&intent(Permission::Native)).unwrap();
    assert!(!native.args.contains(&flag));
}

/// Pi 1.4.0's default composer at rest: the capture-pane output of run 2's
/// probe after its first turn (`tmp/orch-rebuild/native/run2/pi/final-screen.txt`).
const PI_IDLE: &str = include_str!("fixtures/pi-idle.txt");
/// The same session while its first turn ran: the drawn lines the probe's
/// inspection kept, with the `── ⠹ Working ──` editor border.
const PI_WORKING: &str = include_str!("fixtures/pi-working.txt");

#[test]
fn pi_captures_judge_idle_at_rest_and_working_mid_turn() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{ProcessReading, State, judge};
    assert_eq!(
        judge(PI_IDLE, Harness::Pi, ProcessReading::HarnessUp, None),
        State::Idle
    );
    assert_eq!(
        judge(PI_WORKING, Harness::Pi, ProcessReading::HarnessUp, None),
        State::Working
    );
    // The same idle capture settles nothing for a marker-drawing harness.
    assert!(matches!(
        judge(PI_IDLE, Harness::Claude, ProcessReading::HarnessUp, None),
        State::Unjudged { .. }
    ));
}

#[test]
fn the_judge_verb_takes_the_harness_that_drew_the_screen() {
    let dir = tempfile::tempdir().unwrap();
    let screen = dir.path().join("pi.txt");
    std::fs::write(&screen, PI_IDLE).unwrap();
    let out = Command::new(binary())
        .args(["judge", "--harness", "pi", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "idle");
    let out = Command::new(binary())
        .args(["judge", "--harness", "nope", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["refusal"]["key"], "harness-unknown");
}
