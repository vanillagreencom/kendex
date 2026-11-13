//! The observation duty: the lane classifier over three-valued reads of
//! real panes on a private tmux server, the wall rule keyed to the live
//! identity, a Pi lane's rows, the overseer's one verdict shared with the
//! mail gate, the death counted on two passes and the succession asked for
//! through the one request, the stray sweep, the reset the banner names, the
//! account and lane wall records, the wall relaunch through the route,
//! `lane-long`'s counters, the mark line's payload, and the hosted readings
//! over the `lane-host`, runtime-entry and `gh` fixtures linked into a row's
//! world. The rows drive the duties directly with the readers the
//! production duty injects, applying each pass's changes to the baseline as
//! the runner's commit would.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server, write the records they plant and read the panes they opened"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::controller::TransferCause;
use agent_runtime::record::{self, Locking};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::accounts::Roster;
use agent_runtime::accounts::walk::{Chosen, WalkAnswer, WalkRequest, Walked};
use agent_runtime::accounts::wall::{self as account_wall, AccountWall};
use agent_runtime::clock;
use agent_runtime::controller::transition::{DeathCause, RequestTransfer};
use agent_runtime::controller::views::{Caller, MarkKind};
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, Pane, PaneState};
use agent_runtime::observe::{self, ProcessReading};
use agent_runtime::process::{Identity, Memory};
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, LaneVerdict};
use agent_runtime::settings::{Roots, Succession};
use jiff::tz::TimeZone;
use orch_runtime::ops;
use orch_runtime::ops::wall::{self, RecordWallPauses};
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::state::{self, FleetState, Record};
use orch_runtime::watch::context;
use orch_runtime::watch::hosted;
use orch_runtime::watch::lanes::{self, Readers, Relaunch, WallRoute, WindowRow};
use orch_runtime::watch::overseer::{
    self, ContextRead, Judges, MarkKey, Marks, Pick, Slot, Source, Verdict,
};
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
    let accounts = dir.join("tmp/oversee-watch");
    let environment: Vec<(OsString, OsString)> = [(
        OsString::from("AGENT_RUNTIME_ACCOUNT_STATE_DIR"),
        accounts.into_os_string(),
    )]
    .into_iter()
    .chain(
        extra
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v))),
    )
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

/// The production pane and window readers with the test's own server as
/// the one the fleet's reach names, where a pass is given none.
struct TestReaders {
    socket: PathBuf,
}

impl TestReaders {
    fn pane(
        &self,
        sockets: &[PathBuf],
        server: u64,
        start: Option<u64>,
        pane: &str,
    ) -> Reading<PaneState> {
        let mut sockets = sockets.to_vec();
        if !sockets.contains(&self.socket) {
            sockets.push(self.socket.clone());
        }
        lanes::pane_at(&sockets, server, start, pane)
    }

    fn windows(&self, recorded: Option<&Path>, session: &str) -> Reading<(u64, Vec<WindowRow>)> {
        lanes::windows_at(recorded.unwrap_or(&self.socket), session)
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
        self.runner.state_dir().join(record::FLEET_FILE_NAME)
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
    /// The account a Copilot record naming none runs on.
    copilot_home: Option<PathBuf>,
}

impl LaneDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let pick = |_: Harness, _: &str, _: &str| self.pick.clone();
        let start = |r: &Relaunch| {
            self.relaunches.borrow_mut().push(r.clone());
            Ok(())
        };
        let route = WallRoute {
            relaunch: self.settings.watch.get().unwrap().wall_relaunch,
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
            project: &self.settings.roots.project,
            reads: &self.settings.reads,
        };
        let env = agent_runtime::journal::Env {
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
            settings: &self.settings.watch.get().unwrap(),
            now: self.now,
            session: Some(&self.session),
            // The session's first window is the runner's own pane.
            own_panes: &["%0".to_owned()],
            state_dir: &self.state_dir,
            claim_store: &self.settings.claim_store,
            account_state: &self.settings.account_state,
            scripts: &self.scripts,
            route: &route,
            wall_pauses: &wall_pauses,
            hosted: &reads,
            copilot_home: self.copilot_home.as_deref(),
            server: None,
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
        let pane_read =
            |r: &[PathBuf], s: u64, start: Option<u64>, p: &str| $readers.pane(r, s, start, p);
        let windows_read = |r: Option<&Path>, session: &str| $readers.windows(r, session);
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
            copilot_home: None,
        };
    };
}

/// A pane on a server that ended, the pane in it a bash shell: the server's
/// pid and start, and the pane id, once the pid no longer runs.
fn gone_server(dir: &Path) -> (u32, u64, String) {
    let root = dir.join("gone");
    std::fs::create_dir_all(&root).unwrap();
    let gone = Server::start(&root, "fleet");
    let pane = gone.open_window("gone", &root, "bash --norc --noprofile");
    let (pid, start) = (gone.pid, gone.start);
    drop(gone);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while live(pid) {
        assert!(
            std::time::Instant::now() < deadline,
            "the server never ended"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    (pid, start, pane)
}

/// The pane gone from its server, its server ended, and its server's pid
/// answering under another start (a reused pid) are each the window gone.
#[test]
fn a_recorded_pane_the_server_has_not_is_window_gone_on_every_pass() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (gone_pid, gone_start, gone_pane) = gone_server(dir.path());
    let mut ended = lane_record(
        "KEN-2",
        "gh-2",
        "claude",
        &server,
        &gone_pane,
        None,
        dir.path(),
    );
    ended["launch"]["server"] = json!(gone_pid);
    ended["launch"]["server_start"] = json!(gone_start);
    let shell = server.open_window("gh-3", dir.path(), "bash --norc --noprofile");
    let mut reused = lane_record("KEN-3", "gh-3", "claude", &server, &shell, None, dir.path());
    reused["launch"]["server_start"] = json!(server.start - 1);
    fleet.set_lanes(vec![
        lane_record("KEN-1", "gh-1", "claude", &server, "%999", None, dir.path()),
        ended,
        reused,
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    for _ in 0..2 {
        let produced = driver.pass(&state);
        assert_eq!(
            event_lines(&produced),
            vec![
                "EVENT window-gone gh-1",
                "EVENT window-gone gh-2",
                "EVENT window-gone gh-3"
            ]
        );
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

/// A live harness can hold a shell in the pane's foreground for a pass, so
/// a pane holding nothing but shells is `lane-exited` on the second
/// consecutive pass alone, with its closing lines under it, and a third
/// pass says nothing; so is a pane its server keeps dead after its process
/// exited. A pane this reader cannot read is never that,
/// whatever passes go by: its own line once, with the cause.
#[test]
fn a_lane_exits_on_the_second_pass_and_an_unreadable_one_never_does() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    // A live process no socket answers for: its server cannot be told from
    // gone.
    let mut unreadable = lane_record("KEN-3", "gh-3", "claude", &server, &pane, None, dir.path());
    unreadable["launch"]["server"] = json!(std::process::id());
    let dead = server.open_kept_dead("gh-4", dir.path());
    fleet.set_lanes(vec![
        lane_record("KEN-2", "gh-2", "claude", &server, &pane, None, dir.path()),
        unreadable,
        lane_record("KEN-4", "gh-4", "claude", &server, &dead, None, dir.path()),
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
    assert_eq!(
        driver.baseline.get("lane-exited", "gh-4"),
        Some(format!("{} {dead}", server.pid).as_str())
    );
    let second = driver.pass(&state);
    assert_eq!(
        event_lines(&second),
        vec!["EVENT lane-exited gh-2", "EVENT lane-exited gh-4"],
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

/// The banner below the live composer, with the recorded identity holding
/// the pane, is `usage-limit` once with the account and the banner window
/// under it, its row keyed to the identity; a row whose first sighting
/// predates the live process's start reports nothing, on every pass, while
/// the screen stands.
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
    let path = account_wall::account_wall_path(
        &settings.account_state.get().unwrap(),
        "/home/me/.eclaude",
    );
    let text = std::fs::read_to_string(path).ok()?;
    Some(serde_json::from_str(&text).unwrap())
}

/// The clock the rows start at, as the fleet record writes a time.
const NOW_ISO: &str = "2027-01-15T08:00:00Z";

/// The wall judged current for the live identity writes the account record
/// with the reset the banner names and its first sighting, kept on every
/// later pass, and opens `walled.at` on the lane record
/// at the first sighting; the same banner re-stamped before the live
/// process's start, under another identity, writes no record on two passes
/// and closes the standing wall into `pauses`.
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
    let recorded = Some(AccountWall {
        config_dir: "/home/me/.eclaude".to_owned(),
        resets_at: BANNER_RESET,
        seen_at: Some(1_800_000_000),
    });
    assert_eq!(wall_record(&driver.settings), recorded);
    let opened = fleet.runner.fleet();
    assert_eq!(opened["lanes"][0]["walled"], json!({"at": NOW_ISO}));
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    assert_eq!(
        wall_record(&driver.settings),
        recorded,
        "a later pass over the same banner keeps its first sighting"
    );
    assert_eq!(
        fleet.runner.fleet()["lanes"][0]["walled"],
        json!({"at": NOW_ISO}),
        "the standing wall is kept while the banner stands"
    );
    // The same banner first seen before this process started: an earlier
    // process's screen, judged under its identity.
    std::fs::remove_file(account_wall::account_wall_path(
        &driver.settings.account_state.get().unwrap(),
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

/// The reset is pinned to the first sighting; once the clock passes it the
/// lane is `usage-limit-passed` once more, with the banner window under it,
/// and no account record is renewed for a reset behind the clock.
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
    std::fs::remove_file(account_wall::account_wall_path(
        &driver.settings.account_state.get().unwrap(),
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
/// asked for, the class and reason the relaunch keeps, and the checkout,
/// session and refresh word an earlier launcher recorded under `recovery`.
fn relaunchable(mut record: Value, cwd: &Path) -> Value {
    record["model"] = json!("opus");
    record["class"] = json!(CLASS);
    record["class_reason"] = json!(CLASS_REASON);
    record["recovery"] = json!({
        "cwd": cwd.display().to_string(),
        "flags": "--model opus",
        "refresh": true,
        "session": "fleet",
    });
    record
}

/// Under `auto` (the default) a walled lane whose record names its model is
/// relaunched once onto the picked account through the route: the marker
/// for the outcome reader first, the record's own launcher line with
/// `--lane` the picked account, `lane-relaunched` with its log, and nothing
/// on the next pass; under `ask` the wall is `usage-limit` with the pick's
/// answer under it and nothing starts.
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
        let stem = driver.state_dir.join("wall-relaunch-KEN-4");
        let request_file = PathBuf::from(format!("{}.json", stem.display()));
        let close_file = PathBuf::from(format!("{}.close.json", stem.display()));
        let brief_file = PathBuf::from(format!("{}.md", stem.display()));
        assert_eq!(
            relaunch.args,
            vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "\"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$3\"; rc=$?; [ \"$rc\" -eq 0 ] || [ \"$rc\" -eq 75 ] || exit \"$rc\"; exec \"$1\" --state-dir \"$2\" op --fleet --effect-exit --request \"$4\"".to_owned(),
                "wall-relaunch".to_owned(),
                "/nonexistent/orch-runtime".to_owned(),
                driver.state_dir.display().to_string(),
                close_file.display().to_string(),
                request_file.display().to_string(),
            ]
        );
        let retire: Value =
            serde_json::from_str(&std::fs::read_to_string(&close_file).unwrap()).unwrap();
        assert_eq!(
            retire,
            json!({
                "op": "close-owned-resources",
                "item": "KEN-4",
                "no_landing": {"reason": "usage-limit", "source": "wall-route"},
            })
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
                "brief_file": brief_file.display().to_string(),
                "model": "opus",
            })
        );
        let brief = std::fs::read_to_string(&brief_file).unwrap();
        assert!(
            brief.starts_with("/orch start KEN-4 This is an unattended orch lane")
                && brief.ends_with("never as a question in chat. Never end a turn waiting on the person, and end none before a lane-mail ask or notice, or the lane status file, says where the work stands. Send a notice only when the work changed since your last notice, with a new head, PR, verdict, blocker, request or finish. A wait that continues updates the lane status file only. Where you would stop to ask, read lane-mail inbox and continue the workflow.\n"),
            "the start brief closed by the unattended words: {brief:?}"
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

/// A walled lane whose record names an empty session is relaunched under
/// the watch's session, as one whose record names none.
#[test]
fn a_walled_lanes_relaunch_under_an_empty_recorded_session_runs_under_the_watchs() {
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
    record["recovery"]["session"] = json!("");
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first).first().map(String::as_str),
        Some("EVENT lane-relaunched KEN-4 lane=/home/me/.bclaude from=/home/me/.eclaude"),
        "{:?}",
        lines(&first)
    );
    let started = driver.relaunches.borrow();
    assert_eq!(started.len(), 1);
    assert_eq!(started[0].session, server.session);
}

/// A walled lane whose record names no class, or no reason for it, is
/// refused before anything stops: the relaunch keeps the record's pair, so
/// its launch would refuse once the close had retired the walled harness.
/// The refusal is said under the wall after the pick's line; no request,
/// brief or marker is written and nothing starts.
#[test]
fn a_walled_lane_naming_no_class_or_reason_is_refused_before_anything_stops() {
    type Plant = fn(&mut Value);
    let rows: [(&str, Plant); 2] = [
        ("no class", |record| {
            record.as_object_mut().unwrap().remove("class");
        }),
        ("no reason", |record| {
            record.as_object_mut().unwrap().remove("class_reason");
        }),
    ];
    for (name, plant) in rows {
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
        plant(&mut record);
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
        let first = driver.pass(&state);
        assert_eq!(
            lines(&first),
            vec![
                "EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z".to_owned(),
                "pick lane=/home/me/.bclaude".to_owned(),
                "wall-relaunch-refused lane=gh-4 reason=context-unavailable cause=class-unrecorded"
                    .to_owned(),
                "⏺ Working through the queue.".to_owned(),
                BANNER.to_owned(),
                "Run /usage-credits to raise it".to_owned(),
                "❯\u{a0}".to_owned(),
            ],
            "{name}"
        );
        assert!(
            driver.relaunches.borrow().is_empty(),
            "{name}: nothing starts"
        );
        for suffix in ["md", "close.json", "json"] {
            let file = driver
                .state_dir
                .join(format!("wall-relaunch-KEN-4.{suffix}"));
            assert!(!file.exists(), "{name}: {}", file.display());
        }
        let marker = driver
            .settings
            .claim_store
            .parent()
            .unwrap()
            .join("wall-relaunch.gh-4");
        assert!(!marker.exists(), "{name}: {}", marker.display());
    }
}

/// A `claude` the launch rows start that hits a weekly wall: it draws
/// Claude's composer, echoes the first turn it reads, then draws the banner
/// and the composer again and holds; the path to run it as.
fn walled_stub(dir: &Path) -> PathBuf {
    let bin = dir.join("walled");
    std::fs::create_dir_all(&bin).unwrap();
    let path = bin.join("claude");
    write_executable(
        &path,
        format!(
            "#!/bin/bash\nprintf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\nprintf '  ? for shortcuts\\n'\nIFS= read -r line\nprintf '\\xe2\\x9d\\xaf %s\\n' \"$line\"\nprintf '%s\\n' '⏺ Working through the queue.' '{}' 'Run /usage-credits to raise it'\nprintf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\nwhile IFS= read -r _line; do :; done\n",
            BANNER.replace('\'', "'\\''")
        ),
    );
    path
}

/// The launch record the recording stub writes in `cwd`, read once it
/// stands: the stub writes it from its own process after the launch answers.
fn launch_record_of(cwd: &Path) -> Value {
    let path = cwd.join("launch-record.json");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(record) = serde_json::from_str::<Value>(&text)
        {
            return record;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "no launch record at {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A checkout at `path` for a launch to run in, made by `git` under the
/// row's own isolation: a clone of the fleet's repository, its origin and
/// the fleet's checkout's one, since a launch from a foreign repository is
/// refused.
fn init_checkout(fleet: &Fleet, path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    let git = || {
        let mut git = program("git");
        git.env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1");
        git
    };
    let out = git()
        .args([
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            "init",
            "-q",
        ])
        .arg(path)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    fleet_origin(fleet, path);
}

/// The fleet's origin on `checkout` and on the fleet's own checkout, under
/// the row's own isolation: the lane's checkout is then a clone of the
/// fleet's repository, which a launch or relaunch is bound to. A relaunch
/// runs its launch from the lane's checkout, which installs the github
/// package whose resolver names both repositories.
fn fleet_origin(fleet: &Fleet, checkout: &Path) {
    github_skill_under(checkout);
    for repository in [checkout, fleet.runner.state_dir()] {
        let out = program("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .arg("-C")
            .arg(repository)
            .args([
                "config",
                "remote.origin.url",
                "https://github.com/o/fleet.git",
            ])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
}

/// Through the real `launch-lane` and the real duty: the record of a lane
/// launched with `--permission-mode dontAsk` carries the choice, the wall
/// relaunch's request carries it, and the replacement the request starts
/// through the real entry runs with the word and no bypass word; a released
/// record, planted as `main` wrote it, carries the choice in
/// `recovery.flags`, and its request carries the same word. A prompting
/// choice no launch line carries, `--permission-mode plan`, never
/// relaunches under the bypass default: two released records carrying it
/// in the two-word and the `FLAG=VALUE` spelling are refused
/// `permission-choice-unrepresentable` before any request or stop, where
/// the `dontAsk` records relaunch.
#[test]
fn a_walled_lanes_relaunch_keeps_its_permission_choice() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let work = root.join("KEN-5");
    init_checkout(&fleet, &work);
    let spent = root.join("eclaude");
    let picked = root.join("bclaude");
    for account in [&spent, &picked] {
        std::fs::create_dir_all(account).unwrap();
    }
    let binaries = format!("claude={}", walled_stub(&root).display());
    let request = json!({
        "op": "launch-lane",
        "item": "KEN-5",
        "harness": "claude",
        "mail_root": work.display().to_string(),
        "account": spent.display().to_string(),
        "model": "opus",
        "effort": "high",
        "class": CLASS,
        "class_reason": CLASS_REASON,
        "permission": "--permission-mode dontAsk",
    });
    let report = effect_report(&fleet.runner.op_fleet_env(
        &request,
        &[("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str())],
    ));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let runtime = fleet.runner.fleet()["lanes"][0].clone();
    let walled = runtime["launch"]["pane"].as_str().unwrap();
    server.send_line(walled, "work through the queue");
    await_drawn(&server, walled, "weekly limit");
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-6", BANNER);
    let mut released = relaunchable(
        lane_record(
            "KEN-6",
            "gh-6",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ),
        dir.path(),
    );
    // A released record names its model and effort, in its fields and in
    // the flags `main` recorded as given: its launch refused a lane on an
    // account without either.
    released["effort"] = json!("high");
    released["recovery"]["flags"] = json!("--model opus --effort high --permission-mode dontAsk");
    let mut lanes = vec![runtime, released];
    for (item, name, flags) in [
        (
            "KEN-7",
            "gh-7",
            "--model opus --effort high --permission-mode plan",
        ),
        (
            "KEN-8",
            "gh-8",
            "--model opus --effort high --permission-mode=plan",
        ),
    ] {
        let own = root.join(name);
        std::fs::create_dir_all(&own).unwrap();
        let (pane, identity) = walled_claude(&server, &own, name, BANNER);
        let mut prompting = relaunchable(
            lane_record(item, name, "claude", &server, &pane, Some(&identity), &own),
            &own,
        );
        prompting["effort"] = json!("high");
        prompting["recovery"]["flags"] = json!(flags);
        lanes.push(prompting);
    }
    fleet.set_lanes(lanes);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    driver.pick = Pick::Lane(picked.display().to_string());
    let scripts = root.join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
    driver.scripts = scripts;
    let produced = driver.pass(&state);
    let relaunched: Vec<String> = event_lines(&produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT lane-relaunched "))
        .collect();
    assert_eq!(
        relaunched,
        vec![
            format!(
                "EVENT lane-relaunched KEN-5 lane={} from={}",
                picked.display(),
                spent.display()
            ),
            format!(
                "EVENT lane-relaunched KEN-6 lane={} from=/home/me/.eclaude",
                picked.display()
            ),
        ],
        "{:?}",
        lines(&produced)
    );
    for (item, name) in [("KEN-7", "gh-7"), ("KEN-8", "gh-8")] {
        let refusal = format!(
            "wall-relaunch-refused lane={name} reason=context-unavailable cause=permission-choice-unrepresentable"
        );
        assert!(
            lines(&produced).contains(&refusal),
            "{refusal}: {:?}",
            lines(&produced)
        );
        for suffix in ["md", "close.json", "json"] {
            let file = driver
                .state_dir
                .join(format!("wall-relaunch-{item}.{suffix}"));
            assert!(
                !file.exists(),
                "a request for a refused lane: {}",
                file.display()
            );
        }
    }
    let started = driver.relaunches.borrow();
    assert_eq!(started.len(), 2);
    for relaunch in started.iter() {
        let request: Value =
            serde_json::from_str(&std::fs::read_to_string(&relaunch.args[7]).unwrap()).unwrap();
        assert_eq!(
            request["permission"],
            json!("--permission-mode dontAsk"),
            "{}: {request}",
            relaunch.item
        );
    }
    // The runtime record's two requests through the real entry, as the
    // route starts them: the walled predecessor retired, the replacement
    // started on the picked account with the kept choice.
    let chain = &started[0];
    assert_eq!(chain.item, "KEN-5");
    let mut command = program("sh");
    fleet.runner.apply_env(&mut command);
    let out = command
        .args(&chain.args[1..])
        .current_dir(&chain.cwd)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let replacement = launch_record_of(&work);
    let argv: Vec<&str> = replacement["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap())
        .collect();
    assert!(
        argv.windows(2)
            .any(|w| w == ["--permission-mode", "dontAsk"]),
        "the kept choice on the replacement's line: {argv:?}"
    );
    assert!(
        !argv.contains(&"--dangerously-skip-permissions"),
        "the bypass default on the replacement's line: {argv:?}"
    );
    assert_eq!(
        replacement["env"]["CLAUDE_CONFIG_DIR"],
        json!(picked.display().to_string()),
        "{replacement}"
    );
    let lane = fleet.runner.fleet()["lanes"][0].clone();
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(
        lane["account"],
        json!(picked.display().to_string()),
        "{lane}"
    );
}

/// The item state of a running lane whose counts the rows read.
const COUNTS_STATE: &str = r#"{"first_panel":{},"rereview_cycles":1,"cycles":7,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"implement"},{"kind":"fix"},{"kind":"fix"},{"kind":"fix"},{"kind":"review"}],"validate_rounds":[{"kind":"implement"},{"kind":"fix"},{"kind":"restack"},{"kind":"restack"}],"restack_skips":[{},{}],"restacks":4}"#;

/// A running lane `ORCH_WATCH_LANE_AGE_SECS` past its launch is `lane-long`
/// once per age interval with the counts of its worktree's workflow state
/// and run index and the `Step` line of its status file; a parked lane
/// reads every count `unread` and `stage=parked`.
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

/// Codex's capacity refusal above the live composer is no finished turn: it
/// is `model-capacity` once, with no tail, and the next pass says nothing.
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

/// A Pi lane is judged from its rows, since its carrier's drawing cannot
/// settle it: a Stop row is idle on the second pass with the pane's tail
/// under it and no `cause=` for the ordinary end (`stop_reason=stop`, which
/// the writer copies from every finished Pi turn); a later Stop row is news
/// again; an error Stop whose message is the account's limit is
/// `usage-limit` with the harness's own message under it; no rows at all
/// settles nothing.
#[test]
fn a_pi_lane_is_judged_from_its_rows_as_the_released_watch_judged_it() {
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

/// A turn the output limit cut (`stop_reason=length`) is no finished round,
/// so the idle line carries the stop reason: a Stop row with a
/// `stop_reason` that is not the harness's ordinary end and no limit banner
/// is `idle-after-return <lane> cause=<word>` once, with the pane's tail
/// under it; an error that is no limit carries `cause=error`. The ordinary
/// end `stop` is
/// `a_pi_lane_is_judged_from_its_rows_as_the_released_watch_judged_it`.
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

/// A window of the fleet session that no lane, controller record, open
/// intent or receipt names is `stray-window` once; it stands after, and a
/// recorded window is never one.
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
        receipts.join("launch-session:KEN-8:1-1.pane"),
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

/// The overseer duty's driver: the pass over the fleet with planted judge
/// answers and a recording transfer.
struct OverseerDriver<'a> {
    readers: Readers<'a>,
    judges: Judges<'a>,
    settings: Settings,
    baseline: Baseline,
    slot: Slot,
    now: u64,
    transfers: &'a RefCell<Vec<RequestTransfer>>,
    /// The overseer's context record, where a row plants one.
    context_record: Option<PathBuf>,
    /// The owner's alert for a standing gap or a death, by notice file.
    alert: &'a dyn Fn(&str, &str) -> Result<(), String>,
    /// `AGENT_RUNTIME_CONTROLLER_SUCCESSION`, on unless a row turns it off.
    succession: Succession,
}

impl OverseerDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let transfer = |request: RequestTransfer| {
            let mut asked = self.transfers.borrow_mut();
            asked.push(request);
            Ok(format!("request-transfer:overseer:{}", asked.len()))
        };
        let produced = overseer::observe(
            &overseer::Pass {
                fleet,
                readers: &self.readers,
                judges: &self.judges,
                baseline: &self.baseline,
                settings: &self.settings.watch.get().unwrap(),
                succession: self.succession,
                preference: self
                    .settings
                    .controller
                    .preference_set
                    .then_some(self.settings.controller.preference.as_str()),
                now: self.now,
                transfer: &transfer,
                context_record: self.context_record.as_deref(),
                alert: self.alert,
                server: None,
            },
            &self.slot,
        );
        apply(&mut self.baseline, &produced);
        self.now += 240;
        produced
    }
}

/// A judge's answer as a row plants it.
fn marks(key: MarkKey, value: &str, mark: &str, succession: Succession, account: &str) -> Marks {
    Marks {
        key,
        value: value.to_owned(),
        mark: mark.to_owned(),
        succession,
        account: account.to_owned(),
        resets: String::new(),
        status: String::new(),
        reserve_only: false,
        reason: String::new(),
        headroom: String::new(),
        context: ContextRead::Unjudged,
        decision: None,
    }
}

fn below(_: &Caller, _: Option<&str>) -> Result<Marks, String> {
    Ok(marks(MarkKey::Below, "", "", Succession::On, ""))
}

/// The owner's alert of a row that judges none: a death's is taken, which
/// the death rows of their own judge; no gap stands two passes.
fn no_alert(_: &str, text: &str) -> Result<(), String> {
    assert!(
        text.starts_with("overseer-dead:"),
        "no gap stood two passes: {text}"
    );
    Ok(())
}

fn reached(_: &Caller, _: Option<&str>) -> Result<Marks, String> {
    Ok(marks(
        MarkKey::Reached(MarkKind::Headroom),
        "50",
        "5",
        Succession::On,
        "/home/me/.eclaude",
    ))
}

/// The overseer walk choosing the Claude account `bclaude`.
fn walk_b(_: &WalkRequest) -> orch_runtime::error::Result<Walked> {
    Ok(Walked {
        answer: WalkAnswer::Lane(Box::new(Chosen {
            entry: "claude:opus:high".to_owned(),
            harness: Harness::Claude,
            host: None,
            model: "opus".to_owned(),
            class: None,
            effort: "high".to_owned(),
            pick_model: "opus".to_owned(),
            account: Some("/home/me/.bclaude".to_owned()),
            record: None,
            warning: None,
            launch: None,
            kept: false,
            kept_unmeasured: false,
        })),
        walk: "claude:opus:high".to_owned(),
        entries: 1,
        skipped: Vec::new(),
        walled: 0,
        unmeasured: 0,
        unread: Vec::new(),
        deprecated: Vec::new(),
    })
}

/// The line under a reached mark for the session in `cwd` at `pane`.
fn hand_over(cwd: &Path, pane: &str, kind: &str, walks: &str) -> String {
    format!(
        "Hand this session over at the next safe point: write the overseer handoff file, choose the successor with orch-runtime successor --fleet --cwd {} --predecessor {pane} --mark {kind} (it walks {walks}) and ask orch-runtime op --fleet --effect-exit for request-transfer with cause live, its .result.successor as the successor and its .result.expected as the expected record, which answers the transfer's own outcome.",
        cwd.display()
    )
}

fn no_walk(_: &WalkRequest) -> orch_runtime::error::Result<Walked> {
    panic!("the overseer walk is asked only for a walled succession")
}

fn no_wall_pick(_: &Path, _: Harness, _: &str, _: &str) -> Pick {
    panic!("the wall route's pick is the lanes pass's, never the overseer's")
}

fn no_relaunch(_: &Relaunch) -> Result<(), String> {
    panic!("the wall relaunch is the lanes pass's, never the overseer's")
}

/// A standing mark with succession off.
fn reached_off(_: &Caller, _: Option<&str>) -> Result<Marks, String> {
    Ok(marks(
        MarkKey::Reached(MarkKind::Headroom),
        "50",
        "5",
        Succession::Off,
        "/home/me/.eclaude",
    ))
}

/// The pane's memory reader of a row that plants no control group: no cap
/// on the path.
fn no_memory(_: u32) -> Reading<Option<Memory>> {
    Reading::Live(None)
}

macro_rules! overseer_driver {
    ($server:expr, $fleet:expr, $marks:expr, $pick:expr, $readers:ident, $transfers:ident, $name:ident) => {
        overseer_driver!(
            $server,
            $fleet,
            $marks,
            $pick,
            memory = no_memory,
            $readers,
            $transfers,
            $name
        );
    };
    ($server:expr, $fleet:expr, $marks:expr, $pick:expr, memory = $memory:expr, $readers:ident, $transfers:ident, $name:ident) => {
        let $readers = TestReaders {
            socket: $server.socket.clone(),
        };
        let pane_read =
            |r: &[PathBuf], s: u64, start: Option<u64>, p: &str| $readers.pane(r, s, start, p);
        let windows_read = |r: Option<&Path>, session: &str| $readers.windows(r, session);
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
            judges: Judges {
                scripts: PathBuf::from("/nonexistent"),
                marks: &$marks,
                walk: &$pick,
                wall_pick: &no_wall_pick,
                relaunch: &no_relaunch,
                memory: &$memory,
            },
            settings: settings_in($fleet.runner.state_dir()),
            baseline: Baseline::default(),
            slot: Slot::new(),
            now: 1_800_000_000,
            transfers: &$transfers,
            context_record: None,
            alert: &no_alert,
            succession: Succession::On,
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

/// A pane holding nothing but shells under a record naming its harness is
/// dead: the line goes out with `source=process`, the record's transfer is
/// asked for once on the next run with `cause: dead` and the record's own
/// launch fields as the successor, and nothing more is asked after. The one verdict of each
/// pass is what the slot holds, so the mail gate reads the same source and
/// closes while it is down. An unreadable pane counts nothing on any pass.
/// Under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off` the line says `succession=off`
/// and no transfer is asked.
#[test]
fn a_dead_overseer_is_said_and_transferred_once_with_cause_dead() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("overseer", dir.path(), "bash --norc --noprofile");
    let window = window_of(&server, &pane);
    fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
    let state = fleet.read();
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    let key = format!("{} {pane}", server.pid);
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=1 succession=on source=process"
        )]
    );
    let judged = driver.slot.read().expect("a verdict is stored each pass");
    assert_eq!(
        judged.verdict,
        Verdict::Exited {
            source: Source::Process
        }
    );
    assert_eq!(
        driver.baseline.get("overseer-dead", &key),
        Some("announced")
    );
    assert!(first.next_due.is_some(), "the request follows at once");
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
        assert_eq!(asked[0].successor.model.as_deref(), Some("opus"));
        assert_eq!(
            asked[0].successor.account.as_deref(),
            Some("/home/me/.eclaude")
        );
        assert_eq!(asked[0].expected.pane, json!(pane));
        assert_eq!(asked[0].expected.generation, json!(3));
    }
    let fourth = driver.pass(&state);
    assert!(lines(&fourth).is_empty());
    assert_eq!(transfers.borrow().len(), 1, "one request per death");
    // An unreadable pane: the record names a server by the pid of a live
    // process no socket answers for, which cannot be told from gone.
    let mut moved = overseer_at(&server, &pane, &window, dir.path());
    moved["server"] = json!(std::process::id().to_string());
    fleet.set_overseer(moved);
    let unreadable = fleet.read();
    overseer_driver!(server, fleet, below, no_walk, readers2, transfers2, driver2);
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
    let off_pane = server.open_window("overseer-off", dir.path(), "bash --norc --noprofile");
    let off_window = window_of(&server, &off_pane);
    fleet.set_overseer(overseer_at(&server, &off_pane, &off_window, dir.path()));
    let off_state = fleet.read();
    overseer_driver!(server, fleet, below, no_walk, readers3, transfers3, driver3);
    driver3.succession = Succession::Off;
    let off_key = format!("{} {off_pane}", server.pid);
    assert_eq!(
        lines(&driver3.pass(&off_state)),
        vec![format!(
            "EVENT overseer-dead {off_pane} window={off_window} passes=1 succession=off source=process"
        )]
    );
    assert_eq!(
        driver3.baseline.get("overseer-dead", &off_key),
        Some("reported")
    );
    for _ in 0..2 {
        let after = driver3.pass(&off_state);
        assert!(lines(&after).is_empty(), "{:?}", lines(&after));
    }
    assert!(
        transfers3.borrow().is_empty(),
        "succession off asks no transfer"
    );
}

/// The lane and the controller on the controller's own server, which the
/// controller record names and the caller's is not, as a launch from the
/// controller's pane leaves them: each read there and judged as on the
/// caller's own, the lane exited on its second pass and the controller dead,
/// and the stray sweep reads that server's fleet session.
#[test]
fn a_lane_and_a_controller_on_the_server_the_record_names_are_read_there() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let root = dir.path().join("controller");
    std::fs::create_dir_all(&root).unwrap();
    let controller = Server::start(&root, "fleet");
    let pane = controller.open_window("overseer", dir.path(), "bash --norc --noprofile");
    await_bare(&controller, &pane);
    let window = window_of(&controller, &pane);
    let lane = controller.open_window("gh-1", dir.path(), "bash --norc --noprofile");
    let stray = controller.open_window("stray", dir.path(), "exec sleep 600");
    let stray_window = window_of(&controller, &stray);
    fleet.set_overseer(overseer_at(&controller, &pane, &window, dir.path()));
    fleet.set_lanes(vec![lane_record(
        "KEN-1",
        "gh-1",
        "claude",
        &controller,
        &lane,
        None,
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, lane_readers, lanes_pass);
    assert_eq!(
        event_lines(&lanes_pass.pass(&state)),
        vec![format!(
            "EVENT stray-window {stray} window={stray_window} server={} name=stray",
            controller.pid
        )]
    );
    assert_eq!(
        event_lines(&lanes_pass.pass(&state)),
        vec!["EVENT lane-exited gh-1"]
    );
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    assert_eq!(
        lines(&driver.pass(&state)),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=1 succession=on source=process"
        )]
    );
}

/// A property row: every read of a lane or a controller is by pane id on a
/// server confirmed by pid and start, so a second session grouped with the
/// fleet's, sharing its windows under another name, changes no reading.
#[test]
fn a_window_in_a_grouped_session_reads_the_same_for_a_lane_and_a_controller() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("overseer", dir.path(), "bash --norc --noprofile");
    await_bare(&server, &pane);
    let window = window_of(&server, &pane);
    let lane = server.open_window("gh-1", dir.path(), "bash --norc --noprofile");
    let grouped = support::tmux(
        &server.socket,
        &["new-session", "-d", "-t", "fleet", "-s", "view"],
    );
    assert!(grouped.status.success(), "{}", stderr(&grouped));
    fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
    fleet.set_lanes(vec![lane_record(
        "KEN-1",
        "gh-1",
        "claude",
        &server,
        &lane,
        None,
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, lane_readers, lanes_pass);
    assert!(event_lines(&lanes_pass.pass(&state)).is_empty());
    assert_eq!(
        event_lines(&lanes_pass.pass(&state)),
        vec!["EVENT lane-exited gh-1"]
    );
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    assert_eq!(
        lines(&driver.pass(&state)),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=1 succession=on source=process"
        )]
    );
}

/// The controller's pane its server keeps dead after the harness exited,
/// alone in the fleet session, is the death the overseer duty reads and
/// never a window of the stray sweep: the controller record names it.
#[test]
fn a_kept_dead_controller_alone_in_its_session_reads_dead_and_is_no_stray() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_kept_dead("overseer", dir.path());
    server.close_birth_window();
    assert_eq!(server.session_panes(), vec![pane.clone()]);
    let window = String::from_utf8_lossy(
        &support::tmux(
            &server.socket,
            &["display-message", "-p", "-t", &pane, "#{window_id}"],
        )
        .stdout,
    )
    .trim()
    .to_owned();
    fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
    let state = fleet.read();
    lane_driver!(server, fleet, lane_readers, lanes_pass);
    let swept = lanes_pass.pass(&state);
    assert!(
        !event_lines(&swept)
            .iter()
            .any(|l| l.starts_with("EVENT stray-window")),
        "{:?}",
        lines(&swept)
    );
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    assert_eq!(
        lines(&driver.pass(&state)),
        vec![format!(
            "EVENT overseer-dead {pane} window={window} passes=1 succession=on source=pane"
        )]
    );
}

/// The owner's alerts a row records by notice file, refused while
/// `refusing` is set.
struct Alerts {
    sent: RefCell<Vec<(String, String)>>,
    refusing: Cell<bool>,
}

impl Alerts {
    fn new() -> Alerts {
        Alerts {
            sent: RefCell::new(Vec::new()),
            refusing: Cell::new(false),
        }
    }

    fn send(&self, file: &str, text: &str) -> Result<(), String> {
        if self.refusing.get() {
            return Err("mailbox-down".to_owned());
        }
        self.sent
            .borrow_mut()
            .push((file.to_owned(), text.to_owned()));
        Ok(())
    }

    fn texts(&self) -> Vec<String> {
        self.sent.borrow().iter().map(|(_, t)| t.clone()).collect()
    }
}

/// The pane's foreground as the duty reads it for a Claude record, once
/// `want` holds, bounded.
fn await_foreground(
    server: &Server,
    pane: &str,
    want: fn(&ProcessReading) -> bool,
) -> ProcessReading {
    let pid = server.pane_pid(pane);
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let reading = foreground(pid, Some(Harness::Claude), None);
        if want(&reading) {
            return reading;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{pane} never read as wanted: {reading:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Wait until the pane's shell holds it alone.
fn await_bare(server: &Server, pane: &str) {
    let _shells = await_foreground(server, pane, |r| matches!(r, ProcessReading::ShellsOnly));
}

/// Wait until a harness holds the pane: its identity.
fn await_held(server: &Server, pane: &str) -> Identity {
    let ProcessReading::Harness { identity } = await_foreground(server, pane, |r| {
        matches!(r, ProcessReading::Harness { .. })
    }) else {
        unreachable!("awaited a harness")
    };
    identity
}

/// An interactive shell pane that runs a process named `claude` from its
/// prompt: the pane and that process's identity.
fn harness_in_shell(dir: &Path, server: &Server) -> (String, Identity) {
    let claude = named_sleep(dir, "claude");
    let pane = server.open_window("overseer", dir, "bash --norc --noprofile -i");
    await_bare(server, &pane);
    server.send_line(&pane, &format!("{} 600", claude.display()));
    let identity = await_held(server, &pane);
    (pane, identity)
}

/// Kill the pane's harness as the system's memory guard does, and wait for
/// its shell to hold the pane alone again.
fn kill_harness(server: &Server, pane: &str, identity: &Identity) {
    let out = std::process::Command::new("kill")
        .args(["-KILL", &identity.pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    await_bare(server, pane);
}

/// A controller whose end a reading proves is said on the first pass
/// (`passes=1`) whatever `ORCH_OVERSEER_DEAD_PASSES` reads: the exit record
/// or the end row over a pane its shell holds alone, such a pane whose
/// recorded harness was killed, the pane gone from the recorded server,
/// the pane that server keeps dead after its process exited, that server
/// ended or its pid answering under another start, and the harness's own
/// wall row over a pane its shell holds alone.
/// The owner's alert follows on
/// the duty's next run, which the line asks for at once, under its own
/// notice file, and nothing after; the alert says whether anything replaces
/// the session.
#[test]
fn an_overseer_whose_end_is_proven_is_said_on_its_first_pass_and_alerted_to_the_owner_once() {
    struct Case {
        name: &'static str,
        source: &'static str,
        /// The record over a pane on `server`, planted in `dir`.
        plant: fn(&Path, &Server) -> Value,
    }
    let bash = |dir: &Path, server: &Server| {
        let pane = server.open_window("overseer", dir, "bash --norc --noprofile");
        await_bare(server, &pane);
        let window = window_of(server, &pane);
        overseer_at(server, &pane, &window, dir)
    };
    let cases = [
        Case {
            name: "the exit record over a bare pane",
            source: "record",
            plant: |dir, server| {
                let pane = server.open_window("overseer", dir, "bash --norc --noprofile");
                await_bare(server, &pane);
                let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
                record["exit"] = json!({"status": 0, "run": {"generation": 3}});
                record
            },
        },
        Case {
            name: "the end row over a bare pane",
            source: "rows",
            plant: |dir, server| {
                let pane = server.open_window("overseer", dir, "bash --norc --noprofile");
                await_bare(server, &pane);
                let rows = dir.join("overseer-rows.jsonl");
                session_rows(
                    &rows,
                    &[
                        started(1_799_999_000),
                        json!({"harness": "claude", "event": "SessionEnd", "reason": "exit"}),
                    ],
                );
                let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
                record["session_rows"] = json!(rows.display().to_string());
                record
            },
        },
        Case {
            name: "the recorded harness killed, its shell left",
            source: "process",
            plant: |dir, server| {
                let (pane, identity) = harness_in_shell(dir, server);
                let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
                record["harness_pid"] = json!(identity.pid.to_string());
                record["harness_start"] = json!(identity.start);
                kill_harness(server, &pane, &identity);
                record
            },
        },
        Case {
            name: "the pane gone from the recorded server",
            source: "pane",
            plant: |dir, server| overseer_at(server, "%99", "@99", dir),
        },
        Case {
            name: "the pane the recorded server keeps dead",
            source: "pane",
            plant: |dir, server| {
                let pane = server.open_kept_dead("overseer", dir);
                let window = String::from_utf8_lossy(
                    &support::tmux(
                        &server.socket,
                        &["display-message", "-p", "-t", &pane, "#{window_id}"],
                    )
                    .stdout,
                )
                .trim()
                .to_owned();
                overseer_at(server, &pane, &window, dir)
            },
        },
        Case {
            name: "the recorded server ended",
            source: "pane",
            plant: |dir, server| {
                let (pid, start, pane) = gone_server(dir);
                let mut record = overseer_at(server, &pane, "@1", dir);
                record["server"] = json!(pid.to_string());
                record["server_start"] = json!(start);
                record["server_socket"] =
                    json!(dir.join("gone").join("tmux.sock").display().to_string());
                record
            },
        },
        Case {
            name: "the recorded server's pid under another start",
            source: "pane",
            plant: |dir, server| {
                let pane = server.open_window("overseer", dir, "bash --norc --noprofile");
                await_bare(server, &pane);
                let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
                record["server_start"] = json!(server.start - 1);
                record
            },
        },
        Case {
            name: "the harness's own wall row over a bare pane",
            source: "process",
            plant: |dir, server| {
                let pane = server.open_window("overseer", dir, "bash --norc --noprofile");
                await_bare(server, &pane);
                let rows = dir.join("overseer-rows.jsonl");
                session_rows(
                    &rows,
                    &[
                        json!({"harness": "claude", "event": "StopFailure", "error": "rate_limit",
                        "message": "You've hit your weekly limit · resets Oct 4"}),
                    ],
                );
                let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
                record["session_rows"] = json!(rows.display().to_string());
                record
            },
        },
    ];
    for case in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let record = (case.plant)(dir.path(), &server);
        let pane = record["pane"].as_str().unwrap().to_owned();
        let window = record["window"].as_str().unwrap().to_owned();
        let key = format!("{} {pane}", record["server"].as_str().unwrap());
        fleet.set_overseer(record);
        let state = fleet.read();
        let alerts = Alerts::new();
        let alert = |file: &str, text: &str| alerts.send(file, text);
        overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
        driver.succession = Succession::Off;
        driver.alert = &alert;
        let first = driver.pass(&state);
        assert_eq!(
            lines(&first),
            vec![format!(
                "EVENT overseer-dead {pane} window={window} passes=1 succession=off source={}",
                case.source
            )],
            "{}",
            case.name
        );
        assert!(
            first.next_due.is_some(),
            "{}: the alert follows at once",
            case.name
        );
        assert!(
            alerts.texts().is_empty(),
            "{}: the line goes first",
            case.name
        );
        let second = driver.pass(&state);
        assert!(
            lines(&second).is_empty(),
            "{}: {:?}",
            case.name,
            lines(&second)
        );
        let sent = alerts.sent.borrow().clone();
        assert_eq!(sent.len(), 1, "{}: one alert", case.name);
        assert_eq!(sent[0].0, "overseer-dead.txt", "{}", case.name);
        let text = &sent[0].1;
        assert!(
            text.starts_with(&format!("overseer-dead: the overseer in pane {pane} "))
                && text.contains(&format!("source={} on passes=1", case.source))
                && text.contains("Nothing replaces it"),
            "{}: {text}",
            case.name
        );
        assert_eq!(
            driver.baseline.get("overseer-dead-alert", &key),
            Some("dead|alerted"),
            "{}",
            case.name
        );
        for _ in 0..2 {
            let after = driver.pass(&state);
            assert!(
                lines(&after).is_empty(),
                "{}: {:?}",
                case.name,
                lines(&after)
            );
        }
        assert_eq!(alerts.texts().len(), 1, "{}: nothing after", case.name);
        assert!(transfers.borrow().is_empty(), "{}", case.name);
    }
    // Under succession the alert says the watch asks for the recovery, and
    // the request goes out on the same run.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let mut record = bash(dir.path(), &server);
    record["exit"] = json!({"status": 0, "run": {"generation": 3}});
    fleet.set_overseer(record);
    let state = fleet.read();
    let alerts = Alerts::new();
    let alert = |file: &str, text: &str| alerts.send(file, text);
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    driver.alert = &alert;
    driver.pass(&state);
    driver.pass(&state);
    let texts = alerts.texts();
    assert_eq!(texts.len(), 1);
    assert!(
        texts[0].contains("The watch requests its recovery"),
        "{}",
        texts[0]
    );
    assert_eq!(transfers.borrow().len(), 1);
}

/// A pane its shell holds alone under a record that names a harness and
/// no process is the harness gone, as a start reads it: said on its first
/// pass, then alerted to the owner; an alert the mailbox refused stays owed
/// and is sent on the pass after, once. A live harness in the pane clears
/// the death and its alert, and a later death is said and alerted again.
#[test]
fn a_bare_pane_under_a_record_naming_no_process_is_said_on_its_first_pass_and_each_death_alerted_once()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = harness_in_shell(dir.path(), &server);
    let window = window_of(&server, &pane);
    fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
    let state = fleet.read();
    let alerts = Alerts::new();
    let alert = |file: &str, text: &str| alerts.send(file, text);
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    driver.succession = Succession::Off;
    driver.alert = &alert;
    let key = format!("{} {pane}", server.pid);
    let line = format!(
        "EVENT overseer-dead {pane} window={window} passes=1 succession=off source=process"
    );
    kill_harness(&server, &pane, &identity);
    assert_eq!(lines(&driver.pass(&state)), vec![line.clone()]);
    assert!(alerts.texts().is_empty());
    alerts.refusing.set(true);
    assert!(lines(&driver.pass(&state)).is_empty());
    assert_eq!(
        driver.baseline.get("overseer-dead-alert", &key),
        None,
        "an alert the owner did not get stays owed"
    );
    alerts.refusing.set(false);
    driver.pass(&state);
    assert_eq!(alerts.texts().len(), 1);
    driver.pass(&state);
    assert_eq!(alerts.texts().len(), 1, "nothing while the death stands");
    // A harness in the pane again: live, the death and its alert cleared.
    let claude = dir.path().join("claude");
    server.send_line(&pane, &format!("{} 600", claude.display()));
    let identity = await_held(&server, &pane);
    assert!(lines(&driver.pass(&state)).is_empty());
    assert_eq!(driver.slot.read().unwrap().verdict, Verdict::Live);
    assert_eq!(driver.baseline.get("overseer-dead", &key), None);
    assert_eq!(driver.baseline.get("overseer-dead-alert", &key), None);
    kill_harness(&server, &pane, &identity);
    assert_eq!(lines(&driver.pass(&state)), vec![line]);
    driver.pass(&state);
    assert_eq!(alerts.texts().len(), 2, "the later death is alerted again");
    assert!(transfers.borrow().is_empty());
}

/// A controller stopped on purpose is not judged: its record marked `off`
/// over a pane its shell holds alone, or over the pane its stop closed,
/// draws no line and no alert on any pass.
#[test]
fn a_controller_marked_off_is_not_judged_dead() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("overseer", dir.path(), "bash --norc --noprofile");
    await_bare(&server, &pane);
    let window = window_of(&server, &pane);
    for (pane, window) in [(pane.as_str(), window.as_str()), ("%99", "@99")] {
        let mut record = overseer_at(&server, pane, window, dir.path());
        record["off"] = json!({"at": "2026-10-26T10:00:00Z", "generation": 3});
        fleet.set_overseer(record);
        let state = fleet.read();
        let alerts = Alerts::new();
        let alert = |file: &str, text: &str| alerts.send(file, text);
        overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
        driver.alert = &alert;
        for _ in 0..3 {
            let produced = driver.pass(&state);
            assert!(
                lines(&produced).is_empty(),
                "{pane}: {:?}",
                lines(&produced)
            );
            assert_eq!(
                driver.slot.read().unwrap().verdict,
                Verdict::Unwatched {
                    cause: "controller-off"
                }
            );
        }
        assert!(alerts.texts().is_empty(), "{pane}");
        assert!(transfers.borrow().is_empty(), "{pane}");
    }
}

/// A death the caps on the controller's control-group path made: the live
/// controller's OOM kill count is kept each pass (`overseer-oom`, whether
/// or not the memory mark is set), and a death read with that count risen
/// says `cause=memory-cap` on its `overseer-dead` line and carries it on
/// the `request-transfer {dead}` it asks. A count unchanged, a path with
/// no cap and a count unread at the death say no cause. The reader is the
/// real one over fixture `/proc` and cgroup files.
#[test]
fn a_dead_overseer_whose_caps_oom_kill_count_rose_is_dead_of_the_memory_cap() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let claude = named_sleep(dir.path(), "claude");
    let proc_root = dir.path().join("proc");
    let cgroup = dir.path().join("cgroup");
    let scope = cgroup.join("app.slice/overseer.scope");
    std::fs::create_dir_all(proc_root.join("4242")).unwrap();
    std::fs::write(
        proc_root.join("4242/cgroup"),
        "0::/app.slice/overseer.scope\n",
    )
    .unwrap();
    std::fs::create_dir_all(&scope).unwrap();
    std::fs::write(scope.join("memory.current"), "600\n").unwrap();
    // The scope's cap and its OOM kills: `None` leaves the count unread.
    let plant = |max: &str, kills: Option<u64>| {
        std::fs::write(scope.join("memory.max"), format!("{max}\n")).unwrap();
        match kills {
            Some(n) => std::fs::write(
                scope.join("memory.events"),
                format!("low 0\nhigh 0\nmax 9\noom {n}\noom_kill {n}\noom_group_kill 0\n"),
            )
            .unwrap(),
            None => {
                let _ = std::fs::remove_file(scope.join("memory.events"));
            }
        }
    };
    let memory = |_: u32| agent_runtime::process::memory_of(&proc_root, &cgroup, 4242);
    for (case, live, dead, cause) in [
        (
            "rose",
            ("1000", Some(2)),
            ("1000", Some(3)),
            " cause=memory-cap",
        ),
        ("unchanged", ("1000", Some(2)), ("1000", Some(2)), ""),
        ("no cap", ("max", Some(0)), ("max", Some(1)), ""),
        ("unread", ("1000", Some(2)), ("1000", None), ""),
    ] {
        let fleet = Fleet::new(&server);
        let pane = server.open_window(
            "overseer",
            dir.path(),
            &format!(
                "bash --norc --noprofile -c '{} 600; exec bash --norc --noprofile'",
                claude.display()
            ),
        );
        let shell = server.pane_pid(&pane);
        let window = window_of(&server, &pane);
        fleet.set_overseer(overseer_at(&server, &pane, &window, dir.path()));
        let state = fleet.read();
        overseer_driver!(
            server,
            fleet,
            below,
            no_walk,
            memory = memory,
            readers,
            transfers,
            driver
        );
        let key = format!("{} {pane}", server.pid);
        plant(live.0, live.1);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let harness = loop {
            let children = std::fs::read_to_string(format!("/proc/{shell}/task/{shell}/children"))
                .unwrap_or_default();
            if let Some(pid) = children.split_whitespace().next() {
                break pid.to_owned();
            }
            assert!(
                std::time::Instant::now() < deadline,
                "{case}: the harness never ran"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        let first = driver.pass(&state);
        assert_eq!(
            driver.slot.read().unwrap().verdict,
            Verdict::Live,
            "{case}: {:?}",
            lines(&first)
        );
        let kept = live.1.filter(|_| live.0 != "max").map(|n| n.to_string());
        assert_eq!(
            driver.baseline.get("overseer-oom", &key).map(str::to_owned),
            kept,
            "{case}: the live count is kept"
        );
        let killed = std::process::Command::new("kill")
            .args(["-KILL", &harness])
            .status()
            .unwrap();
        assert!(killed.success(), "{case}");
        plant(dead.0, dead.1);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut passes = Vec::new();
        while !matches!(
            driver.slot.read().map(|j| j.verdict),
            Some(Verdict::Exited { .. })
        ) || passes.is_empty()
        {
            assert!(
                std::time::Instant::now() < deadline,
                "{case}: never read dead"
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
            passes = vec![driver.pass(&state)];
        }
        assert_eq!(
            lines(&passes[0]),
            vec![format!(
                "EVENT overseer-dead {pane} window={window} passes=1 succession=on source=process{cause}"
            )],
            "{case}"
        );
        let second = driver.pass(&state);
        assert!(lines(&second).is_empty(), "{case}: {:?}", lines(&second));
        let asked = transfers.borrow();
        assert_eq!(asked.len(), 1, "{case}");
        assert_eq!(asked[0].cause, TransferCause::Dead, "{case}");
        assert_eq!(
            asked[0].death.map(DeathCause::word),
            (!cause.is_empty()).then_some("memory-cap"),
            "{case}"
        );
    }
}

/// The harness's own row states its wall, so a rows wall under a live
/// harness is `overseer-walled` on its first pass with the row's message
/// under it, and the transfer asked for carries `cause: walled`, the spent
/// account to exclude and the successor on the account the walk picked; the
/// account judgement reading room lifts it instead.
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
    overseer_driver!(server, fleet, reached, walk_b, readers, transfers, driver);
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
            asked[0].successor.home, None,
            "the launch prepares the home"
        );
    }
    // The same rows wall with the account judgement reading room: lifted.
    overseer_driver!(server, fleet, below, no_walk, readers2, transfers2, lifted);
    let produced = lifted.pass(&state);
    assert!(lines(&produced).is_empty(), "{:?}", lines(&produced));
    assert_eq!(lifted.slot.read().unwrap().verdict, Verdict::Live);
    assert!(transfers2.borrow().is_empty());
}

/// The first crossing of a headroom mark on a live overseer carries the
/// succession's sentence under the line: the judge's path and
/// `AGENT_RUNTIME_CONTROLLER_PREFERENCE` as set, the default where unset; with
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
    overseer_driver!(server, fleet, reached, no_walk, readers, transfers, driver);
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            format!("EVENT overseer-mark {pane} kind=headroom value=50 mark=5 succession=on"),
            hand_over(
                dir.path(),
                &pane,
                "headroom",
                "AGENT_RUNTIME_CONTROLLER_PREFERENCE=claude:standard:high,codex:standard:high"
            ),
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
        server, fleet, reached, no_walk, readers2, transfers2, chosen
    );
    chosen.settings.controller.preference = "claude:fable:high".to_owned();
    chosen.settings.controller.preference_set = true;
    let preferred = chosen.pass(&state);
    assert_eq!(
        lines(&preferred).get(1).map(String::as_str),
        Some(
            hand_over(
                dir.path(),
                &pane,
                "headroom",
                "AGENT_RUNTIME_CONTROLLER_PREFERENCE=claude:fable:high"
            )
            .as_str()
        ),
        "{:?}",
        lines(&preferred)
    );
    overseer_driver!(
        server,
        fleet,
        reached_off,
        no_walk,
        readers3,
        transfers3,
        off
    );
    let off_line = off.pass(&state);
    assert_eq!(
        lines(&off_line),
        vec![
            format!("EVENT overseer-mark {pane} kind=headroom value=50 mark=5 succession=off"),
            "AGENT_RUNTIME_CONTROLLER_SUCCESSION is off, so no successor opens: rewrite the overseer handoff file and ask the user to start a fresh overseer session.".to_owned(),
        ]
    );
    assert!(transfers3.borrow().is_empty());
}

// The overseer's context record, judged beside a live session.

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

/// The watch judges the context mark with the reading the hook judges it
/// with, so an overseer past its mark between turn ends is said: the
/// session's own record is handed to the judge (the `marks` verb's) as
/// `--context TOKENS:WINDOW`; its `mark-reached
/// kind=context` is `overseer-mark ... kind=context` once with the
/// handling under it, then
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
    let marks = |_: &Caller, context: Option<&str>| {
        handed.borrow_mut().push(context.map(str::to_owned));
        Ok(marks(
            MarkKey::Reached(MarkKind::Context),
            "910000",
            "90",
            Succession::On,
            "",
        ))
    };
    overseer_driver!(server, fleet, marks, no_walk, readers, transfers, driver);
    driver.context_record = Some(record.clone());
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec![
            format!("EVENT overseer-mark {pane} kind=context value=910000 mark=90 succession=on"),
            hand_over(
                dir.path(),
                &pane,
                "context",
                "this session's own entry alone, AGENT_RUNTIME_CONTROLLER_PREFERENCE being unset; where this session's account has reached its headroom or rate mark, AGENT_RUNTIME_CONTROLLER_PREFERENCE=claude:standard:high,codex:standard:high without that account"
            ),
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

/// An overseer whose context fills its window runs on with rows that say
/// nothing, its process alive, so a reading that fills the window with no
/// Stop row after it is the session gone with `source=context`, counted on
/// the death's passes; the same reading with a later Stop row is a session
/// that took a turn since, and live.
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
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
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
    overseer_driver!(server, fleet, below, no_walk, readers2, transfers2, turned);
    turned.context_record = Some(record.clone());
    let live = turned.pass(&state);
    assert!(lines(&live).is_empty(), "{:?}", lines(&live));
    assert_eq!(turned.slot.read().unwrap().verdict, Verdict::Live);
    assert!(transfers2.borrow().is_empty());
}

/// A context record that stopped advancing while the session takes turns
/// watches nothing: a record more than `OVERSEER_CONTEXT_STALE_SECS` old
/// with a Stop row after it is `overseer-context-stale` with its age on
/// every pass it stands; a fresh record, and an old one with no Stop row
/// after it, say nothing.
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
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
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

/// A gap the overseer does not act on leaves the fleet unwatched, so it
/// goes to the owner: a gap is `overseer-context-unmeasured` once; on the
/// next pass the owner's alert goes out and is marked only once sent, so a
/// refused send is tried again on the pass after; then nothing while that
/// gap stands; a different gap starts the turn again, and a reading clears
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
    let alert = |_: &str, text: &str| {
        if refusing.get() {
            return Err("mailbox-down".to_owned());
        }
        alerts.borrow_mut().push(text.to_owned());
        Ok(())
    };
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
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

// The standing handoff and the wall relaunch's outcomes.

/// A handoff record as jq's `tojson` prints it under the event.
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

/// A record with no `resumed_at` is `handoff` once with the record under
/// it, read under the fleet's state directory and under the lane root's
/// `tmp`; the same record is quiet after; a resumed one clears the row; a
/// later record of the same item is news again.
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

/// A state the pass cannot read is never "no handoff", which would drop the
/// event of a lane that handed off and exited: a torn file in the lane
/// root's `tmp` is the pass's partial failure naming the item and that
/// file; the other lane's handoff is out; the standing row survives, so the
/// next readable pass still owes the event.
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
/// the runner commits them; the prepare bound its default, 1800 s, over a
/// fleet holding no intent.
fn outcomes(dir: &Path, baseline: &mut Baseline, now: u64) -> Produced {
    let fleet = FleetState::view(&dir.join("fleet.json"), &serde_json::Map::new()).unwrap();
    let produced =
        overseer::relaunch_outcomes(dir, &fleet, Duration::from_secs(1800), now, baseline);
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

/// A relaunch is judged by its completed status, never by its window: a
/// failed status beside the marker is `lane-prepare-failed` with the exit
/// and the log once; the marker and its status leave with the row, for a
/// status of 0 as well; the next pass says nothing.
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

/// A detached recovery can overrun while its old window survives: a marker
/// with no status `ORCH_WATCH_PREPARE_SECS` past its start is
/// `lane-prepare-stuck` with its age, log and `reason=relaunch-pending`
/// once, keyed by that start, the marker kept; a marker inside the bound is
/// quiet; a relaunch started afresh is said afresh, at the bound exactly.
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

/// A status that cannot be read, or one that is no exit code, is never
/// absent, which would say an ended relaunch stuck or lose its outcome: it
/// is the pass's partial failure naming the file: no line, the marker and
/// the status kept for the next pass, no row.
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

/// A relaunch replaces its lane's window, so a gone window whose relaunch
/// marker stands with no status inside the prepare bound says nothing and
/// moves no row; once the status lands it is `window-gone` as any other,
/// its rows cleared; a marker at the bound suppresses nothing.
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

/// A torn marker is the pass's partial failure naming it, never a pending
/// relaunch absent: no line, no row moved, and the next pass asks again.
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

// --- the hosted readings ---

/// A static ssh provider's line (`schemas/lane-host.md` § Host kinds).
const SSH_LINE: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local";

/// The provider standing for a remote host in the row's world under
/// `dir` ([`provider_world`]): the host a hosted record names.
fn provider(dir: &Path) -> String {
    dir.join("scripts/provider").display().to_string()
}

/// A row's world for the hosted reads: the shared provider
/// ([`provider_world`]), with the runtime-entry
/// (`orch-runtime`, the close verb's) and `gh` fixtures linked beside it in
/// one scripts directory, their planted answers and logs there too, as the
/// production runner finds them from the pass's scripts directory and the
/// `gh` path the pass carries.
struct HostedWorld {
    scripts: PathBuf,
}

impl HostedWorld {
    fn new(dir: &Path) -> HostedWorld {
        let scripts = provider_world(dir);
        for (fixture, name) in [
            ("runtime-close/orch-runtime", "orch-runtime"),
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

    /// What the host answers, by argv (or `<host> <argv>`), the later of two
    /// answers to one argv standing: a `cat` that reads is the file at its
    /// path on the host's disk and one answering 2 a file the host has not,
    /// a `touch` answering 0 the provider's own answer, and every other
    /// answer planted on the provider. The disk is planted afresh.
    fn plant_host(&self, answers: &[(&str, Value)]) {
        let disk = self.scripts.join("disk");
        if disk.exists() {
            std::fs::remove_dir_all(&disk).unwrap();
        }
        std::fs::create_dir_all(&disk).unwrap();
        let mut map = serde_json::Map::new();
        for (key, value) in answers {
            let exit = value.get("exit").and_then(Value::as_i64).unwrap_or(0);
            let plain = value.get("signal").is_none() && value.get("stderr").is_none();
            let words: Vec<&str> = key.split(' ').collect();
            map.remove(*key);
            match (words.as_slice(), exit) {
                (["cat", "--item", _, path], 0) if plain => {
                    on_disk(&disk, path, value["stdout"].as_str().unwrap_or(""));
                }
                (["cat", "--item", _, path], 2) if plain => {
                    let _ = std::fs::remove_file(disk.join(path.trim_start_matches('/')));
                }
                (["touch", "--item", _], 0) if plain => {}
                _ => {
                    map.insert((*key).to_owned(), value.clone());
                }
            }
        }
        std::fs::write(
            self.scripts.join("provider.json"),
            Value::Object(map).to_string(),
        )
        .unwrap();
    }

    /// [`Self::plant_host`] over argvs a row composed.
    fn plant_host_owned(&self, answers: &[(String, Value)]) {
        let answers: Vec<(&str, Value)> = answers
            .iter()
            .map(|(key, value)| (key.as_str(), value.clone()))
            .collect();
        self.plant_host(&answers);
    }

    /// The one answer the runtime entry gives the close verb.
    fn plant_close(&self, answer: Value) {
        std::fs::write(self.scripts.join("orch-runtime.json"), answer.to_string()).unwrap();
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
        self.log("orch-runtime.log")
    }
}

/// A fixture answer: the status and the bytes printed.
fn answer(exit: i32, stdout: &str) -> Value {
    json!({"exit": exit, "stdout": stdout})
}

fn ok(stdout: &str) -> Value {
    answer(0, stdout)
}

/// The close verb's answer as the runtime prints it: its word and what its
/// effect observed.
fn verb_reply(item: &str, word: &str, observation: Value) -> Value {
    let reply = json!({"protocol": "orch-runtime-v1", "ok": true,
        "result": {"item": item, "word": word, "observation": observation}});
    ok(&format!("{reply}\n"))
}

/// A close that ended the lane, its item's archive on the observation.
fn closed_reply(item: &str, archive: &str) -> Value {
    verb_reply(
        item,
        "closed",
        json!({"item_files": "removed", "archive": archive}),
    )
}

/// A close the provider refused, the checkout it kept named.
fn refused_reply(item: &str, path: &str) -> Value {
    verb_reply(
        item,
        "unconfirmed",
        json!({"host_close": "refused", "path": path}),
    )
}

/// The verb's refusal on the tracker's quota hold, as the runtime exits
/// with it.
fn quota_reply(item: &str) -> Value {
    let reply = json!({"protocol": "orch-runtime-v1", "ok": false, "refusal": {
        "key": "tracker-read-failed",
        "fields": [["item", item], ["tracker", "linear"], ["source", "derived"], ["cause", "quota"]]}});
    json!({"exit": 1, "stdout": format!("{reply}\n")})
}

/// The close request's line in the runtime entry's log: the argv with the
/// request's JSON, its keys sorted, in the file's place.
fn close_call(state_dir: &Path, request: &str) -> String {
    format!(
        "--state-dir {} op --fleet --request {request}",
        state_dir.display()
    )
}

/// `gh api repos/O/R/pulls?head=O:B&state=open`'s one open pull request.
fn open_pull(sha: &str, body: &str, draft: Option<bool>) -> Value {
    json!({"body": [{"number": 1, "state": "open", "title": "cloud work", "merged_at": null, "merge_commit_sha": null, "author_association": "NONE", "head": {"sha": sha, "ref": "cloud-work", "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null, "body": body, "draft": draft}]})
}

/// The body digest as the stall row keeps it (`cksum` over the body and
/// the newline jq printed after it).
fn digest(body: &str) -> String {
    agent_runtime::record::cksum(format!("{body}\n").as_bytes()).to_string()
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
fn hosted_lane(dir: &Path, item: &str, window: &str, root: &str) -> Value {
    json!({
        "item": item, "window": window, "harness": "claude", "host": provider(dir), "kind": "ssh",
        "mail_root": root, "status": "running",
    })
}

fn stalled_lines(produced: &Produced) -> Vec<String> {
    event_lines(produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT lane-stalled ") || l.starts_with("EVENT start-stalled "))
        .collect()
}

/// A cloud lane whose record names no repository is read in the fleet's
/// own repository first, as the fleet checkout's origin names it on
/// github.com with gh naming none: its ready pull request there is
/// `state=finished`.
#[test]
fn a_cloud_lane_naming_no_repository_is_read_in_the_fleets_own() {
    if !isolated_row("a_cloud_lane_naming_no_repository_is_read_in_the_fleets_own") {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let out = program("git")
        .arg("-C")
        .arg(fleet.runner.state_dir())
        .args(["config", "remote.origin.url", "git@github.com:o/r.git"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let now = 1_800_000_000;
    let mut lane = cloud_lane("CC-1", "/a", now);
    lane.as_object_mut().unwrap().remove("repo");
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": open_pull("aaa111", "", Some(false)),
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let produced = driver.pass(&state);
    assert_eq!(
        stalled_lines(&produced),
        vec!["EVENT lane-stalled CC-1 age=0 state=finished"],
        "{:?}",
        lines(&produced)
    );
    assert_eq!(produced.failed, None);
}

/// A cloud lane whose record names no repository is never read in the
/// connected repositories alone: where the fleet checkout names no GitHub
/// repository, the read fails naming that cause, though a connected
/// repository holds an open pull request on the lane's branch.
#[test]
fn a_cloud_lane_naming_no_repository_is_unread_where_the_fleets_own_is_unnamed() {
    if !isolated_row("a_cloud_lane_naming_no_repository_is_unread_where_the_fleets_own_is_unnamed")
    {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let out = program("git")
        .arg("-C")
        .arg(fleet.runner.state_dir())
        .args([
            "config",
            "remote.origin.url",
            "https://gitlab.example/g/r.git",
        ])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let now = 1_800_000_000;
    let mut lane = cloud_lane("CC-1", "/a", now);
    lane.as_object_mut().unwrap().remove("repo");
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": open_pull("aaa111", "", Some(false)),
    }));
    lane_driver!(
        server,
        fleet,
        readers,
        driver,
        &[("ORCH_CONNECTED_REPOS", "o/r")]
    );
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let produced = driver.pass(&state);
    assert_eq!(
        produced.failed.as_deref(),
        Some("lane-stall-unread item=CC-1 repo-unresolved cause=unresolved"),
        "{:?}",
        lines(&produced)
    );
    assert!(
        stalled_lines(&produced).is_empty(),
        "{:?}",
        lines(&produced)
    );
}

/// No pane shows a cloud session, so its pull request is what the watch
/// reads: a cloud lane's open pull request standing still for
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
    driver.roster = [
        json!({"alias": "a", "harness": "claude", "config_dir": "/a", "status": "ok", "verdict": "pick",
               "credits": {"remaining_dollars": 12.5}}),
        json!({"alias": "b", "harness": "claude", "config_dir": "/b", "status": "ok", "verdict": "pick",
               "credits": {"remaining_dollars": 0, "locked_reason": "spend-limit"}}),
    ]
    .iter()
    .map(|raw| {
        agent_runtime::accounts::AccountRow::parse(raw, &driver.settings.accounts.get().unwrap())
    })
    .collect::<Option<Vec<_>>>()
    .map(|rows| Roster {
        rows,
        provider_failure: None,
        notes: Vec::new(),
    });
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

/// A stalled cloud lane's directive at or after the stall's `since` and
/// `ORCH_CLOUD_STALL_MINUTES` old closes the lane once through the close
/// verb (`close-lane ITEM` through the runtime's entry), the marker created
/// before the ask and gone after its answer: `lane-closed` with the archive
/// line, then `cloud-stall-closed` with the directive's age. The provider's
/// refusal is `lane-close-refused` with the path, the lane kept and the
/// stall said; the verb's quota refusal defers it with no line; a standing hold asks nothing; a
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
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": open_pull("aaa111", "", Some(true)),
    }));
    world.plant_close(closed_reply("CC-1", "/archive/CC-1"));
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
    let close = close_call(&driver.state_dir, r#"{"item":"CC-1","op":"close-lane"}"#);
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
    // The record still reads the lane open: the operator's lane, named each
    // pass, never a second close.
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
    // The record the close verb wrote: the lane out of flight, the marker leaves.
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
    world.plant_close(refused_reply("CC-1", "/w/cc-1"));
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
    world.plant_close(quota_reply("CC-1"));
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
    world.plant_close(closed_reply("CC-1", "/archive/CC-1"));
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
    // A close ended with no status gave no answer and may have closed: its
    // marker stands, and the next pass leaves the lane to the operator
    // rather than close it again.
    std::fs::remove_file(&marker).unwrap();
    world.plant_close(json!({"signal": "KILL"}));
    let unanswered = driver.pass(&state);
    assert!(
        unanswered
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-unanswered item=CC-1 ")),
        "{:?}",
        unanswered.failed
    );
    assert_eq!(world.close_log().len(), 5);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the unanswered close's marker stands"
    );
    let after = driver.pass(&state);
    assert!(
        after
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-unconfirmed item=CC-1 marker=")),
        "{:?}",
        after.failed
    );
    assert_eq!(
        world.close_log().len(),
        5,
        "no second close after no answer"
    );
    // With no reply, the parser's usage refusal acted on nothing and takes
    // its marker; a panic's 101 may follow the close's act, so its marker
    // stands.
    std::fs::remove_file(&marker).unwrap();
    world.plant_close(json!({"exit": 2, "stderr": "error: unexpected argument\n"}));
    let usage = driver.pass(&state);
    assert!(
        usage
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-failed item=CC-1 exit=2 ")),
        "{:?}",
        usage.failed
    );
    assert!(
        std::fs::metadata(&marker).is_err(),
        "a usage refusal's marker goes"
    );
    world.plant_close(json!({"exit": 101, "stderr": "thread 'main' panicked\n"}));
    let panicked = driver.pass(&state);
    assert!(
        panicked
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-unanswered item=CC-1 ")),
        "{:?}",
        panicked.failed
    );
    assert_eq!(world.close_log().len(), 7);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the panicked close's marker stands"
    );
    // A close that never started (its program not executable) closed
    // nothing: no marker stands, and once it can run the next pass closes.
    use std::os::unix::fs::PermissionsExt;
    std::fs::remove_file(&marker).unwrap();
    world.plant_close(closed_reply("CC-1", "/archive/CC-1"));
    let close = world.scripts.join("orch-runtime");
    std::fs::remove_file(&close).unwrap();
    // Copied by a child, never opened for writing here (ETXTBSY).
    let copied = program("cp")
        .arg(fixtures().join("runtime-close/orch-runtime"))
        .arg(&close)
        .output()
        .unwrap();
    assert!(copied.status.success(), "{}", stderr(&copied));
    std::fs::set_permissions(&close, std::fs::Permissions::from_mode(0o644)).unwrap();
    let unstarted = driver.pass(&state);
    assert!(
        unstarted
            .failed
            .as_deref()
            .is_some_and(|f| f.starts_with("lane-close-failed item=CC-1 ")),
        "{:?}",
        unstarted.failed
    );
    assert!(
        std::fs::metadata(&marker).is_err(),
        "nothing started, no marker"
    );
    std::fs::set_permissions(&close, std::fs::Permissions::from_mode(0o755)).unwrap();
    let closed = driver.pass(&state);
    assert_eq!(
        event_lines(&closed),
        vec![
            "EVENT lane-closed CC-1",
            "EVENT cloud-stall-closed CC-1 directive_age=5020"
        ]
    );
    assert_eq!(world.close_log().len(), 8);
}

/// A hosted lane's status file is on its host, not this disk: it is read
/// through `lane-host cat` under the record's host, a `2` confirmed by
/// `touch`: a missing file past the bound is `start-stalled`, a file that
/// stands ends the watch, and a fetch that failed (the provider's own
/// failure, a `2` whose `touch` failed too) is `start-stall-unread`, the
/// pass's failure and no line; a lane whose worktree the host no longer has
/// (its `.git` gone, the merged check's lane) writes no status file and is
/// no stall.
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
            dir.path(),
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
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/lane-status-KEN-1.md",
            answer(2, ""),
        ),
        ("touch --item KEN-1", ok("")),
        (
            "cat --item KEN-1 /remote/KEN-1/.git",
            ok("gitdir: /x/.git/worktrees/KEN-1\n"),
        ),
        (
            "cat --item KEN-2 /remote/KEN-2/tmp/lane-status-KEN-2.md",
            json!({"exit": 1, "stderr": "lane-host: ssh-failed host=/w/provider\n"}),
        ),
        // Read only by a reader that takes the failure above for no file.
        (
            "cat --item KEN-2 /remote/KEN-2/.git",
            ok("gitdir: /x/.git/worktrees/KEN-2\n"),
        ),
        (
            "cat --item KEN-3 /remote/KEN-3/tmp/lane-status-KEN-3.md",
            answer(2, ""),
        ),
        (
            "touch --item KEN-3",
            json!({"exit": 1, "stderr": "lane-host-ssh: ssh-failed\n"}),
        ),
        (
            "cat --item KEN-4 /remote/KEN-4/tmp/lane-status-KEN-4.md",
            ok("Step: start\n"),
        ),
        (
            "cat --item KEN-5 /remote/KEN-5/tmp/lane-status-KEN-5.md",
            answer(2, ""),
        ),
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
        "a 2 whose touch failed is no file"
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
            .all(|l| l.starts_with(&format!("ORCH_LANE_HOST={} ", provider(dir.path())))),
        "{log:?}"
    );
    assert!(
        log.contains(&format!(
            "ORCH_LANE_HOST={} touch --item KEN-3",
            provider(dir.path())
        )),
        "{log:?}"
    );
    assert!(
        log.contains(&format!(
            "ORCH_LANE_HOST={} cat --item KEN-5 /remote/KEN-5/.git",
            provider(dir.path())
        )),
        "{log:?}"
    );
}

/// Only a running lane's host is asked anything, since a gone provider's
/// failure would stand ahead of every live lane's line and hide it. A done
/// lane, a stopped lane and a parked lane (the `lanes park` record) on a
/// gone provider beside a running lane whose fetch fails: the pass's
/// failure is the live lane's, and no call runs under the gone host.
#[test]
fn a_lane_out_of_flight_s_gone_provider_is_not_asked_and_hides_no_live_lane_s_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let mut live = hosted_lane(dir.path(), "KEN-1", "gh-1", "/remote/KEN-1");
    live["running_at"] = json!(clock::iso_utc(now - 700));
    let mut done = hosted_lane(dir.path(), "KEN-8", "gh-8", "/remote/KEN-8");
    done["host"] = json!("/w/gone");
    done["status"] = json!("done");
    let mut stopped = hosted_lane(dir.path(), "KEN-9", "gh-9", "/remote/KEN-9");
    stopped["host"] = json!("/w/gone");
    stopped["status"] = json!("stopped");
    let mut parked = hosted_lane(dir.path(), "KEN-7", "gh-7", "/remote/KEN-7");
    parked["host"] = json!("/w/gone");
    parked["status"] = json!("parked");
    parked["parked"] = json!({"head": "abc", "repo": "o/r", "at": "2026-10-24T20:00:00Z"});
    fleet.set_lanes(vec![done, live, stopped, parked]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (
            &format!("{} capabilities", provider(dir.path())),
            ok(SSH_LINE),
        ),
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

/// A cloud session writes no status file, so its branch is its start: a
/// branch head committed at or after the record's `session_since` reads the
/// session started: `start-stalled` never goes out, and a started session
/// whose head stands still for `ORCH_WATCH_LANE_STALL_SECS` is
/// `lane-stalled`; a session with no branch is `start-stalled` past the
/// start bound, counted as the local arm counts.
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
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": {"body": []},
        "repos/o/r/branches/cc-1": {"body": {"protected": false, "commit": {"sha": "bbb222", "commit": {"committer": {"date": clock::iso_utc(now - 100)}}}}},
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

/// A hosted lane's `Step` line, workflow state and run index are on its
/// host and come through the provider; a fetch that failed is
/// `stage=unread` and `unread` counts with the pass's failure; a parked
/// hosted lane reads `parked`; a `files=none` kind `none` with `unread`
/// counts.
#[test]
fn a_long_hosted_lane_s_stage_and_counters_are_read_through_the_provider() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let now = 1_800_000_000;
    let launched = clock::iso_utc(now - 12_601);
    let mut one = hosted_lane(dir.path(), "KEN-1", "gh-1", "/remote/KEN-1");
    one["launched_at"] = json!(launched);
    let mut two = hosted_lane(dir.path(), "KEN-2", "gh-2", "/remote/KEN-2");
    two["launched_at"] = json!(launched);
    let mut parked = hosted_lane(dir.path(), "KEN-3", "gh-3", "/remote/KEN-3");
    parked["launched_at"] = json!(launched);
    parked["status"] = json!("parked");
    let mut cloud = cloud_lane("CC-4", "/a", now);
    cloud["launched_at"] = json!(launched);
    fleet.set_lanes(vec![one, two, parked, cloud]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (&format!("{} capabilities", provider(dir.path())), ok(SSH_LINE)),
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
    let mut lane = hosted_lane(dir, item, window, &format!("/remote/{item}"));
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    (lane, pane)
}

/// The provider's answers to the handoff read of a hosted lane at
/// `/remote/<item>` whose checkout holds no handoff: its `.git` naming the
/// clone `/x`, empty settings files, and an item state with no record in
/// the clone's `tmp` and the root's. A row's own answer to one of these
/// argvs, listed after, stands.
fn no_handoff(item: &str) -> Vec<(String, Value)> {
    let root = format!("/remote/{item}");
    let mut answers = vec![(
        format!("cat --item {item} {root}/.git"),
        ok(&format!("gitdir: /x/.git/worktrees/{item}\n")),
    )];
    for file in [
        "kendex.settings.toml",
        ".kendex/settings.toml",
        ".env.local",
    ] {
        answers.push((format!("cat --item {item} {root}/{file}"), ok("")));
    }
    for dir in ["/x", root.as_str()] {
        answers.push((
            format!("cat --item {item} {dir}/tmp/workflow-state-{item}.json"),
            ok("{}"),
        ));
    }
    answers
}

/// A merged lane's close-out removes its item's live record, so a record
/// that stands in the clone is a close-out still running or a lane resumed.
/// A hosted lane the provider's status verb reads exited is `lane-exited`
/// on the second pass; one whose item the GitHub duty read merged and whose
/// `.git` the host has not, or whose `.git` stands with the item's record
/// gone from the clone it names, is closed through the close verb then, its
/// request naming the merge as the delivery, `lane-closed` with its archive
/// line under it; one whose record stands is not; one with no merged row is
/// closed with its sandbox kept (`keep-sandbox`, `kept=sandbox`); the next
/// pass, the closed records read stopped, says nothing.
#[test]
fn a_merged_hosted_lane_whose_work_left_nothing_on_its_host_is_closed_at_lane_exited_and_one_whose_record_stands_is_not()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (one, _) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    let (two, _) = hosted_pane_lane(&server, "KEN-2", "gh-2", dir.path());
    let (three, _) = hosted_pane_lane(&server, "KEN-3", "gh-3", dir.path());
    let (four, _) = hosted_pane_lane(&server, "KEN-4", "gh-4", dir.path());
    fleet.set_lanes(vec![one.clone(), two.clone(), three.clone(), four.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    let mut answers: Vec<(String, Value)> = ["KEN-1", "KEN-2", "KEN-3", "KEN-4"]
        .into_iter()
        .flat_map(no_handoff)
        .collect();
    answers.extend(
        [
            ("capabilities", ok(SSH_LINE)),
            ("status --item KEN-1 --harness claude", ok("exited\n")),
            ("status --item KEN-2 --harness claude", ok("exited\n")),
            ("status --item KEN-3 --harness claude", ok("exited\n")),
            ("status --item KEN-4 --harness claude", ok("exited\n")),
            ("cat --item KEN-1 /remote/KEN-1/.git", answer(2, "")),
            ("touch --item KEN-1", ok("")),
            // No merged row: the gate alone keeps it open, its worktree gone.
            ("cat --item KEN-3 /remote/KEN-3/.git", answer(2, "")),
            ("touch --item KEN-3", ok("")),
            // Its worktree stands and its close-out removed its record.
            (
                "cat --item KEN-4 /x/tmp/workflow-state-KEN-4.json",
                answer(2, ""),
            ),
            ("touch --item KEN-4", ok("")),
        ]
        .map(|(argv, answer)| (argv.to_owned(), answer)),
    );
    world.plant_host_owned(&answers);
    world.plant_close(json!({
        "KEN-1": verb_reply("KEN-1", "closed", json!({"host_close": "kept=/archive/KEN-1"})),
        "KEN-3": verb_reply("KEN-3", "stopped", json!({"identity": "none"})),
        "KEN-4": verb_reply("KEN-4", "closed", json!({"host_close": "kept=/archive/KEN-4"})),
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    for (item, key) in [("KEN-1", "o/r#7"), ("KEN-2", "o/r#8"), ("KEN-4", "o/r#9")] {
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
            "EVENT lane-closed KEN-3",
            "kept=sandbox",
            "EVENT lane-exited gh-4",
            "EVENT lane-closed KEN-4",
            "kept=/archive/KEN-4",
        ]
    );
    assert_eq!(second.failed, None);
    assert_eq!(
        world.close_log(),
        vec![
            close_call(
                &driver.state_dir,
                r#"{"delivery":{"pr":{"pr":7,"repo":"o/r"}},"item":"KEN-1","op":"close-lane"}"#
            ),
            close_call(
                &driver.state_dir,
                r#"{"item":"KEN-3","mode":"keep-sandbox","op":"close-lane"}"#
            ),
            close_call(
                &driver.state_dir,
                r#"{"delivery":{"pr":{"pr":9,"repo":"o/r"}},"item":"KEN-4","op":"close-lane"}"#
            ),
        ]
    );
    let marker = hosted::close_marker_path(
        lanes::watch_state_dir(&driver.settings.claim_store),
        "KEN-1",
    );
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the close's marker stands"
    );
    // The record the close verb wrote, read on the next pass: the marker leaves.
    let mut closed = one;
    closed["status"] = json!("stopped");
    let mut kept = three;
    kept["status"] = json!("stopped");
    let mut done = four;
    done["status"] = json!("stopped");
    fleet.set_lanes(vec![closed, two, kept, done]);
    let third = driver.pass(&fleet.read());
    assert!(event_lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(third.failed, None);
    assert_eq!(world.close_log().len(), 3);
    assert!(std::fs::metadata(&marker).is_err());
}

/// A merged hosted lane read at work is closed once its work left its host:
/// its pane on the fleet server drawn at the harness's working hint and its
/// provider's status verb reading it running, the GitHub duty's merged row
/// standing and the host answering its `.git` absent, the first pass asks
/// the close verb with the merge as the delivery, `lane-closed` with its
/// archive line; the next pass, the same screen, asks nothing again.
#[test]
fn a_merged_hosted_lane_read_working_is_closed_once_its_work_left_its_host() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        "printf '✻ Working… (esc to interrupt)\\n'; exec sleep 600",
    );
    let mut lane = hosted_lane(dir.path(), "KEN-1", "gh-1", "/remote/KEN-1");
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    let mut answers = no_handoff("KEN-1");
    answers.extend(
        [
            ("capabilities", ok(SSH_LINE)),
            ("status --item KEN-1 --harness claude", ok("running\n")),
            ("cat --item KEN-1 /remote/KEN-1/.git", answer(2, "")),
            ("touch --item KEN-1", ok("")),
        ]
        .map(|(argv, answer)| (argv.to_owned(), answer)),
    );
    world.plant_host_owned(&answers);
    world.plant_close(json!({
        "KEN-1": verb_reply("KEN-1", "closed", json!({"host_close": "kept=/archive/KEN-1"})),
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    let said = lines(&first);
    assert!(
        said.contains(&"EVENT lane-closed KEN-1".to_owned()),
        "{said:?}"
    );
    assert_eq!(
        world.close_log(),
        vec![close_call(
            &driver.state_dir,
            r#"{"delivery":{"pr":{"pr":7,"repo":"o/r"}},"item":"KEN-1","op":"close-lane"}"#
        )]
    );
    let second = driver.pass(&state);
    assert!(
        !lines(&second).contains(&"EVENT lane-closed KEN-1".to_owned()),
        "{:?}",
        lines(&second)
    );
    assert_eq!(world.close_log().len(), 1, "one ask per screen");
}

/// The scripts directory a pass runs the real close verb from: `orch-runtime`
/// a wrapper that starts this build's binary in `project` under a cleared
/// environment, the `gh` fixture in `bin` first on its `PATH` with a fixture
/// token, the row's private tmux server as its fleet server and git's ceiling
/// at the temporary root, so `project` is its project root and nothing above
/// it is read; `project` holds the orch, github and mailbox packages' shipped
/// scripts, which the verb runs from there (the cycle recorder's
/// `pr-timeline`, the mailbox reader, `sync-base`).
fn real_close_scripts(dir: &Path, server: &Server, fleet: &Fleet) -> PathBuf {
    let project = dir.join("project");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    for package in ["orch", "github", "mailbox"] {
        let dest = project.join(".agents/skills").join(package);
        std::fs::create_dir_all(&dest).unwrap();
        let out = program("cp")
            .arg("-R")
            .arg(repo.join(package).join("scripts"))
            .arg(&dest)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(fixtures().join("gh/gh"), bin.join("gh")).unwrap();
    let scripts = dir.join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    let root = std::env::temp_dir();
    write_executable(
        &scripts.join(hosted::ORCH_RUNTIME),
        format!(
            "#!/bin/sh\ncd '{project}' || exit 1\nexec env -i PATH='{path}' LANG=C.UTF-8 TMPDIR='{root}' HOME='{home}' GIT_CEILING_DIRECTORIES='{ceiling}' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=fixture-token TMUX='{socket},0,0' AGENT_RUNTIME_TMUX_SESSION='{session}' AGENT_RUNTIME_ACCOUNT_STATE_DIR='{accounts}' '{binary}' --no-private-env \"$@\"\n",
            project = project.display(),
            path = tool_path(&[bin.as_path()]),
            root = root.display(),
            home = root.join("isolated-home").display(),
            ceiling = ceilings(&root).to_string_lossy(),
            socket = server.socket.display(),
            session = server.session,
            accounts = fleet.runner.state_dir().join("tmp/oversee-watch").display(),
            binary = binary().display(),
        ),
    );
    scripts
}

/// The fleet's slot charges as `lane charges` counts them, by account.
fn charges(fleet: &Fleet) -> Value {
    let out = fleet.runner.run(&["lane", "charges", "--fleet"]);
    reply(&out)["result"]["charges"].clone()
}

/// A merged local lane whose work left nothing behind is closed by the
/// watch's own pass whatever its screen reads, and its slot is free: a
/// local Claude Code lane drawn at the harness's working hint, its item's
/// live state record gone from the fleet's state directory, the GitHub
/// duty's merged row standing, is asked closed through the real close verb
/// with the merge as the delivery (its cycle recorded by the real
/// `pr-timeline` over the `gh` fixture); the pass says `lane-closed`, the
/// record reads done, the harness is ended, and `lane charges` counts one
/// slot fewer for the lane's account than before the pass.
#[test]
fn a_merged_local_lane_read_working_is_closed_by_the_watch_and_frees_its_slot() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let claude = named_sleep(dir.path(), "claude");
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        &format!(
            "bash -c \"printf '\\xe2\\x9c\\xbb Working\\xe2\\x80\\xa6 (esc to interrupt)\\n'; exec {} 600\"",
            claude.display()
        ),
    );
    let identity = await_named(&server, &pane, "claude");
    await_drawn(&server, &pane, "esc to interrupt");
    let worktree = dir.path().join("worktree");
    let mut lane = lane_record(
        "issue-1",
        "gh-1",
        "claude",
        &server,
        &pane,
        Some(&identity),
        &worktree,
    );
    lane["repo"] = json!("o/r");
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    let scripts = real_close_scripts(dir.path(), &server, &fleet);
    std::fs::write(
        dir.path().join("bin/gh.json"),
        json!({"graphql number=7 cursor=": pull_seven_timeline()}).to_string(),
    )
    .unwrap();
    let before = charges(&fleet);
    assert_eq!(before["/home/me/.eclaude"], json!(1), "{before}");
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts;
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "issue-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    let said = lines(&first);
    assert!(
        said.contains(&"EVENT lane-closed issue-1".to_owned()),
        "{said:?} {:?}",
        first.failed
    );
    let closed = fleet.read();
    let record = closed.lanes.iter().find(|l| l.item == "issue-1").unwrap();
    assert_eq!(record.status, state::LaneStatus::Done, "{record:?}");
    assert!(!live(identity.pid), "the harness was ended");
    let after = charges(&fleet);
    assert_eq!(
        after.get("/home/me/.eclaude"),
        None,
        "{before} then {after}"
    );
}

/// A merged local lane whose work left nothing behind is closed by the
/// watch's own pass at its finished line, and its slot is free: one local
/// Claude Code lane at its composer, read idle on two passes
/// (`idle-after-return`), and one whose harness ended and whose pane holds
/// only its shell, read exited on two passes (`lane-exited`), each with its
/// item's live state
/// record gone from the fleet's state directory and the GitHub duty's merged
/// row standing, are asked closed through the real close verb with their
/// merges as the deliveries; the pass says `lane-closed` for each, the
/// records read done, the idle lane's harness is ended, and `lane charges`
/// no longer counts its account, which it counted before the pass.
#[test]
fn a_merged_local_lane_read_idle_or_exited_is_closed_by_the_watch_and_frees_its_slot() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let claude = named_sleep(dir.path(), "claude");
    let idle = server.open_window(
        "gh-1",
        dir.path(),
        &format!(
            "bash -c \"printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; exec {} 600\"",
            claude.display()
        ),
    );
    let identity = await_named(&server, &idle, "claude");
    await_drawn(&server, &idle, "❯");
    let exited = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    await_bare(&server, &exited);
    // The second lane's harness ran and ended: its launch identity names a
    // process that is gone, and its pane holds only its shell.
    let mut harness = std::process::Command::new(&claude)
        .arg("600")
        .spawn()
        .unwrap();
    let Reading::Live(ended) = agent_runtime::process::identity(harness.id()) else {
        panic!("the harness's identity did not read");
    };
    harness.kill().unwrap();
    harness.wait().unwrap();
    let mut one = lane_record(
        "issue-1",
        "gh-1",
        "claude",
        &server,
        &idle,
        Some(&identity),
        &dir.path().join("worktree-1"),
    );
    one["repo"] = json!("o/r");
    let mut two = lane_record(
        "issue-2",
        "gh-2",
        "claude",
        &server,
        &exited,
        Some(&ended),
        &dir.path().join("worktree-2"),
    );
    two["repo"] = json!("o/r");
    two["account"] = json!("/home/me/.fclaude");
    fleet.set_lanes(vec![one, two]);
    let state = fleet.read();
    let scripts = real_close_scripts(dir.path(), &server, &fleet);
    let mut eight = pull_seven_timeline();
    eight["body"]["data"]["repository"]["pullRequest"]["number"] = json!(8);
    std::fs::write(
        dir.path().join("bin/gh.json"),
        json!({
            "graphql number=7 cursor=": pull_seven_timeline(),
            "graphql number=8 cursor=": eight,
        })
        .to_string(),
    )
    .unwrap();
    let before = charges(&fleet);
    assert_eq!(
        (
            before.get("/home/me/.eclaude"),
            before.get("/home/me/.fclaude")
        ),
        (Some(&json!(1)), None),
        "an ended harness charges no slot: {before}"
    );
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts;
    for (item, merged) in [("issue-1", "o/r#7"), ("issue-2", "o/r#8")] {
        driver.baseline.apply(Change::Set {
            kind: "merged".into(),
            identity: item.into(),
            value: merged.into(),
        });
    }
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    let said = event_lines(&second);
    for line in [
        "EVENT idle-after-return gh-1",
        "EVENT lane-exited gh-2",
        "EVENT lane-closed issue-1",
        "EVENT lane-closed issue-2",
    ] {
        assert!(
            said.contains(&line.to_owned()),
            "{line}: {said:?} {:?}",
            second.failed
        );
    }
    let closed = fleet.read();
    for item in ["issue-1", "issue-2"] {
        let record = closed.lanes.iter().find(|l| l.item == item).unwrap();
        assert_eq!(record.status, state::LaneStatus::Done, "{record:?}");
    }
    assert!(!live(identity.pid), "the harness was ended");
    let after = charges(&fleet);
    assert_eq!(
        (
            after.get("/home/me/.eclaude"),
            after.get("/home/me/.fclaude")
        ),
        (None, None),
        "{before} then {after}"
    );
}

/// pr-timeline's one GraphQL read of the merged pull request 7, its three
/// selections of `commits` planted under their arguments.
fn pull_seven_timeline() -> Value {
    json!({"body": {"data": {"repository": {"pullRequest": {
        "number": 7, "state": "MERGED", "body": "", "createdAt": "2026-09-20T09:10:00Z", "mergedAt": "2026-09-20T11:20:00Z",
        "author": {"login": "lane-app"}, "headRefName": "", "headRepository": null,
        "mergeCommit": {"__typename": "Commit", "oid": "m1",
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}},
        "commits(first: 1)": {"nodes": [{"commit": {"authoredDate": "2026-09-20T09:00:00Z"}}]},
        "commits(last: 1)": {"nodes": [{"commit": {"__typename": "Commit", "oid": "h2", "committedDate": "2026-09-20T10:10:00Z",
            "status": {"context": {"state": "SUCCESS", "createdAt": "2026-09-20T10:25:00Z"}},
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}]},
        "commits(last: 100)": {"totalCount": 0, "nodes": []},
        "reviews": {"totalCount": 0, "nodes": []},
        "timelineItems": {"pageInfo": {"hasNextPage": false}, "nodes": []}
    }}}}})
}

/// A close the tracker's quota refusal deferred has its `lane-exited` line
/// already reported, so the deferred close keeps `close-pending` as
/// `lane-exited|<pane key>`; the next pass, its line still reported under
/// that key, asks again and closes.
#[test]
fn a_finished_hosted_close_the_tracker_hold_deferred_is_retried_while_its_line_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (one, pane) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    fleet.set_lanes(vec![one.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    let mut answers = no_handoff("KEN-1");
    answers.extend(
        [
            ("capabilities", ok(SSH_LINE)),
            ("status --item KEN-1 --harness claude", ok("exited\n")),
            ("cat --item KEN-1 /remote/KEN-1/.git", answer(2, "")),
            ("touch --item KEN-1", ok("")),
        ]
        .map(|(argv, answer)| (argv.to_owned(), answer)),
    );
    world.plant_host_owned(&answers);
    world.plant_close(quota_reply("KEN-1"));
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
    world.plant_close(verb_reply(
        "KEN-1",
        "closed",
        json!({"host_close": "kept=/archive/KEN-1"}),
    ));
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

/// A walled hosted lane's harness must not run on beside the successor the
/// relaunch opens: a walled lane whose kind declares a local pane has its
/// harness stopped through `lane-host stop --item --harness` under the
/// record's host before the relaunch starts; a stop the provider refuses,
/// or answers with exit 0 and a line that is not `stopped item=ITEM
/// processes=N`, leaves the wall to the overseer with
/// `wall-relaunch-refused reason=stop-failed` and the status under the
/// line, and nothing starts. So does a stop that gave no answer, a status
/// of 128 and above (a signal, the ssh provider's 255), said
/// `reason=stop-unanswered`, since the harness may still run.
#[test]
fn a_walled_hosted_pane_local_lane_is_stopped_through_the_provider_before_its_relaunch() {
    for (stop, refused) in [
        (ok("stopped item=KEN-4 processes=1\n"), None),
        (
            json!({"exit": 4, "stderr": "lane-host: stop-worktree-removed item=KEN-4\n"}),
            Some("stop-failed exit=4"),
        ),
        (ok("stopped item=KEN-4\n"), Some("stop-failed exit=0")),
        (json!({"exit": 137}), Some("stop-unanswered stop exit=137")),
        (json!({"exit": 255}), Some("stop-unanswered stop exit=255")),
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
        record["host"] = json!(provider(dir.path()));
        record["kind"] = json!("ssh");
        // A record the runtime's launch wrote: the lane's root is on its
        // host, and the checkout the launch ran from, where the relaunch
        // runs again, is the only local directory it names.
        record.as_object_mut().unwrap().remove("recovery");
        let remote_root = dir.path().join("only-on-the-remote-host");
        record["mail_root"] = json!(remote_root.display().to_string());
        record["checkout"] = json!(dir.path().display().to_string());
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        let world = HostedWorld::new(dir.path());
        let status_file = format!(
            "cat --item KEN-4 {}/tmp/lane-status-KEN-4.md",
            remote_root.display()
        );
        world.plant_host(&[
            ("capabilities", ok(SSH_LINE)),
            ("status --item KEN-4 --harness claude", ok("running\n")),
            (status_file.as_str(), ok("Step: start\n")),
            ("stop --item KEN-4 --harness claude", stop),
        ]);
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = world.scripts.clone();
        driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
        let produced = driver.pass(&state);
        let stop_line = format!(
            "ORCH_LANE_HOST={} stop --item KEN-4 --harness claude",
            provider(dir.path())
        );
        assert!(
            world.host_log().contains(&stop_line),
            "{:?}",
            world.host_log()
        );
        let started = driver.relaunches.borrow();
        if let Some(status) = refused {
            assert!(
                lines(&produced)
                    .contains(&format!("wall-relaunch-refused lane=gh-4 reason={status}")),
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
            assert_eq!(request["host"], provider(dir.path()), "{request}");
            assert_eq!(request["kind"], "ssh", "{request}");
            assert_eq!(
                request["mail_root"],
                dir.path().canonicalize().unwrap().display().to_string(),
                "the relaunch runs from the checkout, not the host's root: {request}"
            );
        }
    }
}

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
        json!({"item": item, "harness": "claude", "host": provider(dir.path()), "kind": "ssh", "status": status, "prepare": record})
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

#[test]
fn the_wall_relaunch_retires_the_walled_harness_and_relaunches_it_through_the_runtime() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let checkout = dir.path().join("checkout");
    std::fs::create_dir_all(&checkout).unwrap();
    let init = program("git")
        .args(["-C", &checkout.display().to_string(), "init", "-q"])
        .output()
        .unwrap();
    assert!(init.status.success(), "{}", stderr(&init));
    fleet_origin(&fleet, &checkout);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    let old_account = dir.path().join("old-account");
    let new_account = dir.path().join("new-account");
    std::fs::create_dir_all(&old_account).unwrap();
    std::fs::create_dir_all(&new_account).unwrap();
    let mut record = relaunchable(
        lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            &checkout,
        ),
        &checkout,
    );
    // A released record names its model and effort, in its fields and in
    // the flags `main` recorded as given: its launch refused a lane on an
    // account without either.
    record["effort"] = json!("high");
    record["recovery"]["flags"] = json!("--model opus --effort high");
    record["account"] = json!(old_account.display().to_string());
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    let scripts = dir.path().join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts;
    driver.pick = Pick::Lane(new_account.display().to_string());
    let produced = driver.pass(&state);
    assert_eq!(
        driver.relaunches.borrow().len(),
        1,
        "{:?}",
        lines(&produced)
    );
    let relaunch = driver.relaunches.borrow()[0].clone();
    let out = run_relaunch(&fleet, &relaunch);
    assert!(
        out.status.success(),
        "the relaunch's requests were refused: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    assert!(
        !live(identity.pid),
        "the walled harness was retired before the replacement was asked"
    );
    let lane = &fleet.runner.fleet()["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["account"], new_account.display().to_string(), "{lane}");
    assert_ne!(lane["launch"]["pane"], pane, "a new window: {lane}");
    let recorded: Value = serde_json::from_str(
        &std::fs::read_to_string(checkout.join("launch-record.json")).unwrap(),
    )
    .unwrap();
    assert!(
        recorded["argv"].as_array().unwrap().iter().any(|a| a
            .as_str()
            .is_some_and(|text| text.starts_with("/orch start KEN-4 This is an unattended"))),
        "the fresh replacement starts on the start brief: {recorded}"
    );
    assert_eq!(
        recorded["env"]["CLAUDE_CONFIG_DIR"],
        new_account.display().to_string()
    );
    effect_report(&fleet.runner.op_fleet(&json!({
        "op": "close-owned-resources",
        "item": "KEN-4",
        "terminal": {"verdict": "completed", "source": "test"},
    })));
}

/// The detached line as its starter runs it: the entry's word first, in the
/// lane's checkout with the recorded session and the runner's environment.
fn run_relaunch(fleet: &Fleet, relaunch: &Relaunch) -> std::process::Output {
    let mut command = program(&relaunch.args[0]);
    command
        .args(&relaunch.args[1..])
        .current_dir(&relaunch.cwd)
        .env("AGENT_RUNTIME_TMUX_SESSION", &relaunch.session);
    fleet.runner.apply_env(&mut command);
    command.output().unwrap()
}

/// The close retires the walled harness, then the replacement's effect
/// fails: on a Claude account whose config answers no to the checkout's
/// trust, and under a provider whose `create` fails after its `stop`. The
/// wrapper's status file is written as the starter writes it, and the
/// outcome reader runs on it.
#[test]
fn a_wall_relaunch_whose_replacement_effect_fails_is_said_failed_not_relaunched() {
    for hosted in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut fleet = Fleet::new(&server);
        fleet.runner.verify = Some(3);
        let checkout = dir.path().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let init = program("git")
            .args(["-C", &checkout.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(init.status.success(), "{}", stderr(&init));
        fleet_origin(&fleet, &checkout);
        let checkout = checkout.canonicalize().unwrap();
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let old_account = dir.path().join("old-account");
        let new_account = dir.path().join("new-account");
        std::fs::create_dir_all(&old_account).unwrap();
        std::fs::create_dir_all(&new_account).unwrap();
        let account = new_account.display().to_string();
        let mut record = relaunchable(
            lane_record(
                "KEN-4",
                "gh-4",
                "claude",
                &server,
                &pane,
                Some(&identity),
                &checkout,
            ),
            &checkout,
        );
        // A released record names its model and effort, in its fields and in
        // the flags `main` recorded as given: its launch refused a lane on an
        // account without either.
        record["effort"] = json!("high");
        record["recovery"]["flags"] = json!("--model opus --effort high");
        record["account"] = json!(old_account.display().to_string());
        let world = HostedWorld::new(dir.path());
        // The relaunch runs the real runtime through its entry, in the
        // close stand-in's place.
        std::fs::remove_file(world.scripts.join("orch-runtime")).unwrap();
        std::os::unix::fs::symlink(binary(), world.scripts.join("orch-runtime")).unwrap();
        if hosted {
            // The launch finds its provider under the checkout's package.
            let package = checkout.join(".agents/skills/orch");
            std::fs::create_dir_all(&package).unwrap();
            std::os::unix::fs::symlink(&world.scripts, package.join("scripts")).unwrap();
            let remote = dir.path().join("remote-worktree").display().to_string();
            record.as_object_mut().unwrap().remove("recovery");
            record["host"] = json!(provider(dir.path()));
            record["kind"] = json!("ssh");
            record["repo"] = json!("o/r");
            record["checkout"] = json!(checkout.display().to_string());
            record["mail_root"] = json!(remote);
            let status = format!("cat --item KEN-4 {remote}/tmp/lane-status-KEN-4.md");
            let create = format!(
                "create --item KEN-4 --repo o/r --harness claude --account {account} --relaunch"
            );
            world.plant_host(&[
                ("capabilities", ok(SSH_LINE)),
                ("status --item KEN-4 --harness claude", ok("running\n")),
                (status.as_str(), ok("Step: start\n")),
                (
                    "stop --item KEN-4 --harness claude",
                    ok("stopped item=KEN-4 processes=1\n"),
                ),
                (
                    create.as_str(),
                    json!({"exit": 1, "stderr": "lane-host: create-failed item=KEN-4\n"}),
                ),
            ]);
        } else {
            std::fs::write(
                new_account.join(".claude.json"),
                json!({"projects": {checkout.display().to_string(): {"hasTrustDialogAccepted": false}}})
                    .to_string(),
            )
            .unwrap();
        }
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = world.scripts.clone();
        driver.pick = Pick::Lane(account.clone());
        let produced = driver.pass(&state);
        assert_eq!(
            driver.relaunches.borrow().len(),
            1,
            "hosted={hosted}: {:?}",
            lines(&produced)
        );
        let relaunch = driver.relaunches.borrow()[0].clone();
        let out = run_relaunch(&fleet, &relaunch);
        let reply: Value = serde_json::from_str(
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .last()
                .unwrap_or(""),
        )
        .unwrap_or(Value::Null);
        let cause = reply["result"]["effect"]["report"]["intent"]["observation"]["cause"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        let expected = if hosted {
            "host-create-failed"
        } else {
            "trust-refused"
        };
        assert!(
            cause.starts_with(expected),
            "hosted={hosted}: the replacement's own failure: {reply}\n{}",
            stderr(&out)
        );
        assert!(
            !live(identity.pid),
            "hosted={hosted}: the close retired the walled harness first"
        );
        assert_eq!(
            fleet.runner.fleet()["lanes"][0]["status"],
            "stopped",
            "hosted={hosted}"
        );
        let code = out.status.code().unwrap();
        assert_ne!(
            code, 0,
            "hosted={hosted}: a failed replacement is no success"
        );
        std::fs::write(
            overseer::relaunch_exit_path(&relaunch.marker),
            format!("{code}\n"),
        )
        .unwrap();
        let outcomes = overseer::relaunch_outcomes(
            lanes::watch_state_dir(&driver.settings.claim_store),
            &fleet.read(),
            driver.settings.watch.get().unwrap().prepare,
            driver.now,
            &driver.baseline,
        );
        assert_eq!(
            lines(&outcomes),
            vec![format!(
                "EVENT lane-prepare-failed KEN-4 reason=relaunch-failed exit={code} log={}",
                relaunch.log.display()
            )],
            "hosted={hosted}"
        );
    }
}

#[test]
fn an_unconfirmed_wall_replacement_keeps_its_marker_until_its_launch_settles_and_a_later_failure_is_said_once()
 {
    // Whether the replacement reaches its composer before its reconcile.
    for confirms in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut fleet = Fleet::new(&server);
        fleet.runner.verify = Some(1);
        fleet.runner.stub = fixtures().join("stub-late/claude");
        let checkout = dir.path().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let init = program("git")
            .args(["-C", &checkout.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(init.status.success(), "{}", stderr(&init));
        fleet_origin(&fleet, &checkout);
        let checkout = checkout.canonicalize().unwrap();
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let old_account = dir.path().join("old-account");
        let new_account = dir.path().join("new-account");
        std::fs::create_dir_all(&old_account).unwrap();
        std::fs::create_dir_all(&new_account).unwrap();
        let mut record = relaunchable(
            lane_record(
                "KEN-4",
                "gh-4",
                "claude",
                &server,
                &pane,
                Some(&identity),
                &checkout,
            ),
            &checkout,
        );
        // A released record names its model and effort, in its fields and in
        // the flags `main` recorded as given: its launch refused a lane on an
        // account without either.
        record["effort"] = json!("high");
        record["recovery"]["flags"] = json!("--model opus --effort high");
        record["account"] = json!(old_account.display().to_string());
        fleet.set_lanes(vec![record]);
        let scripts = dir.path().join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = scripts;
        driver.pick = Pick::Lane(new_account.display().to_string());
        let produced = driver.pass(&fleet.read());
        assert_eq!(
            driver.relaunches.borrow().len(),
            1,
            "{:?}",
            lines(&produced)
        );
        let relaunch = driver.relaunches.borrow()[0].clone();
        let out = run_relaunch(&fleet, &relaunch);
        let code = out.status.code().unwrap();
        assert_eq!(
            code,
            agent_runtime::effects::UNCONFIRMED_EXIT,
            "confirms={confirms}: the chain answers its launch's open outcome: {}",
            stderr(&out)
        );
        assert!(!live(identity.pid), "the close retired the walled harness");
        std::fs::write(
            overseer::relaunch_exit_path(&relaunch.marker),
            format!("{code}\n"),
        )
        .unwrap();
        let outcomes = |driver: &mut LaneDriver<'_>| {
            let produced = overseer::relaunch_outcomes(
                lanes::watch_state_dir(&driver.settings.claim_store),
                &fleet.read(),
                driver.settings.watch.get().unwrap().prepare,
                driver.now,
                &driver.baseline,
            );
            apply(&mut driver.baseline, &produced);
            lines(&produced)
        };
        assert!(outcomes(&mut driver).is_empty(), "confirms={confirms}");
        assert!(
            relaunch.marker.exists(),
            "confirms={confirms}: the pending marker stands"
        );
        let replacement = fleet.runner.fleet()["intents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["op"] == "launch-session")
            .and_then(|i| i["phase"]["pane"].as_str())
            .expect("the open launch names its window")
            .to_owned();
        if confirms {
            std::fs::write(checkout.join(".stub-composer"), "").unwrap();
        } else {
            let ended = tmux(&server.socket, &["kill-pane", "-t", &replacement]);
            assert!(ended.status.success());
        }
        let settled = fleet.runner.reconcile_one();
        let expected = if confirms { "confirmed" } else { "failed" };
        assert_eq!(settled["intent"]["outcome"], expected, "{settled}");
        let said = outcomes(&mut driver);
        if confirms {
            assert!(said.is_empty(), "a confirmation says nothing: {said:?}");
        } else {
            assert_eq!(
                said,
                vec![format!(
                    "EVENT lane-prepare-failed KEN-4 reason=relaunch-failed log={}",
                    relaunch.log.display()
                )]
            );
        }
        assert!(
            !relaunch.marker.exists(),
            "confirms={confirms}: settled, the marker leaves"
        );
        assert!(
            outcomes(&mut driver).is_empty(),
            "confirms={confirms}: said once"
        );
    }
}

// ---------------------------------------------------------------------------
// The dead replay from the record's own fields and the walled case the walk
// answers none for.
// ---------------------------------------------------------------------------

/// A record carrying no launch line, as the row plants it with the field
/// removed, holds its successor in the record's own typed fields: the
/// transfer asked for carries them, a fresh session with no resume and no
/// line.
#[test]
fn a_dead_controller_is_replayed_from_its_records_own_fields_with_no_launch_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("overseer", dir.path(), "bash --norc --noprofile");
    let window = window_of(&server, &pane);
    let mut record = overseer_at(&server, &pane, &window, dir.path());
    record.as_object_mut().unwrap().remove("launch_line");
    record["effort"] = json!("high");
    record["permission"] = json!("bypass");
    record["extra_args"] = json!(["--verbose"]);
    fleet.set_overseer(record);
    let state = fleet.read();
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    let key = format!("{} {pane}", server.pid);
    for _ in 0..3 {
        driver.pass(&state);
    }
    assert_eq!(
        driver.baseline.get("overseer-dead", &key),
        Some("requested")
    );
    let asked = transfers.borrow();
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].cause, TransferCause::Dead);
    let successor = &asked[0].successor;
    assert_eq!(successor.resume, None);
    assert_eq!(successor.harness.as_deref(), Some("claude"));
    assert_eq!(successor.account.as_deref(), Some("/home/me/.eclaude"));
    assert_eq!(successor.home, None, "the launch prepares the home");
    assert_eq!(successor.model.as_deref(), Some("opus"));
    assert_eq!(successor.effort.as_deref(), Some("high"));
    assert_eq!(
        successor.cwd.as_deref(),
        Some(dir.path().display().to_string().as_str())
    );
    assert_eq!(
        successor.permission,
        Some(agent_runtime::launch::Permission::Bypass)
    );
    assert_eq!(successor.extra_args, vec!["--verbose".to_owned()]);
}

/// The walk answering `none` marks the row reported with no request made;
/// the walk choosing an entry of another harness opens that harness under
/// the full bypass with none of the caller's words.
#[test]
fn a_walled_controller_is_held_where_the_walk_chooses_none_and_crosses_harness_on_its_choice() {
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
    record["extra_args"] = json!(["--dangerously-skip-permissions"]);
    fleet.set_overseer(record);
    let state = fleet.read();
    let asked: RefCell<Vec<WalkRequest>> = RefCell::new(Vec::new());
    let walk_none = |request: &WalkRequest| {
        asked.borrow_mut().push(request.clone());
        Ok(Walked {
            answer: WalkAnswer::None,
            walk: "claude:opus:high".to_owned(),
            entries: 1,
            skipped: Vec::new(),
            walled: 1,
            unmeasured: 0,
            unread: Vec::new(),
            deprecated: Vec::new(),
        })
    };
    overseer_driver!(
        server, fleet, reached, walk_none, readers, transfers, driver
    );
    let key = format!("{} {pane}", server.pid);
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("reported")
    );
    assert!(transfers.borrow().is_empty(), "nothing is asked for");
    {
        let walks = asked.borrow();
        assert_eq!(walks.len(), 1);
        assert_eq!(walks[0].exclude, vec!["/home/me/.eclaude".to_owned()]);
        assert_eq!(
            walks[0].source.as_ref().and_then(|s| s.flags.clone()),
            Some(vec!["--dangerously-skip-permissions".to_owned()])
        );
        assert_eq!(
            walks[0].caller.as_ref().map(|c| c.harness),
            Some(Harness::Claude)
        );
    }
    let third = driver.pass(&state);
    assert!(lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(
        asked.borrow().len(),
        1,
        "a reported wall is not walked again"
    );
    let walk_codex = |_: &WalkRequest| {
        Ok(Walked {
            answer: WalkAnswer::Lane(Box::new(Chosen {
                entry: "codex:standard:high".to_owned(),
                harness: Harness::Codex,
                host: None,
                model: String::new(),
                class: Some("standard".to_owned()),
                effort: "high".to_owned(),
                pick_model: String::new(),
                account: Some("/home/me/.codex".to_owned()),
                record: None,
                warning: None,
                launch: None,
                kept: false,
                kept_unmeasured: false,
            })),
            walk: "codex:standard:high".to_owned(),
            entries: 1,
            skipped: Vec::new(),
            walled: 0,
            unmeasured: 0,
            unread: Vec::new(),
            deprecated: Vec::new(),
        })
    };
    overseer_driver!(
        server, fleet, reached, walk_codex, readers2, transfers2, crossed
    );
    crossed.pass(&state);
    crossed.pass(&state);
    let asked = transfers2.borrow();
    assert_eq!(asked.len(), 1);
    let successor = &asked[0].successor;
    assert_eq!(successor.harness.as_deref(), Some("codex"));
    assert_eq!(successor.account.as_deref(), Some("/home/me/.codex"));
    assert_eq!(successor.home, None, "the launch prepares the home");
    assert_eq!(successor.model, None);
    assert_eq!(successor.effort.as_deref(), Some("high"));
    assert_eq!(successor.class.as_deref(), Some("standard"));
    assert_eq!(
        successor.permission,
        Some(agent_runtime::launch::Permission::Bypass)
    );
    assert!(successor.extra_args.is_empty());
}

/// A walled overseer's hand-over that finds no successor names, on the
/// line the watch prints at that pass, each provider whose entries the walk
/// passed over and why: from the walk's `host-unread` rows where it judged
/// another entry and found no room, from its refusal where it judged none.
/// The row stays `reported`, so the line is said once.
#[test]
fn a_walled_controller_with_no_successor_names_each_unread_host_and_its_cause() {
    let busy = "host-busy count=4 cap=4 verb=accounts item=- step=accounts";
    let failed = "host-accounts-unreadable host=vm2 exit=1 down";
    let skip = |entry: &str, host: &str, cause: &str| json!({"entry": entry, "reason": "host-unread", "lane": null, "host": host, "cause": cause});
    let judged_none = Walked {
        answer: WalkAnswer::None,
        walk: "claude@vm:opus:high,codex@vm:gpt:high,claude@vm2:opus:high,claude:opus:high"
            .to_owned(),
        entries: 4,
        skipped: vec![
            skip("claude@vm:opus:high", "vm", busy),
            skip("codex@vm:gpt:high", "vm", busy),
            skip("claude@vm2:opus:high", "vm2", failed),
            json!({"entry": "claude:opus:high", "reason": "walled", "lane": null}),
        ],
        walled: 1,
        unmeasured: 0,
        unread: vec![
            "claude@vm:opus:high".to_owned(),
            "codex@vm:gpt:high".to_owned(),
            "claude@vm2:opus:high".to_owned(),
        ],
        deprecated: Vec::new(),
    };
    let cases: [(&str, orch_runtime::error::Result<Walked>, String); 2] = [
        (
            "judged and no room",
            Ok(judged_none),
            format!("account-unjudged step=host host=vm cause={busy} host=vm2 cause={failed}"),
        ),
        (
            "none judged",
            Err(agent_runtime::Error::refused(
                "account-unjudged",
                &[("step", "host"), ("host", "vm2"), ("cause", failed)],
            )
            .into()),
            format!("account-unjudged step=host host=vm2 cause={failed}"),
        ),
    ];
    for (case, answer, line) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, window) = walled_overseer(dir.path(), &server, &fleet);
        let state = fleet.read();
        let answer = RefCell::new(Some(answer));
        let walk = |_: &WalkRequest| answer.borrow_mut().take().expect("one walk per wall");
        overseer_driver!(server, fleet, reached, walk, readers, transfers, driver);
        let key = format!("{} {pane}", server.pid);
        let first = driver.pass(&state);
        assert!(
            lines(&first)[0].starts_with(&format!("EVENT overseer-walled {pane} window={window}")),
            "{case}: {:?}",
            lines(&first)
        );
        let handed_over = driver.pass(&state);
        assert_eq!(lines(&handed_over), vec![line], "{case}");
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("reported"),
            "{case}"
        );
        assert!(
            transfers.borrow().is_empty(),
            "{case}: nothing is asked for"
        );
        let after = driver.pass(&state);
        assert!(lines(&after).is_empty(), "{case}: {:?}", lines(&after));
    }
}

/// A Claude overseer walled by its weekly limit, its pane and window.
fn walled_overseer(dir: &Path, server: &Server, fleet: &Fleet) -> (String, String) {
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
    let rows_file = dir.join("session-rows.jsonl");
    std::fs::write(
        &rows_file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\",\"message\":\"You've hit your weekly limit · resets Oct 4\"}\n",
    )
    .unwrap();
    let mut record = overseer_at(server, &pane, &window, dir);
    record["session_rows"] = json!(rows_file.display().to_string());
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    (pane, window)
}

#[test]
fn a_walled_github_lane_s_replacement_starts_on_the_brief_naming_its_repository_issue() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-12", BANNER);
    let mut record = relaunchable(
        lane_record(
            "issue-12",
            "gh-12",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ),
        dir.path(),
    );
    record["tracker"] = json!("github");
    record["repo"] = json!("owner/name");
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    let produced = driver.pass(&state);
    assert_eq!(
        driver.relaunches.borrow().len(),
        1,
        "{:?}",
        lines(&produced)
    );
    let brief =
        std::fs::read_to_string(driver.state_dir.join("wall-relaunch-issue-12.md")).unwrap();
    assert!(
        brief.starts_with("/orch start github owner/name#12 This is an unattended orch lane"),
        "{brief}"
    );
}

/// The scripts directory of the orch package this test tree is under: the
/// real `copilot-statusline` writer runs from it.
fn orch_scripts() -> PathBuf {
    fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("scripts")
}

/// The duty's side of the provider's running answer: a hosted lane of a
/// `pane=local` kind has a shell for its local transport pane, so the
/// provider's answer is the process proof and the local pane's screen is
/// judged with it: a shell drawing Codex's idle screen is
/// `idle-after-return`, never exited, and no capture is asked; a provider
/// line naming no `pane` is the same kind. A transport pane its server keeps
/// dead ended the transport alone: unreadable with its cause, never exited.
#[test]
fn a_hosted_lane_the_provider_reads_running_is_never_exited_off_its_transport_shell() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        "printf '%s\\n' '› complete' '› Type a prompt'; exec bash --norc --noprofile",
    );
    let mut one = hosted_lane(dir.path(), "KEN-1", "gh-1", "/remote/KEN-1");
    one["harness"] = json!("codex");
    one["launch"] = json!({"pane": pane, "server": server.pid});
    let dead = server.open_kept_dead("gh-2", dir.path());
    let mut two = hosted_lane(dir.path(), "KEN-2", "gh-2", "/remote/KEN-2");
    two["harness"] = json!("codex");
    two["launch"] = json!({"pane": dead, "server": server.pid});
    fleet.set_lanes(vec![one, two]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (
            &format!("{} capabilities", provider(dir.path())),
            ok(SSH_LINE),
        ),
        ("status --item KEN-1 --harness codex", ok("running\n")),
        ("status --item KEN-2 --harness codex", ok("running\n")),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let all: Vec<String> = (0..2)
        .flat_map(|_| event_lines(&driver.pass(&state)))
        .collect();
    assert!(
        !all.iter().any(|l| l.starts_with("EVENT lane-exited")),
        "{all:?}"
    );
    assert!(
        all.iter().any(|l| l == "EVENT idle-after-return gh-1"),
        "{all:?}"
    );
    assert!(
        all.iter()
            .any(|l| l == "EVENT lane-unreadable gh-2 cause=pane-dead"),
        "{all:?}"
    );
    let log = world.host_log();
    assert!(!log.iter().any(|l| l.contains("capture")), "{log:?}");
}

/// The scripts directory of a row's provider world: `provider`, the
/// shared provider fixture under a link of its own, logging each call as
/// `ORCH_LANE_HOST=<value|unset> <argv>` to `lane-host.log` beside it, its
/// world (its `disk`, `provider.json` and `provider.log`) this directory.
fn provider_world(dir: &Path) -> PathBuf {
    let scripts = dir.join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    write_executable(
        &scripts.join("provider"),
        format!(
            "#!/bin/sh\nprintf 'ORCH_LANE_HOST=%s %s\\n' \"${{ORCH_LANE_HOST-unset}}\" \"$*\" >> '{log}'\nLANE_HOST_WORLD='{world}' exec '{provider}' \"$@\"\n",
            log = scripts.join("lane-host.log").display(),
            world = scripts.display(),
            provider = fixtures().join("lane-host/provider").display(),
        ),
    );
    scripts
}

/// `text` written at `path` under the host's `disk`.
fn on_disk(disk: &Path, path: &str, text: &str) {
    let file = disk.join(path.trim_start_matches('/'));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(file, text).unwrap();
}

/// Through the real `lane-host` to a provider serving the host's disk: the
/// host's last row, a turn ended on the account's limit, is `usage-limit`;
/// a file at the same path on this disk is never read. The fleet record is
/// a hosted record planted as `main` wrote it (`host` the provider, `kind`
/// `ssh`, `mail_root` the root on the host).
#[test]
fn a_hosted_pi_lanes_rows_are_read_through_its_provider() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pi = named_sleep(dir.path(), "pi");
    let line = format!("printf 'pi drew this\\n'; exec {} 600", pi.display());
    let pane = server.open_window("gh-5", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &pane, "pi");
    await_drawn(&server, &pane, "pi drew this");
    let root = dir.path().join("remote").join("KEN-5");
    let rows = root.join("tmp/lane-mail/KEN-5/session-rows.jsonl");
    std::fs::create_dir_all(rows.parent().unwrap()).unwrap();
    std::fs::write(
        &rows,
        "{\"harness\":\"pi\",\"event\":\"PreToolUse\",\"at\":2}\n",
    )
    .unwrap();
    let scripts = provider_world(dir.path());
    let disk = scripts.join("disk");
    on_disk(
        &disk,
        &rows.display().to_string(),
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"error\",\"message\":\"429 Usage limit reached for this model\",\"at\":3}\n",
    );
    let mut record = lane_record(
        "KEN-5",
        "gh-5",
        "pi",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    );
    record["host"] = json!(provider(dir.path()));
    record["kind"] = json!("ssh");
    record["mail_root"] = json!(root.display().to_string());
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts.clone();
    let produced = driver.pass(&state);
    assert_eq!(
        event_lines(&produced),
        vec!["EVENT usage-limit gh-5 /home/me/.eclaude".to_owned()],
        "{:?} {:?}",
        lines(&produced),
        produced.failed
    );
    let asked = std::fs::read_to_string(scripts.join("provider.log")).unwrap_or_default();
    assert!(
        asked.lines().any(|l| l
            == format!(
                "ORCH_LANE_HOST={} cat --item KEN-5 {}",
                provider(dir.path()),
                rows.display()
            )),
        "{asked}"
    );
}

/// Through the real `lane-host` to a provider serving the host's disk, the
/// record is read in both places the local read names: the clone its `.git`
/// names under the state directory its settings name (none: `tmp`), and the
/// lane root's `tmp`, where a lane whose launch forbids writing the main
/// checkout keeps it. Either is `handoff` with the record under it once; a
/// state the host serves that is no JSON object is the pass's
/// `handoff-read-failed`, never no handoff. The fleet record is a hosted
/// record planted as `main` wrote it (`host` the provider, `kind` `ssh`,
/// `mail_root` the root on the host).
#[test]
fn a_hosted_lanes_handoff_is_read_through_its_provider() {
    let handoff = r#"{"merged":[],"remaining":["review"],"branch":"b","worktree":"/remote/KEN-4","open_pr":null,"traps":[]}"#;
    let record_doc = format!("{{\"handoff\":{handoff}}}\n");
    let clone = "/remote/clone/tmp/workflow-state-KEN-4.json";
    let root = "/remote/KEN-4/tmp/workflow-state-KEN-4.json";
    for (case, place, text) in [
        ("the clone's state", clone, record_doc.as_str()),
        ("the root's tmp", root, record_doc.as_str()),
        ("a state that is no JSON", clone, "not json\n"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let claude = named_sleep(dir.path(), "claude");
        let line = format!("printf 'working\\n'; exec {} 600", claude.display());
        let pane = server.open_window("gh-4", dir.path(), &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, "claude");
        let scripts = provider_world(dir.path());
        let disk = scripts.join("disk");
        on_disk(
            &disk,
            "/remote/KEN-4/.git",
            "gitdir: /remote/clone/.git/worktrees/KEN-4\n",
        );
        on_disk(&disk, place, text);
        let mut record = lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        );
        record["host"] = json!(provider(dir.path()));
        record["kind"] = json!("ssh");
        record["mail_root"] = json!("/remote/KEN-4");
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = scripts.clone();
        let first = driver.pass(&state);
        if text == record_doc {
            let said: Vec<String> = lines(&first)
                .into_iter()
                .skip_while(|l| l != "EVENT handoff KEN-4")
                .take(2)
                .collect();
            assert_eq!(
                said,
                vec!["EVENT handoff KEN-4".to_owned(), handoff.to_owned()],
                "{case}: {:?} {:?}",
                lines(&first),
                first.failed
            );
            let second = driver.pass(&state);
            assert!(
                !lines(&second)
                    .iter()
                    .any(|l| l.starts_with("EVENT handoff")),
                "{case}: {:?}",
                lines(&second)
            );
            // The clone the `.git` named is kept past the merge's close-out,
            // which removes the worktree after saving its state there.
            assert_eq!(
                driver.baseline.get("clone-root", "KEN-4"),
                Some("/remote/clone"),
                "{case}"
            );
            std::fs::remove_file(disk.join("remote/KEN-4/.git")).unwrap();
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("clone-root", "KEN-4"),
                Some("/remote/clone"),
                "{case}: the worktree gone"
            );
        } else {
            assert_eq!(
                first.failed.as_deref(),
                Some(
                    format!("handoff-read-failed item=KEN-4 path={place} cause=state-unreadable")
                        .as_str()
                ),
                "{case}: {:?}",
                lines(&first)
            );
        }
    }
}

/// A hosted lane with no recorded pane keys its exit row on the empty pane
/// key, which an absent row must not read as, so the row standing is the
/// first pass's record: the lane the provider reads exited is `lane-exited`
/// on the second pass alone, its item unmerged, and that pass closes it
/// through the close verb with its sandbox kept (`keep-sandbox`), the
/// record then read stopped and its marker gone; a third pass says
/// nothing. A host whose status read fails reads no exit and asks no close,
/// so the lane keeps its slot.
#[test]
fn a_paneless_hosted_lane_the_provider_reads_exited_is_reported_on_the_second_pass() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let mut four = hosted_lane(dir.path(), "KEN-4", "gh-4", "/remote/KEN-4");
    four["harness"] = json!("codex");
    fleet.set_lanes(vec![four.clone()]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (
            &format!("{} capabilities", provider(dir.path())),
            ok(SSH_LINE),
        ),
        ("status --item KEN-4 --harness codex", ok("exited\n")),
    ]);
    world.plant_close(verb_reply("KEN-4", "stopped", json!({"identity": "none"})));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let first = driver.pass(&state);
    assert_eq!(event_lines(&first), Vec::<String>::new());
    let second = driver.pass(&state);
    assert_eq!(
        lines(&second),
        vec![
            "EVENT lane-exited gh-4",
            "EVENT lane-closed KEN-4",
            "kept=sandbox"
        ]
    );
    assert_eq!(
        world.close_log(),
        vec![close_call(
            &driver.state_dir,
            r#"{"item":"KEN-4","mode":"keep-sandbox","op":"close-lane"}"#
        )]
    );
    let mut stopped = four.clone();
    stopped["status"] = json!("stopped");
    fleet.set_lanes(vec![stopped]);
    let third = driver.pass(&fleet.read());
    assert_eq!(event_lines(&third), Vec::<String>::new());
    assert_eq!(third.failed, None);
    assert_eq!(world.close_log().len(), 1);

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    four["host"] = json!(provider(dir.path()));
    fleet.set_lanes(vec![four]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path());
    world.plant_host(&[
        (
            &format!("{} capabilities", provider(dir.path())),
            ok(SSH_LINE),
        ),
        (
            "status --item KEN-4 --harness codex",
            json!({"exit": 1, "stderr": "provider down\n"}),
        ),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    for _ in 0..3 {
        let pass = driver.pass(&state);
        assert!(
            !event_lines(&pass)
                .iter()
                .any(|l| l.starts_with("EVENT lane-exited ")),
            "{:?}",
            lines(&pass)
        );
    }
    assert!(world.close_log().is_empty(), "an unread host asks no close");
}

/// A `copilot` the launch rows start, at rest: it writes the session the
/// CLI keeps under its home at start (`session-state/<id>/`, the id from the
/// checkout's name), draws Copilot's framed composer and holds; the path to
/// run it as.
fn copilot_stub(dir: &Path) -> PathBuf {
    let bin = dir.join("resting");
    std::fs::create_dir_all(&bin).unwrap();
    let path = bin.join("copilot");
    let rule = "─".repeat(40);
    write_executable(
        &path,
        format!(
            "#!/bin/bash\nhome=\"${{COPILOT_HOME:-$HOME/.copilot}}\"\nid=\"s-$(basename \"$PWD\")\"\nmkdir -p \"$home/session-state/$id\"\nprintf 'id: %s\\ncwd: %s\\n' \"$id\" \"$(pwd -P)\" > \"$home/session-state/$id/workspace.yaml\"\nprintf '%s\\n' '{{\"type\":\"user.message\"}}' > \"$home/session-state/$id/events.jsonl\"\nprintf '%s\\n' ' ~/work [⎇ main]' '{rule}' '❯ ' '{rule}'\nwhile IFS= read -r _line; do :; done\n"
        ),
    );
    path
}

/// The lane-mail hooks a Copilot launch's gate wants under `dir`, and the
/// `kendex` that judges them switched off by nothing, first on `tools`.
fn plant_copilot_hooks(dir: &Path, tools: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    for name in ["lane-mail-check", "lane-mail-compact", "lane-mail-start"] {
        for ext in ["sh", "json"] {
            std::fs::write(dir.join(format!("{name}.{ext}")), "{}\n").unwrap();
        }
    }
    std::fs::create_dir_all(tools).unwrap();
    let link = tools.join("kendex");
    if std::fs::symlink_metadata(&link).is_err() {
        std::os::unix::fs::symlink(fixtures().join("kendex-hooks-off/kendex"), &link).unwrap();
    }
    std::fs::write(
        tools.join("hooks-off.json"),
        json!({"stdout": r#"{"switched_off_by": null}"#}).to_string(),
    )
    .unwrap();
}

/// A Copilot lane launched with allow-all whose managed policy withdrew the
/// grant waits at a permission prompt, and the line's cause has its
/// overseer stop the lane rather than answer the prompt on every tool call.
/// The duty reads the session's status-line record, the real
/// `copilot-statusline` writer's, under the record's account: a running
/// record with `allow_all` true whose session reports the grant off carries
/// `stop-cause=allow-all-blocked-by-policy` on `lane-asking` and on
/// `idle-after-return`; a record bound to no session id is read through the
/// session the store holds for its worktree; a lane launched without
/// allow-all carries no cause; the note is in the line's key, so the grant
/// restored under the same prompt is news once. The asking records are the
/// released shape, planted as `main` wrote them (`allow_all` a top-level
/// boolean, `account` the directory); the idle records are the real
/// `launch-lane`'s, one on an account, one accountless, whose `home` names
/// the directory its sessions ran under where the record names no account.
#[test]
fn a_copilot_lanes_prompt_carries_the_policy_cause_its_session_record_reports() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut fleet = Fleet::new(&server);
    let copilot = named_sleep(dir.path(), "MainThread");
    let dialog = format!(
        "printf '%s\\n' 'Do you want to proceed?' '❯ 1. Yes'; exec {} 120",
        copilot.display()
    );
    let account = root.join("account");
    std::fs::create_dir_all(&account).unwrap();
    let write_record = |home: &Path, session: &str, allow_all: bool| -> u64 {
        let payload = json!({"session_id": session, "allow_all_enabled": allow_all}).to_string();
        let out = program("bash")
            .args(["-c", r#"printf '%s' "$2" | "$1/copilot-statusline""#, "_"])
            .arg(orch_scripts())
            .arg(payload)
            .env("COPILOT_HOME", home)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let record: Value = serde_json::from_slice(
            &std::fs::read(home.join("lane-status").join(format!("{session}.json"))).unwrap(),
        )
        .unwrap();
        record["written_at"].as_u64().unwrap()
    };
    let worktree = dir.path().join("worktree-4");
    std::fs::create_dir_all(&worktree).unwrap();
    let session = account.join("session-state").join("s2");
    std::fs::create_dir_all(&session).unwrap();
    std::fs::write(
        session.join("workspace.yaml"),
        format!(
            "id: s2\ncwd: {}\n",
            worktree.canonicalize().unwrap().display()
        ),
    )
    .unwrap();
    std::fs::write(session.join("events.jsonl"), "{}\n").unwrap();
    let lane = |item: &str, window: &str, root: &Path| {
        let pane = server.open_window(window, dir.path(), &dialog);
        let mut record = lane_record(item, window, "copilot", &server, &pane, None, root);
        record["account"] = json!(account.display().to_string());
        record
    };
    let mut granted = lane("KEN-2", "gh-2", dir.path());
    granted["session_id"] = json!("s1");
    granted["allow_all"] = json!(true);
    let ungranted = lane("KEN-3", "gh-3", dir.path());
    let mut unbound = lane("KEN-4", "gh-4", &worktree);
    unbound["allow_all"] = json!(true);
    // The idle lanes through the real `launch-lane` under the bypass
    // posture: one on the account, one accountless under the launch's
    // own home.
    let home = root.join("home");
    let copilot_home = home.join(".copilot");
    let tools = root.join("tools");
    plant_copilot_hooks(&account.join("hooks"), &tools);
    plant_copilot_hooks(&copilot_home.join("hooks"), &tools);
    fleet.runner.tools = Some(tools);
    let binaries = format!("copilot={}", copilot_stub(&root).display());
    let home_word = home.display().to_string();
    let env = [
        ("AGENT_RUNTIME_HARNESS_BINARIES", binaries.as_str()),
        ("HOME", home_word.as_str()),
    ];
    let launch = |item: &str, account: Option<&Path>| -> Value {
        let work = root.join(item);
        init_checkout(&fleet, &work);
        let mut request = json!({
            "op": "launch-lane",
            "item": item,
            "harness": "copilot",
            "mail_root": work.display().to_string(),
            "model": "claude-opus-5.5",
            "effort": "high",
            "class": CLASS,
            "class_reason": CLASS_REASON,
        });
        if let Some(account) = account {
            request["account"] = json!(account.display().to_string());
        }
        let report = effect_report(&fleet.runner.op_fleet_env(&request, &env));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{item}: {report}");
        report["lane"].clone()
    };
    let bound = launch("KEN-5", Some(&account));
    assert_eq!(bound["allow_all"], json!(true), "{bound}");
    assert_eq!(
        bound["account"],
        json!(account.display().to_string()),
        "{bound}"
    );
    assert_eq!(bound["session_id"], json!("s-KEN-5"), "{bound}");
    let homed = launch("KEN-6", None);
    assert_eq!(homed["allow_all"], json!(true), "{homed}");
    assert_eq!(homed["account"], Value::Null, "{homed}");
    assert_eq!(
        homed["home"],
        json!(copilot_home.display().to_string()),
        "{homed}"
    );
    assert_eq!(homed["session_id"], json!("s-KEN-6"), "{homed}");
    let idle = |record: &Value, note: &str| {
        format!(
            "EVENT idle-after-return {}{note}",
            record["window"].as_str().unwrap()
        )
    };
    fleet.set_lanes(vec![
        granted,
        ungranted,
        unbound,
        bound.clone(),
        homed.clone(),
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    // The pass's clock is the records' own stamp.
    let stamp = |granted: bool| -> u64 {
        [
            write_record(&account, "s1", granted),
            write_record(&account, "s2", false),
            write_record(&account, "s-KEN-5", false),
            write_record(&copilot_home, "s-KEN-6", false),
        ]
        .into_iter()
        .max()
        .unwrap()
    };
    driver.now = stamp(false);
    let first = driver.pass(&state);
    assert_eq!(
        event_lines(&first),
        vec![
            "EVENT lane-asking gh-2 stop-cause=allow-all-blocked-by-policy",
            "EVENT lane-asking gh-3",
            "EVENT lane-asking gh-4 stop-cause=allow-all-blocked-by-policy",
        ],
        "{:?}",
        lines(&first)
    );
    driver.now = stamp(true);
    let second = driver.pass(&state);
    assert_eq!(
        event_lines(&second),
        vec![
            "EVENT lane-asking gh-2".to_owned(),
            idle(&bound, " stop-cause=allow-all-blocked-by-policy"),
            idle(&homed, " stop-cause=allow-all-blocked-by-policy"),
        ],
        "{:?}",
        lines(&second)
    );
}
