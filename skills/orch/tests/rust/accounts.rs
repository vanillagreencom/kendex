//! The accounts judge: the status words over the reader's listing, the
//! window a lane on a model is judged on, the projection on the fleet's
//! own live charges with the candidate charged to each window's reset, the
//! sample's own occupancy as the divisor and the replaced lane left out,
//! the one limit a seat is held to, the provider's rows, seats and the one
//! reading per billed account under a host, the Pi Copilot pool read
//! beside the listing, the grant tier and the cloud repository rule, an
//! unreadable listing admitting nothing, and the record's spelling the
//! shell callers read. Each row names the defect it catches at its doc
//! comment.
//!
//! Two kinds of row: a pure judge case hands rows to
//! `accounts::pick` in this process; a case whose production path starts a
//! child (the reader, the host's capability line, `git` for the checkout's
//! origin) asks the executable through `support::isolated`, so every child
//! runs under the boundary's environment and never this process's. The
//! reader is the `lanes-listing` fixture, which prints a planted listing,
//! per host where one is planted, and a planted `host-accounts` answer,
//! and logs what it was handed; the host's capability line is the
//! `lane-host` fixture's; the fleet state and the live lanes are the
//! row's own.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the records they plant, hold the children whose identities they record, and read the fixture's log"
)]

#[path = "support.rs"]
mod support;

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use orch_runtime::ops::accounts::{
    self, AccountRow, EndSource, FleetFacts, PickAnswer, PickRequest, Roster, Word,
};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::FLEET_FILE_NAME;
use serde_json::{Value, json};
use support::*;

/// The instant every row plants its stamps against, read once per process:
/// the executable judges on the system clock, so each reset, launch
/// instant and stated end is placed relative to it.
fn now() -> u64 {
    static NOW: OnceLock<u64> = OnceLock::new();
    *NOW.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
    })
}

fn stamp(at: u64) -> String {
    clock::iso_utc(at)
}

/// A provider's capability line for an SSH host: no repository rule.
const SSH_LINE: &str =
    "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\tpool=plan\n";

/// A cloud-session host's line: the judge admits an account on it only with
/// repository access.
const CLOUD_LINE: &str = "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none\tpool=cloud-credit\n";

/// One world: a state directory with the listing fixture symlinked as
/// `lanes` and the host fixture as `lane-host`, the settings naming them
/// under `extra` as the caller's environment, and the same environment
/// handed to the executable.
struct World {
    dir: tempfile::TempDir,
    settings: Settings,
    env: Vec<(String, String)>,
    /// A home of the row's own for the executable, in place of the
    /// boundary's scratch home.
    home: Option<PathBuf>,
}

impl World {
    fn new(extra: &[(&str, &str)]) -> World {
        let dir = tempfile::tempdir().unwrap();
        for (name, fixture) in [
            ("lanes", "lanes-listing/lanes"),
            ("lane-host", "lane-host/lane-host"),
        ] {
            std::os::unix::fs::symlink(fixtures().join(fixture), dir.path().join(name)).unwrap();
        }
        let roots = Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let lanes = dir.path().join("lanes").display().to_string();
        let mut environment: Vec<(OsString, OsString)> =
            vec![("OVERSEE_WATCH_LANES".into(), lanes.into())];
        environment.extend(
            extra
                .iter()
                .map(|(k, v)| (OsString::from(k), OsString::from(v))),
        );
        let settings = settings::load(
            &roots,
            &environment,
            &SettingsFlags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap();
        World {
            dir,
            settings,
            env: extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
            home: None,
        }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.path().join(FLEET_FILE_NAME)
    }

    fn plant_listing(&self, rows: &[Value]) {
        self.plant_listing_as("lanes.json", rows);
    }

    /// The listing the reader prints under one host (`lanes-<host>.json`).
    fn plant_host_listing(&self, host: &str, rows: &[Value]) {
        self.plant_listing_as(&format!("lanes-{host}.json"), rows);
    }

    /// The provider's `host-accounts --harness pi --json` answer under one
    /// host.
    fn plant_host_accounts(&self, host: &str, rows: &[Value]) {
        self.plant_listing_as(&format!("host-accounts-{host}.json"), rows);
    }

    fn plant_listing_as(&self, name: &str, rows: &[Value]) {
        std::fs::write(
            self.path().join(name),
            serde_json::to_string(&Value::Array(rows.to_vec())).unwrap(),
        )
        .unwrap();
    }

    /// The host fixture's capability line for `host`.
    fn plant_capabilities(&self, host: &str, line: &str) {
        std::fs::write(
            self.path().join("lane-host.json"),
            json!({format!("{host} capabilities"): {"stdout": line}}).to_string(),
        )
        .unwrap();
    }

    fn write_fleet(&self, lanes: Vec<Value>, overseer_account: Option<&str>) {
        let mut fleet = json!({
            "issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": lanes, "fleet_log": []
        });
        if let Some(account) = overseer_account {
            fleet["overseer"] = json!({"account": account});
        }
        std::fs::write(self.fleet_path(), serde_json::to_string(&fleet).unwrap()).unwrap();
    }

    fn log(&self) -> Vec<String> {
        std::fs::read_to_string(self.path().join("lanes.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn host_log(&self) -> Vec<String> {
        std::fs::read_to_string(self.path().join("lane-host.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// A home of this world's own whose `.gitconfig` rewrites the
    /// checkout's origin from `owner/` to `canary/`: a production `git`
    /// child that reads this home, and not the operator's, reads the
    /// canary.
    fn canary_home(&mut self) {
        let home = self.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join(".gitconfig"),
            "[url \"https://github.com/canary/\"]\n\tinsteadOf = https://github.com/owner/\n",
        )
        .unwrap();
        self.home = Some(home);
    }

    /// The executable under the boundary, in this world,
    /// with its environment.
    fn command(&self) -> std::process::Command {
        let mut command = isolated();
        command
            .current_dir(self.path())
            .env("OVERSEE_WATCH_LANES", self.path().join("lanes"))
            .env("ORCH_STATE_DIR", self.path());
        for (key, value) in &self.env {
            command.env(key, value);
        }
        if let Some(home) = &self.home {
            command.env("HOME", home);
        }
        command
    }

    fn reply(mut command: std::process::Command) -> Value {
        let out = command.output().unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        reply["result"].clone()
    }

    /// `accounts pick --fleet` for `req`: the reply's `result`, the answer's
    /// word, its exit and its record.
    fn pick(&self, req: &PickRequest) -> Value {
        let mut command = self.command();
        command.args(["accounts", "pick", "--fleet", "--harness", &req.harness]);
        if let Some(model) = &req.model {
            command.args(["--native-model", model]);
        }
        for dir in &req.exclude {
            command.args(["--exclude-lane", dir]);
        }
        if let Some(item) = &req.replaces {
            command.args(["--replaces", item]);
        }
        if req.for_overseer {
            command.arg("--for-overseer");
        }
        if let Some(lane) = &req.lane {
            command.args(["--lane", lane]);
        }
        if req.projected {
            command.arg("--projected");
        }
        if let Some(max) = req.max_pct {
            command.args(["--max-pct", &max.to_string()]);
        }
        if let Some(trigger) = req.min_headroom_pct {
            command.args(["--min-headroom-pct", &trigger.to_string()]);
        }
        if req.binding_floor {
            command.arg("--binding-floor");
        }
        World::reply(command)
    }

    /// `accounts roster`: the reply's `result`.
    fn roster(&self) -> Value {
        let mut command = self.command();
        command.args(["accounts", "roster"]);
        World::reply(command)
    }
}

/// One measured local row of `lanes list --json` for a Claude account at
/// `alias`, `used` percent on its weekly window (the binding, resetting 60
/// hours on), the session window at `session` percent four hours in and
/// resetting one hour on.
fn measured(alias: &str, used: u64, session: u64) -> Value {
    let weekly = stamp(now() + 60 * 3600);
    json!({
        "alias": alias,
        "harness": "claude",
        "config_dir": format!("/home/me/.{alias}"),
        "measured_through": "local",
        "status": "ok",
        "verdict": if used < 95 { "room" } else { "walled" },
        "headroom_pct": 100 - used,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": used,
        "session_5h_pct": session,
        "weekly_pct": used,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": stamp(now() + 3600), "weekly": weekly, "model": null, "monthly": null},
        "usage_rate_state": "one-sample",
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
    })
}

/// The provider's reading of the account `measured` describes, as the
/// listing carries it beside this machine's: `measured_through` `host`, no
/// usage age, no model windows.
fn through_host(mut row: Value) -> Value {
    row["measured_through"] = json!("host");
    row["usage_age_s"] = Value::Null;
    row["model_buckets"] = json!([]);
    row
}

/// A grant row: a Claude cloud credit (`cloud-credit`) or a Pi API grant
/// (`api-credit`) with `remaining` of `limit` dollars, ending at `expires`.
fn grant(
    alias: &str,
    harness: &str,
    pool: &str,
    remaining: f64,
    limit: f64,
    expires: &str,
) -> Value {
    let mut row = measured(alias, 0, 0);
    row["harness"] = json!(harness);
    row["pool"] = json!(pool);
    row["credits"] = json!({
        "unit": "usd", "remaining_dollars": remaining, "limit_dollars": limit, "resets_at": expires
    });
    row
}

/// One running lane record on `account`, launched an hour ago, its launch
/// identity `pid` at `start`.
fn lane(item: &str, account: &str, pid: u32, start: &str) -> Value {
    lane_launched(item, account, pid, start, now() - 3600)
}

/// One running lane record on `account` launched at `launched`.
fn lane_launched(item: &str, account: &str, pid: u32, start: &str, launched: u64) -> Value {
    json!({
        "item": item, "window": format!("orch-{item}"), "harness": "claude", "status": "running",
        "account": account, "launched_at": stamp(launched), "running_at": stamp(launched),
        "launch": {"pid": pid, "start": start, "pane": "%1", "server": 1}
    })
}

fn rows(listing: &[Value], settings: &Settings) -> Vec<AccountRow> {
    Roster::parse(
        &serde_json::to_string(&Value::Array(listing.to_vec())).unwrap(),
        &settings.accounts,
    )
    .expect("the listing parses")
    .rows
}

fn picked(answer: &PickAnswer) -> Option<String> {
    match answer {
        PickAnswer::Lane(j) => Some(j.row.config_dir.clone()),
        PickAnswer::None { .. }
        | PickAnswer::Walled(_)
        | PickAnswer::Reserved(_)
        | PickAnswer::Retired { .. }
        | PickAnswer::Excluded(_)
        | PickAnswer::Unmeasured(_)
        | PickAnswer::ProviderUnmeasured { .. }
        | PickAnswer::Unbilled { .. }
        | PickAnswer::NoRecord
        | PickAnswer::CloudRepoUnset(_)
        | PickAnswer::Unjudged { .. } => None,
    }
}

fn exclusions(answer: &PickAnswer) -> Vec<(String, String)> {
    match answer {
        PickAnswer::None { exclusions, .. } => exclusions.clone(),
        PickAnswer::Lane(_)
        | PickAnswer::Walled(_)
        | PickAnswer::Reserved(_)
        | PickAnswer::Retired { .. }
        | PickAnswer::Excluded(_)
        | PickAnswer::Unmeasured(_)
        | PickAnswer::ProviderUnmeasured { .. }
        | PickAnswer::Unbilled { .. }
        | PickAnswer::NoRecord
        | PickAnswer::CloudRepoUnset(_)
        | PickAnswer::Unjudged { .. } => Vec::new(),
    }
}

/// The lane a reply through the executable names, where its answer is
/// `lane`.
fn chosen(reply: &Value) -> Option<String> {
    (reply["answer"] == json!("lane"))
        .then(|| reply["record"]["config_dir"].as_str().unwrap().to_owned())
}

/// A `none` reply's exclusions, `(config_dir, reason)` each.
fn left_out(reply: &Value) -> Vec<(String, String)> {
    if reply["answer"] != json!("none") {
        return Vec::new();
    }
    reply["record"]["exclusions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            (
                e["config_dir"].as_str().unwrap().to_owned(),
                e["reason"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

/// The chooser's request for a Claude launch with `model`.
fn claude(model: Option<&str>) -> PickRequest {
    PickRequest {
        harness: "claude".to_owned(),
        model: model.map(str::to_owned),
        ..PickRequest::default()
    }
}

/// The named reading of `dir` on the projection, the launch question.
fn named(dir: &str, req: PickRequest) -> PickRequest {
    PickRequest {
        lane: Some(dir.to_owned()),
        projected: true,
        ..req
    }
}

/// Defect: a `reserve` account picked for a
/// lane because it has the most room, or dropped from the roster for its
/// word. The provider's `reserved=1` row with the most room is never the
/// lane, is named `reserved` among the exclusions when nothing else has
/// room, and keeps its figures in the roster line with its word after
/// them.
#[test]
fn a_reserve_account_is_never_picked_and_keeps_its_figures_in_the_roster() {
    let world = World::new(&[]);
    let mut reserved = measured("5claude", 10, 5);
    reserved["reserved"] = json!(1);
    let listing = [reserved, measured("6claude", 60, 20)];
    let rows = rows(&listing, &world.settings);
    let req = claude(None);
    let answer = accounts::pick(
        &rows,
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&answer).as_deref(),
        Some("/home/me/.6claude"),
        "the account with less room is the lane: {answer:?}"
    );
    let alone = accounts::pick(
        &rows[..1],
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        now(),
    );
    assert_eq!(picked(&alone), None);
    assert_eq!(
        exclusions(&alone),
        vec![("/home/me/.5claude".to_owned(), "reserved".to_owned())]
    );
    let roster = Roster { rows };
    assert_eq!(
        roster.lines(&accounts::today(now()))[0],
        format!(
            "account 5claude config_dir=/home/me/.5claude harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at={} word=reserve",
            stamp(now() + 60 * 3600)
        )
    );
}

/// An account renewed, retired, reserved. Defect: a retirement date
/// stopping every read of
/// the account, so a renewed, live account reads `retired` with no
/// figures and nothing shows the contradiction. A `retired <date>` account
/// is picked until the date; from the date on it is not picked, its row
/// keeps the figures the reader measured, and its credential still
/// answering is one `account-end-contradicted` line under the roster. The
/// reader is handed `ORCH_LANE_RETIRE` emptied, so it measures the
/// account: the setting is the judge's to apply.
#[test]
fn a_retired_account_is_picked_until_its_date_and_measured_after_it_with_the_contradiction_said() {
    let today = accounts::today(now());
    let tomorrow = accounts::today(now() + 86_400);
    let world = World::new(&[(
        "ORCH_LANE_RETIRE",
        &format!("4claude={today},6claude={tomorrow}"),
    )]);
    // The row with the most room is 4claude, retired today; 6claude
    // retires tomorrow; 7claude never.
    let listing = [
        measured("4claude", 10, 5),
        measured("6claude", 30, 5),
        measured("7claude", 60, 5),
    ];
    world.plant_listing(&listing);
    world.write_fleet(Vec::new(), None);
    let answer = world.pick(&claude(None));
    assert_eq!(
        chosen(&answer).as_deref(),
        Some("/home/me/.6claude"),
        "the account retiring tomorrow is picked, the one retired today is not: {answer}"
    );
    let log = world.log();
    assert_eq!(
        log,
        vec!["ORCH_LANE_HOST=unset ORCH_LANE_RETIRE=emptied list --json"],
        "the reader was asked to measure every account, the statement emptied"
    );
    let roster = world.roster();
    assert_eq!(roster["read"], json!(true));
    assert_eq!(roster["rows"][0]["word"], json!(format!("retired:{today}")));
    assert_eq!(roster["rows"][0]["ended"], json!(true));
    assert_eq!(roster["rows"][1]["ended"], json!(false));
    let weekly = stamp(now() + 60 * 3600);
    assert_eq!(
        roster["lines"],
        json!([
            format!(
                "account 4claude config_dir=/home/me/.4claude harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at={weekly} word=retired:{today}"
            ),
            format!(
                "account 6claude config_dir=/home/me/.6claude harness=claude through=local status=ok verdict=room headroom_pct=70 binding_bucket=weekly binding_resets_at={weekly} word=retired:{tomorrow}"
            ),
            format!(
                "account 7claude config_dir=/home/me/.7claude harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at={weekly}"
            ),
            format!(
                "account-end-contradicted 4claude config_dir=/home/me/.4claude ends={today} source=ORCH_LANE_RETIRE status=ok"
            ),
        ])
    );
    // The provider's own stated end, read from its row as `plan_ends`, is
    // the same word from the other source; a credential that no longer
    // answers contradicts nothing.
    let mut provider = measured("8claude", 50, 5);
    provider["plan_ends"] = json!("2026-10-19");
    provider["status"] = json!("expired");
    provider["headroom_pct"] = Value::Null;
    provider["verdict"] = json!("unmeasured");
    let roster = Roster {
        rows: rows(&[provider], &world.settings),
    };
    assert_eq!(
        roster.rows[0].word(),
        Word::Retired {
            date: "2026-10-19".to_owned(),
            source: EndSource::Provider
        }
    );
    assert_eq!(
        roster.lines(&today).len(),
        1,
        "no contradiction for a credential that does not answer"
    );
}

/// Defect: a listing that could not be read
/// taken as an empty fleet, so a pick answers `none` as if every account
/// were walled, or the roster reads as no accounts. A reader that exits
/// non-zero, or answers a shape that is no listing, is unjudged for the
/// pick and unread for the roster, each with the cause.
#[test]
fn an_unreadable_listing_admits_nothing() {
    let world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let req = claude(None);
    std::fs::write(world.path().join("lanes.rc"), "1\n").unwrap();
    let refused = world.pick(&req);
    assert_eq!(refused["answer"], json!("unjudged"), "{refused}");
    assert_eq!(refused["exit"], json!(1));
    assert!(
        refused["record"]["cause"]
            .as_str()
            .unwrap()
            .starts_with("listing-unread host=local exit=1"),
        "{refused}"
    );
    assert_eq!(world.roster()["read"], json!(false));
    std::fs::remove_file(world.path().join("lanes.rc")).unwrap();
    std::fs::write(
        world.path().join("lanes.text"),
        "{\"not\": \"a listing\"}\n",
    )
    .unwrap();
    let unparsed = world.pick(&req);
    assert_eq!(
        unparsed["record"]["cause"],
        json!("listing-unread host=local parse=failed"),
        "{unparsed}"
    );
    let roster = world.roster();
    assert_eq!(roster["read"], json!(false));
    assert_eq!(roster["cause"], json!("host=local parse=failed"));
}

/// Defect: a lane on model M judged on the fullest window on the
/// account, so an account whose Opus window is spent is refused for a
/// Sonnet lane, or picked for an Opus lane on its Sonnet room. The lane
/// is judged on M's own window: the account with a spent Opus window and
/// a free Sonnet one is the lane for Sonnet and refused for Opus, and
/// without a model the fullest window decides as the reader's binding.
#[test]
fn a_lane_on_a_model_is_judged_on_that_models_window_not_the_fullest() {
    let world = World::new(&[]);
    let mut split = measured("aclaude", 20, 5);
    split["headroom_pct"] = json!(2);
    split["binding_bucket"] = json!("model");
    split["wall"] = json!(98);
    split["verdict"] = json!("walled");
    split["model_buckets"] = json!([
        {"label": "Opus 5", "pct": 98, "resets_at": stamp(now() + 4 * 86_400)},
        {"label": "Sonnet 5.5", "pct": 10, "resets_at": stamp(now() + 4 * 86_400)}
    ]);
    let listing = [split, measured("bclaude", 50, 5)];
    let rows = rows(&listing, &world.settings);
    let facts = FleetFacts::default();
    let pick_for = |model: Option<&str>| {
        accounts::pick(
            &rows,
            &claude(model),
            &facts,
            &world.settings.accounts,
            now(),
        )
    };
    let sonnet = pick_for(Some("claude-sonnet-5-5"));
    assert_eq!(
        picked(&sonnet).as_deref(),
        Some("/home/me/.aclaude"),
        "the Sonnet lane goes to the account whose Sonnet window is free: {sonnet:?}"
    );
    let PickAnswer::Lane(judged) = &sonnet else {
        panic!("{sonnet:?}");
    };
    assert_eq!(
        judged.binding.as_ref().map(|b| (b.bucket.as_str(), b.pct)),
        Some(("weekly", 20.0))
    );
    let opus = pick_for(Some("claude-opus-5"));
    assert_eq!(
        picked(&opus).as_deref(),
        Some("/home/me/.bclaude"),
        "{opus:?}"
    );
    let any = pick_for(None);
    assert_eq!(
        picked(&any).as_deref(),
        Some("/home/me/.bclaude"),
        "{any:?}"
    );
    let PickAnswer::Lane(judged) = &any else {
        panic!("{any:?}");
    };
    assert_eq!(
        judged.binding.as_ref().map(|b| b.bucket.as_str()),
        Some("weekly")
    );
}

/// Defect: a relaunch replacing lane L on account A refused on L's own
/// charge, or the projection charging a claim count instead of the lanes the
/// runtime proves live. The fleet's one running lane on A holds a live
/// launch identity (the row's own child); A's session window charged the
/// live lane's observed rate for it and for the candidate projects past
/// the bound, so a fresh launch is refused with A walled; the same pick
/// naming L as the lane it replaces leaves L's charge out, the candidate
/// alone at the setting's burn, and A is the lane. A lane whose identity
/// is gone charges nothing.
#[test]
fn a_relaunch_replacing_a_lane_adds_no_lane_to_the_projection() {
    let world = World::new(&[]);
    // The session window at 80 percent four hours in: the live lane's
    // observed 20 points an hour, charged for it and the candidate to the
    // reset an hour on, projects past 95; the candidate alone at the
    // setting's 5 leaves room.
    world.plant_listing(&[measured("aclaude", 20, 80)]);
    let child = Owned::sleep();
    world.write_fleet(
        vec![lane(
            "KEN-1",
            "/home/me/.aclaude",
            child.pid(),
            &child.start(),
        )],
        None,
    );
    let fresh = world.pick(&claude(None));
    assert_eq!(fresh["answer"], json!("none"), "{fresh}");
    assert_eq!(
        (
            fresh["record"]["walled"].clone(),
            fresh["record"]["unmeasured"].clone()
        ),
        (json!(1), json!(0)),
        "the live lane's charge walls the account for a fresh launch: {fresh}"
    );
    let relaunch = world.pick(&PickRequest {
        replaces: Some("KEN-1".to_owned()),
        ..claude(None)
    });
    assert_eq!(
        chosen(&relaunch).as_deref(),
        Some("/home/me/.aclaude"),
        "the replaced lane's charge is left out: {relaunch}"
    );
    assert_eq!(relaunch["record"]["claims"], json!(0));
    // A record whose identity is gone charges nothing, so a fresh launch
    // is admitted on it too.
    world.write_fleet(
        vec![lane("KEN-2", "/home/me/.aclaude", GONE_PID as u32, "1")],
        None,
    );
    let gone = world.pick(&claude(None));
    assert_eq!(
        chosen(&gone).as_deref(),
        Some("/home/me/.aclaude"),
        "{gone}"
    );
    drop(child);
}

/// Seat sessions charged to their reset: `S × burn_w ×
/// hours_to_reset_w` on each projected window. Defect: the binding window
/// charged one hour of burn per lane while its reset is days away, so an
/// account whose live lane will spend its week before the reset is read as
/// room and the launch walls both lanes. The weekly window at 90 percent
/// with 144 hours to its reset and one live lane: the live lane and the
/// candidate each charged the setting's weekly burn for 144 hours leave no
/// room under the bound, so the launch is refused with the weekly window
/// as the projected one; the same account with its reset one hour away
/// is the lane.
#[test]
fn the_binding_window_is_charged_to_its_reset_not_for_one_hour() {
    let world = World::new(&[]);
    let mut far = measured("aclaude", 90, 5);
    far["binding_resets_at"] = json!(stamp(now() + 144 * 3600));
    far["resets"]["weekly"] = json!(stamp(now() + 144 * 3600));
    world.plant_listing(&[far]);
    let child = Owned::sleep();
    world.write_fleet(
        vec![lane(
            "KEN-1",
            "/home/me/.aclaude",
            child.pid(),
            &child.start(),
        )],
        None,
    );
    let refused = world.pick(&claude(None));
    assert_eq!(
        (
            refused["answer"].clone(),
            refused["record"]["walled"].clone()
        ),
        (json!("none"), json!(1)),
        "a reset six days away charges the week: {refused}"
    );
    assert_eq!(
        left_out(&refused),
        vec![("/home/me/.aclaude".to_owned(), "walled".to_owned())]
    );
    // The projected window is the weekly one, charged for the two lanes to
    // its reset: 2 × (5 × 5/168) × 144 hours, about 43 points, against
    // the 10 left.
    let judged = world.pick(&named("/home/me/.aclaude", claude(None)));
    assert_eq!(judged["answer"], json!("walled"), "{judged}");
    assert_eq!(
        judged["record"]["projected_window"]["bucket"],
        json!("weekly")
    );
    let room = judged["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (-33.5..-32.0).contains(&room),
        "the room left after the charge to the reset: {room}"
    );
    let mut near = measured("aclaude", 90, 5);
    near["binding_resets_at"] = json!(stamp(now() + 3600));
    near["resets"]["weekly"] = json!(stamp(now() + 3600));
    world.plant_listing(&[near]);
    let admitted = world.pick(&claude(None));
    assert_eq!(
        chosen(&admitted).as_deref(),
        Some("/home/me/.aclaude"),
        "a reset one hour away charges one hour: {admitted}"
    );
    drop(child);
}

/// The seat's limit, `min(ORCH_LANE_MAX_PCT, 100 - ORCH_OVERSEER_HEADROOM_PCT)`,
/// and `pick-seat-omitted` naming `need=`; `lanes --help` § pick's seat
/// rule. Defect: the `min` dropped, so a worker spends the overseer's
/// seat down to the lane limit and past the headroom the overseer hands
/// off at; or an overseer's own pick refusing its seat; or the omitted
/// seat named with no figure for the room it keeps, or with one the hook's
/// seat line cannot read (`need=50.0`). The fleet record's
/// `overseer.account` is a seat: returned last, held to the headroom
/// setting beside the lane limit (`seat-reserve` under it, the record and
/// the `none` answer's `seats` carrying `need` as the integer `50`, the
/// room the seat keeps), and judged as any account when the overseer asks.
#[test]
fn a_seat_is_held_to_the_overseers_headroom_beside_the_lane_limit_and_returned_last() {
    let world = World::new(&[("ORCH_OVERSEER_HEADROOM_PCT", "50")]);
    world.plant_listing(&[measured("seat", 10, 5), measured("worker", 60, 5)]);
    world.write_fleet(Vec::new(), Some("/home/me/.seat"));
    let worker = world.pick(&claude(None));
    assert_eq!(
        chosen(&worker).as_deref(),
        Some("/home/me/.worker"),
        "{worker}"
    );
    // The seat at 55 used projects past 50 and under 95: refused under the
    // overseer's headroom alone.
    world.plant_listing(&[measured("seat", 55, 5)]);
    let reserved = world.pick(&claude(None));
    assert_eq!(reserved["answer"], json!("none"), "{reserved}");
    assert_eq!(
        left_out(&reserved),
        vec![("/home/me/.seat".to_owned(), "seat-reserve".to_owned())]
    );
    let seats = reserved["record"]["seats"].as_array().unwrap();
    assert_eq!(seats.len(), 1, "{reserved}");
    assert_eq!(
        seats[0]["need"],
        json!(50),
        "the omitted seat names the room it keeps, spelled as the callers read it"
    );
    let named = world.pick(&named("/home/me/.seat", claude(None)));
    assert_eq!(named["answer"], json!("walled"), "{named}");
    assert_eq!(named["record"]["verdict"], json!("seat-reserve"));
    assert_eq!(named["record"]["need"], json!(50));
    assert_eq!(named["record"]["seat"], json!(true));
    let overseer = world.pick(&PickRequest {
        for_overseer: true,
        ..claude(None)
    });
    assert_eq!(
        chosen(&overseer).as_deref(),
        Some("/home/me/.seat"),
        "{overseer}"
    );
    assert_eq!(
        overseer["record"].get("need"),
        None,
        "no seat, no room kept"
    );
}

/// The provider's rows under a host are the judge's
/// own, read from the roster with the host. Defect: a hosted pick judged
/// on this machine's rows, or handed to the reader as a `pick` the judge no
/// longer asks; a provider's `seat=1` row spent past the overseer's
/// headroom by a worker; a provider's `reserved=1` row picked for its
/// room. Under `ORCH_LANE_HOST=fleet-vm` the reader lists the provider's
/// rows: the seat with the most room is held to the headroom and comes
/// last, the reserved row is never the lane, the ordinary row is; with
/// the ordinary row excluded the seat is the lane while over its limit and
/// `seat-reserve` under it; the reader is asked for the listing under the
/// host and nothing else, and the host's capability line once.
#[test]
fn a_hosted_pick_reads_the_providers_rows_seats_and_words_from_the_roster_under_its_host() {
    let world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let mut seat = through_host(measured("seat", 10, 5));
    seat["seat"] = json!(1);
    let mut reserved = through_host(measured("held", 5, 5));
    reserved["reserved"] = json!("1");
    world.plant_host_listing(
        "fleet-vm",
        &[seat, reserved, through_host(measured("worker", 60, 5))],
    );
    // This machine's own listing names another account entirely: a pick
    // judged on it would pick that.
    world.plant_listing(&[measured("local", 0, 0)]);
    let chosen_row = world.pick(&claude(None));
    assert_eq!(
        chosen(&chosen_row).as_deref(),
        Some("/home/me/.worker"),
        "the provider's ordinary row, not its seat or its reserved row, nor the local listing: {chosen_row}"
    );
    let seat_last = world.pick(&PickRequest {
        exclude: vec!["/home/me/.worker".to_owned()],
        ..claude(None)
    });
    assert_eq!(
        chosen(&seat_last).as_deref(),
        Some("/home/me/.seat"),
        "{seat_last}"
    );
    assert_eq!(seat_last["record"]["seat"], json!(true));
    assert_eq!(
        seat_last["record"]["need"],
        json!(5),
        "the seat is held to min(95, 100 - 5) under the default headroom, keeping 5"
    );
    assert_eq!(
        left_out(&world.pick(&PickRequest {
            exclude: vec!["/home/me/.worker".to_owned(), "/home/me/.seat".to_owned()],
            ..claude(None)
        })),
        vec![("/home/me/.held".to_owned(), "reserved".to_owned())]
    );
    // The seat past the headroom under a tighter setting: omitted with its
    // need, never spent by a worker.
    let tight = World::new(&[
        ("ORCH_LANE_HOST", "fleet-vm"),
        ("ORCH_OVERSEER_HEADROOM_PCT", "40"),
    ]);
    tight.write_fleet(Vec::new(), None);
    tight.plant_capabilities("fleet-vm", SSH_LINE);
    let mut spent_seat = through_host(measured("seat", 55, 5));
    spent_seat["seat"] = json!(1);
    tight.plant_host_listing("fleet-vm", &[spent_seat]);
    let omitted = tight.pick(&claude(None));
    assert_eq!(omitted["answer"], json!("none"), "{omitted}");
    assert_eq!(omitted["record"]["seats"][0]["need"], json!(40));
    // A named reserved account under the host is refused by its word.
    let named = world.pick(&PickRequest {
        lane: Some("/home/me/.held".to_owned()),
        ..claude(None)
    });
    assert_eq!(named["answer"], json!("reserved"), "{named}");
    assert_eq!(named["record"]["alias"], json!("held"));
    let log = world.log();
    assert!(
        !log.is_empty()
            && log
                .iter()
                .all(|l| l == "ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE=emptied list --json"),
        "the reader lists under the host and is asked for no pick: {log:?}"
    );
    assert_eq!(
        world.host_log().first().map(String::as_str),
        Some("ORCH_LANE_HOST=fleet-vm capabilities"),
        "{:?}",
        world.host_log()
    );
}

/// `lanes`' `host_row_or_local`: the listing carries
/// this machine's reading of a billed account and the provider's beside
/// it, local first, and a pick judges one of them. Defect: both readings
/// judged as two accounts, so a provider's refusal or reservation never
/// stops the local copy and a launch lands on a credential whose own
/// reading refuses it, or a usable provider copy is refused on its dead
/// local copy; or the provider's reading, measured with no window scoped
/// to the launch's model, judged on its shared windows where this machine
/// read the model's own. The same account at local wall 0 and provider
/// wall 99 on a seat: the chooser refuses and the named reading names the
/// provider's `seat-reserve`. A Claude account the provider measured
/// without the model's window: the local reading's model window decides,
/// and with none the account is unmeasured for that model; without a model
/// the provider's reading stands. A provider row that read nothing, an
/// `unreachable` one or a holding with no figure, leaves this machine's
/// measured reading in place.
#[test]
fn one_reading_per_billed_account_the_providers_eligible_reading_over_this_machines_copy() {
    let world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let mut local = measured("aclaude", 0, 0);
    local["model_buckets"] =
        json!([{"label": "Opus", "pct": 0, "resets_at": stamp(now() + 60 * 3600)}]);
    let mut provider = through_host(measured("aclaude", 99, 99));
    provider["seat"] = json!("1");
    provider["verdict"] = json!("walled");
    world.plant_host_listing("fleet-vm", &[local, provider]);
    let refused = world.pick(&claude(None));
    assert_eq!(
        refused["answer"],
        json!("none"),
        "the provider's reading of the one account, not this machine's copy: {refused}"
    );
    assert_eq!(
        left_out(&refused),
        vec![("/home/me/.aclaude".to_owned(), "seat-reserve".to_owned())]
    );
    assert_eq!(refused["record"]["seats"][0]["need"], json!(5));
    let named_seat = world.pick(&named("/home/me/.aclaude", claude(None)));
    assert_eq!(named_seat["answer"], json!("walled"), "{named_seat}");
    assert_eq!(named_seat["record"]["verdict"], json!("seat-reserve"));
    assert_eq!(named_seat["record"]["measured_through"], json!("host"));
    assert_eq!(named_seat["record"]["wall"], json!(99));
    // The model's window: the provider measured the shared windows alone.
    let mut local = measured("tclaude", 10, 5);
    local["model_buckets"] =
        json!([{"label": "Fable 5.1", "pct": 95, "resets_at": stamp(now() + 60 * 3600)}]);
    let provider = through_host(measured("tclaude", 20, 5));
    world.plant_host_listing("fleet-vm", &[local.clone(), provider.clone()]);
    let fable = claude(Some("claude-fable-5-1"));
    let scoped = world.pick(&named("/home/me/.tclaude", fable.clone()));
    assert_eq!(
        scoped["answer"],
        json!("walled"),
        "this machine's Fable window, not the provider's weekly one: {scoped}"
    );
    assert_eq!(scoped["record"]["measured_through"], json!("local"));
    assert_eq!(scoped["record"]["binding_bucket"], json!("model"));
    assert_eq!(scoped["record"]["wall"], json!(95));
    assert_eq!(
        left_out(&world.pick(&fable)),
        vec![("/home/me/.tclaude".to_owned(), "walled".to_owned())]
    );
    let unscoped = world.pick(&claude(None));
    assert_eq!(
        chosen(&unscoped).as_deref(),
        Some("/home/me/.tclaude"),
        "{unscoped}"
    );
    assert_eq!(unscoped["record"]["measured_through"], json!("host"));
    assert_eq!(unscoped["record"]["wall"], json!(20));
    local["model_buckets"] = json!([]);
    world.plant_host_listing("fleet-vm", &[local, provider]);
    let unread = world.pick(&PickRequest {
        lane: Some("/home/me/.tclaude".to_owned()),
        ..fable
    });
    assert_eq!(
        unread["answer"],
        json!("unmeasured"),
        "no reading of the model's window on either side: {unread}"
    );
    assert_eq!(unread["exit"], json!(5));
    assert_eq!(unread["record"]["status"], json!("no_usage_data"));
    assert_eq!(
        unread["record"]["detail"],
        json!("no fresh local model window for claude-fable-5-1")
    );
    // A provider row that read nothing leaves this machine's reading.
    let mut unreachable = through_host(measured("uclaude", 10, 5));
    unreachable["status"] = json!("unreachable");
    unreachable["headroom_pct"] = Value::Null;
    unreachable["verdict"] = json!("unmeasured");
    let mut holding = through_host(measured("hclaude", 10, 5));
    holding["status"] = json!("no_usage_data");
    holding["headroom_pct"] = Value::Null;
    holding["verdict"] = json!("unmeasured");
    world.plant_host_listing(
        "fleet-vm",
        &[
            measured("uclaude", 10, 5),
            measured("hclaude", 30, 5),
            unreachable,
            holding,
        ],
    );
    let own = world.pick(&claude(None));
    assert_eq!(chosen(&own).as_deref(), Some("/home/me/.uclaude"), "{own}");
    assert_eq!(own["record"]["measured_through"], json!("local"));
    assert_eq!(
        own["record"]["qualifying_count"],
        json!(2),
        "both accounts judged on this machine's reading: {own}"
    );
}

/// `lanes --help` § pick's tier 0: a grant, the
/// allowance that expires and does not refill, is spent before any plan
/// window, the one that expires first first. Defect: a plan window spent
/// while a cloud grant with room expires unspent; two grants spent in the
/// wrong order; a Pi API grant pick judged on plan rows; a grant pool
/// nobody measured answered as a wall to wait out. Two cloud grants and a
/// plan account with more room: the grant ending sooner is the lane; that
/// grant under the floor is `walled` and the later one is the lane; a Pi
/// `anthropic/` pick reads the `api-credit` rows alone, and with none
/// measured is `pick-provider-unmeasured`, exit 5.
#[test]
fn a_grant_is_spent_before_a_plan_window_the_one_expiring_first_first() {
    let world = World::new(&[]);
    let later = grant(
        "later",
        "claude",
        "cloud-credit",
        50.0,
        100.0,
        &stamp(now() + 5 * 86_400),
    );
    let sooner = grant(
        "sooner",
        "claude",
        "cloud-credit",
        50.0,
        100.0,
        &stamp(now() + 2 * 86_400),
    );
    let listing = [later.clone(), sooner, measured("plan", 10, 5)];
    let rows = rows(&listing, &world.settings);
    let facts = FleetFacts::default();
    let chosen = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&chosen).as_deref(),
        Some("/home/me/.sooner"),
        "{chosen:?}"
    );
    let PickAnswer::Lane(judged) = &chosen else {
        panic!("{chosen:?}");
    };
    assert_eq!(judged.record()["binding_bucket"], json!("credits"));
    assert_eq!(judged.record()["headroom_pct"], json!(50));
    assert_eq!(judged.record()["qualifying_count"], json!(3));
    let spent = grant(
        "sooner",
        "claude",
        "cloud-credit",
        5.0,
        100.0,
        &stamp(now() + 2 * 86_400),
    );
    let rows = self::rows(&[later, spent, measured("plan", 10, 5)], &world.settings);
    let next = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&next).as_deref(),
        Some("/home/me/.later"),
        "the grant under the floor is walled, the later grant still before the plan: {next:?}"
    );
    let walled = accounts::pick(
        &rows[1..2],
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        exclusions(&walled),
        vec![("/home/me/.sooner".to_owned(), "walled".to_owned())]
    );
    assert_eq!(
        walled.reply()["record"]["walled_resets_at"],
        Value::Null,
        "a grant names no reset to wait for"
    );
    // The Pi API grant: the `api-credit` rows of the `pi` harness alone.
    let api = grant(
        "grant",
        "pi",
        "api-credit",
        20.0,
        25.0,
        &stamp(now() + 12 * 86_400),
    );
    let mut unread = grant(
        "dark",
        "pi",
        "api-credit",
        20.0,
        25.0,
        &stamp(now() + 12 * 86_400),
    );
    unread["status"] = json!("unreachable");
    unread["headroom_pct"] = Value::Null;
    unread["verdict"] = json!("unmeasured");
    let pi = PickRequest {
        harness: "pi".to_owned(),
        model: Some("anthropic/claude-opus-5".to_owned()),
        ..PickRequest::default()
    };
    let rows = self::rows(
        &[api, unread.clone(), measured("plan", 10, 5)],
        &world.settings,
    );
    let chosen = accounts::pick(&rows, &pi, &facts, &world.settings.accounts, now());
    assert_eq!(
        picked(&chosen).as_deref(),
        Some("/home/me/.grant"),
        "{chosen:?}"
    );
    let rows = self::rows(&[unread], &world.settings);
    let unmeasured = accounts::pick(&rows, &pi, &facts, &world.settings.accounts, now());
    assert!(
        matches!(&unmeasured, PickAnswer::ProviderUnmeasured { harness, model } if harness == "pi" && model == "anthropic/claude-opus-5"),
        "{unmeasured:?}"
    );
    assert_eq!(unmeasured.exit(), 5);
    assert_eq!(
        unmeasured.reply()["record"]["refusal"]["cause"],
        json!("provider-unmeasured")
    );
}

/// The succession walk's and the turn-end hook's trigger (`lib/overseer-
/// launch.sh` `ol_pick_record`, `hooks/lane-mail-check.sh`'s account mark;
/// step8-map § 0.4): `--min-headroom-pct T` is the bound `100 - T` in the
/// record's own unit, and `--binding-floor` holds the account's own
/// binding bucket to the bound beside the model's window. Defect: a
/// trigger admitting an account under the threshold because the setting's
/// bound is looser; a successor opened on an account whose own binding
/// bucket, a window of a model it never launches, is at the mark it would
/// hand off on at once. An account at 85 used is room under the setting
/// and walled under a trigger of 20, named or chosen; the account whose
/// Opus window is spent is the Sonnet lane without the floor and not with
/// it.
#[test]
fn the_trigger_is_the_bound_in_the_records_unit_and_the_floor_holds_the_accounts_own_bucket() {
    let world = World::new(&[]);
    let rows = rows(&[measured("aclaude", 85, 5)], &world.settings);
    let facts = FleetFacts::default();
    let loose = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(picked(&loose).as_deref(), Some("/home/me/.aclaude"));
    let trigger = PickRequest {
        min_headroom_pct: Some(20),
        ..claude(None)
    };
    let tight = accounts::pick(&rows, &trigger, &facts, &world.settings.accounts, now());
    assert!(
        matches!(&tight, PickAnswer::None { walled: 1, .. }),
        "the trigger's bound, 80 used, refuses the account at 85: {tight:?}"
    );
    let named = accounts::pick(
        &rows,
        &PickRequest {
            lane: Some("/home/me/.aclaude".to_owned()),
            ..trigger
        },
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert!(
        matches!(&named, PickAnswer::Walled(j) if j.limit == 80.0),
        "{named:?}"
    );
    assert_eq!(named.exit(), 3);
    // The floor: the account's own binding bucket is its spent Opus window.
    let mut split = measured("split", 20, 5);
    split["headroom_pct"] = json!(2);
    split["binding_bucket"] = json!("model");
    split["model_buckets"] = json!([
        {"label": "Opus 5", "pct": 98, "resets_at": stamp(now() + 4 * 86_400)},
        {"label": "Sonnet 5.5", "pct": 10, "resets_at": stamp(now() + 4 * 86_400)}
    ]);
    let rows = self::rows(&[split], &world.settings);
    let sonnet = claude(Some("claude-sonnet-5-5"));
    let open = accounts::pick(&rows, &sonnet, &facts, &world.settings.accounts, now());
    assert_eq!(
        picked(&open).as_deref(),
        Some("/home/me/.split"),
        "{open:?}"
    );
    let floored = accounts::pick(
        &rows,
        &PickRequest {
            binding_floor: true,
            ..sonnet
        },
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert!(
        matches!(&floored, PickAnswer::None { walled: 1, .. }),
        "the account's own Opus window, held to the bound, refuses it: {floored:?}"
    );
}

/// The candidate lane charged: the candidate
/// is a lane in the projection's charge, and the reset bonus
/// `1 + 1 / (1 + hours to the binding reset)` is the selection score's
/// weight, never a charge. Defect: the bonus read as the candidate's
/// charge, so a sooner reset buys a launch past the bound or the
/// candidate spends nothing; the order among rooms ignoring the reset.
/// Two accounts at one wall with resets one hour and a hundred hours
/// away: the sooner reset is the lane, and its projected room is the room
/// less the candidate's own charge to that reset; the account at the
/// bound with a reset a minute away is never the lane over one with room.
#[test]
fn the_candidate_lane_is_charged_and_the_reset_bonus_orders_rooms_without_buying_a_launch() {
    let world = World::new(&[]);
    let mut soon = measured("soon", 50, 5);
    soon["binding_resets_at"] = json!(stamp(now() + 3600));
    soon["resets"]["weekly"] = json!(stamp(now() + 3600));
    let mut late = measured("late", 50, 5);
    late["binding_resets_at"] = json!(stamp(now() + 100 * 3600));
    late["resets"]["weekly"] = json!(stamp(now() + 100 * 3600));
    let rows = rows(&[late.clone(), soon], &world.settings);
    let facts = FleetFacts::default();
    let chosen = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&chosen).as_deref(),
        Some("/home/me/.soon"),
        "{chosen:?}"
    );
    let PickAnswer::Lane(judged) = &chosen else {
        panic!("{chosen:?}");
    };
    let projection = judged.projection.as_ref().unwrap();
    // One candidate lane, the weekly burn 5 × 5/168 a point an hour, one
    // hour to the reset: the room is 50 less that charge.
    assert!(
        (49.8..50.0).contains(&projection.headroom),
        "the candidate's own charge to the reset: {}",
        projection.headroom
    );
    let score = judged.score.unwrap();
    assert!(
        score > projection.headroom && score <= 2.0 * projection.headroom,
        "the bonus weights the room, at most twofold: {score}"
    );
    // The late account's candidate is charged a hundred hours of burn.
    let late_judged = accounts::pick(
        &rows,
        &named("/home/me/.late", claude(None)),
        &facts,
        &world.settings.accounts,
        now(),
    );
    let PickAnswer::Lane(late_judged) = &late_judged else {
        panic!("{late_judged:?}");
    };
    let late_room = late_judged.projection.as_ref().unwrap().headroom;
    assert!((34.0..36.0).contains(&late_room), "{late_room}");
    // At the bound with a reset a minute away: no bonus buys the launch.
    let mut full = measured("full", 95, 5);
    full["binding_resets_at"] = json!(stamp(now() + 60));
    full["resets"]["weekly"] = json!(stamp(now() + 60));
    let rows = self::rows(&[full, late], &world.settings);
    let bounded = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&bounded).as_deref(),
        Some("/home/me/.late"),
        "{bounded:?}"
    );
}

/// `lane-model.sh`'s fixed sample divisor: the session
/// window's observed usage is shared among the lanes live at the sample,
/// never among the lanes live now. Defect: a cached sample divided by the
/// current live-lane count, so every lane launched since the sample
/// dilutes the per-lane burn it measured and a fifth lane is admitted onto
/// an account the five will exhaust before the reset. One sample held
/// constant, 60 percent of the session four hours in and taken 240 seconds
/// ago with one lane live, while three more lanes join after it: the fifth
/// candidate is charged the sample's per-lane rate, 15 points an hour for
/// five lanes to the reset, and the room is -35, the shell's answer on the
/// same sample; the same sample taken now counts every lane live now.
#[test]
fn a_cached_sample_keeps_the_occupancy_held_with_it_as_lanes_join() {
    let world = World::new(&[]);
    let mut row = measured("aclaude", 70, 60);
    row["resets"]["session"] = json!(stamp(now() + 3360));
    row["binding_resets_at"] = json!(stamp(now() + 6 * 3600));
    row["resets"]["weekly"] = json!(stamp(now() + 6 * 3600));
    row["usage_age_s"] = json!(240);
    world.plant_listing(&[row.clone()]);
    let children: Vec<Owned> = (0..4).map(|_| Owned::sleep()).collect();
    let launched = [now() - 3600, now() - 180, now() - 120, now() - 60];
    world.write_fleet(
        children
            .iter()
            .zip(launched)
            .enumerate()
            .map(|(i, (child, at))| {
                lane_launched(
                    &format!("KEN-{}", i + 1),
                    "/home/me/.aclaude",
                    child.pid(),
                    &child.start(),
                    at,
                )
            })
            .collect(),
        None,
    );
    let fifth = world.pick(&named("/home/me/.aclaude", claude(None)));
    assert_eq!(fifth["answer"], json!("walled"), "{fifth}");
    assert_eq!(
        fifth["record"]["projected_window"]["bucket"],
        json!("session")
    );
    let room = fifth["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 35.0).abs() < 0.01,
        "the sample's one lane is the divisor, so the five lanes are charged 15 an hour each: {room}"
    );
    assert_eq!(fifth["record"]["claims"], json!(4));
    assert_eq!(
        (world.pick(&claude(None))["record"]["walled"]).clone(),
        json!(1)
    );
    // The same sample taken now, four hours into the session: the four
    // lanes were live at it, so each is charged a quarter of its rate.
    row["usage_age_s"] = json!(0);
    row["resets"]["session"] = json!(stamp(now() + 3600));
    world.plant_listing(&[row]);
    let fresh = world.pick(&named("/home/me/.aclaude", claude(None)));
    assert_eq!(fresh["answer"], json!("lane"), "{fresh}");
    let room = fresh["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!((room - 21.25).abs() < 0.01, "{room}");
    drop(children);
}

/// The instant a lane began spending on its account: `session_since`,
/// which every launch and relaunch rewrites
/// and a wake keeps, else `running_at`, else `launched_at`. Defect: the
/// sample's occupancy counted from `launched_at`, which a relaunch keeps
/// from the lane's first launch, so a lane relaunched onto this account
/// after the sample (a wall moving several lanes onto one account within
/// the cache's serve age) counts as live at it and dilutes the per-lane
/// burn. The sample of the row above, with one lane on the account since
/// before it and three lanes first launched two hours ago elsewhere and
/// relaunched onto the account after it: the three are not counted, the
/// fifth candidate's room is -35, `walled`.
#[test]
fn a_lane_relaunched_onto_the_account_after_the_sample_spent_none_of_it() {
    let world = World::new(&[]);
    let mut row = measured("aclaude", 70, 60);
    row["resets"]["session"] = json!(stamp(now() + 3360));
    row["binding_resets_at"] = json!(stamp(now() + 6 * 3600));
    row["resets"]["weekly"] = json!(stamp(now() + 6 * 3600));
    row["usage_age_s"] = json!(240);
    world.plant_listing(&[row]);
    let children: Vec<Owned> = (0..4).map(|_| Owned::sleep()).collect();
    let since = [now() - 3600, now() - 180, now() - 120, now() - 60];
    world.write_fleet(
        children
            .iter()
            .zip(since)
            .enumerate()
            .map(|(i, (child, at))| {
                let launched = if i == 0 { at } else { now() - 7200 };
                let mut lane = lane_launched(
                    &format!("KEN-{}", i + 1),
                    "/home/me/.aclaude",
                    child.pid(),
                    &child.start(),
                    launched,
                );
                lane["session_since"] = json!(stamp(at));
                lane["running_at"] = json!(stamp(at));
                lane
            })
            .collect(),
        None,
    );
    let fifth = world.pick(&named("/home/me/.aclaude", claude(None)));
    assert_eq!(fifth["answer"], json!("walled"), "{fifth}");
    let room = fifth["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 35.0).abs() < 0.01,
        "the three relaunched lanes began on the account after the sample: {room}"
    );
    assert_eq!(fifth["record"]["claims"], json!(4));
    drop(children);
}

/// `lane-model.sh`'s measured rate: the rate the reader measured on
/// the binding window is the whole account's delta, shared among the lanes
/// live at the sample, except on a model window, which no lane on another
/// model spends. Defect: the measured rate charged whole per lane, now for
/// the hours to the reset, so an account with two live lanes and 14 points
/// of room is walled. The weekly window at 50 with 80 hours to its reset,
/// 0.3 points an hour measured across two live lanes: the candidate's room
/// is 14, the per-lane share's, and the record carries the reader's rate
/// fields, since the judged window is the reader's; a model window at 50
/// with the same rate is charged the rate whole and walled; a window the
/// reader did not rate carries `one-sample`. The window's identity carries
/// its label (`lane-model.sh`'s `same_window`): two
/// model windows at one reset are two windows, so a Fable read of an
/// account whose reader rated its Opus window carries `one-sample` and no
/// rate, never Opus's measured rate, which the mark judge would ask
/// succession on.
#[test]
fn a_measured_binding_rate_is_the_per_lane_share_of_the_lanes_live_at_the_sample() {
    let world = World::new(&[]);
    let reset = stamp(now() + 80 * 3600);
    let mut weekly = measured("acc", 50, 5);
    weekly["binding_resets_at"] = json!(reset);
    weekly["resets"]["weekly"] = json!(reset);
    weekly["usage_rate_state"] = json!("measured");
    weekly["usage_rate_pct_per_min"] = json!(0.005);
    weekly["projected_wall_minutes"] = json!(10_000);
    let mut model = measured("bclaude", 10, 5);
    model["headroom_pct"] = json!(50);
    model["binding_bucket"] = json!("model");
    model["binding_resets_at"] = json!(reset);
    model["wall"] = json!(50);
    model["model_label"] = json!("Opus 5");
    model["model_buckets"] = json!([{"label": "Opus 5", "pct": 50, "resets_at": reset}]);
    model["usage_rate_state"] = json!("measured");
    model["usage_rate_pct_per_min"] = json!(0.005);
    model["projected_wall_minutes"] = json!(10_000);
    world.plant_listing(&[weekly, model]);
    let children: Vec<Owned> = (0..4).map(|_| Owned::sleep()).collect();
    world.write_fleet(
        children
            .iter()
            .enumerate()
            .map(|(i, child)| {
                let account = if i < 2 {
                    "/home/me/.acc"
                } else {
                    "/home/me/.bclaude"
                };
                lane(
                    &format!("KEN-{}", i + 1),
                    account,
                    child.pid(),
                    &child.start(),
                )
            })
            .collect(),
        None,
    );
    let shared = world.pick(&named("/home/me/.acc", claude(None)));
    assert_eq!(shared["answer"], json!("lane"), "{shared}");
    let room = shared["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room - 14.0).abs() < 0.01,
        "three lanes at the per-lane share 0.15 for 80 hours: {room}"
    );
    assert_eq!(shared["record"]["burn_pct_per_lane_hour"], json!(0.15));
    assert_eq!(shared["record"]["usage_rate_state"], json!("measured"));
    assert_eq!(shared["record"]["projected_wall_minutes"], json!(10_000));
    let opus = world.pick(&named("/home/me/.bclaude", claude(Some("claude-opus-5"))));
    assert_eq!(opus["answer"], json!("walled"), "{opus}");
    let room = opus["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 22.0).abs() < 0.01,
        "a model window's rate is one lane's, charged whole: {room}"
    );
    assert_eq!(opus["record"]["usage_rate_state"], json!("measured"));
    // A window the reader did not rate: the Sonnet lane on bclaude is
    // judged on the weekly window, whose rate nobody measured.
    let sonnet = world.pick(&named(
        "/home/me/.bclaude",
        claude(Some("claude-sonnet-5-5")),
    ));
    assert_eq!(
        sonnet["record"]["binding_bucket"],
        json!("weekly"),
        "{sonnet}"
    );
    assert_eq!(sonnet["record"]["usage_rate_state"], json!("one-sample"));
    assert_eq!(sonnet["record"]["usage_rate_pct_per_min"], Value::Null);
    assert_eq!(sonnet["record"]["projected_wall_minutes"], Value::Null);
    // Two model windows at one reset: the reader rated the Opus window,
    // and the Fable window beside it is another window.
    let mut split = measured("split", 10, 5);
    split["headroom_pct"] = json!(10);
    split["binding_bucket"] = json!("model");
    split["binding_resets_at"] = json!(reset);
    split["wall"] = json!(90);
    split["model_label"] = json!("Opus");
    split["model_buckets"] = json!([
        {"label": "Fable 5.1", "pct": 20, "resets_at": reset},
        {"label": "Opus", "pct": 90, "resets_at": reset},
    ]);
    split["usage_rate_state"] = json!("measured");
    split["usage_rate_pct_per_min"] = json!(0.5);
    split["projected_wall_minutes"] = json!(20);
    world.plant_listing(&[split]);
    let fable = world.pick(&PickRequest {
        lane: Some("/home/me/.split".to_owned()),
        for_overseer: true,
        ..claude(Some("claude-fable-5-1"))
    });
    assert_eq!(fable["record"]["wall"], json!(20), "{fable}");
    assert_eq!(
        fable["record"]["usage_rate_state"],
        json!("one-sample"),
        "the reader rated Opus, not the Fable window at the same reset: {fable}"
    );
    assert_eq!(fable["record"]["usage_rate_pct_per_min"], Value::Null);
    assert_eq!(fable["record"]["projected_wall_minutes"], Value::Null);
    let opus = world.pick(&PickRequest {
        lane: Some("/home/me/.split".to_owned()),
        for_overseer: true,
        ..claude(Some("claude-opus-5"))
    });
    assert_eq!(opus["record"]["wall"], json!(90), "{opus}");
    assert_eq!(opus["record"]["usage_rate_state"], json!("measured"));
    assert_eq!(opus["record"]["projected_wall_minutes"], json!(20));
    drop(children);
}

/// The Pi Copilot pool (`lanes --help` § pick, the Pi
/// `github-copilot/` arm): the pool a Pi launch spends is never listed, so
/// the judge reads it beside the listing. Defect: a `github-copilot/` Pi
/// model with no candidate, so the repository's own second-opinion room
/// check skips with room and the succession walk and the turn-end mark
/// lose the account kind; the owner's stated pool never read; a provider's
/// reading of the pool not replacing the statement; a statement for a
/// Copilot CLI home or an excluded lane judged as a Pi root. The stated
/// override makes the chooser answer that root with its monthly use and
/// headroom through `stated`, and the named form judges it; a named
/// excluded root is refused by its word, `excluded`, exit 3; the provider's
/// `harness=pi` row with a reading replaces the statement, one without a
/// reading leaves it standing; a failed provider read with nothing stated
/// is `copilot-pool-unread`, and nothing stated and nothing read is
/// `unmeasured`, exit 5, a read to repair.
#[test]
fn a_pi_copilot_pool_is_judged_from_the_providers_row_or_the_owners_statement() {
    let root = "/home/me/.pi1".to_owned();
    let cli = "/home/me/.cli".to_owned();
    let excluded = "/home/me/.pi2".to_owned();
    let pool = format!("{root}=100000/1000000,{cli}=1/10,{excluded}=1/10");
    let world = World::new(&[
        ("ORCH_LANE_HOST", "fleet-vm"),
        ("ORCH_LANE_COPILOT_POOL", &pool),
        ("ORCH_LANE_EXCLUDE", "pi2"),
    ]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    // The listing names a Copilot CLI home, which is no Pi root, and a Pi
    // API grant, which is another pool.
    let mut home = through_host(measured("cli", 10, 5));
    home["harness"] = json!("copilot");
    home["config_dir"] = json!(cli);
    home["pool"] = json!("copilot");
    let api = grant(
        "api",
        "pi",
        "api-credit",
        20.0,
        25.0,
        &stamp(now() + 86_400),
    );
    world.plant_host_listing("fleet-vm", &[home, api]);
    let copilot = PickRequest {
        harness: "pi".to_owned(),
        model: Some("github-copilot/claude-opus-5-5".to_owned()),
        ..PickRequest::default()
    };
    let stated = world.pick(&copilot);
    assert_eq!(
        chosen(&stated).as_deref(),
        Some(root.as_str()),
        "the stated root, not the CLI home, the excluded root or the API grant: {stated}"
    );
    let record = &stated["record"];
    assert_eq!(record["measured_through"], json!("stated"));
    assert_eq!(record["monthly_pct"], json!(10));
    assert_eq!(record["headroom_pct"], json!(90));
    assert_eq!(record["binding_bucket"], json!("monthly"));
    assert_eq!(record["alias"], json!("pi1"));
    assert_eq!(record["pool"], json!("copilot"));
    assert_eq!(record["qualifying_count"], json!(1));
    let named_root = world.pick(&PickRequest {
        lane: Some(root.clone()),
        ..copilot.clone()
    });
    assert_eq!(named_root["answer"], json!("lane"), "{named_root}");
    assert_eq!(named_root["record"]["measured_through"], json!("stated"));
    let left_out = world.pick(&PickRequest {
        lane: Some(excluded.clone()),
        ..copilot.clone()
    });
    assert_eq!(left_out["answer"], json!("excluded"), "{left_out}");
    assert_eq!(left_out["exit"], json!(3));
    assert_eq!(left_out["record"]["verdict"], json!("excluded"));
    assert!(
        world.log().contains(
            &"ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE=emptied host-accounts --harness pi --json"
                .to_owned()
        ),
        "the provider's pool rows are asked for under the host: {:?}",
        world.log()
    );
    // The provider's reading of the root replaces the statement.
    let mut provider = through_host(measured("pi1", 0, 0));
    provider["harness"] = json!("pi");
    provider["config_dir"] = json!(root);
    provider["monthly_pct"] = json!(60);
    provider["headroom_pct"] = json!(40);
    provider["binding_bucket"] = json!("monthly");
    provider["binding_resets_at"] = json!(stamp(now() + 10 * 86_400));
    provider["weekly_pct"] = Value::Null;
    provider["session_5h_pct"] = Value::Null;
    provider.as_object_mut().unwrap().remove("verdict");
    provider.as_object_mut().unwrap().remove("pool");
    world.plant_host_accounts("fleet-vm", &[provider.clone()]);
    let read = world.pick(&copilot);
    assert_eq!(chosen(&read).as_deref(), Some(root.as_str()), "{read}");
    assert_eq!(read["record"]["measured_through"], json!("host"));
    assert_eq!(read["record"]["headroom_pct"], json!(40));
    assert_eq!(read["record"]["wall"], json!(60));
    // A provider row that read nothing leaves the statement standing.
    provider["status"] = json!("no_usage_data");
    provider["monthly_pct"] = Value::Null;
    provider["headroom_pct"] = Value::Null;
    world.plant_host_accounts("fleet-vm", &[provider]);
    let standing = world.pick(&copilot);
    assert_eq!(
        standing["record"]["measured_through"],
        json!("stated"),
        "{standing}"
    );
    assert_eq!(standing["record"]["headroom_pct"], json!(90));
    // A failed read is answered by the statement; with none it is unread.
    std::fs::write(world.path().join("host-accounts.rc"), "1\n").unwrap();
    assert_eq!(
        world.pick(&copilot)["record"]["measured_through"],
        json!("stated")
    );
    let bare = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    bare.write_fleet(Vec::new(), None);
    bare.plant_capabilities("fleet-vm", SSH_LINE);
    std::fs::write(bare.path().join("host-accounts.rc"), "1\n").unwrap();
    let unread = bare.pick(&copilot);
    assert_eq!(unread["answer"], json!("unjudged"), "{unread}");
    assert!(
        unread["record"]["cause"]
            .as_str()
            .unwrap()
            .starts_with("copilot-pool-unread host=fleet-vm exit=1"),
        "{unread}"
    );
    std::fs::write(bare.path().join("host-accounts.rc"), "2\n").unwrap();
    let unstated = bare.pick(&copilot);
    assert_eq!(unstated["answer"], json!("unmeasured"), "{unstated}");
    assert_eq!(unstated["exit"], json!(5));
    assert_eq!(
        unstated["record"]["refusal"]["cause"],
        json!("provider-unmeasured")
    );
}

/// `lanes --help` § pick's cloud-session rule, and the boundary's
/// isolation: a `cloud-session` host's
/// account is admitted only where `ORCH_LANE_CLOUD_REPOS` gives it this
/// checkout's repository, read by a `git` child of the judge. Defect: a
/// cloud session opened on an account with no access to the repository,
/// which fails after the launch; an origin nobody can read admitting
/// every account; the judge's `git` child reading the operator's own
/// `~/.gitconfig` in place of the boundary's home. Under a host whose
/// capability line says `launch=cloud-session`, with the checkout's origin
/// on github.com, the account the setting names for that repository
/// (compared as GitHub reads names, without case) is the lane, the other
/// is `cloud-repo-unset` among the exclusions and refused by name at exit
/// 7; with no origin none is admitted; under an SSH host the rule does not
/// apply. Under a home of the row's own whose `.gitconfig` rewrites the
/// origin's owner to `canary`, the account given `canary/repo` is the
/// lane: the production `git` child read the home it was handed.
#[test]
fn a_cloud_session_host_admits_only_an_account_with_access_to_this_repository() {
    let mut world = World::new(&[
        ("ORCH_LANE_HOST", "cloud-x"),
        (
            "ORCH_LANE_CLOUD_REPOS",
            "aclaude=Owner/Repo,bclaude=canary/repo",
        ),
    ]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("cloud-x", CLOUD_LINE);
    world.plant_host_listing(
        "cloud-x",
        &[
            through_host(measured("aclaude", 50, 5)),
            through_host(measured("bclaude", 10, 5)),
        ],
    );
    // A repository of the row's own, with no origin yet: the world is
    // never read as the checkout it was made under.
    let git = |args: &[&str]| {
        let out = program("git")
            .arg("-C")
            .arg(world.path())
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    };
    git(&["init", "-q"]);
    let no_origin = world.pick(&claude(None));
    assert_eq!(
        left_out(&no_origin),
        vec![
            (
                "/home/me/.aclaude".to_owned(),
                "cloud-repo-unset".to_owned()
            ),
            (
                "/home/me/.bclaude".to_owned(),
                "cloud-repo-unset".to_owned()
            ),
        ],
        "no origin to read, no account admitted: {no_origin}"
    );
    git(&[
        "remote",
        "add",
        "origin",
        "https://github.com/owner/repo.git",
    ]);
    let admitted = world.pick(&claude(None));
    assert_eq!(
        chosen(&admitted).as_deref(),
        Some("/home/me/.aclaude"),
        "the account with access, not the one with more room: {admitted}"
    );
    let named = world.pick(&PickRequest {
        lane: Some("/home/me/.bclaude".to_owned()),
        ..claude(None)
    });
    assert_eq!(named["answer"], json!("cloud-repo-unset"), "{named}");
    assert_eq!(named["exit"], json!(7));
    assert_eq!(named["record"]["alias"], json!("bclaude"));
    // The judge's `git` reads the home the boundary hands it.
    world.canary_home();
    let canary = world.pick(&claude(None));
    assert_eq!(
        chosen(&canary).as_deref(),
        Some("/home/me/.bclaude"),
        "the origin read through the row's own home, rewritten to canary/repo: {canary}"
    );
    // The rule is the cloud-session host's alone.
    let ssh = World::new(&[
        ("ORCH_LANE_HOST", "fleet-vm"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude=Owner/Repo"),
    ]);
    ssh.write_fleet(Vec::new(), None);
    ssh.plant_capabilities("fleet-vm", SSH_LINE);
    ssh.plant_host_listing(
        "fleet-vm",
        &[
            through_host(measured("aclaude", 50, 5)),
            through_host(measured("bclaude", 10, 5)),
        ],
    );
    assert_eq!(
        chosen(&ssh.pick(&claude(None))).as_deref(),
        Some("/home/me/.bclaude")
    );
}

/// The `accounts pick` verb: the reply a shell caller reads carries the
/// answer's word,
/// `lanes pick`'s exit by number and the record, so the launcher, the
/// walk, the hook and the mark judge read the verdict they read before;
/// an integral figure is spelled as an integer, the form the mark judge's
/// `^[0-9]{1,3}$` reads, a fraction as a fraction; `--min-headroom-pct` is
/// the callers' trigger; `--env` is the room check a consumer's
/// `SECOND_OPINION_<NAME>_ROOM_CMD` runs, the launch prefix on stdout at
/// exit 0 and the keyed line at the answer's exit otherwise. Defect: a
/// refusal exit where a judgement is an answer; the record missing the
/// fields the callers read (`config_dir`, `projected_window`, `wall`,
/// `binding_bucket`, `projected_headroom_pct`, `effective_headroom_pct`,
/// `qualifying_count`), or spelling `wall` as `20.0`, which the mark judge
/// reads as unreadable so the overseer's headroom mark never fires; the
/// trigger not on the verb; a room check reading a JSON reply as an
/// assignment.
#[test]
fn the_pick_verb_answers_the_judgement_with_the_legacy_exit_by_number() {
    let world = World::new(&[]);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    world.write_fleet(Vec::new(), None);
    let mut command = isolated();
    command
        .current_dir(world.path())
        .env("OVERSEE_WATCH_LANES", world.path().join("lanes"))
        .env("ORCH_STATE_DIR", world.path())
        .args([
            "accounts",
            "pick",
            "--fleet",
            "--harness",
            "claude",
            "--native-model",
            "claude-sonnet-5-5",
            "--lane",
            "/home/me/.aclaude",
            "--projected",
        ]);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let reply: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["ok"], json!(true));
    let result = &reply["result"];
    assert_eq!(result["answer"], json!("lane"));
    assert_eq!(result["exit"], json!(0));
    assert_eq!(result["record"]["config_dir"], json!("/home/me/.aclaude"));
    assert_eq!(result["record"]["binding_bucket"], json!("weekly"));
    assert_eq!(result["record"]["wall"], json!(20));
    assert_eq!(result["record"]["effective_headroom_pct"], json!(80));
    assert!(
        text.contains("\"wall\":20,") && text.contains("\"effective_headroom_pct\":80,"),
        "the integral figures are spelled as integers in the bytes the shell reads: {text}"
    );
    assert_eq!(
        result["record"]["projected_window"]["bucket"],
        json!("weekly")
    );
    let projected = &result["record"]["projected_headroom_pct"];
    assert!(
        projected.is_f64() && projected.as_i64().is_none(),
        "the candidate's charge to a reset 60 hours on leaves a fraction: {projected}"
    );
    assert_eq!(result["record"]["verdict"], json!("room"));
    // The named lane walled: exit 3 by number, the record under it.
    world.plant_listing(&[measured("aclaude", 96, 5)]);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["answer"], json!("walled"));
    assert_eq!(reply["result"]["exit"], json!(3));
    assert_eq!(reply["result"]["record"]["wall"], json!(96));
    // The chooser under the trigger: the count of rooms on the lane.
    world.plant_listing(&[measured("aclaude", 20, 5), measured("bclaude", 85, 5)]);
    let mut chooser = isolated();
    chooser
        .current_dir(world.path())
        .env("OVERSEE_WATCH_LANES", world.path().join("lanes"))
        .env("ORCH_STATE_DIR", world.path())
        .args([
            "accounts",
            "pick",
            "--fleet",
            "--harness",
            "claude",
            "--min-headroom-pct",
            "20",
            "--binding-floor",
        ]);
    let out = chooser.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        reply["result"]["record"]["config_dir"],
        json!("/home/me/.aclaude")
    );
    assert_eq!(
        reply["result"]["record"]["qualifying_count"],
        json!(1),
        "bclaude at 85 is under the trigger's bound of 80: {reply}"
    );
    // The room check: the prefix, then the keyed refusal at exit 3.
    let mut room = isolated();
    room.current_dir(world.path())
        .env("OVERSEE_WATCH_LANES", world.path().join("lanes"))
        .env("ORCH_STATE_DIR", world.path())
        .args([
            "accounts",
            "pick",
            "--env",
            "--fleet",
            "--harness",
            "claude",
            "--native-model",
            "claude-opus-5-5",
        ]);
    let out = room.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "CLAUDE_CONFIG_DIR=/home/me/.aclaude\n"
    );
    world.plant_listing(&[measured("aclaude", 96, 5)]);
    let out = room.output().unwrap();
    assert_eq!(out.status.code(), Some(3), "{}", stderr(&out));
    assert!(out.stdout.is_empty());
    assert_eq!(
        stderr(&out).trim(),
        "orch-runtime: account-none harness=claude exit=3"
    );
    // The roster verb: the rows with their words and the lines.
    let mut roster = isolated();
    roster
        .current_dir(world.path())
        .env("OVERSEE_WATCH_LANES", world.path().join("lanes"))
        .env("ORCH_LANE_RETIRE", "aclaude=2026-01-01")
        .args(["accounts", "roster"]);
    let out = roster.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["read"], json!(true));
    assert_eq!(
        reply["result"]["rows"][0]["word"],
        json!("retired:2026-01-01")
    );
    assert_eq!(reply["result"]["rows"][0]["ended"], json!(true));
    let lines = reply["result"]["lines"].as_array().unwrap();
    assert!(
        lines[1]
            .as_str()
            .unwrap()
            .starts_with("account-end-contradicted aclaude "),
        "{lines:?}"
    );
}

/// Defect: a named account the word refuses,
/// reserved or retired from its day, answered as `walled` with the wall's
/// figures, so the launcher refuses `lane-model-walled pct= bucket=` for
/// an account that has room, sending the operator to a usage wall that is
/// not there. The answer is the word's, at `lanes pick`'s exit 3 by
/// number (no caller learns a new number), its reply naming the word and
/// the record carrying `retired:<date>`.
#[test]
fn a_named_reserved_or_retired_account_is_refused_by_its_word_not_the_walls_figures() {
    let today = accounts::today(now());
    let world = World::new(&[("ORCH_LANE_RETIRE", &format!("oclaude={today}"))]);
    world.write_fleet(Vec::new(), None);
    let mut reserved = measured("rclaude", 10, 5);
    reserved["reserved"] = json!(1);
    world.plant_listing(&[reserved, measured("oclaude", 10, 5)]);
    let named_row = |dir: &str| world.pick(&named(dir, claude(Some("claude-sonnet-5-5"))));
    let reserved = named_row("/home/me/.rclaude");
    assert_eq!(reserved["answer"], json!("reserved"), "{reserved}");
    assert_eq!(reserved["exit"], json!(3));
    assert_eq!(reserved["record"]["verdict"], json!("reserved"));
    assert_eq!(reserved["record"]["word"], json!("reserve"));
    let retired = named_row("/home/me/.oclaude");
    assert_eq!(retired["answer"], json!("retired"), "{retired}");
    assert_eq!(retired["exit"], json!(3));
    assert_eq!(retired["record"]["word"], json!(format!("retired:{today}")));
    assert_eq!(retired["record"]["retire_date"], json!(today));
}

/// Defect: the
/// provider's `plan_ends` compared as text and never validated, so a
/// timestamp or a malformed value ends a day late or never, where the
/// machine's own `ORCH_LANE_RETIRE` is held to a calendar day. A value
/// that names no calendar day reads as invalid, not absent: the row keeps
/// its figures, is never picked (named among the exclusions, and a named
/// pick of it unjudged with the cause: an end nobody can read admits
/// nothing), and is one `account-plan-end-invalid` line under the roster.
#[test]
fn a_plan_end_that_names_no_calendar_day_leaves_the_row_unpicked_with_its_figures_said() {
    let world = World::new(&[]);
    let mut stamped = measured("v", 10, 5);
    stamped["plan_ends"] = json!("2026-10-21T00:00:00Z");
    let listing = [stamped, measured("w", 60, 5)];
    let rows = rows(&listing, &world.settings);
    let req = claude(None);
    let answer = accounts::pick(
        &rows,
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        picked(&answer).as_deref(),
        Some("/home/me/.w"),
        "the account with the most room is left out for the end nobody can read: {answer:?}"
    );
    let alone = accounts::pick(
        &rows[..1],
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        now(),
    );
    assert_eq!(picked(&alone), None);
    assert_eq!(
        exclusions(&alone),
        vec![("/home/me/.v".to_owned(), "plan-end-invalid".to_owned())]
    );
    let named = accounts::pick(
        &rows,
        &PickRequest {
            lane: Some("/home/me/.v".to_owned()),
            ..req.clone()
        },
        &FleetFacts::default(),
        &world.settings.accounts,
        now(),
    );
    assert_eq!(
        named,
        PickAnswer::Unjudged {
            cause: "plan-end-invalid alias=v value=2026-10-21T00:00:00Z".to_owned()
        }
    );
    let roster = Roster { rows };
    assert_eq!(
        roster.rows[0].word(),
        Word::PlanEndInvalid {
            value: "2026-10-21T00:00:00Z".to_owned()
        }
    );
    let weekly = stamp(now() + 60 * 3600);
    assert_eq!(
        roster.lines(&accounts::today(now())),
        vec![
            format!(
                "account v config_dir=/home/me/.v harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at={weekly} word=plan-end-invalid"
            ),
            format!(
                "account w config_dir=/home/me/.w harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at={weekly}"
            ),
            "account-plan-end-invalid alias=v value=2026-10-21T00:00:00Z".to_owned(),
        ]
    );
}

/// The settings' refusals, as `lanes` refused them: a retirement naming
/// no lane or no calendar day, a percentage past 100, a floor that is no
/// whole number, a cloud repository entry naming no `owner/repo`, a stated
/// Copilot pool naming no absolute root, no grant, a grant of nothing or
/// one root twice, an exclusion naming a path, and the retired key
/// `ORCH_OVERSEER_SEAT_RESERVE_PCT` read by nothing.
#[test]
fn a_statement_nobody_can_read_is_refused_by_key_and_value() {
    for (key, value) in [
        ("ORCH_LANE_RETIRE", "4claude"),
        ("ORCH_LANE_RETIRE", "4claude=2026-02-30"),
        ("ORCH_LANE_RETIRE", "=2026-10-20"),
        ("ORCH_LANE_RETIRE", "a/b=2026-10-20"),
        ("ORCH_LANE_MAX_PCT", "101"),
        ("ORCH_OVERSEER_HEADROOM_PCT", "-1"),
        ("ORCH_LANE_BURN_PCT_PER_HOUR", "five"),
        ("ORCH_LANE_CODEX_CREDIT_FLOOR", "1.5"),
        ("ORCH_LANE_CLOUD_CREDIT_FLOOR", "ten"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude=repo"),
        ("ORCH_LANE_CLOUD_REPOS", "=owner/repo"),
        ("ORCH_LANE_COPILOT_POOL", "pi1=1/10"),
        ("ORCH_LANE_COPILOT_POOL", "/h/.pi1=1"),
        ("ORCH_LANE_COPILOT_POOL", "/h/.pi1=1/0"),
        ("ORCH_LANE_COPILOT_POOL", "/h/.pi1=one/10"),
        ("ORCH_LANE_COPILOT_POOL", "/h/.pi1=1/10,/h/.pi1/=2/10"),
        ("ORCH_LANE_EXCLUDE", "/h/.pi1"),
        ("ORCH_LANE_EXCLUDE", "~pi1"),
        ("ORCH_LANE_RETIRE", "~pi1=2026-10-20"),
        ("ORCH_LANE_CLOUD_REPOS", "a~b=owner/repo"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let roots = Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let refused = settings::load(
            &roots,
            &[(OsString::from(key), OsString::from(value))],
            &SettingsFlags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        );
        let Err(error) = refused else {
            panic!("{key}={value} admitted");
        };
        assert_eq!(error.key(), "setting-invalid", "{key}={value}: {error}");
    }
    let world = World::new(&[
        (
            "ORCH_LANE_RETIRE",
            " 4claude = 2026-10-20 , ,6claude=2026-10-21",
        ),
        ("ORCH_LANE_MAX_PCT", "80"),
        ("ORCH_OVERSEER_SEAT_RESERVE_PCT", "not-a-setting"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude=owner/repo, b=o/r.git"),
        (
            "ORCH_LANE_COPILOT_POOL",
            "/h/.pi1=100000/1000000, /h/.pi2=10/10",
        ),
        ("ORCH_LANE_EXCLUDE", "sclaude, pi2"),
        (
            "ORCH_LANE_ALIASES",
            " pi1 = work ,bare,=nameless,empty=, .pi2=second",
        ),
    ]);
    assert_eq!(world.settings.accounts.max_pct, 80);
    assert_eq!(world.settings.accounts.overseer_headroom_pct, 5);
    assert_eq!(
        world
            .settings
            .accounts
            .retire
            .iter()
            .map(|r| (r.name.as_str(), r.date.as_str()))
            .collect::<Vec<_>>(),
        vec![("4claude", "2026-10-20"), ("6claude", "2026-10-21")]
    );
    assert_eq!(
        world
            .settings
            .accounts
            .cloud_repos
            .iter()
            .map(|r| (r.name.as_str(), r.repo.as_str()))
            .collect::<Vec<_>>(),
        vec![("aclaude", "owner/repo"), ("b", "o/r.git")]
    );
    assert_eq!(
        world
            .settings
            .accounts
            .copilot_pool
            .iter()
            .map(|p| (p.dir.as_str(), p.used, p.granted))
            .collect::<Vec<_>>(),
        vec![("/h/.pi1", 100_000, 1_000_000), ("/h/.pi2", 10, 10)]
    );
    assert_eq!(world.settings.accounts.exclude, vec!["sclaude", "pi2"]);
    // The alias overlay as `lanes` reads it: an item without `=` or with
    // an empty side is passed over, never refused.
    assert_eq!(
        world
            .settings
            .accounts
            .aliases
            .iter()
            .map(|a| (a.name.as_str(), a.alias.as_str()))
            .collect::<Vec<_>>(),
        vec![("pi1", "work"), (".pi2", "second")]
    );
}

/// The fetcher the shipped reader asks for a usage body (the shape of
/// `tests/lib/lanes-fixture.sh`'s `make_fetcher` stub): the HTTP status on
/// the first line and `$FIXTURE_DIR/<basename of the config dir>.json`
/// under it.
const FETCHER: &str = "#!/usr/bin/env bash
name=\"$(basename \"$2\")\"
printf '200 \\n'
f=\"$FIXTURE_DIR/$name.json\"
[[ -f \"$f\" ]] || exit 1
cat -- \"$f\"
";

/// The shipped reader's world: a home with one Claude lane,
/// `.aclaude`, whose usage the fetcher answers from a planted body, one
/// Codex lane, `.acodex`, whose plan windows are spent and whose credits
/// stand, and one Pi root, `.pi1`; a `tmux` that answers nothing and a `curl` that
/// refuses first on `PATH`; the provider fixture `tests/fixtures/lane-host`
/// with its rows planted per arm; a checkout of the row's own and a fleet
/// of the row's own. The runtime is asked through the boundary with the
/// shipped `scripts/lanes` as its reader.
struct Producer {
    dir: tempfile::TempDir,
    lanes: PathBuf,
    provider: PathBuf,
}

impl Producer {
    fn new() -> Producer {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let orch = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .to_path_buf();
        for sub in [
            "bin",
            "project",
            "home/.pi1",
            "home/.pi2",
            "state",
            "claims",
            "fixtures",
        ] {
            std::fs::create_dir_all(root.join(sub)).unwrap();
        }
        let executable = |name: &str, text: &str| {
            let path = root.join("bin").join(name);
            std::fs::write(&path, text).unwrap();
            std::fs::set_permissions(
                &path,
                <std::fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o755),
            )
            .unwrap();
        };
        executable("tmux", "#!/bin/sh\nexit 0\n");
        executable("curl", "#!/bin/sh\nexit 1\n");
        executable("fetch", FETCHER);
        let git = program("git")
            .args(["-C"])
            .arg(root.join("project"))
            .args(["init", "-q"])
            .output()
            .unwrap();
        assert!(git.status.success(), "{}", stderr(&git));
        let producer = Producer {
            dir,
            lanes: orch.join("scripts/lanes"),
            provider: orch.join("tests/fixtures/lane-host"),
        };
        producer.plant_lane();
        producer.write_fleet(Vec::new());
        producer
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn home(&self) -> PathBuf {
        self.path().join("home")
    }

    /// The Claude lane's config dir.
    fn claude(&self) -> String {
        self.home().join(".aclaude").display().to_string()
    }

    /// The Pi root.
    fn pi(&self) -> String {
        self.home().join(".pi1").display().to_string()
    }

    /// The Codex lane's config dir, listed only where an arm names it in
    /// `ORCH_LANE_DIRS`.
    fn codex(&self) -> String {
        self.home().join(".acodex").display().to_string()
    }

    /// The other Pi root, the one a statement or a provider row can name
    /// instead of the root a question names.
    fn other_pi(&self) -> String {
        self.home().join(".pi2").display().to_string()
    }

    /// The lane's credentials, as `make_lane` writes them: a token good for
    /// an hour, so the reader renews nothing.
    fn plant_lane(&self) {
        let dir = self.home().join(".aclaude");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(".credentials.json"),
            json!({"claudeAiOauth": {
                "accessToken": "token-aclaude", "refreshToken": "refresh-aclaude",
                "expiresAt": (now() + 3600) * 1000, "subscriptionType": "max",
            }})
            .to_string(),
        )
        .unwrap();
    }

    /// The usage body the fetcher answers for the Claude lane.
    fn plant_usage(&self, body: &Value) {
        std::fs::write(self.path().join("fixtures/.aclaude.json"), body.to_string()).unwrap();
    }

    fn plant_codex(&self) {
        let dir = self.home().join(".acodex");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("auth.json"),
            json!({"tokens": {"access_token": "token-acodex", "account_id": "acct-acodex"}})
                .to_string(),
        )
        .unwrap();
        let usage = json!({
            "rate_limit": {
                "primary_window": {"used_percent": 100, "reset_at": now() + 1800, "limit_window_seconds": 18_000},
                "secondary_window": {"used_percent": 100, "reset_at": now() + 86_400, "limit_window_seconds": 604_800}
            },
            "credits": {"has_credits": true, "unlimited": false, "overage_limit_reached": false, "balance": 6000},
            "spend_control": {"reached": false}
        });
        std::fs::write(self.path().join("fixtures/.acodex.json"), usage.to_string()).unwrap();
    }

    /// The provider's `accounts` rows.
    fn plant_provider(&self, rows: &str) {
        std::fs::write(self.path().join("provider.tsv"), rows).unwrap();
    }

    fn write_fleet(&self, lanes: Vec<Value>) {
        let fleet = json!({
            "issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": lanes, "fleet_log": []
        });
        std::fs::write(
            self.path().join("state").join(FLEET_FILE_NAME),
            serde_json::to_string(&fleet).unwrap(),
        )
        .unwrap();
    }

    /// The environment the reader and the runtime run under: the home,
    /// the lane, the fetcher, the state and cache directories, the
    /// provider (`host`) or the local read, the caches off, and the arm's
    /// own settings.
    fn env(&self, host: bool, extra: &[(&str, &str)]) -> Vec<(String, String)> {
        let root = self.path();
        let mut env: Vec<(String, String)> = [
            ("HOME", self.home().display().to_string()),
            ("LANES_HOME", self.home().display().to_string()),
            ("ORCH_LANE_DIRS", self.claude()),
            (
                "ORCH_LANES_FETCH_CMD",
                root.join("bin/fetch").display().to_string(),
            ),
            ("FIXTURE_DIR", root.join("fixtures").display().to_string()),
            ("ORCH_STATE_DIR", root.join("state").display().to_string()),
            (
                "OVERSEE_WATCH_STATE_DIR",
                root.join("claims").display().to_string(),
            ),
            ("OVERSEE_WATCH_LANES", self.lanes.display().to_string()),
            ("ORCH_LANES_USAGE_TTL", "0".to_owned()),
            ("ORCH_LANES_USAGE_MAX_AGE", "0".to_owned()),
            (
                "LANE_HOST_STUB_LOG",
                root.join("provider.log").display().to_string(),
            ),
            (
                "LANE_HOST_STUB_ACCOUNTS",
                root.join("provider.tsv").display().to_string(),
            ),
            (
                "ORCH_LANE_HOST",
                if host {
                    self.provider.display().to_string()
                } else {
                    "local".to_owned()
                },
            ),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect();
        env.extend(
            extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned())),
        );
        env
    }

    fn command(&self, env: &[(String, String)]) -> std::process::Command {
        let mut command = isolated();
        command
            .current_dir(self.path().join("project"))
            .env("PATH", tool_path(&[&self.path().join("bin")]));
        for (key, value) in env {
            command.env(key, value);
        }
        command
    }

    /// `accounts pick --fleet` with `flags`: the reply's `result`.
    fn pick(&self, env: &[(String, String)], flags: &[&str]) -> Value {
        let mut command = self.command(env);
        command.args(["accounts", "pick", "--fleet"]).args(flags);
        World::reply(command)
    }

    /// The reader's cache record of the Claude lane after one fresh
    /// listing (the caches off), for an arm that plants a sample's age or
    /// its prior before the runtime reads the record under a TTL.
    fn cache_record(&self) -> PathBuf {
        let mut listing = program(&self.lanes);
        listing
            .args(["list", "--json"])
            .current_dir(self.path().join("project"))
            .env("PATH", tool_path(&[&self.path().join("bin")]));
        for (key, value) in self.env(false, &[]) {
            listing.env(key, value);
        }
        let out = listing.output().unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let usage = self.path().join("claims/usage");
        std::fs::read_dir(&usage)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|e| e == "json"))
            .find(|path| {
                let record: Value =
                    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
                record["config_dir"] == json!(self.claude())
            })
            .unwrap_or_else(|| panic!("no cache record of {} under {usage:?}", self.claude()))
    }

    /// The record rewritten by `edit`, its normalized block dropped so the
    /// reader normalizes the planted body again.
    fn edit_record(&self, path: &Path, edit: impl FnOnce(&mut Value)) {
        let mut record: Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        edit(&mut record);
        record.as_object_mut().unwrap().remove("normalized");
        std::fs::write(path, record.to_string()).unwrap();
    }
}

/// A Claude usage body as the endpoint answers it: the 5-hour window, the
/// weekly window and the model-scoped windows, each with its reset.
fn usage_body(session: (u64, u64), weekly: (u64, u64), scoped: &[(&str, u64, u64)]) -> Value {
    json!({
        "five_hour": {"utilization": session.0, "resets_at": stamp(session.1)},
        "seven_day": {"utilization": weekly.0, "resets_at": stamp(weekly.1)},
        "limits": scoped.iter().map(|(label, pct, reset)| json!({
            "kind": "weekly_scoped", "percent": pct, "resets_at": stamp(*reset),
            "scope": {"model": {"display_name": label}},
        })).collect::<Vec<Value>>(),
    })
}

/// One question to the judge and its answer: the flags, the answer's
/// word, its exit, the exit the shell `lanes pick` verb this judge
/// replaces gave on the same world (`retained`, recorded from a run of
/// that verb) and the record's fields pinned by name.
struct Ask {
    flags: Vec<String>,
    answer: &'static str,
    exit: i64,
    retained: Option<i64>,
    record: Vec<(&'static str, Value)>,
}

/// One arm of the producer row: the input it proves, the usage body, the
/// provider's rows (none for a local read), the arm's settings and its
/// questions.
struct Arm<'a> {
    name: &'static str,
    usage: Value,
    provider: Option<String>,
    env: Vec<(&'static str, &'a str)>,
    asks: Vec<Ask>,
}

/// The shipped producers' worlds: the shipped `lanes` listing, its provider
/// fixture and its stated pool, read by the runtime through the boundary,
/// one arm per input the shell `lanes pick` verb this judge replaces read
/// and the judge must keep. Defect: a port that replaces a delegation drops
/// an input the delegate read (the provider's reading over this machine's
/// copy, the pool beside the listing, the alias overlay before an exclusion
/// and a retirement, the label in a model window's identity, the instant a
/// lane began on its account, the Pi root every directory is to the named
/// form, the refusal of a model nothing bills before either form, the
/// provider's Pi row of an excluded root the listing drops before the judge
/// sees it), and no row shows it because every row plants the listing
/// itself. The questions are one named and one chooser question per
/// reachable exit site of the shell verb's call graph (its `pick)`
/// dispatcher, `cmd_pick_lane`, `cmd_pick`, `named_account_judgment`,
/// `measure_lane`, `measure_copilot_pool`, `pick_host_rows`,
/// `host_row_or_local`, `emit_lane`, `validate_lane_settings`,
/// `lane_pick_harness`, `lane_tier_inputs`, `lane_host_pool` and
/// `lib/lane-model.sh`'s judge: `lane_judge`'s six verdict words, `credits`
/// among them, and `host_row_or_local`'s three triggers) for each pool kind
/// the site applies to (a local kind, the Codex credit balance, the Copilot
/// pool, the `anthropic/` API grant, a seat, the cloud credit), and one per
/// input that steers a pick to a site of its own (the exclusion, the
/// retirement, the aliases, the stated pool, the cloud repositories, the
/// headroom, the credit floor, the model, `--exclude-lane`,
/// `--for-overseer`, `--binding-floor` and `--projected`) for each pool kind
/// and each host form the verb dispatches on, this machine's read and a
/// provider host. A ruling pins instead: the claim store and the seats, which the fleet
/// state replaces; the settings refusal, which the loader owns; the
/// dispatcher's class form, unnamed harness, `--exclude-lane` beside
/// `--lane` and `--projected` without `--lane`, which no shipped caller
/// passes; the reader's sites inside `measure_lane`, whose statuses the
/// shipped `lanes list` still measures and whose one judge outcome,
/// unmeasured, the local kind's questions ask; the reader's own failures,
/// which an unread listing holds, and its caches; and a cell whose input
/// reaches the site another cell's question asks (the reader's exclusion of
/// a local kind on this machine's read and on the cloud credit, the fleet's
/// overseer seat beside the provider's, `--exclude-lane` on each pool, the
/// alias overlay on this machine's grant). A site the runtime answers
/// differently is a literal with its reason named in its arm (a retired or
/// excluded root or grant refused by its word at exit 3 where the shell
/// verb found no reading or an unstated pool at exit 5, judged the pool at
/// exit 0, admitted the grant at exit 0 or answered the unset repository at
/// exit 7; a provider row with `status=no_usage_data` and no figure leaving
/// this machine's reading in both forms). Each question's answers are
/// literals, the runtime's own and the shell verb's exit as recorded, never
/// an oracle run here.
#[test]
fn the_judge_answers_the_shipped_producers_worlds_as_the_retained_pick_does() {
    let producer = Producer::new();
    producer.plant_codex();
    let claude_dir = producer.claude();
    let codex_dir = producer.codex();
    let pi_dir = producer.pi();
    let other_pi = producer.other_pi();
    let no_lanes = producer.path().join("no-such-lanes").display().to_string();
    let pool = format!("{pi_dir}=100000/1000000");
    let spent_pool = format!("{pi_dir}=960000/1000000");
    let other_pool = format!("{other_pi}=100000/1000000");
    let missing_claude = producer.home().join(".bclaude").display().to_string();
    let fresh = usage_body(
        (0, now() + 1800),
        (0, now() + 7 * 86_400),
        &[("Opus", 0, now() + 7 * 86_400)],
    );
    let exhausted = usage_body(
        (99, now() + 1800),
        (99, now() + 7 * 86_400),
        &[("Opus", 0, now() + 7 * 86_400)],
    );
    let claude_row = |fields: &str| format!("account={claude_dir}\tharness=claude{fields}\n");
    let codex_row = |fields: &str| format!("account={codex_dir}\tharness=codex{fields}\n");
    let pi_row = |fields: &str| format!("account={pi_dir}\tharness=pi{fields}\n");
    let other_pi_row = |fields: &str| format!("account={other_pi}\tharness=pi{fields}\n");
    let flags = |words: &[&str]| {
        words
            .iter()
            .map(|w| (*w).to_owned())
            .collect::<Vec<String>>()
    };
    let claude_chooser = || flags(&["--harness", "claude"]);
    let claude_named = || flags(&["--harness", "claude", "--lane", &claude_dir]);
    let pi_model = "github-copilot/claude-opus-5-5";
    let api_model = "anthropic/claude-opus-5-5";
    let pi_chooser = || flags(&["--harness", "pi", "--native-model", pi_model]);
    // The chooser's form on a Pi model: the API grant, or a model whose
    // provider nothing bills.
    let model_chooser = |model: &str| flags(&["--harness", "pi", "--native-model", model]);
    let api_chooser = || model_chooser(api_model);
    // The succession walk's question on a Pi preference entry's model.
    let walk_chooser = |model: &str| {
        flags(&[
            "--harness",
            "pi",
            "--min-headroom-pct",
            "5",
            "--for-overseer",
            "--binding-floor",
            "--native-model",
            model,
        ])
    };
    let codex_chooser = || flags(&["--harness", "codex"]);
    let codex_named = || flags(&["--harness", "codex", "--lane", &codex_dir, "--projected"]);
    // The provider's API grant row for the Pi root with `remaining` of 200
    // dollars left, expiring tomorrow.
    let grant_row = |remaining: u64| {
        pi_row(&format!(
            "\tcredit-limit=200.00\tcredit-spent=50.00\tcredit-remaining={remaining}\tcredit-expires={}",
            stamp(now() + 86_400)
        ))
    };
    // The dispatcher's own `claude-cloud` capability line (`scripts/lane-host`),
    // the one the shipped `lane-host` admits from a provider.
    let cloud_line = "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none\trelaunch=fresh\tpark=none\taccounts=none\tpool=cloud-credit\tland=handoff\tpane=local";
    let pi_named = || {
        flags(&[
            "--harness",
            "pi",
            "--native-model",
            pi_model,
            "--lane",
            &pi_dir,
        ])
    };
    // The launcher's form of the named question (`open-terminal`'s
    // `named_lane_judge`): the named root on the projection.
    let named_launch = |model: &str, dir: &str| {
        flags(&[
            "--harness",
            "pi",
            "--native-model",
            model,
            "--lane",
            dir,
            "--projected",
        ])
    };
    let ask = |flags: Vec<String>,
               answer: &'static str,
               exit: i64,
               retained: Option<i64>,
               record: Vec<(&'static str, Value)>| Ask {
        flags,
        answer,
        exit,
        retained,
        record,
    };
    let lane = |through: &str, wall: u64| {
        vec![
            ("measured_through", json!(through)),
            ("verdict", json!("room")),
            ("wall", json!(wall)),
        ]
    };
    let none = |walled: u64, unmeasured: u64| {
        vec![("walled", json!(walled)), ("unmeasured", json!(unmeasured))]
    };
    // A Codex account whose plan windows are spent and whose credits admit
    // the launch: room on the `credits` bucket.
    let credits = || {
        vec![
            ("measured_through", json!("local")),
            ("verdict", json!("room")),
            ("binding_bucket", json!("credits")),
            ("seat", json!(true)),
        ]
    };
    let provider_unmeasured = || {
        vec![(
            "refusal",
            json!({"cause": "provider-unmeasured", "retry_at": null}),
        )]
    };
    // The record the shell verb's named form printed for a Pi root on the
    // Copilot pool that nothing measured (`measure_copilot_pool`), and for
    // one on the API grant with no provider row (`emit_lane ...
    // no_usage_data`, judged by the grant tier).
    let pool_unmeasured = || {
        vec![
            ("measured_through", json!("stated")),
            ("status", json!("no_usage_data")),
            ("verdict", json!("unmeasured")),
            ("pool", json!("copilot")),
            ("wall", Value::Null),
        ]
    };
    let grant_unmeasured = || {
        vec![
            ("status", json!("no_usage_data")),
            ("detail", json!("no provider API-credit row")),
            ("verdict", json!("unmeasured")),
            ("pool", json!("api-credit")),
            ("refusal", json!({"cause": "api-credit", "retry_at": null})),
        ]
    };
    // The named answer for a model whose provider nothing bills: the
    // harness and the model, and no refusal the launcher's named arm would
    // read as its judge failing.
    let unbilled = |model: &str| {
        vec![
            ("harness", json!("pi")),
            ("model", json!(model)),
            ("refusal", Value::Null),
        ]
    };
    let api_refusal = || json!({"cause": "api-credit", "retry_at": null});
    let copilot_word = |verdict: &str, alias: &str| {
        vec![
            ("verdict", json!(verdict)),
            ("alias", json!(alias)),
            ("pool", json!("copilot")),
        ]
    };
    let copilot_retired = || {
        vec![
            ("verdict", json!("retired")),
            ("pool", json!("copilot")),
            ("retire_date", json!("2026-01-01")),
        ]
    };
    // The provider's grant row with 100 dollars left, admitted under a
    // floor below it.
    let floor_room = || {
        vec![
            ask(
                api_chooser(),
                "lane",
                0,
                Some(0),
                vec![("verdict", json!("room")), ("pool", json!("api-credit"))],
            ),
            ask(
                named_launch(api_model, &pi_dir),
                "lane",
                0,
                Some(0),
                vec![
                    ("measured_through", json!("host")),
                    ("verdict", json!("room")),
                    ("pool", json!("api-credit")),
                ],
            ),
        ]
    };
    let retired_root = |dir: &str| {
        vec![(
            "exclusions",
            json!([{"config_dir": dir, "reason": "retired"}]),
        )]
    };
    let arms = vec![
        Arm {
            name: "the provider's seat over this machine's copy of the account",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=99\tweekly-pct=99\tseat=1")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    claude_named(),
                    "walled",
                    3,
                    Some(3),
                    vec![
                        ("measured_through", json!("host")),
                        ("verdict", json!("seat-reserve")),
                        ("wall", json!(99)),
                        ("need", json!(5)),
                    ],
                ),
                ask(
                    flags(&["--harness", "claude", "--for-overseer"]),
                    "none",
                    3,
                    Some(3),
                    none(1, 0),
                ),
            ],
        },
        Arm {
            name: "a provider row that read nothing leaves this machine's reading",
            usage: fresh.clone(),
            provider: Some(claude_row("\tstatus=unreachable")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(0), lane("local", 0)),
                ask(claude_named(), "lane", 0, Some(0), lane("local", 0)),
            ],
        },
        Arm {
            name: "the provider's room over this machine's exhausted copy",
            usage: exhausted.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(0), lane("host", 10)),
                ask(claude_named(), "lane", 0, Some(0), lane("host", 10)),
            ],
        },
        Arm {
            name: "a provider refusal stands over this machine's room, and refuses the named local kind as unmeasured",
            usage: fresh.clone(),
            provider: Some(claude_row(
                "\tstatus=no_credentials\tdetail=http-403-permission_error",
            )),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "none", 3, Some(3), none(0, 1)),
                ask(
                    claude_named(),
                    "unmeasured",
                    5,
                    Some(5),
                    vec![
                        ("measured_through", json!("host")),
                        ("status", json!("no_credentials")),
                        ("verdict", json!("unmeasured")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a provider holding with no figure leaves this machine's reading",
            usage: fresh.clone(),
            provider: Some(claude_row("")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(0), lane("local", 0)),
                ask(claude_named(), "lane", 0, Some(0), lane("local", 0)),
            ],
        },
        Arm {
            name: "a provider no_usage_data row with no figure leaves this machine's reading, where the retained pick refused",
            usage: fresh.clone(),
            provider: Some(claude_row("\tstatus=no_usage_data")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(3), lane("local", 0)),
                ask(claude_named(), "lane", 0, Some(5), lane("local", 0)),
            ],
        },
        Arm {
            name: "a local account the listing does not hold is no record, and the launcher proceeds as it did",
            usage: fresh.clone(),
            provider: None,
            env: vec![],
            asks: vec![
                ask(
                    flags(&[
                        "--harness",
                        "claude",
                        "--lane",
                        &missing_claude,
                        "--projected",
                    ]),
                    "no-record",
                    4,
                    Some(4),
                    vec![],
                ),
                ask(
                    flags(&["--harness", "claude", "--exclude-lane", &claude_dir]),
                    "none",
                    3,
                    Some(3),
                    none(0, 0),
                ),
            ],
        },
        Arm {
            name: "a Pi launch on a model naming no provider, or on a provider nothing bills, is refused before any row is read, local",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_COPILOT_POOL", &pool)],
            asks: vec![
                ask(
                    named_launch("other/model", &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    unbilled("other/model"),
                ),
                ask(
                    model_chooser("other/model"),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch("sonnet:high", &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    unbilled("sonnet:high"),
                ),
                ask(
                    model_chooser("sonnet:high"),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "the same under a provider host",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![("ORCH_LANE_COPILOT_POOL", &pool)],
            asks: vec![
                ask(
                    named_launch("other/model", &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    unbilled("other/model"),
                ),
                ask(
                    model_chooser("other/model"),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch("sonnet:high", &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    unbilled("sonnet:high"),
                ),
                ask(
                    model_chooser("sonnet:high"),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "the owner's stated pool with no provider",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_COPILOT_POOL", &pool)],
            asks: vec![
                ask(pi_chooser(), "lane", 0, Some(0), lane("stated", 10)),
                ask(pi_named(), "lane", 0, Some(0), lane("stated", 10)),
            ],
        },
        Arm {
            name: "the owner's stated pool at the bound is walled by the named form",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_COPILOT_POOL", &spent_pool)],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(3), none(1, 0)),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "walled",
                    3,
                    Some(3),
                    vec![
                        ("measured_through", json!("stated")),
                        ("verdict", json!("walled")),
                        ("wall", json!(96)),
                    ],
                ),
            ],
        },
        Arm {
            name: "the provider's pool row over the statement, its reset carried",
            usage: fresh.clone(),
            provider: Some(pi_row(
                "\tmonthly-pct=60\tmonthly-resets=2026-12-01T00:00:00Z",
            )),
            env: vec![("ORCH_LANE_COPILOT_POOL", &pool)],
            asks: vec![
                ask(
                    pi_chooser(),
                    "lane",
                    0,
                    Some(0),
                    vec![
                        ("measured_through", json!("host")),
                        ("verdict", json!("room")),
                        ("wall", json!(60)),
                        ("binding_resets_at", json!("2026-12-01T00:00:00Z")),
                    ],
                ),
                ask(pi_named(), "lane", 0, Some(0), lane("host", 60)),
            ],
        },
        Arm {
            name: "a provider pool row with no reading leaves the statement",
            usage: fresh.clone(),
            provider: Some(pi_row("\tstatus=no_usage_data")),
            env: vec![("ORCH_LANE_COPILOT_POOL", &pool)],
            asks: vec![
                ask(pi_chooser(), "lane", 0, Some(0), lane("stated", 10)),
                ask(pi_named(), "lane", 0, Some(0), lane("stated", 10)),
            ],
        },
        Arm {
            name: "the provider's pool row with nothing stated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![],
            asks: vec![
                ask(pi_chooser(), "lane", 0, Some(0), lane("host", 60)),
                ask(pi_named(), "lane", 0, Some(0), lane("host", 60)),
            ],
        },
        Arm {
            name: "a provider pool row with no reading and nothing stated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tstatus=no_usage_data")),
            env: vec![],
            asks: vec![
                ask(
                    pi_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    vec![
                        ("status", json!("no_usage_data")),
                        ("verdict", json!("unmeasured")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a provider without the verb and nothing stated: the named Pi root is a pool nobody measured",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![("LANE_HOST_STUB_NO_ACCOUNTS", "1")],
            asks: vec![
                ask(
                    pi_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    pool_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "a failed provider verb and nothing stated",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![("LANE_HOST_STUB_ACCOUNTS_STATUS", "1")],
            asks: vec![
                ask(pi_chooser(), "unjudged", 1, Some(1), vec![]),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "unjudged",
                    1,
                    Some(1),
                    vec![],
                ),
            ],
        },
        Arm {
            name: "a named Pi root on the Copilot pool with nothing stated, this machine's read",
            usage: fresh.clone(),
            provider: None,
            env: vec![],
            asks: vec![
                ask(
                    pi_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    pool_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "a named Pi root with the pool stated for another root",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_COPILOT_POOL", &other_pool)],
            asks: vec![ask(
                named_launch(pi_model, &pi_dir),
                "unmeasured",
                5,
                Some(5),
                pool_unmeasured(),
            )],
        },
        Arm {
            name: "a named Pi root with provider pool rows for another root only",
            usage: fresh.clone(),
            provider: Some(other_pi_row("\tmonthly-pct=60")),
            env: vec![],
            asks: vec![ask(
                named_launch(pi_model, &pi_dir),
                "unmeasured",
                5,
                Some(5),
                pool_unmeasured(),
            )],
        },
        Arm {
            name: "a named Pi root on the API grant, this machine's read",
            usage: fresh.clone(),
            provider: None,
            env: vec![],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    grant_unmeasured(),
                ),
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "a named Pi root on the API grant under a provider with rows for another root only",
            usage: fresh.clone(),
            provider: Some(other_pi_row("\tmonthly-pct=60")),
            env: vec![],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    grant_unmeasured(),
                ),
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "the API grant under a provider whose accounts read failed is unjudged, a retry can answer it",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![("LANE_HOST_STUB_ACCOUNTS_STATUS", "1")],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "unjudged",
                    1,
                    Some(1),
                    vec![],
                ),
                ask(api_chooser(), "unjudged", 1, Some(1), vec![]),
            ],
        },
        Arm {
            name: "a measured API grant with room is the lane",
            usage: fresh.clone(),
            provider: Some(grant_row(150)),
            env: vec![],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "lane",
                    0,
                    Some(0),
                    vec![
                        ("measured_through", json!("host")),
                        ("verdict", json!("room")),
                        ("pool", json!("api-credit")),
                        ("headroom_pct", json!(75)),
                    ],
                ),
                ask(
                    api_chooser(),
                    "lane",
                    0,
                    Some(0),
                    vec![("pool", json!("api-credit")), ("headroom_pct", json!(75))],
                ),
                ask(
                    flags(&[
                        "--harness",
                        "pi",
                        "--native-model",
                        api_model,
                        "--exclude-lane",
                        &pi_dir,
                    ]),
                    "none",
                    3,
                    Some(3),
                    none(0, 0),
                ),
            ],
        },
        Arm {
            name: "a spent API grant is walled with the grant's refusal",
            usage: fresh.clone(),
            provider: Some(grant_row(0)),
            env: vec![],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "walled",
                    3,
                    Some(3),
                    vec![
                        ("verdict", json!("walled")),
                        ("pool", json!("api-credit")),
                        ("refusal", api_refusal()),
                    ],
                ),
                ask(api_chooser(), "none", 3, Some(3), none(1, 0)),
            ],
        },
        Arm {
            name: "an unread API grant row is unmeasured with the grant's refusal",
            usage: fresh.clone(),
            provider: Some(pi_row(
                "\tstatus=unreachable\tdetail=api-credit-tokens-unreadable",
            )),
            env: vec![],
            asks: vec![
                ask(
                    named_launch(api_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    vec![
                        ("status", json!("unreachable")),
                        ("verdict", json!("unmeasured")),
                        ("pool", json!("api-credit")),
                        ("refusal", api_refusal()),
                    ],
                ),
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "the alias overlay before the exclusion of a stated root, refused by its word where the retained named pick judged the pool",
            usage: fresh.clone(),
            provider: None,
            env: vec![
                ("ORCH_LANE_COPILOT_POOL", &pool),
                ("ORCH_LANE_ALIASES", "pi1=work"),
                ("ORCH_LANE_EXCLUDE", "work"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(0),
                    vec![("verdict", json!("excluded")), ("alias", json!("work"))],
                ),
            ],
        },
        Arm {
            name: "the exclusion of a stated root by its directory name, refused by its word where the retained named pick judged the pool",
            usage: fresh.clone(),
            provider: None,
            env: vec![
                ("ORCH_LANE_COPILOT_POOL", &pool),
                ("ORCH_LANE_EXCLUDE", "pi1"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(0),
                    vec![("verdict", json!("excluded")), ("alias", json!("pi1"))],
                ),
            ],
        },
        Arm {
            name: "the alias overlay before the retirement of a stated root, refused by its word where the retained pick found no root",
            usage: fresh.clone(),
            provider: None,
            env: vec![
                ("ORCH_LANE_COPILOT_POOL", &pool),
                ("ORCH_LANE_ALIASES", "pi1=work"),
                ("ORCH_LANE_RETIRE", "work=2026-01-01"),
            ],
            asks: vec![
                ask(
                    pi_chooser(),
                    "none",
                    3,
                    Some(5),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": pi_dir, "reason": "retired"}]),
                    )],
                ),
                ask(
                    pi_named(),
                    "retired",
                    3,
                    Some(5),
                    vec![
                        ("alias", json!("work")),
                        ("retire_date", json!("2026-01-01")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a retired local kind is refused by its word where the retained pick measured it unmeasured",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_RETIRE", "aclaude=2026-01-01")],
            asks: vec![
                ask(
                    claude_chooser(),
                    "none",
                    3,
                    Some(3),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": claude_dir, "reason": "retired"}]),
                    )],
                ),
                ask(
                    claude_named(),
                    "retired",
                    3,
                    Some(5),
                    vec![
                        ("alias", json!("aclaude")),
                        ("retire_date", json!("2026-01-01")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a local kind at its wall is walled by name",
            usage: exhausted.clone(),
            provider: None,
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "none", 3, Some(3), none(1, 0)),
                ask(
                    claude_named(),
                    "walled",
                    3,
                    Some(3),
                    vec![("verdict", json!("walled")), ("wall", json!(99))],
                ),
            ],
        },
        Arm {
            name: "a provider-only target discovery does not hold is judged on the provider's row",
            usage: fresh.clone(),
            provider: Some(format!(
                "account={missing_claude}\tharness=claude\tsession-5h-pct=10\tweekly-pct=10\n"
            )),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(0), vec![]),
                ask(
                    flags(&[
                        "--harness",
                        "claude",
                        "--lane",
                        &missing_claude,
                        "--projected",
                    ]),
                    "lane",
                    0,
                    Some(0),
                    lane("host", 10),
                ),
            ],
        },
        Arm {
            name: "a seat with room is the lane, named and chosen",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10\tseat=1")),
            env: vec![],
            asks: vec![
                ask(claude_chooser(), "lane", 0, Some(0), lane("host", 10)),
                ask(claude_named(), "lane", 0, Some(0), lane("host", 10)),
            ],
        },
        Arm {
            name: "a cloud-session host admits no account where the checkout names no origin",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![("LANE_HOST_STUB_CAPABILITIES", cloud_line)],
            asks: vec![
                ask(
                    claude_chooser(),
                    "none",
                    3,
                    Some(3),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": claude_dir, "reason": "cloud-repo-unset"}]),
                    )],
                ),
                ask(
                    claude_named(),
                    "cloud-repo-unset",
                    7,
                    Some(7),
                    vec![("verdict", json!("cloud-repo-unset"))],
                ),
            ],
        },
        Arm {
            name: "a Claude launch on a model: the provider's row without the model's window leaves this machine's model reading",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![],
            asks: vec![
                ask(
                    flags(&["--harness", "claude", "--native-model", "claude-opus-5"]),
                    "lane",
                    0,
                    Some(0),
                    lane("local", 0),
                ),
                ask(
                    flags(&[
                        "--harness",
                        "claude",
                        "--native-model",
                        "claude-opus-5",
                        "--lane",
                        &claude_dir,
                        "--projected",
                    ]),
                    "lane",
                    0,
                    Some(0),
                    lane("local", 0),
                ),
            ],
        },
        Arm {
            name: "a Claude launch on a model: neither reading carries the model's window, so the launch is unmeasured",
            usage: usage_body((0, now() + 1800), (0, now() + 7 * 86_400), &[]),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![],
            asks: vec![
                ask(
                    flags(&["--harness", "claude", "--native-model", "claude-opus-5"]),
                    "none",
                    3,
                    Some(3),
                    none(0, 1),
                ),
                ask(
                    flags(&[
                        "--harness",
                        "claude",
                        "--native-model",
                        "claude-opus-5",
                        "--lane",
                        &claude_dir,
                        "--projected",
                    ]),
                    "unmeasured",
                    5,
                    Some(5),
                    vec![
                        ("measured_through", json!("local")),
                        ("status", json!("no_usage_data")),
                        (
                            "detail",
                            json!("no fresh local model window for claude-opus-5"),
                        ),
                    ],
                ),
            ],
        },
        Arm {
            name: "a Codex seat whose plan windows are spent spends its credits: room on the credits bucket, named and chosen",
            usage: fresh.clone(),
            provider: Some(codex_row("\tseat=1")),
            env: vec![("ORCH_LANE_DIRS", &codex_dir)],
            asks: vec![
                ask(codex_chooser(), "lane", 0, Some(0), credits()),
                ask(codex_named(), "lane", 0, Some(0), credits()),
            ],
        },
        Arm {
            name: "the API grant whose root ORCH_LANE_EXCLUDE names is a candidate left out by name, refused by its word where the retained named pick judged no row",
            usage: fresh.clone(),
            provider: Some(grant_row(150)),
            env: vec![("ORCH_LANE_EXCLUDE", "pi1")],
            asks: vec![
                ask(api_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(walk_chooser(api_model), "none", 3, Some(3), none(0, 0)),
                ask(
                    named_launch(api_model, &pi_dir),
                    "excluded",
                    3,
                    Some(5),
                    vec![
                        ("verdict", json!("excluded")),
                        ("alias", json!("pi1")),
                        ("pool", json!("api-credit")),
                    ],
                ),
            ],
        },
        Arm {
            name: "the excluded API grant through the alias overlay, refused by its word where the retained named pick judged no row",
            usage: fresh.clone(),
            provider: Some(grant_row(150)),
            env: vec![
                ("ORCH_LANE_ALIASES", "pi1=work"),
                ("ORCH_LANE_EXCLUDE", "work"),
            ],
            asks: vec![
                ask(api_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    named_launch(api_model, &pi_dir),
                    "excluded",
                    3,
                    Some(5),
                    vec![("verdict", json!("excluded")), ("alias", json!("work"))],
                ),
            ],
        },
        Arm {
            name: "a retired API grant root is refused by its word where the retained pick admitted the grant",
            usage: fresh.clone(),
            provider: Some(grant_row(150)),
            env: vec![("ORCH_LANE_RETIRE", "pi1=2026-01-01")],
            asks: vec![
                ask(
                    api_chooser(),
                    "none",
                    3,
                    Some(0),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": pi_dir, "reason": "retired"}]),
                    )],
                ),
                ask(walk_chooser(api_model), "none", 3, Some(0), none(0, 0)),
                ask(
                    named_launch(api_model, &pi_dir),
                    "retired",
                    3,
                    Some(0),
                    vec![
                        ("verdict", json!("retired")),
                        ("pool", json!("api-credit")),
                        ("retire_date", json!("2026-01-01")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a local kind ORCH_LANE_EXCLUDE names is no record to the named form and no candidate to the chooser, the provider holding a row for it, as the retained pick answered",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![("ORCH_LANE_EXCLUDE", "aclaude")],
            asks: vec![
                ask(claude_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(claude_named(), "no-record", 4, Some(4), vec![]),
            ],
        },
        Arm {
            name: "a retired local kind the provider holds a row for is refused by its word where the retained pick measured it unmeasured",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![("ORCH_LANE_RETIRE", "aclaude=2026-01-01")],
            asks: vec![
                ask(
                    claude_chooser(),
                    "none",
                    3,
                    Some(3),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": claude_dir, "reason": "retired"}]),
                    )],
                ),
                ask(
                    claude_named(),
                    "retired",
                    3,
                    Some(5),
                    vec![
                        ("measured_through", json!("host")),
                        ("retire_date", json!("2026-01-01")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a Pi launch on a model nothing bills is refused before the listing is read, the reader unreadable",
            usage: fresh.clone(),
            provider: None,
            env: vec![("OVERSEE_WATCH_LANES", &no_lanes)],
            asks: vec![
                ask(
                    named_launch("sonnet:high", &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    unbilled("sonnet:high"),
                ),
                ask(
                    model_chooser("sonnet:high"),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
            ],
        },
        Arm {
            name: "a provider whose capability line cannot be read judges nothing",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![("LANE_HOST_STUB_NO_CAPABILITIES", "1")],
            asks: vec![
                ask(claude_chooser(), "unjudged", 1, Some(1), vec![]),
                ask(claude_named(), "unjudged", 1, Some(1), vec![]),
                ask(
                    flags(&["--harness", "claude", "--lane", &claude_dir, "--projected"]),
                    "unjudged",
                    1,
                    Some(1),
                    vec![],
                ),
            ],
        },
        Arm {
            name: "a provider-only Copilot root ORCH_LANE_EXCLUDE names is a candidate left out by name, refused by its word where the retained pick found the pool unstated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![("ORCH_LANE_EXCLUDE", "pi1")],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(walk_chooser(pi_model), "none", 3, Some(5), none(0, 0)),
                ask(
                    pi_named(),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "pi1"),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "pi1"),
                ),
            ],
        },
        Arm {
            name: "the excluded provider-only Copilot root through the alias overlay, refused by its word where the retained pick found the pool unstated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![
                ("ORCH_LANE_ALIASES", "pi1=work"),
                ("ORCH_LANE_EXCLUDE", "work"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(walk_chooser(pi_model), "none", 3, Some(5), none(0, 0)),
                ask(
                    pi_named(),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "work"),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "work"),
                ),
            ],
        },
        Arm {
            name: "an excluded provider-only Copilot root whose row read nothing, refused by its word where the retained pick found the pool unstated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tstatus=no_usage_data")),
            env: vec![("ORCH_LANE_EXCLUDE", "pi1")],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(walk_chooser(pi_model), "none", 3, Some(5), none(0, 0)),
                ask(
                    pi_named(),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "pi1"),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "pi1"),
                ),
            ],
        },
        Arm {
            name: "a retired provider-only Copilot root is refused by its word where the retained pick found the pool unstated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![("ORCH_LANE_RETIRE", "pi1=2026-01-01")],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), retired_root(&pi_dir)),
                ask(
                    walk_chooser(pi_model),
                    "none",
                    3,
                    Some(5),
                    retired_root(&pi_dir),
                ),
                ask(pi_named(), "retired", 3, Some(5), copilot_retired()),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "retired",
                    3,
                    Some(5),
                    copilot_retired(),
                ),
            ],
        },
        Arm {
            name: "an excluded Copilot root nobody measured, this machine's read, is a pool nobody measured to both forms, as the retained pick answered",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_EXCLUDE", "pi1")],
            asks: vec![
                ask(
                    pi_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    copilot_word("unmeasured", "pi1"),
                ),
            ],
        },
        Arm {
            name: "a retired Copilot root nobody measured, this machine's read, is refused by its word where the retained pick found no reading",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_RETIRE", "pi1=2026-01-01")],
            asks: vec![
                ask(
                    pi_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "retired",
                    3,
                    Some(5),
                    copilot_word("retired", "pi1"),
                ),
            ],
        },
        Arm {
            name: "an excluded API grant root, this machine's read, is a grant nobody measured to both forms, as the retained pick answered",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_EXCLUDE", "pi1")],
            asks: vec![
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(api_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    vec![
                        ("verdict", json!("unmeasured")),
                        ("alias", json!("pi1")),
                        ("pool", json!("api-credit")),
                        ("refusal", api_refusal()),
                    ],
                ),
            ],
        },
        Arm {
            name: "a retired API grant root, this machine's read, is refused by its word where the retained pick found no grant row",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_RETIRE", "pi1=2026-01-01")],
            asks: vec![
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(api_model, &pi_dir),
                    "retired",
                    3,
                    Some(5),
                    vec![("verdict", json!("retired")), ("pool", json!("api-credit"))],
                ),
            ],
        },
        Arm {
            name: "an excluded stated Copilot root the provider reads, refused by its word where the retained named pick judged the statement",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![
                ("ORCH_LANE_COPILOT_POOL", &pool),
                ("ORCH_LANE_EXCLUDE", "pi1"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "excluded",
                    3,
                    Some(0),
                    vec![
                        ("verdict", json!("excluded")),
                        ("measured_through", json!("host")),
                        ("alias", json!("pi1")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a retired stated Copilot root the provider reads is refused by its word where the retained pick found the pool unstated",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![
                ("ORCH_LANE_COPILOT_POOL", &pool),
                ("ORCH_LANE_RETIRE", "pi1=2026-01-01"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), retired_root(&pi_dir)),
                ask(
                    named_launch(pi_model, &pi_dir),
                    "retired",
                    3,
                    Some(5),
                    vec![
                        ("verdict", json!("retired")),
                        ("measured_through", json!("host")),
                        ("pool", json!("copilot")),
                    ],
                ),
            ],
        },
        Arm {
            name: "a retired account on a cloud-session host is refused by its word where the retained named pick answered the unset repository",
            usage: fresh.clone(),
            provider: Some(String::new()),
            env: vec![
                ("LANE_HOST_STUB_CAPABILITIES", cloud_line),
                ("ORCH_LANE_RETIRE", "aclaude=2026-01-01"),
            ],
            asks: vec![
                ask(
                    claude_chooser(),
                    "none",
                    3,
                    Some(3),
                    vec![(
                        "exclusions",
                        json!([{"config_dir": claude_dir, "reason": "cloud-repo-unset"}]),
                    )],
                ),
                ask(
                    claude_named(),
                    "retired",
                    3,
                    Some(7),
                    vec![
                        ("pool", json!("cloud-credit")),
                        (
                            "refusal",
                            json!({"cause": "cloud-credit", "retry_at": null}),
                        ),
                    ],
                ),
            ],
        },
        Arm {
            name: "the API grant's credit floor at 0 admits a grant with 100 dollars left, as the retained pick did",
            usage: fresh.clone(),
            provider: Some(grant_row(100)),
            env: vec![("ORCH_LANE_CLOUD_CREDIT_FLOOR", "0")],
            asks: floor_room(),
        },
        Arm {
            name: "the API grant's credit floor at 10 admits a grant with 100 dollars left, as the retained pick did",
            usage: fresh.clone(),
            provider: Some(grant_row(100)),
            env: vec![("ORCH_LANE_CLOUD_CREDIT_FLOOR", "10")],
            asks: floor_room(),
        },
        Arm {
            name: "the API grant's credit floor at 100 walls a grant with 100 dollars left, as the retained pick did",
            usage: fresh.clone(),
            provider: Some(grant_row(100)),
            env: vec![("ORCH_LANE_CLOUD_CREDIT_FLOOR", "100")],
            asks: vec![
                ask(
                    api_chooser(),
                    "none",
                    3,
                    Some(3),
                    vec![
                        ("walled", json!(1)),
                        (
                            "exclusions",
                            json!([{"config_dir": pi_dir, "reason": "walled"}]),
                        ),
                    ],
                ),
                ask(
                    named_launch(api_model, &pi_dir),
                    "walled",
                    3,
                    Some(3),
                    vec![
                        ("verdict", json!("walled")),
                        ("pool", json!("api-credit")),
                        ("refusal", api_refusal()),
                    ],
                ),
            ],
        },
        Arm {
            name: "the API grant's credit floor at 0 admits no grant this machine's read cannot measure, as the retained pick answered",
            usage: fresh.clone(),
            provider: None,
            env: vec![("ORCH_LANE_CLOUD_CREDIT_FLOOR", "0")],
            asks: vec![
                ask(
                    api_chooser(),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
                ask(
                    named_launch(api_model, &pi_dir),
                    "unmeasured",
                    5,
                    Some(5),
                    grant_unmeasured(),
                ),
            ],
        },
    ];
    for arm in &arms {
        producer.plant_usage(&arm.usage);
        if let Some(rows) = &arm.provider {
            producer.plant_provider(rows);
        }
        let env = producer.env(arm.provider.is_some(), &arm.env);
        for Ask {
            flags,
            answer,
            exit,
            retained,
            record,
        } in &arm.asks
        {
            let flags: Vec<&str> = flags.iter().map(String::as_str).collect();
            let reply = producer.pick(&env, &flags);
            let context = format!(
                "arm `{}`, {flags:?} (the retained pick exits {retained:?}): {reply}",
                arm.name
            );
            assert_eq!(reply["answer"], json!(answer), "{context}");
            assert_eq!(reply["exit"], json!(exit), "{context}");
            for (key, want) in record {
                assert_eq!(&reply["record"][*key], want, "record.{key}: {context}");
            }
        }
    }
    // The instant a lane began on its account: the reader's sample, served
    // from its cache 240 seconds old, was taken with one lane live, and
    // three lanes first launched two hours ago elsewhere were relaunched
    // onto the account after it. The fifth candidate's room is -35 (the
    // relaunch row's figure), `walled`.
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let cached = producer.env(
        false,
        &[
            ("ORCH_LANES_USAGE_TTL", "300"),
            ("ORCH_LANES_USAGE_MAX_AGE", ""),
        ],
    );
    producer.plant_usage(&usage_body(
        (60, at + 3360),
        (70, at + 6 * 3600),
        &[("Opus", 0, at + 6 * 3600)],
    ));
    let record = producer.cache_record();
    producer.edit_record(&record, |record| {
        record["fetched_at"] = json!(at - 240);
    });
    let children: Vec<Owned> = (0..4).map(|_| Owned::sleep()).collect();
    let since = [at - 3600, at - 180, at - 120, at - 60];
    producer.write_fleet(
        children
            .iter()
            .zip(since)
            .enumerate()
            .map(|(i, (child, since))| {
                let launched = if i == 0 { since } else { at - 7200 };
                let mut lane = lane_launched(
                    &format!("KEN-{}", i + 1),
                    &claude_dir,
                    child.pid(),
                    &child.start(),
                    launched,
                );
                lane["session_since"] = json!(stamp(since));
                lane["running_at"] = json!(stamp(since));
                lane
            })
            .collect(),
    );
    let relaunched = producer.pick(
        &cached,
        &["--harness", "claude", "--lane", &claude_dir, "--projected"],
    );
    assert_eq!(relaunched["answer"], json!("walled"), "{relaunched}");
    let age = relaunched["record"]["usage_age_s"].as_u64().unwrap();
    assert!(
        (240..=270).contains(&age),
        "the aged sample served from the cache, not a fresh fetch: {relaunched}"
    );
    assert_eq!(relaunched["record"]["claims"], json!(4));
    let room = relaunched["record"]["projected_headroom_pct"]
        .as_f64()
        .unwrap();
    assert!(
        (room + 35.0).abs() < 0.05,
        "the sample's one lane is the divisor, the three relaunched after it: {room}"
    );
    drop(children);
    producer.write_fleet(Vec::new());
    // The label in a model window's identity: the reader rated the Opus
    // window, 85 then 90 ten minutes apart at one reset, with the Fable
    // window at 20 beside it at the same reset. A Fable read carries the
    // Fable window with no rate; an Opus read carries the measured one.
    let reset = at + 80 * 3600;
    let split = |opus: u64| {
        usage_body(
            (5, at + 1800),
            (10, reset),
            &[("Opus", opus, reset), ("Fable 5.1", 20, reset)],
        )
    };
    producer.plant_usage(&split(90));
    let record = producer.cache_record();
    producer.edit_record(&record, |record| {
        let fetched = record["fetched_at"].as_u64().unwrap();
        record["prior"] = json!({"fetched_at": fetched - 600, "usage": split(85)});
    });
    let fable = producer.pick(
        &cached,
        &[
            "--harness",
            "claude",
            "--lane",
            &claude_dir,
            "--native-model",
            "claude-fable-5-1",
            "--for-overseer",
        ],
    );
    assert_eq!(fable["record"]["wall"], json!(20), "{fable}");
    assert_eq!(fable["record"]["binding_bucket"], json!("model"), "{fable}");
    assert_eq!(
        fable["record"]["usage_rate_state"],
        json!("one-sample"),
        "the reader rated Opus, not the Fable window at the same reset: {fable}"
    );
    assert_eq!(fable["record"]["usage_rate_pct_per_min"], Value::Null);
    assert_eq!(fable["record"]["projected_wall_minutes"], Value::Null);
    let opus = producer.pick(
        &cached,
        &[
            "--harness",
            "claude",
            "--lane",
            &claude_dir,
            "--native-model",
            "claude-opus-5",
            "--for-overseer",
        ],
    );
    assert_eq!(opus["record"]["wall"], json!(90), "{opus}");
    assert_eq!(
        opus["record"]["usage_rate_state"],
        json!("measured"),
        "{opus}"
    );
    assert_eq!(opus["record"]["usage_rate_pct_per_min"], json!(0.5));
    assert_eq!(opus["record"]["projected_wall_minutes"], json!(20));
    // The label of the window the reader rated under a rounding tie:
    // Fable 90.4 listed before Opus 89.6, Opus risen from
    // 84.6 ten minutes earlier. The reader rounds both to 90 and rates the
    // last of the tie, Opus (`binding_bucket`'s `max_by(.pct)` over the
    // rounded buckets), while its `model_label` names Fable, the greatest
    // raw percentage. The Fable read carries no rate; the Opus read carries
    // the measured one.
    let tie = |opus: f64| {
        json!({
            "five_hour": {"utilization": 5, "resets_at": stamp(at + 1800)},
            "seven_day": {"utilization": 10, "resets_at": stamp(reset)},
            "limits": [
                {"kind": "weekly_scoped", "percent": 90.4, "resets_at": stamp(reset),
                 "scope": {"model": {"display_name": "Fable 5.1"}}},
                {"kind": "weekly_scoped", "percent": opus, "resets_at": stamp(reset),
                 "scope": {"model": {"display_name": "Opus"}}},
            ],
        })
    };
    producer.plant_usage(&tie(89.6));
    let record = producer.cache_record();
    producer.edit_record(&record, |record| {
        let fetched = record["fetched_at"].as_u64().unwrap();
        record["prior"] = json!({"fetched_at": fetched - 600, "usage": tie(84.6)});
    });
    let fable = producer.pick(
        &cached,
        &[
            "--harness",
            "claude",
            "--lane",
            &claude_dir,
            "--native-model",
            "claude-fable-5-1",
            "--for-overseer",
        ],
    );
    assert_eq!(fable["record"]["wall"], json!(90), "{fable}");
    assert_eq!(
        fable["record"]["usage_rate_state"],
        json!("one-sample"),
        "the reader rated the last of the rounded tie, Opus, whatever its raw model_label names: {fable}"
    );
    assert_eq!(fable["record"]["usage_rate_pct_per_min"], Value::Null);
    let opus = producer.pick(
        &cached,
        &[
            "--harness",
            "claude",
            "--lane",
            &claude_dir,
            "--native-model",
            "claude-opus-5",
            "--for-overseer",
        ],
    );
    assert_eq!(opus["record"]["wall"], json!(90), "{opus}");
    assert_eq!(
        opus["record"]["usage_rate_state"],
        json!("measured"),
        "{opus}"
    );
    assert_eq!(opus["record"]["usage_rate_pct_per_min"], json!(0.5));
    assert_eq!(opus["record"]["projected_wall_minutes"], json!(20));
}
