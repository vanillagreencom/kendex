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
        World {
            _dir: dir,
            root,
            home,
            lane,
        }
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
    let cwd = json!({"cwd": world.lane.display().to_string()}).to_string();
    let copilot = r#"{"sessionId":"s1","timestamp":1}"#;
    let rows: &[(&str, &[&str], &str)] = &[
        ("claude", &[], "{}"),
        ("claude", &[], r#"{"stop_hook_active":true}"#),
        ("claude", &[], r#"{"hook_event_name":"PostModelSwitch"}"#),
        ("claude", &["halt"], r#"{"tool_input":{"command":"ls"}}"#),
        ("claude", &["deliver"], "{}"),
        ("claude", &["start"], "{}"),
        ("claude", &["prompt"], "{}"),
        ("claude", &["compact"], "{}"),
        ("claude", &["usage"], &cwd),
        ("claude", &["row", "SessionStart"], "{}"),
        ("copilot", &["start"], copilot),
        ("copilot", &[], copilot),
    ];
    for (harness, args, payload) in rows {
        let out = world.turn(harness, args, payload);
        assert_eq!(
            (out.code, out.stdout.as_str(), out.stderr.as_str()),
            (0, "", ""),
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
        out.first(),
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
    assert_eq!(out.first(), format!("lane-mail-check: idle={ITEM}"));
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
    assert_eq!(out.first(), format!("lane-mail-check: idle-notice={ITEM}"));
    assert_eq!(world.sent_count(), "1\n");
    let sent = fs::read_to_string(world.lane_box().join("to-overseer.jsonl")).unwrap();
    assert!(
        sent.contains(&format!("lane-mail-check: lane-idle={ITEM}")),
        "{sent}"
    );

    // The told notice is the lane's last report: the next turn end is held.
    let out = world.mail("claude", &[], "{}");
    assert_eq!(out.first(), format!("lane-mail-check: idle={ITEM}"));
    // A turn another hook continued is held as a fresh one.
    fs::write(world.lane_box().join("sent-count"), "1\n").unwrap();
    let out = world.mail("claude", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!(out.first(), format!("lane-mail-check: idle={ITEM}"));
}

#[test]
fn a_report_since_the_last_judged_turn_end_passes_it() {
    let world = World::launched();
    let stop = |world: &World| world.mail("claude", &[], "{}");
    assert_eq!(
        stop(&world).first(),
        format!("lane-mail-check: idle={ITEM}")
    );
    world.report("n1", "notice");
    let out = stop(&world);
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "a notice sent");
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
        (out.code, out.stderr.as_str()),
        (0, ""),
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
    assert_eq!((out.code, out.stderr.as_str()), (0, ""), "a halt standing");
    assert!(
        !world.sent_count().contains("held"),
        "{}",
        world.sent_count()
    );
    world.direct("d2", "go on", false);
    assert_eq!(stop(&world).first(), "lane-mail-check: unread=1");
    assert_eq!(
        stop(&world).first(),
        format!("lane-mail-check: idle={ITEM}"),
        "a later directive lifts the halt"
    );
}

#[test]
fn a_continued_pi_turn_end_tells_the_overseer_instead_of_holding() {
    let world = World::launched();
    let out = world.mail("pi", &[], r#"{"stop_hook_active":true}"#);
    assert_eq!((out.code, out.stdout.as_str()), (0, ""), "{}", out.stderr);
    assert_eq!(out.first(), format!("lane-mail-check: idle-notice={ITEM}"));
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
            out.first(),
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
        out.first(),
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
    assert_eq!(out.first(), "lane-mail-check: events=2");
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
    assert_eq!(out.first(), "lane-mail-check: idle-notice-unsent=2");
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
        out.first(),
        format!(
            "lane-mail-check: idle-hold-unrecorded={}",
            dir.join("sent-count").display()
        )
    );
}
