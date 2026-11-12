//! Process tests of the lane cap and the close guard through the
//! `orch-runtime` executable: the identities the
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
//! identities it holds, so it runs on Linux alone.
#![cfg(target_os = "linux")]
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
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

    /// The accounts judge's listing: `rows` planted as the provider's
    /// `accounts` answer under `fleet-vm`, the host fixture linked into the
    /// state directory, so the listing lists them under that host and
    /// every row keeps the directory it names.
    fn plant_listing(&mut self, rows: &[Value]) {
        let rows: Vec<Value> = rows
            .iter()
            .map(|row| {
                let mut row = row.clone();
                row["measured_through"] = json!("host");
                row
            })
            .collect();
        let env = plant_accounts(
            self.state_dir(),
            self.state_dir(),
            Some("fleet-vm"),
            &rows,
            epoch_now(),
        );
        for (key, value) in env {
            self.env.retain(|(name, _)| *name != key);
            self.env.push((key, value));
        }
    }

    /// The listing made unreadable, or readable again: the host's
    /// capability line refused.
    fn refuse_listing(&self, refused: bool) {
        let path = self.state_dir().join("lane-host.json");
        let mut map: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        map["fleet-vm capabilities"] = if refused {
            json!({"exit": 1, "stderr": "lane-host-fixture: capabilities-refused\n"})
        } else {
            json!({"stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\tpool=plan\n"})
        };
        std::fs::write(path, map.to_string()).unwrap();
    }
}

/// The one measured account of the room rows.
const ACCOUNT: &str = "/home/me/.aclaude";

fn epoch_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// [`ACCOUNT`]'s row of `lanes list --json`: a measured Claude account with
/// its weekly window, the binding, at `weekly` percent, read this instant
/// with a week to its reset: each lane on it, the live ones and the
/// candidate, is charged the setting's burn for the week, about 25 points,
/// so at 60 percent one live lane and the candidate project 10 past the
/// room, and the candidate alone leaves 15.
fn listing_row(weekly_pct: u64, now: u64) -> Value {
    let weekly = clock::iso_utc(now + 7 * 86_400);
    json!({
        "alias": "aclaude",
        "harness": "claude",
        "config_dir": ACCOUNT,
        "measured_through": "local",
        "status": "ok",
        "verdict": "room",
        "headroom_pct": 100 - weekly_pct,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": weekly_pct,
        "weekly_pct": weekly_pct,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"weekly": weekly, "model": null, "monthly": null},
        "usage_rate_state": "one-sample",
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
    })
}

/// A lane record on [`ACCOUNT`], its harness `process`, holding its slot
/// through a reservation to `until` where one is named.
fn lane_on(
    item: &str,
    status: &str,
    process: Option<&Owned>,
    until: Option<&str>,
    mail_root: &Path,
) -> Value {
    let mut lane = record(item, status, process, mail_root);
    lane["account"] = json!(ACCOUNT);
    if let Some(until) = until {
        lane["reservation"] = json!({"reason": "resume", "until": until});
    }
    lane
}

/// A launch of `item` on [`ACCOUNT`] for `opus` that asks for the
/// account's room to be judged, the request the room judge reads.
fn launch_on(item: &str, mail_root: &Path) -> Value {
    let mut request = launch(item, mail_root);
    request["account"] = json!(ACCOUNT);
    request["model"] = json!("opus");
    request["effort"] = json!("high");
    request["judge_account"] = json!(true);
    request
}

/// A refusal's fields by name.
fn refusal_fields(answer: &Value) -> HashMap<String, String> {
    answer["refusal"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pair| {
            (
                pair[0].as_str().unwrap().to_owned(),
                pair[1].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

/// A relaunch is judged without its own lane's charge, and never admitted
/// onto an account another lane has filled. The account's weekly window
/// leaves room for no second lane. KEN-1's record stands stopped with a
/// reservation (a charge) and KEN-2 runs live on the account: KEN-1's
/// relaunch is refused `account-walled` on KEN-2's charge and its own as
/// the candidate (two lanes' projection, not three) and moves nothing; with
/// KEN-2 ended it is admitted, its own reservation left out of the
/// judgement as the relaunch drops it, and its record carries none after.
#[test]
fn a_relaunch_is_judged_with_its_own_lanes_charge_left_out() {
    let mut fleet = Fleet::new(4);
    fleet.init_fleet();
    let now = epoch_now();
    fleet.plant_listing(&[listing_row(60, now)]);
    let mut other = Owned::sleep();
    let until = clock::iso_utc(now + 3600);
    fleet.write_lanes(vec![
        lane_on("KEN-1", "stopped", None, Some(&until), fleet.state_dir()),
        lane_on("KEN-2", "running", Some(&other), None, fleet.state_dir()),
    ]);
    let before = fleet.lane("KEN-1");

    let out = fleet.op(&launch_on("KEN-1", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-walled",
        "{}",
        stderr(&out)
    );
    let fields = refusal_fields(&answer);
    assert_eq!(fields["account"], ACCOUNT);
    assert_eq!(fields["model"], "opus");
    assert_eq!(fields["bucket"], "weekly");
    assert_eq!(fields["pct"], "60");
    let headroom: f64 = fields["projected-headroom"].parse().unwrap();
    assert!(
        (-10.5..-9.5).contains(&headroom),
        "KEN-2's charge and the candidate's, not KEN-1's own reservation: {headroom}"
    );
    assert!(
        stderr(&out).starts_with(&format!(
            "orch-runtime: account-walled item=KEN-1 account={ACCOUNT} model=opus pct=60 bucket=weekly projected-headroom="
        )),
        "{}",
        stderr(&out)
    );
    assert_eq!(
        fleet.lane("KEN-1"),
        before,
        "a refused relaunch moves nothing"
    );
    assert!(live(other.pid()), "a refused relaunch signals nothing");

    end(&mut other);
    let out = fleet.op(&launch_on("KEN-1", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(
        answer["result"]["persisted"]["report"]["admission"]["cap"],
        4
    );
    assert!(
        fleet.lane("KEN-1").get("reservation").is_none(),
        "the relaunch takes its own reservation's slot: {}",
        fleet.lane("KEN-1")
    );
}

/// A launch with no record replaces no lane, so every standing charge
/// counts against it. KEN-1's reservation on the account counts against a
/// fresh launch of KEN-3, refused `account-walled` on that one charge with
/// no record written; the listing made unreadable refuses it
/// `account-unjudged`; an account with no row is admitted unjudged, the
/// launch proceeding as given.
#[test]
fn a_launch_with_no_record_is_judged_fresh_and_an_unread_listing_admits_nothing() {
    let mut fleet = Fleet::new(4);
    fleet.init_fleet();
    let now = epoch_now();
    fleet.plant_listing(&[listing_row(60, now)]);
    let until = clock::iso_utc(now + 3600);
    fleet.write_lanes(vec![lane_on(
        "KEN-1",
        "stopped",
        None,
        Some(&until),
        fleet.state_dir(),
    )]);

    let out = fleet.op(&launch_on("KEN-3", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-walled",
        "{}",
        stderr(&out)
    );
    let headroom: f64 = refusal_fields(&answer)["projected-headroom"]
        .parse()
        .unwrap();
    assert!(
        (-10.5..-9.5).contains(&headroom),
        "KEN-1's reservation and the candidate charge a launch that replaces nothing: {headroom}"
    );
    assert_eq!(
        fleet.fleet()["lanes"].as_array().unwrap().len(),
        1,
        "a refused launch writes no record"
    );

    fleet.refuse_listing(true);
    let out = fleet.op(&launch_on("KEN-3", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-unjudged",
        "{}",
        stderr(&out)
    );
    assert_eq!(fleet.fleet()["lanes"].as_array().unwrap().len(), 1);
    fleet.refuse_listing(false);

    let mut unlisted = launch_on("KEN-3", fleet.state_dir());
    unlisted["account"] = json!("/home/me/.other");
    let out = fleet.op(&unlisted);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(fleet.lane("KEN-3")["account"], "/home/me/.other");
}

/// An account its word refuses, reserved or retired from its day, may have
/// room, so the refusal is the word's own key, never `account-walled` with
/// the wall's figures: its line naming the word, or the day and who stated
/// it, with no window's figure; nothing is written.
#[test]
fn a_named_reserved_or_retired_account_is_refused_by_its_word_and_writes_nothing() {
    let mut fleet = Fleet::new(4);
    fleet.init_fleet();
    let now = epoch_now();
    let mut reserved = listing_row(0, now);
    reserved["reserved"] = json!(1);
    fleet.plant_listing(&[reserved]);
    let out = fleet.op(&launch_on("KEN-1", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-reserved",
        "{}",
        stderr(&out)
    );
    let fields = refusal_fields(&answer);
    assert_eq!(fields["account"], ACCOUNT);
    assert_eq!(fields["model"], "opus");
    assert_eq!(fields["word"], "reserve");
    assert!(
        !fields.contains_key("pct") && !fields.contains_key("bucket"),
        "no window's figure in a word's refusal: {fields:?}"
    );
    assert!(
        stderr(&out).starts_with(&format!(
            "orch-runtime: account-reserved item=KEN-1 account={ACCOUNT} model=opus word=reserve"
        )),
        "{}",
        stderr(&out)
    );
    let mut ended = listing_row(0, now);
    ended["plan_ends"] = json!("2000-01-01");
    fleet.plant_listing(&[ended]);
    let out = fleet.op(&launch_on("KEN-1", fleet.state_dir()));
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-retired",
        "{}",
        stderr(&out)
    );
    let fields = refusal_fields(&answer);
    assert_eq!(fields["ends"], "2000-01-01");
    assert_eq!(fields["source"], "provider");
    assert!(
        !fields.contains_key("pct") && !fields.contains_key("bucket"),
        "{fields:?}"
    );
    assert!(
        fleet.fleet()["lanes"]
            .as_array()
            .is_none_or(|lanes| lanes.is_empty()),
        "a refused launch writes no record: {}",
        fleet.fleet()
    );
}

/// The shell launcher reads `account-unmeasured` with
/// `status=provider-unmeasured` as `lane-provider-unmeasured`.
#[test]
fn a_pi_launch_on_a_provider_nothing_bills_is_refused_as_provider_unmeasured() {
    let mut fleet = Fleet::new(4);
    fleet.init_fleet();
    fleet.plant_listing(&[listing_row(0, epoch_now())]);
    let mut request = launch_on("KEN-1", fleet.state_dir());
    request["harness"] = json!("pi");
    request["model"] = json!("sonnet:high");
    let out = fleet.op(&request);
    let answer = reply(&out);
    assert_eq!(
        answer["refusal"]["key"],
        "account-unmeasured",
        "{}",
        stderr(&out)
    );
    let fields = refusal_fields(&answer);
    assert_eq!(fields["status"], "provider-unmeasured");
    assert_eq!(fields["detail"], "none");
    assert!(
        stderr(&out).starts_with(&format!(
            "orch-runtime: account-unmeasured item=KEN-1 account={ACCOUNT} model=sonnet:high status=provider-unmeasured detail=none"
        )),
        "{}",
        stderr(&out)
    );
    assert!(
        fleet.fleet()["lanes"]
            .as_array()
            .is_none_or(|lanes| lanes.is_empty()),
        "a refused launch writes no record: {}",
        fleet.fleet()
    );
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

/// Through the executable: a lane whose recorded harness is a
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
            ["setting", "ORCH_OVERSEER_LANES"]
        ])
    );
    assert!(
        stderr(&out).starts_with(
            "orch-runtime: cap-reached occupancy=1 cap=1 lanes=1 setting=ORCH_OVERSEER_LANES"
        ),
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

/// Through the executable: a bare close on a lane whose harness
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
    // The item's own files beside the fleet record: the close on the
    // tracker's verdict is the item's close-out too.
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-A.json");
    let status_file = plant(fleet.state_dir(), "lane-status-KEN-A.md");
    let answer = reply(&fleet.op(&terminal_close("KEN-A")));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert!(!live(harness.pid()), "the recorded harness ended");
    let lane = fleet.lane("KEN-A");
    assert_eq!(lane["status"], "done");
    assert!(
        std::fs::symlink_metadata(&item_state).is_err(),
        "the item's state left with the terminal close"
    );
    assert!(
        std::fs::symlink_metadata(&status_file).is_err(),
        "the lane status file left with the terminal close"
    );
    let archives = std::env::temp_dir()
        .join("isolated-home/.fleet/archive")
        .join(fleet.state_dir().file_name().unwrap())
        .join("oversee");
    assert!(
        std::fs::read_dir(&archives).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("close-KEN-A-")
        }),
        "the close-out's archive under {}",
        archives.display()
    );
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

/// Through the executable: the `no-landing` close with `interrupt` asks the
/// mailbox before anything else and refuses `ask-unanswered` while one
/// stands, the harness still live and the lane running.
#[test]
fn an_interrupting_close_still_refuses_an_unanswered_ask() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let harness = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-A",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let ask = r#"{"id":"1769700000-9-31","kind":"ask","text":"which base"}"#;
    let asking = Fleet {
        env: vec![("LANE_MAIL_ASKS".to_owned(), ask.to_owned())],
        ..fleet
    };
    let close = json!({
        "op": "close-owned-resources",
        "item": "KEN-A",
        "no_landing": {"reason": "model-switch", "source": "model-recovery", "interrupt": true},
    });
    let answer = reply(&asking.op(&close));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["cause"], "ask-unanswered");
    assert_eq!(report["intent"]["observation"]["ask"], "1769700000-9-31");
    assert!(live(harness.pid()), "an unanswered ask stops nothing");
    assert_eq!(asking.lane("KEN-A")["status"], "running");
}

/// The shipped mailbox reader under a cleared environment rooted at `root`,
/// a git checkout of its own, so an ask a row plants is the reader's own
/// write.
fn shipped_mail(root: &Path) -> PathBuf {
    let path = root.join("shipped-lane-mail");
    let actual = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap();
    write_executable(
        &path,
        format!(
            "#!/bin/sh\nexec env -i HOME='{}' PATH='{}' LANG=C.UTF-8 TMPDIR='{}' GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES='{}' '{}' \"$@\"\n",
            root.join("home").display(),
            tool_path(&[]),
            std::env::temp_dir().display(),
            ceilings(root.parent().unwrap()).to_string_lossy(),
            actual.display()
        ),
    );
    for args in [
        vec!["init", "--quiet"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    path
}

/// Through the executable and the shipped mailbox: an ask the lane's own
/// mailbox holds, written by that mailbox, refuses the interrupting close
/// `ask-unanswered` naming the id the mailbox lists, the harness live and
/// the lane running.
#[test]
fn a_close_reads_the_lanes_open_ask_through_the_shipped_mailbox() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let root = fleet.state_dir().canonicalize().unwrap();
    let mail = shipped_mail(&root);
    let question = root.join("question.txt");
    std::fs::write(&question, "Which base?").unwrap();
    let asked = program(&mail)
        .current_dir(&root)
        .args(["ask", "--item", "KEN-A", "--file"])
        .arg(&question)
        .output()
        .unwrap();
    assert!(asked.status.success(), "{}", stderr(&asked));
    let listed = program(&mail)
        .current_dir(&root)
        .args(["pending", "--item", "KEN-A", "--root"])
        .arg(&root)
        .output()
        .unwrap();
    assert!(listed.status.success(), "{}", stderr(&listed));
    let rows: Vec<Value> = String::from_utf8_lossy(&listed.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let ask = rows
        .iter()
        .find(|r| r["kind"] == "ask")
        .and_then(|r| r["id"].as_str())
        .unwrap_or_else(|| panic!("the mailbox lists no ask: {rows:?}"))
        .to_owned();
    let harness = Owned::sleep();
    fleet.write_lanes(vec![record("KEN-A", "running", Some(&harness), &root)]);
    let asking = Fleet {
        env: vec![("LANE_MAIL_CLI".to_owned(), mail.display().to_string())],
        ..fleet
    };
    let close = json!({
        "op": "close-owned-resources",
        "item": "KEN-A",
        "no_landing": {"reason": "model-switch", "source": "model-recovery", "interrupt": true},
    });
    let answer = reply(&asking.op(&close));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["effect"]["report"];
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["cause"], "ask-unanswered");
    assert_eq!(report["intent"]["observation"]["ask"], json!(ask));
    assert!(live(harness.pid()), "an unanswered ask stops nothing");
    assert_eq!(asking.lane("KEN-A")["status"], "running");
}

/// The lane record the shell suites plant drifting from what the real
/// `launch-lane` writes: `tests/lane_model_recovery.sh` and the hook's
/// `lane-mail-model-switch.test.sh` read the permission words off the
/// record the fixture holds, and `tests/lane-state.sh` and
/// `tests/lane_close.sh` read its launch identity in the start's form, so
/// the fixture is this launch's record, its root and its process, pane and
/// clock values as placeholders and the start's form (`ticks:`) kept before
/// its placeholder.
#[test]
fn the_recovery_suites_planted_record_is_the_real_launch_lanes() {
    const PERMISSION: &str = "--permission-mode dontAsk";
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let mut request = launch_request("KEN-1", &work);
    request["model"] = json!("claude-fable-5-1");
    request["effort"] = json!("high");
    request["permission"] = json!(PERMISSION);
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let mut record = runner.fleet()["lanes"][0].clone();
    for (field, placeholder) in [
        ("pane", "@PANE@"),
        ("server", "@SERVER@"),
        ("server_start", "@SERVER_START@"),
        ("pid", "@PID@"),
    ] {
        if record["launch"].get(field).is_some() {
            record["launch"][field] = json!(placeholder);
        }
    }
    if let Some(start) = record["launch"]["start"].as_str() {
        let form = start.split_once(':').map_or("", |(form, _)| form);
        record["launch"]["start"] = json!(format!("{form}:@START@"));
    }
    for (field, placeholder) in [
        ("session_id", "@SESSION_ID@"),
        ("launched_at", "@LAUNCHED_AT@"),
        ("running_at", "@RUNNING_AT@"),
        ("session_since", "@SESSION_SINCE@"),
    ] {
        assert!(record[field].is_string(), "{field} on the record: {record}");
        record[field] = json!(placeholder);
    }
    let text = serde_json::to_string_pretty(&record)
        .unwrap()
        .replace(&work.display().to_string(), "@ROOT@");
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/fixtures/launch-lane/claude-dontask.json");
    let planted: Value = serde_json::from_str(&std::fs::read_to_string(fixture).unwrap()).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        planted,
        "the fixture is not this launch's record:\n{text}"
    );
    assert_eq!(planted["permission"], json!(PERMISSION), "{planted}");
}

/// Through the executable: each is refused `permission-unrepresentable`
/// naming the harness and the word, and nothing is written.
#[test]
fn a_permission_word_the_launch_line_cannot_carry_is_refused_before_any_record() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let before = fleet.fleet();
    for word in ["--permission-mode unknown", "--permission-mode"] {
        let mut request = launch("KEN-A", fleet.state_dir());
        request["permission"] = json!(word);
        let answer = reply(&fleet.op(&request));
        assert_eq!(
            answer["refusal"]["key"], "permission-unrepresentable",
            "{word}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(
            (fields["harness"].as_str(), fields["permission"].as_str()),
            ("claude", word)
        );
        assert_eq!(fleet.fleet(), before, "{word}: a refusal writes nothing");
    }
    // A launch setting outside its form is refused by key and value before
    // any record: the bounds, posture and programs the launch's effect
    // reads, and the cap its admission judges; so is a lane close's grace
    // before the close reads anything; `state path` answers under each.
    for (key, value, request) in [
        ("ORCH_TMUX_VERIFY_SECS", "0", "launch"),
        ("ORCH_LANE_CLOSE_SECS", "x", "launch"),
        ("ORCH_LAUNCH_PERMISSION", "yes", "launch"),
        ("ORCH_HARNESS_BINARIES", "claude", "launch"),
        ("ORCH_OVERSEER_LANES", "03", "launch"),
        ("ORCH_OVERSEER_CLOUD_LANES", "0", "cloud"),
        ("ORCH_LANE_CLOSE_SECS", "0", "close"),
    ] {
        let mut fleet = Fleet::new(4);
        fleet.init_fleet();
        fleet.env.push((key.into(), value.into()));
        let before = fleet.fleet();
        let request = match request {
            "close" => json!({"op": "close-lane", "item": "KEN-A"}),
            kind => {
                let mut request = launch("KEN-A", fleet.state_dir());
                if kind == "cloud" {
                    request["host"] = json!("claude-cloud");
                    request["account"] = json!(fleet.state_dir().display().to_string());
                    request["model"] = json!("opus");
                    request["effort"] = json!("high");
                }
                request
            }
        };
        let answer = reply(&fleet.op(&request));
        assert_eq!(
            answer["refusal"]["key"], "setting-invalid",
            "{key}: {answer}"
        );
        assert_eq!(
            answer["refusal"]["fields"],
            json!([["key", key], ["value", value]]),
            "{key}"
        );
        assert_eq!(fleet.fleet(), before, "{key}: a refusal writes nothing");
        let control = fleet.run(&["state", "path", "--fleet"]);
        assert!(control.status.success(), "{key}: {}", stderr(&control));
    }
}

/// orch starts, records and watches lanes and controllers on the four
/// harnesses alone. Through the executable, every verb that takes a
/// caller's harness word refuses OpenCode's `harness-unknown` naming it and
/// the four, and writes nothing: a lane's and a controller's launch, a
/// succession, a controller record's heal, the account verbs and the marks;
/// a preference entry naming it is refused naming the entry, the harness
/// and the four.
#[test]
fn every_verb_taking_a_harness_refuses_one_outside_the_four_by_its_name_and_writes_nothing() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let mut doc = fleet.fleet();
    doc["overseer"] = json!({"server": "11", "pane": "%1", "server_start": null});
    std::fs::write(fleet.fleet_path(), doc.to_string()).unwrap();
    let before = fleet.fleet();
    let mut launch_lane = launch("KEN-A", fleet.state_dir());
    launch_lane["harness"] = json!("opencode");
    let opencode = json!({"harness": "opencode"});
    let requests = [
        ("launch-lane", launch_lane),
        (
            "start-controller",
            json!({"op": "start-controller", "controller": opencode}),
        ),
        (
            "request-transfer",
            json!({"op": "request-transfer", "cause": "dead", "expected": {}, "successor": opencode}),
        ),
    ];
    let mut cases: Vec<(&str, Vec<String>)> = requests
        .iter()
        .map(|(name, request)| {
            let path = fleet.state_dir().join(format!("{name}.json"));
            std::fs::write(&path, request.to_string()).unwrap();
            let args =
                ["op", "--fleet", "--request", &path.display().to_string()].map(str::to_owned);
            (*name, args.to_vec())
        })
        .collect();
    let verbs: [(&str, &[&str]); 6] = [
        (
            "state heal",
            &[
                "state",
                "heal",
                "--fleet",
                "--server",
                "11",
                "--pane",
                "%1",
                "--start",
                "5",
                "--harness",
                "opencode",
                "--session",
                "s1",
            ],
        ),
        (
            "accounts billed",
            &[
                "accounts",
                "billed",
                "--harness",
                "opencode",
                "--native-model",
                "m",
            ],
        ),
        (
            "accounts pick",
            &[
                "accounts",
                "pick",
                "--fleet",
                "--harness",
                "opencode",
                "--native-model",
                "m",
            ],
        ),
        (
            "accounts walk source",
            &[
                "accounts",
                "walk",
                "--fleet",
                "--source-harness",
                "opencode",
            ],
        ),
        (
            "accounts walk caller",
            &[
                "accounts",
                "walk",
                "--fleet",
                "--caller-harness",
                "opencode",
            ],
        ),
        ("marks", &["marks", "--fleet", "--harness", "opencode"]),
    ];
    cases.extend(
        verbs
            .iter()
            .map(|(name, args)| (*name, args.iter().map(|a| (*a).to_owned()).collect())),
    );
    for (name, args) in &cases {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let out = fleet.run(&args);
        assert_eq!(out.status.code(), Some(1), "{name}: {}", stderr(&out));
        let answer = reply(&out);
        assert_eq!(
            answer["refusal"]["key"], "harness-unknown",
            "{name}: {answer}"
        );
        assert_eq!(
            answer["refusal"]["fields"],
            json!([
                ["harness", "opencode"],
                ["supported", "claude,codex,copilot,pi"]
            ]),
            "{name}"
        );
        assert_eq!(fleet.fleet(), before, "{name}: a refusal writes nothing");
    }
    let mut preferring = Fleet::new(4);
    preferring.init_fleet();
    preferring
        .env
        .push(("ORCH_LANE_PREFERENCE".into(), "opencode:m:high".into()));
    let answer = reply(&preferring.run(&["accounts", "walk", "--fleet"]));
    assert_eq!(answer["refusal"]["key"], "preference-invalid", "{answer}");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([
            ["entry", "opencode:m:high"],
            ["harness", "opencode"],
            ["supported", "claude,codex,copilot,pi"]
        ])
    );
}

/// A launch on a named account that names no model runs the harness's
/// default model, which spends an account window the judge never read.
/// Through the real `launch-lane`: a launch naming an account and no model,
/// or an empty one, on each harness, and a relaunch over a stopped record
/// alike, is refused `launch-model-missing` naming the harness, the account
/// and the line's model spellings, before any record; a launch naming no
/// account is not judged here.
#[test]
fn a_launch_on_an_account_naming_no_model_is_refused_before_any_record() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let account = fleet.state_dir().display().to_string();
    let rows: [(&str, Option<&str>, &str); 5] = [
        ("claude", None, "--model"),
        ("claude", Some(""), "--model"),
        ("codex", None, "-m,--model"),
        ("copilot", None, "--model"),
        ("pi", None, "--model"),
    ];
    for relaunch in [false, true] {
        if relaunch {
            fleet.write_lanes(vec![record("KEN-M", "stopped", None, fleet.state_dir())]);
        }
        let before = fleet.fleet();
        for (harness, model, spellings) in rows {
            let mut request = launch("KEN-M", fleet.state_dir());
            request["harness"] = json!(harness);
            request["account"] = json!(account);
            request["effort"] = json!("high");
            if let Some(model) = model {
                request["model"] = json!(model);
            }
            let answer = reply(&fleet.op(&request));
            assert_eq!(
                answer["refusal"]["key"], "launch-model-missing",
                "{harness} {model:?} relaunch={relaunch}: {answer}"
            );
            let fields = refusal_fields(&answer);
            assert_eq!(
                (
                    fields["harness"].as_str(),
                    fields["lane"].as_str(),
                    fields["spellings"].as_str()
                ),
                (harness, account.as_str(), spellings),
                "{harness}"
            );
            assert_eq!(fleet.fleet(), before, "{harness}: a refusal writes nothing");
        }
    }
    let mut unnamed = launch("KEN-N", fleet.state_dir());
    unnamed["harness"] = json!("codex");
    let answer = reply(&fleet.op(&unnamed));
    assert_ne!(
        answer["refusal"]["key"], "launch-model-missing",
        "a launch naming no account is not judged: {answer}"
    );
}

/// Through the real `launch-lane`: a launch naming an account and a model
/// but no effort is refused `launch-effort-missing` with the line's effort
/// spellings, before any record; a Pi model carrying its level
/// (`provider/id:level`) names the effort.
#[test]
fn a_launch_on_an_account_naming_no_effort_is_refused_before_any_record() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let account = fleet.state_dir().display().to_string();
    let before = fleet.fleet();
    for (harness, model, spellings) in [
        ("claude", "claude-fable-5-1", "--effort"),
        ("codex", "gpt-6.1-sol", "model_reasoning_effort="),
        ("copilot", "claude-opus-5.5", "--reasoning-effort"),
        ("pi", "github-copilot/claude-opus-5.5", "--thinking"),
    ] {
        let mut request = launch("KEN-E", fleet.state_dir());
        request["harness"] = json!(harness);
        request["account"] = json!(account);
        request["model"] = json!(model);
        let answer = reply(&fleet.op(&request));
        assert_eq!(
            answer["refusal"]["key"], "launch-effort-missing",
            "{harness}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(
            (
                fields["harness"].as_str(),
                fields["lane"].as_str(),
                fields["spellings"].as_str()
            ),
            (harness, account.as_str(), spellings)
        );
        assert_eq!(fleet.fleet(), before, "{harness}: a refusal writes nothing");
    }
    let mut leveled = launch("KEN-E", fleet.state_dir());
    leveled["harness"] = json!("pi");
    leveled["account"] = json!(account);
    leveled["model"] = json!("github-copilot/claude-opus-5.5:high");
    let answer = reply(&fleet.op(&leveled));
    assert_ne!(
        answer["refusal"]["key"], "launch-effort-missing",
        "the level on Pi's model word names the effort: {answer}"
    );
}

/// Through the executable: a `no-landing` disposition on a lane
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

/// A recorded identity live under another
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
    // The same identity with no pane recorded: the second
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

/// A launch whose window opened but whose line could not
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

/// A lane whose recorded harness is gone and
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

/// On a lane close: the recorded harness is stopped
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

/// A pane recorded with no server
/// (the launch object admits a null server) is a handle
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

/// The fleet launch lock as the test holds it: `flock(1)` on
/// `<fleet>.launch.lock`, the lock the admission takes around its count,
/// kept by a child the test owns until the child is ended (`-o`: the held
/// descriptor is the holder's alone, so ending the holder releases the lock).
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
        command.env("PATH", support::tool_path(&[tools]));
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

/// Two runtime contenders at cap minus one: both reach
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

/// Through the real `launch-lane` at a lane cap of one and a cloud cap of
/// one: a running cloud session refuses the next session `cap-reached`
/// naming the cloud setting and writes nothing, and charges no lane slot,
/// so a lane is admitted beside it; a live lane at the lane cap charges no
/// cloud slot, so a session is admitted beside it; `over_cap` admits a
/// session past the cloud cap and is recorded; with no cloud setting the
/// tenth running session fills the cap; and a stopped session's standing
/// reservation holds its slot until it lapses.
#[test]
fn a_cloud_session_is_bounded_by_the_cloud_cap_and_charges_no_lane_slot() {
    let mut fleet = Fleet::new(1);
    fleet
        .env
        .push(("ORCH_OVERSEER_CLOUD_LANES".into(), "1".into()));
    fleet.init_fleet();
    let state_dir = fleet.state_dir().to_path_buf();
    let session = |item: &str| {
        json!({
            "item": item,
            "harness": "claude",
            "host": "claude-cloud",
            "kind": "claude-cloud",
            "status": "running",
            "session_id": "session_held",
            "mail_root": state_dir.display().to_string(),
            "launch": Value::Null,
        })
    };
    let cloud = |item: &str| {
        let mut request = launch(item, &state_dir);
        request["host"] = json!("claude-cloud");
        request["account"] = json!(state_dir.display().to_string());
        request["model"] = json!("opus");
        request["effort"] = json!("high");
        request
    };
    fleet.write_lanes(vec![session("KEN-C1")]);
    let before = fleet.fleet();
    let refused = reply(&fleet.op(&cloud("KEN-C2")));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["refusal"]["key"], "cap-reached", "{refused}");
    let fields = refusal_fields(&refused);
    assert_eq!(fields["setting"], "ORCH_OVERSEER_CLOUD_LANES", "{refused}");
    assert_eq!(fields["cap"], "1", "{refused}");
    assert_eq!(fleet.fleet(), before, "a refusal writes nothing");
    let admitted = reply(&fleet.op(&launch("KEN-L1", fleet.state_dir())));
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(
        admitted["result"]["persisted"]["report"]["admission"]["occupancy"], 0,
        "the session charges no lane slot: {admitted}"
    );
    let harness = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-L2",
        "running",
        Some(&harness),
        fleet.state_dir(),
    )]);
    let admitted = reply(&fleet.op(&cloud("KEN-C3")));
    assert_eq!(admitted["ok"], true, "{admitted}");
    let admission = &admitted["result"]["persisted"]["report"]["admission"];
    assert_eq!(
        (admission["cap"].as_u64(), admission["occupancy"].as_u64()),
        (Some(1), Some(0)),
        "the lane charges no cloud slot: {admitted}"
    );
    assert_eq!(fleet.lane("KEN-C3")["kind"], "claude-cloud");
    fleet.write_lanes(vec![session("KEN-C1")]);
    let mut over = cloud("KEN-C4");
    over["over_cap"] = json!("cloud-cap");
    let admitted = reply(&fleet.op(&over));
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(fleet.lane("KEN-C4")["over_cap"], "cloud-cap");
    fleet.env.clear();
    let ten: Vec<Value> = (1..=10).map(|n| session(&format!("KEN-D{n}"))).collect();
    fleet.write_lanes(ten[..9].to_vec());
    let admitted = reply(&fleet.op(&cloud("KEN-C5")));
    assert_eq!(
        admitted["ok"], true,
        "the ninth session leaves room: {admitted}"
    );
    fleet.write_lanes(ten);
    let refused = reply(&fleet.op(&cloud("KEN-C6")));
    assert_eq!(refused["refusal"]["key"], "cap-reached", "{refused}");
    assert_eq!(refusal_fields(&refused)["cap"], "10", "{refused}");
    fleet
        .env
        .push(("ORCH_OVERSEER_CLOUD_LANES".into(), "1".into()));
    let mut reserved = session("KEN-C1");
    reserved["status"] = json!("stopped");
    reserved["reservation"] =
        json!({"reason": "resume", "until": clock::iso_utc(epoch_now() + 3600)});
    fleet.write_lanes(vec![reserved.clone()]);
    let refused = reply(&fleet.op(&cloud("KEN-C7")));
    assert_eq!(
        refused["refusal"]["key"], "cap-reached",
        "a standing reservation charges the cloud cap: {refused}"
    );
    reserved["reservation"]["until"] = json!(clock::iso_utc(epoch_now() - 1));
    fleet.write_lanes(vec![reserved]);
    let admitted = reply(&fleet.op(&cloud("KEN-C8")));
    assert_eq!(
        admitted["ok"], true,
        "a lapsed reservation holds nothing: {admitted}"
    );
}

/// The paths an archive holds, as `tar` lists them, each relative to `/`.
fn archived(archive: &Path) -> Vec<String> {
    let out = program("tar")
        .args(["-tzf", &archive.display().to_string()])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect()
}

fn relative(path: &Path) -> String {
    std::fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .strip_prefix("/")
        .unwrap()
        .display()
        .to_string()
}

fn plant(dir: &Path, rel: &str) -> PathBuf {
    let path = dir.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "x\n").unwrap();
    path
}

fn age(path: &Path, secs: u64) {
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let at = UNIX_EPOCH + Duration::from_secs(now - secs);
    std::fs::File::open(path).unwrap().set_modified(at).unwrap();
}

/// `state remove` through the executable on a directory with no fleet
/// state: the item's state, status file, handoff and run directory leave,
/// the mailbox and the record's lock stay, the siblings stand, the archive
/// the reply names holds every path that left beside the mailbox and the
/// `--archive` path, and the directory's own retention ran, since no watch
/// runs it there, taking another item's expired record.
#[test]
fn state_remove_takes_the_items_files_after_their_archive_and_leaves_its_siblings() {
    let fleet = Fleet::new(1);
    let dir = fleet.state_dir();
    let leaves = [
        plant(dir, "workflow-state-KEN-A.json"),
        plant(dir, "handoffs/KEN-A-handoff.md"),
        plant(dir, "KEN-A.run/stdout.log"),
        plant(dir, "lane-status-KEN-A.md"),
    ];
    let stays = [
        plant(dir, "workflow-state-KEN-A.json.lock"),
        plant(dir, "lane-mail/KEN-A/to-lane.jsonl"),
        plant(dir, "workflow-state-KEN-AB.json"),
        plant(dir, "audit-KEN-B.json"),
    ];
    let extra = plant(dir, "extra/tmp/dev-return-KEN-A-1-1.json");
    let expired = dir.join("workflow-state-KEN-Z.json");
    std::fs::write(&expired, "{}\n").unwrap();
    age(&expired, 10 * 86_400);
    let out = fleet.run(&[
        "state",
        "remove",
        "--item",
        "KEN-A",
        "--archive",
        &dir.join("extra").join("tmp").display().to_string(),
    ]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer}");
    for path in &leaves {
        assert!(
            std::fs::symlink_metadata(path).is_err(),
            "{} left",
            path.display()
        );
    }
    for path in &stays {
        assert!(
            std::fs::symlink_metadata(path).is_ok(),
            "{} stands",
            path.display()
        );
    }
    let mut removed: Vec<String> = answer["result"]["removed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| relative(Path::new(p.as_str().unwrap())))
        .collect();
    removed.sort();
    let mut want: Vec<String> = [
        "KEN-A.run",
        "handoffs/KEN-A-handoff.md",
        "lane-status-KEN-A.md",
        "workflow-state-KEN-A.json",
    ]
    .iter()
    .map(|rel| format!("{}/{rel}", relative(dir)))
    .collect();
    want.sort();
    assert_eq!(removed, want);
    let kept = PathBuf::from(answer["result"]["kept"].as_str().expect("the archive"));
    let listed = archived(&kept);
    for rel in [
        "workflow-state-KEN-A.json",
        "handoffs/KEN-A-handoff.md",
        "KEN-A.run/stdout.log",
        "lane-status-KEN-A.md",
        "lane-mail/KEN-A/to-lane.jsonl",
    ] {
        let path = format!("{}/{rel}", relative(dir));
        assert!(listed.contains(&path), "{path} archived: {listed:?}");
    }
    assert!(
        listed.contains(&relative(&extra)),
        "the --archive path's file archived: {listed:?}"
    );
    assert!(
        !listed.iter().any(|p| p.ends_with("audit-KEN-B.json")),
        "a sibling's file is not archived: {listed:?}"
    );
    assert!(
        std::fs::symlink_metadata(&expired).is_err(),
        "the expired record left with the directory's retention"
    );
    let pruned: Vec<String> = answer["result"]["pruned"]["paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| relative(Path::new(p.as_str().unwrap())))
        .collect();
    assert_eq!(
        pruned,
        vec![format!("{}/workflow-state-KEN-Z.json", relative(dir))]
    );
    assert!(
        std::fs::symlink_metadata(dir.join("extra")).is_ok(),
        "the --archive path is the caller's to remove"
    );
}

/// A run directory whose mode forbids unlinking inside it: the close-out
/// refuses `remove-failed` naming the archive, which holds the file, and
/// the file still stands.
#[test]
fn state_remove_refuses_a_failed_removal_naming_the_archive_that_holds_the_path() {
    let fleet = Fleet::new(1);
    let dir = fleet.state_dir();
    let held = plant(dir, "KEN-A.run/stdout.log");
    let run_dir = held.parent().unwrap().to_path_buf();
    std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    if std::fs::write(run_dir.join("probe"), "x").is_ok() {
        // A process the mode does not bind cannot plant the failure.
        std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        return;
    }
    let out = fleet.run(&["state", "remove", "--item", "KEN-A"]);
    let answer = reply(&out);
    std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["refusal"]["key"], "remove-failed");
    let fields: HashMap<String, String> = answer["refusal"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pair| {
            (
                pair[0].as_str().unwrap().to_owned(),
                pair[1].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    let kept = PathBuf::from(&fields["kept"]);
    assert!(
        archived(&kept).contains(&format!("{}/KEN-A.run/stdout.log", relative(dir))),
        "the archive holds the path that could not be removed"
    );
    assert!(std::fs::symlink_metadata(&held).is_ok(), "the file stands");
}

// --- the close verb ---

/// The provider kendex's rows stand up behind the real `lane-host`
/// dispatcher: the reusable fixture provider, which declares the static ssh
/// kind's line and answers from its `LANE_HOST_STUB_*` environment.
fn provider() -> String {
    orch_package()
        .join("tests/fixtures/lane-host")
        .display()
        .to_string()
}

fn orch_package() -> PathBuf {
    fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf()
}

/// The lane's root on its host.
const REMOTE_ROOT: &str = "/w/ken-1";

impl Fleet {
    /// A fleet whose project is its state directory (outside any
    /// repository), the catalog's orch, mailbox and agent-runtime packages
    /// linked under it, so the runtime runs the real `lane-host` dispatcher
    /// from its scripts directory, over the fixture provider a hosted record
    /// names; the provider's disk an empty directory (every file absent),
    /// its calls logged; the tracker the linear fixture beside the record;
    /// every mailbox call logged.
    fn hosted(cap: u32) -> Fleet {
        let mut fleet = Fleet::new(cap);
        let skills = fleet.state_dir().join(".agents/skills");
        std::fs::create_dir_all(&skills).unwrap();
        let catalog = orch_package().parent().unwrap().to_path_buf();
        for package in ["orch", "mailbox", "agent-runtime"] {
            std::os::unix::fs::symlink(catalog.join(package), skills.join(package)).unwrap();
        }
        let tracker = fleet.state_dir().join("linear.sh");
        std::os::unix::fs::symlink(fixtures().join("linear-fixture/linear.sh"), &tracker).unwrap();
        let disk = fleet.state_dir().join("provider-disk");
        std::fs::create_dir_all(&disk).unwrap();
        let path = |name: &str| fleet.state_dir().join(name).display().to_string();
        fleet.env = vec![
            (
                "OVERSEE_WATCH_TRACKER".to_owned(),
                tracker.display().to_string(),
            ),
            ("LANE_MAIL_LOG".to_owned(), path("mail.log")),
            ("LANE_HOST_STUB_LOG".to_owned(), path("provider.log")),
            ("LANE_HOST_STUB_DIR".to_owned(), disk.display().to_string()),
        ];
        fleet.init_fleet();
        fleet
    }

    /// One more `LANE_HOST_STUB_*` answer for the provider.
    fn answer(&mut self, name: &str, value: &str) {
        self.env
            .push((format!("LANE_HOST_STUB_{name}"), value.to_owned()));
    }

    /// The tracker's answer for `item`: its state type.
    fn plant_tracker(&self, item: &str, state: &str) {
        let reply = json!({"issues bulk-get": {"body": {"issues": {"nodes": [
            {"identifier": item, "state": {"type": state}, "description": "", "children": {"nodes": []}}
        ]}}}});
        std::fs::write(self.state_dir().join("linear.json"), reply.to_string()).unwrap();
    }

    fn lines(&self, name: &str) -> Vec<String> {
        std::fs::read_to_string(self.state_dir().join(name))
            .unwrap_or_default()
            .lines()
            .map(|l| l.trim_end().to_owned())
            .collect()
    }

    /// The provider's calls past the dispatcher, one argv per line (its
    /// capability line answered before the log).
    fn provider_calls(&self) -> Vec<String> {
        self.lines("provider.log")
    }

    fn mail_log(&self) -> Vec<String> {
        self.lines("mail.log")
    }

    fn close(&self, request: Value) -> Value {
        reply(&self.op(&request))
    }
}

/// A running lane on the fixture provider whose merged pull request its
/// record carries, its harness and launch read through the provider alone.
fn hosted_lane(item: &str) -> Value {
    json!({
        "item": item, "window": format!("fleet:{item}"), "harness": "claude",
        "host": provider(), "kind": "ssh", "mail_root": REMOTE_ROOT, "status": "running",
        "launched_at": "2026-01-29T15:00:00Z", "session_since": "2026-01-29T15:00:00Z",
        "cycle": {"pr": 7},
    })
}

/// The provider calls a close of a running KEN-1 no pane carries makes on
/// its item's terminal verdict, the provider's close last.
const RUNNING_CLOSE: [&str; 3] = [
    "status --item KEN-1 --harness claude",
    "stop --item KEN-1 --harness claude",
    "close --item KEN-1 --merged",
];

/// One provider close case: its name, the provider's answers, then the
/// close's word, its observed provider close and the record's status.
type CloseCase = (
    &'static str,
    &'static [(&'static str, &'static str)],
    &'static str,
    &'static str,
    &'static str,
);

/// A hosted lane whose item its tracker ended closes through its provider,
/// the real dispatcher between: the harness stopped through `lane-host
/// stop`, the item's files archived and removed, then the provider's close,
/// `--merged` since the record carries the merge, and the mailbox read under
/// the record's host. The provider's close answer decides the close: an
/// archive line or `closed=absent` closes the lane with that line on the
/// observation, none reads `kept=none`; a refusal, a failure or no answer
/// leaves the lane running and the close unconfirmed with what it read, the
/// item's files already gone.
#[test]
fn a_hosted_close_stops_through_its_provider_and_closes_its_sandbox_after_the_items_files() {
    let rows: [CloseCase; 6] = [
        ("kept", &[], "closed", "kept=/srv/archive/KEN-1", "done"),
        (
            "absent",
            &[("CLOSE_LINE", "closed=absent item=KEN-1")],
            "closed",
            "closed=absent item=KEN-1",
            "done",
        ),
        (
            "silent",
            &[("CLOSE_LINE", "")],
            "closed",
            "kept=none",
            "done",
        ),
        (
            "refused",
            &[("CLOSE_STATUS", "3")],
            "unconfirmed",
            "refused",
            "running",
        ),
        (
            "failed",
            &[("CLOSE_STATUS", "1")],
            "unconfirmed",
            "failed",
            "running",
        ),
        (
            "unanswered",
            &[("CLOSE_STATUS", "137")],
            "unconfirmed",
            "unanswered",
            "running",
        ),
    ];
    for (case, answers, word, host_close, status) in rows {
        let mut fleet = Fleet::hosted(4);
        for (name, value) in answers {
            fleet.answer(name, value);
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "completed");
        let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        assert_eq!(answer["ok"], true, "{case}: {answer}");
        let result = &answer["result"];
        assert_eq!(result["word"], word, "{case}: {result}");
        assert_eq!(
            result["observation"]["host_close"], host_close,
            "{case}: {result}"
        );
        if case == "refused" {
            assert_eq!(result["observation"]["path"], "/srv/clone", "{result}");
        }
        assert_eq!(fleet.lane("KEN-1")["status"], status, "{case}");
        assert!(
            std::fs::symlink_metadata(&item_state).is_err(),
            "{case}: the item's files left before the provider's close"
        );
        assert_eq!(fleet.provider_calls(), RUNNING_CLOSE, "{case}");
        let mail = fleet.mail_log();
        assert!(!mail.is_empty(), "{case}: the mailbox was read");
        let host = provider();
        assert!(
            mail.iter().all(|line| *line
                == format!(
                    "ORCH_LANE_HOST={host} pending --item KEN-1 --root {REMOTE_ROOT} --host"
                )),
            "{case}: every mailbox read ran under the record's host: {mail:?}"
        );
    }
}

/// The item's files leave before the provider's close: a removal that
/// fails holds the close unconfirmed with `item_files` failed, and the
/// provider is never asked to close; the repeat, the files free to go,
/// runs the close again, removes them and closes the sandbox.
#[test]
fn a_hosted_close_whose_items_files_cannot_leave_never_asks_the_provider_to_close() {
    let fleet = Fleet::hosted(4);
    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    fleet.plant_tracker("KEN-1", "completed");
    let held = plant(fleet.state_dir(), "KEN-1.run/stdout.log");
    let run_dir = held.parent().unwrap().to_path_buf();
    std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    if std::fs::write(run_dir.join("probe"), "x").is_ok() {
        // A process the mode does not bind cannot plant the failure.
        std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        return;
    }
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    std::fs::set_permissions(&run_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let result = &answer["result"];
    assert_eq!(result["word"], "unconfirmed", "{answer}");
    assert_eq!(result["observation"]["item_files"], "failed", "{result}");
    assert_eq!(fleet.provider_calls(), RUNNING_CLOSE[..2], "no close asked");
    assert_eq!(fleet.lane("KEN-1")["status"], "running");

    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{answer}");
    assert_eq!(
        result["observation"]["host_close"],
        "kept=/srv/archive/KEN-1",
        "{answer} {:?}",
        fleet.provider_calls()
    );
    assert!(std::fs::symlink_metadata(&held).is_err());
    assert_eq!(fleet.lane("KEN-1")["status"], "done");
}

/// A running hosted lane no pane carries (its kind captures none and none
/// is recorded) is windowless: on an open item with no landed merge the
/// close refuses `pane-missing` and stops nothing; once its merge landed and
/// its worktree left, the lane ends on that ground although its item stays
/// open, its harness stop skipped where the provider answers the worktree
/// removed, the provider's close not `--merged` (the item did not end
/// completed), and the item's files kept.
#[test]
fn a_hosted_lane_whose_merge_landed_and_worktree_left_ends_with_its_items_files_kept() {
    let mut fleet = Fleet::hosted(4);
    fleet.answer("STOP_STATUS", "4");
    fleet.answer(
        "STOP_ERROR",
        "lane-host-ssh: stop-worktree-removed item=KEN-1",
    );
    let mut unmerged = hosted_lane("KEN-1");
    unmerged.as_object_mut().unwrap().remove("cycle");
    fleet.write_lanes(vec![unmerged]);
    fleet.plant_tracker("KEN-1", "started");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["refusal"]["key"], "pane-missing", "{answer}");
    assert!(
        !fleet
            .provider_calls()
            .iter()
            .any(|l| l.starts_with("stop ")),
        "a refused close stops nothing: {:?}",
        fleet.provider_calls()
    );

    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{answer}");
    let notes: Vec<&str> = result["notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(notes.contains(&"item-files-kept cause=open"), "{notes:?}");
    assert!(
        notes.contains(&"stop-skipped item=KEN-1 harness=claude cause=worktree-removed"),
        "{notes:?}"
    );
    assert_eq!(
        fleet.provider_calls().last().map(String::as_str),
        Some("close --item KEN-1")
    );
    assert!(
        std::fs::symlink_metadata(&item_state).is_ok(),
        "the open item's files stay"
    );
    assert_eq!(fleet.lane("KEN-1")["status"], "done");
    let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
    let row = log.iter().rev().find(|r| r["kind"] == "close").unwrap();
    assert_eq!(row["disposition"], "ended", "{row}");
}

/// A merged hosted lane whose worktree stands is done once its item's
/// close-out removed the item's live record from the clone the worktree's
/// `.git` names, both read on the provider's disk through the real
/// dispatcher: with the record standing the close refuses `pane-missing`
/// and stops nothing; with it removed the lane ends on the merge, its
/// harness stopped and the provider's close asked; a record the host cannot
/// read refuses by the close's unreadable or busy key with the provider's
/// cause.
#[test]
fn a_merged_hosted_lane_whose_worktree_stands_is_done_once_its_items_record_left_the_clone() {
    const RECORD: &str = "/w/clone/tmp/workflow-state-KEN-1.json";
    for (case, standing, cat_status, refused) in [
        ("record standing", true, None, Some(("pane-missing", None))),
        (
            "record unreadable",
            true,
            Some("1"),
            Some(("worktree-read-failed", Some("cat exit=1"))),
        ),
        (
            "record read capped",
            true,
            Some("69"),
            Some(("lane-host-busy", Some("cat exit=69"))),
        ),
        ("record removed", false, None, None),
    ] {
        let mut fleet = Fleet::hosted(4);
        let disk = fleet.state_dir().join("provider-disk");
        let worktree = disk.join(REMOTE_ROOT.trim_start_matches('/'));
        std::fs::create_dir_all(&worktree).unwrap();
        std::fs::write(
            worktree.join(".git"),
            "gitdir: /w/clone/.git/worktrees/ken-1\n",
        )
        .unwrap();
        if standing {
            let record = disk.join(RECORD.trim_start_matches('/'));
            std::fs::create_dir_all(record.parent().unwrap()).unwrap();
            std::fs::write(&record, "{}").unwrap();
        }
        if let Some(status) = cat_status {
            fleet.answer("CAT_STATUS", status);
            fleet.answer("CAT_PATH", RECORD);
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "started");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let calls = fleet.provider_calls();
        assert!(
            calls.contains(&format!("cat --item KEN-1 {RECORD}")),
            "{case}: the record is read in the clone: {calls:?}"
        );
        match refused {
            Some((key, cause)) => {
                assert_eq!(answer["refusal"]["key"], key, "{case}: {answer}");
                if let Some(cause) = cause {
                    let fields = refusal_fields(&answer);
                    assert!(fields["cause"].starts_with(cause), "{case}: {fields:?}");
                }
                assert!(
                    !calls.iter().any(|l| l.starts_with("stop ")),
                    "{case}: a refused close stops nothing: {calls:?}"
                );
                assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
            }
            None => {
                assert_eq!(answer["result"]["word"], "closed", "{case}: {answer}");
                assert!(
                    calls.contains(&"stop --item KEN-1 --harness claude".to_owned()),
                    "{case}: {calls:?}"
                );
                assert_eq!(
                    calls.last().map(String::as_str),
                    Some("close --item KEN-1"),
                    "{case}"
                );
                assert_eq!(fleet.lane("KEN-1")["status"], "done", "{case}");
            }
        }
    }
}

/// The close reads a lane where the watch does: on the tmux server the
/// controller record names before the caller's own. A lane whose pane is an
/// idle shell on the controller's server, its harness ended and the
/// caller's server unreachable, is read exited there and closes, its window
/// closed on that server.
#[test]
fn a_close_reads_its_lane_on_the_controllers_recorded_server() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let dir = tempfile::tempdir().unwrap();
    let controller = Server::start(dir.path(), "fleet");
    let pane = controller.open_window("gh-c", fleet.state_dir(), "bash --norc --noprofile");
    let mut harness = Owned::sleep();
    let start = harness.start();
    end(&mut harness);
    let mut state = fleet.fleet();
    state["overseer"] = json!({"server_socket": controller.socket.display().to_string()});
    state["intents"] = json!([]);
    state["lanes"] = json!([{
        "item": "KEN-C", "window": "fleet:gh-c", "harness": "claude",
        "mail_root": fleet.state_dir().display().to_string(), "status": "running",
        "launched_at": "2026-01-29T15:00:00Z", "session_since": "2026-01-29T15:00:00Z",
        "launch": {
            "pane": pane, "server": controller.pid, "server_start": controller.start,
            "pid": harness.pid(), "start": start,
        },
    }]);
    std::fs::write(
        fleet.fleet_path(),
        serde_json::to_string_pretty(&state).unwrap(),
    )
    .unwrap();
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-C"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let intent = &answer["result"]["effect"]["report"]["intent"];
    assert_eq!(intent["close"]["ground"], "exited", "{answer}");
    assert_eq!(fleet.lane("KEN-C")["status"], "done");
    assert!(
        !controller.panes().contains(&pane),
        "the lane's window is closed on the controller's server"
    );
}

/// `keep-sandbox` on a hosted lane its provider reads exited ends the
/// attempt and keeps the sandbox: nothing is stopped or closed through the
/// provider, the record reads stopped with its work kept.
#[test]
fn a_kept_sandbox_retires_the_attempt_and_asks_the_provider_for_no_stop_or_close() {
    let mut fleet = Fleet::hosted(4);
    fleet.answer("HARNESS_STATE", "exited");
    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    fleet.plant_tracker("KEN-1", "started");
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1", "mode": "keep-sandbox"}));
    let result = &answer["result"];
    assert_eq!(result["word"], "stopped", "{answer}");
    assert_eq!(fleet.lane("KEN-1")["status"], "stopped");
    assert_eq!(fleet.lane("KEN-1")["cycle"], json!({"pr": 7}));
    assert_eq!(
        fleet.provider_calls(),
        ["status --item KEN-1 --harness claude"]
    );
    assert!(std::fs::symlink_metadata(&item_state).is_ok());
}

/// A Claude cloud session, which nothing here stops: on its tracker's
/// terminal verdict the close ends the record and the item's files, asks
/// no provider (the dispatcher answers the cloud kind's line itself), says
/// the session kept, and writes the cloud close row.
#[test]
fn a_cloud_close_ends_the_record_keeps_the_session_and_writes_its_close_row() {
    let fleet = Fleet::hosted(4);
    fleet.write_lanes(vec![json!({
        "item": "KEN-1", "harness": "claude", "host": "claude-cloud", "kind": "claude-cloud",
        "repo": "o/r", "account": "/a", "session_id": "S1",
        "mail_root": fleet.state_dir().join("no-such-cloud-root").display().to_string(),
        "status": "running", "launched_at": "2026-01-29T15:00:00Z",
        "session_since": "2026-01-29T15:00:00Z",
    })]);
    fleet.plant_tracker("KEN-1", "completed");
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{answer}");
    assert!(
        result["notes"]
            .as_array()
            .unwrap()
            .contains(&json!("host-kept kind=claude-cloud session=S1")),
        "{result}"
    );
    assert_eq!(fleet.lane("KEN-1")["status"], "done");
    assert!(std::fs::symlink_metadata(&item_state).is_err());
    assert!(fleet.provider_calls().is_empty());
    let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
    assert!(
        log.iter().any(
            |r| r["kind"] == "close" && r["text"] == "cloud lane closed; session=S1 account=/a"
        ),
        "{log:?}"
    );
}

/// The identity a close supplies fills a record that left it empty and
/// never overrides one it recorded: a harness the record contradicts is
/// refused `record-invalid` naming both before any read of the host; an
/// absent tracker and repository are written with the close.
#[test]
fn a_close_fills_an_empty_identity_and_refuses_one_the_record_contradicts() {
    let mut fleet = Fleet::hosted(4);
    fleet.answer("HARNESS_STATE", "exited");
    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    fleet.plant_tracker("KEN-1", "completed");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1", "harness": "codex"}));
    assert_eq!(answer["refusal"]["key"], "record-invalid", "{answer}");
    let fields = refusal_fields(&answer);
    assert_eq!(
        (
            fields["field"].as_str(),
            fields["recorded"].as_str(),
            fields["option"].as_str()
        ),
        ("harness", "claude", "codex")
    );
    assert!(
        fleet.provider_calls().is_empty(),
        "{:?}",
        fleet.provider_calls()
    );

    let answer = fleet.close(json!({
        "op": "close-lane", "item": "KEN-1", "harness": "claude", "tracker": "linear", "repo": "o/r",
    }));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(
        (lane["tracker"].as_str(), lane["repo"].as_str()),
        (Some("linear"), Some("o/r"))
    );
}

/// A weekly-limit banner dated ahead of every clock these rows run under,
/// a clock-only one, and one in a zone no zoneinfo names.
const DATED_WALL: &str = "  ⎿ \u{a0}You've hit your weekly limit · resets Oct 4, 2099, 6pm (UTC)";
const CLOCK_WALL: &str = "  ⎿ \u{a0}You've hit your session limit · resets 6pm (UTC)";
const ZONELESS_WALL: &str = "  ⎿ \u{a0}You've hit your session limit · resets 6pm (Mars/Olympus)";

/// A limit banner stays on a lane's screen after its window resets. A
/// local Claude lane whose pane shows a usage banner below its last turn,
/// its item ended by its tracker, its account measured by the local listing
/// while the caller's own setting names another host (`ORCH_LANE_HOST`): the
/// wall lifts where the account read under the record's host has room and
/// the banner names no reset ahead, and the lane closes, its harness ended;
/// a dated reset ahead, a zone with no zoneinfo, and an account walled each
/// keep the wall, refused `lane-live state=walled` with the reading's
/// `account=` word and the reset, the harness untouched.
#[test]
fn a_stale_wall_over_an_account_with_room_closes_the_lane() {
    type Case = (
        &'static str,
        &'static str,
        u64,
        Option<(&'static str, Option<&'static str>)>,
    );
    let rows: [Case; 5] = [
        (
            "a clock reset on an account with room",
            CLOCK_WALL,
            20,
            None,
        ),
        // The account is walled on its Opus window alone: the record's
        // Sonnet model has room, which the whole account's reading has not.
        ("a model's own window with room", CLOCK_WALL, 20, None),
        (
            "a dated reset ahead",
            DATED_WALL,
            20,
            Some(("room", Some("2099-10-04T18:00:00Z"))),
        ),
        (
            "a zone with no zoneinfo",
            ZONELESS_WALL,
            20,
            Some(("room", Some("unresolved"))),
        ),
        // A walled account's reading names no reset: the banner is read
        // only once the account has room.
        ("an account walled", DATED_WALL, 100, Some(("walled", None))),
    ];
    for (case, banner, weekly, refused) in rows {
        let mut fleet = Fleet::new(4);
        fleet.init_fleet();
        let state = fleet.state_dir().to_path_buf();
        let server = Server::start(&state, "fleet");
        let now = epoch_now();
        let mut row = listing_row(weekly, now);
        let model = case.starts_with("a model's own window");
        if model {
            row["headroom_pct"] = json!(2);
            row["binding_bucket"] = json!("model");
            row["wall"] = json!(98);
            row["verdict"] = json!("walled");
            row["model_buckets"] = json!([
                {"label": "Opus 5", "pct": 98, "resets_at": clock::iso_utc(now + 4 * 86_400)},
                {"label": "Sonnet 5.5", "pct": 10, "resets_at": clock::iso_utc(now + 4 * 86_400)}
            ]);
        }
        let env = plant_accounts(&state, &state, None, &[row], now);
        fleet.env.extend(env);
        let tracker = state.join("linear.sh");
        std::os::unix::fs::symlink(fixtures().join("linear-fixture/linear.sh"), &tracker).unwrap();
        std::fs::write(
            state.join("linear.json"),
            json!({"issues bulk-get": {"body": {"issues": {"nodes": [
                {"identifier": "KEN-W", "state": {"type": "completed"}, "description": "", "children": {"nodes": []}}
            ]}}}})
            .to_string(),
        )
        .unwrap();
        fleet.env.extend([
            (
                "TMUX".to_owned(),
                format!("{},0,0", server.socket.display()),
            ),
            (
                "OVERSEE_WATCH_TRACKER".to_owned(),
                tracker.display().to_string(),
            ),
            ("ORCH_LANE_HOST".to_owned(), "fleet-vm".to_owned()),
        ]);
        let claude = named_sleep(&state, "claude");
        let screen = state.join("screen.txt");
        std::fs::write(
            &screen,
            format!(
                "⏺ Working through the queue.\n{banner}\nRun /usage-credits to raise it\n❯\u{a0}\n"
            ),
        )
        .unwrap();
        let line = format!("cat {}; exec {} 600", screen.display(), claude.display());
        let pane = server.open_window("gh-w", &state, &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, "claude");
        await_drawn(&server, &pane, "limit");
        let account = state.join("home/.aclaude").display().to_string();
        let mut lane = json!({
            "item": "KEN-W", "window": "fleet:gh-w", "harness": "claude", "account": account,
            "mail_root": state.display().to_string(), "status": "running",
            "launched_at": "2026-01-29T15:00:00Z", "session_since": "2026-01-29T15:00:00Z",
            "launch": {"pane": pane, "server": server.pid, "pid": identity.pid, "start": identity.start},
        });
        if model {
            lane["model"] = json!("claude-sonnet-5-5");
        }
        fleet.write_lanes(vec![lane]);
        let answer = reply(&fleet.op(&json!({"op": "close-lane", "item": "KEN-W"})));
        match refused {
            None => {
                assert_eq!(answer["result"]["word"], "closed", "{case}: {answer}");
                assert_eq!(fleet.lane("KEN-W")["status"], "done", "{case}");
                assert!(!live(identity.pid), "{case}: the harness ended");
            }
            Some((word, resets)) => {
                assert_eq!(answer["refusal"]["key"], "lane-live", "{case}: {answer}");
                let fields = refusal_fields(&answer);
                assert_eq!(
                    (
                        fields["state"].as_str(),
                        fields["account"].as_str(),
                        fields.get("resets").map(String::as_str)
                    ),
                    ("walled", word, resets),
                    "{case}"
                );
                assert_eq!(fleet.lane("KEN-W")["status"], "running", "{case}");
                assert!(live(identity.pid), "{case}: the harness untouched");
            }
        }
    }
}

/// A record the released launcher left `preparing` names its background
/// launch job (`prepare.pid`, an `open-terminal` run leading its own
/// process group): the close stops that group by its members' identities
/// and ends the record; a pid that runs anything else is left running.
#[test]
fn a_released_preparing_records_job_is_stopped() {
    for released in [true, false] {
        let fleet = Fleet::new(4);
        fleet.init_fleet();
        let job = if released {
            // A process group the test leads through `setsid`, its leader a
            // command named `open-terminal`.
            let open_terminal = named_sleep(fleet.state_dir(), "open-terminal");
            Owned(
                program("setsid")
                    .arg(&open_terminal)
                    .arg("600")
                    .spawn()
                    .expect("setsid"),
            )
        } else {
            Owned::sleep()
        };
        // `setsid` has made the child its group's leader once it runs the
        // command it exec'd.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while released
            && std::fs::read_to_string(format!("/proc/{}/comm", job.pid()))
                .unwrap_or_default()
                .trim()
                != "open-terminal"
        {
            assert!(
                std::time::Instant::now() < deadline,
                "the job never ran open-terminal"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut record = record("KEN-P", "preparing", None, fleet.state_dir());
        record["prepare"] =
            json!({"pid": job.pid(), "step": "create", "since": "2026-01-29T15:00:00Z"});
        fleet.write_lanes(vec![record]);
        let answer = reply(&fleet.op(&json!({"op": "close-lane", "item": "KEN-P"})));
        assert_eq!(answer["ok"], true, "released={released}: {answer}");
        assert_ne!(
            fleet.lane("KEN-P")["status"],
            "preparing",
            "released={released}: the record ends"
        );
        assert_eq!(
            live(job.pid()),
            !released,
            "released={released}: only an open-terminal job is stopped"
        );
    }
}

/// One close-lane case over a hosted world: the records, the provider's
/// answers, the world's environment, the tracker's state type (`None`
/// plants no answer), and the request.
struct CloseCase2 {
    name: &'static str,
    lanes: Vec<Value>,
    answers: Vec<(&'static str, &'static str)>,
    env: Vec<(&'static str, &'static str)>,
    tracker: Option<&'static str>,
    request: Value,
}

impl CloseCase2 {
    fn new(name: &'static str, lanes: Vec<Value>) -> CloseCase2 {
        CloseCase2 {
            name,
            lanes,
            answers: Vec::new(),
            env: Vec::new(),
            tracker: Some("completed"),
            request: json!({"op": "close-lane", "item": "KEN-1"}),
        }
    }

    fn run(&self) -> (Fleet, Value) {
        let mut fleet = Fleet::hosted(4);
        for (name, value) in &self.answers {
            fleet.answer(name, value);
        }
        for (name, value) in &self.env {
            fleet.env.push(((*name).to_owned(), (*value).to_owned()));
        }
        fleet.write_lanes(self.lanes.clone());
        if let Some(state) = self.tracker {
            fleet.plant_tracker("KEN-1", state);
        }
        plant(fleet.state_dir(), "workflow-state-KEN-1.json");
        let answer = fleet.close(self.request.clone());
        (fleet, answer)
    }
}

/// A hosted record with `field` removed.
fn without(field: &str) -> Value {
    let mut lane = hosted_lane("KEN-1");
    lane.as_object_mut().unwrap().remove(field);
    lane
}

/// A hosted record with `field` set to `value`.
fn with(field: &str, value: Value) -> Value {
    let mut lane = hosted_lane("KEN-1");
    lane[field] = value;
    lane
}

/// Every read the close makes before it acts refuses with its key and the
/// fields that name the read, and nothing past the refusal runs: the record
/// stands as it was and the provider's sandbox is never closed.
#[test]
fn a_close_refuses_each_read_that_does_not_answer_by_its_key() {
    let mut cases = vec![
        (
            CloseCase2::new(
                "two records",
                vec![hosted_lane("KEN-1"), hosted_lane("KEN-1")],
            ),
            "lane-duplicate",
            vec![("count", "2")],
        ),
        (
            CloseCase2::new("no mail root", vec![without("mail_root")]),
            "record-invalid",
            vec![("field", "mail_root")],
        ),
        (
            CloseCase2::new("capabilities unread", vec![hosted_lane("KEN-1")]),
            "host-capabilities-unread",
            vec![],
        ),
        (
            CloseCase2::new("mailbox capped", vec![hosted_lane("KEN-1")]),
            "lane-host-busy",
            vec![("step", "mail-read")],
        ),
        (
            CloseCase2::new("no harness", vec![without("harness")]),
            "harness-unsupported",
            vec![("harness", "unknown")],
        ),
        (
            CloseCase2::new("park without a pull request", vec![hosted_lane("KEN-1")]),
            "request-invalid",
            vec![("field", "park")],
        ),
        (
            CloseCase2::new(
                "park of a preparing record",
                vec![with("status", json!("preparing"))],
            ),
            "record-invalid",
            vec![("field", "status"), ("value", "preparing")],
        ),
        (
            CloseCase2::new("worktree unreadable", vec![hosted_lane("KEN-1")]),
            "worktree-read-failed",
            vec![],
        ),
        (
            CloseCase2::new("worktree read capped", vec![hosted_lane("KEN-1")]),
            "lane-host-busy",
            vec![],
        ),
        (
            CloseCase2::new("provider stop refused", vec![hosted_lane("KEN-1")]),
            "stop-failed",
            vec![("cause", "provider"), ("status", "1")],
        ),
        (
            CloseCase2::new("provider stop unparsed", vec![hosted_lane("KEN-1")]),
            "stop-failed",
            vec![("cause", "answer-unparsed")],
        ),
        (
            CloseCase2::new("provider stop capped", vec![hosted_lane("KEN-1")]),
            "lane-host-busy",
            vec![("step", "stop")],
        ),
        (
            CloseCase2::new("list capped", vec![hosted_lane("KEN-1")]),
            "lane-host-busy",
            vec![("step", "list")],
        ),
        (
            CloseCase2::new("provider status unread", vec![hosted_lane("KEN-1")]),
            "lane-live",
            vec![("state", "unjudged")],
        ),
        (
            CloseCase2::new("if-terminal on an open item", vec![hosted_lane("KEN-1")]),
            "item-open",
            vec![],
        ),
        (
            CloseCase2::new("tracker unread", vec![hosted_lane("KEN-1")]),
            "tracker-read-failed",
            vec![("cause", "read-failed")],
        ),
        (
            CloseCase2::new("no record", vec![hosted_lane("KEN-2")]),
            "lane-missing",
            vec![("item", "KEN-1")],
        ),
        (
            CloseCase2::new("an unanswered ask", vec![hosted_lane("KEN-1")]),
            "ask-unanswered",
            vec![("ask", "a2")],
        ),
        (
            CloseCase2::new("mailbox unread on an open item", vec![hosted_lane("KEN-1")]),
            "mail-read-failed",
            vec![],
        ),
        (
            CloseCase2::new("a stop word with no arm", vec![hosted_lane("KEN-1")]),
            "host-capabilities-unread",
            vec![],
        ),
        (
            CloseCase2::new(
                "an issue key with no tracker",
                vec![with("item", json!("issue-5"))],
            ),
            "tracker-read-failed",
            vec![("tracker", ""), ("source", "derived")],
        ),
    ];
    for (case, _, _) in &mut cases {
        match case.name {
            "capabilities unread" => case.answers.push(("NO_CAPABILITIES", "1")),
            "mailbox capped" => case.env.push(("LANE_MAIL_STATUS", "69")),
            "park without a pull request" => {
                case.request = json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {}}});
            }
            "park of a preparing record" => {
                case.request =
                    json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}});
            }
            "worktree unreadable" => {
                case.answers.push(("CAT_STATUS", "1"));
                case.tracker = Some("started");
            }
            "worktree read capped" => {
                case.answers.push(("CAT_STATUS", "69"));
                case.tracker = Some("started");
            }
            "provider stop refused" => case.answers.push(("STOP_STATUS", "1")),
            "provider stop unparsed" => case.answers.push(("STOP_LINE", "stopped")),
            "provider stop capped" => case.answers.push(("STOP_STATUS", "69")),
            "list capped" => {
                case.env.push(("LANE_MAIL_STATUS", "2"));
                case.answers.push(("LIST_STATUS", "69"));
            }
            "provider status unread" => case.answers.push(("PROBE_STATUS", "1")),
            "if-terminal on an open item" => {
                case.tracker = Some("started");
                case.request = json!({"op": "close-lane", "item": "KEN-1", "mode": "if-terminal"});
            }
            "tracker unread" => {
                case.tracker = None;
                case.request =
                    json!({"op": "close-lane", "item": "KEN-1", "mode": "terminal-state"});
            }
            // The ask behind a row of another kind is the one that holds.
            "an unanswered ask" => case.env.push((
                "LANE_MAIL_ASKS",
                "{\"kind\":\"notice\",\"id\":\"n1\"}\n{\"kind\":\"ask\",\"id\":\"a2\"}",
            )),
            // An open item's merged lane, its worktree gone, ends on the
            // merge, which an unread mailbox holds.
            "mailbox unread on an open item" => {
                case.tracker = Some("started");
                case.env.push(("LANE_MAIL_STATUS", "1"));
            }
            // An `issue-N` key names no tracker: the key is a GitHub
            // lane's and may be a Linear lane's.
            "an issue key with no tracker" => {
                case.request =
                    json!({"op": "close-lane", "item": "issue-5", "mode": "terminal-state"});
            }
            "a stop word with no arm" => case.answers.push((
                "CAPABILITIES",
                "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=teleport\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane",
            )),
            _ => {}
        }
    }
    for (case, key, fields) in cases {
        let (fleet, answer) = case.run();
        assert_eq!(answer["refusal"]["key"], key, "{}: {answer}", case.name);
        let got = refusal_fields(&answer);
        for (field, value) in fields {
            assert_eq!(
                got.get(field).map(String::as_str),
                Some(value),
                "{}: {answer}",
                case.name
            );
        }
        let status = case.lanes[0]["status"].clone();
        for lane in fleet.fleet()["lanes"].as_array().unwrap() {
            assert_eq!(lane["status"], status, "{}: the record stands", case.name);
        }
        assert!(
            !fleet
                .provider_calls()
                .iter()
                .any(|c| c.starts_with("close ")),
            "{}: {:?}",
            case.name,
            fleet.provider_calls()
        );
    }
}

/// The records a close ends by what they already are: a done record
/// answers `closed` and asks nothing; `terminal-state` answers the
/// tracker's word alone; a stopped or parked record's full close on a
/// terminal item is the provider's close alone, with no stop and no
/// mailbox read; a park or a keep of a parked record answers `parked` and
/// changes nothing; a terminal close whose mailbox read fails on a provider
/// that lists no sandbox for the item ends the record with no provider
/// call, `host-absent`.
#[test]
fn a_close_answers_a_record_by_what_it_already_is() {
    let parked = json!({"repo": "o/r", "pr": 7, "head": "h2", "at": "2026-01-29T16:00:00Z"});
    let mut parked_lane = with("status", json!("parked"));
    parked_lane["parked"] = parked.clone();
    let mut rows = vec![
        (
            CloseCase2::new("done", vec![with("status", json!("done"))]),
            "closed",
            "done",
            vec![],
        ),
        (
            CloseCase2::new("terminal state", vec![hosted_lane("KEN-1")]),
            "state",
            "running",
            vec![],
        ),
        (
            CloseCase2::new("stopped", vec![with("status", json!("stopped"))]),
            "closed",
            "done",
            vec!["close --item KEN-1 --merged"],
        ),
        (
            CloseCase2::new("parked", vec![parked_lane.clone()]),
            "closed",
            "done",
            vec!["close --item KEN-1 --merged"],
        ),
        (
            CloseCase2::new("parked, park asked", vec![parked_lane.clone()]),
            "parked",
            "parked",
            vec![],
        ),
        (
            CloseCase2::new("parked, keep asked", vec![parked_lane]),
            "parked",
            "parked",
            vec![],
        ),
        (
            CloseCase2::new("host absent", vec![hosted_lane("KEN-1")]),
            "closed",
            "done",
            vec!["status --item KEN-1 --harness claude", "list"],
        ),
        // An exited harness reads no ask: none can reach the session.
        (
            CloseCase2::new("exited holding an ask", vec![hosted_lane("KEN-1")]),
            "closed",
            "done",
            vec![
                "status --item KEN-1 --harness claude",
                "close --item KEN-1 --merged",
            ],
        ),
    ];
    for (case, _, _, _) in &mut rows {
        match case.name {
            "terminal state" => {
                case.request =
                    json!({"op": "close-lane", "item": "KEN-1", "mode": "terminal-state"});
            }
            "parked, park asked" => {
                case.request =
                    json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}});
            }
            "parked, keep asked" => {
                case.request = json!({"op": "close-lane", "item": "KEN-1", "mode": "keep-sandbox"});
            }
            "host absent" => {
                case.env.push(("LANE_MAIL_STATUS", "2"));
                case.answers
                    .push(("LIST", "lane.example:/srv/other/ken-9\tbusy"));
            }
            "exited holding an ask" => {
                case.answers.push(("HARNESS_STATE", "exited"));
                case.env
                    .push(("LANE_MAIL_ASKS", "{\"kind\":\"ask\",\"id\":\"a1\"}"));
            }
            _ => {}
        }
    }
    for (case, word, status, calls) in rows {
        let (fleet, answer) = case.run();
        assert_eq!(answer["result"]["word"], word, "{}: {answer}", case.name);
        assert_eq!(fleet.lane("KEN-1")["status"], status, "{}", case.name);
        assert_eq!(fleet.provider_calls(), calls, "{}", case.name);
        // The item's files leave with a close that ends the item, the done
        // record's an earlier close's to have taken.
        let item_state = fleet.state_dir().join("workflow-state-KEN-1.json");
        assert_eq!(
            std::fs::symlink_metadata(&item_state).is_ok(),
            !matches!(
                case.name,
                "stopped" | "parked" | "host absent" | "exited holding an ask"
            ),
            "{}: the item's files",
            case.name
        );
        match case.name {
            "terminal state" => assert_eq!(answer["result"]["state"], "completed"),
            "stopped" | "parked" => assert!(
                fleet.mail_log().is_empty(),
                "{}: no mailbox read on a terminal item: {:?}",
                case.name,
                fleet.mail_log()
            ),
            "parked, park asked" | "parked, keep asked" => {
                assert_eq!(fleet.lane("KEN-1")["parked"], parked, "{}", case.name);
            }
            "host absent" => assert!(
                answer["result"]["notes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|n| n.as_str().is_some_and(|n| n.starts_with("host-absent "))),
                "{answer}"
            ),
            _ => {}
        }
    }
}

/// The pull request a park of KEN-1 reads on `o/r` (number 7, or a
/// dependency's), open, armed and clean on the lane's head and branch.
fn park_pull() -> Value {
    json!({"state": "OPEN", "headRefOid": "h2", "headRefName": "ken-1",
        "autoMergeRequest": {"enabledAt": "2026-01-29T16:00:00Z"}, "mergeStateStatus": "CLEAN",
        "isInMergeQueue": false, "mergeQueueEntry": null})
}

impl Fleet {
    /// A hosted world a park of KEN-1 is judged in: the lane's linked
    /// worktree on the provider's disk at head `h2` on `ken-1` with its
    /// clean status file, the `gh` fixture first on `PATH` answering the
    /// pull requests planted, and the reducer fixture, silent on `o/r`.
    fn park_world() -> Fleet {
        let mut fleet = Fleet::hosted(4);
        let bin = fleet.state_dir().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
        std::fs::write(bin.join("gh.json"), "{}").unwrap();
        let reducer = fleet.state_dir().join("pr-watch");
        std::os::unix::fs::symlink(fixtures().join("pr-watch-fixture/pr-watch.sh"), &reducer)
            .unwrap();
        fleet.plant_reducer("o/r", json!({"exit": 0}));
        fleet.env.extend([
            ("PATH".to_owned(), tool_path(&[bin.as_path()])),
            (
                "OVERSEE_WATCH_PR_WATCH".to_owned(),
                reducer.display().to_string(),
            ),
        ]);
        fleet.disk("/w/ken-1/.git", "gitdir: /w/main/.git/worktrees/ken-1\n");
        fleet.disk(
            "/w/main/.git/worktrees/ken-1/HEAD",
            "ref: refs/heads/ken-1\n",
        );
        fleet.disk("/w/main/.git/refs/heads/ken-1", "h2\n");
        fleet.disk(
            "/w/ken-1/tmp/park-status.json",
            r#"{"head":"h2","branch":"ken-1","porcelain":"","at":"2026-01-29T16:00:00Z"}"#,
        );
        fleet.plant_pull(7, park_pull());
        fleet
    }

    /// A file on the provider's disk at `path`; `None` removes it.
    fn disk(&self, path: &str, text: &str) {
        let at = self
            .state_dir()
            .join("provider-disk")
            .join(path.trim_start_matches('/'));
        std::fs::create_dir_all(at.parent().unwrap()).unwrap();
        std::fs::write(at, text).unwrap();
    }

    fn undisk(&self, path: &str) {
        std::fs::remove_file(
            self.state_dir()
                .join("provider-disk")
                .join(path.trim_start_matches('/')),
        )
        .unwrap();
    }

    /// Pull request `number`'s GraphQL answer, the `pullRequest` node.
    fn plant_pull(&self, number: u64, pull: Value) {
        let path = self.state_dir().join("bin/gh.json");
        let mut map: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        map[format!("graphql number={number} cursor=")] =
            json!({"body": {"data": {"repository": {"pullRequest": pull}}}});
        std::fs::write(path, map.to_string()).unwrap();
    }

    fn plant_reducer(&self, repo: &str, reply: Value) {
        let path = self.state_dir().join("pr-watch.json");
        let mut map: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_else(|| json!({}));
        map[repo] = reply;
        std::fs::write(path, map.to_string()).unwrap();
    }
}

/// A park is admitted by its pull request alone, judged before anything is
/// signalled: the provider's sandbox check, the pull request open on the
/// lane's own head and branch (read through the provider's `cat`, loose or
/// packed, else the item's recorded branch), its clean status file bound to
/// that head, the queue or an armed and clean merge, and the reducer silent
/// on it; a dependency park reads the dependency in its own repository,
/// which the fleet must watch, and none of the lane's own checks. Each
/// refusal names its reason and stops nothing; an admitted park stops the
/// harness through the provider, then the sandbox, and records the park.
#[test]
fn a_park_is_judged_before_anything_is_signalled() {
    let park = |pr: Value| json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": pr}});
    type Setup = fn(&mut Fleet);
    let rows: Vec<(&str, Value, Setup, Option<&str>)> = vec![
        ("armed and clean", park(json!({"pr": 7})), |_| {}, None),
        (
            "in the queue",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["autoMergeRequest"] = Value::Null;
                pull["mergeStateStatus"] = json!("BLOCKED");
                pull["isInMergeQueue"] = json!(true);
                f.plant_pull(7, pull);
            },
            None,
        ),
        (
            "packed head",
            park(json!({"pr": 7})),
            |f| {
                f.undisk("/w/main/.git/refs/heads/ken-1");
                f.disk(
                    "/w/main/.git/packed-refs",
                    "# pack-refs\nh2 refs/heads/ken-1\n",
                );
            },
            None,
        ),
        (
            "recorded branch",
            park(json!({"pr": 7})),
            |f| {
                f.undisk("/w/ken-1/.git");
                std::fs::write(
                    f.state_dir().join("workflow-state-KEN-1.json"),
                    r#"{"version":1,"issue_id":"KEN-1","branch":"ken-1"}"#,
                )
                .unwrap();
            },
            None,
        ),
        (
            "no sandbox pair",
            park(json!({"pr": 7})),
            |f| f.answer("SANDBOX_STATUS", "2"),
            Some("provider-unsupported"),
        ),
        (
            "not open",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["state"] = json!("MERGED");
                f.plant_pull(7, pull);
            },
            Some("pr-not-open"),
        ),
        (
            "pull unread",
            park(json!({"pr": 8})),
            |_| {},
            Some("pr-read-failed"),
        ),
        (
            "another branch",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["headRefName"] = json!("ken-1-old");
                f.plant_pull(7, pull);
            },
            Some("pr-branch-mismatch"),
        ),
        (
            "another head",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["headRefOid"] = json!("h1");
                f.plant_pull(7, pull);
            },
            Some("pr-head-mismatch"),
        ),
        (
            "no head nor recorded branch",
            park(json!({"pr": 7})),
            |f| f.undisk("/w/ken-1/.git"),
            Some("worktree-unread"),
        ),
        (
            "no clean status",
            park(json!({"pr": 7})),
            |f| f.undisk("/w/ken-1/tmp/park-status.json"),
            Some("clean-status-unread"),
        ),
        (
            "a dirty status",
            park(json!({"pr": 7})),
            |f| {
                f.disk(
            "/w/ken-1/tmp/park-status.json",
            r#"{"head":"h2","branch":"ken-1","porcelain":" M src/x.rs","at":"2026-01-29T16:00:00Z"}"#,
        )
            },
            Some("clean-status-invalid"),
        ),
        (
            "unarmed",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["autoMergeRequest"] = Value::Null;
                f.plant_pull(7, pull);
            },
            Some("not-armed"),
        ),
        (
            "not clean",
            park(json!({"pr": 7})),
            |f| {
                let mut pull = park_pull();
                pull["mergeStateStatus"] = json!("BLOCKED");
                f.plant_pull(7, pull);
            },
            Some("merge-state"),
        ),
        (
            "the reducer's attention",
            park(json!({"pr": 7})),
            |f| {
                f.plant_reducer(
                    "o/r",
                    json!({"exit": 1, "stdout": "7\topen-thread\tthread\n"}),
                )
            },
            Some("attention"),
        ),
        (
            "no reducer",
            park(json!({"pr": 7})),
            |f| {
                let gone = f.state_dir().join("no-such-reducer").display().to_string();
                f.env.push(("OVERSEE_WATCH_PR_WATCH".to_owned(), gone));
            },
            Some("reducer-missing"),
        ),
        (
            "a dependency unwatched",
            park(json!({"until_pr": 9, "until_repo": "Other/Repo"})),
            |_| {},
            Some("repo-unwatched"),
        ),
        (
            "a watched dependency",
            park(json!({"until_pr": 9, "until_repo": "Other/Repo"})),
            |f| {
                f.env
                    .push(("ORCH_CONNECTED_REPOS".to_owned(), "other/repo".to_owned()));
                let mut pull = park_pull();
                pull["headRefName"] = json!("theirs");
                pull["headRefOid"] = json!("t9");
                pull["autoMergeRequest"] = Value::Null;
                f.plant_pull(9, pull);
            },
            None,
        ),
        // A dependency park reads the lane's own head: the item's recorded
        // branch, which a queue park falls back on, names none.
        (
            "a dependency, no worktree",
            park(json!({"until_pr": 9, "until_repo": "o/r"})),
            |f| {
                f.undisk("/w/ken-1/.git");
                std::fs::write(
                    f.state_dir().join("workflow-state-KEN-1.json"),
                    r#"{"version":1,"issue_id":"KEN-1","branch":"ken-1"}"#,
                )
                .unwrap();
                f.plant_pull(9, park_pull());
            },
            Some("worktree-unread"),
        ),
        (
            "the sandbox stop refused",
            park(json!({"pr": 7})),
            |f| f.answer("SANDBOX_STOP_STATUS", "1"),
            Some("park-failed"),
        ),
    ];
    for (case, request, setup, refused) in rows {
        let mut fleet = Fleet::park_world();
        setup(&mut fleet);
        fleet.write_lanes(vec![with("repo", json!("o/r"))]);
        fleet.plant_tracker("KEN-1", "started");
        let answer = fleet.close(request);
        let calls = fleet.provider_calls();
        let stopped = calls.iter().any(|c| c.starts_with("stop "));
        match refused {
            None => {
                assert_eq!(answer["result"]["word"], "parked", "{case}: {answer}");
                let lane = fleet.lane("KEN-1");
                assert_eq!(lane["status"], "parked", "{case}");
                assert_eq!(lane["parked"]["head"], "h2", "{case}: {lane}");
                if case == "a watched dependency" {
                    assert_eq!(lane["parked"]["until_repo"], "other/repo", "{case}: {lane}");
                }
                let check = calls
                    .iter()
                    .position(|c| c.starts_with("stop-sandbox --check "))
                    .unwrap();
                let stop = calls.iter().position(|c| c.starts_with("stop ")).unwrap();
                let sandbox = calls
                    .iter()
                    .position(|c| c == "stop-sandbox --item KEN-1")
                    .unwrap();
                assert!(check < stop && stop < sandbox, "{case}: {calls:?}");
            }
            Some("park-failed") => {
                assert_eq!(answer["refusal"]["key"], "park-failed", "{case}: {answer}");
                assert_eq!(fleet.lane("KEN-1")["status"], "stopped", "{case}");
            }
            Some(reason) => {
                assert_eq!(answer["refusal"]["key"], "park-refused", "{case}: {answer}");
                assert_eq!(
                    refusal_fields(&answer)["reason"],
                    reason,
                    "{case}: {answer}"
                );
                assert!(!stopped, "{case}: nothing is signalled: {calls:?}");
                assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
            }
        }
    }
}

/// A park of a record already stopped is judged again from the record
/// alone and stops the sandbox with no harness stop; a park of a lane its
/// provider reads exited takes no stop either and still stops the sandbox.
#[test]
fn a_park_stops_the_sandbox_and_records_parked() {
    for (case, status, state) in [
        ("stopped", "stopped", "running"),
        ("exited", "running", "exited"),
    ] {
        let mut fleet = Fleet::park_world();
        fleet.answer("HARNESS_STATE", state);
        fleet.write_lanes(vec![{
            let mut lane = with("repo", json!("o/r"));
            lane["status"] = json!(status);
            lane
        }]);
        fleet.plant_tracker("KEN-1", "started");
        let answer =
            fleet.close(json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}}));
        assert_eq!(answer["result"]["word"], "parked", "{case}: {answer}");
        assert_eq!(fleet.lane("KEN-1")["status"], "parked", "{case}");
        let calls = fleet.provider_calls();
        assert!(
            !calls.iter().any(|c| c.starts_with("stop --")),
            "{case}: {calls:?}"
        );
        assert!(
            calls.iter().any(|c| c == "stop-sandbox --item KEN-1"),
            "{case}: {calls:?}"
        );
    }
}

/// The ssh kind's line for a provider that captures its own pane.
const VERB_PANE_LINE: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb";

impl Fleet {
    /// A hosted fleet whose provider captures its own pane, drawn as
    /// `screen`, and reports the harness running through a status file a
    /// stop or a sent text may end.
    fn verb_pane(screen: &str) -> Fleet {
        let mut fleet = Fleet::hosted(4);
        let capture = fleet.state_dir().join("provider-screen");
        std::fs::write(&capture, screen).unwrap();
        let state = fleet.state_dir().join("provider-harness-state");
        std::fs::write(&state, "running\n").unwrap();
        fleet.answer("CAPABILITIES", VERB_PANE_LINE);
        fleet.answer("CAPTURE_FILE", &capture.display().to_string());
        fleet.answer("HARNESS_STATE_FILE", &state.display().to_string());
        fleet.answer(
            "SENT_FILE",
            &fleet
                .state_dir()
                .join("provider-sent")
                .display()
                .to_string(),
        );
        fleet.answer(
            "SENT_KEY_FILE",
            &fleet
                .state_dir()
                .join("provider-keys")
                .display()
                .to_string(),
        );
        fleet
            .env
            .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
        fleet
    }
}

/// After the provider's stop the lane must read exited before the close
/// goes on: a provider-pane lane at its composer on a terminal item is
/// stopped, then read through the provider's status until it reads exited
/// within `ORCH_LANE_CLOSE_SECS`, and closes; one the stop leaves running is
/// refused `exit-timeout` naming the processes the stop signalled, its
/// sandbox never closed and its record running.
#[test]
fn a_hosted_harness_is_read_exited_after_its_provider_stop_within_the_bound() {
    let idle = "❯ do the thing\n● Done.\n\n❯\u{a0}\n  ? for shortcuts\n";
    for ends in [true, false] {
        let mut fleet = Fleet::verb_pane(idle);
        if ends {
            fleet.answer("STOP_ENDS", "1");
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "completed");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let calls = fleet.provider_calls();
        let stop = calls
            .iter()
            .position(|c| c == "stop --item KEN-1 --harness claude")
            .expect("the provider's stop");
        assert!(
            calls[stop + 1..]
                .iter()
                .any(|c| c == "status --item KEN-1 --harness claude"),
            "ends={ends}: the status read after the stop: {calls:?}"
        );
        if ends {
            assert_eq!(answer["result"]["word"], "closed", "{answer}");
            assert_eq!(fleet.lane("KEN-1")["status"], "done");
        } else {
            assert_eq!(answer["refusal"]["key"], "exit-timeout", "{answer}");
            let fields = refusal_fields(&answer);
            assert_eq!(fields["processes"], "1", "{answer}");
            assert!(!calls.iter().any(|c| c.starts_with("close ")), "{calls:?}");
            assert_eq!(fleet.lane("KEN-1")["status"], "running");
        }
    }
}

/// Copilot writes its session totals on `/exit`: a hosted Copilot lane on a
/// provider that captures its pane gets `C-c`, then `/exit` as the input
/// file's text, through the provider's own input, and needs no provider
/// stop where that ends it; one `/exit` leaves running is stopped through
/// the provider after the bound.
#[test]
fn a_hosted_copilot_lane_gets_exit_before_its_provider_stop() {
    let rule = "─".repeat(40);
    let idle = format!(" ~/work [⎇ main]\n{rule}\n❯ \n{rule}\n");
    for ends in [true, false] {
        let mut fleet = Fleet::verb_pane(&idle);
        if ends {
            fleet.answer("SEND_ENDS", "1");
        } else {
            fleet.answer("STOP_ENDS", "1");
        }
        let mut lane = hosted_lane("KEN-1");
        lane["harness"] = json!("copilot");
        fleet.write_lanes(vec![lane]);
        fleet.plant_tracker("KEN-1", "completed");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        assert_eq!(answer["result"]["word"], "closed", "ends={ends}: {answer}");
        let calls = fleet.provider_calls();
        let key = calls
            .iter()
            .position(|c| c == "send --item KEN-1 --key C-c")
            .expect("the interrupt key");
        assert!(
            calls[key + 1].starts_with("send --item KEN-1 --file "),
            "{calls:?}"
        );
        assert_eq!(
            std::fs::read_to_string(fleet.state_dir().join("provider-sent")).unwrap(),
            "/exit"
        );
        assert_eq!(
            calls
                .iter()
                .any(|c| c == "stop --item KEN-1 --harness copilot"),
            !ends,
            "ends={ends}: {calls:?}"
        );
        assert!(
            !std::fs::read_dir(fleet.state_dir()).unwrap().any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("copilot-exit.")),
            "the input file is removed"
        );
    }
}

// --- the container close ---

/// A container close's world: a checkout of its own (a git repository the
/// closers' lock lives under), the linear fixture as the tracker beside it
/// answering `replies` by verb, and the `gh` fixture first on `PATH`
/// answering `gh` where given.
struct Container {
    fleet: Fleet,
    checkout: PathBuf,
}

impl Container {
    fn new(replies: Value, gh: Option<Value>) -> Container {
        let mut fleet = Fleet::new(4);
        let checkout = fleet.state_dir().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let out = program("git")
            .args(["-C", &checkout.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(out.status.success(), "git init: {}", stderr(&out));
        let tracker = fleet.state_dir().join("linear.sh");
        std::os::unix::fs::symlink(fixtures().join("linear-fixture/linear.sh"), &tracker).unwrap();
        std::fs::write(fleet.state_dir().join("linear.json"), replies.to_string()).unwrap();
        fleet.env.push((
            "OVERSEE_WATCH_TRACKER".to_owned(),
            tracker.display().to_string(),
        ));
        if let Some(gh) = gh {
            let bin = fleet.state_dir().join("bin");
            std::fs::create_dir_all(&bin).unwrap();
            std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
            std::fs::write(bin.join("gh.json"), gh.to_string()).unwrap();
            fleet
                .env
                .push(("PATH".to_owned(), tool_path(&[bin.as_path()])));
        }
        Container { fleet, checkout }
    }

    fn close(&self, parent: &str) -> Output {
        self.fleet.run(&[
            "container-close",
            &self.checkout.display().to_string(),
            parent,
        ])
    }

    fn calls(&self) -> Vec<String> {
        self.fleet.lines("linear.log")
    }

    fn replies(&self, replies: Value) {
        std::fs::write(
            self.fleet.state_dir().join("linear.json"),
            replies.to_string(),
        )
        .unwrap();
    }
}

fn stdout_of(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// The tracker's answers for a container KEN-C: the parent in `state`, its
/// `children`, and a validation whose parent row has its summary where
/// `summarized`, no open box, no error and its child box 3 unmet.
fn container_replies(state: &str, children: Value, summarized: bool) -> Value {
    let mut results = vec![
        json!({"id": "KEN-C", "has_summary": summarized, "container_open_boxes": [],
        "errors": [], "child_box": 3, "unmet_branch_boxes": [3]}),
    ];
    for child in children.as_array().unwrap() {
        results.push(json!({"id": child["id"], "ok": true, "state_ok": true, "has_summary": true}));
    }
    json!({
        "issues get": {"body": {"state_type": state, "in_pr_bundle": false}},
        "issues children": {"body": children},
        "issues validate-completion": {"body": {"results": results}},
        "issues complete": {"body": {}},
        "issues update": {"body": {}},
    })
}

fn child(id: &str, state: &str) -> Value {
    json!({"id": id, "title": format!("work {id}"), "state_type": state})
}

/// A container closes only when its last child ends, by one decision table
/// read in order: an open child defers with the children still open; every
/// child Done completes the parent with the bundle summary and the child
/// box's evidence; every child canceled sets the parent Canceled; a parent
/// already Done or Canceled is left as it is; and each refusal names its
/// cause, the refused rows with their remedies before it, nothing mutated.
#[test]
fn a_container_closes_only_when_its_children_end() {
    let done = json!([child("KEN-1", "completed"), child("KEN-2", "completed")]);
    let gh = json!({"pr list": {"body": []}});
    // (case, replies, stdout, the mutation's verb words, a refusal's key)
    type Case = (
        &'static str,
        Value,
        &'static str,
        Option<&'static str>,
        Option<&'static str>,
    );
    let mut open_box = container_replies("started", done.clone(), false);
    open_box["issues validate-completion"]["body"]["results"][0]["container_open_boxes"] =
        json!([2]);
    let mut not_ok = container_replies("started", done.clone(), false);
    not_ok["issues validate-completion"]["body"]["results"][1]["ok"] = json!(false);
    not_ok["issues validate-completion"]["body"]["results"][1]["state_ok"] = json!(false);
    let mut invalid = container_replies("started", done.clone(), false);
    invalid["issues validate-completion"]["body"]["results"][0]["errors"] = json!([{"box": 4}]);
    let mut bundle = container_replies("started", done.clone(), false);
    bundle["issues get"]["body"]["in_pr_bundle"] = json!(true);
    let mut unread = container_replies("started", done.clone(), false);
    unread["issues validate-completion"] = json!({"body": {"results": []}});
    let rows: Vec<Case> = vec![
        (
            "a child open",
            container_replies(
                "started",
                json!([child("KEN-1", "completed"), child("KEN-2", "started")]),
                false,
            ),
            "deferred KEN-2\n",
            None,
            None,
        ),
        (
            "every child done",
            container_replies("started", done.clone(), false),
            "closed KEN-C\n",
            Some("issues complete"),
            None,
        ),
        (
            "every child canceled",
            container_replies("started", json!([child("KEN-1", "canceled")]), false),
            "closed KEN-C\n",
            Some("issues update"),
            None,
        ),
        (
            "already done",
            container_replies("completed", done.clone(), true),
            "closed KEN-C\n",
            Some("issues complete"),
            None,
        ),
        (
            "already canceled",
            container_replies("canceled", json!([child("KEN-1", "canceled")]), false),
            "closed KEN-C\n",
            None,
            None,
        ),
        (
            "no children",
            container_replies("started", json!([]), false),
            "",
            None,
            Some("no-children"),
        ),
        (
            "an in-PR bundle root",
            bundle,
            "",
            None,
            Some("in-pr-bundle"),
        ),
        (
            "an open box",
            open_box,
            "",
            None,
            Some("completion-refused"),
        ),
        (
            "a child not ok",
            not_ok,
            "",
            None,
            Some("completion-refused"),
        ),
        (
            "a checklist error",
            invalid,
            "",
            None,
            Some("completion-refused"),
        ),
        (
            "a canceled parent with a done child",
            container_replies("canceled", done.clone(), false),
            "",
            None,
            Some("completion-refused"),
        ),
        (
            "a validation that does not type",
            unread,
            "",
            None,
            Some("validation-result"),
        ),
    ];
    for (case, replies, stdout, mutation, refused) in rows {
        let container = Container::new(replies, Some(gh.clone()));
        let out = container.close("KEN-C");
        assert_eq!(stdout_of(&out), stdout, "{case}: {}", stderr(&out));
        let calls = container.calls();
        let mutated: Vec<&String> = calls
            .iter()
            .filter(|c| c.starts_with("issues complete") || c.starts_with("issues update"))
            .collect();
        match mutation {
            Some(verb) => {
                assert_eq!(mutated.len(), 1, "{case}: {calls:?}");
                assert!(mutated[0].starts_with(verb), "{case}: {calls:?}");
            }
            None => assert!(mutated.is_empty(), "{case}: nothing mutated: {calls:?}"),
        }
        if let Some(key) = refused {
            assert_eq!(out.status.code(), Some(1), "{case}");
            assert!(
                stderr(&out).contains(&format!("container-close: {key} ")),
                "{case}: {}",
                stderr(&out)
            );
        }
        match case {
            "every child done" => {
                let complete = mutated[0];
                assert!(complete.contains("--summary-file"), "{complete}");
                assert!(
                    complete.contains("--done-when-met 3 --evidence-file"),
                    "{complete}"
                );
            }
            "already done" => assert!(
                !mutated[0].contains("--summary-file"),
                "a resumed parent posts no second summary: {}",
                mutated[0]
            ),
            "every child canceled" | "already canceled" => assert!(
                stderr(&out).contains("container-close: canceled parent-id=KEN-C"),
                "{case}: {}",
                stderr(&out)
            ),
            "an open box" | "a child not ok" | "a checklist error" => {
                let row = stderr(&out)
                    .lines()
                    .find(|l| l.starts_with('{'))
                    .map(|l| serde_json::from_str::<Value>(l).unwrap())
                    .unwrap_or(Value::Null);
                assert!(
                    row["remedy"]
                        .as_str()
                        .is_some_and(|r| r.ends_with("then rerun container-close.")),
                    "{case}: {}",
                    stderr(&out)
                );
            }
            _ => {}
        }
    }
}

/// The bundle summary names each Done child's merged pull request from the
/// shared checkout: its own branch's latest merge as `#N`, `unavailable`
/// where a valid lookup matched none; a lookup that fails refuses
/// `pr-unresolved` with the parent left open.
#[test]
fn a_container_summary_names_each_childs_pull_request() {
    let done = json!([child("KEN-1", "completed"), child("KEN-2", "completed")]);
    let gh = |list: Value| json!({"pr list": list});
    let rows = [
        (
            "a merged child and one unmatched",
            Some(json!({"body": [
                {"number": 11, "headRefName": "feature/ken-1-work", "mergedAt": "2026-01-01T00:00:00Z", "isCrossRepository": false},
                {"number": 12, "headRefName": "ken-1", "mergedAt": "2026-01-02T00:00:00Z", "isCrossRepository": false},
                {"number": 13, "headRefName": "ken-1", "mergedAt": "2026-01-03T00:00:00Z", "isCrossRepository": true}
            ]})),
            true,
        ),
        (
            "a failed lookup",
            Some(json!({"exit": 1, "stderr": "HTTP 502"})),
            false,
        ),
    ];
    for (case, list, closes) in rows {
        // The completion held, so the summary it built stands to be read.
        let mut replies = container_replies("started", done.clone(), false);
        replies["issues complete"] = json!({"exit": 1, "stderr": "{\"code\":\"RATELIMITED\",\"quota\":{\"reset\":\"2026-01-01T02:00:00Z\"}}\n"});
        let container = Container::new(replies, list.map(gh));
        let out = container.close("KEN-C");
        if closes {
            assert_eq!(
                stdout_of(&out),
                "held KEN-C 2026-01-01T02:00:00Z\n",
                "{case}: {}",
                stderr(&out)
            );
            let summary = std::fs::read_to_string(
                container
                    .checkout
                    .join("tmp/container-close-held/KEN-C/summary.md"),
            )
            .unwrap();
            assert_eq!(
                summary,
                "## Bundle Complete\n\n- KEN-1 ✓ work KEN-1 — PR #12\n- KEN-2 ✓ work KEN-2 — PR unavailable\n",
                "{case}"
            );
        } else {
            assert_eq!(out.status.code(), Some(1), "{case}");
            assert!(
                stderr(&out).contains("container-close: pr-unresolved child-id=KEN-1"),
                "{case}: {}",
                stderr(&out)
            );
            assert!(
                !container
                    .calls()
                    .iter()
                    .any(|c| c.starts_with("issues complete")),
                "{case}"
            );
        }
    }
}

/// A completion the tracker's quota hold stops holds `held ID RESET`, the
/// summary it built kept under the shared checkout; the next run, its
/// children unchanged, reuses that summary with no second lookup, completes
/// and releases the held inputs.
#[test]
fn a_rate_limited_container_close_holds_and_resumes_once() {
    let done = json!([child("KEN-1", "completed")]);
    let mut replies = container_replies("started", done.clone(), false);
    let receipt = json!({"code": "RATELIMITED", "requests_reset": "2026-01-01T01:00:00Z", "quota": {"reset": "2026-01-01T02:00:00Z"}});
    replies["issues complete"] = json!({"exit": 1, "stderr": format!("{receipt}\n")});
    let gh = json!({"pr list": {"body": [{"number": 21, "headRefName": "ken-1", "mergedAt": "2026-01-01T00:00:00Z", "isCrossRepository": false}]}});
    let container = Container::new(replies, Some(gh));
    let out = container.close("KEN-C");
    assert_eq!(
        stdout_of(&out),
        "held KEN-C 2026-01-01T02:00:00Z\n",
        "{}",
        stderr(&out)
    );
    let held = container
        .checkout
        .join("tmp/container-close-held/KEN-C/summary.md");
    let summary = std::fs::read_to_string(&held).expect("the held summary");
    assert!(summary.contains("KEN-1 ✓ work KEN-1 — PR #21"), "{summary}");
    let lookups = || {
        container
            .fleet
            .lines("bin/gh.log")
            .iter()
            .filter(|c| c.starts_with("pr list"))
            .count()
    };
    assert_eq!(lookups(), 1);
    container.replies(container_replies("started", done, false));
    let out = container.close("KEN-C");
    assert_eq!(stdout_of(&out), "closed KEN-C\n", "{}", stderr(&out));
    assert_eq!(lookups(), 1, "the held summary is reused, no second lookup");
    assert!(
        std::fs::symlink_metadata(&held).is_err(),
        "the held inputs are released"
    );
}

/// The close decides its own parent alone: a container whose own parent is
/// another container closes and reads nothing of that grandparent.
#[test]
fn a_container_close_infers_no_cascade() {
    let mut replies = container_replies("completed", json!([child("KEN-1", "completed")]), true);
    replies["issues get"]["body"]["parent"] = json!({"id": "KEN-G"});
    let container = Container::new(replies, None);
    let out = container.close("KEN-C");
    assert_eq!(stdout_of(&out), "closed KEN-C\n", "{}", stderr(&out));
    assert!(
        container.calls().iter().all(|c| !c.contains("KEN-G")),
        "{:?}",
        container.calls()
    );
}

/// A parent id that is not one item key refuses `invalid-parent` at exit 2
/// before any tracker read.
#[test]
fn a_container_close_refuses_an_invalid_parent_id() {
    for parent in ["../KEN-C", "KEN..C", "-KEN", "KEN C"] {
        let container = Container::new(container_replies("started", json!([]), false), None);
        let out = container.close(parent);
        assert_eq!(out.status.code(), Some(2), "{parent}");
        assert!(
            stderr(&out).contains("container-close: invalid-parent "),
            "{parent}: {}",
            stderr(&out)
        );
        assert!(container.calls().is_empty(), "{parent}");
    }
}

/// One lock under the shared checkout serializes every closer: while
/// another closer holds `tmp/container-close.lock`, a close mutates
/// nothing; once it is released, the close goes on and completes.
#[test]
fn two_closers_of_one_container_mutate_it_once() {
    let container = Container::new(
        container_replies("completed", json!([child("KEN-1", "completed")]), true),
        None,
    );
    let tmp = container.checkout.join("tmp");
    std::fs::create_dir_all(&tmp).unwrap();
    // The other closer: `flock` holding the lock until the release file
    // stands, the barrier this row lifts. Its waiter also ends with this
    // test's process or after 30 s, and its output goes nowhere, so a killed
    // run leaves no holder and no holder keeps the runner's pipes open.
    let holder = Holder {
        release: tmp.join("release"),
        child: program("flock")
            .arg(tmp.join("container-close.lock"))
            .args([
                "sh",
                "-c",
                "i=0; while [ ! -e \"$1\" ] && kill -0 \"$2\" 2>/dev/null && [ \"$i\" -lt 600 ]; \
                 do sleep 0.05; i=$((i + 1)); done",
                "_",
            ])
            .arg(tmp.join("release"))
            .arg(std::process::id().to_string())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("flock"),
    };
    // `flock` starts its command only once it holds the lock.
    let children = format!("/proc/{0}/task/{0}/children", holder.child.id());
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::fs::read_to_string(&children)
        .unwrap_or_default()
        .trim()
        .is_empty()
    {
        assert!(
            std::time::Instant::now() < deadline,
            "the holder never locked"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut command = isolated();
    command
        .args([
            "--state-dir",
            &container.fleet.state_dir().display().to_string(),
        ])
        .args([
            "container-close",
            &container.checkout.display().to_string(),
            "KEN-C",
        ])
        .current_dir(container.fleet.state_dir())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    for (name, value) in &container.fleet.env {
        command.env(name, value);
    }
    let closer = command.spawn().expect("the closer");
    // Time for the closer to reach its lock wait: a close that took no lock
    // reads the parent within it.
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        container.calls().is_empty(),
        "nothing is read under another closer's lock"
    );
    drop(holder);
    let out = closer.wait_with_output().unwrap();
    assert_eq!(stdout_of(&out), "closed KEN-C\n", "{}", stderr(&out));
}

/// The other closer of the lock row and its barrier: dropping it, on a pass
/// or on a failed assertion alike, writes the release file and reaps the
/// holder, so the row ends its own processes before its temp root goes.
struct Holder {
    release: PathBuf,
    child: std::process::Child,
}

impl Drop for Holder {
    fn drop(&mut self) {
        let _ = std::fs::write(&self.release, "");
        let _ = self.child.wait();
    }
}

// --- the cycle verbs ---

/// The verbs the retained `oversee-report` and the overseer's reads run
/// through the `oversee-cycle` shim, over the fleet record: with none,
/// `report` and `rollup` print nothing and write nothing; `report` prints
/// each class's rollup row and each recorded stage's row and leaves the
/// record byte for byte; `rollup` appends each row to the fleet log under
/// its class; `stages ITEM` prints a running lane's stages by start, with
/// `superseded=1` and `reason=`, from the lane's own state; an item no
/// record names refuses `record-missing`, and a lane with no state
/// `stages-unread`. The ended lane's `cycle` is a released record planted
/// as `main`'s close wrote it.
#[test]
fn the_cycle_verbs_print_the_rollup_and_a_running_lanes_stages() {
    let fleet = Fleet::new(4);
    // The shipped shim beside the binary under its launcher's name.
    let scripts = fleet.state_dir().join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    let shim = scripts.join("oversee-cycle");
    std::fs::copy(orch_package().join("scripts/oversee-cycle"), &shim).unwrap();
    std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
    let state_dir = fleet.state_dir().display().to_string();
    let cycle = |args: &[&str]| -> Output {
        program(&shim)
            .args(["--state-dir", &state_dir])
            .args(args)
            .current_dir(fleet.state_dir())
            .output()
            .unwrap()
    };
    for (verb, out) in [
        ("report", cycle(&["report"])),
        ("rollup", fleet.run(&["cycle", "rollup"])),
    ] {
        assert_eq!(
            (out.status.code(), stdout_of(&out)),
            (Some(0), String::new()),
            "{verb} with no fleet record: {}",
            stderr(&out)
        );
    }
    assert!(!fleet.fleet_path().exists(), "nothing is written");
    fleet.init_fleet();
    fleet.write_lanes(vec![
        json!({"item": "KEN-1", "status": "done", "cycle": {"class": "micro", "actual": 100, "lane_secs": 100,
            "verdict": "met", "rounds": null, "pr_rounds": null,
            "stages": [{"kind": "dev", "round_id": "r1", "start": 5, "end": 9}]}}),
        json!({"item": "KEN-2", "status": "running"}),
        json!({"item": "KEN-3", "status": "running"}),
    ]);
    std::fs::write(
        fleet.state_dir().join("workflow-state-KEN-2.json"),
        json!({"stages": [
            {"kind": "fix", "round_id": "r2", "start": 20, "end": null, "superseded": true, "reason": "restacked"},
            {"kind": "dev", "round_id": "r1", "start": 10, "end": 15}
        ]})
        .to_string(),
    )
    .unwrap();
    let rollup = "rollup class=micro items=1 median=100 p90=100 lane_median=100 open_median=- miss_share=0/1 misses=0 draft=- review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0";
    let before = std::fs::read(fleet.fleet_path()).unwrap();
    let out = cycle(&["report"]);
    assert_eq!(
        stdout_of(&out),
        format!("{rollup}\nstage item=KEN-1 kind=dev round_id=r1 start=5 end=9\n"),
        "{}",
        stderr(&out)
    );
    assert_eq!(
        std::fs::read(fleet.fleet_path()).unwrap(),
        before,
        "report writes nothing"
    );
    let out = fleet.run(&["cycle", "rollup"]);
    assert_eq!(stdout_of(&out), format!("{rollup}\n"), "{}", stderr(&out));
    let log = fleet.fleet()["fleet_log"].clone();
    assert_eq!(
        log.as_array()
            .unwrap()
            .iter()
            .map(|row| (
                row["kind"].clone(),
                row["item"].clone(),
                row["text"].clone()
            ))
            .collect::<Vec<_>>(),
        vec![(json!("cycle"), json!("micro"), json!(rollup))],
        "the rollup row joins the fleet log under its class"
    );
    let out = cycle(&["stages", "KEN-2"]);
    assert_eq!(
        stdout_of(&out),
        "stage item=KEN-2 kind=dev round_id=r1 start=10 end=15\nstage item=KEN-2 kind=fix round_id=r2 start=20 end=- superseded=1 reason=restacked\n",
        "{}",
        stderr(&out)
    );
    for (item, key) in [("KEN-9", "record-missing"), ("KEN-3", "stages-unread")] {
        let out = cycle(&["stages", item]);
        assert_ne!(out.status.code(), Some(0), "{item}");
        assert!(stderr(&out).contains(key), "{item}: {}", stderr(&out));
    }
}

/// Each read a container close makes refuses by its key, nothing mutated
/// before it: the parent's, the children's and the validation's reads that
/// fail or do not type, a completion that fails with no quota receipt, a
/// tracker CLI that cannot start, and a checkout that is not one.
#[test]
fn a_container_close_refuses_each_read_by_its_key() {
    let done = json!([child("KEN-1", "completed")]);
    let with = |verb: &str, reply: Value| {
        let mut replies = container_replies("started", done.clone(), false);
        replies[verb] = reply;
        replies
    };
    let mutated = |container: &Container| {
        container
            .calls()
            .iter()
            .filter(|c| c.starts_with("issues complete") || c.starts_with("issues update"))
            .count()
    };
    for (case, replies, key, mutations) in [
        (
            "a parent read that fails",
            with("issues get", json!({"exit": 1})),
            "parent-unreadable",
            0,
        ),
        (
            "a parent that does not type",
            with("issues get", json!({"body": {"state_type": 5}})),
            "parent-response",
            0,
        ),
        (
            "children that fail",
            with("issues children", json!({"exit": 1})),
            "children-unreadable",
            0,
        ),
        (
            "a child with no id",
            with(
                "issues children",
                json!({"body": [{"id": "", "title": "t", "state_type": "completed"}]}),
            ),
            "children-response",
            0,
        ),
        (
            "a validation that fails",
            with("issues validate-completion", json!({"exit": 1})),
            "validation-failed",
            0,
        ),
        (
            "a completion that fails",
            with("issues complete", json!({"exit": 1, "stderr": "boom\n"})),
            "completion-failed",
            1,
        ),
    ] {
        let container = Container::new(replies, Some(json!({"pr list": {"body": []}})));
        let out = container.close("KEN-C");
        assert_eq!(out.status.code(), Some(1), "{case}: {}", stderr(&out));
        assert!(
            stderr(&out).contains(&format!("container-close: {key} ")),
            "{case}: {}",
            stderr(&out)
        );
        assert_eq!(
            mutated(&container),
            mutations,
            "{case}: {:?}",
            container.calls()
        );
    }
    let mut container = Container::new(container_replies("started", done, false), None);
    let missing = container.fleet.state_dir().join("no-linear.sh");
    container.fleet.env.push((
        "OVERSEE_WATCH_TRACKER".to_owned(),
        missing.display().to_string(),
    ));
    let out = container.close("KEN-C");
    assert!(
        stderr(&out).contains("container-close: linear-missing "),
        "a tracker CLI that cannot start: {}",
        stderr(&out)
    );
    let elsewhere = container.fleet.state_dir().join("no-checkout");
    let out = container
        .fleet
        .run(&["container-close", &elsewhere.display().to_string(), "KEN-C"]);
    assert!(
        stderr(&out).contains("container-close: checkout-invalid "),
        "a checkout that is not one: {}",
        stderr(&out)
    );
}

/// pr-timeline's one GraphQL read of the merged pull request 7, its three
/// selections of `commits` planted under their arguments.
fn merged_timeline() -> Value {
    json!({"body": {"data": {"repository": {"pullRequest": {
        "number": 7, "state": "MERGED", "body": "", "createdAt": "2026-01-29T15:10:00Z", "mergedAt": "2026-01-29T16:20:00Z",
        "author": {"login": "lane-app"}, "headRefName": "", "headRepository": null,
        "mergeCommit": {"__typename": "Commit", "oid": "m1",
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}},
        "commits(first: 1)": {"nodes": [{"commit": {"authoredDate": "2026-01-29T15:05:00Z"}}]},
        "commits(last: 1)": {"nodes": [{"commit": {"__typename": "Commit", "oid": "h2", "committedDate": "2026-01-29T15:50:00Z",
            "status": {"context": {"state": "SUCCESS", "createdAt": "2026-01-29T16:00:00Z"}},
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}]},
        "commits(last: 100)": {"totalCount": 0, "nodes": []},
        "reviews": {"totalCount": 0, "nodes": []},
        "timelineItems": {"pageInfo": {"hasNextPage": false}, "nodes": []}
    }}}}})
}

/// The lane state whose fix rounds are `fix`, with one review, three bot
/// iterations and one full validation besides.
fn rounds_state(fix: u64) -> Value {
    json!({"first_panel": {"agents": ["a"]}, "rereview_cycles": 1, "cycles": fix,
        "pr_comment_review": {"iterations": 3}, "validate_rounds": [{"mode": "full"}, {"mode": "range"}]})
}

/// A merged hosted lane's close records its cycle through the real
/// pr-timeline over the `gh` fixture, its rounds read where its host kept
/// its state, through the real dispatcher: the clone its worktree's `.git`
/// names, else the copy its merge saved there, which the clone the watch
/// kept still names once the merge's close-out removed the worktree, else
/// the archive the fleet log's last `kept=` row names, whose empty state
/// marker selects this merge's saved copy and never another's, and which,
/// with no marker at all, answers from the member named for the item before
/// the merge's copy, passing over the empty hard-link entry a twice-archived
/// file leaves; with none, the rounds are null and the close's notes name
/// the paths tried. The class stays unread with its cause, the checkout no
/// repository. The archives are planted in the three forms
/// `lane-host-ssh::archive_tmp` writes, as `main` wrote them. Under the C
/// locale, where tar lists a non-ASCII name escaped, a marker naming one
/// still answers, and a worktree named so still sorts after the clone. A
/// marker naming the physical path of a clone recorded through a symlink
/// names the hard-link entry its second archiving left, and still answers.
#[test]
fn a_closed_lanes_cycle_reads_its_rounds_where_its_host_kept_them() {
    for (case, fix) in [
        ("the clone's state", Some(2)),
        ("the merge's saved copy", Some(4)),
        ("the saved copy after the worktree's removal", Some(4)),
        ("the archive its close kept", Some(6)),
        ("the archive's saved copy alone", Some(6)),
        ("the archive with no state marker", Some(8)),
        ("a marker naming a non-ASCII path", Some(10)),
        ("no marker, a non-ASCII worktree", Some(12)),
        ("a marker naming a hard-link entry", Some(14)),
        ("no state anywhere", None),
    ] {
        let mut fleet = Fleet::hosted(4);
        let skills = fleet.state_dir().join(".agents/skills");
        let catalog = orch_package().parent().unwrap().to_path_buf();
        std::os::unix::fs::symlink(catalog.join("github"), skills.join("github")).unwrap();
        let bin = fleet.state_dir().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
        std::fs::write(
            bin.join("gh.json"),
            json!({"graphql number=7 cursor=": merged_timeline()}).to_string(),
        )
        .unwrap();
        fleet
            .env
            .push(("PATH".to_owned(), tool_path(&[bin.as_path()])));
        fleet
            .env
            .push(("GH_TOKEN".to_owned(), "fixture-token".to_owned()));
        let disk = fleet.state_dir().join("provider-disk");
        let put = |path: &str, text: &str| {
            let at = disk.join(path.trim_start_matches('/'));
            std::fs::create_dir_all(at.parent().unwrap()).unwrap();
            std::fs::write(at, text).unwrap();
        };
        let gitfile = "gitdir: /w/clone/.git/worktrees/ken-1\n";
        let saved = |pr: u64| format!("/w/clone/tmp/cycle-state/workflow-state-pr-{pr}.json");
        // The clone a watch pass read from the worktree's `.git`, kept in
        // the baseline beside the fleet state.
        let retained = || {
            std::fs::write(
                fleet.state_dir().join("oversee-watch.baseline.json"),
                json!({"rows": [{"kind": "clone-root", "identity": "KEN-1", "value": "/w/clone"}]})
                    .to_string(),
            )
            .unwrap();
        };
        // The archive a close kept, `marker` its `lane-host-state` member
        // where it has one, each `linked` member a hard link to the member it
        // names, archived after it, and the fleet log's row naming it.
        let archive = |marker: Option<&str>, members: &[(&str, Value)], linked: &[(&str, &str)]| {
            let kept = fleet.state_dir().join("kept");
            for (member, state) in members {
                let at = kept.join(member);
                std::fs::create_dir_all(at.parent().unwrap()).unwrap();
                std::fs::write(at, state.to_string()).unwrap();
            }
            for (link, target) in linked {
                let at = kept.join(link);
                std::fs::create_dir_all(at.parent().unwrap()).unwrap();
                std::fs::hard_link(kept.join(target), at).unwrap();
            }
            let mut names: Vec<&str> = members.iter().map(|(member, _)| *member).collect();
            names.extend(linked.iter().map(|(link, _)| *link));
            if let Some(marker) = marker {
                std::fs::write(kept.join("lane-host-state"), marker).unwrap();
                names.insert(0, "lane-host-state");
            }
            let archive = fleet.state_dir().join("kept.tgz");
            let out = program("tar")
                .arg("-czf")
                .arg(&archive)
                .arg("-C")
                .arg(&kept)
                .args(&names)
                .output()
                .unwrap();
            assert!(out.status.success(), "tar: {}", stderr(&out));
            json!({"at": "2026-01-29T16:30:00Z", "kind": "close", "item": "KEN-1",
                "text": format!("lane-host close kept={}", archive.display())})
        };
        let mut log = Vec::new();
        match (case, fix) {
            ("the clone's state", Some(fix)) => {
                put(&format!("{REMOTE_ROOT}/.git"), gitfile);
                put(
                    "/w/clone/tmp/workflow-state-KEN-1.json",
                    &rounds_state(fix).to_string(),
                );
            }
            ("the merge's saved copy", Some(fix)) => {
                put(&format!("{REMOTE_ROOT}/.git"), gitfile);
                put(&saved(7), &rounds_state(fix).to_string());
            }
            ("the saved copy after the worktree's removal", Some(fix)) => {
                retained();
                put(&saved(6), &rounds_state(9).to_string());
                put(&saved(7), &rounds_state(fix).to_string());
            }
            ("the archive its close kept", Some(fix)) => log.push(archive(
                Some("clone/tmp/workflow-state-KEN-1.json\n"),
                &[("clone/tmp/workflow-state-KEN-1.json", rounds_state(fix))],
                &[],
            )),
            ("the archive's saved copy alone", Some(fix)) => log.push(archive(
                Some("\n"),
                &[
                    (&saved(6)[1..], rounds_state(9)),
                    (&saved(7)[1..], rounds_state(fix)),
                ],
                &[],
            )),
            // The worktree's tmp linked to the clone's archives one state file
            // under both paths, the clone's as the hard-link entry.
            ("the archive with no state marker", Some(fix)) => log.push(archive(
                None,
                &[
                    ("w/ken-1/tmp/workflow-state-KEN-1.json", rounds_state(fix)),
                    (&saved(7)[1..], rounds_state(9)),
                ],
                &[(
                    "w/clone/tmp/workflow-state-KEN-1.json",
                    "w/ken-1/tmp/workflow-state-KEN-1.json",
                )],
            )),
            ("a marker naming a non-ASCII path", Some(fix)) => log.push(archive(
                Some("clon\u{e9}/tmp/workflow-state-KEN-1.json\n"),
                &[(
                    "clon\u{e9}/tmp/workflow-state-KEN-1.json",
                    rounds_state(fix),
                )],
                &[],
            )),
            // The worktree's name sorts before the clone's, so only a name
            // read raw places the clone's copy first.
            ("no marker, a non-ASCII worktree", Some(fix)) => log.push(archive(
                None,
                &[
                    (
                        "w/an\u{e9}-1/tmp/workflow-state-KEN-1.json",
                        rounds_state(9),
                    ),
                    ("w/clone/tmp/workflow-state-KEN-1.json", rounds_state(fix)),
                ],
                &[],
            )),
            // The clone's tmp archived through its recorded path, then the
            // state file through its physical one, which the marker names.
            ("a marker naming a hard-link entry", Some(fix)) => log.push(archive(
                Some("var/w/clone/tmp/workflow-state-KEN-1.json\n"),
                &[("w/clone/tmp/workflow-state-KEN-1.json", rounds_state(fix))],
                &[(
                    "var/w/clone/tmp/workflow-state-KEN-1.json",
                    "w/clone/tmp/workflow-state-KEN-1.json",
                )],
            )),
            _ => retained(),
        }
        let mut lane = hosted_lane("KEN-1");
        if case.contains("non-ASCII") {
            fleet.env.push(("LC_ALL".to_owned(), "C".to_owned()));
        }
        if case == "no marker, a non-ASCII worktree" {
            lane["mail_root"] = json!("/w/an\u{e9}-1");
        }
        fleet.write_lanes(vec![lane]);
        let mut doc = fleet.fleet();
        doc["fleet_log"] = json!(log);
        std::fs::write(fleet.fleet_path(), doc.to_string()).unwrap();
        fleet.plant_tracker("KEN-1", "completed");
        let answer = fleet.close(
            json!({"op": "close-lane", "item": "KEN-1", "delivery": {"pr": {"pr": 7, "repo": "o/r"}}}),
        );
        assert_eq!(answer["result"]["word"], "closed", "{case}: {answer}");
        let cycle = fleet.lane("KEN-1")["cycle"].clone();
        assert_eq!(cycle["pr"], json!(7), "{case}: {cycle}");
        assert_eq!(
            (cycle["class"].clone(), cycle["class_cause"].clone()),
            (Value::Null, json!("checkout-absent")),
            "{case}: {cycle}"
        );
        let notes: Vec<String> = answer["result"]["notes"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|n| n.as_str().map(str::to_owned))
            .collect();
        match fix {
            Some(fix) => assert_eq!(
                cycle["rounds"],
                json!({"review": 2, "fix": fix, "bot": 3, "full_validations": 1}),
                "{case}: {notes:?}"
            ),
            None => {
                assert_eq!(cycle["rounds"], Value::Null, "{case}");
                assert!(
                    notes
                        .iter()
                        .any(|n| n == "oversee-cycle: rounds-unread item=KEN-1"),
                    "{case}: {notes:?}"
                );
                for path in [format!("{REMOTE_ROOT}/.git"), saved(7)] {
                    let tried = format!("lane-gitfile: state-tried item=KEN-1 path={path}");
                    assert!(
                        notes.iter().flat_map(|n| n.lines()).any(|l| l == tried),
                        "{case}: {notes:?}"
                    );
                }
            }
        }
    }
}

/// A hosted lane's validation runs are its host's: its close stops none
/// here, even where its root names a directory this machine also holds.
#[test]
fn a_hosted_close_stops_no_validation_run_of_this_machine() {
    let mut fleet = Fleet::hosted(4);
    let validate_log = fleet.state_dir().join("validate.log");
    fleet.env.push((
        "DEV_VALIDATE_LOG".to_owned(),
        validate_log.display().to_string(),
    ));
    let mut lane = hosted_lane("KEN-1");
    lane["mail_root"] = json!(fleet.state_dir().display().to_string());
    fleet.write_lanes(vec![lane]);
    fleet.plant_tracker("KEN-1", "completed");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    assert_eq!(
        std::fs::read_to_string(&validate_log).unwrap_or_default(),
        "",
        "no validation run stopped on this machine"
    );
}

// --- a merged item's boxes, completed by the close ------------------------------

/// The merge commit the planted pull request names.
const MERGE_SHA: &str = "0123456789abcdef0123456789abcdef01234567";

/// A Done-when of two branch-provable boxes, open or ticked with evidence.
fn done_when(ticked: bool) -> String {
    if ticked {
        "## Done when\n\n- [x] first\n  Evidence: lane proof one\n- [x] second\n  Evidence: lane proof two\n".to_owned()
    } else {
        "## Done when\n\n- [ ] first\n- [ ] second\n".to_owned()
    }
}

impl Fleet {
    /// A hosted world whose tracker is the linear package's own CLI over
    /// the planted Linear API (`linear-api/curl`) for KEN-1, in `state`
    /// with `description`, and whose `gh` answers pull request 7 of `o/r`
    /// merged with `body`. The state directory is the git checkout the CLI
    /// resolves its project from.
    fn boxes_world(state: &str, description: &str, body: &str) -> Fleet {
        let mut fleet = Fleet::hosted(4);
        fleet.answer("STOP_STATUS", "4");
        fleet.answer(
            "STOP_ERROR",
            "lane-host-ssh: stop-worktree-removed item=KEN-1",
        );
        let git = |args: &[&str]| {
            let out = program("git")
                .current_dir(fleet.state_dir())
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        };
        git(&["init", "-q"]);
        git(&["config", "gc.auto", "0"]);
        git(&["config", "maintenance.auto", "false"]);
        let bin = fleet.state_dir().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::os::unix::fs::symlink(fixtures().join("linear-api/curl"), bin.join("curl")).unwrap();
        std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
        let kind = if state == "Done" {
            "completed"
        } else {
            "started"
        };
        std::fs::write(
            bin.join("linear-api.json"),
            json!({"identifier": "KEN-1", "team": "KEN", "description": description,
                "state": {"name": state, "type": kind}})
            .to_string(),
        )
        .unwrap();
        let pull = json!({"number": 7, "state": "closed", "title": "work", "body": body,
            "merged_at": "2026-01-29T16:30:00Z", "merge_commit_sha": MERGE_SHA,
            "author_association": "NONE", "user": null,
            "base": {"ref": "main", "sha": "1111111111111111111111111111111111111111"},
            "head": {"sha": "2222222222222222222222222222222222222222", "ref": "ken-1",
                "repo": {"full_name": "o/r", "owner": {"login": "o", "type": "User"}}}});
        std::fs::write(
            bin.join("gh.json"),
            json!({"repos/o/r/pulls/7": {"body": pull}}).to_string(),
        )
        .unwrap();
        let linear = orch_package()
            .parent()
            .unwrap()
            .join("linear/scripts/linear.sh");
        fleet.env.extend([
            ("PATH".to_owned(), tool_path(&[bin.as_path()])),
            (
                "OVERSEE_WATCH_TRACKER".to_owned(),
                linear.display().to_string(),
            ),
            (
                "LINEAR_API_KEY_OVERRIDE".to_owned(),
                "test-token".to_owned(),
            ),
            ("LINEAR_TEAM".to_owned(), "KEN".to_owned()),
        ]);
        let mut lane = hosted_lane("KEN-1");
        lane["tracker"] = json!("linear");
        lane["repo"] = json!("o/r");
        fleet.write_lanes(vec![lane]);
        fleet
    }

    /// The issue as the planted API holds it after the close.
    fn issue(&self) -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(self.state_dir().join("bin/linear-api.json")).unwrap(),
        )
        .unwrap()
    }

    /// The GraphQL payloads the CLI sent whose document names `operation`.
    fn sent(&self, operation: &str) -> Vec<Value> {
        self.lines("bin/linear-api.log")
            .iter()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|p| p["query"].as_str().is_some_and(|q| q.contains(operation)))
            .collect()
    }
}

/// A merged item its lane left with branch-provable boxes open, its
/// sandbox gone or its lane ended over a Done item, has the boxes the
/// merged pull request's `## Done-when evidence` section proves ticked by
/// the close, through the linear package's own `issues complete`, each
/// Evidence line citing the merge and the close's cause, and the state the
/// command sets. A box the section gives no evidence for ticks nothing:
/// one comment names the boxes with and without evidence. An item the lane
/// completed is left alone.
#[test]
fn a_merged_items_proved_boxes_are_ticked_by_the_close_where_its_lane_could_not() {
    let proved = "## Summary\n- work\n\n## Done-when evidence\n1: tests/a.rs first_row\n2: tests/a.rs second_row\n\n## Test Plan\n- rows\n";
    let one = "## Done-when evidence\n1: tests/a.rs first_row\n";
    struct Case {
        name: &'static str,
        state: &'static str,
        ticked: bool,
        body: &'static str,
        note: Option<&'static str>,
        after: &'static str,
        comment: Option<(&'static str, &'static str)>,
        /// The mailbox read fails and the provider lists no sandbox for
        /// the item: the terminal close's `host-absent` ground.
        absent: bool,
    }
    let cases = [
        Case {
            name: "sandbox gone, both proved",
            state: "Verifying",
            ticked: false,
            body: proved,
            note: Some("boxes-ticked by=close cause=sandbox-gone boxes=1,2"),
            after: "Done",
            comment: None,
            absent: false,
        },
        Case {
            name: "Done, its sandbox gone from the provider",
            state: "Done",
            ticked: false,
            body: proved,
            note: Some("boxes-ticked by=close cause=sandbox-gone boxes=1,2"),
            after: "Done",
            comment: None,
            absent: true,
        },
        Case {
            name: "Done by the integration, the lane ended",
            state: "Done",
            ticked: false,
            body: proved,
            note: Some("boxes-ticked by=close cause=lane-ended boxes=1,2"),
            after: "Done",
            comment: None,
            absent: false,
        },
        Case {
            name: "one box without evidence",
            state: "Verifying",
            ticked: false,
            body: one,
            note: Some("boxes-unticked cause=evidence-partial boxes=2 comment=posted"),
            after: "Verifying",
            comment: Some(("with evidence: 1", "without evidence: 2")),
            absent: false,
        },
        Case {
            name: "no evidence section",
            state: "Verifying",
            ticked: false,
            body: "## Summary\n- work\n",
            note: Some("boxes-unticked cause=evidence-absent boxes=1,2 comment=posted"),
            after: "Verifying",
            comment: Some(("with evidence: none", "without evidence: 1,2")),
            absent: false,
        },
        Case {
            name: "the lane completed it",
            state: "Verifying",
            ticked: true,
            body: proved,
            note: None,
            after: "Verifying",
            comment: None,
            absent: false,
        },
    ];
    for case in cases {
        let name = case.name;
        let mut fleet = Fleet::boxes_world(case.state, &done_when(case.ticked), case.body);
        if case.absent {
            fleet
                .env
                .push(("LANE_MAIL_STATUS".to_owned(), "2".to_owned()));
            fleet.answer("LIST", "lane.example:/srv/other/ken-9\tbusy");
        }
        let before = fleet.issue()["description"].clone();
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let result = &answer["result"];
        assert_eq!(result["word"], "closed", "{name}: {answer}");
        let notes: Vec<&str> = result["notes"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|n| n.starts_with("boxes-"))
            .collect();
        assert_eq!(notes, case.note.into_iter().collect::<Vec<_>>(), "{name}");
        let issue = fleet.issue();
        assert_eq!(issue["state"]["name"], case.after, "{name}: {issue}");
        let description = issue["description"].as_str().unwrap();
        let updates = fleet.sent("issueUpdate");
        if case.note.is_some_and(|n| n.starts_with("boxes-ticked")) {
            let cause = if case.absent || case.state != "Done" {
                "sandbox-gone"
            } else {
                "lane-ended"
            };
            for (n, row) in [("first", "first_row"), ("second", "second_row")] {
                let proof = format!(
                    "- [x] {n}\n  Evidence: tests/a.rs {row} (merged as {MERGE_SHA} in o/r#7; ticked-by=close cause={cause})\n"
                );
                assert!(description.contains(&proof), "{name}: {description}");
            }
            assert_eq!(updates.len(), 1, "{name}: one update: {updates:?}");
        } else {
            assert_eq!(issue["description"], before, "{name}");
            assert!(updates.is_empty(), "{name}: no update: {updates:?}");
        }
        let comments = fleet.sent("commentCreate");
        match case.comment {
            Some((with, without)) => {
                assert_eq!(comments.len(), 1, "{name}: one comment: {comments:?}");
                let body = comments[0]["variables"]["input"]["body"].as_str().unwrap();
                assert!(
                    body.contains(with) && body.contains(without),
                    "{name}: {body}"
                );
            }
            None => assert!(comments.is_empty(), "{name}: no comment: {comments:?}"),
        }
        if case.note.is_none() {
            assert!(
                !fleet
                    .lines("bin/gh.log")
                    .iter()
                    .any(|l| l.contains("pulls/7")),
                "{name}: no pull request read for an item the lane completed"
            );
        }
        assert_eq!(fleet.lane("KEN-1")["status"], "done", "{name}");
    }

    // A box ticked with no Evidence line is one the command refuses on, so
    // the section's line for it is given beside the open box's.
    let fleet = Fleet::boxes_world(
        "Verifying",
        "## Done when\n\n- [x] first\n- [ ] second\n",
        proved,
    );
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    let notes: Vec<&str> = answer["result"]["notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .filter(|n| n.starts_with("boxes-"))
        .collect();
    assert_eq!(
        notes,
        ["boxes-ticked by=close cause=sandbox-gone boxes=1,2"],
        "{answer}"
    );
    assert_eq!(fleet.issue()["state"]["name"], "Done", "{answer}");

    // A Done item is read by no duty again: a completion whose pull request
    // GitHub does not hold is named in one comment there.
    let fleet = Fleet::boxes_world("Done", &done_when(false), proved);
    std::fs::write(fleet.state_dir().join("bin/gh.json"), "{}").unwrap();
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let notes: Vec<&str> = answer["result"]["notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .filter(|n| n.starts_with("boxes-"))
        .collect();
    assert_eq!(
        notes,
        ["boxes-unticked cause=pr-missing comment=posted"],
        "{answer}"
    );
    let comments = fleet.sent("commentCreate");
    assert_eq!(comments.len(), 1, "{comments:?}");
    let body = comments[0]["variables"]["input"]["body"].as_str().unwrap();
    assert!(body.contains("boxes-unticked cause=pr-missing"), "{body}");

    // A write Linear answers with a 5xx may have landed: the completion's
    // and the comment's are unknown, never failed.
    let box_notes = |answer: &Value| -> Vec<String> {
        answer["result"]["notes"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|n| n.starts_with("boxes-"))
            .map(str::to_owned)
            .collect()
    };
    for (state, body, operation, note) in [
        (
            "Verifying",
            proved,
            "UpdateIssue",
            "boxes-unknown cause=unconfirmed",
        ),
        (
            "Done",
            one,
            "CreateComment",
            "boxes-unticked cause=evidence-partial boxes=2 comment=unknown",
        ),
    ] {
        let fleet = Fleet::boxes_world(state, &done_when(false), body);
        let path = fleet.state_dir().join("bin/linear-api.json");
        let mut world: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        world["codes"] = json!({ operation: 502 });
        std::fs::write(&path, world.to_string()).unwrap();
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        assert_eq!(box_notes(&answer), [note], "{operation}: {answer}");
    }

    // A provider close that fails leaves the close unconfirmed, which the
    // watch asks again: the comment waits for the close that confirms, and
    // is posted once.
    let mut fleet = Fleet::boxes_world("Verifying", &done_when(false), one);
    fleet.answer("CLOSE_STATUS", "1");
    for _ in 0..2 {
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        assert_eq!(answer["result"]["word"], "unconfirmed", "{answer}");
        assert!(
            !answer["result"]["notes"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(Value::as_str)
                .any(|n| n.starts_with("boxes-")),
            "{answer}"
        );
    }
    assert_eq!(fleet.sent("commentCreate"), Vec::<Value>::new());
    fleet.answer("CLOSE_STATUS", "0");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    assert_eq!(fleet.sent("commentCreate").len(), 1, "{answer}");
}
