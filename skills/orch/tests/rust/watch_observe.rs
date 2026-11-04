//! The observation duty (decision 121 Q6, Q9-Q11; step5-map § A2, § A3;
//! decisions 99, 105, 125 (1), 130): the lane classifier over three-valued
//! reads of real panes on a private tmux server, the wall rule keyed to the
//! live identity, a Pi lane's rows, the overseer's one verdict shared with
//! the mail gate, the death counted on two passes and the succession asked
//! for through the one request, and the stray sweep. Each row names the
//! defect it catches at its doc comment. The rows drive the duties directly
//! with the readers the production duty injects, applying each pass's
//! changes to the baseline as the runner's commit would. U5d2's rows
//! (decision 160 (1)): the reset the banner names and `usage-limit-passed`,
//! the account wall record and the lane record's wall keyed to the
//! identity, the wall relaunch through the route, `lane-long`'s counters
//! and the mark line's payload. U7a's rows (step7-map § A1): the hosted
//! readings over the `lane-host`, `lane-close` and `gh` fixtures linked
//! into a row's world, the provider calls made by the production runner
//! from that world's scripts directory.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server, write the records they plant and read the panes they opened"
)]

#[path = "support.rs"]
mod support;

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, Pane, PaneFields};
use agent_runtime::observe::{self, ProcessReading};
use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, LaneVerdict};
use jiff::tz::TimeZone;
use orch_runtime::ops::accounts::Roster;
use orch_runtime::ops::wall::{self, AccountWall, RecordWallPauses};
use orch_runtime::ops::{self, RequestTransfer};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings, Succession};
use orch_runtime::state::{self, FleetState, Locking, Record, TransferCause};
use orch_runtime::watch::context;
use orch_runtime::watch::hosted;
use orch_runtime::watch::lanes::{self, Readers, Relaunch, WallRoute, WindowRow};
use orch_runtime::watch::overseer::{self, Legacy, Marks, Pick, Slot, Source, Verdict};
use orch_runtime::watch::{Baseline, Change, Event, Produced};
use serde_json::{Value, json};
use std::ffi::OsString;
use support::*;

/// The settings a duty in `dir` runs under; nothing is read from the
/// test's own tree.
fn settings_in(dir: &Path) -> Settings {
    settings_with(dir, &[])
}

/// [`settings_in`] with `extra` as the caller's environment.
fn settings_with(dir: &Path, extra: &[(&str, &str)]) -> Settings {
    let roots = Roots {
        project: dir.to_path_buf(),
        common: dir.to_path_buf(),
    };
    let environment: Vec<(OsString, OsString)> = extra
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(v)))
        .collect();
    settings::load(
        &roots,
        &environment,
        &SettingsFlags {
            state_dir: Some(dir.to_path_buf()),
            private_env: false,
        },
    )
    .unwrap()
}

/// The zone a banner's reset is read in: the named zone, or UTC for a
/// banner naming none, the suite's own runner zone.
fn zone(name: Option<&str>) -> Option<TimeZone> {
    match name {
        Some(name) => TimeZone::get(name).ok(),
        None => Some(TimeZone::UTC),
    }
}

/// The readers over the test's own server: the pane by exact id on it,
/// confirmed by pid, the one judge's foreground read, the capture, the
/// listing and the files, as the production readers read them on the
/// ambient server.
struct TestReaders {
    socket: PathBuf,
}

impl TestReaders {
    fn server(&self) -> Option<tmux::Server> {
        tmux::server(&self.socket).ok()
    }

    fn pane(&self, server: u64, start: Option<u64>, pane: &str) -> Reading<PaneFields> {
        let Some(live) = self.server() else {
            return Reading::Unreadable {
                cause: "server-unreachable",
            };
        };
        if u64::from(live.pid) != server {
            return Reading::Unreadable {
                cause: "server-unreachable",
            };
        }
        if start.is_some_and(|s| s != live.start) {
            return Reading::Unreadable {
                cause: "server-replaced",
            };
        }
        tmux::pane_fields(&live, pane)
    }

    fn windows(&self, session: &str) -> Reading<(u64, Vec<WindowRow>)> {
        let Some(live) = self.server() else {
            return Reading::Unreadable {
                cause: "server-unreachable",
            };
        };
        tmux::list_windows(&live, session).map(|rows| {
            (
                u64::from(live.pid),
                rows.into_iter()
                    .map(|(window, pane, name)| WindowRow { pane, window, name })
                    .collect(),
            )
        })
    }
}

fn foreground(
    pane_pid: u32,
    harness: Option<Harness>,
    recorded: Option<&Identity>,
) -> ProcessReading {
    let owns = |name: &str| harness.is_some_and(|h| h.owns_process(name));
    observe::foreground(pane_pid, &owns, recorded)
}

fn capture(pane: &Pane) -> Result<String, String> {
    tmux::capture(pane).map_err(|e| e.to_string())
}

fn status_file(path: &Path) -> Reading<()> {
    match std::fs::metadata(path) {
        Ok(_) => Reading::Live(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Reading::Gone,
        Err(_) => Reading::Unreadable {
            cause: "status-file-unreadable",
        },
    }
}

fn lane_rows(path: &Path) -> Reading<LaneVerdict> {
    rows::lane_verdict(path)
}

/// A copy of `sleep` named `name` under `dir`, so a pane holds a process the
/// kernel names as a harness; written by a child shell (support's reason).
fn named_sleep(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    let out = std::process::Command::new("sh")
        .args([
            "-c",
            "cp \"$(command -v sleep)\" \"$1\" && chmod 755 \"$1\"",
            "_",
        ])
        .arg(&path)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    path
}

/// The lane record of `item` whose window is `name`, launched in `pane` on
/// `server`, holding `identity` where the launch recorded one. Its status
/// file is written under the mail root, so the lane has started.
fn lane_record(
    item: &str,
    name: &str,
    harness: &str,
    server: &Server,
    pane: &str,
    identity: Option<&Identity>,
    mail_root: &Path,
) -> Value {
    let status = mail_root.join("tmp").join(format!("lane-status-{item}.md"));
    std::fs::create_dir_all(status.parent().unwrap()).unwrap();
    std::fs::write(&status, "Step: start\n").unwrap();
    let mut launch = json!({"pane": pane, "server": server.pid});
    if let Some(id) = identity {
        launch["pid"] = json!(id.pid);
        launch["start"] = json!(id.start);
    }
    json!({
        "item": item,
        "window": name,
        "harness": harness,
        "status": "running",
        "account": "/home/me/.eclaude",
        "mail_root": mail_root.display().to_string(),
        "running_at": "2026-01-01T00:00:00Z",
        "launch": launch,
    })
}

/// The fleet state as the duty reads it: the runner's own `init`, the
/// planted records written over it, read back through the store's reader.
struct Fleet {
    runner: Runner,
}

impl Fleet {
    fn new(server: &Server) -> Fleet {
        let runner = Runner::new(server, "stub-record");
        runner.init_fleet();
        Fleet { runner }
    }

    fn path(&self) -> PathBuf {
        self.runner.state_dir().join(state::FLEET_FILE_NAME)
    }

    fn set_lanes(&self, lanes: Vec<Value>) {
        let mut fleet = self.runner.fleet();
        fleet["lanes"] = Value::Array(lanes);
        self.runner.write_fleet(&fleet);
    }

    fn set_overseer(&self, overseer: Value) {
        let mut fleet = self.runner.fleet();
        fleet["overseer"] = overseer;
        self.runner.write_fleet(&fleet);
    }

    fn read(&self) -> FleetState {
        let path = self.path();
        let snapshot = state::load(&path).unwrap().expect("the fleet stands");
        FleetState::view(&path, &snapshot.doc).unwrap()
    }
}

/// The identity of the pane's process once its shell has exec'd `name`.
fn await_named(server: &Server, pane: &str, name: &str) -> Identity {
    let pid = server.pane_pid(pane);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if comm.trim() == name {
            return Identity {
                pid,
                start: start_of(pid),
            };
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the pane never exec'd {name}"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// Wait until the pane draws `needle`, bounded.
fn await_drawn(server: &Server, pane: &str, needle: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let cap = tmux(&server.socket, &["capture-pane", "-p", "-t", pane]);
        if String::from_utf8_lossy(&cap.stdout).contains(needle) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{needle:?} was never drawn"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

fn lines(produced: &Produced) -> Vec<String> {
    produced.events.iter().map(Event::render).collect()
}

fn event_lines(produced: &Produced) -> Vec<String> {
    lines(produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT "))
        .collect()
}

fn apply(baseline: &mut Baseline, produced: &Produced) {
    for change in &produced.changes {
        baseline.apply(change.clone());
    }
}

/// One lanes pass over `fleet` with the baseline as it stands, the changes
/// applied after, as the runner commits them; the wall route's pick is
/// planted, the relaunches it starts are recorded, and the lane walls
/// are written onto the fleet file through the wall transition.
struct LaneDriver<'a> {
    readers: Readers<'a>,
    settings: Settings,
    session: String,
    state_dir: PathBuf,
    fleet_path: PathBuf,
    baseline: Baseline,
    now: u64,
    pick: Pick,
    relaunches: RefCell<Vec<Relaunch>>,
    /// The scripts directory the provider calls run from: a row's world
    /// with the fixtures linked in, or nowhere for a local fleet.
    scripts: PathBuf,
    /// `gh` as the hosted reads run it: the fixture in a row's world.
    gh: PathBuf,
    /// The account roster a draft pull request's credit is read from;
    /// `None` is a roster that could not be read.
    roster: Option<Roster>,
    /// The fleet's repositories for a record naming none.
    repos: Vec<String>,
}

impl LaneDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let pick = |_: Harness, _: &str, _: &str| self.pick.clone();
        let start = |r: &Relaunch| {
            self.relaunches.borrow_mut().push(r.clone());
            Ok(())
        };
        let route = WallRoute {
            relaunch: self.settings.watch.wall_relaunch,
            pick: &pick,
            start: &start,
        };
        let roster = || {
            self.roster
                .clone()
                .ok_or_else(|| "host=local exit=1 roster-unread".to_owned())
        };
        let reads = hosted::Reads {
            gh: &self.gh,
            roster: &roster,
            repos: &self.repos,
        };
        let env = ops::Env {
            now_secs: self.now,
            now_nanos: u128::from(self.now) * 1_000_000_000,
            nonce: 1,
            owner: None,
        };
        let wall_pauses = |request: RecordWallPauses| {
            let request = ops::Request::RecordWallPauses(request);
            ops::apply(&self.fleet_path, &request, &env, Locking::FLOCK)
                .map(|_| ())
                .map_err(|e| e.to_string())
        };
        let produced = lanes::observe(&lanes::Pass {
            fleet,
            readers: &self.readers,
            baseline: &self.baseline,
            settings: &self.settings.watch,
            now: self.now,
            session: Some(&self.session),
            // The session's first window is the runner's own pane.
            own_panes: &["%0".to_owned()],
            state_dir: &self.state_dir,
            claim_store: &self.settings.claim_store,
            scripts: &self.scripts,
            route: &route,
            wall_pauses: &wall_pauses,
            hosted: &reads,
        });
        apply(&mut self.baseline, &produced);
        self.now += 240;
        produced
    }
}

macro_rules! lane_driver {
    ($server:expr, $fleet:expr, $readers:ident, $name:ident) => {
        lane_driver!($server, $fleet, $readers, $name, &[]);
    };
    ($server:expr, $fleet:expr, $readers:ident, $name:ident, $env:expr) => {
        let $readers = TestReaders {
            socket: $server.socket.clone(),
        };
        let pane_read = |s: u64, start: Option<u64>, p: &str| $readers.pane(s, start, p);
        let windows_read = |session: &str| $readers.windows(session);
        let mut $name = LaneDriver {
            readers: Readers {
                pane: &pane_read,
                foreground: &foreground,
                capture: &capture,
                start_epoch: &observe::start_epoch,
                rows: &lane_rows,
                status_file: &status_file,
                windows: &windows_read,
                receipts: &lanes::receipts_in,
                zone: &zone,
            },
            settings: settings_with($fleet.runner.state_dir(), $env),
            session: $server.session.clone(),
            state_dir: $fleet.runner.state_dir().to_path_buf(),
            fleet_path: $fleet.path(),
            baseline: Baseline::default(),
            now: 1_800_000_000,
            pick: Pick::None,
            relaunches: RefCell::new(Vec::new()),
            scripts: PathBuf::from("/nonexistent"),
            gh: PathBuf::from("/nonexistent/gh"),
            roster: None,
            repos: Vec::new(),
        };
    };
}

/// Defect: a window the server no longer has read as anything but gone, or
/// gone read once and then forgotten. A lane whose recorded pane the server
/// has not is `window-gone` on every pass, by its window name, and leaves
/// no row behind.
#[test]
fn a_recorded_pane_the_server_has_not_is_window_gone_on_every_pass() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    fleet.set_lanes(vec![lane_record(
        "KEN-1",
        "gh-1",
        "claude",
        &server,
        "%999",
        None,
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    for _ in 0..2 {
        let produced = driver.pass(&state);
        assert_eq!(event_lines(&produced), vec!["EVENT window-gone gh-1"]);
    }
    assert!(
        driver
            .baseline
            .rows
            .iter()
            .all(|r| r.kind == "start-stalled"),
        "a gone window leaves no observation row: {:?}",
        driver.baseline.rows
    );
}

/// Defect: a lane's finished shell reported on the first pass a live
/// harness could hold it in the foreground for, or reported again on every
/// pass after. A pane holding nothing but shells is `lane-exited` on the
/// second consecutive pass alone, with its closing lines under it, and a
/// third pass says nothing. Decision 99: a pane this reader cannot read is
/// never that, whatever passes go by: its own line once, with the cause.
#[test]
fn a_lane_exits_on_the_second_pass_and_an_unreadable_one_never_does() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    let mut unreadable = lane_record("KEN-3", "gh-3", "claude", &server, &pane, None, dir.path());
    unreadable["launch"]["server"] = json!(server.pid + 1);
    fleet.set_lanes(vec![
        lane_record("KEN-2", "gh-2", "claude", &server, &pane, None, dir.path()),
        unreadable,
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec!["EVENT lane-unreadable gh-3 cause=server-unreachable"],
        "{:?}",
        lines(&first)
    );
    assert_eq!(
        driver.baseline.get("lane-exited", "gh-2"),
        Some(format!("{} {pane}", server.pid).as_str())
    );
    let second = driver.pass(&state);
    assert_eq!(
        event_lines(&second),
        vec!["EVENT lane-exited gh-2"],
        "{:?}",
        lines(&second)
    );
    assert_eq!(
        driver.baseline.get("lane-exited", "gh-2"),
        Some(format!("{} {pane}|reported", server.pid).as_str())
    );
    let third = driver.pass(&state);
    assert!(event_lines(&third).is_empty(), "{:?}", lines(&third));
    assert!(
        !driver
            .baseline
            .rows
            .iter()
            .any(|r| r.identity == "gh-3" && r.kind == "lane-exited"),
        "the unreadable lane holds no exit row: {:?}",
        driver.baseline.rows
    );
    assert_eq!(
        driver.baseline.get("lane-unreadable", "gh-3"),
        Some("server-unreachable")
    );
}

/// The weekly banner Claude Code draws, its reset a dated clause ahead of
/// the rows' clock (1_800_000_000, 2027-01-15), so the wall stands.
const BANNER: &str = "  ⎿ \u{a0}You've hit your weekly limit · resets Oct 4, 2027, 6pm (UTC)";
/// The instant `BANNER` names.
const BANNER_RESET: u64 = 1_822_672_800;

/// Open a window whose shell prints `banner` and Claude's composer, then
/// execs a process the kernel names `claude`; the lane's identity.
fn walled_claude(server: &Server, dir: &Path, name: &str, banner: &str) -> (String, Identity) {
    let claude = named_sleep(dir, "claude");
    let screen = dir.join(format!("{name}-screen.txt"));
    std::fs::write(
        &screen,
        format!(
            "⏺ Working through the queue.\n{banner}\nRun /usage-credits to raise it\n❯\u{a0}\n"
        ),
    )
    .unwrap();
    let line = format!("cat {}; exec {} 600", screen.display(), claude.display());
    let pane = server.open_window(name, dir, &format!("bash -c \"{line}\""));
    let identity = await_named(server, &pane, "claude");
    await_drawn(server, &pane, "weekly limit");
    (pane, identity)
}

/// Decisions 125 (1), 130. Defect: a wall screen reported on every pass, or
/// a banner an earlier process drew in the pane promoted to the live
/// process's wall. The banner below the live composer, with the recorded
/// identity holding the pane, is `usage-limit` once with the account and
/// the banner window under it, its row keyed to the identity; a row whose
/// first sighting predates the live process's start reports nothing, on
/// every pass, while the screen stands.
#[test]
fn a_usage_limit_screen_is_reported_once_and_an_older_screen_is_not_a_wall() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    fleet.set_lanes(vec![lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            "EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z".to_owned(),
            "⏺ Working through the queue.".to_owned(),
            BANNER.to_owned(),
            "Run /usage-credits to raise it".to_owned(),
            "❯\u{a0}".to_owned(),
        ]
    );
    let row = driver
        .baseline
        .get("usage-limit", "gh-4")
        .unwrap()
        .to_owned();
    let fields: Vec<&str> = row.split('|').collect();
    assert_eq!(fields[2], format!("{}:{}", identity.pid, identity.start));
    assert_eq!(fields[3], "usage-limit");
    let second = driver.pass(&state);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
    // The same banner first seen before this process started: an earlier
    // process's screen, judged under its identity.
    let Reading::Live(started) = observe::start_epoch(&identity) else {
        panic!("the live identity's start reads")
    };
    driver.baseline.apply(Change::Set {
        kind: "usage-limit".into(),
        identity: "gh-4".into(),
        value: format!("{}|{}|1:ticks:1|usage-limit", started - 100, fields[1]),
    });
    for _ in 0..2 {
        let older = driver.pass(&state);
        assert!(
            lines(&older).is_empty(),
            "an older screen is no wall: {:?}",
            lines(&older)
        );
        let kept = driver.baseline.get("usage-limit", "gh-4").unwrap();
        assert!(kept.starts_with(&format!("{}|", started - 100)), "{kept}");
    }
}

/// The account wall record `lanes` reads for the rows' spent account
/// (`lib/account-wall.sh`, `account_wall_record`): `walls/<cksum>.json`
/// beside the claim store, or none.
fn wall_record(settings: &Settings) -> Option<AccountWall> {
    let path = wall::account_wall_path(&settings.claim_store, "/home/me/.eclaude");
    let text = std::fs::read_to_string(path).ok()?;
    Some(serde_json::from_str(&text).unwrap())
}

/// The clock the rows start at, as the fleet record writes a time.
const NOW_ISO: &str = "2027-01-15T08:00:00Z";

/// Decisions 125 (1), 130; `oversee-watch:3393` (`wall_pause`). Defect: the
/// account wall recorded, or the lane record's wall opened, for a banner an
/// earlier process drew: a record keyed by the pane alone. The wall judged
/// current for the live identity writes the account record with the reset
/// the banner names and opens `walled.at` on the lane record at the first
/// sighting; the same banner re-stamped before the live process's start,
/// under another identity, writes no record on two passes and closes the
/// standing wall into `pauses`.
#[test]
fn the_account_wall_and_the_lane_wall_are_recorded_for_the_live_identity_alone() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    fleet.set_lanes(vec![lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec!["EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z"]
    );
    assert_eq!(
        wall_record(&driver.settings),
        Some(AccountWall {
            config_dir: "/home/me/.eclaude".to_owned(),
            resets_at: BANNER_RESET,
        })
    );
    let opened = fleet.runner.fleet();
    assert_eq!(opened["lanes"][0]["walled"], json!({"at": NOW_ISO}));
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    assert_eq!(
        fleet.runner.fleet()["lanes"][0]["walled"],
        json!({"at": NOW_ISO}),
        "the standing wall is kept while the banner stands"
    );
    // The same banner first seen before this process started: an earlier
    // process's screen, judged under its identity.
    std::fs::remove_file(wall::account_wall_path(
        &driver.settings.claim_store,
        "/home/me/.eclaude",
    ))
    .unwrap();
    let Reading::Live(started) = observe::start_epoch(&identity) else {
        panic!("the live identity's start reads")
    };
    let row = driver
        .baseline
        .get("usage-limit", "gh-4")
        .unwrap()
        .to_owned();
    let fields: Vec<&str> = row.split('|').collect();
    driver.baseline.apply(Change::Set {
        kind: "usage-limit".into(),
        identity: "gh-4".into(),
        value: format!("{}|{}|1:ticks:1|usage-limit", started - 100, fields[1]),
    });
    for _ in 0..2 {
        let older = driver.pass(&state);
        assert_eq!(
            wall_record(&driver.settings),
            None,
            "the record is written for the live identity alone: {:?}",
            lines(&older)
        );
    }
    let closed = fleet.runner.fleet();
    assert_eq!(closed["lanes"][0].get("walled"), None, "{closed}");
    assert_eq!(
        closed["lanes"][0]["pauses"],
        json!([{"from": NOW_ISO, "to": "2027-01-15T08:08:00Z", "cause": "walled"}])
    );
}

/// `oversee-watch:4885-4906`; `744fd5727:skills/orch/tests/oversee_watch_usage_limit.sh` § SURFACE 2.
/// Defect: a wall whose reset has gone by still reported as standing, or
/// `usage-limit-passed` reported on every pass after it. The reset is pinned
/// to the first sighting; once the clock passes it the lane is
/// `usage-limit-passed` once more, with the banner window under it, and no
/// account record is renewed for a reset behind the clock.
#[test]
fn a_reset_behind_the_clock_is_usage_limit_passed_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    fleet.set_lanes(vec![lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec!["EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z"]
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    std::fs::remove_file(wall::account_wall_path(
        &driver.settings.claim_store,
        "/home/me/.eclaude",
    ))
    .unwrap();
    driver.now = BANNER_RESET + 60;
    let passed = driver.pass(&state);
    assert_eq!(
        lines(&passed),
        vec![
            "EVENT usage-limit-passed gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z"
                .to_owned(),
            "⏺ Working through the queue.".to_owned(),
            BANNER.to_owned(),
            "Run /usage-credits to raise it".to_owned(),
            "❯\u{a0}".to_owned(),
        ]
    );
    let row = driver.baseline.get("usage-limit", "gh-4").unwrap();
    assert_eq!(row.split('|').nth(3), Some("usage-limit-passed"), "{row}");
    assert_eq!(
        wall_record(&driver.settings),
        None,
        "a reset behind the clock is no wall to record"
    );
    let again = driver.pass(&state);
    assert!(lines(&again).is_empty(), "{:?}", lines(&again));
}

/// A lane record carrying what the relaunch needs: the model the pick is
/// asked for and the checkout, session and refresh word an earlier
/// launcher recorded under `recovery`.
fn relaunchable(mut record: Value, cwd: &Path) -> Value {
    record["model"] = json!("opus");
    record["recovery"] = json!({
        "cwd": cwd.display().to_string(),
        "flags": "--model opus",
        "refresh": true,
        "session": "fleet",
    });
    record
}

/// Decision 121 Q10; `oversee-watch:4694` (`wall_route`), the rows
/// `744fd5727:skills/orch/tests/oversee_watch_wall_relaunch.sh` pins. Defect: the relaunch
/// started on every pass the wall stands, started under `ask`, or started
/// with no pick. Under `auto` (the default, `oversee-watch:659`) a walled
/// lane whose record names its model is relaunched once onto the picked
/// account through the route: the marker for the legacy outcome reader
/// first, the record's own launcher line with `--lane` the picked account,
/// `lane-relaunched` with its log, and nothing on the next pass; under
/// `ask` the wall is `usage-limit` with the pick's answer under it and
/// nothing starts.
#[test]
fn a_walled_lane_is_relaunched_once_under_auto_and_only_reported_under_ask() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    fleet.set_lanes(vec![relaunchable(
        lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    let log = driver.state_dir.join("wall-relaunch-KEN-4.log");
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            "EVENT lane-relaunched KEN-4 lane=/home/me/.bclaude from=/home/me/.eclaude".to_owned(),
            format!("log={}", log.display()),
        ]
    );
    {
        let started = driver.relaunches.borrow();
        assert_eq!(started.len(), 1);
        let relaunch = &started[0];
        assert_eq!(relaunch.item, "KEN-4");
        assert_eq!(relaunch.window, "gh-4");
        assert_eq!(relaunch.to, "/home/me/.bclaude");
        assert_eq!(relaunch.spent, "/home/me/.eclaude");
        assert_eq!(relaunch.cwd, dir.path().canonicalize().unwrap());
        assert_eq!(relaunch.session, "fleet");
        assert_eq!(relaunch.log, log);
        // The relaunch is the runtime's own request, applied by its entry
        // with no launcher script between: the record's harness and model,
        // the picked account, the spent one excluded, the refresh word.
        let request_file = driver.state_dir.join("wall-relaunch-KEN-4.json");
        assert_eq!(
            relaunch.args,
            vec![
                "/nonexistent/orch-runtime".to_owned(),
                "--state-dir".to_owned(),
                driver.state_dir.display().to_string(),
                "op".to_owned(),
                "--fleet".to_owned(),
                "--request".to_owned(),
                request_file.display().to_string(),
            ]
        );
        let request: Value =
            serde_json::from_str(&std::fs::read_to_string(&request_file).unwrap()).unwrap();
        assert_eq!(
            request,
            json!({
                "op": "launch-lane",
                "item": "KEN-4",
                "harness": "claude",
                "mail_root": dir.path().canonicalize().unwrap().display().to_string(),
                "account": "/home/me/.bclaude",
                "exclude_account": "/home/me/.eclaude",
                "refresh": true,
                "model": "opus",
            })
        );
        assert_eq!(
            relaunch.marker,
            driver
                .settings
                .claim_store
                .parent()
                .unwrap()
                .join("wall-relaunch.gh-4")
        );
        let marker: Value =
            serde_json::from_str(&std::fs::read_to_string(&relaunch.marker).unwrap()).unwrap();
        assert_eq!(
            marker,
            json!({"item": "KEN-4", "since": 1_800_000_000_u64, "log": log.display().to_string()})
        );
    }
    let row = driver.baseline.get("usage-limit", "gh-4").unwrap();
    assert_eq!(row.split('|').nth(3), Some("lane-relaunched"), "{row}");
    let second = driver.pass(&state);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
    assert_eq!(driver.relaunches.borrow().len(), 1, "one relaunch per wall");
    // Under `ask` the same wall is reported with the pick's answer.
    lane_driver!(
        server,
        fleet,
        readers2,
        asked,
        &[("ORCH_WALL_RELAUNCH", "ask")]
    );
    asked.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    let reported = asked.pass(&state);
    assert_eq!(
        lines(&reported),
        vec![
            "EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z".to_owned(),
            "pick lane=/home/me/.bclaude".to_owned(),
            "⏺ Working through the queue.".to_owned(),
            BANNER.to_owned(),
            "Run /usage-credits to raise it".to_owned(),
            "❯\u{a0}".to_owned(),
        ]
    );
    assert!(
        asked.relaunches.borrow().is_empty(),
        "nothing starts under ask"
    );
}

/// The item state `744fd5727:skills/orch/tests/oversee_watch_start_stall.sh` plants for its
/// `separate_counts` row.
const COUNTS_STATE: &str = r#"{"first_panel":{},"rereview_cycles":1,"cycles":7,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"implement"},{"kind":"fix"},{"kind":"fix"},{"kind":"fix"},{"kind":"review"}],"validate_rounds":[{"kind":"implement"},{"kind":"fix"},{"kind":"restack"},{"kind":"restack"}],"restack_skips":[{},{}],"restacks":4}"#;

/// `lib/watch-host-kinds.sh:446` (`check_lane_long`), the rows
/// `744fd5727:skills/orch/tests/oversee_watch_start_stall.sh` pins (`separate_counts`, `parked`,
/// the age intervals). Defect: a long lane reported on every pass, or its
/// counts read from anywhere but the lane's own records. A running lane
/// `ORCH_WATCH_LANE_AGE_SECS` past its launch is `lane-long` once per age
/// interval with the counts of its worktree's workflow state and run index
/// and the `Step` line of its status file; a parked lane reads every count
/// `unread` and `stage=parked`.
#[test]
fn a_long_lane_is_reported_once_per_age_interval_with_its_records_counts() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let launched: u64 = 1_800_000_000 - 12_601;
    let mut running = lane_record("KEN-9", "gh-9", "claude", &server, "%999", None, dir.path());
    running["launched_at"] = json!("2027-01-15T04:29:59Z");
    let tmp = dir.path().join("tmp");
    std::fs::write(
        tmp.join("lane-status-KEN-9.md"),
        "# Lane status\n- Step: dev round 1\n",
    )
    .unwrap();
    std::fs::write(tmp.join("workflow-state-KEN-9.json"), COUNTS_STATE).unwrap();
    std::fs::write(
        tmp.join("validation-runs"),
        "dev-validate-runs-v1\ndev-validate-implement\ndev-validate-fix\ndev-validate-restack-a\ndev-validate-restack-b\n",
    )
    .unwrap();
    let parked_root = dir.path().join("parked");
    let mut parked = lane_record(
        "KEN-10",
        "gh-10",
        "claude",
        &server,
        "%998",
        None,
        &parked_root,
    );
    parked["status"] = json!("parked");
    parked["launched_at"] = json!("2027-01-15T04:29:59Z");
    fleet.set_lanes(vec![running, parked]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let long = |produced: &Produced| -> Vec<String> {
        event_lines(produced)
            .into_iter()
            .filter(|l| l.starts_with("EVENT lane-long "))
            .collect()
    };
    let first = driver.pass(&state);
    assert_eq!(
        long(&first),
        vec![
            "EVENT lane-long KEN-9 age=12601 review_rounds=5 fix_receipts=3 validation_runs=4 restacks=4 repeated_class_rounds=1 stage=dev round 1",
            "EVENT lane-long KEN-10 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked",
        ]
    );
    assert_eq!(
        driver.baseline.get("lane-long", "KEN-9"),
        Some(format!("{launched}|1").as_str())
    );
    let second = driver.pass(&state);
    assert!(long(&second).is_empty(), "{:?}", lines(&second));
    driver.now = launched + 25_200;
    let third = driver.pass(&state);
    assert_eq!(
        long(&third),
        vec![
            "EVENT lane-long KEN-9 age=25200 review_rounds=5 fix_receipts=3 validation_runs=4 restacks=4 repeated_class_rounds=1 stage=dev round 1",
            "EVENT lane-long KEN-10 age=25200 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked",
        ]
    );
    assert_eq!(
        driver.baseline.get("lane-long", "KEN-9"),
        Some(format!("{launched}|2").as_str())
    );
}

/// Decision 121 Q6. Defect: Codex's capacity refusal reported as a finished
/// turn, or on every pass. The refusal above the live composer is
/// `model-capacity` once, with no tail, and the next pass says nothing.
#[test]
fn a_codex_capacity_refusal_is_model_capacity_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let codex = named_sleep(dir.path(), "codex");
    let fixture = fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("fixtures/oversee-watch/codex-model-capacity.txt");
    let line = format!("cat {}; exec {} 600", fixture.display(), codex.display());
    let pane = server.open_window("gh-6", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &pane, "codex");
    await_drawn(&server, &pane, "at capacity");
    fleet.set_lanes(vec![lane_record(
        "KEN-6",
        "gh-6",
        "codex",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert_eq!(lines(&first), vec!["EVENT model-capacity gh-6"]);
    let second = driver.pass(&state);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
}

/// Defect: a Pi lane judged off its pane, which its carrier's drawing
/// cannot settle, or its rows read in a way the legacy did not, or the
/// harness's ordinary end (`stop_reason=stop`, what the writer copies
/// from every finished Pi turn) rendered as a `cause=` on the line. The
/// rows judge: a Stop row is idle on the second pass with the pane's tail
/// under it, the line as today; a later Stop row is news again; an error
/// Stop whose message is the account's limit is `usage-limit` with the
/// harness's own message under it; no rows at all settles nothing.
#[test]
fn a_pi_lane_is_judged_from_its_rows_as_the_legacy_judged_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pi = named_sleep(dir.path(), "pi");
    let line = format!("printf 'pi drew this\\n'; exec {} 600", pi.display());
    let pane = server.open_window("gh-5", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &pane, "pi");
    await_drawn(&server, &pane, "pi drew this");
    fleet.set_lanes(vec![lane_record(
        "KEN-5",
        "gh-5",
        "pi",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    let rows_file = dir.path().join("tmp/lane-mail/KEN-5/session-rows.jsonl");
    std::fs::create_dir_all(rows_file.parent().unwrap()).unwrap();
    lane_driver!(server, fleet, readers, driver);
    let none = driver.pass(&state);
    assert!(
        lines(&none).is_empty(),
        "no rows settles nothing: {:?}",
        lines(&none)
    );
    std::fs::write(
        &rows_file,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"stop\",\"working_agents\":0,\"at\":1}\n",
    )
    .unwrap();
    let first = driver.pass(&state);
    assert!(lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![
            "EVENT idle-after-return gh-5".to_owned(),
            "pi drew this".to_owned()
        ]
    );
    let third = driver.pass(&state);
    assert!(lines(&third).is_empty(), "{:?}", lines(&third));
    std::fs::write(
        &rows_file,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"stop\",\"working_agents\":0,\"at\":2}\n",
    )
    .unwrap();
    driver.pass(&state);
    let again = driver.pass(&state);
    assert_eq!(event_lines(&again), vec!["EVENT idle-after-return gh-5"]);
    std::fs::write(
        &rows_file,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"error\",\"message\":\"429 Usage limit reached for this model\",\"at\":3}\n",
    )
    .unwrap();
    let walled = driver.pass(&state);
    assert_eq!(
        lines(&walled),
        vec![
            "EVENT usage-limit gh-5 /home/me/.eclaude".to_owned(),
            "429 Usage limit reached for this model".to_owned()
        ]
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
}

/// Decisions 174 (round 9, item 6), 184 (7). Defect: the idle line
/// dropping the stop reason the lane's own Stop row carries, so a turn the
/// output limit cut (`stop_reason=length`) reads as a finished round and
/// the lane as free. A Stop row with a `stop_reason` that is not the
/// harness's ordinary end and no limit banner is
/// `idle-after-return <lane> cause=<word>` once, with the pane's tail under
/// it; an error that is no limit carries `cause=error`. The row with the
/// ordinary end `stop`, the line as today, is
/// `a_pi_lane_is_judged_from_its_rows_as_the_legacy_judged_it`.
#[test]
fn a_pi_lane_s_stop_reason_is_the_idle_line_s_cause() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pi = named_sleep(dir.path(), "pi");
    let line = format!("printf 'cut mid-report\\n'; exec {} 600", pi.display());
    let pane = server.open_window("gh-7", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &pane, "pi");
    await_drawn(&server, &pane, "cut mid-report");
    fleet.set_lanes(vec![lane_record(
        "KEN-7",
        "gh-7",
        "pi",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    let rows_file = dir.path().join("tmp/lane-mail/KEN-7/session-rows.jsonl");
    std::fs::create_dir_all(rows_file.parent().unwrap()).unwrap();
    std::fs::write(
        &rows_file,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"length\",\"working_agents\":0,\"at\":1}\n",
    )
    .unwrap();
    lane_driver!(server, fleet, readers, driver);
    let first = driver.pass(&state);
    assert!(lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![
            "EVENT idle-after-return gh-7 cause=length".to_owned(),
            "cut mid-report".to_owned()
        ]
    );
    let third = driver.pass(&state);
    assert!(lines(&third).is_empty(), "{:?}", lines(&third));
    std::fs::write(
        &rows_file,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"error\",\"message\":\"tool failed\",\"at\":2}\n",
    )
    .unwrap();
    driver.pass(&state);
    let again = driver.pass(&state);
    assert_eq!(
        event_lines(&again),
        vec!["EVENT idle-after-return gh-7 cause=error"]
    );
}

/// Decisions 96, 121 Q11. Defect: a window nothing records adopted, closed,
/// or reported on every pass. A window of the fleet session that no lane,
/// controller record, open intent or receipt names is `stray-window` once;
/// it stands after, and a recorded window is never one.
#[test]
fn a_window_nothing_records_is_a_stray_reported_once_and_never_closed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let recorded = server.open_window("gh-7", dir.path(), "bash --norc --noprofile");
    let stray = server.open_window("stray", dir.path(), "bash --norc --noprofile");
    fleet.set_lanes(vec![lane_record(
        "KEN-7",
        "gh-7",
        "claude",
        &server,
        &recorded,
        None,
        dir.path(),
    )]);
    let receipts = fleet.runner.state_dir().join("intents");
    std::fs::create_dir_all(&receipts).unwrap();
    let receipted = server.open_window("opening", dir.path(), "bash --norc --noprofile");
    std::fs::write(
        receipts.join("launch-lane:KEN-8:1-1.pane"),
        format!("{receipted} 4242\n"),
    )
    .unwrap();
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let Reading::Live(stray_fields) =
        tmux::pane_fields(&tmux::server(&server.socket).unwrap(), &stray)
    else {
        panic!("the stray pane reads")
    };
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec![format!(
            "EVENT stray-window {stray} window={} server={} name=stray",
            stray_fields.pane.window, server.pid
        )]
    );
    let second = driver.pass(&state);
    assert!(
        !event_lines(&second)
            .iter()
            .any(|l| l.starts_with("EVENT stray-window")),
        "{:?}",
        lines(&second)
    );
    assert!(server.panes().contains(&stray), "the stray stands");
    assert!(server.panes().contains(&receipted));
}

/// The overseer duty's driver: the pass over the fleet with planted legacy
/// answers and a recording transfer.
struct OverseerDriver<'a> {
    readers: Readers<'a>,
    legacy: Legacy<'a>,
    settings: Settings,
    baseline: Baseline,
    slot: Slot,
    now: u64,
    transfers: &'a RefCell<Vec<RequestTransfer>>,
    /// The overseer's context record, where a row plants one.
    context_record: Option<PathBuf>,
    /// The owner's alert for a standing gap.
    alert: &'a dyn Fn(&str) -> Result<(), String>,
}

impl OverseerDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let transfer = |request: RequestTransfer| {
            self.transfers.borrow_mut().push(request);
            Ok(())
        };
        let produced = overseer::observe(
            &overseer::Pass {
                fleet,
                readers: &self.readers,
                legacy: &self.legacy,
                baseline: &self.baseline,
                settings: &self.settings.watch,
                succession: Succession::On,
                preference: &self.settings.overseer_preference,
                now: self.now,
                transfer: &transfer,
                context_record: self.context_record.as_deref(),
                alert: self.alert,
            },
            &self.slot,
        );
        apply(&mut self.baseline, &produced);
        self.now += 240;
        produced
    }
}

fn below(_: &Path, _: Option<Harness>, _: Option<&str>) -> Result<Marks, String> {
    Marks::parse("oversee-succeed: account-below-mark kind=headroom").ok_or_default()
}

fn no_alert(_: &str) -> Result<(), String> {
    panic!("no gap stood two passes")
}

trait OrDefault<T> {
    fn ok_or_default(self) -> Result<T, String>;
}

impl<T> OrDefault<T> for Option<T> {
    fn ok_or_default(self) -> Result<T, String> {
        self.ok_or_else(|| "unparsed".to_owned())
    }
}

fn reached(_: &Path, _: Option<Harness>, _: Option<&str>) -> Result<Marks, String> {
    Marks::parse("oversee-succeed: mark-reached kind=headroom value=50 mark=5 succession=on account=/home/me/.eclaude").ok_or_default()
}

fn pick_b(_: &Path, _: Harness, _: &str) -> Pick {
    Pick::Lane("/home/me/.bclaude".to_owned())
}

fn no_pick(_: &Path, _: Harness, _: &str) -> Pick {
    panic!("the account walk is asked only for a walled succession")
}

fn no_wall_pick(_: &Path, _: Harness, _: &str, _: &str) -> Pick {
    panic!("the wall route's pick is the lanes pass's, never the overseer's")
}

fn no_relaunch(_: &Path, _: &Relaunch) -> Result<(), String> {
    panic!("the wall relaunch is the lanes pass's, never the overseer's")
}

/// A standing mark with succession off (`oversee-watch:4062`).
fn reached_off(_: &Path, _: Option<Harness>, _: Option<&str>) -> Result<Marks, String> {
    Marks::parse("oversee-succeed: mark-reached kind=headroom value=50 mark=5 succession=off account=/home/me/.eclaude").ok_or_default()
}

macro_rules! overseer_driver {
    ($server:expr, $fleet:expr, $marks:expr, $pick:expr, $readers:ident, $transfers:ident, $name:ident) => {
        let $readers = TestReaders {
            socket: $server.socket.clone(),
        };
        let pane_read = |s: u64, start: Option<u64>, p: &str| $readers.pane(s, start, p);
        let windows_read = |session: &str| $readers.windows(session);
        let $transfers = RefCell::new(Vec::new());
        let mut $name = OverseerDriver {
            readers: Readers {
                pane: &pane_read,
                foreground: &foreground,
                capture: &capture,
                start_epoch: &observe::start_epoch,
                rows: &lane_rows,
                status_file: &status_file,
                windows: &windows_read,
                receipts: &lanes::receipts_in,
                zone: &zone,
            },
            legacy: Legacy {
                scripts: PathBuf::from("/nonexistent"),
                marks: &$marks,
                pick: &$pick,
                wall_pick: &no_wall_pick,
                relaunch: &no_relaunch,
            },
            settings: settings_in($fleet.runner.state_dir()),
            baseline: Baseline::default(),
            slot: Slot::new(),
            now: 1_800_000_000,
            transfers: &$transfers,
            context_record: None,
            alert: &no_alert,
        };
    };
}

/// The controller record naming `pane` on the test's server.
fn overseer_at(server: &Server, pane: &str, window: &str, cwd: &Path) -> Value {
    json!({
        "runtime": "tmux",
        "generation": 3,
        "server": server.pid.to_string(),
        "server_start": server.start,
        "server_socket": server.socket.display().to_string(),
        "pane": pane,
        "window": window,
        "harness": "claude",
        "account": "/home/me/.eclaude",
        "home": "/home/me/.eclaude",
        "model": "opus",
        "cwd": cwd.display().to_string(),
        "launch_line": "cd /r && claude",
    })
}

fn window_of(server: &Server, pane: &str) -> String {
    let Reading::Live(fields) = tmux::pane_fields(&tmux::server(&server.socket).unwrap(), pane)
    else {
        panic!("the pane reads")
    };
    fields.pane.window
}

/// Decisions 77, 99, 121 Q10; step5-map § A3. Defect: a death relaunched on
/// one reading, counted on an unreadable read, or judged twice from two
/// readings by the mail gate and the long check. A pane holding nothing but
/// shells is dead on the second consecutive pass: the line goes out with
/// `source=process`, the record's transfer is asked for once on the next
/// run with `cause: dead` and the held line as the successor, and nothing
/// more is asked after. The one verdict of each pass is what the slot holds,
/// so the mail gate reads the same source and closes while it is down. An
/// unreadable pane counts nothing on any pass.
#[test]
fn a_dead_overseer_is_counted_on_two_passes_and_transferred_once_with_cause_dead() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("overseer", dir.path(), "bash --norc --noprofile");
    let window = window_of(&server, &pane);
    fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
    let state = fleet.read();
    overseer_driver!(server, fleet, below, no_pick, readers, transfers, driver);
    let key = format!("{} {pane}", server.pid);
    let first = driver.pass(&state);
    assert!(lines(&first).is_empty(), "{:?}", lines(&first));
    let judged = driver.slot.read().expect("a verdict is stored each pass");
    assert_eq!(
        judged.verdict,
        Verdict::Exited {
            source: Source::Process
        }
    );
    assert_eq!(driver.baseline.get("overseer-dead", &key), Some("1"));
    assert!(transfers.borrow().is_empty());
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=2 succession=on source=process"
        )]
    );
    assert_eq!(
        driver.baseline.get("overseer-dead", &key),
        Some("announced")
    );
    assert!(second.next_due.is_some(), "the request follows at once");
    assert!(
        transfers.borrow().is_empty(),
        "the line is on disk before anything moves"
    );
    let third = driver.pass(&state);
    assert!(lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(
        driver.baseline.get("overseer-dead", &key),
        Some("requested")
    );
    {
        let asked = transfers.borrow();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].cause, TransferCause::Dead);
        assert_eq!(asked[0].exclude_account, None);
        assert_eq!(
            asked[0].successor.launch_line.as_deref(),
            Some("cd /r && claude")
        );
        assert_eq!(asked[0].expected.pane, json!(pane));
        assert_eq!(asked[0].expected.generation, json!(3));
    }
    let fourth = driver.pass(&state);
    assert!(lines(&fourth).is_empty());
    assert_eq!(transfers.borrow().len(), 1, "one request per death");
    // An unreadable pane: the record names a server this is not.
    let mut moved = overseer_at(&server, &pane, &window, dir.path());
    moved["server"] = json!((server.pid + 1).to_string());
    fleet.set_overseer(moved);
    let unreadable = fleet.read();
    overseer_driver!(server, fleet, below, no_pick, readers2, transfers2, driver2);
    for _ in 0..3 {
        let produced = driver2.pass(&unreadable);
        assert!(lines(&produced).is_empty(), "{:?}", lines(&produced));
        assert_eq!(
            driver2.slot.read().unwrap().verdict,
            Verdict::Unreadable {
                cause: "server-unreachable".into()
            }
        );
    }
    assert!(
        driver2.baseline.rows.is_empty(),
        "nothing counted: {:?}",
        driver2.baseline.rows
    );
    assert!(transfers2.borrow().is_empty());
}

/// Decision 121 Q10. Defect: a wall the harness's own row states waited
/// out for a second pass, or succeeded onto the spent account. A rows wall
/// under a live harness is `overseer-walled` on its first pass with the
/// row's message under it, and the transfer asked for carries `cause:
/// walled`, the spent account to exclude and the successor on the account
/// the walk picked; the account judgement reading room lifts it instead.
#[test]
fn a_walled_overseer_is_transferred_with_cause_walled_and_the_spent_account_excluded() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let claude = named_sleep(dir.path(), "claude");
    let pane = server.open_window(
        "overseer",
        dir.path(),
        &format!(
            "bash -c \"printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; exec {} 600\"",
            claude.display()
        ),
    );
    let identity = await_named(&server, &pane, "claude");
    let window = window_of(&server, &pane);
    let rows_file = dir.path().join("session-rows.jsonl");
    std::fs::write(
        &rows_file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\",\"message\":\"You've hit your weekly limit · resets Oct 4\"}\n",
    )
    .unwrap();
    let mut record = overseer_at(&server, &pane, &window, dir.path());
    record["session_rows"] = json!(rows_file.display().to_string());
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    let state = fleet.read();
    overseer_driver!(server, fleet, reached, pick_b, readers, transfers, driver);
    let key = format!("{} {pane}", server.pid);
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            format!(
                "EVENT overseer-walled {pane} window={window} passes=1 succession=on source=rows"
            ),
            "You've hit your weekly limit · resets Oct 4".to_owned(),
        ]
    );
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    let second = driver.pass(&state);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
    {
        let asked = transfers.borrow();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].cause, TransferCause::Walled);
        assert_eq!(
            asked[0].exclude_account.as_deref(),
            Some("/home/me/.eclaude")
        );
        assert_eq!(
            asked[0].successor.account.as_deref(),
            Some("/home/me/.bclaude")
        );
        assert_eq!(
            asked[0].successor.home.as_deref(),
            Some("/home/me/.bclaude")
        );
    }
    // The same rows wall with the account judgement reading room: lifted.
    overseer_driver!(server, fleet, below, no_pick, readers2, transfers2, lifted);
    let produced = lifted.pass(&state);
    assert!(lines(&produced).is_empty(), "{:?}", lines(&produced));
    assert_eq!(lifted.slot.read().unwrap().verdict, Verdict::Live);
    assert!(transfers2.borrow().is_empty());
}

/// `oversee-watch:4062-4067` (`overseer_mark_check`), the bytes
/// `744fd5727:skills/orch/tests/oversee_watch_overseer_marks.sh` pins. Defect: the mark line out
/// with no handling under it, or a handling naming a preference the walk
/// does not read. The first crossing of a headroom mark on a live overseer
/// carries the succession's sentence under the line: the judge's path and
/// `ORCH_OVERSEER_PREFERENCE` as set, the default where unset; with
/// succession off, the handoff sentence; the next pass repeats neither.
#[test]
fn the_mark_line_carries_the_succession_s_handling_under_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let claude = named_sleep(dir.path(), "claude");
    let pane = server.open_window(
        "overseer",
        dir.path(),
        &format!(
            "bash -c \"printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; exec {} 600\"",
            claude.display()
        ),
    );
    let identity = await_named(&server, &pane, "claude");
    let window = window_of(&server, &pane);
    let mut record = overseer_at(&server, &pane, &window, dir.path());
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    let state = fleet.read();
    overseer_driver!(server, fleet, reached, no_pick, readers, transfers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            format!("EVENT overseer-mark {pane} kind=headroom value=50 mark=5 succession=on"),
            "Run /nonexistent/oversee-succeed -- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=claude:standard:high,codex:standard:high choosing the successor lane.".to_owned(),
        ]
    );
    assert_eq!(driver.slot.read().unwrap().verdict, Verdict::Live);
    assert!(transfers.borrow().is_empty());
    let second = driver.pass(&state);
    assert!(
        lines(&second).is_empty(),
        "the mark repeats every mark_repeat passes alone: {:?}",
        lines(&second)
    );
    overseer_driver!(
        server, fleet, reached, no_pick, readers2, transfers2, chosen
    );
    chosen.settings.overseer_preference = "claude:fable:high".to_owned();
    let preferred = chosen.pass(&state);
    assert_eq!(
        lines(&preferred).get(1).map(String::as_str),
        Some(
            "Run /nonexistent/oversee-succeed -- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=claude:fable:high choosing the successor lane."
        ),
        "{:?}",
        lines(&preferred)
    );
    overseer_driver!(
        server,
        fleet,
        reached_off,
        no_pick,
        readers3,
        transfers3,
        off
    );
    let off_line = off.pass(&state);
    assert_eq!(
        lines(&off_line),
        vec![
            format!("EVENT overseer-mark {pane} kind=headroom value=50 mark=5 succession=off"),
            "ORCH_OVERSEER_SUCCESSION is off, so no successor opens: rewrite the overseer handoff file and ask the user to start a fresh overseer session.".to_owned(),
        ]
    );
    assert!(transfers3.borrow().is_empty());
}

// U6h (step6-map § A10 row (6), § B "an overseer at its context limit";
// decisions 126 (2), 176 (1) (d)): the overseer's context record, judged
// beside a live session.

/// A live overseer in a pane holding a process named `claude`, its record
/// naming the rows file under `dir`: the pane, its window, the record's
/// pane key and the rows file.
fn live_overseer(dir: &Path, server: &Server, fleet: &Fleet) -> (String, String, String, PathBuf) {
    let claude = named_sleep(dir, "claude");
    let pane = server.open_window(
        "overseer",
        dir,
        &format!(
            "bash -c \"printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; exec {} 600\"",
            claude.display()
        ),
    );
    let identity = await_named(server, &pane, "claude");
    let window = window_of(server, &pane);
    let rows = dir.join("overseer-rows.jsonl");
    let mut record = overseer_at(server, &pane, &window, dir);
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    record["session_rows"] = json!(rows.display().to_string());
    fleet.set_overseer(record);
    let key = format!("{} {pane}", server.pid);
    (pane, window, key, rows)
}

/// The record `lane_context_record` writes, as the hook wrote it at `at`:
/// a reading of `tokens` of `window`, or a gap.
fn context_record(
    path: &Path,
    key: &str,
    tokens: Option<u64>,
    window: Option<u64>,
    gap: Option<&str>,
    at: u64,
) {
    std::fs::write(
        path,
        json!({
            "harness": "claude", "model": "opus", "tokens": tokens, "window": window,
            "used_pct": null, "capacity_source": null, "session_id": "s1",
            "pane_key": key, "gap": gap, "at": clock::iso_utc(at)
        })
        .to_string(),
    )
    .unwrap();
}

/// The session rows the hook writes, one object a line.
fn session_rows(path: &Path, rows: &[Value]) {
    let text: String = rows.iter().map(|r| format!("{r}\n")).collect();
    std::fs::write(path, text).unwrap();
}

/// A SessionStart row for session `s1` at `at`, and a Stop row at `at`.
fn started(at: u64) -> Value {
    json!({"event": "SessionStart", "session_id": "s1", "harness": "claude", "at": at})
}

fn stopped(at: u64) -> Value {
    json!({"event": "Stop", "harness": "claude", "at": at})
}

/// Decisions 176 (1) (d), 179 (5); `oversee-succeed --check-marks
/// --context` (A10 row (6)). Defect: the watch judging the context mark
/// with no reading while the hook judges it with one, so an overseer past
/// its context mark between turn ends is never said; or the mark said on
/// every pass. The session's own record is handed to the judge as
/// `--context TOKENS:WINDOW`; its `mark-reached kind=context` is
/// `overseer-mark ... kind=context` once with the handling under it, then
/// once every `ORCH_OVERSEER_MARK_REPEAT` passes; a record another pane
/// wrote hands the judge nothing.
#[test]
fn the_context_reading_is_handed_to_the_judge_and_a_context_mark_is_said_once_per_repeat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _, key, rows) = live_overseer(dir.path(), &server, &fleet);
    let state = fleet.read();
    let record = dir.path().join("context.json");
    let now = 1_800_000_000;
    context_record(
        &record,
        &key,
        Some(910_000),
        Some(1_000_000),
        None,
        now - 60,
    );
    session_rows(&rows, &[started(now - 600), stopped(now - 30)]);
    let handed: RefCell<Vec<Option<String>>> = RefCell::new(Vec::new());
    let marks = |_: &Path, _: Option<Harness>, context: Option<&str>| {
        handed.borrow_mut().push(context.map(str::to_owned));
        Marks::parse("oversee-succeed: mark-reached kind=context value=910000 mark=90 succession=on headroom=unreadable window=1000000").ok_or_default()
    };
    overseer_driver!(server, fleet, marks, no_pick, readers, transfers, driver);
    driver.context_record = Some(record.clone());
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            format!("EVENT overseer-mark {pane} kind=context value=910000 mark=90 succession=on"),
            "Run /nonexistent/oversee-succeed -- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=claude:standard:high,codex:standard:high choosing the successor lane.".to_owned(),
        ]
    );
    assert_eq!(
        handed.borrow().as_slice(),
        &[Some("910000:1000000".to_owned())],
        "the judge is handed the session's own reading"
    );
    assert_eq!(driver.slot.read().unwrap().verdict, Verdict::Live);
    for _ in 0..4 {
        let quiet = driver.pass(&state);
        assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    }
    let again = driver.pass(&state);
    assert_eq!(
        lines(&again).first().map(String::as_str),
        Some(
            format!("EVENT overseer-mark {pane} kind=context value=910000 mark=90 succession=on")
                .as_str()
        ),
        "{:?}",
        lines(&again)
    );
    assert!(transfers.borrow().is_empty());
    // A record another pane wrote says nothing of this session: the judge
    // is asked with no reading.
    context_record(
        &record,
        "1 %99",
        Some(910_000),
        Some(1_000_000),
        None,
        now - 60,
    );
    let _ = driver.pass(&state);
    assert_eq!(handed.borrow().last().cloned(), Some(None));
}

/// `744fd5727:oversee-watch:4215-4228` (`overseer_context_wedged`), § B
/// "the same record with no Stop row after a full window" (A10 row (6)).
/// Defect: an overseer whose context fills its window read as live
/// because its process runs and its rows say nothing, so the fleet runs
/// unattended until someone finds the pane; or relaunched on one reading.
/// A reading that fills the window with no Stop row after it is the
/// session gone with `source=context`, counted on the death's passes; the
/// same reading with a later Stop row is a session that took a turn since,
/// and live.
#[test]
fn a_full_window_with_no_later_stop_row_is_the_session_gone_by_context() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, window, key, rows) = live_overseer(dir.path(), &server, &fleet);
    let state = fleet.read();
    let record = dir.path().join("context.json");
    let now = 1_800_000_000;
    context_record(
        &record,
        &key,
        Some(1_000_000),
        Some(1_000_000),
        None,
        now - 60,
    );
    session_rows(&rows, &[started(now - 600), stopped(now - 120)]);
    overseer_driver!(server, fleet, below, no_pick, readers, transfers, driver);
    driver.context_record = Some(record.clone());
    let first = driver.pass(&state);
    assert!(lines(&first).is_empty(), "{:?}", lines(&first));
    assert_eq!(
        driver.slot.read().unwrap().verdict,
        Verdict::Exited {
            source: Source::Context
        }
    );
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=2 succession=on source=context"
        )]
    );
    assert!(
        transfers.borrow().is_empty(),
        "the request follows on the next run"
    );
    // A Stop row after the reading: a turn ended since, so the session is
    // live and the reading alone settles nothing.
    session_rows(
        &rows,
        &[started(now - 600), stopped(now - 120), stopped(now - 30)],
    );
    overseer_driver!(server, fleet, below, no_pick, readers2, transfers2, turned);
    turned.context_record = Some(record.clone());
    let live = turned.pass(&state);
    assert!(lines(&live).is_empty(), "{:?}", lines(&live));
    assert_eq!(turned.slot.read().unwrap().verdict, Verdict::Live);
    assert!(transfers2.borrow().is_empty());
}

/// `744fd5727:oversee-watch:4146-4160` (`overseer_context_check`, the
/// stale arm; A10 row (6)). Defect: a record that stopped advancing
/// passing for a context mark that is watching. A record more than
/// `OVERSEER_CONTEXT_STALE_SECS` old with a Stop row after it is
/// `overseer-context-stale` with its age on every pass it stands; a fresh
/// record, and an old one with no Stop row after it, say nothing.
#[test]
fn a_stale_context_record_with_a_later_stop_row_is_said_on_every_pass() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _, key, rows) = live_overseer(dir.path(), &server, &fleet);
    let state = fleet.read();
    let record = dir.path().join("context.json");
    let now = 1_800_000_000;
    context_record(&record, &key, Some(100), Some(1_000_000), None, now - 4000);
    session_rows(&rows, &[started(now - 6000), stopped(now - 100)]);
    overseer_driver!(server, fleet, below, no_pick, readers, transfers, driver);
    driver.context_record = Some(record.clone());
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![format!("EVENT overseer-context-stale {pane} age=4000")]
    );
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![format!("EVENT overseer-context-stale {pane} age=4240")]
    );
    assert_eq!(driver.slot.read().unwrap().verdict, Verdict::Live);
    // Fresh: nothing. Old with the Stop row before it: nothing.
    context_record(
        &record,
        &key,
        Some(100),
        Some(1_000_000),
        None,
        now + 480 - 100,
    );
    let fresh = driver.pass(&state);
    assert!(lines(&fresh).is_empty(), "{:?}", lines(&fresh));
    context_record(&record, &key, Some(100), Some(1_000_000), None, now - 4000);
    session_rows(&rows, &[started(now - 6000), stopped(now - 5000)]);
    let unturned = driver.pass(&state);
    assert!(lines(&unturned).is_empty(), "{:?}", lines(&unturned));
    assert!(transfers.borrow().is_empty());
}

/// `744fd5727:oversee-watch:4161-4200` (`overseer_context_gap`,
/// `overseer_gap_alert`; A10 row (6)). Defect: a gap repeated to an
/// overseer that is not acting on it, which left a fleet unwatched; the
/// owner's alert marked sent when the mailbox refused it; or a gap said
/// forever. A gap is `overseer-context-unmeasured` once; on the next pass
/// the owner's alert goes out and is marked only once sent, so a refused
/// send is tried again on the pass after; then nothing while that gap
/// stands; a different gap starts the turn again, and a reading clears
/// the row.
#[test]
fn a_gap_is_said_once_then_alerted_to_the_owner_once_sent_and_quiet_after() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _, key, rows) = live_overseer(dir.path(), &server, &fleet);
    let state = fleet.read();
    let record = dir.path().join("context.json");
    let now = 1_800_000_000;
    context_record(&record, &key, None, None, Some("pane-unrecorded"), now - 60);
    session_rows(&rows, &[started(now - 600)]);
    let alerts: RefCell<Vec<String>> = RefCell::new(Vec::new());
    let refusing = Cell::new(false);
    let alert = |text: &str| {
        if refusing.get() {
            return Err("mailbox-down".to_owned());
        }
        alerts.borrow_mut().push(text.to_owned());
        Ok(())
    };
    overseer_driver!(server, fleet, below, no_pick, readers, transfers, driver);
    driver.context_record = Some(record.clone());
    driver.alert = &alert;
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![format!(
            "EVENT overseer-context-unmeasured {pane} gap=pane-unrecorded"
        )]
    );
    assert_eq!(
        driver.baseline.get(context::GAP_ROW, &key),
        Some("pane-unrecorded|told")
    );
    refusing.set(true);
    let refused = driver.pass(&state);
    assert!(lines(&refused).is_empty(), "{:?}", lines(&refused));
    assert!(alerts.borrow().is_empty());
    assert_eq!(
        driver.baseline.get(context::GAP_ROW, &key),
        Some("pane-unrecorded|told"),
        "an alert the owner did not get stays owed"
    );
    refusing.set(false);
    let sent = driver.pass(&state);
    assert!(lines(&sent).is_empty(), "{:?}", lines(&sent));
    assert_eq!(
        alerts.borrow().as_slice(),
        &[context::alert_text(&pane, "pane-unrecorded")]
    );
    assert_eq!(
        driver.baseline.get(context::GAP_ROW, &key),
        Some("pane-unrecorded|alerted")
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    assert_eq!(alerts.borrow().len(), 1);
    context_record(&record, &key, None, None, Some("usage-unread"), now - 60);
    let other = driver.pass(&state);
    assert_eq!(
        lines(&other),
        vec![format!(
            "EVENT overseer-context-unmeasured {pane} gap=usage-unread"
        )]
    );
    context_record(&record, &key, Some(100), Some(1_000_000), None, now + 2000);
    let reading = driver.pass(&state);
    assert!(lines(&reading).is_empty(), "{:?}", lines(&reading));
    assert_eq!(driver.baseline.get(context::GAP_ROW, &key), None);
    assert!(transfers.borrow().is_empty());
}

// U5d3 (decision 176 (1) (a), (c)): the standing handoff and the wall
// relaunch's outcomes.

/// The handoff record `744fd5727:skills/orch/tests/oversee_watch.sh` § 2b plants
/// (`handoff_record`), as jq's `tojson` printed it under the event.
const HANDOFF_RECORD: &str = r##"{"written_at":"2026-09-06T05:00:00Z","merged":["#2210"],"remaining":["merge-pr § 5"],"branch":"ken-1","worktree":"/w","open_pr":2218,"traps":[]}"##;

/// The item's workflow state carrying `record` as its handoff.
fn handoff_state(record: &str) -> String {
    format!(r#"{{"cycles":0,"handoff":{record}}}"#)
}

/// A lane record naming no pane, so the pass judges nothing off a screen.
fn paneless(mut record: Value) -> Value {
    record.as_object_mut().unwrap().remove("launch");
    record
}

/// `oversee-watch:2097` (`check_handoff`); `744fd5727:skills/orch/tests/oversee_watch.sh` § 2b
/// (`handoff_once`, `handoff_root_record`, `handoff_resumed`). Defect: a
/// standing handoff said on every pass, or again on a re-run before the
/// relaunch stamps the record; a record only in the lane root's own `tmp`
/// missed; a record the relaunched lane stamped `resumed_at` on still
/// said. A record with no `resumed_at` is `handoff` once with the record
/// under it, read under the fleet's state directory and under the lane
/// root's `tmp`; the same record is quiet after; a resumed one clears the
/// row; a later record of the same item is news again.
#[test]
fn a_standing_handoff_is_said_once_per_record_and_a_resumed_one_clears() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let root = dir.path().join("root-KEN-2");
    fleet.set_lanes(vec![
        paneless(lane_record(
            "KEN-1",
            "gh-1",
            "claude",
            &server,
            "%999",
            None,
            dir.path(),
        )),
        paneless(lane_record(
            "KEN-2", "gh-2", "claude", &server, "%998", None, &root,
        )),
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let state_dir = driver.state_dir.clone();
    let fleet_place = move |item: &str| state_dir.join(format!("workflow-state-{item}.json"));
    std::fs::write(fleet_place("KEN-1"), handoff_state(HANDOFF_RECORD)).unwrap();
    // KEN-2's record stands only in its root's tmp, the fleet's place
    // holding a state with no record.
    std::fs::write(fleet_place("KEN-2"), "{\"cycles\":0}\n").unwrap();
    std::fs::write(
        root.join("tmp/workflow-state-KEN-2.json"),
        handoff_state(r#"{"written_at":"t"}"#),
    )
    .unwrap();
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            "EVENT handoff KEN-1",
            HANDOFF_RECORD,
            "EVENT handoff KEN-2",
            r#"{"written_at":"t"}"#,
        ]
    );
    let key = driver.baseline.get("handoff", "KEN-1").unwrap().to_owned();
    let second = driver.pass(&state);
    assert!(
        lines(&second).is_empty(),
        "the same record is reported once: {:?}",
        lines(&second)
    );
    assert_eq!(driver.baseline.get("handoff", "KEN-1"), Some(key.as_str()));
    // The relaunched lane stamped the record: spent.
    std::fs::write(
        fleet_place("KEN-1"),
        handoff_state(
            r#"{"written_at":"2026-09-06T05:00:00Z","resumed_at":"2026-09-06T05:10:00Z"}"#,
        ),
    )
    .unwrap();
    let resumed = driver.pass(&state);
    assert!(lines(&resumed).is_empty(), "{:?}", lines(&resumed));
    assert_eq!(
        driver.baseline.get("handoff", "KEN-1"),
        None,
        "a resumed record clears the row"
    );
    assert!(driver.baseline.get("handoff", "KEN-2").is_some());
    std::fs::write(
        fleet_place("KEN-1"),
        handoff_state(r#"{"written_at":"2026-09-07T05:00:00Z"}"#),
    )
    .unwrap();
    let again = driver.pass(&state);
    assert_eq!(
        lines(&again),
        vec![
            "EVENT handoff KEN-1",
            r#"{"written_at":"2026-09-07T05:00:00Z"}"#
        ]
    );
}

/// `744fd5727:skills/orch/tests/oversee_watch.sh` § 2b (`handoff_root_torn`, `handoff_unread_*`).
/// Defect: a state this pass could not read passed off as "no handoff",
/// clearing the row and dropping the event for a lane that has already
/// handed off and exited, or one lane's refused read silencing the other
/// lanes' news. A torn file in the lane root's `tmp` is the pass's partial
/// failure naming the item and that file; the other lane's handoff is out;
/// the standing row survives, so the next readable pass still owes the
/// event.
#[test]
fn a_refused_handoff_read_is_the_pass_s_failure_and_the_other_lanes_news_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let root = dir.path().join("root-KEN-1");
    fleet.set_lanes(vec![
        paneless(lane_record(
            "KEN-1", "gh-1", "claude", &server, "%999", None, &root,
        )),
        paneless(lane_record(
            "KEN-2",
            "gh-2",
            "claude",
            &server,
            "%998",
            None,
            dir.path(),
        )),
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let state_dir = driver.state_dir.clone();
    let fleet_place = move |item: &str| state_dir.join(format!("workflow-state-{item}.json"));
    std::fs::write(fleet_place("KEN-1"), "{\"cycles\":0}\n").unwrap();
    let torn = root.join("tmp/workflow-state-KEN-1.json");
    std::fs::write(&torn, "{\"handoff\":").unwrap();
    std::fs::write(fleet_place("KEN-2"), handoff_state(HANDOFF_RECORD)).unwrap();
    driver.baseline.apply(Change::Set {
        kind: "handoff".into(),
        identity: "KEN-1".into(),
        value: "2455569205".into(),
    });
    let produced = driver.pass(&state);
    assert_eq!(
        produced.failed.as_deref(),
        Some(format!("handoff-read-failed item=KEN-1 path={}", torn.display()).as_str())
    );
    assert_eq!(
        lines(&produced),
        vec!["EVENT handoff KEN-2", HANDOFF_RECORD]
    );
    assert_eq!(
        driver.baseline.get("handoff", "KEN-1"),
        Some("2455569205"),
        "the standing row survives, so the next readable pass still owes the event"
    );
}

/// One outcomes pass over the markers under `dir`, the changes applied as
/// the runner commits them; the prepare bound its default, 1800 s.
fn outcomes(dir: &Path, baseline: &mut Baseline, now: u64) -> Produced {
    let produced = overseer::relaunch_outcomes(dir, Duration::from_secs(1800), now, baseline);
    apply(baseline, &produced);
    produced
}

/// A relaunch marker as the wall route writes it; the marker and its log.
fn plant_marker(dir: &Path, lane: &str, item: &str, since: u64) -> (PathBuf, PathBuf) {
    let marker = wall::relaunch_marker_path(dir, lane);
    let log = dir.join(format!("wall-relaunch-{item}.log"));
    wall::write_relaunch_marker(&marker, item, since, &log).unwrap();
    (marker, log)
}

/// `oversee-watch:4667` (`wall_relaunch_outcomes`), the bytes
/// `744fd5727:skills/orch/tests/oversee_watch_wall_relaunch.sh` `failure_passes` pins. Defect: a
/// relaunch that exited non-zero never said, said on every pass, or judged
/// off its window instead of its completed status; a status of 0 said as a
/// failure. The completed status beside the marker is `lane-prepare-failed`
/// with the exit and the log once; the marker and its status leave with
/// the row, for a status of 0 as well; the next pass says nothing.
#[test]
fn a_failed_relaunch_is_said_once_with_its_exit_and_log_and_its_marker_leaves() {
    let dir = tempfile::tempdir().unwrap();
    let now = 1_800_000_000;
    let (failed, log) = plant_marker(dir.path(), "gh-2", "KEN-2", now - 60);
    std::fs::write(overseer::relaunch_exit_path(&failed), "1\n").unwrap();
    let (ok, _) = plant_marker(dir.path(), "gh-3", "KEN-3", now - 60);
    std::fs::write(overseer::relaunch_exit_path(&ok), "0\n").unwrap();
    let mut baseline = Baseline::default();
    baseline.apply(Change::Set {
        kind: "wall-relaunch".into(),
        identity: "KEN-2".into(),
        value: format!("{}|stuck", now - 60),
    });
    let first = outcomes(dir.path(), &mut baseline, now);
    assert_eq!(
        lines(&first),
        vec![format!(
            "EVENT lane-prepare-failed KEN-2 reason=relaunch-failed exit=1 log={}",
            log.display()
        )]
    );
    assert_eq!(first.failed, None);
    for marker in [&failed, &ok] {
        assert!(
            !marker.exists() && !overseer::relaunch_exit_path(marker).exists(),
            "the marker ends after its outcome was reported: {}",
            marker.display()
        );
    }
    assert_eq!(baseline.get("wall-relaunch", "KEN-2"), None);
    let second = outcomes(dir.path(), &mut baseline, now + 240);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
}

/// `744fd5727:skills/orch/tests/oversee_watch_wall_relaunch.sh` `stuck_passes`. Defect: an
/// overdue detached recovery never said while its old window survives,
/// said on every pass, or a fresh relaunch's wait silenced by an earlier
/// one's row. A marker with no status `ORCH_WATCH_PREPARE_SECS` past its
/// start is `lane-prepare-stuck` with its age, log and
/// `reason=relaunch-pending` once, keyed by that start, the marker kept; a
/// marker inside the bound is quiet; a relaunch started afresh is said
/// afresh, at the bound exactly.
#[test]
fn a_relaunch_pending_past_the_prepare_bound_is_said_once_per_start() {
    let dir = tempfile::tempdir().unwrap();
    let now = 1_800_000_000;
    let (pending, log) = plant_marker(dir.path(), "gh-2", "KEN-2", now - 1801);
    let (young, _) = plant_marker(dir.path(), "gh-4", "KEN-4", now);
    let mut baseline = Baseline::default();
    let first = outcomes(dir.path(), &mut baseline, now);
    assert_eq!(
        lines(&first),
        vec![format!(
            "EVENT lane-prepare-stuck KEN-2 age=1801s log={} reason=relaunch-pending",
            log.display()
        )]
    );
    assert_eq!(
        baseline.get("wall-relaunch", "KEN-2"),
        Some(format!("{}|stuck", now - 1801).as_str())
    );
    assert!(pending.exists(), "the marker stands until its status lands");
    let second = outcomes(dir.path(), &mut baseline, now + 240);
    assert!(lines(&second).is_empty(), "{:?}", lines(&second));
    std::fs::remove_file(young).unwrap();
    let restarted = now + 240;
    plant_marker(dir.path(), "gh-2", "KEN-2", restarted);
    let third = outcomes(dir.path(), &mut baseline, restarted + 1800);
    assert_eq!(
        lines(&third),
        vec![format!(
            "EVENT lane-prepare-stuck KEN-2 age=1800s log={} reason=relaunch-pending",
            log.display()
        )]
    );
}

/// Decisions 99, 105. Defect: an exit status this reader cannot read taken
/// as absent, so an ended relaunch is said stuck or its outcome lost. A
/// status that cannot be read, or one that is no exit code, is the pass's
/// partial failure naming the file: no line, the marker and the status
/// kept for the next pass, no row.
#[test]
fn an_unreadable_exit_status_is_the_pass_s_failure_not_a_stuck_line() {
    let dir = tempfile::tempdir().unwrap();
    let now = 1_800_000_000;
    let (marker, _) = plant_marker(dir.path(), "gh-2", "KEN-2", now - 3600);
    let exit = overseer::relaunch_exit_path(&marker);
    std::fs::create_dir(&exit).unwrap();
    let mut baseline = Baseline::default();
    let produced = outcomes(dir.path(), &mut baseline, now);
    let expected = format!("state-read-failed path={}", exit.display());
    assert!(
        produced
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with(&expected)),
        "an unreadable status is the pass's failure: {:?}",
        produced.failed
    );
    assert!(lines(&produced).is_empty(), "{:?}", lines(&produced));
    assert!(
        marker.exists() && exit.exists(),
        "nothing leaves on a failed read"
    );
    assert!(baseline.rows.is_empty(), "{:?}", baseline.rows);
    std::fs::remove_dir(&exit).unwrap();
    std::fs::write(&exit, "boom\n").unwrap();
    let produced = outcomes(dir.path(), &mut baseline, now);
    assert!(
        produced
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with(&expected)),
        "a status that is no exit code is the same failure: {:?}",
        produced.failed
    );
    assert!(lines(&produced).is_empty(), "{:?}", lines(&produced));
    assert!(marker.exists() && exit.exists());
}

/// A lane whose recorded pane the server has not.
fn gone_lane(server: &Server, item: &str, window: &str, pane: &str, dir: &Path) -> Value {
    lane_record(item, window, "claude", server, pane, None, dir)
}

/// The `usage-limit` row the relaunch left (`|lane-relaunched`), the row
/// a gone window clears, planted to prove whether it moves.
const RELAUNCHED_ROW: &str = "1800000000|%7|usage-limit|lane-relaunched";

/// `oversee-watch:4656` (`wall_relaunch_pending`) at its one caller
/// (`:4812`), the row `744fd5727:skills/orch/tests/oversee_watch_wall_relaunch.sh` `gone_passes`
/// pins (`"0 1"`). Defect: the window a relaunch is replacing said gone
/// while that launch is still opening it, its wall row cleared under the
/// relaunch so the wall is relaunched again; or the suppression outliving
/// the launch, so a window gone for good is never said. A gone window
/// whose relaunch marker stands with no status inside the prepare bound
/// says nothing and moves no row; once the status lands it is
/// `window-gone` as any other, its rows cleared; a marker at the bound
/// suppresses nothing.
#[test]
fn a_gone_window_under_a_pending_relaunch_is_said_once_the_launch_ended() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    fleet.set_lanes(vec![
        gone_lane(&server, "KEN-2", "gh-2", "%999", dir.path()),
        gone_lane(&server, "KEN-3", "gh-3", "%998", dir.path()),
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let watch_dir = lanes::watch_state_dir(&driver.settings.claim_store).to_path_buf();
    std::fs::create_dir_all(&watch_dir).unwrap();
    let (pending, _) = plant_marker(&watch_dir, "gh-2", "KEN-2", driver.now);
    plant_marker(&watch_dir, "gh-3", "KEN-3", driver.now - 1800);
    driver.baseline.apply(Change::Set {
        kind: "usage-limit".into(),
        identity: "gh-2".into(),
        value: RELAUNCHED_ROW.into(),
    });
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec!["EVENT window-gone gh-3"],
        "no window-gone while the relaunch runs; one for the marker at the bound"
    );
    assert_eq!(first.failed, None);
    assert_eq!(
        driver.baseline.get("usage-limit", "gh-2"),
        Some(RELAUNCHED_ROW),
        "no row moves under the relaunch"
    );
    std::fs::write(overseer::relaunch_exit_path(&pending), "0\n").unwrap();
    let second = driver.pass(&state);
    assert_eq!(
        event_lines(&second),
        vec!["EVENT window-gone gh-2", "EVENT window-gone gh-3"],
        "window-gone once the launch ended"
    );
    assert_eq!(
        driver.baseline.get("usage-limit", "gh-2"),
        None,
        "the ended relaunch's gone window clears its rows"
    );
}

/// Decisions 99, 105, 156 (1). Defect: a relaunch marker this reader
/// cannot read taken as no pending relaunch (the legacy's `jq -er`
/// failure, `oversee-watch:4660`), so the window the relaunch is replacing
/// is said gone and its rows cleared under it. A torn marker is the pass's
/// partial failure naming it: no line, no row moved, and the next pass
/// asks again.
#[test]
fn an_unreadable_relaunch_marker_is_the_pass_s_failure_not_a_gone_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    fleet.set_lanes(vec![gone_lane(
        &server,
        "KEN-2",
        "gh-2",
        "%999",
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let watch_dir = lanes::watch_state_dir(&driver.settings.claim_store).to_path_buf();
    std::fs::create_dir_all(&watch_dir).unwrap();
    let marker = wall::relaunch_marker_path(&watch_dir, "gh-2");
    std::fs::write(&marker, r#"{"item":"KEN-2","since":"#).unwrap();
    driver.baseline.apply(Change::Set {
        kind: "usage-limit".into(),
        identity: "gh-2".into(),
        value: RELAUNCHED_ROW.into(),
    });
    let expected = format!("state-read-failed path={}", marker.display());
    for _ in 0..2 {
        let produced = driver.pass(&state);
        assert!(
            produced
                .failed
                .as_deref()
                .is_some_and(|f| f.starts_with(&expected)),
            "an unreadable marker is the pass's failure: {:?}",
            produced.failed
        );
        assert!(
            event_lines(&produced).is_empty(),
            "{:?}",
            event_lines(&produced)
        );
        assert_eq!(
            driver.baseline.get("usage-limit", "gh-2"),
            Some(RELAUNCHED_ROW),
            "no row moves on a failed read"
        );
    }
}

// --- U7a: the hosted readings (step7-map § A1; decisions 57, 176 (1) (e)-(i), 192 Q1, Q2) ---

/// The `local` and `claude-cloud` lines the dispatcher answers, and a static
/// ssh provider's (`schemas/lane-host.md` § Host kinds).
const CLOUD_LINE: &str =
    "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none";
const SSH_LINE: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb";
/// A provider path, the host a hosted record names.
const PROVIDER: &str = "/w/provider";

/// A row's world for the hosted reads: the `lane-host`, `lane-close` and
/// `gh` fixtures linked under one scripts directory, their planted answers
/// and logs beside them, as the production runner finds them from the
/// pass's scripts directory and the `gh` path the pass carries.
struct HostedWorld {
    scripts: PathBuf,
}

impl HostedWorld {
    fn new(dir: &Path) -> HostedWorld {
        let scripts = dir.join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        for (fixture, name) in [
            ("lane-host/lane-host", "lane-host"),
            ("lane-close/lane-close", "lane-close"),
            ("gh/gh", "gh"),
        ] {
            std::os::unix::fs::symlink(fixtures().join(fixture), scripts.join(name)).unwrap();
        }
        let world = HostedWorld { scripts };
        world.plant_host(&[]);
        world.plant_close(json!({}));
        world.plant_gh(json!({}));
        world
    }

    fn gh(&self) -> PathBuf {
        self.scripts.join("gh")
    }

    /// The `lane-host` answers, by argv (or `<host> <argv>`).
    fn plant_host(&self, answers: &[(&str, Value)]) {
        let map: serde_json::Map<String, Value> = answers
            .iter()
            .map(|(key, value)| ((*key).to_owned(), value.clone()))
            .collect();
        std::fs::write(
            self.scripts.join("lane-host.json"),
            Value::Object(map).to_string(),
        )
        .unwrap();
    }

    /// The one `lane-close` answer.
    fn plant_close(&self, answer: Value) {
        std::fs::write(self.scripts.join("lane-close.json"), answer.to_string()).unwrap();
    }

    /// The `gh api` answers, by path.
    fn plant_gh(&self, answers: Value) {
        std::fs::write(self.scripts.join("gh.json"), answers.to_string()).unwrap();
    }

    fn log(&self, name: &str) -> Vec<String> {
        std::fs::read_to_string(self.scripts.join(name))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn host_log(&self) -> Vec<String> {
        self.log("lane-host.log")
    }

    fn close_log(&self) -> Vec<String> {
        self.log("lane-close.log")
    }
}

/// A fixture answer: the status and the bytes printed.
fn answer(exit: i32, stdout: &str) -> Value {
    json!({"exit": exit, "stdout": stdout})
}

fn ok(stdout: &str) -> Value {
    answer(0, stdout)
}

/// `gh api repos/O/R/pulls?head=O:B&state=open`'s one open pull request.
fn open_pull(sha: &str, body: &str, draft: Option<bool>) -> Value {
    json!({"body": [{"head": {"sha": sha}, "body": body, "draft": draft}]})
}

/// The body digest as the stall row keeps it (`cksum` over the body and
/// the newline jq printed after it).
fn digest(body: &str) -> String {
    wall::cksum(format!("{body}\n").as_bytes()).to_string()
}

/// A running Claude cloud lane: its session opened at `now - 7000`, on
/// `account`, in `o/r`.
fn cloud_lane(item: &str, account: &str, now: u64) -> Value {
    json!({
        "item": item, "harness": "claude", "host": "claude-cloud", "kind": "claude-cloud",
        "repo": "o/r", "account": account, "mail_root": "/remote/cloud", "status": "running",
        "running_at": clock::iso_utc(now - 7200), "launched_at": clock::iso_utc(now - 7200),
        "session_since": clock::iso_utc(now - 7000),
    })
}

/// A running lane on the ssh provider, its worktree at `root` on the host.
fn hosted_lane(item: &str, window: &str, root: &str) -> Value {
    json!({
        "item": item, "window": window, "harness": "claude", "host": PROVIDER, "kind": "ssh",
        "mail_root": root, "status": "running",
    })
}

/// The tracker's quota receipt line, holding until `reset`.
fn quota_receipt(reset: u64) -> String {
    json!({"code": "RATELIMITED", "quota": {"limit": "requests", "status": "future", "reset": clock::iso_utc(reset), "reset_epoch": reset}})
        .to_string()
}

fn stalled_lines(produced: &Produced) -> Vec<String> {
    event_lines(produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT lane-stalled ") || l.starts_with("EVENT start-stalled "))
        .collect()
}

/// `lib/watch-host-kinds.sh:368` (`check_lane_stall`), the cases
/// `744fd5727:skills/orch/tests/oversee_watch_cloud.sh` pinned on the cloud
/// lane's pull request (`stalled`, `finished`, `credit`). Defect: a cloud
/// session no pane shows never said stalled, said on every pass, said while
/// its pull request still moves, or a ready pull request closed as a stall.
/// A cloud lane's open pull request standing still for
/// `ORCH_WATCH_LANE_STALL_SECS` is `lane-stalled` with the age once, then
/// every `mark_repeat` passes; a head that moved starts the bound over; a
/// ready one is `state=finished` at once, a draft on an account the roster
/// reads out of credit `state=out-of-credit`, each once per repeat; none of
/// them is closed.
#[test]
fn a_cloud_lane_whose_pull_request_stands_still_is_lane_stalled_and_a_ready_or_unpaid_one_said_at_once()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    fleet.set_lanes(vec![
        cloud_lane("CC-1", "/a", now),
        cloud_lane("CC-2", "/a", now),
        cloud_lane("CC-3", "/b", now),
    ]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[("capabilities", ok(CLOUD_LINE))]);
    let body = "## Lane status\nStep: implement";
    let pulls = |sha: &str| {
        json!({
            "repos/o/r/pulls?head=o:cc-1&state=open": open_pull(sha, body, Some(true)),
            "repos/o/r/pulls?head=o:cc-2&state=open": open_pull("bbb222", "", Some(false)),
            "repos/o/r/pulls?head=o:cc-3&state=open": open_pull("ccc333", "", Some(true)),
        })
    };
    world.plant_gh(pulls("aaa111"));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    driver.roster = Roster::parse(
        &json!([
            {"alias": "a", "harness": "claude", "config_dir": "/a", "status": "ok", "verdict": "pick",
             "credits": {"remaining_dollars": 12.5}},
            {"alias": "b", "harness": "claude", "config_dir": "/b", "status": "ok", "verdict": "pick",
             "credits": {"remaining_dollars": 0, "locked_reason": "spend-limit"}}
        ])
        .to_string(),
        &driver.settings.accounts,
    );
    assert!(driver.roster.is_some(), "the planted roster reads");
    let first = driver.pass(&state);
    assert_eq!(
        stalled_lines(&first),
        vec![
            "EVENT lane-stalled CC-2 age=0 state=finished",
            "EVENT lane-stalled CC-3 age=0 state=out-of-credit",
        ],
        "{:?}",
        lines(&first)
    );
    assert_eq!(first.failed, None);
    assert_eq!(
        driver.baseline.get("lane-stalled", "CC-1"),
        Some(format!("aaa111|{}|{now}||", digest(body)).as_str())
    );
    for _ in 0..4 {
        let quiet = driver.pass(&state);
        assert!(stalled_lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    }
    driver.now = now + 3600;
    let sixth = driver.pass(&state);
    assert_eq!(
        stalled_lines(&sixth),
        vec![
            "EVENT lane-stalled CC-1 age=3600",
            "EVENT lane-stalled CC-2 age=3600 state=finished",
            "EVENT lane-stalled CC-3 age=3600 state=out-of-credit",
        ],
        "the stalled lane at the bound, the two states on their repeat"
    );
    // The head moved: the bound starts over and the lane is quiet.
    world.plant_gh(pulls("ddd444"));
    let moved = driver.pass(&state);
    assert!(stalled_lines(&moved).is_empty(), "{:?}", lines(&moved));
    assert_eq!(
        driver.baseline.get("lane-stalled", "CC-1"),
        Some(format!("ddd444|{}|{}||", digest(body), now + 3840).as_str())
    );
    assert!(world.close_log().is_empty(), "no stall closes a lane here");
    assert!(
        world
            .host_log()
            .iter()
            .all(|l| l == "ORCH_LANE_HOST=claude-cloud capabilities"),
        "{:?}",
        world.host_log()
    );
}

/// Decisions 120, 192 Q2; `lib/watch-host-kinds.sh:431` (`cloud_stall_close`),
/// `oversee-watch:1420` (`close_hosted_lane`), the case
/// `744fd5727:skills/orch/tests/oversee_watch_cloud.sh` pinned as `closed`.
/// Defect: a stalled cloud lane whose directive went unanswered closed on
/// every pass, closed without a record that it was asked, a refusal read as
/// a close, a tracker quota hold read as a failure, or a close asked beside
/// a marker an earlier runtime left. The directive at or after the stall's
/// `since` and `ORCH_CLOUD_STALL_MINUTES` old closes the lane once through
/// `lane-close --state-dir [DIR] [ITEM]`, the marker created before the ask
/// and gone after its answer: `lane-closed` with the archive line, then
/// `cloud-stall-closed` with the directive's age. Exit 3 is
/// `lane-close-refused` with the path, the lane kept and the stall said; a
/// quota receipt defers it with no line; a standing hold asks nothing; a
/// standing marker beside the open lane asks nothing and is the pass's
/// failure; a marker of an earlier launch is pruned and the close proceeds.
#[test]
fn a_stalled_cloud_lane_whose_directive_went_unanswered_is_closed_once_with_the_marker_before_the_ask()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let mut lane = cloud_lane("CC-1", "/a", now);
    lane["directive_send"] = json!({"at": now - 1900, "result": "sent", "text": "Rebase."});
    fleet.set_lanes(vec![lane.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[("capabilities", ok(CLOUD_LINE))]);
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": open_pull("aaa111", "", Some(true)),
    }));
    world.plant_close(ok("kept=/archive/CC-1\n"));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    driver.baseline.apply(Change::Set {
        kind: "lane-stalled".into(),
        identity: "CC-1".into(),
        value: format!("aaa111|{}|{}||", digest(""), now - 3700),
    });
    let marker =
        hosted::close_marker_path(lanes::watch_state_dir(&driver.settings.claim_store), "CC-1");
    let close = format!("--state-dir {} CC-1", driver.state_dir.display());
    let closed = driver.pass(&state);
    assert_eq!(
        lines(&closed),
        vec![
            "EVENT lane-closed CC-1",
            "kept=/archive/CC-1",
            "EVENT cloud-stall-closed CC-1 directive_age=1900",
        ]
    );
    assert_eq!(closed.failed, None);
    assert_eq!(world.close_log(), vec![close.clone()]);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the marker stands until the record confirms the close"
    );
    // The record still reads the lane open (decision 194): the operator's
    // lane, named each pass, never a second close.
    let open_still = driver.pass(&state);
    assert!(
        open_still
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-unconfirmed item=CC-1 marker=")),
        "{:?}",
        open_still.failed
    );
    assert_eq!(
        world.close_log().len(),
        1,
        "no second close beside the marker"
    );
    // The record `lane-close` wrote: the lane out of flight, the marker leaves.
    let mut stopped = lane.clone();
    stopped["status"] = json!("stopped");
    fleet.set_lanes(vec![stopped]);
    let after_close = driver.pass(&fleet.read());
    assert_eq!(after_close.failed, None);
    assert!(lines(&after_close).is_empty(), "{:?}", lines(&after_close));
    assert!(
        std::fs::metadata(&marker).is_err(),
        "the marker leaves once the record confirms the close"
    );
    // The lane launched again on the same record and stalled again (the
    // stopped lane's row left with it): the close refused, the lane kept,
    // the stall said.
    fleet.set_lanes(vec![lane.clone()]);
    let state = fleet.read();
    driver.baseline.apply(Change::Set {
        kind: "lane-stalled".into(),
        identity: "CC-1".into(),
        value: format!("aaa111|{}|{}||", digest(""), driver.now - 3700),
    });
    world.plant_close(json!({"exit": 3, "stdout": "lane-close: close-refused path=/w/cc-1\n"}));
    let refused = driver.pass(&state);
    assert_eq!(
        lines(&refused),
        vec![
            "EVENT lane-close-refused CC-1",
            "path=/w/cc-1",
            "EVENT lane-stalled CC-1 age=3700",
        ]
    );
    assert_eq!(refused.failed, None);
    assert_eq!(world.close_log().len(), 2);
    assert!(
        std::fs::metadata(&marker).is_err(),
        "an answer that closed nothing takes its marker"
    );
    // The tracker's quota refusal on the answer: deferred, no line.
    world.plant_close(json!({"exit": 1, "stderr": format!("{}\n", quota_receipt(now + 7200))}));
    let deferred = driver.pass(&state);
    assert!(lines(&deferred).is_empty(), "{:?}", lines(&deferred));
    assert_eq!(deferred.failed, None);
    assert_eq!(world.close_log().len(), 3);
    // The hold the tracker duty recorded: nothing asked.
    driver.baseline.apply(Change::Set {
        kind: "tracker-quota".into(),
        identity: "fleet".into(),
        value: json!({"limit": "requests", "status": "future", "reset": clock::iso_utc(now + 7200), "reset_epoch": now + 7200}).to_string(),
    });
    let held = driver.pass(&state);
    assert!(lines(&held).is_empty(), "{:?}", lines(&held));
    assert_eq!(world.close_log().len(), 3, "a standing hold asks nothing");
    driver.baseline.apply(Change::Clear {
        kind: "tracker-quota".into(),
        identity: "fleet".into(),
    });
    // A marker an earlier runtime left beside the open lane: nothing asked.
    std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
    let launch = lane["launched_at"].as_str().unwrap();
    std::fs::write(
        &marker,
        json!({"item": "CC-1", "reason": "cloud-stall", "at": now, "launch": launch}).to_string(),
    )
    .unwrap();
    world.plant_close(ok("kept=/archive/CC-1\n"));
    let standing = driver.pass(&state);
    assert!(
        standing
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-unconfirmed item=CC-1 marker=")),
        "{:?}",
        standing.failed
    );
    assert!(lines(&standing).is_empty(), "{:?}", lines(&standing));
    assert_eq!(world.close_log().len(), 3, "a standing marker asks nothing");
    assert!(std::fs::metadata(&marker).is_ok(), "the marker stands");
    // A marker of an earlier launch of the item: pruned, the close proceeds.
    std::fs::write(
        &marker,
        json!({"item": "CC-1", "reason": "cloud-stall", "at": now, "launch": "2000-01-01T00:00:00Z"}).to_string(),
    )
    .unwrap();
    let again = driver.pass(&state);
    assert_eq!(
        event_lines(&again),
        vec![
            "EVENT lane-closed CC-1",
            "EVENT cloud-stall-closed CC-1 directive_age=3580"
        ]
    );
    assert_eq!(again.failed, None);
    assert_eq!(world.close_log().len(), 4);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "this close's own marker stands for the record read"
    );
}

/// `oversee-watch:2662` (`check_start_stall`, the `HOSTED_ROOT` arm), the
/// case `744fd5727:skills/orch/tests/oversee_watch_start_stall.sh` pinned as
/// `hosted_fetch`. Defect: a hosted lane's status file read on this disk,
/// where it is not, so every hosted lane is `start-stalled`; or a fetch that
/// failed read as "no file". The file is read through `lane-host cat` under
/// the record's host, a `2` confirmed by `touch`: a missing file past the
/// bound is `start-stalled`, a file that stands ends the watch, and a fetch
/// that failed (the provider's own failure, the dispatcher's busy refusal)
/// is `start-stall-unread`, the pass's failure and no line (decision 99); a
/// lane whose worktree the host no longer has (its `.git` gone, the merged
/// check's lane, c11:2678's `HOSTED_GONE_ITEMS` skip) writes no status file
/// and is no stall.
#[test]
fn a_hosted_lane_s_status_file_is_read_through_the_provider_and_a_failed_fetch_is_no_stall() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let running = clock::iso_utc(now - 700);
    let mut lanes = Vec::new();
    for n in 1..=5 {
        let mut lane = hosted_lane(
            &format!("KEN-{n}"),
            &format!("gh-{n}"),
            &format!("/remote/KEN-{n}"),
        );
        lane["running_at"] = json!(running);
        lanes.push(lane);
    }
    fleet.set_lanes(lanes);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    let status = |n: u32| {
        (
            format!("status --item KEN-{n} --harness claude"),
            ok("running\n"),
        )
    };
    let statuses: Vec<(String, Value)> = (1..=5).map(status).collect();
    let mut answers: Vec<(&str, Value)> = statuses
        .iter()
        .map(|(k, v)| (k.as_str(), v.clone()))
        .collect();
    answers.extend([
        ("capabilities", ok(SSH_LINE)),
        ("cat --item KEN-1 /remote/KEN-1/tmp/lane-status-KEN-1.md", answer(2, "")),
        ("touch --item KEN-1", ok("")),
        ("cat --item KEN-1 /remote/KEN-1/.git", ok("gitdir: /x/.git/worktrees/KEN-1\n")),
        (
            "cat --item KEN-2 /remote/KEN-2/tmp/lane-status-KEN-2.md",
            json!({"exit": 1, "stderr": "lane-host: ssh-failed host=/w/provider\n"}),
        ),
        // Read only by a reader that takes the failure above for no file.
        ("cat --item KEN-2 /remote/KEN-2/.git", ok("gitdir: /x/.git/worktrees/KEN-2\n")),
        ("cat --item KEN-3 /remote/KEN-3/tmp/lane-status-KEN-3.md", answer(2, "")),
        (
            "touch --item KEN-3",
            json!({"exit": 69, "stderr": "lane-host: lane-host-busy count=4 cap=4 verb=touch item=KEN-3\n"}),
        ),
        ("cat --item KEN-4 /remote/KEN-4/tmp/lane-status-KEN-4.md", ok("Step: start\n")),
        ("cat --item KEN-5 /remote/KEN-5/tmp/lane-status-KEN-5.md", answer(2, "")),
        ("touch --item KEN-5", ok("")),
        ("cat --item KEN-5 /remote/KEN-5/.git", answer(2, "")),
    ]);
    world.plant_host(&answers);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let produced = driver.pass(&state);
    assert_eq!(
        event_lines(&produced),
        vec!["EVENT start-stalled gh-1 age=700"]
    );
    assert_eq!(
        produced.failed.as_deref(),
        Some(
            "start-stall-unread item=KEN-2 cause=cat exit=1 lane-host: ssh-failed host=/w/provider"
        )
    );
    assert_eq!(
        driver.baseline.get("start-stalled", "gh-1"),
        Some(format!("{}|0", now - 700).as_str())
    );
    assert_eq!(driver.baseline.get("start-stalled", "gh-2"), None);
    assert_eq!(
        driver.baseline.get("start-stalled", "gh-3"),
        None,
        "the busy refusal is no file"
    );
    assert_eq!(
        driver.baseline.get("start-stalled", "gh-4"),
        Some(format!("{}|seen", now - 700).as_str())
    );
    assert_eq!(
        driver.baseline.get("start-stalled", "gh-5"),
        None,
        "a worktree the host no longer has is no stall"
    );
    let log = world.host_log();
    assert!(
        log.iter()
            .all(|l| l.starts_with("ORCH_LANE_HOST=/w/provider ")),
        "{log:?}"
    );
    assert!(
        log.contains(&"ORCH_LANE_HOST=/w/provider touch --item KEN-3".to_owned()),
        "{log:?}"
    );
    assert!(
        log.contains(&"ORCH_LANE_HOST=/w/provider cat --item KEN-5 /remote/KEN-5/.git".to_owned()),
        "{log:?}"
    );
}

/// R-U7-1 L1 and R-U7-2 L1 (`fleet_merge`, `oversee-watch:959-969`: the
/// running rows' hosts alone; a parked row went to `PARKED_ITEMS` with no
/// host read). Defect: a done, stopped or parked record's host asked for
/// its capability line every pass, so a provider that is gone is `host-
/// capabilities-unread` ahead of every live lane's line, hiding a live
/// lane's `start-stall-unread` and the standing marker's
/// `lane-close-unconfirmed`, the operator's one signal (decision 194); the
/// parked lane's one reader, `lane_long`, reads no line for it. A done
/// lane, a stopped lane and a parked lane (the `lanes park` record) on a
/// gone provider beside a running lane whose fetch fails: the pass's
/// failure is the live lane's, and no call runs under the gone host.
#[test]
fn a_lane_out_of_flight_s_gone_provider_is_not_asked_and_hides_no_live_lane_s_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let mut live = hosted_lane("KEN-1", "gh-1", "/remote/KEN-1");
    live["running_at"] = json!(clock::iso_utc(now - 700));
    let mut done = hosted_lane("KEN-8", "gh-8", "/remote/KEN-8");
    done["host"] = json!("/w/gone");
    done["status"] = json!("done");
    let mut stopped = hosted_lane("KEN-9", "gh-9", "/remote/KEN-9");
    stopped["host"] = json!("/w/gone");
    stopped["status"] = json!("stopped");
    let mut parked = hosted_lane("KEN-7", "gh-7", "/remote/KEN-7");
    parked["host"] = json!("/w/gone");
    parked["status"] = json!("parked");
    parked["parked"] = json!({"head": "abc", "repo": "o/r", "at": "2026-10-24T20:00:00Z"});
    fleet.set_lanes(vec![done, live, stopped, parked]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (&format!("{PROVIDER} capabilities"), ok(SSH_LINE)),
        ("status --item KEN-1 --harness claude", ok("running\n")),
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/lane-status-KEN-1.md",
            json!({"exit": 1, "stderr": "lane-host: ssh-failed host=/w/provider\n"}),
        ),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let produced = driver.pass(&state);
    assert_eq!(
        produced.failed.as_deref(),
        Some(
            "start-stall-unread item=KEN-1 cause=cat exit=1 lane-host: ssh-failed host=/w/provider"
        ),
        "the live lane's line, not the gone provider's"
    );
    assert!(event_lines(&produced).is_empty(), "{:?}", lines(&produced));
    let log = world.host_log();
    assert!(
        !log.iter().any(|l| l.starts_with("ORCH_LANE_HOST=/w/gone ")),
        "no call under the gone host: {log:?}"
    );
}

/// `oversee-watch:2662` (`check_start_stall`, the `FILELESS` arm), the cases
/// `744fd5727:skills/orch/tests/oversee_watch_cloud.sh` pinned as `pushed`
/// and `never_pushed`. Defect: a cloud session that pushed said
/// `start-stalled` for want of a status file it never writes, or a session
/// that never pushed left unsaid. A branch head committed at or after the
/// record's `session_since` reads the session started: `start-stalled`
/// never goes out, and a started session whose head stands still for
/// `ORCH_WATCH_LANE_STALL_SECS` is `lane-stalled`; a session with no branch
/// is `start-stalled` past the start bound, counted as the local arm counts.
#[test]
fn a_cloud_session_with_no_pull_request_is_quiet_once_pushed_and_lane_stalled_when_nothing_moves() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    fleet.set_lanes(vec![
        cloud_lane("CC-1", "/a", now),
        cloud_lane("CC-2", "/a", now),
    ]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[("capabilities", ok(CLOUD_LINE))]);
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": {"body": []},
        "repos/o/r/branches/cc-1": {"body": {"commit": {"sha": "bbb222", "commit": {"committer": {"date": clock::iso_utc(now - 100)}}}}},
        "repos/o/r/pulls?head=o:cc-2&state=open": {"body": []},
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let first = driver.pass(&state);
    assert_eq!(
        stalled_lines(&first),
        vec!["EVENT start-stalled CC-2 age=7200"]
    );
    assert_eq!(first.failed, None);
    assert_eq!(
        driver.baseline.get("start-stalled", "CC-1"),
        Some(format!("{}|pushed|o/r:bbb222|{now}|", now - 7200).as_str())
    );
    assert_eq!(
        driver.baseline.get("start-stalled", "CC-2"),
        Some(format!("{0}|0||{0}|", now - 7200).as_str())
    );
    for _ in 0..3 {
        let quiet = driver.pass(&state);
        assert!(stalled_lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    }
    driver.now = now + 3600;
    let stalled = driver.pass(&state);
    assert_eq!(
        stalled_lines(&stalled),
        vec!["EVENT lane-stalled CC-1 age=3600"]
    );
    assert_eq!(
        driver.baseline.get("start-stalled", "CC-1"),
        Some(format!("{}|pushed|o/r:bbb222|{now}|0", now - 7200).as_str())
    );
}

/// `lib/watch-host-kinds.sh:446` (`check_lane_long`, the hosted arms of
/// `lane_step` and `lane_long_rounds`), the cases
/// `744fd5727:skills/orch/tests/oversee_watch_start_stall.sh` pinned as
/// `hosted_stage`. Defect: a hosted lane's stage and counts read off this
/// disk, so every hosted lane reads `none` and zero; a fetch that failed
/// read as no file. A hosted lane's `Step` line, workflow state and run
/// index come through the provider; a fetch that failed is `stage=unread`
/// and `unread` counts with the pass's failure; a parked hosted lane reads
/// `parked`; a `files=none` kind `none` with `unread` counts.
#[test]
fn a_long_hosted_lane_s_stage_and_counters_are_read_through_the_provider() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let launched = clock::iso_utc(now - 12_601);
    let mut one = hosted_lane("KEN-1", "gh-1", "/remote/KEN-1");
    one["launched_at"] = json!(launched);
    let mut two = hosted_lane("KEN-2", "gh-2", "/remote/KEN-2");
    two["launched_at"] = json!(launched);
    let mut parked = hosted_lane("KEN-3", "gh-3", "/remote/KEN-3");
    parked["launched_at"] = json!(launched);
    parked["status"] = json!("parked");
    let mut cloud = cloud_lane("CC-4", "/a", now);
    cloud["launched_at"] = json!(launched);
    fleet.set_lanes(vec![one, two, parked, cloud]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (&format!("{PROVIDER} capabilities"), ok(SSH_LINE)),
        ("claude-cloud capabilities", ok(CLOUD_LINE)),
        ("status --item KEN-1 --harness claude", ok("running\n")),
        ("status --item KEN-2 --harness claude", ok("running\n")),
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/lane-status-KEN-1.md",
            ok("# Lane status\n- Step: dev round 1\n"),
        ),
        ("cat --item KEN-1 /remote/KEN-1/tmp/workflow-state-KEN-1.json", ok(COUNTS_STATE)),
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/validation-runs",
            ok("dev-validate-runs-v1\ndev-validate-implement\ndev-validate-fix\ndev-validate-restack-a\ndev-validate-restack-b\n"),
        ),
        ("cat --item KEN-2 /remote/KEN-2/tmp/lane-status-KEN-2.md", answer(1, "")),
        ("cat --item KEN-2 /remote/KEN-2/tmp/workflow-state-KEN-2.json", answer(1, "")),
        ("cat --item KEN-2 /remote/KEN-2/tmp/validation-runs", answer(1, "")),
    ]);
    world.plant_gh(json!({"repos/o/r/pulls?head=o:cc-4&state=open": {"body": []}}));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let produced = driver.pass(&state);
    let long: Vec<String> = event_lines(&produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT lane-long "))
        .collect();
    assert_eq!(
        long,
        vec![
            "EVENT lane-long KEN-1 age=12601 review_rounds=5 fix_receipts=3 validation_runs=4 restacks=4 repeated_class_rounds=1 stage=dev round 1",
            "EVENT lane-long KEN-2 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=unread",
            "EVENT lane-long KEN-3 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked",
            "EVENT lane-long CC-4 age=12601 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=none",
        ]
    );
    assert!(
        produced
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-long-rounds-unread item=KEN-2 cause=cat exit=1")),
        "{:?}",
        produced.failed
    );
    let log = world.host_log();
    assert!(
        !log.iter()
            .any(|l| l.contains("KEN-3") || l.contains("CC-4")),
        "a parked lane and a cloud lane fetch nothing: {log:?}"
    );
}

/// A hosted lane with a pane on the fleet server, its `.git` answered as
/// `git_answer` by the provider and its status verb as `exited`.
fn hosted_pane_lane(server: &Server, item: &str, window: &str, dir: &Path) -> (Value, String) {
    let pane = server.open_window(window, dir, "bash --norc --noprofile");
    let mut lane = hosted_lane(item, window, &format!("/remote/{item}"));
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    (lane, pane)
}

/// `oversee-watch:1477-1510` (`finished_hosted_lane_eligible`,
/// `close_finished_hosted_lane` at `:4857`), `:4796` (the status verb), the
/// case `744fd5727:skills/orch/tests/oversee_watch_hosted.sh` pinned as
/// `merged_gone_closes`. Defect: a merged hosted lane whose worktree its own
/// close-out removed left open on the host for a person to close, or a lane
/// still inside its merge close-out (its worktree standing) closed under
/// it. A hosted lane the provider's status verb reads exited is
/// `lane-exited` on the second pass; one whose item the GitHub duty read
/// merged and whose `.git` the host has not is closed through `lane-close`
/// then, `lane-closed` with its archive line under it; one whose worktree
/// stands, and one with no merged row, are not; the next pass says nothing.
#[test]
fn a_merged_hosted_lane_whose_worktree_the_host_has_not_is_closed_at_lane_exited_and_a_standing_one_is_not()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (one, _) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    let (two, _) = hosted_pane_lane(&server, "KEN-2", "gh-2", dir.path());
    let (three, _) = hosted_pane_lane(&server, "KEN-3", "gh-3", dir.path());
    fleet.set_lanes(vec![one.clone(), two.clone(), three.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        ("capabilities", ok(SSH_LINE)),
        ("status --item KEN-1 --harness claude", ok("exited\n")),
        ("status --item KEN-2 --harness claude", ok("exited\n")),
        ("status --item KEN-3 --harness claude", ok("exited\n")),
        ("cat --item KEN-1 /remote/KEN-1/.git", answer(2, "")),
        ("touch --item KEN-1", ok("")),
        (
            "cat --item KEN-2 /remote/KEN-2/.git",
            ok("gitdir: /x/.git/worktrees/KEN-2\n"),
        ),
    ]);
    world.plant_close(ok("kept=/archive/KEN-1\n"));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    for (item, key) in [("KEN-1", "o/r#7"), ("KEN-2", "o/r#8")] {
        driver.baseline.apply(Change::Set {
            kind: "merged".into(),
            identity: item.into(),
            value: key.into(),
        });
    }
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    assert!(world.close_log().is_empty());
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![
            "EVENT lane-exited gh-1",
            "EVENT lane-closed KEN-1",
            "kept=/archive/KEN-1",
            "EVENT lane-exited gh-2",
            "EVENT lane-exited gh-3",
        ]
    );
    assert_eq!(second.failed, None);
    assert_eq!(
        world.close_log(),
        vec![format!("--state-dir {} KEN-1", driver.state_dir.display())]
    );
    assert!(
        !world.host_log().iter().any(|l| l.contains("KEN-3 /remote")),
        "no merged row, no worktree read: {:?}",
        world.host_log()
    );
    let marker = hosted::close_marker_path(
        lanes::watch_state_dir(&driver.settings.claim_store),
        "KEN-1",
    );
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the close's marker stands"
    );
    // The record `lane-close` wrote, read on the next pass: the marker leaves.
    let mut closed = one;
    closed["status"] = json!("stopped");
    fleet.set_lanes(vec![closed, two, three]);
    let third = driver.pass(&fleet.read());
    assert!(event_lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(third.failed, None);
    assert_eq!(world.close_log().len(), 1);
    assert!(std::fs::metadata(&marker).is_err());
}

/// `oversee-watch:1490-1510`, `:5100` (the `close-pending` retry), the case
/// `744fd5727:skills/orch/tests/oversee_watch_hosted.sh` pinned as
/// `quota_defers_close`. Defect: a close the tracker's quota refusal
/// deferred never asked again, since its `lane-exited` line was already
/// reported, or asked again after the pane changed under it. The deferred
/// close keeps `close-pending` as `lane-exited|<pane key>`; the next pass,
/// its line still reported under that key, asks again and closes.
#[test]
fn a_finished_hosted_close_the_tracker_hold_deferred_is_retried_while_its_line_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (one, pane) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    fleet.set_lanes(vec![one.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        ("capabilities", ok(SSH_LINE)),
        ("status --item KEN-1 --harness claude", ok("exited\n")),
        ("cat --item KEN-1 /remote/KEN-1/.git", answer(2, "")),
        ("touch --item KEN-1", ok("")),
    ]);
    world.plant_close(json!({"exit": 1, "stderr": format!("{}\n", quota_receipt(1_800_007_200))}));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    assert_eq!(event_lines(&second), vec!["EVENT lane-exited gh-1"]);
    assert_eq!(second.failed, None);
    let pane_key = format!("{} {pane}", server.pid);
    assert_eq!(
        driver.baseline.get("close-pending", "gh-1"),
        Some(format!("lane-exited|{pane_key}").as_str())
    );
    assert_eq!(world.close_log().len(), 1);
    world.plant_close(ok("kept=/archive/KEN-1\n"));
    let third = driver.pass(&state);
    assert_eq!(
        lines(&third),
        vec!["EVENT lane-closed KEN-1", "kept=/archive/KEN-1"]
    );
    assert_eq!(driver.baseline.get("close-pending", "gh-1"), None);
    assert_eq!(world.close_log().len(), 2);
    let mut closed = one;
    closed["status"] = json!("stopped");
    fleet.set_lanes(vec![closed]);
    let fourth = driver.pass(&fleet.read());
    assert!(lines(&fourth).is_empty(), "{:?}", lines(&fourth));
    assert_eq!(fourth.failed, None);
    assert_eq!(world.close_log().len(), 2);
}

/// `oversee-watch:4727-4735` (`wall_route`, the hosted stop), the cases
/// `744fd5727:skills/orch/tests/oversee_watch_wall_relaunch.sh` pinned as
/// `hosted_stop` and `hosted_stop_failed`. Defect: a walled hosted lane's
/// harness left running on its host under the successor the relaunch opens,
/// or a stop the provider did not confirm followed by a relaunch anyway. A
/// walled lane whose kind declares a local pane has its harness stopped
/// through `lane-host stop --item --harness` under the record's host before
/// the relaunch starts; a stop the provider refuses, or answers with exit 0
/// and a line that is not `stopped item=ITEM processes=N`
/// (`lane_recovery_stop_confirmed`'s second arm), leaves the wall to the
/// overseer with `wall-relaunch-refused reason=stop-failed` and the status
/// under the line, and nothing starts.
#[test]
fn a_walled_hosted_pane_local_lane_is_stopped_through_the_provider_before_its_relaunch() {
    for (stop, refused) in [
        (ok("stopped item=KEN-4 processes=1\n"), None),
        (
            json!({"exit": 4, "stderr": "lane-host: stop-worktree-removed item=KEN-4\n"}),
            Some("exit=4"),
        ),
        (ok("stopped item=KEN-4\n"), Some("exit=0")),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let mut record = relaunchable(
            lane_record(
                "KEN-4",
                "gh-4",
                "claude",
                &server,
                &pane,
                Some(&identity),
                dir.path(),
            ),
            dir.path(),
        );
        record["host"] = json!(PROVIDER);
        record["kind"] = json!("ssh");
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        let world = HostedWorld::new(dir.path());
        let status_file = format!(
            "cat --item KEN-4 {}/tmp/lane-status-KEN-4.md",
            dir.path().display()
        );
        world.plant_host(&[
            ("capabilities", ok(&format!("{SSH_LINE}\tpane=local"))),
            ("status --item KEN-4 --harness claude", ok("running\n")),
            (status_file.as_str(), ok("Step: start\n")),
            ("stop --item KEN-4 --harness claude", stop),
        ]);
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = world.scripts.clone();
        driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
        let produced = driver.pass(&state);
        let stop_line = "ORCH_LANE_HOST=/w/provider stop --item KEN-4 --harness claude".to_owned();
        assert!(
            world.host_log().contains(&stop_line),
            "{:?}",
            world.host_log()
        );
        let started = driver.relaunches.borrow();
        if let Some(status) = refused {
            assert!(
                lines(&produced).contains(&format!(
                    "wall-relaunch-refused lane=gh-4 reason=stop-failed {status}"
                )),
                "{:?}",
                lines(&produced)
            );
            assert!(
                event_lines(&produced)
                    .iter()
                    .any(|l| l.starts_with("EVENT usage-limit gh-4 ")),
                "{:?}",
                lines(&produced)
            );
            assert!(started.is_empty(), "nothing starts on a failed stop");
        } else {
            assert!(
                event_lines(&produced).contains(
                    &"EVENT lane-relaunched KEN-4 lane=/home/me/.bclaude from=/home/me/.eclaude"
                        .to_owned()
                ),
                "{:?}",
                lines(&produced)
            );
            assert_eq!(started.len(), 1);
            let request: Value = serde_json::from_str(
                &std::fs::read_to_string(started[0].args.last().unwrap()).unwrap(),
            )
            .unwrap();
            assert_eq!(request["host"], PROVIDER, "{request}");
            assert_eq!(request["kind"], "ssh", "{request}");
        }
    }
}

/// `oversee-watch:2148` (`check_prepare`) over `PREPARE_ROWS_FILTER`
/// (`:859`), the cases `744fd5727:skills/orch/tests/oversee_watch_prepare.sh`
/// pinned as `stuck`, `ready`, `failed`. Defect: a hosted launch's
/// background preparation that never ends left unsaid, or said on every
/// pass; a preparation that ended never said ready or failed. A `prepare`
/// record past `ORCH_WATCH_PREPARE_SECS` while `preparing` is
/// `lane-prepare-stuck` with its age and log once, one whose lane runs
/// `lane-ready` once, one whose lane stopped with a reason
/// `lane-prepare-failed` with the reason and log once; the next pass says
/// nothing, and a record that leaves takes its row.
#[test]
fn the_prepare_records_are_said_once_per_key() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let prepare = |item: &str, status: &str, since: u64, log: &str, reason: Option<&str>| {
        let mut record = json!({"since": clock::iso_utc(since), "log": log, "pid": 7});
        if let Some(reason) = reason {
            record["reason"] = json!(reason);
        }
        json!({"item": item, "harness": "claude", "host": PROVIDER, "kind": "ssh", "status": status, "prepare": record})
    };
    let lanes = vec![
        prepare("KEN-1", "preparing", now - 1801, "/l1", None),
        prepare("KEN-2", "running", now - 10, "/l2", None),
        prepare("KEN-3", "stopped", now - 20, "/l3", Some("create-failed")),
        prepare("KEN-4", "preparing", now - 100, "/l4", None),
    ];
    fleet.set_lanes(lanes.clone());
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        ("capabilities", ok(SSH_LINE)),
        ("status --item KEN-1 --harness claude", ok("running\n")),
        ("status --item KEN-2 --harness claude", ok("running\n")),
        ("status --item KEN-4 --harness claude", ok("running\n")),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let prepare_lines = |produced: &Produced| -> Vec<String> {
        event_lines(produced)
            .into_iter()
            .filter(|l| l.starts_with("EVENT lane-prepare") || l.starts_with("EVENT lane-ready "))
            .collect()
    };
    let first = driver.pass(&state);
    assert_eq!(
        prepare_lines(&first),
        vec![
            "EVENT lane-prepare-stuck KEN-1 age=1801s log=/l1",
            "EVENT lane-ready KEN-2",
            "EVENT lane-prepare-failed KEN-3 reason=create-failed log=/l3",
        ]
    );
    assert_eq!(first.failed, None);
    assert_eq!(
        driver.baseline.get("lane-prepare", "KEN-1"),
        Some(format!("{}|stuck", now - 1801).as_str())
    );
    assert_eq!(driver.baseline.get("lane-prepare", "KEN-4"), None);
    let second = driver.pass(&state);
    assert!(prepare_lines(&second).is_empty(), "{:?}", lines(&second));
    fleet.set_lanes(lanes[..2].to_vec());
    let third = driver.pass(&fleet.read());
    assert!(prepare_lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(
        driver.baseline.get("lane-prepare", "KEN-3"),
        None,
        "the row left with the record"
    );
    assert_eq!(
        driver.baseline.get("lane-prepare", "KEN-2"),
        Some(format!("{}|ready", now - 10).as_str())
    );
}
