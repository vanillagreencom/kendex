//! The accounts judge: the status words over the reader's listing, the
//! window a lane on a model is judged on, the projection on the fleet's
//! own live charges with the candidate charged to each window's reset, the
//! sample's own occupancy as the divisor and the replaced lane left out,
//! the one limit a seat is held to, the provider's rows, seats and the one
//! reading per billed account under a host, the Pi Copilot pool read
//! beside the listing, the grant tier and the cloud repository rule, an
//! unreadable listing admitting nothing, and the record's spelling the
//! shell callers read. Each row's name says the failure it catches.
//!
//! Two kinds of row: a pure judge case hands rows to `accounts::pick` in
//! this process; a case whose production path starts a child (the usage
//! fixture `curl`, the host's provider, `git` for the checkout's origin)
//! asks the executable through `support::isolated`, so every child runs
//! under the boundary's environment and never this process's. The
//! accounts are planted as the listing reads them (`support::plant_accounts`):
//! a local account's directory, credential and usage record under the
//! world's home, a provider's row in the host fixture's `accounts` answer;
//! the usage endpoints are the `usage-curl` fixture, which answers from
//! planted bodies and logs each request; the fleet state and the live
//! lanes are the row's own.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the records they plant, hold the children whose identities they record, and read the fixture's log"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::FLEET_FILE_NAME;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::settings::Roots;
use orch_runtime::ops::accounts::{
    self, AccountRow, EndSource, FleetFacts, PickAnswer, PickRequest, Roster, Word,
};
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
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

/// One world: a state directory holding the host fixture as `lane-host`
/// and the usage fixture as `bin/curl`, the accounts planted under its
/// `home` with their usage records under it, the settings naming them
/// under `extra` as the caller's environment, and the same environment
/// handed to the executable.
struct World {
    dir: tempfile::TempDir,
    settings: Settings,
    env: Vec<(String, String)>,
}

impl World {
    fn new(extra: &[(&str, &str)]) -> World {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("bin")).unwrap();
        std::fs::create_dir_all(dir.path().join("home")).unwrap();
        for (name, fixture) in [
            ("lane-host", "lane-host/lane-host"),
            ("bin/curl", "usage-curl/curl"),
        ] {
            std::os::unix::fs::symlink(fixtures().join(fixture), dir.path().join(name)).unwrap();
        }
        install_lane_host(dir.path(), dir.path());
        let roots = Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let base = [
            ("HOME", dir.path().join("home").display().to_string()),
            ("OVERSEE_WATCH_STATE_DIR", dir.path().display().to_string()),
            (
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                dir.path().display().to_string(),
            ),
            ("ORCH_STATE_DIR", dir.path().display().to_string()),
            (
                "USAGE_FIXTURE_DIR",
                dir.path().join("fixtures").display().to_string(),
            ),
        ];
        let mut env: Vec<(String, String)> = base
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect();
        env.extend(
            extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned())),
        );
        let environment: Vec<(OsString, OsString)> = env
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect();
        let settings = settings::load(
            &roots,
            &environment,
            &SettingsFlags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap();
        World { dir, settings, env }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.path().join(FLEET_FILE_NAME)
    }

    /// The directory a planted local account `alias` stands at.
    fn dir(&self, alias: &str) -> String {
        self.path()
            .join("home")
            .join(format!(".{alias}"))
            .display()
            .to_string()
    }

    /// The accounts the listing lists: the local rows as directories under
    /// the home with their records, the provider's rows under `host` as
    /// its `accounts` answer.
    fn plant(&mut self, host: Option<&str>, rows: &[Value]) {
        let env = plant_accounts(self.path(), self.path(), host, rows, now());
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
    }

    fn plant_listing(&mut self, rows: &[Value]) {
        self.plant(None, rows);
    }

    /// The listing under one host: the local rows and the provider's.
    fn plant_host_listing(&mut self, host: &str, rows: &[Value]) {
        self.plant(Some(host), rows);
    }

    /// The host fixture's capability line for `host`.
    fn plant_capabilities(&self, host: &str, line: &str) {
        let path = self.path().join("lane-host.json");
        let mut map: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_else(|| json!({}));
        map[format!("{host} capabilities")] = json!({"stdout": line});
        std::fs::write(path, map.to_string()).unwrap();
    }

    /// The host fixture's `accounts` answer for `host` refused at `exit`.
    fn refuse_accounts(&self, host: &str, exit: i64) {
        let path = self.path().join("lane-host.json");
        let mut map: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_else(|| json!({}));
        map[format!("{host} accounts")] =
            json!({"exit": exit, "stderr": "lane-host-fixture: accounts-refused\n"});
        std::fs::write(path, map.to_string()).unwrap();
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

    /// The body the usage fixture answers for `token` at `endpoint`
    /// (`usage`, `profile` or `copilot`), and the status line beside it.
    fn plant_answer(&self, token: &str, endpoint: &str, body: &Value, status: Option<&str>) {
        let fixtures = self.path().join("fixtures");
        std::fs::create_dir_all(&fixtures).unwrap();
        std::fs::write(
            fixtures.join(format!("{token}.{endpoint}.json")),
            body.to_string(),
        )
        .unwrap();
        let status_file = fixtures.join(format!("{token}.{endpoint}.status"));
        match status {
            Some(line) => std::fs::write(status_file, format!("{line}\n")).unwrap(),
            None => {
                let _ = std::fs::remove_file(status_file);
            }
        }
    }

    /// The usage record of a planted local account, under the world's
    /// state directory.
    fn record_path(&self, harness: &str, alias: &str) -> PathBuf {
        let dir = self.dir(alias);
        self.path().join("usage").join(format!(
            "{harness}-{}-{}.json",
            orch_runtime::ops::wall::cksum(dir.as_bytes()),
            dir.len()
        ))
    }

    /// The requests the usage fixture answered, `<endpoint> <token>` each.
    fn curl_log(&self) -> Vec<String> {
        std::fs::read_to_string(self.path().join("fixtures/curl.log"))
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

    /// The home's `.gitconfig` rewrites the checkout's origin from
    /// `owner/` to `canary/`: a production `git` child that reads this
    /// home, and not the operator's, reads the canary.
    fn canary_home(&self) {
        std::fs::write(
            self.path().join("home/.gitconfig"),
            "[url \"https://github.com/canary/\"]\n\tinsteadOf = https://github.com/owner/\n",
        )
        .unwrap();
    }

    /// The executable under the boundary, in this world, with its
    /// environment and the usage fixture first on its path.
    fn command(&self) -> std::process::Command {
        let mut command = isolated();
        command
            .current_dir(self.path())
            .env("PATH", tool_path(&[&self.path().join("bin")]));
        for (key, value) in &self.env {
            command.env(key, value);
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

/// One measured local row of the listing for a Claude account at
/// `alias`, `used` percent on its weekly window (the binding, resetting 60
/// hours on), and the 5-hour figure the endpoint still sends at `session`
/// percent, which no judgement reads.
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

fn roster_of(rows: Vec<AccountRow>) -> Roster {
    Roster {
        rows,
        provider_failure: None,
        notes: Vec::new(),
    }
}

fn rows(listing: &[Value], settings: &Settings) -> Vec<AccountRow> {
    listing
        .iter()
        .map(|raw| {
            AccountRow::parse(raw, &settings.accounts.get().unwrap()).expect("a listing row")
        })
        .collect()
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

/// The room a seat [`measured`] plants keeps for its overseer at the
/// trigger `trigger` with no rate measured: the trigger and the setting's
/// default burn of 5 points an hour of five hours, 5/168 of it an hour of
/// the week, charged for the 60 hours to the weekly reset, rounded up.
fn seat_need(trigger: u64) -> u64 {
    trigger + 9
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

/// The provider's `reserved=1` row with the most room is never the lane, is
/// named `reserved` among the exclusions when nothing else has room, and
/// keeps its figures in the roster line with its word after them.
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert_eq!(picked(&alone), None);
    assert_eq!(
        exclusions(&alone),
        vec![("/home/me/.5claude".to_owned(), "reserved".to_owned())]
    );
    let roster = roster_of(rows);
    assert_eq!(
        roster.lines(&accounts::today(now()))[0],
        format!(
            "account 5claude config_dir=/home/me/.5claude harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at={} word=reserve",
            stamp(now() + 60 * 3600)
        )
    );
}

/// An account renewed, retired, reserved. A `retired <date>` account is
/// picked until the date; from the date on it is not picked, its row keeps
/// the figures the listing measured, and its credential still answering is
/// one `account-end-contradicted` line under the roster. The listing
/// measures the retired account like any other: the setting is the judge's
/// to apply.
#[test]
fn a_retired_account_is_picked_until_its_date_and_measured_after_it_with_the_contradiction_said() {
    let today = accounts::today(now());
    let tomorrow = accounts::today(now() + 86_400);
    let mut world = World::new(&[(
        "AGENT_RUNTIME_ACCOUNT_RETIRE",
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
        Some(world.dir("6claude").as_str()),
        "the account retiring tomorrow is picked, the one retired today is not: {answer}"
    );
    assert_eq!(
        world.roster()["rows"][0]["status"],
        json!("ok"),
        "the retired account is measured like any other"
    );
    let roster = world.roster();
    assert_eq!(roster["read"], json!(true));
    assert_eq!(roster["rows"][0]["word"], json!(format!("retired:{today}")));
    assert_eq!(roster["rows"][0]["ended"], json!(true));
    assert_eq!(roster["rows"][1]["ended"], json!(false));
    let weekly = stamp(now() + 60 * 3600);
    let (d4, d6, d7) = (
        world.dir("4claude"),
        world.dir("6claude"),
        world.dir("7claude"),
    );
    assert_eq!(
        roster["lines"],
        json!([
            format!(
                "account 4claude config_dir={d4} harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at={weekly} word=retired:{today}"
            ),
            format!(
                "account 6claude config_dir={d6} harness=claude through=local status=ok verdict=room headroom_pct=70 binding_bucket=weekly binding_resets_at={weekly} word=retired:{tomorrow}"
            ),
            format!(
                "account 7claude config_dir={d7} harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at={weekly}"
            ),
            format!(
                "account-end-contradicted 4claude config_dir={d4} ends={today} source=AGENT_RUNTIME_ACCOUNT_RETIRE status=ok"
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
    let roster = roster_of(rows(&[provider], &world.settings));
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

/// A listing that cannot be read is no empty fleet: a configured account
/// whose directory cannot be read is unjudged for the pick and unread for
/// the roster, each with the cause.
#[test]
fn an_unreadable_listing_admits_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 0)]);
    let home = world.path().join("home");
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o000)).unwrap();
    let refused = world.pick(&claude(None));
    let roster = world.roster();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(refused["answer"], json!("unjudged"), "{refused}");
    assert_eq!(refused["exit"], json!(1));
    assert!(
        refused["record"]["cause"]
            .as_str()
            .unwrap()
            .starts_with("listing-unread host=local account-dir-unreadable path="),
        "{refused}"
    );
    assert_eq!(roster["read"], json!(false));
    assert!(
        roster["cause"]
            .as_str()
            .unwrap()
            .starts_with("host=local account-dir-unreadable path="),
        "{roster}"
    );
}

/// A lane on model M is judged on M's own window, never the fullest on the
/// account: the account with a spent Opus window and a free Sonnet one is
/// the lane for Sonnet and refused for Opus, and without a model the
/// fullest window decides as the reader's binding.
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
            &world.settings.accounts.get().unwrap(),
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

/// A relaunch replacing lane L on account A is never refused on L's own
/// charge, and the projection charges the lanes the runtime proves live.
/// The fleet's one running lane on A holds a live launch identity (the
/// row's own child); A's weekly window charged the live lane's measured
/// rate for it and for the candidate projects past the bound, so a fresh
/// launch is refused with A walled; the same pick naming L as the lane it
/// replaces leaves L's charge out, the candidate alone at the setting's
/// burn, and A is the lane. A lane whose identity is gone charges nothing.
#[test]
fn a_relaunch_replacing_a_lane_adds_no_lane_to_the_projection() {
    let mut world = World::new(&[]);
    // The week at 80 percent with its reset an hour on: the measured 15
    // points an hour, charged for the live lane and the candidate,
    // projects past 95; the candidate alone at the setting's burn leaves
    // room.
    let mut row = measured("aclaude", 80, 0);
    row["binding_resets_at"] = json!(stamp(now() + 3600));
    row["resets"]["weekly"] = json!(stamp(now() + 3600));
    row["usage_rate_state"] = json!("measured");
    row["usage_rate_pct_per_min"] = json!(0.25);
    world.plant_listing(&[row]);
    let account = world.dir("aclaude");
    let child = Owned::sleep();
    world.write_fleet(
        vec![lane("KEN-1", &account, child.pid(), &child.start())],
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
        Some(account.as_str()),
        "the replaced lane's charge is left out: {relaunch}"
    );
    assert_eq!(relaunch["record"]["claims"], json!(0));
    // A record whose identity is gone charges nothing, so a fresh launch
    // is admitted on it too.
    world.write_fleet(vec![lane("KEN-2", &account, GONE_PID as u32, "1")], None);
    let gone = world.pick(&claude(None));
    assert_eq!(chosen(&gone).as_deref(), Some(account.as_str()), "{gone}");
    drop(child);
}

/// Seat sessions charged to their reset: `S × burn_w × hours_to_reset_w` on
/// each projected window. The weekly window at 90 percent with 144 hours to
/// its reset and one live lane: the live lane and the candidate each
/// charged the setting's weekly burn for 144 hours leave no room under the
/// bound, so the launch is refused with the weekly window as the projected
/// one; the same account with its reset one hour away is the lane.
#[test]
fn the_binding_window_is_charged_to_its_reset_not_for_one_hour() {
    let mut world = World::new(&[]);
    let mut far = measured("aclaude", 90, 5);
    far["binding_resets_at"] = json!(stamp(now() + 144 * 3600));
    far["resets"]["weekly"] = json!(stamp(now() + 144 * 3600));
    world.plant_listing(&[far]);
    let account = world.dir("aclaude");
    let child = Owned::sleep();
    world.write_fleet(
        vec![lane("KEN-1", &account, child.pid(), &child.start())],
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
        vec![(account.clone(), "walled".to_owned())]
    );
    // The projected window is the weekly one, charged for the two lanes to
    // its reset: 2 × (5 × 5/168) × 144 hours, about 43 points, against
    // the 10 left.
    let judged = world.pick(&named(&account, claude(None)));
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
        Some(account.as_str()),
        "a reset one hour away charges one hour: {admitted}"
    );
    drop(child);
}

/// The seat's limit, `min(AGENT_RUNTIME_ACCOUNT_MAX_PCT, 100 -
/// AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT)` over the room left once the overseer's own
/// spend to the reset is charged, and `pick-seat-omitted` naming `need=`.
/// The fleet record's `overseer.account` is a seat: returned last, held to
/// its overseer's need beside the lane limit (`seat-reserve` under it, the
/// record and the `none` answer's `seats` carrying `need` as the integer
/// [`seat_need`], the room the seat keeps), and judged as any account when
/// the overseer asks.
#[test]
fn a_seat_is_held_to_the_overseers_headroom_beside_the_lane_limit_and_returned_last() {
    let mut world = World::new(&[("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "50")]);
    world.plant_listing(&[measured("seat", 10, 5), measured("worker", 60, 5)]);
    let seat_dir = world.dir("seat");
    world.write_fleet(Vec::new(), Some(&seat_dir));
    let worker = world.pick(&claude(None));
    assert_eq!(
        chosen(&worker).as_deref(),
        Some(world.dir("worker").as_str()),
        "{worker}"
    );
    // The seat at 55 used projects past 50 and under 95: refused under the
    // overseer's headroom alone.
    world.plant_listing(&[measured("seat", 55, 5)]);
    let reserved = world.pick(&claude(None));
    assert_eq!(reserved["answer"], json!("none"), "{reserved}");
    assert_eq!(
        left_out(&reserved),
        vec![(seat_dir.clone(), "seat-reserve".to_owned())]
    );
    let seats = reserved["record"]["seats"].as_array().unwrap();
    assert_eq!(seats.len(), 1, "{reserved}");
    assert_eq!(
        seats[0]["need"],
        json!(seat_need(50)),
        "the omitted seat names the room it keeps, spelled as the callers read it"
    );
    let named = world.pick(&named(&seat_dir, claude(None)));
    assert_eq!(named["answer"], json!("walled"), "{named}");
    assert_eq!(named["record"]["verdict"], json!("seat-reserve"));
    assert_eq!(named["record"]["need"], json!(seat_need(50)));
    assert_eq!(named["record"]["seat"], json!(true));
    let overseer = world.pick(&PickRequest {
        for_overseer: true,
        ..claude(None)
    });
    assert_eq!(
        chosen(&overseer).as_deref(),
        Some(seat_dir.as_str()),
        "{overseer}"
    );
    assert_eq!(
        overseer["record"].get("need"),
        None,
        "no seat, no room kept"
    );
}

/// A seat keeps what its overseer will spend to the reset, measured in its
/// own plan's points: the same work reads 0.12 points an hour on a larger
/// plan and 0.3 on a smaller one, so with the week at 50 percent and 100
/// hours to its reset the larger seat keeps 17 (the trigger 5 and 12) and
/// still takes a worker, while the smaller keeps 35 (5 and 30) and is
/// `seat-reserve`, where a flat reserve would hand its overseer's room to
/// the worker. A lane live at the sample spent half the measured rate, so
/// with one beside it the larger seat keeps 11 (5 and 6).
#[test]
fn a_seat_keeps_what_its_overseer_spends_to_the_reset_so_a_smaller_plan_keeps_more() {
    let mut world = World::new(&[]);
    let reset = stamp(now() + 100 * 3600);
    let seat = |alias: &str, rate: f64| {
        let mut row = measured(alias, 50, 0);
        row["binding_resets_at"] = json!(reset);
        row["resets"]["weekly"] = json!(reset);
        row["usage_rate_state"] = json!("measured");
        row["usage_rate_pct_per_min"] = json!(rate);
        row
    };
    world.plant_listing(&[seat("large", 0.002), seat("small", 0.005)]);
    for (alias, answer, verdict, need) in [
        ("large", "lane", "room", 17),
        ("small", "walled", "seat-reserve", 35),
    ] {
        let dir = world.dir(alias);
        world.write_fleet(Vec::new(), Some(&dir));
        let judged = world.pick(&named(&dir, claude(None)));
        assert_eq!(
            (
                &judged["answer"],
                &judged["record"]["verdict"],
                &judged["record"]["need"]
            ),
            (&json!(answer), &json!(verdict), &json!(need)),
            "{alias}: {judged}"
        );
    }
    let dir = world.dir("large");
    let child = Owned::sleep();
    world.write_fleet(
        vec![lane("KEN-1", &dir, child.pid(), &child.start())],
        Some(&dir),
    );
    let shared = world.pick(&named(&dir, claude(None)));
    assert_eq!(
        (
            &shared["answer"],
            &shared["record"]["verdict"],
            &shared["record"]["need"]
        ),
        (&json!("lane"), &json!("room"), &json!(11)),
        "one sampled lane halves the overseer's share: {shared}"
    );
    drop(child);
}

/// A Copilot home or a Pi root is never a seat: a pick of a Copilot pool
/// reads no seat, the fleet's overseer included. Named as the fleet's
/// overseer at monthly 93 with the reset 30 days out, where a seat would
/// keep 25 points and be `seat-reserve`, each is judged as an ordinary
/// account under the turn-end hook's trigger of 3: `lane`, `room`, no
/// `need`.
#[test]
fn a_copilot_home_or_a_pi_root_the_overseer_names_is_judged_as_an_ordinary_account() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let pool = |alias: &str, harness: &str| {
        let mut row = through_host(measured(alias, 0, 0));
        row["harness"] = json!(harness);
        row["config_dir"] = json!(format!("/home/me/.{alias}"));
        row["monthly_pct"] = json!(93);
        row["headroom_pct"] = Value::Null;
        row["weekly_pct"] = Value::Null;
        row["session_5h_pct"] = Value::Null;
        row["resets"]["monthly"] = json!(stamp(now() + 30 * 86_400));
        row
    };
    world.plant_host_listing("fleet-vm", &[pool("cli", "copilot"), pool("pi1", "pi")]);
    let judged: Vec<Value> = [
        ("copilot", None, "/home/me/.cli"),
        (
            "pi",
            Some("github-copilot/claude-opus-5-5"),
            "/home/me/.pi1",
        ),
    ]
    .into_iter()
    .map(|(harness, model, dir)| {
        world.write_fleet(Vec::new(), Some(dir));
        let reply = world.pick(&PickRequest {
            harness: harness.to_owned(),
            model: model.map(str::to_owned),
            lane: Some(dir.to_owned()),
            min_headroom_pct: Some(3),
            ..PickRequest::default()
        });
        json!([
            harness,
            reply["answer"],
            reply["record"]["verdict"],
            reply["record"]["wall"],
            reply["record"].get("need")
        ])
    })
    .collect();
    assert_eq!(
        judged,
        vec![
            json!(["copilot", "lane", "room", 93, null]),
            json!(["pi", "lane", "room", 93, null]),
        ]
    );
}

/// The provider's rows under a host are the judge's own, read from the
/// roster with the host. Under `ORCH_LANE_HOST=fleet-vm` the listing
/// carries the provider's rows: the seat with the most room is held to the
/// headroom and comes last, the reserved row is never the lane, the
/// ordinary row is; with the ordinary row excluded the seat is the lane
/// while over its limit and `seat-reserve` under it; the provider is asked
/// for its capability line and its accounts under the host, and nothing
/// else.
#[test]
fn a_hosted_pick_reads_the_providers_rows_seats_and_words_from_the_roster_under_its_host() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
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
    let chosen_row = world.pick(&claude(None));
    assert_eq!(
        chosen(&chosen_row).as_deref(),
        Some("/home/me/.worker"),
        "the provider's ordinary row, not its seat or its reserved row: {chosen_row}"
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
        json!(seat_need(5)),
        "the seat keeps the default headroom and its overseer's spend to the reset"
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
    let mut tight = World::new(&[
        ("ORCH_LANE_HOST", "fleet-vm"),
        ("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "40"),
    ]);
    tight.write_fleet(Vec::new(), None);
    tight.plant_capabilities("fleet-vm", SSH_LINE);
    let mut spent_seat = through_host(measured("seat", 55, 5));
    spent_seat["seat"] = json!(1);
    tight.plant_host_listing("fleet-vm", &[spent_seat]);
    let omitted = tight.pick(&claude(None));
    assert_eq!(omitted["answer"], json!("none"), "{omitted}");
    assert_eq!(omitted["record"]["seats"][0]["need"], json!(seat_need(40)));
    // A named reserved account under the host is refused by its word.
    let named = world.pick(&PickRequest {
        lane: Some("/home/me/.held".to_owned()),
        ..claude(None)
    });
    assert_eq!(named["answer"], json!("reserved"), "{named}");
    assert_eq!(named["record"]["alias"], json!("held"));
    let log = world.host_log();
    assert!(
        !log.is_empty()
            && log.iter().all(|l| {
                l == "ORCH_LANE_HOST=fleet-vm capabilities"
                    || l == "ORCH_LANE_HOST=fleet-vm accounts"
            }),
        "the provider is asked under the host for its line and its accounts, nothing else: {log:?}"
    );
    assert_eq!(
        log.first().map(String::as_str),
        Some("ORCH_LANE_HOST=fleet-vm capabilities"),
        "{log:?}"
    );
}

/// `lanes`' `host_row_or_local`: the listing carries this machine's reading
/// of a billed account and the provider's beside it, local first, and a
/// pick judges one of them. The same account at local wall 0 and provider
/// wall 99 on a seat: the chooser refuses and the named reading names the
/// provider's `seat-reserve`. A Claude account the provider measured
/// without the model's window: the local reading's model window decides,
/// and with none the account is unmeasured for that model; without a model
/// the provider's reading stands. A provider row that read nothing, an
/// `unreachable` one or a holding with no figure, leaves this machine's
/// measured reading in place.
#[test]
fn one_reading_per_billed_account_the_providers_eligible_reading_over_this_machines_copy() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    // The provider's row names the directory this machine's reading stands
    // at, as a provider holding a copy of the same account does.
    let at = |dir: &str, mut row: Value| {
        row["config_dir"] = json!(dir);
        row
    };
    let (aclaude, tclaude, uclaude, hclaude) = (
        world.dir("aclaude"),
        world.dir("tclaude"),
        world.dir("uclaude"),
        world.dir("hclaude"),
    );
    let mut local = measured("aclaude", 0, 0);
    local["model_buckets"] =
        json!([{"label": "Opus", "pct": 0, "resets_at": stamp(now() + 60 * 3600)}]);
    let mut provider = at(&aclaude, through_host(measured("aclaude", 99, 99)));
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
        vec![(world.dir("aclaude"), "seat-reserve".to_owned())]
    );
    assert_eq!(refused["record"]["seats"][0]["need"], json!(seat_need(5)));
    let named_seat = world.pick(&named(&world.dir("aclaude"), claude(None)));
    assert_eq!(named_seat["answer"], json!("walled"), "{named_seat}");
    assert_eq!(named_seat["record"]["verdict"], json!("seat-reserve"));
    assert_eq!(named_seat["record"]["measured_through"], json!("host"));
    assert_eq!(named_seat["record"]["wall"], json!(99));
    // The model's window: the provider measured the shared windows alone.
    let mut local = measured("tclaude", 10, 5);
    local["model_buckets"] =
        json!([{"label": "Fable 5.1", "pct": 95, "resets_at": stamp(now() + 60 * 3600)}]);
    let provider = at(&tclaude, through_host(measured("tclaude", 20, 5)));
    world.plant_host_listing("fleet-vm", &[local.clone(), provider.clone()]);
    let fable = claude(Some("claude-fable-5-1"));
    let scoped = world.pick(&named(&world.dir("tclaude"), fable.clone()));
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
        vec![(world.dir("tclaude"), "walled".to_owned())]
    );
    let unscoped = world.pick(&claude(None));
    assert_eq!(
        chosen(&unscoped).as_deref(),
        Some(world.dir("tclaude").as_str()),
        "{unscoped}"
    );
    assert_eq!(unscoped["record"]["measured_through"], json!("host"));
    assert_eq!(unscoped["record"]["wall"], json!(20));
    local["model_buckets"] = json!([]);
    world.plant_host_listing("fleet-vm", &[local, provider]);
    let unread = world.pick(&PickRequest {
        lane: Some(world.dir("tclaude")),
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
    let mut unreachable = at(&uclaude, through_host(measured("uclaude", 10, 5)));
    unreachable["status"] = json!("unreachable");
    unreachable["headroom_pct"] = Value::Null;
    unreachable["weekly_pct"] = Value::Null;
    unreachable["session_5h_pct"] = Value::Null;
    unreachable["verdict"] = json!("unmeasured");
    let mut holding = at(&hclaude, through_host(measured("hclaude", 10, 5)));
    holding["status"] = json!("no_usage_data");
    holding["headroom_pct"] = Value::Null;
    holding["weekly_pct"] = Value::Null;
    holding["session_5h_pct"] = Value::Null;
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
    assert_eq!(
        chosen(&own).as_deref(),
        Some(world.dir("uclaude").as_str()),
        "{own}"
    );
    assert_eq!(own["record"]["measured_through"], json!("local"));
    assert_eq!(
        own["record"]["qualifying_count"],
        json!(2),
        "both accounts judged on this machine's reading: {own}"
    );
}

/// A Claude home signed in by a token, its `setup-token` beside it and no
/// credential file, reads nothing on this machine while the provider
/// measured its week: a Fable lane named on it, and the chooser's Fable
/// pick, are judged on that week, the provider's reading standing as an
/// account's one reading does; where the provider read no figure the home
/// is `unmeasured`, exit 5, on its own `no_credentials`. Named where
/// nothing lists it and nothing reads it, a home is `unmeasured`, exit 5,
/// never `no-record`.
#[test]
fn a_token_signed_home_is_judged_on_the_providers_week_and_an_unlisted_one_is_unmeasured() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let dir = world.dir("tclaude");
    let mut local = measured("tclaude", 0, 0);
    local["status"] = json!("no_credentials");
    let mut provider = through_host(measured("tclaude", 20, 0));
    provider["config_dir"] = json!(dir);
    world.plant_host_listing("fleet-vm", &[local, provider]);
    std::fs::write(
        Path::new(&dir).join("setup-token"),
        "sk-ant-oat01-fixture\n",
    )
    .unwrap();
    let fable = world.pick(&named(&dir, claude(Some("claude-fable-5-1"))));
    let chooser = world.pick(&claude(Some("claude-fable-5-1")));
    assert_eq!(
        (
            &fable["answer"],
            &fable["record"]["measured_through"],
            &fable["record"]["wall"],
            chosen(&chooser).as_deref(),
            &chooser["record"]["measured_through"]
        ),
        (
            &json!("lane"),
            &json!("host"),
            &json!(20),
            Some(dir.as_str()),
            &json!("host")
        ),
        "the named form and the chooser alike: {fable} {chooser}"
    );
    // A provider row that read no figure leaves nothing to judge: the home
    // is unmeasured on this machine's own status.
    let mut local = measured("tclaude", 0, 0);
    local["status"] = json!("no_credentials");
    let mut unread = through_host(measured("tclaude", 20, 0));
    unread["config_dir"] = json!(dir);
    unread["status"] = json!("no_usage_data");
    unread["headroom_pct"] = Value::Null;
    unread["weekly_pct"] = Value::Null;
    unread["session_5h_pct"] = Value::Null;
    unread["verdict"] = json!("unmeasured");
    world.plant_host_listing("fleet-vm", &[local, unread]);
    let host_unread = world.pick(&named(&dir, claude(Some("claude-fable-5-1"))));
    assert_eq!(
        (
            &host_unread["answer"],
            &host_unread["exit"],
            &host_unread["record"]["measured_through"],
            &host_unread["record"]["status"]
        ),
        (
            &json!("unmeasured"),
            &json!(5),
            &json!("local"),
            &json!("no_credentials")
        ),
        "{host_unread}"
    );
    let unlisted = world.path().join("home/.tokenhome");
    std::fs::create_dir_all(&unlisted).unwrap();
    std::fs::write(unlisted.join("setup-token"), "sk-ant-oat01-fixture\n").unwrap();
    let alone = world.pick(&PickRequest {
        lane: Some(unlisted.display().to_string()),
        ..claude(None)
    });
    assert_eq!(
        (&alone["answer"], &alone["exit"], &alone["record"]["status"]),
        (&json!("unmeasured"), &json!(5), &json!("no_credentials")),
        "{alone}"
    );
}

/// A credentialed home whose own read failed is no token-signed home: its
/// failure is the account's reading of the model's window, not an absence
/// the provider's shared week fills. Beside a provider row that measured
/// the week and no Fable window, a local copy refused with HTTP 503 and one
/// whose usage body held no window are each `unmeasured` for a Fable lane,
/// exit 5, with the local status and its cause, and the chooser leaves each
/// out as unmeasured rather than launching onto a window nobody read.
#[test]
fn a_failed_local_read_beside_the_providers_shared_week_is_unmeasured_for_the_model() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let dir = world.dir("fclaude");
    let fable = claude(Some("claude-fable-5-1"));
    let failed = [
        ("unreachable", "usage query refused with HTTP 503"),
        (
            "no_usage_data",
            "authenticated, but the usage response carried no weekly, monthly or model window",
        ),
    ];
    let judged: Vec<Value> = failed
        .iter()
        .map(|(status, _)| {
            let mut local = measured("fclaude", 0, 0);
            local["status"] = json!(status);
            local["headroom_pct"] = Value::Null;
            local["weekly_pct"] = Value::Null;
            local["session_5h_pct"] = Value::Null;
            let mut provider = through_host(measured("fclaude", 20, 0));
            provider["config_dir"] = json!(dir);
            world.plant_host_listing("fleet-vm", &[local, provider]);
            let reply = world.pick(&named(&dir, fable.clone()));
            let chooser = world.pick(&fable);
            json!([
                reply["answer"],
                reply["exit"],
                reply["record"]["measured_through"],
                reply["record"]["status"],
                reply["record"]["detail"],
                chooser["answer"],
                left_out(&chooser)
            ])
        })
        .collect();
    let unmeasured: Vec<Value> = failed
        .iter()
        .map(|(status, detail)| {
            json!([
                "unmeasured",
                5,
                "local",
                status,
                detail,
                "none",
                [[dir, "unmeasured"]]
            ])
        })
        .collect();
    assert_eq!(judged, unmeasured);
}

/// The account a Pi lane spends follows its model's provider, and
/// `accounts billed` answers it by the pick's own rule: a `pi-claude/`
/// model spends a Claude seat, a `github-copilot/` or `anthropic/` one the
/// Pi root, and any other provider, or a model named without one, nothing
/// the pick measures. A verb that answered otherwise would have its caller
/// judge a Pi lane on an account the lane does not spend.
#[test]
fn the_billed_verb_names_the_account_a_pi_lane_spends_by_its_models_provider() {
    let world = World::new(&[]);
    let models = [
        "pi-claude/claude-opus-5-5",
        "github-copilot/claude-opus-5-5",
        "anthropic/claude-opus-5-5",
        "openai/gpt-5",
        "claude-opus-5-5",
    ];
    let answers: Vec<Value> = models
        .iter()
        .map(|model| {
            let mut command = world.command();
            command.args([
                "accounts",
                "billed",
                "--harness",
                "pi",
                "--native-model",
                model,
            ]);
            World::reply(command)["billed"].clone()
        })
        .collect();
    assert_eq!(
        answers,
        vec![
            json!("claude"),
            json!("pi"),
            json!("pi"),
            json!("unmeasured"),
            json!("unmeasured")
        ],
        "{models:?}"
    );
}

/// `lanes --help` § pick's tier 0: a grant, the allowance that expires and
/// does not refill, is spent before any plan window, the one that expires
/// first first. Two cloud grants and a plan account with more room: the
/// grant ending sooner is the lane; that grant under the floor is `walled`
/// and the later one is the lane; a Pi `anthropic/` pick reads the
/// `api-credit` rows alone, and with none measured is
/// `pick-provider-unmeasured`, exit 5.
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
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
    let chosen = accounts::pick(
        &rows,
        &pi,
        &facts,
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert_eq!(
        picked(&chosen).as_deref(),
        Some("/home/me/.grant"),
        "{chosen:?}"
    );
    let rows = self::rows(&[unread], &world.settings);
    let unmeasured = accounts::pick(
        &rows,
        &pi,
        &facts,
        &world.settings.accounts.get().unwrap(),
        now(),
    );
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

/// The succession walk's and the turn-end hook's trigger
/// (`lib/overseer-launch.sh` `ol_pick_record`, `hooks/lane-mail-check.sh`'s
/// account mark): `--min-headroom-pct T` is the bound `100 - T` in the
/// record's own unit, and `--binding-floor` holds the account's own binding
/// bucket to the bound beside the model's window. An account at 85 used is
/// room under the setting and walled under a trigger of 20, named or
/// chosen; the account whose Opus window is spent is the Sonnet lane
/// without the floor and not with it.
#[test]
fn the_trigger_is_the_bound_in_the_records_unit_and_the_floor_holds_the_accounts_own_bucket() {
    let world = World::new(&[]);
    let rows = rows(&[measured("aclaude", 85, 5)], &world.settings);
    let facts = FleetFacts::default();
    let loose = accounts::pick(
        &rows,
        &claude(None),
        &facts,
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert_eq!(picked(&loose).as_deref(), Some("/home/me/.aclaude"));
    let trigger = PickRequest {
        min_headroom_pct: Some(20),
        ..claude(None)
    };
    let tight = accounts::pick(
        &rows,
        &trigger,
        &facts,
        &world.settings.accounts.get().unwrap(),
        now(),
    );
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
        &world.settings.accounts.get().unwrap(),
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
    let open = accounts::pick(
        &rows,
        &sonnet,
        &facts,
        &world.settings.accounts.get().unwrap(),
        now(),
    );
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
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert!(
        matches!(&floored, PickAnswer::None { walled: 1, .. }),
        "the account's own Opus window, held to the bound, refuses it: {floored:?}"
    );
}

/// The candidate lane charged: the candidate is a lane in the projection's
/// charge, and the reset bonus `1 + 1 / (1 + hours to the binding reset)`
/// is the selection score's weight, never a charge. Two accounts at one
/// wall with resets one hour and a hundred hours away: the sooner reset is
/// the lane, and its projected room is the room less the candidate's own
/// charge to that reset; the account at the bound with a reset a minute
/// away is never the lane over one with room.
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert_eq!(
        picked(&bounded).as_deref(),
        Some("/home/me/.late"),
        "{bounded:?}"
    );
}

/// `lane-model.sh`'s fixed sample divisor: the session window's observed
/// usage is shared among the lanes live at the sample, never among the
/// lanes live now. One sample held constant, the week at 70 percent with
/// its reset under an hour on and its rate measured at 15 points an hour,
/// taken 240 seconds ago with one lane live, while three more lanes join
/// after it: the fifth candidate is charged the sample's per-lane rate, 15
/// an hour for five lanes to the reset, and the room is -45; the same
/// sample taken now counts every lane live now, a quarter of the rate each.
#[test]
fn a_cached_sample_keeps_the_occupancy_held_with_it_as_lanes_join() {
    let mut world = World::new(&[]);
    let mut row = sampled_week();
    world.plant_listing(&[row.clone()]);
    let account = world.dir("aclaude");
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
                    &account,
                    child.pid(),
                    &child.start(),
                    at,
                )
            })
            .collect(),
        None,
    );
    let fifth = world.pick(&named(&account, claude(None)));
    assert_eq!(fifth["answer"], json!("walled"), "{fifth}");
    assert_eq!(
        fifth["record"]["projected_window"]["bucket"],
        json!("weekly")
    );
    let room = fifth["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 45.0).abs() < 0.01,
        "the sample's one lane is the divisor, so the five lanes are charged 15 an hour each: {room}"
    );
    assert_eq!(fifth["record"]["claims"], json!(4));
    assert_eq!(
        (world.pick(&claude(None))["record"]["walled"]).clone(),
        json!(1)
    );
    // The same sample taken now: the four lanes were live at it, so each
    // is charged a quarter of its rate.
    row["usage_age_s"] = json!(0);
    world.plant_listing(&[row]);
    let fresh = world.pick(&named(&account, claude(None)));
    assert_eq!(fresh["answer"], json!("lane"), "{fresh}");
    let room = fresh["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!((room - 11.25).abs() < 0.01, "{room}");
    drop(children);
}

/// The week the two sample rows judge: 70 percent with its reset 3360
/// seconds on, the reader's rate on it measured at 15 points an hour, the
/// sample taken 240 seconds ago.
fn sampled_week() -> Value {
    let mut row = measured("aclaude", 70, 0);
    row["binding_resets_at"] = json!(stamp(now() + 3360));
    row["resets"]["weekly"] = json!(stamp(now() + 3360));
    row["usage_rate_state"] = json!("measured");
    row["usage_rate_pct_per_min"] = json!(0.25);
    row["usage_age_s"] = json!(240);
    row
}

/// The instant a lane began spending on its account: `session_since`, which
/// every launch and relaunch rewrites and a wake keeps, else `running_at`,
/// else `launched_at`. The sample of the row above, with one lane on the
/// account since before it and three lanes first launched two hours ago
/// elsewhere and relaunched onto the account after it: the three are not
/// counted, the fifth candidate's room is -45, `walled`.
#[test]
fn a_lane_relaunched_onto_the_account_after_the_sample_spent_none_of_it() {
    let mut world = World::new(&[]);
    world.plant_listing(&[sampled_week()]);
    let account = world.dir("aclaude");
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
                    &account,
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
    let fifth = world.pick(&named(&account, claude(None)));
    assert_eq!(fifth["answer"], json!("walled"), "{fifth}");
    let room = fifth["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 45.0).abs() < 0.01,
        "the three relaunched lanes began on the account after the sample: {room}"
    );
    assert_eq!(fifth["record"]["claims"], json!(4));
    drop(children);
}

/// `lane-model.sh`'s measured rate: the rate the reader measured on the
/// binding window is the whole account's delta, shared among the lanes live
/// at the sample, except on a model window, which no lane on another model
/// spends. The weekly window at 50 with 80 hours to its reset, 0.3 points
/// an hour measured across two live lanes: the candidate's room is 14, the
/// per-lane share's, and the record carries the reader's rate fields, since
/// the judged window is the reader's; a model window at 50 with the same
/// rate is charged the rate whole and walled; a window the reader did not
/// rate carries `one-sample`. The window's identity carries its label
/// (`lane-model.sh`'s `same_window`): two model windows at one reset are
/// two windows, so a Fable read of an account whose reader rated its Opus
/// window carries `one-sample` and no rate, never Opus's measured rate,
/// which the mark judge would ask succession on.
#[test]
fn a_measured_binding_rate_is_the_per_lane_share_of_the_lanes_live_at_the_sample() {
    let mut world = World::new(&[]);
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
    let (acc, bclaude) = (world.dir("acc"), world.dir("bclaude"));
    let children: Vec<Owned> = (0..4).map(|_| Owned::sleep()).collect();
    world.write_fleet(
        children
            .iter()
            .enumerate()
            .map(|(i, child)| {
                let account = if i < 2 { &acc } else { &bclaude };
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
    let shared = world.pick(&named(&acc, claude(None)));
    assert_eq!(shared["answer"], json!("lane"), "{shared}");
    let room = shared["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room - 14.0).abs() < 0.01,
        "three lanes at the per-lane share 0.15 for 80 hours: {room}"
    );
    assert_eq!(shared["record"]["burn_pct_per_lane_hour"], json!(0.15));
    assert_eq!(shared["record"]["usage_rate_state"], json!("measured"));
    assert_eq!(shared["record"]["projected_wall_minutes"], json!(10_000));
    let opus = world.pick(&named(&bclaude, claude(Some("claude-opus-5"))));
    assert_eq!(opus["answer"], json!("walled"), "{opus}");
    let room = opus["record"]["projected_headroom_pct"].as_f64().unwrap();
    assert!(
        (room + 22.0).abs() < 0.01,
        "a model window's rate is one lane's, charged whole: {room}"
    );
    assert_eq!(opus["record"]["usage_rate_state"], json!("measured"));
    // A window the reader did not rate: the Sonnet lane on bclaude is
    // judged on the weekly window, whose rate nobody measured.
    let sonnet = world.pick(&named(&bclaude, claude(Some("claude-sonnet-5-5"))));
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
        lane: Some(world.dir("split")),
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
        lane: Some(world.dir("split")),
        for_overseer: true,
        ..claude(Some("claude-opus-5"))
    });
    assert_eq!(opus["record"]["wall"], json!(90), "{opus}");
    assert_eq!(opus["record"]["usage_rate_state"], json!("measured"));
    assert_eq!(opus["record"]["projected_wall_minutes"], json!(20));
    drop(children);
}

/// The Pi Copilot pool (`lanes --help` § pick, the Pi `github-copilot/`
/// arm): the pool a Pi launch spends is never listed, so the judge reads it
/// beside the listing. The stated override makes the chooser answer that
/// root with its monthly use and headroom through `stated`, and the named
/// form judges it; a named excluded root is refused by its word,
/// `excluded`, exit 3; the provider's `harness=pi` row with a reading
/// replaces the statement, one without a reading leaves it standing; a
/// failed provider read with nothing stated is `copilot-pool-unread`, and
/// nothing stated and nothing read is `unmeasured`, exit 5, a read to
/// repair.
#[test]
fn a_pi_copilot_pool_is_judged_from_the_providers_row_or_the_owners_statement() {
    let root = "/home/me/.pi1".to_owned();
    let cli = "/home/me/.cli".to_owned();
    let excluded = "/home/me/.pi2".to_owned();
    let pool = format!("{root}=100000/1000000,{cli}=1/10,{excluded}=1/10");
    let mut world = World::new(&[
        ("ORCH_LANE_HOST", "fleet-vm"),
        ("AGENT_RUNTIME_COPILOT_POOL", &pool),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi2"),
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
    world.plant_host_listing("fleet-vm", &[home.clone(), api.clone()]);
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
        world
            .host_log()
            .contains(&"ORCH_LANE_HOST=fleet-vm accounts".to_owned()),
        "the provider's rows are asked for under the host: {:?}",
        world.host_log()
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
    world.plant_host_listing("fleet-vm", &[home.clone(), api.clone(), provider.clone()]);
    let read = world.pick(&copilot);
    assert_eq!(chosen(&read).as_deref(), Some(root.as_str()), "{read}");
    assert_eq!(read["record"]["measured_through"], json!("host"));
    assert_eq!(read["record"]["headroom_pct"], json!(40));
    assert_eq!(read["record"]["wall"], json!(60));
    // A provider row that read nothing leaves the statement standing.
    provider["status"] = json!("no_usage_data");
    provider["monthly_pct"] = Value::Null;
    provider["headroom_pct"] = Value::Null;
    world.plant_host_listing("fleet-vm", &[home, api, provider]);
    let standing = world.pick(&copilot);
    assert_eq!(
        standing["record"]["measured_through"],
        json!("stated"),
        "{standing}"
    );
    assert_eq!(standing["record"]["headroom_pct"], json!(90));
    // A failed read is answered by the statement; with none it is unread.
    world.refuse_accounts("fleet-vm", 1);
    assert_eq!(
        world.pick(&copilot)["record"]["measured_through"],
        json!("stated")
    );
    let bare = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    bare.write_fleet(Vec::new(), None);
    bare.plant_capabilities("fleet-vm", SSH_LINE);
    bare.refuse_accounts("fleet-vm", 1);
    let unread = bare.pick(&copilot);
    assert_eq!(unread["answer"], json!("unjudged"), "{unread}");
    assert!(
        unread["record"]["cause"].as_str().unwrap().starts_with(
            "copilot-pool-unread host=fleet-vm host-accounts-unreadable host=fleet-vm exit=1"
        ),
        "{unread}"
    );
    bare.refuse_accounts("fleet-vm", 2);
    let unstated = bare.pick(&copilot);
    assert_eq!(unstated["answer"], json!("unmeasured"), "{unstated}");
    assert_eq!(unstated["exit"], json!(5));
    assert_eq!(
        unstated["record"]["refusal"]["cause"],
        json!("provider-unmeasured")
    );
}

/// `lanes --help` § pick's cloud-session rule, and the boundary's
/// isolation: a `cloud-session` host's account is admitted only where
/// `ORCH_LANE_CLOUD_REPOS` gives it this checkout's repository, read by a
/// `git` child of the judge. Under a host whose capability line says
/// `launch=cloud-session`, with the checkout's origin on github.com, the
/// account the setting names for that repository (compared as GitHub reads
/// names, without case) is the lane, the other is `cloud-repo-unset` among
/// the exclusions and refused by name at exit 7; with no origin none is
/// admitted; under an SSH host the rule does not apply. Under a home of the
/// row's own whose `.gitconfig` rewrites the origin's owner to `canary`,
/// the account given `canary/repo` is the lane: the production `git` child
/// read the home it was handed.
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
    // The host's pool is its cloud credit, read from each account's own
    // usage body: the account with access carries less of it.
    let cloud = |alias: &str, remaining: f64| {
        let expires = stamp(now() + 5 * 86_400);
        let mut row = grant(alias, "claude", "cloud-credit", remaining, 100.0, &expires);
        row["credits"]["used_dollars"] = json!(100.0 - remaining);
        row
    };
    world.plant_host_listing("cloud-x", &[cloud("aclaude", 50.0), cloud("bclaude", 90.0)]);
    let (aclaude, bclaude) = (world.dir("aclaude"), world.dir("bclaude"));
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
            (aclaude.clone(), "cloud-repo-unset".to_owned()),
            (bclaude.clone(), "cloud-repo-unset".to_owned()),
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
        Some(aclaude.as_str()),
        "the account with access, not the one with more room: {admitted}"
    );
    let named = world.pick(&PickRequest {
        lane: Some(bclaude.clone()),
        ..claude(None)
    });
    assert_eq!(named["answer"], json!("cloud-repo-unset"), "{named}");
    assert_eq!(named["exit"], json!(7));
    assert_eq!(named["record"]["alias"], json!("bclaude"));
    // The reply the hook suites plant for a lane's turn end on this refusal.
    let home = world.path().join("home");
    assert!(
        planted_form(&planted_pick("cloud-repo-unset"), Path::new("/home/me"))
            == planted_form(&named, &home),
        "planted replies the judge does not answer: {}",
        json!({"cloud-repo-unset": spelled_home(&named, &home)})
    );
    // The judge's `git` reads the home the boundary hands it.
    world.canary_home();
    let canary = world.pick(&claude(None));
    assert_eq!(
        chosen(&canary).as_deref(),
        Some(bclaude.as_str()),
        "the origin read through the row's own home, rewritten to canary/repo: {canary}"
    );
    // The rule is the cloud-session host's alone.
    let mut ssh = World::new(&[
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
/// answer's word, `lanes pick`'s exit by number and the record, so the
/// launcher, the walk, the hook and the mark judge read the verdict in the
/// form they parse; an integral figure is spelled as an integer, the form
/// the mark judge's `^[0-9]{1,3}$` reads, a fraction as a fraction;
/// `--min-headroom-pct` is the callers' trigger; `--env` is the room check
/// a consumer's `SECOND_OPINION_<NAME>_ROOM_CMD` runs, the launch prefix on
/// stdout at exit 0 and the keyed line at the answer's exit otherwise.
#[test]
fn the_pick_verb_answers_the_judgement_with_the_released_exit_by_number() {
    let mut world = World::new(&[]);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    world.write_fleet(Vec::new(), None);
    let account = world.dir("aclaude");
    let mut command = world.command();
    command.args([
        "accounts",
        "pick",
        "--fleet",
        "--harness",
        "claude",
        "--native-model",
        "claude-sonnet-5-5",
        "--lane",
        &account,
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
    assert_eq!(result["record"]["config_dir"], json!(account));
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
    let mut chooser = world.command();
    chooser.args([
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
    assert_eq!(reply["result"]["record"]["config_dir"], json!(account));
    assert_eq!(
        reply["result"]["record"]["qualifying_count"],
        json!(1),
        "bclaude at 85 is under the trigger's bound of 80: {reply}"
    );
    // The room check: the prefix, then the keyed refusal at exit 3.
    let mut room = world.command();
    room.args([
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
        format!("CLAUDE_CONFIG_DIR={account}\n")
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
    let mut roster = world.command();
    roster
        .env("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2026-01-01")
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

/// A named account its word refuses, reserved or retired from its day, may
/// have room, so the answer is the word's, never `walled` with the wall's
/// figures: at `lanes pick`'s exit 3 by number (no caller learns a new
/// number), its reply naming the word and the record carrying
/// `retired:<date>`.
#[test]
fn a_named_reserved_or_retired_account_is_refused_by_its_word_not_the_walls_figures() {
    let today = accounts::today(now());
    let mut world = World::new(&[
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", &format!("oclaude={today}")),
        ("ORCH_LANE_HOST", "fleet-vm"),
    ]);
    world.write_fleet(Vec::new(), None);
    world.plant_capabilities("fleet-vm", SSH_LINE);
    let mut reserved = through_host(measured("rclaude", 10, 5));
    reserved["reserved"] = json!(1);
    world.plant_host_listing("fleet-vm", &[reserved, measured("oclaude", 10, 5)]);
    let named_row = |dir: &str| world.pick(&named(dir, claude(Some("claude-sonnet-5-5"))));
    let reserved = named_row("/home/me/.rclaude");
    assert_eq!(reserved["answer"], json!("reserved"), "{reserved}");
    assert_eq!(reserved["exit"], json!(3));
    assert_eq!(reserved["record"]["verdict"], json!("reserved"));
    assert_eq!(reserved["record"]["word"], json!("reserve"));
    let retired = named_row(&world.dir("oclaude"));
    assert_eq!(retired["answer"], json!("retired"), "{retired}");
    assert_eq!(retired["exit"], json!(3));
    assert_eq!(retired["record"]["word"], json!(format!("retired:{today}")));
    assert_eq!(retired["record"]["retire_date"], json!(today));
}

/// The provider's `plan_ends` is held to a calendar day, as the machine's
/// own `AGENT_RUNTIME_ACCOUNT_RETIRE` is: a value that names no calendar day reads as
/// invalid, not absent: the row keeps its figures, is never picked (named
/// among the exclusions, and a named pick of it unjudged with the cause: an
/// end nobody can read admits nothing), and is one
/// `account-plan-end-invalid` line under the roster.
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
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
        &world.settings.accounts.get().unwrap(),
        now(),
    );
    assert_eq!(
        named,
        PickAnswer::Unjudged {
            cause: "plan-end-invalid alias=v value=2026-10-21T00:00:00Z".to_owned()
        }
    );
    let roster = roster_of(rows);
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

/// The settings' refusals: a retirement naming no lane or no calendar day,
/// a percentage past 100, a floor that is no whole number, a cloud
/// repository entry naming no `owner/repo`, a stated Copilot pool naming no
/// absolute root, no grant, a grant of nothing or one root twice, an
/// exclusion naming a path, and the retired key
/// `ORCH_OVERSEER_SEAT_RESERVE_PCT` read by nothing.
#[test]
fn a_statement_nobody_can_read_is_refused_by_key_and_value() {
    for (key, value) in [
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "4claude"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "4claude=2026-02-30"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "=2026-10-20"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "a/b=2026-10-20"),
        ("AGENT_RUNTIME_ACCOUNT_MAX_PCT", "101"),
        ("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "-1"),
        ("AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR", "five"),
        ("AGENT_RUNTIME_CODEX_CREDIT_FLOOR", "1.5"),
        ("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "ten"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude=repo"),
        ("ORCH_LANE_CLOUD_REPOS", "=owner/repo"),
        ("AGENT_RUNTIME_COPILOT_POOL", "pi1=1/10"),
        ("AGENT_RUNTIME_COPILOT_POOL", "/h/.pi1=1"),
        ("AGENT_RUNTIME_COPILOT_POOL", "/h/.pi1=1/0"),
        ("AGENT_RUNTIME_COPILOT_POOL", "/h/.pi1=one/10"),
        ("AGENT_RUNTIME_COPILOT_POOL", "/h/.pi1=1/10,/h/.pi1/=2/10"),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "/h/.pi1"),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "~pi1"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "~pi1=2026-10-20"),
        ("ORCH_LANE_CLOUD_REPOS", "a~b=owner/repo"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let roots = Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let loaded = settings::load(
            &roots,
            &[(OsString::from(key), OsString::from(value))],
            &SettingsFlags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap_or_else(|e| panic!("{key}={value} refused the load: {e}"));
        let Err(error) = loaded.accounts.get() else {
            panic!("{key}={value} admitted");
        };
        assert_eq!(error.key(), "setting-invalid", "{key}={value}: {error}");
    }
    let world = World::new(&[
        (
            "AGENT_RUNTIME_ACCOUNT_RETIRE",
            " 4claude = 2026-10-20 , ,6claude=2026-10-21",
        ),
        ("AGENT_RUNTIME_ACCOUNT_MAX_PCT", "80"),
        ("ORCH_OVERSEER_SEAT_RESERVE_PCT", "not-a-setting"),
        ("ORCH_LANE_CLOUD_REPOS", "aclaude=owner/repo, b=o/r.git"),
        (
            "AGENT_RUNTIME_COPILOT_POOL",
            "/h/.pi1=100000/1000000, /h/.pi2=10/10",
        ),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "sclaude, pi2"),
        (
            "AGENT_RUNTIME_ACCOUNT_ALIASES",
            " pi1 = work ,bare,=nameless,empty=, .pi2=second",
        ),
    ]);
    assert_eq!(world.settings.accounts.get().unwrap().max_pct, 80);
    assert_eq!(
        world
            .settings
            .accounts
            .get()
            .unwrap()
            .controller_headroom_pct,
        5
    );
    assert_eq!(
        world
            .settings
            .accounts
            .get()
            .unwrap()
            .retire
            .iter()
            .map(|r| (r.name.as_str(), r.date.as_str()))
            .collect::<Vec<_>>(),
        vec![("4claude", "2026-10-20"), ("6claude", "2026-10-21")]
    );
    assert_eq!(
        world
            .settings
            .provider
            .get()
            .unwrap()
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
            .get()
            .unwrap()
            .copilot_pool
            .iter()
            .map(|p| (p.dir.as_str(), p.used, p.granted))
            .collect::<Vec<_>>(),
        vec![("/h/.pi1", 100_000, 1_000_000), ("/h/.pi2", 10, 10)]
    );
    assert_eq!(
        world.settings.accounts.get().unwrap().exclude,
        vec!["sclaude", "pi2"]
    );
    // The alias overlay as `lanes` reads it: an item without `=` or with
    // an empty side is passed over, never refused.
    assert_eq!(
        world
            .settings
            .accounts
            .get()
            .unwrap()
            .aliases
            .iter()
            .map(|a| (a.name.as_str(), a.alias.as_str()))
            .collect::<Vec<_>>(),
        vec![("pi1", "work"), (".pi2", "second")]
    );
}

/// The producers' world: a home with one Claude lane, `.aclaude`, whose
/// usage the usage fixture answers from a planted body, one Codex lane,
/// `.acodex`, whose plan windows are spent and whose credits stand, and
/// one Pi root, `.pi1`; a `tmux` that answers nothing and the usage
/// fixture as `curl` first on `PATH`; the shipped `lane-host` dispatcher
/// under the provider fixture `tests/fixtures/lane-host` with its rows
/// planted per arm; a checkout of the row's own and a fleet of the row's
/// own. The runtime is asked through the boundary.
struct Producer {
    dir: tempfile::TempDir,
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
        write_executable(&root.join("bin/tmux"), "#!/bin/sh\nexit 0\n");
        std::os::unix::fs::symlink(fixtures().join("usage-curl/curl"), root.join("bin/curl"))
            .unwrap();
        let git = program("git")
            .args(["-C"])
            .arg(root.join("project"))
            .args(["init", "-q"])
            .output()
            .unwrap();
        assert!(git.status.success(), "{}", stderr(&git));
        let install = root.join("project/.agents/skills/orch");
        std::fs::create_dir_all(&install).unwrap();
        std::os::unix::fs::symlink(orch.join("scripts"), install.join("scripts")).unwrap();
        let producer = Producer {
            dir,
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
    /// `AGENT_RUNTIME_ACCOUNT_DIRS`.
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

    /// The usage body the usage fixture answers for the Claude lane.
    fn plant_usage(&self, body: &Value) {
        std::fs::write(
            self.path().join("fixtures/token-aclaude.usage.json"),
            body.to_string(),
        )
        .unwrap();
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
        std::fs::write(
            self.path().join("fixtures/token-acodex.usage.json"),
            usage.to_string(),
        )
        .unwrap();
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

    /// The environment the runtime runs under: the home, the lane, the
    /// usage fixture's bodies, the state and cache directories, the
    /// provider (`host`) or the local read, the caches off, and the arm's
    /// own settings.
    fn env(&self, host: bool, extra: &[(&str, &str)]) -> Vec<(String, String)> {
        let root = self.path();
        let mut env: Vec<(String, String)> = [
            ("HOME", self.home().display().to_string()),
            ("AGENT_RUNTIME_ACCOUNT_DIRS", self.claude()),
            (
                "USAGE_FIXTURE_DIR",
                root.join("fixtures").display().to_string(),
            ),
            ("ORCH_STATE_DIR", root.join("state").display().to_string()),
            (
                "OVERSEE_WATCH_STATE_DIR",
                root.join("claims").display().to_string(),
            ),
            (
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                root.join("claims").display().to_string(),
            ),
            ("AGENT_RUNTIME_USAGE_TTL", "0".to_owned()),
            ("AGENT_RUNTIME_USAGE_MAX_AGE", "0".to_owned()),
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

    /// The listing's record of the Claude lane after one fresh listing
    /// (the caches off), for an arm that plants a sample's age or its
    /// prior before the runtime reads the record under a TTL.
    fn cache_record(&self) -> PathBuf {
        let mut listing = self.command(&self.env(false, &[]));
        listing.args(["accounts", "roster"]);
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

    /// The record rewritten by `edit`.
    fn edit_record(&self, path: &Path, edit: impl FnOnce(&mut Value)) {
        let mut record: Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        edit(&mut record);
        std::fs::write(path, record.to_string()).unwrap();
    }
}

/// A Claude usage body as the endpoint answers it: the 5-hour window it
/// still sends, the weekly window and the model-scoped windows, each with
/// its reset.
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
/// one arm per input the shell `lanes pick` verb reads and the judge must
/// keep. Every other row plants the listing itself, so an input the shell
/// verb reads and the judge drops shows only here. The questions are one
/// named and one chooser question per reachable exit site of the shell
/// verb's call graph (its `pick)` dispatcher, `cmd_pick_lane`, `cmd_pick`,
/// `named_account_judgment`, `measure_lane`, `measure_copilot_pool`,
/// `pick_host_rows`, `host_row_or_local`, `emit_lane`,
/// `validate_lane_settings`, `lane_pick_harness`, `lane_tier_inputs`,
/// `lane_host_pool` and `lib/lane-model.sh`'s judge: `lane_judge`'s six
/// verdict words, `credits` among them, and `host_row_or_local`'s three
/// triggers) for each pool kind the site applies to (a local kind, the
/// Codex credit balance, the Copilot pool, the `anthropic/` API grant, a
/// seat, the cloud credit), and one per input that steers a pick to a site
/// of its own (the exclusion, the retirement, the aliases, the stated pool,
/// the cloud repositories, the headroom, the credit floor, the model,
/// `--exclude-lane`, `--for-overseer`, `--binding-floor` and `--projected`)
/// for each pool kind and each host form the verb dispatches on, this
/// machine's read and a provider host. A ruling pins instead: the claim
/// store and the seats, which the fleet state replaces; the settings
/// refusal, which the loader owns; the dispatcher's class form, unnamed
/// harness, `--exclude-lane` beside `--lane` and `--projected` without
/// `--lane`, which no shipped caller passes; the reader's sites inside
/// `measure_lane`, whose statuses the shipped `lanes list` still measures
/// and whose one judge outcome, unmeasured, the local kind's questions ask;
/// the reader's own failures, which an unread listing holds, and its
/// caches; and a cell whose input reaches the site another cell's question
/// asks (the reader's exclusion of a local kind on this machine's read and
/// on the cloud credit, the fleet's overseer seat beside the provider's,
/// `--exclude-lane` on each pool, the alias overlay on this machine's
/// grant). A site the runtime answers differently is a literal with its
/// reason named in its arm (a retired or excluded root or grant refused by
/// its word at exit 3 where the shell verb found no reading or an unstated
/// pool at exit 5, judged the pool at exit 0, admitted the grant at exit 0
/// or answered the unset repository at exit 7; a provider row with
/// `status=no_usage_data` and no figure leaving this machine's reading in
/// both forms). Each question's answers are literals, the runtime's own and
/// the shell verb's exit as recorded, never an oracle run here.
#[test]
fn the_judge_answers_the_shipped_producers_worlds_as_the_retained_pick_does() {
    let producer = Producer::new();
    producer.plant_codex();
    let claude_dir = producer.claude();
    let codex_dir = producer.codex();
    let pi_dir = producer.pi();
    let other_pi = producer.other_pi();
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
    // The launcher's form of the named question: the named root on the
    // projection.
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
                        // The default headroom 5 and the overseer's one hour
                        // at the setting's burn where no reset is stated,
                        // rounded up; the retained pick kept 5.
                        ("need", json!(6)),
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &pool)],
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &pool)],
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &pool)],
            asks: vec![
                ask(pi_chooser(), "lane", 0, Some(0), lane("stated", 10)),
                ask(pi_named(), "lane", 0, Some(0), lane("stated", 10)),
            ],
        },
        Arm {
            name: "the owner's stated pool at the bound is walled by the named form",
            usage: fresh.clone(),
            provider: None,
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &spent_pool)],
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &pool)],
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &pool)],
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
            env: vec![("AGENT_RUNTIME_COPILOT_POOL", &other_pool)],
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
                ("AGENT_RUNTIME_COPILOT_POOL", &pool),
                ("AGENT_RUNTIME_ACCOUNT_ALIASES", "pi1=work"),
                ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "work"),
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
                ("AGENT_RUNTIME_COPILOT_POOL", &pool),
                ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1"),
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
                ("AGENT_RUNTIME_COPILOT_POOL", &pool),
                ("AGENT_RUNTIME_ACCOUNT_ALIASES", "pi1=work"),
                ("AGENT_RUNTIME_ACCOUNT_RETIRE", "work=2026-01-01"),
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
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2026-01-01")],
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
            env: vec![("AGENT_RUNTIME_ACCOUNT_DIRS", &codex_dir)],
            asks: vec![
                ask(codex_chooser(), "lane", 0, Some(0), credits()),
                ask(codex_named(), "lane", 0, Some(0), credits()),
            ],
        },
        Arm {
            name: "the API grant whose root AGENT_RUNTIME_ACCOUNT_EXCLUDE names is left out of every lane pick by name and refused by its word, where the retained named pick judged no row, and is the overseer walk's to read",
            usage: fresh.clone(),
            provider: Some(grant_row(150)),
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1")],
            asks: vec![
                ask(api_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    walk_chooser(api_model),
                    "lane",
                    0,
                    Some(3),
                    vec![("excluded", json!(true))],
                ),
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
                ("AGENT_RUNTIME_ACCOUNT_ALIASES", "pi1=work"),
                ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "work"),
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
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "pi1=2026-01-01")],
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
            name: "a local kind AGENT_RUNTIME_ACCOUNT_EXCLUDE names is refused by its word in the named form, where the retained pick found no record, and no candidate to the chooser, the provider holding a row for it",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "aclaude")],
            asks: vec![
                ask(claude_chooser(), "none", 3, Some(3), none(0, 0)),
                ask(
                    claude_named(),
                    "excluded",
                    3,
                    Some(4),
                    vec![("verdict", json!("excluded")), ("excluded", json!(true))],
                ),
            ],
        },
        Arm {
            name: "a retired local kind the provider holds a row for is refused by its word where the retained pick measured it unmeasured",
            usage: fresh.clone(),
            provider: Some(claude_row("\tsession-5h-pct=10\tweekly-pct=10")),
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2026-01-01")],
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
            env: vec![],
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
            name: "a provider-only Copilot root AGENT_RUNTIME_ACCOUNT_EXCLUDE names is left out of every lane pick by name and refused by its word, where the retained pick found the pool unstated, and is the overseer walk's to read",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1")],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(
                    walk_chooser(pi_model),
                    "lane",
                    0,
                    Some(5),
                    vec![("excluded", json!(true)), ("headroom_pct", json!(40))],
                ),
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
            name: "the excluded provider-only Copilot root through the alias overlay, refused by its word where the retained pick found the pool unstated, and the overseer walk's to read",
            usage: fresh.clone(),
            provider: Some(pi_row("\tmonthly-pct=60")),
            env: vec![
                ("AGENT_RUNTIME_ACCOUNT_ALIASES", "pi1=work"),
                ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "work"),
            ],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(
                    walk_chooser(pi_model),
                    "lane",
                    0,
                    Some(5),
                    vec![("excluded", json!(true)), ("headroom_pct", json!(40))],
                ),
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
            name: "an excluded provider-only Copilot root whose row read nothing, refused by its word where the retained pick found the pool unstated, and the pool nobody measured to the overseer walk",
            usage: fresh.clone(),
            provider: Some(pi_row("\tstatus=no_usage_data")),
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1")],
            asks: vec![
                ask(pi_chooser(), "none", 3, Some(5), none(0, 0)),
                ask(
                    walk_chooser(pi_model),
                    "unmeasured",
                    5,
                    Some(5),
                    provider_unmeasured(),
                ),
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
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "pi1=2026-01-01")],
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
            name: "an excluded Copilot root nobody measured, this machine's read, is a pool nobody measured to the chooser and refused by its word in the named form, where the retained pick found no reading",
            usage: fresh.clone(),
            provider: None,
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1")],
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
                    "excluded",
                    3,
                    Some(5),
                    copilot_word("excluded", "pi1"),
                ),
            ],
        },
        Arm {
            name: "a retired Copilot root nobody measured, this machine's read, is refused by its word where the retained pick found no reading",
            usage: fresh.clone(),
            provider: None,
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "pi1=2026-01-01")],
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
            name: "an excluded API grant root, this machine's read, is a grant nobody measured to the chooser and refused by its word in the named form, where the retained pick found no grant row",
            usage: fresh.clone(),
            provider: None,
            env: vec![("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1")],
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
            name: "a retired API grant root, this machine's read, is refused by its word where the retained pick found no grant row",
            usage: fresh.clone(),
            provider: None,
            env: vec![("AGENT_RUNTIME_ACCOUNT_RETIRE", "pi1=2026-01-01")],
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
                ("AGENT_RUNTIME_COPILOT_POOL", &pool),
                ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "pi1"),
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
                ("AGENT_RUNTIME_COPILOT_POOL", &pool),
                ("AGENT_RUNTIME_ACCOUNT_RETIRE", "pi1=2026-01-01"),
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
                ("AGENT_RUNTIME_ACCOUNT_RETIRE", "aclaude=2026-01-01"),
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
            env: vec![("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "0")],
            asks: floor_room(),
        },
        Arm {
            name: "the API grant's credit floor at 10 admits a grant with 100 dollars left, as the retained pick did",
            usage: fresh.clone(),
            provider: Some(grant_row(100)),
            env: vec![("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "10")],
            asks: floor_room(),
        },
        Arm {
            name: "the API grant's credit floor at 100 walls a grant with 100 dollars left, as the retained pick did",
            usage: fresh.clone(),
            provider: Some(grant_row(100)),
            env: vec![("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "100")],
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
            env: vec![("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "0")],
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
    // from its cache 240 seconds old with the week's rate measured against
    // the sample twelve minutes before it, was taken with one lane live,
    // and three lanes first launched two hours ago elsewhere were
    // relaunched onto the account after it. The fifth candidate's room is
    // -45 (the relaunch row's figure), `walled`.
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let cached = producer.env(
        false,
        &[
            ("AGENT_RUNTIME_USAGE_TTL", "300"),
            ("AGENT_RUNTIME_USAGE_MAX_AGE", ""),
        ],
    );
    let week = |pct: u64| usage_body((0, at + 1800), (pct, at + 3360), &[("Opus", 0, at + 3360)]);
    producer.plant_usage(&week(70));
    let record = producer.cache_record();
    producer.edit_record(&record, |record| {
        record["fetched_at"] = json!(at - 240);
        record["prior"] = json!({"fetched_at": at - 960, "usage": week(67)});
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
        (room + 45.0).abs() < 0.05,
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

// --- the listing ------------------------------------------------------------------------------

/// A Claude usage body as the endpoint answers it, with the windows given.
fn claude_body(session: Value, weekly: Value, scoped: &[(&str, Value)]) -> Value {
    json!({
        "five_hour": {"utilization": session, "resets_at": stamp(now() + 1800)},
        "seven_day": {"utilization": weekly, "resets_at": stamp(now() + 7 * 86_400)},
        "limits": scoped.iter().map(|(label, pct)| json!({
            "kind": "weekly_scoped", "percent": pct, "resets_at": stamp(now() + 7 * 86_400),
            "scope": {"model": {"display_name": label}},
        })).collect::<Vec<Value>>(),
    })
}

#[test]
fn an_unreadable_percentage_reads_unmeasured_never_zero() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let mut codex = measured("acodex", 20, 10);
    codex["harness"] = json!("codex");
    world.plant_listing(&[
        measured("aclaude", 20, 10),
        codex,
        measured("bclaude", 20, 10),
    ]);
    for (harness, alias) in [
        ("claude", "aclaude"),
        ("codex", "acodex"),
        ("claude", "bclaude"),
    ] {
        std::fs::remove_file(world.record_path(harness, alias)).unwrap();
    }
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(10), json!(20), &[("Opus", json!("30"))]),
        None,
    );
    world.plant_answer(
        "token-acodex",
        "usage",
        &json!({"rate_limit": {
            "primary_window": {"used_percent": 20, "reset_at": now() + 1800, "limit_window_seconds": 18_000},
            "secondary_window": {"used_percent": -1, "reset_at": now() + 86_400, "limit_window_seconds": 604_800}}}),
        None,
    );
    world.plant_answer(
        "token-bclaude",
        "usage",
        &json!({"seven_day": {"utilization": 20, "resets_at": stamp(now() + 7 * 86_400)}}),
        None,
    );
    let roster = world.roster();
    let row = |alias: &str| {
        roster["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["alias"] == json!(alias))
            .map(|r| r["record"].clone())
            .unwrap_or_else(|| panic!("{alias}: {roster}"))
    };
    for alias in ["aclaude", "acodex"] {
        let row = row(alias);
        assert_eq!(row["status"], json!("no_usage_data"), "{alias}: {row}");
        assert_eq!(row["verdict"], json!("unmeasured"), "{alias}: {row}");
        assert_eq!(row["headroom_pct"], Value::Null, "{alias}: {row}");
    }
    let absent = row("bclaude");
    assert_eq!(absent["status"], json!("ok"), "{absent}");
    assert_eq!(absent["headroom_pct"], json!(80), "{absent}");
    let claude_pick = world.pick(&claude(None));
    assert_eq!(
        chosen(&claude_pick).as_deref(),
        Some(world.dir("bclaude").as_str()),
        "the account whose reading nobody could read is never the lane: {claude_pick}"
    );
    let codex_pick = world.pick(&PickRequest {
        harness: "codex".to_owned(),
        ..PickRequest::default()
    });
    assert_eq!(codex_pick["answer"], json!("none"), "{codex_pick}");
    assert_eq!(codex_pick["record"]["unmeasured"], json!(1), "{codex_pick}");
}

#[test]
fn a_usage_429_keeps_the_cached_reading_with_its_age_and_the_window_posts_nothing() {
    let mut world = World::new(&[("AGENT_RUNTIME_USAGE_TTL", "0")]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 10)]);
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(10), json!(20), &[]),
        None,
    );
    let first = world.roster();
    assert_eq!(first["rows"][0]["status"], json!("ok"), "{first}");
    assert_eq!(first["rows"][0]["record"]["headroom_pct"], json!(80));
    assert_eq!(world.curl_log(), vec!["usage token-aclaude"]);
    let record = world.record_path("claude", "aclaude");
    let mut value: Value =
        serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    value["fetched_at"] = json!(now() - 45);
    std::fs::write(&record, value.to_string()).unwrap();
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(60), json!(60), &[]),
        Some("429 0"),
    );
    let refused = world.roster();
    let row = &refused["rows"][0]["record"];
    assert_eq!(row["status"], json!("rate_limited"), "{refused}");
    assert_eq!(
        row["headroom_pct"],
        json!(80),
        "the recorded figure, not the refusal's body: {refused}"
    );
    let age = row["usage_age_s"].as_u64().unwrap();
    assert!((45..=60).contains(&age), "the figure's own age: {refused}");
    assert_eq!(world.curl_log().len(), 2);
    let value: Value = serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    assert_eq!(value["refusal"]["code"], json!("429"));
    assert_eq!(
        value["refusal"]["expires_at"].as_u64().unwrap() - value["fetched_at"].as_u64().unwrap(),
        300,
        "a Retry-After of 0 takes the default window: {value}"
    );
    let again = world.roster();
    assert_eq!(again["rows"][0]["status"], json!("rate_limited"), "{again}");
    assert_eq!(again["rows"][0]["record"]["headroom_pct"], json!(80));
    assert_eq!(world.curl_log().len(), 2, "nothing posts inside the window");
    assert_eq!(
        chosen(&world.pick(&claude(None))).as_deref(),
        Some(world.dir("aclaude").as_str()),
        "the served figure is judged, not a wall"
    );
    let mut value: Value =
        serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    value["usage_fetched_at"] = json!(now() - 86_400);
    std::fs::write(&record, value.to_string()).unwrap();
    let old = world.roster();
    assert_eq!(old["rows"][0]["status"], json!("rate_limited"), "{old}");
    assert_eq!(
        old["rows"][0]["record"]["headroom_pct"],
        Value::Null,
        "a figure a day old is not served: {old}"
    );
    assert_eq!(world.curl_log().len(), 2);
    assert_eq!(world.pick(&claude(None))["answer"], json!("none"));
}

/// The week every wall row's account is walled in, as `measured` plants it.
fn walled_week() -> u64 {
    now() + 60 * 3600
}

fn weekly_body(pct: u64, reset: u64) -> Value {
    json!({"seven_day": {"utilization": pct, "resets_at": stamp(reset)}})
}

/// The account wall the watch records for `dir`, resetting with the walled
/// week and naming `seen_at` as the banner's first sighting.
fn plant_wall(world: &World, dir: &str, seen_at: Option<u64>) {
    let path = orch_runtime::ops::wall::account_wall_path(
        &world.settings.account_state.get().unwrap(),
        dir,
    );
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut record = json!({
        "config_dir": orch_runtime::ops::wall::canon(dir),
        "resets_at": walled_week(),
    });
    if let Some(seen) = seen_at {
        record["seen_at"] = json!(seen);
    }
    std::fs::write(path, record.to_string()).unwrap();
}

/// The usage record of `alias` holding one weekly figure read at `at`.
fn plant_figure(world: &World, alias: &str, pct: u64, at: u64, reset: u64) {
    std::fs::write(
        world.record_path("claude", alias),
        json!({"harness": "claude", "config_dir": world.dir(alias), "fetched_at": at,
               "usage": weekly_body(pct, reset), "sample_claims": 1})
        .to_string(),
    )
    .unwrap();
}

/// An early reset keeps the week's reset time and leaves the banner on the
/// walled lane's screen, so only the fall of the account's weekly figure,
/// from one read after the wall was first seen, tells it from the endpoint
/// that does not report the wall. The account is offered from the fetch that
/// reads the fall, still on the fetches after it, and from a record the
/// shell `lanes` wrote over the fall.
#[test]
fn an_early_reset_that_keeps_its_reset_time_frees_the_account_once_its_figure_falls_after_the_wall()
{
    let mut world = World::new(&[("AGENT_RUNTIME_USAGE_TTL", "0")]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 100, 0), measured("bclaude", 50, 0)]);
    let dir = world.dir("aclaude");
    plant_wall(&world, &dir, Some(now() - 3600));
    plant_figure(&world, "aclaude", 100, now() - 600, walled_week());
    world.plant_answer(
        "token-aclaude",
        "usage",
        &weekly_body(0, walled_week()),
        None,
    );
    world.plant_answer(
        "token-bclaude",
        "usage",
        &weekly_body(50, walled_week()),
        None,
    );
    let freed = listed_row(&world, "aclaude");
    assert_eq!(
        (&freed["weekly_pct"], &freed["verdict"]),
        (&json!(0), &json!("room")),
        "{freed}"
    );
    let pick = world.pick(&claude(None));
    assert_eq!(
        chosen(&pick).as_deref(),
        Some(dir.as_str()),
        "the fetch after the fall: {pick}"
    );
    let again = listed_row(&world, "aclaude");
    assert_eq!(again["verdict"], json!("room"), "{again}");
    std::fs::write(
        world.record_path("claude", "aclaude"),
        json!({"harness": "claude", "config_dir": dir, "fetched_at": now() - 60,
               "usage": weekly_body(0, walled_week()),
               "prior": {"fetched_at": now() - 600, "usage": weekly_body(100, walled_week())},
               "sample_claims": 1})
        .to_string(),
    )
    .unwrap();
    let shell = listed_row(&world, "aclaude");
    assert_eq!(
        shell["verdict"],
        json!("room"),
        "the fall a record without `drop` shows: {shell}"
    );
}

/// A reading with room under a standing wall is the endpoint that does not
/// report it unless a fall after the sighting shows a reset: no fall; a fall
/// from a figure read before the sighting, where the wall came after an
/// earlier reset of the same week; a fall across the earlier figure's
/// weekly reset; a record naming no sighting; and a provider's row, whose
/// figures carry no read time, beside this machine's record of a fall under
/// the same spelling. Each holds the account walled and the pick takes the
/// account at 50.
#[test]
fn a_reading_with_room_holds_the_wall_unless_its_figure_fell_after_the_sighting_inside_one_week() {
    let seen = now() - 3600;
    // (case, earlier figure, its read time, its weekly reset, the sighting, the answer)
    let cases = [
        ("no fall", 40, now() - 600, walled_week(), Some(seen), 45),
        (
            "before the sighting",
            100,
            seen - 600,
            walled_week(),
            Some(seen),
            0,
        ),
        (
            "across the reset",
            100,
            now() - 600,
            now() - 60,
            Some(seen),
            0,
        ),
        ("no sighting", 100, now() - 600, walled_week(), None, 0),
    ];
    for (case, pct, at, reset, seen_at, answer) in cases {
        let mut world = World::new(&[("AGENT_RUNTIME_USAGE_TTL", "0")]);
        world.write_fleet(Vec::new(), None);
        world.plant_listing(&[measured("aclaude", pct, 0), measured("bclaude", 50, 0)]);
        plant_wall(&world, &world.dir("aclaude"), seen_at);
        plant_figure(&world, "aclaude", pct, at, reset);
        world.plant_answer(
            "token-aclaude",
            "usage",
            &weekly_body(answer, walled_week()),
            None,
        );
        world.plant_answer(
            "token-bclaude",
            "usage",
            &weekly_body(50, walled_week()),
            None,
        );
        let row = listed_row(&world, "aclaude");
        assert_eq!(
            (
                &row["weekly_pct"],
                &row["verdict"],
                &row["resets"]["weekly"]
            ),
            (&json!(100), &json!("walled"), &json!(stamp(walled_week()))),
            "{case}: {row}"
        );
        assert_eq!(
            chosen(&world.pick(&claude(None))).as_deref(),
            Some(world.dir("bclaude").as_str()),
            "{case}"
        );
    }
    let mut hosted = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    hosted.write_fleet(Vec::new(), None);
    hosted.plant_capabilities("fleet-vm", SSH_LINE);
    hosted.plant_host_listing(
        "fleet-vm",
        &[
            through_host(measured("hclaude", 0, 0)),
            through_host(measured("worker", 50, 0)),
        ],
    );
    let spelling = "/home/me/.hclaude";
    plant_wall(&hosted, spelling, Some(seen));
    std::fs::create_dir_all(hosted.path().join("usage")).unwrap();
    std::fs::write(
        hosted.path().join("usage").join(format!(
            "claude-{}-{}.json",
            orch_runtime::ops::wall::cksum(spelling.as_bytes()),
            spelling.len()
        )),
        json!({"harness": "claude", "config_dir": spelling, "fetched_at": now() - 60,
               "usage": weekly_body(0, walled_week()),
               "prior": {"fetched_at": now() - 600, "usage": weekly_body(100, walled_week())},
               "sample_claims": 1,
               "drop": {"from_at": now() - 600, "from_pct": 100, "at": now() - 60, "to_pct": 0}})
        .to_string(),
    )
    .unwrap();
    let provider = listed_row(&hosted, "hclaude");
    assert_eq!(
        (&provider["weekly_pct"], &provider["verdict"]),
        (&json!(100), &json!("walled")),
        "provider: {provider}"
    );
    assert_eq!(
        chosen(&hosted.pick(&claude(None))).as_deref(),
        Some("/home/me/.worker"),
        "provider"
    );
}

#[test]
fn two_refreshers_under_the_lock_fetch_once() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 10)]);
    std::fs::remove_file(world.record_path("claude", "aclaude")).unwrap();
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(10), json!(20), &[]),
        None,
    );
    std::fs::write(world.path().join("fixtures/delay"), "1\n").unwrap();
    let mut first = world.command();
    first.args(["accounts", "roster"]);
    let mut second = world.command();
    second.args(["accounts", "roster"]);
    let first = first.stdout(std::process::Stdio::piped()).spawn().unwrap();
    let second = second.stdout(std::process::Stdio::piped()).spawn().unwrap();
    let outputs = [
        first.wait_with_output().unwrap(),
        second.wait_with_output().unwrap(),
    ];
    for out in &outputs {
        assert!(out.status.success(), "{}", stderr(out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["result"]["rows"][0]["status"], json!("ok"), "{reply}");
        assert_eq!(
            reply["result"]["rows"][0]["record"]["headroom_pct"],
            json!(80),
            "{reply}"
        );
    }
    assert_eq!(
        world.curl_log(),
        vec!["usage token-aclaude"],
        "the second reader took the first's figure inside the lock"
    );
}

/// Room is judged on the plan windows alone: a Claude account whose body
/// still reports its 5-hour window full is a lane on its week at 20, and a
/// Codex account whose one window is a 5-hour one has no plan window read,
/// so it is unmeasured, never room.
#[test]
fn a_full_five_hour_window_is_no_wall_and_a_five_hour_figure_alone_is_no_reading() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let mut codex = measured("acodex", 20, 0);
    codex["harness"] = json!("codex");
    world.plant_listing(&[measured("aclaude", 20, 0), codex]);
    for (harness, alias) in [("claude", "aclaude"), ("codex", "acodex")] {
        std::fs::remove_file(world.record_path(harness, alias)).unwrap();
    }
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(99), json!(20), &[]),
        None,
    );
    world.plant_answer(
        "token-acodex",
        "usage",
        &json!({"rate_limit": {
            "primary_window": {"used_percent": 99, "reset_at": now() + 1800, "limit_window_seconds": 18_000},
            "secondary_window": null}}),
        None,
    );
    let lane = world.pick(&claude(Some("claude-fable-5-1")));
    assert_eq!(
        chosen(&lane).as_deref(),
        Some(world.dir("aclaude").as_str()),
        "{lane}"
    );
    assert_eq!(
        (
            &lane["record"]["binding_bucket"],
            &lane["record"]["wall"],
            &lane["record"]["projected_window"]["bucket"]
        ),
        (&json!("weekly"), &json!(20), &json!("weekly")),
        "{lane}"
    );
    let codex = world.pick(&named(
        &world.dir("acodex"),
        PickRequest {
            harness: "codex".to_owned(),
            ..PickRequest::default()
        },
    ));
    assert_eq!(
        (&codex["answer"], &codex["exit"], &codex["record"]["status"]),
        (&json!("unmeasured"), &json!(5), &json!("no_usage_data")),
        "{codex}"
    );
}

#[test]
fn each_endpoint_shape_is_read_as_its_recorded_body() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let mut codex = measured("acodex", 20, 10);
    codex["harness"] = json!("codex");
    let mut copilot = measured("acopilot", 20, 10);
    copilot["harness"] = json!("copilot");
    world.plant_listing(&[measured("aclaude", 20, 10), codex, copilot]);
    for (harness, alias) in [
        ("claude", "aclaude"),
        ("codex", "acodex"),
        ("copilot", "acopilot"),
    ] {
        std::fs::remove_file(world.record_path(harness, alias)).unwrap();
    }
    let mut claude_usage = claude_body(
        json!(10),
        json!(20),
        &[("Opus", json!(5)), ("Fable 5.1", json!(40))],
    );
    claude_usage["iguana_necktie"] = json!({"limit_dollars": 50, "used_dollars": 20, "remaining_dollars": 30,
        "resets_at": "2099-08-01T06:00:00Z", "locked_reason": null});
    world.plant_answer("token-aclaude", "usage", &claude_usage, None);
    world.plant_answer(
        "token-acodex",
        "usage",
        &json!({"rate_limit": {
            "primary_window": {"used_percent": 44, "reset_at": 1_785_000_000, "limit_window_seconds": 604_800},
            "secondary_window": null},
            "credits": {"has_credits": true, "unlimited": false, "overage_limit_reached": false, "balance": "6000"},
            "spend_control": {"reached": false}}),
        None,
    );
    world.plant_answer(
        "token-acopilot",
        "copilot",
        &json!({"copilot_plan": "business", "quota_reset_date_utc": "2099-10-01",
            "quota_snapshots": {"premium_interactions": {"entitlement": 1_000_000, "remaining": 900_000,
                "credits_used": 318_085, "overage_permitted": true, "overage_count": 0, "unlimited": false}}}),
        None,
    );
    let roster = world.roster();
    let row = |alias: &str| {
        roster["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["alias"] == json!(alias))
            .map(|r| r["record"].clone())
            .unwrap_or_else(|| panic!("{alias}: {roster}"))
    };
    let claude = row("aclaude");
    assert_eq!(
        (
            &claude["weekly_pct"],
            &claude["model_pct"],
            &claude["model_label"]
        ),
        (&json!(20), &json!(40), &json!("Fable 5.1")),
        "{claude}"
    );
    assert_eq!(
        (
            claude.get("session_5h_pct"),
            &claude["resets"].get("session")
        ),
        (None, &None),
        "the body's 5-hour window is no plan window: {claude}"
    );
    assert_eq!(claude["headroom_pct"], json!(60));
    assert_eq!(claude["binding_bucket"], json!("model"));
    assert_eq!(claude["credits"]["remaining_dollars"], json!(30));
    assert_eq!(claude["credits"]["unit"], json!("usd"));
    let codex = row("acodex");
    assert_eq!(
        codex["weekly_pct"],
        json!(44),
        "a 7-day primary window fills the weekly slot: {codex}"
    );
    assert_eq!(codex["headroom_pct"], json!(56));
    assert_eq!(codex["resets"]["weekly"], json!("2026-07-25T17:20:00Z"));
    assert_eq!(codex["credits"]["balance"], json!(6000));
    assert_eq!(codex["credits"]["spend_control_reached"], json!(false));
    let copilot = row("acopilot");
    assert_eq!(copilot["monthly_pct"], json!(10), "{copilot}");
    assert_eq!(copilot["headroom_pct"], json!(90));
    assert_eq!(copilot["binding_bucket"], json!("monthly"));
    assert_eq!(copilot["binding_resets_at"], json!("2099-10-01T00:00:00Z"));
    assert_eq!(copilot["plan"], json!("business"));
    assert_eq!(copilot["credits"]["used"], json!(100_000));
    assert_eq!(copilot["credits_used"], json!(318_085));
    assert_eq!(copilot["pool"], json!("copilot"));
}

#[test]
fn the_copilot_login_is_read_from_the_config_or_the_keyring_and_the_statement_stands_in() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let mut acopilot = measured("acopilot", 20, 10);
    acopilot["harness"] = json!("copilot");
    world.plant_listing(&[acopilot]);
    let home = world.path().join("home");
    for (name, config) in [
        (
            "kcopilot",
            json!({"lastLoggedInUser": {"host": "https://github.com", "login": "probe"}}),
        ),
        (
            "tcopilot",
            json!({"copilotTokens": {"https://acme.ghe.com:a": "ghu_tenant"}}),
        ),
        ("scopilot", json!({})),
    ] {
        let dir = home.join(format!(".{name}"));
        std::fs::create_dir_all(dir.join("session-state")).unwrap();
        std::fs::write(dir.join("config.json"), config.to_string()).unwrap();
    }
    std::fs::remove_file(world.record_path("copilot", "acopilot")).unwrap();
    let dirs = ["acopilot", "kcopilot", "tcopilot", "scopilot"]
        .map(|n| world.dir(n))
        .join(":");
    world.env.retain(|(k, _)| k != "AGENT_RUNTIME_ACCOUNT_DIRS");
    world
        .env
        .push(("AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(), dirs));
    world.env.push((
        "AGENT_RUNTIME_COPILOT_POOL".to_owned(),
        format!("{}=250/1000", world.dir("scopilot")),
    ));
    let secret_tool = world.path().join("bin/secret-tool");
    write_executable(
        &secret_tool,
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$USAGE_FIXTURE_DIR/secret-tool.log\"\ncase \"$5\" in *:github) printf '[/org/freedesktop/secrets/collection/login/7]\\nlabel = keyring:probe@copilot-cli\\nsecret = gho_keyring\\n' ;; esac\n",
    );
    let pool = |remaining: u64| {
        json!({"quota_snapshots": {"premium_interactions": {"entitlement": 1000, "remaining": remaining}},
               "quota_reset_date_utc": "2099-10-01"})
    };
    world.plant_answer("token-acopilot", "copilot", &pool(900), None);
    world.plant_answer("gho_keyring", "copilot", &pool(600), None);
    let roster = world.roster();
    let row = |alias: &str| {
        roster["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["alias"] == json!(alias))
            .map(|r| r["record"].clone())
            .unwrap_or_else(|| panic!("{alias}: {roster}"))
    };
    assert_eq!(row("acopilot")["monthly_pct"], json!(10), "{roster}");
    assert_eq!(
        row("kcopilot")["monthly_pct"],
        json!(40),
        "the keyring login's pool: {roster}"
    );
    assert_eq!(
        std::fs::read_to_string(world.path().join("fixtures/secret-tool.log")).unwrap(),
        "search service copilot-cli username https://github.com:probe:github\n"
    );
    let tenant = row("tcopilot");
    assert_eq!(tenant["status"], json!("no_credentials"), "{tenant}");
    assert!(
        tenant["detail"]
            .as_str()
            .unwrap()
            .starts_with("copilot login unread: token-foreign-host"),
        "{tenant}"
    );
    let stated = row("scopilot");
    assert_eq!(stated["measured_through"], json!("stated"), "{stated}");
    assert_eq!(stated["monthly_pct"], json!(25));
    assert_eq!(stated["credits"]["remaining"], json!(750));
    let log = world.curl_log();
    assert_eq!(
        log,
        vec!["copilot token-acopilot", "copilot gho_keyring"],
        "{log:?}"
    );
    let argv = std::fs::read_to_string(world.path().join("fixtures/curl.argv")).unwrap();
    assert!(
        !argv.contains("token-acopilot")
            && !argv.contains("gho_keyring")
            && !argv.contains("ghu_tenant"),
        "no login on an argument vector: {argv}"
    );
    assert!(argv.contains("-K -"), "{argv}");
}

#[test]
fn an_excluded_account_is_measured_and_refused_for_lanes_and_a_retired_one_refused_by_name() {
    let today = accounts::today(now());
    let mut world = World::new(&[
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "xclaude"),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", &format!("rclaude={today}")),
    ]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[
        measured("xclaude", 0, 0),
        measured("rclaude", 10, 5),
        measured("aclaude", 60, 5),
    ]);
    let roster = world.roster();
    let lines = roster["lines"].as_array().unwrap();
    assert!(
        lines[0]
            .as_str()
            .unwrap()
            .contains(" status=ok verdict=room headroom_pct=100 "),
        "the excluded account is measured: {lines:?}"
    );
    assert!(
        lines[1]
            .as_str()
            .unwrap()
            .ends_with(&format!(" word=retired:{today}")),
        "{lines:?}"
    );
    assert!(
        lines[1]
            .as_str()
            .unwrap()
            .contains(" status=ok verdict=room headroom_pct=90 "),
        "the retired account is measured: {lines:?}"
    );
    let chosen_row = world.pick(&claude(None));
    assert_eq!(
        chosen(&chosen_row).as_deref(),
        Some(world.dir("aclaude").as_str()),
        "neither the excluded nor the retired account, whatever their room: {chosen_row}"
    );
    let excluded = world.pick(&named(&world.dir("xclaude"), claude(None)));
    assert_eq!(excluded["answer"], json!("excluded"), "{excluded}");
    assert_eq!(excluded["exit"], json!(3));
    assert_eq!(excluded["record"]["excluded"], json!(true));
    // An overseer on the excluded home reads its figures: its own pick, the
    // one its marks ask, judges the account and refuses nothing by the
    // owner's lane exclusion.
    let own = world.pick(&PickRequest {
        lane: Some(world.dir("xclaude")),
        for_overseer: true,
        ..claude(None)
    });
    assert_eq!(own["answer"], json!("lane"), "{own}");
    assert_eq!(own["record"]["headroom_pct"], json!(100), "{own}");
    assert_eq!(own["record"]["excluded"], json!(true), "{own}");
    let retired = world.pick(&named(&world.dir("rclaude"), claude(None)));
    assert_eq!(retired["answer"], json!("retired"), "{retired}");
    assert_eq!(retired["record"]["retired"], json!(true));
    assert_eq!(retired["record"]["retire_date"], json!(today));
}

#[test]
fn an_explicit_local_request_under_a_fleet_provider_is_judged_on_the_local_listing() {
    let mut world = World::new(&[
        ("ORCH_LANE_PREFERENCE", "claude@local:fable:high"),
        ("ORCH_LANE_HOST", "provider-x"),
    ]);
    std::os::unix::fs::symlink(
        fixtures().join("kendex-launch/kendex"),
        world.path().join("bin/kendex"),
    )
    .unwrap();
    world.write_fleet(vec![], None);
    let local = measured("aclaude", 20, 5);
    let mut provider = through_host(measured("aclaude", 100, 100));
    provider["config_dir"] = json!(world.dir("aclaude"));
    world.plant_host_listing("provider-x", &[local, provider]);
    let mut command = world.command();
    command.args(["accounts", "walk", "--fleet"]);
    let result = World::reply(command);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(result["chosen"]["host"], json!("local"), "{result}");
    assert_eq!(
        result["chosen"]["account"].as_str(),
        Some(world.dir("aclaude").as_str()),
        "the local account on its own reading, not the provider's: {result}"
    );
    assert!(
        !world.host_log().iter().any(|l| l.ends_with(" accounts")),
        "the provider's rows are not read for a local request: {:?}",
        world.host_log()
    );
}

// --- token renewal -------------------------------------------------------------------------------

/// The credentials file of the planted local account `alias`.
fn credential_file(world: &World, harness: &str, alias: &str) -> PathBuf {
    let name = if harness == "claude" {
        ".credentials.json"
    } else {
        "auth.json"
    };
    PathBuf::from(world.dir(alias)).join(name)
}

/// A Claude login written over the planted one: the access token
/// `token-aclaude` expiring at `expires_ms`, `refresh` as the refresh token
/// where given, the refresh login ending at `login_ends_ms` where given.
/// The text written is returned, so a row can read the file back whole.
fn write_claude_login(
    world: &World,
    expires_ms: u64,
    refresh: Option<&str>,
    login_ends_ms: Option<u64>,
) -> String {
    let mut oauth = json!({
        "accessToken": "token-aclaude",
        "expiresAt": expires_ms,
        "subscriptionType": "max",
    });
    if let Some(refresh) = refresh {
        oauth["refreshToken"] = json!(refresh);
    }
    if let Some(ends) = login_ends_ms {
        oauth["refreshTokenExpiresAt"] = json!(ends);
    }
    let text = json!({"claudeAiOauth": oauth}).to_string();
    std::fs::write(credential_file(world, "claude", "aclaude"), &text).unwrap();
    text
}

fn base64url(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, b| (n << 8) | u32::from(*b)) << (8 * (3 - chunk.len()));
        for i in 0..=chunk.len() {
            out.push(TABLE[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

/// A Codex access token: a JWT whose `exp` claim is `exp`.
fn jwt(exp: u64) -> String {
    format!(
        "{}.{}.sig",
        base64url(b"{\"alg\":\"RS256\"}"),
        base64url(format!("{{\"exp\":{exp}}}").as_bytes())
    )
}

/// The Codex login written over the planted one: `access` expiring as its
/// claim says, `refresh` beside it where given.
fn write_codex_login(world: &World, access: &str, refresh: Option<&str>) {
    let mut tokens = json!({"access_token": access, "account_id": "acct-1"});
    if let Some(refresh) = refresh {
        tokens["refresh_token"] = json!(refresh);
    }
    std::fs::write(
        credential_file(world, "codex", "acodex"),
        json!({"tokens": tokens}).to_string(),
    )
    .unwrap();
}

/// A file under the world's fixture directory, the one the fake `curl`
/// and the fake `codex` read.
fn plant_fixture(world: &World, name: &str, text: &str) {
    let fixtures = world.path().join("fixtures");
    std::fs::create_dir_all(&fixtures).unwrap();
    std::fs::write(fixtures.join(name), text).unwrap();
}

/// The fake Codex CLI first on the world's path, and the fixture
/// directory it logs into.
fn plant_codex_stub(world: &World) {
    std::fs::create_dir_all(world.path().join("fixtures")).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("codex-renew/codex"),
        world.path().join("bin/codex"),
    )
    .unwrap();
}

fn codex_log(world: &World) -> Vec<String> {
    std::fs::read_to_string(world.path().join("fixtures/codex.log"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The record of `alias` in the listing `accounts roster` prints.
fn listed_row(world: &World, alias: &str) -> Value {
    let roster = world.roster();
    roster["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["alias"] == json!(alias))
        .map(|r| r["record"].clone())
        .unwrap_or_else(|| panic!("{alias}: {roster}"))
}

/// A world holding one Claude account whose access token expired an hour
/// ago, its refresh token `refresh-aclaude`, no usage record (so a renewed
/// login fetches its usage) and the client id configured.
fn expired_claude_world() -> World {
    let mut world = World::new(&[("AGENT_RUNTIME_CLAUDE_CLIENT_ID", "client-1")]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    std::fs::remove_file(world.record_path("claude", "aclaude")).unwrap();
    write_claude_login(&world, (now() - 3600) * 1000, Some("refresh-aclaude"), None);
    std::fs::create_dir_all(world.path().join("fixtures")).unwrap();
    world
}

/// The token endpoint's answer for `refresh-aclaude`: a renewed login
/// `renewed-token` with the rotated refresh token, and the usage body
/// the renewed token reads.
fn plant_renewal(world: &World, status: Option<&str>) {
    world.plant_answer(
        "refresh-aclaude",
        "token",
        &json!({"access_token": "renewed-token", "refresh_token": "rotated-refresh", "expires_in": 3600}),
        status,
    );
    world.plant_answer(
        "renewed-token",
        "usage",
        &json!({"seven_day": {"utilization": 20, "resets_at": stamp(now() + 7 * 86_400)}}),
        None,
    );
}

#[test]
fn a_claude_token_refusal_reads_its_status_by_http_answer_and_parks_the_lane_for_its_window() {
    let cases = [
        (
            "429 900",
            json!({"error": {"type": "rate_limit_error", "message": "Rate limited."}}),
            "rate_limited",
            900,
        ),
        (
            "503",
            json!({"error": {"type": "api_error", "message": "Overloaded"}}),
            "unreachable",
            300,
        ),
        (
            "400",
            json!({"error": {"type": "invalid_grant", "message": "Refresh token not found"}}),
            "expired",
            300,
        ),
        ("401", json!({}), "expired", 300),
        (
            "200",
            json!({"error": {"type": "invalid_request", "message": "bad body"}}),
            "expired",
            300,
        ),
        (
            "200",
            json!({"access_token": "renewed-token", "refresh_token": "rotated-refresh"}),
            "expired",
            300,
        ),
        (
            "200",
            json!({"access_token": "renewed-token", "refresh_token": "rotated-refresh", "expires_in": 0}),
            "expired",
            300,
        ),
    ];
    for (status, body, expected, window) in cases {
        let world = expired_claude_world();
        let planted =
            std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap();
        world.plant_answer("refresh-aclaude", "token", &body, Some(status));
        let row = listed_row(&world, "aclaude");
        assert_eq!(row["status"], json!(expected), "{status} {body}: {row}");
        assert_eq!(row["refreshable"], json!(false), "{status}: {row}");
        assert_eq!(row["headroom_pct"], Value::Null, "{status}: {row}");
        let detail = row["detail"].as_str().unwrap();
        assert!(
            detail.starts_with("access token expired and could not be renewed: "),
            "{status}: {detail}"
        );
        let code = status.split(' ').next().unwrap();
        if code != "200" {
            assert!(
                detail.contains(&format!("HTTP {code}")),
                "{status}: {detail}"
            );
        }
        assert_eq!(world.curl_log(), vec!["token refresh-aclaude"], "{status}");
        assert_eq!(
            std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap(),
            planted,
            "{status}: the file is untouched by a refusal"
        );
        let record: Value = serde_json::from_str(
            &std::fs::read_to_string(world.record_path("claude", "aclaude")).unwrap(),
        )
        .unwrap();
        assert_eq!(
            record["refusal"]["endpoint"],
            json!("token"),
            "{status}: {record}"
        );
        assert_eq!(record["refusal"]["code"], json!(code), "{status}: {record}");
        assert_eq!(
            record["refusal"]["expires_at"].as_u64().unwrap()
                - record["fetched_at"].as_u64().unwrap(),
            window,
            "{status}: {record}"
        );
        let again = listed_row(&world, "aclaude");
        assert_eq!(again["status"], json!(expected), "{status}: {again}");
        assert!(again["usage_age_s"].is_number(), "{status}: {again}");
        assert_eq!(
            world.curl_log(),
            vec!["token refresh-aclaude"],
            "{status}: nothing is posted inside the window"
        );
    }
}

#[test]
fn a_claude_renewal_this_machine_cannot_make_names_its_cause_and_posts_nothing() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    std::fs::remove_file(world.record_path("claude", "aclaude")).unwrap();
    write_claude_login(&world, (now() - 3600) * 1000, Some("refresh-aclaude"), None);
    plant_renewal(&world, None);
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("error"), "{row}");
    assert!(
        row["detail"]
            .as_str()
            .unwrap()
            .contains("AGENT_RUNTIME_CLAUDE_CLIENT_ID"),
        "{row}"
    );
    assert_eq!(
        world.curl_log(),
        Vec::<String>::new(),
        "no client id: nothing is posted"
    );
    assert!(
        std::fs::metadata(world.record_path("claude", "aclaude")).is_err(),
        "no client id: nothing is recorded"
    );

    let world = expired_claude_world();
    write_claude_login(&world, (now() - 3600) * 1000, None, None);
    plant_renewal(&world, None);
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("expired"), "{row}");
    assert!(
        row["detail"].as_str().unwrap().contains("no refresh token"),
        "{row}"
    );
    assert_eq!(
        world.curl_log(),
        Vec::<String>::new(),
        "no refresh token: nothing is posted"
    );
    assert!(std::fs::metadata(world.record_path("claude", "aclaude")).is_err());

    let world = expired_claude_world();
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("unreachable"), "{row}");
    assert_eq!(row["refreshable"], json!(false), "{row}");
    assert_eq!(world.curl_log(), vec!["token refresh-aclaude"]);
    assert!(
        std::fs::metadata(world.record_path("claude", "aclaude")).is_err(),
        "an unreached endpoint answered no window to record"
    );
    plant_renewal(&world, None);
    let before = now();
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("ok"), "{row}");
    assert_eq!(row["refreshable"], json!(true), "{row}");
    assert_eq!(row["headroom_pct"], json!(80), "{row}");
    assert_eq!(
        world.curl_log(),
        vec![
            "token refresh-aclaude",
            "token refresh-aclaude",
            "usage renewed-token"
        ],
        "the next listing posts again and reads usage through the new token"
    );
    let file: Value = serde_json::from_str(
        &std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        file["claudeAiOauth"]["accessToken"],
        json!("renewed-token"),
        "{file}"
    );
    assert_eq!(
        file["claudeAiOauth"]["refreshToken"],
        json!("rotated-refresh"),
        "{file}"
    );
    assert_eq!(
        file["claudeAiOauth"]["subscriptionType"],
        json!("max"),
        "{file}"
    );
    let expires = file["claudeAiOauth"]["expiresAt"].as_u64().unwrap();
    assert!(
        (before + 3600) * 1000 <= expires && expires <= (now() + 3600 + 60) * 1000,
        "the new expiry is one lifetime on: {expires}"
    );
    let argv = std::fs::read_to_string(world.path().join("fixtures/curl.argv")).unwrap();
    assert!(
        !argv.contains("refresh-aclaude"),
        "no refresh token on an argument vector: {argv}"
    );
    assert!(argv.contains("--data-binary @-"), "{argv}");
    assert!(argv.contains("-A claude-cli/"), "{argv}");
    let mode = std::os::unix::fs::PermissionsExt::mode(
        &std::fs::metadata(credential_file(&world, "claude", "aclaude"))
            .unwrap()
            .permissions(),
    );
    assert_eq!(
        mode & 0o777,
        0o600,
        "the rewritten file is the owner's alone"
    );
}

#[test]
fn a_live_access_token_under_an_ended_refresh_login_is_refused_without_a_post() {
    let live = (now() + 365 * 86_400) * 1000;
    let world = expired_claude_world();
    world.plant_answer(
        "token-aclaude",
        "usage",
        &json!({"seven_day": {"utilization": 20, "resets_at": stamp(now() + 7 * 86_400)}}),
        None,
    );
    plant_renewal(&world, None);
    write_claude_login(&world, live, Some("refresh-aclaude"), Some(now() * 1000));
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("expired"), "{row}");
    assert_eq!(row["refreshable"], json!(false), "{row}");
    assert_eq!(
        world.curl_log(),
        Vec::<String>::new(),
        "an ended login posts nothing"
    );
    let by_name = world.pick(&named(&world.dir("aclaude"), claude(None)));
    assert_eq!(by_name["answer"], json!("unmeasured"), "{by_name}");
    assert_eq!(by_name["exit"], json!(5), "{by_name}");
    assert_eq!(by_name["record"]["status"], json!("expired"), "{by_name}");
    let chooser = world.pick(&claude(None));
    assert_eq!(chooser["answer"], json!("none"), "{chooser}");
    assert_eq!(chooser["exit"], json!(3), "{chooser}");
    assert_eq!(chooser["record"]["unmeasured"], json!(1), "{chooser}");

    write_claude_login(
        &world,
        live,
        Some("refresh-aclaude"),
        Some((now() + 3600) * 1000),
    );
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("ok"), "{row}");
    assert_eq!(row["refreshable"], json!(false), "{row}");
    assert_eq!(world.curl_log(), vec!["usage token-aclaude"]);

    write_claude_login(
        &world,
        (now() - 3600) * 1000,
        Some("refresh-aclaude"),
        Some((now() - 1) * 1000),
    );
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("expired"), "{row}");
    assert_eq!(
        world.curl_log(),
        vec!["usage token-aclaude"],
        "an expired token under an ended login is not renewed"
    );

    write_claude_login(&world, (now() - 3600) * 1000, Some("refresh-aclaude"), None);
    let row = listed_row(&world, "aclaude");
    assert_eq!(row["status"], json!("ok"), "{row}");
    assert_eq!(row["refreshable"], json!(true), "{row}");
    assert_eq!(row["headroom_pct"], json!(80), "{row}");
    assert_eq!(
        world.curl_log(),
        vec!["usage token-aclaude", "token refresh-aclaude"],
        "a login this listing renewed is the same account: its record is served"
    );
}

#[test]
fn two_renewers_under_the_credentials_lock_rotate_the_refresh_token_once() {
    let world = expired_claude_world();
    plant_renewal(&world, None);
    plant_fixture(&world, "delay", "2\n");
    let children: Vec<std::process::Child> = (0..2)
        .map(|_| {
            let mut command = world.command();
            command
                .args(["accounts", "roster"])
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped());
            command.spawn().unwrap()
        })
        .collect();
    for child in children {
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        let row = reply["result"]["rows"][0]["record"].clone();
        assert_eq!(row["status"], json!("ok"), "{reply}");
        assert_eq!(row["refreshable"], json!(true), "{reply}");
        assert_eq!(row["headroom_pct"], json!(80), "{reply}");
    }
    let log = world.curl_log();
    assert_eq!(
        log.iter().filter(|l| l.starts_with("token ")).count(),
        1,
        "one grant for two renewers: {log:?}"
    );
    assert_eq!(
        log.iter().filter(|l| l.starts_with("usage ")).count(),
        1,
        "one usage request, the waiter served from the record: {log:?}"
    );
    let file: Value = serde_json::from_str(
        &std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        file["claudeAiOauth"]["refreshToken"],
        json!("rotated-refresh"),
        "{file}"
    );
    assert_eq!(
        file["claudeAiOauth"]["accessToken"],
        json!("renewed-token"),
        "{file}"
    );
}

#[test]
fn a_rotation_that_cannot_land_its_file_leaves_the_old_credentials_whole() {
    use std::os::unix::fs::PermissionsExt;
    let world = expired_claude_world();
    let planted = std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap();
    plant_renewal(&world, None);
    plant_fixture(&world, "delay", "3\n");
    let mut command = world.command();
    command
        .args(["accounts", "roster"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let child = command.spawn().unwrap();
    let started = std::time::Instant::now();
    while !world.curl_log().iter().any(|l| l.starts_with("token ")) {
        assert!(
            started.elapsed() < std::time::Duration::from_secs(20),
            "the grant was never posted: {:?}",
            world.curl_log()
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let dir = PathBuf::from(world.dir("aclaude"));
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    let out = child.wait_with_output().unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    let row = reply["result"]["rows"][0]["record"].clone();
    assert_eq!(row["status"], json!("error"), "{reply}");
    assert!(
        row["detail"].as_str().unwrap().contains("could not be"),
        "{reply}"
    );
    assert_eq!(
        std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap(),
        planted,
        "the old file is whole"
    );
    assert_eq!(world.curl_log(), vec!["token refresh-aclaude"]);
    let leftovers: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.ends_with(".tmp"))
        .collect();
    assert_eq!(leftovers, Vec::<String>::new());
}

/// One Codex renewal case: whether the CLI renews, what it says on stderr
/// and answers to request 1, whether it exits at once, the status and the
/// detail fragments the account reads, and the log's last word.
type CodexCase<'a> = (
    bool,
    Option<&'a str>,
    Option<&'a str>,
    bool,
    &'a str,
    Vec<&'a str>,
    &'a str,
);

#[test]
fn a_codex_renewal_is_the_cli_s_own_run_and_its_auth_json_read_back_is_the_verdict() {
    let revoked = "Your access token could not be refreshed. Please log out and sign in again.";
    let offline = "error sending request for url (https://auth.openai.com/oauth/token)";
    let unknown = "500 Internal Server Error: upstream failure";
    let error_answer = "{\"error\":{\"code\":-32603,\"message\":\"workspace routing discovery failed\"},\"id\":1}\n";
    let asked = "initialize,initialized,account/read";
    let cases: [CodexCase; 8] = [
        (true, None, None, false, "ok", vec![], asked),
        (
            false,
            Some(revoked),
            None,
            false,
            "expired",
            vec!["codex could not renew it: Your access token", "codex login"],
            asked,
        ),
        (
            false,
            Some(offline),
            None,
            false,
            "unreachable",
            vec!["codex could not reach the token endpoint: error sending"],
            asked,
        ),
        (
            false,
            None,
            Some(error_answer),
            false,
            "unreachable",
            vec!["codex answered the renewal with an error: workspace routing discovery failed"],
            asked,
        ),
        (
            false,
            Some(unknown),
            Some(error_answer),
            false,
            "unreachable",
            vec![
                "codex could not renew it: 500 Internal Server Error: upstream failure; codex answered the renewal with an error",
            ],
            asked,
        ),
        (
            false,
            Some(unknown),
            None,
            false,
            "expired",
            vec![
                "codex could not renew it: 500 Internal Server Error: upstream failure; run codex once with CODEX_HOME=",
            ],
            asked,
        ),
        (
            false,
            None,
            None,
            false,
            "expired",
            vec!["codex did not renew it; run codex once with CODEX_HOME="],
            asked,
        ),
        (
            false,
            None,
            None,
            true,
            "expired",
            vec!["codex did not renew it; run codex once with CODEX_HOME="],
            "exited",
        ),
    ];
    let mut codex_row = measured("acodex", 30, 0);
    codex_row["harness"] = json!("codex");
    let renewed_auth = json!({"tokens": {
        "access_token": jwt(now() + 36_000), "refresh_token": "rotated-refresh", "account_id": "acct-1"}})
    .to_string();
    for (renewed, says, answer, exits, expected, fragments, last) in cases {
        let mut world = World::new(&[]);
        world.write_fleet(Vec::new(), None);
        world.plant_listing(&[codex_row.clone()]);
        write_codex_login(&world, &jwt(now() - 60), Some("refresh-codex"));
        plant_codex_stub(&world);
        if renewed {
            plant_fixture(&world, "codex.renewed.json", &renewed_auth);
        }
        if let Some(says) = says {
            plant_fixture(&world, "codex.says", says);
        }
        if let Some(answer) = answer {
            plant_fixture(&world, "codex.answer", answer);
        }
        if exits {
            plant_fixture(&world, "codex.exits", "");
        }
        let dir = world.dir("acodex");
        let row = listed_row(&world, "acodex");
        assert_eq!(row["status"], json!(expected), "{says:?} {answer:?}: {row}");
        assert_eq!(row["refreshable"], json!(renewed), "{row}");
        if renewed {
            assert_eq!(row["headroom_pct"], json!(70), "{row}");
            assert_eq!(
                world.curl_log(),
                Vec::<String>::new(),
                "the record is served: {row}"
            );
        } else {
            assert_eq!(row["headroom_pct"], Value::Null, "{row}");
            let detail = row["detail"].as_str().unwrap();
            assert!(
                detail.starts_with("access token expired and could not be renewed: "),
                "{detail}"
            );
            for fragment in fragments {
                assert!(detail.contains(fragment), "{fragment:?} in {detail:?}");
            }
            assert_eq!(
                detail.contains(&format!("CODEX_HOME={dir}")),
                expected == "expired",
                "a dead login names its remedy, an untested one none: {detail}"
            );
        }
        assert_eq!(codex_log(&world), vec![format!("{dir} {dir} {last}")]);
    }

    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[codex_row.clone()]);
    write_codex_login(&world, &jwt(now() - 60), None);
    plant_codex_stub(&world);
    plant_fixture(&world, "codex.renewed.json", &renewed_auth);
    let row = listed_row(&world, "acodex");
    assert_eq!(row["status"], json!("expired"), "{row}");
    assert!(
        row["detail"]
            .as_str()
            .unwrap()
            .contains("there is no refresh token in"),
        "{row}"
    );
    assert_eq!(
        codex_log(&world),
        Vec::<String>::new(),
        "the CLI is never started"
    );

    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[codex_row]);
    write_codex_login(&world, &jwt(now() - 60), Some("refresh-codex"));
    let without = world.path().join("bin-without-codex");
    std::fs::create_dir_all(&without).unwrap();
    std::os::unix::fs::symlink(fixtures().join("usage-curl/curl"), without.join("curl")).unwrap();
    let git = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|dir| dir.join("git"))
        .find(|git| std::fs::metadata(git).is_ok())
        .expect("a git on this process's path");
    std::os::unix::fs::symlink(git, without.join("git")).unwrap();
    let mut command = world.command();
    command.args(["accounts", "roster"]).env("PATH", &without);
    let roster = World::reply(command);
    let row = roster["rows"][0]["record"].clone();
    assert_eq!(row["status"], json!("expired"), "{roster}");
    assert!(
        row["detail"]
            .as_str()
            .unwrap()
            .contains("no codex command is on PATH"),
        "{roster}"
    );
    assert_eq!(codex_log(&world), Vec::<String>::new());
}

#[test]
fn a_callers_ceiling_during_the_claude_grant_still_lands_the_rotated_refresh_token() {
    let world = expired_claude_world();
    plant_renewal(&world, None);
    plant_fixture(&world, "delay", "3\n");
    let mut command = program(tool("timeout"));
    command
        .args(["-s", "TERM", "1"])
        .arg(binary())
        .args(["--no-private-env", "accounts", "roster"])
        .current_dir(world.path())
        .env("PATH", path_without_flock(&world));
    for (key, value) in &world.env {
        command.env(key, value);
    }
    let out = command.output().unwrap();
    assert_eq!(out.status.code(), Some(124), "{}", stderr(&out));
    let file = credential_file(&world, "claude", "aclaude");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let landed = loop {
        let text = std::fs::read_to_string(&file).unwrap();
        let login: Value = serde_json::from_str(&text).unwrap();
        if login["claudeAiOauth"]["refreshToken"] == json!("rotated-refresh") {
            break login;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the rotation the endpoint answered never landed: {login}"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    assert_eq!(
        landed["claudeAiOauth"]["accessToken"],
        json!("renewed-token")
    );
    assert_eq!(world.curl_log(), vec!["token refresh-aclaude"]);
    let mutex = PathBuf::from(world.dir("aclaude")).join(".lanes-refresh.lock.d");
    while std::fs::metadata(&mutex).is_ok() {
        assert!(
            std::time::Instant::now() < deadline,
            "the credentials mutex outlived the renewal"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[test]
fn a_private_file_setting_reaches_the_account_readers_as_it_reached_the_released_listing() {
    let private_run = |world: &World, args: &[&str]| {
        let mut command = program(binary());
        command
            .current_dir(world.path())
            .env("PATH", tool_path(&[&world.path().join("bin")]));
        for (key, value) in &world.env {
            command.env(key, value);
        }
        command.args(args);
        World::reply(command)
    };

    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    std::fs::write(
        world.path().join(".env.local"),
        "AGENT_RUNTIME_ACCOUNT_EXCLUDE=aclaude\n",
    )
    .unwrap();
    let pick = private_run(
        &world,
        &["accounts", "pick", "--fleet", "--harness", "claude"],
    );
    assert_eq!(pick["answer"], json!("none"), "{pick}");
    assert_eq!(pick["exit"], json!(3), "{pick}");
    let roster = private_run(&world, &["accounts", "roster"]);
    assert_eq!(
        roster["rows"][0]["record"]["excluded"],
        json!(true),
        "{roster}"
    );

    let mut world = expired_claude_world();
    world
        .env
        .retain(|(key, _)| key != "AGENT_RUNTIME_CLAUDE_CLIENT_ID");
    plant_renewal(&world, None);
    std::fs::write(
        world.path().join(".env.local"),
        "AGENT_RUNTIME_CLAUDE_CLIENT_ID=client-1\n",
    )
    .unwrap();
    let roster = private_run(&world, &["accounts", "roster"]);
    let row = &roster["rows"][0]["record"];
    assert_eq!(row["status"], json!("ok"), "{roster}");
    assert_eq!(row["refreshable"], json!(true), "{roster}");
    assert_eq!(
        world.curl_log(),
        vec!["token refresh-aclaude", "usage renewed-token"]
    );
}

/// An account key the private file spells through the home is read as the
/// released listing read the file it sourced: `$HOME`, `${HOME}`, a quoted
/// `"$HOME/..."` and a `~` at the value's start or after a `:` name the
/// caller's home, on an `export` line too. A spelling only a shell reads is
/// passed over with one notice, the key read as if the line were absent,
/// and every verb still runs.
#[test]
fn a_private_file_account_key_spelled_through_the_home_reads_the_home_and_a_shell_only_form_is_passed_over()
 {
    let producer = Producer::new();
    producer.plant_usage(&claude_body(json!(10), json!(20), &[]));
    let home = producer.home();
    std::fs::create_dir_all(home.join("lane-a")).unwrap();
    std::fs::copy(
        home.join(".aclaude/.credentials.json"),
        home.join("lane-a/.credentials.json"),
    )
    .unwrap();
    let env: Vec<(String, String)> = producer
        .env(false, &[])
        .into_iter()
        .filter(|(key, _)| key != "AGENT_RUNTIME_ACCOUNT_DIRS")
        .collect();
    let run = |args: &[&str]| {
        let mut command = program(binary());
        command
            .current_dir(producer.path().join("project"))
            .env("PATH", tool_path(&[&producer.path().join("bin")]));
        for (key, value) in &env {
            command.env(key, value);
        }
        command.args(args).output().unwrap()
    };
    let at = |name: &str, status: &str| (home.join(name).display().to_string(), status.to_owned());
    for (line, mut want, skipped) in [
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS=$HOME/lane-a\n",
            vec![at("lane-a", "ok")],
            None,
        ),
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS=\"$HOME/lane-a\"\n",
            vec![at("lane-a", "ok")],
            None,
        ),
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS=~/lane-a\n",
            vec![at("lane-a", "ok")],
            None,
        ),
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS=${HOME}/lane-a:~/.aclaude # both\n",
            vec![at("lane-a", "ok"), at(".aclaude", "ok")],
            None,
        ),
        (
            "export CODEX_HOME=$HOME/.codex-work\n",
            vec![at(".codex-work", "no_credentials")],
            None,
        ),
        (
            "AGENT_RUNTIME_ACCOUNT_DIRS=$(dirname ~/lane-a/x)\n",
            vec![],
            Some("AGENT_RUNTIME_ACCOUNT_DIRS"),
        ),
    ] {
        std::fs::write(producer.path().join("project/.env.local"), line).unwrap();
        let roster = run(&["accounts", "roster"]);
        assert!(roster.status.success(), "{line:?}: {}", stderr(&roster));
        let reply: Value = serde_json::from_slice(&roster.stdout).unwrap();
        let mut dirs: Vec<(String, String)> = reply["result"]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                (
                    row["config_dir"].as_str().unwrap().to_owned(),
                    row["status"].as_str().unwrap().to_owned(),
                )
            })
            .collect();
        dirs.sort();
        want.sort();
        assert_eq!(dirs, want, "{line:?}");
        let notices: Vec<String> = stderr(&roster)
            .lines()
            .filter(|l| l.starts_with("settings-skipped "))
            .map(str::to_owned)
            .collect();
        let want_notice: Vec<String> = skipped
            .map(|key| {
                format!(
                    "settings-skipped path={}/project/.env.local key={key} reason=shell-form",
                    producer.path().display()
                )
            })
            .into_iter()
            .collect();
        assert_eq!(notices, want_notice, "{line:?}");
        let state = run(&["state", "path", "--fleet"]);
        assert!(state.status.success(), "{line:?}: {}", stderr(&state));
    }
}

/// The candidates are the accounts the owner configures, never a login
/// folder found by looking: an `AGENT_RUNTIME_ACCOUNT_DIRS` entry relative to the home
/// lists that home's directory, while the bare `~/.copilot` beside it,
/// signed in, is no row; named by `COPILOT_HOME` it is measured and a named
/// pick judges it, while the chooser still leaves it out; with the setting
/// unset no account is listed and the roster says so.
#[test]
fn the_candidates_are_the_configured_accounts_alone_never_a_login_folder_found_in_the_home() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("2claude", 20, 0)]);
    let copilot = world.path().join("home/.copilot");
    std::fs::create_dir_all(copilot.join("session-state")).unwrap();
    std::fs::write(
        copilot.join("config.json"),
        json!({"copilotTokens": "token-copilot"}).to_string(),
    )
    .unwrap();
    world.plant_answer(
        "token-copilot",
        "copilot",
        &json!({"quota_snapshots": {"premium_interactions": {"entitlement": 300, "remaining": 270}},
                "quota_reset_date_utc": "2099-10-01"}),
        None,
    );
    let set = |world: &mut World, key: &str, value: Option<&str>| {
        world.env.retain(|(k, _)| k != key);
        if let Some(value) = value {
            world.env.push((key.to_owned(), value.to_owned()));
        }
    };
    let listed = |world: &World| -> Vec<String> {
        world.roster()["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["config_dir"].as_str().unwrap().to_owned())
            .collect()
    };
    set(&mut world, "AGENT_RUNTIME_ACCOUNT_DIRS", Some(".2claude"));
    assert_eq!(listed(&world), vec![world.dir("2claude")]);
    let copilot_dir = copilot.display().to_string();
    set(&mut world, "COPILOT_HOME", Some(&copilot_dir));
    assert_eq!(
        listed(&world),
        vec![world.dir("2claude"), copilot_dir.clone()]
    );
    let copilot_pick = |lane: Option<String>| {
        world.pick(&PickRequest {
            harness: "copilot".to_owned(),
            lane,
            ..PickRequest::default()
        })
    };
    let chooser = copilot_pick(None);
    assert_eq!(
        (&chooser["answer"], &chooser["record"]["exclusions"]),
        (&json!("none"), &json!([])),
        "{chooser}"
    );
    let named = copilot_pick(Some(copilot_dir.clone()));
    assert_eq!(
        (&named["answer"], &named["record"]["configured"]),
        (&json!("lane"), &json!(false)),
        "{named}"
    );
    set(&mut world, "COPILOT_HOME", None);
    set(&mut world, "AGENT_RUNTIME_ACCOUNT_DIRS", None);
    let roster = world.roster();
    assert_eq!(roster["accounts"], json!(0), "{roster}");
    assert!(
        roster["lines"].as_array().unwrap().contains(&json!(
            "accounts-unconfigured key=AGENT_RUNTIME_ACCOUNT_DIRS"
        )),
        "{roster}"
    );
}

/// A directory of links to every tool the listing and its fixtures run
/// here, `flock` left out: the path of a host without `flock(1)`.
fn path_without_flock(world: &World) -> PathBuf {
    let bin = world.path().join("bin-without-flock");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(fixtures().join("usage-curl/curl"), bin.join("curl")).unwrap();
    for name in ["bash", "cat", "sleep", "git", "rm"] {
        std::os::unix::fs::symlink(tool(name), bin.join(name)).unwrap();
    }
    assert!(!agent_runtime::record::flock_on_path(Some(bin.as_os_str())));
    bin
}

/// `name` as the boundary's tool path finds it.
fn tool(name: &str) -> PathBuf {
    std::env::split_paths(&tool_path(&[]))
        .map(|dir| dir.join(name))
        .find(|path| std::fs::metadata(path).is_ok())
        .unwrap_or_else(|| panic!("{name} on the tool path"))
}

#[test]
fn without_flock_the_renewal_waits_out_a_shell_renewers_mkdir_mutex_and_takes_its_token() {
    let world = expired_claude_world();
    plant_renewal(&world, None);
    world.plant_answer(
        "peer-token",
        "usage",
        &claude_body(json!(10), json!(30), &[]),
        None,
    );
    let dir = PathBuf::from(world.dir("aclaude"));
    let mutex = dir.join(".lanes-refresh.lock.d");
    std::fs::create_dir(&mutex).unwrap();
    let mut command = world.command();
    command
        .env("PATH", path_without_flock(&world))
        .args(["accounts", "roster"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let child = command.spawn().unwrap();
    let held = || {
        let mut guard = agent_runtime::record::lock(&dir.join(".lanes-refresh")).unwrap();
        let now = agent_runtime::record::Wait {
            limit: std::time::Duration::ZERO,
            ..agent_runtime::record::Wait::DEFAULT
        };
        guard.with_wait(&now.start(), || Ok(())).is_err()
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while !held() {
        assert!(
            std::time::Instant::now() < deadline,
            "the renewal never took the credentials flock"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let window = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < window {
        assert_eq!(
            world.curl_log(),
            Vec::<String>::new(),
            "nothing is posted while the shell renewer's mutex stands"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::fs::write(
        credential_file(&world, "claude", "aclaude"),
        json!({"claudeAiOauth": {
            "accessToken": "peer-token", "refreshToken": "peer-refresh",
            "expiresAt": (now() + 3600) * 1000, "subscriptionType": "max"}})
        .to_string(),
    )
    .unwrap();
    std::fs::remove_dir(&mutex).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    let row = &reply["result"]["rows"][0]["record"];
    assert_eq!(row["status"], json!("ok"), "{reply}");
    assert_eq!(row["headroom_pct"], json!(70), "{reply}");
    assert_eq!(world.curl_log(), vec!["usage peer-token"]);
    let login: Value = serde_json::from_str(
        &std::fs::read_to_string(credential_file(&world, "claude", "aclaude")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        login["claudeAiOauth"]["refreshToken"],
        json!("peer-refresh")
    );
    assert!(
        std::fs::metadata(&mutex).is_err(),
        "the renewal's own mutex is gone"
    );
}

#[test]
fn a_cold_429_is_asked_once_more_by_the_first_cold_account_of_a_listing_alone() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 10), measured("bclaude", 20, 10)]);
    for alias in ["aclaude", "bclaude"] {
        std::fs::remove_file(world.record_path("claude", alias)).unwrap();
        world.plant_answer(
            &format!("token-{alias}"),
            "usage",
            &claude_body(json!(10), json!(20), &[]),
            None,
        );
        plant_fixture(&world, &format!("token-{alias}.usage.first"), "429 1\n");
    }
    let roster = world.roster();
    let row = |alias: &str| {
        roster["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["alias"] == json!(alias))
            .map(|r| r["record"].clone())
            .unwrap_or_else(|| panic!("{alias}: {roster}"))
    };
    let retried = row("aclaude");
    assert_eq!(retried["status"], json!("ok"), "{retried}");
    assert_eq!(retried["headroom_pct"], json!(80), "{retried}");
    let refused = row("bclaude");
    assert_eq!(refused["status"], json!("rate_limited"), "{refused}");
    assert_eq!(refused["headroom_pct"], Value::Null, "{refused}");
    assert_eq!(
        world.curl_log(),
        vec![
            "usage token-aclaude",
            "usage token-aclaude",
            "usage token-bclaude"
        ],
        "one retry per listing, spent on the first cold account"
    );
    let record = |alias: &str| -> Value {
        serde_json::from_str(&std::fs::read_to_string(world.record_path("claude", alias)).unwrap())
            .unwrap()
    };
    assert_eq!(record("aclaude")["refusal"], Value::Null);
    assert_eq!(record("bclaude")["refusal"]["code"], json!("429"));
}

/// The host fixture's `accounts` answer for `host`, its lines as given.
fn answer_accounts(world: &World, host: &str, lines: &str) {
    let path = world.path().join("lane-host.json");
    let mut map: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    map[format!("{host} accounts")] = json!({"stdout": lines});
    std::fs::write(path, map.to_string()).unwrap();
}

#[test]
fn a_cached_provider_answer_whose_consumed_window_has_reset_is_asked_again() {
    let mut world = World::new(&[("ORCH_LANE_HOST", "provider-x")]);
    world.write_fleet(Vec::new(), None);
    world.plant_host_listing("provider-x", &[]);
    let line = |pct: u64, reset: u64| {
        format!(
            "account=/srv/.pclaude\tharness=claude\tweekly-pct={pct}\tweekly-resets={}\n",
            stamp(reset)
        )
    };
    answer_accounts(&world, "provider-x", &line(100, now() - 60));
    let first = world.pick(&claude(None));
    assert_eq!(first["answer"], json!("none"), "{first}");
    answer_accounts(&world, "provider-x", &line(20, now() + 3600));
    let after = world.pick(&claude(None));
    assert_eq!(after["answer"], json!("lane"), "{after}");
    assert_eq!(
        after["record"]["config_dir"],
        json!("/srv/.pclaude"),
        "{after}"
    );
    assert_eq!(
        world
            .host_log()
            .iter()
            .filter(|l| l.ends_with(" accounts"))
            .count(),
        2,
        "{:?}",
        world.host_log()
    );
}

#[test]
fn two_readers_of_a_changed_login_fetch_its_usage_once() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    world.plant_listing(&[measured("aclaude", 20, 5)]);
    std::fs::File::open(world.record_path("claude", "aclaude"))
        .unwrap()
        .set_modified(UNIX_EPOCH + std::time::Duration::from_secs(now() - 60))
        .unwrap();
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(10), json!(20), &[]),
        None,
    );
    let hold = world.path().join("fixtures/hold");
    assert!(
        program("mkfifo")
            .arg(&hold)
            .env("PATH", tool_path(&[]))
            .status()
            .unwrap()
            .success()
    );
    let start = || {
        let mut command = world.command();
        command
            .args(["accounts", "roster"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        command.spawn().unwrap()
    };
    let first = start();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::fs::metadata(world.path().join("fixtures/held")).is_err() {
        assert!(
            std::time::Instant::now() < deadline,
            "the first request never came"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let second = start();
    let waiting = || {
        std::fs::read_dir(format!("/proc/{}/fd", second.id()))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|fd| std::fs::read_link(fd.path()).ok())
            .any(|target| target.ends_with(".usage-refresh.lock"))
    };
    while !waiting() {
        assert!(
            std::time::Instant::now() < deadline,
            "the second reader never reached the refresh lock"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&hold)
        .and_then(|mut fifo| std::io::Write::write_all(&mut fifo, b"go\n"))
        .unwrap();
    for child in [first, second] {
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(
            reply["result"]["rows"][0]["record"]["headroom_pct"],
            json!(80),
            "{reply}"
        );
    }
    assert_eq!(world.curl_log(), vec!["usage token-aclaude"]);
}

#[test]
fn a_codex_cli_ending_at_the_end_of_its_input_still_renews_while_stdin_is_held_for_its_answer() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let mut codex_row = measured("acodex", 30, 0);
    codex_row["harness"] = json!("codex");
    world.plant_listing(&[codex_row]);
    write_codex_login(&world, &jwt(now() - 60), Some("refresh-codex"));
    plant_codex_stub(&world);
    plant_fixture(
        &world,
        "codex.renewed.json",
        &json!({"tokens": {
            "access_token": jwt(now() + 36_000), "refresh_token": "rotated-refresh", "account_id": "acct-1"}})
        .to_string(),
    );
    plant_fixture(&world, "codex.inflight", "");
    let row = listed_row(&world, "acodex");
    assert_eq!(row["status"], json!("ok"), "{row}");
    assert_eq!(row["refreshable"], json!(true), "{row}");
    let dir = world.dir("acodex");
    assert_eq!(
        codex_log(&world),
        vec![format!("{dir} {dir} initialize,initialized,account/read")]
    );
}
