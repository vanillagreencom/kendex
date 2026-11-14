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
            .env("AGENT_RUNTIME_TMUX_SESSION", "fleet")
            .env("ORCH_OVERSEER_LANES", self.cap.to_string())
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
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
            json!({"stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\tpool=plan\trelaunch=resume\tpark=none\taccounts=none\tland=lane\tpane=local\n"})
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
/// the candidate (two lanes' projection, not three) and moves nothing but
/// the stamp of its wait for room; with the other lane ended it is admitted, its own
/// reservation left out of the judgement as the relaunch drops it, its
/// record carrying none after and the wait closed into its pauses.
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
    let mut held = fleet.lane("KEN-1");
    let wait = held.as_object_mut().unwrap().remove("capacity_wait");
    assert_eq!(
        held, before,
        "a refused relaunch moves nothing but its wait's stamp"
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
    let relaunched = fleet.lane("KEN-1");
    assert!(
        relaunched.get("reservation").is_none(),
        "the relaunch takes its own reservation's slot: {relaunched}"
    );
    assert_eq!(
        relaunched["pauses"],
        json!([{"from": wait.unwrap()["at"], "to": relaunched["session_since"], "cause": "capacity"}]),
        "an account with no room held the relaunch: {relaunched}"
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

/// A launch that asks for its account's room under a provider whose
/// `accounts` read fails, or is refused at the provider-call bound with
/// every slot held, is refused `account-unjudged`, naming the host and the
/// cause, and writes nothing; the same world answered admits it.
#[test]
fn a_launch_under_a_failed_or_busy_accounts_read_is_refused_and_writes_nothing() {
    let refused = "lane-host-fixture: accounts-refused";
    let cases = [
        (None, None),
        (
            Some(1),
            Some(format!(
                "account-unjudged step=host host={{host}} cause=host-accounts-unreadable host={{host}} exit=1 {refused}"
            )),
        ),
        (
            Some(0),
            Some(
                "account-unjudged step=host host={host} cause=host-busy count=1 cap=1 verb=accounts item=- step=accounts"
                    .to_owned(),
            ),
        ),
    ];
    for (exit, cause) in cases {
        let mut fleet = Fleet::new(4);
        fleet.init_fleet();
        fleet.plant_listing(&[listing_row(10, epoch_now())]);
        let host = fleet.state_dir().join("fleet-vm").display().to_string();
        let cause = cause.map(|c| c.replace("{host}", &host));
        match exit {
            Some(0) => {
                let held = hold_host_slots(&fleet.state_dir().join("home"));
                fleet.env.extend(held);
            }
            Some(exit) => {
                let path = fleet.state_dir().join("lane-host.json");
                let mut map: Value =
                    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
                map["fleet-vm accounts"] = json!({"exit": exit, "stderr": format!("{refused}\n")});
                std::fs::write(path, map.to_string()).unwrap();
            }
            None => {}
        }
        let out = fleet.op(&launch_on("KEN-3", fleet.state_dir()));
        let answer = reply(&out);
        let lanes = fleet.fleet()["lanes"].as_array().map_or(0, Vec::len);
        match cause {
            None => {
                assert_eq!(answer["ok"], true, "{}", stderr(&out));
                assert_eq!(lanes, 1);
            }
            Some(cause) => {
                assert_eq!(
                    answer["refusal"]["key"], "account-unjudged",
                    "{exit:?}: {answer}"
                );
                assert_eq!(refusal_fields(&answer)["cause"], cause, "{exit:?}");
                assert_eq!(lanes, 0, "{exit:?}: a refused launch writes no record");
            }
        }
    }
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
/// with a pending return and a counter retained.
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
        "cycles": 2,
    })
}

fn launch(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
        "model": "claude-fable-5-1",
        "class": CLASS,
        "class_reason": CLASS_REASON,
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
/// charges the cap, and the ended lane's record keeps every field; a stopped
/// lane whose harness runs holds its slot and refuses its own relaunch.
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
        "id": "launch-session:KEN-B:1-1",
        "op": "launch-session",
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

    // A stopped lane whose harness still runs holds its slot, and its own
    // relaunch is refused rather than doubling it; once it ends, the
    // relaunch replaces its own lane.
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let mut stopped = Owned::sleep();
    fleet.write_lanes(vec![record(
        "KEN-D",
        "stopped",
        Some(&stopped),
        fleet.state_dir(),
    )]);
    let answer = reply(&fleet.op(&launch("KEN-E", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "cap-reached", "{answer}");
    let answer = reply(&fleet.op(&launch("KEN-D", fleet.state_dir())));
    assert_eq!(answer["refusal"]["key"], "harness-live", "{answer}");
    end(&mut stopped);
    let answer = reply(&fleet.op(&launch("KEN-D", fleet.state_dir())));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(
        answer["result"]["persisted"]["report"]["admission"]["occupancy"],
        0
    );
}

/// Through the executable: a stopped lane's relaunch the cap refuses is a
/// wait from its first refusal to its admission. The first refusal stamps
/// `capacity_wait` at its own time and a later one leaves that stamp; each
/// prints the refusal a launch with no record prints, byte for byte, with
/// its exit. The admitted relaunch closes the wait into `pauses` with cause
/// `capacity`, ahead of the park the record ended on, and a lane never
/// refused carries neither.
#[test]
fn a_relaunch_held_for_the_cap_is_a_wait_from_its_first_refusal_to_its_admission() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let mut harness = Owned::sleep();
    let park =
        json!({"from": "2026-01-29T15:10:00Z", "to": "2026-01-29T15:20:00Z", "cause": "parked"});
    let mut held = record("KEN-B", "stopped", None, fleet.state_dir());
    held["pauses"] = json!([park]);
    fleet.write_lanes(vec![
        record("KEN-A", "running", Some(&harness), fleet.state_dir()),
        held,
        record("KEN-D", "stopped", None, fleet.state_dir()),
    ]);
    let before = fleet.lane("KEN-B");

    let from = epoch_now();
    let first = fleet.op(&launch("KEN-B", fleet.state_dir()));
    let to = epoch_now();
    assert_eq!(reply(&first)["refusal"]["key"], "cap-reached");
    let mut stamped = fleet.lane("KEN-B");
    let at = stamped
        .as_object_mut()
        .unwrap()
        .remove("capacity_wait")
        .expect("the first refusal stamps the wait");
    let at = clock::epoch_secs(at["at"].as_str().unwrap()).unwrap();
    assert!((from..=to).contains(&at), "stamped at its refusal: {at}");
    assert_eq!(stamped, before, "the stamp is all a refusal writes");

    // The stamp stands in for a first refusal earlier than this one.
    let mut doc = fleet.fleet();
    doc["lanes"][1]["capacity_wait"] = json!({"at": "2026-01-29T15:30:00Z"});
    std::fs::write(
        fleet.fleet_path(),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .unwrap();
    let second = fleet.op(&launch("KEN-B", fleet.state_dir()));
    assert_eq!(
        fleet.lane("KEN-B")["capacity_wait"],
        json!({"at": "2026-01-29T15:30:00Z"}),
        "a later refusal leaves the first stamp"
    );
    let fresh = fleet.op(&launch("KEN-C", fleet.state_dir()));
    assert!(
        stderr(&fresh).starts_with(
            "orch-runtime: cap-reached occupancy=1 cap=1 lanes=1 setting=ORCH_OVERSEER_LANES"
        ),
        "{}",
        stderr(&fresh)
    );
    for out in [&first, &second] {
        assert_eq!(
            (&out.status, &out.stdout, &out.stderr),
            (&fresh.status, &fresh.stdout, &fresh.stderr),
            "a held relaunch prints a fresh launch's refusal"
        );
    }

    end(&mut harness);
    let out = fleet.op(&launch("KEN-B", fleet.state_dir()));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let relaunched = fleet.lane("KEN-B");
    assert_eq!(relaunched.get("capacity_wait"), None, "{relaunched}");
    assert_eq!(
        relaunched["pauses"],
        json!([
            {"from": "2026-01-29T15:30:00Z", "to": relaunched["session_since"], "cause": "capacity"},
            park,
        ])
    );

    let out = fleet.op(&launch("KEN-D", fleet.state_dir()));
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let never = fleet.lane("KEN-D");
    assert_eq!(
        (never.get("pauses"), never.get("capacity_wait")),
        (None, None),
        "{never}"
    );
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
    let (command, run_dir) = validation_run(asking.state_dir());
    git_checkout(asking.state_dir());
    let archive_root = tempfile::tempdir().unwrap();
    let fleet = Fleet {
        env: vec![
            ("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()),
            (
                "ORCH_ARCHIVE_ROOT".to_owned(),
                archive_root.path().display().to_string(),
            ),
        ],
        ..asking
    };
    // The item's own files beside the fleet record: the close on the
    // tracker's verdict is the item's close-out too.
    // The item record is read as a record: the validation stop reads every
    // item of the state directory for a stage that admitted a run.
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-A.json");
    std::fs::write(&item_state, json!({"stages": []}).to_string()).unwrap();
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
    let archives = archive_root
        .path()
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
    assert!(
        run_stopped(&run_dir) && !live(command.pid()),
        "the worktree's validation run ended"
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
/// `launch-lane` writes: `tests/lane_model_recovery.sh` reads the
/// permission words off the record the fixture holds, and `tests/lane-state.sh` and
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
        ("AGENT_RUNTIME_TMUX_VERIFY_SECS", "0", "launch"),
        ("ORCH_LANE_CLOSE_SECS", "x", "launch"),
        ("AGENT_RUNTIME_LAUNCH_PERMISSION", "yes", "launch"),
        ("AGENT_RUNTIME_HARNESS_BINARIES", "claude", "launch"),
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

/// Through the executable: a validation step is the validation start's own
/// in-process request, so one sent to `op` is refused `request-invalid`
/// before any record is read or written.
#[test]
fn a_validate_step_sent_over_the_wire_is_refused_as_an_invalid_request() {
    let fleet = Fleet::new(4);
    let step = json!({"op": "validate", "step": "stop", "round_id": "r1", "run_dir": "/w/run"});
    let out = fleet.run(&["op", "--item", "KEN-1", "--request-json", &step.to_string()]);
    assert_ne!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(
        reply(&out)["refusal"]["key"],
        "request-invalid",
        "{}",
        stderr(&out)
    );
    assert_eq!(
        std::fs::read_dir(fleet.state_dir()).unwrap().count(),
        0,
        "nothing written"
    );
}

/// Through the executable: a launch whose repository is no `owner/name`
/// GitHub issues is refused `repo-invalid` naming it, and nothing is
/// written; one GitHub issues, in any case, is admitted.
#[test]
fn a_launch_naming_a_repository_github_never_issues_is_refused_before_any_record() {
    let fleet = Fleet::new(4);
    fleet.init_fleet();
    let before = fleet.fleet();
    for repo in ["o/..", "own_er/r", "o/r/x", "o"] {
        let mut request = launch("KEN-A", fleet.state_dir());
        request["repo"] = json!(repo);
        let answer = reply(&fleet.op(&request));
        assert_eq!(answer["refusal"]["key"], "repo-invalid", "{repo}: {answer}");
        assert_eq!(refusal_fields(&answer)["repo"], repo, "{repo}");
        assert_eq!(fleet.fleet(), before, "{repo}: a refusal writes nothing");
    }
    let mut request = launch("KEN-A", fleet.state_dir());
    request["repo"] = json!("O/r.x_y-z");
    let answer = reply(&fleet.op(&request));
    assert_ne!(answer["refusal"]["key"], "repo-invalid", "{answer}");
    assert_eq!(fleet.lane("KEN-A")["repo"], "O/r.x_y-z", "{answer}");
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
    doc["controller"] = json!({"server": "11", "pane": "%1", "server_start": null});
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
    let verbs: [(&str, &[&str]); 5] = [
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
            "lane pick",
            &[
                "lane",
                "pick",
                "--fleet",
                "--harness",
                "opencode",
                "--native-model",
                "m",
            ],
        ),
        (
            "lane walk source",
            &["lane", "walk", "--fleet", "--source-harness", "opencode"],
        ),
        (
            "lane walk caller",
            &["lane", "walk", "--fleet", "--caller-harness", "opencode"],
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
    let answer = reply(&preferring.run(&["lane", "walk", "--fleet"]));
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
            match model {
                Some(model) => request["model"] = json!(model),
                None => {
                    request.as_object_mut().unwrap().remove("model");
                }
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
    unnamed.as_object_mut().unwrap().remove("model");
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

/// `request` with its class and reason as `stated` names them, a member
/// left out where it names none.
fn stating(mut request: Value, (class, reason): (Option<&str>, Option<&str>)) -> Value {
    let members = request.as_object_mut().unwrap();
    for (key, value) in [("class", class), ("class_reason", reason)] {
        match value {
            Some(value) => members.insert(key.to_owned(), json!(value)),
            None => members.remove(key),
        };
    }
    request
}

/// Every launch states the class its assignment runs at and why. Through
/// the real `launch-lane` on a private server with the stub harness: a
/// first launch naming no class, no reason, one without the other, an
/// empty reason, a word that is no class word or a Claude family name, and
/// a relaunch naming neither over a record that names none, are each
/// refused `launch-class-missing` naming the item and the harness, before
/// any intent; a class word in any case is admitted and recorded as the
/// record spells it.
#[test]
fn a_launch_naming_no_class_or_reason_is_refused_before_any_intent() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let refused = |request: &Value, case: &str| {
        let before = runner.fleet();
        let answer = reply(&runner.op_fleet(request));
        assert_eq!(
            answer["refusal"]["key"], "launch-class-missing",
            "{case}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(
            (fields["item"].as_str(), fields["harness"].as_str()),
            (request["item"].as_str().unwrap(), "claude"),
            "{case}"
        );
        assert_eq!(runner.fleet(), before, "{case}: a refusal writes nothing");
    };
    let rows: [(Option<&str>, Option<&str>); 7] = [
        (None, None),
        (Some(CLASS), None),
        (None, Some(CLASS_REASON)),
        (Some(CLASS), Some("")),
        (Some(CLASS), Some("  ")),
        (Some("medium"), Some(CLASS_REASON)),
        (Some("opus"), Some(CLASS_REASON)),
    ];
    for stated in rows {
        refused(
            &stating(launch_request("KEN-C", &work), stated),
            &format!("{stated:?}"),
        );
    }
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([record("KEN-R", "stopped", None, &work)]);
    runner.write_fleet(&fleet);
    refused(
        &stating(launch_request("KEN-R", &work), (None, None)),
        "a relaunch over a record naming none",
    );
    let admitted = effect_report(&runner.op_fleet(&stating(
        launch_request("KEN-C", &work),
        (Some("Light"), Some("a one-file rename")),
    )));
    assert_eq!(admitted["intent"]["outcome"], "confirmed", "{admitted}");
    assert_eq!(
        (
            &admitted["lane"]["class"],
            &admitted["lane"]["class_reason"]
        ),
        (&json!("light"), &json!("a one-file rename"))
    );
}

/// An assignment keeps its class and reason through a relaunch. Through
/// the real `launch-lane` and close over the stub harness: a relaunch
/// naming neither runs at the record's class and reason, one naming a
/// class without its reason is refused `launch-class-missing`, and one
/// naming a pair replaces the record's when it confirms.
#[test]
fn a_relaunch_keeps_its_class_and_reason_and_a_named_pair_replaces_them() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let pair = |lane: &Value| (lane["class"].clone(), lane["class_reason"].clone());
    let light = (json!("light"), json!("a one-file rename"));
    let first = effect_report(&runner.op_fleet(&stating(
        launch_request("KEN-K", &work),
        (Some("light"), Some("a one-file rename")),
    )));
    assert_eq!(first["intent"]["outcome"], "confirmed", "{first}");
    assert_eq!(pair(&first["lane"]), light);
    effect_report(&runner.op_fleet(&terminal_close("KEN-K")));
    let kept =
        effect_report(&runner.op_fleet(&stating(launch_request("KEN-K", &work), (None, None))));
    assert_eq!(kept["intent"]["outcome"], "confirmed", "{kept}");
    assert_eq!(
        pair(&kept["lane"]),
        light,
        "the relaunch runs at the record's"
    );
    effect_report(&runner.op_fleet(&terminal_close("KEN-K")));
    let before = runner.fleet();
    let answer = reply(&runner.op_fleet(&stating(
        launch_request("KEN-K", &work),
        (Some(CLASS), None),
    )));
    assert_eq!(answer["refusal"]["key"], "launch-class-missing", "{answer}");
    assert_eq!(runner.fleet(), before, "a refusal writes nothing");
    let replaced = effect_report(&runner.op_fleet(&launch_request("KEN-K", &work)));
    assert_eq!(replaced["intent"]["outcome"], "confirmed", "{replaced}");
    assert_eq!(pair(&replaced["lane"]), (json!(CLASS), json!(CLASS_REASON)));
}

/// A launch naming no model runs the harness's default, which shows no
/// class. Through the real `launch-lane` on a private server, every harness
/// the stub: a launch naming no account and no model, or an empty one, on
/// each harness, and a relaunch naming neither model nor class over a
/// record whose class is `light`, are refused `class-unverified` naming the
/// class and the harness, before any intent; one naming an account and no
/// model keeps its `launch-model-missing`; a Claude launch naming the
/// class's alias is admitted.
#[test]
fn a_launch_whose_model_shows_no_class_is_refused_class_unverified() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    let stub = runner.stub.display().to_string();
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("claude={stub},codex={stub},copilot={stub},pi={stub}"),
    ));
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let accountless = |item: &str, harness: &str, model: Option<&str>| {
        let mut request = launch_request(item, &work);
        let members = request.as_object_mut().unwrap();
        members.remove("account");
        members.remove("effort");
        members.insert("harness".to_owned(), json!(harness));
        match model {
            Some(model) => members.insert("model".to_owned(), json!(model)),
            None => members.remove("model"),
        };
        request
    };
    let refused = |request: &Value, key: &str, class: &str| {
        let before = runner.fleet();
        let answer = reply(&runner.op_fleet(request));
        assert_eq!(answer["refusal"]["key"], key, "{request}: {answer}");
        if key == "class-unverified" {
            let fields = refusal_fields(&answer);
            assert_eq!(
                (fields["class"].as_str(), fields["harness"].as_str()),
                (class, request["harness"].as_str().unwrap()),
                "{request}"
            );
        }
        assert_eq!(
            runner.fleet(),
            before,
            "{request}: a refusal writes nothing"
        );
    };
    for harness in ["claude", "codex", "copilot", "pi"] {
        refused(
            &accountless("KEN-V", harness, None),
            "class-unverified",
            CLASS,
        );
        refused(
            &accountless("KEN-V", harness, Some("")),
            "class-unverified",
            CLASS,
        );
    }
    let mut on_account = launch_request("KEN-V", &work);
    on_account.as_object_mut().unwrap().remove("model");
    refused(&on_account, "launch-model-missing", CLASS);
    let mut fleet = runner.fleet();
    let mut record = record("KEN-R", "stopped", None, &work);
    record["class"] = json!("light");
    record["class_reason"] = json!("a one-file rename");
    fleet["lanes"] = json!([record]);
    runner.write_fleet(&fleet);
    refused(
        &stating(accountless("KEN-R", "claude", None), (None, None)),
        "class-unverified",
        "light",
    );
    let admitted = effect_report(&runner.op_fleet(&accountless("KEN-V", "claude", Some("opus"))));
    assert_eq!(admitted["intent"]["outcome"], "confirmed", "{admitted}");
}

/// A close that retires `item`'s attempt with no landing for `reason`,
/// interrupting its harness, a judged park where `park` is set.
fn retire(item: &str, reason: &str, park: bool) -> Value {
    let mut request = json!({
        "op": "close-owned-resources",
        "item": item,
        "no_landing": {"reason": reason, "source": "overseer", "interrupt": true},
    });
    if park {
        request["no_landing"]["park"] = json!({"pr": 12, "head": "h12"});
    }
    request
}

/// An attempt below `standard` retired with no landing for its outcome is
/// the item's miss. Through the real `launch-lane` and the real close over
/// the stub harness: a `light` or `fast` attempt the close retires for the
/// overseer's own reason, `keep-sandbox` among them, records
/// `class_missed` with the class, the reason and the close's time; one
/// retired for a model switch, a usage wall or a park, and a `standard`
/// attempt for any reason, records none.
#[test]
fn a_no_landing_close_below_standard_records_its_miss_unless_the_cause_is_outside_the_outcome() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let rows: [(&str, &str, &str, bool, bool); 6] = [
        ("KEN-M1", "light", "wrong-approach", false, true),
        ("KEN-M2", "fast", "keep-sandbox", false, true),
        ("KEN-M3", "light", "model-switch", false, false),
        ("KEN-M4", "light", "usage-limit", false, false),
        ("KEN-M5", "light", "wrong-approach", true, false),
        ("KEN-M6", "standard", "wrong-approach", false, false),
    ];
    for (item, class, reason, park, missed) in rows {
        let launched = effect_report(&runner.op_fleet(&stating(
            launch_request(item, &work),
            (Some(class), Some("a one-file rename")),
        )));
        assert_eq!(
            launched["intent"]["outcome"], "confirmed",
            "{item}: {launched}"
        );
        let closed = effect_report(&runner.op_fleet(&retire(item, reason, park)));
        assert_eq!(closed["intent"]["outcome"], "confirmed", "{item}: {closed}");
        let lane = &closed["lane"];
        assert_eq!(lane["status"], "stopped", "{item}");
        if missed {
            assert_eq!(
                (
                    &lane["class_missed"]["class"],
                    &lane["class_missed"]["cause"]
                ),
                (&json!(class), &json!(reason)),
                "{item}: {lane}"
            );
            assert_eq!(
                lane["class_missed"]["at"], closed["intent"]["completed_at"],
                "{item}"
            );
        } else {
            assert_eq!(lane.get("class_missed"), None, "{item}: {lane}");
        }
    }
}

/// After its miss an item runs at `standard` or above. Through the real
/// `launch-lane` over the stub harness: a relaunch below `standard`, the
/// record's class kept or `fast` named, is refused `launch-class-missed`
/// naming the item, the missed class and its cause, before any intent; one
/// at `standard` is admitted and its confirmation clears the miss, after
/// which a launch at `light` runs again.
#[test]
fn a_launch_below_standard_after_its_miss_is_refused_until_one_at_standard_confirms() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let light = (Some("light"), Some("a one-file rename"));
    let launched = effect_report(&runner.op_fleet(&stating(launch_request("KEN-X", &work), light)));
    assert_eq!(launched["intent"]["outcome"], "confirmed", "{launched}");
    effect_report(&runner.op_fleet(&retire("KEN-X", "wrong-approach", false)));
    for stated in [(None, None), (Some("fast"), Some("a typo"))] {
        let before = runner.fleet();
        let answer = reply(&runner.op_fleet(&stating(launch_request("KEN-X", &work), stated)));
        assert_eq!(
            answer["refusal"]["key"], "launch-class-missed",
            "{stated:?}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(
            (
                fields["item"].as_str(),
                fields["class"].as_str(),
                fields["cause"].as_str()
            ),
            ("KEN-X", "light", "wrong-approach"),
            "{stated:?}"
        );
        assert_eq!(
            runner.fleet(),
            before,
            "{stated:?}: a refusal writes nothing"
        );
    }
    let standard = effect_report(&runner.op_fleet(&launch_request("KEN-X", &work)));
    assert_eq!(standard["intent"]["outcome"], "confirmed", "{standard}");
    assert_eq!(standard["lane"]["class"], json!(CLASS));
    assert_eq!(standard["lane"].get("class_missed"), None, "{standard}");
    effect_report(&runner.op_fleet(&terminal_close("KEN-X")));
    let again = effect_report(&runner.op_fleet(&stating(launch_request("KEN-X", &work), light)));
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
}

/// Through the executable: a `no-landing` disposition on a lane
/// whose recorded harness is gone retires the attempt and keeps the item's
/// work: the lane reads stopped with its pending return, parked record,
/// launch, recovery route and counter, the log row carries the disposition,
/// and the retired
/// attempt charges nothing.
#[test]
fn a_no_landing_disposition_retires_the_attempt_and_keeps_the_work() {
    let fleet = Fleet::new(1);
    fleet.init_fleet();
    let mut harness = Owned::sleep();
    let mut lane = record("KEN-A", "running", Some(&harness), fleet.state_dir());
    lane["parked"] = json!({"head": "abc", "repo": "o/r", "at": "2026-10-24T20:00:00Z"});
    fleet.write_lanes(vec![lane]);
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
        .env("AGENT_RUNTIME_TMUX_SESSION", "fleet")
        .env("ORCH_OVERSEER_LANES", fleet.cap.to_string())
        .env(
            "LANE_MAIL_CLI",
            fixtures().join("lane-mail-quiet/lane-mail"),
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
/// `--archive` path, its `records.json` declaring the item's record the
/// `state` member and every other path `along`, and the directory's own
/// retention ran, since no watch
/// runs it there, taking another item's expired record.
#[test]
fn state_remove_takes_the_items_files_after_their_archive_and_leaves_its_siblings() {
    let archive_root = tempfile::tempdir().unwrap();
    let fleet = Fleet {
        env: vec![(
            "ORCH_ARCHIVE_ROOT".to_owned(),
            archive_root.path().display().to_string(),
        )],
        ..Fleet::new(1)
    };
    let dir = fleet.state_dir();
    git_checkout(dir);
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
    let record = format!(
        "{}/records.json",
        relative(&kept).strip_suffix(".tgz").unwrap()
    );
    let out = program("tar")
        .args(["-xzOf", &kept.display().to_string(), &record])
        .output()
        .unwrap();
    assert!(out.status.success(), "{record}: {}", stderr(&out));
    let declared: Value = serde_json::from_slice(&out.stdout).unwrap();
    let mut members: Vec<(String, String)> = declared["members"]
        .as_array()
        .unwrap_or_else(|| panic!("{declared}"))
        .iter()
        .map(|m| {
            (
                m["path"].as_str().unwrap().to_owned(),
                m["role"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    members.sort();
    let mut want: Vec<(String, String)> = [
        ("workflow-state-KEN-A.json", "state"),
        ("handoffs/KEN-A-handoff.md", "along"),
        ("KEN-A.run", "along"),
        ("lane-status-KEN-A.md", "along"),
        ("lane-mail/KEN-A", "along"),
    ]
    .iter()
    .map(|(rel, role)| (format!("{}/{rel}", relative(dir)), (*role).to_owned()))
    .chain([(relative(&dir.join("extra/tmp")), "along".to_owned())])
    .collect();
    want.sort();
    assert_eq!(members, want, "each packed path declared with its role");
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
    let archive_root = tempfile::tempdir().unwrap();
    let fleet = Fleet {
        env: vec![(
            "ORCH_ARCHIVE_ROOT".to_owned(),
            archive_root.path().display().to_string(),
        )],
        ..Fleet::new(1)
    };
    let dir = fleet.state_dir();
    git_checkout(dir);
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

    /// The tracker's answer for `item`: its state type, and an item with no
    /// open Done-when box past the lane's own completion, so a close owes
    /// its boxes nothing.
    fn plant_tracker(&self, item: &str, state: &str) {
        let name = if state == "completed" {
            "Done"
        } else {
            "Verifying"
        };
        let reply = json!({
            "issues bulk-get": {"body": {"issues": {"nodes": [
                {"identifier": item, "state": {"type": state}, "description": "", "children": {"nodes": []}}
            ]}}},
            "graphql BoxItem": {"body": {"issue": {"description": "", "state": {"name": name, "type": state}}}},
        });
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
        "cycle": {"pr": 7}, "repo": "o/r",
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
/// the record's host. The provider's close answer and its `list` after it
/// decide the close: an archive line or `closed=absent` with no row listed
/// for the item, or only an `available` one, closes the lane with that line
/// on the observation, none reads `kept=none`; a row still listed holds the
/// close `standing` with the row's state, a list that fails holds it
/// `unconfirmed`; a refusal, a failure or no answer of the close itself
/// leaves the lane running and the close unconfirmed with what it read, no
/// list asked, the item's files already gone.
#[test]
fn a_hosted_close_stops_through_its_provider_and_closes_its_sandbox_after_the_items_files() {
    let rows: [CloseCase; 9] = [
        ("kept", &[], "closed", "kept=/srv/archive/KEN-1", "done"),
        (
            "listed standing",
            &[("LIST", "o/r/KEN-1\thosted\t-\tlane.example")],
            "unconfirmed",
            "standing",
            "running",
        ),
        (
            "list failed",
            &[("LIST_STATUS", "1")],
            "unconfirmed",
            "unconfirmed",
            "running",
        ),
        (
            "listed available",
            &[("LIST", "o/r/KEN-1\tavailable\t-\tlane.example")],
            "closed",
            "kept=/srv/archive/KEN-1",
            "done",
        ),
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
        if case == "listed standing" {
            assert_eq!(result["observation"]["listed"], "hosted", "{result}");
            assert_eq!(
                result["observation"]["closed"], "kept=/srv/archive/KEN-1",
                "{result}"
            );
        }
        assert_eq!(fleet.lane("KEN-1")["status"], status, "{case}");
        assert!(
            std::fs::symlink_metadata(&item_state).is_err(),
            "{case}: the item's files left before the provider's close"
        );
        let mut calls = RUNNING_CLOSE.to_vec();
        if !matches!(case, "refused" | "failed" | "unanswered") {
            calls.push("list");
        }
        assert_eq!(fleet.provider_calls(), calls, "{case}");
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

/// A merged hosted lane whose clone left its host closes all the same: the
/// provider answers `status` and `stop` as it does with no clone, each
/// refused `<verb>-unowned` with status 75, its `close` `closed=absent`,
/// and its `list` names no row for the item; the close skips the stop it
/// cannot make, ends the lane `done` with that line, and the item's files
/// leave once the archive under the configured root holds them.
#[test]
fn a_hosted_close_over_a_gone_clone_ends_done_with_the_items_files_archived_and_removed() {
    let archive_root = tempfile::tempdir().unwrap();
    let mut fleet = Fleet::hosted(4);
    fleet.env.push((
        "ORCH_ARCHIVE_ROOT".to_owned(),
        archive_root.path().display().to_string(),
    ));
    git_checkout(fleet.state_dir());
    gone_clone(&mut fleet, hosted_lane("KEN-1"));
    fleet.plant_tracker("KEN-1", "completed");
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let held = relative(&item_state);
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["ok"], true, "{answer}");
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{result}");
    assert_eq!(
        result["observation"]["host_close"], "closed=absent item=KEN-1",
        "{result}"
    );
    assert!(
        result["notes"].as_array().unwrap().contains(&json!(
            "stop-skipped item=KEN-1 harness=claude cause=unowned"
        )),
        "{result}"
    );
    assert_eq!(fleet.lane("KEN-1")["status"], "done");
    assert!(
        std::fs::symlink_metadata(&item_state).is_err(),
        "the item's files left"
    );
    let mut tarballs = Vec::new();
    for project in std::fs::read_dir(archive_root.path()).unwrap() {
        let oversee = project.unwrap().path().join("oversee");
        for entry in std::fs::read_dir(oversee).unwrap() {
            tarballs.push(entry.unwrap().path());
        }
    }
    assert_eq!(tarballs.len(), 1, "{tarballs:?}");
    assert!(
        archived(&tarballs[0]).contains(&held),
        "the archive holds {held}"
    );
    assert_eq!(
        fleet.provider_calls(),
        [
            "status --item KEN-1 --harness claude",
            "cat --item KEN-1 /w/ken-1/.git",
            "touch --item KEN-1",
            "stop --item KEN-1 --harness claude",
            "close --item KEN-1 --merged",
            "list",
        ]
    );
}

/// An unmerged hosted lane whose clone left its host closes as an exited
/// one does: the provider's `status-unowned` refusal is no lane to judge,
/// the stop it cannot make is skipped, and the canceled item's files leave
/// before the provider's close answers `closed=absent`.
#[test]
fn an_unmerged_hosted_close_over_a_gone_clone_ends_done_with_the_items_files_removed() {
    let mut fleet = Fleet::hosted(4);
    let mut unmerged = hosted_lane("KEN-1");
    unmerged.as_object_mut().unwrap().remove("cycle");
    gone_clone(&mut fleet, unmerged);
    fleet.plant_tracker("KEN-1", "canceled");
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["ok"], true, "{answer}");
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{result}");
    assert_eq!(
        result["observation"]["host_close"], "closed=absent item=KEN-1",
        "{result}"
    );
    assert!(
        result["notes"].as_array().unwrap().contains(&json!(
            "stop-skipped item=KEN-1 harness=claude cause=unowned"
        )),
        "{result}"
    );
    assert_eq!(fleet.lane("KEN-1")["status"], "done");
    assert!(
        std::fs::symlink_metadata(&item_state).is_err(),
        "the item's files left"
    );
    assert_eq!(
        fleet.provider_calls(),
        [
            "status --item KEN-1 --harness claude",
            "stop --item KEN-1 --harness claude",
            "close --item KEN-1",
            "list",
        ]
    );
}

/// `lane`, the fleet's one record, on a provider that answers as the real
/// one does once the lane's clone left its host: `status` and `stop`
/// refused `<verb>-unowned` with status 75, `close` `closed=absent`, and a
/// `list` naming no row for the item; every other verb the fixture's.
fn gone_clone(fleet: &mut Fleet, mut lane: Value) {
    fleet.answer("CLOSE_LINE", "closed=absent item=KEN-1");
    fleet.answer("LIST", "");
    let gone = fleet.state_dir().join("gone-clone-provider");
    write_executable(
        &gone,
        format!(
            "#!/bin/bash\ncase \"$1\" in\nstatus|stop)\n  printf '%q ' \"$@\" >> \"$LANE_HOST_STUB_LOG\"\n  printf '\\n' >> \"$LANE_HOST_STUB_LOG\"\n  printf 'lane-host-ssh: %s-unowned item=%s\\n' \"$1\" \"$3\" >&2\n  exit 75 ;;\nesac\nexec '{}' \"$@\"\n",
            provider()
        ),
    );
    lane["host"] = json!(gone.display().to_string());
    fleet.write_lanes(vec![lane]);
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
    let calls = fleet.provider_calls();
    assert_eq!(
        calls[calls.len().saturating_sub(2)..],
        ["close --item KEN-1", "list"]
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
/// `.git` names, both read on the provider's disk: with the record
/// standing the close refuses `pane-missing` and stops nothing; with it
/// removed the lane ends on the merge, its harness stopped and the
/// provider's close asked; a record the host cannot read refuses
/// `worktree-read-failed` with the provider's cause, and a read refused at
/// the provider-call bound with every slot held refuses `host-busy`,
/// asking the provider nothing.
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
            Some("held"),
            Some((
                "host-busy",
                Some("cat host-busy count=1 cap=1 verb=cat item=KEN-1"),
            )),
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
        match cat_status {
            Some("held") => {
                let held = hold_host_slots(&fleet.state_dir().join("home"));
                fleet.env.extend(held);
            }
            Some(status) => {
                fleet.answer("CAT_STATUS", status);
                fleet.answer("CAT_PATH", RECORD);
            }
            None => {}
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "started");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let calls = fleet.provider_calls();
        if cat_status == Some("held") {
            assert!(calls.is_empty(), "{case}: nothing ran: {calls:?}");
        } else {
            assert!(
                calls.contains(&format!("cat --item KEN-1 {RECORD}")),
                "{case}: the record is read in the clone: {calls:?}"
            );
        }
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
                    calls[calls.len().saturating_sub(2)..],
                    ["close --item KEN-1", "list"],
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
    state["controller"] = json!({"server_socket": controller.socket.display().to_string()});
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
/// provider, the record reads stopped with its work kept, its sandbox
/// standing and no park owed.
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
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "stopped");
    assert_eq!(lane["cycle"], json!({"pr": 7}));
    assert_eq!(lane["sandbox"], "standing", "{lane}");
    assert!(lane.get("park_owed").is_none(), "{lane}");
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

    // GitHub reads a repository's name without case: a record naming `O/R`
    // closes under a request naming `o/r`, its own spelling kept.
    let mut fleet = Fleet::hosted(4);
    fleet.answer("HARNESS_STATE", "exited");
    fleet.write_lanes(vec![with("repo", json!("O/R"))]);
    fleet.plant_tracker("KEN-1", "completed");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1", "repo": "o/r"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    assert_eq!(fleet.lane("KEN-1")["repo"], "O/R");
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

/// A hosted lane's wall is weighed against its account read under the
/// record's host. A Claude lane on the fixture provider whose captured pane
/// shows a usage banner naming no reset ahead, its item ended by its
/// tracker, its account at room on this machine's listing, while the
/// provider's `accounts` read fails or answers busy: the read is unjudged,
/// the wall kept, refused `lane-live state=walled account=read-failed`, the
/// record running, the provider asked for its accounts and for no stop and
/// no close.
#[test]
fn a_stale_wall_under_a_failed_or_busy_accounts_read_keeps_the_lane_and_stops_nothing() {
    for status in ["1", "69"] {
        let mut fleet = Fleet::verb_pane(&format!(
            "⏺ Working through the queue.\n{CLOCK_WALL}\nRun /usage-credits to raise it\n❯\u{a0}\n"
        ));
        fleet.answer("ACCOUNTS_STATUS", status);
        let state = fleet.state_dir().to_path_buf();
        let now = epoch_now();
        let env = plant_accounts(&state, &state, None, &[listing_row(20, now)], now);
        fleet.env.extend(env);
        let mut lane = without("cycle");
        lane["account"] = json!(state.join("home/.aclaude").display().to_string());
        fleet.write_lanes(vec![lane]);
        fleet.plant_tracker("KEN-1", "completed");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let fields = [
            ("item", "KEN-1"),
            ("state", "walled"),
            ("window", "fleet:KEN-1"),
            ("account", "read-failed"),
        ];
        assert_eq!(
            answer,
            json!({
                "protocol": "orch-runtime-v1",
                "ok": false,
                "refusal": {
                    "key": "lane-live",
                    "fields": fields,
                    "text": format!("refused lane-live: {fields:?}"),
                },
            }),
            "{status}"
        );
        assert_eq!(fleet.lane("KEN-1")["status"], "running", "{status}");
        let calls = fleet.provider_calls();
        assert!(calls.iter().any(|c| c == "accounts"), "{status}: {calls:?}");
        assert!(
            !calls
                .iter()
                .any(|c| c.starts_with("stop ") || c.starts_with("close ")),
            "{status}: {calls:?}"
        );
    }
}

/// One close-lane case over a hosted world: the records, the provider's
/// answers, the world's environment, the tracker's state type (`None`
/// plants no answer), the request, and the provider-call slots under the
/// world's own home bound to one call: every slot held from the start
/// (`Held`), or held by the close itself once the provider answered the
/// verb named (`After`).
struct CloseCase2 {
    name: &'static str,
    lanes: Vec<Value>,
    answers: Vec<(&'static str, &'static str)>,
    env: Vec<(&'static str, &'static str)>,
    tracker: Option<&'static str>,
    request: Value,
    slots: Option<Slots>,
}

#[derive(Clone, Copy)]
enum Slots {
    Held,
    After(&'static str),
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
            slots: None,
        }
    }

    fn run(&self) -> (Fleet, Value) {
        let mut fleet = Fleet::hosted(4);
        for (name, value) in &self.answers {
            fleet.answer(name, value);
        }
        let home = fleet.state_dir().join("home");
        match self.slots {
            Some(Slots::Held) => fleet.env.extend(hold_host_slots(&home)),
            Some(Slots::After(verb)) => {
                fleet.env.extend(host_slot_bound(&home));
                fleet.answer("HOLD_AFTER", verb);
            }
            None => {}
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
            "host-busy",
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
            "host-busy",
            vec![],
        ),
        (
            CloseCase2::new("provider stop refused", vec![hosted_lane("KEN-1")]),
            "stop-failed",
            vec![("cause", "provider"), ("status", "1")],
        ),
        (
            CloseCase2::new("provider stop busy", vec![hosted_lane("KEN-1")]),
            "stop-failed",
            vec![("cause", "provider"), ("status", "75")],
        ),
        (
            CloseCase2::new("provider stop unparsed", vec![hosted_lane("KEN-1")]),
            "stop-failed",
            vec![("cause", "answer-unparsed")],
        ),
        (
            CloseCase2::new("provider stop capped", vec![hosted_lane("KEN-1")]),
            "host-busy",
            vec![("step", "stop")],
        ),
        (
            CloseCase2::new("list capped", vec![hosted_lane("KEN-1")]),
            "host-busy",
            vec![("step", "list")],
        ),
        (
            // Unmerged: a merged lane whose work left its host closes
            // whatever its screen reads.
            CloseCase2::new("provider status unread", vec![without("cycle")]),
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
                case.slots = Some(Slots::Held);
                case.tracker = Some("started");
            }
            "provider stop refused" => case.answers.push(("STOP_STATUS", "1")),
            // Status 75 is no lane of the item only beside its own line.
            "provider stop busy" => {
                case.answers.push(("STOP_STATUS", "75"));
                case.answers.push((
                    "STOP_ERROR",
                    "lane-host-ssh: ownership-busy target=lane.example clone=/srv/clone exit=75",
                ));
            }
            "provider stop unparsed" => case.answers.push(("STOP_LINE", "stopped")),
            "provider stop capped" => case.slots = Some(Slots::After("status")),
            "list capped" => {
                case.env.push(("LANE_MAIL_STATUS", "2"));
                case.slots = Some(Slots::After("status"));
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
/// tracker's word alone, for a record parked on its own ask too, which
/// waits on no pull request; a stopped or parked record's full close on a
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
    let mut ask_parked = with("status", json!("parked"));
    ask_parked["parked"] =
        json!({"repo": "o/r", "head": "h2", "at": "2026-01-29T16:00:00Z", "ask": "a1"});
    let mut rows = vec![
        (
            CloseCase2::new("ask parked, terminal state", vec![ask_parked]),
            "state",
            "parked",
            vec![],
        ),
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
            vec!["close --item KEN-1 --merged", "list"],
        ),
        (
            CloseCase2::new("parked", vec![parked_lane.clone()]),
            "closed",
            "done",
            vec!["close --item KEN-1 --merged", "list"],
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
                "list",
            ],
        ),
    ];
    for (case, _, _, _) in &mut rows {
        match case.name {
            "terminal state" | "ask parked, terminal state" => {
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
            "terminal state" | "ask parked, terminal state" => {
                assert_eq!(answer["result"]["state"], "completed", "{}", case.name);
            }
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

/// close-lane reads Linear's state type `duplicate` as it reads `canceled`:
/// on a parked record `terminal-state` answers `canceled`, and `if-terminal`
/// closes the lane with the same provider calls a canceled item's close makes.
#[test]
fn close_lane_reads_a_duplicate_item_as_a_canceled_one() {
    let mut parked = with("status", json!("parked"));
    parked["parked"] =
        json!({"repo": "o/r", "head": "h2", "at": "2026-01-29T16:00:00Z", "ask": "a1"});
    let mut closes = Vec::new();
    for kind in ["canceled", "duplicate"] {
        let mut state = CloseCase2::new("terminal state", vec![parked.clone()]);
        state.tracker = Some(kind);
        state.request = json!({"op": "close-lane", "item": "KEN-1", "mode": "terminal-state"});
        let (_, answer) = state.run();
        assert_eq!(answer["result"]["word"], "state", "{kind}: {answer}");
        assert_eq!(answer["result"]["state"], "canceled", "{kind}: {answer}");
        let mut close = CloseCase2::new("if terminal", vec![parked.clone()]);
        close.tracker = Some(kind);
        close.request = json!({"op": "close-lane", "item": "KEN-1", "mode": "if-terminal"});
        let (fleet, answer) = close.run();
        assert_eq!(answer["result"]["word"], "closed", "{kind}: {answer}");
        assert_eq!(fleet.lane("KEN-1")["status"], "done", "{kind}");
        closes.push(fleet.provider_calls());
    }
    assert_eq!(closes[0], closes[1], "the same close for both");
}

/// The lane's one open ask, as the mailbox's `pending` lists it.
const ASK_A1: &str = r#"{"kind":"ask","id":"a1"}"#;

/// The pull request a park of KEN-1 reads on `o/r` (number 7, or a
/// dependency's), open, armed and clean on the lane's head and branch.
fn park_pull() -> Value {
    json!({"state": "OPEN", "headRefOid": "h2", "headRefName": "ken-1",
        "autoMergeRequest": {"enabledAt": "2026-01-29T16:00:00Z"}, "mergeStateStatus": "CLEAN",
        "isInMergeQueue": false, "mergeQueueEntry": null})
}

impl Fleet {
    /// A hosted world a park of KEN-1 is judged in: the lane's linked
    /// worktree on the provider's disk at head `h2` on `ken-1`, pushed to
    /// `origin`, with its clean status file, the `gh` fixture first on `PATH` answering the
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
        fleet.disk("/w/main/.git/refs/remotes/origin/ken-1", "h2\n");
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

/// A park is admitted by its pull request or by the lane's own oldest open
/// ask, judged before anything is signalled: the provider's sandbox check,
/// the ask it names the open one (a pull request's park refuses any open
/// ask `ask-unanswered`), the pull request open on the
/// lane's own head and branch (read through the provider's `cat`, loose or
/// packed, else the item's recorded branch), a head read there named by the
/// sandbox's `origin` remote-tracking ref, its clean status file bound to
/// that head, the queue or an armed and clean merge, and the reducer silent
/// on it; a dependency park reads the dependency in its own repository,
/// which the fleet must watch, and none of the lane's own checks. Each
/// refusal names its reason and stops nothing; an admitted park stops the
/// harness through the provider, then the sandbox, and records the park; a
/// sandbox stop that fails leaves the record stopped with its sandbox
/// standing and the park owed.
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
        // A head its sandbox's remote-tracking ref does not name would be
        // stranded with the agent that can push it stopped.
        (
            "a dependency, head unpushed",
            park(json!({"until_pr": 9, "until_repo": "o/r"})),
            |f| {
                f.disk("/w/main/.git/refs/remotes/origin/ken-1", "h1\n");
                f.plant_pull(9, park_pull());
            },
            Some("unpushed"),
        ),
        (
            "a dependency, no remote branch",
            park(json!({"until_pr": 9, "until_repo": "o/r"})),
            |f| {
                f.undisk("/w/main/.git/refs/remotes/origin/ken-1");
                f.plant_pull(9, park_pull());
            },
            Some("unpushed"),
        ),
        (
            "the sandbox stop refused",
            park(json!({"pr": 7})),
            |f| f.answer("SANDBOX_STOP_STATUS", "1"),
            Some("park-failed"),
        ),
        // A park on the lane's own open ask reads no pull request; one
        // naming another ask, and a pull request's park beside an open ask,
        // stop nothing.
        (
            "an ask park on the open ask",
            park(json!({"ask": "a1"})),
            |f| f.env.push(("LANE_MAIL_ASKS".to_owned(), ASK_A1.to_owned())),
            None,
        ),
        (
            "an ask park on another ask",
            park(json!({"ask": "a2"})),
            |f| f.env.push(("LANE_MAIL_ASKS".to_owned(), ASK_A1.to_owned())),
            Some("ask-not-open"),
        ),
        (
            "a pull request's park beside an open ask",
            park(json!({"pr": 7})),
            |f| f.env.push(("LANE_MAIL_ASKS".to_owned(), ASK_A1.to_owned())),
            Some("ask-unanswered"),
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
                assert!(lane.get("sandbox").is_none(), "{case}: {lane}");
                assert!(lane.get("park_owed").is_none(), "{case}: {lane}");
                if case == "a watched dependency" {
                    assert_eq!(lane["parked"]["until_repo"], "other/repo", "{case}: {lane}");
                }
                if case == "an ask park on the open ask" {
                    assert_eq!(lane["parked"]["ask"], "a1", "{case}: {lane}");
                    assert!(lane["parked"].get("pr").is_none(), "{case}: {lane}");
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
                let lane = fleet.lane("KEN-1");
                assert_eq!(lane["status"], "stopped", "{case}");
                assert_eq!(lane["sandbox"], "standing", "{case}: {lane}");
                assert_eq!(
                    lane["park_owed"],
                    json!({"pr": 7, "head": "h2"}),
                    "{case}: {lane}"
                );
            }
            Some("ask-unanswered") => {
                assert_eq!(
                    answer["refusal"]["key"], "ask-unanswered",
                    "{case}: {answer}"
                );
                assert!(!stopped, "{case}: nothing is signalled: {calls:?}");
                assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
            }
            Some(reason) => {
                assert_eq!(answer["refusal"]["key"], "park-refused", "{case}: {answer}");
                assert_eq!(
                    refusal_fields(&answer)["reason"],
                    reason,
                    "{case}: {answer}"
                );
                if reason == "unpushed" {
                    let fields = refusal_fields(&answer);
                    let remote = if case.ends_with("no remote branch") {
                        "absent"
                    } else {
                        "h1"
                    };
                    assert_eq!(fields["head"], "h2", "{case}: {answer}");
                    assert_eq!(fields["remote"], remote, "{case}: {answer}");
                }
                if reason == "ask-not-open" {
                    let fields = refusal_fields(&answer);
                    assert_eq!(fields["ask"], "a2", "{case}: {answer}");
                    assert_eq!(fields["open"], "a1", "{case}: {answer}");
                }
                assert!(!stopped, "{case}: nothing is signalled: {calls:?}");
                assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
            }
        }
    }
}

/// A park asked of a stopped record writes the park owed before its sandbox
/// stop: a kept sandbox whose stop the provider refuses as still stopping
/// (no `sandbox-stopped` line) stays stopped and standing with the park
/// owed; the same park asked again over a sandbox already down, answered
/// by its `sandbox-stopped` line, parks and clears both marks.
#[test]
fn a_park_of_a_kept_sandbox_whose_stop_fails_stays_owed_until_a_park_confirms() {
    let mut fleet = Fleet::park_world();
    let mut kept = with("repo", json!("o/r"));
    kept["status"] = json!("stopped");
    kept["sandbox"] = json!("standing");
    fleet.write_lanes(vec![kept]);
    fleet.plant_tracker("KEN-1", "started");
    let park = json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}});
    fleet.answer("SANDBOX_STOP_STATUS", "3");
    let refused = fleet.close(park.clone());
    assert_eq!(refused["refusal"]["key"], "park-failed", "{refused}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "stopped", "{lane}");
    assert_eq!(lane["sandbox"], "standing", "{lane}");
    assert_eq!(lane["park_owed"], json!({"pr": 7, "head": "h2"}), "{lane}");
    fleet
        .env
        .retain(|(name, _)| name != "LANE_HOST_STUB_SANDBOX_STOP_STATUS");
    let parked = fleet.close(park);
    assert_eq!(parked["result"]["word"], "parked", "{parked}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "parked", "{lane}");
    assert!(lane.get("park_owed").is_none(), "{lane}");
    assert!(lane.get("sandbox").is_none(), "{lane}");
}

/// A park a stopped record owes is confirmed by its provider's sandbox stop
/// alone: over a sandbox already down, whose provider refuses every `cat`,
/// `touch` and mailbox read, the owed park asks none of them nor the stop's
/// check. It reads GitHub again, so a pull request merged, or moved to
/// another head, while the park is owed refuses with nothing stopped; once
/// the stop confirms, the record parks on the head judged when the park was
/// first asked; a park owed on the lane's own ask parks the same way. A park
/// naming another wait is not owed and is judged in full, so it is refused
/// at its mailbox read.
#[test]
fn an_owed_park_over_a_sandbox_already_down_is_confirmed_by_the_providers_stop_alone() {
    let mut fleet = Fleet::park_world();
    fleet.write_lanes(vec![with("repo", json!("o/r"))]);
    fleet.plant_tracker("KEN-1", "started");
    let park = json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}});
    let owed = json!({"pr": 7, "head": "h2"});
    let sandbox_stops = |fleet: &Fleet| {
        fleet
            .provider_calls()
            .iter()
            .filter(|c| *c == "stop-sandbox --item KEN-1")
            .count()
    };
    // A running lane's park whose sandbox stop the provider refuses as
    // still stopping.
    fleet.answer("SANDBOX_STOP_STATUS", "1");
    let refused = fleet.close(park.clone());
    assert_eq!(refused["refusal"]["key"], "park-failed", "{refused}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "stopped", "{lane}");
    assert_eq!(lane["sandbox"], "standing", "{lane}");
    assert_eq!(lane["park_owed"], owed, "{lane}");
    let provider_from = fleet.provider_calls().len();
    let mail_from = fleet.mail_log().len();
    // The provider's answers over a sandbox already down: each `cat`
    // refused `lane-stopped` with exit 4, its `touch` probe the same, the
    // mailbox's host read refused; its check answers.
    fleet.answer("CAT_STATUS", "4");
    fleet.answer("CAT_STATE", "stopped");
    fleet.answer("TOUCH_STATUS", "4");
    fleet
        .env
        .push(("LANE_MAIL_STATUS".to_owned(), "2".to_owned()));
    let stopping = fleet.close(park.clone());
    assert_eq!(stopping["refusal"]["key"], "park-failed", "{stopping}");
    assert_eq!(fleet.lane("KEN-1")["park_owed"], owed);
    let mail = fleet.mail_log();
    assert!(
        !mail[mail_from..].iter().any(|l| l.contains("pending")),
        "{mail:?}"
    );
    let other = fleet.close(json!({"op": "close-lane", "item": "KEN-1",
        "mode": {"park": {"until_pr": 9, "until_repo": "o/r"}}}));
    assert_eq!(other["refusal"]["key"], "mail-read-failed", "{other}");
    assert_eq!(fleet.lane("KEN-1")["park_owed"], owed);
    let mail_from = fleet.mail_log().len();
    let stops = sandbox_stops(&fleet);
    for (field, value, reason) in [
        ("state", json!("MERGED"), "pr-not-open"),
        ("headRefOid", json!("h1"), "pr-head-mismatch"),
    ] {
        let mut pull = park_pull();
        pull[field] = value;
        fleet.plant_pull(7, pull);
        let answer = fleet.close(park.clone());
        assert_eq!(
            answer["refusal"]["key"], "park-refused",
            "{reason}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(fields["reason"], reason, "{answer}");
        if reason == "pr-head-mismatch" {
            assert_eq!(fields["branch-source"], "park-owed", "{answer}");
        }
        assert_eq!(fleet.lane("KEN-1")["park_owed"], owed, "{reason}");
        assert_eq!(sandbox_stops(&fleet), stops, "{reason}: nothing is stopped");
    }
    fleet.plant_pull(7, park_pull());
    fleet
        .env
        .retain(|(name, _)| name != "LANE_HOST_STUB_SANDBOX_STOP_STATUS");
    let parked = fleet.close(park);
    assert_eq!(parked["result"]["word"], "parked", "{parked}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "parked", "{lane}");
    assert_eq!(lane["parked"]["head"], "h2", "{lane}");
    assert!(lane.get("park_owed").is_none(), "{lane}");
    assert!(lane.get("sandbox").is_none(), "{lane}");
    // A park owed on the lane's own ask, its mark as its judge wrote it:
    // the ask was read then, so the down mailbox is not read again.
    let mut asking = with("repo", json!("o/r"));
    asking["status"] = json!("stopped");
    asking["sandbox"] = json!("standing");
    asking["park_owed"] = json!({"ask": "a1", "head": "h2"});
    fleet.write_lanes(vec![asking]);
    let parked =
        fleet.close(json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"ask": "a1"}}}));
    assert_eq!(parked["result"]["word"], "parked", "{parked}");
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["parked"]["ask"], "a1", "{lane}");
    assert_eq!(lane["parked"]["head"], "h2", "{lane}");
    assert!(lane.get("park_owed").is_none(), "{lane}");
    let calls = fleet.provider_calls();
    assert!(
        !calls[provider_from..].iter().any(|c| c.starts_with("cat ")
            || c.starts_with("touch ")
            || c.starts_with("stop-sandbox --check ")),
        "{calls:?}"
    );
    let mail = fleet.mail_log();
    assert!(
        !mail[mail_from..].iter().any(|l| l.contains("pending")),
        "{mail:?}"
    );
}

/// A park of a record that names no repository is judged in the fleet's
/// own: with gh naming none in the project, a project whose origin names no
/// GitHub repository refuses `repo-unresolved` and signals nothing, and one
/// whose origin names `o/r` on github.com parks against `o/r`.
#[test]
fn a_park_of_a_record_naming_no_repository_reads_the_fleets_own() {
    let fleet = Fleet::park_world();
    let project = fleet.state_dir();
    let git = |args: &[&str]| {
        let out = program("git")
            .arg("-C")
            .arg(project)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    };
    git(&["init", "-q", "-b", "main", "."]);
    git(&["remote", "add", "origin", "https://gitlab.example/g/r"]);
    std::os::unix::fs::symlink(
        orch_package().parent().unwrap().join("github"),
        project.join(".agents/skills/github"),
    )
    .unwrap();
    fleet.write_lanes(vec![{
        let mut lane = hosted_lane("KEN-1");
        lane.as_object_mut().unwrap().remove("repo");
        lane
    }]);
    fleet.plant_tracker("KEN-1", "started");
    let park = json!({"op": "close-lane", "item": "KEN-1", "mode": {"park": {"pr": 7}}});
    let answer = fleet.close(park.clone());
    assert_eq!(answer["refusal"]["key"], "park-refused", "{answer}");
    assert_eq!(
        refusal_fields(&answer)["reason"],
        "repo-unresolved",
        "{answer}"
    );
    let calls = fleet.provider_calls();
    assert!(!calls.iter().any(|c| c.starts_with("stop ")), "{calls:?}");
    assert_eq!(fleet.lane("KEN-1")["status"], "running");
    git(&["remote", "set-url", "origin", "git@github.com:o/r.git"]);
    let answer = fleet.close(park);
    assert_eq!(answer["result"]["word"], "parked", "{answer}");
    assert_eq!(fleet.lane("KEN-1")["parked"]["repo"], "o/r");
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
                .starts_with("send.")),
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
        results.push(
            json!({"id": child["identifier"], "ok": true, "state_ok": true, "has_summary": true}),
        );
    }
    json!({
        "issues bulk-get": {"body": [{"state_type": state, "in_pr_bundle": false}]},
        "graphql Children": {"body": {"issue": {"children": child_page(children)}}},
        "issues validate-completion": {"body": {"results": results}},
        "issues complete": {"body": {}},
        "issues update": {"body": {}},
    })
}

/// One closed page of children, as the children document answers it.
fn child_page(nodes: Value) -> Value {
    json!({"pageInfo": {"hasNextPage": false}, "nodes": nodes})
}

fn child(id: &str, state: &str) -> Value {
    json!({"identifier": id, "title": format!("work {id}"), "state": {"type": state}})
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
    bundle["issues bulk-get"]["body"][0]["in_pr_bundle"] = json!(true);
    let mut nested = child("KEN-1", "completed");
    nested["children"] = child_page(json!([child("KEN-3", "started")]));
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
            "a grandchild open",
            container_replies("started", json!([nested]), false),
            "deferred KEN-3\n",
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

/// A container close reads Linear's state type `duplicate` as it reads
/// `canceled`, for a child and for the parent: a Duplicate child beside a
/// canceled one sets the parent Canceled; beside a Done one it is left out
/// of the bundle summary and its held rows and named Canceled in the child
/// box's evidence; a Duplicate parent whose children all dropped is left as
/// it is; one with a Done child refuses as a Canceled parent does.
#[test]
fn a_duplicate_reads_as_canceled_in_a_container_close() {
    let done_and_duplicate = json!([child("KEN-1", "completed"), child("KEN-2", "duplicate")]);
    let mut held = container_replies("started", done_and_duplicate, false);
    held["issues complete"] = json!({"exit": 1, "stderr": "{\"code\":\"RATELIMITED\",\"quota\":{\"reset\":\"2026-01-01T02:00:00Z\"}}\n"});
    let gh = json!({"pr list": {"body": [{"number": 21, "headRefName": "ken-1", "mergedAt": "2026-01-01T00:00:00Z", "isCrossRepository": false}]}});
    // (case, replies, stdout, the mutation's verb words, a refusal's cause)
    type Case = (
        &'static str,
        Value,
        &'static str,
        Option<&'static str>,
        Option<&'static str>,
    );
    let rows: [Case; 4] = [
        (
            "a duplicate child beside a canceled one",
            container_replies(
                "started",
                json!([child("KEN-1", "canceled"), child("KEN-2", "duplicate")]),
                false,
            ),
            "closed KEN-C\n",
            Some("issues update"),
            None,
        ),
        (
            "a done child beside a duplicate one",
            held,
            "held KEN-C 2026-01-01T02:00:00Z\n",
            Some("issues complete"),
            None,
        ),
        (
            "an already duplicate parent",
            container_replies("duplicate", json!([child("KEN-1", "duplicate")]), false),
            "closed KEN-C\n",
            None,
            None,
        ),
        (
            "a duplicate parent with a done child",
            container_replies("duplicate", json!([child("KEN-1", "completed")]), false),
            "",
            None,
            Some("parent-canceled"),
        ),
    ];
    for (case, replies, stdout, mutation, refused) in rows {
        let container = Container::new(replies, Some(gh.clone()));
        // The tracker keeps the evidence file the completion names: the
        // close removes its run directory once the call returns.
        let state = container.fleet.state_dir();
        let tracker = state.join("linear.sh");
        std::fs::remove_file(&tracker).unwrap();
        write_executable(
            &tracker,
            format!(
                "#!/bin/bash\nprev=\nfor a in \"$@\"; do [ \"$prev\" = --evidence-file ] && cp -- \"$a\" '{dir}/evidence.seen'; prev=$a; done\nLINEAR_FAKE_REPLIES='{dir}/linear.json' LINEAR_FAKE_LOG='{dir}/linear.log' exec '{fixture}' \"$@\"\n",
                dir = state.display(),
                fixture = fixtures().join("linear-fixture/linear.sh").display(),
            ),
        );
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
        if let Some(cause) = refused {
            assert_eq!(out.status.code(), Some(1), "{case}");
            assert!(
                stderr(&out).contains(&format!(
                    "container-close: completion-refused parent-id=KEN-C cause={cause}"
                )),
                "{case}: {}",
                stderr(&out)
            );
        }
        let held_dir = container.checkout.join("tmp/container-close-held/KEN-C");
        match case {
            "a duplicate child beside a canceled one" | "an already duplicate parent" => assert!(
                stderr(&out).contains("container-close: canceled parent-id=KEN-C"),
                "{case}: {}",
                stderr(&out)
            ),
            "a done child beside a duplicate one" => {
                assert_eq!(
                    std::fs::read_to_string(held_dir.join("children.tsv")).unwrap(),
                    "KEN-1\twork KEN-1\tcompleted\n",
                    "{case}"
                );
                assert_eq!(
                    std::fs::read_to_string(held_dir.join("summary.md")).unwrap(),
                    "## Bundle Complete\n\n- KEN-1 ✓ work KEN-1 — PR #21\n",
                    "{case}"
                );
                assert_eq!(
                    std::fs::read_to_string(state.join("evidence.seen")).unwrap(),
                    "3: container-close read every child Done or Canceled: KEN-1 Done, KEN-2 Canceled\n",
                    "{case}"
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
    replies["issues bulk-get"]["body"][0]["parent_id"] = json!("KEN-G");
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

/// The cycle verbs over the fleet record: with none, `report` and
/// `rollup` print nothing and write nothing; `report` prints
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
    let cycle = |args: &[&str]| -> Output { fleet.run(&[&["cycle"], args].concat()) };
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
    let rollup = "rollup class=micro items=1 median=100 p90=100 lane_median=100 open_median=- miss_share=0/1 misses=0 draft=- review=- fix=- bot=- full_mode_runs=- rounds_unread=1 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0";
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
            with("issues bulk-get", json!({"exit": 1})),
            "parent-unreadable",
            0,
        ),
        (
            "a parent that does not type",
            with("issues bulk-get", json!({"body": [{"state_type": 5}]})),
            "parent-response",
            0,
        ),
        (
            "children that fail",
            with("graphql Children", json!({"exit": 1})),
            "children-unreadable",
            0,
        ),
        (
            "a child with no id",
            with(
                "graphql Children",
                json!({"body": {"issue": {"children": child_page(json!([child("", "completed")]))}}}),
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
/// iterations and one full validation besides, and its merge question held
/// 15:30 to 16:10, the 2400 seconds the cycle takes off as a wait.
fn rounds_state(fix: u64) -> Value {
    json!({"first_panel": {"agents": ["a"]}, "rereview_cycles": 1, "cycles": fix,
        "pr_comment_review": {"iterations": 3}, "validate_rounds": [{"mode": "full"}, {"mode": "range"}],
        "pauses": [{"from": "2026-01-29T15:30:00Z", "to": "2026-01-29T16:10:00Z", "cause": "merge-hold"}]})
}

/// A merged hosted lane's close records its cycle through the real
/// pr-timeline over the `gh` fixture, its rounds read where its host kept
/// its state, through the real dispatcher: the clone its worktree's `.git`
/// names, else the copy its merge saved there, which the clone the watch
/// kept still names once the merge's close-out removed the worktree, else
/// the archive the fleet log's last `kept=` row names, read only where it
/// declares its state: a state marker's member; with an empty marker, this
/// merge's copy among the saved copies its list names, never another merge's
/// nor a copy the list leaves out; a close-out archive's `records.json`
/// member of role `state`, never a nested copy that sorts first. An archive
/// declaring neither answers nothing, its path tried with
/// `cause=undeclared`; with no state anywhere, the rounds are null and the
/// close's notes name the paths tried. The class stays unread with its
/// cause, the checkout no repository. The hosted archives are planted in the
/// forms `lane-host-ssh::archive_tmp` writes; the close-out archive is the
/// real `state remove`'s. Under the C locale, where tar lists a non-ASCII
/// name escaped, a marker naming one still answers. A marker naming the
/// physical path of a clone recorded through a symlink names the hard-link
/// entry its second archiving left, and still answers.
#[test]
fn a_closed_lanes_cycle_reads_its_rounds_where_its_host_kept_them() {
    for (case, fix) in [
        ("the clone's state", Some(2)),
        ("the merge's saved copy", Some(4)),
        ("the saved copy after the worktree's removal", Some(4)),
        ("the archive its close kept", Some(6)),
        ("the archive's saved copy alone", Some(6)),
        ("an empty marker with no saved list", None),
        ("the archive with no state marker", None),
        ("a marker naming a non-ASCII path", Some(10)),
        ("a marker naming a hard-link entry", Some(14)),
        ("the close-out archive's declared state", Some(16)),
        ("no state anywhere", None),
    ] {
        let mut fleet = Fleet::hosted(4);
        let archive_root = tempfile::tempdir().unwrap();
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
        let kept_row = |archive: &Path| {
            json!({"at": "2026-01-29T16:30:00Z", "kind": "close", "item": "KEN-1",
                "text": format!("lane-host close kept={}", archive.display())})
        };
        let undeclared = format!(
            "{} cause=undeclared",
            fleet.state_dir().join("kept.tgz").display()
        );
        let mut tried = vec![format!("{REMOTE_ROOT}/.git")];
        // The archive a close kept, `marker` its `lane-host-state` member
        // where it has one and `listed` its `lane-host-saved` member, each
        // `linked` member a hard link to the member it names, archived after
        // it, and the fleet log's row naming it.
        let archive = |marker: Option<&str>,
                       listed: Option<&str>,
                       members: &[(&str, Value)],
                       linked: &[(&str, &str)]| {
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
            if let Some(listed) = listed {
                std::fs::write(kept.join("lane-host-saved"), listed).unwrap();
                names.insert(0, "lane-host-saved");
            }
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
            kept_row(&archive)
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
                None,
                &[("clone/tmp/workflow-state-KEN-1.json", rounds_state(fix))],
                &[],
            )),
            // A copy of this merge the list leaves out comes first in the
            // archive and in name order.
            ("the archive's saved copy alone", Some(fix)) => log.push(archive(
                Some("\n"),
                Some(&format!("{}\n{}\n", &saved(6)[1..], &saved(7)[1..])),
                &[
                    (
                        "a/tmp/cycle-state/workflow-state-pr-7.json",
                        rounds_state(9),
                    ),
                    (&saved(6)[1..], rounds_state(9)),
                    (&saved(7)[1..], rounds_state(fix)),
                ],
                &[],
            )),
            ("an empty marker with no saved list", None) => {
                log.push(archive(
                    Some("\n"),
                    None,
                    &[(&saved(7)[1..], rounds_state(9))],
                    &[],
                ));
                tried.push(undeclared.clone());
            }
            ("the archive with no state marker", None) => {
                log.push(archive(
                    None,
                    None,
                    &[
                        ("w/clone/tmp/workflow-state-KEN-1.json", rounds_state(9)),
                        (&saved(7)[1..], rounds_state(9)),
                    ],
                    &[],
                ));
                tried.push(undeclared.clone());
            }
            ("a marker naming a non-ASCII path", Some(fix)) => log.push(archive(
                Some("clon\u{e9}/tmp/workflow-state-KEN-1.json\n"),
                None,
                &[(
                    "clon\u{e9}/tmp/workflow-state-KEN-1.json",
                    rounds_state(fix),
                )],
                &[],
            )),
            // The clone's tmp archived through its recorded path, then the
            // state file through its physical one, which the marker names.
            ("a marker naming a hard-link entry", Some(fix)) => log.push(archive(
                Some("var/w/clone/tmp/workflow-state-KEN-1.json\n"),
                None,
                &[("w/clone/tmp/workflow-state-KEN-1.json", rounds_state(fix))],
                &[(
                    "var/w/clone/tmp/workflow-state-KEN-1.json",
                    "w/clone/tmp/workflow-state-KEN-1.json",
                )],
            )),
            // The item's close-out over an `--archive` tree holding another
            // copy of its record, whose path sorts before the record's.
            // The remove runs from a checkout of its own, which a configured
            // archive root is judged against: the lane's directory stays no
            // repository for the cycle read.
            ("the close-out archive's declared state", Some(fix)) => {
                let dir = fleet.state_dir();
                std::fs::write(
                    dir.join("workflow-state-KEN-1.json"),
                    rounds_state(fix).to_string(),
                )
                .unwrap();
                let nested = dir.join("a-tree/tmp/workflow-state-KEN-1.json");
                std::fs::create_dir_all(nested.parent().unwrap()).unwrap();
                std::fs::write(&nested, rounds_state(9).to_string()).unwrap();
                let project = tempfile::tempdir().unwrap();
                git_checkout(project.path());
                let removed = reply(
                    &isolated()
                        .args(["--state-dir", &dir.display().to_string()])
                        .args(["state", "remove", "--item", "KEN-1", "--archive"])
                        .arg(dir.join("a-tree"))
                        .env("ORCH_ARCHIVE_ROOT", archive_root.path())
                        .current_dir(project.path())
                        .output()
                        .unwrap(),
                );
                let kept = removed["result"]["kept"].as_str().expect("the archive");
                log.push(kept_row(Path::new(kept)));
            }
            _ => {
                retained();
                tried.push(saved(7));
            }
        }
        if case.contains("non-ASCII") {
            fleet.env.push(("LC_ALL".to_owned(), "C".to_owned()));
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
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
                (cycle["rounds"].clone(), cycle["waited"].clone()),
                (
                    json!({"review": 2, "fix": fix, "bot": 3, "full_mode_runs": 1}),
                    json!(2400)
                ),
                "{case}: {notes:?}"
            ),
            None => {
                assert_eq!(
                    (cycle["rounds"].clone(), cycle["waited"].clone()),
                    (Value::Null, json!(0)),
                    "{case}"
                );
                assert!(
                    notes
                        .iter()
                        .any(|n| n == "oversee-cycle: rounds-unread item=KEN-1"),
                    "{case}: {notes:?}"
                );
                for path in &tried {
                    let line = format!("lane-gitfile: state-tried item=KEN-1 path={path}");
                    assert!(
                        notes.iter().flat_map(|n| n.lines()).any(|l| l == line),
                        "{case}: {line} in {notes:?}"
                    );
                }
            }
        }
    }
}

/// A closed hosted lane's merged class is read in the fleet's checkout only
/// where that checkout is of the repository the pull request was merged in:
/// with gh naming none, a checkout whose origin names another repository on
/// github.com leaves the class unread as `checkout-other-repo`.
#[test]
fn a_closed_lanes_class_is_unread_in_a_checkout_of_another_repository() {
    let mut fleet = Fleet::hosted(4);
    let project = fleet.state_dir().to_path_buf();
    let catalog = orch_package().parent().unwrap().to_path_buf();
    std::os::unix::fs::symlink(
        catalog.join("github"),
        project.join(".agents/skills/github"),
    )
    .unwrap();
    let bin = project.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
    std::fs::write(
        bin.join("gh.json"),
        json!({"graphql number=7 cursor=": merged_timeline()}).to_string(),
    )
    .unwrap();
    fleet.env.extend([
        ("PATH".to_owned(), tool_path(&[bin.as_path()])),
        ("GH_TOKEN".to_owned(), "fixture-token".to_owned()),
        // No fetch this row's checkout runs may leave the machine.
        ("GIT_ALLOW_PROTOCOL".to_owned(), "file".to_owned()),
    ]);
    let git = |args: &[&str]| {
        let out = program("git")
            .arg("-C")
            .arg(&project)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    };
    git(&["init", "-q", "-b", "main", "."]);
    git(&["remote", "add", "origin", "git@github.com:o/other.git"]);
    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    fleet.plant_tracker("KEN-1", "completed");
    let answer = fleet.close(
        json!({"op": "close-lane", "item": "KEN-1", "delivery": {"pr": {"pr": 7, "repo": "o/r"}}}),
    );
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    let cycle = fleet.lane("KEN-1")["cycle"].clone();
    assert_eq!(
        (cycle["class"].clone(), cycle["class_cause"].clone()),
        (Value::Null, json!("checkout-other-repo")),
        "{cycle}"
    );
}

/// A hosted lane's validation runs are its host's: its close stops none
/// here, even where its root names a directory this machine also holds.
#[test]
fn a_hosted_close_stops_no_validation_run_of_this_machine() {
    let fleet = Fleet::hosted(4);
    let (command, run_dir) = validation_run(fleet.state_dir());
    let mut lane = hosted_lane("KEN-1");
    lane["mail_root"] = json!(fleet.state_dir().display().to_string());
    fleet.write_lanes(vec![lane]);
    fleet.plant_tracker("KEN-1", "completed");
    let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    assert!(
        live(command.pid()) && !run_stopped(&run_dir),
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
/// command sets. A box the section gives no evidence for ticks nothing and
/// refuses the close `boxes-unsettled` with nothing moved and nothing
/// posted; a close whose disposal gives the boxes up then ends the lane,
/// posts the one comment that names the boxes with and without evidence,
/// and writes its `landing-disposed` row. An item the lane completed is
/// left alone.
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
            note: Some("boxes-unticked cause=evidence-partial boxes=2"),
            after: "Verifying",
            comment: Some(("with evidence: 1", "without evidence: 2")),
            absent: false,
        },
        Case {
            name: "no evidence section",
            state: "Verifying",
            ticked: false,
            body: "## Summary\n- work\n",
            note: Some("boxes-unticked cause=evidence-absent boxes=1,2"),
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
        let mut request = json!({"op": "close-lane", "item": "KEN-1"});
        let open = case.comment.is_some();
        if open {
            let answer = fleet.close(request.clone());
            assert_eq!(
                answer["refusal"]["key"], "boxes-unsettled",
                "{name}: {answer}"
            );
            let fields = refusal_fields(&answer);
            let cause = case.note.unwrap().split_whitespace().nth(1).unwrap();
            assert_eq!(
                format!("cause={}", fields["cause"]),
                cause,
                "{name}: {fields:?}"
            );
            assert_eq!(fleet.lane("KEN-1")["status"], "running", "{name}");
            assert!(
                fleet.sent("commentCreate").is_empty(),
                "{name}: nothing posted"
            );
            assert!(
                !fleet
                    .provider_calls()
                    .iter()
                    .any(|l| l.starts_with("stop ")),
                "{name}: a refused close stops nothing"
            );
            request["landing"] = json!({"disposed": {"by": "overseer", "id": "1769700000-9-31",
                "reason": "the lane wrote no evidence", "of": "boxes"}});
        }
        let answer = fleet.close(request);
        let result = &answer["result"];
        assert_eq!(result["word"], "closed", "{name}: {answer}");
        let notes: Vec<&str> = result["notes"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|n| n.starts_with("boxes-"))
            .collect();
        let mut want: Vec<&str> = case.note.into_iter().collect();
        if open {
            want.push("boxes-comment=posted");
        }
        assert_eq!(notes, want, "{name}");
        let disposed: Vec<Value> = fleet.fleet()["fleet_log"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["kind"] == "landing-disposed")
            .cloned()
            .collect();
        if open {
            assert_eq!(disposed.len(), 1, "{name}: {disposed:?}");
            assert_eq!(disposed[0]["of"], "boxes", "{name}");
            assert_eq!(disposed[0]["by"], "overseer", "{name}");
            assert_eq!(disposed[0]["id"], "1769700000-9-31", "{name}");
        } else {
            assert!(disposed.is_empty(), "{name}: {disposed:?}");
        }
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
    let disposed = |request: &mut Value| {
        request["landing"] = json!({"disposed": {"by": "owner-directive", "id": "d-1",
            "reason": "boxes completed by hand", "of": "boxes"}});
    };

    // A completion left open refuses the close by its state and cause, with
    // nothing posted; a Done item is read by no duty again, so the close its
    // disposal ends names the completion in one comment there. A write
    // Linear answers with a 5xx may have landed: it is unknown, never failed.
    for (case, state, body, operation, refusal, notes) in [
        (
            "its pull request absent from GitHub",
            "Done",
            proved,
            None,
            ("unticked", "pr-missing"),
            ["boxes-unticked cause=pr-missing", "boxes-comment=posted"],
        ),
        (
            "its completion unconfirmed",
            "Verifying",
            proved,
            Some("UpdateIssue"),
            ("unknown", "unconfirmed"),
            ["boxes-unknown cause=unconfirmed", ""],
        ),
        (
            "its comment unconfirmed",
            "Done",
            one,
            Some("CreateComment"),
            ("unticked", "evidence-partial"),
            [
                "boxes-unticked cause=evidence-partial boxes=2",
                "boxes-comment=unknown",
            ],
        ),
    ] {
        let fleet = Fleet::boxes_world(state, &done_when(false), body);
        if operation.is_none() {
            std::fs::write(fleet.state_dir().join("bin/gh.json"), "{}").unwrap();
        }
        if let Some(operation) = operation {
            let path = fleet.state_dir().join("bin/linear-api.json");
            let mut world: Value =
                serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            world["codes"] = json!({ operation: 502 });
            std::fs::write(&path, world.to_string()).unwrap();
        }
        let mut request = json!({"op": "close-lane", "item": "KEN-1"});
        let answer = fleet.close(request.clone());
        assert_eq!(
            answer["refusal"]["key"], "boxes-unsettled",
            "{case}: {answer}"
        );
        let fields = refusal_fields(&answer);
        assert_eq!(
            (fields["state"].as_str(), fields["cause"].as_str()),
            refusal,
            "{case}"
        );
        assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
        assert!(fleet.sent("commentCreate").is_empty(), "{case}");
        disposed(&mut request);
        let answer = fleet.close(request);
        assert_eq!(answer["result"]["word"], "closed", "{case}: {answer}");
        let want: Vec<&str> = notes.into_iter().filter(|n| !n.is_empty()).collect();
        assert_eq!(box_notes(&answer), want, "{case}: {answer}");
        if case == "its pull request absent from GitHub" {
            let comments = fleet.sent("commentCreate");
            assert_eq!(comments.len(), 1, "{comments:?}");
            let body = comments[0]["variables"]["input"]["body"].as_str().unwrap();
            assert!(body.contains("boxes-unticked cause=pr-missing"), "{body}");
        }
    }

    // A provider close that fails leaves the close unconfirmed, which is
    // asked again: the comment waits for the close that confirms, and is
    // posted once.
    let mut fleet = Fleet::boxes_world("Verifying", &done_when(false), one);
    fleet.answer("CLOSE_STATUS", "1");
    let mut request = json!({"op": "close-lane", "item": "KEN-1"});
    disposed(&mut request);
    for _ in 0..2 {
        let answer = fleet.close(request.clone());
        assert_eq!(answer["result"]["word"], "unconfirmed", "{answer}");
        assert!(
            !box_notes(&answer)
                .iter()
                .any(|n| n.starts_with("boxes-comment")),
            "{answer}"
        );
    }
    assert_eq!(fleet.sent("commentCreate"), Vec::<Value>::new());
    fleet.answer("CLOSE_STATUS", "0");
    let answer = fleet.close(request);
    assert_eq!(answer["result"]["word"], "closed", "{answer}");
    assert_eq!(fleet.sent("commentCreate").len(), 1, "{answer}");
}

// --- a landing the close cannot record ------------------------------------------

/// A delivery whose merge cycle the recorder cannot write refuses the close
/// `cycle-unrecorded` with nothing moved: the lane running, no provider
/// stop or close asked, its item's files standing. A disposal that gives up
/// the boxes alone still refuses; one that gives up the record ends the
/// lane with the cause noted, a direct delivery's boxes noted unread, and
/// one `landing-disposed` row naming the authority and what it gave up.
#[test]
fn a_landing_the_close_cannot_record_holds_the_lane_until_a_disposal_gives_it_up() {
    let mut fleet = Fleet::hosted(4);
    let bin = fleet.state_dir().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
    std::fs::write(bin.join("gh.json"), "{}").unwrap();
    fleet
        .env
        .push(("PATH".to_owned(), tool_path(&[bin.as_path()])));
    fleet.write_lanes(vec![hosted_lane("KEN-1")]);
    fleet.plant_tracker("KEN-1", "completed");
    let item_state = plant(fleet.state_dir(), "workflow-state-KEN-1.json");
    let delivery = json!({"commit": {"commit": "0123456789abcdef0123456789abcdef01234567"}});
    let mut request = json!({"op": "close-lane", "item": "KEN-1", "delivery": delivery});
    let disposal = |of: &str| {
        json!({"disposed": {"by": "overseer", "id": "1769700000-9-31",
            "reason": "the merge's timeline is unreadable", "of": of}})
    };

    for landing in [None, Some(disposal("boxes"))] {
        if let Some(landing) = landing {
            request["landing"] = landing;
        }
        let answer = fleet.close(request.clone());
        assert_eq!(answer["refusal"]["key"], "cycle-unrecorded", "{answer}");
        let fields = refusal_fields(&answer);
        assert_eq!(fields["item"], "KEN-1");
        assert!(!fields["cause"].is_empty(), "{fields:?}");
        assert_eq!(fleet.lane("KEN-1")["status"], "running");
        assert!(
            !fleet
                .provider_calls()
                .iter()
                .any(|l| l.starts_with("stop ") || l.starts_with("close ")),
            "a refused close acts on nothing: {:?}",
            fleet.provider_calls()
        );
        assert!(std::fs::symlink_metadata(&item_state).is_ok());
    }

    request["landing"] = disposal("record");
    let answer = fleet.close(request);
    let result = &answer["result"];
    assert_eq!(result["word"], "closed", "{answer}");
    let notes: Vec<&str> = result["notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(
        notes
            .iter()
            .any(|n| n.starts_with("cycle-unrecorded cause=")),
        "{notes:?}"
    );
    assert!(
        notes.contains(&"boxes-unread cause=direct-delivery"),
        "{notes:?}"
    );
    let lane = fleet.lane("KEN-1");
    assert_eq!(lane["status"], "done");
    assert!(
        lane.get("cycle").is_none_or(|c| c == &json!({"pr": 7})),
        "{lane}"
    );
    let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
    let rows: Vec<&Value> = log
        .iter()
        .filter(|r| r["kind"] == "landing-disposed")
        .collect();
    assert_eq!(rows.len(), 1, "{log:?}");
    let row = rows[0];
    assert_eq!(
        (&row["item"], &row["by"], &row["id"], &row["of"]),
        (
            &json!("KEN-1"),
            &json!("overseer"),
            &json!("1769700000-9-31"),
            &json!("record")
        ),
        "{row}"
    );
    assert_eq!(row["reason"], "the merge's timeline is unreadable");
}

// --- a merged lane whose work left its host -------------------------------------

/// A merged hosted lane whose work left nothing on its host closes whatever
/// its screen reads: on a provider that captures its own pane drawn at the
/// harness's working hint, or failing its capture, the lane ends on its
/// merge (`disposition: ended`, item files kept on its open item) with its
/// harness stopped through the provider; with its item's record standing in
/// the clone the same screen refuses `lane-live state=working` and stops
/// nothing.
#[test]
fn a_merged_hosted_lane_whose_work_left_its_host_closes_whatever_its_screen_reads() {
    const RECORD: &str = "/w/clone/tmp/workflow-state-KEN-1.json";
    let working = "❯ do the thing\n✻ Working… (esc to interrupt)\n";
    for (case, capture_fails, standing) in [
        ("working, its record standing", false, true),
        ("working, its record left", false, false),
        ("its capture failing, its record left", true, false),
    ] {
        let mut fleet = Fleet::verb_pane(working);
        if capture_fails {
            fleet.answer("CAPTURE_STATUS", "1");
        }
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
        fleet.answer("STOP_ENDS", "1");
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "started");
        let answer = fleet.close(json!({"op": "close-lane", "item": "KEN-1"}));
        let calls = fleet.provider_calls();
        if standing {
            assert_eq!(answer["refusal"]["key"], "lane-live", "{case}: {answer}");
            assert_eq!(refusal_fields(&answer)["state"], "working", "{case}");
            assert!(
                !calls.iter().any(|l| l.starts_with("stop ")),
                "{case}: {calls:?}"
            );
            assert_eq!(fleet.lane("KEN-1")["status"], "running", "{case}");
            continue;
        }
        assert_eq!(answer["result"]["word"], "closed", "{case}: {answer}");
        assert!(
            calls.contains(&"stop --item KEN-1 --harness claude".to_owned()),
            "{case}: {calls:?}"
        );
        assert_eq!(fleet.lane("KEN-1")["status"], "done", "{case}");
        let log = fleet.fleet()["fleet_log"].as_array().unwrap().clone();
        let row = log.iter().rev().find(|r| r["kind"] == "close").unwrap();
        assert_eq!(
            (&row["disposition"], &row["source"]),
            (&json!("ended"), &json!("merged")),
            "{case}: {row}"
        );
    }
}

// --- the base checkout after a landing ------------------------------------------

/// After a recorded landing the project's base checkout follows the landed
/// base through the real `sync-base`: a close whose delivery's cycle the
/// recorder wrote, over a project checkout one commit behind its origin,
/// leaves the checkout at the origin's head; one whose tracked file is
/// dirty is left where it stood, the close noting `base-follow refused
/// cause=dirty` and ending the lane all the same.
#[test]
fn a_recorded_landing_brings_the_base_checkout_to_the_landed_base() {
    for dirty in [false, true] {
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
        let origin = TempDir::new().unwrap();
        let project = fleet.state_dir().to_path_buf();
        let git = |dir: &Path, args: &[&str]| -> String {
            let out = program("git")
                .current_dir(dir)
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
            String::from_utf8_lossy(&out.stdout).trim().to_owned()
        };
        git(origin.path(), &["init", "-q", "--bare", "-b", "main"]);
        git(&project, &["init", "-q", "-b", "main"]);
        git(&project, &["config", "gc.auto", "0"]);
        git(&project, &["config", "maintenance.auto", "false"]);
        std::fs::write(project.join("tracked.txt"), "one\n").unwrap();
        git(&project, &["add", "tracked.txt"]);
        git(&project, &["commit", "-q", "-m", "one"]);
        let behind = git(&project, &["rev-parse", "HEAD"]);
        std::fs::write(project.join("tracked.txt"), "two\n").unwrap();
        git(&project, &["commit", "-q", "-am", "two"]);
        let landed = git(&project, &["rev-parse", "HEAD"]);
        let remote = origin.path().display().to_string();
        git(&project, &["remote", "add", "origin", &remote]);
        git(&project, &["push", "-q", "origin", "main"]);
        git(&project, &["reset", "-q", "--hard", &behind]);
        if dirty {
            std::fs::write(project.join("tracked.txt"), "local\n").unwrap();
        }
        fleet.write_lanes(vec![hosted_lane("KEN-1")]);
        fleet.plant_tracker("KEN-1", "completed");
        let answer = fleet.close(
            json!({"op": "close-lane", "item": "KEN-1", "delivery": {"pr": {"pr": 7, "repo": "o/r"}}}),
        );
        let result = &answer["result"];
        assert_eq!(result["word"], "closed", "dirty={dirty}: {answer}");
        assert_eq!(fleet.lane("KEN-1")["status"], "done");
        let notes: Vec<&str> = result["notes"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .filter(|n| n.starts_with("base-follow"))
            .collect();
        let head = git(&project, &["rev-parse", "HEAD"]);
        if dirty {
            assert_eq!(notes, ["base-follow refused cause=dirty"], "{answer}");
            assert_eq!(head, behind, "a dirty checkout stays where it stood");
        } else {
            assert!(notes.is_empty(), "{answer}");
            assert_eq!(result["observation"]["base"], "followed branch=main");
            assert_eq!(head, landed, "the checkout follows the landed base");
        }
    }
}
