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
/// its weekly window (the binding) at 20 percent and its session window at
/// `session` percent, read this instant with three hours to its reset, so
/// the window opened two hours ago and the judge charges each lane on it,
/// the live ones and the candidate, the live lane's observed
/// half of the window's use for each of the three hours left (the session
/// projection, `ops/accounts.rs` `projection`): at 60 percent one live
/// lane and the candidate project 140 past the room, and the candidate
/// alone, at the setting's burn, leaves 25.
fn listing_row(session: u64, now: u64) -> Value {
    let weekly = clock::iso_utc(now + 3 * 86_400);
    json!({
        "alias": "aclaude",
        "harness": "claude",
        "config_dir": ACCOUNT,
        "measured_through": "local",
        "status": "ok",
        "verdict": "room",
        "headroom_pct": 80,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": 20,
        "session_5h_pct": session,
        "weekly_pct": 20,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": clock::iso_utc(now + 3 * 3600), "weekly": weekly, "model": null, "monthly": null},
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
/// onto an account another lane has filled. The account's session window
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
    assert_eq!(fields["bucket"], "session");
    assert_eq!(fields["pct"], "60");
    let headroom: f64 = fields["projected-headroom"].parse().unwrap();
    assert!(
        (-141.0..-139.0).contains(&headroom),
        "KEN-2's charge and the candidate's, not KEN-1's own reservation: {headroom}"
    );
    assert!(
        stderr(&out).starts_with(&format!(
            "orch-runtime: account-walled item=KEN-1 account={ACCOUNT} model=opus pct=60 bucket=session projected-headroom="
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
        (-141.0..-139.0).contains(&headroom),
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
