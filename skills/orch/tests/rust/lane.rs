//! Process tests of the lane cap and the close guard through the
//! `orch-runtime` executable (decisions 83, 97, 98, 105): the identities the
//! fleet records are processes this test starts and holds, so the kernel
//! table answers for them as it would for a harness, and no model or
//! mailbox takes part. The admission rows run with no tmux server at all: a
//! launch the cap admits fails before any window, since the fleet server it
//! is given does not exist, which is what those rows want, the admission
//! being the transition under test and the committed `preparing` row what
//! the next admission must see. The one row that needs a window opened
//! takes the shared private server.
//!
//! The whole suite reads the kernel's `/proc` process table for the
//! identities it holds (R-U4b3 N1), so it runs on Linux alone.
#![cfg(target_os = "linux")]
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::Duration;

use serde_json::{Value, json};
use support::*;
use tempfile::TempDir;

/// The kernel's state letter for a pid, `None` once its entry is gone.
fn state_of(pid: u32) -> Option<char> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(')')
        .and_then(|(_, rest)| rest.split_whitespace().next())
        .and_then(|f| f.chars().next())
}

/// End a held child and wait until the kernel holds it as a zombie, exited
/// and awaiting this test; it stays held unreaped, so its pid is reused by
/// nothing this test can see, and it reads gone from here.
fn end(owned: &mut Owned) {
    owned.0.kill().unwrap();
    for _ in 0..500 {
        if state_of(owned.pid()) == Some('Z') {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("the ended child never became a zombie");
}

/// The binary against a fleet state in its own directory, with no tmux
/// server to reach (the socket named does not exist), a cap, and the two
/// CLIs a close runs pointed at their quiet stubs.
struct Fleet {
    dir: TempDir,
    cap: u32,
    env: Vec<(String, String)>,
}

impl Fleet {
    fn new(cap: u32) -> Fleet {
        Fleet {
            dir: tempfile::tempdir().unwrap(),
            cap,
            env: Vec::new(),
        }
    }

    fn state_dir(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.state_dir().join("workflow-state-oversee.json")
    }

    fn run(&self, args: &[&str]) -> Output {
        let mut command = isolated();
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(args)
            .env(
                "TMUX",
                format!("{},0,0", self.state_dir().join("no-such.sock").display()),
            )
            .env("ORCH_TMUX_SESSION", "fleet")
            .env("ORCH_OVERSEER_LANES", self.cap.to_string())
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "DEV_VALIDATE_CLI",
                fixtures().join("dev-validate-quiet/dev-validate-run"),
            )
            .current_dir(self.state_dir());
        for (name, value) in &self.env {
            command.env(name, value);
        }
        command.output().expect("orch-runtime")
    }

    fn op(&self, request: &Value) -> Output {
        let path = self.state_dir().join("request.json");
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        self.run(&["op", "--fleet", "--request", &path.display().to_string()])
    }

    fn init_fleet(&self) {
        let out = self.run(&["state", "init", "--fleet"]);
        assert!(out.status.success(), "init: {}", stderr(&out));
    }

    fn fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_path()).unwrap()).unwrap()
    }

    fn write_lanes(&self, lanes: Vec<Value>) {
        let mut fleet = self.fleet();
        fleet["lanes"] = Value::Array(lanes);
        fleet["intents"] = json!([]);
        std::fs::write(
            self.fleet_path(),
            serde_json::to_string_pretty(&fleet).unwrap(),
        )
        .unwrap();
    }

    fn lane(&self, item: &str) -> Value {
        self.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .cloned()
            .unwrap_or(Value::Null)
    }
}

/// A lane record as a confirmed launch leaves it, its harness `process`,
/// with a pending return, a recovery route and a counter retained.
fn record(item: &str, status: &str, process: Option<&Owned>, mail_root: &Path) -> Value {
    let launch = match process {
        Some(p) => json!({"pane": "%7", "server": 41020, "pid": p.pid(), "start": p.start()}),
        None => Value::Null,
    };
    json!({
        "item": item,
        "harness": "claude",
        "window": format!("fleet:{item}"),
        "mail_root": mail_root.display().to_string(),
        "session_since": "2026-01-29T15:00:00Z",
        "launched_at": "2026-01-29T15:00:00Z",
        "status": status,
        "launch": launch,
        "pending_pr": {"pr": 5814, "repo": "o/r", "head": "abc"},
        "recovery": {"cwd": mail_root.display().to_string(), "flags": "", "refresh": true},
        "cycles": 2,
    })
}

fn launch(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
    })
}

fn terminal_close(item: &str) -> Value {
    json!({
        "op": "close-owned-resources",
        "item": item,
        "terminal": {"verdict": "completed", "source": "linear"},
    })
}

/// Decision 97 through the executable: a lane whose recorded harness is a
/// live process this test holds charges the cap and refuses the next lane
/// at a cap of one with the stable key and its values; the same lane ended
/// charges nothing though its status, pane and pending return still stand,
/// so the next lane is admitted with occupancy zero, its preparing row then
/// charges the cap, and the ended lane's record keeps every field.
#[test]
fn the_cap_charges_a_live_harness_and_releases_an_ended_one() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let mut harness = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let before = fleet.lane("KEN-A");

    let out = fleet.op(&launch("KEN-B", fleet.state_dir()));
    assert!(!out.status.success());
    let answer = reply(&out);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["occupancy", "1"],
            ["cap", "1"],
            ["lanes", "1"],
            ["claims", "0"]
        ])
    );
    assert!(
        stderr(&out).starts_with("orch-runtime: cap-reached occupancy=1 cap=1 lanes=1 claims=0"),
        "{}",
        stderr(&out)
    );
    assert_eq!(fleet.fleet()["lanes"].as_array().unwrap().len(), 1);
    assert!(live(harness.pid()), "a refused launch signals nothing");

    end(&mut harness);
    let out = fleet.op(&launch("KEN-B", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let admission = &answer["result"]["persisted"]["report"]["admission"];
    assert_eq!(admission["occupancy"], 0);
    assert_eq!(admission["cap"], 1);
    assert_eq!(admission["charges"], json!([]));
    // No fleet server exists here, so the admitted launch fails before any
    // window; the record it leaves is `stopped`, not a charge.
    assert_eq!(
        answer["result"]["effect"]["report"]["intent"]["outcome"],
        "failed"
    );
    assert_eq!(
        fleet.lane("KEN-A"),
        before,
        "the ended lane keeps every field"
    );

    // A preparing row under an open launch intent charges the cap: plant
    // one as an admission that has not yet confirmed or failed.
    let mut doc = fleet.fleet();
    let lanes = doc["lanes"].as_array_mut().unwrap();
    lanes[1]["status"] = json!("preparing");
    doc["intents"] = json!([{
        "id": "launch-lane:KEN-B:1-1",
        "op": "launch-lane",
        "target": "KEN-B",
        "created_at": "2026-01-29T15:00:00Z",
        "owner": {"pid": 1, "start": "ticks:0"},
        "outcome": "not-started",
        "lane_since": "2026-01-29T15:00:00Z",
    }]);
    std::fs::write(
        fleet.fleet_path(),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .unwrap();
    let out = fleet.op(&launch("KEN-C", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(answer["refusal"]["fields"][0], json!(["occupancy", "1"]));
}

/// The legacy claim store, read beside the records and never written
/// (decisions 108 (1), 111 (B)): a claim row at the server pid and pane id
/// of a lane whose launch identity reads live is read in that pane, and with
/// no server answering at the socket the pane cannot be read, so the row
/// protects a slot as unknown (the suppression itself is
/// `a_claim_is_suppressed_only_by_the_launch_identity_holding_its_pane`);
/// once that harness ends the row carries no proof of its own and protects
/// a slot; an unaccounted row protects a slot; a reservation row protects as
/// unknown while it stands, whether its launcher pid is live or gone, since
/// a pid alone is no identity; every row's bytes are as they were after the
/// count, and only the legacy launcher (here, the test in its place) removes
/// a row.
#[test]
fn legacy_claim_rows_count_by_provenance_and_are_never_pruned() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let watch = fleet.state_dir().join("watch");
    let store = watch.join("claims");
    std::fs::create_dir_all(&store).unwrap();
    let fleet_name = format!(
        "{}/workflow-state-oversee.json",
        std::fs::canonicalize(fleet.state_dir()).unwrap().display()
    );
    let row = |name: &str, server: &str, pane: &str| {
        let line = format!(
            "{server}\t{pane}\t/a/a1\tKEN-X\t2026-01-01T00:00:00Z\t{fleet_name}\ta1\tlocal\tplan\n"
        );
        std::fs::write(store.join(name), &line).unwrap();
        line
    };
    let mut launcher = Owned::sleep();
    let mut harness = Owned::sleep();
    // The lane's own claim: its server and pane.
    let own = row("claim.a1.claim", "41020", "%7");
    let reserve = row("claim.r1.reserve", &launcher.pid().to_string(), "-");
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let fleet = Fleet {
        env: vec![(
            "OVERSEE_WATCH_STATE_DIR".to_owned(),
            watch.display().to_string(),
        )],
        ..fleet
    };
    // The live lane, its claim at its numbers unreadable in a pane no server
    // answers for, and the reservation: three charges at a cap of one.
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["occupancy", "3"],
            ["cap", "1"],
            ["lanes", "1"],
            ["claims", "2"]
        ])
    );
    // The harness ends: no launch identity reads live at its server and
    // pane, so its claim row protects a slot of its own beside the
    // reservation.
    end(&mut harness);
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["occupancy", "2"],
            ["cap", "1"],
            ["lanes", "0"],
            ["claims", "2"]
        ])
    );
    // The launcher ends: its reservation stands and still protects; a pid
    // the kernel has no process for is not a read of the attempt.
    end(&mut launcher);
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(answer["refusal"]["fields"][0], json!(["occupancy", "2"]));
    // Read-only: every row stands with its bytes through every count.
    assert_eq!(
        std::fs::read_to_string(store.join("claim.a1.claim")).unwrap(),
        own
    );
    assert_eq!(
        std::fs::read_to_string(store.join("claim.r1.reserve")).unwrap(),
        reserve
    );
    // The legacy launcher removes its rows (the test here, in its place);
    // the lane is then admitted, and an unaccounted claim protects a slot
    // the next launch meets.
    std::fs::remove_file(store.join("claim.a1.claim")).unwrap();
    std::fs::remove_file(store.join("claim.r1.reserve")).unwrap();
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["ok"], true, "{answer}");
    let admission = &answer["result"]["persisted"]["report"]["admission"];
    assert_eq!(admission["occupancy"], 0);
    let stray = row("claim.s2.claim", "41020", "%9");
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let answer = reply(&fleet.op(&launch("KEN-C", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["occupancy", "1"],
            ["cap", "1"],
            ["lanes", "0"],
            ["claims", "1"]
        ])
    );
    assert_eq!(
        std::fs::read_to_string(store.join("claim.s2.claim")).unwrap(),
        stray
    );
    // A store that is not a directory refuses rather than counting nothing.
    std::fs::remove_dir_all(&store).unwrap();
    std::fs::write(&store, "").unwrap();
    let answer = reply(&fleet.op(&launch("KEN-D", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-unreadable");
    assert_eq!(answer["refusal"]["fields"][0], json!(["source", "claims"]));
}

/// Decision 83 through the executable: a bare close on a lane whose harness
/// runs refuses `lane-live` and signals nothing; with the tracker's terminal
/// verdict the close asks the mailbox for unanswered asks first and refuses
/// `ask-unanswered` while one stands, the harness still live; with none it
/// ends the harness exactly, stops the worktree's validation runs through
/// the runner and records the lane done with the verdict on its log row.
#[test]
fn a_close_needs_a_ground_asks_the_mailbox_and_then_ends_the_harness() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let harness = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let bare = json!({"op": "close-owned-resources", "item": "KEN-A"});
    let answer = reply(&fleet.op(&bare));
    assert_eq!(answer["refusal"]["key"], "lane-live");
    assert!(live(harness.pid()));
    assert_eq!(fleet.lane("KEN-A")["status"], "running");

    let ask = r#"{"id":"1769700000-9-31","kind":"ask","text":"which base"}"#;
    let asking = Fleet {
        env: vec![("LANE_MAIL_ASKS".to_owned(), ask.to_owned())],
        ..fleet
    };
    let answer = reply(&asking.op(&terminal_close("KEN-A")));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["intent"]["observation"]["cause"], "ask-unanswered");
    assert_eq!(report["intent"]["observation"]["ask"], "1769700000-9-31");
    assert!(live(harness.pid()), "an unanswered ask stops nothing");
    assert_eq!(asking.lane("KEN-A")["status"], "running");

    let mail_log = asking.state_dir().join("mail.log");
    let validate_log = asking.state_dir().join("validate.log");
    let fleet = Fleet {
        env: vec![
            ("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()),
            (
                "DEV_VALIDATE_LOG".to_owned(),
                validate_log.display().to_string(),
            ),
        ],
        ..asking
    };
    let answer = reply(&fleet.op(&terminal_close("KEN-A")));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(!live(harness.pid()), "the recorded harness ended");
    let lane = fleet.lane("KEN-A");
    assert_eq!(lane["status"], "done");
    assert!(
        lane.get("pending_pr").is_none(),
        "a full close drops the PR identity"
    );
    let root = fleet.state_dir().display().to_string();
    assert_eq!(
        std::fs::read_to_string(&mail_log).unwrap(),
        format!("pending --item KEN-A --root {root}\n")
    );
    assert_eq!(
        std::fs::read_to_string(&validate_log).unwrap(),
        format!("--stop --worktree {root}\n")
    );
    let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
    let row = log.last().unwrap();
    assert_eq!(row["kind"], "close");
    assert_eq!(row["verdict"], "completed");
    assert_eq!(row["source"], "linear");
}

/// Decision 98 through the executable: a `no-landing` disposition on a lane
/// whose recorded harness is gone retires the attempt and keeps the item's
/// work: the lane reads stopped with its pending return, launch, recovery
/// route and counter, the log row carries the disposition, and the retired
/// attempt charges nothing.
#[test]
fn a_no_landing_disposition_retires_the_attempt_and_keeps_the_work() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let mut harness = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    end(&mut harness);
    let before = fleet.lane("KEN-A");
    let disposition = json!({
        "op": "close-owned-resources",
        "item": "KEN-A",
        "no_landing": {"reason": "diagnosis-complete", "source": "overseer"},
    });
    let answer = reply(&fleet.op(&disposition));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["intent"]["close"]["ground"], "no-landing");
    let mut kept = before.clone();
    kept["status"] = json!("stopped");
    assert_eq!(
        fleet.lane("KEN-A"),
        kept,
        "everything but the status stands"
    );
    let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
    let row = log.last().unwrap();
    assert_eq!(row["disposition"], "no-landing");
    assert_eq!(row["reason"], "diagnosis-complete");
    // The retired attempt holds no slot: the next lane is admitted at a cap
    // of one.
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(
        answer["result"]["persisted"]["report"]["admission"]["occupancy"],
        0
    );
}

/// Decision 105 (3) with decision 68: a recorded identity live under another
/// start is a reused pid. With a recorded pane on a server the host does not
/// answer for (the server process lives, its socket does not), the close is
/// `unconfirmed` on every reading, counts none, and the lane stands with its
/// handle; with no pane recorded at all, the second independent reading
/// confirms and the lane is done.
#[test]
fn a_recorded_pane_the_host_does_not_answer_for_never_confirms_a_stale_close() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    // The reused pid: a live child under a start the record does not carry.
    let reused = Owned::sleep();
    // The "server": a live process whose pid the record names as the tmux
    // server and no socket answers for, so the pane is unobservable.
    let server = Owned::sleep();
    let with_pane = |pane: Value, server_pid: Value| {
        let mut rec = record("KEN-S", "running", None, fleet.state_dir());
        rec["launch"] = json!({
            "pane": pane,
            "server": server_pid,
            "pid": reused.pid(),
            "start": "ticks:0",
        });
        rec
    };
    fleet.write_lanes(vec![with_pane(json!("%7"), json!(server.pid()))]);
    for reading in 1..=2 {
        let answer = reply(&fleet.op(&terminal_close("KEN-S")));
        assert_eq!(answer["ok"], true, "{answer}");
        let report = &answer["result"]["effect"]["report"];
        assert_eq!(
            report["intent"]["outcome"], "unconfirmed",
            "reading {reading}: {report}"
        );
        let observation = &report["intent"]["observation"];
        assert_eq!(observation["identity"], "stale", "reading {reading}");
        assert_eq!(observation["observed"], "unobservable", "reading {reading}");
        assert_eq!(
            observation["cause"], "server-unreachable",
            "reading {reading}"
        );
        assert!(
            observation.get("readings").is_none(),
            "reading {reading}: an unreadable recorded pane counts no reading: {observation}"
        );
        assert_eq!(fleet.lane("KEN-S")["status"], "running");
        assert!(live(reused.pid()), "the reused pid is never signalled");
    }
    // The same identity with no pane recorded: decision 68's second
    // reading confirms.
    fleet.write_lanes(vec![with_pane(Value::Null, Value::Null)]);
    let first = reply(&fleet.op(&terminal_close("KEN-S")));
    let report = &first["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["observed"], "unrecorded");
    assert_eq!(report["intent"]["observation"]["readings"], 1);
    let second = reply(&fleet.op(&terminal_close("KEN-S")));
    let report = &second["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["readings"], 2);
    assert_eq!(fleet.lane("KEN-S")["status"], "done");
    assert!(live(reused.pid()), "the reused pid is never signalled");
}

/// Decision 105 (2): a launch whose window opened but whose line could not
/// be typed closes its one pane by exact id; when that close does not
/// confirm either, the launch stays `unconfirmed` at `opening` with the pane
/// recorded and the intent open, the lane `preparing`, and the pane still
/// standing on the server. Once the host answers again, the reconcile past
/// the bound closes that recorded pane and fails the launch.
#[test]
fn a_launch_whose_line_and_cleanup_both_fail_keeps_its_intent_and_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env = vec![
        ("TMUX_REAL".to_owned(), which_tmux()),
        // The line's paste and the pane's close both refused: the host
        // answers for the window and for nothing after it.
        (
            "TMUX_FAIL_VERB".to_owned(),
            "load-buffer kill-pane".to_owned(),
        ),
    ];
    runner.init_fleet();
    let panes_before = server.panes().len();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-L", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["phase"], "opening");
    assert_eq!(observation["note"], "launch-line-unsent");
    assert_eq!(observation["refusal"], "external-failed");
    assert!(
        observation["cause"]
            .as_str()
            .is_some_and(|cause| cause.starts_with("pane-close:")),
        "the close's cause travels: {observation}"
    );
    let fleet = runner.fleet();
    let intent = &fleet["intents"][0];
    assert!(
        intent["completed_at"].is_null(),
        "the intent stays open: {intent}"
    );
    assert_eq!(intent["phase"]["phase"], "opening");
    let pane = intent["phase"]["pane"]
        .as_str()
        .expect("the recorded pane")
        .to_owned();
    assert_eq!(
        remaining(observation, "pane")["pane"],
        pane,
        "the standing pane is on the outcome"
    );
    assert_eq!(fleet["lanes"][0]["status"], "preparing");
    assert_eq!(server.panes().len(), panes_before + 1, "the pane stands");
    assert!(server.panes().contains(&pane));
    // The host answers again: past the bound the reconcile closes exactly
    // the recorded pane and the launch fails, nothing registered.
    runner.tools = None;
    runner.env = Vec::new();
    std::thread::sleep(Duration::from_millis(1100));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"],
        "nothing-registered"
    );
    assert_eq!(report["intent"]["observation"]["cause"], "pane-closed");
    assert!(
        !server.panes().contains(&pane),
        "the recorded pane is closed"
    );
    assert_eq!(server.panes().len(), panes_before);
    assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
}

/// Decision 105 and R-U4a5 L1: a lane whose recorded harness is gone and
/// whose record names no pane holds nothing to close. The close confirms on
/// the first request and the lane reads done; no second reading is asked
/// for, since no handle was recorded, which is not a recorded handle the
/// host did not answer for.
#[test]
fn a_close_of_a_gone_identity_with_no_pane_recorded_confirms_on_the_first_request() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let mut gone = Owned::sleep();
    let start = gone.start();
    end(&mut gone);
    let mut rec = record("KEN-G", "running", None, fleet.state_dir());
    rec["launch"] = json!({"pane": null, "server": null, "pid": gone.pid(), "start": start});
    fleet.write_lanes(vec![rec]);
    let answer = reply(&fleet.op(&terminal_close("KEN-G")));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(
        report["intent"]["observation"].get("readings").is_none(),
        "no second reading is owed with no handle recorded: {report}"
    );
    assert_eq!(fleet.lane("KEN-G")["status"], "done");
}

/// Decision 105 (2) on a lane close: the recorded harness is stopped
/// exactly, then the close of its recorded window is refused by the host.
/// The close stays `unconfirmed` with the recorded pane on the outcome and
/// the lane not done, nothing claimed past the close that did not answer;
/// once the host answers, the repeated close closes the standing window and
/// the lane reads done. The recorded harness is a process this test holds
/// and the recorded pane an idle shell, so the window stands after the exact
/// stop, as a harness under a wrapper shell leaves it.
#[test]
fn a_close_whose_window_close_is_refused_stays_unconfirmed_until_the_host_answers() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_idle("KEN-W", runner.state_dir());
    let harness = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-W",
        "running",
        &runner,
        json!({
            "pane": pane,
            "server": server.pid,
            "pid": harness.pid(),
            "start": harness.start(),
        }),
    )]);
    runner.write_fleet(&fleet);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env.push(("TMUX_REAL".to_owned(), which_tmux()));
    runner
        .env
        .push(("TMUX_FAIL_VERB".to_owned(), "kill-window".to_owned()));
    let closed = effect_report(&runner.op_fleet(&terminal_close("KEN-W")));
    assert_eq!(closed["intent"]["outcome"], "unconfirmed", "{closed}");
    let observation = &closed["intent"]["observation"];
    assert_eq!(observation["identity"], "stopped");
    assert!(
        observation["cause"]
            .as_str()
            .is_some_and(|cause| cause.starts_with("pane-close:")),
        "the refused close is the cause: {observation}"
    );
    assert_eq!(
        remaining(observation, "pane")["pane"],
        pane,
        "the recorded pane is on the outcome"
    );
    assert!(!live(harness.pid()), "the harness was stopped exactly");
    assert!(server.panes().contains(&pane), "the pane stands unclosed");
    let fleet = runner.fleet();
    assert_eq!(
        fleet["lanes"][0]["status"], "running",
        "the lane is not done"
    );
    assert!(
        fleet["intents"][0]["completed_at"].is_null(),
        "the close stays open"
    );
    // The host answers again: the repeated close closes the standing window
    // of the stopped harness and confirms.
    runner.tools = None;
    runner.env.retain(|(name, _)| name != "TMUX_FAIL_VERB");
    let again = effect_report(&runner.op_fleet(&terminal_close("KEN-W")));
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "done");
    assert!(
        !server.panes().contains(&pane),
        "the lane's window is closed"
    );
}

/// Decision 111 (A) (1), R-U4a6b C1 (2): a pane recorded with no server
/// (the legacy launch object admits a null server, decision 35) is a handle
/// this host cannot address, not an absent one. With the recorded identity
/// gone, the close discharges that identity by its own read and holds the
/// pane unaddressed as the remaining obligation: `unconfirmed`, the lane
/// never `done`, on the first request and on the repeat alike.
#[test]
fn a_pane_recorded_without_its_server_is_never_read_as_absent() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let mut gone = Owned::sleep();
    let start = gone.start();
    end(&mut gone);
    let mut rec = record("KEN-U", "running", None, fleet.state_dir());
    rec["launch"] = json!({"pane": "%7", "server": null, "pid": gone.pid(), "start": start});
    fleet.write_lanes(vec![rec]);
    for request in 1..=2 {
        let answer = reply(&fleet.op(&terminal_close("KEN-U")));
        assert_eq!(answer["ok"], true, "request {request}: {answer}");
        let report = &answer["result"]["effect"]["report"];
        assert_eq!(
            report["intent"]["outcome"], "unconfirmed",
            "request {request}: {report}"
        );
        let observation = &report["intent"]["observation"];
        assert_eq!(observation["identity"], "gone", "request {request}");
        assert_eq!(observation["observed"], "unrecorded", "request {request}");
        let pane = remaining(observation, "pane");
        assert_eq!(pane["pane"], "%7", "request {request}: {observation}");
        assert_eq!(
            pane["unaddressable"], true,
            "request {request}: {observation}"
        );
        assert!(pane["server"].is_null(), "request {request}: {observation}");
        assert!(
            remaining(observation, "process").is_null(),
            "request {request}: the gone identity is discharged: {observation}"
        );
        assert_eq!(
            fleet.lane("KEN-U")["status"],
            "running",
            "request {request}: the lane is never done over an unaddressed pane"
        );
    }
}

/// The legacy fleet launch lock as the test holds it: `flock(1)` on
/// `<fleet>.launch.lock`, the lock `lane-cap.sh`'s `cap_take` holds around
/// its count and its reservation write, kept by a child the test owns until
/// the child is ended (`-o`: the held descriptor is the holder's alone, so
/// ending the holder releases the lock).
fn hold_launch_lock(fleet: &Fleet) -> (PathBuf, Owned) {
    let lock = PathBuf::from(format!(
        "{}/workflow-state-oversee.json.launch.lock",
        std::fs::canonicalize(fleet.state_dir()).unwrap().display()
    ));
    let holder = Owned(
        Command::new("flock")
            .args(["-x", "-o"])
            .arg(&lock)
            .args(["sleep", "60"])
            .spawn()
            .expect("flock"),
    );
    // Held once a non-blocking take refuses.
    for _ in 0..500 {
        let probe = Command::new("flock")
            .args(["-n", "-x"])
            .arg(&lock)
            .arg("true")
            .output()
            .expect("flock probe");
        if !probe.status.success() {
            return (lock, holder);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("the holder never took the launch lock");
}

/// A fleet `op` spawned as a child the test drives, its request in a file
/// of its own so two may run at once, with `extra` environment and `tools`
/// ahead of the inherited `PATH`.
fn spawn_op(
    fleet: &Fleet,
    request: &Value,
    extra: &[(&str, &str)],
    tools: Option<&Path>,
) -> std::process::Child {
    let name = format!("request-{}.json", request["item"].as_str().unwrap());
    let path = fleet.state_dir().join(name);
    std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
    let mut command = isolated();
    command
        .args(["--state-dir", &fleet.state_dir().display().to_string()])
        .args(["op", "--fleet", "--request", &path.display().to_string()])
        .env(
            "TMUX",
            format!("{},0,0", fleet.state_dir().join("no-such.sock").display()),
        )
        .env("ORCH_TMUX_SESSION", "fleet")
        .env("ORCH_OVERSEER_LANES", fleet.cap.to_string())
        .env(
            "LANE_MAIL_CLI",
            fixtures().join("lane-mail-quiet/lane-mail"),
        )
        .env(
            "DEV_VALIDATE_CLI",
            fixtures().join("dev-validate-quiet/dev-validate-run"),
        )
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .current_dir(fleet.state_dir());
    if let Some(tools) = tools {
        let inherited = std::env::var("PATH").unwrap_or_default();
        command.env("PATH", format!("{}:{inherited}", tools.display()));
    }
    for (name, value) in extra {
        command.env(name, value);
    }
    command.spawn().expect("spawn orch-runtime op")
}

/// Whether `pid` holds an open descriptor on `path`, read from the kernel's
/// own table of its descriptors.
fn holds_open(pid: u32, path: &Path) -> bool {
    let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
        return false;
    };
    fds.flatten()
        .any(|fd| std::fs::read_link(fd.path()).is_ok_and(|target| target == path))
}

/// Wait until the contender `child` stands at the launch lock: `record::lock`
/// opens `<fleet>.launch.lock` before its bounded poll of the flock and holds
/// the descriptor through it, so a contender holding one while this test's
/// holder holds the lock has reached the lock boundary and not passed it.
/// Bounded by a deadline of the test's own; a contender that ends first
/// fails the row.
fn await_at_lock(lock: &Path, child: &mut std::process::Child) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        assert!(
            child.try_wait().unwrap().is_none(),
            "the contender ended before reaching the launch lock"
        );
        if holds_open(child.id(), lock) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the contender never reached the launch lock"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Decision 108 (3): the admission takes the legacy fleet launch lock. While
/// a process this test owns holds `<fleet>.launch.lock` with `flock(1)`,
/// as the legacy launcher does around its count, the runtime's admission
/// reaches the lock and waits there with nothing written; once the holder
/// ends it admits, once.
#[test]
fn admission_waits_on_the_held_legacy_launch_lock_and_then_admits_once() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let before = fleet.fleet();
    let (lock, holder) = hold_launch_lock(&fleet);
    let mut waiting = spawn_op(&fleet, &launch("KEN-A", fleet.state_dir()), &[], None);
    await_at_lock(&lock, &mut waiting);
    assert_eq!(fleet.fleet(), before, "nothing is written while it waits");
    drop(holder);
    let out = waiting.wait_with_output().unwrap();
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let admission = &answer["result"]["persisted"]["report"]["admission"];
    assert_eq!(admission["occupancy"], 0);
    assert_eq!(fleet.fleet()["lanes"].as_array().unwrap().len(), 1);
    assert!(
        lock.is_file(),
        "the lock file is the legacy's: {}",
        lock.display()
    );
}

/// Decision 108 (3) with two runtime contenders at cap minus one: both reach
/// the launch lock the test holds and wait there; released together, exactly
/// one is admitted and the other, counting the winner's committed preparing
/// row under the same lock, refuses `cap-reached`, not `record-changed`. The
/// winner's effect is held at its first tmux call by the tmux-hold shim, so
/// its preparing row stands while the loser counts.
#[test]
fn two_contenders_at_cap_minus_one_admit_exactly_one_under_the_launch_lock() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let real_tmux = which_tmux();
    let holddir = fixtures().join("tmux-hold");
    let fifo = fleet.state_dir().join("hold.fifo");
    mkfifo(&fifo);
    let (lock, holder) = hold_launch_lock(&fleet);
    let shim_env = [
        ("TMUX_REAL", real_tmux.as_str()),
        ("TMUX_HOLD_FIFO", &fifo.display().to_string()),
        ("TMUX_HOLD_VERB", "display-message"),
    ];
    let mut contenders = vec![
        spawn_op(
            &fleet,
            &launch("KEN-A", fleet.state_dir()),
            &shim_env,
            Some(&holddir),
        ),
        spawn_op(
            &fleet,
            &launch("KEN-B", fleet.state_dir()),
            &shim_env,
            Some(&holddir),
        ),
    ];
    for contender in &mut contenders {
        await_at_lock(&lock, contender);
    }
    drop(holder);
    // The loser ends first: the winner is held in its effect.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let loser = loop {
        if let Some(index) = contenders
            .iter_mut()
            .position(|c| c.try_wait().unwrap().is_some())
        {
            break contenders.remove(index);
        }
        assert!(std::time::Instant::now() < deadline, "no contender ended");
        std::thread::sleep(Duration::from_millis(20));
    };
    let refused = reply(&loser.wait_with_output().unwrap());
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["refusal"]["key"], "cap-reached", "{refused}");
    assert_eq!(refused["refusal"]["fields"][0], json!(["occupancy", "1"]));
    let standing = fleet.fleet();
    assert_eq!(standing["lanes"].as_array().unwrap().len(), 1);
    assert_eq!(standing["lanes"][0]["status"], "preparing");
    // Release the winner: its effect meets no fleet server and fails; the
    // admission it reports is the one that committed.
    std::fs::write(&fifo, b"go\n").unwrap();
    let winner = contenders.remove(0);
    let admitted = reply(&winner.wait_with_output().unwrap());
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(
        admitted["result"]["persisted"]["report"]["admission"]["occupancy"],
        0
    );
    assert_eq!(fleet.fleet()["lanes"].as_array().unwrap().len(), 1);
}

/// A claim store beside the fleet, as the legacy launcher keeps it, with the
/// fleet spelled the way its rows spell it: the store, and the one-row writer
/// returning the bytes written.
fn claim_store(fleet: &Fleet) -> (PathBuf, impl Fn(&str, &str, &str) -> String + use<>) {
    let watch = fleet.state_dir().join("watch");
    let store = watch.join("claims");
    std::fs::create_dir_all(&store).unwrap();
    let fleet_name = format!(
        "{}/workflow-state-oversee.json",
        std::fs::canonicalize(fleet.state_dir()).unwrap().display()
    );
    let path = store.clone();
    let row = move |name: &str, server: &str, pane: &str| {
        let line = format!(
            "{server}\t{pane}\t/a/a1\tKEN-X\t2026-01-01T00:00:00Z\t{fleet_name}\ta1\tlocal\tplan\n"
        );
        std::fs::write(path.join(name), &line).unwrap();
        line
    };
    (watch, row)
}

/// R-U4b2 C1, decision 111 (B): a live detached wake proves execution
/// outside any pane, and the launch coordinates a stopped lane keeps name a
/// server pid and a pane id a later server and another attempt's window may
/// hold. Another attempt's claim at those numbers is therefore protected:
/// the wake charges once and the claim once, and at a cap of two the next
/// lane is refused, the claim's bytes untouched. With the launch identity
/// live and no server answering at the socket, the pane the claim names
/// cannot be read, and the claim protects as unknown with the cause.
#[test]
fn a_live_wake_at_stale_launch_coordinates_never_suppresses_another_attempts_claim() {
    let fleet = Fleet::new(2);
    fleet.init_fleet();
    let (watch, row) = claim_store(&fleet);
    let other = row("claim.b2.claim", "41020", "%7");
    let mut launched = Owned::sleep();
    let launched_start = launched.start();
    end(&mut launched);
    let wake = Owned::sleep();
    let mut rec = record("KEN-A", "stopped", None, fleet.state_dir());
    rec["launch"] = json!({
        "pane": "%7",
        "server": 41020,
        "pid": launched.pid(),
        "start": launched_start,
    });
    rec["wake"] = json!({"pid": wake.pid(), "start": wake.start()});
    fleet.write_lanes(vec![rec.clone()]);
    let fleet = Fleet {
        env: vec![
            (
                "OVERSEE_WATCH_STATE_DIR".to_owned(),
                watch.display().to_string(),
            ),
            (
                "ORCH_HARNESS_BINARIES".to_owned(),
                format!("claude={}", stub("stub-confirm").display()),
            ),
        ],
        ..fleet
    };
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached", "{answer}");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["occupancy", "2"],
            ["cap", "2"],
            ["lanes", "1"],
            ["claims", "1"]
        ])
    );
    assert!(live(wake.pid()), "a refused launch signals nothing");
    assert_eq!(
        std::fs::read_to_string(watch.join("claims").join("claim.b2.claim")).unwrap(),
        other
    );
    // The launch identity live at those numbers: the pane is read on the
    // server the socket names, and none answers, so the claim protects as
    // unknown with the cause; at a cap of three the launch is admitted and
    // its admission names the charge.
    let launched = Owned::sleep();
    rec["launch"] = json!({
        "pane": "%7",
        "server": 41020,
        "pid": launched.pid(),
        "start": launched.start(),
    });
    fleet.write_lanes(vec![rec]);
    let fleet = Fleet { cap: 3, ..fleet };
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    assert_eq!(answer["ok"], true, "{answer}");
    let admission = &answer["result"]["persisted"]["report"]["admission"];
    assert_eq!(admission["occupancy"], 2, "{admission}");
    let charges = admission["charges"].as_array().unwrap();
    assert!(
        charges.contains(&json!({
            "source": "claim",
            "file": "claim.b2.claim",
            "reason": "unknown",
            "cause": "server-unreachable",
        })),
        "{admission}"
    );
    assert!(
        charges.contains(&json!({"source": "lane", "item": "KEN-A", "reason": "live"})),
        "{admission}"
    );
    // No fleet server exists here, so the admitted launch fails before any
    // window.
    assert_eq!(
        answer["result"]["effect"]["report"]["intent"]["outcome"],
        "failed"
    );
    assert!(live(launched.pid()) && live(wake.pid()));
}

/// Decision 111 (B), the suppression itself, on a private server: the lane's
/// launch identity is the process holding the terminal of the pane its
/// launch records, so the claim at that server pid and pane id doubles it
/// and adds nothing, one slot at a cap of one. The same claim with the
/// launch identity live outside the pane (a process this test holds) adds a
/// slot: the pane's foreground is not that identity, and equal numbers alone
/// prove nothing. With the pane closed and the identity still live, the row
/// protects as well.
#[test]
fn a_claim_is_suppressed_only_by_the_launch_identity_holding_its_pane() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let server = Server::start(fleet.state_dir(), "fleet");
    let pane = server.open_idle("KEN-A", fleet.state_dir());
    let pane_pid = server.pane_pid(&pane);
    let (watch, row) = claim_store(&fleet);
    let own = row("claim.a1.claim", &server.pid.to_string(), &pane);
    let mut rec = record("KEN-A", "running", None, fleet.state_dir());
    rec["launch"] = json!({
        "pane": pane,
        "server": server.pid,
        "pid": pane_pid,
        "start": start_of(pane_pid),
    });
    fleet.write_lanes(vec![rec.clone()]);
    let fleet = Fleet {
        env: vec![
            (
                "TMUX".to_owned(),
                format!("{},0,0", server.socket.display()),
            ),
            (
                "OVERSEE_WATCH_STATE_DIR".to_owned(),
                watch.display().to_string(),
            ),
            (
                "ORCH_HARNESS_BINARIES".to_owned(),
                format!("claude={}", stub("stub-confirm").display()),
            ),
        ],
        ..fleet
    };
    let refused = |answer: &Value, lanes: &str, claims: &str, occupancy: &str| {
        assert_eq!(answer["refusal"]["key"], "cap-reached", "{answer}");
        assert_eq!(
            answer["refusal"]["fields"],
            json!([
                ["occupancy", occupancy],
                ["cap", "1"],
                ["lanes", lanes],
                ["claims", claims]
            ]),
            "{answer}"
        );
    };
    // The launch identity holds the claimed pane: the claim is its double.
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    refused(&answer, "1", "0", "1");
    // The launch identity live, but not the process in the pane's
    // foreground: the claim protects.
    let elsewhere = Owned::sleep();
    rec["launch"]["pid"] = json!(elsewhere.pid());
    rec["launch"]["start"] = json!(elsewhere.start());
    fleet.write_lanes(vec![rec]);
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    refused(&answer, "1", "1", "2");
    // The claimed pane closed, the identity live: gone protects too.
    let killed = tmux(&server.socket, &["kill-pane", "-t", &pane]);
    assert!(killed.status.success(), "kill-pane: {}", stderr(&killed));
    let answer = reply(&fleet.op(&launch("KEN-B", fleet.state_dir())));
    refused(&answer, "1", "1", "2");
    assert!(live(elsewhere.pid()), "a refused launch signals nothing");
    assert_eq!(
        std::fs::read_to_string(watch.join("claims").join("claim.a1.claim")).unwrap(),
        own,
        "the store is read, never written"
    );
}
