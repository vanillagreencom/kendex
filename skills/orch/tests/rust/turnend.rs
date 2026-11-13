//! Process tests of the turn-end verb through the `orch-runtime`
//! executable: a planted payload on stdin and a planted world (a lane's
//! checkout, its launch marker and mailbox directory, the user's cache) and
//! the answer read back as a harness reads it, stdout, stderr and the exit
//! status. Every row runs the real binary and the real `git`.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant checkouts, markers, caches and file times and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use support::*;
use tempfile::TempDir;

/// What the harness was handed.
struct Out {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Out {
    fn first(&self) -> &str {
        self.stderr.lines().next().unwrap_or("")
    }

    fn last(&self) -> &str {
        self.stderr.lines().last().unwrap_or("")
    }

    /// The keyed line after the account mark's, asserted to be
    /// `account=<account>`: a lane's Stop in a world planting no account
    /// tells its account mark first.
    fn after(&self, account: &str) -> &str {
        let mut keyed = self
            .stderr
            .lines()
            .filter(|l| l.starts_with("lane-mail-check: "));
        let told = format!("lane-mail-check: account={account}");
        assert_eq!(keyed.next(), Some(told.as_str()), "{}", self.stderr);
        keyed.next().unwrap_or("")
    }

    /// The JSON answer on stdout.
    fn json(&self) -> Value {
        serde_json::from_str(self.stdout.trim_end())
            .unwrap_or_else(|e| panic!("stdout is no JSON answer ({e}): {:?}", self.stdout))
    }
}

/// A scratch root holding a lane's checkout on its item's branch, the
/// user's home and the install directories a hook sits in.
struct World {
    _dir: TempDir,
    root: PathBuf,
    home: PathBuf,
    lane: PathBuf,
}

const ITEM: &str = "ken-1";

fn git(dir: &Path, args: &[&str]) {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git");
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
}

impl World {
    /// A lane checked out on its item's branch, with no marker and no
    /// mailbox.
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        let home = root.join("home");
        let lane = root.join("lane");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&lane).unwrap();
        repository(&lane, ITEM);
        let world = World {
            _dir: dir,
            root,
            home,
            lane,
        };
        fs::create_dir_all(world.stand_ins()).unwrap();
        for name in ["node", "pi"] {
            write_executable(
                &world.stand_ins().join(name),
                format!(
                    "#!/bin/sh\nprintf '{name}: no stand-in answers: %s\\n' \"$*\" >&2\nexit 4\n"
                ),
            );
        }
        world
    }

    /// The directory first on the verb's `PATH`: `node` and `pi` stand-ins
    /// that refuse unless a row plants an answer, so no row reaches a real
    /// Pi install or its registry.
    fn stand_ins(&self) -> PathBuf {
        self.root.join("stand-ins")
    }

    /// The install directory of `harness` under the scratch root.
    fn hooks(&self, harness: &str) -> PathBuf {
        let dir = match harness {
            "claude" => ".claude/hooks",
            "codex" => ".codex/hooks",
            "copilot" => ".github/hooks",
            "pi" => ".pi/kendex/hooks",
            other => panic!("no install directory for {other}"),
        };
        self.root.join("install").join(dir)
    }

    fn common(&self) -> PathBuf {
        self.lane.join(".git")
    }

    /// The launch marker for `item`, binding `root`.
    fn mark(&self, item: &str, root: &Path) {
        let dir = self.common().join("lane-mail");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(item.to_ascii_lowercase()),
            format!("{}\n", root.display()),
        )
        .unwrap();
    }

    fn mail_root(&self) -> PathBuf {
        self.lane.join("tmp").join("lane-mail")
    }

    fn mailbox(&self, item: &str) {
        fs::create_dir_all(self.mail_root().join(item)).unwrap();
    }

    /// A marked lane whose mailbox directory is gone.
    fn boxless() -> World {
        let world = World::new();
        world.mark(ITEM, &world.lane);
        world
    }

    /// A lane its marker binds, with its mailbox.
    fn launched() -> World {
        let world = World::boxless();
        world.mailbox(ITEM);
        world
    }

    fn leads(&self) -> PathBuf {
        self.home.join(".cache/lane-mail/copilot-leads")
    }

    fn usage(&self) -> PathBuf {
        self.home.join(".cache/lane-mail/copilot-usage")
    }

    /// The verb run from the lane under `harness`'s install.
    fn turn(&self, harness: &str, args: &[&str], payload: &str) -> Out {
        self.turn_in(&self.lane, &self.hooks(harness), args, payload, &[])
    }

    /// The verb run from `dir` under the install `hooks`, with `env` added.
    fn turn_in(
        &self,
        dir: &Path,
        hooks: &Path,
        args: &[&str],
        payload: &str,
        env: &[(&str, &str)],
    ) -> Out {
        let mut command = isolated();
        command
            .arg("turn-end")
            .arg("--hook-dir")
            .arg(hooks)
            .args(args)
            .current_dir(dir)
            .env("PWD", dir)
            .env("HOME", &self.home)
            .env("PATH", tool_path(&[&self.stand_ins()]))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (name, value) in env {
            command.env(name, value);
        }
        let mut child = command.spawn().expect("orch-runtime");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(payload.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        Out {
            code: out.status.code().expect("an exit status"),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }
}

fn repository(dir: &Path, branch: &str) {
    git(dir, &["init", "-q"]);
    git(dir, &["config", "gc.auto", "0"]);
    git(dir, &["config", "maintenance.auto", "false"]);
    git(dir, &["checkout", "-q", "-b", branch]);
    git(dir, &["commit", "-q", "--allow-empty", "-m", "base"]);
}

/// `path`'s modification time moved `age` into the past.
fn aged(path: &Path, age: Duration) {
    let file = fs::OpenOptions::new().append(true).open(path).unwrap();
    file.set_modified(SystemTime::now() - age).unwrap();
}

fn days(n: u64) -> Duration {
    Duration::from_secs(n * 86_400)
}

fn plant(path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, "").unwrap();
}

fn mailbox_missing(world: &World) -> String {
    format!(
        "lane-mail-check: mailbox-missing={}",
        world.mail_root().display()
    )
}

#[test]
fn an_unknown_arm_is_refused_before_the_payload_in_every_harness() {
    let world = World::launched();
    for harness in ["claude", "codex", "copilot"] {
        for word in ["bogus", "-x"] {
            let out = world.turn(harness, &[word], "no payload is read");
            let row = format!("{harness} {word}");
            assert_eq!(out.code, 2, "{row}: {}", out.stderr);
            assert_eq!(out.stdout, "", "{row}");
            assert_eq!(out.first(), format!("lane-mail-check: arm={word}"), "{row}");
        }
    }
}

/// A row of the refusal shapes: the harness, the arguments, the payload,
/// the exit status and the field the stdout answer carries the text in.
type Shape<'a> = (&'a str, &'a [&'a str], &'a str, i32, Option<&'a str>);

#[test]
fn a_refusal_takes_the_shape_its_harness_and_arm_read() {
    let world = World::boxless();
    let cwd = json!({"cwd": world.lane.display().to_string()}).to_string();
    let copilot = r#"{"sessionId":"s1","timestamp":1}"#;
    let halt = r#"{"tool_input":{"command":"ls"}}"#;
    let rows: &[Shape] = &[
        ("claude", &[], "{}", 2, None),
        ("codex", &["halt"], halt, 2, None),
        ("claude", &["deliver"], "{}", 2, None),
        ("claude", &["compact"], "{}", 2, None),
        ("claude", &["usage"], &cwd, 2, None),
        (
            "claude",
            &[],
            r#"{"hook_event_name":"PostModelSwitch"}"#,
            2,
            None,
        ),
        ("claude", &["start"], "{}", 0, None),
        ("claude", &["prompt"], "{}", 0, None),
        ("copilot", &[], copilot, 0, Some("reason")),
        (
            "copilot",
            &["halt"],
            copilot,
            2,
            Some("permissionDecisionReason"),
        ),
        (
            "copilot",
            &["deliver"],
            copilot,
            0,
            Some("additionalContext"),
        ),
        ("copilot", &["start"], copilot, 0, None),
        ("copilot", &["prompt"], copilot, 0, None),
    ];
    for (harness, args, payload, code, field) in rows {
        let row = format!("{harness} {args:?}");
        let out = world.turn(harness, args, payload);
        assert_eq!(out.code, *code, "{row}: {}", out.stderr);
        assert_eq!(out.first(), mailbox_missing(&world), "{row}");
        match field {
            None => assert_eq!(out.stdout, "", "{row}"),
            Some(field) => {
                let answer = out.json();
                assert_eq!(answer[field], json!(out.stderr.trim_end()), "{row}");
                let kind = match *field {
                    "reason" => ("decision", "block"),
                    "permissionDecisionReason" => ("permissionDecision", "deny"),
                    _ => ("additionalContext", out.stderr.trim_end()),
                };
                assert_eq!(answer[kind.0], json!(kind.1), "{row}");
            }
        }
    }
}

#[test]
fn a_launched_lane_with_nothing_to_hold_passes_every_arm_with_nothing_written() {
    let world = World::launched();
    let copilot = r#"{"sessionId":"s1","timestamp":1}"#;
    // A Stop tells the account mark, which no account here measures.
    let told = "lane-mail-check: account=unlisted";
    let rows: &[(&str, &[&str], &str, &str)] = &[
        ("claude", &[], "{}", told),
        ("claude", &[], r#"{"stop_hook_active":true}"#, told),
        (
            "claude",
            &[],
            r#"{"hook_event_name":"PostModelSwitch"}"#,
            "",
        ),
        (
            "claude",
            &["halt"],
            r#"{"tool_input":{"command":"ls"}}"#,
            "",
        ),
        ("claude", &["deliver"], "{}", ""),
        ("claude", &["start"], "{}", ""),
        ("claude", &["prompt"], "{}", ""),
        ("claude", &["compact"], "{}", ""),
        ("claude", &["row", "SessionStart"], "{}", ""),
        ("copilot", &["start"], copilot, ""),
    ];
    for (harness, args, payload, keys) in rows {
        let out = world.turn(harness, args, payload);
        assert_eq!(
            (out.code, out.stdout.as_str(), keyed(&out).as_str()),
            (0, "", *keys),
            "{harness} {args:?} {payload}"
        );
    }
}

#[test]
fn the_mailbox_restoring_command_alone_passes_a_tool_call() {
    let world = World::boxless();
    let restore = format!("mkdir -p -- {}", world.mail_root().display());
    let encoded = json!({"command": restore}).to_string();
    let claude = |command: &str, agent: bool| {
        let mut payload = json!({"tool_input": {"command": command}});
        if agent {
            payload["agent_id"] = json!("a1");
        }
        payload.to_string()
    };
    let copilot =
        |args: Value| json!({"sessionId": "s1", "timestamp": 1, "toolArgs": args}).to_string();
    // harness, arm, payload, exit status, the refusal names the command
    let rows: &[(&str, &str, String, i32, Option<bool>)] = &[
        ("claude", "halt", claude(&restore, false), 0, None),
        ("claude", "halt", claude("ls", false), 2, Some(true)),
        ("claude", "halt", claude(&restore, true), 2, Some(false)),
        ("claude", "stop", claude(&restore, false), 2, Some(true)),
        ("copilot", "halt", copilot(json!(encoded)), 0, None),
        (
            "copilot",
            "halt",
            copilot(json!({"command": restore})),
            0,
            None,
        ),
        (
            "copilot",
            "halt",
            copilot(json!({"command": "ls"})),
            2,
            Some(true),
        ),
    ];
    for (harness, arm, payload, code, names) in rows {
        let row = format!("{harness} {arm} {payload}");
        let out = world.turn(harness, &[arm], payload);
        assert_eq!(out.code, *code, "{row}: {}", out.stderr);
        match names {
            None => assert_eq!(out.stderr, "", "{row}"),
            Some(names) => {
                assert_eq!(out.first(), mailbox_missing(&world), "{row}");
                assert_eq!(out.last() == restore, *names, "{row}: {}", out.stderr);
                assert_eq!(out.stderr.contains(&restore), *names, "{row}");
            }
        }
    }
    let out = world.turn("copilot", &["halt"], &copilot(json!("not json")));
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: payload=invalid-json");
    assert_eq!(out.json()["permissionDecision"], json!("deny"));
}

#[test]
fn a_subagents_call_that_hands_context_passes_before_any_lane_read() {
    let world = World::boxless();
    let sub = r#"{"agent_id":"a1","agent_type":"general-purpose"}"#;
    for args in [&["deliver"][..], &["start"], &["prompt"]] {
        let out = world.turn("claude", args, sub);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.stderr.as_str()),
            (0, "", ""),
            "{args:?}"
        );
    }
    let switch = r#"{"hook_event_name":"PostModelSwitch","agent_type":"x"}"#;
    let out = world.turn("claude", &[], switch);
    assert_eq!(
        (out.code, out.stderr.as_str()),
        (0, ""),
        "a subagent's model switch"
    );
    let out = world.turn("claude", &[], sub);
    assert_eq!(
        out.code, 2,
        "a subagent's turn end is judged: {}",
        out.stderr
    );
    assert_eq!(out.first(), mailbox_missing(&world));
    let out = world.turn("claude", &["deliver"], "{}");
    assert_eq!(
        out.code, 2,
        "the lead's finished call is judged: {}",
        out.stderr
    );
}

#[test]
fn a_compaction_no_lead_made_flags_nothing_and_reports_an_unknown_automatic_one() {
    let world = World::boxless();
    let compact = |session: Option<&str>, trigger: &str| {
        let mut payload = json!({"timestamp": 1, "trigger": trigger});
        if let Some(session) = session {
            payload["sessionId"] = json!(session);
        }
        payload.to_string()
    };
    let out = world.turn("copilot", &["compact"], &compact(Some("s7"), "auto"));
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: session-unrecorded=s7");
    let out = world.turn("copilot", &["compact"], &compact(None, "auto"));
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: session-unrecorded=none");
    let out = world.turn("copilot", &["compact"], &compact(Some("s7"), "manual"));
    assert_eq!(
        (out.code, out.stderr.as_str()),
        (0, ""),
        "a manual one is not reported"
    );
    let out = world.turn(
        "claude",
        &["compact"],
        r#"{"agent_id":"a1","trigger":"auto"}"#,
    );
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "a subagent's");
    plant(&world.leads().join("s7"));
    let out = world.turn("copilot", &["compact"], &compact(Some("s7"), "manual"));
    assert_eq!(out.code, 2, "a recorded lead's is judged: {}", out.stderr);
    assert_eq!(out.first(), mailbox_missing(&world));
}

#[test]
fn a_copilot_call_through_another_harness_install_passes_silently() {
    let world = World::boxless();
    let payload = r#"{"sessionId":"s1","timestamp":1}"#;
    let out = world.turn("claude", &[], payload);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let out = world.turn("copilot", &[], payload);
    assert_eq!(
        out.json()["decision"],
        json!("block"),
        "the Copilot install judges it"
    );
}

#[test]
fn a_copilot_lead_is_recorded_at_its_start_and_proved_by_its_own_transcript() {
    let world = World::boxless();
    let compact = |session: &str| json!({"sessionId": session, "timestamp": 1}).to_string();
    let out = world.turn("copilot", &["compact"], &compact("s1"));
    assert_eq!(
        out.code, 0,
        "an unrecorded session's compaction passes: {}",
        out.stderr
    );
    world.turn("copilot", &["start"], &compact("s1"));
    assert!(
        world.leads().join("s1").is_file(),
        "the start records its lead"
    );
    let out = world.turn("copilot", &["compact"], &compact("s1"));
    assert_eq!(
        out.code, 2,
        "the recorded lead's compaction is judged: {}",
        out.stderr
    );

    let stop = |dir: &str, session: &str| {
        let transcript = world.root.join("state").join(dir).join("events.jsonl");
        json!({"sessionId": session, "timestamp": 1, "transcriptPath": transcript.display().to_string()}).to_string()
    };
    let restore = format!("mkdir -p -- {}", world.mail_root().display());
    let out = world.turn("copilot", &[], &stop("s2", "s2"));
    assert!(
        world.leads().join("s2").is_file(),
        "a stop in its own session's directory records it"
    );
    let reason = out.json()["reason"].as_str().unwrap_or_default().to_owned();
    assert!(
        reason.ends_with(&restore),
        "the lead is shown the command: {reason}"
    );
    let out = world.turn("copilot", &[], &stop("s2", "s3"));
    assert!(
        !world.leads().join("s3").exists(),
        "a stop in another session's directory records nothing"
    );
    let reason = out.json()["reason"].as_str().unwrap_or_default().to_owned();
    assert!(reason.starts_with(&mailbox_missing(&world)), "{reason}");
    assert!(
        !reason.contains(&restore),
        "a subagent is never shown the command: {reason}"
    );
}

#[test]
fn lead_records_and_pending_markers_untouched_past_thirty_whole_days_are_pruned_at_a_start() {
    let world = World::new();
    let leads = world.leads();
    let usage = world.usage();
    let old = [
        leads.join("old"),
        usage.join("old"),
        usage.join("nested").join("old"),
    ];
    let kept = [leads.join("young"), usage.join("boundary")];
    for path in old.iter().chain(&kept) {
        plant(path);
    }
    for path in &old {
        aged(path, days(31) + Duration::from_secs(3600));
    }
    aged(&kept[0], days(10));
    aged(&kept[1], days(30) + Duration::from_secs(12 * 3600));
    let outside = world.root.join("outside");
    plant(&outside);
    aged(&outside, days(40));
    std::os::unix::fs::symlink(&outside, leads.join("link")).unwrap();
    let out = world.turn("copilot", &["start"], r#"{"sessionId":"s1","timestamp":1}"#);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""));
    for path in &old {
        assert!(!path.exists(), "pruned: {}", path.display());
    }
    for path in kept.iter().chain([&outside, &leads.join("s1")]) {
        assert!(path.exists(), "kept: {}", path.display());
    }
    assert!(
        leads.join("link").symlink_metadata().is_ok(),
        "a link is never removed"
    );
}

#[test]
fn a_lead_record_that_cannot_be_written_or_pruned_is_reported_and_the_session_goes_on() {
    let start = r#"{"sessionId":"s1","timestamp":1}"#;
    let world = World::new();
    let out = world.turn("copilot", &["start"], r#"{"timestamp":1}"#);
    assert_eq!(
        (out.code, out.first()),
        (0, "lane-mail-check: lead-unrecorded=none")
    );

    let world = World::new();
    plant(&world.home.join(".cache/lane-mail"));
    let out = world.turn("copilot", &["start"], start);
    let want = format!(
        "lane-mail-check: lead-unrecorded={}",
        world.leads().join("s1").display()
    );
    assert_eq!(
        (out.code, out.first()),
        (0, want.as_str()),
        "{}",
        out.stderr
    );

    let world = World::new();
    let held = world.leads().join("held");
    let stale = held.join("old");
    plant(&stale);
    aged(&stale, days(40));
    fs::set_permissions(&held, fs::Permissions::from_mode(0o555)).unwrap();
    let out = world.turn("copilot", &["start"], start);
    fs::set_permissions(&held, fs::Permissions::from_mode(0o755)).unwrap();
    let want = format!(
        "lane-mail-check: leads-unpruned={}",
        world.leads().display()
    );
    assert_eq!(
        (out.code, out.first()),
        (0, want.as_str()),
        "{}",
        out.stderr
    );
    assert!(
        world.leads().join("s1").is_file(),
        "the session's own record stands"
    );
}

#[test]
fn a_gap_the_lane_cannot_clear_is_held_on_a_fresh_turn_end_and_reported_where_holding_loops() {
    let world = World::new();
    let plain = world.root.join("plain");
    fs::create_dir_all(plain.join("tmp/lane-mail")).unwrap();
    let hooks = world.hooks("claude");
    let git_line = format!(
        "lane-mail-check: git=-C {} rev-parse --show-toplevel --git-common-dir",
        plain.display()
    );
    // arm, payload, exit status
    let rows: &[(&[&str], &str, i32)] = &[
        (&[], "{}", 2),
        (&[], r#"{"stop_hook_active":true}"#, 0),
        (&["halt"], "{}", 0),
        (&["lane"], "{}", 0),
        (&["row", "SessionStart"], "{}", 0),
        (&["deliver"], "{}", 2),
    ];
    for (args, payload, code) in rows {
        let out = world.turn_in(&plain, &hooks, args, payload, &[]);
        assert_eq!(out.code, *code, "{args:?} {payload}: {}", out.stderr);
        assert_eq!(
            (out.first(), out.stdout.as_str()),
            (git_line.as_str(), ""),
            "{args:?}"
        );
    }
    let out = world.turn_in(&plain, &hooks, &[], "{}", &[("TMUX", "/x,1,0")]);
    let branch_line = format!(
        "lane-mail-check: git=-C {} symbolic-ref -q --short HEAD",
        plain.display()
    );
    assert_eq!(
        (out.code, out.first()),
        (2, branch_line.as_str()),
        "tmux with no pane reads no lane discovery"
    );

    let bare = world.root.join("bare");
    fs::create_dir_all(&bare).unwrap();
    let out = world.turn_in(&bare, &hooks, &[], "{}", &[]);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "", "")
    );
    let out = world.turn_in(&bare, &hooks, &["lane"], "{}", &[]);
    assert_eq!(
        (out.code, out.stdout.as_str(), out.stderr.as_str()),
        (0, "none\n", "")
    );
}

#[test]
fn a_branch_git_cannot_read_is_held_never_read_as_no_lane() {
    let world = World::launched();
    fs::write(world.common().join("HEAD"), "ref: refs/heads/a..b\n").unwrap();
    let line = format!(
        "lane-mail-check: git=-C {} symbolic-ref -q --short HEAD",
        world.lane.display()
    );
    let out = world.turn("claude", &[], "{}");
    assert_eq!(
        (out.code, out.first()),
        (2, line.as_str()),
        "{}",
        out.stderr
    );
    let out = world.turn("claude", &["halt"], "{}");
    assert_eq!(
        (out.code, out.first()),
        (0, line.as_str()),
        "{}",
        out.stderr
    );
}

#[test]
fn the_lane_arm_names_a_launched_lane_and_nothing_else() {
    let sub = r#"{"agent_id":"a1"}"#;
    // world, payload, stdout, first stderr line (`@` is the marker path)
    let rows: &[(&str, &str, &str, &str)] = &[
        ("launched", "{}", "lane\n", ""),
        ("launched", sub, "lane\n", ""),
        ("unmarked", "{}", "none\n", ""),
        ("rebound", "{}", "none\n", ""),
        ("boxless", "{}", "none\n", ""),
        ("bare", "{}", "none\n", ""),
        ("marker-dir", "{}", "", "lane-mail-check: marker=@"),
        ("marker-link", "{}", "", "lane-mail-check: marker=@"),
    ];
    for (shape, payload, stdout, first) in rows {
        let world = World::new();
        let marker = world.common().join("lane-mail").join(ITEM);
        match *shape {
            "launched" => {
                world.mark(ITEM, &world.lane);
                world.mailbox(ITEM);
            }
            "unmarked" => world.mailbox(ITEM),
            "rebound" => {
                world.mark(ITEM, &world.root.join("another-root"));
                world.mailbox(ITEM);
            }
            "boxless" => world.mark(ITEM, &world.lane),
            "bare" => {}
            "marker-dir" => {
                world.mailbox(ITEM);
                fs::create_dir_all(&marker).unwrap();
            }
            "marker-link" => {
                world.mailbox(ITEM);
                let held = world.root.join("held-root");
                fs::write(&held, format!("{}\n", world.lane.display())).unwrap();
                fs::create_dir_all(marker.parent().unwrap()).unwrap();
                std::os::unix::fs::symlink(&held, &marker).unwrap();
            }
            other => panic!("no world {other}"),
        }
        let out = world.turn("claude", &["lane"], payload);
        let first = first.replace('@', &marker.display().to_string());
        assert_eq!(
            (out.code, out.stdout.as_str(), out.first()),
            (0, *stdout, first.as_str()),
            "{shape} {payload}: {}",
            out.stderr
        );
    }
}

#[test]
fn the_item_is_the_briefs_or_the_one_mailbox_its_branch_names() {
    let world = World::launched();
    let out = world.turn_in(
        &world.lane,
        &world.hooks("claude"),
        &[],
        "{}",
        &[("LANE_MAIL_ITEM", "a/b")],
    );
    assert_eq!(
        (out.code, out.first()),
        (2, "lane-mail-check: item=invalid"),
        "{}",
        out.stderr
    );
    let out = world.turn_in(
        &world.lane,
        &world.hooks("claude"),
        &[],
        r#"{"stop_hook_active":true}"#,
        &[("LANE_MAIL_ITEM", "a/b")],
    );
    assert_eq!(
        (out.code, out.first()),
        (0, "lane-mail-check: item=invalid")
    );

    let world = World::new();
    world.mark(ITEM, &world.lane);
    world.mailbox("KEN-1");
    let out = world.turn("claude", &["lane"], "{}");
    assert_eq!(
        out.stdout, "lane\n",
        "the branch names its mailbox in any case: {}",
        out.stderr
    );
    world.mailbox(".ken-1");
    let out = world.turn("claude", &["lane"], "{}");
    assert_eq!(
        out.stdout, "lane\n",
        "a hidden directory is no mailbox: {}",
        out.stderr
    );
    world.mailbox(ITEM);
    let out = world.turn("claude", &[], "{}");
    assert_eq!(
        (out.code, out.first()),
        (2, "lane-mail-check: item=ambiguous"),
        "{}",
        out.stderr
    );

    let world = World::launched();
    git(&world.lane, &["checkout", "-q", "-b", "other"]);
    let out = world.turn_in(
        &world.lane,
        &world.hooks("claude"),
        &["lane"],
        "{}",
        &[("LANE_MAIL_ITEM", ITEM)],
    );
    assert_eq!(
        out.stdout, "lane\n",
        "the brief's item over the branch: {}",
        out.stderr
    );
    let out = world.turn("claude", &["lane"], "{}");
    assert_eq!(
        out.stdout, "none\n",
        "a branch naming no mailbox: {}",
        out.stderr
    );
}

#[test]
fn a_lane_run_from_its_main_clone_is_read_at_the_root_its_marker_binds() {
    let world = World::new();
    let worktree = world.root.join("worktree");
    let path = worktree.display().to_string();
    git(
        &world.lane,
        &["worktree", "add", "-q", "-b", "ken-2", &path],
    );
    world.mark("ken-2", &worktree);
    fs::create_dir_all(worktree.join("tmp/lane-mail/ken-2")).unwrap();
    let hooks = world.hooks("claude");
    let out = world.turn_in(
        &world.lane,
        &hooks,
        &["lane"],
        "{}",
        &[("LANE_MAIL_ITEM", "ken-2")],
    );
    assert_eq!(out.stdout, "lane\n", "{}", out.stderr);
    let project = world.lane.display().to_string();
    let out = world.turn_in(
        &world.lane,
        &hooks,
        &["lane"],
        "{}",
        &[
            ("LANE_MAIL_ITEM", "ken-2"),
            ("CLAUDE_PROJECT_DIR", &project),
        ],
    );
    assert_eq!(
        out.stdout, "none\n",
        "the session's own directory first: {}",
        out.stderr
    );
}

#[test]
fn a_payload_field_of_another_type_refuses_it_and_an_empty_payload_passes() {
    let world = World::new();
    // arm, payload, refused
    let rows: &[(&str, &str, bool)] = &[
        ("stop", "", false),
        ("stop", "null", false),
        ("stop", "{}", false),
        (
            "stop",
            r#"{"context_window":200000,"stop_hook_active":"yes"}"#,
            false,
        ),
        ("stop", r#"{"context_window":2e5}"#, false),
        (
            "stop",
            r#"{"transcript_path":"/t","transcriptPath":5}"#,
            false,
        ),
        (
            "stop",
            r#"{"hook_event_name":"SubagentStop","agent_id":1}"#,
            false,
        ),
        ("stop", r#"{"cwd":5}"#, false),
        ("stop", r#"{"session_id":"a b"}"#, false),
        ("stop", "not json", true),
        ("stop", "[]", true),
        ("stop", r#""text""#, true),
        ("stop", "{} {}", true),
        ("stop", r#"{"session_id":5}"#, true),
        ("stop", r#"{"transcriptPath":[]}"#, true),
        ("stop", r#"{"tool_name":{}}"#, true),
        ("stop", r#"{"agent_id":1}"#, true),
        ("stop", r#"{"trigger":true}"#, true),
        ("stop", r#"{"context_window":0}"#, true),
        ("stop", r#"{"context_window":1.5}"#, true),
        ("stop", r#"{"context_window":"9"}"#, true),
        ("usage", r#"{"cwd":5}"#, true),
    ];
    for (arm, payload, refused) in rows {
        let out = world.turn("claude", &[arm], payload);
        let want = if *refused {
            (2, "lane-mail-check: payload=invalid-json")
        } else {
            (0, "")
        };
        assert_eq!(
            (out.code, out.first()),
            want,
            "{arm} {payload}: {}",
            out.stderr
        );
    }
}

#[test]
fn a_payload_that_cannot_be_read_is_refused() {
    let world = World::new();
    let mut command = isolated();
    let out = command
        .args(["turn-end", "--hook-dir"])
        .arg(world.hooks("claude"))
        .current_dir(&world.lane)
        .env("HOME", &world.home)
        .stdin(fs::File::open(&world.root).unwrap())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{text}");
    assert_eq!(
        text.lines().next(),
        Some("lane-mail-check: payload=unreadable")
    );
}

/// The mailbox package's own reader, which every mail row runs.
fn lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../mailbox/scripts/lane-mail")
}

/// The plain read that acknowledges a halt, as the lead is told to run it.
fn read_command(world: &World) -> String {
    format!(
        "{} inbox --item {ITEM} --root {}",
        lane_mail().display(),
        world.lane.display()
    )
}

impl World {
    fn lane_box(&self) -> PathBuf {
        self.mail_root().join(ITEM)
    }

    /// One line appended to the lane's box `file`, as the mailbox writes it.
    fn append(&self, file: &str, line: Value) {
        let mut handle = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.lane_box().join(file))
            .unwrap();
        writeln!(handle, "{line}").unwrap();
    }

    /// A directive the overseer sent the lane, a halt where `halt`.
    fn direct(&self, id: &str, text: &str, halt: bool) {
        let mut line = json!({"id": id, "kind": "directive", "at": "2026-11-11T00:00:00Z", "from": "overseer", "text": text});
        if halt {
            line["halt"] = json!(true);
        }
        self.append("to-lane.jsonl", line);
    }

    /// An ask or a notice the lane sent its overseer.
    fn report(&self, id: &str, kind: &str) {
        let line = json!({"id": id, "kind": kind, "at": "2026-11-11T00:00:00Z", "from": ITEM, "text": "x"});
        self.append("to-overseer.jsonl", line);
    }

    /// The count the lane's cursor stands at, none before a first read.
    fn cursor(&self) -> String {
        fs::read_to_string(self.lane_box().join("to-lane.cursor"))
            .unwrap_or_default()
            .trim()
            .to_owned()
    }

    fn sent_count(&self) -> String {
        fs::read_to_string(self.lane_box().join("sent-count")).unwrap_or_default()
    }

    /// The verb run from the lane under `harness`'s install, with the
    /// mailbox package's reader named.
    fn mail(&self, harness: &str, args: &[&str], payload: &str) -> Out {
        let reader = lane_mail().display().to_string();
        let env = [("LANE_MAIL_CLI", reader.as_str())];
        self.turn_in(&self.lane, &self.hooks(harness), args, payload, &env)
    }

    /// The Copilot lead `session`, as its start records it.
    fn lead(&self, session: &str) {
        plant(&self.leads().join(session));
    }
}

#[test]
fn unread_mail_holds_a_lanes_turn_end_and_is_marked_read_once_the_refusal_is_written() {
    let world = World::launched();
    world.direct("d1", "rebase onto main", false);
    world.direct("d2", "then push", false);
    let out = world.mail("claude", &[], "{}");
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.stdout, "");
    assert_eq!(out.first(), "lane-mail-check: unread=2");
    assert!(
        out.stderr.contains(
            "the overseer sent these messages to this lane; act on each as its text directs:\n{\"id\":\"d1\""
        ),
        "{}",
        out.stderr
    );
    assert!(
        out.stderr.contains("\"text\":\"then push\""),
        "{}",
        out.stderr
    );
    assert!(!out.stderr.contains("a halt among them"), "{}", out.stderr);
    assert_eq!(world.cursor(), "2");
    let out = world.mail("claude", &[], "{}");
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle={ITEM}"),
        "read once"
    );

    world.direct("d3", "and report", false);
    let out = world.mail("copilot", &[], "{}");
    assert_eq!(out.code, 0, "{}", out.stderr);
    let answer = out.json();
    assert_eq!(answer["decision"], "block");
    assert!(
        answer["reason"]
            .as_str()
            .unwrap()
            .starts_with("lane-mail-check: unread=1\n"),
        "{answer}"
    );
    assert_eq!(world.cursor(), "3");

    // A subagent's turn end is handed none; a continued one is not read.
    world.direct("d4", "later", false);
    let out = world.mail("claude", &[], r#"{"agent_id":"a1"}"#);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""));
    let out = world.mail("claude", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert!(!out.stderr.contains("unread="), "{}", out.stderr);
    assert_eq!(world.cursor(), "3");
}

#[test]
fn a_halt_refuses_every_tool_call_but_the_read_that_acknowledges_it() {
    let world = World::launched();
    let call = |command: &str| {
        json!({"tool_name": "Bash", "tool_input": {"command": command}}).to_string()
    };
    world.direct("d1", "go on", false);
    let out = world.mail("claude", &["halt"], &call("ls"));
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "no halt stands");

    world.direct("h1", "stop the push", true);
    let command = read_command(&world);
    let out = world.mail("claude", &["halt"], &call("ls"));
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: halt=h1");
    assert!(
        out.stderr.ends_with(&format!(
            "Run exactly this command, then act on the directive:\n{command}\nstop the push\n"
        )),
        "{}",
        out.stderr
    );
    let out = world.mail("claude", &["halt"], &call(&command));
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "the read passes");

    let out = world.mail(
        "claude",
        &["halt"],
        &json!({"agent_id": "a1", "tool_input": {"command": command}}).to_string(),
    );
    assert_eq!(out.code, 2, "a subagent is refused the read");
    assert_eq!(out.first(), "lane-mail-check: halt=h1");
    assert!(!out.stderr.contains(&command), "{}", out.stderr);
    assert!(
        out.stderr
            .contains("Stop, and report the halt to the lead:\nstop the push")
    );

    let unknown =
        json!({"sessionId": "s9", "toolName": "bash", "toolArgs": {"command": "ls"}}).to_string();
    let out = world.mail("copilot", &["halt"], &unknown);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.json()["permissionDecision"], "deny");
    assert!(!out.stderr.contains(&command), "{}", out.stderr);
    assert!(out.stderr.contains("is not shown here"), "{}", out.stderr);
    let unknown = json!({"sessionId": "s9", "toolName": "bash", "toolArgs": {"command": command}})
        .to_string();
    let out = world.mail("copilot", &["halt"], &unknown);
    assert_eq!(
        (out.code, out.stdout.as_str()),
        (0, ""),
        "an unknown caller may run the read"
    );
    assert_eq!(world.cursor(), "0", "the halt arm acknowledges nothing");

    // A turn end shows the lead the read, and its acknowledgement stops
    // short of the halt, which still stands.
    let out = world.mail("claude", &[], "{}");
    assert_eq!(out.first(), "lane-mail-check: unread=2");
    assert!(
        out.stderr.ends_with(&format!(
            "a halt among them refuses every tool call but one until the lane runs exactly this command:\n{command}\n"
        )),
        "{}",
        out.stderr
    );
    assert_eq!(world.cursor(), "1");
    let out = world.mail("claude", &["halt"], &call("ls"));
    assert_eq!(out.first(), "lane-mail-check: halt=h1");
}

#[test]
fn unread_mail_travels_as_context_after_a_tool_call_at_a_start_and_at_a_prompt() {
    let world = World::launched();
    world.direct("d1", "rebase", false);
    let out = world.mail("claude", &["deliver"], "{}");
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "{}", out.stderr);
    let answer = out.json();
    assert_eq!(answer["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    let context = answer["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap();
    assert!(
        context.starts_with("lane-mail-check: unread=1\n"),
        "{context}"
    );
    assert!(context.contains("\"text\":\"rebase\""), "{context}");
    assert_eq!(answer.as_object().unwrap().len(), 1, "{answer}");
    assert_eq!(world.cursor(), "1");

    world.direct("d2", "push", false);
    let out = world.mail("claude", &["start"], "{}");
    assert_eq!(
        out.json()["hookSpecificOutput"]["hookEventName"],
        "SessionStart"
    );
    assert_eq!(world.cursor(), "2");

    world.lead("s1");
    world.direct("d3", "report", false);
    let out = world.mail(
        "copilot",
        &["deliver"],
        r#"{"sessionId":"s1","toolName":"bash"}"#,
    );
    let answer = out.json();
    assert!(
        answer["additionalContext"]
            .as_str()
            .unwrap()
            .starts_with("lane-mail-check: unread=1\n"),
        "{answer}"
    );
    assert_eq!(answer.as_object().unwrap().len(), 1, "{answer}");
    assert_eq!(world.cursor(), "3");

    // A Copilot prompt's context may be dropped: it acknowledges nothing.
    world.direct("d4", "again", false);
    let out = world.mail("copilot", &["prompt"], r#"{"sessionId":"s1","prompt":"x"}"#);
    assert!(
        out.json()["additionalContext"].is_string(),
        "{}",
        out.stdout
    );
    assert_eq!(world.cursor(), "3");
    let out = world.mail("claude", &["prompt"], "{}");
    assert_eq!(
        out.json()["hookSpecificOutput"]["hookEventName"],
        "UserPromptSubmit"
    );
    assert_eq!(world.cursor(), "4");
}

#[test]
fn a_caller_that_sends_the_context_on_is_handed_the_acknowledgement() {
    let world = World::launched();
    world.direct("d1", "rebase", false);
    world.direct("d2", "push", false);
    let out = world.mail("pi", &["deliver"], r#"{"kendex_ack":"caller"}"#);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "{}", out.stderr);
    let answer = out.json();
    let argv: Vec<String> = serde_json::from_value(answer["kendex_ack"].clone()).unwrap();
    let root = world.lane.display().to_string();
    let reader = lane_mail().display().to_string();
    assert_eq!(
        argv,
        [
            reader.as_str(),
            "inbox",
            "--item",
            ITEM,
            "--root",
            root.as_str(),
            "--ack",
            "2"
        ]
    );
    assert!(answer["hookSpecificOutput"]["additionalContext"].is_string());
    assert_eq!(world.cursor(), "0", "the caller moves the cursor");
    let ran = program(&argv[0]).args(&argv[1..]).output().unwrap();
    assert!(ran.status.success(), "{}", stderr(&ran));
    assert_eq!(world.cursor(), "2");
}

#[test]
fn a_copilot_tool_call_from_no_recorded_lead_is_handed_no_mail() {
    let world = World::launched();
    world.direct("d1", "rebase", false);
    let out = world.mail(
        "copilot",
        &["deliver"],
        r#"{"sessionId":"s9","toolName":"bash"}"#,
    );
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: session-unrecorded=s9");
    assert!(
        out.stderr.contains("finished Copilot tool call"),
        "{}",
        out.stderr
    );
    assert_eq!(world.cursor(), "0");
}

#[test]
fn a_context_answer_stdout_cannot_take_is_refused_and_leaves_the_lines_unread() {
    let world = World::launched();
    world.direct("d1", "rebase", false);
    let mut command = isolated();
    let mut child = command
        .args(["turn-end", "--hook-dir"])
        .arg(world.hooks("claude"))
        .arg("deliver")
        .current_dir(&world.lane)
        .env("PWD", &world.lane)
        .env("HOME", &world.home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("LANE_MAIL_CLI", lane_mail())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(child.stdout.take());
    child.stdin.take().unwrap().write_all(b"{}").unwrap();
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{text}");
    assert_eq!(
        text.lines().next(),
        Some("lane-mail-check: notice=unwritten")
    );
    assert_eq!(world.cursor(), "0");
}

#[test]
fn a_reader_that_cannot_answer_is_refused_never_read_as_an_empty_mailbox() {
    let world = World::launched();
    world.direct("d1", "rebase", false);
    let absent = world.root.join("no-reader");
    let env = [("LANE_MAIL_CLI", absent.to_str().unwrap())];
    let out = world.turn_in(&world.lane, &world.hooks("claude"), &[], "{}", &env);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: reader={}", absent.display())
    );

    fs::remove_file(world.lane_box().join("to-lane.jsonl")).unwrap();
    fs::create_dir(world.lane_box().join("to-lane.jsonl")).unwrap();
    let out = world.mail("claude", &["halt"], r#"{"tool_input":{"command":"ls"}}"#);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: inbox=2");
    assert!(
        out.stderr.contains("lane-mail: mailbox-unsafe="),
        "{}",
        out.stderr
    );
}

#[test]
fn the_question_tool_is_refused_in_a_launched_lane_with_the_route_its_lead_runs() {
    let world = World::launched();
    let call = |extra: Value| {
        let mut payload = json!({"tool_name": "AskUserQuestion", "tool_input": {}});
        payload
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        payload.to_string()
    };
    let out = world.mail("claude", &["halt"], &call(json!({})));
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(
        out.first(),
        "lane-mail-check: question-tool=AskUserQuestion"
    );
    let (reader, root) = (
        lane_mail().display().to_string(),
        world.lane.display().to_string(),
    );
    assert!(
        out.stderr.ends_with(&format!(
            "then wait on the id the send prints:\n  {reader} ask --item {ITEM} --root {root} --file [PATH]\n  {reader} wait --item {ITEM} --root {root} --id [MSGID]\n"
        )),
        "{}",
        out.stderr
    );
    for tool in ["EnterPlanMode", "request_user_input", "question"] {
        let out = world.mail("claude", &["halt"], &call(json!({"tool_name": tool})));
        assert_eq!(
            out.first(),
            format!("lane-mail-check: question-tool={tool}")
        );
    }
    let out = world.mail(
        "claude",
        &["halt"],
        &call(json!({"agent_type": "reviewer"})),
    );
    assert_eq!(out.code, 2);
    assert!(
        out.stderr
            .contains("Stop, and report the question to the lead"),
        "{}",
        out.stderr
    );
    assert!(!out.stderr.contains(" ask --item "), "{}", out.stderr);
    let out = world.mail("claude", &["halt"], &call(json!({"tool_name": "Bash"})));
    assert_eq!((out.code, out.stderr.as_str()), (0, ""));

    // A session that is no launched lane asks its user as it always did.
    fs::remove_file(world.common().join("lane-mail").join(ITEM)).unwrap();
    let out = world.mail("claude", &["halt"], &call(json!({})));
    assert_eq!((out.code, out.stderr.as_str()), (0, ""));
}

#[test]
fn an_idle_turn_end_is_held_once_then_told_to_the_overseer() {
    let world = World::launched();
    let out = world.mail("claude", &[], "{}");
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle={ITEM}")
    );
    let (reader, root) = (
        lane_mail().display().to_string(),
        world.lane.display().to_string(),
    );
    assert!(
        out.stderr.contains(&format!(
            "continue the workflow:\n  {reader} inbox --item {ITEM} --root {root}\nSend a question"
        )),
        "{}",
        out.stderr
    );
    assert!(
        out.stderr.ends_with(&format!(
            "Send changed work as a notice:\n  {reader} notice --item {ITEM} --root {root} --file [PATH]\nFor a wait that continues, update this lane status file and end the turn:\n  {root}/tmp/lane-status-{ITEM}.md\n"
        )),
        "{}",
        out.stderr
    );
    assert_eq!(world.sent_count(), "0 held\n");

    let out = world.mail("claude", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle-notice={ITEM}")
    );
    assert_eq!(world.sent_count(), "1\n");
    let sent = fs::read_to_string(world.lane_box().join("to-overseer.jsonl")).unwrap();
    assert!(
        sent.contains(&format!("lane-mail-check: lane-idle={ITEM}")),
        "{sent}"
    );

    // The told notice is the lane's last report: the next turn end is held.
    let out = world.mail("claude", &[], "{}");
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle={ITEM}")
    );
    // A turn another hook continued is held as a fresh one.
    fs::write(world.lane_box().join("sent-count"), "1\n").unwrap();
    let out = world.mail("claude", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle={ITEM}")
    );
}

#[test]
fn a_report_since_the_last_judged_turn_end_passes_it() {
    let world = World::launched();
    let stop = |world: &World| world.mail("claude", &[], "{}");
    assert_eq!(
        stop(&world).after("unlisted"),
        format!("lane-mail-check: idle={ITEM}")
    );
    world.report("n1", "notice");
    let out = stop(&world);
    assert_eq!(
        (out.code, keyed(&out).as_str()),
        (0, "lane-mail-check: account=unlisted"),
        "a notice sent"
    );
    assert_eq!(world.sent_count(), "1\n", "the hold clears");
    world.report("a1", "ask");
    assert_eq!((stop(&world).code, world.sent_count().as_str()), (0, "2\n"));
    world.report("x1", "answer");
    assert_eq!(stop(&world).code, 2, "an answer is no report");

    let status = world
        .lane
        .join("tmp")
        .join(format!("lane-status-{ITEM}.md"));
    fs::write(&status, "waiting on CI\n").unwrap();
    let out = stop(&world);
    assert_eq!(
        (out.code, keyed(&out).as_str()),
        (0, "lane-mail-check: account=unlisted"),
        "a status file update"
    );
    assert_eq!(stop(&world).code, 2, "the same state again");
    fs::write(&status, "waiting on CI\n").unwrap();
    assert_eq!(stop(&world).code, 0, "a rewrite of the same text");
    fs::remove_file(&status).unwrap();
    assert_eq!(stop(&world).code, 2, "a removed file is no report");

    world.direct("h1", "stop", true);
    let out = stop(&world);
    assert_eq!(
        out.first(),
        "lane-mail-check: unread=1",
        "the mail is held first"
    );
    let read = program(lane_mail())
        .args(["inbox", "--item", ITEM, "--root"])
        .arg(&world.lane)
        .output()
        .unwrap();
    assert!(read.status.success(), "{}", stderr(&read));
    let out = stop(&world);
    assert_eq!(
        (out.code, keyed(&out).as_str()),
        (0, "lane-mail-check: account=unlisted"),
        "a halt standing"
    );
    assert!(
        !world.sent_count().contains("held"),
        "{}",
        world.sent_count()
    );
    world.direct("d2", "go on", false);
    assert_eq!(stop(&world).first(), "lane-mail-check: unread=1");
    assert_eq!(
        stop(&world).after("unlisted"),
        format!("lane-mail-check: idle={ITEM}"),
        "a later directive lifts the halt"
    );
}

#[test]
fn a_continued_pi_turn_end_tells_the_overseer_instead_of_holding() {
    let world = World::launched();
    let out = world.mail("pi", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(
        out.after("unmeasured"),
        format!("lane-mail-check: idle-notice={ITEM}")
    );
    assert_eq!(world.sent_count(), "1\n");
}

#[test]
fn a_record_or_listing_the_idle_judge_cannot_read_passes_the_turn_end_reported() {
    let world = World::launched();
    let record = world.lane_box().join("sent-count");
    for text in [
        "x\n",
        "1 held held\n",
        "01\n",
        "1 status=a/b held\n",
        "1 maybe\n",
    ] {
        fs::write(&record, text).unwrap();
        let out = world.mail("claude", &[], "{}");
        assert_eq!(
            (out.code, out.stdout.as_str()),
            (0, ""),
            "{text:?}: {}",
            out.stderr
        );
        assert_eq!(
            out.after("unlisted"),
            format!("lane-mail-check: idle-record={}", record.display()),
            "{text:?}"
        );
        assert_eq!(world.sent_count(), "0\n", "{text:?}: rewritten");
    }
    fs::remove_file(&record).unwrap();
    fs::create_dir(&record).unwrap();
    let out = world.mail("claude", &[], "{}");
    assert_eq!(out.code, 0, "{}", out.stderr);
    let lines: Vec<&str> = out
        .stderr
        .lines()
        .filter(|l| l.starts_with("lane-mail-check: "))
        .collect();
    assert_eq!(
        lines,
        [
            "lane-mail-check: account=unlisted".to_owned(),
            format!("lane-mail-check: idle-record={}", record.display()),
            format!("lane-mail-check: idle-unrecorded={}", record.display())
        ]
    );
    assert!(
        out.stderr
            .ends_with("compares against the record it already holds:\n"),
        "left, never written over: {}",
        out.stderr
    );
    fs::remove_dir(&record).unwrap();

    let status = world
        .lane
        .join("tmp")
        .join(format!("lane-status-{ITEM}.md"));
    std::os::unix::fs::symlink(world.root.join("elsewhere"), &status).unwrap();
    let out = world.mail("claude", &[], "{}");
    assert_eq!(
        out.after("unlisted"),
        format!("lane-mail-check: idle-status={}", status.display())
    );
    assert!(
        out.stderr.contains("no symbolic link at the file itself"),
        "{}",
        out.stderr
    );
    assert_eq!(
        out.last(),
        format!("  {}", status.display()),
        "held on the mail alone"
    );
    fs::remove_file(&status).unwrap();

    fs::create_dir(world.lane_box().join("to-overseer.jsonl")).unwrap();
    let out = world.mail("claude", &[], "{}");
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(out.after("unlisted"), "lane-mail-check: events=2");
    assert!(
        out.stderr.contains("lane-mail: mailbox-unsafe="),
        "{}",
        out.stderr
    );
}

#[test]
fn an_idle_notice_the_mailbox_or_the_record_cannot_take_is_reported_and_the_turn_ends() {
    let world = World::launched();
    let outbox = world.lane_box().join("to-overseer.jsonl");
    fs::write(&outbox, "").unwrap();
    fs::set_permissions(&outbox, fs::Permissions::from_mode(0o444)).unwrap();
    let out = world.mail("pi", &[], r#"{"stop_hook_active":true}"#);
    fs::set_permissions(&outbox, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(
        out.after("unmeasured"),
        "lane-mail-check: idle-notice-unsent=2"
    );
    assert!(
        out.stderr.contains("lane-mail: write-failed="),
        "{}",
        out.stderr
    );
    assert_eq!(world.sent_count(), "", "nothing recorded");

    let dir = world.lane_box();
    let mode = fs::metadata(&dir).unwrap().permissions();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o555)).unwrap();
    let out = world.mail("pi", &[], r#"{"stop_hook_active":true}"#);
    fs::set_permissions(&dir, mode).unwrap();
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    let lines: Vec<&str> = out
        .stderr
        .lines()
        .filter(|l| l.starts_with("lane-mail-check: "))
        .collect();
    assert_eq!(
        lines,
        [
            "lane-mail-check: account=unmeasured".to_owned(),
            format!(
                "lane-mail-check: idle-notice-unrecorded={}",
                dir.join("sent-count").display()
            ),
            format!("lane-mail-check: idle-notice={ITEM}"),
        ]
    );
    let sent = fs::read_to_string(&outbox).unwrap();
    assert!(sent.contains("lane-idle="), "the notice was sent: {sent}");
}

#[test]
fn a_hold_the_record_cannot_take_is_not_made() {
    let world = World::launched();
    let dir = world.lane_box();
    let mode = fs::metadata(&dir).unwrap().permissions();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o555)).unwrap();
    let out = world.mail("claude", &[], "{}");
    fs::set_permissions(&dir, mode).unwrap();
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(
        out.after("unlisted"),
        format!(
            "lane-mail-check: idle-hold-unrecorded={}",
            dir.join("sent-count").display()
        )
    );
}

// --- the handoff marks -----------------------------------------------------

/// The variables a row adds to the verb's environment.
type Env<'a> = &'a [(&'a str, &'a str)];

/// A Claude Code usage line as the session writes it, summing to `tokens`.
fn claude_usage(model: &str, tokens: u64) -> Value {
    json!({"type": "assistant", "message": {"model": model, "usage": {
        "input_tokens": 1, "cache_read_input_tokens": tokens - 8,
        "cache_creation_input_tokens": 0, "output_tokens": 7}}})
}

/// Claude's measured background `Agent` call and its launch result, the
/// result record stamped with `session` where one is named.
fn claude_launch(id: &str, session: Option<&str>) -> Vec<Value> {
    let call = format!("call-{id}");
    let mut result = json!({"type": "user", "toolUseResult": null, "message": {"role": "user",
        "content": [{"type": "tool_result", "tool_use_id": call,
            "content": format!("Async agent launched successfully. agentId: {id}"), "is_error": false}]}});
    if let Some(session) = session {
        result["sessionId"] = json!(session);
    }
    vec![
        json!({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": call, "name": "Agent", "input": {"run_in_background": true}}]}}),
        result,
    ]
}

/// A task notification Claude Code appends to a tool call's result.
fn claude_notification(id: &str, status: &str) -> Vec<Value> {
    vec![
        json!({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": format!("bash-{id}"), "name": "Bash", "input": {"command": "true"}}]}}),
        json!({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result",
            "tool_use_id": format!("bash-{id}"), "is_error": false,
            "content": format!("done\n<task-notification><task-id>{id}</task-id><status>{status}</status></task-notification>")}]}}),
    ]
}

impl World {
    /// A session file of `lines` under the scratch root.
    fn transcript(&self, name: &str, lines: &[Value]) -> PathBuf {
        let path = self.root.join(name);
        let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
        fs::write(&path, text).unwrap();
        path
    }

    fn record(&self) -> Value {
        let path = self.mail_root().join(ITEM).join("context.json");
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }
}

/// The record a lane's turn end leaves, and the context mark judged on it:
/// a reading below the mark passes and is recorded; one strictly past the
/// share of the window, or at the token count the setting names, whichever
/// comes first, is held with the commands that record the handoff and told
/// that count; a share or a count out of its form is held on the setting;
/// and a reading with no verified window below the count is reported
/// unmeasured.
#[test]
fn a_lane_turn_end_records_its_reading_and_is_held_past_the_context_mark() {
    let world = World::launched();
    let off = ("DISABLE_AUTO_COMPACT", "1");
    let cap = ("ORCH_HANDOFF_CONTEXT_TOKENS", "123457");
    // Below the mark the account mark is told, which no account here
    // measures: the released answer.
    let told = "lane-mail-check: account=unlisted";
    let rows: &[(u64, Env, i32, &str)] = &[
        (1_000, &[off], 0, told),
        (180_000, &[off], 0, told),
        (180_001, &[off], 2, "lane-mail-check: context=180001"),
        (
            100_001,
            &[off, ("ORCH_HANDOFF_CONTEXT_PCT", "50")],
            2,
            "lane-mail-check: context=100001",
        ),
        (650_000, &[], 2, "lane-mail-check: context=650000"),
        (
            649_999,
            &[],
            0,
            "lane-mail-check: window-unread=claude-haiku-5-5",
        ),
        (123_457, &[off, cap], 2, "lane-mail-check: context=123457"),
        (123_456, &[off, cap], 0, told),
        (150_000, &[off, cap], 2, "lane-mail-check: context=150000"),
        (
            1_000,
            &[],
            0,
            "lane-mail-check: window-unread=claude-haiku-5-5",
        ),
        (
            1_000,
            &[("ORCH_HANDOFF_CONTEXT_PCT", "101")],
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_PCT=101",
        ),
        (
            1_000,
            &[("ORCH_HANDOFF_CONTEXT_PCT", "0")],
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_PCT=0",
        ),
        (
            1_000,
            &[("ORCH_HANDOFF_CONTEXT_TOKENS", "65k")],
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_TOKENS=65k",
        ),
        (
            1_000,
            &[("ORCH_HANDOFF_CONTEXT_TOKENS", "0")],
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_TOKENS=0",
        ),
    ];
    for (tokens, env, code, first) in rows {
        let row = format!("{tokens} {env:?}");
        let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", *tokens)]);
        let payload = json!({"session_id": "s1", "transcript_path": transcript}).to_string();
        let out = world.turn_in(&world.lane, &world.hooks("claude"), &[], &payload, env);
        assert_eq!(out.code, *code, "{row}: {}", out.stderr);
        assert_eq!(out.first(), *first, "{row}");
        // The refusal the session reads names the count it was judged at.
        if *code == 2 && env.contains(&cap) {
            assert!(
                out.stderr.contains("123457 tokens used"),
                "{row}: {}",
                out.stderr
            );
        }
        if out.first().starts_with("lane-mail-check: setting-range") {
            continue;
        }
        let record = world.record();
        assert_eq!(record["tokens"], json!(tokens), "{row}");
        assert_eq!(record["session_id"], json!("s1"), "{row}");
        let window = if env.contains(&off) {
            json!(200_000)
        } else {
            Value::Null
        };
        assert_eq!(record["window"], window, "{row}");
    }
    // A record that cannot be written is reported and the reading still
    // judged; an install naming no harness reads no context and says so.
    let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", 1_000)]);
    let payload = json!({"session_id": "s1", "transcript_path": transcript}).to_string();
    let record = world.mail_root().join(ITEM).join("context.json");
    fs::remove_file(&record).unwrap();
    fs::create_dir_all(record.join("held")).unwrap();
    let out = world.turn_in(&world.lane, &world.hooks("claude"), &[], &payload, &[off]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: context-unrecorded={}", record.display())
    );
    fs::remove_dir_all(&record).unwrap();
    let unlisted = world.root.join("install").join("hooks");
    let out = world.turn_in(&world.lane, &unlisted, &[], &payload, &[off]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: harness-unlisted={}", unlisted.display())
    );
    assert!(!record.exists());
    // The refusal names the commands that record the handoff, the state
    // file's directory and the item's init on its branch, and the attached
    // agents the Stop payload's registry still names out.
    let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", 650_000)]);
    let payload = json!({"session_id": "s1", "transcript_path": transcript,
        "background_tasks": [{"type": "subagent", "id": "a1", "status": "running"},
            {"type": "shell", "id": "b1", "status": "running"}]})
    .to_string();
    let out = world.turn("claude", &[], &payload);
    assert_eq!(out.code, 2, "{}", out.stderr);
    let state_dir = world.lane.join("tmp");
    assert!(
        out.stderr
            .contains("lane-mail-check: attached-agent=a1 status=running output=unknown"),
        "{}",
        out.stderr
    );
    assert!(!out.stderr.contains("attached-agent=b1"), "{}", out.stderr);
    assert!(!out.stderr.contains("agents=unknown"), "{}", out.stderr);
    let init = format!(
        "--state-dir {} init {ITEM} --branch {ITEM}\n",
        state_dir.display()
    );
    assert!(out.stderr.contains(&init), "{}", out.stderr);
    let set = format!("--state-dir {} set {ITEM} handoff '", state_dir.display());
    let record = out
        .stderr
        .lines()
        .find_map(|line| {
            line.split_once(&set)
                .map(|(_, word)| word.trim_end_matches('\''))
        })
        .unwrap_or_else(|| panic!("no handoff command: {}", out.stderr));
    let record: Value = serde_json::from_str(record).unwrap();
    assert_eq!(record["context"]["decision"]["tokens"], json!(650_000));
    assert_eq!(record["context"]["decision"]["cap_mark"], json!(650_000));
    assert_eq!(record["context"]["source"]["session_id"], json!("s1"));
}

/// A lane whose handoff record stands is handing itself off and is never
/// held, whatever its reading; a transcript named and unreadable is held,
/// and a usage line the adapter cannot read is reported and passed.
#[test]
fn a_standing_handoff_passes_and_an_unreadable_transcript_is_held() {
    let world = World::launched();
    let past = world.transcript("t.jsonl", &[claude_usage("m", 650_000)]);
    let state = world
        .lane
        .join("tmp")
        .join(format!("workflow-state-{ITEM}.json"));
    fs::create_dir_all(state.parent().unwrap()).unwrap();
    fs::write(&state, json!({"handoff": {"remaining": ["x"]}}).to_string()).unwrap();
    let payload = json!({"transcript_path": past}).to_string();
    let out = world.turn("claude", &[], &payload);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "{}", out.stderr);
    // A state file that cannot be read passes a turn end with the gap named
    // and refuses an attached launch on that input.
    fs::write(&state, "not json").unwrap();
    let out = world.turn("claude", &[], &payload);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: handoff-unreadable={}", state.display())
    );
    let launch = json!({"transcript_path": past, "tool_name": "Agent"}).to_string();
    let out = world.turn("claude", &["halt"], &launch);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: agent-input=unreadable");
    assert!(
        out.stderr
            .contains("\nlane-mail-check: detached-route=orch-job-runner\n"),
        "{}",
        out.stderr
    );
    fs::remove_file(&state).unwrap();

    let missing = world.root.join("missing.jsonl");
    let payload = json!({"transcript_path": missing}).to_string();
    let out = world.turn("claude", &[], &payload);
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: transcript=unreadable");

    let unread = world.transcript(
        "u.jsonl",
        &[json!({"type": "assistant", "message": {"model": "m", "usage": {"other": 1}}})],
    );
    let payload = json!({"transcript_path": unread}).to_string();
    let out = world.turn("claude", &[], &payload);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: usage-unread={}", unread.display())
    );
}

/// An attached launch below both marks passes; at the context mark it is
/// refused with the handoff; past the mark less the reserve it is refused
/// while an agent the lead launched is out and passes once a record proves
/// that agent ended. A reserve out of its form is held on the setting.
#[test]
fn an_attached_launch_keeps_the_reserve_only_while_an_agent_may_be_out() {
    let world = World::launched();
    let off = ("DISABLE_AUTO_COMPACT", "1");
    let launched = claude_launch("a1", None);
    let ended: Vec<Value> = launched
        .iter()
        .cloned()
        .chain(claude_notification("a1", "completed"))
        .collect();
    let none: Vec<Value> = Vec::new();
    let rows: &[(u64, &[Value], Env, i32, &str)] = &[
        (20_000, &launched, &[off], 0, ""),
        (30_000, &none, &[off], 0, ""),
        (
            30_000,
            &launched,
            &[off],
            2,
            "lane-mail-check: agent-reserve=Agent tokens=30000 reserve=150000",
        ),
        (30_000, &ended, &[off], 0, ""),
        (
            30_000,
            &launched,
            &[off, ("ORCH_HANDOFF_AGENT_RESERVE_TOKENS", "0")],
            0,
            "",
        ),
        (
            30_000,
            &launched,
            &[off, ("ORCH_HANDOFF_AGENT_RESERVE_TOKENS", "1e5")],
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=1e5",
        ),
        (
            180_001,
            &none,
            &[off],
            2,
            "lane-mail-check: agent-launch=Agent tokens=180001",
        ),
        (
            20_000,
            &launched,
            &[off, ("ORCH_HANDOFF_AGENT_RESERVE_TOKENS", "400000")],
            2,
            "lane-mail-check: agent-reserve=Agent tokens=20000 reserve=400000",
        ),
        (
            1_000,
            &none,
            &[],
            2,
            "lane-mail-check: agent-input=context-unmeasured",
        ),
    ];
    for (tokens, agents, env, code, first) in rows {
        let row = format!("{tokens} {} {env:?}", agents.len());
        let mut lines = agents.to_vec();
        lines.push(claude_usage("claude-haiku-5-5", *tokens));
        let transcript = world.transcript("t.jsonl", &lines);
        let payload = json!({"session_id": "s1", "transcript_path": transcript,
            "tool_name": "Agent", "tool_input": {}})
        .to_string();
        let out = world.turn_in(
            &world.lane,
            &world.hooks("claude"),
            &["halt"],
            &payload,
            env,
        );
        assert_eq!(out.code, *code, "{row}: {}", out.stderr);
        assert_eq!(out.first(), *first, "{row}");
        if first.contains("agent-reserve") {
            assert!(
                out.stderr
                    .contains("lane-mail-check: attached-agent=a1 status=running output=unknown"),
                "{row}: {}",
                out.stderr
            );
            assert!(!out.stderr.contains(" handoff '"), "{row}: {}", out.stderr);
        }
    }
    let other = world.transcript("t.jsonl", &[claude_usage("m", 1_000)]);
    let payload = json!({"transcript_path": other, "tool_name": "Read"}).to_string();
    let out = world.turn("claude", &["halt"], &payload);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "no launch tool");
    // A launch with no reading to judge is refused on the gap that left it.
    let empty = world.transcript("e.jsonl", &[]);
    for (payload, gap) in [
        (json!({"tool_name": "Agent"}), "transcript-unnamed"),
        (
            json!({"tool_name": "Agent", "transcript_path": empty}),
            "usage-absent",
        ),
    ] {
        let out = world.turn("claude", &["halt"], &payload.to_string());
        assert_eq!(out.code, 2, "{gap}: {}", out.stderr);
        assert_eq!(out.first(), format!("lane-mail-check: agent-input={gap}"));
    }
}

/// A Pi lane's reading takes a window only where Pi's settings turn its
/// compaction off: the one the payload names, else the one its own record
/// holds for the same session and model. Settings that cannot be read are
/// reported and judged as compaction on.
#[test]
fn a_pi_reading_takes_its_window_from_the_payload_or_its_own_record() {
    let world = World::launched();
    let hooks = world.root.join("install").join(".pi/kendex/hooks");
    let agent = world.root.join("pi-agent");
    fs::create_dir_all(&agent).unwrap();
    let pi = |tokens: u64| {
        json!({"type": "message", "message": {"role": "assistant", "model": "m", "provider": "p",
            "usage": {"input": 1, "output": 7, "cacheRead": tokens - 8, "cacheWrite": 0}}})
    };
    let transcript = world.transcript("pi.jsonl", &[pi(950)]);
    let record = world.mail_root().join(ITEM).join("context.json");
    let dir = agent.display().to_string();
    let env = [("PI_CODING_AGENT_DIR", dir.as_str())];
    let held = json!({"harness": "pi", "model": "p/m", "tokens": 1, "window": 1000,
        "session_id": "s1", "pane_key": null, "gap": null, "at": "2026-11-11T00:00:00Z"})
    .to_string();
    let rows: &[(&str, Option<u64>, bool, i32, &str)] = &[
        (
            r#"{"compaction":{"enabled":false}}"#,
            None,
            true,
            2,
            "lane-mail-check: context=950",
        ),
        (
            r#"{"compaction":{"enabled":false}}"#,
            Some(2000),
            true,
            0,
            "lane-mail-check: account=unmeasured",
        ),
        (
            r#"{"compaction":{"enabled":false}}"#,
            None,
            false,
            0,
            "lane-mail-check: window-unread=p/m",
        ),
        ("{}", None, true, 0, "lane-mail-check: window-unread=p/m"),
        (
            "not json",
            None,
            true,
            0,
            "lane-mail-check: compaction-unread=pi",
        ),
    ];
    for (settings, window, recorded, code, first) in rows {
        let row = format!("{settings} {window:?} {recorded}");
        fs::write(agent.join("settings.json"), settings).unwrap();
        if *recorded {
            fs::write(&record, &held).unwrap();
        } else {
            let _ = fs::remove_file(&record);
        }
        let mut payload = json!({"session_id": "s1", "transcript_path": transcript});
        if let Some(window) = window {
            payload["context_window"] = json!(window);
        }
        let out = world.turn_in(&world.lane, &hooks, &[], &payload.to_string(), &env);
        assert_eq!(out.code, *code, "{row}: {}", out.stderr);
        assert_eq!(out.first(), *first, "{row}");
    }
    // Neither the payload nor the record names a window: Pi's own registry
    // is read through the `node` and the `pi` first on the turn end's PATH,
    // the window it names is recorded, and a registry that names none
    // leaves the window unread.
    fs::write(
        agent.join("settings.json"),
        r#"{"compaction":{"enabled":false}}"#,
    )
    .unwrap();
    let payload = json!({"session_id": "s1", "transcript_path": transcript}).to_string();
    let rows: &[(&str, i32, &str, Value)] = &[
        ("echo 1000", 2, "lane-mail-check: context=950", json!(1000)),
        ("true", 0, "lane-mail-check: window-unread=p/m", json!(null)),
    ];
    for (answer, code, first, window) in rows {
        let _ = fs::remove_file(&record);
        world.pi_registry(&agent, answer);
        let out = world.turn_in(&world.lane, &hooks, &[], &payload, &env);
        assert_eq!(out.code, *code, "{answer}: {}", out.stderr);
        assert_eq!(out.first(), *first, "{answer}");
        assert_eq!(world.record()["window"], *window, "{answer}");
    }
}

impl World {
    /// A `node` stand-in first on the verb's `PATH` in the contract the
    /// released suite's stub install fixes: handed the `pi` first on that
    /// `PATH`, the provider and the id of `p/m`, offline, under the Pi user
    /// directory `agent`, it runs `answer`, which prints the registry's
    /// window as one whole number or nothing; any other call is refused.
    fn pi_registry(&self, agent: &Path, answer: &str) {
        let pi = self.stand_ins().join("pi");
        let node = format!(
            "#!/bin/sh\nfor a; do p3=$p2; p2=$p1; p1=$a; done\n[ \"$p3\" = '{}' ] && [ \"$p2\" = p ] && [ \"$p1\" = m ] && [ \"$PI_OFFLINE\" = 1 ] && [ \"$PI_CODING_AGENT_DIR\" = '{}' ] || exit 4\n{answer}\n",
            pi.display(),
            agent.display()
        );
        write_executable(&self.stand_ins().join("node"), node);
    }
}

/// A helper last put out by a record of another session than the one the
/// payload names is no helper this session can wait for: it keeps the
/// reserve, and the refusal names the handoff instead of a wait.
#[test]
fn a_helper_from_another_session_keeps_the_reserve_unobserved() {
    let world = World::launched();
    let env = [("DISABLE_AUTO_COMPACT", "1")];
    for (launched_in, first) in [
        (
            "s1",
            "lane-mail-check: agent-reserve=Agent tokens=30000 reserve=150000",
        ),
        (
            "s0",
            "lane-mail-check: agent-unobserved=Agent tokens=30000 reserve=150000",
        ),
    ] {
        let mut lines = claude_launch("a1", Some(launched_in));
        lines.push(claude_usage("claude-haiku-5-5", 30_000));
        let transcript = world.transcript("t.jsonl", &lines);
        let payload =
            json!({"session_id": "s1", "transcript_path": transcript, "tool_name": "Agent"})
                .to_string();
        let out = world.turn_in(
            &world.lane,
            &world.hooks("claude"),
            &["halt"],
            &payload,
            &env,
        );
        assert_eq!(out.code, 2, "{launched_in}: {}", out.stderr);
        assert_eq!(out.first(), first, "{launched_in}");
        let names_handoff = out.stderr.contains(&format!(" set {ITEM} handoff '"));
        assert_eq!(names_handoff, launched_in == "s0", "{}", out.stderr);
    }
}

/// Codex's rollout: a spawned agent is out until a full listing reads it
/// returned, and the refusal tells the lead to list agents after its wait.
#[test]
fn a_codex_launch_keeps_the_reserve_until_a_listing_reads_the_agent_returned() {
    let world = World::launched();
    let overrides = json!({"harness": "codex", "settings": {
        "model_auto_compact_token_limit": "1000000",
        "model_auto_compact_token_limit_scope": "body_after_prefix",
        "model_post_turn_compact_threshold_percent": "0"}})
    .to_string();
    let env = [("ORCH_COMPACTION_OVERRIDES", overrides.as_str())];
    let item = |kind: &str, fields: Value| {
        let mut payload = fields;
        payload["type"] = json!(kind);
        json!({"type": "response_item", "payload": payload})
    };
    let spawned = vec![
        json!({"type": "turn_context", "payload": {"model": "gpt-5"}}),
        item(
            "function_call",
            json!({"name": "spawn_agent", "call_id": "c1", "arguments": "{}"}),
        ),
        item(
            "function_call_output",
            json!({"call_id": "c1", "output": "{\"task_name\":\"/root/a1\"}"}),
        ),
    ];
    let listed: Vec<Value> = spawned
        .iter()
        .cloned()
        .chain([
            item("function_call", json!({"name": "list_agents", "call_id": "c2", "arguments": "{}"})),
            item(
                "function_call_output",
                json!({"call_id": "c2", "output": "{\"agents\":[{\"agent_name\":\"/root/a1\",\"agent_status\":\"completed\"}]}"}),
            ),
        ])
        .collect();
    let count = json!({"type": "event_msg", "payload": {"type": "token_count", "info": {
        "last_token_usage": {"total_tokens": 510_000}, "model_context_window": 1_000_000}}});
    for (lines, code) in [(spawned, 2), (listed, 0)] {
        let mut lines = lines;
        lines.push(count.clone());
        let transcript = world.transcript("r.jsonl", &lines);
        let payload = json!({"session_id": "s1", "transcript_path": transcript,
            "tool_name": "spawn_agent", "tool_use_id": "c9"})
        .to_string();
        let out = world.turn_in(
            &world.lane,
            &world.hooks("codex"),
            &["halt"],
            &payload,
            &env,
        );
        assert_eq!(out.code, code, "{}", out.stderr);
        if code == 2 {
            assert_eq!(
                out.first(),
                "lane-mail-check: agent-reserve=spawn_agent tokens=510000 reserve=150000"
            );
            assert!(out.stderr.contains("Call list_agents"), "{}", out.stderr);
            assert!(
                out.stderr.contains(
                    "lane-mail-check: attached-agent=/root/a1 status=running output=unknown"
                ),
                "{}",
                out.stderr
            );
        }
    }
}

// --- the Copilot readings ----------------------------------------------------

impl World {
    /// The account directory a Copilot lane runs on, as `COPILOT_HOME`.
    fn copilot_home(&self) -> PathBuf {
        self.root.join("copilot-account")
    }

    /// A status-line record for `s1` written by the shipped
    /// `copilot-statusline` from the object the CLI hands it: `tokens` of a
    /// `window`, `transcript` bound where named, `allow_all` where named.
    fn status_line(
        &self,
        tokens: u64,
        window: u64,
        transcript: Option<&Path>,
        allow_all: Option<bool>,
    ) {
        let mut status = json!({"session_id": "s1", "model": {"id": "claude-opus-5"},
            "context_window": {"current_context_tokens": tokens, "context_window_size": window}});
        if let Some(transcript) = transcript {
            status["transcript_path"] = json!(transcript);
        }
        if let Some(allow_all) = allow_all {
            status["allow_all_enabled"] = json!(allow_all);
        }
        let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts");
        let out = program("bash")
            .args(["-c", r#"printf '%s' "$2" | "$1/copilot-statusline""#, "_"])
            .arg(scripts)
            .arg(status.to_string())
            .env("COPILOT_HOME", self.copilot_home())
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }

    /// The transcript Copilot writes for `s1` under the account's store.
    fn copilot_transcript(&self) -> PathBuf {
        self.copilot_home().join("session-state/s1/events.jsonl")
    }

    /// The status-line record's own file.
    fn status_record(&self) -> PathBuf {
        self.copilot_home().join("lane-status").join("s1.json")
    }

    /// A reading recorded in the lane's mailbox as the usage arm records the
    /// extension's: `capacity` the share it compacts at, for `session`,
    /// under `source`.
    fn extension_reading(&self, tokens: Option<u64>, capacity: u64, session: &str, source: &str) {
        let gap = if tokens.is_none() {
            json!("pane-unrecorded")
        } else {
            Value::Null
        };
        let record = json!({"harness": "copilot", "model": null, "tokens": tokens,
            "window": capacity, "capacity_source": source, "session_id": session,
            "pane_key": null, "gap": gap, "at": "2026-11-11T00:00:00Z"});
        fs::write(
            self.mail_root().join(ITEM).join("context.json"),
            record.to_string(),
        )
        .unwrap();
    }

    /// A Copilot lead's turn end of `s1`, its transcript under the account's
    /// store, with `env` added to the account's `COPILOT_HOME`.
    fn copilot_stop(&self, env: Env) -> Out {
        let transcript = self.copilot_transcript();
        let payload =
            json!({"sessionId": "s1", "transcriptPath": transcript, "timestamp": 1}).to_string();
        let home = self.copilot_home().display().to_string();
        let mut env = env.to_vec();
        env.push(("COPILOT_HOME", home.as_str()));
        self.turn_in(&self.lane, &self.hooks("copilot"), &[], &payload, &env)
    }
}

const EXTENSION: &str = "80% of tokenLimit, Copilot's backgroundCompactionThreshold default";

/// The keyed lines of an answer's stderr.
fn keyed(out: &Out) -> String {
    out.stderr
        .lines()
        .filter(|l| l.starts_with("lane-mail-check: "))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A status-line row: the record's tokens and window, the transcript it is
/// bound to and its allow-all report, the variables the turn end runs
/// with, its first line and its decision.
type StatusRow<'a> = (u64, u64, &'a Path, Option<bool>, Env<'a>, &'a str, &'a str);

/// A Copilot lane with no extension reading is read from its fresh
/// status-line record, judged on the share of its window Copilot compacts
/// at and recorded; a record of another transcript, a stale one or none
/// leaves the context unmeasured and passes; a policy that took the
/// granted allow-all mode is reported beside the judgement.
#[test]
fn a_copilot_lane_with_no_extension_reading_is_judged_on_its_status_line_record() {
    let world = World::launched();
    let gap = |reason: &str| {
        format!(
            "lane-mail-check: reading-unrecorded={}\nlane-mail-check: session-record={reason}\nlane-mail-check: account=unmeasured",
            world.mail_root().join(ITEM).join("context.json").display()
        )
    };
    let out = world.copilot_stop(&[]);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(keyed(&out), gap("missing"));
    let transcript = world.copilot_transcript();
    let other = world.root.join("session-state/s2/events.jsonl");
    let grant: Env = &[("COPILOT_ALLOW_ALL", "true")];
    let policy = "lane-mail-check: stop-cause=allow-all-blocked-by-policy";
    // Below the mark the account mark is told, which nothing here measures.
    let told = "lane-mail-check: account=unmeasured";
    let rows: &[StatusRow] = &[
        (100_000, 1_000_000, &transcript, None, &[], told, ""),
        (
            650_000,
            1_000_000,
            &transcript,
            None,
            &[],
            "lane-mail-check: context=650000",
            "block",
        ),
        (
            150_000,
            200_000,
            &transcript,
            None,
            &[],
            "lane-mail-check: context=150000",
            "block",
        ),
        (140_000, 200_000, &transcript, None, &[], told, ""),
        (
            100_000,
            1_000_000,
            &other,
            None,
            &[],
            "wrong-transcript",
            "",
        ),
        (
            100_000,
            1_000_000,
            &transcript,
            Some(false),
            grant,
            policy,
            "",
        ),
        (100_000, 1_000_000, &transcript, Some(false), &[], told, ""),
    ];
    for (tokens, window, bound, allow_all, env, first, decision) in rows {
        let row = format!("{tokens} {window} {bound:?} {allow_all:?} {env:?}");
        world.status_line(*tokens, *window, Some(bound), *allow_all);
        let out = world.copilot_stop(env);
        assert_eq!(out.code, 0, "{row}: {}", out.stderr);
        if !first.is_empty() && !first.contains(' ') {
            assert_eq!(keyed(&out), gap(first), "{row}");
            continue;
        }
        assert_eq!(out.first(), *first, "{row}");
        let answer = if decision.is_empty() {
            Value::Null
        } else {
            out.json()["decision"].clone()
        };
        let want = if decision.is_empty() {
            Value::Null
        } else {
            json!(decision)
        };
        assert_eq!(answer, want, "{row}");
        let record = world.record();
        assert_eq!(
            [
                &record["harness"],
                &record["tokens"],
                &record["window"],
                &record["model"],
                &record["capacity_source"]
            ],
            [
                &json!("copilot"),
                &json!(tokens),
                &json!(window * 80 / 100),
                &json!("claude-opus-5"),
                &json!("80% of context_window_size, from the Copilot statusLine session record")
            ],
            "{row}"
        );
    }
    // A record the status line stopped refreshing is never read as room.
    world.status_line(650_000, 1_000_000, Some(&transcript), None);
    let mut record: Value =
        serde_json::from_str(&fs::read_to_string(world.status_record()).unwrap()).unwrap();
    record["written_at"] = json!(1);
    fs::write(world.status_record(), record.to_string()).unwrap();
    let out = world.copilot_stop(&[]);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(keyed(&out), gap("stale"));
}

/// The extension's reading of this session is read first and never
/// overridden by the status-line record; one of another session and a gap
/// record give way to it. A flagged automatic compaction holds the turn end
/// whatever the reading, a record that stands and cannot be read is held,
/// and a reading still on its way leaves the context unmeasured.
#[test]
fn a_copilot_lanes_extension_reading_comes_first_and_its_compaction_flag_holds() {
    let world = World::launched();
    let transcript = world.copilot_transcript();
    // The extension's reading stands alone where no status-line record
    // answers.
    world.extension_reading(Some(720_001), 800_000, "s1", EXTENSION);
    let out = world.copilot_stop(&[]);
    assert_eq!(out.first(), "lane-mail-check: context=720001");
    world.status_line(650_000, 1_000_000, Some(&transcript), None);
    let held = "lane-mail-check: context=650000";
    let rows: &[(Option<u64>, &str, &str, &str)] = &[
        (
            Some(100_000),
            "s1",
            EXTENSION,
            "lane-mail-check: account=unmeasured",
        ),
        (
            Some(720_001),
            "s1",
            EXTENSION,
            "lane-mail-check: context=720001",
        ),
        (Some(100_000), "s0", EXTENSION, held),
        (None, "s1", "pane-unrecorded", held),
    ];
    for (tokens, session, source, first) in rows {
        let row = format!("{tokens:?} {session} {source}");
        world.extension_reading(*tokens, 800_000, session, source);
        let out = world.copilot_stop(&[]);
        assert_eq!(out.code, 0, "{row}: {}", out.stderr);
        assert_eq!(out.first(), *first, "{row}");
    }
    let record = world.mail_root().join(ITEM).join("context.json");
    fs::write(&record, "not json").unwrap();
    let out = world.copilot_stop(&[]);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: record={}", record.display())
    );
    assert_eq!(out.json()["decision"], json!("block"));
    fs::remove_file(&record).unwrap();
    // The compaction flag: this session's holds whatever the reading, and
    // the handoff it names records the compaction; one of another session,
    // or of none, flags nothing.
    world.status_line(100_000, 1_000_000, Some(&transcript), None);
    let flag = world.mail_root().join(ITEM).join("compaction.json");
    let flags = [
        (json!("s1"), "lane-mail-check: compacted=auto"),
        (json!("s0"), "lane-mail-check: account=unmeasured"),
        (Value::Null, "lane-mail-check: account=unmeasured"),
    ];
    for (session, first) in flags {
        let planted = json!({"harness": "copilot", "trigger": "auto", "session_id": session,
            "pane_key": null, "at": "2026-11-11T00:00:00Z"});
        fs::write(&flag, planted.to_string()).unwrap();
        let out = world.copilot_stop(&[]);
        assert_eq!(out.code, 0, "{session}: {}", out.stderr);
        assert_eq!(out.first(), first, "{session}");
        if first == "lane-mail-check: compacted=auto" {
            assert!(
                out.stderr.contains(r#""compacted":true"#),
                "{session}: {}",
                out.stderr
            );
        }
    }
    // A flag that stands and cannot be read as one is held.
    fs::write(&flag, "[]").unwrap();
    let out = world.copilot_stop(&[]);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: record={}", flag.display())
    );
    fs::remove_file(&flag).unwrap();
    fs::create_dir(&flag).unwrap();
    let out = world.copilot_stop(&[]);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: record={}", flag.display())
    );
    fs::remove_dir(&flag).unwrap();
    // A reading still on its way: its pending marker outlasts the wait, and
    // the record past the mark is not judged in its place.
    world.status_line(650_000, 1_000_000, Some(&transcript), None);
    let marker = world.usage().join("s1");
    plant(&marker);
    let out = world.copilot_stop(&[]);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: reading-pending={}", marker.display())
    );
    // A payload naming no session has no reading on its way, whatever
    // markers other sessions left.
    let home = world.copilot_home().display().to_string();
    let out = world.turn_in(
        &world.lane,
        &world.hooks("copilot"),
        &[],
        r#"{"timestamp":1}"#,
        &[("COPILOT_HOME", home.as_str())],
    );
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        out.first(),
        format!("lane-mail-check: reading-unrecorded={}", record.display())
    );
}

/// A Copilot lead's attached launch: refused on the gap where no reading
/// stands, and past the mark less the reserve refused unobserved, since no
/// record of Copilot's names an attached agent's return.
#[test]
fn a_copilot_attached_launch_is_refused_on_a_gap_and_unobserved_past_the_reserve() {
    let world = World::launched();
    world.lead("s1");
    let home = world.copilot_home().display().to_string();
    let payload = json!({"sessionId": "s1", "toolName": "task", "timestamp": 1}).to_string();
    let launch = || {
        world.turn_in(
            &world.lane,
            &world.hooks("copilot"),
            &["halt"],
            &payload,
            &[("COPILOT_HOME", home.as_str())],
        )
    };
    let out = launch();
    assert_eq!(out.code, 2, "{}", out.stderr);
    let record = world.mail_root().join(ITEM).join("context.json");
    assert_eq!(
        out.first(),
        format!("lane-mail-check: reading-unrecorded={}", record.display())
    );
    assert!(
        out.stderr
            .contains("\nlane-mail-check: agent-input=session-record\n"),
        "{}",
        out.stderr
    );
    world.status_line(30_000, 200_000, None, None);
    let out = launch();
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(
        out.first(),
        "lane-mail-check: agent-unobserved=task tokens=30000 reserve=150000"
    );
    assert!(
        out.stderr.contains("agent-roster=unread harness=copilot"),
        "{}",
        out.stderr
    );
    // A flagged automatic compaction leaves no reading to judge the launch on.
    let flag = json!({"harness": "copilot", "trigger": "auto", "session_id": "s1",
        "pane_key": null, "at": "2026-11-11T00:00:00Z"});
    fs::write(
        world.mail_root().join(ITEM).join("compaction.json"),
        flag.to_string(),
    )
    .unwrap();
    let out = launch();
    assert_eq!(out.code, 2, "{}", out.stderr);
    assert_eq!(out.first(), "lane-mail-check: agent-input=usage-absent");
}

// --- the record the review admission reads -----------------------------------

/// The pid the planted `tmux` server answers, and so the server half of
/// every pane key a row's session carries.
const SERVER_PID: &str = "4242";

impl World {
    /// The environment of a session on `pane` of a planted tmux server: a
    /// `tmux` stand-in first on `PATH` answers the server read alone, with
    /// [`SERVER_PID`], and refuses every other call.
    fn on_pane(&self, pane: &str) -> Vec<(String, String)> {
        write_executable(
            &self.stand_ins().join("tmux"),
            format!(
                "#!/bin/sh\n[ \"$1\" = -S ] && shift 2\ncase \"$*\" in\n  'display-message -p #{{pid}} #{{start_time}}') printf '{SERVER_PID} 1700000000\\n' ;;\n  *) printf 'tmux stand-in: no answer for: %s\\n' \"$*\" >&2; exit 1 ;;\nesac\n"
            ),
        );
        vec![
            (
                "TMUX".to_owned(),
                format!("{},{SERVER_PID},0", self.root.join("tmux-socket").display()),
            ),
            ("TMUX_PANE".to_owned(), pane.to_owned()),
        ]
    }

    /// The lane's context record as a row plants it.
    fn plant_record(&self, record: Value) {
        fs::write(
            self.mail_root().join(ITEM).join("context.json"),
            record.to_string(),
        )
        .unwrap();
    }
}

fn borrowed(env: &[(String, String)]) -> Vec<(&str, &str)> {
    env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
}

/// A lane's tool call binds its record to the session the payload names,
/// with the caller's pane key and the transcript, wherever the record names
/// another session or none; a record of this session stands as it is; and
/// the turn end's reading carries the same key and transcript.
#[test]
fn a_tool_call_binds_the_lanes_record_to_its_own_session_and_pane() {
    let world = World::launched();
    let pane = world.on_pane("%3");
    let env = borrowed(&pane);
    let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", 1_000)]);
    let call = json!({"session_id": "s1", "transcript_path": transcript,
        "tool_name": "Bash", "tool_input": {"command": "true"}})
    .to_string();
    let bound = |record: &Value| {
        json!([
            record["session_id"],
            record["pane_key"],
            record["transcript"],
            record["tokens"]
        ])
    };
    let key = format!("{SERVER_PID} %3");
    let fresh = json!(["s1", key, transcript, null]);
    // `(the record standing, the record after the call)`: none, another
    // session's at another pane and one naming no session are replaced;
    // this session's own reading stands.
    let own = json!({"harness": "claude", "tokens": 900, "session_id": "s1",
        "pane_key": format!("{SERVER_PID} %3"), "gap": null, "at": "2026-11-11T00:00:00Z"});
    let rows: &[(Option<Value>, Value)] = &[
        (None, fresh.clone()),
        (
            Some(json!({"harness": "claude", "tokens": 5, "session_id": "s0",
                "pane_key": format!("{SERVER_PID} %1"), "gap": null, "at": "2026-11-11T00:00:00Z"})),
            fresh.clone(),
        ),
        (
            Some(
                json!({"harness": "claude", "tokens": 5, "gap": null, "at": "2026-11-11T00:00:00Z"}),
            ),
            fresh.clone(),
        ),
        (Some(own.clone()), bound(&own)),
    ];
    for (standing, want) in rows {
        let record = world.mail_root().join(ITEM).join("context.json");
        match standing {
            Some(standing) => world.plant_record(standing.clone()),
            None => {
                let _ = fs::remove_file(&record);
            }
        }
        let out = world.turn_in(&world.lane, &world.hooks("claude"), &["halt"], &call, &env);
        assert_eq!((out.code, out.stderr.as_str()), (0, ""), "{standing:?}");
        assert_eq!(bound(&world.record()), *want, "{standing:?}");
    }
    let off = ("DISABLE_AUTO_COMPACT", "1");
    let mut stop_env = env.clone();
    stop_env.push(off);
    let stop = json!({"session_id": "s1", "transcript_path": transcript}).to_string();
    let out = world.turn_in(&world.lane, &world.hooks("claude"), &[], &stop, &stop_env);
    assert_eq!(out.code, 0, "{}", out.stderr);
    assert_eq!(
        bound(&world.record()),
        json!(["s1", key, transcript, 1_000])
    );
}

impl World {
    /// The review admission for `launch` run from the lane, with `env`
    /// added.
    fn admission(&self, launch: &str, env: Env) -> Out {
        let mut command = isolated();
        command
            .args(["admission", "--item", ITEM, launch])
            .current_dir(&self.lane)
            .env("PWD", &self.lane)
            .env("HOME", &self.home)
            .env("PATH", tool_path(&[&self.stand_ins()]))
            .env("GIT_CONFIG_NOSYSTEM", "1");
        for (name, value) in env {
            command.env(name, value);
        }
        let out = command.output().expect("orch-runtime");
        Out {
            code: out.status.code().expect("an exit status"),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }

    /// A tool call of session `s1` under `harness`'s install naming
    /// `transcript`, the one that binds the lane's record.
    fn tool_call(&self, harness: &str, transcript: Option<&Path>, env: Env) {
        let mut call = json!({"session_id": "s1", "tool_name": "Bash",
            "tool_input": {"command": "true"}});
        if let Some(transcript) = transcript {
            call["transcript_path"] = json!(transcript);
        }
        let out = self.turn_in(
            &self.lane,
            &self.hooks(harness),
            &["halt"],
            &call.to_string(),
            env,
        );
        assert_eq!((out.code, out.stderr.as_str()), (0, ""), "{call}");
    }
}

/// One setting a row adds, where it adds one.
type Setting<'a> = Option<(&'a str, &'a str)>;

/// The transcript lines a row writes, where it writes any.
type Lines<'a> = Option<&'a [Value]>;

/// The verdict and the first keyed line of an admission's answer.
fn admitted(out: &Out) -> (i32, String) {
    if out.code == 0 {
        assert_eq!(out.stderr, "", "a pass names nothing on stderr");
        return (0, out.json()["verdict"].as_str().unwrap_or("").to_owned());
    }
    assert_eq!(out.stdout, "", "a refusal prints no verdict");
    (out.code, out.first().to_owned())
}

/// The admission answers from the record the session's own tool call bound,
/// reading the transcript fresh at every call: an attached launch is judged
/// with the attached-agent reserve and a checkpoint on the plain mark, each
/// settings word and each missing input refused by name, and the answer
/// names the decision and the native session it was read for.
#[test]
fn the_admission_judges_the_session_its_own_tool_call_bound() {
    let world = World::launched();
    let pane = world.on_pane("%3");
    let mut env = borrowed(&pane);
    env.push(("DISABLE_AUTO_COMPACT", "1"));
    let transcript = world.root.join("t.jsonl");
    world.tool_call("claude", Some(&transcript), &env);
    // `(tokens, launch, setting, verdict or first keyed line)`, the window
    // 200000 and the mark 90 percent: 180000 plain, 30000 less the reserve.
    let reserve = |value| ("ORCH_HANDOFF_AGENT_RESERVE_TOKENS", value);
    let rows: &[(u64, &str, Setting, i32, &str)] = &[
        (20_000, "--attached-launch", None, 0, "room"),
        (30_000, "--attached-launch", None, 0, "due"),
        (30_000, "--checkpoint", None, 0, "room"),
        (180_000, "--checkpoint", None, 0, "room"),
        (180_001, "--checkpoint", None, 0, "due"),
        (20_000, "--attached-launch", Some(reserve("0")), 0, "room"),
        (
            20_000,
            "--attached-launch",
            Some(reserve("1e5")),
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=1e5",
        ),
        (20_000, "--checkpoint", Some(reserve("1e5")), 0, "room"),
        (
            20_000,
            "--checkpoint",
            Some(("ORCH_HANDOFF_CONTEXT_PCT", "101")),
            2,
            "lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_PCT=101",
        ),
        (
            20_000,
            "--checkpoint",
            Some(("DISABLE_AUTO_COMPACT", "")),
            2,
            "lane-mail-check: agent-input=context-unmeasured",
        ),
    ];
    for (tokens, launch, setting, code, want) in rows {
        let row = format!("{tokens} {launch} {setting:?}");
        world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", *tokens)]);
        let mut env = env.clone();
        env.extend(setting.iter().copied());
        let out = world.admission(launch, &env);
        assert_eq!(
            admitted(&out),
            (*code, (*want).to_owned()),
            "{row}: {}",
            out.stderr
        );
        if *code == 0 {
            let answer = out.json();
            assert_eq!(answer["decision"]["tokens"], json!(tokens), "{row}");
            let reserved = *launch == "--attached-launch";
            assert_eq!(
                answer["decision"]["reserve_applied"],
                json!(reserved),
                "{row}"
            );
            assert_eq!(
                answer["source"],
                json!({"harness": "claude", "session_id": "s1", "transcript": transcript,
                    "pane_key": null, "capacity_source": null, "compacted": false}),
                "{row}"
            );
        }
    }
    // Each input a reading needs, refused by name with nothing started.
    let unread = json!({"type": "assistant", "message": {"model": "m", "usage": {"other": 1}}});
    let missing = world.root.join("missing.jsonl");
    let rows: &[(Lines, Option<&Path>, &str)] = &[
        (
            None,
            None,
            "lane-mail-check: agent-input=transcript-unnamed",
        ),
        (
            None,
            Some(&missing),
            "lane-mail-check: transcript=unreadable",
        ),
        (
            Some(&[]),
            Some(&transcript),
            "lane-mail-check: agent-input=usage-absent",
        ),
        (
            Some(&[unread]),
            Some(&transcript),
            "lane-mail-check: agent-input=usage-unread",
        ),
    ];
    for (lines, named, want) in rows {
        if let Some(lines) = lines {
            world.transcript("t.jsonl", lines);
        }
        world.plant_record(
            json!({"harness": "claude", "gap": "tool-call", "session_id": "s1",
            "pane_key": format!("{SERVER_PID} %3"), "transcript": named,
            "at": "2026-11-11T00:00:00Z"}),
        );
        let out = world.admission("--attached-launch", &env);
        assert_eq!(admitted(&out), (2, (*want).to_owned()), "{}", out.stderr);
    }
}

/// The admission binds only a record of the session at the caller's own
/// pane: none, one of zero bytes or not an object, one naming no session
/// and one written at another pane are refused by name; a lane with no pane
/// is told apart by the session id its own tool call wrote.
#[test]
fn the_admission_refuses_a_record_of_no_session_or_another_pane() {
    let world = World::launched();
    let record = world.mail_root().join(ITEM).join("context.json");
    let unrecorded = format!("lane-mail-check: session-unrecorded={}", record.display());
    let at_three = world.on_pane("%3");
    let at_four = world.on_pane("%4");
    let mut three = borrowed(&at_three);
    three.push(("DISABLE_AUTO_COMPACT", "1"));
    let mut four = borrowed(&at_four);
    four.push(("DISABLE_AUTO_COMPACT", "1"));
    let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", 1_000)]);
    let out = world.admission("--attached-launch", &three);
    assert_eq!(admitted(&out), (2, unrecorded.clone()), "{}", out.stderr);
    for text in ["", "[]"] {
        fs::write(&record, text).unwrap();
        let out = world.admission("--attached-launch", &three);
        assert_eq!(
            admitted(&out),
            (2, unrecorded.clone()),
            "{text:?}: {}",
            out.stderr
        );
    }
    world.plant_record(json!({"harness": "claude", "tokens": 5, "gap": null,
        "pane_key": format!("{SERVER_PID} %3"), "at": "2026-11-11T00:00:00Z"}));
    let out = world.admission("--attached-launch", &three);
    assert_eq!(admitted(&out), (2, unrecorded), "{}", out.stderr);
    world.tool_call("claude", Some(&transcript), &three);
    let out = world.admission("--attached-launch", &four);
    assert_eq!(
        admitted(&out),
        (
            2,
            format!("lane-mail-check: session-other-pane={SERVER_PID} %3 caller={SERVER_PID} %4")
        ),
        "{}",
        out.stderr
    );
    let out = world.admission("--attached-launch", &three);
    assert_eq!(admitted(&out), (0, "room".to_owned()), "{}", out.stderr);
    let paneless = [("DISABLE_AUTO_COMPACT", "1")];
    let out = world.admission("--attached-launch", &paneless);
    assert_eq!(
        admitted(&out),
        (
            2,
            format!("lane-mail-check: session-other-pane={SERVER_PID} %3 caller=none")
        ),
        "{}",
        out.stderr
    );
    fs::remove_file(&record).unwrap();
    world.tool_call("claude", Some(&transcript), &paneless);
    let out = world.admission("--attached-launch", &paneless);
    assert_eq!(admitted(&out), (0, "room".to_owned()), "{}", out.stderr);
}

impl World {
    /// `orch-runtime session` run from the lane, with `env` added.
    fn session(&self, env: Env) -> Out {
        let mut command = isolated();
        command
            .arg("session")
            .current_dir(&self.lane)
            .env("PWD", &self.lane)
            .env("HOME", &self.home)
            .env("PATH", tool_path(&[&self.stand_ins()]))
            .env("GIT_CONFIG_NOSYSTEM", "1");
        for (name, value) in env {
            command.env(name, value);
        }
        let out = command.output().expect("orch-runtime");
        Out {
            code: out.status.code().expect("an exit status"),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }
}

/// A call naming no session answers for the session the lane's record binds
/// at the caller's pane, read from that session's own transcript, with the
/// name its launch declared: `agent-runtime session model`'s three lines.
/// With no record, or one bound at another pane, it is `session-unnamed`
/// naming the record, and nothing of the record's session is printed.
#[test]
fn a_call_naming_no_session_reads_the_session_bound_at_its_pane() {
    let world = World::launched();
    let record = world.mail_root().join(ITEM).join("context.json");
    let unnamed = format!("session-unnamed record={} cause=", record.display());
    let at_three = world.on_pane("%3");
    let at_four = world.on_pane("%4");
    let mut three = borrowed(&at_three);
    three.push(("AGENT_RUNTIME_LAUNCH_AGENT", ITEM));
    let four = borrowed(&at_four);
    let transcript = world.transcript("t.jsonl", &[claude_usage("claude-haiku-5-5", 1_000)]);
    let refused = |out: &Out| {
        out.code == 2 && out.stdout.lines().count() == 1 && out.stdout.starts_with(&unnamed)
    };
    let out = world.session(&three);
    assert!(refused(&out), "no record: {} {}", out.stdout, out.stderr);
    world.tool_call("claude", Some(&transcript), &three);
    let out = world.session(&three);
    assert_eq!(
        (out.code, out.stdout.as_str()),
        (
            1,
            "model=claude-haiku-5-5 source=session\nsession-effort-unrecorded harness=claude session=s1\nagent=ken-1 source=launch\n"
        ),
        "{}",
        out.stderr
    );
    let out = world.session(&four);
    assert!(refused(&out), "another pane: {} {}", out.stdout, out.stderr);
}

/// A Codex attached launch the reserve alone refuses, the plain mark still
/// with room, is admitted to process-owned reviewers; at the plain mark it
/// is due, and a checkpoint or another harness keeps its plain verdict. A
/// Copilot session flagged compacting is due before any judgement, and its
/// extension reading is judged as any other.
#[test]
fn the_admission_names_codex_alternate_review_and_copilot_compaction() {
    let world = World::launched();
    let pane = world.on_pane("%3");
    let overrides = json!({"harness": "codex", "settings": {
        "model_auto_compact_token_limit": "1000000",
        "model_auto_compact_token_limit_scope": "body_after_prefix",
        "model_post_turn_compact_threshold_percent": "0"}})
    .to_string();
    let mut env = borrowed(&pane);
    env.push(("ORCH_COMPACTION_OVERRIDES", overrides.as_str()));
    let transcript = world.root.join("r.jsonl");
    world.tool_call("codex", Some(&transcript), &env);
    // The token cap is 650000; the reserve 150000 leaves 500000 below it.
    let rows: &[(u64, &str, &str)] = &[
        (499_999, "--attached-launch", "room"),
        (510_000, "--attached-launch", "alternate-review"),
        (510_000, "--checkpoint", "room"),
        (650_000, "--attached-launch", "due"),
    ];
    for (tokens, launch, want) in rows {
        world.transcript(
            "r.jsonl",
            &[
                json!({"type": "turn_context", "payload": {"model": "gpt-5"}}),
                json!({"type": "event_msg", "payload": {"type": "token_count", "info": {
                    "last_token_usage": {"total_tokens": tokens}, "model_context_window": 1_000_000}}}),
            ],
        );
        let out = world.admission(launch, &env);
        assert_eq!(
            admitted(&out),
            (0, (*want).to_owned()),
            "{tokens} {launch}: {}",
            out.stderr
        );
        if *want == "alternate-review" {
            let decision = &out.json()["decision"];
            assert_eq!(decision["reserve_applied"], json!(true));
            assert_eq!(out.json()["source"]["harness"], json!("codex"));
        }
    }
    // Copilot: the extension's reading judged, then the compaction flag.
    let copilot = World::launched();
    let pane = copilot.on_pane("%3");
    let mut env = borrowed(&pane);
    let account = copilot.copilot_home().display().to_string();
    env.push(("COPILOT_HOME", account.as_str()));
    copilot.plant_record(json!({"harness": "copilot", "model": null, "tokens": 1_000,
        "window": 200_000, "capacity_source": EXTENSION, "session_id": "s1",
        "pane_key": format!("{SERVER_PID} %3"), "gap": null, "at": "2026-11-11T00:00:00Z"}));
    let out = copilot.admission("--attached-launch", &env);
    assert_eq!(admitted(&out), (0, "room".to_owned()), "{}", out.stderr);
    fs::write(
        copilot.mail_root().join(ITEM).join("compaction.json"),
        json!({"harness": "copilot", "trigger": "auto", "session_id": "s1"}).to_string(),
    )
    .unwrap();
    let out = copilot.admission("--attached-launch", &env);
    assert_eq!(admitted(&out), (0, "due".to_owned()), "{}", out.stderr);
    let answer = out.json();
    assert_eq!(
        (
            answer["decision"].clone(),
            answer["source"]["compacted"].clone()
        ),
        (Value::Null, json!(true))
    );
}

/// The settings load's notice follows the turn end's own answer, once: a
/// harness reads the keyed line first, and a lane whose private env file
/// holds a line the load passes over is still told so, though the turn
/// loads its settings more than once.
#[test]
fn the_settings_loads_notice_follows_the_turn_ends_keyed_answer() {
    let world = World::launched();
    world.direct("d1", "rebase onto main", false);
    fs::write(
        world.lane.join(".env.local"),
        "GH_TOKEN=$(printf example)\n",
    )
    .unwrap();
    let reader = lane_mail().display().to_string();
    // The verb as the hook runs it, the private env file read.
    let stop = || {
        let mut child = program(binary())
            .arg("turn-end")
            .arg("--hook-dir")
            .arg(world.hooks("claude"))
            .current_dir(&world.lane)
            .env("PWD", &world.lane)
            .env("HOME", &world.home)
            .env("PATH", tool_path(&[&world.stand_ins()]))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("LANE_MAIL_CLI", &reader)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("orch-runtime");
        child.stdin.take().unwrap().write_all(b"{}").unwrap();
        let out = child.wait_with_output().unwrap();
        (
            out.status.code(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    };
    let notice = format!(
        "settings-skipped path={}/.env.local key=GH_TOKEN reason=shell-form",
        world.lane.display()
    );
    let (code, said) = stop();
    assert_eq!(code, Some(2), "{said}");
    assert_eq!(
        said.lines().next(),
        Some("lane-mail-check: unread=1"),
        "{said}"
    );
    let told: Vec<&str> = said
        .lines()
        .filter(|l| l.starts_with("settings-skipped "))
        .collect();
    assert_eq!(told, [notice.as_str()], "{said}");
    assert_eq!(said.lines().last(), Some(notice.as_str()), "{said}");
    // The mail read, the turn end reaches the marks and the idle judge,
    // each loading the settings again: its own notice is said once, at the
    // end (the account read's own run says its notice in its cause).
    let (_, said) = stop();
    assert!(
        said.starts_with("lane-mail-check: account=unlisted\n"),
        "{said}"
    );
    let closing: Vec<&str> = said
        .lines()
        .rev()
        .take_while(|l| l.starts_with("settings-skipped "))
        .collect();
    assert_eq!(closing, [notice.as_str()], "{said}");
}
