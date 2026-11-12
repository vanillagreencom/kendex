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
    // The identity is the pane's foreground process, the stub itself, which
    // the kernel names for the harness.
    let pid = launch["pid"].as_u64().expect("the pane process pid") as u32;
    assert_eq!(launch["pane"].as_str().unwrap(), {
        let pane = launch["pane"].as_str().unwrap();
        assert_eq!(server.pane_pid(pane), pid);
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
    fleet["overseer"] = json!({"runtime": "tmux", "generation": 4, "pane": "%0"});
    fleet["intents"] = json!([transfer_intent(None, None)]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["reconciled"], "intent-stale");
    assert_eq!(report["intent"]["observed_generation"], 4);
    assert_eq!(runner.fleet()["overseer"]["generation"], 4, "unmoved");
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
    let harness_pid = server.pane_pid(&pane);
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
    let harness_pid = server.pane_pid(&pane);
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
    fleet["overseer"] = overseer_record(predecessor.0, predecessor.1, server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
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
    let mut phase = phase(
        "delivered",
        server,
        pane,
        since_ms,
        Some(Path::new("/h/handoff.md")),
    );
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
                fleet["intents"][0]["selection"] = json!({"harness": "nosuch"});
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
                    runner.fleet()["overseer"]["pending"],
                    original_pending(),
                    "the original pending is put back"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["pending"], original_pending());
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
                let overseer = runner.fleet()["overseer"].clone();
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                let overseer = runner.fleet()["overseer"].clone();
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert!(runner.fleet()["overseer"]["pending"]["runner"].is_object());
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
                fleet["overseer"]["pending"]["cwd"] = json!("/nonexistent/successor/dir");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "cwd-missing");
                assert_eq!(report["intent"]["observation"]["retired"], true);
                let overseer = runner.fleet()["overseer"].clone();
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
                fleet["overseer"].as_object_mut().unwrap().remove("pending");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pending-missing");
                assert_eq!(report["intent"]["observation"]["runner"], "stopped");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 4);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert!(
                    runner.fleet()["overseer"]["pending"]["runner"].is_object(),
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert_eq!(
                    runner.fleet()["overseer"]["pending"]["runner"]["pane"],
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 4);
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
            check: |runner, _, _| assert_eq!(runner.fleet()["overseer"]["generation"], 4),
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
                let kept = runner.fleet()["overseer"]["pending"]["runner"].clone();
                assert_eq!(kept["pane"], "%1");
                assert!(
                    kept["pid"].as_u64().is_some(),
                    "the recorded identity is kept"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(runner.fleet()["overseer"]["pending"], original_pending());
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
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
                assert_eq!(fleet["overseer"]["generation"], 3);
                assert_eq!(
                    fleet["overseer"]["pending"],
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
                assert_eq!(runner.fleet()["overseer"]["pending"], original_pending());
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
                assert_eq!(fleet["overseer"]["pending"], original_pending());
                assert_eq!(fleet["overseer"]["generation"], 3);
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

/// A relaunch on another account than the bound session's recorded one
/// starts fresh with `account-switched`; one whose destination home holds
/// no file for the fixed id starts fresh with `session-absent`, its own
/// cause, the account unchanged. The stub refuses a
/// resume of a session its home does not hold, as the harness does, so a
/// relaunch that resumed across accounts would fail here; one on the same
/// account resumes the bound session.
#[test]
fn a_relaunch_on_another_account_starts_fresh_and_the_same_account_resumes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-resume");
    runner.init_fleet();
    let a = dir.path().join("a");
    let b = dir.path().join("b");
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();
    let request = |account: &Path| {
        json!({
            "op": "launch-lane",
            "item": "KEN-R",
            "harness": "claude",
            "mail_root": runner.state_dir().display().to_string(),
            "account": account.display().to_string(),
            "model": "claude-fable-5-1",
            "effort": "high",
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
/// startup.
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
    let mut child = runner.spawn_op_fleet(
        &launch_request("KEN-C", runner.state_dir()),
        &[
            ("TMUX_REAL", real.as_str()),
            ("TMUX_HOLD_FIFO", fifo_s.as_str()),
            ("TMUX_HOLD_MARK", mark_s.as_str()),
            ("TMUX_HOLD_VERB", "capture-pane"),
            ("TMUX_HOLD_OPENED", opened_s.as_str()),
            ("TMUX_HOLD_READY_COMM", "claude"),
        ],
        &fixtures().join("tmux-hold"),
    );
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
        "claude",
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

/// A `send_line` reply reported failed may have run the line, which writes
/// the receipt and execs the harness. The pane is closed and the receipt
/// read, not assumed absent, so a live registered pid stands and the launch
/// holds rather than settling `failed` over a running harness.
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
    runner.tools = Some(tools);
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-N", runner.state_dir())));
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
        // The recorded root: a bash whose child is a sleep named `claude`, so
        // the kernel names it as the recorded harness's own process.
        let claude = dir.path().join("claude");
        std::os::unix::fs::symlink("/bin/sleep", &claude).unwrap();
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
fn close_lane_with_worktree(runner: &Runner, item: &str, wt: &Path) -> Value {
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane(item, runner, wt)]);
    runner.write_fleet(&fleet);
    close_with_worktree(runner, item)
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

/// The report of `item`'s terminal close with the worktree package at
/// `cli` as `WORKTREE_CLI`.
fn close_with_worktree_cli(runner: &Runner, item: &str, cli: &str) -> Value {
    effect_report(&runner.op_fleet_env(&terminal_close(item), &[("WORKTREE_CLI", cli)]))
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
fn close_with_worktree(runner: &Runner, item: &str) -> Value {
    close_with_worktree_cli(runner, item, &worktree_cli())
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
        let report = close_with_worktree(&runner, "KEN-W");
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

/// An idle local lane whose merge landed, its item still open on its
/// tracker and its worktree standing: while the item's live state record
/// stands the lane may be at work on it, so `close-lane` refuses
/// `lane-live state=idle` and touches neither the harness nor the
/// worktree. Once the item's close-out removed that record the close ends
/// the lane on its merge, its harness stopped before the worktree is
/// released, so the session never runs on in a removed directory.
#[test]
fn a_merged_lane_whose_close_out_is_done_is_stopped_before_its_worktree_is_released() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    let replies = runner.state_dir().join("linear.json");
    // The lane completed its boxes: the item reads Verifying with none open.
    let open = json!({
        "issues bulk-get": {"body": {"issues": {"nodes": [
            {"identifier": "KEN-W", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}
        ]}}},
        "issues get": {"body": {"issue": {"description": "", "state": {"name": "Verifying", "type": "started"}}}},
    });
    std::fs::write(&replies, open.to_string()).unwrap();
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
    let (_repo, wt) = worktree_fixture(dir.path());
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-W", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
    let pid = launched["lane"]["launch"]["pid"].as_u64().unwrap() as u32;
    let mut fleet = runner.fleet();
    fleet["lanes"][0]["mail_root"] = json!(wt.display().to_string());
    fleet["lanes"][0]["cycle"] = json!({"pr": 7});
    fleet["lanes"][0]["repo"] = json!("o/r");
    runner.write_fleet(&fleet);
    let record = runner.state_dir().join("workflow-state-KEN-W.json");
    std::fs::write(&record, "{}\n").unwrap();
    let close = json!({"op": "close-lane", "item": "KEN-W"});
    // The worktree package as planted: it records whether the harness runs
    // when the release asks it to remove the worktree, then removes it.
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
    let cli = cli.display().to_string();
    let worktree = [("WORKTREE_CLI", cli.as_str())];

    let answer = reply(&runner.op_fleet_env(&close, &worktree));
    assert_eq!(answer["refusal"]["key"], "lane-live", "{answer}");
    assert_eq!(
        refusal_field(&answer, "state"),
        Some("idle".to_owned()),
        "{answer}"
    );
    assert!(live(pid), "a refused close stops nothing");
    assert!(wt.exists(), "a refused close removes nothing");

    std::fs::remove_file(&record).unwrap();
    let answer = reply(&runner.op_fleet_env(&close, &worktree));
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{answer}");
    assert!(!live(pid), "the harness is stopped");
    assert!(!wt.exists(), "the clean merged worktree is released");
    assert_eq!(
        std::fs::read_to_string(&saw).unwrap().trim(),
        "gone",
        "the harness is stopped before the worktree's release: {answer}"
    );
}

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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
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
    let report = close_with_worktree(&runner, "KEN-H");
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
    let report = close_lane_with_worktree(&runner, "KEN-T", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-N", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-C", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-U", &wt);
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
        let report = close_lane_with_worktree(&runner, "KEN-A", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-I", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-D", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-H", &wt);
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
    let report = close_lane_with_worktree(&runner, "KEN-G", &wt);
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
    let report = close_with_worktree(&runner, "KEN-M");
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
    let report = close_with_worktree(&runner, "KEN-R");
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
    let report = close_with_worktree(&runner, "KEN-J");
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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    let mut lane = worktree_lane("KEN-S", &runner, &wt);
    lane["kept"] = json!("dirty");
    lane["kept_mail"] = json!("/stale");
    fleet["lanes"] = json!([lane]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, "KEN-S");
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
    let (_repo, wt) = claim_worktree_fixture(runner.state_dir());
    let tracked = git(&wt, &["ls-files"]);
    assert!(
        !tracked.is_empty() && git(&wt, &["ls-files", "--deleted"]) == tracked,
        "the claim holds every tracked file in its index and none on disk: {tracked:?}"
    );
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([cloud_lane("KEN-C", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, "KEN-C");
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
    let (_repo, wt) = claim_worktree_fixture(runner.state_dir());
    let draft = wt.join("draft.txt");
    std::fs::write(&draft, "x\n").unwrap();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([cloud_lane("KEN-D", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let report = close_with_worktree(&runner, "KEN-D");
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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-N", &runner, &wt)]);
    runner.write_fleet(&fleet);
    let missing = runner.state_dir().join("no-such-package/worktree");
    let report = close_with_worktree_cli(&runner, "KEN-N", &missing.display().to_string());
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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([worktree_lane("KEN-U", &runner, &wt)]);
    runner.write_fleet(&fleet);
    // The worktree itself unreadable: its own metadata reads, its entries
    // (its `.git`, its runs under `tmp/`) do not.
    std::fs::set_permissions(&wt, std::fs::Permissions::from_mode(0o000)).unwrap();
    let unread = std::fs::metadata(wt.join(".git")).is_err();
    let report = close_with_worktree(&runner, "KEN-U");
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
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([row]);
        runner.write_fleet(&fleet);
        if fields.get("host").is_some() {
            // The hosted lane's sandbox is its provider's to close, through
            // the `lane-host` the project's scripts directory holds.
            let scripts = runner.state_dir().join(".agents/skills/orch/scripts");
            std::fs::create_dir_all(&scripts).unwrap();
            std::os::unix::fs::symlink(
                fixtures().join("lane-host/lane-host"),
                scripts.join("lane-host"),
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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
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
    let mut child = runner.spawn_op_fleet(
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
    let report = close_with_worktree(&runner, "KEN-X");
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
    let (_repo, wt) = worktree_fixture(runner.state_dir());
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
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-MW")));
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
/// linked where an apply puts them, built through their real setup over
/// agent-runtime's planted cargo into the row's cache before the window
/// opens, so the lane's first turn end can read its mail; a build that fails
/// refuses the launch with no window and no marker.
#[test]
fn a_launch_builds_its_installs_runtimes_before_the_window_and_a_failed_build_opens_none() {
    let dir = tempfile::tempdir().unwrap();
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
    let cache = dir.path().join("cache");
    let log = dir.path().join("cargo.log");
    runner.env.push((
        "AGENT_RUNTIME_CACHE".to_owned(),
        cache.display().to_string(),
    ));
    runner
        .env
        .push(("FAKE_CARGO_LOG".to_owned(), log.display().to_string()));

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
            .is_some_and(|line| line.starts_with("orch-runtime-setup: build-failed status=1 key=")),
        "the setup's own refusal: {report}"
    );
    assert_eq!(server.panes().len(), 1, "no window opened");
    assert_eq!(marker_of(&root, "KEN-B"), None, "no marker written");

    let report = effect_report(&runner.op_fleet(&launch_request("KEN-C", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let mut built: Vec<String> = std::fs::read_dir(cache.join("bin"))
        .unwrap()
        .map(|entry| {
            let name = entry.unwrap().file_name().into_string().unwrap();
            name.rsplit_once('-').unwrap().0.to_owned()
        })
        .collect();
    built.sort();
    assert_eq!(
        built,
        ["agent-runtime", "orch-runtime"],
        "both runtimes built"
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
        [canonical(&orch), canonical(&orch), canonical(&agent)],
        "the failed orch build, then each package's own runtime"
    );
}

/// The hosted launch's world: the provider fixture as the project's
/// `lane-host`, its answers planted by argv, the ssh client fixture and the
/// stub harness on the runtime's path, and a "host" worktree on this disk.
struct HostedLaunch {
    runner: Runner,
    scripts: PathBuf,
    tools: PathBuf,
    host_path: PathBuf,
}

const PROVIDER_PATH: &str = "/w/provider";

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
            scripts.join("lane-host"),
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
        };
        world.plant(record);
        world
    }

    fn host(&self) -> String {
        self.host_path.display().to_string()
    }

    /// The provider's answers for one launch of `KEN-H`: the static ssh
    /// line with a local pane, a create naming this disk's worktree, the
    /// worktree's `.git` naming a clone, no marker until the launch puts
    /// one (its second read answers the root), and the launch record
    /// `record`.
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

    fn request(&self) -> Value {
        json!({
            "op": "launch-lane",
            "item": "KEN-H",
            "harness": "claude",
            "mail_root": self.runner.state_dir().display().to_string(),
            "account": self.runner.state_dir().display().to_string(),
            "model": "claude-fable-5-1",
            "effort": "high",
            "host": PROVIDER_PATH,
            "repo": "o/r",
        })
    }
}

#[test]
fn a_hosted_launch_runs_the_providers_verbs_and_opens_its_window_over_ssh() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    let panes_before = server.panes().len();
    let report = effect_report(&world.runner.op_fleet(&world.request()));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = &report["lane"];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["host"], PROVIDER_PATH);
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
            format!("ORCH_LANE_HOST={PROVIDER_PATH} capabilities"),
            format!(
                "ORCH_LANE_HOST={PROVIDER_PATH} create --item KEN-H --repo o/r --harness claude --account {account}"
            ),
            format!("ORCH_LANE_HOST={PROVIDER_PATH} cat --item KEN-H {host}/.git"),
            format!(
                "ORCH_LANE_HOST={PROVIDER_PATH} cat --item KEN-H /srv/clone/.git/lane-mail/ken-h"
            ),
            format!("ORCH_LANE_HOST={PROVIDER_PATH} touch --item KEN-H"),
            format!(
                "ORCH_LANE_HOST={PROVIDER_PATH} put --item KEN-H /srv/clone/.git/lane-mail/ken-h"
            ),
            format!(
                "ORCH_LANE_HOST={PROVIDER_PATH} cat --item KEN-H /srv/clone/.git/lane-mail/ken-h"
            ),
            format!(
                "ORCH_LANE_HOST={PROVIDER_PATH} cat --item KEN-H /srv/clone/.git/lane-launch/ken-h.json"
            ),
        ],
        "the provider's verbs in order, each under the record's host: the marker the host lacked is put and read back before the record is read"
    );
    let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
    assert!(
        ssh.starts_with("-t -o BatchMode=yes -o ConnectTimeout=5 -- lane.example exec bash -c "),
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

/// A create whose line adds `tree=unrebased`, the shipped ssh provider's
/// answer where it kept the item's retained tree on its own head
/// (`lane-host-ssh-tests.py`'s conflicting relaunch): the launch goes on in
/// that tree, its observation names the tree, and the brief closes by
/// telling the lane its restack is its own.
#[test]
fn a_hosted_create_that_kept_the_tree_unrebased_opens_and_tells_the_lane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    let answers_path = world.scripts.join("lane-host.json");
    let mut answers: Value =
        serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
    let account = world.runner.state_dir().display().to_string();
    answers[format!("create --item KEN-H --repo o/r --harness claude --account {account}")] = json!({
        "stdout": format!("ssh-target=lane.example\tpath={}\tremote-prefix=exec bash -c\ttree=unrebased\n", world.host())
    });
    std::fs::write(&answers_path, answers.to_string()).unwrap();
    let brief = dir.path().join("brief.md");
    std::fs::write(&brief, "/orch start KEN-H\n").unwrap();
    let mut request = world.request();
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&world.runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["lane"]["mail_root"], world.host(), "{report}");
    assert_eq!(
        report["intent"]["observation"]["tree"], "unrebased",
        "{report}"
    );
    let ssh = std::fs::read_to_string(world.tools.join("ssh.log")).unwrap();
    assert!(
        ssh.contains("this tree is not rebased. The restack is yours to run."),
        "the lane is told its tree is kept unrebased: {ssh}"
    );
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

/// Through the real `lane-host`: a launch whose `op` ends inside the
/// provider's create leaves the phase it recorded before it, and the
/// reconcile holds the launch `host-create-unknown`, the lane `preparing`
/// and its slot charged, since the provider may hold a sandbox for it; the
/// next launch request meets that held launch and asks no create; a close
/// supersedes it, its provider close confirmed by `list`, and ends the
/// record. A create the provider's lock then refuses fails
/// `host-create-busy`, the create's own refusal, which charges nothing; the
/// next create reuses what the provider holds and opens.
#[test]
fn a_hosted_create_whose_answer_is_lost_holds_its_launch_until_a_close_confirms_the_sandbox_gone() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    // The shipped dispatcher in the fixture's place, its libraries beside
    // it as an install lays them out; the fixture is the provider it runs.
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts");
    let provider = dir.path().join("provider");
    std::fs::create_dir_all(&provider).unwrap();
    std::fs::rename(
        world.scripts.join("lane-host.json"),
        provider.join("lane-host.json"),
    )
    .unwrap();
    std::fs::remove_file(world.scripts.join("lane-host")).unwrap();
    std::os::unix::fs::symlink(shipped.join("lane-host"), world.scripts.join("lane-host")).unwrap();
    std::os::unix::fs::symlink(shipped.join("lib"), world.scripts.join("lib")).unwrap();
    std::os::unix::fs::symlink(
        shipped.join("../../mailbox"),
        world.scripts.join("../../mailbox"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("lane-host/lane-host"),
        provider.join("lane-host"),
    )
    .unwrap();
    let host = provider.join("lane-host").display().to_string();
    let account = world.runner.state_dir().display().to_string();
    let first = format!("create --item KEN-H --repo o/r --harness claude --account {account}");
    let create = format!("{first} --relaunch");
    let answers_path = provider.join("lane-host.json");
    let mut answers: Value =
        serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
    answers[first.as_str()] = json!({"kill_ancestor": 2});
    answers["close --item KEN-H"] = json!({"stdout": "kept=none\n"});
    answers["list"] = json!({"stdout": ""});
    // The shipped ssh provider's lock, held by the item's own earlier
    // create: its notice beside the 75 (`lane-host-ssh`'s `ownership-busy`).
    answers[format!("{create}#1")] = json!({
        "exit": 75,
        "stderr": "lane-host-ssh: ownership-busy target=lane.example clone=/srv/clone exit=75\n",
    });
    answers[format!("{create}#2")] = json!({"stdout": format!(
        "ssh-target=lane.example\tpath={}\tremote-prefix=exec bash -c\n",
        world.host()
    )});
    std::fs::write(&answers_path, answers.to_string()).unwrap();
    let calls = || -> Vec<String> {
        std::fs::read_to_string(provider.join("lane-host.log"))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                l.trim_start_matches(&format!("ORCH_LANE_HOST={host} "))
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
    assert!(
        close.is_some_and(|at| after[at + 1..].iter().any(|l| l == "list")),
        "the provider's close confirmed by its list: {after:?}"
    );

    let busy = effect_report(&world.runner.op_fleet(&request));
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

#[test]
fn a_hold_fixture_whose_row_never_releases_it_ends_within_its_bound() {
    use std::io::Write;
    use std::os::unix::process::CommandExt;
    use std::process::Stdio;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let fifo = |name: &str| {
        let path = root.join(name);
        mkfifo(&path);
        path.display().to_string()
    };
    let run_dir = root.join("run");
    std::fs::create_dir(&run_dir).unwrap();
    std::fs::write(run_dir.join("start"), "").unwrap();
    let codex_home = root.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    mkfifo(&codex_home.join("rollout-gate"));
    let path = |name: &str| root.join(name).display().to_string();
    // Each hold fixture with the words and settings that bring it to its
    // hold; the real program it would run after a release is `true`.
    type Case = (&'static str, Vec<String>, Vec<(&'static str, String)>);
    let cases: Vec<Case> = vec![
        (
            "tmux-hold/tmux",
            vec!["new-window".into()],
            vec![
                ("TMUX_HOLD_FIFO", fifo("tmux.fifo")),
                ("TMUX_REAL", "true".into()),
            ],
        ),
        (
            "git-hold/git",
            vec!["worktree".into(), "remove".into(), "lane".into()],
            vec![
                ("GIT_HOLD_FIFO", fifo("git.fifo")),
                ("GIT_REAL", "true".into()),
            ],
        ),
        (
            "lane-mail-hold/lane-mail",
            vec!["send".into()],
            vec![
                ("LANE_MAIL_HOLD_FIFO", fifo("lane-mail.fifo")),
                ("LANE_MAIL_REAL", "true".into()),
            ],
        ),
        (
            "kill-hold/kill",
            vec!["-TERM".into(), "1".into()],
            vec![
                ("KILL_HOLD_FIFO", fifo("kill.fifo")),
                ("KILL_HOLD_LOG", path("kill.log")),
            ],
        ),
        (
            "linear-hold/linear.sh",
            vec!["issue".into()],
            vec![
                ("LINEAR_HOLD_FIFO", fifo("linear.fifo")),
                ("LINEAR_HOLD_LOG", path("linear-hold.log")),
            ],
        ),
        (
            "stub-turns/claude",
            vec![],
            vec![("STUB_TURNS_HOLD", fifo("turns.fifo"))],
        ),
        (
            "stub-codex-gated/codex",
            vec![],
            vec![("CODEX_HOME", codex_home.display().to_string())],
        ),
        (
            "dev-validate-child/dev-validate-run",
            vec![
                "--child".into(),
                "--run-dir".into(),
                run_dir.display().to_string(),
            ],
            vec![("DEV_VALIDATE_CHILD_HOLD", fifo("validate.fifo"))],
        ),
    ];
    let started: Vec<_> = cases
        .iter()
        .map(|(fixture, args, env)| {
            let mut command = program(fixtures().join(fixture));
            command
                .args(args)
                .envs(env.iter().map(|(name, value)| (*name, value)))
                .env("HOLD_BOUND_SECS", "1")
                .current_dir(root)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0);
            let mut child = command.spawn().unwrap();
            // The turn stub holds on the line it reads; the others ignore it.
            let mut stdin = child.stdin.take().unwrap();
            let _ = stdin.write_all(b"turn\n");
            (*fixture, child, stdin)
        })
        .collect();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut ended = Vec::new();
    let mut held = Vec::new();
    for (fixture, mut child, stdin) in started {
        let status = loop {
            match child.try_wait().unwrap() {
                Some(status) => break Some(status),
                None if Instant::now() >= deadline => break None,
                None => std::thread::sleep(Duration::from_millis(20)),
            }
        };
        match status {
            Some(status) => ended.push((fixture, status.code())),
            None => {
                // The leader is unreaped, so its group id still names this
                // row's group; the group holds the fixture's own children.
                let _ = program("kill")
                    .args(["-KILL", "--", &format!("-{}", child.id())])
                    .status();
                let _ = child.wait();
                held.push(fixture);
            }
        }
        drop(stdin);
    }
    assert!(
        held.is_empty(),
        "held past the bound with no writer: {held:?}"
    );
    for (fixture, code) in ended {
        assert_eq!(code, Some(124), "{fixture} ends as its hold unreleased");
    }
}

/// A second launch on the record the first left: the provider is asked to
/// reuse the worktree it holds, whatever session the record binds.
#[test]
fn a_hosted_relaunch_asks_the_provider_to_reuse_its_worktree() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    let mut fleet = world.runner.fleet();
    let mut prior = lane("KEN-H", "stopped", &world.runner, Value::Null);
    prior["host"] = json!(PROVIDER_PATH);
    prior["kind"] = json!("ssh");
    prior["launched_at"] = json!("2026-01-29T15:20:00Z");
    fleet["lanes"] = json!([prior]);
    world.runner.write_fleet(&fleet);
    let account = world.runner.state_dir().display().to_string();
    let host = world.host();
    let mut answers: Value = serde_json::from_str(
        &std::fs::read_to_string(world.scripts.join("lane-host.json")).unwrap(),
    )
    .unwrap();
    answers[format!(
        "create --item KEN-H --repo o/r --harness claude --account {account} --relaunch"
    )] = json!({"stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\n")});
    std::fs::write(
        world.scripts.join("lane-host.json"),
        serde_json::to_string(&answers).unwrap(),
    )
    .unwrap();
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
    effect_report(&world.runner.op_fleet(&terminal_close("KEN-H")));
}

/// A relaunch of a lane whose last pause is its park brings its stopped
/// sandbox back through the provider's start before `create --relaunch`;
/// a start the provider refuses, or answers without its `sandbox-started`
/// line, fails the launch with no create asked.
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
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let mut fleet = world.runner.fleet();
        let mut prior = lane("KEN-H", "parked", &world.runner, Value::Null);
        prior["host"] = json!(PROVIDER_PATH);
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
        answers["start --item KEN-H"] = start;
        answers[format!(
            "create --item KEN-H --repo o/r --harness claude --account {account} --relaunch"
        )] = json!({"stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\n")});
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
        match outcome {
            "confirmed" => assert!(at("start") < at("create"), "{case}: {calls:?}"),
            _ => {
                assert_eq!(at("create"), None, "{case}: no create: {calls:?}");
                assert!(
                    report["intent"]["observation"]["cause"]
                        .as_str()
                        .is_some_and(|c| c.starts_with("host-start-failed ")),
                    "{case}: {report}"
                );
            }
        }
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
    for case in ["started, its create refused", "cut inside its start"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
        let world = HostedLaunch::new(&server, dir.path(), record);
        let mut fleet = world.runner.fleet();
        let mut prior = lane("KEN-H", "parked", &world.runner, Value::Null);
        prior["host"] = json!(PROVIDER_PATH);
        prior["kind"] = json!("ssh");
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
        std::fs::create_dir_all(&home).unwrap();
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
    assert_eq!(settings_of(&narrower), None, "no bypass, no consent");

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

/// Through the real launch: a Codex lane and a Copilot lane whose harness
/// is up at its composer a second before it writes its session (Codex its
/// rollout, through the private launch home's link to the account's store;
/// Copilot its first event) bind that session, never `session-unbound`.
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

/// A hosted Copilot lane, whose home is on its host, and a hosted Pi lane
/// billing a Claude seat are refused before the provider creates anything;
/// a hosted Pi lane on its own root is judged on its host's files once
/// `create` named that root.
#[test]
fn a_hosted_lane_is_gated_before_create_and_a_hosted_pi_lane_on_its_host_s_files() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let world = HostedLaunch::new(&server, dir.path(), record);
    let account = world.runner.state_dir().display().to_string();
    let host = world.host();
    let answers_path = world.scripts.join("lane-host.json");
    let mut answers: Value =
        serde_json::from_str(&std::fs::read_to_string(&answers_path).unwrap()).unwrap();
    // The record the refused launches leave stands, so this one re-enters
    // it and asks the provider to reuse its worktree.
    answers
        [format!("create --item KEN-H --repo o/r --harness pi --account {account} --relaunch")] = json!({
        "stdout": format!("ssh-target=lane.example\tpath={host}\tremote-prefix=exec bash -c\tpi-root=/srv/pi-root\n")
    });
    answers["cat --item KEN-H /srv/pi-root/settings.json"] =
        json!({"stdout": r#"{"compaction": {"enabled": true}}"#});
    answers[format!("cat --item KEN-H {host}/.pi/settings.json")] = json!({"exit": 2});
    std::fs::write(&answers_path, answers.to_string()).unwrap();
    for (harness, model, cause, created) in [
        (
            "copilot",
            None,
            "unsupported-for-oversee harness=copilot reason=hosted".to_owned(),
            false,
        ),
        (
            "pi",
            Some("pi-claude/fable"),
            format!("host-pi-claude-seat host={PROVIDER_PATH} model=pi-claude/fable"),
            false,
        ),
        (
            "pi",
            Some("github-copilot/gpt-6"),
            "compaction-on harness=pi file=/srv/pi-root/settings.json".to_owned(),
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

/// A pane agent `tmux split-window` starts takes its environment from the
/// host's tmux server, started outside the provider's login shell whose key
/// and proxy variables the parent reads. Through the real hosted
/// `launch-lane`, the fixture provider and a private server: the typed line
/// runs the session-environment step before the harness, so the pane agent
/// the harness splits off reads the key its Pi `models.json` names and the
/// proxy, as the parent does.
#[test]
fn a_hosted_pi_lane_on_the_copilot_pool_hands_its_pane_agents_the_login_environment() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let record = json!({"identity_file": "/srv/clone/.git/lane-host-pid", "runtime": "/cache/bin/orch-runtime-k"});
    let mut world = HostedLaunch::new(&server, dir.path(), record);
    world.runner.verify = Some(2);
    let root = dir.path().join("pi-home");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join("models.json"),
        r#"{"providers":{"github-copilot":{"apiKey":"$POOL_KEY"}}}"#,
    )
    .unwrap();
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
    let path = world.scripts.join("lane-host.json");
    let mut answers: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let account = world.runner.state_dir().display().to_string();
    let host = world.host();
    answers[format!("create --item KEN-H --repo o/r --harness pi --account {account}")] = json!({
        "stdout": format!(
            "ssh-target=lane.example\tpath={host}\tremote-prefix=exec env POOL_KEY=fixture HTTPS_PROXY=http://proxy.test:3128 PI_CODING_AGENT_DIR={} bash -c\tpi-root={}\n",
            root.display(),
            root.display()
        )
    });
    answers[format!("cat --item KEN-H {}/settings.json", root.display())] =
        json!({"stdout": r#"{"compaction":{"enabled":false}}"#});
    answers[format!("cat --item KEN-H {host}/.pi/settings.json")] =
        json!({"stdout": r#"{"packages":["./packages/@vanillagreen/pi-hooks"]}"#});
    answers[format!("cat --item KEN-H {host}/.pi/packages/@vanillagreen/pi-hooks/package.json")] = json!({
        "stdout": r#"{"version":"1","pi":{"extensions":["./extensions/lane-mail-wake.ts"]}}"#
    });
    answers[format!(
        "cat --item KEN-H {host}/.pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
    )] = json!({"stdout": "context_window"});
    std::fs::write(path, answers.to_string()).unwrap();
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
    assert_eq!(
        std::fs::read_to_string(&parent_env).unwrap().trim(),
        "fixture|http://proxy.test:3128",
        "the harness reads the login shell's variables"
    );
    assert_eq!(
        std::fs::read_to_string(&child_env).unwrap().trim(),
        "fixture|http://proxy.test:3128",
        "the pane agent reads the same from the session"
    );
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

/// The model-switch recovery's handoff to the runtime, over the record the
/// real `launch-lane` wrote: `lib/lane-relaunch.sh model-recovery` stops
/// the predecessor through the runtime's close, which reads the identity
/// the launch recorded in the launch's own form and interrupts the turn it
/// is in, and starts the replacement on the recorded model through the
/// real `launch-lane`. A field the runtime needs that the record never
/// carried, a stop that reads the live harness stale and leaves it running
/// beside a record marked stopped, or a stop that waits on a harness mid-
/// turn, fails here and nowhere later. The released case is the record an
/// earlier launcher wrote, planted as it wrote it: a bare `lstart` start
/// and a `recovery` object whose flags carry a narrower permission choice,
/// which reaches the replacement's line and never widens to the bypass
/// default.
#[test]
fn the_model_switch_recovery_stops_through_the_runtime_and_relaunches_over_the_real_launch_lane() {
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum Predecessor {
        Idle,
        Released,
        Working,
    }
    for case in [
        Predecessor::Idle,
        Predecessor::Released,
        Predecessor::Working,
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(2);
        runner.init_fleet();
        let work = runner.state_dir().to_path_buf();
        let hold = work.join("hold.fifo");
        if case == Predecessor::Working {
            // A harness mid-turn: it draws its composer, and on the first
            // line it reads echoes the turn, draws Claude Code's working
            // line and holds the turn open on the FIFO, bounded.
            mkfifo(&hold);
            let working = dir.path().join("working");
            std::fs::create_dir_all(&working).unwrap();
            let stub = working.join("claude");
            write_executable(
                &stub,
                format!(
                    "#!/bin/bash\nprintf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\nprintf '  ? for shortcuts\\n'\nIFS= read -r line\nprintf '\\xe2\\x9d\\xaf %s\\n' \"$line\"\nprintf '%s\\n' '* Thinking... (esc to interrupt)'\nexec 9<>'{}'\nread -r -t 30 -u 9 _\nexit 0\n",
                    hold.display()
                ),
            );
            runner.stub = stub;
        }
        let mut request = launch_request("KEN-R", &work);
        request["model"] = json!("claude-fable-5-1");
        request["effort"] = json!("high");
        let report = effect_report(&runner.op_fleet(&request));
        assert_eq!(
            report["intent"]["outcome"], "confirmed",
            "{case:?}: {report}"
        );
        if case == Predecessor::Working {
            // A turn under way: the harness holds its turn open and draws
            // no composer, so the pane reads working.
            let pane = report["lane"]["launch"]["pane"].as_str().unwrap();
            server.send_line(pane, "keep working");
            let state = runner.run(&["lane", "status", "--item", "KEN-R"]);
            assert_eq!(
                reply(&state)["result"]["state"],
                "working",
                "{}",
                stderr(&state)
            );
        } else {
            launch_record_of(&work);
            std::fs::remove_file(work.join("launch-record.json")).unwrap();
        }
        let mut fleet = runner.fleet();
        let predecessor = fleet["lanes"][0]["launch"]["pid"].as_u64().unwrap() as u32;
        if case == Predecessor::Released {
            fleet["lanes"][0]["launch"]["start"] = json!(lstart_of(predecessor));
            fleet["lanes"][0]["recovery"] = json!({
                "cwd": work.display().to_string(),
                "flags": "--model claude-opus-4-8 --effort high --permission-mode dontAsk",
                "refresh": false,
                "session": "fleet",
            });
        }
        fleet["lanes"][0]["model_check"] = json!({"session_id": "current", "outcome": "switched"});
        fleet["fleet_log"] = json!([{
            "kind": "model-switched", "item": "KEN-R", "session_id": "current",
            "launch_identity": {
                "launch": fleet["lanes"][0]["launch"],
                "launched_at": fleet["lanes"][0]["launched_at"],
            },
        }]);
        runner.write_fleet(&fleet);
        let scripts = installed_scripts(dir.path());
        let mut command = program("bash");
        runner.apply_env(&mut command);
        let out = command
            .arg(scripts.join("lib/lane-relaunch.sh"))
            .args(["model-recovery", &fleet["lanes"][0].to_string()])
            .arg(&work)
            .arg("current")
            .env("ORCH_MODEL_RECOVERY_LIMIT", "3")
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(0), "{case:?}: {}", stderr(&out));
        assert!(
            !live(predecessor),
            "{case:?}: the predecessor runs on beside its record"
        );
        let fleet = runner.fleet();
        let lane = &fleet["lanes"][0];
        assert_eq!(lane["status"], "running", "{case:?}: {lane}");
        assert_eq!(lane["model"], "claude-fable-5-1", "{case:?}: {lane}");
        assert_ne!(
            lane["launch"]["pid"].as_u64().unwrap() as u32,
            predecessor,
            "{case:?}: the replacement is another harness"
        );
        let log = fleet["fleet_log"].as_array().unwrap();
        let close = log.iter().find(|row| row["kind"] == "close").unwrap();
        assert_eq!(close["disposition"], "no-landing", "{case:?}: {close}");
        assert_eq!(close["reason"], "model-switch", "{case:?}: {close}");
        assert_eq!(log[0]["recovery"], "replaced", "{case:?}: {log:?}");
        if case == Predecessor::Working {
            continue;
        }
        let recorded = launch_record_of(&work);
        let argv: Vec<&str> = recorded["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap())
            .collect();
        assert!(
            argv.windows(2)
                .any(|w| w == ["--model", "claude-fable-5-1"]),
            "{case:?}: the recorded model on the line: {argv:?}"
        );
        assert!(
            argv.windows(2).any(|w| w == ["--effort", "high"]),
            "{case:?}: the recorded effort on the line: {argv:?}"
        );
        assert_eq!(
            recorded["env"]["CLAUDE_CONFIG_DIR"],
            work.display().to_string()
        );
        let released = case == Predecessor::Released;
        let bypass = argv.contains(&"--dangerously-skip-permissions");
        let narrower = argv
            .windows(2)
            .any(|w| w == ["--permission-mode", "dontAsk"]);
        assert_eq!(
            (bypass, narrower),
            (!released, released),
            "{case:?}: the recorded permission choice on the line: {argv:?}"
        );
        assert_eq!(
            recorded["env"]["CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"],
            if released { "" } else { "1" },
            "{case:?}: the bypass switches ride a full bypass alone: {recorded}"
        );
    }
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
/// with nothing written; a record that binds none takes the obligation a
/// later launch names; a parent named without its pair is refused
/// `request-invalid` with nothing written; the cycle recorder copies the
/// recorded obligation into the cycle.
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
    // The close verb over the record the launch wrote, left stopped as a
    // kept sandbox leaves it, its delivery a direct push in the project's
    // checkout (the state directory) whose push log is unread: the cycle
    // the close records reads the launch's binding.
    let relaunched = effect_report(&runner.op_fleet(&launch_request("KEN-O", runner.state_dir())));
    assert_eq!(relaunched["intent"]["outcome"], "confirmed", "{relaunched}");
    let mut fleet = runner.fleet();
    for lane in fleet["lanes"].as_array_mut().unwrap() {
        if lane["item"] == "KEN-O" {
            lane["status"] = json!("stopped");
            lane["launch"] = Value::Null;
        }
    }
    runner.write_fleet(&fleet);
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
        &json!({"op": "close-lane", "item": "KEN-O", "delivery": {"commit": {"commit": head}}}),
    ));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let lane = runner.fleet()["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == "KEN-O")
        .cloned()
        .unwrap();
    assert_eq!(
        lane["cycle"]["obligation"], obligation,
        "the cycle reads the launch's binding: {lane}"
    );
}

/// Through the real `launch-lane` and the real recovery: a lane launched
/// with `--permission-mode dontAsk` records the choice as its line's words,
/// the replacement's line carries `dontAsk` and no bypass word, and the
/// relaunched record keeps the choice.
#[test]
fn a_lanes_recorded_permission_choice_reaches_its_model_switch_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(2);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let argv_of = |record: &Value| -> Vec<String> {
        record["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap().to_owned())
            .collect()
    };
    let choice = ["--permission-mode".to_owned(), "dontAsk".to_owned()];
    let mut request = launch_request("KEN-P", &work);
    request["model"] = json!("claude-fable-5-1");
    request["effort"] = json!("high");
    request["permission"] = json!("--permission-mode dontAsk");
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        report["lane"]["permission"], "--permission-mode dontAsk",
        "{}",
        report["lane"]
    );
    let argv = argv_of(&launch_record_of(&work));
    assert!(argv.windows(2).any(|w| w == choice), "{argv:?}");
    std::fs::remove_file(work.join("launch-record.json")).unwrap();
    let mut fleet = runner.fleet();
    let predecessor = fleet["lanes"][0]["launch"]["pid"].as_u64().unwrap() as u32;
    fleet["lanes"][0]["model_check"] = json!({"session_id": "current", "outcome": "switched"});
    fleet["fleet_log"] = json!([{
        "kind": "model-switched", "item": "KEN-P", "session_id": "current",
        "launch_identity": {
            "launch": fleet["lanes"][0]["launch"],
            "launched_at": fleet["lanes"][0]["launched_at"],
        },
    }]);
    runner.write_fleet(&fleet);
    let scripts = installed_scripts(dir.path());
    let mut command = program("bash");
    runner.apply_env(&mut command);
    let out = command
        .arg(scripts.join("lib/lane-relaunch.sh"))
        .args(["model-recovery", &fleet["lanes"][0].to_string()])
        .arg(&work)
        .arg("current")
        .env("ORCH_MODEL_RECOVERY_LIMIT", "3")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert!(
        !live(predecessor),
        "the predecessor runs on beside its record"
    );
    let lane = runner.fleet()["lanes"][0].clone();
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(
        lane["permission"], "--permission-mode dontAsk",
        "the relaunch keeps the choice: {lane}"
    );
    let argv = argv_of(&launch_record_of(&work));
    assert!(
        argv.windows(2).any(|w| w == choice),
        "the replacement runs under the recorded choice: {argv:?}"
    );
    assert!(
        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
        "no bypass word beside the choice: {argv:?}"
    );
}

/// The `ps -o lstart` text of a live pid as the shell launcher recorded a
/// harness's start, in the C locale and UTC with its blanks squeezed.
fn lstart_of(pid: u32) -> String {
    let out = program("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The shipped scripts laid out as an install under `dir`, their sibling
/// libraries beside them and `orch-runtime` the binary under test, for a
/// row that runs a shell entry which calls the runtime back.
fn installed_scripts(dir: &Path) -> PathBuf {
    let scripts = dir.join("packages/orch/scripts");
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts");
    let tests = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../tests");
    let out = program("bash")
        .args([
            "-euo",
            "pipefail",
            "-c",
            r#"mkdir -p "$2" && cp -R "$1/." "$2/" && . "$3/lib/shared-skill-libs.sh" && orch_fixture_shared_libs "${2%/scripts}" && printf '#!/bin/bash\nexec "%s" --no-private-env "$@"\n' "$4" > "$2/orch-runtime" && chmod +x "$2/orch-runtime""#,
            "install",
        ])
        .arg(&shipped)
        .arg(&scripts)
        .arg(&tests)
        .arg(binary())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    scripts
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
/// form is read against this row; the hook's recovery continuation,
/// captured from the real `lane_recovery_continuation`; a local relaunch
/// that resumes its bound session; a hosted lane, through the real
/// `lane-host` dispatcher and a fixture provider.
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
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts");
    let continuation = program("bash")
        .args([
            "-c",
            ". \"$1/lib/lane-launch.sh\" && . \"$1/lib/lane-relaunch.sh\" && lane_recovery_continuation KEN-U claude",
            "continuation",
        ])
        .arg(&shipped)
        .output()
        .unwrap();
    assert!(continuation.status.success(), "{}", stderr(&continuation));
    let continuation = String::from_utf8(continuation.stdout).unwrap();
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
        let expected = closed(&brief, mode);
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
    let world = HostedLaunch::new(
        &server,
        dir.path(),
        json!({
            "identity_file": "/srv/clone/.git/lane-host-pid",
            "runtime": "/cache/bin/orch-runtime-k"
        }),
    );
    // The real dispatcher in front of the fixture provider, and the
    // recording harness on the host.
    let provider = dir.path().join("provider");
    std::fs::create_dir_all(&provider).unwrap();
    std::fs::rename(
        world.scripts.join("lane-host.json"),
        provider.join("lane-host.json"),
    )
    .unwrap();
    std::fs::remove_file(world.scripts.join("lane-host")).unwrap();
    std::os::unix::fs::symlink(shipped.join("lane-host"), world.scripts.join("lane-host")).unwrap();
    std::os::unix::fs::symlink(shipped.join("lib"), world.scripts.join("lib")).unwrap();
    std::os::unix::fs::symlink(
        shipped.join("../../mailbox"),
        world.scripts.join("../../mailbox"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("lane-host/lane-host"),
        provider.join("lane-host"),
    )
    .unwrap();
    std::fs::remove_file(world.tools.join("claude")).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("stub-record/claude"),
        world.tools.join("claude"),
    )
    .unwrap();
    let brief = dir.path().join("hosted-brief.md");
    std::fs::write(&brief, "Review the hosted change.\n").unwrap();
    let mut request = world.request();
    request["host"] = json!(provider.join("lane-host").display().to_string());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(
        &world
            .runner
            .op_fleet_env(&request, &[("ORCH_LANE_OUTPUT", "normal")]),
    );
    assert_ne!(report["intent"]["outcome"], "failed", "hosted: {report}");
    let recorded = launch_record_of(&world.host_path);
    let expected = closed("Review the hosted change.", Some("normal"));
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
        closed(continuation.trim_end(), None),
        "resume: the brief the resumed line reads"
    );
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
/// carries an opener's own declaration, model-line hold and Codex
/// compaction reading: a Copilot CLI or Pi session sees the model its launch
/// pinned, a Claude Code or Codex session and a launch pinning none declare
/// nothing, and none of the three reaches a session from its opener.
#[test]
fn a_lane_declares_its_pinned_model_to_the_review_and_never_its_openers() {
    let cases: [(&str, Option<&str>, Option<&str>); 5] = [
        ("claude", Some("claude-fable-5-1"), None),
        ("codex", Some("gpt-5.5"), None),
        ("copilot", Some("claude-opus-5"), Some("claude-opus-5")),
        ("pi", Some("claude-fable-5-1"), Some("claude-fable-5-1")),
        ("pi", None, None),
    ];
    for (harness, model, declared) in cases {
        let case = format!("{harness} {model:?}");
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        for (name, value) in [
            ("SECOND_OPINION_CURRENT_MODEL", "the opener's model"),
            ("ORCH_MODEL_LINES_HELD", "1"),
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
        match model {
            Some(model) => request["model"] = json!(model),
            None => {
                request.as_object_mut().unwrap().remove("model");
            }
        }
        let report = effect_report(&runner.op_fleet(&request));
        assert_ne!(report["intent"]["outcome"], "failed", "{case}: {report}");
        let opened = &launch_record_of(&work)["opened"];
        assert_eq!(
            opened["SECOND_OPINION_CURRENT_MODEL"],
            declared.map_or(Value::Null, |m| json!(m)),
            "{case}: the model the session declares: {opened}"
        );
        assert_eq!(
            opened["ORCH_MODEL_LINES_HELD"],
            Value::Null,
            "{case}: the opener's hold: {opened}"
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
