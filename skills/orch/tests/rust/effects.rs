//! Live-effect process tests of the `orch-runtime` executable: each creates
//! its own private tmux server, drives the binary against a stub harness
//! that never launches a real model, and reaps what it started.
//!
//! The stub harnesses are the scripts beside this file, `fixtures/<stub>/
//! claude`: each is named for the harness it stands in for and run by bash
//! directly, so the kernel records the harness's process name for the pane's
//! foreground process, which the judge requires before it reads the pane
//! idle. They are selected through the `AGENT_RUNTIME_HARNESS_BINARIES`
//! product setting for a custom install path. The tmux server each test
//! makes lives on its own socket under a `TempDir`, reads no configuration
//! file and runs a named pane shell; the test ends it with
//! `tmux -S <sock> kill-server` on that socket alone and never signals by
//! name.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::*;

/// A close carrying the tracker's terminal verdict, the ground that ends a
/// lane whose harness still runs.
fn terminal_close(item: &str) -> Value {
    json!({
        "op": "close-owned-resources",
        "item": item,
        "terminal": {"verdict": "completed", "source": "test"},
    })
}

#[test]
fn a_launch_confirmed_records_the_running_lane_with_its_pane_identity() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-1", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["op"], "record-outcome");
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["lane"]["status"], "running");
    let launch = &report["lane"]["launch"];
    assert!(launch["pane"].as_str().unwrap().starts_with('%'));
    assert_eq!(launch["server"], server.pid);
    // The identity is the harness the pane's wrapper runs, the stub itself,
    // which the kernel names for the harness.
    let pid = launch["pid"].as_u64().expect("the pane process pid") as u32;
    assert_eq!(launch["pane"].as_str().unwrap(), {
        let pane = launch["pane"].as_str().unwrap();
        assert_eq!(server.harness_pid(pane), pid);
        pane
    });
    assert_eq!(
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .unwrap()
            .trim(),
        "claude"
    );
    assert!(launch["start"].as_str().is_some());
    // The lane's `window` is `session:title`, the title the item; the pane
    // id stays in `launch.pane`.
    assert_eq!(report["lane"]["window"], "fleet:KEN-1");
    // The window the launch opened stands on the server, and the intent
    // recorded it before the wait.
    assert!(
        server
            .panes()
            .iter()
            .any(|p| p == launch["pane"].as_str().unwrap())
    );
    let intent = &report["intent"];
    assert_eq!(intent["phase"]["phase"], "window-opened");
    assert_eq!(intent["phase"]["pane"], launch["pane"]);
    assert_eq!(
        intent["phase"]["socket"],
        server.socket.display().to_string()
    );
}

#[test]
fn a_launch_whose_harness_exits_at_once_records_failed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-fail");
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-2", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
}

#[test]
fn a_launch_that_never_draws_its_composer_records_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = Some(1); // a short injected bound: the stub never settles
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-3", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert!(report["intent"]["completed_at"].is_null(), "an open intent");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "preparing",
        "the lane is left preparing"
    );
    // The pane the effect opened is persisted on the lane's `launch` and in
    // the intent's phase, so a reconcile can re-observe it.
    let launch = runner.fleet()["lanes"][0]["launch"].clone();
    assert!(
        launch["pane"].as_str().unwrap().starts_with('%'),
        "the pane is persisted for reconcile"
    );
    assert_eq!(launch["server"], server.pid);
    assert_eq!(report["intent"]["phase"]["pane"], launch["pane"]);
    // The pane registered itself before it exec'd the stub: its receipt names
    // this intent, the pane and the pid the stub runs under, and stands while
    // the intent is open.
    let pane = launch["pane"].as_str().unwrap();
    let intent_id = report["intent"]["id"].as_str().unwrap();
    let receipt = read_receipt(&runner, intent_id);
    assert_eq!(receipt["intent"], intent_id);
    assert_eq!(receipt["pane"], pane);
    assert_eq!(receipt["pid"], server.pane_pid(pane));
    assert!(receipt["written_at"].as_str().is_some());
    // A reconcile reads that pane; the stub still never draws, so the launch
    // stays unconfirmed and the intent stays open, with the reading kept.
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(again["intent"]["observation"]["state"]["state"], "unjudged");
}

/// A pane whose screen carries the composer marker while a shell holds its
/// terminal never reads idle, so the launch never confirms; a reconcile
/// reads the same. The window spans the stub's exec and the shell's first
/// prompt, so the op's last reading is the shell's.
#[test]
fn a_pane_whose_foreground_is_a_shell_never_reads_idle_whatever_it_draws() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-shell");
    runner.verify = Some(4);
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-40", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
    let pane = report["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    // The shell draws the marker as its prompt, which a loaded host can
    // land after the window: the screen is read until it does, bounded.
    let deadline = Instant::now() + Duration::from_secs(10);
    let drawn = loop {
        let screen = tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]);
        if String::from_utf8_lossy(&screen.stdout).contains('\u{276f}') {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(drawn, "the screen does carry the composer marker");
    let reading = report["intent"]["observation"]["process"]["reading"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        reading == "shells-only" || reading == "foreground-shell",
        "a shell holds the pane: {reading}"
    );
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
}

#[test]
fn a_launch_never_confirms_when_its_harness_execs_a_shell_before_capture() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-survivor");
    runner.verify = Some(1);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir(&tools).unwrap();
    runner.tools = Some(tools.clone());
    let (request, env) = copilot_survivor(dir.path(), &runner, &tools, "KEN-CAPTURE");

    // The harness stays foreground until the test releases it through the
    // terminal. The shell that replaces it draws Copilot's framed composer.
    write_executable(
        &dir.path().join("copilot-bin/copilot"),
        "#!/bin/bash\nread -r _ || exit 1\nPS1=$'❯\\n──────────' exec bash --noprofile --norc -i\n",
    );
    let fifo = dir.path().join("capture.fifo");
    mkfifo(&fifo);
    let mark = dir.path().join("capturing");
    let opened = dir.path().join("opened");
    // Only the capture under test waits. Later polls use tmux directly.
    write_executable(
        &dir.path().join("tmux"),
        "#!/bin/bash\nif [ -e \"$TMUX_HOLD_MARK\" ]; then exec \"$TMUX_REAL\" \"$@\"; fi\nexec \"$TMUX_TEST_HOLD\" \"$@\"\n",
    );
    let real = which_tmux();
    let shim = fixtures().join("tmux-hold/tmux");
    let mut env: Vec<(&str, &str)> = env.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect();
    env.extend([
        ("TMUX_REAL", real.as_str()),
        ("TMUX_TEST_HOLD", shim.to_str().unwrap()),
        ("TMUX_HOLD_FIFO", fifo.to_str().unwrap()),
        ("TMUX_HOLD_MARK", mark.to_str().unwrap()),
        ("TMUX_HOLD_VERB", "capture-pane"),
        ("TMUX_HOLD_OPENED", opened.to_str().unwrap()),
        ("TMUX_HOLD_READY_COMM", "copilot"),
        ("HOLD_BOUND_SECS", "15"),
    ]);
    let mut child = Owned(runner.spawn_op_fleet(&request, &env, dir.path()));
    let deadline = Instant::now() + Duration::from_secs(15);
    while !mark.exists() {
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "the launch ended before capture: {}",
            runner.fleet()
        );
        assert!(
            Instant::now() < deadline,
            "the capture never reached its hold"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let fleet = runner.fleet();
    let intent = &fleet["intents"][0];
    assert!(
        intent["obligations"]["standing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["kind"] == "process")
    );
    let pane = intent["phase"]["pane"].as_str().unwrap();
    let pid = server.pane_pid(pane);
    server.send_line(pane, "exec");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let screen = tmux(&server.socket, &["capture-pane", "-p", "-t", pane]);
        if String::from_utf8_lossy(&screen.stdout).contains("❯\n──────────") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the shell never drew the composer"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(server.pane_pid(pane), pid);
    release_hold(&fifo, Duration::from_secs(5), || runner.fleet().to_string());

    let deadline = Instant::now() + Duration::from_secs(15);
    let status = loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "the launch never returned");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(
        status.success(),
        "the launch operation exited with {status}"
    );
    let fleet = runner.fleet();
    assert_eq!(fleet["intents"][0]["outcome"], "unconfirmed", "{fleet}");
    assert_eq!(fleet["lanes"][0]["status"], "preparing", "{fleet}");
}

/// A harness that exits before its first draw never confirms, whatever the
/// pane's shell drew while typing the launch line.
#[test]
fn a_launch_whose_harness_dies_before_drawing_never_confirms() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-dying");
    runner.init_fleet();
    for n in 0..12 {
        let item = format!("KEN-D{n}");
        let report = effect_report(&runner.op_fleet(&launch_request(&item, runner.state_dir())));
        assert_eq!(report["intent"]["outcome"], "failed", "{item}");
        assert_eq!(report["lane"]["status"], "stopped", "{item}");
    }
}

#[test]
fn a_stop_ends_the_recorded_identity_and_closes_the_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-4", runner.state_dir())));
    let pid = launched["lane"]["launch"]["pid"].as_u64().unwrap() as u32;
    let pane = launched["lane"]["launch"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(live(pid));
    let out = runner.op_fleet(&terminal_close("KEN-4"));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["lane"]["status"], "done");
    // The recorded process is gone and its window is closed.
    assert!(!live(pid), "the harness process is stopped");
    assert!(!server.panes().contains(&pane), "the window is closed");
}

#[test]
fn a_stop_whose_recorded_start_no_longer_matches_records_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    // A live process the test owns, recorded under a start that is not its.
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-5",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    runner.write_fleet(&fleet);
    let out = runner.op_fleet(&terminal_close("KEN-5"));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "running",
        "the lane is left as it stood"
    );
    assert!(live(owned.pid()), "the mismatched process was not killed");
}

/// A close interrupted before its signal leaves an open intent over a live,
/// matching identity. The repeated close reconciles it as a stop still owed
/// and runs that stop.
#[test]
fn a_repeated_close_runs_the_stop_its_reconcile_reads_pending() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-41",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": owned.start()}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-resources",
        "KEN-41",
        "not-started",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-41")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done");
    assert!(!live(owned.pid()), "the stop ran on the repeat");
    assert_eq!(
        runner.fleet()["intents"].as_array().unwrap().len(),
        1,
        "no second intent"
    );
}

/// The effect's process ends during the launch poll; a reconcile completes
/// the launch from the recorded pane, confirming it with the identity it
/// reads, or failing it once that pane is gone. The lane records the
/// fleet's session, never the name of another session grouped with it.
#[test]
fn reconcile_completes_a_launch_from_its_recorded_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "KEN-42",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let grouped = tmux(
        &server.socket,
        &["new-session", "-d", "-t", "fleet", "-s", "view"],
    );
    assert!(grouped.status.success(), "{}", stderr(&grouped));
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-42", "preparing", &runner, Value::Null)]);
    fleet["intents"] = json!([lane_intent(
        "launch-session",
        "KEN-42",
        "not-started",
        Some(phase("window-opened", &server, &pane, since, None)),
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = runner.fleet()["lanes"][0].clone();
    assert_eq!(lane["status"], "running");
    assert_eq!(lane["launch"]["pane"], pane);
    assert_eq!(lane["launch"]["pid"], server.pane_pid(&pane));
    assert_eq!(lane["window"], "fleet:KEN-42");
    assert_eq!(lane["mail_root"], runner.state_dir().display().to_string());
    let ungrouped = tmux(&server.socket, &["kill-session", "-t", "=view"]);
    assert!(ungrouped.status.success(), "{}", stderr(&ungrouped));
    // The close that follows stops it by that identity and the lane is done,
    // its window closed.
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-42")));
    assert_eq!(closed["intent"]["outcome"], "confirmed");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(server.panes().len(), 1);
}

#[test]
fn reconcile_marks_a_transfer_intent_stale_when_the_generation_moved() {
    // A transfer intent still open after a released succession moved the
    // overseer's generation reconciles as intent-stale with the observed
    // generation, never a second controller.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mut fleet = runner.fleet();
    fleet["controller"] = json!({"runtime": "tmux", "generation": 4, "pane": "%0"});
    fleet["intents"] = json!([transfer_intent(None, None)]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["reconciled"], "intent-stale");
    assert_eq!(report["intent"]["observed_generation"], 4);
    assert_eq!(runner.fleet()["controller"]["generation"], 4, "unmoved");
}

#[test]
fn two_launch_processes_mint_distinct_intent_ids() {
    // Through the binary, each `op` process mints its own stamp, so a relaunch
    // after a close gets a new id.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let first = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    assert_eq!(first["intent"]["outcome"], "confirmed");
    let first_id = first["intent"]["id"].as_str().unwrap().to_owned();
    assert!(first_id.starts_with("launch-session:KEN-1:"), "{first_id}");
    effect_report(&runner.op_fleet(&terminal_close("KEN-1")));
    let second = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    let second_id = second["intent"]["id"].as_str().unwrap().to_owned();
    assert_ne!(second_id, first_id, "a distinct id per process");
    assert_eq!(second["intent"]["outcome"], "confirmed");
}

/// A local lane `KEN-1` confirmed on the state directory's account, whose
/// usage reads `used` percent in both windows through the usage fixture,
/// and a controller record naming the fleet's socket: the world a restart
/// leaves once the server goes.
fn relaunch_world(dir: &Path, server: &Server, used: u32, class: &str) -> Runner {
    let mut runner = Runner::new(server, "stub-confirm");
    runner.init_fleet();
    let bin = dir.join("usage-bin");
    let usage = dir.join("usage-fixtures");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&usage).unwrap();
    std::os::unix::fs::symlink(account_fixtures().join("usage-curl/curl"), bin.join("curl"))
        .unwrap();
    std::fs::write(
        usage.join("planted.usage.json"),
        json!({"five_hour": {"utilization": used, "resets_at": "2027-01-01T00:00:00Z"},
            "seven_day": {"utilization": used, "resets_at": "2027-01-01T00:00:00Z"}})
        .to_string(),
    )
    .unwrap();
    runner.tools = Some(bin);
    runner
        .env
        .push(("USAGE_FIXTURE_DIR".to_owned(), usage.display().to_string()));
    let mut request = launch_request("KEN-1", runner.state_dir());
    request["class"] = json!(class);
    let launched = effect_report(&runner.op_fleet(&request));
    assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
    let mut fleet = runner.fleet();
    fleet["controller"] = json!({"server_socket": server.socket.display().to_string()});
    runner.write_fleet(&fleet);
    runner
}

/// `lane relaunch` for `item`, run from a pane of another server than the
/// fleet's, with `extra` environment.
fn relaunch(
    runner: &Runner,
    dir: &Path,
    item: &str,
    extra: &[(&str, &str)],
) -> std::process::Output {
    let decoy = format!("{},0,0", dir.join("decoy.sock").display());
    let mut env = vec![("TMUX", decoy.as_str())];
    env.extend_from_slice(extra);
    runner.run_env(&["lane", "relaunch", "--fleet", item], &env)
}

/// The key of the refusal a run printed, its exit 1.
fn refused_by(out: &std::process::Output) -> String {
    assert_eq!(out.status.code(), Some(1), "{}", stderr(out));
    reply(out)["refusal"]["key"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

/// The fleet's server killed, as a restart ends it, and awaited gone with
/// the lane harness it held: a relaunch reads that harness's identity, so a
/// harness still exiting would read live.
fn end_server(server: &Server, harness: u32) {
    let killed = tmux(&server.socket, &["kill-server"]);
    assert!(killed.status.success(), "{}", stderr(&killed));
    let deadline = Instant::now() + Duration::from_secs(10);
    while live(server.pid) || live(harness) {
        assert!(Instant::now() < deadline, "the fleet server never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The pid of `item`'s harness, as its record names it.
fn harness_pid(runner: &Runner, item: &str) -> u32 {
    let fleet = runner.fleet();
    let lane = fleet["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == item)
        .unwrap_or_else(|| panic!("no lane {item}: {fleet}"));
    u32::try_from(lane["launch"]["pid"].as_u64().unwrap()).unwrap()
}

/// After a restart a local lane's record stands with its session and the
/// fleet's server gone, and the caller stands on another server: `lane
/// relaunch` with the item alone closes the lane and launches it again from
/// its record, on its own account and the start brief, on the controller
/// record's socket, where a server is started again.
#[test]
fn lane_relaunch_brings_a_recorded_local_lane_back_from_its_record_alone() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    // The server's socket stands in a directory of its own, which the
    // restart empties away as `/tmp` is emptied at boot.
    let sockets = dir.path().join("sockets");
    std::fs::create_dir(&sockets).unwrap();
    let server = Server::start(&sockets, "fleet");
    let runner = relaunch_world(dir.path(), &server, 5, "light");
    end_server(&server, harness_pid(&runner, "KEN-1"));
    std::fs::remove_dir_all(&sockets).unwrap();
    let out = relaunch(&runner, dir.path(), "KEN-1", &[]);
    let line = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    assert_eq!(out.status.code(), Some(0), "{line} {}", stderr(&out));
    let words: Vec<&str> = line.split(' ').collect();
    // The lane's session stands recorded under its own account, so the
    // relaunch resumes it.
    assert_eq!(
        words[..3],
        ["resumed", "item=KEN-1", "route=resume"],
        "{line}"
    );
    assert_eq!(
        std::fs::metadata(&sockets).unwrap().permissions().mode() & 0o777,
        0o700,
        "the socket's directory made again, private"
    );
    assert_eq!(
        words[3],
        format!("account={}", runner.state_dir().display()),
        "{line}"
    );
    let identity = tmux(&server.socket, &["display-message", "-p", "#{pid}"]);
    let started: u64 = String::from_utf8_lossy(&identity.stdout)
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("no server answers: {}", stderr(&identity)));
    let fleet = runner.fleet();
    let intents = fleet["intents"].as_array().unwrap();
    let (launch, close) = (&intents[intents.len() - 1], &intents[intents.len() - 2]);
    assert_eq!(close["op"], "close-resources", "{close}");
    assert_eq!(close["outcome"], "confirmed", "{close}");
    assert_eq!(launch["op"], "launch-session", "{launch}");
    assert_eq!(launch["outcome"], "confirmed", "{launch}");
    let lane = &fleet["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["class"], "light", "{lane}");
    assert_eq!(lane.get("class_missed"), None, "{lane}");
    assert_eq!(lane["launch"]["server"], started, "{lane}");
    let request: Value = serde_json::from_str(
        &std::fs::read_to_string(runner.state_dir().join("restart-relaunch-KEN-1.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        request["brief_file"],
        runner
            .state_dir()
            .join("restart-relaunch-KEN-1.md")
            .display()
            .to_string(),
        "{request}"
    );
}

/// What `lane relaunch` refuses before it closes anything: a lane whose
/// session still runs, idle at its composer, a fleet whose controller
/// record names no server, so the caller's own server is never reached, an
/// item with no lane, a hosted lane, whose server is its host's, a lane
/// whose own account the launch's judge reads walled, and a launch its
/// admission refuses, here on a setting only a launch reads. The lane
/// stands running after each.
#[test]
fn lane_relaunch_refuses_by_key_with_nothing_closed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = relaunch_world(dir.path(), &server, 99, CLASS);
    let fleet = runner.fleet();
    let harness = harness_pid(&runner, "KEN-1");
    // With no account to judge, nothing but the live session holds this
    // relaunch before its close.
    let mut live_accountless = fleet.clone();
    live_accountless["lanes"][0]
        .as_object_mut()
        .unwrap()
        .remove("account");
    runner.write_fleet(&live_accountless);
    let out = relaunch(&runner, dir.path(), "KEN-1", &[]);
    assert_eq!(refused_by(&out), "lane-live");
    let after = runner.fleet();
    assert_eq!(after["lanes"][0]["status"], "running", "{after}");
    assert!(
        !after["intents"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["op"] == "close-resources"),
        "a live lane's relaunch closes nothing: {after}"
    );
    assert!(live(harness), "a live lane's relaunch stops no harness");
    // Every row below reads the lane's session gone, as a restart leaves it.
    end_server(&server, harness);
    let mut hosted = fleet.clone();
    hosted["lanes"][0]["host"] = json!("/opt/provider");
    let mut unrecorded = fleet.clone();
    unrecorded["controller"] = json!({});
    let mut accountless = fleet.clone();
    accountless["lanes"][0]
        .as_object_mut()
        .unwrap()
        .remove("account");
    let unadmitted = [("ORCH_LANE_OUTPUT", "bogus")];
    // The item, the fleet record, the run's extra environment, the key and
    // a field the refusal carries.
    type Row<'a> = (
        &'a str,
        &'a Value,
        &'a [(&'a str, &'a str)],
        &'a str,
        Option<Value>,
    );
    let rows: [Row; 5] = [
        (
            "KEN-1",
            &unrecorded,
            &[],
            "server-socket-unrecorded",
            Some(json!(["field", "server_socket"])),
        ),
        ("KEN-9", &fleet, &[], "lane-missing", None),
        ("KEN-1", &hosted, &[], "lane-hosted", None),
        (
            "KEN-1",
            &fleet,
            &[],
            "account-walled",
            Some(json!(["account", runner.state_dir().display().to_string()])),
        ),
        (
            "KEN-1",
            &accountless,
            &unadmitted,
            "setting-invalid",
            Some(json!(["key", "ORCH_LANE_OUTPUT"])),
        ),
    ];
    for (item, record, extra, key, field) in rows {
        runner.write_fleet(record);
        let out = relaunch(&runner, dir.path(), item, extra);
        assert_eq!(refused_by(&out), key, "{item}");
        if let Some(field) = field {
            let fields = reply(&out)["refusal"]["fields"].clone();
            assert!(
                fields.as_array().is_some_and(|f| f.contains(&field)),
                "{fields}"
            );
        }
        assert_eq!(
            runner.fleet()["lanes"][0]["status"],
            "running",
            "{key}: nothing closed"
        );
    }
}

/// A relaunch whose launch fails after a confirmed close, here on a
/// recorded socket whose directory its server may not bind in, answers
/// `launch-failed` at exit 3 naming the close's intent and the server's own
/// line: the one signal that the lane now stands closed.
#[test]
fn lane_relaunch_whose_launch_fails_after_the_close_names_the_close() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let sockets = dir.path().join("sockets");
    std::fs::create_dir(&sockets).unwrap();
    let server = Server::start(&sockets, "fleet");
    let runner = relaunch_world(dir.path(), &server, 5, CLASS);
    end_server(&server, harness_pid(&runner, "KEN-1"));
    std::fs::set_permissions(&sockets, std::fs::Permissions::from_mode(0o500)).unwrap();
    let out = relaunch(&runner, dir.path(), "KEN-1", &[]);
    std::fs::set_permissions(&sockets, std::fs::Permissions::from_mode(0o700)).unwrap();
    let text = stderr(&out);
    assert_eq!(out.status.code(), Some(3), "{text}");
    let line = text
        .lines()
        .find(|l| l.starts_with("orch-runtime: launch-failed item=KEN-1 "))
        .unwrap_or_else(|| panic!("no launch-failed line: {text}"));
    let fleet = runner.fleet();
    let closes: Vec<&str> = fleet["intents"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["op"] == "close-resources" && i["target"] == "KEN-1")
        .filter_map(|i| i["id"].as_str())
        .collect();
    assert_eq!(closes.len(), 1, "{closes:?}");
    assert!(
        line.split(' ').any(|w| w == format!("close={}", closes[0])),
        "{line}"
    );
    assert!(
        line.split(' ').any(|w| w == "cause=tmux-server-unstarted"),
        "{line}"
    );
    let said = std::fs::read_to_string(runner.state_dir().join("tmux-server.err")).unwrap();
    let said = said
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or_else(|| panic!("the server said nothing: {line}"));
    assert!(line.ends_with(&format!(" detail={said}")), "{line}");
    assert_ne!(
        fleet["lanes"][0]["status"], "running",
        "{}",
        fleet["lanes"][0]
    );
}

/// A launch whose server is gone from a socket the controller record does
/// not name, the caller's own, starts no server there: the fleet stays on
/// its recorded server. A fleet with no controller record names none.
#[test]
fn a_launch_off_the_recorded_socket_starts_no_server() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let killed = tmux(&server.socket, &["kill-server"]);
    assert!(killed.status.success(), "{}", stderr(&killed));
    let deadline = Instant::now() + Duration::from_secs(10);
    while live(server.pid) {
        assert!(Instant::now() < deadline, "the fleet server never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
    let elsewhere = dir.path().join("recorded.sock").display().to_string();
    let rows = [
        ("KEN-10", None),
        ("KEN-12", Some(json!({"server_socket": elsewhere}))),
    ];
    for (item, controller) in rows {
        if let Some(controller) = controller {
            let mut fleet = runner.fleet();
            fleet["controller"] = controller;
            runner.write_fleet(&fleet);
        }
        let report = effect_report(&runner.op_fleet(&launch_request(item, runner.state_dir())));
        assert_eq!(report["intent"]["outcome"], "failed", "{item}: {report}");
        let observation = &report["intent"]["observation"];
        assert_eq!(
            observation["cause"], "tmux-server-absent",
            "{item}: {observation}"
        );
        assert!(
            std::os::unix::net::UnixStream::connect(&server.socket).is_err(),
            "{item}: no server listens on the caller's socket"
        );
        assert!(
            !runner.state_dir().join("tmux-server.runner").exists(),
            "{item}: no server job recorded"
        );
    }
}

/// A started fleet server that exits at once, here on a socket its own
/// directory will not let it bind, refuses as soon as it ended, never at
/// the end of the bound, with the server's own last stderr line as the
/// refusal's cause.
#[test]
fn a_fleet_server_that_exits_at_once_refuses_at_once_with_its_own_line() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let shut = dir.path().join("shut");
    std::fs::create_dir(&shut).unwrap();
    std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o500)).unwrap();
    let socket = shut.join("tmux.sock");
    let mut fleet = runner.fleet();
    fleet["controller"] = json!({"server_socket": socket.display().to_string()});
    runner.write_fleet(&fleet);
    let bound = Duration::from_secs(60);
    let started = Instant::now();
    let report = effect_report(&runner.op_fleet_env(
        &launch_request("KEN-13", runner.state_dir()),
        &[
            ("TMUX", &format!("{},0,0", socket.display())),
            (
                "AGENT_RUNTIME_TMUX_VERIFY_SECS",
                &bound.as_secs().to_string(),
            ),
        ],
    ));
    let elapsed = started.elapsed();
    std::fs::set_permissions(&shut, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(
        observation["cause"], "tmux-server-unstarted",
        "{observation}"
    );
    let said = std::fs::read_to_string(runner.state_dir().join("tmux-server.err")).unwrap();
    assert_eq!(
        observation["detail"].as_str(),
        said.lines().rev().find(|l| !l.trim().is_empty()),
        "{observation}"
    );
    assert!(elapsed < bound / 2, "{elapsed:?}: {observation}");
}

#[test]
fn a_launch_with_no_tmux_session_records_failed() {
    // A refusal the effect knows before any window opens records `failed`,
    // never a bare error that wedges the intent at not-started.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let out = runner.op_fleet_env(
        &launch_request("KEN-10", runner.state_dir()),
        &[("AGENT_RUNTIME_TMUX_SESSION", "nosuch")],
    );
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
    // The session the launch looked for and the socket it looked on ride
    // the observation, so the record names what to repair.
    let observation = &report["intent"]["observation"];
    assert_eq!(
        observation["cause"], "tmux-session-missing",
        "{observation}"
    );
    assert_eq!(observation["session"], "nosuch", "{observation}");
    assert_eq!(
        observation["socket"],
        server.socket.display().to_string(),
        "{observation}"
    );
    assert_eq!(server.panes().len(), 1, "no window ever opened");
}

#[test]
fn a_launch_whose_harness_exits_during_the_poll_records_failed() {
    // The harness exits while the launch polls its pane; the pane goes, and
    // the launch records `failed`, not an error.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-slow-exit");
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-11", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
}

#[test]
fn reconcile_close_on_a_start_mismatch_records_unconfirmed() {
    // A live pid whose recorded start no longer matches is an identity change,
    // not gone, so the close stays unconfirmed, not done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-20",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-resources",
        "KEN-20",
        "unconfirmed",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "running",
        "the lane is not done"
    );
    assert!(live(owned.pid()), "reconcile starts no effect");
}

#[test]
fn reconcile_close_marks_done_only_when_the_identity_is_confirmed_gone() {
    // A pid no process holds is confirmed gone, so the close completes and the
    // lane reads done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-21",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": GONE_PID, "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-resources",
        "KEN-21",
        "unconfirmed",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "done");
}

#[test]
fn a_close_stops_the_detached_wake_turn_before_the_lane_reads_done() {
    // The lane's `wake` turn runs outside the pane's process tree, so the
    // close stops it by the identity the record names before the lane reads
    // done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-30", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "confirmed");
    // A detached turn the test owns, recorded as the lane's `wake`.
    let wake = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"][0]["wake"] = json!({"pid": wake.pid(), "start": wake.start()});
    runner.write_fleet(&fleet);
    assert!(live(wake.pid()));
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-30")));
    assert_eq!(closed["intent"]["outcome"], "confirmed");
    assert_eq!(closed["lane"]["status"], "done");
    assert!(!live(wake.pid()), "the wake turn was stopped");
}

/// The private server a launch opened on is killed and another started on
/// the same socket. One socket is held by one server, so the recorded pane
/// is gone: the launch fails on reconcile and the close that follows ends
/// the lane.
#[test]
fn a_launch_whose_server_was_replaced_fails_on_reconcile_and_closes() {
    let dir = tempfile::tempdir().unwrap();
    let first = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&first, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-C", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    let killed = tmux(&first.socket, &["kill-server"]);
    assert!(killed.status.success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while live(first.pid) {
        assert!(Instant::now() < deadline, "the first server never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
    let second = Server::start(dir.path(), "fleet");
    assert_eq!(second.socket, first.socket);
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "failed", "{again}");
    assert_eq!(again["intent"]["observation"]["cause"], "server-replaced");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-C")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(
        second.panes().len(),
        1,
        "nothing opened on the second server"
    );
}

/// A launch whose harness never draws is left unconfirmed, and a close then
/// supersedes it: the launch intent closes `failed` with
/// `superseded-by-close`, the close stops the pane's foreground harness by
/// the identity read then, and the lane is done.
#[test]
fn a_close_supersedes_a_launch_that_never_drew() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-P", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "unconfirmed");
    let launch_id = launched["intent"]["id"].as_str().unwrap().to_owned();
    let pane = launched["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let harness_pid = server.harness_pid(&pane);
    assert!(live(harness_pid));
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-P")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(closed["intent"]["observation"]["stop"], "pane-foreground");
    assert_eq!(
        closed["intent"]["observation"]["process"]["identity"]["pid"],
        harness_pid
    );
    assert!(!live(harness_pid), "the harness in the pane was stopped");
    assert_eq!(server.panes().len(), 1, "the window is closed");
    let intents = runner.fleet()["intents"].as_array().unwrap().clone();
    assert_eq!(intents.len(), 2);
    let launch = intents.iter().find(|i| i["id"] == launch_id).unwrap();
    assert_eq!(launch["outcome"], "failed");
    assert_eq!(launch["observation"]["cause"], "superseded-by-close");
    assert!(launch["completed_at"].is_string());
}

/// A `stopped` lane recorded under one harness word is relaunched under
/// another and never draws, so the lane keeps its earlier word. The close
/// that supersedes the launch judges the pane's foreground by the harness
/// the launch selected and stops it by identity, never by the lane's
/// earlier word, which would read the harness as foreign and kill the
/// window alone.
#[test]
fn a_superseding_close_stops_the_relaunched_harness_not_the_lane_s_earlier_word() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let mut fleet = runner.fleet();
    let mut stopped = lane("KEN-H", "stopped", &runner, Value::Null);
    stopped["harness"] = json!("codex");
    fleet["lanes"] = json!([stopped]);
    runner.write_fleet(&fleet);
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-H", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["harness"],
        "codex",
        "the lane keeps its earlier word until a launch confirms"
    );
    let pane = launched["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let harness_pid = server.harness_pid(&pane);
    assert!(live(harness_pid));
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-H")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(closed["intent"]["observation"]["stop"], "pane-foreground");
    assert_eq!(
        closed["intent"]["observation"]["process"]["identity"]["pid"],
        harness_pid
    );
    assert!(!live(harness_pid), "the harness in the pane was stopped");
    assert_eq!(server.panes().len(), 1, "the window is closed");
}

/// A contender reconciles an intent whose owner is a live process still
/// before its first window. The owner is held at `new-window` by the
/// tmux-hold shim with its intent persisted at the `opening` phase; the
/// contender's reconcile reads `owner-live` and touches nothing, and the
/// owner, released, opens its window carrying its intent id and confirms.
#[test]
fn a_contender_reconciling_a_live_owners_intent_reports_owner_live() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let real_tmux = which_tmux();
    let holddir = fixtures().join("tmux-hold");
    let fifo = runner.state_dir().join("hold.fifo");
    mkfifo(&fifo);
    let request = launch_request("KEN-1", runner.state_dir());
    let owner = runner.spawn_op_fleet(
        &request,
        &[
            ("TMUX_REAL", &real_tmux),
            ("TMUX_HOLD_FIFO", &fifo.display().to_string()),
        ],
        &holddir,
    );
    // The owner persists its intent at `opening`, then the shim holds it at
    // new-window: no window exists yet, so a reconcile without the owner
    // check would read `nothing-opened` and fail the intent.
    wait_for_phase(&runner, "launch-session:KEN-1", "opening");
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "owner-live");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
    assert_eq!(
        runner.fleet()["intents"][0]["phase"]["phase"],
        "opening",
        "the contender left the phase untouched"
    );
    // Release the owner: it opens its window carrying its intent id, and
    // confirms; the contender moved none of its record.
    std::fs::write(&fifo, b"go\n").unwrap();
    let out = owner.wait_with_output().expect("owner op");
    assert!(
        reply(&out)["ok"].as_bool().unwrap_or(false),
        "owner refused: {}",
        stderr(&out)
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert_eq!(runner.fleet()["intents"][0]["outcome"], "confirmed");
}

/// A reconcile at `opening` with a dead owner never adopts a window the
/// intent neither recorded nor received a receipt for, however present a
/// harness in it is. The window is left standing and the launch fails
/// `nothing-opened`.
#[test]
fn an_unrecorded_unreceipted_window_is_never_adopted_at_the_opening_phase() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let since = now_ms();
    // A window on the server running the harness, opened by something
    // other than this intent: no record names it and no receipt does.
    let pane = server.open_stub(
        "KEN-M",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let fleet = lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(opening_phase(&server, since, None)),
    );
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "nothing-opened");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
    assert!(
        server.panes().iter().any(|p| p == &pane),
        "the window is left alone"
    );
}

/// The runtime dies after its window is created and before `new-window`
/// answered with the pane id, so the pane was never recorded and, its line
/// never typed, never registered. The server's `after-new-window` hook
/// holds the `new-window` client on a `wait-for` channel, so the window
/// exists while the runtime is still inside that one command; the test
/// kills the runtime, its own child, there and releases the hook. The phase
/// records that the launcher was asked, so the window possibly opened is an
/// obligation nothing read discharges: the reconcile holds the launch
/// `unconfirmed` with `window-unread` and the window on its server
/// standing, never adopted, never assumed absent, and the lane as found.
#[test]
fn a_crash_inside_new_window_leaves_a_stray_that_is_never_adopted() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("tmux.conf");
    std::fs::write(
        &config,
        "set-hook -g after-new-window 'wait-for orch-hold'\n",
    )
    .unwrap();
    let server = Server::start_with_config(dir.path(), "fleet", &config);
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let request = launch_request("KEN-1", runner.state_dir());
    let mut owner = runner.spawn_op_fleet(&request, &[], runner.state_dir());
    wait_for_phase(&runner, "launch-session:KEN-1", "opening");
    // The window exists once the server lists two panes; the hook then holds
    // the runtime's `new-window` until the channel is signalled.
    let deadline = Instant::now() + Duration::from_secs(10);
    while server.panes().len() < 2 {
        assert!(Instant::now() < deadline, "the window never opened");
        std::thread::sleep(Duration::from_millis(20));
    }
    owner.kill().expect("kill the held runtime");
    owner.wait().expect("reap the held runtime");
    let released = tmux(&server.socket, &["wait-for", "-S", "orch-hold"]);
    assert!(
        released.status.success(),
        "wait-for -S: {}",
        stderr(&released)
    );
    let panes = server.panes();
    assert_eq!(panes.len(), 2);
    assert!(
        runner.fleet()["intents"][0]["phase"]["pane"].is_null(),
        "the pane was never recorded"
    );
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["note"], "window-unread");
    assert_eq!(
        remaining(observation, "window")["server"],
        json!(server.pid),
        "the window possibly opened stands as an obligation: {observation}"
    );
    let fleet = runner.fleet();
    assert!(
        fleet["intents"][0]["completed_at"].is_null(),
        "the intent stays open"
    );
    assert_eq!(fleet["lanes"][0]["status"], "preparing");
    assert!(fleet["lanes"][0]["launch"].is_null(), "no pane bound");
    assert_eq!(server.panes(), panes, "the stray stands untouched");
}

/// A server whose `after-new-window` hook fails makes tmux exit non-zero
/// after the launch's window opened and its pane was printed: the launch
/// fails with tmux's refusal, the window closed by its exact id and
/// nothing left standing on the server.
#[test]
fn a_new_window_whose_hook_fails_after_the_window_opened_leaves_no_window() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("tmux.conf");
    std::fs::write(
        &config,
        "set-hook -g after-new-window 'run-shell \"exit 1\"'\n",
    )
    .unwrap();
    let server = Server::start_with_config(dir.path(), "fleet", &config);
    let panes = server.panes();
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["note"], "launch-line-unsent");
    assert_eq!(observation["refusal"], "tmux-refused");
    assert_eq!(report["lane"]["status"], "stopped", "{report}");
    assert_eq!(server.panes(), panes, "the window is closed");
}

/// A close whose recorded pid runs under another start, with no pane
/// recorded. The first reconcile reading is `unconfirmed` with `identity:
/// stale`; a second, independent reading confirms the close, and the live
/// process is never signalled.
#[test]
fn a_close_over_a_reused_pid_confirms_on_the_second_independent_reading() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-R",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent("close-resources", "KEN-R", "not-started", None)]);
    runner.write_fleet(&fleet);
    let first = runner.reconcile_one();
    assert_eq!(first["intent"]["outcome"], "unconfirmed", "{first}");
    assert_eq!(first["intent"]["observation"]["identity"], "stale");
    assert_eq!(first["intent"]["observation"]["readings"], 1);
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    let second = runner.reconcile_one();
    assert_eq!(second["intent"]["outcome"], "confirmed", "{second}");
    assert_eq!(second["intent"]["observation"]["identity"], "stale");
    assert_eq!(second["intent"]["observation"]["readings"], 2);
    assert_eq!(runner.fleet()["lanes"][0]["status"], "done");
    assert!(
        live(owned.pid()),
        "the process under the reused pid was never signalled"
    );
}

/// What one matrix cell plants: the fleet state, and what it holds open so
/// the planted processes and panes outlive the reconcile.
struct Planted {
    fleet: Value,
    owned: Vec<Owned>,
}

/// One cell of the reconcile matrix: the intent's operation and recorded
/// phase, whether a recorded identity is present, the observed state the
/// row plants, and the outcome the reconcile must record.
struct Cell {
    op: &'static str,
    phase: &'static str,
    identity: &'static str,
    observed: &'static str,
    expect: &'static str,
    plant: fn(&Runner, &Server) -> Planted,
    check: fn(&Runner, &Server, &Value),
}

const ORIGINAL_PENDING: &str =
    r#"{"launch_line": "cd /r && claude --model older", "harness": "claude"}"#;

fn original_pending() -> Value {
    serde_json::from_str(ORIGINAL_PENDING).unwrap()
}

/// The fleet with one lane and one launch or close intent.
fn lane_fleet(
    runner: &Runner,
    op: &str,
    status: &str,
    launch: Value,
    phase: Option<Value>,
) -> Value {
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-M", status, runner, launch)]);
    fleet["intents"] = json!([lane_intent(op, "KEN-M", "not-started", phase)]);
    fleet
}

/// The fleet with the overseer record naming `predecessor`, the successor
/// pending, and one transfer intent at `phase` holding the original pending.
fn transfer_fleet(
    runner: &Runner,
    server: &Server,
    predecessor: (u32, &str),
    phase: Option<Value>,
) -> Value {
    let mut fleet = runner.fleet();
    fleet["controller"] = overseer_record(predecessor.0, predecessor.1, server, runner.state_dir());
    fleet["controller"]["pending"] = pending(runner.state_dir());
    fleet["intents"] = json!([transfer_intent(phase, Some(original_pending()))]);
    fleet
}

fn no_check(_: &Runner, _: &Server, _: &Value) {}

/// An unanswering socket whose recorded server process still runs: a
/// process the test owns stands for the server, the one unobservable case.
fn unanswering_server(runner: &Runner, process: &Owned) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: process.pid(),
        start: 1,
        process_start: process.start(),
        guard: None,
    }
}

/// An unanswering socket whose recorded server process is gone: the server
/// and every pane it held are gone.
fn gone_server(runner: &Runner) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: GONE_PID as u32,
        start: 1,
        process_start: "ticks:1".to_owned(),
        guard: None,
    }
}

/// A `delivered` phase bound to `file`, the runner's own session file.
fn delivered(server: &Server, pane: &str, since_ms: u64, file: &Path) -> Value {
    let brief = server.socket.parent().unwrap().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let mut phase = phase("delivered", server, pane, since_ms, Some(&brief));
    phase["turns_before"] = json!(0);
    phase["session"] = json!({
        "session_id": file.file_stem().unwrap().to_str().unwrap(),
        "file": file.display().to_string(),
    });
    phase
}

/// The reconcile matrix over (operation, recorded phase, recorded identity,
/// observed state), one cell per row, each yielding its outcome and none
/// left without one. `retired` is read from the predecessor's identity, an
/// unobservable pane is `unconfirmed`, a failed transfer keeps the original
/// pending, and a confirmed launch binds a session read since its own
/// window opened.
#[test]
fn the_reconcile_matrix_is_total() {
    reconcile_cells(vec![
        Cell {
            op: "launch",
            phase: "none",
            identity: "-",
            observed: "nothing opened",
            expect: "failed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(runner, "launch-session", "preparing", Value::Null, None),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "pane gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(phase("window-opened", server, "%77", now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, _| {
                let process = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(phase(
                        "window-opened",
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        None,
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["observed"], "unobservable");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "server gone",
            expect: "failed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(phase(
                        "window-opened",
                        &gone_server(runner),
                        "%1",
                        now_ms(),
                        None,
                    )),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["cause"], "server-gone");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "pane present, harness word unknown",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                fleet["lanes"][0]["harness"] = json!("nosuch");
                fleet["intents"][0]["selection"] =
                    json!({"harness": "nosuch", "class": CLASS, "class_reason": CLASS_REASON});
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["cause"], "harness-unknown");
                assert_eq!(report["intent"]["observation"]["observed"], "present");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "shell foreground",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-shell",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "harness undrawn",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-unconfirmed",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_harness(&pane);
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["state"]["state"],
                    "unjudged"
                );
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "harness idle",
            expect: "confirmed",
            plant: |runner, server| {
                // A lead session an earlier run left for the cwd, written
                // before the window opened; the floor excludes it.
                let dir = project_dir(runner.state_dir(), runner.state_dir());
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(
                    dir.join("older.jsonl"),
                    format!("{}\n", neighbour_row("user", runner.state_dir())),
                )
                .unwrap();
                std::thread::sleep(Duration::from_millis(20));
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The stub's first turn, as a lane's brief is: the row that
                // names the session's cwd.
                let own = dir.join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                let typed = tmux(
                    &server.socket,
                    &["send-keys", "-t", &pane, "BRIEF", "Enter"],
                );
                assert!(typed.status.success());
                let deadline = Instant::now() + Duration::from_secs(5);
                while file_turns(&own).is_empty() {
                    assert!(Instant::now() < deadline, "the stub recorded no turn");
                    std::thread::sleep(Duration::from_millis(50));
                }
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, _| {
                let lane = runner.fleet()["lanes"][0].clone();
                assert_eq!(lane["status"], "running");
                let pane = lane["launch"]["pane"].as_str().unwrap().to_owned();
                let pid = server.pane_pid(&pane);
                assert_eq!(lane["launch"]["pid"], pid);
                // The session bound is the stub's own, written since the
                // window opened, never the older lead in the same directory.
                assert_eq!(lane["session_id"], format!("stub-{pid}"));
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane gone",
            expect: "confirmed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "close-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": null, "start": null}),
                    None,
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "done"),
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane present",
            expect: "unconfirmed",
            plant: |runner, server| {
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "close-resources",
                        "running",
                        json!({"pane": pane, "server": server.pid, "pid": null, "start": null}),
                        None,
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["pane"], "present");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane unrecorded",
            expect: "unconfirmed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(runner, "close-resources", "running", Value::Null, None),
                owned: vec![],
            },
            check: no_check,
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "gone",
            expect: "confirmed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "close-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": GONE_PID, "start": "ticks:1"}),
                    None,
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "done"),
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "live, same start",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "close-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": owned.pid(), "start": owned.start()}),
                    None,
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["stop"], "pending");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "live, other start",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "close-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
                    None,
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["identity"], "stale");
                assert_eq!(report["intent"]["observation"]["readings"], 1);
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "transfer",
            phase: "none",
            identity: "predecessor",
            observed: "predecessor live",
            expect: "failed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = transfer_fleet(runner, server, (owned.pid(), &owned.start()), None);
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert_eq!(
                    runner.fleet()["controller"]["pending"],
                    original_pending(),
                    "the original pending is put back"
                );
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "none",
            identity: "predecessor",
            observed: "predecessor gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(runner, server, (GONE_PID as u32, "ticks:1"), None),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor",
            observed: "predecessor live, runner present",
            expect: "failed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (owned.pid(), &owned.start()),
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert_eq!(
                    server.panes().len(),
                    1,
                    "the runner was stopped and its window closed"
                );
                assert_eq!(runner.fleet()["controller"]["pending"], original_pending());
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner idle, no brief",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                let overseer = runner.fleet()["controller"].clone();
                assert_eq!(overseer["generation"], 4);
                let pane = overseer["pane"].as_str().unwrap().to_owned();
                assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("window-opened", server, "%77", now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase(
                        "window-opened",
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        None,
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                let overseer = runner.fleet()["controller"].clone();
                assert_eq!(overseer["generation"], 3);
                assert_eq!(
                    overseer["pending"]["runner"]["pane"], "%1",
                    "the runner is kept"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "server gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase(
                        "window-opened",
                        &gone_server(runner),
                        "%1",
                        now_ms(),
                        None,
                    )),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(report["intent"]["observation"]["cause"], "server-gone");
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner up, not idle, no brief",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-unconfirmed",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_harness(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "successor-not-idle"
                );
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
                assert!(runner.fleet()["controller"]["pending"]["runner"].is_object());
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner idle, pending's directory gone",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                fleet["controller"]["pending"]["cwd"] = json!("/nonexistent/successor/dir");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "cwd-missing");
                assert_eq!(report["intent"]["observation"]["retired"], true);
                let overseer = runner.fleet()["controller"].clone();
                assert_eq!(overseer["generation"], 3);
                let kept = overseer["pending"]["runner"]["pane"].as_str().unwrap();
                assert!(
                    server.panes().iter().any(|p| p == kept),
                    "the runner is kept, its pane standing"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner idle, pending missing",
            expect: "failed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                fleet["controller"]
                    .as_object_mut()
                    .unwrap()
                    .remove("pending");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pending-missing");
                assert_eq!(report["intent"]["observation"]["runner"], "stopped");
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
                assert_eq!(server.panes().len(), 1, "the runner's window is closed");
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner idle, brief held",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let brief = runner.state_dir().join("handoff.md");
                std::fs::write(&brief, "HANDOFF\n").unwrap();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The id the launch fixed, which names the runner's file before
                // it carries a turn.
                let mut phase = phase("window-opened", server, &pane, since, Some(&brief));
                phase["session_id"] = json!(format!("stub-{}", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
                assert_eq!(
                    runner.stub_turns(runner.state_dir(), runner.state_dir()),
                    vec!["HANDOFF".to_owned()]
                );
                assert_eq!(runner.fleet()["controller"]["generation"], 4);
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner not idle, brief held",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let brief = runner.state_dir().join("handoff.md");
                std::fs::write(&brief, "HANDOFF\n").unwrap();
                let pane = server.open_stub(
                    "overseer",
                    "stub-shell",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("window-opened", server, &pane, since, Some(&brief))),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "successor-not-idle"
                );
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "delivering",
            identity: "predecessor gone",
            observed: "the paste possibly made, no turn recorded",
            expect: "unconfirmed",
            // The phase written before the paste. A reconcile that finds it
            // waits for the turn and never pastes again: the stub, which
            // records every line it reads, records none.
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                let mut delivering = delivered(server, &pane, since, &file);
                delivering["phase"] = json!("delivering");
                delivering["lines"] = json!(1);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivering),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
                assert!(
                    runner
                        .stub_turns(runner.state_dir(), runner.state_dir())
                        .is_empty(),
                    "a brief recorded as delivering is never pasted again"
                );
                assert_eq!(report["intent"]["phase"]["phase"], "delivering");
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "no turn recorded",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-mute",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
                assert!(
                    runner.fleet()["controller"]["pending"]["runner"].is_object(),
                    "the runner is kept"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "a neighbour's turn only",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-mute",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let neighbour =
                    Neighbour::writing(runner.state_dir(), runner.state_dir(), 1, "user");
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![neighbour._writer],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(delivered(
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        Path::new("/h/projects/-w/0f6e.jsonl"),
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
                assert_eq!(
                    runner.fleet()["controller"]["pending"]["runner"]["pane"],
                    "%1"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "turn recorded",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The turn the delivery produced, typed as the paste would be.
                let typed = tmux(
                    &server.socket,
                    &["send-keys", "-t", &pane, "HANDOFF", "Enter"],
                );
                assert!(typed.status.success());
                let deadline = Instant::now() + Duration::from_secs(5);
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                while file_turns(&file).is_empty() {
                    assert!(Instant::now() < deadline, "the stub recorded no turn");
                    std::thread::sleep(Duration::from_millis(50));
                }
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(runner.fleet()["controller"]["generation"], 4);
                assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
            },
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner live",
            observed: "runner present",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let pid = server.pane_pid(&pane);
                let mut phase = phase("identity-read", server, &pane, since, None);
                phase["pid"] = json!(pid);
                phase["start"] = json!(start_of(pid));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["controller"]["generation"], 4),
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner live",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let mut phase = phase(
                    "identity-read",
                    &unanswering_server(runner, &process),
                    "%1",
                    now_ms(),
                    None,
                );
                phase["pid"] = json!(process.pid());
                phase["start"] = json!(process.start());
                let fleet =
                    transfer_fleet(runner, server, (GONE_PID as u32, "ticks:1"), Some(phase));
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                let kept = runner.fleet()["controller"]["pending"]["runner"].clone();
                assert_eq!(kept["pane"], "%1");
                assert!(
                    kept["pid"].as_u64().is_some(),
                    "the recorded identity is kept"
                );
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner gone",
            observed: "runner present under another identity",
            expect: "failed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut phase = phase("identity-read", server, &pane, since, None);
                phase["pid"] = json!(GONE_PID);
                phase["start"] = json!("ticks:1");
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            // A reconcile that finds the intent's owner live defers to it and
            // touches nothing, whatever the pane reads.
            op: "launch",
            phase: "window-opened",
            identity: "owner live",
            observed: "owner-live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owner = Owned::sleep();
                let mut fleet = lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(phase("window-opened", server, "%77", now_ms(), None)),
                );
                fleet["intents"][0]["owner"] = json!({"pid": owner.pid(), "start": owner.start()});
                Planted {
                    fleet,
                    owned: vec![owner],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "owner-live");
                // The record is untouched: the lane stays preparing and the
                // phase is not advanced.
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
                assert_eq!(
                    runner.fleet()["intents"][0]["phase"]["phase"],
                    "window-opened"
                );
            },
        },
        Cell {
            // A crash before the open: an intent at `opening` with a dead
            // owner, no pane recorded and no receipt written.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "no pane recorded, no receipt",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(opening_phase(server, now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "nothing-opened");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
            },
        },
        Cell {
            // A crash after the pane registered and before the record named it:
            // the receipt names a live harness in its pane. The reconcile
            // adopts that exact pane and completes, noting the receipt it
            // adopted by.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "receipt names a live harness, no pane recorded",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                plant_receipt(
                    runner,
                    "launch-session:KEN-M:1-1",
                    &pane,
                    server.pane_pid(&pane),
                );
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(opening_phase(server, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                let fleet = runner.fleet();
                assert_eq!(fleet["lanes"][0]["status"], "running");
                let phase = &fleet["intents"][0]["phase"];
                assert_eq!(phase["phase"], "window-opened");
                let panes = server.panes();
                assert_eq!(panes.len(), 2);
                assert_eq!(
                    phase["pane"], panes[1],
                    "the adopted pane is the receipted one"
                );
                assert_eq!(fleet["lanes"][0]["launch"]["pane"], panes[1]);
                let registered = &report["intent"]["observation"]["registered"];
                assert_eq!(registered["pane"], panes[1]);
                // The identity the receipt proved is the one the phase carries
                // and the one the publication records, pid and start alike.
                let pid = registered["pid"].as_u64().expect("the receipt's pid") as u32;
                assert_eq!(phase["identity"]["pid"], pid);
                assert_eq!(phase["identity"]["start"], start_of(pid));
                assert_eq!(fleet["lanes"][0]["launch"]["pid"], pid);
                assert_eq!(fleet["lanes"][0]["launch"]["start"], start_of(pid));
            },
        },
        Cell {
            // The pane was recorded and its line has not run within the bound.
            // Held: nothing bound, nothing failed, the pane kept for the next
            // reconcile.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "pane recorded, no receipt, within the bound",
            expect: "unconfirmed",
            plant: |runner, server| {
                let pane = server.open_idle("KEN-M", runner.state_dir());
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(opening_phase(server, now_ms(), Some(&pane))),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "receipt-pending");
                let fleet = runner.fleet();
                assert_eq!(fleet["lanes"][0]["status"], "preparing");
                assert!(fleet["lanes"][0]["launch"].is_null(), "no pane bound");
                assert_eq!(fleet["intents"][0]["phase"]["phase"], "opening");
                assert_eq!(server.panes().len(), 2, "the pane is kept");
            },
        },
        Cell {
            // The recorded pane never registered within the bound: it is ours
            // and holds no harness, so that exact pane is closed and the launch
            // fails. An unrelated window on the same server is not touched, and
            // neither is a sibling pane a hook split into the recorded pane's
            // own window: the close is by pane id, not by window.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "pane recorded, no receipt, past the bound",
            expect: "failed",
            plant: |runner, server| {
                let other = server.open_stub(
                    "KEN-other",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&other);
                let pane = server.open_idle("KEN-M", runner.state_dir());
                server.split(&pane);
                // The matrix runner's bound is one second; five seconds ago
                // is past it.
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(opening_phase(server, now_ms() - 5_000, Some(&pane))),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "nothing-registered"
                );
                assert_eq!(report["intent"]["observation"]["cause"], "pane-closed");
                let fleet = runner.fleet();
                assert_eq!(fleet["lanes"][0]["status"], "stopped");
                let recorded = fleet["intents"][0]["phase"]["pane"]
                    .as_str()
                    .expect("the recorded pane")
                    .to_owned();
                let panes = server.panes();
                assert!(
                    !panes.contains(&recorded),
                    "the recorded pane is closed: {panes:?}"
                );
                assert_eq!(
                    panes.len(),
                    3,
                    "the server's own, the unrelated window's and the sibling stand: {panes:?}"
                );
                let names = server.window_names();
                assert!(
                    names.iter().any(|n| n == "KEN-M"),
                    "the sibling keeps the recorded pane's window: {names:?}"
                );
                assert!(
                    names.iter().any(|n| n == "KEN-other"),
                    "the unrelated window survives: {names:?}"
                );
            },
        },
        Cell {
            // The recorded pane is already gone and no receipt stands: nothing
            // can register from it.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "pane recorded and gone, no receipt",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-session",
                    "preparing",
                    Value::Null,
                    Some(opening_phase(server, now_ms(), Some("%77"))),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "nothing-registered"
                );
                assert_eq!(report["intent"]["observation"]["cause"], "pane-gone");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
            },
        },
        Cell {
            // A receipt that is not this intent's shape is held, never read as
            // absence: nothing bound, nothing failed, nothing closed.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "receipt malformed",
            expect: "unconfirmed",
            plant: |runner, server| {
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                plant_receipt_text(runner, "launch-session:KEN-M:1-1", "{\"intent\":");
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(opening_phase(server, now_ms(), None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "receipt-invalid");
                assert_eq!(report["intent"]["observation"]["cause"], "json-invalid");
                let fleet = runner.fleet();
                assert_eq!(fleet["lanes"][0]["status"], "preparing");
                assert!(fleet["lanes"][0]["launch"].is_null(), "no pane bound");
                assert_eq!(fleet["intents"][0]["phase"]["phase"], "opening");
                assert_eq!(server.panes().len(), 2, "the pane is kept");
            },
        },
        Cell {
            // The succession arm: the runner's receipt names a live runner
            // before retirement. Adopted, then abandoned as a `window-opened`
            // reconcile abandons it: the runner stopped, the predecessor in
            // control, the original pending put back.
            op: "transfer",
            phase: "opening",
            identity: "predecessor live",
            observed: "receipt names a live runner",
            expect: "failed",
            plant: |runner, server| {
                let predecessor = Owned::sleep();
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                plant_receipt(
                    runner,
                    "request-transfer:overseer:3:1-1",
                    &pane,
                    server.pane_pid(&pane),
                );
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (predecessor.pid(), &predecessor.start()),
                        Some(opening_phase(server, since, None)),
                    ),
                    owned: vec![predecessor],
                }
            },
            check: |runner, server, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "abandoned-before-retirement"
                );
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert!(
                    report["intent"]["observation"]["registered"]["pid"]
                        .as_u64()
                        .is_some(),
                    "the receipt adopted by is noted"
                );
                assert_eq!(
                    server.panes().len(),
                    1,
                    "the runner was stopped and its window closed"
                );
                assert_eq!(runner.fleet()["controller"]["pending"], original_pending());
                assert_eq!(runner.fleet()["controller"]["generation"], 3);
            },
        },
        Cell {
            // The succession arm: a malformed receipt is held. The intent stays
            // open, the successor pending stands as the request wrote it, the
            // predecessor keeps control, the pane is kept.
            op: "transfer",
            phase: "opening",
            identity: "predecessor live",
            observed: "receipt malformed",
            expect: "unconfirmed",
            plant: |runner, server| {
                let predecessor = Owned::sleep();
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                plant_receipt_text(runner, "request-transfer:overseer:3:1-1", "[]");
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (predecessor.pid(), &predecessor.start()),
                        Some(opening_phase(server, since, None)),
                    ),
                    owned: vec![predecessor],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "receipt-invalid");
                assert_eq!(report["intent"]["observation"]["cause"], "json-invalid");
                assert_eq!(report["intent"]["observation"]["retired"], false);
                let fleet = runner.fleet();
                assert_eq!(fleet["controller"]["generation"], 3);
                assert_eq!(
                    fleet["controller"]["pending"],
                    pending(runner.state_dir()),
                    "the successor pending stands as requested"
                );
                assert_eq!(fleet["intents"][0]["phase"]["phase"], "opening");
                assert_eq!(server.panes().len(), 2, "the pane is kept");
            },
        },
        Cell {
            // The succession arm: the recorded runner pane never registered
            // within the bound. That exact pane is closed, the succession fails
            // before retirement and the original pending is put back.
            op: "transfer",
            phase: "opening",
            identity: "predecessor live",
            observed: "pane recorded, no receipt, past the bound",
            expect: "failed",
            plant: |runner, server| {
                let predecessor = Owned::sleep();
                let pane = server.open_idle("overseer", runner.state_dir());
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (predecessor.pid(), &predecessor.start()),
                        Some(opening_phase(server, now_ms() - 5_000, Some(&pane))),
                    ),
                    owned: vec![predecessor],
                }
            },
            check: |runner, server, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "nothing-registered"
                );
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert_eq!(server.panes().len(), 1, "the recorded pane is closed");
                assert_eq!(runner.fleet()["controller"]["pending"], original_pending());
            },
        },
    ]);
}

/// A receipt whose pid no live process holds is a harness that exited, read
/// through the one identity reader before any adoption. Nothing is adopted;
/// the pane the receipt names, ours and holding no harness, is closed by
/// its exact id before the failure completes, and a sibling pane split into
/// the same window stands. The launch fails `harness-exited` with no pane
/// bound, the succession fails before retirement with its original pending
/// put back. The must-fail control for the identity confirmation runs these
/// two rows by this test's name.
#[test]
fn a_receipt_naming_a_dead_harness_fails_without_adopting_the_pane() {
    fn closed_exactly(server: &Server, registered: &str, sibling: &str) {
        let panes = server.panes();
        assert!(
            !panes.contains(&registered.to_owned()),
            "the registered pane is closed: {panes:?}"
        );
        assert!(
            panes.contains(&sibling.to_owned()),
            "the sibling in the same window stands: {panes:?}"
        );
        assert_eq!(panes.len(), 2, "{panes:?}");
    }
    reconcile_cells(vec![
        Cell {
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "receipt names a dead harness",
            expect: "failed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let sibling = server.split(&pane);
                plant_receipt(runner, "launch-session:KEN-M:1-1", &pane, GONE_PID as u32);
                // A fresh server numbers the session's pane %0, the stub's
                // %1 and the sibling %2.
                assert_eq!((pane.as_str(), sibling.as_str()), ("%1", "%2"));
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-session",
                        "preparing",
                        Value::Null,
                        Some(opening_phase(server, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "harness-exited");
                assert_eq!(report["intent"]["observation"]["cause"], "pane-closed");
                let fleet = runner.fleet();
                // The dead-receipt close goes through the signal-writing close,
                // which records the first signal before the kill.
                assert_eq!(
                    fleet["intents"][0]["obligations"]["signalled"], true,
                    "the recovery close records its signal: {}",
                    fleet["intents"][0]
                );
                assert_eq!(fleet["lanes"][0]["status"], "stopped");
                assert!(fleet["lanes"][0]["launch"].is_null(), "no pane bound");
                closed_exactly(server, "%1", "%2");
            },
        },
        Cell {
            op: "transfer",
            phase: "opening",
            identity: "predecessor live",
            observed: "receipt names a dead runner",
            expect: "failed",
            plant: |runner, server| {
                let predecessor = Owned::sleep();
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let sibling = server.split(&pane);
                plant_receipt(
                    runner,
                    "request-transfer:overseer:3:1-1",
                    &pane,
                    GONE_PID as u32,
                );
                assert_eq!((pane.as_str(), sibling.as_str()), ("%1", "%2"));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (predecessor.pid(), &predecessor.start()),
                        Some(opening_phase(server, since, None)),
                    ),
                    owned: vec![predecessor],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "harness-exited");
                assert_eq!(report["intent"]["observation"]["cause"], "pane-closed");
                assert_eq!(report["intent"]["observation"]["retired"], false);
                let fleet = runner.fleet();
                assert_eq!(fleet["controller"]["pending"], original_pending());
                assert_eq!(fleet["controller"]["generation"], 3);
                closed_exactly(server, "%1", "%2");
            },
        },
    ]);
}

/// At the receipt guard: the receipt names a dead harness and its pane is
/// closed by exact id before the failure completes; when the host refuses
/// that close, the launch stays open with the cause, its pane standing and
/// nothing adopted, and the reconcile completes it once the host answers,
/// closing exactly that pane.
#[test]
fn a_dead_receipts_pane_close_the_host_refuses_holds_the_launch_until_it_answers() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env = vec![
        ("TMUX_REAL".to_owned(), which_tmux()),
        ("TMUX_FAIL_VERB".to_owned(), "kill-pane".to_owned()),
    ];
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "KEN-M",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, GONE_PID as u32);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(opening_phase(&server, since, None)),
    ));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["note"], "harness-exited");
    assert!(
        observation["cause"]
            .as_str()
            .is_some_and(|cause| cause.starts_with("pane-close:")),
        "the refused close is the cause: {observation}"
    );
    let fleet = runner.fleet();
    assert!(fleet["intents"][0]["completed_at"].is_null(), "held open");
    assert_eq!(fleet["intents"][0]["phase"]["phase"], "opening");
    assert_eq!(fleet["lanes"][0]["status"], "preparing");
    assert!(fleet["lanes"][0]["launch"].is_null(), "no pane adopted");
    assert!(server.panes().contains(&pane), "the pane stands");
    // The host answers again: the reconcile closes exactly the registered
    // pane and the launch fails.
    runner.tools = None;
    runner.env.clear();
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "failed", "{again}");
    assert_eq!(again["intent"]["observation"]["note"], "harness-exited");
    assert_eq!(again["intent"]["observation"]["cause"], "pane-closed");
    assert!(
        !server.panes().contains(&pane),
        "the registered pane is closed"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
}

/// A host that stops answering between two reads of one pane settles
/// nothing. The receipt names a live harness and is adopted under its
/// identity; the capture that follows fails while the pane stands, so the
/// launch is `unconfirmed` with the cause, never `pane-gone`, the lane is
/// left preparing, the pane stands, and the phase carries the receipt's
/// identity for the next reconcile. The failure is planted through a tmux
/// shim that refuses one verb and execs the real tmux for every other.
#[test]
fn a_tmux_failure_between_reads_holds_an_adopted_launch_unconfirmed_never_pane_gone() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env = vec![
        ("TMUX_REAL".to_owned(), which_tmux()),
        ("TMUX_FAIL_VERB".to_owned(), "capture-pane".to_owned()),
    ];
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "KEN-M",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, pid);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(opening_phase(&server, since, None)),
    ));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["observed"], "unobservable");
    assert_eq!(observation["cause"], "capture-failed");
    assert_eq!(observation["registered"]["pid"], pid);
    let fleet = runner.fleet();
    assert_eq!(fleet["lanes"][0]["status"], "preparing");
    assert!(fleet["intents"][0]["completed_at"].is_null(), "held open");
    let phase = &fleet["intents"][0]["phase"];
    assert_eq!(phase["phase"], "window-opened");
    assert_eq!(phase["pane"], pane);
    assert_eq!(phase["identity"]["pid"], pid);
    assert_eq!(phase["identity"]["start"], start_of(pid));
    assert!(
        server.panes().contains(&pane),
        "the pane stands: nothing was closed on a read that failed"
    );
    assert!(live(pid), "the harness runs on");
    // The shim gone, the same intent confirms under the identity the phase
    // carries: the one the receipt proved.
    runner.tools = None;
    runner.env.clear();
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
    let fleet = runner.fleet();
    assert_eq!(fleet["lanes"][0]["status"], "running");
    assert_eq!(fleet["lanes"][0]["launch"]["pid"], pid);
    assert_eq!(fleet["lanes"][0]["launch"]["start"], start_of(pid));
}

/// A pane's disappearance never discharges the process that ran in it. The
/// pane's process ignores `SIGHUP`, as a harness beneath a wrapper may, so
/// an exact `kill-pane` leaves the pane gone and that same pid and start
/// running. At `window-opened` with that identity recorded, and at
/// `opening` with the receipt naming that pid, the reconcile holds the
/// launch `unconfirmed`: the pane is discharged by its own read, the
/// identity read live stands as the remaining obligation, the lane is left
/// as found, and nothing is closed `failed` over a process that runs on.
#[test]
fn a_process_surviving_its_panes_close_keeps_the_launch_open_with_its_identity_standing() {
    struct Cell {
        name: &'static str,
        phase: fn(&Server, &str, &Runner) -> Value,
        /// The observation key and word that say what the identity read.
        word: (&'static str, &'static str),
        cause: &'static str,
        kind: &'static str,
    }
    let cells = [
        Cell {
            name: "window-opened with the identity recorded",
            phase: |server, pane, _| {
                let pid = server.pane_pid(pane);
                let mut phase = phase("window-opened", server, pane, now_ms(), None);
                phase["identity"] = json!({"pid": pid, "start": start_of(pid)});
                phase
            },
            word: ("identity", "live"),
            cause: "pane-gone",
            kind: "process",
        },
        Cell {
            name: "opening with the receipt naming the pid",
            phase: |server, pane, runner| {
                let pid = server.pane_pid(pane);
                plant_receipt(runner, "launch-session:KEN-M:1-1", pane, pid);
                opening_phase(server, now_ms(), Some(pane))
            },
            word: ("note", "pane-gone"),
            cause: "pid-live",
            kind: "pid",
        },
    ];
    for cell in cells {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = Some(1);
        runner.init_fleet();
        // The pane's process, exec'd with SIGHUP ignored: the hangup tmux
        // sends on `kill-pane` does not end it.
        let pane = server.open_window("KEN-M", runner.state_dir(), "trap '' HUP; exec sleep 600");
        let pid = server.pane_pid(&pane);
        // The pane's pid is `sleep` once the shell has exec'd it with the
        // hangup ignored; before that the hangup would end the shell.
        let deadline = Instant::now() + Duration::from_secs(10);
        while std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .map(|comm| comm.trim() != "sleep")
            .unwrap_or(true)
        {
            assert!(
                Instant::now() < deadline,
                "{}: the pane never exec'd sleep",
                cell.name
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let phase = (cell.phase)(&server, &pane, &runner);
        runner.write_fleet(&lane_fleet(
            &runner,
            "launch-session",
            "preparing",
            Value::Null,
            Some(phase),
        ));
        let killed = tmux(&server.socket, &["kill-pane", "-t", &pane]);
        assert!(killed.status.success(), "kill-pane: {}", stderr(&killed));
        assert!(
            !server.panes().contains(&pane),
            "{}: the pane is gone",
            cell.name
        );
        assert!(live(pid), "{}: the process survived its pane", cell.name);
        let report = runner.reconcile_one();
        let observation = &report["intent"]["observation"];
        assert_eq!(
            report["intent"]["outcome"], "unconfirmed",
            "{}: {report}",
            cell.name
        );
        assert_eq!(
            observation[cell.word.0], cell.word.1,
            "{}: {observation}",
            cell.name
        );
        assert_eq!(
            observation["cause"], cell.cause,
            "{}: {observation}",
            cell.name
        );
        assert_eq!(
            remaining(observation, cell.kind)["pid"],
            pid,
            "{}: the surviving identity is the remaining obligation: {observation}",
            cell.name
        );
        assert!(
            remaining(observation, "pane").is_null(),
            "{}: the pane read gone is discharged: {observation}",
            cell.name
        );
        let fleet = runner.fleet();
        assert!(
            fleet["intents"][0]["completed_at"].is_null(),
            "{}: the intent stays open",
            cell.name
        );
        assert_eq!(fleet["lanes"][0]["status"], "preparing", "{}", cell.name);
        assert!(live(pid), "{}: nothing signalled the survivor", cell.name);
        // The test ends what it started, and reads it gone before the next
        // cell.
        let ended = std::process::Command::new("kill")
            .args(["-9", &pid.to_string()])
            .status()
            .expect("kill");
        assert!(ended.success(), "{}: kill -9 {pid}", cell.name);
        let deadline = Instant::now() + Duration::from_secs(5);
        while live(pid) {
            assert!(
                Instant::now() < deadline,
                "{}: {pid} never ended",
                cell.name
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

/// Run each cell on its own server and runner: plant, reconcile once, check
/// the outcome and the cell's own assertions, and that an `unconfirmed`
/// intent stays open while any other is closed.
fn reconcile_cells(cells: Vec<Cell>) {
    for cell in cells {
        let name = format!(
            "{} / {} / {} / {}",
            cell.op, cell.phase, cell.identity, cell.observed
        );
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = Some(1);
        runner.init_fleet();
        let planted = (cell.plant)(&runner, &server);
        runner.write_fleet(&planted.fleet);
        let report = runner.reconcile_one();
        assert_eq!(report["intent"]["outcome"], cell.expect, "{name}: {report}");
        (cell.check)(&runner, &server, &report);
        // An intent with a final outcome is closed; an unconfirmed one stays
        // open with its observation for the next reconcile.
        let intent = runner.fleet()["intents"][0].clone();
        assert_eq!(
            intent["completed_at"].is_null(),
            cell.expect == "unconfirmed",
            "{name}"
        );
        // A deferral to a live or unreadable owner is a read-only reply: the
        // observation is on the reply and the file's intent stands as planted.
        // Every other cell records its observation.
        let deferred = matches!(
            report["intent"]["observation"]["note"].as_str(),
            Some("owner-live" | "owner-unreadable")
        );
        if deferred {
            assert!(
                report["intent"]["observation"].is_object(),
                "{name}: the reply carries the observation"
            );
            assert_eq!(
                intent, planted.fleet["intents"][0],
                "{name}: a deferral writes nothing"
            );
        } else {
            assert!(
                intent["observation"].is_object(),
                "{name}: an observation is recorded"
            );
        }
        drop(planted.owned);
    }
}

/// A relaunch on another account whose home lacks the bound session starts
/// fresh with `account-switched`; one whose destination home holds no file
/// for the fixed id starts fresh with `session-absent`, its own cause, the
/// account unchanged. The stub refuses a resume of a session its home does
/// not hold, as the harness does, so a relaunch that resumed across
/// unshared accounts would fail here; one on the same account, or on an
/// account whose `projects` leads to the same store, resumes the bound
/// session.
#[test]
fn a_relaunch_resumes_where_its_account_holds_the_session_and_starts_fresh_elsewhere() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-resume");
    runner.init_fleet();
    let a = dir.path().join("a");
    let b = dir.path().join("b");
    plant_credential(&a);
    plant_credential(&b);
    let request = |account: &Path| {
        json!({
            "op": "launch-lane",
            "item": "KEN-R",
            "harness": "claude",
            "mail_root": runner.state_dir().display().to_string(),
            "account": account.display().to_string(),
            "model": "claude-fable-5-1",
            "effort": "high",
            "class": CLASS,
            "class_reason": CLASS_REASON,
        })
    };
    let first = effect_report(&runner.op_fleet(&request(&a)));
    assert_eq!(first["intent"]["outcome"], "confirmed", "{first}");
    assert_eq!(first["intent"]["observation"]["route"], "fresh");
    let bound = first["lane"]["session_id"]
        .as_str()
        .expect("the fixed session id is bound")
        .to_owned();
    effect_report(&runner.op_fleet(&terminal_close("KEN-R")));
    // Another account: fresh, never a resume the destination cannot honour.
    let switched = effect_report(&runner.op_fleet(&request(&b)));
    assert_eq!(switched["intent"]["outcome"], "confirmed", "{switched}");
    assert_eq!(switched["intent"]["observation"]["route"], "fresh");
    assert_eq!(
        switched["intent"]["observation"]["route_cause"],
        "account-switched"
    );
    let rebound = switched["lane"]["session_id"].as_str().unwrap().to_owned();
    assert_ne!(rebound, bound, "a fresh session, not the old id");
    effect_report(&runner.op_fleet(&terminal_close("KEN-R")));
    // The same account again, its file standing: the bound session resumes.
    let resumed = effect_report(&runner.op_fleet(&request(&b)));
    assert_eq!(resumed["intent"]["outcome"], "confirmed", "{resumed}");
    assert_eq!(resumed["intent"]["observation"]["route"], "resume");
    assert_eq!(resumed["lane"]["session_id"], rebound);
    effect_report(&runner.op_fleet(&terminal_close("KEN-R")));
    // The same account with the session file gone: fresh again.
    let slug: String = runner
        .state_dir()
        .display()
        .to_string()
        .chars()
        .map(|c| if c == '/' || c == '.' { '-' } else { c })
        .collect();
    std::fs::remove_file(
        b.join("projects")
            .join(&slug)
            .join(format!("{rebound}.jsonl")),
    )
    .unwrap();
    let missing = effect_report(&runner.op_fleet(&request(&b)));
    assert_eq!(missing["intent"]["outcome"], "confirmed", "{missing}");
    assert_eq!(missing["intent"]["observation"]["route"], "fresh");
    assert_eq!(
        missing["intent"]["observation"]["route_cause"],
        "session-absent"
    );
    let held = missing["lane"]["session_id"].as_str().unwrap().to_owned();
    effect_report(&runner.op_fleet(&terminal_close("KEN-R")));
    // Another account whose `projects` leads to `b`'s: the bound session
    // resumes there, on the new account. Its seat stands outside `/tmp`, as
    // an operator's does, since the confinement mounts a private `/tmp`
    // where a link under it would not stand.
    let seats = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let c = seats.path().join("c");
    plant_credential(&c);
    std::os::unix::fs::symlink(b.join("projects"), c.join("projects")).unwrap();
    let shared = effect_report(&runner.op_fleet(&request(&c)));
    assert_eq!(shared["intent"]["outcome"], "confirmed", "{shared}");
    assert_eq!(
        shared["intent"]["observation"]["route"], "resume",
        "{shared}"
    );
    assert_eq!(shared["lane"]["session_id"], held.as_str());
    assert_eq!(shared["lane"]["account"], c.display().to_string());
}

/// A reconcile never confirms from the parent identity alone. A close whose
/// last run recorded a validation stop that failed stays `unconfirmed` on
/// reconcile with the obligation kept, which the repeated close's stop
/// route runs again; a close whose lane records a live wake turn stays
/// `unconfirmed` with `wake: live`, and the repeated close stops the wake
/// before it confirms. A wake record with no identity is no handle.
#[test]
fn a_reconciled_close_never_confirms_over_an_owed_validation_stop_or_a_live_wake() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (command, run_dir) = validation_run(runner.state_dir());
    // The validation stop owed: the parent gone, no pane, the last outcome
    // recorded `validate: stop-failed`, a run of the worktree still going.
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-V",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": GONE_PID, "start": "ticks:1"}),
    )]);
    let mut owed = lane_intent("close-resources", "KEN-V", "unconfirmed", None);
    owed["observation"] = json!({"identity": "stopped", "validate": "stop-failed"});
    owed["close"] = json!({"ground": "terminal", "verdict": "completed", "source": "test"});
    fleet["intents"] = json!([owed]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["validate"], "stop-failed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert!(
        live(command.pid()) && !run_stopped(&run_dir),
        "a reconcile stops nothing itself"
    );
    // The repeated close runs the validation stop and confirms.
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-V")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert!(
        run_stopped(&run_dir) && !live(command.pid()),
        "the owed stop ended the run"
    );

    // The live wake: the parent gone, the wake a child this test holds.
    let wake = Owned::sleep();
    let mut fleet = runner.fleet();
    let mut rec = lane(
        "KEN-K",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": GONE_PID, "start": "ticks:1"}),
    );
    rec["wake"] = json!({"pid": wake.pid(), "start": wake.start()});
    fleet["lanes"] = json!([rec]);
    let mut open = lane_intent("close-resources", "KEN-K", "unconfirmed", None);
    open["close"] = json!({"ground": "terminal", "verdict": "completed", "source": "test"});
    fleet["intents"] = json!([open]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["wake"], "live");
    assert!(live(wake.pid()), "a reconcile signals nothing");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-K")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert!(!live(wake.pid()), "the repeated close stopped the wake");
    assert_eq!(closed["lane"]["status"], "done");

    // A wake with no identity is no handle: the reconcile confirms.
    let mut fleet = runner.fleet();
    let mut rec = lane(
        "KEN-N",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": GONE_PID, "start": "ticks:1"}),
    );
    rec["wake"] = json!({"pid": null, "start": null});
    fleet["lanes"] = json!([rec]);
    fleet["intents"] = json!([lane_intent("close-resources", "KEN-N", "unconfirmed", None)]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
}

// ---------------------------------------------------------------------------
// The receipted survivor, the same-key adoption and the replacement
// acquired before its stop.
// ---------------------------------------------------------------------------

/// A pane whose process ignores the hangup tmux sends on its close: `sleep`
/// exec'd with HUP ignored, its pid read once the exec has happened, so the
/// row holds the pid that survives the pane.
fn survivor(server: &Server, runner: &Runner) -> (String, u32) {
    let pane = server.open_window("KEN-M", runner.state_dir(), "trap '' HUP; exec sleep 600");
    let pid = server.pane_pid(&pane);
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|comm| comm.trim() != "sleep")
        .unwrap_or(true)
    {
        assert!(Instant::now() < deadline, "the pane never exec'd sleep");
        std::thread::sleep(Duration::from_millis(10));
    }
    (pane, pid)
}

/// End a process a row started and read it gone.
fn reap(pid: u32) {
    let _ = std::process::Command::new("kill")
        .args(["-9", &pid.to_string()])
        .status();
    let deadline = Instant::now() + Duration::from_secs(5);
    while live(pid) {
        assert!(Instant::now() < deadline, "{pid} never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The discharged rows of the intent's recorded set whose evidence word is
/// `by`, as `{kind, ...}` objects.
fn discharged_by(intent: &Value, by: &str) -> Vec<Value> {
    discharged_rows(&intent["obligations"], by)
}

/// The same rows of the intent's lane set.
fn lane_discharged_by(intent: &Value, by: &str) -> Vec<Value> {
    discharged_rows(&intent["lane_obligations"], by)
}

fn discharged_rows(set: &Value, by: &str) -> Vec<Value> {
    set["discharged"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter(|row| row["by"] == by)
                .map(|row| row["obligation"].clone())
                .collect()
        })
        .unwrap_or_default()
}

/// The server, not the pane, goes at `opening`, and the receipt names a pid
/// that survived it. The receipt is read before anything is discharged: its
/// pid is read live and stands, so the launch is held `unconfirmed` with
/// that pid, the receipt discharged by its read and its file kept.
#[test]
fn a_server_gone_at_opening_reads_the_receipt_before_any_discharge() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, pid);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(phase),
    ));
    let _ = tmux(&server.socket, &["kill-server"]);
    let deadline = Instant::now() + Duration::from_secs(5);
    while live(server.pid) {
        assert!(Instant::now() < deadline, "the server never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(live(pid), "the receipt's process survived its server");
    let report = runner.reconcile_one();
    let still = live(pid);
    let intent = runner.fleet()["intents"][0].clone();
    reap(pid);
    assert!(
        still,
        "the survivor still ran when the outcome was recorded"
    );
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "the receipt is owed until read, and its pid stands: {report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "pid")["pid"],
        pid,
        "{report}"
    );
    assert_eq!(
        discharged_by(&intent, "receipt-read"),
        vec![json!({"kind": "receipt"})],
        "the receipt is discharged by its read, not by the server's end: {intent}"
    );
    assert!(
        receipt_path(&runner, "launch-session:KEN-M:1-1").exists(),
        "the open intent keeps its receipt"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
}

/// The `window-opened` record as the launch writes it after the line is
/// typed, the receipt standing until read, the pane killed under a process
/// that survived it. The reconcile reads the receipt, reads its pid live
/// and holds the launch with that pid; nothing is failed over a live
/// process.
#[test]
fn a_window_opened_record_before_its_identity_reads_the_written_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, pid);
    let phase = phase("window-opened", &server, &pane, now_ms(), None);
    let mut fleet = lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(phase),
    );
    fleet["intents"][0]["obligations"] = json!({
        "standing": [
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "harness"},
            {"kind": "receipt", "role": "harness"},
        ],
        "discharged": [
            {"obligation": {"kind": "window", "server": server.pid, "server_start": server.start}, "by": "pane-recorded", "role": "harness"},
        ],
    });
    runner.write_fleet(&fleet);
    let killed = tmux(&server.socket, &["kill-pane", "-t", &pane]);
    assert!(killed.status.success());
    assert!(live(pid), "the process survived its pane");
    let report = runner.reconcile_one();
    let still = live(pid);
    let intent = runner.fleet()["intents"][0].clone();
    reap(pid);
    assert!(still);
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "the receipt's pid is owed: {report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "pid")["pid"],
        pid,
        "{report}"
    );
    assert_eq!(
        discharged_by(&intent, "receipt-read"),
        vec![json!({"kind": "receipt"})],
        "{intent}"
    );
    assert_eq!(discharged_by(&intent, "pane-gone").len(), 1, "{intent}");
}

/// The real launch, held at its first read after the `window-opened` write
/// by a tmux shim that blocks `capture-pane`, is killed there, as a crash
/// at the first wait. The pane is then killed under a harness that ignores
/// the hangup. The reconcile reads the receipt the launch left standing,
/// reads its pid live, and holds the launch with that pid: the record said
/// nothing the launch had not read. The shim holds the launch's first
/// pane-field read until the pane's process is the stub, so the foreground
/// read before the held capture sees the harness whatever the stub's start
/// took, and the record at the capture barrier is judged, not the stub's
/// startup. The lane is a Copilot CLI lane's, whose harness runs
/// unconfined and can outlive its pane.
#[test]
fn a_crash_at_the_first_wait_after_the_window_opened_write_reads_the_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-survivor");
    runner.verify = Some(2);
    runner.init_fleet();
    let fifo = runner.state_dir().join("hold.fifo");
    mkfifo(&fifo);
    let mark = runner.state_dir().join("hold.mark");
    let opened = runner.state_dir().join("hold.opened");
    let real = which_tmux();
    let fifo_s = fifo.display().to_string();
    let mark_s = mark.display().to_string();
    let opened_s = opened.display().to_string();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    runner.tools = Some(tools.clone());
    let (request, env) = copilot_survivor(dir.path(), &runner, &tools, "KEN-C");
    let mut held: Vec<(&str, &str)> = env.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect();
    held.extend([
        ("TMUX_REAL", real.as_str()),
        ("TMUX_HOLD_FIFO", fifo_s.as_str()),
        ("TMUX_HOLD_MARK", mark_s.as_str()),
        ("TMUX_HOLD_VERB", "capture-pane"),
        ("TMUX_HOLD_OPENED", opened_s.as_str()),
        ("TMUX_HOLD_READY_COMM", "copilot"),
    ]);
    let mut child = runner.spawn_op_fleet(&request, &held, &fixtures().join("tmux-hold"));
    wait_for_phase(&runner, "launch-session:", "window-opened");
    // The launch is at its first wait: the shim holds its first capture.
    let deadline = Instant::now() + Duration::from_secs(10);
    while !mark.exists() {
        assert!(
            Instant::now() < deadline,
            "the launch never reached its first wait"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The record at the first wait: the pane standing with the receipt, nothing
    // discharged that was not read.
    let held = runner.fleet()["intents"][0].clone();
    let standing = held["obligations"]["standing"].as_array().unwrap().clone();
    assert!(
        standing.iter().any(|o| o["kind"] == "receipt"),
        "the receipt stands until read: {held}"
    );
    assert!(standing.iter().any(|o| o["kind"] == "pane"), "{held}");
    // The foreground identity is acquired through the writing reader and so is
    // recorded before the capture the shim holds: a run killed at its capture
    // has already written what it read.
    assert!(
        standing.iter().any(|o| o["kind"] == "process"),
        "the foreground identity is recorded before the capture barrier: {held}"
    );
    assert!(
        discharged_by(&held, "receipt-read").is_empty(),
        "nothing read the receipt yet: {held}"
    );
    let pane = held["phase"]["pane"].as_str().unwrap().to_owned();
    // The crash: the launch process is killed at its wait, and the held
    // shim released so it exits too.
    child.kill().unwrap();
    child.wait().unwrap();
    release_hold(&fifo, Duration::from_secs(10), || {
        runner.fleet().to_string()
    });
    let pid = server.pane_pid(&pane);
    // The barrier held the first pane-field read until the stub held the
    // pane, so it holds it still when the pane is killed under it.
    assert_eq!(
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .map(|comm| comm.trim().to_owned())
            .unwrap_or_default(),
        "copilot",
        "the launch read the pane only once the stub held it"
    );
    let killed = tmux(&server.socket, &["kill-pane", "-t", &pane]);
    assert!(killed.status.success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while server.panes().contains(&pane) {
        assert!(Instant::now() < deadline, "the pane never closed");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(live(pid), "the stub survived its pane");
    let report = runner.reconcile_one();
    let still = live(pid);
    let intent = runner.fleet()["intents"][0].clone();
    reap(pid);
    assert!(still, "the survivor ran when the outcome was recorded");
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        remaining(&report["intent"]["observation"], "process")["pid"],
        pid,
        "the foreground identity, recorded before the capture and read live, is what remains: {report}"
    );
    assert_eq!(
        discharged_by(&intent, "receipt-read"),
        vec![json!({"kind": "receipt"})],
        "{intent}"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
}

/// The receipt names the pane the opening recorded, so the adoption's key
/// equals the recorded one. The recorded pane keeps standing through the
/// adoption and passes to the lane record at publication; it is never
/// discharged `adopted`.
#[test]
fn an_adoption_keeps_the_recorded_pane_standing_under_its_own_key() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(2);
    runner.init_fleet();
    let pane = server.open_stub(
        "KEN-M",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, pid);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    let mut fleet = lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(phase),
    );
    fleet["intents"][0]["obligations"] = json!({
        "standing": [
            {"kind": "receipt", "role": "harness"},
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "harness"},
        ],
        "discharged": [],
    });
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["launch"]["pane"], pane);
    let intent = runner.fleet()["intents"][0].clone();
    assert!(
        discharged_by(&intent, "adopted").is_empty(),
        "the same-key pane is never discharged as adopted: {intent}"
    );
    assert_eq!(
        discharged_by(&intent, "published")
            .iter()
            .filter(|o| o["kind"] == "pane")
            .count(),
        1,
        "the recorded pane passed to the lane record at publication: {intent}"
    );
    assert!(server.panes().contains(&pane), "the pane stands");
}

/// The dead-receipt row with the pane the opening recorded, as
/// `open_window` writes it before the line is typed, and the pane's close
/// refused by the host. The adoption keeps that pane standing, so a refused
/// close settles nothing: the launch is held, the pane stands, and the next
/// reconcile closes it.
#[test]
fn a_dead_receipts_refused_close_holds_when_the_opening_recorded_its_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env = vec![
        ("TMUX_REAL".to_owned(), which_tmux()),
        ("TMUX_FAIL_VERB".to_owned(), "kill-pane".to_owned()),
    ];
    runner.init_fleet();
    let pane = server.open_stub(
        "KEN-M",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, GONE_PID as u32);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    let mut fleet = lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(phase),
    );
    fleet["intents"][0]["obligations"] = json!({
        "standing": [
            {"kind": "receipt", "role": "harness"},
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "harness"},
        ],
        "discharged": [],
    });
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "a refused close settles nothing: {report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "pane")["pane"],
        pane
    );
    assert!(server.panes().contains(&pane), "the pane stands");
    runner.tools = None;
    runner.env.clear();
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "failed", "{again}");
    assert!(
        !server.panes().contains(&pane),
        "the host answering, the pane is closed"
    );
}

/// The replacement foreground read in the recorded pane on a close whose
/// recorded identity is gone is written as an obligation before the stop
/// that follows, on the first run and on a signalled retry alike. A `kill`
/// that holds the first signal lets the row read the record at the stop's
/// wait: the replacement stands and `signalled` is recorded.
#[test]
fn a_replacement_foreground_is_recorded_before_the_stop_that_follows_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_stub(
        "KEN-H",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let foreground = server.pane_pid(&pane);
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-H",
        "running",
        &runner,
        json!({"pane": pane, "server": server.pid, "pid": GONE_PID, "start": "ticks:1"}),
    )]);
    runner.write_fleet(&fleet);
    let log = runner.state_dir().join("kill.log");
    let fifo = runner.state_dir().join("kill.fifo");
    mkfifo(&fifo);
    let log_s = log.display().to_string();
    let fifo_s = fifo.display().to_string();
    runner
        .env
        .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
    let child = runner.spawn_op_fleet(
        &terminal_close("KEN-H"),
        &[
            ("KILL_HOLD_LOG", log_s.as_str()),
            ("KILL_HOLD_FIFO", fifo_s.as_str()),
            ("ORCH_LANE_CLOSE_SECS", "1"),
        ],
        &fixtures().join("kill-hold"),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while std::fs::read_to_string(&log)
        .map(|t| t.is_empty())
        .unwrap_or(true)
    {
        assert!(Instant::now() < deadline, "the stop never signalled");
        std::thread::sleep(Duration::from_millis(20));
    }
    // At the stop's wait, with its first signal acknowledged: the
    // replacement identity stands in the record and the signal is recorded.
    let held = runner.fleet()["intents"][0].clone();
    assert_eq!(held["obligations"]["signalled"], true, "{held}");
    assert!(
        held["obligations"]["standing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["kind"] == "process" && o["pid"] == foreground),
        "the replacement foreground is written before its stop: {held}"
    );
    release_hold(&fifo, Duration::from_secs(10), || {
        runner.fleet().to_string()
    });
    let out = child.wait_with_output().unwrap();
    let first = effect_report(&out);
    assert_eq!(first["intent"]["outcome"], "unconfirmed", "{first}");
    assert_eq!(first["intent"]["observation"]["timeout_pid"], foreground);
    assert!(live(foreground), "the held kill signalled nothing");
    // The signalled retry: the same replacement, already recorded, stands
    // through another held stop; nothing is lost and nothing refuses.
    runner.tools = Some(fixtures().join("kill-noop"));
    let again = effect_report(&runner.op_fleet(&terminal_close("KEN-H")));
    assert_eq!(again["intent"]["outcome"], "unconfirmed", "{again}");
    let retried = runner.fleet()["intents"][0].clone();
    assert_eq!(retried["obligations"]["signalled"], true);
    assert!(
        retried["obligations"]["standing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["kind"] == "process" && o["pid"] == foreground),
        "{retried}"
    );
    // The host's own kill: the close completes.
    runner.tools = None;
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-H")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert!(!live(foreground));
}

/// A receipted survivor stands on the reconcile that reads it live, and the
/// next reconcile, reading its own recorded pid gone, settles the launch.
/// The pid is read by its own key on every route, not only the phase's
/// identity.
#[test]
fn a_receipted_survivor_read_gone_on_a_later_reconcile_settles_the_launch() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-session:KEN-M:1-1", &pane, pid);
    let mut fleet = lane_fleet(
        &runner,
        "launch-session",
        "preparing",
        Value::Null,
        Some(phase("window-opened", &server, &pane, now_ms(), None)),
    );
    fleet["intents"][0]["obligations"] = json!({
        "standing": [
            {"kind": "receipt", "role": "harness"},
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "harness"},
        ],
        "discharged": [],
    });
    runner.write_fleet(&fleet);
    assert!(
        tmux(&server.socket, &["kill-pane", "-t", &pane])
            .status
            .success()
    );
    let first = runner.reconcile_one();
    assert_eq!(
        first["intent"]["outcome"], "unconfirmed",
        "the receipted survivor stands: {first}"
    );
    reap(pid);
    let second = runner.reconcile_one();
    assert_eq!(
        second["intent"]["outcome"], "failed",
        "the acquired pid read gone settles the launch: {second}"
    );
}

/// A lane whose recorded server start differs from the ambient server's is
/// a reused pid, not this lane's server; the close reads the pane gone with
/// it and kills nothing live.
#[test]
fn a_lane_close_leaves_a_pane_on_a_different_server_identity() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_idle("KEN-V", runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-V",
        "running",
        &runner,
        json!({
            "pane": pane,
            "server": server.pid,
            "server_start": server.start - 1,
            "pid": null,
            "start": null,
        }),
    )]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-V")));
    assert!(
        server.panes().contains(&pane),
        "the pane on a different server start was killed: {report}"
    );
}

/// An unreadable worktree root is no proof of absence, so the validation
/// stop stays owed and the close holds, never confirming over runs it could
/// not read.
#[test]
fn a_close_whose_validation_root_is_unreadable_holds_the_validation_owed() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let parent = runner.state_dir().join("locked");
    let root = parent.join("worktree");
    std::fs::create_dir_all(&root).unwrap();
    let mut fleet = runner.fleet();
    let mut row = lane("KEN-V", "running", &runner, Value::Null);
    row["mail_root"] = json!(root.display().to_string());
    fleet["lanes"] = json!([row]);
    runner.write_fleet(&fleet);
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o000)).unwrap();
    let unread = std::fs::metadata(&root).is_err();
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-V")));
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(unread, "the probe's parent is unreadable");
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "an unreadable worktree holds the validation owed: {report}"
    );
    assert_eq!(
        report["intent"]["observation"]["validate"], "stop-failed",
        "{report}"
    );
}

/// A Copilot CLI lane's launch world for a row whose harness must outlive
/// its killed pane: only an unconfined harness can, since a confined one
/// ends with its wrapper. The account with its lane-mail hooks, hooks
/// switched off by no layer, a hangup-ignoring stub named `copilot`, the
/// checkout's origin; the environment the launch runs under.
fn copilot_survivor(
    dir: &Path,
    runner: &Runner,
    tools: &Path,
    item: &str,
) -> (Value, Vec<(String, String)>) {
    let account = dir.join("copilot-account");
    plant_copilot_hooks(&account.join("hooks"));
    plant_hooks_off(tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
    let bin = dir.join("copilot-bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_executable(
        &bin.join("copilot"),
        std::fs::read_to_string(stub("stub-survivor")).unwrap(),
    );
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    fleet_origin(&[runner.state_dir()]);
    let mut request = launch_request(item, runner.state_dir());
    request["harness"] = json!("copilot");
    request["account"] = json!(account.display().to_string());
    let env = vec![
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("copilot={}", bin.join("copilot").display()),
        ),
        ("HOME".to_owned(), home.display().to_string()),
    ];
    (request, env)
}

/// A `send_line` reply reported failed may have run the line, which writes
/// the receipt and execs the harness. The pane is closed and the receipt
/// read, not assumed absent, so a live registered pid stands and the launch
/// holds rather than settling `failed` over a running harness.
/// A Copilot CLI lane's, whose harness runs unconfined and can outlive its
/// pane.
#[test]
fn a_send_reply_reported_failed_that_ran_the_line_reads_the_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-survivor");
    runner.verify = Some(1);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let copy = runner.state_dir().join("receipt-copy");
    let shim = tools.join("tmux");
    write_executable(
        &shim,
        format!(
            "#!/bin/bash\nsk=; en=; kp=\nfor a in \"$@\"; do\n  [ \"$a\" = send-keys ] && sk=1\n  [ \"$a\" = Enter ] && en=1\n  [ \"$a\" = kill-pane ] && kp=1\ndone\nif [ -n \"$sk\" ] && [ -n \"$en\" ]; then {real} \"$@\"; echo 'tmux: timed out' >&2; exit 1; fi\nif [ -n \"$kp\" ]; then sleep 2; cat {state}/intents/*.pane > {copy} 2>/dev/null; fi\nexec {real} \"$@\"\n",
            real = which_tmux(),
            state = runner.state_dir().display(),
            copy = copy.display(),
        ),
    );
    runner.tools = Some(tools.clone());
    let (request, env) = copilot_survivor(dir.path(), &runner, &tools, "KEN-N");
    let env: Vec<(&str, &str)> = env.iter().map(|(n, v)| (n.as_str(), v.as_str())).collect();
    let report = effect_report(&runner.op_fleet_env(&request, &env));
    let receipt: Value =
        serde_json::from_str(&std::fs::read_to_string(&copy).unwrap_or_else(|_| "null".to_owned()))
            .unwrap_or(Value::Null);
    let pid = receipt["pid"].as_u64().map(|p| p as u32);
    let survivor = pid.is_some_and(live);
    if let Some(pid) = pid {
        reap(pid);
    }
    assert!(
        !(report["intent"]["outcome"] == "failed" && survivor),
        "a terminal failure over a receipted live process: {report}"
    );
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "the receipt is read and its live pid stands: {report}"
    );
}

/// A wake the lane's writer replaced is no longer named by the lane, but
/// the close intent recorded it. The repeated close stops the recorded wake
/// as well as the lane's current one, and confirms only once both are gone.
#[test]
fn a_close_stops_a_recorded_wake_the_lane_no_longer_names() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let old_wake = Owned::sleep();
    let new_wake = Owned::sleep();
    let mut fleet = runner.fleet();
    let mut row = lane("KEN-W", "running", &runner, Value::Null);
    row["wake"] = json!({"pid": old_wake.pid(), "start": old_wake.start()});
    fleet["lanes"] = json!([row]);
    // The close intent's set already recorded the first wake (its bootstrap at
    // a first run), and nothing else; the close itself never ran.
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-W:1-1", "op": "close-resources", "target": "KEN-W", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "auxiliary"},
        ], "discharged": [], "signalled": true},
        "lane_obligations": {"standing": [{"kind": "validation"}]},
    }]);
    // The lane's writer replaced the wake since.
    fleet["lanes"][0]["wake"] = json!({"pid": new_wake.pid(), "start": new_wake.start()});
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-W")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(!live(new_wake.pid()), "the lane's current wake was stopped");
    assert!(
        !live(old_wake.pid()),
        "the recorded wake the lane no longer names was stopped too: {report}"
    );
}

/// A replacement foreground the close acquired whose pane is since gone is
/// read by its own key on the next reconcile, not through the lane's launch
/// identity: live it holds the close, gone it settles.
#[test]
fn a_replacement_foreground_whose_pane_is_gone_is_read_by_its_own_key() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let foreground = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-F", "running", &runner, Value::Null)]);
    // The close recorded the replacement foreground it read in the pane; the
    // pane is gone since and the lane names no launch identity.
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-F:1-1", "op": "close-resources", "target": "KEN-F", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "stop": "pane-foreground"},
        "obligations": {"standing": [
            {"kind": "process", "pid": foreground.pid(), "start": foreground.start(), "role": "harness"},
        ], "discharged": [], "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
    }]);
    runner.write_fleet(&fleet);
    let held = runner.reconcile_one();
    assert_eq!(
        held["intent"]["outcome"], "unconfirmed",
        "the live foreground holds: {held}"
    );
    assert_eq!(
        remaining(&held["intent"]["observation"], "process")["pid"],
        foreground.pid()
    );
    reap(foreground.pid());
    let settled = runner.reconcile_one();
    assert_eq!(
        settled["intent"]["outcome"], "confirmed",
        "the foreground read gone by its own key settles the close: {settled}"
    );
}

// ---------------------------------------------------------------------------
// The moved lane. A close acts only on its own recorded set, never the
// session a relaunch moved the lane under.
// ---------------------------------------------------------------------------

/// The store judges a moved lane by the intent's recorded keys, never the
/// stamp alone. The same moved lane under a later `session_since` and under
/// the close's own (the released launcher writes whole seconds, so a
/// relaunch can carry the intent's stamp with new launch keys), read by the
/// reconcile alone after the recorded wake ended: the close's recorded set
/// is all discharged, so the reconcile settles by that set, closes
/// `intent-stale`, never holds `stop: pending` on the new session's live
/// harness, and the new lane stays `running` with its replacement launch.
#[test]
fn a_moved_lane_close_settles_by_its_recorded_set() {
    for (session_since, stamp) in [
        ("2026-01-29T16:00:00Z", "a later stamp"),
        ("2026-01-29T15:20:00Z", "the close's own stamp"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let old_wake = Owned::sleep();
        let new_harness = Owned::sleep();
        let new_pane = server.open_idle("KEN-M", runner.state_dir());
        let mut fleet = runner.fleet();
        let mut row = lane(
            "KEN-M",
            "running",
            &runner,
            json!({
                "pane": new_pane, "server": server.pid, "server_start": server.start,
                "pid": new_harness.pid(), "start": new_harness.start(),
            }),
        );
        row["session_since"] = json!(session_since);
        fleet["lanes"] = json!([row]);
        fleet["intents"] = json!([{
            "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "stopped", "wake": "live", "cause": "wake-timeout"},
            "obligations": {"standing": [
                {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "auxiliary"},
            ], "discharged": [],
            "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
        }]);
        runner.write_fleet(&fleet);
        let old_pid = old_wake.pid();
        reap(old_pid);
        let report = runner.reconcile_one();
        assert_ne!(
            report["intent"]["observation"]["stop"], "pending",
            "{stamp}: the reconcile held the old close on the new session's live harness: {report}"
        );
        assert_eq!(
            report["intent"]["outcome"], "confirmed",
            "{stamp}: the recorded set is gone, so the moved close settles for its own set: {report}"
        );
        assert_eq!(
            report["intent"]["reconciled"], "intent-stale",
            "{stamp}: the store judged the lane moved by its keys: {report}"
        );
        assert!(
            live(new_harness.pid()),
            "{stamp}: the new session's harness stands"
        );
        let after = runner.fleet();
        assert_eq!(
            after["lanes"][0]["status"], "running",
            "{stamp}: the new lane is live and outside the close set: {report}"
        );
        assert_eq!(
            after["lanes"][0]["launch"]["pid"],
            new_harness.pid(),
            "{stamp}: the lane keeps its replacement launch"
        );
    }
}

/// A running lane whose harness is `harness`, an open, signalled close of
/// it holding that harness, and a closed transfer owing its notice.
fn held_close_with_an_owed_notice(runner: &Runner, harness: &Owned) {
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-M",
        "running",
        runner,
        json!({"pid": harness.pid(), "start": harness.start()}),
    );
    row["session_since"] = json!("2026-01-29T15:20:00Z");
    let owed = "orch-runtime: job-launch-failed op=request-transfer intent=request-transfer:overseer:3:1-1 outcome=failed";
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([
        {
            "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "live", "timeout_pid": harness.pid()},
            "obligations": {"standing": [
                {"kind": "process", "pid": harness.pid(), "start": harness.start(), "role": "harness", "harness": "claude"},
            ], "discharged": [],
            "signalled": true, "revision": 2}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
        },
        {
            "id": "request-transfer:overseer:3:1-1", "op": "request-transfer", "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z",
            "completed_at": "2026-01-29T15:21:00Z", "outcome": "failed",
            "observation": {"retired": false, "note": "job-launch-failed"},
            "notice": {"key": "job-launch-failed", "text": owed, "owner": "owed"},
            "obligations": {"standing": [], "discharged": [], "revision": 1}
        }
    ]);
    runner.write_fleet(&fleet);
}

/// A reconcile with two open intents, one of a close whose lane row is
/// gone, reconciles the other and reports the refused one by its cause,
/// `lane-missing`, under `refused`; the verb succeeds and the refused
/// intent stands as it was for the next reconcile.
#[test]
fn a_reconcile_reports_a_refused_intent_and_reconciles_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let harness = Owned::sleep();
    held_close_with_an_owed_notice(&runner, &harness);
    let mut fleet = runner.fleet();
    let gone = json!({
        "id": "close-resources:KEN-GONE:1-1", "op": "close-resources",
        "target": "KEN-GONE", "created_at": "2026-01-29T15:20:00Z",
        "outcome": "unconfirmed", "lane_since": "2026-01-29T15:20:00Z",
        "obligations": {"standing": [], "discharged": [], "signalled": false, "revision": 1}
    });
    fleet["intents"]
        .as_array_mut()
        .unwrap()
        .insert(0, gone.clone());
    runner.write_fleet(&fleet);
    let out = runner.run(&["reconcile", "--fleet"]);
    let answer = reply(&out);
    assert!(
        answer["ok"].as_bool().unwrap_or(false),
        "one refused intent never fails the verb: {}",
        stderr(&out)
    );
    let refused = answer["result"]["refused"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert_eq!(refused.len(), 1, "{answer}");
    assert_eq!(refused[0]["intent"], "close-resources:KEN-GONE:1-1");
    assert_eq!(refused[0]["refusal"], "lane-missing", "{answer}");
    let reconciled = answer["result"]["reconciled"].as_array().unwrap();
    assert_eq!(reconciled.len(), 1, "the other intent reconciled: {answer}");
    assert_eq!(
        reconciled[0]["report"]["intent"]["id"],
        "close-resources:KEN-M:1-1"
    );
    let after = runner.fleet();
    assert_eq!(
        after["intents"][0], gone,
        "the refused intent stands as it was"
    );
    assert!(live(harness.pid()));
}

/// A moved lane whose close never signalled: before any signal the close
/// refuses `lane-moved` with no effect, the new session untouched.
#[test]
fn a_moved_lane_close_before_any_signal_refuses_with_no_effect() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let new_harness = Owned::sleep();
    let new_pane = server.open_idle("KEN-M", runner.state_dir());
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-M",
        "running",
        &runner,
        json!({
            "pane": new_pane, "server": server.pid, "server_start": server.start,
            "pid": new_harness.pid(), "start": new_harness.start(),
        }),
    );
    row["session_since"] = json!("2026-01-29T16:00:00Z");
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started",
        "lane_since": "2026-01-29T15:20:00Z",
        "obligations": {"standing": [], "discharged": [], "signalled": false},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"], "lane-moved",
        "{report}"
    );
    assert!(
        live(new_harness.pid()),
        "nothing of the new session was signalled"
    );
    assert!(server.panes().contains(&new_pane), "the new window stands");
}

/// A moved lane's signalled close retries on its own recorded set. The
/// repeated close and the reconcile leave the new session's harness and
/// window untouched and stop the earlier recorded wake by its own token, so
/// the intent settles instead of standing read-only for good.
#[test]
fn a_moved_lanes_old_live_wake_is_stopped_by_its_own_set_on_the_retry() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let old_wake = Owned::sleep();
    let new_harness = Owned::sleep();
    let new_pane = server.open_idle("KEN-M", runner.state_dir());
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-M",
        "running",
        &runner,
        json!({
            "pane": new_pane, "server": server.pid, "server_start": server.start,
            "pid": new_harness.pid(), "start": new_harness.start(),
        }),
    );
    row["session_since"] = json!("2026-01-29T16:00:00Z");
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "auxiliary"},
        ], "discharged": [],
        "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_ne!(
        report["intent"]["observation"]["stop"], "pending",
        "the moved close holds no stop on the new session: {report}"
    );
    assert!(
        live(new_harness.pid()),
        "the new session's harness was stopped: {report}"
    );
    assert!(
        server.panes().contains(&new_pane),
        "the new session's window was closed: {report}"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert!(
        !live(old_wake.pid()),
        "the old recorded wake is stopped by the retry on the intent's own set: {report}"
    );
    assert_eq!(
        report["intent"]["outcome"], "confirmed",
        "the old set settles once its wake is stopped: {report}"
    );
    assert_eq!(report["intent"]["reconciled"], "intent-stale", "{report}");
    assert!(
        discharged_by(&report["intent"], "stopped")
            .iter()
            .any(|o| o["pid"] == old_wake.pid()),
        "stopped by its own token: {report}"
    );
}

/// A signalled close owing its validation stop under a lane that moved
/// releases that obligation `lane-moved`, since the worktree's runs belong
/// to the session that now holds the lane; the close settles, the new
/// session untouched, the lane left as found.
#[test]
fn a_moved_close_owing_its_validation_releases_it_lane_moved() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let new_harness = Owned::sleep();
    let new_pane = server.open_idle("KEN-M", runner.state_dir());
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-M",
        "running",
        &runner,
        json!({
            "pane": new_pane, "server": server.pid, "server_start": server.start,
            "pid": new_harness.pid(), "start": new_harness.start(),
        }),
    );
    row["session_since"] = json!("2026-01-29T16:00:00Z");
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "validate": "stop-failed", "cause": "runner-refused"},
        "obligations": {"standing": [], "discharged": [], "signalled": true},
        "lane_obligations": {"standing": [{"kind": "validation"}]},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        lane_discharged_by(&report["intent"], "lane-moved")
            .iter()
            .any(|o| o["kind"] == "validation"),
        "the owed validation is released to the session holding the lane: {report}"
    );
    assert_eq!(report["intent"]["reconciled"], "intent-stale", "{report}");
    assert!(live(new_harness.pid()), "the new session stands");
    assert!(server.panes().contains(&new_pane), "the new window stands");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
}

/// A signalled close holding its own recorded harness (a stop that read
/// unreadable after its signal) under a lane that moved signals that
/// harness again through its own token on the repeat; the new session is
/// never named.
#[test]
fn a_moved_close_stops_its_own_recorded_harness_by_token_on_the_repeat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let old_harness = Owned::sleep();
    let new_harness = Owned::sleep();
    let new_pane = server.open_idle("KEN-M", runner.state_dir());
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-M",
        "running",
        &runner,
        json!({
            "pane": new_pane, "server": server.pid, "server_start": server.start,
            "pid": new_harness.pid(), "start": new_harness.start(),
        }),
    );
    row["session_since"] = json!("2026-01-29T16:00:00Z");
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "unreadable", "pid": old_harness.pid(), "cause": "ps-failed"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_harness.pid(), "start": old_harness.start(), "role": "harness"},
        ], "discharged": [],
        "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert!(live(new_harness.pid()), "the new session stands: {report}");
    assert!(server.panes().contains(&new_pane), "the new window stands");
    assert!(
        !live(old_harness.pid()),
        "the close's own recorded harness is signalled again by its token: {report}"
    );
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        discharged_by(&report["intent"], "stopped")
            .iter()
            .any(|o| o["pid"] == old_harness.pid()),
        "{report}"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
}

/// A held close whose lane the released launcher relaunched with another
/// harness stops its own recorded root by token and the root's descendants
/// named by the harness kind the set recorded at its bootstrap, never by
/// the relaunched session's harness. The recorded root is a bash holding a
/// child named `claude`; the lane now says `codex`. Both are stopped,
/// nothing of the new session is. A set that recorded no kind (the control)
/// stops the root alone and leaves the descendant, never signalling by the
/// new session's name.
#[test]
fn a_moved_close_stops_the_old_roots_descendants_by_the_recorded_harness() {
    for (recorded_kind, descendant_after) in [(Some("claude"), "gone"), (None, "alive")] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        // The recorded root: a bash whose child is a sleeper named `claude`,
        // so the kernel names it as the recorded harness's own process.
        let claude = named_sleep(dir.path(), "claude");
        let pidfile = dir.path().join("descendant");
        let mut root = std::process::Command::new("bash")
            .arg("-c")
            .arg("\"$0\" 30 & echo $! > \"$1\"; wait")
            .arg(&claude)
            .arg(&pidfile)
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let descendant: u32 = loop {
            if let Ok(text) = std::fs::read_to_string(&pidfile)
                && let Ok(pid) = text.trim().parse()
            {
                break pid;
            }
            assert!(
                Instant::now() < deadline,
                "the descendant never wrote its pid"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        let root_pid = root.id();
        let root_start = start_of(root_pid);
        let new_harness = Owned::sleep();
        let new_pane = server.open_idle("KEN-M", runner.state_dir());
        let mut fleet = runner.fleet();
        let mut row = lane(
            "KEN-M",
            "running",
            &runner,
            json!({
                "pane": new_pane, "server": server.pid, "server_start": server.start,
                "pid": new_harness.pid(), "start": new_harness.start(),
            }),
        );
        row["harness"] = json!("codex");
        row["session_since"] = json!("2026-01-29T16:00:00Z");
        fleet["lanes"] = json!([row]);
        let mut held =
            json!({"kind": "process", "pid": root_pid, "start": root_start, "role": "harness"});
        if let Some(kind) = recorded_kind {
            held["harness"] = json!(kind);
        }
        fleet["intents"] = json!([{
            "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "unreadable", "pid": root_pid, "cause": "ps-failed"},
            "obligations": {"standing": [held],
                "discharged": [],
                "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
        }]);
        runner.write_fleet(&fleet);
        let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
        let _ = root.wait();
        let settled = Instant::now() + Duration::from_secs(5);
        while live(descendant) && descendant_after == "gone" && Instant::now() < settled {
            std::thread::sleep(Duration::from_millis(20));
        }
        let descendant_state = if live(descendant) { "alive" } else { "gone" };
        if live(descendant) {
            let _ = std::process::Command::new("kill")
                .args(["-KILL", &descendant.to_string()])
                .status();
        }
        assert!(live(new_harness.pid()), "the new session stands: {report}");
        assert!(server.panes().contains(&new_pane), "the new window stands");
        assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
        assert!(
            discharged_by(&report["intent"], "stopped")
                .iter()
                .any(|o| o["pid"] == root_pid),
            "the recorded root is stopped by its token: {report}"
        );
        assert_eq!(
            descendant_state, descendant_after,
            "recorded kind {recorded_kind:?}: the root's own descendant named by the recorded harness: {report}"
        );
        assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    }
}

/// One repeated close request, its reconcile and the stop it reruns,
/// records one stale reading of a reused pid, never two; the next request's
/// reading is the second, which settles the identity, the reused pid never
/// signalled.
#[test]
fn one_repeated_close_request_counts_one_stale_reading() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let held = Owned::sleep();
    let mut fleet = lane_fleet(&runner, "close-resources", "running", Value::Null, None);
    fleet["intents"][0]["outcome"] = json!("unconfirmed");
    fleet["intents"][0]["obligations"] = json!({
        "standing": [{"kind": "process", "pid": held.pid(), "start": "ticks:0", "role": "harness"}],
        "discharged": [],
        "signalled": true,
    });
    fleet["intents"][0]["lane_obligations"] = json!({
        "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}],
    });
    runner.write_fleet(&fleet);
    let key = format!("{}:ticks:0", held.pid());
    let once = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(once["intent"]["outcome"], "unconfirmed", "{once}");
    assert_eq!(
        runner.fleet()["intents"][0]["obligations"]["stale"][&key],
        1,
        "one request, one reading: {once}"
    );
    assert!(live(held.pid()), "the reused pid was never signalled");
    let again = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
    assert_eq!(
        discharged_by(&again["intent"], "stale-readings:2").len(),
        1,
        "the next request's reading settles it: {again}"
    );
    assert!(live(held.pid()), "the reused pid was never signalled");
}

/// A wake the lane's writer replaced with none still has a stop route. A
/// held, signalled close owing an owned live wake, the lane naming no wake
/// now, stops the recorded wake on the repeated close by sweeping the set,
/// not the lane's current wake.
#[test]
fn a_recorded_wake_the_lane_no_longer_names_at_all_is_still_stopped() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let wake = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-M", "running", &runner, Value::Null)]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": wake.pid(), "start": wake.start(), "role": "auxiliary"},
        ], "discharged": [],
        "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        !live(wake.pid()),
        "the recorded wake the lane no longer names was stopped: {report}"
    );
}

/// A recorded secondary identity whose pid another process now holds is
/// counted stale per recorded key on each reconcile and settles on the
/// second independent reading, with no signal to the reused pid.
#[test]
fn a_stale_secondary_identity_settles_on_the_second_independent_reading() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let held = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-M", "running", &runner, Value::Null)]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-M:1-1", "op": "close-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "stop": "pane-foreground"},
        "obligations": {"standing": [
            {"kind": "process", "pid": held.pid(), "start": "ticks:0", "role": "harness"},
        ], "discharged": [],
        "signalled": true}, "lane_obligations": {"discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped"}]},
    }]);
    runner.write_fleet(&fleet);
    let first = runner.reconcile_one();
    assert_eq!(
        first["intent"]["outcome"], "unconfirmed",
        "one reading holds: {first}"
    );
    let second = runner.reconcile_one();
    assert_eq!(
        second["intent"]["outcome"], "confirmed",
        "the second independent stale reading settles the identity: {second}"
    );
    assert_eq!(
        discharged_by(&second["intent"], "stale-readings:2").len(),
        1,
        "settled by its stale count: {second}"
    );
    assert!(live(held.pid()), "the reused pid was never signalled");
}

/// `git args` in `cwd`, which must succeed; its stdout.
fn git(cwd: &Path, args: &[&str]) -> String {
    let out = program("git")
        .current_dir(cwd)
        .args(args)
        .output()
        .expect("git");
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        cwd.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// The repository under `dir` every worktree row plants a linked worktree
/// in. `tmp/` is ignored, as this repository ignores it, so a lane mailbox
/// under it is invisible to `git status`. The repository is its own
/// `origin` with `origin/HEAD` on `main`: the worktree package's `remove`
/// reads that for its branch-deletion proof and refuses before anything is
/// removed where no default branch can be named.
fn repository_fixture(dir: &Path) -> PathBuf {
    let repo = dir.join("repo");
    git(dir, &["init", "-q", "-b", "main", "repo"]);
    std::fs::write(repo.join(".gitignore"), "tmp/\n").unwrap();
    git(&repo, &["add", ".gitignore"]);
    git(
        &repo,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "-m",
            "init",
        ],
    );
    let repo_s = repo.display().to_string();
    git(&repo, &["remote", "add", "origin", &repo_s]);
    git(&repo, &["fetch", "-q", "origin"]);
    git(&repo, &["remote", "set-head", "origin", "main"]);
    repo
}

/// A repository under `dir` with one checked-out linked worktree on branch
/// `lane` at the same commit as `main`: (repository, worktree). The fixture
/// every worktree row plants and then varies. The linked worktree is
/// registered in the repository's `git worktree list`, which the package
/// reads from the main worktree the runtime runs it in; an unregistered
/// target it refuses.
fn worktree_fixture(dir: &Path) -> (PathBuf, PathBuf) {
    let repo = repository_fixture(dir);
    let wt = dir.join("wt");
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            &wt.display().to_string(),
            "-b",
            "lane",
        ],
    );
    (repo, wt)
}

/// A repository under `dir` with one linked worktree on branch `lane` as
/// the shipped cloud launcher makes a `claude-cloud` lane's
/// (it runs `worktree create <id> --no-checkout`), set up as
/// the package's `setup_app_worktree` does for a no-checkout create:
/// `extensions.worktreeConfig` on the repository, the index read from
/// `HEAD`, no file written, and the mark `kendex-worktree.checkoutMode
/// claim` in the worktree's own config.
fn claim_worktree_fixture(dir: &Path) -> (PathBuf, PathBuf) {
    let repo = repository_fixture(dir);
    let wt = dir.join("wt");
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            "--no-checkout",
            &wt.display().to_string(),
            "-b",
            "lane",
        ],
    );
    git(&repo, &["config", "extensions.worktreeConfig", "true"]);
    git(&wt, &["read-tree", "HEAD"]);
    git(
        &wt,
        &[
            "config",
            "--worktree",
            "kendex-worktree.checkoutMode",
            "claim",
        ],
    );
    (repo, wt)
}

/// One commit of `repo`'s index as the fixture's author.
fn commit(repo: &Path, message: &str) {
    git(
        repo,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "-m",
            message,
        ],
    );
}

/// A repository under `dir/name` with one committed file: the source a
/// row's superproject adds as a submodule.
fn submodule_source(dir: &Path, name: &str) -> PathBuf {
    let source = dir.join(name);
    git(dir, &["init", "-q", "-b", "main", name]);
    std::fs::write(source.join("tracked.txt"), "o\n").unwrap();
    git(&source, &["add", "tracked.txt"]);
    commit(&source, "base");
    source
}

/// Adds `source` to `repo`'s checked-out branch as the submodule `name`
/// and commits it, `ignore` written first as `submodule.<name>.ignore` in
/// the committed `.gitmodules`.
fn add_submodule(repo: &Path, source: &Path, name: &str, ignore: Option<&str>) {
    git(
        repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &source.display().to_string(),
            name,
        ],
    );
    if let Some(ignore) = ignore {
        let key = format!("submodule.{name}.ignore");
        git(repo, &["config", "-f", ".gitmodules", &key, ignore]);
    }
    git(repo, &["add", ".gitmodules", name]);
    commit(repo, "submodule");
}

/// Fast-forwards the fixture worktree's `lane` onto `main` after `main`
/// moved, `origin/main` with it (the package's branch-deletion proof reads
/// it); the worktree then holds `main`'s gitlinks, each uninitialized.
fn merge_main(repo: &Path, wt: &Path) {
    git(repo, &["fetch", "-q", "origin"]);
    git(wt, &["merge", "-q", "--ff-only", "main"]);
}

/// Initializes every submodule of `wt`, nested ones included, as a lane
/// that checked out a superproject does.
fn init_submodules(wt: &Path) {
    git(
        wt,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "update",
            "-q",
            "--init",
            "--recursive",
        ],
    );
}

/// A commit made only inside `wt`'s initialized submodule `sub`, its
/// gitlink bump committed on `lane`, `main` fast-forwarded onto it and
/// `origin` fetched: the superproject reads merged and clean while the
/// commit's only copy is the worktree's module store. Returns the commit
/// and the store's path.
fn unpushed_submodule_commit(repo: &Path, wt: &Path) -> (String, PathBuf) {
    let sub = wt.join("sub");
    std::fs::write(sub.join("work.txt"), "w\n").unwrap();
    git(&sub, &["add", "work.txt"]);
    commit(&sub, "work");
    let work = git(&sub, &["rev-parse", "HEAD"]);
    let store = PathBuf::from(git(
        &sub,
        &["rev-parse", "--path-format=absolute", "--git-dir"],
    ));
    git(wt, &["add", "sub"]);
    commit(wt, "bump");
    git(repo, &["merge", "-q", "--ff-only", "lane"]);
    git(repo, &["fetch", "-q", "origin"]);
    (work, store)
}

/// The close's pinned status listing of `wt`, the superproject's evidence
/// of a dirty tree.
fn pinned_status(wt: &Path) -> String {
    git(
        wt,
        &[
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ],
    )
}

/// The report of `item`'s terminal close, `wt` recorded as the lane's
/// worktree, through the real worktree package.
fn close_lane_with_worktree(runner: &Runner, checkout: &Path, item: &str, wt: &Path) -> Value {
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane(item, runner, wt)]);
    runner.write_fleet(&fleet);
    close_with_worktree(runner, checkout, item)
}

/// Whether the module store at `store` holds `commit`, by `git cat-file
/// -e` run against that store alone.
fn commit_in_store(store: &Path, commit: &str) -> bool {
    program("git")
        .args([
            "--git-dir",
            &store.display().to_string(),
            "cat-file",
            "-e",
            commit,
        ])
        .status()
        .expect("git")
        .success()
}

/// Asserts `report` is a confirmed close that kept `wt` with `reason` on
/// the lane, the worktree standing.
fn assert_kept(report: &Value, wt: &Path, reason: &str) {
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "kept",
        "{report}"
    );
    assert_eq!(report["lane"]["kept"], reason, "{report}");
    assert!(wt.exists(), "the worktree stands");
}

/// Asserts `report` is a confirmed close that released `wt` with no `kept`
/// on the lane, the path gone.
fn assert_released(report: &Value, wt: &Path) {
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert_eq!(report["lane"]["kept"], Value::Null, "{report}");
    assert!(!wt.exists(), "the worktree was not removed");
}

#[test]
fn a_direct_landing_close_consumes_only_a_base_contained_rebase_map() {
    for (unlanded, archived) in [(false, false), (true, false), (false, true)] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let (repo, wt) = worktree_fixture(runner.state_dir());
        std::fs::create_dir_all(repo.join(".agents")).unwrap();
        let skills = Path::new(&worktree_cli())
            .ancestors()
            .nth(3)
            .unwrap()
            .to_path_buf();
        std::os::unix::fs::symlink(skills, repo.join(".agents/skills")).unwrap();
        std::fs::write(repo.join(".git/info/exclude"), "/.agents/\n").unwrap();
        let origin = dir.path().join("origin.git");
        git(
            dir.path(),
            &["init", "-q", "--bare", origin.to_str().unwrap()],
        );
        git(
            &repo,
            &["remote", "set-url", "origin", origin.to_str().unwrap()],
        );
        git(&repo, &["config", "gc.auto", "0"]);
        git(&repo, &["config", "maintenance.auto", "false"]);
        git(&repo, &["push", "-q", "origin", "main"]);
        git(&repo, &["checkout", "-qb", "develop"]);
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        // GitHub's default moved while origin/HEAD stayed stale. The
        // inherited token is refused, but the saved sign-in can read it.
        write_executable(
            &bin.join("gh"),
            r#"#!/bin/sh
case "$1 $2" in
    'repo view') echo o/repo ;;
    'api user') printf 'HTTP/2.0 401 Unauthorized\n\n'; exit 1 ;;
    'auth status') [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] ;;
    'api repos/o/repo')
        [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || exit 1
        echo develop ;;
    *) exit 1 ;;
esac
"#,
        );
        let path = tool_path(&[&bin]);
        let advance_base = || {
            git(&repo, &["commit", "-qm", "base advances", "--allow-empty"]);
            git(&repo, &["push", "-q", "origin", "develop"]);
            git(&repo, &["rev-parse", "develop"])
        };
        let worktree_push = |args: &[&str]| {
            let out = program(worktree_cli())
                .arg("push")
                .args(args)
                .env("PATH", &path)
                .current_dir(&wt)
                .output()
                .unwrap();
            assert!(out.status.success(), "push {args:?}: {}", stderr(&out));
        };
        std::fs::write(wt.join("landed"), "landed\n").unwrap();
        git(&wt, &["add", "landed"]);
        commit(&wt, "work to land");
        let original = git(&wt, &["rev-parse", "HEAD"]);
        let base = advance_base();
        worktree_push(&["--prepare-base"]);
        worktree_push(&["--to-base", &base]);
        let delivered = git(&wt, &["rev-parse", "HEAD"]);
        assert_ne!(original, delivered);
        assert_eq!(git(&repo, &["rev-parse", "origin/develop"]), delivered);
        assert_eq!(
            git(
                &repo,
                &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
            ),
            "origin/main"
        );
        let map = PathBuf::from(git(
            &wt,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "kendex-rebase-map",
            ],
        ));
        if unlanded {
            git(&repo, &["merge", "-q", "--ff-only", "origin/develop"]);
            std::fs::write(wt.join("unlanded"), "unlanded\n").unwrap();
            git(&wt, &["add", "unlanded"]);
            commit(&wt, "work for another landing");
            advance_base();
            worktree_push(&["--prepare-base"]);
            assert_ne!(git(&wt, &["rev-parse", "HEAD"]), delivered);
            git(&wt, &["reset", "-q", "--hard", &delivered]);
        }
        let map_before = std::fs::read(&map).unwrap();
        let record = item_record(runner.state_dir(), "KEN-M");
        let restack_landing = json!({"original": original, "at": 1, "round": null});
        if !archived {
            std::fs::write(
                &record,
                json!({
                    "issue_id": "KEN-M", "worktree": wt, "branch": "lane", "fixed_items": [{"commit": original}],
                    "restacks": 2, "restack_landing": restack_landing,
                }).to_string(),
            ).unwrap();
        }
        let mut fleet = runner.fleet();
        let mut lane = worktree_lane("KEN-M", &runner, &wt);
        lane["status"] = json!("stopped");
        fleet["lanes"] = json!([lane]);
        runner.write_fleet(&fleet);
        let answer = reply(&runner.op_fleet_in(
            &repo,
            &json!({"op": "close-lane", "item": "KEN-M", "delivery": {"commit": {"commit": delivered}}}),
            &[("WORKTREE_CLI", &worktree_cli()), ("PATH", &path), ("GH_TOKEN", "expired-fixture-token")],
        ));
        assert_eq!(answer["result"]["word"], "closed", "{answer}");
        let lane = &runner.fleet()["lanes"][0];
        let branch = git(&repo, &["branch", "--list", "lane"]);
        if unlanded || archived {
            assert_eq!(
                answer["result"]["observation"]["worktree"], "kept",
                "{answer}"
            );
            assert!(
                lane["kept"]
                    .as_str()
                    .unwrap()
                    .contains("worktree-remove-rebase-map: "),
                "{lane}"
            );
            assert_eq!(branch, "+ lane");
            assert_eq!(std::fs::read(&map).unwrap(), map_before);
        } else {
            assert_eq!(
                answer["result"]["observation"]["worktree"], "released",
                "{answer}"
            );
            assert!(!wt.exists());
            assert_eq!(branch, "");
        }
        if archived {
            assert!(!record.exists());
        } else {
            let saved: Value = serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
            assert_eq!(
                saved["fixed_items"][0]["commit"],
                if unlanded { original } else { delivered }
            );
            assert_eq!(saved["restacks"], 2);
            assert_eq!(saved["restack_landing"], restack_landing);
        }
    }
}

/// The report of `item`'s terminal close with the worktree package at
/// `cli` as `WORKTREE_CLI`, run from `checkout`, the repository whose
/// linked worktree the lane holds: the overseer runs in the checkout its
/// lanes' worktrees belong to, and the close trusts no other git folder.
fn close_with_worktree_cli(runner: &Runner, checkout: &Path, item: &str, cli: &str) -> Value {
    effect_report(&runner.op_fleet_in(checkout, &terminal_close(item), &[("WORKTREE_CLI", cli)]))
}

/// A running lane with no recorded identity or pane whose worktree is `wt`:
/// its close takes the pane route to the finish, where the worktree is
/// released or kept.
fn worktree_lane(item: &str, runner: &Runner, wt: &Path) -> Value {
    let mut row = lane(item, "running", runner, Value::Null);
    row["mail_root"] = json!(wt.display().to_string());
    row
}

/// The worktree package's script in this checkout, the owner a close
/// removes a worktree through: the sibling catalog package of the orch
/// skill under test.
fn worktree_cli() -> String {
    fixtures()
        .ancestors()
        .nth(4)
        .expect("the catalog's skills directory")
        .join("worktree/scripts/worktree")
        .display()
        .to_string()
}

/// The report of `item`'s terminal close with the real worktree package as
/// `WORKTREE_CLI`.
fn close_with_worktree(runner: &Runner, checkout: &Path, item: &str) -> Value {
    close_with_worktree_cli(runner, checkout, item, &worktree_cli())
}

/// One unread notice a lane wrote to its mailbox under the worktree's
/// ignored `tmp/`, where the shipped `lane-mail` writes it: the row's bytes
/// and the file's path under `wt`.
fn plant_lane_notice(wt: &Path, item: &str) -> (Vec<u8>, PathBuf) {
    let row = format!("{{\"kind\":\"notice\",\"id\":\"n1\",\"item\":\"{item}\"}}\n").into_bytes();
    let dir = wt.join("tmp/lane-mail").join(item);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("to-overseer.jsonl");
    std::fs::write(&path, &row).unwrap();
    (row, path)
}

/// The standing and discharged worktree rows of `intent`'s lane set.
fn worktree_rows(intent: &Value) -> Vec<Value> {
    let standing = intent["lane_obligations"]["standing"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let discharged = intent["lane_obligations"]["discharged"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    standing
        .into_iter()
        .filter(|o| o["kind"] == "worktree")
        .chain(
            discharged
                .into_iter()
                .filter(|d| d["obligation"]["kind"] == "worktree"),
        )
        .collect()
}

/// The lane's worktree is an owned resource of the close, released through
/// the worktree package's `remove` when clean and merged, else kept with
/// its reason on the lane record and the close still settled. Each row
/// varies the fixture worktree: a removal over unmerged commits or a dirty
/// tree loses work, a refusal read as released has the record lie about the
/// disk, and a released worktree with no `kept` or a kept one without its
/// reason leaves prune unable to judge the state. The locked row is the
/// package's own refusal, issued before anything is removed.
#[test]
fn a_close_releases_a_clean_merged_worktree_and_keeps_one_it_would_lose_work_on() {
    type Plant = fn(&Path, &Path);
    /// The lane's `kept` after the close: none for a release, the reason
    /// word, or a refusal carrying the package's keyed line.
    enum Kept {
        Released,
        Reason(&'static str),
        Refusal(&'static str),
    }
    // (name, how the fixture is varied, the observation's worktree word, the
    // lane's `kept`, whether the path still stands)
    let rows: Vec<(&str, Plant, &str, Kept, bool)> = vec![
        (
            "clean and merged: released",
            |_, _| {},
            "released",
            Kept::Released,
            false,
        ),
        (
            "unmerged commits: kept",
            |_, wt| {
                git(
                    wt,
                    &[
                        "-c",
                        "user.email=t@t",
                        "-c",
                        "user.name=t",
                        "commit",
                        "-q",
                        "--allow-empty",
                        "-m",
                        "work",
                    ],
                );
            },
            "kept",
            Kept::Reason("unmerged"),
            true,
        ),
        (
            "an untracked file: kept dirty",
            |_, wt| std::fs::write(wt.join("draft.txt"), "x\n").unwrap(),
            "kept",
            Kept::Reason("dirty"),
            true,
        ),
        (
            "the removal refuses a locked worktree: kept with the refusal",
            |repo, wt| {
                git(repo, &["worktree", "lock", &wt.display().to_string()]);
            },
            "kept",
            Kept::Refusal("worktree-worktree-locked: "),
            true,
        ),
    ];
    for (name, plant, word, kept, stands) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let (repo, wt) = worktree_fixture(runner.state_dir());
        plant(&repo, &wt);
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([worktree_lane("KEN-W", &runner, &wt)]);
        runner.write_fleet(&fleet);
        let report = close_with_worktree(&runner, &repo, "KEN-W");
        assert_eq!(report["intent"]["outcome"], "confirmed", "{name}: {report}");
        assert_eq!(report["lane"]["status"], "done", "{name}: {report}");
        assert_eq!(
            report["intent"]["observation"]["worktree"], word,
            "{name}: {report}"
        );
        assert_eq!(wt.exists(), stands, "{name}: the path on disk");
        let lane_kept = report["lane"]["kept"].as_str();
        match kept {
            Kept::Released => assert_eq!(
                lane_kept, None,
                "{name}: a released worktree records no reason"
            ),
            // The package's own keyed line, not the `refused:` prefix alone,
            // which a package that cannot start would also carry.
            Kept::Refusal(line) => assert!(
                lane_kept.is_some_and(|k| k.starts_with("refused:status=1 ") && k.contains(line)),
                "{name}: the package's refusal is recorded: {report}"
            ),
            Kept::Reason(reason) => assert_eq!(lane_kept, Some(reason), "{name}: {report}"),
        }
        let rows = worktree_rows(&report["intent"]);
        assert_eq!(rows.len(), 1, "{name}: one worktree row: {report}");
        assert_eq!(
            rows[0]["obligation"]["path"],
            wt.display().to_string(),
            "{name}: the discharge names the recorded path"
        );
        let by = rows[0]["by"].as_str().unwrap_or_default();
        match kept {
            Kept::Released => assert_eq!(by, "released", "{name}"),
            Kept::Reason(_) | Kept::Refusal(_) => {
                assert!(by.starts_with("kept:"), "{name}: {by}");
            }
        }
        // A locked fixture worktree would stand in the way of the tempdir's
        // removal only through git's own metadata; the directory removes as
        // files.
    }
}

/// A copy of `repo`'s git folder at `at`, its `config` naming `run` as
/// `core.fsmonitor` and as the clean filter its `info/attributes` puts every
/// path through: a git folder a confined lane can make under its own root,
/// from which any git that takes it for its repository or its common folder
/// runs `run`, the filter where no `core.fsmonitor` override reaches.
fn planted_git_folder(repo: &Path, at: &Path, run: &Path) {
    std::fs::create_dir_all(at.parent().unwrap()).unwrap();
    let out = program("cp")
        .arg("-R")
        .arg(repo.join(".git"))
        .arg(at)
        .output()
        .expect("cp");
    assert!(out.status.success(), "cp: {}", stderr(&out));
    let config = at.join("config").display().to_string();
    let run = run.display().to_string();
    git(repo, &["config", "--file", &config, "core.fsmonitor", &run]);
    git(
        repo,
        &["config", "--file", &config, "filter.planted.clean", &run],
    );
    std::fs::create_dir_all(at.join("info")).unwrap();
    std::fs::write(at.join("info/attributes"), "* filter=planted\n").unwrap();
}

/// The tracked `.gitignore` of `wt` given another modification time, its
/// bytes unchanged: a status read refreshes its index entry, reading the
/// file through its filter, and writes the index.
fn restat(wt: &Path) {
    let past = std::time::SystemTime::now() - Duration::from_secs(600);
    std::fs::File::options()
        .write(true)
        .open(wt.join(".gitignore"))
        .unwrap()
        .set_modified(past)
        .unwrap();
}

/// A confined lane may write its root's `.git` file, its own admin folder
/// under the common git folder, and a hooks folder the common one lacked at
/// launch. The close's git reads of the lane's worktree run unconfined, as
/// the operator, so they take their git folders from the overseer's own
/// checkout and run no program a lane named: a `.git` leading outside that
/// checkout's `worktrees/` and a worktree configuration holding any key but
/// the worktree package's own keep the worktree, each with its word, and a
/// rewritten `commondir` or a planted hook is not read, and the worktree
/// package's removal runs from that checkout. Each row's lane write names a
/// program that writes a marker under the row's temporary root; no marker
/// may stand after the close.
#[test]
fn a_close_runs_no_program_a_lane_planted_in_its_git_folders() {
    type Plant = fn(&Path, &Path, &Path);
    /// The worktree's end: kept with the close's own word, kept with the
    /// package's keyed refusal, or released.
    enum End {
        Kept(&'static str),
        Refused(&'static str),
        Released,
    }
    // (name, the lane's write, the worktree's end)
    let rows: Vec<(&str, Plant, End)> = vec![
        (
            "the root's .git names a git folder under the root",
            |repo, wt, run| {
                // Shaped as a linked worktree's admin folder, so the
                // gitfile's parser takes it and its place alone refuses it.
                let planted = wt.join("tmp/planted/.git");
                planted_git_folder(repo, &planted, run);
                let admin = planted.join("worktrees/wt");
                let gitfile = format!("gitdir: {}\n", admin.display());
                std::fs::write(wt.join(".git"), gitfile).unwrap();
            },
            End::Kept("git-dir-foreign"),
        ),
        (
            "its admin folder's commondir names a git folder under the root",
            |repo, wt, run| {
                let planted = wt.join("tmp/planted.git");
                planted_git_folder(repo, &planted, run);
                let commondir = format!("{}\n", planted.display());
                std::fs::write(repo.join(".git/worktrees/wt/commondir"), commondir).unwrap();
                restat(wt);
            },
            // The close's pinned reads find the tree clean and merged; the
            // package, run from the overseer's checkout, finds no worktree
            // registered there through the rewritten admin folder.
            End::Refused("worktree-path-unregistered: "),
        ),
        (
            "a worktree configuration under extensions.worktreeConfig",
            |repo, _, run| {
                git(repo, &["config", "extensions.worktreeConfig", "true"]);
                git(
                    repo,
                    &[
                        "config",
                        "--file",
                        ".git/worktrees/wt/config.worktree",
                        "core.fsmonitor",
                        &run.display().to_string(),
                    ],
                );
            },
            End::Kept("worktree-config"),
        ),
        (
            "a post-index-change hook where no hooks folder stood at launch",
            |repo, wt, run| {
                let hooks = repo.join(".git/hooks");
                std::fs::remove_dir_all(&hooks).unwrap();
                std::fs::create_dir(&hooks).unwrap();
                std::os::unix::fs::symlink(run, hooks.join("post-index-change")).unwrap();
                restat(wt);
            },
            End::Released,
        ),
    ];
    for (name, plant, end) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let (repo, wt) = worktree_fixture(runner.state_dir());
        let marker = runner.state_dir().join("planted-ran");
        let run = runner.state_dir().join("planted-program");
        write_executable(
            &run,
            format!("#!/bin/sh\necho \"$0\" >> '{}'\n", marker.display()),
        );
        plant(&repo, &wt, &run);
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([worktree_lane("KEN-P", &runner, &wt)]);
        runner.write_fleet(&fleet);
        let report = close_with_worktree(&runner, &repo, "KEN-P");
        assert!(
            !marker.exists(),
            "{name}: the close ran the lane's program: {report}"
        );
        assert_eq!(report["intent"]["outcome"], "confirmed", "{name}: {report}");
        let kept = report["lane"]["kept"].as_str();
        match end {
            End::Kept(word) => assert_eq!(kept, Some(word), "{name}: {report}"),
            End::Refused(line) => assert!(
                kept.is_some_and(|k| k.starts_with("refused:status=1 ") && k.contains(line)),
                "{name}: {report}"
            ),
            End::Released => assert_eq!(kept, None, "{name}: {report}"),
        }
        assert_eq!(
            wt.exists(),
            !matches!(end, End::Released),
            "{name}: the worktree on disk"
        );
    }
}

/// A lane may hold a worktree of another repository than the overseer's:
/// a connected repository's, or a second clone's. Its row then carries the
/// common git folder its registration read (`checkout_common`), and the
/// close pins its reads to that folder and removes a clean, merged worktree
/// from that repository's main checkout. Trust reaches no further than the
/// row: a `.git` leading into a third repository's `worktrees/`, a row
/// that records no folder over a `.git` leading under the lane's own root,
/// the recorded folder's `worktrees/` replaced by a link (a lane may write
/// that folder), and a recorded folder not named `.git` keep the worktree
/// `git-dir-foreign` and run no program planted there. The release of the
/// first row runs from the recorded repository's main checkout, never the
/// overseer's.
#[test]
fn a_close_releases_a_worktree_of_the_repository_its_row_records() {
    type Plant = fn(&Path, &Path, &Path, &Path);
    // The folder the row records, from (that repository, a third folder).
    type Record = fn(&Path, &Path) -> Option<PathBuf>;
    let its_own: Record = |repo, _| Some(std::fs::canonicalize(repo.join(".git")).unwrap());
    // (name, the folder the row records, the lane's write as (that
    // repository, the worktree, the program, a third folder), the word the
    // worktree is kept with, none for a release)
    let rows: Vec<(&str, Record, Plant, Option<&str>)> = vec![
        (
            "a clean, merged worktree of the recorded repository",
            its_own,
            |_, _, _, _| {},
            None,
        ),
        (
            "its .git leads into a third repository's worktrees/",
            its_own,
            |repo, wt, run, third| {
                let planted = third.join(".git");
                planted_git_folder(repo, &planted, run);
                let gitfile = format!("gitdir: {}\n", planted.join("worktrees/wt").display());
                std::fs::write(wt.join(".git"), gitfile).unwrap();
            },
            Some("git-dir-foreign"),
        ),
        (
            "no recorded folder, its .git leading under its own root",
            |_, _| None,
            |repo, wt, run, _| {
                let planted = wt.join("tmp/planted/.git");
                planted_git_folder(repo, &planted, run);
                let gitfile = format!("gitdir: {}\n", planted.join("worktrees/wt").display());
                std::fs::write(wt.join(".git"), gitfile).unwrap();
            },
            Some("git-dir-foreign"),
        ),
        (
            "the recorded repository's worktrees/ a link into a third's",
            its_own,
            |repo, wt, run, third| {
                let planted = third.join(".git");
                planted_git_folder(repo, &planted, run);
                let worktrees = repo.join(".git/worktrees");
                std::fs::rename(&worktrees, repo.join(".git/moved")).unwrap();
                std::os::unix::fs::symlink(planted.join("worktrees"), &worktrees).unwrap();
                restat(wt);
            },
            Some("git-dir-foreign"),
        ),
        (
            "a recorded folder not named .git, a link to the repository's",
            |repo, third| {
                let link = third.join("common");
                std::os::unix::fs::symlink(repo.join(".git"), &link).unwrap();
                Some(link)
            },
            |_, _, _, _| {},
            Some("git-dir-foreign"),
        ),
    ];
    for (name, record, plant, kept) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let [own, other, third] = ["a", "b", "c"].map(|name| {
            let at = runner.state_dir().join(name);
            std::fs::create_dir_all(&at).unwrap();
            at
        });
        let overseer = repository_fixture(&own);
        let (repo, wt) = worktree_fixture(&other);
        let marker = runner.state_dir().join("planted-ran");
        let run = runner.state_dir().join("planted-program");
        write_executable(
            &run,
            format!("#!/bin/sh\necho \"$0\" >> '{}'\n", marker.display()),
        );
        plant(&repo, &wt, &run, &third);
        let mut row = worktree_lane("KEN-C", &runner, &wt);
        if let Some(common) = record(&repo, &third) {
            row["checkout_common"] = json!(common.display().to_string());
        }
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([row]);
        runner.write_fleet(&fleet);
        let report = close_with_worktree(&runner, &overseer, "KEN-C");
        assert!(
            !marker.exists(),
            "{name}: the close ran the lane's program: {report}"
        );
        match kept {
            None => assert_released(&report, &wt),
            Some(word) => assert_kept(&report, &wt, word),
        }
    }
}

/// A merged idle local lane as the close finds it: its launch confirmed,
/// its fleet row naming its worktree, its merge cycle and its repository,
/// its item Verifying on its tracker with only a post-merge box open, and
/// its live state record standing. The worktree package as planted records
/// whether the harness runs when the release asks it to remove the
/// worktree, then removes it.
struct MergedLane {
    runner: Runner,
    repo: PathBuf,
    wt: PathBuf,
    pid: u32,
    record: PathBuf,
    saw: PathBuf,
    cli: String,
    _server: Server,
    _dir: tempfile::TempDir,
}

impl MergedLane {
    fn new() -> MergedLane {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        let replies = runner.state_dir().join("linear.json");
        let item = json!({
            "issues bulk-get": {"body": {"issues": {"nodes": [
                {"identifier": "KEN-W", "state": {"type": "started"}, "description": POST_MERGE_ONLY, "children": {"nodes": []}}
            ]}}},
            "graphql BoxItem": {"body": {"issue": {"description": POST_MERGE_ONLY, "state": {"name": "Verifying", "type": "started"}}}},
        });
        std::fs::write(&replies, item.to_string()).unwrap();
        runner.env = vec![
            (
                "OVERSEE_WATCH_TRACKER".to_owned(),
                fixtures()
                    .join("linear-fixture/linear.sh")
                    .display()
                    .to_string(),
            ),
            (
                "LINEAR_FAKE_REPLIES".to_owned(),
                replies.display().to_string(),
            ),
            (
                "LINEAR_FAKE_LOG".to_owned(),
                runner.state_dir().join("linear.log").display().to_string(),
            ),
        ];
        runner.init_fleet();
        let (repo, wt) = worktree_fixture(dir.path());
        let launched =
            effect_report(&runner.op_fleet(&launch_request("KEN-W", runner.state_dir())));
        assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
        let pid = launched["lane"]["launch"]["pid"].as_u64().unwrap() as u32;
        let mut fleet = runner.fleet();
        fleet["lanes"][0]["mail_root"] = json!(wt.display().to_string());
        fleet["lanes"][0]["cycle"] = json!({"pr": 7});
        fleet["lanes"][0]["repo"] = json!("o/r");
        runner.write_fleet(&fleet);
        let record = support::item_record(runner.state_dir(), "KEN-W");
        std::fs::write(&record, "{}\n").unwrap();
        let saw = runner.state_dir().join("release-saw-harness");
        let cli = runner.state_dir().join("worktree-recording");
        write_executable(
            &cli,
            format!(
                "#!/bin/sh\nif [ \"$1\" = remove ]; then if kill -0 {pid} 2>/dev/null; then echo live; else echo gone; fi > '{}'; fi\nexec '{}' \"$@\"\n",
                saw.display(),
                worktree_cli()
            ),
        );
        MergedLane {
            runner,
            repo,
            wt,
            pid,
            record,
            saw,
            cli: cli.display().to_string(),
            _server: server,
            _dir: dir,
        }
    }

    fn close(&self) -> Value {
        let close = json!({"op": "close-lane", "item": "KEN-W"});
        let worktree = [("WORKTREE_CLI", self.cli.as_str())];
        reply(&self.runner.op_fleet_in(&self.repo, &close, &worktree))
    }

    /// The close refused the lane at its idle screen, touching neither the
    /// harness nor the worktree.
    fn assert_refused(&self, case: &str, answer: &Value) {
        assert_eq!(answer["refusal"]["key"], "lane-live", "{case}: {answer}");
        assert_eq!(
            refusal_field(answer, "state"),
            Some("idle".to_owned()),
            "{case}: {answer}"
        );
        assert!(live(self.pid), "{case}: a refused close stops nothing");
        assert!(self.wt.exists(), "{case}: a refused close removes nothing");
    }

    /// The close ended the lane on its merge, its harness stopped before
    /// the worktree's release, so the session never runs on in a removed
    /// directory.
    fn assert_closed(&self, answer: &Value) {
        assert_eq!(answer["result"]["word"], "closed", "{answer}");
        assert!(!live(self.pid), "the harness is stopped");
        assert!(!self.wt.exists(), "the clean merged worktree is released");
        assert_eq!(
            std::fs::read_to_string(&self.saw).unwrap().trim(),
            "gone",
            "the harness is stopped before the worktree's release: {answer}"
        );
    }
}

/// An idle local lane whose merge landed, its item still open on its
/// tracker and its worktree standing: while the item's live state record
/// stands the lane may be at work on it, so `close-lane` refuses
/// `lane-live state=idle`. Once the item's close-out removed that record
/// the close ends the lane on its merge.
#[test]
fn a_merged_lane_whose_close_out_is_done_is_stopped_before_its_worktree_is_released() {
    let lane = MergedLane::new();
    lane.assert_refused("the record standing", &lane.close());
    std::fs::remove_file(&lane.record).unwrap();
    lane.assert_closed(&lane.close());
}

/// A confined lane's close-out stamps its item's record, which its grants
/// hold, where an unconfined one removes it. A stamp an earlier attempt
/// wrote, between the lane's first launch and its current session as a
/// relaunch leaves them, says nothing of this attempt, so the close
/// refuses. Once this attempt's confined `state remove` stamped the record
/// the close ends the lane on its merge with the record standing for the
/// open item and its post-merge box left to the verification duty.
#[test]
fn a_confined_lanes_close_out_stamp_of_this_attempt_ends_its_merged_lane() {
    let lane = MergedLane::new();
    let mut fleet = lane.runner.fleet();
    fleet["lanes"][0]["launched_at"] = json!("2000-01-01T00:00:00Z");
    lane.runner.write_fleet(&fleet);
    std::fs::write(
        &lane.record,
        json!({"closed_out_at": "2000-06-01T00:00:00Z"}).to_string(),
    )
    .unwrap();
    lane.assert_refused("an earlier attempt's stamp", &lane.close());

    let removed = lane.runner.run_in(
        &lane.repo,
        &["state", "remove", "--item", "KEN-W"],
        &[("AGENT_RUNTIME_CONFINED", "1")],
    );
    assert_eq!(
        String::from_utf8_lossy(&removed.stdout),
        "state-remove: left cause=confined owner=overseer\n",
        "{}",
        String::from_utf8_lossy(&removed.stderr)
    );
    lane.assert_closed(&lane.close());
    assert!(lane.record.exists(), "the open item's record stays");
    let tracker = std::fs::read_to_string(lane.runner.state_dir().join("linear.log")).unwrap();
    assert!(
        tracker.lines().any(|l| l.starts_with("graphql")),
        "the close read the item's boxes: {tracker}"
    );
    assert!(
        !tracker.lines().any(|l| l.starts_with("issues complete")),
        "the post-merge box is left to the verification duty: {tracker}"
    );
}

/// A merged item's Done-when with its branch-provable box ticked with its
/// evidence and its post-merge box open: merge-pr's completion has run.
const POST_MERGE_ONLY: &str = "## Done when\n- [x] branch proof\n  Evidence: branch tests\n- [ ] Post-merge: health; Where: logs; Why after merge: deployment; Deadline: 2026-10-02T00:00:00Z";

/// The value of the refusal's field `name`.
fn refusal_field(answer: &Value, name: &str) -> Option<String> {
    answer["refusal"]["fields"]
        .as_array()?
        .iter()
        .find(|pair| pair[0] == name)
        .and_then(|pair| pair[1].as_str())
        .map(str::to_owned)
}

/// The dirty read lists every untracked file whatever the repository's
/// `status.showUntrackedFiles` setting, so a draft that setting hides from
/// a plain `git status` still keeps the worktree: a listing that obeys the
/// setting would read the tree clean, and the close would delete the draft
/// with the worktree.
#[test]
fn a_close_keeps_a_worktree_whose_untracked_draft_git_status_config_hides() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    git(&wt, &["config", "status.showUntrackedFiles", "no"]);
    let draft = wt.join("draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    assert_eq!(
        git(&wt, &["status", "--porcelain"]),
        "",
        "the probe's draft is hidden from a plain status"
    );
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-H", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-H");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "kept",
        "{report}"
    );
    assert_eq!(report["lane"]["kept"], "dirty", "{report}");
    assert!(
        draft.exists(),
        "untracked work deleted under status.showUntrackedFiles=no"
    );
}

/// A person's file at a gitlink's path (a vendored submodule turned into
/// one script, not yet staged) reads to git as an unpopulated gitlink, and
/// `submodule.<name>.ignore=all` hides its ` T` line from a status read
/// without `--ignore-submodules=none`. The close reads it dirt and keeps
/// the worktree, the file intact.
#[test]
fn a_close_keeps_a_worktree_whose_file_over_an_ignored_gitlink_is_dirt() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let source = submodule_source(runner.state_dir(), "sub-source");
    add_submodule(&repo, &source, "sub", Some("all"));
    merge_main(&repo, &wt);
    let file = wt.join("sub");
    std::fs::remove_dir(&file).unwrap();
    std::fs::write(&file, "person's file\n").unwrap();
    assert_eq!(
        git(&wt, &["status", "--porcelain", "--untracked-files=all"]),
        "",
        "the producer's ignore setting hides the replaced gitlink"
    );
    assert_eq!(
        pinned_status(&wt).trim(),
        "T sub",
        "the pinned read lists it"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-T", &wt);
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(report["lane"]["kept"], "dirty", "{report}");
    assert_eq!(
        std::fs::read_to_string(&file).ok().as_deref(),
        Some("person's file\n"),
        "the file at the gitlink path stands"
    );
}

/// The keep reads the worktree's module store and its populated gitlinks,
/// whatever the nested repositories' settings say: a nested submodule's own
/// `.gitmodules` `ignore=all` empties the superproject's pinned status
/// listing for a draft in the inner tree, so a keep reading that listing
/// would read the tree clean and the package's forced removal would delete
/// the draft with the worktree.
#[test]
fn a_close_keeps_a_worktree_whose_nested_submodule_setting_hides_a_draft() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let inner = submodule_source(runner.state_dir(), "inner-source");
    let middle = submodule_source(runner.state_dir(), "middle-source");
    add_submodule(&middle, &inner, "inner", Some("all"));
    add_submodule(&repo, &middle, "sub", None);
    merge_main(&repo, &wt);
    init_submodules(&wt);
    let draft = wt.join("sub/inner/draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    assert_eq!(
        pinned_status(&wt),
        "",
        "the probe's draft is hidden by the nested submodule's ignore=all"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-N", &wt);
    assert_kept(&report, &wt, "submodules");
    assert_eq!(
        std::fs::read(&draft).ok().as_deref(),
        Some(b"x\n".as_slice()),
        "the nested submodule draft was deleted under a nested setting"
    );
}

/// A submodule's commits are the worktree's as much as its files. A lane
/// commits inside a submodule and merges the gitlink bump, so the
/// superproject's `rev-list` pre-check reads the worktree merged and its
/// status listing clean, while the submodule commit's only copy is the
/// worktree's submodule store; a forced removal over it would leave `main`
/// naming a commit that exists nowhere.
#[test]
fn a_close_keeps_a_worktree_whose_submodule_holds_an_unpushed_commit() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let source = submodule_source(runner.state_dir(), "sub-source");
    add_submodule(&repo, &source, "sub", None);
    merge_main(&repo, &wt);
    init_submodules(&wt);
    let (work, store) = unpushed_submodule_commit(&repo, &wt);
    assert_eq!(
        pinned_status(&wt),
        "",
        "the probe's superproject listing reads clean"
    );
    assert_eq!(
        git(&repo, &["rev-parse", "main"]),
        git(&wt, &["rev-parse", "HEAD"]),
        "the probe's gitlink bump is merged"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-C", &wt);
    assert_kept(&report, &wt, "submodules");
    assert!(
        store.is_dir(),
        "the submodule store was deleted: {}",
        store.display()
    );
    assert_eq!(
        git(&wt.join("sub"), &["rev-parse", "HEAD"]),
        work,
        "the submodule's unpushed commit was lost"
    );
}

/// A gitlink never initialized, with no store and no populated directory,
/// has nothing to lose, so a clean merged worktree whose `.gitmodules`
/// names one is released, as git's own unforced removal removes it; every
/// gitlink read as a populated submodule would keep every worktree of a
/// repository with submodules, and no lane there would ever be released.
#[test]
fn a_close_releases_a_clean_worktree_whose_submodule_was_never_initialized() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let source = submodule_source(runner.state_dir(), "sub-source");
    add_submodule(&repo, &source, "sub", None);
    merge_main(&repo, &wt);
    assert!(
        git(&wt, &["ls-files", "--stage"]).contains("160000 "),
        "the probe's index holds the gitlink"
    );
    assert!(
        !wt.join("sub/.git").exists(),
        "the probe's submodule is populated"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-U", &wt);
    assert_released(&report, &wt);
}

/// The keep reads the index's gitlink, which no activation setting changes:
/// `submodule.<name>.active=false`, or a `submodule.active` pattern
/// excluding the submodule with the entry's own `active` unset
/// (gitsubmodules(7) § Active submodules), makes `git submodule status`
/// prefix a populated submodule `-`, so a keep reading that status would
/// read it absent, with the nested `ignore=all` emptying the pinned status,
/// and the forced removal would delete the inner draft.
#[test]
fn a_close_keeps_a_worktree_whose_submodule_activation_setting_hides_a_nested_draft() {
    // (name, the settings written to the worktree's config after `submodule
    // update --init` wrote `submodule.sub.active=true`)
    let rows: [(&str, &[&[&str]]); 2] = [
        (
            "submodule.sub.active=false",
            &[&["config", "submodule.sub.active", "false"]],
        ),
        (
            "submodule.active=:(exclude)sub",
            &[
                &["config", "--unset", "submodule.sub.active"],
                &["config", "submodule.active", ":(exclude)sub"],
            ],
        ),
    ];
    for (name, settings) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let (repo, wt) = worktree_fixture(runner.state_dir());
        let inner = submodule_source(runner.state_dir(), "inner-source");
        let middle = submodule_source(runner.state_dir(), "middle-source");
        add_submodule(&middle, &inner, "inner", Some("all"));
        add_submodule(&repo, &middle, "sub", None);
        merge_main(&repo, &wt);
        init_submodules(&wt);
        for setting in settings {
            git(&wt, setting);
        }
        let draft = wt.join("sub/inner/draft.txt");
        std::fs::write(&draft, "x\n").unwrap();
        assert!(
            git(&wt, &["submodule", "status"]).starts_with('-'),
            "{name}: the probe's populated submodule lists as uninitialized"
        );
        assert_eq!(
            pinned_status(&wt),
            "",
            "{name}: the probe's draft is hidden by the nested ignore=all"
        );
        let report = close_lane_with_worktree(&runner, &repo, "KEN-A", &wt);
        assert_kept(&report, &wt, "submodules");
        assert_eq!(
            std::fs::read(&draft).ok().as_deref(),
            Some(b"x\n".as_slice()),
            "{name}: the nested draft was deleted under an activation setting"
        );
    }
}

/// The index's gitlink names the submodule's module store whatever the
/// activation setting says. A lane commits inside its submodule and merges
/// the gitlink bump, and `submodule.sub.active=false` makes `git submodule
/// status` list the populated submodule `-`, so a keep reading that status
/// would read it absent and the superproject merged and clean, and the
/// forced removal would delete the worktree's module store, the commit's
/// only copy.
#[test]
fn a_close_keeps_a_worktree_whose_inactive_submodule_holds_an_unpushed_commit() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let source = submodule_source(runner.state_dir(), "sub-source");
    add_submodule(&repo, &source, "sub", None);
    merge_main(&repo, &wt);
    init_submodules(&wt);
    let (work, store) = unpushed_submodule_commit(&repo, &wt);
    git(&wt, &["config", "submodule.sub.active", "false"]);
    assert!(
        git(&wt, &["submodule", "status"]).starts_with('-'),
        "the probe's populated submodule lists as uninitialized"
    );
    assert_eq!(
        pinned_status(&wt),
        "",
        "the probe's superproject listing reads clean"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-I", &wt);
    assert_kept(&report, &wt, "submodules");
    assert!(
        commit_in_store(&store, &work),
        "the submodule's unpushed commit {work} is gone with its store {}",
        store.display()
    );
}

/// `git submodule deinit` empties the submodule's directory and leaves its
/// module store under the worktree's git directory, which the keep reads.
/// The deinitialized entry lists `-`, its `.git` is gone with the tree and
/// the pinned status lists nothing, so a keep reading `submodule status` or
/// the populated directory alone would release the worktree, and the forced
/// removal would delete the store, the only copy of a commit made inside
/// the submodule, and a draft a person wrote into the emptied directory.
#[test]
fn a_close_keeps_a_worktree_whose_deinitialized_submodule_left_its_store() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let source = submodule_source(runner.state_dir(), "sub-source");
    add_submodule(&repo, &source, "sub", None);
    merge_main(&repo, &wt);
    init_submodules(&wt);
    let (work, store) = unpushed_submodule_commit(&repo, &wt);
    git(&wt, &["submodule", "deinit", "-q", "sub"]);
    let draft = wt.join("sub/draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    assert!(
        !wt.join("sub/.git").exists(),
        "the probe's deinit left the submodule populated"
    );
    assert_eq!(
        pinned_status(&wt),
        "",
        "the probe's draft under the gitlink is listed by nothing"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-D", &wt);
    assert_kept(&report, &wt, "submodules");
    assert_eq!(
        std::fs::read(&draft).ok().as_deref(),
        Some(b"x\n".as_slice()),
        "the draft written after deinit was deleted"
    );
    assert!(
        commit_in_store(&store, &work),
        "the submodule's unpushed commit {work} is gone with its store {}",
        store.display()
    );
}

/// The keep reads the module store and the populated gitlinks of the index,
/// so a submodule a person cloned by hand into the gitlink path, its
/// repository a `.git` directory inside the worktree's tree and no store
/// under the worktree's git directory, keeps the worktree as git's own
/// unforced removal refuses it; a keep reading the store alone would
/// release it, and the forced removal would delete the clone with a draft
/// its nested `ignore=all` hides from the pinned status.
#[test]
fn a_close_keeps_a_worktree_whose_submodule_is_a_clone_with_no_store() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let inner = submodule_source(runner.state_dir(), "inner-source");
    let middle = submodule_source(runner.state_dir(), "middle-source");
    add_submodule(&middle, &inner, "inner", Some("all"));
    add_submodule(&repo, &middle, "sub", None);
    merge_main(&repo, &wt);
    let sub = wt.join("sub");
    git(&wt, &["clone", "-q", &middle.display().to_string(), "sub"]);
    init_submodules(&sub);
    let draft = sub.join("inner/draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    assert!(
        sub.join(".git").is_dir(),
        "the probe's clone is no repository of its own"
    );
    let modules = git(
        &wt,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "modules",
        ],
    );
    assert!(
        !Path::new(&modules).exists(),
        "the probe's worktree holds a module store: {modules}"
    );
    assert_eq!(
        pinned_status(&wt),
        "",
        "the probe's draft is hidden by the nested ignore=all"
    );
    let report = close_lane_with_worktree(&runner, &repo, "KEN-H", &wt);
    assert_kept(&report, &wt, "submodules");
    assert_eq!(
        std::fs::read(&draft).ok().as_deref(),
        Some(b"x\n".as_slice()),
        "the hand clone's nested draft was deleted"
    );
}

/// The keep reads no `.gitmodules`, so a gitlink with no mapping there, an
/// embedded repository `git add` took as one, is judged like any other and
/// a clean merged worktree is released. A read through `.gitmodules` (`git
/// submodule status`) exits 128 on the unmapped gitlink, which would hold
/// the worktree `worktree-unreadable` on every repeat and the lane would
/// never end.
#[test]
fn a_close_releases_a_clean_worktree_whose_gitlink_has_no_gitmodules_mapping() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let embedded = repo.join("emb");
    git(&repo, &["init", "-q", "-b", "main", "emb"]);
    std::fs::write(embedded.join("tracked.txt"), "o\n").unwrap();
    git(&embedded, &["add", "tracked.txt"]);
    commit(&embedded, "base");
    git(&repo, &["add", "emb"]);
    commit(&repo, "embedded");
    merge_main(&repo, &wt);
    let unmapped = program("git")
        .current_dir(&wt)
        .args(["submodule", "status"])
        .output()
        .expect("git");
    assert!(
        !unmapped.status.success(),
        "the probe's gitlink has a .gitmodules mapping: {}",
        String::from_utf8_lossy(&unmapped.stdout)
    );
    assert_eq!(pinned_status(&wt), "", "the probe's tree reads clean");
    let report = close_lane_with_worktree(&runner, &repo, "KEN-G", &wt);
    assert_released(&report, &wt);
}

/// The removal goes through the worktree package, which moves a lane's
/// mailboxes to the main checkout's `tmp/lane-mail/` before git deletes the
/// tree, so an unread notice under the worktree's ignored `tmp/`, invisible
/// to the dirty read, outlives the removal where the overseer's watch reads
/// a removed lane's mail; a raw `git worktree remove` would delete the
/// notice before its reader took it.
#[test]
fn a_close_releasing_a_worktree_moves_its_unread_lane_mail_to_the_main_checkout() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let (row, _) = plant_lane_notice(&wt, "KEN-M");
    assert_eq!(
        git(&wt, &["status", "--porcelain", "--untracked-files=all"]),
        "",
        "the probe's mailbox is under the ignored tmp/: the dirty read does not keep it"
    );
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-M", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-M");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert_eq!(report["lane"].get("kept"), None, "{report}");
    assert_eq!(report["lane"].get("kept_mail"), None, "{report}");
    assert!(!wt.exists(), "the worktree was released");
    let moved = repo.join("tmp/lane-mail/KEN-M/to-overseer.jsonl");
    assert_eq!(
        std::fs::read(&moved).ok(),
        Some(row),
        "unread lane mail was deleted instead of kept or moved: {}",
        moved.display()
    );
}

/// A linked worktree's mailbox moves during close. It must carry its
/// unread notice to the main checkout without the lane's GitHub token.
#[test]
fn a_confirmed_close_does_not_move_the_lanes_gh_token_into_the_main_checkout() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let (row, notice) = plant_lane_notice(&wt, "KEN-G");
    std::fs::write(notice.with_file_name("gh-token"), "fixture-token\n").unwrap();

    let report = close_lane_with_worktree(&runner, &repo, "KEN-G", &wt);
    assert_released(&report, &wt);
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let moved = repo.join("tmp/lane-mail/KEN-G/to-overseer.jsonl");
    assert_eq!(std::fs::read(&moved).unwrap(), row);
    let tokens = program("find")
        .arg(&repo)
        .args(["-name", "gh-token"])
        .output()
        .unwrap();
    assert!(tokens.status.success(), "{}", stderr(&tokens));
    assert!(
        tokens.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&tokens.stdout)
    );
}

/// The package's rc 2: a lane mailbox the package cannot move to the main
/// checkout's refuses the removal with nothing removed, and the close keeps
/// the worktree `mail-unmoved`, the notice where the lane wrote it.
#[test]
fn a_close_keeps_a_worktree_whose_lane_mail_cannot_be_moved() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let (row, notice) = plant_lane_notice(&wt, "KEN-R");
    // The main checkout's mailbox directory stands but takes no entry.
    let main_mail = repo.join("tmp/lane-mail");
    std::fs::create_dir_all(&main_mail).unwrap();
    std::fs::set_permissions(&main_mail, std::fs::Permissions::from_mode(0o500)).unwrap();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-R", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-R");
    std::fs::set_permissions(&main_mail, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "kept",
        "{report}"
    );
    assert_eq!(report["lane"]["kept"], "mail-unmoved", "{report}");
    assert!(wt.exists(), "nothing was removed");
    assert_eq!(
        std::fs::read(&notice).ok(),
        Some(row),
        "the notice stands where the lane wrote it"
    );
    assert!(
        !main_mail.join("KEN-R").exists(),
        "no mailbox reached the main checkout"
    );
}

/// The package's rc 3: a mailbox that cannot join the one already in the
/// main checkout is kept beside it, the worktree removed all the same, and
/// the close records where the package kept it on the lane as `kept_mail`,
/// the mail readable there.
#[test]
fn a_close_releasing_a_worktree_records_the_lane_mail_kept_beside_the_main_checkouts() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let (row, _) = plant_lane_notice(&wt, "KEN-J");
    // The main checkout's mailbox for the item is one no mail can join:
    // its to-overseer.jsonl a symlink, which the package's join refuses.
    let main_box = repo.join("tmp/lane-mail/KEN-J");
    std::fs::create_dir_all(&main_box).unwrap();
    std::os::unix::fs::symlink("/nonexistent", main_box.join("to-overseer.jsonl")).unwrap();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-J", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-J");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert_eq!(report["lane"].get("kept"), None, "{report}");
    assert!(!wt.exists(), "the worktree was released");
    let kept = report["lane"]["kept_mail"]
        .as_str()
        .unwrap_or_else(|| panic!("the kept mailbox is recorded on the lane: {report}"));
    assert_eq!(
        std::fs::read(Path::new(kept).join("KEN-J/to-overseer.jsonl")).ok(),
        Some(row),
        "the notice is readable where the record says: {kept}"
    );
}

/// The close is the one writer of the lane's `kept` and `kept_mail`, and a
/// relaunch keeps every field it does not write, so a lane closed `kept:
/// dirty`, relaunched and closed again with its worktree released must read
/// neither, or the retention duty would keep a worktree that is gone.
#[test]
fn a_later_close_that_releases_clears_an_earlier_closes_kept() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    let mut lane = worktree_lane("KEN-S", &runner, &wt);
    lane["kept"] = json!("dirty");
    lane["kept_mail"] = json!("/stale");
    fleet["lanes"] = json!([lane]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-S");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert!(!wt.exists(), "the worktree was released");
    assert_eq!(
        report["lane"].get("kept"),
        None,
        "a later close that releases leaves a stale kept: {report}"
    );
    assert_eq!(report["lane"].get("kept_mail"), None, "{report}");
}

/// A `claude-cloud` lane records `host: claude-cloud` with its `mail_root`
/// the item's worktree on this machine, the one worktree a hosted lane's
/// close removes here, so its close owes that worktree
/// and releases it through the package like a local lane's; a worktree
/// standing after a done close with no `kept` would read as released to the
/// retention duty.
#[test]
fn a_claude_cloud_lanes_local_worktree_is_owed_and_released() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = claim_worktree_fixture(runner.state_dir());
    let tracked = git(&wt, &["ls-files"]);
    assert!(
        !tracked.is_empty() && git(&wt, &["ls-files", "--deleted"]) == tracked,
        "the claim holds every tracked file in its index and none on disk: {tracked:?}"
    );
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([cloud_lane("KEN-C", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-C");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert!(!wt.exists(), "the cloud lane's local worktree was released");
    let rows = worktree_rows(&report["intent"]);
    assert_eq!(rows.len(), 1, "one worktree row: {report}");
    assert_eq!(rows[0]["by"], "released", "{report}");
    assert_eq!(report["lane"].get("kept"), None, "{report}");
}

/// In a claim worktree only the ` D` lines are the claim's design; an
/// untracked draft under it is work, and the close keeps the worktree
/// `dirty` with the draft intact.
#[test]
fn a_claude_cloud_lanes_claim_worktree_holding_a_draft_is_kept_dirty() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = claim_worktree_fixture(runner.state_dir());
    let draft = wt.join("draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([cloud_lane("KEN-D", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, &repo, "KEN-D");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["status"], "done", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "kept",
        "{report}"
    );
    assert_eq!(report["lane"]["kept"], "dirty", "{report}");
    assert!(wt.exists(), "the claim worktree stands");
    assert!(draft.exists(), "the draft under the claim was deleted");
}

/// A `claude-cloud` lane on `wt`, its local worktree, as the released
/// launcher records it: `host` and `kind` the cloud word.
fn cloud_lane(item: &str, runner: &Runner, wt: &Path) -> Value {
    let mut lane = worktree_lane(item, runner, wt);
    lane["host"] = json!("claude-cloud");
    lane["kind"] = json!("claude-cloud");
    lane
}

/// The fleet's own checkout given one commit of `src.txt`, itself as
/// `origin` with `origin/HEAD` on `main`, and per-worktree config: a launch
/// in a linked worktree of it is bound to the fleet's repository, and the
/// worktree package can reuse a tree there.
fn fleet_repository(runner: &Runner) -> PathBuf {
    let repo = std::fs::canonicalize(runner.state_dir()).unwrap();
    for (key, value) in [
        ("gc.auto", "0"),
        ("maintenance.auto", "false"),
        ("extensions.worktreeConfig", "true"),
    ] {
        git(&repo, &["config", key, value]);
    }
    std::fs::write(repo.join("src.txt"), "src\n").unwrap();
    git(&repo, &["add", "src.txt"]);
    commit(&repo, "init");
    git(&repo, &["branch", "-M", "main"]);
    let origin = repo.display().to_string();
    git(&repo, &["remote", "add", "origin", &origin]);
    git(&repo, &["fetch", "-q", "origin"]);
    git(&repo, &["remote", "set-head", "origin", "main"]);
    repo
}

/// A stopped `claude-cloud` lane on `wt` and the local launch request that
/// relaunches it there, as an approved pull request's landing lane is
/// launched after a no-landing stop: the request names the tree the cloud
/// launch recorded and no host.
fn cloud_relaunch(item: &str, runner: &Runner, wt: &Path) -> Value {
    let mut stopped = cloud_lane(item, runner, wt);
    stopped["status"] = json!("stopped");
    let mut fleet = runner.fleet();
    let mut lanes = fleet["lanes"].as_array().cloned().unwrap_or_default();
    lanes.push(stopped);
    fleet["lanes"] = Value::Array(lanes);
    runner.write_fleet(&fleet);
    let mut request = launch_request(item, wt);
    request["account"] = json!(runner.state_dir().display().to_string());
    request
}

/// Whether `wt` is a checkout: no tracked file missing from disk and no
/// claim mark.
fn checked_out(wt: &Path) -> bool {
    git(wt, &["ls-files", "--deleted"]).is_empty()
        && git(
            wt,
            &[
                "config",
                "--get",
                "--default",
                "",
                "kendex-worktree.checkoutMode",
            ],
        ) != "claim"
}

/// An approved cloud pull request's landing lane relaunched locally in the
/// claim the worktree package made with `create --no-checkout`: the
/// package's guarded reuse runs before the window, so the lane starts in a
/// checkout of its branch holding the branch's files, never in the claim.
#[test]
fn a_cloud_lanes_local_relaunch_opens_its_window_in_the_reused_checkout() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let repo = fleet_repository(&runner);
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    // gh's answer for a branch with no open pull request: nothing, exit 0.
    write_executable(
        &bin.join("gh"),
        "#!/bin/sh\nif [ \"$1 $2\" = 'pr list' ]; then exit 0; fi\nexit 4\n",
    );
    let path = tool_path(&[&bin]);
    let trees = root.join("trees").display().to_string();
    let created = program(worktree_cli())
        .args(["create", "KEN-C", "--no-checkout"])
        .env("PATH", &path)
        .env("WORKTREE_BASE_DIR", &trees)
        .current_dir(&repo)
        .output()
        .unwrap();
    assert!(
        created.status.success(),
        "worktree create: {}",
        String::from_utf8_lossy(&created.stderr)
    );
    let wt = PathBuf::from(String::from_utf8_lossy(&created.stdout).trim());
    assert!(
        wt.starts_with(&trees) && !checked_out(&wt),
        "the cloud launch's tree is a claim under the row's root"
    );
    let request = cloud_relaunch("KEN-C", &runner, &wt);
    let cli = worktree_cli();
    let report = effect_report(&runner.op_fleet_env(
        &request,
        &[
            ("WORKTREE_CLI", cli.as_str()),
            ("PATH", path.as_str()),
            ("WORKTREE_BASE_DIR", trees.as_str()),
        ],
    ));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        checked_out(&wt) && wt.join("src.txt").is_file(),
        "the window opened in a tree without the branch's files: {report}"
    );
    assert_eq!(
        report["intent"]["observation"].get("tree"),
        None,
        "{report}"
    );
}

/// The guarded reuse's other answers, through a planted package that
/// records each call: one that refuses, or finds the item another
/// session's, or hands back another tree, fails the launch with its named
/// cause and opens no window, the claim left as it stands; one that keeps the tree on its own head
/// (76) launches in it with `tree: unrebased`; a standing checkout's
/// relaunch asks the package nothing.
#[test]
fn a_cloud_lanes_local_relaunch_ends_on_a_refused_reuse_and_names_an_unrebased_one() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let repo = fleet_repository(&runner);
    let root = std::fs::canonicalize(dir.path()).unwrap();
    // (case, item, claim, the package's answer, outcome, cause, tree)
    let cases = [
        (
            "refused",
            "KEN-F",
            true,
            "echo 'worktree-reuse-refused: no' >&2; exit 1",
            "failed",
            Some("worktree-failed exit=1 worktree-reuse-refused: no"),
            None,
        ),
        (
            "owned",
            "KEN-O",
            true,
            "exit 75",
            "failed",
            Some("item-owned exit=75"),
            None,
        ),
        (
            "elsewhere",
            "KEN-E",
            true,
            "echo /nonexistent-tree",
            "failed",
            Some("worktree-reuse-elsewhere path=/nonexistent-tree"),
            None,
        ),
        (
            "unrebased",
            "KEN-U",
            true,
            "git checkout-index -a && git config --worktree kendex-worktree.checkoutMode checkout && pwd -P; exit 76",
            "confirmed",
            None,
            Some("unrebased"),
        ),
        (
            "checkout",
            "KEN-K",
            false,
            "exit 1",
            "confirmed",
            None,
            None,
        ),
    ];
    for (case, item, claim, answer, outcome, cause, tree) in cases {
        let wt = root.join(case);
        let at = wt.display().to_string();
        if claim {
            git(
                &repo,
                &["worktree", "add", "-q", "--no-checkout", &at, "-b", case],
            );
            git(&wt, &["read-tree", "HEAD"]);
            git(
                &wt,
                &[
                    "config",
                    "--worktree",
                    "kendex-worktree.checkoutMode",
                    "claim",
                ],
            );
        } else {
            git(&repo, &["worktree", "add", "-q", &at, "-b", case]);
        }
        let calls = root.join(format!("{case}.calls"));
        let cli = root.join(format!("{case}.worktree"));
        write_executable(
            &cli,
            format!(
                "#!/bin/sh\nprintf '%s|%s\\n' \"$(pwd -P)\" \"$*\" >> '{}'\n{answer}\n",
                calls.display()
            ),
        );
        let request = cloud_relaunch(item, &runner, &wt);
        let windows = server.panes().len();
        let report = effect_report(
            &runner.op_fleet_env(&request, &[("WORKTREE_CLI", &cli.display().to_string())]),
        );
        assert_eq!(report["intent"]["outcome"], outcome, "{case}: {report}");
        let observation = &report["intent"]["observation"];
        assert_eq!(observation["cause"].as_str(), cause, "{case}: {report}");
        assert_eq!(observation["tree"].as_str(), tree, "{case}: {report}");
        let asked = std::fs::read_to_string(&calls).unwrap_or_default();
        if claim {
            assert_eq!(
                asked,
                format!(
                    "{}|create {item} --reuse --keep-on-conflict\n",
                    wt.display()
                ),
                "{case}: the guarded reuse, once, in the claim"
            );
        } else {
            assert_eq!(
                asked, "",
                "{case}: a standing checkout asks the package nothing"
            );
        }
        if outcome == "failed" {
            assert_eq!(server.panes().len(), windows, "{case}: a window opened");
            assert!(!checked_out(&wt), "{case}: the claim was rewritten");
        } else {
            assert!(checked_out(&wt), "{case}: launched in a claim");
        }
    }
}

/// A worktree package that cannot start (a script that is not there never
/// starts: the runner's cause, no `worktree-` keyed line) removed nothing,
/// so the worktree is held `removal-not-started`: the close `unconfirmed`,
/// the worktree in `remaining`, the lane not `done`, nothing removed, and
/// the repeat reads it again once the install is repaired. A start that
/// failed read as the package's refusal would record a terminal `kept:
/// refused:...` on a lane whose close is never retried; read as no answer
/// (`removal-unanswered`), it would claim a removal that may have happened.
#[test]
fn a_worktree_package_that_cannot_start_holds_the_close_with_nothing_removed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-N", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let missing = runner.state_dir().join("no-such-package/worktree");
    let report = close_with_worktree_cli(&runner, &repo, "KEN-N", &missing.display().to_string());
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "unreadable",
        "{report}"
    );
    assert!(
        report["intent"]["observation"]["cause"]
            .as_str()
            .is_some_and(|c| c.contains("removal-not-started:")),
        "held as a removal that never started: {report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "worktree")["path"],
        wt.display().to_string(),
        "the worktree stands in what remains: {report}"
    );
    assert!(
        worktree_rows(&report["intent"])
            .iter()
            .all(|r| r.get("by").is_none()),
        "nothing discharged it: {report}"
    );
    let lane = &runner.fleet()["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(
        lane.get("kept"),
        None,
        "no terminal reason recorded: {lane}"
    );
    assert!(wt.exists(), "nothing was removed");
}

/// The hold: a worktree whose path cannot be read is neither released nor
/// kept. Its validation runs cannot be read either, so the validation stop
/// fails first and the close holds before the worktree is read: both
/// obligations stand and the close does not settle, so a repeated close
/// reads them again; an unreadable path discharged as released or kept
/// would record a state nothing read.
#[test]
fn an_unreadable_worktree_holds_the_close_worktree_unreadable() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-U", &runner, &wt)]);
    runner.write_fleet(&fleet);
    // The worktree itself unreadable: its own metadata reads, its entries
    // (its `.git`, its runs under `tmp/`) do not.
    std::fs::set_permissions(&wt, std::fs::Permissions::from_mode(0o000)).unwrap();
    let unread = std::fs::metadata(wt.join(".git")).is_err();
    let report = close_with_worktree(&runner, &repo, "KEN-U");
    std::fs::set_permissions(&wt, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(unread, "the probe's `.git` entry is unreadable");
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["validate"], "stop-failed", "{report}");
    assert!(
        observation["cause"]
            .as_str()
            .is_some_and(|c| c.starts_with("validate-unreadable:")),
        "{report}"
    );
    for kind in ["validation", "worktree"] {
        assert!(
            !remaining(observation, kind).is_null(),
            "the {kind} stands in what remains: {report}"
        );
    }
    assert_eq!(
        remaining(observation, "worktree")["path"],
        wt.display().to_string(),
        "{report}"
    );
    assert!(
        lane_discharged_by(&report["intent"], "released").is_empty()
            && worktree_rows(&report["intent"])
                .iter()
                .all(|r| r.get("by").is_none()),
        "nothing discharged it: {report}"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert!(wt.exists(), "nothing was removed");
}

/// A close whose lane record names no local worktree acquires none, so a
/// lane with no mail root and a hosted lane (whose worktree is its host's)
/// settle with no worktree row: a worktree obligation on a path this
/// machine does not hold would never settle.
#[test]
fn a_lane_with_no_local_worktree_acquires_no_worktree_obligation() {
    // (name, the lane fields that name no local worktree)
    let rows: Vec<(&str, Value)> = vec![
        ("no mail root", json!({"mail_root": Value::Null})),
        (
            "a hosted lane",
            json!({"host": "/host", "mail_root": "/srv/worktree"}),
        ),
    ];
    for (name, fields) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let mut row = lane("KEN-N", "running", &runner, Value::Null);
        for (key, value) in fields.as_object().unwrap() {
            row[key] = value.clone();
        }
        // The hosted lane's sandbox is its provider's to close: the planted
        // provider its record names.
        let scripts = runner.state_dir().join("provider-world");
        if fields.get("host").is_some() {
            row["host"] = json!(scripts.join("provider").display().to_string());
        }
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([row]);
        runner.write_fleet(&fleet);
        if fields.get("host").is_some() {
            std::fs::create_dir_all(&scripts).unwrap();
            std::os::unix::fs::symlink(
                fixtures().join("lane-host/lane-host"),
                scripts.join("provider"),
            )
            .unwrap();
            std::fs::write(
                scripts.join("lane-host.json"),
                json!({"close --item KEN-N": {"stdout": "kept=none\n"}, "list": {"stdout": ""}})
                    .to_string(),
            )
            .unwrap();
        }
        let report = effect_report(&runner.op_fleet(&terminal_close("KEN-N")));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{name}: {report}");
        assert!(
            worktree_rows(&report["intent"]).is_empty(),
            "{name}: no worktree acquired: {report}"
        );
        assert!(
            report["intent"]["observation"].get("worktree").is_none(),
            "{name}"
        );
        assert_eq!(report["lane"].get("kept"), None, "{name}");
    }
}

/// The worktree is acquired, written on the intent, before the removal
/// runs, so a close that dies at its removal leaves the record naming the
/// worktree it owes and the repeated close releases it. The git shim, on
/// the PATH the worktree package inherits, holds the run at the package's
/// `git worktree remove`; the row reads the record there, kills the run,
/// and repeats the close.
#[test]
fn a_close_crashed_at_its_removal_holds_the_worktree_acquired_for_the_repeat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-X", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let fifo = runner.state_dir().join("hold.fifo");
    mkfifo(&fifo);
    let mark = runner.state_dir().join("hold.mark");
    let real_git = Command::new("sh")
        .args(["-c", "command -v git"])
        .output()
        .expect("which git");
    let real_git = String::from_utf8_lossy(&real_git.stdout).trim().to_owned();
    assert!(!real_git.is_empty(), "a real git on PATH");
    let skip = runner.state_dir().join("hold.skip");
    let fifo_s = fifo.display().to_string();
    let mark_s = mark.display().to_string();
    let skip_s = skip.display().to_string();
    let cli = worktree_cli();
    let mut child = runner.spawn_op_fleet_in(
        &repo,
        &terminal_close("KEN-X"),
        &[
            ("WORKTREE_CLI", cli.as_str()),
            ("GIT_REAL", real_git.as_str()),
            ("GIT_HOLD_FIFO", fifo_s.as_str()),
            ("GIT_HOLD_MARK", mark_s.as_str()),
            ("GIT_HOLD_SKIP", skip_s.as_str()),
        ],
        &fixtures().join("git-hold"),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while !mark.exists() {
        assert!(
            Instant::now() < deadline,
            "the close never reached its removal: {}",
            runner.fleet()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The record at the removal: the worktree standing in the lane set, the
    // signal written, nothing discharged about it.
    let held = runner.fleet()["intents"][0].clone();
    let standing = held["lane_obligations"]["standing"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        standing
            .iter()
            .any(|o| o["kind"] == "worktree" && o["path"] == wt.display().to_string()),
        "the worktree is acquired before the removal: {held}"
    );
    assert_eq!(held["obligations"]["signalled"], true, "{held}");
    assert!(lane_discharged_by(&held, "released").is_empty(), "{held}");
    // The crash: the close is killed at its removal and the held shim
    // released with the skip file in place, so it exits without running the
    // removal its caller is dead for.
    child.kill().unwrap();
    child.wait().unwrap();
    std::fs::write(&skip, "").unwrap();
    release_hold(&fifo, Duration::from_secs(10), || {
        runner.fleet().to_string()
    });
    assert!(wt.exists(), "the held removal never ran");
    // The repeated close reads the standing worktree and releases it.
    let report = close_with_worktree(&runner, &repo, "KEN-X");
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "released",
        "{report}"
    );
    assert!(!wt.exists(), "the repeat released the worktree");
    assert_eq!(
        runner.fleet()["intents"].as_array().unwrap().len(),
        1,
        "no second intent"
    );
}

/// A signalled close owing its worktree under a lane that moved releases
/// that obligation `lane-moved`, as it does the validation stop, since the
/// worktree is the session's that now holds the lane; the close settles and
/// the worktree stands.
#[test]
fn a_moved_close_owing_its_worktree_releases_it_lane_moved() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (repo, wt) = worktree_fixture(runner.state_dir());
    let new_harness = Owned::sleep();
    let new_pane = server.open_idle("KEN-MW", runner.state_dir());
    let mut fleet = runner.fleet();
    let mut row = lane(
        "KEN-MW",
        "running",
        &runner,
        json!({
            "pane": new_pane, "server": server.pid, "server_start": server.start,
            "pid": new_harness.pid(), "start": new_harness.start(),
        }),
    );
    row["session_since"] = json!("2026-01-29T16:00:00Z");
    row["mail_root"] = json!(wt.display().to_string());
    fleet["lanes"] = json!([row]);
    fleet["intents"] = json!([{
        "id": "close-resources:KEN-MW:1-1", "op": "close-resources", "target": "KEN-MW", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "worktree": "unreadable", "cause": "worktree-unreadable:permission denied"},
        "obligations": {"standing": [], "discharged": [], "signalled": true},
        "lane_obligations": {"standing": [{"kind": "worktree", "path": wt.display().to_string()}]},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet_in(&repo, &terminal_close("KEN-MW"), &[]));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        lane_discharged_by(&report["intent"], "lane-moved")
            .iter()
            .any(|o| o["kind"] == "worktree"),
        "the owed worktree is released to the session holding the lane: {report}"
    );
    assert!(wt.exists(), "the new session's worktree stands");
    assert!(live(new_harness.pid()), "the new session stands");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
}

/// The marker the lane's hook reads, as the launch wrote it under the
/// checkout's common git directory for `item`, read three-valued.
fn marker_of(root: &Path, item: &str) -> Option<String> {
    let path = root
        .join(".git")
        .join("lane-mail")
        .join(item.to_ascii_lowercase());
    match std::fs::read_to_string(path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => panic!("the marker could not be read: {e}"),
    }
}

/// The effect is held at its `new-window` call and killed there.
#[test]
fn a_launch_writes_its_marker_and_mailbox_before_the_window_and_a_crash_between_reads_them_back() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let root = std::fs::canonicalize(runner.state_dir()).unwrap();
    let real_tmux = which_tmux();
    let holddir = fixtures().join("tmux-hold");
    let fifo = dir.path().join("hold.fifo");
    mkfifo(&fifo);
    let mark = dir.path().join("held");
    let fifo_s = fifo.display().to_string();
    let mark_s = mark.display().to_string();
    let shim_env = [
        ("TMUX_REAL", real_tmux.as_str()),
        ("TMUX_HOLD_FIFO", fifo_s.as_str()),
        ("TMUX_HOLD_VERB", "new-window"),
        ("TMUX_HOLD_MARK", mark_s.as_str()),
    ];
    let mut request = launch_request("KEN-M", runner.state_dir());
    request["refresh"] = json!(true);
    let mut child = runner.spawn_op_fleet(&request, &shim_env, &holddir);
    let deadline = Instant::now() + Duration::from_secs(20);
    while std::fs::metadata(&mark).is_err() {
        assert!(
            child.try_wait().unwrap().is_none(),
            "the launch ended before its window: {}",
            stderr(&child.wait_with_output().unwrap())
        );
        assert!(
            Instant::now() < deadline,
            "the launch never reached new-window"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // Held before the window: the record stands.
    assert_eq!(
        marker_of(&root, "KEN-M").as_deref(),
        Some(format!("{}\n", root.display()).as_str()),
        "the marker holds the lane's root before any window"
    );
    assert!(
        std::fs::metadata(root.join("tmp").join("lane-mail").join("KEN-M"))
            .is_ok_and(|m| m.is_dir()),
        "the lane's mailbox stands before any window"
    );
    assert_eq!(
        std::fs::read_to_string(root.join(".git").join("lane-refresh")).unwrap(),
        format!("{}\n", root.display()),
        "the refresh record names the root for a refresh lane"
    );
    assert_eq!(server.panes().len(), 1, "no window yet");
    // The crash between the record and the window.
    child.kill().unwrap();
    let _ = child.wait();
    release_hold(&fifo, Duration::from_secs(5), || {
        "the shim at new-window".to_owned()
    });
    // The launcher was asked and nothing registered: the window it may
    // have opened stands as an obligation, the intent open, and the marker
    // written before it is read back on the outcome.
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"], "pane-unrecorded",
        "{report}"
    );
    assert_eq!(
        report["intent"]["observation"]["marker"], "present",
        "the marker is read back on the outcome: {report}"
    );
    // A launch that is no refresh lane removes the record, so a relaunch
    // states it again.
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-N", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        std::fs::metadata(root.join(".git").join("lane-refresh")).is_err(),
        "the refresh record left with the launch that did not ask for it"
    );
}

/// The launch directory's own install, its orch and agent-runtime packages
/// linked where an apply puts them, prepared through orch's one real setup
/// (agent-runtime's runtime, then orch's) over agent-runtime's planted
/// cargo before the window opens, so the lane's first turn end can read its
/// mail. The lane is confined, so its setup runs under its words: a build
/// that fails refuses the launch with no window; one that succeeds writes
/// the lane's own cache while the shared cache, holding another tree's
/// binary, stays as it was; a launch whose keys the shared cache holds
/// builds nothing and runs the shared binaries through its own cache.
#[test]
#[cfg(target_os = "linux")]
fn a_launch_builds_its_installs_runtimes_before_the_window_and_a_failed_build_opens_none() {
    // The planted cargo and the shared cache stand outside the worktree.
    let (dir, _) = outside_tmp();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let root = std::fs::canonicalize(runner.state_dir()).unwrap();
    let packages = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let skills = root.join(".agents/skills");
    std::fs::create_dir_all(&skills).unwrap();
    for package in ["orch", "agent-runtime"] {
        std::os::unix::fs::symlink(packages.join(package), skills.join(package)).unwrap();
    }
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    std::os::unix::fs::symlink(
        packages.join("agent-runtime/tests/setup/cargo"),
        tools.join("cargo"),
    )
    .unwrap();
    runner.tools = Some(tools);
    let shared = dir.path().join("cache");
    std::fs::create_dir_all(shared.join("bin")).unwrap();
    write_executable(&shared.join("bin/agent-runtime-other"), "#!/bin/sh\n");
    // Inside the worktree: the planted cargo runs under the lane's words.
    let log = root.join("cargo.log");
    runner.env.push((
        "AGENT_RUNTIME_CACHE".to_owned(),
        shared.display().to_string(),
    ));
    runner
        .env
        .push(("FAKE_CARGO_LOG".to_owned(), log.display().to_string()));
    let shared_files = |dir: &Path| -> Vec<(String, Vec<u8>)> {
        let mut files: Vec<(String, Vec<u8>)> = std::fs::read_dir(dir.join("bin"))
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (
                    entry.file_name().into_string().unwrap(),
                    std::fs::read(entry.path()).unwrap(),
                )
            })
            .collect();
        files.sort();
        files
    };
    let before = shared_files(&shared);

    let out = runner.op_fleet_env(
        &launch_request("KEN-B", runner.state_dir()),
        &[("FAKE_CARGO_EXIT", "1")],
    );
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["cause"], "runtime-unbuilt", "{report}");
    assert_eq!(
        observation["setup"],
        skills.join("orch/scripts/setup").display().to_string()
    );
    assert!(
        observation["detail"]
            .as_str()
            .is_some_and(|line| line.starts_with("agent-runtime-setup: build-failed status=1 key=")),
        "the setup's own refusal, its first build's: {report}"
    );
    assert_eq!(server.panes().len(), 1, "no window opened");

    let report = effect_report(&runner.op_fleet(&launch_request("KEN-C", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let own = root.join("tmp/runtime-cache");
    let built = |kind: fn(&std::fs::FileType) -> bool| -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(own.join("bin"))
            .unwrap()
            .map(Result::unwrap)
            .filter(|entry| kind(&entry.file_type().unwrap()))
            .map(|entry| entry.file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    };
    let made = built(std::fs::FileType::is_file);
    assert_eq!(
        made.iter()
            .map(|name| name.rsplit_once('-').unwrap().0)
            .collect::<Vec<_>>(),
        ["agent-runtime", "orch-runtime"],
        "both runtimes built into the lane's own cache"
    );
    assert_eq!(
        shared_files(&shared),
        before,
        "the shared cache is as it was"
    );
    let manifests: Vec<String> = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .map(|line| line.rsplit_once(' ').unwrap().1.to_owned())
        .collect();
    let orch = skills.join("orch/runtime/Cargo.toml");
    let agent = skills.join("agent-runtime/runtime/Cargo.toml");
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap();
    assert_eq!(
        manifests
            .iter()
            .map(|m| canonical(Path::new(m)))
            .collect::<Vec<_>>(),
        [canonical(&agent), canonical(&agent), canonical(&orch)],
        "the failed agent-runtime build, then each package's own runtime, agent-runtime first"
    );

    // The shared cache now holds this tree's keys, as the operator's own
    // build leaves them; a lane with a fresh cache of its own builds
    // nothing and links them.
    for name in &made {
        copy_executable(&own.join("bin").join(name), &shared.join("bin").join(name));
    }
    std::fs::remove_dir_all(&own).unwrap();
    let before = shared_files(&shared);
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-D", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        std::fs::read_to_string(&log).unwrap().lines().count(),
        3,
        "nothing built"
    );
    assert!(
        built(std::fs::FileType::is_file).is_empty(),
        "the own cache holds no build"
    );
    for name in &made {
        assert_eq!(
            canonical(&own.join("bin").join(name)),
            canonical(&shared.join("bin").join(name)),
            "{name} runs from the shared cache"
        );
    }
    assert_eq!(
        shared_files(&shared),
        before,
        "the shared cache is as it was"
    );
}

/// A confined lane's tree runs its setup under the lane's words: a setup
/// that writes the home and the shared runtime cache is refused both, and
/// the launch answers `runtime-unbuilt` with no window.
#[test]
#[cfg(target_os = "linux")]
fn a_confined_launch_s_setup_that_writes_the_home_or_the_shared_cache_is_refused_both_and_opens_no_window()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let root = std::fs::canonicalize(runner.state_dir()).unwrap();
    let home = dir.path().join("home");
    let cache = dir.path().join("cache");
    let shared = cache.join("runtimes");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(shared.join("bin")).unwrap();
    let binary = shared.join("bin/agent-runtime-k");
    write_executable(&binary, "#!/bin/sh\n");
    let setup = root.join(".agents/skills/orch/scripts/setup");
    std::fs::create_dir_all(setup.parent().unwrap()).unwrap();
    write_executable(
        &setup,
        format!(
            "#!/bin/sh\nprintf tampered >> '{}'\n: > \"$HOME/y\"\n",
            binary.display()
        ),
    );
    for (name, value) in [
        ("HOME", &home),
        ("XDG_CACHE_HOME", &cache),
        ("AGENT_RUNTIME_CACHE", &shared),
    ] {
        runner
            .env
            .push((name.to_owned(), value.display().to_string()));
    }
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-Y", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["cause"], "runtime-unbuilt", "{report}");
    assert_eq!(
        observation["setup"],
        setup.display().to_string(),
        "{report}"
    );
    assert!(
        observation["status"].as_str().is_some_and(|s| s != "0"),
        "{report}"
    );
    assert!(
        std::fs::symlink_metadata(home.join("y")).is_err(),
        "the setup wrote the home"
    );
    assert_eq!(
        std::fs::read(&binary).unwrap(),
        b"#!/bin/sh\n",
        "the setup wrote the shared cache"
    );
    assert_eq!(server.panes().len(), 1, "no window opened");
}

/// A lane's launch on a computer with no `tmux` refuses `unready` naming
/// its install before its intent persists: the fleet's record holds no
/// intent and no window opens.
#[test]
fn a_launch_with_no_tmux_refuses_before_its_intent_persists() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let path = path_without(&dir.path().join("no-tmux"), &["tmux"]);
    let out = runner.op_fleet_env(
        &launch_request("KEN-R", runner.state_dir()),
        &[("PATH", &path)],
    );
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert_eq!(
        stderr(&out).lines().next(),
        Some("orch-runtime: unready duty=launch program=tmux cause=absent fix=install-tmux")
    );
    assert_eq!(
        runner.fleet()["intents"].as_array().map_or(0, Vec::len),
        0,
        "an intent persisted before the launch asked"
    );
    assert_eq!(server.panes().len(), 1, "no window opened");
}

/// The hosted launch's world: a provider under the project's scripts
/// directory, the ssh client and the stub harness on the runtime's path, and
/// the host's worktree on this disk. The provider is the shipped ssh one
/// ([`HostedLaunch::ssh`]), or, for a kind kendex ships no provider of, one
/// whose answers are planted by argv ([`HostedLaunch::new`]).
struct HostedLaunch {
    runner: Runner,
    scripts: PathBuf,
    tools: PathBuf,
    host_path: PathBuf,
    ssh: Option<SshHost>,
}

/// The name the provider runs under in a world's scripts directory, which
/// its log names as the host.
const PROVIDER: &str = SSH_PROVIDER;

/// `files` written in the checkout `at` and committed there with every
/// other change it holds.
fn commit_files(at: &Path, files: &[(&str, &str)]) {
    for (path, text) in files {
        let file = at.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, text).unwrap();
    }
    git(at, &["add", "."]);
    commit(at, "row");
}

impl HostedLaunch {
    fn new(server: &Server, dir: &Path, record: Value) -> HostedLaunch {
        let mut runner = Runner::new(server, "stub-confirm");
        runner.verify = Some(5);
        runner.init_fleet();
        let scripts = runner
            .state_dir()
            .join(".agents")
            .join("skills")
            .join("orch")
            .join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        std::os::unix::fs::symlink(
            fixtures().join("lane-host").join("lane-host"),
            scripts.join(PROVIDER),
        )
        .unwrap();
        let tools = dir.join("tools");
        std::fs::create_dir_all(&tools).unwrap();
        std::os::unix::fs::symlink(fixtures().join("ssh").join("ssh"), tools.join("ssh")).unwrap();
        std::os::unix::fs::symlink(stub("stub-confirm"), tools.join("claude")).unwrap();
        runner.tools = Some(tools.clone());
        let host_path = dir.join("host-wt");
        std::fs::create_dir_all(&host_path).unwrap();
        let world = HostedLaunch {
            runner,
            scripts,
            tools,
            host_path,
            ssh: None,
        };
        world.plant(record);
        world
    }

    /// The world over the shipped ssh provider ([`SshHost`]) for `KEN-H`,
    /// its log the provider's, the runner's account holding the credentials
    /// a create copies and its path holding the host's `ssh`.
    fn ssh(server: &Server, dir: &Path) -> HostedLaunch {
        let mut runner = Runner::new(server, "stub-confirm");
        runner.verify = Some(5);
        runner.init_fleet();
        let scripts = runner
            .state_dir()
            .join(".agents")
            .join("skills")
            .join("orch")
            .join("scripts");
        let host = SshHost::new(dir, &scripts, "KEN-H");
        std::fs::write(runner.state_dir().join("setup-token"), "claude-token-row\n").unwrap();
        std::fs::write(runner.state_dir().join("auth.json"), "{\"seed\":\"row\"}\n").unwrap();
        runner.tools = Some(host.tools.clone());
        HostedLaunch {
            runner,
            scripts,
            tools: host.tools.clone(),
            host_path: host.worktree(),
            ssh: Some(host),
        }
    }

    /// The shipped provider's host; a world of another kind has none.
    fn ssh_host(&self) -> &SshHost {
        self.ssh
            .as_ref()
            .expect("a world over the shipped ssh provider")
    }

    /// The clone the inventory names.
    fn clone(&self) -> PathBuf {
        self.ssh_host().clone()
    }

    /// The repository the clone is cloned from.
    fn source(&self) -> PathBuf {
        self.ssh_host().source()
    }

    /// The host's home, where the provider's remote shell starts.
    fn home(&self) -> PathBuf {
        self.ssh_host().home()
    }

    /// `path` on the host's disk, relative to the host's home as the
    /// provider's remote shell resolves it; none where it is absent.
    fn on_host(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(self.home().join(path)).ok()
    }

    /// A first launch over the provider, confirmed, then its attempt
    /// retired with no landing: the lane stopped, its tree kept on the host.
    fn launched_and_retired(&self) {
        let first = effect_report(&self.runner.op_fleet(&self.request()));
        assert_eq!(first["intent"]["outcome"], "confirmed", "{first}");
        let retired = effect_report(&self.runner.op_fleet(&json!({
            "op": "close-owned-resources",
            "item": "KEN-H",
            "no_landing": {"reason": "wrong-approach", "source": "overseer", "interrupt": true},
        })));
        assert_eq!(retired["intent"]["outcome"], "confirmed", "{retired}");
    }

    fn host(&self) -> String {
        self.host_path.display().to_string()
    }

    /// The host a hosted record names: the world's provider.
    fn provider(&self) -> String {
        self.scripts.join(PROVIDER).display().to_string()
    }

    /// The provider's answers for one launch of `KEN-H`: the static ssh
    /// line with a local pane, a create naming this disk's worktree, the
    /// worktree's `.git` naming a clone, no marker until the launch puts
    /// one (its second read answers the root), the launch record `record`,
    /// and a host whose Claude settings already consent to the bypass the
    /// default posture launches under.
    fn plant(&self, record: Value) {
        let account = self.runner.state_dir().display().to_string();
        let host = self.host();
        let answers = json!({
            "capabilities": {"stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tpane=local\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\n"},
            format!("create --item KEN-H --repo o/r --harness claude --account {account}"):
                {"stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\n")},
            format!("cat --item KEN-H {host}/.git"): {"stdout": "gitdir: /srv/clone/.git/worktrees/lane\n"},
            "cat --item KEN-H /srv/clone/.git/lane-mail/ken-h": {"exit": 2},
            "cat --item KEN-H /srv/clone/.git/lane-mail/ken-h#2": {"stdout": format!("{host}\n")},
            "touch --item KEN-H": {},
            "put --item KEN-H /srv/clone/.git/lane-mail/ken-h": {},
            "cat --item KEN-H /srv/clone/.git/lane-launch/ken-h.json": {"stdout": record.to_string()},
            "cat --item KEN-H .claude/settings.json": {"stdout": "{\"skipDangerousModePermissionPrompt\": true}\n"},
        });
        std::fs::write(
            self.scripts.join("lane-host.json"),
            serde_json::to_string(&answers).unwrap(),
        )
        .unwrap();
    }

    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.scripts.join("lane-host.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The bytes of each `put` of `path`, in the order the provider took
    /// them.
    fn puts(&self, path: &str) -> Vec<String> {
        let line = format!("ORCH_LANE_HOST={PROVIDER} put --item KEN-H {path}");
        self.calls()
            .iter()
            .enumerate()
            .filter(|(_, call)| **call == line)
            .map(|(at, _)| {
                std::fs::read_to_string(self.scripts.join(format!("lane-host.put.{}", at + 1)))
                    .unwrap()
            })
            .collect()
    }

    fn request(&self) -> Value {
        json!({
            "op": "launch-lane",
            "item": "KEN-H",
            "harness": "claude",
            "mail_root": self.runner.state_dir().display().to_string(),
            "account": self.runner.state_dir().display().to_string(),
            "model": "claude-fable-5-1",
            "effort": "high",
            "class": CLASS,
            "class_reason": CLASS_REASON,
            "host": self.provider(),
            "repo": "o/r",
        })
    }

    /// Interrupt a real hosted launch at its first pane read, with the
    /// provider's worktree created and the window ready to reconcile.
    fn interrupt_launch(&self, server: &Server) {
        let fifo = self.runner.state_dir().join("capture.fifo");
        let mark = self.runner.state_dir().join("capture.mark");
        mkfifo(&fifo);
        let mut child = self.runner.spawn_op_fleet(
            &self.request(),
            &[
                ("TMUX_REAL", &which_tmux()),
                ("TMUX_HOLD_FIFO", fifo.to_str().unwrap()),
                ("TMUX_HOLD_MARK", mark.to_str().unwrap()),
                ("TMUX_HOLD_VERB", "capture-pane"),
            ],
            &fixtures().join("tmux-hold"),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        while !mark.exists() {
            if Instant::now() >= deadline || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                let out = child.wait_with_output().unwrap();
                panic!("launch did not reach its pane read: {}", stderr(&out));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        child.kill().unwrap();
        child.wait().unwrap();
        release_hold(&fifo, Duration::from_secs(10), || {
            self.runner.fleet().to_string()
        });
        let fleet = self.runner.fleet();
        let pane = fleet["intents"][0]["phase"]["pane"].as_str().unwrap();
        server.await_composer(pane);
        assert_eq!(fleet["lanes"][0]["status"], "preparing");
    }

    fn reconcile_launch(&self) -> Value {
        let report = self.runner.reconcile_one();
        assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
        report["lane"].clone()
    }

    fn hosted_mail(&self, args: &[&str]) -> String {
        let file = self.runner.state_dir().join("message.txt");
        std::fs::write(&file, "Which base?\n").unwrap();
        let out = program(lane_mail())
            .current_dir(&self.host_path)
            .args(args)
            .arg("--file")
            .arg(&file)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        String::from_utf8(out.stdout).unwrap()
    }

    fn watch_mail(
        &self,
    ) -> (
        orch_runtime::watch::Produced,
        Vec<orch_runtime::watch::mail::Refused>,
    ) {
        use orch_runtime::watch::mail::{Config, MailDuty};
        use orch_runtime::watch::{Baseline, Tick};

        let state = self.runner.state_dir();
        let mut duty = MailDuty::new(
            orch_runtime::mailbox::Mailbox::new(isolated_program(lane_mail())),
            Config {
                fleet: state.join(agent_runtime::record::FLEET_FILE_NAME),
                common_root: state.to_path_buf(),
                request: state.join("mail-request"),
                snapshots: state.join("mail-snapshots"),
                interval: Duration::ZERO,
                mark_repeat: 1,
                unread: Duration::ZERO,
                tracker_asks: false,
            },
        );
        duty.turn(&Tick {
            duty: orch_runtime::schedule::Duty::Mail,
            now: Instant::now(),
            wall: 1_769_700_000,
            baseline: &Baseline::default(),
            clock: &FakeClock::new(),
        })
        .unwrap()
    }
}

#[test]
fn hosted_mail_root_survives_reconciliation_of_the_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    world.interrupt_launch(&server);
    let lane = world.reconcile_launch();
    assert_eq!(lane["mail_root"], world.host());
    assert_eq!(
        lane["checkout"],
        world.runner.state_dir().display().to_string()
    );
}

#[test]
fn hosted_mail_root_reaches_the_watch_and_context_report() {
    use orch_runtime::watch::{Event, context, hosted};

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    world.interrupt_launch(&server);
    // The provider's disk and the control checkout can have identical
    // path text. Give the preparing record the checkout from that case.
    let mut fleet = world.runner.fleet();
    fleet["lanes"][0]["checkout"] = json!(world.host());
    fleet["lanes"][0]["mail_root"] = json!(world.host());
    world.runner.write_fleet(&fleet);
    let lane = world.reconcile_launch();
    assert_eq!(lane["mail_root"], lane["checkout"]);
    world.hosted_mail(&["notice", "--item", "KEN-H"]);
    std::fs::write(
        world.host_path.join("tmp/lane-mail/KEN-H/context.json"),
        r#"{"harness":"claude","tokens":1234,"window":200000,"at":"2026-01-29T15:20:00Z"}"#,
    )
    .unwrap();

    let (mail, refused) = world.watch_mail();
    let lane = serde_json::from_value(lane).unwrap();
    let caps = hosted::capabilities(&world.scripts, &world.provider()).unwrap();
    let read = context::lane(&lane, caps.files, &world.scripts, 1_769_700_000);
    assert!(refused.is_empty(), "{refused:?}");
    assert!(
        mail.events.iter().any(|e| matches!(
            e, Event::LaneNotice { item, .. } if item == "KEN-H"
        )),
        "mail: {mail:?}; context: {read:?}"
    );
    let context::LaneContext::Own { record, .. } = read else {
        panic!("hosted lane context: {read:?}");
    };
    assert_eq!(record.tokens, Some(1234));
}

#[test]
fn hosted_mail_root_reaches_close_ask_and_last_mail() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    world.interrupt_launch(&server);
    world.reconcile_launch();
    let ask = world.hosted_mail(&["ask", "--item", "KEN-H"]);
    let id = ask.trim().strip_prefix("id=").unwrap();

    let close = terminal_close("KEN-H");
    let blocked = effect_report(&world.runner.op_fleet(&close));
    assert_eq!(
        blocked["intent"]["observation"]["cause"], "ask-unanswered",
        "{blocked}"
    );
    assert_eq!(blocked["intent"]["observation"]["ask"], id);

    world.hosted_mail(&["send", "--item", "KEN-H", "--re", id]);
    world.hosted_mail(&["notice", "--item", "KEN-H"]);
    let closed = effect_report(&world.runner.op_fleet(&close));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    let last = &closed["intent"]["observation"]["mail"];
    assert_eq!(last["envelopes"][0]["kind"], "notice", "{last}");
}

#[test]
fn hosted_mail_root_missing_at_confirmation_is_unread_to_the_watch() {
    use orch_runtime::watch::{Change, hosted};

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    world.interrupt_launch(&server);
    let mut fleet = world.runner.fleet();
    // An older launcher recorded this phase without the provider's root.
    fleet["intents"][0]["phase"]
        .as_object_mut()
        .unwrap()
        .remove("hosted_mail_root");
    world.runner.write_fleet(&fleet);
    let lane = world.reconcile_launch();
    let (mail, refused) = world.watch_mail();
    assert!(
        refused
            .iter()
            .any(|r| r.target == "KEN-H" && r.cause.contains("mail-root-unrecorded")),
        "{refused:?}"
    );
    assert!(
        mail.changes.iter().all(|change| match change {
            Change::Pass { .. } => true,
            Change::Set { identity, .. } | Change::Clear { identity, .. } => identity != "KEN-H",
        }),
        "{mail:?}"
    );
    assert!(lane["mail_root"].is_null(), "{lane}");
    let lane = serde_json::from_value(lane).unwrap();
    assert_eq!(
        hosted::record_left(&world.scripts, &lane),
        hosted::Answer::Unreadable {
            cause: "mail-root-unrecorded".to_owned(),
        }
    );
}

#[test]
fn hosted_mail_root_pending_at_close_is_unread() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::new(&server, dir.path(), json!({}));
    // The provider's create lost its answer, but its listing shows the
    // sandbox stands. Reconcile holds the launch at host-create.
    let fixture = world.scripts.join("lane-host.json");
    let mut answers: Value = serde_json::from_slice(&std::fs::read(&fixture).unwrap()).unwrap();
    let account = world.runner.state_dir().display();
    answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")] =
        json!({"exit": 255});
    answers["list"] = json!({"stdout": "o/r/KEN-H\thosted\t-\tlane.example\n"});
    std::fs::write(&fixture, answers.to_string()).unwrap();
    let launch = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(launch["intent"]["outcome"], "unconfirmed", "{launch}");
    assert_eq!(world.runner.fleet()["lanes"][0]["status"], "preparing");
    let before_close = world.calls().len();
    let closed = effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    let reading = &closed["intent"]["observation"];
    assert_eq!(closed["intent"]["outcome"], "unconfirmed", "{closed}");
    assert_eq!(reading["mail"], "unread", "{reading}");
    let cause = reading["cause"].as_str().unwrap();
    assert!(
        cause.split_whitespace().any(|word| word == "root-pending"),
        "{reading}"
    );
    let checkout = world.runner.state_dir().display().to_string();
    let calls = world.calls();
    assert!(
        calls[before_close..]
            .iter()
            .all(|line| !line.contains(&checkout)),
        "{calls:?}"
    );
}

#[test]
fn a_hosted_launch_runs_the_providers_verbs_and_opens_its_window_over_ssh() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    let clone = world.clone().display().to_string();
    let panes_before = server.panes().len();
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = &report["lane"];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["host"], world.provider());
    assert_eq!(lane["kind"], "ssh");
    assert_eq!(
        lane["mail_root"],
        world.host(),
        "the worktree the host named"
    );
    assert_eq!(
        lane["checkout"],
        world.runner.state_dir().display().to_string(),
        "the checkout the launch ran from stays beside the host's root"
    );
    assert_eq!(lane["window"], "fleet:KEN-H");
    assert_eq!(lane["session_id"], Value::Null);
    assert_eq!(report["intent"]["observation"]["note"], "session-hosted");
    assert_eq!(server.panes().len(), panes_before + 1, "one window opened");
    let account = world.runner.state_dir().display().to_string();
    let host = world.host();
    assert_eq!(
        world.calls(),
        vec![
            format!("ORCH_LANE_HOST={PROVIDER} capabilities"),
            format!(
                "ORCH_LANE_HOST={PROVIDER} create --item KEN-H --repo o/r --harness claude --account {account}"
            ),
            format!("ORCH_LANE_HOST={PROVIDER} cat --item KEN-H /"),
            format!("ORCH_LANE_HOST={PROVIDER} cat --item KEN-H .claude/settings.json"),
            format!("ORCH_LANE_HOST={PROVIDER} cat --item KEN-H {host}/.git"),
            format!("ORCH_LANE_HOST={PROVIDER} cat --item KEN-H {clone}/.git/lane-mail/ken-h"),
            format!(
                "ORCH_LANE_HOST={PROVIDER} cat --item KEN-H {clone}/.git/lane-launch/ken-h.json"
            ),
        ],
        "the provider's verbs in order, each under the record's host: the marker the create wrote is read before the record"
    );
    let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
    assert!(
        ssh.starts_with("-t -o BatchMode=yes -o ConnectTimeout=5 -- lane.example exec env "),
        "the one typed line runs the provider's prefix over a client that asks no prompt and dials within the launch bound: {ssh}"
    );
    assert!(
        ssh.contains(&format!(
            "cd {} && exec",
            agent_runtime::launch::shell_quote(&host)
        )),
        "the harness line enters the worktree the host named: {ssh}"
    );
    assert!(
        !ssh.contains("CLAUDE_CONFIG_DIR"),
        "no account variable reaches the host: {ssh}"
    );
    assert!(
        ssh.contains(&format!(" KENDEX_LANE_ORIGIN={host} "))
            && ssh.contains(" KENDEX_USER_EMAIL= "),
        "the lane words name the worktree on the host and clear the owner's email: {ssh}"
    );
    // The identity the lane runs under is the harness the line started.
    let pid = lane["launch"]["pid"].as_u64().unwrap() as u32;
    assert_eq!(
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .unwrap()
            .trim(),
        "claude"
    );
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

#[test]
fn a_development_root_provider_keeps_hosted_launches_out_of_the_home() {
    for (harness, model, runtime, home, cause) in [
        (
            "claude",
            "claude-fable-5-1",
            Some("/cache/orch-runtime"),
            None,
            None,
        ),
        (
            "claude",
            "claude-fable-5-1",
            None,
            None,
            Some("host-runtime-unbuilt"),
        ),
        (
            "copilot",
            "gpt-6",
            Some("/cache/orch-runtime"),
            None,
            Some("host-create-field-required field=copilot-home"),
        ),
        (
            "pi",
            "github-copilot/gpt-6",
            Some("/cache/orch-runtime"),
            None,
            Some("host-create-field-required field=pi-root"),
        ),
        (
            "copilot",
            "gpt-6",
            Some("/cache/orch-runtime"),
            Some("copilot-home=.copilot"),
            Some("host-create-field-required field=copilot-home"),
        ),
        (
            "pi",
            "github-copilot/gpt-6",
            Some("/cache/orch-runtime"),
            Some("pi-root={pi-root}"),
            Some("compaction-on harness=pi file={pi-root}/settings.json"),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let server = Server::start(&root, "fleet");
        let world = HostedLaunch::new(&server, &root, json!({}));
        let git = root.join("clone/.git").display().to_string();
        let marker = format!("{git}/lane-mail/ken-h");
        let record = format!("{git}/lane-launch/ken-h.json");
        let worktree = world.host();
        let account = world.runner.state_dir().display().to_string();
        let pi_root = root.join("pi-agent");
        let pi_root = pi_root.to_str().unwrap();
        let create_home = home.map_or(String::new(), |field| {
            format!("\t{}", field.replace("{pi-root}", pi_root))
        });
        world.plant_detached("exec bash -c", json!({
            format!("create --item KEN-H --repo o/r --harness {harness} --account {account}"):
                {"stdout": format!("ssh-target=lane.example\tpath={worktree}\tremote-prefix=exec bash -c{create_home}\n")},
            format!("cat --item KEN-H {worktree}/.git"):
                {"stdout": format!("gitdir: {git}/worktrees/lane\n")},
            format!("cat --item KEN-H {marker}"): {"stdout": format!("{worktree}\n")},
            format!("cat --item KEN-H {record}"):
                {"stdout": json!({"identity_file": format!("{git}/lane-host-pid"), "runtime": runtime}).to_string()},
            format!("cat --item KEN-H {pi_root}/."):
                {"exit": 1, "stderr": "cat: Is a directory\n"},
            format!("cat --item KEN-H {pi_root}/settings.json"):
                {"stdout": r#"{"compaction":{"enabled":true}}"#},
            format!("cat --item KEN-H {worktree}/.pi/settings.json"): {"exit": 2},
        }));
        std::fs::write(
            world.scripts.join("development-root"),
            format!("{}\n", root.display()),
        )
        .unwrap();
        std::fs::remove_file(world.tools.join("claude")).unwrap();
        std::os::unix::fs::symlink(
            fixtures().join("stub-record/claude"),
            world.tools.join("claude"),
        )
        .unwrap();
        let mut request = world.request();
        request["harness"] = json!(harness);
        request["model"] = json!(model);
        let report = effect_report(&world.runner.op_fleet(&request));
        let verbs = world.verbs();
        for verb in &verbs {
            if verb == "cat --item KEN-H /"
                || (home.is_some() && verb == "cat --item KEN-H .copilot/.")
            {
                continue;
            }
            if let Some(path) = verb
                .strip_prefix("cat --item KEN-H ")
                .or_else(|| verb.strip_prefix("put --item KEN-H "))
            {
                assert!(Path::new(path).starts_with(&root), "{verb}");
            }
        }
        if let Some(cause) = cause {
            let cause = cause.replace("{pi-root}", pi_root);
            assert_eq!(report["intent"]["outcome"], "failed", "{report}");
            assert!(
                report["intent"]["observation"]["cause"]
                    .as_str()
                    .is_some_and(|observed| observed.starts_with(&cause)),
                "{report}"
            );
            assert!(!world.tools.join("ssh.log").exists());
        } else {
            assert_eq!(
                report["intent"]["observation"]["note"], "session-hosted",
                "{report}"
            );
            let recorded = launch_record_of(&world.host_path);
            let args = recorded["argv"].as_array().unwrap();
            let settings = args
                .iter()
                .enumerate()
                .filter(|(_, arg)| {
                    arg.as_str()
                        .is_some_and(|word| word == "--settings" || word.starts_with("--settings="))
                })
                .collect::<Vec<_>>();
            assert_eq!(settings.len(), 1, "{args:?}");
            assert_eq!(settings[0].1, "--settings");
            assert_eq!(
                serde_json::from_str::<Value>(args[settings[0].0 + 1].as_str().unwrap()).unwrap(),
                json!({"skipDangerousModePermissionPrompt": true, "env": {"DISABLE_AUTO_COMPACT": "1"}})
            );
            assert!(
                verbs.contains(&format!("cat --item KEN-H {record}")),
                "{verbs:?}"
            );
            assert!(
                verbs.contains(&"capture --item KEN-H".to_owned()),
                "{verbs:?}"
            );
        }
    }
}

#[test]
fn a_hosted_launch_preserves_a_failed_boundary_probe_before_account_files() {
    for (harness, model) in [("claude", "claude-fable-5-1"), ("copilot", "gpt-6")] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let world = HostedLaunch::new(&server, dir.path(), json!({}));
        let mut request = world.request();
        let account = world.runner.state_dir().display().to_string();
        request["harness"] = json!(harness);
        request["model"] = json!(model);
        world.plant_detached("exec true", json!({
            format!("create --item KEN-H --repo o/r --harness {harness} --account {account}"):
                {"stdout": format!("ssh-target=lane.example\tpath={}\tremote-prefix=exec true\n", world.host())},
        }));
        let report = effect_report(
            &world
                .runner
                .op_fleet_env(&request, &[("ORCH_LANE_HOST_SHORT_MAX_CALLS", "0")]),
        );
        assert_eq!(report["intent"]["outcome"], "failed", "{report}");
        assert_eq!(
            report["intent"]["observation"]["cause"],
            format!(
                "host-path-probe-failed path=/ host={} cause=setting-invalid name=ORCH_LANE_HOST_SHORT_MAX_CALLS value=0",
                world.provider()
            ),
        );
        assert!(!world.tools.join("ssh.log").exists());
    }
}

/// A create whose line adds `tree=unrebased`, the shipped ssh provider's
/// answer to a relaunch whose tree conflicts with the moved base and is kept
/// on its own head, or a preparing create (`state=preparing`, exit 75, a
/// provider of another kind) whose `wait` answers it: the launch goes on in
/// that tree, its observation names the tree, and the brief closes by
/// telling the lane its restack is its own.
#[test]
fn a_hosted_create_that_kept_the_tree_unrebased_opens_and_tells_the_lane() {
    {
        let case = "on the create line";
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let world = HostedLaunch::ssh(&server, dir.path());
        commit_files(&world.source(), &[("shared.txt", "base\n")]);
        world.launched_and_retired();
        commit_files(&world.host_path, &[("shared.txt", "item\n")]);
        commit_files(&world.source(), &[("shared.txt", "moved base\n")]);
        let brief = dir.path().join("brief.md");
        std::fs::write(&brief, "/orch start KEN-H\n").unwrap();
        let mut request = world.request();
        request["brief_file"] = json!(brief.display().to_string());
        let report = effect_report(&world.runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
        assert_eq!(
            report["lane"]["mail_root"],
            world.host(),
            "{case}: {report}"
        );
        assert_eq!(
            report["intent"]["observation"]["tree"], "unrebased",
            "{case}: {report}"
        );
        assert_eq!(
            std::fs::read_to_string(world.host_path.join("shared.txt")).unwrap(),
            "item\n",
            "{case}: the item's work kept"
        );
        let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
        assert!(
            ssh.contains("not rebased onto the base branch. The restack is yours to run."),
            "{case}: the lane is told its tree is kept unrebased: {ssh}"
        );
        effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    }
    let cases = [(
        "on the wait",
        "\tstate=preparing",
        75,
        Some("tree=unrebased\n"),
    )];
    for (case, fields, exit, waited) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let answers_path = world.scripts.join("lane-host.json");
        let mut answers: Value =
            serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
        let account = world.runner.state_dir().display().to_string();
        answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")] = json!({
            "exit": exit,
            "stdout": format!("ssh-target=lane.example\tpath={}\tremote-prefix=exec bash -c{fields}\n", world.host())
        });
        if let Some(stdout) = waited {
            answers["wait --item KEN-H"] = json!({"stdout": stdout});
        }
        std::fs::write(&answers_path, answers.to_string()).unwrap();
        let brief = dir.path().join("brief.md");
        std::fs::write(&brief, "/orch start KEN-H\n").unwrap();
        let mut request = world.request();
        request["brief_file"] = json!(brief.display().to_string());
        let report = effect_report(&world.runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
        assert_eq!(
            report["lane"]["mail_root"],
            world.host(),
            "{case}: {report}"
        );
        assert_eq!(
            report["intent"]["observation"]["tree"], "unrebased",
            "{case}: {report}"
        );
        assert_eq!(
            world
                .calls()
                .iter()
                .any(|call| call.ends_with(" wait --item KEN-H")),
            waited.is_some(),
            "{case}: a wait is asked only after a preparing create"
        );
        let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
        assert!(
            ssh.contains("not rebased onto the base branch. The restack is yours to run."),
            "{case}: the lane is told its tree is kept unrebased: {ssh}"
        );
        effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    }
}

/// A create that answers keeps its stderr on the launch's observation, line
/// for line, whatever later step fails and through the reconcile and the
/// superseding close of a launch left unconfirmed: a provider's notices of
/// the cross-model reviewer and the login seed it gave, and a transcript
/// too long for the record, kept by its two ends with the count between.
#[test]
fn a_hosted_launch_keeps_the_stderr_of_the_create_that_answered() {
    let cross = "lane-host-daytona: claude-cross-none cause=no-eligible-target";
    let seed = "lane-host-daytona: codex-seed-placed account=a2";
    let notices = format!("{cross}\n\n  {seed}\n");
    let transcript: String = (1..=25).map(|n| format!("npm line {n}\n")).collect();
    let ends: Vec<String> = (1..=10)
        .chain(16..=25)
        .map(|n| format!("npm line {n}"))
        .collect();
    let built = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let unbuilt = json!({});
    let cases = [
        (
            "notices",
            &notices,
            &built,
            "stub-confirm",
            "confirmed",
            json!([cross, seed]),
            Value::Null,
        ),
        (
            "a later step fails",
            &notices,
            &unbuilt,
            "stub-confirm",
            "failed",
            json!([cross, seed]),
            Value::Null,
        ),
        (
            "a transcript",
            &transcript,
            &built,
            "stub-confirm",
            "confirmed",
            json!(ends),
            json!(5),
        ),
        (
            "an unconfirmed launch reconciled",
            &transcript,
            &built,
            "stub-unconfirmed",
            "unconfirmed",
            json!(ends),
            json!(5),
        ),
    ];
    for (case, stderr, record, harness, outcome, lines, elided) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut world = HostedLaunch::new(&server, dir.path(), record.clone());
        if harness != "stub-confirm" {
            world.runner.verify = Some(1);
            let claude = world.tools.join("claude");
            std::fs::remove_file(&claude).unwrap();
            std::os::unix::fs::symlink(stub(harness), &claude).unwrap();
        }
        let answers_path = world.scripts.join("lane-host.json");
        let mut answers: Value =
            serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
        let account = world.runner.state_dir().display().to_string();
        answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")]["stderr"] =
            json!(stderr);
        std::fs::write(&answers_path, answers.to_string()).unwrap();
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        let observation = &report["intent"]["observation"];
        assert_eq!(report["intent"]["outcome"], outcome, "{case}: {report}");
        assert_eq!(observation["create_stderr"], lines, "{case}: {report}");
        assert_eq!(
            observation["create_stderr_elided"], elided,
            "{case}: {report}"
        );
        let launch_id = report["intent"]["id"].clone();
        let launch = |world: &HostedLaunch| -> Value {
            world.runner.fleet()["intents"]
                .as_array()
                .unwrap()
                .iter()
                .find(|i| i["id"] == launch_id)
                .unwrap()
                .clone()
        };
        if outcome == "unconfirmed" {
            let replay = world.runner.reconcile_one();
            assert_eq!(replay["intent"]["id"], launch_id, "{case}: {replay}");
            let kept = &launch(&world)["observation"];
            assert_eq!(kept["create_stderr"], lines, "{case}: {replay}");
            assert_eq!(kept["create_stderr_elided"], elided, "{case}: {replay}");
        }
        let closed = effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
        let ended = launch(&world);
        if outcome == "unconfirmed" {
            assert_eq!(
                ended["observation"]["cause"], "superseded-by-close",
                "{case}: {closed}"
            );
        }
        assert_eq!(
            ended["observation"]["create_stderr"], lines,
            "{case}: {ended}"
        );
        assert_eq!(
            ended["observation"]["create_stderr_elided"], elided,
            "{case}: {ended}"
        );
    }
}

/// Through the runtime's provider call: a launch whose `op` ends inside the
/// provider's create leaves the phase it recorded before it, and the
/// reconcile holds the launch `host-create-unknown`, the lane `preparing`
/// and its slot charged, since the provider may hold a sandbox for it; the
/// next launch request meets that held launch and asks no create; a close
/// supersedes it, its provider close answering the sandbox absent, or
/// confirmed by `list` where it answers any other line, and ends the
/// record. A create the provider's lock then refuses fails
/// `host-create-busy`, the create's own refusal, which charges nothing; the
/// next create reuses what the provider holds and opens.
#[test]
fn a_hosted_create_whose_answer_is_lost_holds_its_launch_until_a_close_confirms_the_sandbox_gone() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    let provider = world.scripts.clone();
    let host = world.provider();
    std::fs::write(world.tools.join("cut"), "").unwrap();
    let calls = || -> Vec<String> {
        std::fs::read_to_string(provider.join("lane-host.log"))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                l.trim_start_matches(&format!("ORCH_LANE_HOST={PROVIDER} "))
                    .to_owned()
            })
            .collect()
    };
    let creates = || calls().iter().filter(|l| l.starts_with("create ")).count();
    let lane = || world.runner.fleet()["lanes"][0].clone();
    let mut request = world.request();
    request["host"] = json!(host);
    let ended = world.runner.op_fleet(&request);
    assert!(!ended.status.success(), "the asking op ended");
    let reconciled = world.runner.reconcile_one();
    assert_ne!(reconciled["intent"]["outcome"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["intent"]["observation"]["note"], "host-create-unknown",
        "{reconciled}"
    );
    assert_eq!(lane()["status"], "preparing");

    let panes_before = server.panes().len();
    let held = reply(&world.runner.op_fleet(&request));
    assert_eq!(held["ok"], true, "{held}");
    assert_eq!(lane()["status"], "preparing", "{held}");
    assert_eq!(
        creates(),
        1,
        "the held launch asks no create: {:?}",
        calls()
    );
    assert_eq!(server.panes().len(), panes_before, "no window opened");

    let closed = effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(lane()["status"], "done");
    let after = calls();
    let close = after.iter().position(|l| l == "close --item KEN-H");
    let absent = closed["intent"]["observation"]["host_close"]
        .as_str()
        .is_some_and(|line| line.starts_with("closed=absent "));
    assert!(
        close.is_some_and(|at| absent || after[at + 1..].iter().any(|l| l == "list")),
        "the provider's close answered absent or confirmed by its list: {closed} {after:?}"
    );

    // The provider's lock beside the clone, held as an earlier create of
    // the item holds it.
    let held = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}.lane-host.lock", world.clone().display()))
        .unwrap();
    held.lock().unwrap();
    let busy = effect_report(&world.runner.op_fleet(&request));
    drop(held);
    assert_eq!(busy["intent"]["outcome"], "failed", "{busy}");
    assert!(
        busy["intent"]["observation"]["cause"]
            .as_str()
            .is_some_and(|c| c.starts_with("host-create-busy ")),
        "the provider's lock is no other item's ownership: {busy}"
    );
    assert_eq!(lane()["status"], "stopped");
    assert!(lane().get("sandbox").is_none(), "{}", lane());
    let again = effect_report(&world.runner.op_fleet(&request));
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
    assert_eq!(creates(), 3, "{:?}", calls());
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

#[test]
fn a_hosted_lane_whose_runtime_is_unbuilt_is_refused_before_any_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    let panes_before = server.panes().len();
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert!(
        report["intent"]["observation"]["cause"]
            .as_str()
            .is_some_and(|c| c.starts_with("host-runtime-unbuilt ")),
        "{report}"
    );
    assert_eq!(report["lane"]["status"], "stopped");
    assert_eq!(server.panes().len(), panes_before, "no window opened");
    assert!(
        world
            .calls()
            .iter()
            .any(|c| c.ends_with("put --item KEN-H /srv/clone/.git/lane-mail/ken-h")),
        "the marker the host lacked was put before the record was read: {:?}",
        world.calls()
    );
    assert!(
        std::fs::metadata(world.tools.join("ssh.log")).is_err(),
        "nothing dialled"
    );
}

/// The capability line of a provider that owns the harness's session on
/// its host (`pane=verb`).
const DETACHED_CAPABILITIES: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tpane=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\n";
/// A Claude screen at its composer, which the one screen judge reads idle.
const CLAUDE_AT_COMPOSER: &str = "❯ do the thing\n● Done.\n\n❯\u{a0}\n  ? for shortcuts\n";
/// The viewer command the planted provider's `viewer-prefix` answers.
const VIEWER_LINE: &str = "fleet-broker attach KEN-H --viewer";

/// The panes of the server that `before` did not list.
fn new_panes(server: &Server, before: &[String]) -> Vec<String> {
    server
        .panes()
        .into_iter()
        .filter(|p| !before.contains(p))
        .collect()
}

/// The first nonempty line `pane` shows once its shell ran a line this row
/// typed after the shell's prompt: anything typed into the pane earlier
/// reaches the shell before the row's line, so a pane nothing was typed
/// into shows the row's line on its first prompt.
fn first_line_read(server: &Server, pane: &str) -> String {
    let screen = |server: &Server| {
        String::from_utf8_lossy(&tmux(&server.socket, &["capture-pane", "-p", "-t", pane]).stdout)
            .into_owned()
    };
    let wait = |drawn: &dyn Fn(&str) -> bool| {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let text = screen(server);
            if text.lines().any(|l| drawn(l.trim())) {
                return text;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "never drawn: {text:?}"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    };
    wait(&|l| l.ends_with(['$', '#']));
    server.send_line(pane, "echo row-42");
    let text = wait(&|l| l == "row-42");
    text.lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or_default()
        .to_owned()
}

/// The value of the window option `name` on `pane`'s window, empty where
/// unset.
fn window_option(server: &Server, pane: &str, name: &str) -> String {
    let out = tmux(&server.socket, &["show-options", "-wv", "-t", pane, name]);
    String::from_utf8_lossy(&out.stdout).trim_end().to_owned()
}

impl HostedLaunch {
    /// The answers of a provider that owns the harness's session: its
    /// capability line, a create whose prefix is `prefix`, the harness read
    /// running at its composer through `status` and `capture`, its stop
    /// confirmed; `more` over them.
    fn plant_detached(&self, prefix: &str, more: Value) {
        let path = self.scripts.join("lane-host.json");
        let mut answers: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let account = self.runner.state_dir().display().to_string();
        answers["capabilities"] = json!({"stdout": DETACHED_CAPABILITIES});
        answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")] = json!({
            "stdout": format!("ssh-target=lane.example\tpath={}\tremote-prefix={prefix}\n", self.host())
        });
        answers["status --item KEN-H --harness claude"] = json!({"stdout": "running\n"});
        answers["capture --item KEN-H"] = json!({"stdout": CLAUDE_AT_COMPOSER});
        answers["stop --item KEN-H --harness claude"] =
            json!({"stdout": "stopped item=KEN-H processes=1\n"});
        answers["viewer-prefix --item KEN-H"] = json!({"stdout": format!("{VIEWER_LINE}\n")});
        for (key, answer) in more.as_object().unwrap() {
            answers[key] = answer.clone();
        }
        std::fs::write(&path, answers.to_string()).unwrap();
    }

    /// The provider's calls with the host's prefix taken off.
    fn verbs(&self) -> Vec<String> {
        self.calls()
            .iter()
            .map(|c| {
                c.trim_start_matches(&format!("ORCH_LANE_HOST={PROVIDER} "))
                    .to_owned()
            })
            .collect()
    }
}

/// A provider that owns the harness's session: the launch runs its prefix
/// over a client with no terminal and its stdin closed, confirms the
/// harness through the provider's `status` and `capture`, then asks its
/// `viewer-prefix` and opens the lane's window on the fleet server for a
/// person to watch: unselected, nothing typed into it, its viewer option
/// the provider's line, its shell holding none of the launching process's
/// variables (a credential among them). The record names that window's
/// pane and server, no process, and says the pane is a viewer's.
#[test]
fn a_pane_verb_launch_runs_the_prefix_detached_and_opens_its_viewer_window_untyped() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    world.plant_detached("exec true", json!({}));
    let panes_before = server.panes();
    let active = |server: &Server| {
        let out = tmux(
            &server.socket,
            &["display-message", "-p", "-t", "=fleet:", "#{window_id}"],
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let active_before = active(&server);
    let report = effect_report(&world.runner.op_fleet_env(
        &world.request(),
        &[("CLAUDE_CODE_OAUTH_TOKEN", "planted-credential")],
    ));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "session-hosted");
    let lane = &report["lane"];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["host"], world.provider());
    assert_eq!(lane["kind"], "ssh");
    assert_eq!(lane["harness"], "claude");
    assert_eq!(
        lane["mail_root"],
        world.host(),
        "the worktree the host named"
    );
    assert_eq!(lane["window"], "fleet:KEN-H", "the lane's name");
    let opened = new_panes(&server, &panes_before);
    assert_eq!(opened.len(), 1, "one window opened: {opened:?}");
    let pane = &opened[0];
    assert_eq!(
        lane["launch"],
        json!({"pane": pane, "server": server.pid, "server_start": server.start, "pid": null, "start": null}),
        "the window's pane and server, no process: {lane}"
    );
    assert_eq!(lane["viewer"], true, "{lane}");
    assert_eq!(
        active(&server),
        active_before,
        "the window opened unselected"
    );
    assert_eq!(
        window_option(&server, pane, "@lane-viewer-command"),
        VIEWER_LINE
    );
    let environ = std::fs::read(format!("/proc/{}/environ", server.pane_pid(pane))).unwrap();
    assert!(
        !environ
            .split(|b| *b == 0)
            .any(|entry| entry.starts_with(b"CLAUDE_CODE_OAUTH_TOKEN=")),
        "the window's shell holds none of the launching process's variables"
    );
    let first = first_line_read(&server, pane);
    assert!(
        first.ends_with("$ echo row-42") || first.ends_with("# echo row-42"),
        "nothing was typed into the window: {first:?}"
    );
    let account = world.runner.state_dir().display().to_string();
    let host = world.host();
    let verbs = world.verbs();
    assert_eq!(
        verbs[verbs.len() - 4..],
        [
            "cat --item KEN-H /srv/clone/.git/lane-launch/ken-h.json".to_owned(),
            "status --item KEN-H --harness claude".to_owned(),
            "capture --item KEN-H".to_owned(),
            "viewer-prefix --item KEN-H".to_owned(),
        ],
        "the launch record verified, the harness read through the provider, then its viewer asked: {verbs:?}"
    );
    assert_eq!(
        verbs[1],
        format!("create --item KEN-H --repo o/r --harness claude --account {account}")
    );
    assert!(!verbs.iter().any(|v| v.starts_with("stop ")), "{verbs:?}");
    let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
    assert_eq!(
        ssh.matches(" -- lane.example ").count(),
        1,
        "one run: {ssh}"
    );
    assert!(
        ssh.starts_with("-T -o BatchMode=yes -o ConnectTimeout=5 -- lane.example exec true "),
        "the prefix runs over a client with no terminal that asks no prompt: {ssh}"
    );
    assert!(
        ssh.contains(&format!(
            "cd {} && exec",
            agent_runtime::launch::shell_quote(&host)
        )),
        "the harness line enters the worktree the host named: {ssh}"
    );
}

/// The provider's `viewer-prefix` answers as the released launcher read
/// them, after the harness is confirmed: exit 2 is a provider with no
/// viewer, the window opened with no option; any other status fails the
/// launch `host-viewer-failed` with the provider's refusal line, the last
/// stderr line carrying `fix=`, and an empty answer or one of two lines
/// fails it `host-viewer-invalid`, each through the provider's stop with no
/// window left. A window whose `new-window` printed it and then failed (an
/// `after-new-window` hook that fails) is closed before the stop, and the
/// launch fails.
#[test]
fn a_pane_verb_viewer_prefix_answers_as_the_release_did() {
    let hook_fails = "set-hook -g after-new-window 'run-shell \"exit 1\"'\n";
    let cases = [
        ("no viewer verb", json!({"exit": 2}), None, None),
        (
            "refused",
            json!({"exit": 1, "stderr": "lane-host-fixture: viewer-window-pending item=KEN-H\nlane-host-fixture: viewer-refused item=KEN-H fix=retry-viewer\n"}),
            None,
            Some(
                "host-viewer-failed item=KEN-H exit=1 lane-host-fixture: viewer-refused item=KEN-H fix=retry-viewer",
            ),
        ),
        (
            "empty",
            json!({"stdout": "\n"}),
            None,
            Some("host-viewer-invalid item=KEN-H"),
        ),
        (
            "two lines",
            json!({"stdout": "fleet-broker attach\nKEN-H\n"}),
            None,
            Some("host-viewer-invalid item=KEN-H"),
        ),
        (
            "window hook failed",
            json!({"stdout": format!("{VIEWER_LINE}\n")}),
            Some(hook_fails),
            Some("viewer-window-failed item=KEN-H cause=tmux-refused"),
        ),
    ];
    for (case, viewer, config, cause) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = match config {
            Some(text) => {
                let path = dir.path().join("tmux.conf");
                std::fs::write(&path, text).unwrap();
                Server::start_with_config(dir.path(), "fleet", &path)
            }
            None => Server::start(dir.path(), "fleet"),
        };
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        world.plant_detached("exec true", json!({"viewer-prefix --item KEN-H": viewer}));
        let panes_before = server.panes();
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        let verbs = world.verbs();
        let opened = new_panes(&server, &panes_before);
        match cause {
            None => {
                assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
                assert_eq!(opened.len(), 1, "{case}: {opened:?}");
                assert_eq!(
                    window_option(&server, &opened[0], "@lane-viewer-command"),
                    "",
                    "{case}: no option set"
                );
                assert!(
                    !verbs.iter().any(|v| v.starts_with("stop ")),
                    "{case}: {verbs:?}"
                );
            }
            Some(cause) => {
                assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
                assert!(
                    report["intent"]["observation"]["cause"]
                        .as_str()
                        .is_some_and(|c| c.starts_with(cause)),
                    "{case}: {report}"
                );
                assert_eq!(
                    verbs.last().map(String::as_str),
                    Some("stop --item KEN-H --harness claude"),
                    "{case}: {verbs:?}"
                );
                assert!(opened.is_empty(), "{case}: no window left: {opened:?}");
                assert_eq!(report["lane"]["status"], "stopped", "{case}");
            }
        }
    }
}

/// From the exec on, a launch that fails asks the provider to stop the
/// harness its prefix may have started, then fails with its cause: a prefix
/// that refused, a harness read exited, a capture that failed, and a
/// harness never read up within the launch bound.
#[test]
fn a_pane_verb_launch_that_fails_after_its_exec_stops_through_its_provider() {
    let cases = [
        (
            "prefix refused",
            "sh -c 'exit 3'",
            json!({}),
            "host-exec-failed ssh exit=3",
        ),
        (
            "harness exited",
            "exec true",
            json!({"status --item KEN-H --harness claude": {"stdout": "exited\n"}}),
            "host-harness-exited",
        ),
        (
            "capture failed",
            "exec true",
            json!({"capture --item KEN-H": {"exit": 1}}),
            "host-capture-failed item=KEN-H",
        ),
        (
            "never up",
            "exec true",
            json!({"capture --item KEN-H": {"stdout": "starting\n"}}),
            "host-harness-unconfirmed",
        ),
    ];
    for (case, prefix, more, cause) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let mut world = HostedLaunch::new(&server, dir.path(), record);
        world.runner.verify = Some(1);
        world.plant_detached(prefix, more);
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        assert!(
            report["intent"]["observation"]["cause"]
                .as_str()
                .is_some_and(|c| c.starts_with(cause)),
            "{case}: {report}"
        );
        let verbs = world.verbs();
        assert_eq!(
            verbs.last().map(String::as_str),
            Some("stop --item KEN-H --harness claude"),
            "{case}: {verbs:?}"
        );
        assert_eq!(report["lane"]["status"], "stopped", "{case}");
        assert_eq!(report["lane"]["sandbox"], "standing", "{case}");
    }
}

/// A stop that gives no answer after a failed exec may leave the harness
/// running: the launch is held at its exec, the lane `preparing` with its
/// slot kept, and the next launch request meets the held launch and creates
/// nothing.
#[test]
fn a_pane_verb_launch_whose_stop_is_unanswered_holds_its_slot() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    world.plant_detached(
        "exec true",
        json!({
            "capture --item KEN-H": {"exit": 1},
            "stop --item KEN-H --harness claude": {"exit": 255},
        }),
    );
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(
        report["intent"]["observation"]["note"], "host-exec-unknown",
        "{report}"
    );
    assert_eq!(world.runner.fleet()["lanes"][0]["status"], "preparing");
    let held = reply(&world.runner.op_fleet(&world.request()));
    assert_eq!(held["ok"], true, "{held}");
    assert_eq!(world.runner.fleet()["lanes"][0]["status"], "preparing");
    let creates = world
        .verbs()
        .iter()
        .filter(|v| v.starts_with("create "))
        .count();
    assert_eq!(
        creates,
        1,
        "the held launch asks no create: {:?}",
        world.verbs()
    );
}

/// A launch whose process ends inside the exec leaves the `host-exec` phase
/// it recorded before it: the reconcile holds the launch, the lane
/// `preparing`, since the prefix may have started the harness.
#[test]
fn a_pane_verb_launch_cut_after_its_exec_is_held_by_the_reconcile() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    // The client's parent is the launch's own process.
    world.plant_detached("kill -KILL $PPID; exec true", json!({}));
    let ended = world.runner.op_fleet(&world.request());
    assert!(!ended.status.success(), "the asking op ended");
    let reconciled = world.runner.reconcile_one();
    assert_ne!(reconciled["intent"]["outcome"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["intent"]["observation"]["note"], "host-exec-unknown",
        "{reconciled}"
    );
    assert_eq!(world.runner.fleet()["lanes"][0]["status"], "preparing");
}

/// The record the launch writes for a provider that owns the harness's
/// session is the one its readers take, whatever its viewer window shows:
/// with that window respawned, as Fleet's hook does while a person watches,
/// into a process named for the harness at an idle composer, `lane status`
/// reads the lane through the provider's `status` and `capture` (working),
/// and the close of its completed item stops the harness through the
/// provider's `stop`, reads it exited there, closes the sandbox, ends the
/// record and closes the viewer window, reading nothing in it as the
/// harness (`stop: window-only`).
#[test]
fn a_pane_verb_lane_launched_is_read_and_closed_through_its_provider() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let mut world = HostedLaunch::new(&server, dir.path(), record);
    let state = world.runner.state_dir().to_path_buf();
    std::os::unix::fs::symlink(
        fixtures().join("linear-fixture/linear.sh"),
        state.join("linear.sh"),
    )
    .unwrap();
    std::fs::write(
        state.join("linear.json"),
        json!({
            "issues bulk-get": {"body": {"issues": {"nodes": [
                {"identifier": "KEN-H", "state": {"type": "completed"}, "description": "", "children": {"nodes": []}}
            ]}}},
            "graphql BoxItem": {"body": {"issue": {"description": "", "state": {"name": "Done", "type": "completed"}}}},
        })
        .to_string(),
    )
    .unwrap();
    world.runner.env.push((
        "OVERSEE_WATCH_TRACKER".to_owned(),
        state.join("linear.sh").display().to_string(),
    ));
    world
        .runner
        .env
        .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
    // The fourth status read is the close's first after its stop; the
    // second capture is `lane status`'s. The lane's mailbox on its host is
    // empty: each of its files is absent there, the host answering.
    let mut answers = json!({
        "status --item KEN-H --harness claude#4": {"stdout": "exited\n"},
        "capture --item KEN-H#2": {"stdout": "❯ do the thing\n✻ Working… (esc to interrupt)\n"},
        "close --item KEN-H": {"stdout": "kept=none\n"},
        "list": {"stdout": ""},
    });
    for file in [
        "to-lane.jsonl",
        "to-overseer.jsonl",
        "to-lane.cursor",
        "to-lane.cursor.lock",
    ] {
        answers[format!(
            "cat --item KEN-H {}/tmp/lane-mail/KEN-H/{file}",
            world.host()
        )] = json!({"exit": 2});
    }
    world.plant_detached("exec true", answers);
    let panes = server.panes();
    let launched = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
    let viewer = new_panes(&server, &panes);
    assert_eq!(viewer.len(), 1, "{viewer:?}");
    let viewer = viewer[0].clone();
    let claude = named_sleep(dir.path(), "claude");
    let respawned = tmux(
        &server.socket,
        &[
            "respawn-pane",
            "-k",
            "-t",
            &viewer,
            &format!("printf '❯\\302\\240\\n'; exec {} 600", claude.display()),
        ],
    );
    assert!(respawned.status.success(), "{}", stderr(&respawned));
    await_named(&server, &viewer, "claude");

    let read_from = world.verbs().len();
    let status = reply(&world.runner.run(&["lane", "status", "--item", "KEN-H"]));
    assert_eq!(status["result"]["state"], "working", "{status}");
    let read = world.verbs()[read_from..].to_vec();
    assert_eq!(
        read[..3],
        [
            "capabilities".to_owned(),
            "status --item KEN-H --harness claude".to_owned(),
            "capture --item KEN-H".to_owned(),
        ],
        "the watch's read through the provider: {read:?}"
    );
    assert!(
        read.contains(&format!(
            "cat --item KEN-H {}/tmp/items/KEN-H/workflow-state-KEN-H.json",
            world.host()
        )),
        "the lane's files read under the worktree the host named: {read:?}"
    );

    let closed = reply(
        &world
            .runner
            .op_fleet(&json!({"op": "close-lane", "item": "KEN-H"})),
    );
    assert_eq!(closed["result"]["word"], "closed", "{closed}");
    assert_eq!(world.runner.fleet()["lanes"][0]["status"], "done");
    let verbs = world.verbs();
    let stop = verbs
        .iter()
        .position(|v| v == "stop --item KEN-H --harness claude")
        .unwrap_or_else(|| panic!("the provider's stop: {verbs:?}"));
    assert!(
        verbs[stop + 1..]
            .iter()
            .any(|v| v == "status --item KEN-H --harness claude")
            && verbs[stop + 1..].iter().any(|v| v == "close --item KEN-H"),
        "read exited, then the sandbox closed: {verbs:?}"
    );
    let close = world.runner.fleet()["intents"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|i| i["op"] == "close-resources")
        .cloned()
        .unwrap_or_else(|| panic!("the close intent: {}", world.runner.fleet()));
    assert_eq!(
        close["observation"]["stop"], "window-only",
        "nothing in the viewer read as the harness: {close}"
    );
    assert_eq!(server.panes(), panes, "the viewer window closed");
}

/// A `pane=verb` lane whose provider reads its harness exited, its item not
/// terminal, is closed on its exit: the record's pane is its viewer's
/// window, which holds no harness, so the close is admitted on the
/// `exited` ground and its effect runs, never refused `lane-live`.
#[test]
fn an_exited_pane_verb_lane_holding_its_viewer_closes_on_its_exit() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let mut world = HostedLaunch::new(&server, dir.path(), record);
    world
        .runner
        .env
        .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
    world.plant_detached(
        "exec true",
        json!({
            "status --item KEN-H --harness claude#2": {"stdout": "exited\n"},
            "close --item KEN-H": {"stdout": "kept=none\n"},
            "list": {"stdout": ""},
        }),
    );
    let launched = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
    assert_eq!(world.runner.fleet()["lanes"][0]["viewer"], true);
    let closed = reply(
        &world
            .runner
            .op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-H"})),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    let close = world.runner.fleet()["intents"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|i| i["op"] == "close-resources")
        .cloned()
        .unwrap_or_else(|| panic!("the close's intent: {}", world.runner.fleet()));
    assert_eq!(close["close"]["ground"], "exited", "{close}");
}

/// A `pane=verb` lane's viewer window runs no harness, so the direct
/// `no-landing` close of a live one stops the hosted harness through its
/// provider: the lane reads `stopped` only once the provider's status reads
/// it exited after its stop; a status still running past the close bound
/// holds with the record as it was; an unanswered ask refuses with nothing
/// stopped; and the recovery close without `interrupt` refuses a working
/// harness `not-idle`, its idle proof read through the provider. A close
/// with no ground ends only a harness read gone: one the provider reads
/// running refuses `lane-live` with nothing stopped.
#[test]
fn a_direct_close_of_a_live_detached_viewer_stops_its_harness_through_its_provider() {
    struct Row {
        name: &'static str,
        /// The `no_landing` disposition's `interrupt`; `None` states no
        /// ground.
        interrupt: Option<bool>,
        exits: bool,
        working: bool,
        ask: bool,
        outcome: &'static str,
        observed: (&'static str, &'static str),
        stops: bool,
    }
    let rows = [
        Row {
            name: "stopped",
            interrupt: Some(true),
            exits: true,
            working: true,
            ask: false,
            outcome: "confirmed",
            observed: ("host_stop", "stopped processes=1"),
            stops: true,
        },
        Row {
            name: "exit unanswered",
            interrupt: Some(true),
            exits: false,
            working: false,
            ask: false,
            outcome: "unconfirmed",
            observed: ("host_stop", "exit-timeout"),
            stops: true,
        },
        Row {
            name: "ask unanswered",
            interrupt: Some(true),
            exits: true,
            working: false,
            ask: true,
            outcome: "failed",
            observed: ("cause", "ask-unanswered"),
            stops: false,
        },
        Row {
            name: "recovery of a working harness",
            interrupt: Some(false),
            exits: true,
            working: true,
            ask: false,
            outcome: "failed",
            observed: ("cause", "not-idle"),
            stops: false,
        },
        Row {
            name: "bare close of a live harness",
            interrupt: None,
            exits: true,
            working: false,
            ask: false,
            outcome: "failed",
            observed: ("cause", "lane-live"),
            stops: false,
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let mut world = HostedLaunch::new(&server, dir.path(), record);
        world
            .runner
            .env
            .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
        let mut answers = json!({});
        for file in [
            "to-lane.jsonl",
            "to-overseer.jsonl",
            "to-lane.cursor",
            "to-lane.cursor.lock",
        ] {
            answers[format!(
                "cat --item KEN-H {}/tmp/lane-mail/KEN-H/{file}",
                world.host()
            )] = json!({"exit": 2});
        }
        if row.ask {
            // The lane's ask as its mailbox writes it, read back through the
            // provider from the lane's worktree on its host.
            let mail = dir.path().join("mail");
            std::fs::create_dir_all(&mail).unwrap();
            git_checkout(&mail);
            std::fs::write(mail.join("ask.txt"), "which base").unwrap();
            let out = program(lane_mail())
                .current_dir(&mail)
                .args(["ask", "--item", "KEN-H", "--file"])
                .arg(mail.join("ask.txt"))
                .output()
                .unwrap();
            assert!(out.status.success(), "{}", stderr(&out));
            for file in ["to-overseer.jsonl", "to-overseer.jsonl.numbering"] {
                let written = mail.join("tmp/lane-mail/KEN-H").join(file);
                answers[format!(
                    "cat --item KEN-H {}/tmp/lane-mail/KEN-H/{file}",
                    world.host()
                )] = match std::fs::read_to_string(written) {
                    Ok(text) => json!({"stdout": text}),
                    Err(_) => json!({"exit": 2}),
                };
            }
        }
        world.plant_detached("exec true", answers.clone());
        let panes = server.panes();
        let launched = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(
            launched["intent"]["outcome"], "confirmed",
            "{}: {launched}",
            row.name
        );
        assert_eq!(world.runner.fleet()["lanes"][0]["viewer"], true);
        let viewer = new_panes(&server, &panes);
        assert_eq!(viewer.len(), 1, "{}: {viewer:?}", row.name);

        // The harness reads running at the close's first read, then exited at
        // every read after the provider's stop where the row's provider
        // answers it.
        let status = "status --item KEN-H --harness claude";
        let from = world.verbs().len();
        let read = world.verbs().iter().filter(|v| *v == status).count();
        let mut answers = answers;
        answers[format!("{status}#{}", read + 1)] = json!({"stdout": "running\n"});
        if row.exits {
            for nth in read + 2..read + 12 {
                answers[format!("{status}#{nth}")] = json!({"stdout": "exited\n"});
            }
        }
        if row.working {
            answers["capture --item KEN-H"] =
                json!({"stdout": "❯ do the thing\n✻ Working… (esc to interrupt)\n"});
        }
        world.plant_detached("exec true", answers);

        let mut request = json!({"op": "close-owned-resources", "item": "KEN-H"});
        if let Some(interrupt) = row.interrupt {
            request["no_landing"] =
                json!({"reason": "model-switch", "source": "overseer", "interrupt": interrupt});
        }
        let out = world.runner.op_fleet(&request);
        let report = effect_report(&out);
        let verbs = world.verbs()[from..].to_vec();
        assert_eq!(
            report["intent"]["outcome"], row.outcome,
            "{}: {report}\n{verbs:?}",
            row.name
        );
        assert_eq!(
            report["intent"]["observation"][row.observed.0], row.observed.1,
            "{}: {report}\n{verbs:?}",
            row.name
        );
        let stop = verbs
            .iter()
            .position(|v| v == "stop --item KEN-H --harness claude");
        assert_eq!(stop.is_some(), row.stops, "{}: {verbs:?}", row.name);
        assert!(
            !verbs.iter().any(|v| v == "close --item KEN-H"),
            "{}: the sandbox is the lane's still: {verbs:?}",
            row.name
        );
        if let Some(stop) = stop {
            assert!(
                verbs[stop + 1..].iter().any(|v| v == status),
                "{}: the exit read after the stop: {verbs:?}",
                row.name
            );
        }
        let confirmed = row.outcome == "confirmed";
        assert_eq!(
            world.runner.fleet()["lanes"][0]["status"],
            if confirmed { "stopped" } else { "running" },
            "{}: {}",
            row.name,
            world.runner.fleet()
        );
        assert_eq!(
            server.panes().len(),
            if confirmed {
                panes.len()
            } else {
                panes.len() + 1
            },
            "{}: the viewer closes only on a confirmed stop",
            row.name
        );
    }
}

/// A second launch on the record the first left: the provider is asked to
/// reuse the worktree it holds, and the lane opens in the tree the first
/// launch's work stands in.
#[test]
fn a_hosted_relaunch_asks_the_provider_to_reuse_its_worktree() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    world.launched_and_retired();
    commit_files(&world.host_path, &[("item.txt", "item\n")]);
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        world
            .calls()
            .iter()
            .any(|c| c.contains(" create ") && c.ends_with(" --relaunch")),
        "the standing record's worktree is reused: {:?}",
        world.calls()
    );
    // The shipped provider declares `park=none`: its sandbox never stops.
    let calls = world.calls();
    assert!(
        !calls.iter().any(|c| {
            c.contains(" stop-sandbox ") || c.ends_with(" list") || c.contains(" start ")
        }),
        "a park=none provider is asked neither check, list nor start: {calls:?}",
    );
    assert_eq!(report["lane"]["mail_root"], world.host(), "{report}");
    assert_eq!(
        std::fs::read_to_string(world.host_path.join("item.txt")).unwrap(),
        "item\n",
        "the first launch's work stands in the reused tree"
    );
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

/// A relaunch of a lane whose last pause is its park brings its stopped
/// sandbox back through the provider's start before `create --relaunch`;
/// a start the provider refuses, or answers without its `sandbox-started`
/// line, fails the launch with no create asked. A start that answers the
/// item unknown, a sandbox the provider no longer holds, creates a fresh
/// one: `create` with no `--relaunch`, the outcome naming the start's
/// answer and its route fresh for the sandbox absent.
#[test]
fn a_parked_hosted_relaunch_starts_its_sandbox_before_its_create() {
    for (case, start, outcome) in [
        (
            "started",
            json!({"stdout": "sandbox-started item=KEN-H\n"}),
            "confirmed",
        ),
        ("refused", json!({"exit": 1}), "failed"),
        ("unparsed", json!({"stdout": "started\n"}), "failed"),
        (
            "item unknown",
            json!({"exit": 1, "stderr": "lane-host-daytona: item-unknown item=KEN-H fix=\"lane-host-daytona list\"\n"}),
            "confirmed",
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let mut fleet = world.runner.fleet();
        let mut prior = lane("KEN-H", "parked", &world.runner, Value::Null);
        prior["host"] = json!(world.provider());
        prior["kind"] = json!("ssh");
        prior["launched_at"] = json!("2026-01-29T15:20:00Z");
        prior["parked"] =
            json!({"repo": "o/r", "pr": 7, "head": "h2", "at": "2026-01-29T15:40:00Z"});
        fleet["lanes"] = json!([prior]);
        world.runner.write_fleet(&fleet);
        let account = world.runner.state_dir().display().to_string();
        let host = world.host();
        let mut answers: Value = serde_json::from_str(
            &std::fs::read_to_string(world.scripts.join("lane-host.json")).unwrap(),
        )
        .unwrap();
        let line = answers["capabilities"]["stdout"]
            .as_str()
            .unwrap()
            .to_owned();
        answers["capabilities"]["stdout"] = json!(line.replace("park=none", "park=verb"));
        answers["start --item KEN-H"] = start;
        let created = json!({"stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\n")});
        let create = format!("create --item KEN-H --repo o/r --harness claude --account {account}");
        answers[format!("{create} --relaunch")] = created.clone();
        if case == "item unknown" {
            answers[create.as_str()] = created;
        }
        std::fs::write(
            world.scripts.join("lane-host.json"),
            serde_json::to_string(&answers).unwrap(),
        )
        .unwrap();
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(report["intent"]["outcome"], outcome, "{case}: {report}");
        let calls = world.calls();
        let at = |verb: &str| {
            calls
                .iter()
                .position(|c| c.contains(&format!(" {verb} --item KEN-H")))
        };
        assert!(at("start").is_some(), "{case}: {calls:?}");
        let fresh = calls
            .iter()
            .any(|c| c.contains(" create --item KEN-H") && !c.ends_with(" --relaunch"));
        assert_eq!(fresh, case == "item unknown", "{case}: {calls:?}");
        let observation = &report["intent"]["observation"];
        match outcome {
            "confirmed" => {
                assert!(at("start") < at("create"), "{case}: {calls:?}");
                if case == "item unknown" {
                    assert_eq!(
                        (
                            &observation["host_start"],
                            &observation["route"],
                            &observation["route_cause"]
                        ),
                        (
                            &json!("item-unknown"),
                            &json!("fresh"),
                            &json!("sandbox-absent")
                        ),
                        "{case}: {report}"
                    );
                } else {
                    assert_eq!(observation["host_start"], Value::Null, "{case}: {report}");
                }
            }
            _ => {
                assert_eq!(at("create"), None, "{case}: no create: {calls:?}");
                assert!(
                    report["intent"]["observation"]["cause"]
                        .as_str()
                        .is_some_and(|c| c.starts_with("host-start-failed ")),
                    "{case}: {report}"
                );
                if case == "refused" {
                    assert_eq!(
                        report["intent"]["observation"]["cause"],
                        "host-start-failed start exit=1 stderr=empty",
                        "{case}: a start refused with no stderr says so"
                    );
                }
            }
        }
        effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    }
}

/// A lane that handed off is closed on the `no_landing` ground, which keeps
/// its sandbox, then relaunched over its record. On a `park=verb` provider,
/// where its list still names the sandbox, its start takes it up before
/// `create --relaunch`, which the provider refuses as another session's
/// (`item-owned`) over a standing sandbox no start took up. A list naming
/// none asks no start, and a list that fails refuses with nothing asked of
/// the sandbox. The `park=none` relaunch is
/// `a_hosted_relaunch_asks_the_provider_to_reuse_its_worktree`.
#[test]
fn a_relaunch_after_a_no_landing_close_starts_the_standing_sandbox_before_its_create() {
    struct Row {
        name: &'static str,
        list: Value,
        outcome: &'static str,
        starts: bool,
        creates: bool,
    }
    let rows = [
        Row {
            name: "standing",
            list: json!({"stdout": "o/r/KEN-H\tstarted\t3m\tlane-o-r-ken-h\n"}),
            outcome: "confirmed",
            starts: true,
            creates: true,
        },
        Row {
            name: "gone",
            list: json!({"stdout": ""}),
            outcome: "confirmed",
            starts: false,
            creates: true,
        },
        Row {
            name: "list failed",
            list: json!({"exit": 1, "stderr": "lane-host-fixture: list-failed\n"}),
            outcome: "failed",
            starts: false,
            creates: false,
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let mut world = HostedLaunch::new(&server, dir.path(), record);
        world
            .runner
            .env
            .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
        let mut answers = json!({
            "capabilities": {"stdout": DETACHED_CAPABILITIES.replace("park=none", "park=verb")},
        });
        for file in [
            "to-lane.jsonl",
            "to-overseer.jsonl",
            "to-lane.cursor",
            "to-lane.cursor.lock",
        ] {
            answers[format!(
                "cat --item KEN-H {}/tmp/lane-mail/KEN-H/{file}",
                world.host()
            )] = json!({"exit": 2});
        }
        world.plant_detached("exec true", answers.clone());
        let launched = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(
            launched["intent"]["outcome"], "confirmed",
            "{}: {launched}",
            row.name
        );

        // The recovery close: the harness reads exited after the provider's
        // stop, and the sandbox is kept.
        let status = "status --item KEN-H --harness claude";
        let reads = |world: &HostedLaunch| world.verbs().iter().filter(|v| *v == status).count();
        let read = reads(&world);
        answers[format!("{status}#{}", read + 1)] = json!({"stdout": "running\n"});
        for nth in read + 2..read + 12 {
            answers[format!("{status}#{nth}")] = json!({"stdout": "exited\n"});
        }
        world.plant_detached("exec true", answers.clone());
        let closed = effect_report(&world.runner.op_fleet(&json!({
            "op": "close-owned-resources",
            "item": "KEN-H",
            "no_landing": {"reason": "handoff", "source": "overseer", "interrupt": true},
        })));
        assert_eq!(
            closed["intent"]["outcome"], "confirmed",
            "{}: {closed}",
            row.name
        );
        assert_eq!(
            world.runner.fleet()["lanes"][0]["sandbox"],
            "standing",
            "{}",
            row.name
        );

        // The relaunch over the kept sandbox.
        let from = world.verbs().len();
        let read = reads(&world);
        for nth in read + 1..read + 12 {
            answers[format!("{status}#{nth}")] = json!({"stdout": "running\n"});
        }
        let account = world.runner.state_dir().display().to_string();
        let created = json!({
            "stdout": format!("ssh-target=lane.example\tpath={}\tremote-prefix=exec true\n", world.host())
        });
        answers[format!(
            "create --item KEN-H --repo o/r --harness claude --account {account} --relaunch"
        )] = json!({
            "after": "start --item KEN-H",
            "unmet": {"exit": 75},
            "stdout": created["stdout"],
        });
        if !row.starts {
            answers[format!(
                "create --item KEN-H --repo o/r --harness claude --account {account} --relaunch"
            )] = created;
        }
        answers["list"] = row.list;
        answers["start --item KEN-H"] = json!({"stdout": "sandbox-started item=KEN-H\n"});
        answers["cat --item KEN-H /srv/clone/.git/lane-mail/ken-h"] =
            json!({"stdout": format!("{}\n", world.host())});
        world.plant_detached("exec true", answers);
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        let verbs = world.verbs()[from..].to_vec();
        assert_eq!(
            report["intent"]["outcome"], row.outcome,
            "{}: {report}\n{verbs:?}",
            row.name
        );
        let at = |verb: &str| verbs.iter().position(|v| v.starts_with(verb));
        assert!(at("list").is_some(), "{}: {verbs:?}", row.name);
        assert_eq!(
            at("start ").is_some(),
            row.starts,
            "{}: {verbs:?}",
            row.name
        );
        assert_eq!(
            at("create ").is_some(),
            row.creates,
            "{}: {verbs:?}",
            row.name
        );
        if row.starts {
            assert!(at("start ") < at("create "), "{}: {verbs:?}", row.name);
        }
        if !row.creates {
            assert!(
                report["intent"]["observation"]["cause"]
                    .as_str()
                    .is_some_and(|c| c.starts_with("host-list-failed ")),
                "{}: {report}",
                row.name
            );
            assert_eq!(
                world.runner.fleet()["lanes"][0]["sandbox"],
                "standing",
                "{}: the kept sandbox still holds its slot",
                row.name
            );
        }
    }
}

/// A failed host call's cause is the provider's refusal: the last stderr
/// line carrying `fix=`, else its first line, never a notice printed before
/// or after a `fix=` refusal, and `stderr=empty` where the provider printed
/// nothing.
#[test]
fn a_failed_host_create_records_the_provider_s_refusal_line() {
    let notices = "lane-host-fixture: gh-token-rotated lane=lane-ken-h source=app\n\
                   lane-host-fixture: credit-low balance=3\n";
    let refusal = "lane-host-fixture: create-preparation-failed item=KEN-H fix=retry-create";
    for (case, stderr, line) in [
        ("refusal last", format!("{notices}{refusal}\n"), refusal),
        (
            "refusal before a trailing notice",
            format!("{notices}{refusal}\nlane-host-fixture: cleanup-done\n"),
            refusal,
        ),
        (
            "no fix= line",
            notices.to_owned(),
            "lane-host-fixture: gh-token-rotated lane=lane-ken-h source=app",
        ),
        ("stderr empty", String::new(), "stderr=empty"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let account = world.runner.state_dir().display().to_string();
        let path = world.scripts.join("lane-host.json");
        let mut answers: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")] =
            json!({"exit": 1, "stderr": stderr});
        std::fs::write(&path, serde_json::to_string(&answers).unwrap()).unwrap();
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        assert_eq!(
            report["intent"]["observation"]["cause"],
            format!("host-create-failed create exit=1 {line}"),
            "{case}: {report}"
        );
    }
}

/// The refusal of the shipped ssh provider's failed step after its sync-base
/// step is the cause a failed relaunch records, not the sync output printed
/// before it: a clone whose lane-marker is not executable fails the relaunch
/// `host-create-failed` naming the provider's own `marker-script-missing`
/// and the marker's path, and one whose agent-runtime setup refuses with its
/// keyed line, which carries no `fix=`, names that line.
#[test]
fn a_shipped_ssh_relaunch_records_the_failed_step_s_refusal_over_its_sync_output() {
    use std::os::unix::fs::PermissionsExt;
    let marker = ".agents/skills/orch/scripts/lane-marker";
    let setup = ".agents/skills/agent-runtime/scripts/setup";
    for case in ["marker", "setup"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let world = HostedLaunch::ssh(&server, dir.path());
        world.launched_and_retired();
        let clone = world.clone();
        // The sync-base step refuses a tracked change, so the clone reads
        // past each planted one.
        let refusal = if case == "marker" {
            git(&clone, &["config", "core.fileMode", "false"]);
            std::fs::set_permissions(clone.join(marker), std::fs::Permissions::from_mode(0o644))
                .unwrap();
            format!(
                "lane-host-ssh: marker-script-missing path={}",
                clone.join(marker).display()
            )
        } else {
            git(&clone, &["update-index", "--skip-worktree", setup]);
            std::fs::write(
                clone.join(setup),
                "#!/bin/sh\nprintf 'agent-runtime-setup: build-failed status=101 key=k\\n' >&2\nexit 1\n",
            )
            .unwrap();
            "agent-runtime-setup: build-failed status=101 key=k".to_owned()
        };
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        let cause = format!(
            "host-create-failed create exit=1 lane-host-ssh: remote-failed target=lane.example exit=1 cause={refusal} fix="
        );
        assert!(
            report["intent"]["observation"]["cause"]
                .as_str()
                .is_some_and(|recorded| recorded.starts_with(&cause)),
            "{case}: {report}"
        );
        effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
    }
}

/// A parked relaunch stopped part way keeps its slot until a close confirms
/// its sandbox gone: one whose provider started the sandbox and then
/// refused the create fails with the record `stopped`, the sandbox noted
/// standing and the account still charged; its close asks the provider's
/// close, confirmed by `list`, and releases the charge. One whose process
/// ended inside the start leaves the `host-start` phase it recorded before
/// it, which the reconcile holds: the lane stays `preparing`.
#[test]
fn a_part_way_hosted_relaunch_keeps_its_slot_until_a_close_confirms_its_sandbox_gone() {
    use orch_runtime::watch::hosted::{self, Answer};

    for case in ["started, its create refused", "cut inside its start"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let mut fleet = world.runner.fleet();
        let mut prior = lane("KEN-H", "parked", &world.runner, Value::Null);
        prior["host"] = json!(world.provider());
        prior["kind"] = json!("ssh");
        prior["checkout"] = json!(world.runner.state_dir().display().to_string());
        prior["mail_root"] = json!(world.host());
        prior["mail_root_confirmed"] = json!(true);
        prior["launched_at"] = json!("2026-01-29T15:20:00Z");
        prior["parked"] =
            json!({"repo": "o/r", "pr": 7, "head": "h2", "at": "2026-01-29T15:40:00Z"});
        fleet["lanes"] = json!([prior]);
        world.runner.write_fleet(&fleet);
        let account = world.runner.state_dir().display().to_string();
        let canon = std::fs::canonicalize(world.runner.state_dir())
            .unwrap()
            .display()
            .to_string();
        let mut answers: Value = serde_json::from_str(
            &std::fs::read_to_string(world.scripts.join("lane-host.json")).unwrap(),
        )
        .unwrap();
        // The provider is asked directly here, so its parent is the asker.
        answers["start --item KEN-H"] = if case == "cut inside its start" {
            answers[format!("cat --item KEN-H {account}/tmp/lane-status-KEN-H.md")] =
                json!({"stdout": "Step: start\n"});
            json!({"kill_ancestor": 1})
        } else {
            json!({"stdout": "sandbox-started item=KEN-H\n"})
        };
        answers[format!(
            "create --item KEN-H --repo o/r --harness claude --account {account} --relaunch"
        )] = json!({"exit": 1, "stderr": "lane-host-ssh: create-failed item=KEN-H\n"});
        answers["close --item KEN-H"] = json!({"stdout": "kept=none\n"});
        answers["list"] = json!({"stdout": ""});
        std::fs::write(
            world.scripts.join("lane-host.json"),
            serde_json::to_string(&answers).unwrap(),
        )
        .unwrap();
        let charges = || {
            reply(&world.runner.run(&["lane", "charges", "--fleet"]))["result"]["charges"].clone()
        };
        let lane_now = || world.runner.fleet()["lanes"][0].clone();
        if case == "cut inside its start" {
            let ended = world.runner.op_fleet(&world.request());
            assert!(!ended.status.success(), "{case}: the asking op ended");
            let reconciled = world.runner.reconcile_one();
            assert_ne!(
                reconciled["intent"]["outcome"], "failed",
                "{case}: {reconciled}"
            );
            assert_eq!(
                reconciled["intent"]["observation"]["note"], "host-start-unknown",
                "{case}: {reconciled}"
            );
            assert_eq!(lane_now()["status"], "preparing", "{case}");
            let replacement = serde_json::from_value(lane_now()).unwrap();
            assert_eq!(
                hosted::status_file(&world.scripts, &replacement),
                Answer::Unreadable {
                    cause: "root-pending".to_owned(),
                },
                "{case}"
            );
            assert_eq!(charges(), json!({ canon.clone(): 1 }), "{case}");
            continue;
        }
        let report = effect_report(&world.runner.op_fleet(&world.request()));
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        assert_eq!(lane_now()["status"], "stopped", "{case}");
        assert_eq!(lane_now()["sandbox"], "standing", "{case}: {}", lane_now());
        assert_eq!(charges(), json!({ canon.clone(): 1 }), "{case}");
        let closed = effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
        assert_eq!(closed["intent"]["outcome"], "confirmed", "{case}: {closed}");
        assert!(
            world.calls().iter().any(|c| c.ends_with(" list")),
            "{case}: {:?}",
            world.calls()
        );
        assert!(
            lane_now().get("sandbox").is_none(),
            "{case}: {}",
            lane_now()
        );
        assert_eq!(charges(), json!({}), "{case}");
    }
}

/// An accountless Claude lane runs under the operator's own config dir,
/// which the launch never writes a trust pair into: only a named account's
/// config is the launch's to prepare.
#[test]
fn an_accountless_claude_launch_writes_no_trust_pair_into_the_operator_s_home() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mut request = launch_request("KEN-A", runner.state_dir());
    request.as_object_mut().unwrap().remove("account");
    let home_word = home.display().to_string();
    let report = effect_report(&runner.op_fleet_env(&request, &[("HOME", home_word.as_str())]));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        std::fs::symlink_metadata(home.join(".claude")).is_err(),
        "nothing written under the operator's config dir: {report}"
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-A")));
}

/// The `kendex` fixture first on a row's tools path, answering `hooks-off`
/// with `answer`; its calls are read back from `kendex.log` beside it.
fn plant_hooks_off(tools: &Path, answer: Value) {
    let link = tools.join("kendex");
    if std::fs::symlink_metadata(&link).is_err() {
        std::os::unix::fs::symlink(fixtures().join("kendex-hooks-off/kendex"), &link).unwrap();
    }
    std::fs::write(tools.join("hooks-off.json"), answer.to_string()).unwrap();
    let _ = std::fs::remove_file(tools.join("kendex.log"));
}

/// The three lane-mail hooks registered under `dir`.
fn plant_copilot_hooks(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    for name in ["lane-mail-check", "lane-mail-compact", "lane-mail-start"] {
        for ext in ["sh", "json"] {
            std::fs::write(dir.join(format!("{name}.{ext}")), "{}\n").unwrap();
        }
    }
}

/// A Copilot lane launches only where its turn-end, compaction and start
/// hooks run: registered in its worktree or its home, and switched off by
/// no settings layer, which `kendex hooks-off` judges. Each refusal comes
/// before any window.
#[test]
fn a_copilot_lane_launches_only_where_its_lane_mail_hooks_run() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    runner.tools = Some(tools.clone());
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let account = dir.path().join("copilot-account");
    std::fs::create_dir_all(&account).unwrap();
    let binaries = format!(
        "copilot={}",
        fixtures().join("stub-record").join("copilot").display()
    );
    let home_word = home.display().to_string();
    let env = [
        ("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str()),
        ("HOME", home_word.as_str()),
    ];
    let answer = |stdout: &str| json!({"stdout": stdout});
    type Case<'a> = (&'a str, Option<bool>, Value, Option<&'a str>);
    let cases: [Case; 8] = [
        (
            "KEN-C1",
            None,
            answer(r#"{"switched_off_by": null}"#),
            Some("no-context-hooks"),
        ),
        (
            "KEN-C2",
            Some(true),
            answer(r#"{"switched_off_by": "/x/.copilot/settings.json"}"#),
            Some("hooks-disabled file=/x/.copilot/settings.json"),
        ),
        (
            "KEN-C3",
            Some(false),
            json!({"exit": 2, "stderr": "kendex: settings unreadable\n"}),
            Some("hooks-unjudged exit=2"),
        ),
        (
            "KEN-C4",
            Some(true),
            answer("[]"),
            Some("hooks-unjudged exit=answer"),
        ),
        (
            "KEN-C5",
            Some(false),
            answer(r#"{"switched_off_by": null}"#),
            None,
        ),
        (
            "KEN-C6",
            None,
            answer(r#"{"switched_off_by": null}"#),
            Some("no-context-hooks"),
        ),
        (
            "KEN-C7",
            Some(true),
            answer(r#"{"switched_off_by": null}"#),
            None,
        ),
        (
            "KEN-C8",
            Some(false),
            answer(r#"{"switched_off_by": null}"#),
            None,
        ),
    ];
    for (item, in_worktree, kendex, refused) in cases {
        let worktree = dir.path().join(item);
        std::fs::create_dir_all(&worktree).unwrap();
        let init = program("git")
            .args(["-C", &worktree.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(init.status.success(), "{}", stderr(&init));
        fleet_origin(&[runner.state_dir(), &worktree]);
        let _ = std::fs::remove_dir_all(account.join("hooks"));
        let scope = match in_worktree {
            Some(true) => Some(worktree.join(".github/hooks")),
            Some(false) => Some(account.join("hooks")),
            None => None,
        };
        if let Some(scope) = &scope {
            plant_copilot_hooks(scope);
        }
        // One hook alone in the worktree is no scope the session runs.
        if item == "KEN-C6" {
            let half = worktree.join(".github/hooks");
            std::fs::create_dir_all(&half).unwrap();
            for ext in ["sh", "json"] {
                std::fs::write(half.join(format!("lane-mail-check.{ext}")), "{}\n").unwrap();
            }
        }
        // Both scopes hold the three: the worktree's registrations are the
        // ones judged.
        if item == "KEN-C7" {
            plant_copilot_hooks(&account.join("hooks"));
        }
        plant_hooks_off(&tools, kendex);
        let mut request = launch_request(item, &worktree);
        request["harness"] = json!("copilot");
        request["account"] = json!(account.display().to_string());
        // No account named: the home is the one the launching environment
        // names in `COPILOT_HOME`.
        let account_word = account.display().to_string();
        let mut env = env.to_vec();
        if item == "KEN-C8" {
            request.as_object_mut().unwrap().remove("account");
            env.push(("COPILOT_HOME", account_word.as_str()));
        }
        let panes_before = server.panes().len();
        let report = effect_report(&runner.op_fleet_env(&request, &env));
        let calls = std::fs::read_to_string(tools.join("kendex.log")).unwrap_or_default();
        match refused {
            Some(reason) => {
                assert_eq!(report["intent"]["outcome"], "failed", "{item}: {report}");
                let cause = report["intent"]["observation"]["cause"]
                    .as_str()
                    .unwrap_or("");
                assert!(
                    cause.starts_with(&format!(
                        "unsupported-for-oversee harness=copilot reason={reason}"
                    )),
                    "{item}: {report}"
                );
                assert_eq!(server.panes().len(), panes_before, "{item}: no window");
            }
            None => {
                assert_ne!(report["intent"]["outcome"], "failed", "{item}: {report}");
                // The harness started in its window: its record stands.
                launch_record_of(&worktree);
            }
        }
        match &scope {
            None => assert_eq!(calls, "", "{item}: no hooks, nothing to ask"),
            Some(scope) => {
                let documents: Vec<String> =
                    ["lane-mail-check", "lane-mail-compact", "lane-mail-start"]
                        .iter()
                        .map(|name| format!("--hook-document {}/{name}.json", scope.display()))
                        .collect();
                assert_eq!(
                    calls,
                    format!(
                        "hooks-off --copilot-home {} --project {} {}\n",
                        account.display(),
                        worktree.display(),
                        documents.join(" ")
                    ),
                    "{item}: the home, the worktree and the scope's registrations"
                );
            }
        }
    }
}

/// The record tells a reader whether a policy block can take allow-all from
/// the lane. Through the real `launch-lane`: a Copilot lane under the
/// bypass posture records `allow_all: true` and its line carries the grant;
/// one whose request narrows the permission records `false`, its line the
/// narrower word and no grant; a Claude lane records none.
#[test]
fn a_copilot_lanes_record_says_whether_its_line_grants_allow_all() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    runner.tools = Some(tools.clone());
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let account = dir.path().join("copilot-account");
    plant_copilot_hooks(&account.join("hooks"));
    plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
    let binaries = format!(
        "copilot={}",
        fixtures().join("stub-record").join("copilot").display()
    );
    let home_word = home.display().to_string();
    let env = [
        ("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str()),
        ("HOME", home_word.as_str()),
    ];
    for (item, permission, allow_all, grant) in [
        ("KEN-G1", None, true, "true"),
        ("KEN-G2", Some("--allow-all-tools"), false, ""),
    ] {
        let worktree = dir.path().join(item);
        std::fs::create_dir_all(&worktree).unwrap();
        let init = program("git")
            .args(["-C", &worktree.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(init.status.success(), "{}", stderr(&init));
        fleet_origin(&[runner.state_dir(), &worktree]);
        let mut request = launch_request(item, &worktree);
        request["harness"] = json!("copilot");
        request["account"] = json!(account.display().to_string());
        if let Some(permission) = permission {
            request["permission"] = json!(permission);
        }
        let report = effect_report(&runner.op_fleet_env(&request, &env));
        assert_ne!(report["intent"]["outcome"], "failed", "{item}: {report}");
        assert_eq!(report["lane"]["allow_all"], allow_all, "{item}: {report}");
        let recorded = launch_record_of(&worktree);
        assert_eq!(
            recorded["env"]["COPILOT_ALLOW_ALL"], grant,
            "{item}: the grant on the line: {recorded}"
        );
        let argv = recorded["argv"].as_array().unwrap();
        assert_eq!(
            argv.contains(&json!("--allow-all")),
            allow_all,
            "{item}: the bypass word on the line: {argv:?}"
        );
        assert_eq!(
            argv.contains(&json!("--allow-all-tools")),
            permission.is_some(),
            "{item}: the request's word on the line: {argv:?}"
        );
    }
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-G3", runner.state_dir())));
    assert_ne!(report["intent"]["outcome"], "failed", "{report}");
    assert!(
        report["lane"].get("allow_all").is_some_and(Value::is_null),
        "a Claude lane records the field with no grant to judge: {}",
        report["lane"]
    );
}

/// Through the real launch over a harness that waits on Claude Code's
/// bypass-permissions confirmation until its config dir's settings.json
/// consents: a bypassed launch on a fresh account home, on one that already
/// consents, and on one that trusts the directory but never consented,
/// each opens at the composer with the consent standing and every other
/// key kept; a launch with a narrower grant writes no consent; a recorded
/// `false` refuses before any window.
#[test]
fn a_bypassed_claude_launch_records_the_accounts_bypass_consent_and_honours_a_refusal() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-bypass-gated");
    runner.init_fleet();
    let cwd = runner.state_dir().display().to_string();
    let home = |name: &str| {
        let home = dir.path().join(name);
        plant_credential(&home);
        home
    };
    let settings_of = |home: &Path| -> Option<Value> {
        std::fs::read_to_string(home.join("settings.json"))
            .ok()
            .map(|text| serde_json::from_str(&text).unwrap())
    };
    let launch = |item: &str, home: &Path, permission: Option<&str>| {
        let mut request = launch_request(item, runner.state_dir());
        request["account"] = json!(home.display().to_string());
        if let Some(permission) = permission {
            request["permission"] = json!(permission);
        }
        effect_report(&runner.op_fleet(&request))
    };
    let confirmed = |item: &str, report: &Value| {
        assert_eq!(report["intent"]["outcome"], "confirmed", "{item}: {report}");
        effect_report(&runner.op_fleet(&terminal_close(item)));
    };

    let fresh = home("fresh");
    let report = launch("KEN-B1", &fresh, None);
    confirmed("KEN-B1", &report);
    assert_eq!(report["intent"]["observation"]["trust"], "account-config");
    assert_eq!(
        settings_of(&fresh),
        Some(json!({"skipDangerousModePermissionPrompt": true}))
    );

    let prepared = home("prepared");
    let text = "{\"theme\": \"dark\", \"skipDangerousModePermissionPrompt\": true}\n";
    std::fs::write(prepared.join("settings.json"), text).unwrap();
    confirmed("KEN-B2", &launch("KEN-B2", &prepared, None));
    assert_eq!(
        std::fs::read_to_string(prepared.join("settings.json")).unwrap(),
        text,
        "a consent that stands is not written again"
    );

    let trusted = home("trusted");
    let mut projects = serde_json::Map::new();
    projects.insert(cwd, json!({"hasTrustDialogAccepted": true}));
    std::fs::write(
        trusted.join(".claude.json"),
        json!({"projects": projects}).to_string(),
    )
    .unwrap();
    std::fs::write(trusted.join("settings.json"), r#"{"theme": "dark"}"#).unwrap();
    let report = launch("KEN-B3", &trusted, None);
    confirmed("KEN-B3", &report);
    assert_eq!(report["intent"]["observation"]["trust"], "preapproved");
    assert_eq!(
        settings_of(&trusted),
        Some(json!({"theme": "dark", "skipDangerousModePermissionPrompt": true}))
    );

    let narrower = home("narrower");
    confirmed(
        "KEN-B4",
        &launch("KEN-B4", &narrower, Some("--permission-mode dontAsk")),
    );
    assert_eq!(
        settings_of(&narrower),
        None,
        "no bypass, no consent, and no settings made in a seat the lane cannot write"
    );

    let refusing = home("refusing");
    let text = r#"{"skipDangerousModePermissionPrompt": false}"#;
    std::fs::write(refusing.join("settings.json"), text).unwrap();
    let panes_before = server.panes().len();
    let report = launch("KEN-B5", &refusing, None);
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["cause"], "bypass-refused");
    assert_eq!(
        report["intent"]["observation"]["path"],
        refusing.join("settings.json").display().to_string()
    );
    assert_eq!(server.panes().len(), panes_before, "no window: {report}");
    assert_eq!(
        std::fs::read_to_string(refusing.join("settings.json")).unwrap(),
        text,
        "a recorded answer is honoured, never overwritten"
    );
}

/// Through the real hosted launch over the shipped ssh provider: a bypassed
/// Claude lane reads its host's Claude settings once `create` answered and
/// before any window, records the consent where it is absent with every
/// other key kept and reads it back, refuses a recorded `false` and a file
/// it cannot read, each naming the host; a launch with a narrower grant
/// reads nothing.
#[test]
fn a_bypassed_hosted_claude_lane_records_the_hosts_bypass_consent_and_honours_a_refusal() {
    let settings = ".claude/settings.json";
    let consent = json!({"skipDangerousModePermissionPrompt": true});
    let themed = json!({"theme": "dark", "skipDangerousModePermissionPrompt": true});
    let refused = r#"{"skipDangerousModePermissionPrompt": false}"#;
    // What stands at the host's settings path before the launch: absent,
    // a file's text, or a directory no `cat` reads.
    enum Standing<'a> {
        Absent,
        Text(&'a str),
        Unreadable,
    }
    type Case<'a> = (
        &'a str,
        Standing<'a>,
        Option<&'a str>,
        Result<Option<&'a Value>, &'a str>,
    );
    let cases: [Case; 5] = [
        ("absent", Standing::Absent, None, Ok(Some(&consent))),
        (
            "other keys",
            Standing::Text(r#"{"theme": "dark"}"#),
            None,
            Ok(Some(&themed)),
        ),
        (
            "refused",
            Standing::Text(refused),
            None,
            Err("bypass-refused harness=claude path=.claude/settings.json"),
        ),
        (
            "unreadable",
            Standing::Unreadable,
            None,
            Err("config-unreadable harness=claude path=.claude/settings.json cause="),
        ),
        (
            "narrower",
            Standing::Absent,
            Some("--permission-mode dontAsk"),
            Ok(None),
        ),
    ];
    for (case, standing, permission, expected) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let world = HostedLaunch::ssh(&server, dir.path());
        let path = world.home().join(settings);
        std::fs::remove_file(&path).unwrap();
        let before = match standing {
            Standing::Absent => None,
            Standing::Text(text) => {
                std::fs::write(&path, text).unwrap();
                Some(text.to_owned())
            }
            Standing::Unreadable => {
                std::fs::create_dir(&path).unwrap();
                None
            }
        };
        let mut request = world.request();
        if let Some(permission) = permission {
            request["permission"] = json!(permission);
        }
        let panes_before = server.panes().len();
        let report = effect_report(&world.runner.op_fleet(&request));
        let calls = world.calls();
        let after = world.on_host(settings);
        match expected {
            Ok(written) => {
                assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
                assert_eq!(server.panes().len(), panes_before + 1, "{case}: one window");
                assert_eq!(
                    after.map(|bytes| serde_json::from_str::<Value>(&bytes).unwrap()),
                    written.cloned(),
                    "{case}: the consent put where it was absent, every other key kept: {calls:?}"
                );
                if permission.is_some() {
                    assert!(
                        !calls.iter().any(|c| c.ends_with(" .claude/settings.json")),
                        "{case}: a narrower grant reads no consent: {calls:?}"
                    );
                }
                effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
            }
            Err(cause) => {
                assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
                let observed = report["intent"]["observation"]["cause"]
                    .as_str()
                    .unwrap_or("");
                assert!(
                    observed.starts_with(cause)
                        && observed.ends_with(&format!(" host={}", world.provider())),
                    "{case}: {report}"
                );
                assert_eq!(server.panes().len(), panes_before, "{case}: no window");
                assert_eq!(after, before, "{case}: nothing put");
                assert!(
                    std::fs::metadata(world.tools.join("ssh.log")).is_err(),
                    "{case}: nothing dialled"
                );
            }
        }
    }
}

/// Through the real launch: a Codex lane and a Copilot lane whose harness
/// is up at its composer a second before it writes its session (Codex its
/// rollout, through the private launch home's link to the account's store;
/// Copilot its workspace) bind that session, never `session-unbound`.
#[test]
fn a_launch_binds_the_session_its_harness_writes_after_its_composer_is_up() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(10);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    runner.tools = Some(tools.clone());
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let late = fixtures().join("stub-session-late");
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!(
            "codex={},copilot={}",
            late.join("codex").display(),
            late.join("copilot").display()
        ),
    ));
    let copilot = dir.path().join("copilot-account");
    plant_copilot_hooks(&copilot.join("hooks"));
    plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
    let codex = dir.path().join("codex-account");
    std::fs::create_dir_all(&codex).unwrap();
    let work = runner.state_dir().to_path_buf();
    for (item, harness, account) in [("KEN-S1", "codex", &codex), ("KEN-S2", "copilot", &copilot)] {
        let _ = std::fs::remove_file(work.join(".stub-session-id"));
        let mut request = launch_request(item, &work);
        request["harness"] = json!(harness);
        request["account"] = json!(account.display().to_string());
        let report = effect_report(&runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{item}: {report}");
        assert_eq!(
            report["intent"]["observation"].get("note"),
            None,
            "{item}: {report}"
        );
        let written = std::fs::read_to_string(work.join(".stub-session-id")).unwrap();
        assert_eq!(
            report["lane"]["session_id"],
            written.trim_end(),
            "{item}: the session its harness wrote: {report}"
        );
        effect_report(&runner.op_fleet(&terminal_close(item)));
    }
}

#[test]
fn a_refused_launch_keeps_the_dependencys_cause_as_detail_or_beside_the_refusals_own() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    // Each home is refused by agent-runtime's trust preparation over its
    // planted file. A Claude config that is not JSON names the parser's cause
    // and no detail of its own. A Copilot home whose `EXTENSIONS` flag is off,
    // with no status line to fall back on, names its own detail word beside
    // the status line's cause. A `None` detail is the parser's text.
    type Case<'a> = (
        &'a str,
        &'a str,
        &'a str,
        &'a str,
        &'a str,
        &'a str,
        Option<&'a str>,
        Option<&'a str>,
    );
    let cases: [Case; 2] = [
        (
            "KEN-D1",
            "claude",
            ".claude.json",
            "{not json",
            "config-unreadable",
            "path",
            None,
            None,
        ),
        (
            "KEN-D2",
            "copilot",
            "settings.json",
            r#"{"enabledFeatureFlags": {"EXTENSIONS": false}}"#,
            "no-context-reader",
            "file",
            Some("disabled"),
            Some("no-status-line"),
        ),
    ];
    for (item, harness, file, text, key, file_field, detail, detail_cause) in cases {
        let account = dir.path().join(format!("{harness}-account"));
        std::fs::create_dir_all(&account).unwrap();
        let planted = account.join(file);
        std::fs::write(&planted, text).unwrap();
        let mut request = launch_request(item, runner.state_dir());
        request["harness"] = json!(harness);
        request["account"] = json!(account.display().to_string());
        let panes_before = server.panes().len();
        let report = effect_report(&runner.op_fleet(&request));
        let observation = &report["intent"]["observation"];
        assert_eq!(report["intent"]["outcome"], "failed", "{item}: {report}");
        assert_eq!(observation["cause"], key, "{item}: {report}");
        assert_eq!(
            observation[file_field],
            planted.display().to_string(),
            "{item}: {report}"
        );
        let observed = observation["detail"].as_str().unwrap_or_default();
        match detail {
            Some(word) => assert_eq!(observed, word, "{item}: {report}"),
            None => assert!(!observed.is_empty(), "{item}: {report}"),
        }
        assert_eq!(
            observation.get("detail_cause").and_then(Value::as_str),
            detail_cause,
            "{item}: {report}"
        );
        assert_eq!(
            server.panes().len(),
            panes_before,
            "{item}: no window: {report}"
        );
    }
}

/// A hosted Pi lane billing a Claude seat is refused before the provider
/// creates anything; a hosted Pi lane on its own root is judged on its
/// host's files once `create` named that root.
#[test]
fn a_hosted_pi_lane_is_gated_before_create_and_on_its_host_s_files() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    // The Pi root the provider names is the inventory's account on the host.
    let root = world.clone().parent().unwrap().join("remote-account");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join("settings.json"),
        r#"{"compaction": {"enabled": true}}"#,
    )
    .unwrap();
    for (harness, model, cause, created) in [
        (
            "pi",
            Some("pi-claude/fable"),
            format!(
                "host-pi-claude-seat host={} model=pi-claude/fable",
                world.provider()
            ),
            false,
        ),
        (
            "pi",
            Some("github-copilot/gpt-6"),
            format!(
                "compaction-on harness=pi file={}/settings.json",
                root.display()
            ),
            true,
        ),
    ] {
        let _ = std::fs::remove_file(world.scripts.join("lane-host.log"));
        let mut request = world.request();
        request["harness"] = json!(harness);
        if let Some(model) = model {
            request["model"] = json!(model);
        }
        let panes_before = server.panes().len();
        let report = effect_report(&world.runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "failed", "{harness}: {report}");
        assert_eq!(
            report["intent"]["observation"]["cause"], cause,
            "{harness} {model:?}: {report}"
        );
        assert_eq!(server.panes().len(), panes_before, "{harness}: no window");
        assert_eq!(
            world.calls().iter().any(|c| c.contains(" create ")),
            created,
            "{harness} {model:?}: {:?}",
            world.calls()
        );
        assert!(
            std::fs::metadata(world.tools.join("ssh.log")).is_err(),
            "nothing dialled"
        );
    }
}

/// Through the real hosted launch over the shipped ssh provider: a Copilot
/// lane is created, then its context reader is made to stand in the Copilot
/// home the provider named (`.copilot` under the host user's home where a
/// provider of another kind names none) through the provider's `put`, the extension and the settings flag
/// put only where they differ, and its three lane-mail hooks are found on
/// the host before the window opens. A host holding no hooks, and a home
/// whose flag is set false, refuse naming the host, with no window and
/// nothing put.
#[test]
fn a_hosted_copilot_lane_installs_its_context_reader_and_runs_only_where_its_hooks_stand() {
    const EXTENSION: &str =
        include_str!("../../../agent-runtime/runtime/src/copilot-lane-context.mjs");
    let enabled = r#"{"enabledFeatureFlags": {"EXTENSIONS": true}}"#;
    let hooks = ["lane-mail-check", "lane-mail-compact", "lane-mail-start"];
    // The shipped provider names the inventory's account as the Copilot
    // home; the default home is a provider's that names none, planted.
    type Case<'a> = (
        &'a str,
        bool,
        Option<&'a str>,
        &'a str,
        bool,
        Result<Option<Value>, &'a str>,
    );
    let cases: [Case; 5] = [
        (
            "installed",
            true,
            None,
            r#"{"theme": "dark"}"#,
            true,
            Ok(Some(
                json!({"theme": "dark", "enabledFeatureFlags": {"EXTENSIONS": true}}),
            )),
        ),
        ("standing", true, Some(EXTENSION), enabled, true, Ok(None)),
        (
            "default home",
            false,
            Some(EXTENSION),
            enabled,
            true,
            Ok(None),
        ),
        (
            "no hooks",
            true,
            Some(EXTENSION),
            enabled,
            false,
            Err("unsupported-for-oversee harness=copilot reason=no-context-hooks scope="),
        ),
        (
            "disabled",
            true,
            Some(EXTENSION),
            r#"{"enabledFeatureFlags": {"EXTENSIONS": false}}"#,
            true,
            Err("no-context-reader harness=copilot file={home}/settings.json detail=disabled"),
        ),
    ];
    for (case, shipped, extension, settings, held, expected) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut world = if shipped {
            HostedLaunch::ssh(&server, dir.path())
        } else {
            let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
            HostedLaunch::new(&server, dir.path(), record)
        };
        world.runner.verify = Some(1);
        std::os::unix::fs::symlink(
            fixtures().join("stub-record").join("copilot"),
            world.tools.join("copilot"),
        )
        .unwrap();
        let home = if shipped {
            world
                .clone()
                .parent()
                .unwrap()
                .join("remote-account")
                .display()
                .to_string()
        } else {
            ".copilot".to_owned()
        };
        let host = world.host();
        let extension_path = format!("{home}/extensions/kendex-lane-context/extension.mjs");
        let settings_path = format!("{home}/settings.json");
        if shipped {
            let mut files = vec![(settings_path.clone(), settings.to_owned())];
            if let Some(extension) = extension {
                files.push((extension_path.clone(), extension.to_owned()));
            }
            for name in hooks {
                for ext in ["sh", "json"] {
                    if held {
                        files.push((format!("{home}/hooks/{name}.{ext}"), "{}\n".to_owned()));
                    }
                }
            }
            for (path, text) in files {
                std::fs::create_dir_all(Path::new(&path).parent().unwrap()).unwrap();
                std::fs::write(&path, text).unwrap();
            }
        } else {
            let account = world.runner.state_dir().display().to_string();
            let answers_path = world.scripts.join("lane-host.json");
            let mut answers: Value =
                serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
            answers
                [format!("create --item KEN-H --repo o/r --harness copilot --account {account}")] = json!({
                "stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\n")
            });
            answers[format!("cat --item KEN-H {extension_path}")] =
                json!({"stdout": extension.unwrap()});
            answers[format!("cat --item KEN-H {settings_path}")] = json!({"stdout": settings});
            for name in hooks {
                for ext in ["sh", "json"] {
                    answers[format!("cat --item KEN-H {host}/.github/hooks/{name}.{ext}")] =
                        json!({"exit": 2});
                    answers[format!("cat --item KEN-H {home}/hooks/{name}.{ext}")] =
                        json!({"stdout": "{}\n"});
                }
            }
            std::fs::write(&answers_path, answers.to_string()).unwrap();
        }
        let mut request = world.request();
        request["harness"] = json!("copilot");
        let panes_before = server.panes().len();
        let report = effect_report(&world.runner.op_fleet(&request));
        let calls = world.calls();
        // What the launch put: the planted provider keeps each put, the
        // shipped one leaves the file changed where a put reached it.
        let put = |path: &str, before: Option<&str>| -> Vec<String> {
            if shipped {
                std::fs::read_to_string(path)
                    .ok()
                    .filter(|after| Some(after.as_str()) != before)
                    .into_iter()
                    .collect()
            } else {
                world.puts(path)
            }
        };
        let extensions = put(&extension_path, extension);
        let flags = put(&settings_path, Some(settings));
        match expected {
            Ok(written) => {
                assert_ne!(report["intent"]["outcome"], "failed", "{case}: {report}");
                assert_eq!(server.panes().len(), panes_before + 1, "{case}: one window");
                let launched = launch_record_of(Path::new(&host));
                assert_eq!(
                    launched["program"]
                        .as_str()
                        .and_then(|p| Path::new(p).file_name()?.to_str()),
                    Some("copilot"),
                    "{case}: {launched}"
                );
                assert!(
                    calls
                        .iter()
                        .any(|c| c.ends_with(&format!(" {home}/hooks/lane-mail-start.json"))),
                    "{case}: the hooks read in the home: {calls:?}"
                );
                match written {
                    Some(settings) => {
                        assert_eq!(extensions, vec![EXTENSION.to_owned()], "{case}");
                        assert_eq!(
                            flags
                                .iter()
                                .map(|bytes| serde_json::from_str::<Value>(bytes).unwrap())
                                .collect::<Vec<_>>(),
                            vec![settings],
                            "{case}: the flag set, every other key kept"
                        );
                    }
                    None => assert_eq!(
                        (extensions.len(), flags.len()),
                        (0, 0),
                        "{case}: nothing put where the reader stands: {calls:?}"
                    ),
                }
                effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
            }
            Err(cause) => {
                assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
                let cause = cause.replace("{home}", &home);
                let observed = report["intent"]["observation"]["cause"]
                    .as_str()
                    .unwrap_or("");
                assert!(
                    observed.starts_with(&cause)
                        && observed.ends_with(&format!(" host={}", world.provider())),
                    "{case}: {report}"
                );
                assert_eq!(server.panes().len(), panes_before, "{case}: no window");
                assert_eq!(
                    (extensions.len(), flags.len()),
                    (0, 0),
                    "{case}: nothing put: {calls:?}"
                );
                assert!(
                    std::fs::metadata(world.tools.join("ssh.log")).is_err(),
                    "{case}: nothing dialled"
                );
            }
        }
    }
}

/// A pane agent `tmux split-window` starts takes its environment from the
/// host's tmux server, started outside the provider's login shell whose key
/// and proxy variables the parent reads. Through the real hosted
/// `launch-lane`, the shipped ssh provider and a private server: the typed line
/// runs the session-environment step before the harness, so the pane agent
/// the harness splits off reads the key its Pi `models.json` names and the
/// proxy, as the parent does, byte for byte through tmux's parser. The
/// values are secrets: the login shell traces every command it runs with
/// its words expanded, which holds the argv of every process it starts, and
/// no traced word carries either value.
#[test]
fn a_hosted_pi_lane_on_the_copilot_pool_hands_its_pane_agents_the_login_environment() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut world = HostedLaunch::ssh(&server, dir.path());
    world.runner.verify = Some(2);
    // Each value holds a run no shell or tmux quoting splits, the needle
    // the trace is searched for, beside every character tmux's parser
    // treats specially.
    let key_needle = "pool-key-7f3a";
    let key = format!("{key_needle}'q \"d\" $HOME;#~\\");
    let proxy_needle = "proxy-pass-91c";
    let proxy = format!("http://lane:{proxy_needle}@proxy.test:3128");
    // The host user's login shell sets the pool's key and proxy, then
    // traces itself. Bash 3.2 has no BASH_XTRACEFD; the same descriptor
    // captures its stderr trace.
    let trace = dir.path().join("login-trace.log");
    std::fs::write(
        world.home().join(".bash_profile"),
        format!(
            "export POOL_KEY='{}' HTTPS_PROXY='{proxy}'\nexec 7>>'{}'\nBASH_XTRACEFD=7\nexec 2>&7\nset -x\n",
            key.replace('\'', "'\\''"),
            trace.display()
        ),
    )
    .unwrap();
    // The Pi root the provider names is the inventory's account on the host.
    let root = world.clone().parent().unwrap().join("remote-account");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join("models.json"),
        r#"{"providers":{"github-copilot":{"apiKey":"$POOL_KEY"}}}"#,
    )
    .unwrap();
    std::fs::write(
        root.join("settings.json"),
        r#"{"compaction":{"enabled":false}}"#,
    )
    .unwrap();
    commit_files(
        &world.source(),
        &[
            (
                ".pi/settings.json",
                r#"{"packages":["./packages/@vanillagreen/pi-hooks"]}"#,
            ),
            (
                ".pi/packages/@vanillagreen/pi-hooks/package.json",
                r#"{"version":"1","pi":{"extensions":["./extensions/lane-mail-wake.ts"]}}"#,
            ),
            (
                ".pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts",
                "context_window",
            ),
        ],
    );
    let parent_env = dir.path().join("parent.env");
    let child_env = dir.path().join("child.env");
    let child = dir.path().join("child.sh");
    std::fs::write(
        &child,
        format!(
            "#!/bin/bash\nprintf '%s|%s\\n' \"${{POOL_KEY-unset}}\" \"${{HTTPS_PROXY-unset}}\" > '{}'\n",
            child_env.display()
        ),
    )
    .unwrap();
    // The Pi stand-in: it reads the two names, splits a pane agent off the
    // way pi-agents-tmux does and stands.
    let pi = world.tools.join("pi");
    write_executable(
        &pi,
        format!(
            "#!/bin/bash\nprintf '%s|%s\\n' \"${{POOL_KEY-unset}}\" \"${{HTTPS_PROXY-unset}}\" > '{}'\ntmux split-window -d -t \"$TMUX_PANE\" \"/bin/bash '{}'\"\nprintf 'pi starting\\n'\nwhile read -r line; do :; done\n",
            parent_env.display(),
            child.display()
        ),
    );
    let mut request = world.request();
    request["harness"] = json!("pi");
    request["model"] = json!("github-copilot/gpt-6");
    let report = effect_report(&world.runner.op_fleet(&request));
    assert_ne!(report["intent"]["outcome"], "failed", "{report}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::fs::metadata(&child_env).is_err() {
        assert!(Instant::now() < deadline, "the pane agent never ran");
        std::thread::sleep(Duration::from_millis(20));
    }
    let expected = format!("{key}|{proxy}\n");
    assert_eq!(
        std::fs::read_to_string(&parent_env).unwrap(),
        expected,
        "the harness reads the login shell's variables"
    );
    assert_eq!(
        std::fs::read_to_string(&child_env).unwrap(),
        expected,
        "the pane agent reads the same from the session"
    );
    let traced = std::fs::read_to_string(&trace).unwrap();
    assert!(
        traced.contains("printenv POOL_KEY"),
        "the trace holds the step's read of the key: {traced}"
    );
    for needle in [key_needle, proxy_needle] {
        let carried: Vec<&str> = traced.lines().filter(|l| l.contains(needle)).collect();
        assert!(
            carried.is_empty(),
            "{needle} on a command line: {carried:?}"
        );
    }
}

/// A Pi lane billing a Claude seat runs under Pi's own root; the seat
/// reaches the launch through its own variable alone. That root's settings
/// and carrier are what the launch reads before any window: on Pi's default
/// compaction it refuses, and with compaction off and a carrier that sends
/// the window and wakes on mail it opens.
#[test]
fn a_pi_lane_on_a_claude_seat_keeps_pis_own_root_beside_the_seat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let home = dir.path().join("home");
    let pi_root = home.join(".pi/agent");
    std::fs::create_dir_all(&pi_root).unwrap();
    let home = home.display().to_string();
    let binaries = format!("pi={}", fixtures().join("stub-record").join("pi").display());
    let env = [
        ("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str()),
        ("HOME", home.as_str()),
    ];
    let mut request = launch_request("KEN-PI0", runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    let panes_before = server.panes().len();
    let report = effect_report(&runner.op_fleet_env(&request, &env));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"],
        format!(
            "compaction-on harness=pi file={}/settings.json",
            pi_root.display()
        ),
        "{report}"
    );
    assert_eq!(server.panes().len(), panes_before, "no window opened");
    std::fs::write(
        pi_root.join("settings.json"),
        r#"{"compaction": {"enabled": false}, "packages": ["./packages/@vanillagreen/pi-hooks"]}"#,
    )
    .unwrap();
    let carrier = pi_root.join("packages/@vanillagreen/pi-hooks");
    std::fs::create_dir_all(carrier.join("extensions")).unwrap();
    std::fs::write(
        carrier.join("package.json"),
        r#"{"version": "1.4.0", "pi": {"extensions": ["./extensions/lane-mail-wake.ts"]}}"#,
    )
    .unwrap();
    std::fs::write(
        carrier.join("extensions/vocab.ts"),
        "export const fields = { context_window: 0 };\n",
    )
    .unwrap();
    request["item"] = json!("KEN-PI");
    let elsewhere = dir.path().join("server-pi-root");
    let set = tmux(
        &server.socket,
        &[
            "set-environment",
            "-g",
            "PI_CODING_AGENT_DIR",
            &elsewhere.display().to_string(),
        ],
    );
    assert!(set.status.success(), "{}", stderr(&set));
    let out = runner.op_fleet_env(&request, &env);
    let report = effect_report(&out);
    assert!(
        matches!(
            report["intent"]["outcome"].as_str(),
            Some("confirmed" | "unconfirmed")
        ),
        "{report}"
    );
    let recorded = launch_record_of(runner.state_dir());
    assert_eq!(
        recorded["env"]["CLAUDE_CONFIG_DIR"],
        seat.display().to_string()
    );
    assert_eq!(
        recorded["env"]["PI_CODING_AGENT_DIR"],
        pi_root.display().to_string(),
        "the root the gate judged, never the seat: {recorded}"
    );
    let relocated = dir.path().join("relocated-pi-root");
    std::fs::create_dir_all(&relocated).unwrap();
    std::fs::write(
        relocated.join("settings.json"),
        r#"{"compaction": {"enabled": true}}"#,
    )
    .unwrap();
    let relocated_word = relocated.display().to_string();
    request["item"] = json!("KEN-PI2");
    let panes_before = server.panes().len();
    let report = effect_report(&runner.op_fleet_env(
        &request,
        &[
            env[0],
            env[1],
            ("PI_CODING_AGENT_DIR", relocated_word.as_str()),
        ],
    ));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"],
        format!("compaction-on harness=pi file={relocated_word}/settings.json"),
        "{report}"
    );
    assert_eq!(server.panes().len(), panes_before, "no window opened");
}

/// A local lane on a named Claude account, Claude's own or a Pi
/// `pi-claude/` seat, signs in as that account alone whatever the fleet
/// server's environment holds: a declared token file's text is the token
/// it holds, an undeclared account signs in by its stored login with no
/// token in its environment, every key that would outrank either and the
/// endpoint that would receive it are cleared, and an account whose
/// declared file holds no token refuses before any window opens, naming the
/// account, the cause and the file. Each row: the item, the harness, the
/// account's declared file, and the token the lane holds or the refusal's
/// cause.
#[test]
fn a_lane_on_a_named_claude_account_signs_in_as_that_account_alone() {
    enum Want {
        Holds(Option<&'static str>),
        Refused(&'static str),
    }
    let rows = [
        (
            "KEN-SF",
            "claude",
            Some("file-token\n"),
            Want::Holds(Some("file-token")),
        ),
        ("KEN-SL", "claude", None, Want::Holds(None)),
        ("KEN-SP", "pi", None, Want::Holds(None)),
        (
            "KEN-SA",
            "claude",
            Some(""),
            Want::Refused("declared-token-absent"),
        ),
    ];
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    for (name, value) in [
        ("CLAUDE_CODE_OAUTH_TOKEN", "inherited"),
        ("ANTHROPIC_API_KEY", "planted-key"),
        ("ANTHROPIC_AUTH_TOKEN", "planted-auth"),
        ("ANTHROPIC_BASE_URL", "https://gateway.invalid"),
    ] {
        let out = tmux(&server.socket, &["set-environment", "-g", name, value]);
        assert!(out.status.success(), "{}", stderr(&out));
    }
    let home = dir.path().join("home");
    pi_root_ready(&home.join(".pi/agent"));
    let home = home.display().to_string();
    let binaries = format!(
        "claude={},pi={}",
        fixtures().join("stub-record/claude").display(),
        fixtures().join("stub-record/pi").display()
    );
    for (item, harness, declared, want) in rows {
        let seat = dir.path().join(format!("seat-{item}"));
        plant_credential(&seat);
        let token = dir.path().join(format!("{item}.token"));
        let setting = match declared {
            Some(text) => {
                std::fs::write(&token, text).unwrap();
                format!("{}={}", seat.display(), token.display())
            }
            None => String::new(),
        };
        let env = [
            ("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str()),
            ("AGENT_RUNTIME_ACCOUNT_TOKEN_FILES", setting.as_str()),
            ("HOME", home.as_str()),
        ];
        let mut request = launch_request(item, runner.state_dir());
        request["harness"] = json!(harness);
        request["account"] = json!(seat.display().to_string());
        if harness == "pi" {
            request["model"] = json!("pi-claude/fable");
        }
        let record = runner.state_dir().join("launch-record.json");
        let _ = std::fs::remove_file(&record);
        let panes_before = server.panes().len();
        let report = effect_report(&runner.op_fleet_env(&request, &env));
        match want {
            Want::Holds(holds) => {
                assert!(
                    matches!(
                        report["intent"]["outcome"].as_str(),
                        Some("confirmed" | "unconfirmed")
                    ),
                    "{item}: {report}"
                );
                let launched = launch_record_of(runner.state_dir());
                assert_eq!(
                    launched["sign_in"],
                    json!({
                        "CLAUDE_CODE_OAUTH_TOKEN": holds,
                        "ANTHROPIC_API_KEY": null,
                        "ANTHROPIC_AUTH_TOKEN": null,
                        "ANTHROPIC_BASE_URL": null,
                    }),
                    "{item}: {launched}"
                );
            }
            Want::Refused(cause) => {
                assert_eq!(report["intent"]["outcome"], "failed", "{item}: {report}");
                let observation = &report["intent"]["observation"];
                for (field, value) in [
                    ("cause", "successor-not-signed-in".to_owned()),
                    ("account", seat.display().to_string()),
                    ("detail", cause.to_owned()),
                    ("file", token.display().to_string()),
                ] {
                    assert_eq!(observation[field], json!(value), "{item}: {report}");
                }
                assert_eq!(
                    server.panes().len(),
                    panes_before,
                    "{item}: no window opened"
                );
            }
        }
    }
}

/// A Pi root and a carrier that leaves its compaction off and wakes on mail.
fn pi_root_ready(root: &Path) {
    let carrier = root.join("packages/@vanillagreen/pi-hooks");
    std::fs::create_dir_all(carrier.join("extensions")).unwrap();
    std::fs::write(
        root.join("settings.json"),
        r#"{"compaction": {"enabled": false}, "packages": ["./packages/@vanillagreen/pi-hooks"]}"#,
    )
    .unwrap();
    std::fs::write(
        carrier.join("package.json"),
        r#"{"version": "1.4.0", "pi": {"extensions": ["./extensions/lane-mail-wake.ts"]}}"#,
    )
    .unwrap();
    std::fs::write(
        carrier.join("extensions/vocab.ts"),
        "export const fields = { context_window: 0 };\n",
    )
    .unwrap();
}

#[test]
fn a_pi_root_the_private_env_file_names_is_the_root_a_seat_lane_is_judged_and_run_on() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join(".pi/agent")).unwrap();
    let relocated = home.join("relocated-pi");
    std::fs::create_dir_all(&relocated).unwrap();
    std::fs::write(
        relocated.join("settings.json"),
        r#"{"compaction": {"enabled": true}}"#,
    )
    .unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("pi={}", fixtures().join("stub-record/pi").display()),
    ));
    let work = runner.state_dir().to_path_buf();
    std::fs::write(
        work.join(".env.local"),
        "export PI_CODING_AGENT_DIR=$HOME/relocated-pi\n",
    )
    .unwrap();
    // The real executable reading the project's private file.
    let launch = |item: &str| {
        let mut request = launch_request(item, &work);
        request["harness"] = json!("pi");
        request["model"] = json!("pi-claude/fable");
        request["account"] = json!(seat.display().to_string());
        let path = work.join(format!("{item}.json"));
        std::fs::write(&path, request.to_string()).unwrap();
        let mut command = program(binary());
        command
            .args(["--state-dir", &work.display().to_string()])
            .args(["op", "--fleet", "--request", &path.display().to_string()])
            .current_dir(&work);
        runner.apply_env(&mut command);
        effect_report(&command.output().unwrap())
    };
    let panes = server.panes().len();
    let refused = launch("KEN-PR1");
    assert_eq!(refused["intent"]["outcome"], "failed", "{refused}");
    assert_eq!(
        refused["intent"]["observation"]["cause"],
        format!(
            "compaction-on harness=pi file={}/settings.json",
            relocated.display()
        ),
        "{refused}"
    );
    assert_eq!(server.panes().len(), panes, "no window opened");
    pi_root_ready(&relocated);
    let opened = launch("KEN-PR2");
    assert_ne!(opened["intent"]["outcome"], "failed", "{opened}");
    assert_eq!(
        opened["intent"]["phase"]["home"],
        relocated.display().to_string(),
        "the opening records the home a reconcile reads: {opened}"
    );
    let recorded = launch_record_of(&work);
    assert_eq!(
        recorded["env"]["PI_CODING_AGENT_DIR"],
        relocated.display().to_string(),
        "{recorded}"
    );
}

#[test]
fn a_codex_lane_with_no_account_runs_on_the_codex_home_the_fleet_server_hands_its_panes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let served = dir.path().join("served-codex");
    std::fs::create_dir_all(&served).unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("codex={}", fixtures().join("stub-record/codex").display()),
    ));
    let work = runner.state_dir().to_path_buf();
    let set = |args: &[&str]| {
        let out = tmux(&server.socket, args);
        assert!(out.status.success(), "{}", stderr(&out));
    };
    // The server's global scope, then the session's marker removing it: the
    // pane takes the session's word first.
    let served_word = served.display().to_string();
    set(&["set-environment", "-g", "CODEX_HOME", &served_word]);
    let session_target = format!("={}", server.session);
    for (item, want) in [
        ("KEN-CX1", served.clone()),
        ("KEN-CX2", home.join(".codex")),
    ] {
        if item == "KEN-CX2" {
            set(&["set-environment", "-t", &session_target, "-r", "CODEX_HOME"]);
        }
        let mut request = launch_request(item, &work);
        request["harness"] = json!("codex");
        request.as_object_mut().unwrap().remove("account");
        let report = effect_report(&runner.op_fleet(&request));
        assert_ne!(report["intent"]["outcome"], "failed", "{item}: {report}");
        let recorded = launch_record_of(&work);
        assert_eq!(
            recorded["env"]["CODEX_HOME"],
            agent_runtime::trust::home_path(&want, &work)
                .display()
                .to_string(),
            "{item}: {recorded}"
        );
    }
}

#[test]
fn a_reconciled_pi_lane_on_a_seat_binds_its_session_under_pis_root_not_the_seat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let seat = dir.path().join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    let root = dir.path().join("pi-root");
    std::fs::create_dir_all(&root).unwrap();
    // A program named `pi` that draws Pi's composer at rest and stands.
    let bin = dir.path().join("pi-bin");
    std::fs::create_dir_all(&bin).unwrap();
    let pi = bin.join("pi");
    write_executable(
        &pi,
        "#!/bin/bash\nprintf '%s\\n' '────────────────────────────────' '────────────────────────────────' '~/work (main)' '0.4%/1.0M'\nwhile IFS= read -r _line; do :; done\n",
    );
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("pi={}", pi.display()),
    ));
    runner
        .env
        .push(("PI_CODING_AGENT_DIR".to_owned(), root.display().to_string()));
    let since = now_ms();
    let pane = server.open_window("KEN-PIR", &work, &format!("exec {}", pi.display()));
    let deadline = Instant::now() + Duration::from_secs(10);
    let drawn = || {
        let out = tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]);
        String::from_utf8_lossy(&out.stdout).contains("0.4%/1.0M")
    };
    while !drawn() {
        assert!(Instant::now() < deadline, "the stand-in never drew");
        std::thread::sleep(Duration::from_millis(50));
    }
    // The session the launch's own Pi wrote, under Pi's root.
    let sessions = root
        .join("sessions")
        .join(agent_runtime::session::pi_slug(&work));
    std::fs::create_dir_all(&sessions).unwrap();
    std::fs::write(
        sessions.join("one.jsonl"),
        format!(
            "{}\n",
            json!({"type": "session", "id": "pi-session-1", "cwd": work.display().to_string()})
        ),
    )
    .unwrap();
    let mut lane = lane("KEN-PIR", "preparing", &runner, Value::Null);
    lane["harness"] = json!("pi");
    lane["model"] = json!("pi-claude/fable");
    lane["account"] = json!(seat.display().to_string());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane]);
    // The launch recorded Pi's root on its opening; the reconcile's own
    // environment names another.
    let mut opened = phase("window-opened", &server, &pane, since, None);
    opened["home"] = json!(root.display().to_string());
    fleet["intents"] = json!([lane_intent(
        "launch-session",
        "KEN-PIR",
        "not-started",
        Some(opened),
    )]);
    runner.write_fleet(&fleet);
    runner.env.retain(|(key, _)| key != "PI_CODING_AGENT_DIR");
    runner.env.push((
        "PI_CODING_AGENT_DIR".to_owned(),
        dir.path().join("elsewhere").display().to_string(),
    ));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = runner.fleet()["lanes"][0].clone();
    assert_eq!(lane["session_id"], "pi-session-1", "{report}");
    assert_eq!(
        lane["home"],
        root.display().to_string(),
        "the relaunch reads the recorded home: {lane}"
    );
}

/// A stopped lane with no account recorded the home its bound session
/// stands in, and whether it named it; whatever the fleet server or the
/// settings now hand the harness, the relaunch resumes the session on that
/// home in that mode. A record with no home, as every released record is,
/// resumes under the home a fresh launch picks: the server's, else the
/// loaded `COPILOT_HOME`, else the default, Claude's implicit. A fresh
/// Claude launch names the server's config dir as found, even
/// `$HOME/.claude`, and records that it named it; where the server names
/// none it runs on the implicit default, the variable cleared.
#[test]
fn a_lane_with_no_account_runs_under_the_one_home_its_session_is_proved_and_recorded_under() {
    // The case, the harness, what the lane recorded (`dir` a named home of
    // its own, `implicit` Claude's default named by nothing, `named-default`
    // the default named, `released` a bound session and no home, `none` no
    // session), and the home the server or the settings now name (`current`,
    // `home-claude`, `$HOME/.claude` spelled out, or `nothing`).
    let cases = [
        (
            "codex: the server hands the recorded home",
            "codex",
            "dir",
            "dir",
        ),
        (
            "codex: the server now hands another home",
            "codex",
            "dir",
            "current",
        ),
        (
            "copilot: the settings now name another home",
            "copilot",
            "dir",
            "current",
        ),
        (
            "claude: the server now names another config dir",
            "claude",
            "dir",
            "current",
        ),
        (
            "claude: the implicit default recorded, the server names another",
            "claude",
            "implicit",
            "current",
        ),
        (
            "claude: the named default recorded, the server names another",
            "claude",
            "named-default",
            "current",
        ),
        (
            "claude: a fresh launch under the server's config dir",
            "claude",
            "none",
            "current",
        ),
        (
            "claude: a fresh launch, the server naming $HOME/.claude",
            "claude",
            "none",
            "home-claude",
        ),
        (
            "claude: a fresh launch, the server naming nothing",
            "claude",
            "none",
            "nothing",
        ),
        (
            "claude: a released record under the server's config dir",
            "claude",
            "released",
            "current",
        ),
        (
            "codex: a released record under the server's CODEX_HOME",
            "codex",
            "released",
            "current",
        ),
        (
            "claude: a released record, the server naming nothing",
            "claude",
            "released",
            "nothing",
        ),
        (
            "codex: a released record, the server naming nothing",
            "codex",
            "released",
            "nothing",
        ),
        (
            "copilot: a released record under the loaded COPILOT_HOME",
            "copilot",
            "released",
            "current",
        ),
    ];
    for (case, harness, recorded, served) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        let own = dir.path().join("dir");
        let served = match served {
            "nothing" => None,
            "home-claude" => Some(home.join(".claude")),
            other => Some(dir.path().join(other)),
        };
        if let Some(served) = &served {
            std::fs::create_dir_all(served).unwrap();
        }
        // The home the session stands in and the launch should run on, and
        // whether the launch names it: with nothing recorded and nothing
        // served, the harness's default, Claude's implicit.
        let (expected, named) = match (recorded, &served) {
            ("dir", _) => (own.clone(), true),
            ("implicit", _) => (home.join(".claude"), false),
            ("named-default", _) => (home.join(".claude"), true),
            (_, Some(served)) => (served.clone(), true),
            (_, None) => (home.join(format!(".{harness}")), harness != "claude"),
        };
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        runner.env.push((
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!(
                "{harness}={}",
                fixtures().join("stub-record").join(harness).display()
            ),
        ));
        let work = runner.state_dir().to_path_buf();
        let id = match harness {
            "claude" => "11111111-1111-4111-8111-111111111111".to_owned(),
            _ => format!("{harness}-session-1"),
        };
        let (variable, store) = match harness {
            "codex" => ("CODEX_HOME", "sessions"),
            "claude" => ("CLAUDE_CONFIG_DIR", "projects"),
            _ => ("COPILOT_HOME", "session-state"),
        };
        match (harness, &served) {
            ("copilot", Some(served)) => {
                let tools = dir.path().join("tools");
                std::fs::create_dir_all(&tools).unwrap();
                runner.tools = Some(tools.clone());
                plant_copilot_hooks(&work.join(".github/hooks"));
                plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
                runner
                    .env
                    .push(("COPILOT_HOME".to_owned(), served.display().to_string()));
            }
            (_, Some(served)) => {
                let out = tmux(
                    &server.socket,
                    &[
                        "set-environment",
                        "-g",
                        variable,
                        &served.display().to_string(),
                    ],
                );
                assert!(out.status.success(), "{case}: {}", stderr(&out));
            }
            (_, None) => {}
        }
        let bound = recorded != "none";
        match (harness, bound) {
            (_, false) => {}
            ("codex", true) => {
                let day = expected.join("sessions/2026/11/04");
                std::fs::create_dir_all(&day).unwrap();
                std::fs::write(
                    day.join(format!("rollout-a-{id}.jsonl")),
                    format!(
                        "{}\n",
                        json!({"type": "session_meta", "payload": {"id": id, "cwd": work.display().to_string(), "source": "cli"}})
                    ),
                )
                .unwrap();
            }
            ("claude", true) => {
                let project = project_dir(&expected, &work);
                std::fs::create_dir_all(&project).unwrap();
                std::fs::write(project.join(format!("{id}.jsonl")), "{}\n").unwrap();
            }
            (_, true) => {
                let state = expected.join("session-state").join(&id);
                std::fs::create_dir_all(&state).unwrap();
                std::fs::write(
                    state.join("workspace.yaml"),
                    format!("id: {id}\ncwd: {}\n", work.display()),
                )
                .unwrap();
                std::fs::write(state.join("events.jsonl"), "{}\n").unwrap();
            }
        }
        let mut stopped = lane("KEN-R", "stopped", &runner, Value::Null);
        stopped["harness"] = json!(harness);
        if bound {
            stopped["session_id"] = json!(id);
        }
        if bound && recorded != "released" {
            stopped["home"] = json!(expected.display().to_string());
            if !named {
                stopped["home_implicit"] = json!(true);
            }
        }
        stopped.as_object_mut().unwrap().remove("account");
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([stopped]);
        runner.write_fleet(&fleet);
        let mut request = launch_request("KEN-R", &work);
        request["harness"] = json!(harness);
        request.as_object_mut().unwrap().remove("account");
        let report = effect_report(&runner.op_fleet(&request));
        if bound {
            assert_eq!(
                report["intent"]["observation"]["route"], "resume",
                "{case}: {report}"
            );
        }
        let launched = launch_record_of(&work);
        // A home is its session store: a private Codex launch home links the
        // account's.
        let store_of = |path: &Path| {
            std::fs::canonicalize(path.join(store))
                .or_else(|_| std::fs::canonicalize(path))
                .ok()
        };
        let child = launched["env"][variable].as_str().unwrap_or("");
        if harness == "claude" {
            let spelled = if named {
                expected.display().to_string()
            } else {
                String::new()
            };
            assert_eq!(
                child, spelled,
                "{case}: the config dir named as it was found, or none: {launched}"
            );
        } else {
            assert_eq!(
                store_of(Path::new(child)),
                store_of(&expected),
                "{case}: the harness runs on the home its session is proved under: {launched}"
            );
        }
        let phase = &report["intent"]["phase"];
        assert_eq!(
            phase["home"]
                .as_str()
                .and_then(|recorded| store_of(Path::new(recorded))),
            store_of(&expected),
            "{case}: the launch records the home the harness runs on: {report}"
        );
        assert_eq!(
            phase["home_implicit"].as_bool().unwrap_or(false),
            !named,
            "{case}: the launch records whether it named its home: {report}"
        );
    }
}

/// With nothing recorded and the server naming nothing, the launch keeps
/// the inherited home (`~/.codex`; the loaded `COPILOT_HOME`), which must
/// exist: it refuses `home-missing` before any window opens, nothing
/// recorded as opening.
#[test]
fn an_accountless_launch_whose_inherited_home_does_not_stand_refuses_before_any_window() {
    let cases = [
        ("codex: no ~/.codex under HOME", "codex", None),
        (
            "copilot: the loaded COPILOT_HOME names no directory",
            "copilot",
            Some("COPILOT_HOME"),
        ),
    ];
    for (case, harness, variable) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        if let Some(variable) = variable {
            runner.env.push((
                variable.to_owned(),
                dir.path().join("absent").display().to_string(),
            ));
        }
        runner.env.push((
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!(
                "{harness}={}",
                fixtures().join("stub-record").join(harness).display()
            ),
        ));
        let work = runner.state_dir().to_path_buf();
        let mut request = launch_request("KEN-H", &work);
        request["harness"] = json!(harness);
        request.as_object_mut().unwrap().remove("account");
        let panes = server.panes().len();
        let report = effect_report(&runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        assert_eq!(
            report["intent"]["observation"]["cause"], "home-missing",
            "{case}: {report}"
        );
        let absent = match variable {
            Some(_) => dir.path().join("absent"),
            None => home.join(".codex"),
        };
        assert_eq!(
            report["intent"]["observation"]["path"],
            absent.display().to_string(),
            "{case}: the home the launch would run on: {report}"
        );
        assert!(
            report["intent"]["phase"].is_null(),
            "{case}: nothing recorded as opening: {report}"
        );
        assert_eq!(server.panes().len(), panes, "{case}: no window opened");
    }
}

/// The root a Pi lane runs on must stand before anything judges it: the
/// harness gate would read an absent root's settings as compaction on.
/// Through the real `launch-lane`: the launch fails `home-missing` naming
/// the root, nothing recorded as opening, no window.
#[test]
fn a_seated_pi_lane_with_no_pi_root_refuses_home_missing_before_the_gate() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("pi={}", fixtures().join("stub-record/pi").display()),
    ));
    let mut request = launch_request("KEN-PS", runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    let panes = server.panes().len();
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"], "home-missing",
        "{report}"
    );
    assert_eq!(
        report["intent"]["observation"]["path"],
        home.join(".pi/agent").display().to_string(),
        "the root the launch would run on: {report}"
    );
    assert!(
        report["intent"]["phase"].is_null(),
        "nothing recorded as opening: {report}"
    );
    assert_eq!(server.panes().len(), panes, "no window opened");
}

/// The cycle reader takes the lane record's tier, and a micro lane's
/// relaunch brief opens the workflow with `start` whatever the item's tier.
/// Through the real `launch-lane`: a brief opening the orch workflow with
/// `start` records the standard tier and the item-tier line's inputs; one
/// stating no verb and two item-tier lines that differ records none; one
/// opening with `micro` records micro and its line's inputs, and that
/// lane's relaunch on the wall's start brief keeps them; closed `done`, its
/// next phase opening with `small` records small and that brief's inputs,
/// as a first launch does.
#[test]
fn the_launch_records_the_tier_its_brief_states_and_a_relaunch_keeps_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let brief = runner.state_dir().join("brief.md");
    std::fs::write(
        &brief,
        "/orch start KEN-T\ntier=small brief=small cause=estimate estimate=3 delta=10 paths=2\n",
    )
    .unwrap();
    let mut request = launch_request("KEN-T", runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["tier"], "standard", "{}", report["lane"]);
    assert_eq!(
        report["lane"]["tier_inputs"],
        json!({"estimate": 3, "delta": 10, "paths": 2}),
        "{}",
        report["lane"]
    );
    std::fs::write(
        &brief,
        "Resume the work.\ntier=small brief=small cause=a estimate=3 delta=10 paths=2\ntier=micro brief=micro cause=b estimate=1 delta=1 paths=1\n",
    )
    .unwrap();
    let mut other = launch_request("KEN-U", runner.state_dir());
    other["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&other));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        report["lane"].get("tier").is_some_and(Value::is_null),
        "two lines that differ state no tier: {}",
        report["lane"]
    );
    assert_eq!(
        report["lane"]["tier_inputs"],
        json!({"estimate": null, "delta": null, "paths": null})
    );
    std::fs::write(
        &brief,
        "/orch micro KEN-V\ntier=micro brief=micro cause=estimate estimate=1 delta=4 paths=1\n",
    )
    .unwrap();
    let mut micro = launch_request("KEN-V", runner.state_dir());
    micro["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&micro));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["tier"], "micro", "{}", report["lane"]);
    let inputs = json!({"estimate": 1, "delta": 4, "paths": 1});
    assert_eq!(report["lane"]["tier_inputs"], inputs, "{}", report["lane"]);
    let mut fleet = runner.fleet();
    let micro_row = fleet["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .position(|l| l["item"] == "KEN-V")
        .unwrap();
    fleet["lanes"][micro_row]["status"] = json!("stopped");
    fleet["lanes"][micro_row]["launch"] = Value::Null;
    runner.write_fleet(&fleet);
    std::fs::write(&brief, "/orch start KEN-V Work unattended.\n").unwrap();
    let report = effect_report(&runner.op_fleet(&micro));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        (&report["lane"]["tier"], &report["lane"]["tier_inputs"]),
        (&json!("micro"), &inputs),
        "a relaunch on the start brief keeps the first launch's tier: {}",
        report["lane"]
    );
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-V")));
    assert_eq!(closed["lane"]["status"], "done", "{closed}");
    std::fs::write(
        &brief,
        "/orch small KEN-V\ntier=small brief=small cause=estimate estimate=2 delta=40 paths=3\n",
    )
    .unwrap();
    let report = effect_report(&runner.op_fleet(&micro));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        (&report["lane"]["tier"], &report["lane"]["tier_inputs"]),
        (
            &json!("small"),
            &json!({"estimate": 2, "delta": 40, "paths": 3})
        ),
        "the next phase over a done record records its own brief's tier: {}",
        report["lane"]
    );
}

/// A lane bound to no obligation leaves its cycle's lineage unknown.
/// Through the real `launch-lane` and the real `close-lane`: a launch
/// naming the item's obligation records it; the item's next phase naming
/// none keeps it, and one naming another is refused `obligation-conflict`
/// with nothing written; a first launch naming neither an obligation nor a
/// repository records none, and its record takes the obligation a later
/// launch names; a parent named without its pair is refused
/// `request-invalid` with nothing written. A first launch naming a
/// repository and no obligation records the item as its own parent; a
/// relaunch and the next phase keep it, the cycle recorder copies it into
/// the cycle, a later launch naming the same is admitted and keeps it, and
/// one naming another parent or another repository is refused
/// `obligation-conflict` with nothing written.
#[test]
fn the_launch_binds_the_items_obligation_and_its_cycle_records_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let obligation = json!({
        "repo": "o/r", "item": "KEN-O", "parent_repo": "o/p", "parent_item": "KEN-P",
    });
    let mut request = launch_request("KEN-O", runner.state_dir());
    request["obligation"] = obligation.clone();
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        report["lane"]["obligation"], obligation,
        "{}",
        report["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-O")));
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-O", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        report["lane"]["obligation"], obligation,
        "a launch naming none keeps the bound lineage: {}",
        report["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-O")));
    let before = runner.fleet();
    let mut other = request.clone();
    other["obligation"]["parent_item"] = json!("KEN-Q");
    let out = runner.op_fleet(&other);
    let answer = reply(&out);
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["refusal"]["key"], "obligation-conflict", "{answer}");
    assert_eq!(runner.fleet(), before, "a refused launch writes nothing");
    let unbound = effect_report(&runner.op_fleet(&launch_request("KEN-Q", runner.state_dir())));
    assert_eq!(unbound["intent"]["outcome"], "confirmed", "{unbound}");
    assert!(
        unbound["lane"].get("obligation").is_none(),
        "{}",
        unbound["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-Q")));
    let mut bind_later = launch_request("KEN-Q", runner.state_dir());
    let later = json!({
        "repo": "o/r", "item": "KEN-Q", "parent_repo": null, "parent_item": null,
    });
    bind_later["obligation"] = later.clone();
    let bound = effect_report(&runner.op_fleet(&bind_later));
    assert_eq!(
        bound["lane"]["obligation"], later,
        "a record binding none takes the named obligation: {}",
        bound["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-Q")));
    let before = runner.fleet();
    let mut half = launch_request("KEN-H", runner.state_dir());
    half["obligation"] = json!({
        "repo": "o/r", "item": "KEN-H", "parent_repo": "o/p", "parent_item": null,
    });
    let answer = reply(&runner.op_fleet(&half));
    assert_eq!(answer["refusal"]["key"], "request-invalid", "{answer}");
    assert_eq!(runner.fleet(), before, "a half-named parent writes nothing");
    let stop = |item: &str| {
        let mut fleet = runner.fleet();
        for lane in fleet["lanes"].as_array_mut().unwrap() {
            if lane["item"] == item {
                lane["status"] = json!("stopped");
                lane["launch"] = Value::Null;
            }
        }
        runner.write_fleet(&fleet);
    };
    let mut first = launch_request("KEN-S", runner.state_dir());
    first["repo"] = json!("O/R");
    let own = json!({"repo": "o/r", "item": "KEN-S", "parent_repo": "o/r", "parent_item": "KEN-S"});
    let report = effect_report(&runner.op_fleet(&first));
    assert_eq!(
        report["lane"]["obligation"], own,
        "a first launch naming a repository records its own item: {}",
        report["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-S")));
    let report = effect_report(&runner.op_fleet(&first));
    assert_eq!(
        report["lane"]["obligation"], own,
        "the next phase keeps it: {}",
        report["lane"]
    );
    stop("KEN-S");
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-S", runner.state_dir())));
    assert_eq!(
        report["lane"]["obligation"], own,
        "a relaunch keeps it: {}",
        report["lane"]
    );
    // The close verb over the record the launch wrote, left stopped as a
    // kept sandbox leaves it, its delivery a direct push in the project's
    // checkout (the state directory) whose push log is unread: the cycle
    // the close records reads the launch's binding.
    stop("KEN-S");
    let state = runner.state_dir().display().to_string();
    let out = program("git")
        .args(["-C", &state, "commit", "-q", "--allow-empty", "-m", "work"])
        .output()
        .unwrap();
    assert!(out.status.success(), "git commit: {}", stderr(&out));
    let head = program("git")
        .args(["-C", &state, "rev-parse", "HEAD"])
        .output()
        .unwrap();
    let head = String::from_utf8_lossy(&head.stdout).trim().to_owned();
    let answer = reply(&runner.op_fleet(
        &json!({"op": "close-lane", "item": "KEN-S", "delivery": {"commit": {"commit": head}}}),
    ));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let lane = runner.fleet()["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == "KEN-S")
        .cloned()
        .unwrap();
    assert_eq!(
        lane["cycle"]["obligation"], own,
        "the cycle reads the launch's binding: {lane}"
    );
    let mut named = launch_request("KEN-S", runner.state_dir());
    named["obligation"] = own.clone();
    let report = effect_report(&runner.op_fleet(&named));
    assert_eq!(
        report["lane"]["obligation"], own,
        "the same lineage stated again keeps it: {}",
        report["lane"]
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-S")));
    let before = runner.fleet();
    for stated in [
        json!({"repo": "o/r", "item": "KEN-S", "parent_repo": "o/p", "parent_item": "KEN-P"}),
        json!({"repo": "o/x", "item": "KEN-S", "parent_repo": "o/r", "parent_item": "KEN-S"}),
    ] {
        named["obligation"] = stated.clone();
        let answer = reply(&runner.op_fleet(&named));
        assert_eq!(
            answer["refusal"]["key"], "obligation-conflict",
            "{stated}: {answer}"
        );
        assert_eq!(
            runner.fleet(),
            before,
            "{stated}: another lineage writes nothing"
        );
    }
}

/// One origin for the fleet's checkout and a lane's: a clone of the
/// fleet's repository, which its launch is bound to.
fn fleet_origin(checkouts: &[&Path]) {
    for checkout in checkouts {
        let out = program("git")
            .arg("-C")
            .arg(checkout)
            .args([
                "config",
                "remote.origin.url",
                "https://github.com/o/fleet.git",
            ])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
}

/// A lane briefed without the unattended words asks its questions in a chat
/// nobody reads, and a lane told its output mode only by a skill it reads
/// later writes its first reply under no mode. Through the real
/// `launch-lane`, on every launch path: the brief reaches the harness's
/// line closed by the unattended words, once, on a line after the brief's
/// own, then by the sentence of the resolved `ORCH_LANE_OUTPUT`, once, on
/// the last line, the quiet sentence where the setting is unset. The paths:
/// a fresh local launch on each harness; a Claude brief that already
/// carries the words, at its end or on its first line before an item-tier
/// line; the watch's wall relaunch brief, in the form
/// `watch/lanes.rs::start_brief` writes, pinned here so a change to that
/// form is read against this row; the model recovery's continuation,
/// in the form `effects/lane_model.rs::continuation` writes; a local relaunch
/// that resumes its bound session; a hosted lane, through the runtime's
/// provider call to the shipped ssh provider.
#[test]
fn every_lane_brief_states_its_resolved_lane_output_once() {
    let text = |path: &str| {
        std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(path))
            .unwrap()
            .trim_end()
            .to_owned()
    };
    let words = text("src/watch/unattended.txt");
    let words = words.as_str();
    let quiet = text("src/effects/lane-output-quiet.txt");
    let normal = text("src/effects/lane-output-normal.txt");
    let closed = |brief: &str, mode: Option<&str>| {
        let brief = if brief.contains(words) {
            brief.to_owned()
        } else {
            format!("{brief}\n{words}")
        };
        let sentence = if mode == Some("normal") {
            &normal
        } else {
            &quiet
        };
        format!("{brief}\n{sentence}")
    };
    let continuation = "Resume the orch workflow for KEN-U from where this session stopped. Run .agents/skills/mailbox/scripts/lane-mail inbox --item KEN-U first and act on every envelope it prints, answers and directives alike, as its text directs, then re-arm your mailbox monitor on .agents/skills/mailbox/scripts/lane-mail watch --item KEN-U through your harness background wake.\n".to_owned();
    let cases: [(&str, &str, Option<&str>); 9] = [
        ("claude", "/orch start KEN-U", None),
        (
            "codex",
            "Read .agents/skills/orch/SKILL.md and run orch start KEN-U.",
            Some("normal"),
        ),
        (
            "copilot",
            "Read .agents/skills/orch/SKILL.md and run orch start KEN-U.",
            None,
        ),
        ("pi", "/skill:orch start KEN-U", Some("normal")),
        ("claude", "/orch start KEN-U WORDS", None),
        (
            "claude",
            "/orch small KEN-U WORDS\ntier=small brief=small cause=estimate estimate=2 delta=40 paths=3",
            Some("quiet"),
        ),
        (
            "codex",
            "Read .agents/skills/orch/SKILL.md and execute the orch start workflow for KEN-U. WORDS",
            Some("normal"),
        ),
        ("pi", "/skill:orch start KEN-U WORDS", None),
        ("claude", continuation.trim_end(), Some("normal")),
    ];
    for (harness, brief, mode) in cases {
        let brief = brief.replace("WORDS", words);
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        runner.env.push((
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!(
                "{harness}={}",
                fixtures().join("stub-record").join(harness).display()
            ),
        ));
        let work = runner.state_dir().to_path_buf();
        let mut request = launch_request("KEN-U", &work);
        request["harness"] = json!(harness);
        match harness {
            "claude" => {}
            "copilot" => {
                let tools = dir.path().join("tools");
                std::fs::create_dir_all(&tools).unwrap();
                runner.tools = Some(tools.clone());
                plant_copilot_hooks(&work.join(".github/hooks"));
                plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
                let copilot_home = dir.path().join("copilot");
                std::fs::create_dir_all(&copilot_home).unwrap();
                request["account"] = json!(copilot_home.display().to_string());
            }
            "pi" => {
                pi_root_ready(&home.join(".pi/agent"));
                request.as_object_mut().unwrap().remove("account");
            }
            _ => {
                request.as_object_mut().unwrap().remove("account");
            }
        }
        let file = dir.path().join("brief.md");
        std::fs::write(&file, format!("{brief}\n")).unwrap();
        request["brief_file"] = json!(file.display().to_string());
        let setting: Vec<(&str, &str)> =
            mode.map(|m| ("ORCH_LANE_OUTPUT", m)).into_iter().collect();
        let report = effect_report(&runner.op_fleet_env(&request, &setting));
        assert_ne!(report["intent"]["outcome"], "failed", "{harness}: {report}");
        let recorded = launch_record_of(&work);
        let carried: Vec<&str> = recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|arg| arg.contains(words))
            .collect();
        let expected = armed(closed(&brief, mode), harness, "KEN-U");
        assert_eq!(
            carried,
            [expected.as_str()],
            "{harness}: the brief the line carries: {recorded}"
        );
        assert_eq!(
            carried[0].matches(words).count(),
            1,
            "{harness}: the words once: {recorded}"
        );
    }
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let world = HostedLaunch::ssh(&server, dir.path());
    // The recording harness on the host.
    std::fs::remove_file(world.tools.join("claude")).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("stub-record/claude"),
        world.tools.join("claude"),
    )
    .unwrap();
    let brief = dir.path().join("hosted-brief.md");
    std::fs::write(&brief, "Review the hosted change.\n").unwrap();
    let mut request = world.request();
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(
        &world
            .runner
            .op_fleet_env(&request, &[("ORCH_LANE_OUTPUT", "normal")]),
    );
    assert_ne!(report["intent"]["outcome"], "failed", "hosted: {report}");
    let recorded = launch_record_of(&world.host_path);
    let expected = armed(
        closed("Review the hosted change.", Some("normal")),
        "claude",
        "KEN-H",
    );
    assert!(
        recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .any(|arg| arg == &json!(expected)),
        "hosted: the brief the host's line carries: {recorded}"
    );
    // A relaunch on the account its bound session ran under resumes that
    // session with the brief as its next prompt: the file the line reads.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-resume");
    runner.init_fleet();
    let account = dir.path().join("account");
    std::fs::create_dir_all(&account).unwrap();
    plant_credential(&account);
    let file = dir.path().join("brief.md");
    std::fs::write(&file, &continuation).unwrap();
    let request = json!({
        "op": "launch-lane",
        "item": "KEN-U",
        "harness": "claude",
        "mail_root": runner.state_dir().display().to_string(),
        "account": account.display().to_string(),
        "model": "claude-fable-5-1",
        "effort": "high",
        "class": CLASS,
        "class_reason": CLASS_REASON,
        "brief_file": file.display().to_string(),
    });
    let first = effect_report(&runner.op_fleet(&request));
    assert_eq!(first["intent"]["outcome"], "confirmed", "{first}");
    effect_report(&runner.op_fleet(&terminal_close("KEN-U")));
    let resumed = effect_report(&runner.op_fleet(&request));
    assert_eq!(
        resumed["intent"]["observation"]["route"], "resume",
        "{resumed}"
    );
    let held = runner.state_dir().join("intents").join(format!(
        "{}.brief",
        resumed["intent"]["id"].as_str().unwrap()
    ));
    assert_eq!(
        std::fs::read_to_string(&held).unwrap().trim_end(),
        armed(closed(continuation.trim_end(), None), "claude", "KEN-U"),
        "resume: the brief the resumed line reads"
    );
}

/// The line a lane brief on `harness` closes with to arm the mailbox
/// monitor of `item`, as the lane reads it: none for Codex and Pi.
fn arm_line(harness: &str, item: &str) -> Option<String> {
    match harness {
        "claude" => Some(format!(
            "As your first step, arm your mailbox monitor: a Monitor on .agents/skills/mailbox/scripts/lane-mail watch --item {item}, re-armed at each expiry; run the lane-mail inbox command each of its announcements prints."
        )),
        "copilot" => Some(format!(
            "As your first step, arm your mailbox monitor: .agents/skills/mailbox/scripts/lane-mail watch --once --item {item} as a background command, re-armed after each exit once the lane-mail inbox command it printed has run."
        )),
        _ => None,
    }
}

/// `closed`, a brief ending on its mode sentence, with the arm line of
/// `harness` for `item` on the line before that sentence.
fn armed(closed: String, harness: &str, item: &str) -> String {
    match (arm_line(harness, item), closed.rsplit_once('\n')) {
        (Some(line), Some((head, sentence))) => format!("{head}\n{line}\n{sentence}"),
        (Some(_), None) | (None, _) => closed,
    }
}

/// A lane told nothing of the paths its launch admitted edits outside them
/// before it asks, so two lanes can change one file before the judge reads
/// either. Through the real `launch-lane`: a brief naming paths reaches the
/// harness's line closed by the record's touched set, sorted, as one
/// `Admitted paths:` line on the line after the brief's own, before the
/// unattended words.
#[test]
fn a_lane_brief_names_the_paths_its_launch_admitted() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("claude={}", fixtures().join("stub-record/claude").display()),
    ));
    let work = runner.state_dir().to_path_buf();
    let file = dir.path().join("brief.md");
    std::fs::write(&file, "/orch start KEN-U on `src/b.sh` and `src/a.sh`\n").unwrap();
    let mut request = launch_request("KEN-U", &work);
    request["brief_file"] = json!(file.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_ne!(report["intent"]["outcome"], "failed", "{report}");
    let recorded = launch_record_of(&work);
    let brief = recorded["argv"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .find(|arg| arg.starts_with("/orch start KEN-U"))
        .unwrap_or_else(|| panic!("no brief on the line: {recorded}"));
    let lines: Vec<&str> = brief.lines().collect();
    assert_eq!(
        lines[..2],
        [
            "/orch start KEN-U on `src/b.sh` and `src/a.sh`",
            r#"Admitted paths: ["src/a.sh","src/b.sh"]"#,
        ],
        "{brief}"
    );
}

/// A launch that names no brief file opens its lane on the start brief,
/// never on nothing, and the brief closes with its harness's arm line,
/// once, before the mode sentence: a lane told nothing of its mailbox
/// monitor gets its overseer's mail only at its turn ends. Through the real
/// `launch-lane`, reading the brief the recording harness got: a fresh
/// local launch on Claude Code, Copilot CLI and Codex (which arms nothing),
/// and a hosted Claude relaunch over the record its first launch left, its
/// provider keeping the tree unrebased, which the brief tells the lane.
#[test]
fn a_launch_with_no_brief_file_starts_its_lane_on_the_armed_start_brief() {
    let text = |path: &str| {
        std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(path))
            .unwrap()
            .trim_end()
            .to_owned()
    };
    let words = text("src/watch/unattended.txt");
    let quiet = text("src/effects/lane-output-quiet.txt");
    let prose = "Read .agents/skills/orch/SKILL.md and execute the orch start workflow for KEN-U.";
    let cases = [
        ("claude", format!("/orch start KEN-U {words}")),
        ("copilot", format!("{prose} {words}")),
        ("codex", format!("{prose} {words}")),
    ];
    for (harness, start) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        runner.env.push((
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!(
                "{harness}={}",
                fixtures().join("stub-record").join(harness).display()
            ),
        ));
        let work = runner.state_dir().to_path_buf();
        let mut request = launch_request("KEN-U", &work);
        request["harness"] = json!(harness);
        if harness == "copilot" {
            let tools = dir.path().join("tools");
            std::fs::create_dir_all(&tools).unwrap();
            runner.tools = Some(tools.clone());
            plant_copilot_hooks(&work.join(".github/hooks"));
            plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
            let copilot_home = dir.path().join("copilot");
            std::fs::create_dir_all(&copilot_home).unwrap();
            request["account"] = json!(copilot_home.display().to_string());
        } else if harness == "codex" {
            request.as_object_mut().unwrap().remove("account");
        }
        let report = effect_report(&runner.op_fleet(&request));
        assert_ne!(report["intent"]["outcome"], "failed", "{harness}: {report}");
        let recorded = launch_record_of(&work);
        let carried: Vec<&str> = recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|arg| arg.contains(words.as_str()))
            .collect();
        let expected = armed(format!("{start}\n{quiet}"), harness, "KEN-U");
        assert_eq!(
            carried,
            [expected.as_str()],
            "{harness}: the brief the line carries: {recorded}"
        );
    }
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    // A relaunch whose tree conflicts with the moved base, kept unrebased.
    let world = HostedLaunch::ssh(&server, dir.path());
    commit_files(&world.source(), &[("shared.txt", "base\n")]);
    world.launched_and_retired();
    commit_files(&world.host_path, &[("shared.txt", "item\n")]);
    commit_files(&world.source(), &[("shared.txt", "moved base\n")]);
    std::fs::remove_file(world.tools.join("claude")).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("stub-record/claude"),
        world.tools.join("claude"),
    )
    .unwrap();
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(report["intent"]["outcome"], "confirmed", "hosted: {report}");
    let recorded = launch_record_of(&world.host_path);
    let expected = format!(
        "{}\nYour retained work is kept as it stands, not rebased onto the base branch. The restack is yours to run.",
        armed(
            format!("/orch start KEN-H {words}\n{quiet}"),
            "claude",
            "KEN-H"
        )
    );
    assert!(
        recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .any(|arg| arg == &json!(expected)),
        "hosted relaunch: the brief the host's line carries: {recorded}"
    );
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

/// An `ORCH_LANE_OUTPUT` the brief cannot state, a typo of either word,
/// would start a lane under a mode the owner never chose. Through the real
/// `launch-lane`: the launch refuses `setting-invalid` naming the key and
/// the value before any intent is recorded or any harness starts.
#[test]
fn a_lane_output_outside_its_words_refuses_the_launch_before_any_record() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!(
            "claude={}",
            fixtures().join("stub-record").join("claude").display()
        ),
    ));
    let work = runner.state_dir().to_path_buf();
    let file = dir.path().join("brief.md");
    std::fs::write(&file, "/orch start KEN-U\n").unwrap();
    let mut request = launch_request("KEN-U", &work);
    request["brief_file"] = json!(file.display().to_string());
    let before = runner.fleet();
    let answer = reply(&runner.op_fleet_env(&request, &[("ORCH_LANE_OUTPUT", "verbose")]));
    assert_eq!(answer["refusal"]["key"], "setting-invalid", "{answer}");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([["key", "ORCH_LANE_OUTPUT"], ["value", "verbose"]]),
        "{answer}"
    );
    assert_eq!(runner.fleet(), before, "a refusal writes nothing");
    assert!(
        !work.join("launch-record.json").exists(),
        "no harness started"
    );
}

/// The review inside a lane judges independence by the model the lane
/// declares: a Copilot CLI or Pi session has no other identity it can read,
/// and a Claude Code or Codex session is detected by the review itself.
/// Through the real `launch-lane`, on a fleet server whose environment
/// carries an opener's model declaration and Codex compaction reading.
/// Copilot CLI and Pi declare the pinned model. Claude Code and Codex
/// declare no model, and Codex gets its own compaction reading.
#[test]
fn a_lane_declares_its_pinned_model_to_the_review_and_never_its_openers() {
    let cases: [(&str, &str, Option<&str>); 4] = [
        ("claude", "claude-fable-5-1", None),
        ("codex", "gpt-5.5", None),
        ("copilot", "claude-opus-5", Some("claude-opus-5")),
        ("pi", "claude-fable-5-1", Some("claude-fable-5-1")),
    ];
    for (harness, model, declared) in cases {
        let case = format!("{harness} {model}");
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        for (name, value) in [
            ("SECOND_OPINION_CURRENT_MODEL", "the opener's model"),
            ("ORCH_COMPACTION_OVERRIDES", "the opener's reading"),
        ] {
            let out = tmux(&server.socket, &["set-environment", "-g", name, value]);
            assert!(out.status.success(), "{case}: {}", stderr(&out));
        }
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        runner.env.push((
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!(
                "{harness}={}",
                fixtures().join("stub-record").join(harness).display()
            ),
        ));
        let work = runner.state_dir().to_path_buf();
        let mut request = launch_request("KEN-R", &work);
        request["harness"] = json!(harness);
        match harness {
            "copilot" => {
                let tools = dir.path().join("tools");
                std::fs::create_dir_all(&tools).unwrap();
                runner.tools = Some(tools.clone());
                plant_copilot_hooks(&work.join(".github/hooks"));
                plant_hooks_off(&tools, json!({"stdout": r#"{"switched_off_by": null}"#}));
                let copilot_home = dir.path().join("copilot");
                std::fs::create_dir_all(&copilot_home).unwrap();
                request["account"] = json!(copilot_home.display().to_string());
            }
            "pi" => {
                pi_root_ready(&home.join(".pi/agent"));
                request.as_object_mut().unwrap().remove("account");
            }
            _ => {
                request.as_object_mut().unwrap().remove("account");
            }
        }
        request["model"] = json!(model);
        let report = effect_report(&runner.op_fleet(&request));
        assert_ne!(report["intent"]["outcome"], "failed", "{case}: {report}");
        let opened = &launch_record_of(&work)["opened"];
        assert_eq!(
            opened["SECOND_OPINION_CURRENT_MODEL"],
            declared.map_or(Value::Null, |m| json!(m)),
            "{case}: the model the session declares: {opened}"
        );
        if harness == "codex" {
            let reading = opened["ORCH_COMPACTION_OVERRIDES"].as_str().unwrap_or("");
            let reading: Value = serde_json::from_str(reading)
                .unwrap_or_else(|e| panic!("{case}: the line's own reading {reading:?}: {e}"));
            assert_eq!(reading["harness"], "codex", "{case}: {opened}");
        }
    }
}

/// The launch record the record stubs write in `cwd`, read once it stands:
/// the stub writes it from its own process after the launch answers.
fn launch_record_of(cwd: &Path) -> Value {
    let path = cwd.join("launch-record.json");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(record) = serde_json::from_str::<Value>(&text)
        {
            return record;
        }
        assert!(
            Instant::now() < deadline,
            "no launch record at {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A harness stand-in that writes what the lane reaches into a probe file
/// in its working directory, then runs `harness`: the display and the bus,
/// a file made in each of `PROBE_SEATS`' folders, an append to each of
/// `PROBE_FILES`, the runtime cache it names, `PROBE_RUN` and `gh`'s token.
#[cfg(target_os = "linux")]
fn probe_script(harness: &Path) -> String {
    format!(
        "#!/bin/bash\nexec 3>&1 > \"${{PROBE_OUT:-$PWD}}/probe-$AGENT_RUNTIME_LAUNCH_AGENT-$$.txt\" 2>&1\necho started\n{{\n  tmux -S \"${{XDG_RUNTIME_DIR:-/none}}/${{WAYLAND_DISPLAY:-none}}\" has-session 2>/dev/null && echo display=reached || echo display=refused\n  [ -e \"${{XDG_RUNTIME_DIR:-/none}}/bus\" ] && echo bus=visible || echo bus=hidden\n  for seat in ${{PROBE_SEATS:-}}; do touch \"$seat/probe\" 2>/dev/null && echo \"seat=${{seat##*/}} written\" || echo \"seat=${{seat##*/}} refused\"; done\n  for file in ${{PROBE_FILES:-}}; do (: >> \"$file\") 2>/dev/null && echo \"file=${{file##*/}} written\" || echo \"file=${{file##*/}} refused\"; done\n  echo \"cache=${{AGENT_RUNTIME_CACHE:-none}}\"\n  [ -z \"${{PROBE_RUN:-}}\" ] || eval \"$PROBE_RUN\"\n  echo \"gh=$(gh auth token 2>/dev/null || echo none)\"\n}}\nexec {harness} \"$@\" >&3 2>&3 3>&-\n",
        harness = harness.display()
    )
}

/// A launch world for the confinement's rows: the fleet server, a runtime
/// folder the launch hides (a socket standing for the session bus, a
/// second private server at `wayland-1` standing for the display), a `gh`
/// that answers the bus's login, `GH_TOKEN` before it, and a probe harness
/// that writes what it reached into `probe-<item>.txt` in its worktree, or
/// in the folder `PROBE_OUT` names, then runs the confirming stub. The
/// world, its state directory with it, stands outside `/tmp`
/// ([`outside_tmp`]), so what the lane's grants do not bind stays readable
/// to the lane as the rest of the tree is.
#[cfg(target_os = "linux")]
struct Confined {
    dir: tempfile::TempDir,
    server: Server,
    runner: Runner,
    display: PathBuf,
    _bus: std::os::unix::net::UnixListener,
}

#[cfg(target_os = "linux")]
impl Confined {
    fn new() -> Confined {
        let (dir, _) = outside_tmp();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner {
            dir: outside_tmp().0,
            ..Runner::new(&server, "stub-confirm")
        };
        runner.verify = Some(30);
        runner.init_fleet();
        let root = runner.state_dir().to_path_buf();
        let runtime = dir.path().join("rt");
        std::fs::create_dir_all(&runtime).unwrap();
        let bus = std::os::unix::net::UnixListener::bind(runtime.join("bus")).unwrap();
        let display = runtime.join("wayland-1");
        let out = tmux(&display, &["new-session", "-d", "-s", "display"]);
        assert!(out.status.success(), "the display: {}", stderr(&out));
        let tools = root.join("tools");
        std::fs::create_dir_all(&tools).unwrap();
        write_executable(
            &tools.join("gh"),
            "#!/bin/sh\n# gh's token read: GH_TOKEN first, else the login on the session bus.\nif [ \"$1 $2\" = \"auth token\" ]; then\n  if [ -n \"${GH_TOKEN:-}\" ]; then printf '%s\\n' \"$GH_TOKEN\"; exit 0; fi\n  if [ -S \"${XDG_RUNTIME_DIR:-/none}/bus\" ]; then echo bus-login-token; exit 0; fi\n  echo 'no oauth token found for github.com' >&2; exit 1\nfi\nexit 4\n",
        );
        let probe = root.join("probe").join("claude");
        std::fs::create_dir_all(probe.parent().unwrap()).unwrap();
        write_executable(&probe, probe_script(&stub("stub-confirm")));
        runner.stub = probe;
        runner.tools = Some(tools.clone());
        runner
            .env
            .push(("XDG_RUNTIME_DIR".to_owned(), runtime.display().to_string()));
        let path = tmux(&server.socket, &["show-environment", "-g", "PATH"]);
        let path = String::from_utf8_lossy(&path.stdout);
        let path = path.trim().trim_start_matches("PATH=");
        for (name, value) in [
            ("PATH", format!("{}:{path}", tools.display())),
            ("XDG_RUNTIME_DIR", runtime.display().to_string()),
            ("WAYLAND_DISPLAY", "wayland-1".to_owned()),
        ] {
            // The session's own: tmux records a display name its creating
            // client lacked as removed in the session, over the global one.
            let out = tmux(
                &server.socket,
                &["set-environment", "-t", &server.session, name, &value],
            );
            assert!(out.status.success(), "{name}: {}", stderr(&out));
        }
        Confined {
            dir,
            server,
            runner,
            display,
            _bus: bus,
        }
    }

    /// Launch `request` and answer its report, refusing an unconfirmed one.
    fn launch(&self, request: &Value) -> Value {
        let report = effect_report(&self.runner.op_fleet(request));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
        report
    }

    /// The probe's lines for `item`, one file per launch, once `launches`
    /// of them are whole, bounded: a resumed launch confirms by its
    /// session, which can stand before the probe has run.
    fn probe(&self, item: &str, launches: usize) -> String {
        self.probe_in(self.runner.state_dir(), item, launches)
    }

    /// [`Confined::probe`] for a lane whose worktree is `worktree`.
    fn probe_in(&self, worktree: &Path, item: &str, launches: usize) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let mut text = String::new();
            for entry in std::fs::read_dir(worktree).unwrap() {
                let entry = entry.unwrap();
                if entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(&format!("probe-{item}-"))
                {
                    text.push_str(&std::fs::read_to_string(entry.path()).unwrap_or_default());
                }
            }
            if text.lines().filter(|l| l.starts_with("gh=")).count() >= launches {
                return text;
            }
            assert!(
                Instant::now() < deadline,
                "probe {launches} of {item}: {text} {:?}",
                std::fs::read_dir(worktree)
                    .unwrap()
                    .map(|e| e.unwrap().file_name())
                    .collect::<Vec<_>>()
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The folders the probe creates a file in.
    fn seat_env(&self, seats: &str) {
        self.probe_env("PROBE_SEATS", seats);
    }

    /// The files the probe opens to append nothing to.
    fn file_env(&self, files: &str) {
        self.probe_env("PROBE_FILES", files);
    }

    fn probe_env(&self, name: &str, value: &str) {
        let out = tmux(&self.server.socket, &["set-environment", "-g", name, value]);
        assert!(out.status.success(), "{}", stderr(&out));
    }

    /// A linked worktree of the state directory's checkout, as a fleet
    /// lane's is, signed in as the account its launch names: its common git
    /// folder is the checkout's, outside the worktree.
    fn linked_worktree(&self, name: &str) -> PathBuf {
        let state = self.runner.state_dir();
        git(
            state,
            &[
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "base",
            ],
        );
        let wt = self.dir.path().join(name);
        git(
            state,
            &[
                "worktree",
                "add",
                "-q",
                &wt.display().to_string(),
                "-b",
                name,
            ],
        );
        plant_credential(&wt);
        wt
    }
}

#[cfg(target_os = "linux")]
impl Drop for Confined {
    fn drop(&mut self) {
        let _ = tmux(&self.display, &["kill-server"]);
    }
}

/// The display is the record's: a lane launched with `desktop` reaches the
/// window's display socket, a stopped lane whose record holds it is
/// relaunched by a request naming none and still does, and a lane launched
/// without it is refused the socket, its runtime folder hidden.
#[test]
#[cfg(target_os = "linux")]
fn a_desktop_lane_reaches_the_display_its_relaunch_still_does_and_a_lane_without_it_is_refused() {
    let world = Confined::new();
    let mut request = launch_request("KEN-D", world.runner.state_dir());
    request["desktop"] = json!(true);
    let report = world.launch(&request);
    assert_eq!(report["intent"]["observation"]["desktop"], true, "{report}");
    assert_eq!(
        report["intent"]["observation"]["confinement"],
        json!({"state": "confined"})
    );
    assert_eq!(report["lane"]["desktop"], true, "{}", report["lane"]);
    let first = world.probe("KEN-D", 1);
    assert!(first.contains("display=reached"), "{first}");
    let mut fleet = world.runner.fleet();
    let mut stopped = lane("KEN-R", "stopped", &world.runner, Value::Null);
    stopped["desktop"] = json!(true);
    fleet["lanes"].as_array_mut().unwrap().push(stopped);
    world.runner.write_fleet(&fleet);
    let relaunched = world.launch(&launch_request("KEN-R", world.runner.state_dir()));
    assert_eq!(
        relaunched["intent"]["observation"]["desktop"], true,
        "{relaunched}"
    );
    let probe = world.probe("KEN-R", 1);
    assert!(probe.contains("display=reached"), "{probe}");
    world.launch(&launch_request("KEN-E", world.runner.state_dir()));
    let probe = world.probe("KEN-E", 1);
    assert!(probe.contains("display=refused"), "{probe}");
    assert!(probe.contains("bus=hidden"), "{probe}");
}

/// A lane's second opinion runs on the accounts its configured targets can
/// pick: a Claude lane whose roster names Codex writes the configured Codex
/// account's seat, and is refused a Copilot account's and another Claude
/// account's, which no target of it can pick. In a Codex seat, written
/// whole, the lane writes its state database and is refused the hook
/// registration, the instructions and the command rules the operator's next
/// session there runs: where they stand, and where the registration or the
/// rules folder was absent, whose empty form the launch writes.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_writes_the_seat_its_review_target_can_pick_and_is_refused_a_third_harness_s() {
    let mut world = Confined::new();
    let seats = world.dir.path().join("seats");
    let planted = [
        ("codex1", "auth.json"),
        ("codex2", "auth.json"),
        ("copilot1", "config.json"),
        ("claude2", ".credentials.json"),
    ]
    .map(|(name, file)| {
        let seat = seats.join(name);
        std::fs::create_dir_all(&seat).unwrap();
        std::fs::write(seat.join(file), "{}").unwrap();
        seat.display().to_string()
    });
    let operators_hooks = "{\"hooks\": {\"Stop\": []}}\n";
    let standing = Path::new(&planted[1]);
    std::fs::write(standing.join("hooks.json"), operators_hooks).unwrap();
    std::fs::write(standing.join("AGENTS.md"), "operator\n").unwrap();
    world.runner.env.extend([
        ("AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(), planted.join(":")),
        (
            "SECOND_OPINION_MODELS".to_owned(),
            "claude codex".to_owned(),
        ),
    ]);
    world.seat_env(&planted.join(" "));
    let files = [
        format!("{}/state_5.sqlite", planted[0]),
        format!("{}/hooks.json", planted[0]),
        format!("{}/hooks.json", planted[1]),
        format!("{}/AGENTS.md", planted[1]),
    ];
    world.file_env(&files.join(" "));
    let rules = Path::new(&planted[0]).join("rules");
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "mkdir -p '{r}' 2>/dev/null; (: > '{r}/default.rules') 2>/dev/null && echo rules=planted || echo rules=refused",
            r = rules.display()
        ),
    );
    let report = world.launch(&launch_request("KEN-S", world.runner.state_dir()));
    let probe = world.probe("KEN-S", 1);
    assert!(probe.contains("rules=refused"), "{probe}");
    assert_eq!(
        std::fs::read_dir(&rules).unwrap().count(),
        0,
        "the absent rules folder stands empty"
    );
    assert!(probe.contains("seat=codex1 written"), "{probe}");
    assert!(probe.contains("file=state_5.sqlite written"), "{probe}");
    assert_eq!(
        probe.matches("file=hooks.json refused").count(),
        2,
        "{probe}"
    );
    assert!(probe.contains("file=AGENTS.md refused"), "{probe}");
    assert_eq!(
        std::fs::read_to_string(Path::new(&planted[0]).join("hooks.json")).unwrap(),
        "{\n  \"hooks\": {}\n}\n",
        "the absent registration stands in its empty form"
    );
    assert_eq!(
        std::fs::read_to_string(standing.join("hooks.json")).unwrap(),
        operators_hooks
    );
    assert!(probe.contains("seat=copilot1 refused"), "{probe}");
    assert!(probe.contains("seat=claude2 refused"), "{probe}");
    let named: Vec<String> = report["intent"]["observation"]["seats"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_owned())
        .collect();
    let codex = std::fs::canonicalize(&planted[0]).unwrap();
    assert!(
        named.contains(&codex.display().to_string()),
        "the record names the review seat: {named:?}"
    );
    assert_eq!(
        std::fs::read_to_string(codex.join("config.toml")).unwrap(),
        "",
        "the seat's settings file stands for its read-only carve-out"
    );
}

/// A Claude lane on a seat whose settings file is a link launches, whether
/// the link leads outside the seat to the operator's own settings, as every
/// operator seat's does, or to a file inside the seat: its setup and its
/// harness run under words that bind the file the link leads to read-only,
/// so the lane reads the settings through the link and is refused a write
/// to them. A link whose target cannot be read, absent or refused, refuses
/// the launch by name.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_on_a_seat_whose_settings_are_a_link_reads_them_and_is_refused_a_write() {
    use std::os::unix::fs::PermissionsExt;
    let mut world = Confined::new();
    let setup = world
        .runner
        .state_dir()
        .join(".agents/skills/orch/scripts/setup");
    std::fs::create_dir_all(setup.parent().unwrap()).unwrap();
    write_executable(&setup, "#!/bin/sh\n");
    let operator = world.dir.path().join("operator/.claude/settings.json");
    let inside = world.dir.path().join("seat-in/shared/settings.json");
    for (item, seat, target) in [
        ("KEN-L", world.dir.path().join("seat-out"), operator),
        ("KEN-K", world.dir.path().join("seat-in"), inside),
    ] {
        std::fs::create_dir_all(&seat).unwrap();
        plant_credential(&seat);
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::fs::write(&target, "{\"theme\": \"dark\"}\n").unwrap();
        let link = seat.join("settings.json");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        world.file_env(&link.display().to_string());
        world.probe_env(
            "PROBE_RUN",
            &format!("echo \"settings=$(cat '{}')\"", link.display()),
        );
        let mut request = launch_request(item, world.runner.state_dir());
        request["account"] = json!(seat.display().to_string());
        world.launch(&request);
        let probe = world.probe(item, 1);
        let settings = std::fs::read_to_string(&target).unwrap();
        assert!(
            probe.contains(&format!("settings={}", settings.trim_end())),
            "{item}: {probe}"
        );
        assert!(
            probe.contains("file=settings.json refused"),
            "{item}: {probe}"
        );
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink(),
            "{item}: the seat's link stands"
        );
    }

    // Review seats, which no trust record writes before the grants.
    let refused_file = world.dir.path().join("operator/refused.toml");
    std::fs::write(&refused_file, "").unwrap();
    std::fs::set_permissions(&refused_file, std::fs::Permissions::from_mode(0o000)).unwrap();
    for (item, name, target) in [
        (
            "KEN-M",
            "codex-gone",
            world.dir.path().join("operator/gone.toml"),
        ),
        ("KEN-N", "codex-refused", refused_file.clone()),
    ] {
        let seat = world.dir.path().join("seats").join(name);
        std::fs::create_dir_all(&seat).unwrap();
        std::fs::write(seat.join("auth.json"), "{}").unwrap();
        let link = seat.join("config.toml");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        world
            .runner
            .env
            .retain(|(var, _)| var != "AGENT_RUNTIME_ACCOUNT_DIRS");
        world.runner.env.extend([
            (
                "AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(),
                seat.display().to_string(),
            ),
            ("SECOND_OPINION_MODELS".to_owned(), "codex".to_owned()),
        ]);
        let report = effect_report(
            &world
                .runner
                .op_fleet(&launch_request(item, world.runner.state_dir())),
        );
        assert_eq!(report["intent"]["outcome"], "failed", "{item}: {report}");
        let observation = &report["intent"]["observation"];
        assert_eq!(
            observation["cause"], "grant-link-unreadable",
            "{item}: {report}"
        );
        assert_eq!(
            observation["path"],
            std::fs::canonicalize(&seat)
                .unwrap()
                .join("config.toml")
                .display()
                .to_string(),
            "{item}: the refusal names the link: {report}"
        );
    }
    assert!(
        std::fs::symlink_metadata(world.dir.path().join("operator/gone.toml")).is_err(),
        "nothing made at an absent target"
    );
}

/// A probe line that makes and writes into each of `folders` under `root`,
/// saying which took the write.
#[cfg(target_os = "linux")]
fn folder_writes(root: &Path, folders: &[&str]) -> String {
    format!(
        "for d in {}; do {{ mkdir -p '{r}'/$d && touch '{r}'/$d/probe; }} 2>/dev/null && echo \"folder=$d written\" || echo \"folder=$d refused\"; done",
        folders.join(" "),
        r = root.display()
    )
}

/// A Claude lane cannot replace its seat's settings: the seat is read-only,
/// so the link every operator seat holds stands and the settings read
/// through it stay the operator's. The session folder its harness writes in
/// the seat, made by the launch, takes the lane's session file.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_on_a_claude_seat_is_refused_new_settings_and_writes_its_session() {
    let world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let operator = outside.join("operator/.claude/settings.json");
    std::fs::create_dir_all(operator.parent().unwrap()).unwrap();
    std::fs::write(&operator, "{\"theme\": \"dark\"}\n").unwrap();
    let seat = outside.join("seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let link = seat.join("settings.json");
    std::os::unix::fs::symlink(&operator, &link).unwrap();
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "rm -f '{s}/settings.json' 2>/dev/null; {{ echo '{{\"hooks\": {{}}}}' > '{s}/settings.json'; }} 2>/dev/null && echo replace=written || echo replace=refused\necho \"settings=$(cat '{s}/settings.json')\"\n{}",
            folder_writes(&seat, &["projects"]),
            s = seat.display()
        ),
    );
    let mut request = launch_request("KEN-SR", world.runner.state_dir());
    request["account"] = json!(seat.display().to_string());
    world.launch(&request);
    let probe = world.probe("KEN-SR", 1);
    // The launch records its bypass consent in the settings before the
    // window, through the link.
    let settings = std::fs::read_to_string(&operator).unwrap();
    assert!(settings.contains("\"theme\": \"dark\""), "{settings}");
    assert!(probe.contains("replace=refused"), "{probe}");
    assert!(
        probe.contains(&format!("settings={}", settings.trim_end())),
        "{probe}"
    );
    assert!(probe.contains("folder=projects written"), "{probe}");
    assert_eq!(std::fs::read_link(&link).unwrap(), operator);
    assert!(seat.join("projects/probe").is_file());
}

/// A Copilot seat a lane's review can run on and a Pi lane's own root keep
/// the folders their harness loads code from read-only: the lane is refused
/// a file in `extensions/`, `hooks/` and `packages/` of each, present or
/// not. The session folder each harness writes takes one: the Copilot
/// seat's `session-state/`, made by the launch in a seat otherwise
/// read-only, and `sessions/` in the Pi root, which Pi must write whole.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_is_refused_the_code_folders_of_a_copilot_seat_and_a_pi_root_and_writes_their_sessions() {
    let mut world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let copilot = outside.join("copilot1");
    std::fs::create_dir_all(copilot.join("extensions")).unwrap();
    std::fs::write(copilot.join("config.json"), "{}").unwrap();
    world.runner.env.extend([
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(),
            copilot.display().to_string(),
        ),
        ("SECOND_OPINION_MODELS".to_owned(), "copilot".to_owned()),
    ]);
    world.probe_env(
        "PROBE_RUN",
        &folder_writes(
            &copilot,
            &["extensions", "hooks", "packages", "session-state"],
        ),
    );
    world.launch(&launch_request("KEN-CP", world.runner.state_dir()));
    let probe = world.probe("KEN-CP", 1);
    for name in ["extensions", "hooks", "packages"] {
        assert!(probe.contains(&format!("folder={name} refused")), "{probe}");
    }
    assert!(probe.contains("folder=session-state written"), "{probe}");

    let root = outside.join("pi-root");
    pi_root_ready(&root);
    std::fs::create_dir_all(root.join("extensions")).unwrap();
    let seat = outside.join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let bin = outside.join("pi-bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_executable(
        &bin.join("pi"),
        "#!/bin/bash\nprintf '%s\\n' '────────────────────────────────' '────────────────────────────────' '~/work (main)' '0.4%/1.0M'\nwhile IFS= read -r _line; do :; done\n",
    );
    let probe_pi = world.runner.state_dir().join("probe-pi").join("pi");
    std::fs::create_dir_all(probe_pi.parent().unwrap()).unwrap();
    write_executable(&probe_pi, probe_script(&bin.join("pi")));
    world.runner.env.extend([
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("pi={}", probe_pi.display()),
        ),
        ("PI_CODING_AGENT_DIR".to_owned(), root.display().to_string()),
    ]);
    world.probe_env(
        "PROBE_RUN",
        &folder_writes(&root, &["extensions", "packages", "sessions"]),
    );
    let mut request = launch_request("KEN-PR", world.runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    let report = effect_report(&world.runner.op_fleet(&request));
    assert!(
        matches!(
            report["intent"]["outcome"].as_str(),
            Some("confirmed" | "unconfirmed")
        ),
        "{report}"
    );
    let probe = world.probe("KEN-PR", 1);
    for name in ["extensions", "packages"] {
        assert!(probe.contains(&format!("folder={name} refused")), "{probe}");
    }
    assert!(probe.contains("folder=sessions written"), "{probe}");
    assert!(!root.join("extensions/probe").exists());
}

/// A confined launch makes no folder in a Pi root on the host: Pi reads an
/// empty global `hooks/` as a legacy folder and waits for a key before its
/// composer, here and in every later Pi session on that root.
#[test]
#[cfg(target_os = "linux")]
fn a_pi_lane_leaves_the_pi_root_s_absent_code_folders_absent_and_starts() {
    let mut world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let root = outside.join("pi-root");
    pi_root_ready(&root);
    let seat = outside.join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let pi = world.runner.state_dir().join("pi-stub").join("pi");
    std::fs::create_dir_all(pi.parent().unwrap()).unwrap();
    write_executable(
        &pi,
        "#!/bin/bash\nif [ -e \"$PI_CODING_AGENT_DIR/hooks\" ]; then\n  echo 'Warning: Global hooks/ directory found. Press any key to continue...'\n  while :; do read -r _line || sleep 1; done\nfi\nprintf '%s\\n' '────────────────────────────────' '────────────────────────────────' '~/work (main)' '0.4%/1.0M'\nwhile IFS= read -r _line; do :; done\n",
    );
    world.runner.env.extend([
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("pi={}", pi.display()),
        ),
        ("PI_CODING_AGENT_DIR".to_owned(), root.display().to_string()),
    ]);
    let mut request = launch_request("KEN-PA", world.runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    world.launch(&request);
    for name in ["extensions", "hooks"] {
        assert!(
            std::fs::symlink_metadata(root.join(name)).is_err(),
            "{name} made in the Pi root"
        );
    }
}

/// A Pi lane is refused the global hooks the pi-hooks carrier runs in the
/// operator's next Pi session, under the Pi root's `kendex/`: the scripts
/// folder where it stands, and the registration where it was absent, whose
/// empty form the launch writes. The lane cannot rename `kendex/` away from
/// them to plant a new one, and writes its session state beside them.
#[test]
#[cfg(target_os = "linux")]
fn a_pi_lane_is_refused_the_kendex_hooks_of_its_root_and_writes_its_session_state_beside_them() {
    let mut world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let root = outside.join("pi-root");
    pi_root_ready(&root);
    let kendex = root.join("kendex");
    std::fs::create_dir_all(kendex.join("hooks")).unwrap();
    let operators_script = "#!/bin/sh\nexit 0\n";
    std::fs::write(kendex.join("hooks/guard.sh"), operators_script).unwrap();
    let seat = outside.join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let bin = outside.join("pi-bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_executable(
        &bin.join("pi"),
        "#!/bin/bash\nprintf '%s\\n' '────────────────────────────────' '────────────────────────────────' '~/work (main)' '0.4%/1.0M'\nwhile IFS= read -r _line; do :; done\n",
    );
    let probe_pi = world.runner.state_dir().join("probe-pi").join("pi");
    std::fs::create_dir_all(probe_pi.parent().unwrap()).unwrap();
    write_executable(&probe_pi, probe_script(&bin.join("pi")));
    world.runner.env.extend([
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("pi={}", probe_pi.display()),
        ),
        ("PI_CODING_AGENT_DIR".to_owned(), root.display().to_string()),
    ]);
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "(printf x > '{k}/hooks.json') 2>/dev/null && echo registry=planted || echo registry=refused\n(printf x > '{k}/hooks/guard.sh') 2>/dev/null && echo script=planted || echo script=refused\nmv '{k}' '{k}.moved' 2>/dev/null && echo kendex=moved || echo kendex=held\n{{ mkdir -p '{k}/sessions/s1' && printf x > '{k}/sessions/s1/state.json'; }} 2>/dev/null && echo sessions=written || echo sessions=refused",
            k = kendex.display()
        ),
    );
    let mut request = launch_request("KEN-PK", world.runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    let report = effect_report(&world.runner.op_fleet(&request));
    assert!(
        matches!(
            report["intent"]["outcome"].as_str(),
            Some("confirmed" | "unconfirmed")
        ),
        "{report}"
    );
    let probe = world.probe("KEN-PK", 1);
    for line in [
        "registry=refused",
        "script=refused",
        "kendex=held",
        "sessions=written",
    ] {
        assert!(probe.contains(line), "{line}: {probe}");
    }
    assert_eq!(
        std::fs::read_to_string(kendex.join("hooks.json")).unwrap(),
        "{\n  \"hooks\": {}\n}\n",
        "the absent registration stands in its empty form"
    );
    assert_eq!(
        std::fs::read_to_string(kendex.join("hooks/guard.sh")).unwrap(),
        operators_script
    );
}

/// A lane in a linked worktree is refused the main checkout's per-worktree
/// git configuration, which git reads there under `extensions.worktreeConfig`
/// and whose `core.fsmonitor` runs at the operator's next `git status`: the
/// launch writes it empty where none stood, and the lane cannot write it.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_is_refused_the_main_checkout_s_per_worktree_git_configuration() {
    let world = Confined::new();
    let state = world.runner.state_dir().to_path_buf();
    let wt = world.linked_worktree("ken-w");
    let config = state.join(".git/config.worktree");
    assert!(
        std::fs::symlink_metadata(&config).is_err(),
        "no per-worktree configuration stands before the launch"
    );
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "(printf '[core]\\n\\tfsmonitor = planted\\n' >> '{c}') 2>/dev/null && echo worktree-config=planted || echo worktree-config=refused",
            c = config.display()
        ),
    );
    world.launch(&launch_request("KEN-W", &wt));
    let probe = world.probe_in(&wt, "KEN-W", 1);
    assert!(probe.contains("worktree-config=refused"), "{probe}");
    assert_eq!(std::fs::read_to_string(&config).unwrap(), "");
}

#[test]
#[cfg(target_os = "linux")]
fn a_connected_lane_relaunches_with_fleet_state_outside_git() {
    let world = Confined::new();
    let connected = world.runner.state_dir();
    git(connected, &["config", "gc.auto", "0"]);
    git(connected, &["config", "maintenance.auto", "false"]);
    git(
        connected,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/o/connected.git",
        ],
    );
    let wt = world.linked_worktree("ken-connected");
    let executor = world.dir.path().join("executor");
    git_checkout(&executor);
    git(
        &executor,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/o/executor.git",
        ],
    );
    let runner = Runner {
        tools: world.runner.tools.clone(),
        env: world.runner.env.clone(),
        ..Runner::new(&world.server, "stub-confirm")
    };
    let settings = [("ORCH_CONNECTED_REPOS", "o/connected")];
    let init = runner.run_in(&executor, &["state", "init", "--fleet"], &settings);
    assert!(init.status.success(), "{}", stderr(&init));
    let mut fleet = runner.fleet();
    let mut stopped = lane("KEN-CONNECTED", "stopped", &runner, Value::Null);
    stopped["mail_root"] = json!(wt);
    fleet["lanes"] = json!([stopped]);
    runner.write_fleet(&fleet);

    let request = launch_request("KEN-CONNECTED", &wt);
    let report = effect_report(&runner.op_fleet_in(&executor, &request, &settings));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["intent"]["selection"]["relaunch"], true);
    assert!(report["lane"]["checkout_common"].is_null());
}

/// A Pi lane starts past Pi's "Trust project folder?", which Pi asks before
/// its composer unless its line carries `--approve` or its root's
/// `trust.json` trusts the folder, with nobody at the pane to answer.
#[test]
#[cfg(target_os = "linux")]
fn a_pi_lane_starts_past_pi_s_project_trust_question() {
    let mut world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let root = outside.join("pi-root");
    pi_root_ready(&root);
    let seat = outside.join("claude-seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    let pi = world.runner.state_dir().join("pi-stub").join("pi");
    std::fs::create_dir_all(pi.parent().unwrap()).unwrap();
    write_executable(
        &pi,
        "#!/bin/bash\napproved=\nfor a; do [ \"$a\" = --approve ] && approved=1; done\nif [ -z \"$approved\" ] && ! grep -qF \"\\\"$PWD\\\": true\" \"$PI_CODING_AGENT_DIR/trust.json\" 2>/dev/null; then\n  printf 'Trust project folder?\\n%s\\n' \"$PWD\"\n  while :; do read -r _line || sleep 1; done\nfi\nprintf '%s\\n' '────────────────────────────────' '────────────────────────────────' '~/work (main)' '0.4%/1.0M'\nwhile IFS= read -r _line; do :; done\n",
    );
    world.runner.env.extend([
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("pi={}", pi.display()),
        ),
        ("PI_CODING_AGENT_DIR".to_owned(), root.display().to_string()),
    ]);
    let mut request = launch_request("KEN-PT", world.runner.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("pi-claude/fable");
    request["account"] = json!(seat.display().to_string());
    world.launch(&request);
}

/// A seat shares its session folders by link, as an operator's seats do:
/// the lane writes its transcript where the seat's `projects` leads, outside
/// the seat, and the seat around the link stays read-only. A link that leads
/// nowhere refuses the launch by name.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_on_a_seat_whose_projects_is_a_link_writes_its_transcript_where_it_leads() {
    let world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let shared = outside.join("shared/projects");
    std::fs::create_dir_all(&shared).unwrap();
    let seat = outside.join("seat");
    std::fs::create_dir_all(&seat).unwrap();
    plant_credential(&seat);
    std::os::unix::fs::symlink(&shared, seat.join("projects")).unwrap();
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "{}\ntouch '{s}/stray' 2>/dev/null && echo stray=written || echo stray=refused",
            folder_writes(&seat, &["projects"]),
            s = seat.display()
        ),
    );
    let mut request = launch_request("KEN-SL", world.runner.state_dir());
    request["account"] = json!(seat.display().to_string());
    world.launch(&request);
    let probe = world.probe("KEN-SL", 1);
    assert!(probe.contains("folder=projects written"), "{probe}");
    assert!(probe.contains("stray=refused"), "{probe}");
    assert!(shared.join("probe").is_file());
    assert!(
        std::fs::symlink_metadata(seat.join("projects"))
            .unwrap()
            .file_type()
            .is_symlink()
    );

    let gone = outside.join("seat-gone");
    plant_credential(&gone);
    std::os::unix::fs::symlink(outside.join("shared/absent"), gone.join("projects")).unwrap();
    let mut request = launch_request("KEN-SG", world.runner.state_dir());
    request["account"] = json!(gone.display().to_string());
    let report = effect_report(&world.runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["cause"], "grant-link-unreadable", "{report}");
    assert_eq!(
        observation["path"],
        gone.join("projects").display().to_string(),
        "{report}"
    );
    assert!(std::fs::symlink_metadata(outside.join("shared/absent")).is_err());
}

/// A Codex seat whose state store and session folder are links into a
/// folder no grant names, as every operator Codex seat's are, cannot hold a
/// confined lane: Codex writes through the links into the read-only tree.
/// The lane on it launches unconfined under the cause `linked-seat`, which
/// its record names even after reconciliation, and writes through the links.
/// A seat whose one link is its settings file, read-only by design, keeps its
/// lane confined.
#[test]
#[cfg(target_os = "linux")]
fn a_codex_lane_on_a_seat_linked_outside_its_grants_runs_unconfined_by_name() {
    use std::os::unix::fs::symlink;
    let mut world = Confined::new();
    world.runner.verify = Some(1);
    let (_outside, outside) = outside_tmp();
    let codex = world.runner.state_dir().join("probe-codex").join("codex");
    std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
    write_executable(&codex, probe_script(&fixtures().join("stub-record/codex")));
    world.runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("codex={}", codex.display()),
    ));
    let shared = outside.join("shared");
    std::fs::create_dir_all(shared.join("sessions")).unwrap();
    for name in ["state_5.sqlite", "config.toml"] {
        std::fs::write(shared.join(name), "").unwrap();
    }
    let linked = outside.join("codex-linked");
    let plain = outside.join("codex-plain");
    for seat in [&linked, &plain] {
        std::fs::create_dir_all(seat).unwrap();
        std::fs::write(seat.join("auth.json"), "{}").unwrap();
        symlink(shared.join("config.toml"), seat.join("config.toml")).unwrap();
    }
    for name in ["state_5.sqlite", "sessions"] {
        symlink(shared.join(name), linked.join(name)).unwrap();
    }
    for (item, seat, confinement) in [
        (
            "KEN-CL",
            &linked,
            json!({"state": "unconfined", "cause": "linked-seat"}),
        ),
        ("KEN-CU", &plain, json!({"state": "confined"})),
    ] {
        world.file_env(&seat.join("state_5.sqlite").display().to_string());
        world.probe_env("PROBE_RUN", &folder_writes(seat, &["sessions"]));
        let mut request = launch_request(item, world.runner.state_dir());
        request["harness"] = json!("codex");
        request["account"] = json!(seat.display().to_string());
        let report = effect_report(&world.runner.op_fleet(&request));
        assert_ne!(report["intent"]["outcome"], "failed", "{item}: {report}");
        assert_eq!(
            report["intent"]["observation"]["confinement"], confinement,
            "{item}: {report}"
        );
        if seat == &linked {
            assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
            let replay = world.runner.reconcile_one();
            assert_eq!(replay["intent"]["id"], report["intent"]["id"], "{replay}");
            assert_eq!(
                world.runner.fleet()["intents"][0]["observation"]["confinement"],
                confinement,
                "{replay}"
            );
        }
        let probe = world.probe(item, 1);
        assert!(
            probe.contains("file=state_5.sqlite written"),
            "{item}: {probe}"
        );
        assert!(probe.contains("folder=sessions written"), "{item}: {probe}");
    }
    assert!(shared.join("sessions/probe").is_file());
    // A read-only lane holds no path only while its grants hold it.
    let mut request = launch_request("KEN-CR", world.runner.state_dir());
    request["harness"] = json!("codex");
    request["account"] = json!(linked.display().to_string());
    request["read_only"] = json!(true);
    let report = effect_report(&world.runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(
        (&observation["cause"], &observation["detail"]),
        (&json!("read-only-unconfined"), &json!("linked-seat")),
        "{report}"
    );
}

/// The pane hands the lane a temporary-folder variable naming a host folder,
/// as a user service manager publishes `CLAUDE_CODE_TMPDIR`: inside the
/// wrapper it names the wrapper's own `/tmp`, which the lane writes, and the
/// host folder takes nothing.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_whose_pane_names_a_host_temporary_folder_writes_the_wrapper_s_own() {
    let world = Confined::new();
    let (_outside, outside) = outside_tmp();
    let host = outside.join("claude-tmp");
    std::fs::create_dir_all(&host).unwrap();
    world.probe_env("CLAUDE_CODE_TMPDIR", &host.display().to_string());
    world.probe_env(
        "PROBE_RUN",
        "echo \"claude_tmp=$CLAUDE_CODE_TMPDIR\"; mkdir -p \"$CLAUDE_CODE_TMPDIR/claude-1\" 2>/dev/null && echo claude_tmp=written || echo claude_tmp=refused",
    );
    world.launch(&launch_request("KEN-T", world.runner.state_dir()));
    let probe = world.probe("KEN-T", 1);
    assert!(probe.contains("claude_tmp=/tmp\n"), "{probe}");
    assert!(probe.contains("claude_tmp=written"), "{probe}");
    assert_eq!(std::fs::read_dir(&host).unwrap().count(), 0);
}

/// A confined lane's `gh` reads the token the launch handed it, the bus it
/// would read a login over hidden; the token's file is the lane's alone and
/// is gone after the close.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_s_gh_reads_the_handed_token_with_the_bus_hidden_and_the_close_removes_its_file() {
    use std::os::unix::fs::PermissionsExt;
    let world = Confined::new();
    let report = world.launch(&launch_request("KEN-G", world.runner.state_dir()));
    assert_eq!(
        report["intent"]["observation"]["gh_token"], "handed",
        "{report}"
    );
    let probe = world.probe("KEN-G", 1);
    assert!(probe.contains("bus=hidden"), "{probe}");
    assert!(probe.contains("gh=bus-login-token"), "{probe}");
    let token = world
        .runner
        .state_dir()
        .join("tmp/lane-mail/KEN-G/gh-token");
    let mode = std::fs::metadata(&token).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let closed = effect_report(&world.runner.op_fleet(&terminal_close("KEN-G")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert!(
        std::fs::symlink_metadata(&token).is_err(),
        "the token's file is gone after the close"
    );
}

/// A repository's own tool folder the overseer's `ORCH_LANE_WRITABLE`
/// names is written by the lane, its sibling refused; the launch record
/// names what was granted.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_writes_the_folder_its_overseer_s_setting_names_and_is_refused_its_sibling() {
    let mut world = Confined::new();
    let tools = world.dir.path().join("repo-tools");
    let [named, sibling] = ["go-mod", "gradle"].map(|name| tools.join(name));
    for dir in [&named, &sibling] {
        std::fs::create_dir_all(dir).unwrap();
    }
    world
        .runner
        .env
        .push(("ORCH_LANE_WRITABLE".to_owned(), named.display().to_string()));
    world.seat_env(&format!("{} {}", named.display(), sibling.display()));
    let report = world.launch(&launch_request("KEN-W", world.runner.state_dir()));
    let probe = world.probe("KEN-W", 1);
    assert!(probe.contains("seat=go-mod written"), "{probe}");
    assert!(probe.contains("seat=gradle refused"), "{probe}");
    assert_eq!(
        report["intent"]["observation"]["lane_writable"],
        json!([std::fs::canonicalize(&named).unwrap()]),
        "{report}"
    );
}

/// The home itself named in `ORCH_LANE_WRITABLE` would unconfine the lane:
/// the launch refuses it by name before any window.
#[test]
#[cfg(target_os = "linux")]
fn the_home_named_in_the_lane_writable_setting_refuses_the_launch() {
    let mut world = Confined::new();
    let home = world.dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    world.runner.env.extend([
        ("HOME".to_owned(), home.display().to_string()),
        ("ORCH_LANE_WRITABLE".to_owned(), home.display().to_string()),
    ]);
    let report = effect_report(
        &world
            .runner
            .op_fleet(&launch_request("KEN-H", world.runner.state_dir())),
    );
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"], "lane-writable-home",
        "{report}"
    );
    assert_eq!(world.server.panes().len(), 1, "no window opened");
}

/// A lane's tools build and cache in caches of its own in its tree, each
/// named by the variable its tool reads, while the operator's stay
/// read-only: Cargo's extracted sources, build scripts and git checkouts an
/// unconfined build compiles, and the cache folder's package managers and
/// runtimes, kendex's among them, which unconfined programs run.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_builds_in_caches_of_its_own_and_is_refused_the_operator_s_build_inputs() {
    let mut world = Confined::new();
    let cargo = world.dir.path().join("cargo");
    let cache = world.dir.path().join("cache");
    let operators = [
        cargo.join("registry/src/index.crates.io-0/dep-1.0.0/build.rs"),
        cargo.join("registry/src/index.crates.io-0/dep-1.0.0/src/lib.rs"),
        cargo.join("registry/cache/index.crates.io-0/dep-1.0.0.crate"),
        cargo.join("git/checkouts/dep-0/abc1234/src/main.rs"),
        cargo.join("config.toml"),
        cache.join("node/corepack/pnpm/9.0.0/dist/pnpm.cjs"),
        cache.join("kendex/agent-runtime/bin/agent-runtime-k"),
    ];
    for file in &operators {
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, "operator\n").unwrap();
    }
    world.runner.env.extend([
        ("CARGO_HOME".to_owned(), cargo.display().to_string()),
        ("XDG_CACHE_HOME".to_owned(), cache.display().to_string()),
    ]);
    world.file_env(
        &operators
            .iter()
            .map(|f| f.display().to_string())
            .collect::<Vec<_>>()
            .join(" "),
    );
    let tmp = std::fs::canonicalize(world.runner.state_dir())
        .unwrap()
        .join("tmp");
    // (variable, the lane's own folder it names)
    let own = [
        ("CARGO_HOME", tmp.join("cargo-home")),
        ("npm_config_cache", tmp.join("npm-cache")),
        ("XDG_CACHE_HOME", tmp.join("cache-home")),
    ];
    world.probe_env(
        "PROBE_RUN",
        &own.iter()
            .map(|(var, _)| {
                format!("echo \"{var}=${var}\"; touch \"${var}/probe\" 2>/dev/null && echo \"own={var} written\" || echo \"own={var} refused\"")
            })
            .collect::<Vec<_>>()
            .join("\n"),
    );
    world.launch(&launch_request("KEN-K", world.runner.state_dir()));
    let probe = world.probe("KEN-K", 1);
    for file in &operators {
        let name = file.file_name().unwrap().to_string_lossy();
        assert!(
            probe.contains(&format!("file={name} refused")),
            "{name}: {probe}"
        );
    }
    for (var, dir) in &own {
        assert!(
            probe.contains(&format!("{var}={}\n", dir.display())),
            "{var}: {probe}"
        );
        assert!(
            probe.contains(&format!("own={var} written")),
            "{var}: {probe}"
        );
        assert!(dir.join("probe").is_file(), "{var}");
    }
}

/// A confined lane runs its runtimes from a cache of its own in its tree:
/// its line names the folder, which links the shared cache's binaries, and
/// the lane writes it. kendex's folder under the cache folder, whose sources
/// an unconfined kendex installs from, and the shared runtime cache, whose
/// binaries unconfined programs run, stay read-only whatever writable grant
/// meets them: one holding both, one inside either, and one holding both
/// through a cache folder that is a link while kendex's folder is not made.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_runs_its_runtimes_from_its_own_cache_and_cannot_write_kendex_s_or_the_shared_one_whatever_grant_meets_them()
 {
    /// One way a writable grant meets kendex's folder and the shared cache.
    struct Row {
        case: &'static str,
        /// The cache folder is a link to the folder it names.
        linked: bool,
        /// The `ORCH_LANE_WRITABLE` entry under the cache folder, "" the
        /// folder itself.
        granted: &'static str,
        /// The `AGENT_RUNTIME_CACHE` under the cache folder, none for
        /// kendex's default.
        named: Option<&'static str>,
        kendex_stands: bool,
        sibling_written: bool,
    }
    let rows = [
        Row {
            case: "cache folder",
            linked: false,
            granted: "",
            named: Some("runtimes"),
            kendex_stands: true,
            sibling_written: true,
        },
        Row {
            case: "kendex's sources",
            linked: false,
            granted: "kendex/sources",
            named: None,
            kendex_stands: true,
            sibling_written: false,
        },
        Row {
            case: "shared cache's bin",
            linked: false,
            granted: "runtimes/bin",
            named: Some("runtimes"),
            kendex_stands: true,
            sibling_written: false,
        },
        Row {
            case: "linked cache folder",
            linked: true,
            granted: "",
            named: Some("runtimes"),
            kendex_stands: false,
            sibling_written: true,
        },
    ];
    for Row {
        case,
        linked,
        granted,
        named,
        kendex_stands,
        sibling_written,
    } in rows
    {
        let mut world = Confined::new();
        let cache = world.dir.path().join("cache");
        if linked {
            let target = world.dir.path().join("cache-target");
            std::fs::create_dir_all(&target).unwrap();
            std::os::unix::fs::symlink(&target, &cache).unwrap();
        }
        let shared = cache.join(named.unwrap_or("kendex/agent-runtime"));
        let source = cache.join("kendex/sources/catalog/skills/dev/SKILL.md");
        std::fs::create_dir_all(shared.join("bin")).unwrap();
        std::fs::create_dir_all(cache.join("go-build")).unwrap();
        if kendex_stands {
            std::fs::create_dir_all(source.parent().unwrap()).unwrap();
            std::fs::write(&source, "operator\n").unwrap();
        }
        assert_eq!(cache.join("kendex").exists(), kendex_stands, "{case}");
        write_executable(&shared.join("bin/agent-runtime-k"), "#!/bin/sh\n");
        let grant = if granted.is_empty() {
            cache.clone()
        } else {
            cache.join(granted)
        };
        world.runner.env.extend([
            ("XDG_CACHE_HOME".to_owned(), cache.display().to_string()),
            ("ORCH_LANE_WRITABLE".to_owned(), grant.display().to_string()),
        ]);
        if named.is_some() {
            world.runner.env.push((
                "AGENT_RUNTIME_CACHE".to_owned(),
                shared.display().to_string(),
            ));
        }
        let own = std::fs::canonicalize(world.runner.state_dir())
            .unwrap()
            .join("tmp/runtime-cache");
        // (target, a file the probe makes its folder for and appends to,
        // written)
        let targets = [
            ("own", own.join("probe"), true),
            ("sibling", cache.join("go-build/probe"), sibling_written),
            ("kendex", source.clone(), false),
            ("shared", shared.join("bin/agent-runtime-k"), false),
        ];
        world.probe_env(
            "PROBE_RUN",
            &targets
                .iter()
                .map(|(name, file, _)| {
                    format!(
                        "( mkdir -p \"{dir}\" && : >> \"{file}\" ) 2>/dev/null && echo \"target={name} written\" || echo \"target={name} refused\"",
                        dir = file.parent().unwrap().display(),
                        file = file.display()
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
        );
        world.launch(&launch_request("KEN-J", world.runner.state_dir()));
        let probe = world.probe("KEN-J", 1);
        assert!(
            probe.contains(&format!("cache={}\n", own.display())),
            "{case}: {probe}"
        );
        for (name, _, written) in &targets {
            let want = if *written { "written" } else { "refused" };
            assert!(
                probe.contains(&format!("target={name} {want}\n")),
                "{case}: {name} {want}: {probe}"
            );
        }
        assert_eq!(
            std::fs::canonicalize(own.join("bin/agent-runtime-k")).unwrap(),
            std::fs::canonicalize(shared.join("bin/agent-runtime-k")).unwrap(),
            "{case}: the own cache links the shared binary"
        );
    }
}

/// A lane in a linked worktree writes its own item's folder of the
/// overseer's state directory and nothing else of it: the directory itself,
/// so the fleet record, and another item's folder are refused, and so is
/// another lane's marker under the common git folder it otherwise writes.
#[test]
#[cfg(target_os = "linux")]
fn a_lane_writes_its_item_s_folder_and_is_refused_the_state_directory_another_item_s_and_a_marker()
{
    let world = Confined::new();
    let state = world.runner.state_dir().to_path_buf();
    let wt = world.linked_worktree("ken-i");
    let other = support::item_record(&state, "KEN-O");
    std::fs::write(&other, "{}\n").unwrap();
    let marker = state.join(".git/lane-mail/ken-o");
    std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
    std::fs::write(&marker, "/elsewhere\n").unwrap();
    let own = orch_runtime::state::item_dir(&state, "KEN-I");
    world.seat_env(&format!(
        "{} {} {}",
        own.display(),
        other.parent().unwrap().display(),
        state.display()
    ));
    world.file_env(&format!(
        "{} {}",
        state.join("workflow-state-oversee.json").display(),
        marker.display()
    ));
    world.launch(&launch_request("KEN-I", &wt));
    let probe = world.probe_in(&wt, "KEN-I", 1);
    let named = state.file_name().unwrap().to_string_lossy().into_owned();
    for line in [
        "seat=KEN-I written".to_owned(),
        "seat=KEN-O refused".to_owned(),
        format!("seat={named} refused"),
        "file=workflow-state-oversee.json refused".to_owned(),
        "file=ken-o refused".to_owned(),
    ] {
        assert!(probe.contains(&line), "{line}: {probe}");
    }
}

/// A `read_only` lane's confinement binds its checkout read-only bar its
/// `tmp`: in a linked worktree it is refused a tracked file and the common
/// git folder and writes its `tmp`, where a writing lane beside it writes
/// all three.
#[test]
#[cfg(target_os = "linux")]
fn a_read_only_lane_writes_its_checkout_s_tmp_and_nothing_else_of_its_checkout() {
    let world = Confined::new();
    let common = world.runner.state_dir().join(".git");
    for (item, read_only, checkout) in [("KEN-W", false, "written"), ("KEN-O", true, "refused")] {
        let wt = world.linked_worktree(&item.to_ascii_lowercase());
        let out = wt.join("tmp");
        world.probe_env("PROBE_OUT", &out.display().to_string());
        world.file_env(&format!(
            "{} {} {}",
            wt.join("tracked.txt").display(),
            common.join(format!("planted-{item}")).display(),
            out.join("scratch.txt").display()
        ));
        let mut request = launch_request(item, &wt);
        request["read_only"] = json!(read_only);
        world.launch(&request);
        let probe = world.probe_in(&out, item, 1);
        for line in [
            format!("file=tracked.txt {checkout}"),
            format!("file=planted-{item} {checkout}"),
            "file=scratch.txt written".to_owned(),
        ] {
            assert!(probe.contains(&line), "{item}: {line}: {probe}");
        }
    }
}

/// A confined lane's job writes its end notice's scratch in the lane's own
/// worktree, which its grants hold: the job's end reaches its send, and the
/// state directory takes no new file.
#[test]
#[cfg(target_os = "linux")]
fn a_confined_lane_s_job_end_writes_its_notice_in_its_worktree_and_nothing_in_the_state_directory()
{
    let world = Confined::new();
    let state = world.runner.state_dir().to_path_buf();
    let wt = world.linked_worktree("ken-j");
    world.probe_env(
        "PROBE_RUN",
        &format!(
            "'{}' launch-job --name probe-job --run \"$PWD/tmp/probe-job\" --owner KEN-J -- true",
            support::binary().display()
        ),
    );
    world.launch(&launch_request("KEN-J", &wt));
    world.probe_in(&wt, "KEN-J", 1);
    let log = wt.join("tmp/probe-job.log");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mark = loop {
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        if let Some(mark) = text.lines().find_map(|l| l.strip_prefix("job-end-notice=")) {
            break mark.to_owned();
        }
        assert!(Instant::now() < deadline, "the job's end: {text}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(!mark.starts_with("unsent:notice-"), "{mark}");
    assert!(wt.join("tmp/validate").is_dir(), "{mark}");
    assert!(!state.join("validate").exists(), "{mark}");
}

/// A worktree whose `tmp` links outside it shares the link's target with
/// whatever else stands there: a confined launch is refused by name before
/// any window, naming the link and where it leads.
#[test]
#[cfg(target_os = "linux")]
fn a_confined_launch_refuses_a_worktree_tmp_that_links_outside_it() {
    let world = Confined::new();
    let wt = world.linked_worktree("ken-l");
    let shared = world.dir.path().join("shared-tmp");
    std::fs::create_dir_all(&shared).unwrap();
    std::os::unix::fs::symlink(&shared, wt.join("tmp")).unwrap();
    let report = effect_report(&world.runner.op_fleet(&launch_request("KEN-L", &wt)));
    let observation = &report["intent"]["observation"];
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(observation["cause"], "grant-tmp-linked", "{report}");
    assert_eq!(
        observation["path"],
        std::fs::canonicalize(&wt)
            .unwrap()
            .join("tmp")
            .display()
            .to_string(),
        "{report}"
    );
    assert_eq!(
        observation["target"],
        std::fs::canonicalize(&shared)
            .unwrap()
            .display()
            .to_string(),
        "{report}"
    );
    assert_eq!(world.server.panes().len(), 1, "no window opened");
}
