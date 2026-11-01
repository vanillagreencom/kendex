//! The accounts judge (step6-map § A10; decisions 97, 99, 141 (5), 183
//! Q10, Q11; round 8 items 5-7; U6h): the status words over the legacy
//! reader's listing, the window a lane on a model is judged on, the
//! projection on the fleet's own live charges with the replaced lane left
//! out, and an unreadable listing admitting nothing. Each row names the
//! defect it catches at its doc comment. The reader is the
//! `lanes-listing` fixture, which prints a planted listing and logs what
//! it was handed; the fleet state and the live lane are the row's own.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the records they plant, hold the child whose identity they record, and read the fixture's log"
)]

#[path = "support.rs"]
mod support;

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use orch_runtime::ops::Host;
use orch_runtime::ops::accounts::{
    self, AccountRow, EndSource, FleetFacts, PickAnswer, PickRequest, Roster, Word,
};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::FLEET_FILE_NAME;
use serde_json::{Value, json};
use support::*;

/// A fixed instant: 2026-10-20T12:00:00Z, so the stated ends the rows
/// plant are ahead, at, or behind it by the UTC day.
const NOW: u64 = 1_792_497_600;

/// One world: a state directory with the fixture symlinked as `lanes`
/// and the settings naming it, under `extra` as the caller's environment.
struct World {
    dir: tempfile::TempDir,
    settings: Settings,
}

impl World {
    fn new(extra: &[(&str, &str)]) -> World {
        let dir = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(
            fixtures().join("lanes-listing/lanes"),
            dir.path().join("lanes"),
        )
        .unwrap();
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
        World { dir, settings }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.path().join(FLEET_FILE_NAME)
    }

    fn plant_listing(&self, rows: &[Value]) {
        std::fs::write(
            self.path().join("lanes.json"),
            serde_json::to_string(&Value::Array(rows.to_vec())).unwrap(),
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

    /// The fixture's log emptied, so the next read is what one call asked.
    fn clear_log(&self) {
        let _ = std::fs::remove_file(self.path().join("lanes.log"));
    }

    fn plant_pick(&self, exit: i32, body: Value) {
        std::fs::write(
            self.path().join("pick.json"),
            serde_json::to_string(&json!({"exit": exit, "body": body})).unwrap(),
        )
        .unwrap();
    }

    fn host(&self) -> Host<'static> {
        Host::kernel(
            self.settings.lane_cap,
            Some(self.settings.claim_store.clone()),
        )
    }

    fn pick(&self, req: &PickRequest) -> PickAnswer {
        accounts::pick_fleet(&self.settings, &self.fleet_path(), &self.host(), req, NOW)
    }
}

/// One measured local row of `lanes list --json` for a Claude account at
/// `alias`, `used` percent on its weekly window (the binding), the session
/// window at `session` percent resetting five hours on.
fn measured(alias: &str, used: u64, session: u64) -> Value {
    json!({
        "alias": alias,
        "harness": "claude",
        "config_dir": format!("/home/me/.{alias}"),
        "measured_through": "local",
        "status": "ok",
        "verdict": if used < 95 { "room" } else { "walled" },
        "headroom_pct": 100 - used,
        "binding_bucket": "weekly",
        "binding_resets_at": "2026-10-23T00:00:00Z",
        "wall": used,
        "session_5h_pct": session,
        "weekly_pct": used,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": "2026-10-20T17:00:00Z", "weekly": "2026-10-23T00:00:00Z", "model": null, "monthly": null},
        "usage_rate_state": "one-sample",
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
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
        | PickAnswer::Unmeasured(_)
        | PickAnswer::NoRecord
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
        | PickAnswer::Unmeasured(_)
        | PickAnswer::NoRecord
        | PickAnswer::Unjudged { .. } => Vec::new(),
    }
}

/// Round 8 item 7 (A10 row (1)). Defect: a `reserve` account picked for a
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
    let req = PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    };
    let answer = accounts::pick(
        &rows,
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        NOW,
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
        NOW,
    );
    assert_eq!(picked(&alone), None);
    assert_eq!(
        exclusions(&alone),
        vec![("/home/me/.5claude".to_owned(), "reserved".to_owned())]
    );
    let roster = Roster { rows };
    assert_eq!(
        roster.lines("2026-10-20")[0],
        "account 5claude config_dir=/home/me/.5claude harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z word=reserve"
    );
}

/// Round 8 item 6 (A10 row (2)); step6-map § B "an account renewed,
/// retired, reserved". Defect: a retirement date stopping every read of
/// the account, so a renewed, live account reads `retired` with no
/// figures and nothing shows the contradiction. A `retired <date>` account
/// is picked until the date; from the date on it is not picked, its row
/// keeps the figures the reader measured, and its credential still
/// answering is one `account-end-contradicted` line under the roster. The
/// reader is handed `ORCH_LANE_RETIRE` emptied, so it measures the
/// account: the setting is the judge's to apply.
#[test]
fn a_retired_account_is_picked_until_its_date_and_measured_after_it_with_the_contradiction_said() {
    let world = World::new(&[("ORCH_LANE_RETIRE", "4claude=2026-10-20,6claude=2026-10-21")]);
    // The row with the most room is 4claude, retired today; 6claude
    // retires tomorrow; 7claude never.
    let listing = [
        measured("4claude", 10, 5),
        measured("6claude", 30, 5),
        measured("7claude", 60, 5),
    ];
    world.plant_listing(&listing);
    world.write_fleet(Vec::new(), None);
    let req = PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    };
    let answer = world.pick(&req);
    assert_eq!(
        picked(&answer).as_deref(),
        Some("/home/me/.6claude"),
        "the account retiring tomorrow is picked, the one retired today is not: {answer:?}"
    );
    let log = world.log();
    assert_eq!(
        log,
        vec!["ORCH_LANE_HOST=unset ORCH_LANE_RETIRE=emptied list --json"],
        "the reader was asked to measure every account, the statement emptied"
    );
    let roster = accounts::roster(&world.settings, None).unwrap();
    let today = accounts::today(NOW);
    assert_eq!(today, "2026-10-20");
    assert_eq!(
        roster.rows[0].word(),
        Word::Retired {
            date: "2026-10-20".to_owned(),
            source: EndSource::Setting
        }
    );
    assert_eq!(
        roster.lines(&today),
        vec![
            "account 4claude config_dir=/home/me/.4claude harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z word=retired:2026-10-20",
            "account 6claude config_dir=/home/me/.6claude harness=claude through=local status=ok verdict=room headroom_pct=70 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z word=retired:2026-10-21",
            "account 7claude config_dir=/home/me/.7claude harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z",
            "account-end-contradicted 4claude config_dir=/home/me/.4claude ends=2026-10-20 source=ORCH_LANE_RETIRE status=ok",
        ]
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

/// Decision 99 (A10 row (3)). Defect: a listing that could not be read
/// taken as an empty fleet, so a pick answers `none` as if every account
/// were walled, or the roster reads as no accounts. A reader that exits
/// non-zero, or answers a shape that is no listing, is unjudged for the
/// pick and unread for the roster, each with the cause.
#[test]
fn an_unreadable_listing_admits_nothing() {
    let world = World::new(&[]);
    world.write_fleet(Vec::new(), None);
    let req = PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    };
    std::fs::write(world.path().join("lanes.rc"), "1\n").unwrap();
    let refused = world.pick(&req);
    assert!(
        matches!(&refused, PickAnswer::Unjudged { cause } if cause.starts_with("listing-unread host=local exit=1")),
        "{refused:?}"
    );
    assert!(accounts::roster(&world.settings, None).is_err());
    std::fs::remove_file(world.path().join("lanes.rc")).unwrap();
    std::fs::write(
        world.path().join("lanes.text"),
        "{\"not\": \"a listing\"}\n",
    )
    .unwrap();
    let unparsed = world.pick(&req);
    assert!(
        matches!(&unparsed, PickAnswer::Unjudged { cause } if cause == "listing-unread host=local parse=failed"),
        "{unparsed:?}"
    );
    assert_eq!(
        accounts::roster(&world.settings, None).unwrap_err(),
        "host=local parse=failed"
    );
    assert_eq!(refused.exit(), 1);
    assert_eq!(refused.reply()["answer"], json!("unjudged"));
}

/// Round 6 item 5, decision 141 (5) (A10 row (4); KEN-4416, KEN-4599).
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
        {"label": "Opus 5", "pct": 98, "resets_at": "2026-10-24T00:00:00Z"},
        {"label": "Sonnet 5.5", "pct": 10, "resets_at": "2026-10-24T00:00:00Z"}
    ]);
    let listing = [split, measured("bclaude", 50, 5)];
    let rows = rows(&listing, &world.settings);
    let facts = FleetFacts::default();
    let pick_for = |model: Option<&str>| {
        accounts::pick(
            &rows,
            &PickRequest {
                harness: "claude".to_owned(),
                model: model.map(str::to_owned),
                ..PickRequest::default()
            },
            &facts,
            &world.settings.accounts,
            NOW,
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

/// Decision 97; step6-map § A5 (A10 row (5)); round 8 item 3. Defect: a
/// relaunch replacing lane L on account A refused on L's own charge, or
/// the projection charging a legacy claim count instead of the lanes the
/// runtime proves live. The fleet's one running lane on A holds a live
/// launch identity (the row's own child); A's session window with one
/// charge projects past the bound, so a fresh launch is refused with A
/// walled; the same pick naming L as the lane it replaces leaves L's
/// charge out and A is the lane. A lane whose identity is gone charges
/// nothing.
#[test]
fn a_relaunch_replacing_a_lane_adds_no_lane_to_the_projection() {
    let world = World::new(&[]);
    // The session window at 93 percent, read this instant, five hours to
    // its reset: one live lane's session burn projects far past 95.
    world.plant_listing(&[measured("aclaude", 20, 93)]);
    let child = Owned::sleep();
    let lane = |item: &str, pid: u32, start: &str| {
        json!({
            "item": item, "window": format!("orch-{item}"), "harness": "claude", "status": "running",
            "account": "/home/me/.aclaude", "running_at": "2026-10-20T11:00:00Z",
            "launch": {"pid": pid, "start": start, "pane": "%1", "server": 1}
        })
    };
    world.write_fleet(vec![lane("KEN-1", child.pid(), &child.start())], None);
    let fresh = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert!(
        matches!(
            &fresh,
            PickAnswer::None {
                walled: 1,
                unmeasured: 0,
                ..
            }
        ),
        "the live lane's charge walls the account for a fresh launch: {fresh:?}"
    );
    let relaunch = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        replaces: Some("KEN-1".to_owned()),
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&relaunch).as_deref(),
        Some("/home/me/.aclaude"),
        "the replaced lane's charge is left out: {relaunch:?}"
    );
    let PickAnswer::Lane(judged) = &relaunch else {
        panic!("{relaunch:?}");
    };
    assert_eq!(judged.claims, 0);
    // A record whose identity is gone charges nothing, so a fresh launch
    // is admitted on it too.
    world.write_fleet(vec![lane("KEN-2", GONE_PID as u32, "1")], None);
    let gone = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&gone).as_deref(),
        Some("/home/me/.aclaude"),
        "{gone:?}"
    );
    drop(child);
}

/// `lanes --help` § pick's seat rule, the rows
/// `744fd5727:skills/orch/tests/lanes.sh` pinned under its seat table.
/// Defect: the overseer's own account spent by a worker lane past the
/// reserve, or an overseer's own pick refusing its seat on it. The fleet
/// record's `overseer.account` is a seat: returned last, and only while
/// its projected room exceeds `ORCH_OVERSEER_SEAT_RESERVE_PCT`
/// (`seat-reserve` otherwise); `for_overseer` judges it as any account.
#[test]
fn a_seat_is_returned_last_and_kept_above_its_reserve_unless_the_overseer_asks() {
    let world = World::new(&[("ORCH_OVERSEER_SEAT_RESERVE_PCT", "50")]);
    world.plant_listing(&[measured("seat", 10, 5), measured("worker", 60, 5)]);
    world.write_fleet(Vec::new(), Some("/home/me/.seat"));
    let worker = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&worker).as_deref(),
        Some("/home/me/.worker"),
        "{worker:?}"
    );
    world.plant_listing(&[measured("seat", 55, 5)]);
    let reserved = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert!(
        matches!(&reserved, PickAnswer::None { seats, .. } if seats.len() == 1),
        "{reserved:?}"
    );
    let overseer = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        for_overseer: true,
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&overseer).as_deref(),
        Some("/home/me/.seat"),
        "{overseer:?}"
    );
}

/// The delegation the port keeps (step6-map § A10 "kept for step 7 or 8"):
/// a pick under a provider and a pick on an API grant stay the legacy
/// reader's judgement of the windows, its answer read as the legacy
/// callers read it, with the statement left to the reader; the words are
/// read first from the roster with the host (the row below). Defect: a
/// hosted pick judged on the local rows alone, or the legacy's exit read
/// as a verdict it is not.
#[test]
fn a_hosted_or_grant_pick_is_the_legacy_readers_and_its_answer_is_read_by_exit() {
    let world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    world.plant_pick(0, measured("hosted", 30, 5));
    let hosted = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        model: Some("claude-opus-5".to_owned()),
        exclude: vec!["/home/me/.spent".to_owned()],
        for_overseer: true,
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&hosted).as_deref(),
        Some("/home/me/.hosted"),
        "{hosted:?}"
    );
    // The roster is read with the host and the statement emptied (the
    // words are this judge's); the statement is the legacy reader's to
    // apply on the delegated pick: left as the process had it (set or
    // unset), never emptied.
    let log = world.log();
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(
        log[0],
        "ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE=emptied list --json"
    );
    assert!(
        log[1].starts_with("ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE="),
        "{log:?}"
    );
    assert!(!log[1].contains("ORCH_LANE_RETIRE=emptied"), "{log:?}");
    assert!(
        log[1].ends_with(" pick --harness claude --native-model claude-opus-5 --exclude-lane /home/me/.spent --for-overseer --json"),
        "{log:?}"
    );
    world.plant_pick(
        3,
        json!({"walled": 2, "unmeasured": 1, "walled_resets_at": "2026-10-21T00:00:00Z", "exclusions": [{"config_dir": "/h/.a", "reason": "walled"}]}),
    );
    let none = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert!(
        matches!(&none, PickAnswer::None { walled: 2, unmeasured: 1, walled_resets_at: Some(at), .. } if at == "2026-10-21T00:00:00Z"),
        "{none:?}"
    );
    world.plant_pick(7, json!({}));
    let other = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert!(
        matches!(&other, PickAnswer::Unjudged { cause } if cause.starts_with("exit=7")),
        "{other:?}"
    );
    // The grant pool on a local read is delegated too.
    let local = World::new(&[]);
    local.write_fleet(Vec::new(), None);
    local.plant_pick(4, json!({}));
    let grant = local.pick(&PickRequest {
        harness: "pi".to_owned(),
        model: Some("anthropic/claude-opus-5".to_owned()),
        lane: Some("/home/me/.pi".to_owned()),
        ..PickRequest::default()
    });
    assert_eq!(grant, PickAnswer::NoRecord);
    let log = local.log();
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(
        log[0],
        "ORCH_LANE_HOST=unset ORCH_LANE_RETIRE=emptied list --json"
    );
    assert!(
        log[1].starts_with("ORCH_LANE_HOST=unset ORCH_LANE_RETIRE="),
        "{log:?}"
    );
    assert!(!log[1].contains("ORCH_LANE_RETIRE=emptied"), "{log:?}");
    assert!(
        log[1].ends_with(
            " pick --harness pi --native-model anthropic/claude-opus-5 --lane /home/me/.pi --json"
        ),
        "{log:?}"
    );
}

/// Decision 188 (b) (R-U6-2 M2; decision 187 (7)). Defect: the provider's
/// `reserved` word, carried on host rows alone, reaching no production
/// pick, because every pick under a provider is delegated to a reader
/// that judges none of the words, so a reserved account is picked on every
/// machine with a provider. On the delegated path the roster is read with
/// the host first: each account of the billed harness whose word refuses
/// it, reserved or retired from its day, is handed to the legacy reader as
/// one `--exclude-lane` beside the request's own (another harness's
/// reserved row is not); a `--lane` pick naming such an account is
/// answered by its word with the reader never asked; a roster that cannot
/// be read is unjudged with the cause, never a pick that ignores the word.
#[test]
fn a_delegated_pick_hands_the_legacy_reader_every_account_the_word_refuses() {
    let world = World::new(&[("ORCH_LANE_HOST", "fleet-vm")]);
    world.write_fleet(Vec::new(), None);
    let mut reserved = measured("r", 10, 5);
    reserved["reserved"] = json!("1");
    let mut ended = measured("t", 20, 5);
    ended["plan_ends"] = json!("2026-10-19");
    let mut ahead = measured("s", 25, 5);
    ahead["plan_ends"] = json!("2026-10-21");
    let mut other_harness = measured("c", 5, 5);
    other_harness["harness"] = json!("codex");
    other_harness["reserved"] = json!("1");
    world.plant_listing(&[reserved, ended, ahead, other_harness, measured("u", 60, 5)]);
    world.plant_pick(0, measured("u", 60, 5));
    let chosen = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        exclude: vec!["/home/me/.spent".to_owned()],
        ..PickRequest::default()
    });
    assert_eq!(
        picked(&chosen).as_deref(),
        Some("/home/me/.u"),
        "{chosen:?}"
    );
    let log = world.log();
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(
        log[0],
        "ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE=emptied list --json"
    );
    assert!(
        log[1].ends_with(" pick --harness claude --exclude-lane /home/me/.spent --exclude-lane /home/me/.r --exclude-lane /home/me/.t --json"),
        "the reserved and the ended account are the reader's exclusions, beside the caller's; the account retiring tomorrow and the other harness's row are not: {log:?}"
    );
    // A named account the word refuses is answered here, by its word, and
    // the reader is not asked.
    world.clear_log();
    let named = |dir: &str| {
        world.pick(&PickRequest {
            harness: "claude".to_owned(),
            lane: Some(dir.to_owned()),
            projected: true,
            ..PickRequest::default()
        })
    };
    let reserved = named("/home/me/.r");
    assert!(
        matches!(&reserved, PickAnswer::Reserved(j) if j.row.alias == "r"),
        "{reserved:?}"
    );
    let retired = named("/home/me/.t");
    assert!(
        matches!(&retired, PickAnswer::Retired { judged, ends, source: EndSource::Provider } if judged.row.alias == "t" && ends == "2026-10-19"),
        "{retired:?}"
    );
    let log = world.log();
    assert_eq!(
        log,
        vec!["ORCH_LANE_HOST=fleet-vm ORCH_LANE_RETIRE=emptied list --json"; 2],
        "two roster reads, no pick asked"
    );
    // A named account the word admits is the reader's, judged alone: no
    // exclusion travels with a `--lane` pick.
    world.clear_log();
    let open = named("/home/me/.u");
    assert_eq!(picked(&open).as_deref(), Some("/home/me/.u"), "{open:?}");
    let log = world.log();
    assert_eq!(log.len(), 2, "{log:?}");
    assert!(
        log[1].ends_with(" pick --harness claude --lane /home/me/.u --projected --json"),
        "{log:?}"
    );
    // The roster unread: nothing is asked and nothing is picked.
    world.clear_log();
    std::fs::write(world.path().join("lanes.rc"), "1\n").unwrap();
    let unread = world.pick(&PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    });
    assert!(
        matches!(&unread, PickAnswer::Unjudged { cause } if cause.starts_with("listing-unread host=fleet-vm exit=1")),
        "{unread:?}"
    );
    assert_eq!(world.log().len(), 1, "the reader was not asked to pick");
}

/// The `accounts pick` verb (decision 94 (b)): the reply a shell caller
/// reads carries the answer's word, `lanes pick`'s exit by number and the
/// record, so `open-terminal` reads the verdict it read before. Defect: a
/// refusal exit where a judgement is an answer, or the record missing the
/// fields the caller reads (`config_dir`, `projected_window`, `wall`,
/// `binding_bucket`, `projected_headroom_pct`).
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
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["ok"], json!(true));
    let result = &reply["result"];
    assert_eq!(result["answer"], json!("lane"));
    assert_eq!(result["exit"], json!(0));
    assert_eq!(result["record"]["config_dir"], json!("/home/me/.aclaude"));
    assert_eq!(result["record"]["binding_bucket"], json!("weekly"));
    assert_eq!(result["record"]["wall"], json!(20.0));
    assert_eq!(
        result["record"]["projected_window"]["bucket"],
        json!("weekly")
    );
    assert!(result["record"]["projected_headroom_pct"].is_number());
    assert_eq!(result["record"]["verdict"], json!("room"));
    // The named lane walled: exit 3 by number, the record under it.
    world.plant_listing(&[measured("aclaude", 96, 5)]);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["answer"], json!("walled"));
    assert_eq!(reply["result"]["exit"], json!(3));
    assert_eq!(reply["result"]["record"]["wall"], json!(96.0));
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

/// Decision 188 (b) (R-U6-2 L4). Defect: a named account the word refuses,
/// reserved or retired from its day, answered as `walled` with the wall's
/// figures, so the launcher refuses `lane-model-walled pct= bucket=` for
/// an account that has room, sending the operator to a usage wall that is
/// not there. The answer is the word's, at `lanes pick`'s exit 3 by
/// number (no caller learns a new number), its reply naming the word and
/// the record carrying `retired:<date>`; through the verb the same.
#[test]
fn a_named_reserved_or_retired_account_is_refused_by_its_word_not_the_walls_figures() {
    let world = World::new(&[("ORCH_LANE_RETIRE", "oclaude=2026-10-20")]);
    world.write_fleet(Vec::new(), None);
    let mut reserved = measured("rclaude", 10, 5);
    reserved["reserved"] = json!(1);
    world.plant_listing(&[reserved, measured("oclaude", 10, 5)]);
    let named = |dir: &str| {
        world.pick(&PickRequest {
            harness: "claude".to_owned(),
            model: Some("claude-sonnet-5-5".to_owned()),
            lane: Some(dir.to_owned()),
            projected: true,
            ..PickRequest::default()
        })
    };
    let reserved = named("/home/me/.rclaude");
    assert!(
        matches!(&reserved, PickAnswer::Reserved(j) if j.verdict == "reserved"),
        "{reserved:?}"
    );
    assert_eq!(reserved.exit(), 3);
    let reply = reserved.reply();
    assert_eq!(reply["answer"], json!("reserved"));
    assert_eq!(reply["record"]["word"], json!("reserve"));
    let retired = named("/home/me/.oclaude");
    assert!(
        matches!(&retired, PickAnswer::Retired { ends, source: EndSource::Setting, .. } if ends == "2026-10-20"),
        "{retired:?}"
    );
    assert_eq!(retired.exit(), 3);
    let reply = retired.reply();
    assert_eq!(reply["answer"], json!("retired"));
    assert_eq!(reply["record"]["word"], json!("retired:2026-10-20"));
    // The verb: the word, the exit by number, the record.
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
            "--lane",
            "/home/me/.rclaude",
            "--projected",
        ]);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["answer"], json!("reserved"));
    assert_eq!(reply["result"]["exit"], json!(3));
    assert_eq!(reply["result"]["record"]["verdict"], json!("reserved"));
}

/// Decision 188 (b) (R-U6-2 follow-up 3; decision 187 (9)). Defect: the
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
    let req = PickRequest {
        harness: "claude".to_owned(),
        ..PickRequest::default()
    };
    let answer = accounts::pick(
        &rows,
        &req,
        &FleetFacts::default(),
        &world.settings.accounts,
        NOW,
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
        NOW,
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
        NOW,
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
    assert_eq!(
        roster.lines("2026-10-20"),
        vec![
            "account v config_dir=/home/me/.v harness=claude through=local status=ok verdict=room headroom_pct=90 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z word=plan-end-invalid",
            "account w config_dir=/home/me/.w harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at=2026-10-23T00:00:00Z",
            "account-plan-end-invalid alias=v value=2026-10-21T00:00:00Z",
        ]
    );
}

/// The settings' refusals, as `lanes` refused them: a retirement naming
/// no lane or no calendar day, a percentage past 100.
#[test]
fn a_statement_nobody_can_read_is_refused_by_key_and_value() {
    for (key, value) in [
        ("ORCH_LANE_RETIRE", "4claude"),
        ("ORCH_LANE_RETIRE", "4claude=2026-02-30"),
        ("ORCH_LANE_RETIRE", "=2026-10-20"),
        ("ORCH_LANE_RETIRE", "a/b=2026-10-20"),
        ("ORCH_LANE_MAX_PCT", "101"),
        ("ORCH_OVERSEER_SEAT_RESERVE_PCT", "-1"),
        ("ORCH_LANE_BURN_PCT_PER_HOUR", "five"),
        ("ORCH_LANE_CODEX_CREDIT_FLOOR", "1.5"),
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
    ]);
    assert_eq!(world.settings.accounts.max_pct, 80);
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
}
