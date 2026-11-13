//! The accounts judge: the status words over the reader's listing, the
//! window a lane on a model is judged on, the projection with the
//! candidate charged to each window's reset, the one limit a seat is held
//! to, the grant tier, an unreadable listing admitting nothing, the usage
//! reads, the cache and the renewal, and the record's spelling the shell
//! callers read. Each row's name says the failure it catches.
//!
//! Two kinds of row: a pure judge case hands rows to `accounts::pick` in
//! this process; a case whose production path starts a child (the usage
//! fixture `curl`, the renewal's own step) asks the executable under the
//! test child's isolation, so every child runs under its environment and
//! never this process's. The accounts are planted as the listing reads them
//! (`plant_listing`): a local account's directory, credential and usage
//! record under the world's home; the usage endpoints are the `usage-curl`
//! fixture, which answers from planted bodies and logs each request; the
//! controller record is the row's own. No orch stands in a world, so no
//! lane is counted: the lanes' charges are orch's rows.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the records they plant, hold the children whose identities they record, and read the fixture's log"
)]

#[path = "account_planters.rs"]
mod account_planters;
#[path = "isolation.rs"]
mod isolation;

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use account_planters::*;
use agent_runtime::accounts::{
    self, AccountRow, EndSource, FleetFacts, PickAnswer, PickRequest, Roster, Word,
};
use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::settings::{self, AccountSettings, Judged, Keys};
use isolation::*;
use serde_json::{Value, json};

/// The controller record a world plants: its `overseer` member is a seat.
const RECORD: &str = "workflow-state-oversee.json";

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_agent-runtime"))
}

/// The executable under the test child's isolation, its working directory
/// the temporary root's own, so no checkout above it is a project root.
fn isolated() -> std::process::Command {
    let cwd = std::env::temp_dir().join("isolated-cwd");
    std::fs::create_dir_all(&cwd).expect("the isolated working directory");
    let mut command = program(binary());
    command.current_dir(cwd);
    command
}

/// The settings a world's reading takes, as the executable loads them from
/// the world's environment.
struct Settings {
    accounts: Judged<AccountSettings>,
    account_state: Judged<PathBuf>,
}

/// One world: the usage fixture as `bin/curl`, the accounts planted under
/// its `home` with their usage records under it, the settings naming them
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
        std::os::unix::fs::symlink(
            account_fixtures().join("usage-curl/curl"),
            dir.path().join("bin/curl"),
        )
        .unwrap();
        let base = [
            ("HOME", dir.path().join("home").display().to_string()),
            (
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                dir.path().display().to_string(),
            ),
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
        let settings = World::load(dir.path(), &env);
        World { dir, settings, env }
    }

    /// The account settings of `env` read as the executable reads them,
    /// with no settings file and no private env file in the world.
    fn load(project: &Path, env: &[(String, String)]) -> Settings {
        let environment: Vec<(OsString, OsString)> = env
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect();
        let keys = Keys {
            read: &[settings::ACCOUNT_KEYS],
            load: &[],
        };
        let values = settings::layered(project, &environment, false, &keys).unwrap();
        Settings {
            accounts: AccountSettings::read(&values),
            account_state: settings::account_state_dir(&values),
        }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.path().join(RECORD)
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
    /// the home with their records.
    fn plant_listing(&mut self, rows: &[Value]) {
        let Planted { env, .. } = plant_listing(self.path(), self.path(), rows, now());
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
        self.settings = World::load(self.path(), &self.env);
    }

    /// The controller record: `lanes` beside the member whose account is a
    /// seat, where one is named.
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
            agent_runtime::record::cksum(dir.as_bytes()),
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

    /// The executable in this world, with its environment and the usage
    /// fixture first on its path.
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

    /// `accounts pick --record` for `req`: the reply's `result`, the
    /// answer's word, its exit and its record.
    fn pick(&self, req: &PickRequest) -> Value {
        let mut command = self.command();
        command.args(["accounts", "pick", "--harness", req.harness.name()]);
        command.arg("--record").arg(self.fleet_path());
        if let Some(model) = &req.model {
            command.args(["--native-model", model]);
        }
        for dir in &req.exclude {
            command.args(["--exclude-account", dir]);
        }
        if req.for_overseer {
            command.arg("--for-controller");
        }
        if let Some(lane) = &req.lane {
            command.args(["--account", lane]);
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

    /// `accounts judge --record` over the batch `lines` with `flags`, read
    /// from a file in the world, or from stdin where `stdin` is set: the
    /// reply's `result`.
    fn judge(&self, lines: &str, flags: &[&str], stdin: bool) -> Value {
        let mut command = self.command();
        command.args(["accounts", "judge", "--record"]);
        command.arg(self.fleet_path()).args(flags);
        if !stdin {
            let file = self.path().join("batch.txt");
            std::fs::write(&file, lines).unwrap();
            command.arg("--rows").arg(file);
            return World::reply(command);
        }
        command
            .args(["--rows", "-"])
            .stdin(std::process::Stdio::piped());
        command
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut child = command.spawn().unwrap();
        std::io::Write::write_all(&mut child.stdin.take().unwrap(), lines.as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        reply["result"].clone()
    }
}

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
        model: model.map(str::to_owned),
        ..PickRequest::new(Harness::Claude)
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

/// The account a Pi lane spends follows its model's provider, and
/// `Harness::billed` answers it by the pick's own rule: a `pi-claude/`
/// model spends a Claude seat, a `github-copilot/` or `anthropic/` one the
/// Pi root, and any other provider, or a model named without one, nothing
/// the pick measures. A rule that answered otherwise would have its caller
/// judge a Pi lane on an account the lane does not spend.
#[test]
fn the_billed_verb_names_the_account_a_pi_lane_spends_by_its_models_provider() {
    let models = [
        "pi-claude/claude-opus-5-5",
        "github-copilot/claude-opus-5-5",
        "anthropic/claude-opus-5-5",
        "openai/gpt-5",
        "claude-opus-5-5",
    ];
    let answers: Vec<Option<Harness>> = models.iter().map(|m| Harness::Pi.billed(m)).collect();
    assert_eq!(
        answers,
        vec![
            Some(Harness::Claude),
            Some(Harness::Pi),
            Some(Harness::Pi),
            None,
            None
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
    assert_eq!(
        walled.reply()["record"]["refusals"],
        json!([{"config_dir": "/home/me/.sooner", "refusal": {"cause": "cloud-credit", "retry_at": null}}]),
        "the `none` answer names the grant's refusal, the read its caller repairs"
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
        model: Some("anthropic/claude-opus-5".to_owned()),
        ..PickRequest::new(Harness::Pi)
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
        matches!(&unmeasured, PickAnswer::ProviderUnmeasured { harness, model } if *harness == Harness::Pi && model == "anthropic/claude-opus-5"),
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
        "--harness",
        "claude",
        "--native-model",
        "claude-sonnet-5-5",
        "--account",
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
        "agent-runtime: account-none harness=claude exit=3"
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
        ..PickRequest::new(Harness::Codex)
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
    let path = agent_runtime::accounts::wall::account_wall_path(
        &world.settings.account_state.get().unwrap(),
        dir,
    );
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut record = json!({
        "config_dir": agent_runtime::accounts::wall::canon(dir),
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
            ..PickRequest::new(Harness::Codex)
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

/// A stated Pi root is measured through its own Copilot login, as a Copilot
/// CLI home is, and that reading stands over the statement; a root whose
/// login does not read, or whose login the endpoint refuses or leaves
/// unanswered, keeps the statement, with the reason it measured nothing.
/// Every statement here says its pool is spent, so only a measured reading
/// finds room.
#[test]
fn a_pi_roots_copilot_login_is_measured_first_and_the_statement_stands_in_where_it_does_not() {
    let mut world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let login = |refresh: &str, host: Option<&str>| {
        let mut entry = json!({"type": "oauth", "refresh": refresh,
                               "access": format!("tid-{refresh}"), "expires": (now() + 3600) * 1000});
        if let Some(host) = host {
            entry["enterpriseUrl"] = json!(host);
        }
        json!({"github-copilot": entry})
    };
    for (name, auth) in [
        ("mpi", Some(login("ghu_pi", None))),
        ("tpi", Some(login("ghu_tenant", Some("acme.ghe.com")))),
        ("spi", None),
        ("rpi", Some(login("ghu_refused", None))),
        ("upi", Some(login("ghu_unanswered", None))),
    ] {
        let dir = world.path().join("home").join(format!(".{name}"));
        std::fs::create_dir_all(&dir).unwrap();
        if let Some(auth) = auth {
            std::fs::write(dir.join("auth.json"), auth.to_string()).unwrap();
        }
    }
    let pool = ["mpi", "tpi", "spi", "rpi", "upi"]
        .map(|n| format!("{}=1000/1000", world.dir(n)))
        .join(",");
    world
        .env
        .push(("AGENT_RUNTIME_COPILOT_POOL".to_owned(), pool));
    let room = json!({"quota_snapshots": {"premium_interactions": {"entitlement": 1000, "remaining": 600}},
                      "quota_reset_date_utc": "2099-10-01", "copilot_plan": "individual"});
    world.plant_answer("ghu_pi", "copilot", &room, None);
    world.plant_answer("ghu_refused", "copilot", &room, Some("401"));
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
    let fields = |r: &Value| {
        [
            "harness",
            "measured_through",
            "status",
            "monthly_pct",
            "pool",
        ]
        .map(|k| r[k].clone())
    };
    let measured = row("mpi");
    assert_eq!(
        fields(&measured),
        [
            json!("pi"),
            json!("local"),
            json!("ok"),
            json!(40),
            json!("copilot")
        ],
        "{measured}"
    );
    for (alias, reason) in [
        ("tpi", "token-foreign-host"),
        ("spi", "auth-missing"),
        ("rpi", "refused"),
        ("upi", "unreachable"),
    ] {
        let stated = row(alias);
        assert_eq!(
            fields(&stated),
            [
                json!("pi"),
                json!("stated"),
                json!("ok"),
                json!(100),
                json!("copilot")
            ],
            "{stated}"
        );
        assert!(
            stated["detail"].as_str().unwrap().contains(reason),
            "{stated}"
        );
    }
    assert_eq!(
        world.curl_log(),
        vec![
            "copilot ghu_pi",
            "copilot ghu_refused",
            "copilot ghu_unanswered"
        ]
    );
    let argv = std::fs::read_to_string(world.path().join("fixtures/curl.argv")).unwrap();
    assert!(
        !argv.contains("ghu_pi"),
        "no login on an argument vector: {argv}"
    );
    let reply = world.pick(&PickRequest {
        model: Some("github-copilot/claude-sonnet-5".to_owned()),
        ..PickRequest::new(Harness::Pi)
    });
    assert_eq!(chosen(&reply), Some(world.dir("mpi")), "{reply}");
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
        lines[0].as_str().unwrap().ends_with(" word=reserve"),
        "an account kept from workers reads as a reserved one: {lines:?}"
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
    assert_eq!(excluded["record"]["word"], json!("reserve"));
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

/// One Codex row's credit facts as the provider line states them.
fn codex_credit(balance: u64) -> String {
    format!(
        "credit-remaining={balance}\tcredit-available=1\tcredit-overage-limit-reached=0\tcredit-spend-control-reached=0"
    )
}

/// A batch someone else measured is judged by the one judge, one entry per
/// line in order, its line number the text's: a Codex week spent is room on
/// a credit above the floor (5000) and walled below it; a provider's
/// reserve and a non-Claude plan end refuse by their words with the figures
/// kept; a line nobody can read is its own `unreadable` entry and the lines
/// beside it are judged; the owner's exclusion refuses for a lane and not
/// for the controller's own question.
#[test]
fn a_supplied_batch_is_judged_line_by_line_by_the_one_judge() {
    let today = accounts::today(now());
    let world = World::new(&[("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "xclaude")]);
    world.write_fleet(Vec::new(), None);
    let week = stamp(now() + 60 * 3600);
    let lines = [
        format!(
            "account=/home/me/.credit\tharness=codex\tweekly-pct=100\tweekly-resets={week}\t{}",
            codex_credit(6000)
        ),
        format!(
            "account=/home/me/.floor\tharness=codex\tweekly-pct=100\tweekly-resets={week}\t{}",
            codex_credit(4000)
        ),
        String::new(),
        "account=/home/me/.held\tharness=claude\tweekly-pct=10\treserved=1".to_owned(),
        format!("account=/home/me/.ending\tharness=codex\tweekly-pct=10\tplan-ends={today}"),
        "account=/home/me/.broken\tharness=claude\tweekly-pct=abc".to_owned(),
        "account=/home/me/.xclaude\tharness=claude\tweekly-pct=20".to_owned(),
    ]
    .join("\n");
    let reply = world.judge(&lines, &[], false);
    let rows = reply["rows"].as_array().unwrap();
    let ended = format!("retired:{today}");
    // line, account, verdict, word, binding bucket, headroom
    let table: [(u64, &str, &str, &str, &str, Value); 6] = [
        (1, "/home/me/.credit", "room", "pick", "credits", json!(0)),
        (2, "/home/me/.floor", "walled", "pick", "weekly", json!(0)),
        (
            4,
            "/home/me/.held",
            "reserved",
            "reserve",
            "weekly",
            json!(90),
        ),
        (
            5,
            "/home/me/.ending",
            "retired",
            &ended,
            "weekly",
            json!(90),
        ),
        (6, "/home/me/.broken", "unreadable", "", "", Value::Null),
        (
            7,
            "/home/me/.xclaude",
            "excluded",
            "reserve",
            "weekly",
            json!(80),
        ),
    ];
    assert_eq!(rows.len(), table.len(), "{reply}");
    for (entry, (line, account, verdict, word, bucket, headroom)) in rows.iter().zip(table) {
        assert_eq!(entry["line"], json!(line), "{entry}");
        assert_eq!(entry["account"], json!(account), "{entry}");
        assert_eq!(entry["verdict"], json!(verdict), "{entry}");
        if verdict == "unreadable" {
            assert_eq!(entry["field"], json!("weekly-pct"), "{entry}");
            continue;
        }
        assert_eq!(entry["word"], json!(word), "{entry}");
        assert_eq!(entry["record"]["verdict"], json!(verdict), "{entry}");
        assert_eq!(entry["record"]["binding_bucket"], json!(bucket), "{entry}");
        assert_eq!(entry["record"]["headroom_pct"], headroom, "{entry}");
        assert_eq!(
            entry["record"]["measured_through"],
            json!("supplied"),
            "{entry}"
        );
    }
    let own = world.judge(&lines, &["--for-controller"], false);
    assert_eq!(own["rows"][5]["verdict"], json!("room"), "{own}");
}

/// The listing's verdict of a reading this machine took and the judge's
/// verdict of the same figures supplied are one: a Codex week spent with a
/// credit above the floor is room on the credit in both, below it walled
/// in both.
#[test]
fn a_reading_this_machine_took_and_the_same_figures_supplied_read_one_verdict() {
    for (balance, verdict, bucket) in [(6000, "room", "credits"), (4000, "walled", "weekly")] {
        let mut world = World::new(&[]);
        world.write_fleet(Vec::new(), None);
        let mut row = measured("lcodex", 100, 0);
        row["harness"] = json!("codex");
        row["credits"] = json!({"has_credits": true, "unlimited": false,
            "overage_limit_reached": false, "spend_control_reached": false, "balance": balance});
        world.plant_listing(std::slice::from_ref(&row));
        let local = &world.roster()["rows"][0]["record"];
        let supplied = world.judge(&provider_line(&row, &world.dir("lcodex")), &[], true);
        let supplied = &supplied["rows"][0]["record"];
        for record in [local, supplied] {
            assert_eq!(record["verdict"], json!(verdict), "{balance}: {record}");
            assert_eq!(
                record["binding_bucket"],
                json!(bucket),
                "{balance}: {record}"
            );
        }
    }
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
        account_fixtures().join("codex-renew/codex"),
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
    std::os::unix::fs::symlink(
        account_fixtures().join("usage-curl/curl"),
        without.join("curl"),
    )
    .unwrap();
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
        .args(["accounts", "roster"])
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
    let pick = private_run(&world, &["accounts", "pick", "--harness", "claude"]);
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
    let mut world = World::new(&[
        ("AGENT_RUNTIME_USAGE_TTL", "0"),
        ("AGENT_RUNTIME_USAGE_MAX_AGE", "0"),
    ]);
    world.plant_listing(&[measured("aclaude", 20, 10)]);
    world.plant_answer(
        "token-aclaude",
        "usage",
        &claude_body(json!(10), json!(20), &[]),
        None,
    );
    let home = world.path().join("home");
    std::fs::create_dir_all(home.join("lane-a")).unwrap();
    std::fs::copy(
        home.join(".aclaude/.credentials.json"),
        home.join("lane-a/.credentials.json"),
    )
    .unwrap();
    std::fs::create_dir_all(world.path().join("project")).unwrap();
    let env: Vec<(String, String)> = world
        .env
        .iter()
        .filter(|(key, _)| key != "AGENT_RUNTIME_ACCOUNT_DIRS")
        .cloned()
        .collect();
    let run = |args: &[&str]| {
        let mut command = program(binary());
        command
            .current_dir(world.path().join("project"))
            .env("PATH", tool_path(&[&world.path().join("bin")]));
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
        std::fs::write(world.path().join("project/.env.local"), line).unwrap();
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
                    world.path().display()
                )
            })
            .into_iter()
            .collect();
        assert_eq!(notices, want_notice, "{line:?}");
        let pick = run(&["accounts", "pick", "--harness", "claude"]);
        assert!(pick.status.success(), "{line:?}: {}", stderr(&pick));
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
            lane,
            ..PickRequest::new(Harness::Copilot)
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
    std::os::unix::fs::symlink(account_fixtures().join("usage-curl/curl"), bin.join("curl"))
        .unwrap();
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

/// A verb's name, its argv and the refusal's fields it must print.
type Case<'a> = (&'a str, &'a [&'a str], Vec<(&'a str, &'a str)>);

/// A harness word outside the four is refused by its name, with the four
/// beside it, by every account verb that takes one: the pick's harness, the
/// walk's source and caller, and a preference entry's, each before a read
/// and with nothing written under the records' root.
#[test]
fn every_verb_taking_a_harness_refuses_one_outside_the_four_by_its_name_and_writes_nothing() {
    let world = World::new(&[]);
    let cases: [Case; 4] = [
        (
            "accounts pick",
            &[
                "accounts",
                "pick",
                "--harness",
                "opencode",
                "--native-model",
                "m",
            ],
            vec![
                ("harness", "opencode"),
                ("supported", "claude,codex,copilot,pi"),
            ],
        ),
        (
            "accounts walk source",
            &[
                "accounts",
                "walk",
                "--preference",
                "",
                "--source-harness",
                "opencode",
            ],
            vec![
                ("harness", "opencode"),
                ("supported", "claude,codex,copilot,pi"),
            ],
        ),
        (
            "accounts walk caller",
            &[
                "accounts",
                "walk",
                "--preference",
                "",
                "--caller-harness",
                "opencode",
            ],
            vec![
                ("harness", "opencode"),
                ("supported", "claude,codex,copilot,pi"),
            ],
        ),
        (
            "accounts walk preference",
            &["accounts", "walk", "--preference", "opencode:m:high"],
            vec![
                ("entry", "opencode:m:high"),
                ("harness", "opencode"),
                ("supported", "claude,codex,copilot,pi"),
            ],
        ),
    ];
    for (name, args, fields) in cases {
        let mut command = world.command();
        command.args(args);
        let out = command.output().unwrap();
        assert_eq!(out.status.code(), Some(1), "{name}: {}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        let key = if name.ends_with("preference") {
            "preference-invalid"
        } else {
            "harness-unknown"
        };
        assert_eq!(reply["refusal"]["key"], json!(key), "{name}: {reply}");
        let want: Vec<Value> = fields.iter().map(|(k, v)| json!([k, v])).collect();
        assert_eq!(reply["refusal"]["fields"], json!(want), "{name}: {reply}");
    }
    assert!(
        !world.path().join("usage").exists() && !world.path().join("walls").exists(),
        "a refused verb wrote under the records' root"
    );
}

/// The lanes' charges are asked of the project's orch, the one program that
/// counts them: a project holding no orch has no lanes and the reading
/// counts none; one holding orch's shipped entry with its runtime unbuilt
/// refuses `account-charges-unread` with the entry and its exit, the keyed
/// line under `--env` too, never a judgement as if no lane ran.
#[test]
fn an_installed_orch_that_cannot_count_its_lanes_refuses_the_reading_and_no_orch_counts_none() {
    let mut world = World::new(&[]);
    world.plant_listing(&[measured("aclaude", 20, 0)]);
    world.write_fleet(Vec::new(), None);
    let none = world.pick(&claude(None));
    assert_eq!(chosen(&none), Some(world.dir("aclaude")), "{none}");
    assert_eq!(none["record"]["claims"], json!(0), "{none}");
    let skills = world.path().join(".agents/skills");
    std::fs::create_dir_all(&skills).unwrap();
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for name in ["orch", "agent-runtime"] {
        std::os::unix::fs::symlink(repo.join(name).canonicalize().unwrap(), skills.join(name))
            .unwrap();
    }
    let cache = world.path().join("cache");
    let entry = skills
        .join("orch/scripts/orch-runtime")
        .display()
        .to_string();
    for text in [false, true] {
        let mut command = world.command();
        command.env("AGENT_RUNTIME_CACHE", &cache).args([
            "accounts",
            "pick",
            "--harness",
            "claude",
        ]);
        if text {
            command.arg("--env");
        }
        let out = command.output().unwrap();
        assert_eq!(out.status.code(), Some(1), "--env {text}: {}", stderr(&out));
        let line = format!("agent-runtime: account-charges-unread program={entry} exit=69");
        assert!(
            stderr(&out).lines().any(|l| l == line),
            "--env {text}: {}",
            stderr(&out)
        );
        if !text {
            let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(
                reply["refusal"]["key"],
                json!("account-charges-unread"),
                "{reply}"
            );
        }
    }
}
