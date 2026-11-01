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
//! and the mark line's payload.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server, write the records they plant and read the panes they opened"
)]

#[path = "support.rs"]
mod support;

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, Pane, PaneFields};
use agent_runtime::observe::{self, ProcessReading};
use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, LaneVerdict};
use jiff::tz::TimeZone;
use orch_runtime::ops::wall::{self, AccountWall, RecordWallPauses};
use orch_runtime::ops::{self, RequestTransfer};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings, Succession};
use orch_runtime::state::{self, FleetState, Locking, Record, TransferCause};
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
            scripts: Path::new("/nonexistent"),
            route: &route,
            wall_pauses: &wall_pauses,
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

/// `oversee-watch:4885-4906`; `tests/oversee_watch_usage_limit.sh` § SURFACE 2.
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

/// A lane record carrying what the relaunch needs (`lib/lane-relaunch.sh`,
/// `lane_recovery_args`): the model the pick is asked for and the
/// launcher's recorded choices.
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
/// `tests/oversee_watch_wall_relaunch.sh` pins. Defect: the relaunch
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
        assert_eq!(
            relaunch.args,
            vec![
                "/nonexistent/open-terminal",
                "--tmux",
                "--relaunch",
                "--continue-resume",
                "--harness",
                "claude",
                "--launch-flags",
                "--model opus",
                "--state-dir",
                &driver.state_dir.display().to_string(),
                "--host",
                "local",
                "--tracker",
                "",
                "--lane-refresh",
                "--lane",
                "/home/me/.bclaude",
                "KEN-4",
            ]
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

/// The item state `tests/oversee_watch_start_stall.sh` plants for its
/// `separate_counts` row.
const COUNTS_STATE: &str = r#"{"first_panel":{},"rereview_cycles":1,"cycles":7,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"implement"},{"kind":"fix"},{"kind":"fix"},{"kind":"fix"},{"kind":"review"}],"validate_rounds":[{"kind":"implement"},{"kind":"fix"},{"kind":"restack"},{"kind":"restack"}],"restack_skips":[{},{}],"restacks":4}"#;

/// `lib/watch-host-kinds.sh:446` (`check_lane_long`), the rows
/// `tests/oversee_watch_start_stall.sh` pins (`separate_counts`, `parked`,
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
/// cannot settle, or its rows read in a way the legacy did not. The rows
/// judge: a Stop row is idle on the second pass with the pane's tail under
/// it; a later Stop row is news again; an error Stop whose message is the
/// account's limit is `usage-limit` with the harness's own message under
/// it; no rows at all settles nothing.
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
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"at\":1}\n",
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
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"at\":2}\n",
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
            },
            &self.slot,
        );
        apply(&mut self.baseline, &produced);
        self.now += 240;
        produced
    }
}

fn below(_: &Path, _: Option<Harness>) -> Result<Marks, String> {
    Marks::parse("oversee-succeed: account-below-mark kind=headroom").ok_or_default()
}

trait OrDefault<T> {
    fn ok_or_default(self) -> Result<T, String>;
}

impl<T> OrDefault<T> for Option<T> {
    fn ok_or_default(self) -> Result<T, String> {
        self.ok_or_else(|| "unparsed".to_owned())
    }
}

fn reached(_: &Path, _: Option<Harness>) -> Result<Marks, String> {
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
fn reached_off(_: &Path, _: Option<Harness>) -> Result<Marks, String> {
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
/// `tests/oversee_watch_overseer_marks.sh` pins. Defect: the mark line out
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
