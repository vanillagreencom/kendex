//! Live-effect process tests of the `orch-runtime` executable: each creates
//! its own private tmux server, drives the binary against a stub harness
//! that never launches a real model, and reaps what it started.
//!
//! The stub harnesses are the scripts beside this file, `fixtures/<stub>/
//! claude`: each is named for the harness it stands in for and run by bash
//! directly, so the kernel records the harness's process name for the pane's
//! foreground process, which the judge requires before it reads the pane
//! idle (decision 60). They are selected through the `ORCH_HARNESS_BINARIES`
//! product setting for a custom install path. The tmux server each test
//! makes lives on its own socket under a `TempDir`, reads no configuration
//! file and runs a named pane shell (decision 69); the test ends it with
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

/// A close carrying the tracker's terminal verdict, the ground decision 83
/// takes to end a lane whose harness still runs.
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
    // the kernel names for the harness (decision 60).
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
    // The lane's `window` is the legacy `session:title` form, the title the
    // item (decision 56); the pane id stays in `launch.pane`.
    assert_eq!(report["lane"]["window"], "fleet:KEN-1");
    // The window the launch opened stands on the server, and the intent
    // recorded it before the wait (decision 62).
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
    // The pane registered itself before it exec'd the stub (decision 96):
    // its receipt names this intent, the pane and the pid the stub runs
    // under, and stands while the intent is open.
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

/// Decision 60, R-U18 high 1: a pane whose screen carries the composer
/// marker while a shell holds its terminal never reads idle, so the launch
/// never confirms; a reconcile reads the same.
#[test]
fn a_pane_whose_foreground_is_a_shell_never_reads_idle_whatever_it_draws() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-shell");
    runner.verify = Some(1);
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-40", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
    let pane = report["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let screen = tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]);
    assert!(
        String::from_utf8_lossy(&screen.stdout).contains('\u{276f}'),
        "the screen does carry the composer marker"
    );
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

/// Decision 60, R-U18 P9: a harness that exits before its first draw never
/// confirms, whatever the pane's shell drew while typing the launch line.
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

/// Decision 64, R-U18 P2d: a close interrupted before its signal leaves an
/// open intent over a live, matching identity. The repeated close reconciles
/// it as a stop still owed and runs that stop.
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
        "close-owned-resources",
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

/// Decision 62, R-U18 P13: the effect's process ends after retirement with
/// the runner at its composer and no brief owed; a reconcile completes the
/// succession from the recorded phase and publishes that runner.
#[test]
fn reconcile_publishes_a_runner_recorded_at_the_retired_phase() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    // The predecessor is gone: its recorded identity holds no process.
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    fleet["intents"] = json!([transfer_intent(
        Some(phase("retired", &server, &pane, since, None)),
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert_eq!(overseer["pane"], pane);
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert_eq!(
        overseer["server_socket"],
        server.socket.display().to_string()
    );
}

/// Decision 62, R-U18 P14: the effect's process ends during the launch poll;
/// a reconcile completes the launch from the recorded pane, confirming it
/// with the identity it reads, or failing it once that pane is gone.
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
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-42", "preparing", &runner, Value::Null)]);
    fleet["intents"] = json!([lane_intent(
        "launch-lane",
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
    // The close that follows stops it by that identity and the lane is done,
    // its window closed.
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-42")));
    assert_eq!(closed["intent"]["outcome"], "confirmed");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(server.panes().len(), 1);
}

#[test]
fn reconcile_marks_a_transfer_intent_stale_when_the_generation_moved() {
    // Decision 44: a transfer intent still open after a legacy succession
    // moved the overseer's generation reconciles as intent-stale with the
    // observed generation, never a second controller.
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
    // R-U10 finding 1 through the binary: each `op` process mints its own
    // stamp, so a relaunch after a close gets a new id.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let first = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    assert_eq!(first["intent"]["outcome"], "confirmed");
    let first_id = first["intent"]["id"].as_str().unwrap().to_owned();
    assert!(first_id.starts_with("launch-lane:KEN-1:"), "{first_id}");
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
        &[("ORCH_TMUX_SESSION", "nosuch")],
    );
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
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
    // Decision 59: a live pid whose recorded start no longer matches is an
    // identity change, not gone, so the close stays unconfirmed, not done.
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
        "close-owned-resources",
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
    // Decision 59: a pid no process holds is confirmed gone, so the close
    // completes and the lane reads done.
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
        "close-owned-resources",
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

/// Decision 66, R-U19 probe C: the private server a launch opened on is
/// killed and another started on the same socket. One socket is held by one
/// server, so the recorded pane is gone: the launch fails on reconcile and
/// the close that follows ends the lane.
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

/// Decision 67, R-U18 P1n: a launch whose harness never draws is left
/// unconfirmed, and a close then supersedes it: the launch intent closes
/// `failed` with `superseded-by-close`, the close stops the pane's foreground
/// harness by the identity read then, and the lane is done.
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

/// R-U20 finding 1: a `stopped` lane recorded under one harness word is
/// relaunched under another and never draws, so the lane keeps its earlier
/// word. The close that supersedes the launch judges the pane's foreground
/// by the harness the launch selected and stops it by identity, never by
/// the lane's earlier word, which would read the harness as foreign and kill
/// the window alone.
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

/// Decision 72, step4-map § B row 1: a contender reconciles an intent whose
/// owner is a live process still before its first window. The owner is held
/// at `new-window` by the tmux-hold shim with its intent persisted at the
/// `opening` phase; the contender's reconcile reads `owner-live` and touches
/// nothing, and the owner, released, opens its window carrying its intent id and confirms.
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
    wait_for_phase(&runner, "launch-lane:KEN-1", "opening");
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

/// Decision 96: a reconcile at `opening` with a dead owner never adopts a
/// window the intent neither recorded nor received a receipt for, however
/// present a harness in it is. The window is left standing and the launch
/// fails `nothing-opened`.
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
        "launch-lane",
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

/// Decisions 96 and 111 (5): the runtime dies after its window is created
/// and before `new-window` answered with the pane id, so the pane was never
/// recorded and, its line never typed, never registered. The server's
/// `after-new-window` hook holds the `new-window` client on a `wait-for`
/// channel, so the window exists while the runtime is still inside that one
/// command; the test kills the runtime, its own child, there and releases
/// the hook. The phase records that the launcher was asked, so the window
/// possibly opened is an obligation nothing read discharges: the reconcile
/// holds the launch `unconfirmed` with `window-unread` and the window on
/// its server standing, never adopted, never assumed absent, and the lane
/// as found.
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
    wait_for_phase(&runner, "launch-lane:KEN-1", "opening");
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

/// Decision 68, R-U18 P2b: a close whose recorded pid runs under another
/// start, with no pane recorded. The first reconcile reading is `unconfirmed`
/// with `identity: stale` (decision 59); a second, independent reading
/// confirms the close, and the live process is never signalled.
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
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-R",
        "not-started",
        None
    )]);
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

/// One cell of the reconcile matrix (decision 64): the intent's operation
/// and recorded phase, whether a recorded identity is present, the observed
/// state the row plants, and the outcome the reconcile must record.
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
/// process the test owns stands for the server (decision 66's one
/// unobservable case).
fn unanswering_server(runner: &Runner, process: &Owned) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: process.pid(),
        start: 1,
        process_start: process.start(),
    }
}

/// An unanswering socket whose recorded server process is gone: the server
/// and every pane it held are gone (decision 66).
fn gone_server(runner: &Runner) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: GONE_PID as u32,
        start: 1,
        process_start: "ticks:1".to_owned(),
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

/// Decision 64: the reconcile matrix over (operation, recorded phase,
/// recorded identity, observed state), one cell per row, each yielding its
/// outcome and none left without one. `retired` is read from the
/// predecessor's identity, an unobservable pane is `unconfirmed`, a failed
/// transfer keeps the original pending, and a confirmed launch binds a
/// session read since its own window opened.
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
                fleet: lane_fleet(runner, "launch-lane", "preparing", Value::Null, None),
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
                    "launch-lane",
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
                    "launch-lane",
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
                    "launch-lane",
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
                    "launch-lane",
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
                        "launch-lane",
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
                        "launch-lane",
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
                        "launch-lane",
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
                    "close-owned-resources",
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
                        "close-owned-resources",
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
                fleet: lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    Value::Null,
                    None,
                ),
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
                    "close-owned-resources",
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
                    "close-owned-resources",
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
                    "close-owned-resources",
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
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", server, "%77", now_ms(), None)),
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
            phase: "retired",
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
                        "retired",
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
            phase: "retired",
            identity: "predecessor gone",
            observed: "server gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", &gone_server(runner), "%1", now_ms(), None)),
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
            phase: "retired",
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
                        Some(phase("retired", server, &pane, since, None)),
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
            phase: "retired",
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
                    Some(phase("retired", server, &pane, since, None)),
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
            phase: "retired",
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
                    Some(phase("retired", server, &pane, since, None)),
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
            phase: "retired",
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
                        Some(phase("retired", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, _| {
                let overseer = runner.fleet()["overseer"].clone();
                assert_eq!(overseer["generation"], 4);
                let pane = overseer["pane"].as_str().unwrap().to_owned();
                assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
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
                // The id the launch fixed, which names the runner's file
                // before it carries a turn (decision 65).
                let mut phase = phase("retired", server, &pane, since, Some(&brief));
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
            phase: "retired",
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
                        Some(phase("retired", server, &pane, since, Some(&brief))),
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
            // Decision 124e (23): the phase written before the paste. A
            // reconcile that finds it waits for the turn and never pastes
            // again: the stub, which records every line it reads, records
            // none.
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
            // Decision 72: a reconcile that finds the intent's owner live
            // defers to it and touches nothing, whatever the pane reads.
            op: "launch",
            phase: "window-opened",
            identity: "owner live",
            observed: "owner-live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owner = Owned::sleep();
                let mut fleet = lane_fleet(
                    runner,
                    "launch-lane",
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
            // Decision 96, crash before the open: an intent at `opening` with
            // a dead owner, no pane recorded and no receipt written.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "no pane recorded, no receipt",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-lane",
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
            // Decision 96, crash after the pane registered and before the
            // record named it: the receipt names a live harness in its pane.
            // The reconcile adopts that exact pane and completes, noting the
            // receipt it adopted by.
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
                    "launch-lane:KEN-M:1-1",
                    &pane,
                    server.pane_pid(&pane),
                );
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
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
                // Decision 99: the identity the receipt proved is the one
                // the phase carries and the one the publication records,
                // pid and start alike.
                let pid = registered["pid"].as_u64().expect("the receipt's pid") as u32;
                assert_eq!(phase["identity"]["pid"], pid);
                assert_eq!(phase["identity"]["start"], start_of(pid));
                assert_eq!(fleet["lanes"][0]["launch"]["pid"], pid);
                assert_eq!(fleet["lanes"][0]["launch"]["start"], start_of(pid));
            },
        },
        Cell {
            // Decision 96: the pane was recorded and its line has not run
            // within the bound. Held: nothing bound, nothing failed, the
            // pane kept for the next reconcile.
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
                        "launch-lane",
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
            // Decision 96: the recorded pane never registered within the
            // bound: it is ours and holds no harness, so that exact pane is
            // closed and the launch fails. An unrelated window on the same
            // server is not touched, and neither is a sibling pane a hook
            // split into the recorded pane's own window (decision 99): the
            // close is by pane id, not by window.
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
                        "launch-lane",
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
            // Decision 96: the recorded pane is already gone and no receipt
            // stands: nothing can register from it.
            op: "launch",
            phase: "opening",
            identity: "dead owner",
            observed: "pane recorded and gone, no receipt",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-lane",
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
            // Decision 96: a receipt that is not this intent's shape is held,
            // never read as absence: nothing bound, nothing failed, nothing
            // closed.
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
                plant_receipt_text(runner, "launch-lane:KEN-M:1-1", "{\"intent\":");
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
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
            // Decision 96, the succession arm: the runner's receipt names a
            // live runner before retirement. Adopted, then abandoned as a
            // `window-opened` reconcile abandons it: the runner stopped, the
            // predecessor in control, the original pending put back.
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
            // Decision 96, the succession arm: a malformed receipt is held.
            // The intent stays open, the successor pending stands as the
            // request wrote it, the predecessor keeps control, the pane is
            // kept.
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
            // Decision 96, the succession arm: the recorded runner pane never
            // registered within the bound. That exact pane is closed, the
            // succession fails before retirement and the original pending is
            // put back.
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

/// Decisions 96 and 99: a receipt whose pid no live process holds is a
/// harness that exited, read through the one identity reader before any
/// adoption. Nothing is adopted; the pane the receipt names, ours and
/// holding no harness, is closed by its exact id before the failure
/// completes, and a sibling pane split into the same window stands. The
/// launch fails `harness-exited` with no pane bound, the succession fails
/// before retirement with its original pending put back. The must-fail
/// control for the identity confirmation runs these two rows by this test's
/// name.
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
                plant_receipt(runner, "launch-lane:KEN-M:1-1", &pane, GONE_PID as u32);
                // A fresh server numbers the session's pane %0, the stub's
                // %1 and the sibling %2.
                assert_eq!((pane.as_str(), sibling.as_str()), ("%1", "%2"));
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
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
                // which records the first signal before the kill (decision 120
                // (2), R-U4g3 Codex site 4).
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

/// Decision 105 (2) at the receipt guard: the receipt names a dead harness
/// and its pane is closed by exact id before the failure completes; when the
/// host refuses that close, the launch stays open with the cause, its pane
/// standing and nothing adopted, and the reconcile completes it once the
/// host answers, closing exactly that pane.
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
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, GONE_PID as u32);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-lane",
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

/// Decision 99: a host that stops answering between two reads of one pane
/// settles nothing. The receipt names a live harness and is adopted under
/// its identity; the capture that follows fails while the pane stands, so
/// the launch is `unconfirmed` with the cause, never `pane-gone`, the lane
/// is left preparing, the pane stands, and the phase carries the receipt's
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
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, pid);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-lane",
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

/// Decision 111 (A) (2), R-U4a6b C1 (1): a pane's disappearance never
/// discharges the process that ran in it. The pane's process ignores
/// `SIGHUP`, as a harness beneath a wrapper may, so an exact `kill-pane`
/// leaves the pane gone and that same pid and start running. At
/// `window-opened` with that identity recorded, and at `opening` with the
/// receipt naming that pid, the reconcile holds the launch `unconfirmed`:
/// the pane is discharged by its own read, the identity read live stands
/// as the remaining obligation, the lane is left as found, and nothing is
/// closed `failed` over a process that runs on.
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
                plant_receipt(runner, "launch-lane:KEN-M:1-1", pane, pid);
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
            "launch-lane",
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
        // A deferral to a live or unreadable owner is a read-only reply
        // (decision 109 (4)): the observation is on the reply and the file's
        // intent stands as planted. Every other cell records its observation.
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

/// Decision 108 (4): a relaunch on another account than the bound session's
/// recorded one starts fresh with `account-switched`; so does one whose
/// destination home holds no file for the fixed id. The stub refuses a
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
        "account-switched"
    );
}

/// Decision 108 (7), the two R-U4b closes: a reconcile never confirms from
/// the parent identity alone. A close whose last run recorded a validation
/// stop that failed stays `unconfirmed` on reconcile with the obligation
/// kept, which the repeated close's stop route runs again; a close whose
/// lane records a live wake turn stays `unconfirmed` with `wake: live`, and
/// the repeated close stops the wake before it confirms. A wake record with
/// no identity is no handle.
#[test]
fn a_reconciled_close_never_confirms_over_an_owed_validation_stop_or_a_live_wake() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let validate_log = runner.state_dir().join("validate.log");
    runner.env.push((
        "DEV_VALIDATE_LOG".to_owned(),
        validate_log.display().to_string(),
    ));
    // The validation stop owed: the parent gone, no pane, the last outcome
    // recorded `validate: stop-failed`.
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-V",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": GONE_PID, "start": "ticks:1"}),
    )]);
    let mut owed = lane_intent("close-owned-resources", "KEN-V", "unconfirmed", None);
    owed["observation"] = json!({"identity": "stopped", "validate": "stop-failed"});
    owed["close"] = json!({"ground": "terminal", "verdict": "completed", "source": "test"});
    fleet["intents"] = json!([owed]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["validate"], "stop-failed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert!(!validate_log.exists(), "a reconcile stops nothing itself");
    // The repeated close runs the validation stop and confirms.
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-V")));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert!(
        std::fs::read_to_string(&validate_log)
            .unwrap()
            .contains("--stop"),
        "the owed stop ran"
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
    let mut open = lane_intent("close-owned-resources", "KEN-K", "unconfirmed", None);
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
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-N",
        "unconfirmed",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
}

// ---------------------------------------------------------------------------
// Decision 120: the receipted survivor, the same-key adoption and the
// replacement acquired before its stop (R-U4g2 P1, P2, P8; R-U4g2-codex C1
// probes 1, 2, 3 and 5), as fixed rows.
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
    intent["obligations"]["discharged"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter(|row| row["by"] == by)
                .map(|row| row["obligation"].clone())
                .collect()
        })
        .unwrap_or_default()
}

/// R-U4g2 P1, R-U4g2-codex C1 probe 1: the server, not the pane, goes at
/// `opening`, and the receipt names a pid that survived it. The receipt is
/// read before anything is discharged (decision 120 (5)): its pid is read
/// live and stands, so the launch is held `unconfirmed` with that pid, the
/// receipt discharged by its read and its file kept.
#[test]
fn a_server_gone_at_opening_reads_the_receipt_before_any_discharge() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, pid);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    runner.write_fleet(&lane_fleet(
        &runner,
        "launch-lane",
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
        receipt_path(&runner, "launch-lane:KEN-M:1-1").exists(),
        "the open intent keeps its receipt"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
}

/// R-U4g2 P2, R-U4g2-codex C1 probe 2: the `window-opened` record as the
/// launch writes it after the line is typed, the receipt standing until
/// read (decision 120 (5)), the pane killed under a process that survived
/// it. The reconcile reads the receipt, reads its pid live and holds the
/// launch with that pid; nothing is failed over a live process.
#[test]
fn a_window_opened_record_before_its_identity_reads_the_written_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, pid);
    let phase = phase("window-opened", &server, &pane, now_ms(), None);
    let mut fleet = lane_fleet(
        &runner,
        "launch-lane",
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

/// R-U4g2-codex C1 probe 4: the real launch, held at its first read after
/// the `window-opened` write by a tmux shim that blocks `capture-pane`, is
/// killed there, as a crash at the first wait. The pane is then killed
/// under a harness that ignores the hangup. The reconcile reads the receipt
/// the launch left standing, reads its pid live, and holds the launch with
/// that pid: the record said nothing the launch had not read. The shim
/// holds the launch's first pane-field read until the pane's process is
/// the stub (decision 124i (34)), so the foreground read before the held
/// capture sees the harness whatever the stub's start took, and the record
/// at the capture barrier is judged, not the stub's startup.
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
    wait_for_phase(&runner, "launch-lane:", "window-opened");
    // The launch is at its first wait: the shim holds its first capture.
    let deadline = Instant::now() + Duration::from_secs(10);
    while !mark.exists() {
        assert!(
            Instant::now() < deadline,
            "the launch never reached its first wait"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The record at the first wait: the pane standing with the receipt,
    // nothing discharged that was not read (decision 120 (5)).
    let held = runner.fleet()["intents"][0].clone();
    let standing = held["obligations"]["standing"].as_array().unwrap().clone();
    assert!(
        standing.iter().any(|o| o["kind"] == "receipt"),
        "the receipt stands until read: {held}"
    );
    assert!(standing.iter().any(|o| o["kind"] == "pane"), "{held}");
    // The foreground identity is acquired through the writing reader and so is
    // recorded before the capture the shim holds (decision 120 (2), R-U4g3
    // Codex site 3): a run killed at its capture has already written what it
    // read.
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

/// R-U4g2-codex C1 probe 5 (decision 120 (5)): the receipt names the pane the
/// opening recorded, so the adoption's key equals the recorded one. The
/// recorded pane keeps standing through the adoption and passes to the lane
/// record at publication; it is never discharged `adopted`.
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
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, pid);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    let mut fleet = lane_fleet(
        &runner,
        "launch-lane",
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

/// R-U4g2 P8: the dead-receipt row with the pane the opening recorded, as
/// `open_window` writes it before the line is typed, and the pane's close
/// refused by the host. The adoption keeps that pane standing (decision 120
/// (5)), so a refused close settles nothing: the launch is held, the pane
/// stands, and the next reconcile closes it.
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
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, GONE_PID as u32);
    let mut phase = opening_phase(&server, now_ms(), Some(&pane));
    phase["asked"] = json!(true);
    let mut fleet = lane_fleet(
        &runner,
        "launch-lane",
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

/// R-U4g2-codex C1 probe 3 (decision 120 (2)): the replacement foreground
/// read in the recorded pane on a close whose recorded identity is gone is
/// written as an obligation before the stop that follows, on the first run
/// and on a signalled retry alike. A `kill` that holds the first signal
/// lets the row read the record at the stop's wait: the replacement stands
/// and `signalled` is recorded.
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

/// R-U4g3-codex H1 (decision 120 (3)): a receipted survivor stands on the
/// reconcile that reads it live, and the next reconcile, reading its own
/// recorded pid gone, settles the launch. The pid is read by its own key on
/// every route, not only the phase's identity.
#[test]
fn a_receipted_survivor_read_gone_on_a_later_reconcile_settles_the_launch() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let (pane, pid) = survivor(&server, &runner);
    plant_receipt(&runner, "launch-lane:KEN-M:1-1", &pane, pid);
    let mut fleet = lane_fleet(
        &runner,
        "launch-lane",
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

/// R-U4g3-codex site 8 (decision 120 (2), L3): a lane whose recorded server
/// start differs from the ambient server's is a reused pid, not this lane's
/// server; the close reads the pane gone with it and kills nothing live.
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

/// R-U4g3-codex site 6 (decision 99): an unreadable worktree root is no proof
/// of absence, so the validation stop stays owed and the close holds, never
/// confirming over runs it could not read.
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

/// R-U4g3-codex site 1 (decision 120 (1)): a `send_line` reply reported failed
/// may have run the line, which writes the receipt and execs the harness. The
/// pane is closed and the receipt read, not assumed absent, so a live
/// registered pid stands and the launch holds rather than settling `failed`
/// over a running harness.
#[test]
fn a_send_reply_reported_failed_that_ran_the_line_reads_the_receipt() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-survivor");
    runner.verify = Some(1);
    runner.init_fleet();
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let copy = runner.state_dir().join("receipt-copy");
    let shim = tools.join("tmux");
    std::fs::write(
        &shim,
        format!(
            "#!/bin/bash\nsk=; en=; kp=\nfor a in \"$@\"; do\n  [ \"$a\" = send-keys ] && sk=1\n  [ \"$a\" = Enter ] && en=1\n  [ \"$a\" = kill-pane ] && kp=1\ndone\nif [ -n \"$sk\" ] && [ -n \"$en\" ]; then {real} \"$@\"; echo 'tmux: timed out' >&2; exit 1; fi\nif [ -n \"$kp\" ]; then sleep 2; cat {state}/intents/*.pane > {copy} 2>/dev/null; fi\nexec {real} \"$@\"\n",
            real = which_tmux(),
            state = runner.state_dir().display(),
            copy = copy.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// Decision 124a (2): a wake the lane's writer replaced is no longer named by
/// the lane, but the close intent recorded it. The repeated close stops the
/// recorded wake as well as the lane's current one, and confirms only once
/// both are gone.
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
    // The close intent's set already recorded the old wake (its bootstrap at
    // a first run), and nothing else; the close itself never ran.
    fleet["intents"] = json!([{
        "id": "close-owned-resources:KEN-W:1-1", "op": "close-owned-resources", "target": "KEN-W", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "wake"},
            {"kind": "validation", "role": "validation"},
        ], "discharged": [], "signalled": true},
    }]);
    // The legacy writer replaced the wake since.
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

/// Decision 124a (2): a replacement foreground the close acquired whose pane
/// is since gone is read by its own key on the next reconcile, not through
/// the lane's launch identity: live it holds the close, gone it settles.
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
        "id": "close-owned-resources:KEN-F:1-1", "op": "close-owned-resources", "target": "KEN-F", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "stop": "pane-foreground"},
        "obligations": {"standing": [
            {"kind": "process", "pid": foreground.pid(), "start": foreground.start(), "role": "harness"},
        ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}], "signalled": true},
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
// Decision 124b (2): the moved lane. A close acts only on its own recorded
// set, never the session a relaunch moved the lane under; each row names the
// probe it answers.
// ---------------------------------------------------------------------------

/// Decisions 124b (2) and 124d (14) (R-U4g5 Codex
/// `rg5_same_stamp_moved_keys_do_not_close_the_new_lane`): the store judges a
/// moved lane by the intent's recorded keys, never the stamp alone. The same
/// moved lane under a later `session_since` and under the close's own (the
/// legacy launcher writes whole seconds, so a relaunch can carry the intent's
/// stamp with new launch keys), read by the reconcile alone after the
/// recorded wake ended: the close's recorded set is all discharged, so the
/// reconcile settles by that set, closes `intent-stale`, never holds
/// `stop: pending` on the new session's live harness, and the new lane stays
/// `running` with its replacement launch.
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
            "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "stopped", "wake": "live", "cause": "wake-timeout"},
            "obligations": {"standing": [
                {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "wake"},
            ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
            "signalled": true},
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
            "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "live", "timeout_pid": harness.pid()},
            "obligations": {"standing": [
                {"kind": "process", "pid": harness.pid(), "start": harness.start(), "role": "harness", "harness": "claude"},
            ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
            "signalled": true, "revision": 2},
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

/// Decision 124l (45), R-U4g8 opus M1's second reconcile: a reconcile with
/// two open intents, one of a close whose lane row is gone, reconciles the
/// other and reports the refused one by its cause, `lane-missing`, under
/// `refused`; the verb succeeds and the refused intent stands as it was
/// for the next reconcile.
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
        "id": "close-owned-resources:KEN-GONE:1-1", "op": "close-owned-resources",
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
    assert_eq!(refused[0]["intent"], "close-owned-resources:KEN-GONE:1-1");
    assert_eq!(refused[0]["refusal"], "lane-missing", "{answer}");
    let reconciled = answer["result"]["reconciled"].as_array().unwrap();
    assert_eq!(reconciled.len(), 1, "the other intent reconciled: {answer}");
    assert_eq!(
        reconciled[0]["report"]["intent"]["id"],
        "close-owned-resources:KEN-M:1-1"
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started",
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

/// Decision 124d (20), R-U4g5 Codex `probe-moved.rs`: a moved lane's
/// signalled close retries on its own recorded set. The repeated close and
/// the reconcile leave the new session's harness and window untouched and
/// stop the old recorded wake by its own token, so the intent settles
/// instead of standing read-only for good.
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_wake.pid(), "start": old_wake.start(), "role": "wake"},
        ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
        "signalled": true},
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

/// Decision 124e (24), R-U4g5 opus `ru4g5_probe_a_moved_close_owing_validation_has_no_route`:
/// a signalled close owing its validation stop under a lane that moved
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "validate": "stop-failed", "cause": "runner-refused"},
        "obligations": {"standing": [{"kind": "validation", "role": "validation"}], "discharged": [], "signalled": true},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        discharged_by(&report["intent"], "lane-moved")
            .iter()
            .any(|o| o["kind"] == "validation"),
        "the owed validation is released to the session holding the lane: {report}"
    );
    assert_eq!(report["intent"]["reconciled"], "intent-stale", "{report}");
    assert!(live(new_harness.pid()), "the new session stands");
    assert!(server.panes().contains(&new_pane), "the new window stands");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
}

/// Decision 124d (20), R-U4g5 opus
/// `ru4g5_probe_a_moved_close_never_resignals_its_own_recorded_harness`: a
/// signalled close holding its own recorded harness (a stop that read
/// unreadable after its signal) under a lane that moved signals that harness
/// again through its own token on the repeat; the new session is never
/// named.
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "unreadable", "pid": old_harness.pid(), "cause": "ps-failed"},
        "obligations": {"standing": [
            {"kind": "process", "pid": old_harness.pid(), "start": old_harness.start(), "role": "harness"},
        ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
        "signalled": true},
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

/// Decision 124g (29), R-U4g6 opus L2: a held close whose lane the legacy
/// launcher relaunched with another harness stops its own recorded root by
/// token and the root's descendants named by the harness kind the set
/// recorded at its bootstrap, never by the relaunched session's harness.
/// The old root is a bash holding a child named `claude`; the lane now says
/// `codex`. Both are stopped, nothing of the new session is. A set that
/// recorded no kind (the control) stops the root alone and leaves the
/// descendant, never signalling by the new session's name.
#[test]
fn a_moved_close_stops_the_old_roots_descendants_by_the_recorded_harness() {
    for (recorded_kind, descendant_after) in [(Some("claude"), "gone"), (None, "alive")] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        // The old root: a bash whose child is a sleep named `claude`, so the
        // kernel names it as the recorded harness's own process.
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
            "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "lane_since": "2026-01-29T15:20:00Z",
            "observation": {"identity": "unreadable", "pid": root_pid, "cause": "ps-failed"},
            "obligations": {"standing": [held],
                "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
                "signalled": true},
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

/// Decision 124e (22), R-U4g5 opus
/// `ru4g5_probe_one_repeated_close_counts_two_stale_readings`: one repeated
/// close request, its reconcile and the stop it reruns, records one stale
/// reading of a reused pid, never two; the next request's reading is the
/// second, which settles the identity, the reused pid never signalled.
#[test]
fn one_repeated_close_request_counts_one_stale_reading() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let held = Owned::sleep();
    let mut fleet = lane_fleet(
        &runner,
        "close-owned-resources",
        "running",
        Value::Null,
        None,
    );
    fleet["intents"][0]["outcome"] = json!("unconfirmed");
    fleet["intents"][0]["obligations"] = json!({
        "standing": [{"kind": "process", "pid": held.pid(), "start": "ticks:0", "role": "harness"}],
        "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
        "signalled": true,
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

/// Decision 124b (2), R-U4g4 Codex M2: a wake the lane's writer replaced with
/// none still has a stop route. A held, signalled close owing an owned live
/// wake, the lane naming no wake now, stops the recorded wake on the repeated
/// close by sweeping the set, not the lane's current wake.
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "wake": "live", "cause": "wake-timeout"},
        "obligations": {"standing": [
            {"kind": "process", "pid": wake.pid(), "start": wake.start(), "role": "wake"},
        ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
        "signalled": true},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-M")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        !live(wake.pid()),
        "the recorded wake the lane no longer names was stopped: {report}"
    );
}

/// Decision 124c (11), R-U4g4 Codex M2: a recorded secondary identity whose
/// pid another process now holds is counted stale per recorded key on each
/// reconcile and settles on the second independent reading, with no signal
/// to the reused pid.
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
        "id": "close-owned-resources:KEN-M:1-1", "op": "close-owned-resources", "target": "KEN-M", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "none", "stop": "pane-foreground"},
        "obligations": {"standing": [
            {"kind": "process", "pid": held.pid(), "start": "ticks:0", "role": "harness"},
        ], "discharged": [{"obligation": {"kind": "validation"}, "by": "validation-stopped", "role": "validation"}],
        "signalled": true},
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
/// (`open-terminal` runs `worktree create <id> --no-checkout`), set up as
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

/// The standing and discharged worktree rows of `intent`'s set.
fn worktree_rows(intent: &Value) -> Vec<Value> {
    let standing = intent["obligations"]["standing"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let discharged = intent["obligations"]["discharged"]
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

/// Decision 128 (9): the lane's worktree is an owned resource of the close,
/// released through the worktree package's `remove` when clean and merged,
/// else kept with its reason on the lane record and the close still
/// settled. Each row varies the fixture worktree and names the defect it
/// catches: a removal over unmerged commits or a dirty tree (work lost), a
/// refusal read as released (the record lying about the disk), a released
/// worktree with no `kept` or a kept one without its reason (prune cannot
/// judge the state). The locked row is the package's own refusal, issued
/// before anything is removed.
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

/// Decision 151 (1): the dirty read lists every untracked file whatever the
/// repository's `status.showUntrackedFiles` setting, so a draft that
/// setting hides from a plain `git status` still keeps the worktree. The
/// defect: a listing that obeys the setting reads the tree clean, and the
/// close deletes the draft with the worktree.
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

/// R-U5j5 L1 and follow-up 1. Defect: a person's file standing at a
/// gitlink's path (a vendored submodule turned into one script, not yet
/// staged) holding the close `worktree-unreadable` forever, where git reads
/// the gitlink as unpopulated; and, once it continues to the status read,
/// `submodule.<name>.ignore=all` hiding that ` T` line from a status read
/// without `--ignore-submodules=none`, so the forced removal deletes the
/// file. The close reads it dirt and keeps the worktree, the file intact.
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

/// Decision 169: the keep reads the worktree's module store and its
/// populated gitlinks, whatever the nested repositories' settings say. The
/// defect (R-U5j3, both reviews): a nested submodule's
/// own `.gitmodules` `ignore=all` empties the superproject's pinned status
/// listing for a draft in the inner tree, the tree reads clean, and the
/// package's forced removal deletes the draft with the worktree.
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

/// Decision 163: a submodule's commits are the worktree's as much as its
/// files. The defect (R-U5j3): a lane commits inside a submodule and merges
/// the gitlink bump, so the superproject's `rev-list` pre-check reads the
/// worktree merged and its status listing clean, while the submodule
/// commit's only copy is the worktree's submodule store, which the
/// package's forced removal deletes; `main` then names a commit that
/// exists nowhere.
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

/// Decision 169: a gitlink never initialized, with no store and no
/// populated directory, has nothing to lose, so a clean merged worktree
/// whose `.gitmodules` names one is released, as git's own unforced removal
/// removes it. The defect: every gitlink read as a populated submodule
/// keeps every worktree of a repository with submodules, and no lane there
/// is ever released.
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

/// Decision 166: the keep reads the index's gitlink, which no activation
/// setting changes. The defect (R-U5j4 C1): `submodule.<name>.active=false`,
/// or a `submodule.active` pattern excluding the submodule with the entry's
/// own `active` unset (gitsubmodules(7) § Active submodules), makes `git
/// submodule status` prefix a populated submodule `-`, so U5j4's keep read
/// it absent, the nested `ignore=all` emptied the pinned status, and the
/// forced removal deleted the inner draft.
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

/// Decision 166: the index's gitlink names the submodule's module store
/// whatever the activation setting says. The defect (R-U5j4 C1): a lane
/// commits inside its submodule and merges the gitlink bump, and
/// `submodule.sub.active=false` makes `git submodule status` list the
/// populated submodule `-`, so U5j4's keep read it absent, the superproject
/// read merged and clean, and the forced removal deleted the worktree's
/// module store, the commit's only copy.
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

/// Decision 169: `git submodule deinit` empties the submodule's directory
/// and leaves its module store under the worktree's git directory, which
/// the keep reads. The defect (R-U5j4 C1 and P2, both reviews): the
/// deinitialized entry lists `-`, its `.git` is gone with the tree and the
/// pinned status lists nothing, so a keep reading `submodule status` or the
/// populated directory alone released the worktree, and the forced removal
/// deleted the store, the only copy of a commit made inside the submodule,
/// and a draft a person wrote into the emptied directory.
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

/// Decision 169: the keep reads the module store and the populated
/// gitlinks of the index, so a submodule a person cloned by hand into the
/// gitlink path, its repository a `.git` directory inside the worktree's
/// tree and no store under the worktree's git directory, keeps the
/// worktree as git's own unforced removal refuses it. The defect: a keep
/// reading the store alone releases it, and the forced removal deletes the
/// clone with a draft its nested `ignore=all` hides from the pinned status.
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

/// Decision 169: the keep reads no `.gitmodules`, so a gitlink with no
/// mapping there, an embedded repository `git add` took as one, is judged
/// like any other and a clean merged worktree is released. The defect
/// (R-U5j4 M1): a read through `.gitmodules` (`git submodule status`) exits
/// 128 on the unmapped gitlink, so the close held the worktree
/// `worktree-unreadable` on every repeat and the lane never ended.
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

/// Decision 151 (2): the removal goes through the worktree package, which
/// moves a lane's mailboxes to the main checkout's `tmp/lane-mail/` before
/// git deletes the tree, so an unread notice under the worktree's ignored
/// `tmp/`, invisible to the dirty read, outlives the removal where the
/// overseer's watch reads a removed lane's mail. The defect: a raw `git
/// worktree remove` deletes the notice before its reader took it, and the
/// lane reads `done` with no `kept`.
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

/// Decision 151 (2), the package's rc 2: a lane mailbox the package cannot
/// move to the main checkout's refuses the removal with nothing removed, and
/// the close keeps the worktree `mail-unmoved`, the notice where the lane
/// wrote it. The defect: a refusal read as released, or a kept worktree
/// without the reason the mail stands for.
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

/// Decision 151 (2), the package's rc 3: a mailbox that cannot join the one
/// already in the main checkout is kept beside it, the worktree removed all
/// the same, and the close records where the package kept it on the lane
/// as `kept_mail`, the mail readable there. The defect: a released worktree
/// whose unread mail was set aside with no record of where.
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

/// R-U5j L1: the close is the one writer of the lane's `kept` and
/// `kept_mail`, and a relaunch keeps every field it does not write, so a
/// lane closed `kept: dirty`, relaunched and closed again with its worktree
/// released must read neither. The defect: a stale `kept` outlives a
/// release, and the retention duty keeps a worktree that is gone.
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

/// R-U5j M2: a `claude-cloud` lane records `host: claude-cloud` with its
/// `mail_root` the item's worktree on this machine, the one worktree the
/// legacy `lane-close` removes for a hosted lane, so its close owes that
/// worktree and releases it through the package like a local lane's. The
/// defect: the worktree standing after a done close with no `kept`, which
/// the retention duty would read as released.
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

/// R-U5j2 M1, the other side: in a claim worktree only the ` D` lines are
/// the claim's design; an untracked draft under it is work, and the close
/// keeps the worktree `dirty` with the draft intact. The defect: a claim
/// read as clean whatever it holds, the draft deleted with the worktree.
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

/// A `claude-cloud` lane on `wt`, its local worktree, as `open-terminal`
/// records it: `host` and `kind` the cloud word.
fn cloud_lane(item: &str, runner: &Runner, wt: &Path) -> Value {
    let mut lane = worktree_lane(item, runner, wt);
    lane["host"] = json!("claude-cloud");
    lane["kind"] = json!("claude-cloud");
    lane
}

/// R-U5j2 L1: a worktree package that cannot start (a script that is not
/// there never starts: the runner's cause, no `worktree-` keyed line) is no answer
/// from the package, so the worktree is held `removal-unanswered`: the
/// close `unconfirmed`, the worktree in `remaining`, the lane not `done`,
/// nothing removed, and the repeat reads it again once the install is
/// repaired. The defect: a start that failed read as the package's refusal
/// records a terminal `kept: refused:...` on a lane whose close is never
/// retried.
#[test]
fn a_worktree_package_that_cannot_start_holds_the_close_removal_unanswered() {
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
            .is_some_and(|c| c.contains("removal-unanswered:")),
        "held as no answer from the package: {report}"
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

/// Decision 128 (9), the hold: a worktree whose path cannot be read is
/// neither released nor kept; the obligation stands `worktree-unreadable`
/// and the close does not settle, so a repeated close reads it again. The
/// defect: an unreadable path discharged as released or kept would record a
/// state nothing read.
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
    // The worktree itself unreadable: its own metadata reads (the validation
    // stop's read of the root passes), its `.git` entry does not.
    std::fs::set_permissions(&wt, std::fs::Permissions::from_mode(0o000)).unwrap();
    let unread = std::fs::metadata(wt.join(".git")).is_err();
    let report = close_with_worktree(&runner, "KEN-U");
    std::fs::set_permissions(&wt, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(unread, "the probe's `.git` entry is unreadable");
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["worktree"], "unreadable",
        "{report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "worktree")["path"],
        wt.display().to_string(),
        "the worktree stands in what remains: {report}"
    );
    assert!(
        discharged_by(&report["intent"], "released").is_empty()
            && worktree_rows(&report["intent"])
                .iter()
                .all(|r| r.get("by").is_none()),
        "nothing discharged it: {report}"
    );
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    assert!(wt.exists(), "nothing was removed");
}

/// Decision 128 (9): a close whose lane record names no local worktree
/// acquires none, so a lane with no mail root and a hosted lane (whose
/// worktree is its host's, decision 57) settle with no worktree row. The
/// defect: a worktree obligation on a path this machine does not hold would
/// never settle.
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

/// Decision 128 (9) with 115 (A): the worktree is acquired, written on the
/// intent, before the removal runs, so a close that dies at its removal
/// leaves the record naming the worktree it owes and the repeated close
/// releases it. The git shim, on the PATH the worktree package inherits,
/// holds the run at the package's `git worktree remove`; the row reads the
/// record there, kills the run, and repeats the close. The defect: a
/// removal before its acquisition is written leaves a dead close with no
/// record of the worktree it was removing.
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
    // The record at the removal: the worktree standing under its role, the
    // signal written, nothing discharged about it.
    let held = runner.fleet()["intents"][0].clone();
    let standing = held["obligations"]["standing"].as_array().unwrap().clone();
    assert!(
        standing.iter().any(|o| o["kind"] == "worktree"
            && o["path"] == wt.display().to_string()
            && o["role"] == "worktree"),
        "the worktree is acquired before the removal: {held}"
    );
    assert_eq!(held["obligations"]["signalled"], true, "{held}");
    assert!(discharged_by(&held, "released").is_empty(), "{held}");
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

/// Decisions 124e (24) and 128 (9): a signalled close owing its worktree
/// under a lane that moved releases that obligation `lane-moved`, as it does
/// the validation stop, since the worktree is the session's that now holds
/// the lane; the close settles and the worktree stands. The defect: a moved
/// close removing the new session's worktree.
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
        "id": "close-owned-resources:KEN-MW:1-1", "op": "close-owned-resources", "target": "KEN-MW", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "lane_since": "2026-01-29T15:20:00Z",
        "observation": {"identity": "stopped", "worktree": "unreadable", "cause": "worktree-unreadable:permission denied"},
        "obligations": {"standing": [{"kind": "worktree", "path": wt.display().to_string(), "role": "worktree"}], "discharged": [], "signalled": true},
    }]);
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&terminal_close("KEN-MW")));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        discharged_by(&report["intent"], "lane-moved")
            .iter()
            .any(|o| o["kind"] == "worktree"),
        "the owed worktree is released to the session holding the lane: {report}"
    );
    assert!(wt.exists(), "the new session's worktree stands");
    assert!(live(new_harness.pid()), "the new session stands");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
}
