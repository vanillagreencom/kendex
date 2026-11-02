//! The measurement of decisions 25, 121 Q14 and 135 (5), read under
//! decision 147: the starts the one runner makes on the legacy pass-cost
//! fixture (fifteen lanes, each a stub pane drawing a working turn and one
//! unread notice in its mailbox, `LINEAR_TEAM` set and one `--repo`), for
//! one mail turn and one run of every long-pass duty, by duty tag from
//! `agent_runtime::host::counts()`, beside the fixture's request counts
//! from the fake tracker's and `gh`'s call logs. The counter's scope: the
//! direct starts of the scheduler process; the per-intent detached jobs
//! (a transfer or a stop) and the boundary CLIs' own children (`lane-mail`
//! runs `jq` and Python) count in their own processes and not here. The
//! legacy figures, 100 starts per mail turn and 800 per long pass
//! (`744fd5727:skills/orch/tests/oversee_watch_pass_cost.sh`, retired with the loop), are a regression
//! ceiling the after row stays under, not a target. The per-second claim is
//! not asserted: no file or issue states its load or denominator (decision
//! 147), so the row prints the figures and claims nothing per second.
//!
//! The duties run in a child of this test process: the observation duty
//! reaches the private tmux server through `$TMUX`, which a test never
//! sets on its own process, and the counter is per process. The inner row
//! builds the runner as `watch run` does, runs the first tick and prints
//! the counts; the outer row builds the fixture, starts the inner under the
//! fixture's environment and asserts on what it printed.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows build the fixture they measure, start the inner row as a child and read the one counter"
)]

#[path = "support.rs"]
mod support;

use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use agent_runtime::host;
use agent_runtime::process::Identity;
use orch_runtime::effects;
use orch_runtime::ops::Env;
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots};
use orch_runtime::state::{FLEET_FILE_NAME, Locking, Owner};
use orch_runtime::watch::tracker::Shared;
use orch_runtime::watch::{self, Flags, Paths, Produced, Recorded, Runner};
use serde_json::{Value, json};
use support::*;

/// The environment name that hands the inner row its world.
const WORLD_VAR: &str = "WATCH_COST_WORLD";
/// The prefix of the one stdout line the inner row prints for the outer.
const MARK: &str = "WATCH_COST=";
/// The fleet's fixed start, the legacy `--since`.
const SINCE: &str = "2026-01-01T00:00:00Z";
/// The repository the legacy fixture named (`run_watch`'s `--repo`).
const REPO: &str = "owner/repo";
/// The legacy fixture's lane count (`744fd5727:skills/orch/tests/oversee_watch_pass_cost.sh`).
const LANES: u32 = 15;
/// The legacy ceilings (`744fd5727:skills/orch/tests/oversee_watch_pass_cost.sh:53-56`).
const MAIL_CEILING: u64 = 100;
const LONG_CEILING: u64 = 800;
/// The programs agent-runtime's own runner starts untagged (decision 145
/// (2)): the process reads and signals under the one runner, keyed by
/// program alone.
const UNTAGGED: [&str; 3] = ["tmux", "ps", "kill"];

/// One line on stdout: the inner row's counts for the outer, and the
/// outer's table for the record.
fn say(line: &str) {
    use std::io::Write;
    let mut out = std::io::stdout();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

fn recorded() -> Recorded {
    Recorded {
        pane: "none".into(),
        script: "/w/oversee-watch".into(),
        cwd: "/w".into(),
        args: vec!["watch".into(), "run".into()],
    }
}

/// The counter as rows of `[program, tag, starts]`.
fn rows(counts: &host::Counts) -> Vec<Value> {
    counts
        .by_key()
        .map(|(key, n)| json!([key.program, key.tag, n]))
        .collect()
}

/// The inner half: the runner with every duty registered as `watch run`
/// registers them, one tick on the fake clock (the mail turn on its thread,
/// every long duty on the other), the counts read once both threads sleep
/// again; then the heartbeat alone, on a runner whose one period is one
/// second. Printed as one `WATCH_COST=` line for the outer row. The counter
/// is zeroed before each runner starts, with no run in flight (R-U5b).
#[test]
#[ignore = "the inner half of the measurement: its outer row runs it in a child under the fixture's environment"]
fn fifteen_lane_pass_inner() {
    let Some(world) = std::env::var_os(WORLD_VAR) else {
        return;
    };
    let root = PathBuf::from(world);
    let vars: Vec<(OsString, OsString)> = std::env::vars_os().collect();
    let roots = Roots {
        project: root.clone(),
        common: root.clone(),
    };
    let settings = settings::load(
        &roots,
        &vars,
        &SettingsFlags {
            state_dir: Some(root.clone()),
            private_env: false,
        },
    )
    .unwrap();
    let path = root.join(FLEET_FILE_NAME);
    let paths = Paths::of(&path).unwrap();
    let identity = me();
    let owner = Owner {
        pid: u64::from(identity.pid),
        start: identity.start.clone(),
    };
    let env = Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_000_000_000,
        nonce: 7,
        owner: Some(owner),
    };
    let locking = Locking::FLOCK;
    let repos = vec![REPO.to_owned()];
    let since = Some(SINCE.to_owned());
    let clock = FakeClock::new();
    let mut runner = Runner::new(
        paths.clone(),
        &clock,
        &settings,
        Flags {
            interval: secs(240),
            max_loops: 25,
            since: since.clone(),
            replace: None,
        },
        identity.clone(),
        recorded(),
    );
    let shared =
        watch::tracker::register(&mut runner, &path, &settings, &env, locking, since.clone())
            .unwrap();
    let verifying = watch::verifying::register(&mut runner, &settings, shared.clone());
    watch::heartbeat::register(
        &mut runner,
        &path,
        &settings,
        secs(240),
        25,
        since.clone(),
        repos.clone(),
        shared.clone(),
        verifying,
    );
    watch::report::register(&mut runner, &path, &settings, repos.clone());
    watch::retention::register(&mut runner, &path, &settings, locking).unwrap();
    watch::github::register(
        &mut runner,
        &path,
        &settings,
        since.clone(),
        repos.clone(),
        shared,
    )
    .unwrap();
    watch::mail::register(&mut runner, &path, &settings).unwrap();
    watch::overseer::register(
        &mut runner,
        &path,
        &settings,
        &env,
        locking,
        watch::overseer::Slot::new(),
    );
    watch::wake::register(&mut runner, &path, &settings);
    let reconcile = (path.clone(), settings.clone(), env.clone());
    runner.register(
        Duty::Reconcile,
        Box::new(move |tick: &watch::Tick| {
            effects::reconcile(
                &reconcile.0,
                &reconcile.1,
                &reconcile.2,
                locking,
                tick.clock,
            )?;
            Ok(Produced::default())
        }),
    );
    host::reset_counts();
    let first: Mutex<Option<host::Counts>> = Mutex::new(None);
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        *first.lock().unwrap() = Some(host::counts());
    });
    assert!(ended.is_ok(), "{ended:?}");
    let first = first
        .into_inner()
        .unwrap()
        .expect("the first tick's counts");
    let clock = FakeClock::new();
    let mut runner = Runner::new(
        paths.clone(),
        &clock,
        &settings,
        Flags {
            interval: secs(1),
            max_loops: 1,
            since: since.clone(),
            replace: None,
        },
        identity.clone(),
        recorded(),
    );
    let verifying: watch::verifying::Lines = Arc::new(Mutex::new(Vec::new()));
    watch::heartbeat::register(
        &mut runner,
        &path,
        &settings,
        secs(1),
        1,
        since,
        repos,
        Shared::default(),
        verifying,
    );
    host::reset_counts();
    let heartbeat: Mutex<Option<host::Counts>> = Mutex::new(None);
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
        clock.pass(secs(1));
        *heartbeat.lock().unwrap() = Some(host::counts());
    });
    assert!(ended.is_ok(), "{ended:?}");
    let heartbeat = heartbeat
        .into_inner()
        .unwrap()
        .expect("the heartbeat's counts");
    let log: Vec<String> = std::fs::read_to_string(&paths.log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    say(&format!(
        "{MARK}{}",
        json!({"first": rows(&first), "heartbeat": rows(&heartbeat), "log": log})
    ));
}

/// A copy of `sleep` named `claude` under `dir`, the harness each stub pane
/// holds in its foreground (the legacy fixture's `cmd-<lane>.txt`).
fn named_claude(dir: &Path) -> PathBuf {
    let path = dir.join("claude");
    let out = program("sh")
        .args([
            "-c",
            "cp \"$(command -v sleep)\" \"$1\" && chmod 755 \"$1\"",
            "_",
        ])
        .arg(&path)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    path
}

/// The identity of the pane's process once its shell has exec'd `claude`,
/// and the working turn drawn (the legacy fixture's `pane-<lane>.txt`).
fn await_working(server: &Server, pane: &str) -> Identity {
    let pid = server.pane_pid(pane);
    let deadline = std::time::Instant::now() + secs(5);
    loop {
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        let cap = tmux(&server.socket, &["capture-pane", "-p", "-t", pane]);
        if comm.trim() == "claude" && String::from_utf8_lossy(&cap.stdout).contains("working on it")
        {
            return Identity {
                pid,
                start: start_of(pid),
            };
        }
        assert!(
            std::time::Instant::now() < deadline,
            "pane {pane} never held claude drawing its turn"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// The real mailbox program, the sibling package's: the one boundary the
/// mail turn crosses.
fn real_lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap()
}

/// The starts under `tag`, and the total.
fn tagged(rows: &[Value], tag: &str) -> u64 {
    rows.iter()
        .filter(|r| r[1].as_str() == Some(tag))
        .map(|r| r[2].as_u64().unwrap_or(0))
        .sum()
}

fn total(rows: &[Value]) -> u64 {
    rows.iter().map(|r| r[2].as_u64().unwrap_or(0)).sum()
}

fn under(rows: &[Value], program: &str, tag: Option<&str>) -> u64 {
    rows.iter()
        .filter(|r| r[0].as_str() == Some(program) && r[1].as_str() == tag)
        .map(|r| r[2].as_u64().unwrap_or(0))
        .sum()
}

/// The after row (step5-map § C as decision 135 (5) reduced it): the
/// fifteen-lane fixture on a private server, one mail turn and one run of
/// every long-pass duty, the heartbeat among them, measured by the one
/// counter. Defects: a mail turn or a long pass that starts more processes
/// than the legacy loop did (the ceilings); a duty's start counted under
/// no tag, so the per-duty figure is unreadable (every start carries its
/// duty's tag but agent-runtime's own `tmux`, `ps` and `kill`); a window
/// that misses the lanes' reads (one `lane-mail` start under `mail`, one
/// `tmux` read per lane); a pass that failed and so measured less than a
/// pass. The figures are printed, the per-second rate is not claimed.
#[test]
fn the_fifteen_lane_fixture_starts_per_pass_stay_under_the_legacy_ceilings() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    // A checkout: `lane-mail` roots the overseer's box at the common root.
    for args in [
        vec!["init", "-q"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(&root)
            .args(&args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    }
    let server = Server::start(&root, "fleet");
    let claude = named_claude(&root);
    let screen = root.join("screen.txt");
    std::fs::write(&screen, "⏺ working on it\n❯\u{a0}\n").unwrap();
    let mut lanes = Vec::new();
    for i in 1..=LANES {
        let name = format!("gh-{i}");
        let item = format!("KEN-{i}");
        let line = format!("cat {}; exec {} 600", screen.display(), claude.display());
        let pane = server.open_window(&name, &root, &format!("bash -c \"{line}\""));
        let identity = await_working(&server, &pane);
        let status = root.join("tmp").join(format!("lane-status-{item}.md"));
        std::fs::create_dir_all(status.parent().unwrap()).unwrap();
        std::fs::write(&status, "Step: start\n").unwrap();
        let mailbox = root.join("tmp").join("lane-mail").join(&item);
        std::fs::create_dir_all(&mailbox).unwrap();
        std::fs::write(
            mailbox.join("to-overseer.jsonl"),
            format!(
                "{}\n",
                json!({"id": format!("n{i}"), "kind": "notice", "at": "2026-01-29T15:20:00Z", "from": item, "text": "Unread"})
            ),
        )
        .unwrap();
        lanes.push(json!({
            "item": item, "window": name, "harness": "claude", "kind": "local", "host": null,
            "status": "running", "account": "/home/me/.eclaude",
            "mail_root": root.display().to_string(),
            "session_since": "2026-01-29T15:00:00Z", "launched_at": "2026-01-29T15:00:00Z",
            "running_at": "2026-01-29T15:00:10Z",
            "launch": {"pane": pane, "server": server.pid, "pid": identity.pid, "start": identity.start},
        }));
    }
    let mut fleet: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-oversee.json")).unwrap();
    fleet["lanes"] = Value::Array(lanes);
    fleet["intents"] = json!([]);
    std::fs::write(
        root.join(FLEET_FILE_NAME),
        serde_json::to_string_pretty(&fleet).unwrap(),
    )
    .unwrap();
    // The boundary programs, each symlinked under the world as the name
    // the duty runs it by, answering from its map beside that name: every
    // list empty, the reducer quiet, no report due, no account listed, as
    // the legacy harness's stubs answered.
    for (name, fixture) in [
        ("linear", "linear-fixture/linear.sh"),
        ("gh", "gh/gh"),
        ("pr-watch", "pr-watch-fixture/pr-watch.sh"),
        ("lanes", "lanes-fixture/lanes"),
        ("oversee-report", "oversee-report-fixture/oversee-report"),
    ] {
        std::os::unix::fs::symlink(fixtures().join(fixture), root.join(name)).unwrap();
    }
    std::fs::write(
        root.join("linear.json"),
        json!({
            "statuses list": {"body": [
                {"name": "In Progress", "type": "started"}, {"name": "In Review", "type": "started"},
                {"name": "Verifying", "type": "started"}, {"name": "Todo", "type": "unstarted"},
                {"name": "Backlog", "type": "backlog"}, {"name": "Triage", "type": "triage"},
                {"name": "Done", "type": "completed"}, {"name": "Canceled", "type": "canceled"}
            ]},
            "issues list": {"body": []},
        })
        .to_string(),
    )
    .unwrap();
    let mut gh = json!({
        format!("repos/{REPO}/actions/workflows?per_page=100&page=1"): {"body": {"total_count": 0, "workflows": []}},
        format!("repos/{REPO}/pulls?state=open&per_page=100&page=1"): {"body": []},
        format!("repos/{REPO}/issues?state=open&per_page=100&page=1"): {"body": []},
    });
    // The merged index reads each running lane's closed pulls by its item
    // branch (`github.rs`, `pulls?state=closed&head=`), empty here.
    for i in 1..=LANES {
        for page in ["", "&per_page=100&page=1"] {
            gh[format!("repos/{REPO}/pulls?state=closed&head=owner%3Aken-{i}{page}")] =
                json!({"body": []});
            // And the merged search by item since the fleet's start, empty.
            gh[format!(
                "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-{i}%22%20in%3Atitle%2Cbody%20merged%3A%3E%3D2026-01-01T00%3A00%3A00Z{page}"
            )] = json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}});
        }
    }
    std::fs::write(root.join("gh.json"), gh.to_string()).unwrap();
    std::fs::write(
        root.join("pr-watch.json"),
        json!({REPO: {"exit": 0}}).to_string(),
    )
    .unwrap();
    std::fs::write(root.join("lanes.json"), "[]\n").unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    let inherited = std::env::var("PATH").unwrap_or_default();
    let out = program(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "fifteen_lane_pass_inner",
            "--include-ignored",
            "--nocapture",
            "--test-threads",
            "1",
        ])
        .env(WORLD_VAR, &root)
        .env("PATH", format!("{}:{inherited}", root.display()))
        .env(
            "TMUX",
            format!("{},{},$0", server.socket.display(), server.pid),
        )
        .env("LINEAR_TEAM", "kendex")
        .env("OVERSEE_WATCH_TRACKER", root.join("linear"))
        .env("OVERSEE_WATCH_PR_WATCH", root.join("pr-watch"))
        .env("OVERSEE_WATCH_REPORT", root.join("oversee-report"))
        .env("OVERSEE_WATCH_LANES", root.join("lanes"))
        .env("LANE_MAIL_CLI", real_lane_mail())
        .env("ORCH_JOB_UNIT", job_unit())
        .env("ORCH_WATCH_MAIL_INTERVAL", "20")
        .current_dir(&root)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        out.status.success(),
        "the inner row failed:\n{stdout}\n{}",
        stderr(&out)
    );
    // The harness prints `test <name> ... ` ahead of the row's own output
    // on the same line, so the mark is found inside it.
    let line = stdout
        .lines()
        .find_map(|l| l.find(MARK).map(|at| &l[at + MARK.len()..]))
        .unwrap_or_else(|| {
            panic!(
                "the inner row printed no counts line:\n{stdout}\n{}",
                stderr(&out)
            )
        });
    let measured: Value = serde_json::from_str(line).unwrap();
    let first = measured["first"].as_array().unwrap();
    let heartbeat = measured["heartbeat"].as_array().unwrap();
    let log: Vec<&str> = measured["log"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    let gh_requests = std::fs::read_to_string(root.join("gh.log"))
        .unwrap_or_default()
        .lines()
        .count();
    let tracker_requests = std::fs::read_to_string(root.join("linear.log"))
        .unwrap_or_default()
        .lines()
        .count();
    let mail = tagged(first, "mail");
    let long = total(first) - mail + total(heartbeat);
    say(&format!(
        "starts per pass, fifteen lanes ({} notices, one mail turn, one long pass with the heartbeat):",
        LANES
    ));
    say("  program | tag | starts");
    for row in first.iter().chain(heartbeat.iter()) {
        say(&format!(
            "  {} | {} | {}",
            row[0].as_str().unwrap_or("?"),
            row[1].as_str().unwrap_or("-"),
            row[2]
        ));
    }
    say(&format!(
        "  mail turn {mail} (ceiling {MAIL_CEILING}); long pass {long} (ceiling {LONG_CEILING}); total {}",
        mail + long
    ));
    say(&format!(
        "  requests: gh {gh_requests}, tracker {tracker_requests}"
    ));
    say(&format!("  log: {log:?}"));
    // One run of every slot: a duty that failed measured less than a pass.
    assert!(
        !log.iter().any(|l| l.starts_with("EVENT watch-step-failed")),
        "every duty ran whole: {log:?}"
    );
    assert_eq!(
        log.iter()
            .filter(|l| l.starts_with("EVENT lane-notice "))
            .count(),
        LANES as usize,
        "the mail turn read every lane's notice: {log:?}"
    );
    // Every start is attributable to its duty.
    for row in first.iter().chain(heartbeat.iter()) {
        if row[1].is_null() {
            let program = row[0].as_str().unwrap_or("?");
            assert!(
                UNTAGGED.contains(&program),
                "a start with no duty tag: {program} ({} starts)",
                row[2]
            );
        }
    }
    // The window held the reads it measures.
    assert!(
        under(first, "lane-mail", Some("mail")) >= 1,
        "the mail turn's drain is in the window: {first:?}"
    );
    assert!(
        under(first, "tmux", None) >= u64::from(LANES),
        "one read per lane is in the window: {first:?}"
    );
    assert!(
        mail <= MAIL_CEILING,
        "the mail turn's {mail} starts stay under the legacy {MAIL_CEILING}"
    );
    assert!(
        long <= LONG_CEILING,
        "the long pass's {long} starts stay under the legacy {LONG_CEILING}"
    );
}
