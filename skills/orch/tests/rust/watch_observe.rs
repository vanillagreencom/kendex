//! The observation duty: the lane classifier over three-valued reads of
//! real panes on a private tmux server, the wall rule keyed to the live
//! identity, each local lane's rows, the overseer's one verdict shared with the
//! mail gate, the death counted on two passes and the succession asked for
//! through the one request, the stray sweep, the reset the banner names, the
//! account and lane wall records, the wall relaunch through the route,
//! `lane-long`'s counters, the mark line's payload, and the hosted readings
//! over the provider, runtime-entry and `gh` fixtures linked into a row's
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
use agent_runtime::clock::{self, Clock};
use agent_runtime::controller::transition::{DeathCause, RequestTransfer};
use agent_runtime::controller::views::{AccountState, Caller, MarkKind};
use agent_runtime::harness::Harness;
use agent_runtime::host::tmux::{self, Pane, PaneState};
use agent_runtime::observe::{self, ProcessReading};
use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use agent_runtime::rows;
use agent_runtime::settings::{Roots, Succession};
use jiff::tz::TimeZone;
use orch_runtime::mailbox::{Mailbox, Refusal};
use orch_runtime::ops;
use orch_runtime::ops::wall::{self, RecordWallPauses};
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::state::{self, FleetState, Lane, Record};
use orch_runtime::watch::context;
use orch_runtime::watch::lanes::{self, Readers, Relaunch, WallRoute, WindowRow};
use orch_runtime::watch::overseer::{
    self, ContextRead, Judges, MarkKey, Marks, Slot, Source, Verdict,
};
use orch_runtime::watch::{Baseline, Change, Event, Produced};
use orch_runtime::watch::{github, hosted};
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

fn lane_rows(path: &Path) -> Reading<rows::Row> {
    rows::last_row(path)
}

/// The session record reader of a row that plants none: no Codex or
/// Copilot record stands.
fn no_session_record(
    _: Harness,
    _: &Path,
    _: &Path,
    _: &str,
) -> Reading<Option<agent_runtime::session::Failure>> {
    Reading::Gone
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
        fleet["controller"] = overseer;
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
    /// The entry the provider walk chooses, none answering `none`; `Err` is
    /// the walk's refusal.
    provider_move: Result<Option<Chosen>, String>,
    /// The provider walks the passes asked, in order.
    provider_walks: std::rc::Rc<RefCell<Vec<WalkRequest>>>,
    /// `ORCH_LANE_PREFERENCE` as the route reads it.
    preference: Option<String>,
    halted: fn(&Lane) -> Result<bool, Refusal>,
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

/// The walk's answer a row plants for a walled lane's account walk: an
/// account on the lane's own harness and model, or none.
#[derive(Debug, Clone)]
enum Pick {
    Lane(String),
    None,
}

/// A walk's reply carrying `answer` and nothing it skipped.
fn walked_with(answer: WalkAnswer) -> Walked {
    Walked {
        answer,
        walk: String::new(),
        entries: 1,
        skipped: Vec::new(),
        walled: 0,
        unmeasured: 0,
        unread: Vec::new(),
        deprecated: Vec::new(),
    }
}

/// The entry a walk chose: `harness` running `model` at `effort` on
/// `account`.
fn chosen(harness: Harness, model: &str, effort: &str, account: &str) -> Chosen {
    Chosen {
        entry: format!("{}:{model}:{effort}", harness.name()),
        harness,
        host: None,
        model: model.to_owned(),
        class: None,
        effort: effort.to_owned(),
        pick_model: model.to_owned(),
        account: Some(account.to_owned()),
        record: None,
        warning: None,
        launch: Some("window"),
        kept: false,
        kept_unmeasured: false,
    }
}

impl LaneDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let picked = self.pick.clone();
        self.pass_with_pick(fleet, &|_, _, _| picked.clone())
    }

    /// A pass whose account walk answers `pick` for the walled lane's own
    /// harness and model and the account it leaves, and whose provider walk
    /// answers the driver's `provider_move`, else none.
    fn pass_with_pick(
        &mut self,
        fleet: &FleetState,
        pick: &dyn Fn(Harness, &str, &str) -> Pick,
    ) -> Produced {
        let provider_move = self.provider_move.clone();
        let provider_walks = self.provider_walks.clone();
        let walk = |_: &str, request: &WalkRequest| -> Result<Walked, String> {
            let Some(caller) = &request.caller else {
                provider_walks.borrow_mut().push(request.clone());
                return provider_move.clone().map(|to| {
                    walked_with(match to {
                        Some(to) => WalkAnswer::Lane(Box::new(to)),
                        None => WalkAnswer::None,
                    })
                });
            };
            let model = caller.model.clone().unwrap_or_default();
            let effort = caller.effort.clone().unwrap_or_default();
            let spent = request.exclude.first().cloned().unwrap_or_default();
            Ok(walked_with(match pick(caller.harness, &model, &spent) {
                Pick::Lane(account) => {
                    WalkAnswer::Lane(Box::new(chosen(caller.harness, &model, &effort, &account)))
                }
                Pick::None => WalkAnswer::None,
            }))
        };
        self.pass_with_walk(fleet, &walk)
    }

    /// A pass whose recovery walks are `walk`'s answers.
    fn pass_with_walk(
        &mut self,
        fleet: &FleetState,
        walk: &dyn Fn(&str, &WalkRequest) -> Result<Walked, String>,
    ) -> Produced {
        let start = |r: &Relaunch| {
            self.relaunches.borrow_mut().push(r.clone());
            Ok(())
        };
        let exited = |lane: &Lane| {
            orch_runtime::effects::relaunch::composed(
                &self.settings,
                &self.fleet_path,
                &lane.item,
                &ops::Host::kernel(),
                self.now,
            )
            .map_err(|e| e.to_string())
        };
        let route = WallRoute {
            relaunch: self.settings.watch.get().unwrap().wall_relaunch,
            walk,
            preference: self.preference.as_deref(),
            host: self
                .settings
                .provider
                .get()
                .map(|provider| provider.host)
                .map_err(|e| e.to_string()),
            halted: &self.halted,
            exited: &exited,
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
            fleet_path: &self.fleet_path,
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
                session_failure: &no_session_record,
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
            provider_move: Ok(None),
            provider_walks: std::rc::Rc::new(RefCell::new(Vec::new())),
            preference: None,
            halted: |_| Ok(false),
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
            .all(|r| r.kind == "start-stalled" || r.kind == "lane-restart"),
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
    await_drawn(server, &pane, banner.trim_start());
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
            "wall-relaunch-refused lane=gh-4 reason=record-unnamed".to_owned(),
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

/// The account wall record the account walk reads for the rows' spent
/// account: `walls/<cksum>.json`
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

/// The five-hour banner from KEN-5416's resume reading 2 dates a wall
/// only when the inferred reset fits the five-hour window.
#[test]
fn the_captured_claude_five_hour_banner_writes_a_dated_session_wall() {
    const CAPTURED: &str =
        "  ⎿ \u{a0}You've hit your 5-hour limit · resets 9:30pm (America/Los_Angeles)";
    for (seen, expected_reset) in [
        // At midnight in the banner's zone, the next 9:30 pm is 21h30m away.
        ("2027-01-15T08:00:00Z", None),
        ("2027-01-16T00:30:00Z", Some("2027-01-16T05:30:00Z")),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", CAPTURED);
        fleet.set_lanes(vec![lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        )]);
        let now = clock::epoch_secs(seen).unwrap();
        let started = |_: &Identity| Reading::Live(now - 1);
        lane_driver!(server, fleet, readers, driver);
        driver.now = now;
        driver.readers.start_epoch = &started;
        let produced = driver.pass(&fleet.read());
        let path = account_wall::session_wall_path(
            &driver.settings.account_state.get().unwrap(),
            "/home/me/.eclaude",
        );
        if let Some(reset) = expected_reset {
            let recorded: AccountWall =
                serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
            assert_eq!(
                clock::iso_utc(recorded.resets_at),
                reset,
                "sighting at {seen}"
            );
        } else {
            assert!(
                !path.try_exists().unwrap(),
                "sighting at {seen} must leave no dated account wall"
            );
        }
        let reset_clause =
            expected_reset.map_or_else(String::new, |reset| format!(" resets={reset}"));
        assert_eq!(
            event_lines(&produced),
            [format!(
                "EVENT usage-limit gh-4 /home/me/.eclaude{reset_clause}"
            )]
        );
        assert_eq!(wall_record(&driver.settings), None);
    }
}

/// The reset is pinned to the first sighting; once the clock passes it the
/// lane is `usage-limit-passed` once more, with the wake's resume and the
/// banner window under it, and no account record is renewed for a reset
/// behind the clock.
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
            "resume wake".to_owned(),
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

/// A pane whose process, named `program` for the harness it stands for,
/// draws the screen it starts on and redraws the pane whole with each
/// screen file whose path is typed into it ([`redraw`]), so a row moves a
/// lane's screen under one live identity.
fn redrawing(
    server: &Server,
    dir: &Path,
    name: &str,
    program: &str,
    screen: &str,
) -> (String, Identity) {
    let bin = dir.join(format!("{name}-bin"));
    std::fs::create_dir_all(&bin).unwrap();
    let drawer = bin.join(program);
    write_executable(
        &drawer,
        "#!/bin/bash\ndraw() { printf '\\033[2J\\033[H'; while IFS= read -r l; do printf '%s\\n' \"$l\"; done < \"$1\"; }\ndraw \"$1\"\nwhile IFS= read -r f; do draw \"$f\"; done\n",
    );
    let first = dir.join(format!("{name}-screen-0.txt"));
    std::fs::write(&first, screen).unwrap();
    let pane = server.open_window(
        name,
        dir,
        &format!("exec {} {}", drawer.display(), first.display()),
    );
    let identity = await_named(server, &pane, program);
    (pane, identity)
}

/// The screen `screen` drawn into `pane` through [`redrawing`], read
/// back once `needle` is on it.
fn redraw(server: &Server, pane: &str, dir: &Path, file: &str, screen: &str, needle: &str) {
    let path = dir.join(file);
    std::fs::write(&path, screen).unwrap();
    server.send_line(pane, &path.display().to_string());
    await_drawn(server, pane, needle);
}

/// The wall screen of [`walled_claude`] with the banner `banner`.
fn wall_screen(banner: &str) -> String {
    format!("⏺ Working through the queue.\n{banner}\nRun /usage-credits to raise it\n❯\u{a0}\n")
}

/// A wall ends at the first read with no banner, so the same banner drawn
/// again after it is `usage-limit` once more under the same identity.
#[test]
fn a_wall_that_cleared_and_came_back_with_the_same_banner_is_reported_again() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = redrawing(&server, dir.path(), "gh-4", "claude", &wall_screen(BANNER));
    await_drawn(&server, &pane, "weekly limit");
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
    let wall = vec!["EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z"];
    assert_eq!(event_lines(&driver.pass(&state)), wall);
    assert!(event_lines(&driver.pass(&state)).is_empty());
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-4-screen-1.txt",
        "⏺ Back at work after the wall.\n❯\u{a0}\n",
        "Back at work",
    );
    driver.pass(&state);
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-4-screen-2.txt",
        &wall_screen(BANNER),
        "weekly limit",
    );
    assert_eq!(event_lines(&driver.pass(&state)), wall);
}

/// A wall whose reset passed on a lane the wake reaches is
/// `usage-limit-passed` with `resume wake` and the wake's `resume` row
/// keyed to the identity and the reset; one the wake does not reach (its
/// record names no account) says `resume unreached` and asks nothing; a
/// record naming no model, or no account, says why no pick ran while the
/// reset is ahead. A resumed turn that ended at the same banner is told
/// once with `resume walled`, its row cleared, so no second resume is
/// asked for that wall, and the next pass says nothing.
#[test]
fn a_passed_wall_asks_the_wake_for_one_resume_and_a_resume_answered_by_the_same_banner_is_told_once()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = redrawing(&server, dir.path(), "gh-4", "claude", &wall_screen(BANNER));
    await_drawn(&server, &pane, "weekly limit");
    let (unreached, unreached_identity) =
        redrawing(&server, dir.path(), "gh-5", "claude", &wall_screen(BANNER));
    await_drawn(&server, &unreached, "weekly limit");
    let mut no_account = lane_record(
        "KEN-5",
        "gh-5",
        "claude",
        &server,
        &unreached,
        Some(&unreached_identity),
        dir.path(),
    );
    no_account.as_object_mut().unwrap().remove("account");
    no_account["model"] = json!("opus");
    fleet.set_lanes(vec![
        lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ),
        no_account,
    ]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    let notes = |produced: &Produced| -> Vec<String> {
        lines(produced)
            .into_iter()
            .filter(|l| {
                l.starts_with("EVENT ") || l.starts_with("resume ") || l.starts_with("wall-")
            })
            .collect()
    };
    assert_eq!(
        notes(&driver.pass(&state)),
        vec![
            "EVENT usage-limit gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z",
            "wall-relaunch-refused lane=gh-4 reason=record-unnamed",
            "EVENT usage-limit gh-5 resets=2027-10-04T18:00:00Z",
            "wall-relaunch-refused lane=gh-5 reason=account-unknown",
        ]
    );
    driver.now = BANNER_RESET + 60;
    assert_eq!(
        notes(&driver.pass(&state)),
        vec![
            "EVENT usage-limit-passed gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z",
            "resume wake",
            "EVENT usage-limit-passed gh-5 resets=2027-10-04T18:00:00Z",
            "resume unreached",
        ]
    );
    let asked = format!(
        "usage-limit|{}:{}|{BANNER_RESET}",
        identity.pid, identity.start
    );
    assert_eq!(driver.baseline.get("resume", "gh-4"), Some(asked.as_str()));
    assert_eq!(driver.baseline.get("resume", "gh-5"), None);
    assert!(lines(&driver.pass(&state)).is_empty());
    assert_eq!(driver.baseline.get("resume", "gh-4"), Some(asked.as_str()));
    // The resume typed, the turn answered by the same banner.
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-4-screen-1.txt",
        &format!(
            "{}❯ Resume the orch workflow for KEN-4\n{BANNER}\nRun /usage-credits again\n❯\u{a0}\n",
            wall_screen(BANNER).trim_end_matches("❯\u{a0}\n")
        ),
        "credits again",
    );
    let told = driver.pass(&state);
    assert_eq!(
        lines(&told),
        vec![
            "EVENT usage-limit-passed gh-4 /home/me/.eclaude resets=2027-10-04T18:00:00Z"
                .to_owned(),
            "resume walled".to_owned(),
            BANNER.to_owned(),
            "Run /usage-credits again".to_owned(),
            "❯\u{a0}".to_owned(),
        ]
    );
    assert_eq!(driver.baseline.get("resume", "gh-4"), None);
    assert!(lines(&driver.pass(&state)).is_empty());
}

/// A lane record carrying what the relaunch needs: the model the pick is
/// asked for, the class and reason the relaunch keeps, and the refresh
/// word the launch recorded.
fn relaunchable(mut record: Value) -> Value {
    record["model"] = json!("opus");
    record["class"] = json!(CLASS);
    record["class_reason"] = json!(CLASS_REASON);
    record["refresh"] = json!(true);
    record
}

/// Under `auto` (the default) a walled lane whose record names its model is
/// relaunched once onto the picked account through the route: the marker
/// for the outcome reader first, the record's own launcher line with
/// `--lane` the picked account, `lane-relaunched` with its log, and nothing
/// on the next pass; under `ask` the wall is `usage-limit` with the pick's
/// answer under it and nothing starts. A reading lane reports its wall
/// even under `auto` and starts no replacement.
#[test]
fn a_walled_lane_is_relaunched_once_under_auto_and_only_reported_under_ask() {
    if !isolated_row("a_walled_lane_is_relaunched_once_under_auto_and_only_reported_under_ask") {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    git_checkout(dir.path());
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    fleet.set_lanes(vec![relaunchable(lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    ))]);
    let state = fleet.read();
    lane_driver!(
        server,
        fleet,
        readers,
        driver,
        &[("ORCH_WALL_RELAUNCH", "auto")]
    );
    driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    driver.halted = |lane| Mailbox::new(lane_mail().to_path_buf()).lane_halted(lane);
    let log = driver.state_dir.join("wall-relaunch-KEN-4.log");
    let text = dir.path().join("directive.txt");
    let mail = |args: &[&str]| {
        let output = program(lane_mail())
            .current_dir(dir.path())
            .args(args)
            .args(["--item", "KEN-4"])
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", stderr(&output));
    };
    let send = |kind, words| {
        std::fs::write(&text, words).unwrap();
        mail(&["send", kind, "--file", text.to_str().unwrap()]);
    };
    send("--halt", "Hold for the control computer restart.");
    mail(&["inbox"]);
    assert!(
        Mailbox::new(lane_mail().to_path_buf())
            .inbox_peek("KEN-4", dir.path())
            .unwrap()
            .unread
            .is_empty(),
        "the lane acknowledged the halt"
    );
    for _ in 0..2 {
        driver.pass(&state);
        assert!(driver.relaunches.borrow().is_empty(), "standing halt");
        assert!(
            !driver
                .state_dir
                .join("wall-relaunch-KEN-4.close.json")
                .exists(),
            "standing halt must leave the predecessor alone"
        );
    }
    lane_driver!(
        server,
        fleet,
        reset_readers,
        reset,
        &[("ORCH_WALL_RELAUNCH", "auto")]
    );
    reset.halted = driver.halted;
    reset.pass(&state);
    reset.now = BANNER_RESET + 60;
    for _ in 0..2 {
        let passed = reset.pass(&state);
        assert_eq!(
            reset.baseline.get("resume", "gh-4"),
            None,
            "standing halt must withhold the reset resume"
        );
        assert!(lines(&passed).is_empty(), "{:?}", lines(&passed));
    }
    send("--directive", "The restart is complete. Resume work.");
    reset.pass(&state);
    assert_eq!(
        reset.baseline.get("resume", "gh-4"),
        Some(
            format!(
                "usage-limit|{}:{}|{BANNER_RESET}",
                identity.pid, identity.start
            )
            .as_str()
        )
    );
    assert!(reset.relaunches.borrow().is_empty());
    let since = driver.now;
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
            json!({"item": "KEN-4", "since": since, "log": log.display().to_string()})
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

    fleet.set_lanes(vec![relaunchable(lane_record(
        "verify-KEN-4-box-1",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    ))]);
    lane_driver!(server, fleet, reading_readers, reading);
    reading.pick = Pick::Lane("/home/me/.bclaude".to_owned());
    let reported = reading.pass(&fleet.read());
    assert!(
        lines(&reported)
            .iter()
            .any(|line| line.starts_with("EVENT usage-limit gh-4 ")),
        "the overseer can handle the reading lane's wall"
    );
    assert!(reading.relaunches.borrow().is_empty());
    assert!(
        !reading
            .state_dir
            .join("wall-relaunch-verify-KEN-4-box-1.close.json")
            .exists()
    );
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
        let mut record = relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ));
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
    let out = git().args(["init", "-q"]).arg(path).output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    // The row removes the checkout, so no background writer may race it.
    for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
        let out = git()
            .arg("-C")
            .arg(path)
            .args(["config", key, value])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
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
/// through the real entry runs with the word and no bypass word.
#[test]
fn a_walled_lanes_relaunch_keeps_its_permission_choice() {
    // The walled stub and the seats stand outside the confined worktree.
    let (dir, root) = outside_tmp();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let work = root.join("KEN-5");
    init_checkout(&fleet, &work);
    let spent = root.join("eclaude");
    let picked = root.join("bclaude");
    for account in [&spent, &picked] {
        plant_credential(account);
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
    fleet.set_lanes(vec![runtime]);
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
        vec![format!(
            "EVENT lane-relaunched KEN-5 lane={} from={}",
            picked.display(),
            spent.display()
        )],
        "{:?}",
        lines(&produced)
    );
    let started = driver.relaunches.borrow();
    assert_eq!(started.len(), 1);
    let chain = &started[0];
    assert_eq!(chain.item, "KEN-5");
    let request: Value =
        serde_json::from_str(&std::fs::read_to_string(&chain.args[7]).unwrap()).unwrap();
    assert_eq!(
        request["permission"],
        json!("--permission-mode dontAsk"),
        "{request}"
    );
    // The record's two requests through the real entry, as the route
    // starts them: the walled predecessor retired, the replacement started
    // on the picked account with the kept choice.
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
    std::fs::write(support::item_record(&tmp, "KEN-9"), COUNTS_STATE).unwrap();
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

/// The screen a real hosted Codex lane's pane drew when its provider's API
/// ended its turn.
fn codex_api_error_screen() -> PathBuf {
    fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("fixtures/oversee-watch/codex-api-error.txt")
}

/// A Codex turn its provider's API ended, on a hosted lane whose window the
/// wake types into (`pane=local`, `status=verb`), is no finished return: it
/// asks the wake for one resume (`resume=api-error|<key>`) with no line; a
/// turn ending on an API error again before the wake delivered that resume
/// asks nothing more and is no line either.
#[test]
fn a_codex_api_error_turn_end_is_no_finished_return() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let first = std::fs::read_to_string(codex_api_error_screen()).unwrap();
    let (pane, _client) = redrawing(&server, dir.path(), "gh-7", "ssh", &first);
    await_drawn(&server, &pane, "Bad Request");
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-7"]);
    let _lane = host.lead("KEN-7", "codex");
    let root = host.lane_root("KEN-7").display().to_string();
    let mut hosted = hosted_lane(dir.path(), "KEN-7", "gh-7", &root);
    hosted["harness"] = json!("codex");
    hosted["launch"] = json!({"pane": pane, "server": server.pid});
    fleet.set_lanes(vec![hosted]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let resume = |driver: &LaneDriver<'_>| driver.baseline.get("resume", "gh-7").map(str::to_owned);
    let asked = |row: Option<String>, word: &str| {
        row.as_deref()
            .is_some_and(|r| r.starts_with(&format!("{word}|")))
    };
    let told = |driver: &mut LaneDriver<'_>| -> Vec<String> {
        (0..3)
            .flat_map(|_| event_lines(&driver.pass(&state)))
            .filter(|l| l.starts_with("EVENT idle-after-return"))
            .collect()
    };
    assert_eq!(told(&mut driver), Vec::<String>::new());
    let first = resume(&driver);
    assert!(asked(first.clone(), "api-error"), "{first:?}");
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-7-screen-1.txt",
        "\u{203a} Resume the orch workflow for KEN-7\n\u{25a0} {\"detail\":\"Bad Request\"}\n\u{203a} Ask Codex to do anything\n",
        "Resume the orch",
    );
    assert_eq!(told(&mut driver), Vec::<String>::new());
    assert_eq!(resume(&driver), first);
}

/// A hosted Codex lane's API-error stop as its provider's `capture`
/// returned it for a `pane=verb`, `status=verb` lane: the error line
/// directly above the composer, the status rows under it.
fn codex_api_error_capture() -> PathBuf {
    codex_api_error_screen().with_file_name("codex-api-error-fleet.txt")
}

/// A `pane=verb` Codex lane whose provider's capture is that stop
/// ([`codex_api_error_capture`]), its window here a viewer's: the lanes
/// duty reads it idle with `cause=api-error` and asks the wake for one
/// resume (`resume=api-error|<key>`) with no line.
#[test]
fn a_pane_verb_codex_api_error_capture_asks_one_resume_with_no_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let viewer = server.open_window("gh-9", dir.path(), "exec bash --norc --noprofile");
    let mut hosted = hosted_lane(dir.path(), "KEN-9", "gh-9", "/remote/lane");
    hosted["harness"] = json!("codex");
    hosted["viewer"] = json!(true);
    hosted["launch"] = json!({"pane": viewer, "server": server.pid});
    fleet.set_lanes(vec![hosted]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    let capture = std::fs::read_to_string(codex_api_error_capture()).unwrap();
    world.plant_host(&[
        ("capabilities", ok(VERB_LINE)),
        ("status --item KEN-9 --harness codex", ok("running\n")),
        ("capture --item KEN-9", ok(&capture)),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let told: Vec<String> = (0..3)
        .flat_map(|_| event_lines(&driver.pass(&state)))
        .filter(|l| l.starts_with("EVENT idle-after-return"))
        .collect();
    assert_eq!(told, Vec::<String>::new(), "{:?}", world.host_log());
    let row = driver.baseline.get("resume", "gh-9").map(str::to_owned);
    assert!(
        row.as_deref().is_some_and(|r| r.starts_with("api-error|")),
        "{row:?} {:?}",
        world.host_log()
    );
}

/// A resume the wake refused, after one it delivered, is told once: the
/// refused row reads no delivery, so no later pass asks a fresh one and
/// the wake tells nothing more while the screen stands unchanged.
#[test]
fn a_refused_api_error_resume_is_told_once_on_an_unchanged_idle_screen() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let viewer = server.open_window("gh-9", dir.path(), "exec bash --norc --noprofile");
    let mut hosted = hosted_lane(dir.path(), "KEN-9", "gh-9", "/remote/lane");
    hosted["harness"] = json!("codex");
    hosted["viewer"] = json!(true);
    hosted["launch"] = json!({"pane": viewer, "server": server.pid});
    fleet.set_lanes(vec![hosted]);
    fleet.set_overseer(json!({"server_socket": server.socket}));
    let state = fleet.read();
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    let capture = std::fs::read_to_string(codex_api_error_capture()).unwrap();
    let plant = |status| {
        world.plant_host(&[
            ("capabilities", ok(VERB_LINE)),
            ("status --item KEN-9 --harness codex", status),
            ("capture --item KEN-9", ok(&capture)),
        ]);
    };
    plant(ok("running\n"));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    for _ in 0..2 {
        assert!(event_lines(&driver.pass(&state)).is_empty());
    }
    let resume = |driver: &LaneDriver<'_>| driver.baseline.get("resume", "gh-9").map(str::to_owned);
    let delivered = resume(&driver).unwrap();
    wake_delivered(&fleet, "KEN-9", &delivered, driver.now);
    // The delivery's stamp keys the idle screen anew, judged over two passes.
    for _ in 0..2 {
        assert!(event_lines(&driver.pass(&state)).is_empty());
    }
    let asked = resume(&driver).unwrap();
    assert_ne!(asked, delivered, "a fresh resume after the delivered one");
    plant(json!({"exit": 1}));
    let clock = FakeClock::new();
    let wake = |driver: &LaneDriver<'_>| {
        let tick = orch_runtime::watch::Tick {
            duty: orch_runtime::schedule::Duty::Wake,
            now: agent_runtime::clock::Clock::now(&clock),
            wall: driver.now,
            baseline: &driver.baseline,
            clock: &clock,
        };
        orch_runtime::watch::wake::body(&fleet.path(), &driver.settings)(&tick).unwrap()
    };
    assert_eq!(
        event_lines(&wake(&driver)),
        vec!["EVENT idle-after-return gh-9 cause=api-error"]
    );
    plant(ok("running\n"));
    for _ in 0..3 {
        assert_eq!(event_lines(&driver.pass(&state)), Vec::<String>::new());
    }
    assert_eq!(resume(&driver), Some(asked), "the refused resume stands");
    assert_eq!(event_lines(&wake(&driver)), Vec::<String>::new());
}

/// A Codex turn its provider's API ended, on a local lane the wake types
/// into, asks the wake for one resume (`resume=api-error|<key>|pass:<s>`)
/// with no line; a turn that ends on an API error again after the wake
/// delivered that resume asks a fresh one, still with no line, once per
/// pass; a finished return then ends the episode with its line, so a later
/// API error is resumed again.
#[test]
fn a_codex_api_error_is_resumed_after_each_delivered_resume_until_a_finished_return() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let first = std::fs::read_to_string(codex_api_error_screen()).unwrap();
    let (pane, identity) = redrawing(&server, dir.path(), "gh-8", "codex", &first);
    await_drawn(&server, &pane, "Bad Request");
    fleet.set_lanes(vec![lane_record(
        "KEN-8",
        "gh-8",
        "codex",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    )]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    // The row a released watch wrote at a second failure, which the wake
    // resumes nothing for and an upgrade keeps.
    driver.baseline.apply(Change::Set {
        kind: "resume".into(),
        identity: "gh-8".into(),
        value: "told|gh-8-pane|Some(1)|None|7".into(),
    });
    let resume = |driver: &LaneDriver<'_>| driver.baseline.get("resume", "gh-8").map(str::to_owned);
    let asked = |row: Option<String>, word: &str| {
        row.as_deref()
            .is_some_and(|r| r.starts_with(&format!("{word}|")))
    };
    for _ in 0..3 {
        let quiet = driver.pass(&state);
        assert!(event_lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    }
    let first_ask = resume(&driver).unwrap();
    assert!(asked(Some(first_ask.clone()), "api-error"), "{first_ask}");
    assert!(
        first_ask.contains("|pass:"),
        "the wake serves the row: {first_ask}"
    );
    // The wake typed the resume and the resumed turn ended on the same
    // provider error.
    wake_delivered(&fleet, "KEN-8", &first_ask, driver.now);
    let error = "\u{25a0} {\"detail\":\"Bad Request\"}";
    let composer = "\u{203a} Ask Codex to do anything";
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-8-screen-1.txt",
        &format!("\u{203a} Resume the orch workflow for KEN-8\n{error}\n{composer}\n"),
        "Resume the orch",
    );
    let again = driver.pass(&state);
    assert!(event_lines(&again).is_empty(), "{:?}", lines(&again));
    let second_ask = resume(&driver).unwrap();
    assert!(asked(Some(second_ask.clone()), "api-error"), "{second_ask}");
    assert_ne!(
        second_ask, first_ask,
        "a fresh resume for the stop after it"
    );
    // Until the wake delivers it, the stop asks nothing more.
    assert!(event_lines(&driver.pass(&state)).is_empty());
    assert_eq!(resume(&driver).as_deref(), Some(second_ask.as_str()));
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-8-screen-2.txt",
        &format!(
            "\u{203a} Resume the orch workflow for KEN-8\n\u{2022} Validation passed.\n{composer}\n"
        ),
        "Validation passed",
    );
    assert_eq!(
        event_lines(&driver.pass(&state)),
        vec!["EVENT idle-after-return gh-8"]
    );
    assert_eq!(resume(&driver), None);
    assert_eq!(driver.baseline.get("provider-stop", "gh-8"), None);
    redraw(
        &server,
        &pane,
        dir.path(),
        "gh-8-screen-3.txt",
        &format!("\u{203a} Run the socket suite\n{error}\n{composer}\n"),
        "socket suite",
    );
    let later = driver.pass(&state);
    assert!(event_lines(&later).is_empty(), "{:?}", lines(&later));
    assert!(asked(resume(&driver), "api-error"), "{:?}", resume(&driver));
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
        format!("{}{row}\n", std::fs::read_to_string(&rows_file).unwrap(), row = json!({"harness":"pi","event":"Stop","stop_reason":"stop","working_agents":0,"at":2})),
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
            "wall-relaunch-refused lane=gh-5 reason=record-unnamed".to_owned(),
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
    assert!(event_lines(&again).is_empty());
    assert!(
        driver
            .baseline
            .get("resume", "gh-7")
            .unwrap()
            .starts_with("error|")
    );
}

/// Each harness's provider stop, and a reading lane's output limit, asks
/// the wake for a resume with no line; the same stop again asks nothing
/// until the wake delivered that resume, then a fresh one.
#[test]
fn provider_stops_are_resumed_after_each_delivered_resume_on_every_harness() {
    if !isolated_row("provider_stops_are_resumed_after_each_delivered_resume_on_every_harness") {
        return;
    }
    for (item, harness, cause, screen, draw, stop) in [
        (
            "KEN-1",
            "claude",
            "server_error",
            "❯\u{a0}\n",
            "❯",
            r#"{"harness":"claude","event":"StopFailure","error":"server_error"}"#,
        ),
        (
            "KEN-1",
            "pi",
            "error",
            "pi drew this\n",
            "pi drew this",
            r#"{"harness":"pi","event":"Stop","stop_reason":"error","working_agents":0}"#,
        ),
        (
            "verify-KEN-5-box-1",
            "pi",
            "length",
            "pi drew this\n",
            "pi drew this",
            r#"{"harness":"pi","event":"Stop","stop_reason":"length","working_agents":0}"#,
        ),
        (
            "verify-KEN-5-box-2",
            "codex",
            "api-error",
            CODEX_LIVE_FAILURE,
            "not supported",
            r#"{"harness":"codex","event":"UserPromptSubmit"}"#,
        ),
        (
            "KEN-1",
            "copilot",
            "api-error",
            "❯ Brief\n✗ Execution failed: CAPIError: Connection error.\n❯ \n────────────────────────────────────────\n",
            "────",
            r#"{"harness":"copilot","event":"UserPromptSubmit"}"#,
        ),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, &dir, "gh-1", harness, screen);
        await_drawn(&server, &pane, draw);
        fleet.set_lanes(vec![lane_record(
            item,
            "gh-1",
            harness,
            &server,
            &pane,
            Some(&identity),
            &dir,
        )]);
        let file = dir
            .join("tmp/lane-mail")
            .join(item)
            .join("session-rows.jsonl");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{stop}\n")).unwrap();
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.pass(&state);
        let stopped = driver.pass(&state);
        let expected = format!("{cause}|");
        assert!(
            driver
                .baseline
                .get("resume", "gh-1")
                .is_some_and(|row| row.starts_with(&expected)),
            "{harness} did not request a {cause} continuation"
        );
        assert!(event_lines(&stopped).is_empty(), "{harness}");
        let first = driver.baseline.get("resume", "gh-1").unwrap().to_owned();
        std::fs::write(&file, format!("{stop}\n{stop}\n")).unwrap();
        let events: Vec<_> = (0..3)
            .flat_map(|_| event_lines(&driver.pass(&state)))
            .collect();
        assert_eq!(events, Vec::<String>::new(), "{harness}");
        assert_eq!(
            driver.baseline.get("resume", "gh-1"),
            Some(first.as_str()),
            "{harness}: nothing more before the wake delivers"
        );
        wake_delivered(&fleet, item, &first, driver.now);
        let events: Vec<_> = (0..2)
            .flat_map(|_| event_lines(&driver.pass(&state)))
            .collect();
        assert_eq!(events, Vec::<String>::new(), "{harness}");
        let fresh = driver.baseline.get("resume", "gh-1").unwrap();
        assert!(fresh.starts_with(&expected), "{harness}: {fresh}");
        assert_ne!(fresh, first, "{harness}");
    }
}

/// A window of the fleet session that no lane, controller record, open
/// intent or receipt names is `stray-window` once; it stands after, and a
/// recorded window is never one: a window an open launch's set holds before
/// its phase or outcome names it (a viewer opened in the launch's last
/// step) among them.
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
    let viewer = server.open_window("KEN-9", dir.path(), "bash --norc --noprofile");
    let mut doc = fleet.runner.fleet();
    doc["intents"] = json!([{
        "id": "launch-session:KEN-9:1-1", "op": "launch-session", "target": "KEN-9",
        "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "phase": {"phase": "preparing", "step": "host-exec", "at": "provider"},
        "obligations": {"standing": [{"kind": "pane", "pane": viewer, "server": server.pid,
            "server_start": server.start, "role": "harness"}], "discharged": []}
    }]);
    fleet.runner.write_fleet(&doc);
    let state = fleet.read();
    assert!(
        state.intents.iter().any(|i| i.open()),
        "the launch stands open"
    );
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
    assert!(server.panes().contains(&viewer));
}

/// A window opened after the pass's snapshot, named `name`, and what its
/// opener recorded: its pane.
type OpensAfterSnapshot = fn(&Server, &Fleet, &Path, &str) -> String;

/// A confirmed hosted launch's viewer window and the lane record it writes.
fn hosted_viewer(server: &Server, fleet: &Fleet, dir: &Path, name: &str) -> String {
    let pane = server.open_window(name, dir, "bash --norc --noprofile");
    fleet.set_lanes(vec![json!({
        "item": "KEN-H", "window": "fleet:KEN-H", "harness": "claude", "status": "running",
        "host": "lane-host-ssh", "kind": "ssh", "viewer": true,
        "mail_root": dir.display().to_string(),
        "launch": {"pane": pane, "server": server.pid, "server_start": server.start,
            "pid": null, "start": null},
    })]);
    pane
}

/// A succession's new controller pane and the controller record it writes.
fn succeeding_overseer(server: &Server, fleet: &Fleet, dir: &Path, name: &str) -> String {
    let pane = server.open_window(name, dir, "bash --norc --noprofile");
    fleet.set_overseer(overseer_at(server, &pane, &window_of(server, &pane), dir));
    pane
}

/// An open launch whose window was asked on server `pid`, its pane not yet
/// recorded, as the window acquisition writes it before `new-window`.
fn window_asked(server: &Server, fleet: &Fleet, dir: &Path, name: &str, pid: u64) -> String {
    let mut doc = fleet.runner.fleet();
    doc["intents"] = json!([{
        "id": "launch-session:KEN-W:1-1", "op": "launch-session", "target": "KEN-W",
        "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
        "phase": {"phase": "preparing", "step": "host-exec", "at": "provider"},
        "obligations": {"standing": [{"kind": "window", "server": pid,
            "server_start": server.start, "role": "harness"}], "discharged": []}
    }]);
    fleet.runner.write_fleet(&doc);
    server.open_window(name, dir, "bash --norc --noprofile")
}

/// The stray sweep judges a window by the records it reads after its
/// listing, never by the pass's older snapshot: a hosted launch's viewer or
/// a succession's controller pane opened and recorded after the snapshot is
/// no stray. A window an open launch asked on the listed server, its pane
/// not yet recorded, is held that pass and reported on the next that still
/// finds it unnamed; one asked on another server holds nothing, and a
/// window nothing records is reported at once. None is ever closed.
#[test]
fn a_window_is_judged_by_the_records_read_after_its_listing() {
    let cases: [(&str, OpensAfterSnapshot, [bool; 3]); 5] = [
        ("KEN-H", hosted_viewer, [false, false, false]),
        ("overseer", succeeding_overseer, [false, false, false]),
        (
            "asked-here",
            |s, f, d, n| window_asked(s, f, d, n, u64::from(s.pid)),
            [false, true, false],
        ),
        (
            "asked-elsewhere",
            |s, f, d, n| window_asked(s, f, d, n, u64::from(s.pid) + 1),
            [true, false, false],
        ),
        (
            "unrecorded",
            |s, _, d, n| s.open_window(n, d, "bash --norc --noprofile"),
            [true, false, false],
        ),
    ];
    for (name, opens, expected) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let snapshot = fleet.read();
        let opened: RefCell<Option<String>> = RefCell::new(None);
        // The window opens and its record is written after the snapshot,
        // as the pass's own lane reads run, and before the sweep lists.
        let listing = |recorded: Option<&Path>, session: &str| {
            if opened.borrow().is_none() {
                *opened.borrow_mut() = Some(opens(&server, &fleet, dir.path(), name));
            }
            lanes::windows_at(recorded.unwrap_or(&server.socket), session)
        };
        lane_driver!(server, fleet, readers, driver);
        driver.readers.windows = &listing;
        let strays = |produced: Produced| -> Vec<String> {
            event_lines(&produced)
                .into_iter()
                .filter(|l| l.starts_with("EVENT stray-window"))
                .collect()
        };
        let mut passes = vec![strays(driver.pass(&snapshot))];
        for _ in 1..expected.len() {
            passes.push(strays(driver.pass(&fleet.read())));
        }
        let pane = opened.borrow().clone().expect("the sweep listed");
        let line = format!(
            "EVENT stray-window {pane} window={} server={} name={name}",
            window_of(&server, &pane),
            server.pid
        );
        let want: Vec<Vec<String>> = expected
            .iter()
            .map(|&reported| if reported { vec![line.clone()] } else { vec![] })
            .collect();
        assert_eq!(passes, want, "{name}");
        assert!(server.panes().contains(&pane), "{name}: the window stands");
    }
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
    /// The refusal every transfer asked is answered with, where a row
    /// plants one; each is recorded all the same.
    refusal: Option<&'a str>,
}

impl OverseerDriver<'_> {
    fn pass(&mut self, fleet: &FleetState) -> Produced {
        let transfer = |request: RequestTransfer| {
            let mut asked = self.transfers.borrow_mut();
            asked.push(request);
            match self.refusal {
                Some(refusal) => Err(refusal.to_owned()),
                None => Ok(format!("request-transfer:overseer:{}", asked.len())),
            }
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

/// A judge's answer as a row plants it, its own account read as the judge
/// reads it for that answer: at the trigger for a headroom mark, unread
/// for an unmeasured headroom, not read for a due context reading, and
/// with room otherwise. A row planting another reading sets `own`.
fn marks(key: MarkKey, value: &str, mark: &str, succession: Succession, account: &str) -> Marks {
    let own = match key {
        MarkKey::Reached(MarkKind::Headroom) => Some(AccountState::AtTrigger),
        MarkKey::Unmeasured(MarkKind::Headroom) => Some(AccountState::Unreadable),
        MarkKey::Reached(MarkKind::Context) => None,
        MarkKey::Reached(_) | MarkKey::Unmeasured(_) | MarkKey::Below => {
            Some(AccountState::HasRoom)
        }
    };
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
        own,
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
fn no_memory(_: u32) -> Reading<Option<u64>> {
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
                session_failure: &no_session_record,
                status_file: &status_file,
                windows: &windows_read,
                receipts: &lanes::receipts_in,
                zone: &zone,
            },
            judges: Judges {
                scripts: PathBuf::from("/nonexistent"),
                marks: &$marks,
                walk: &$pick,
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
            refusal: None,
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

/// The overseer walk choosing the Codex account `.codex`.
fn walk_codex(_: &WalkRequest) -> orch_runtime::error::Result<Walked> {
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
}

/// A controller its provider stopped is resumed on its own account once
/// per pass, a fresh resume row each pass, for the 30 minutes the stop's
/// action holds; past them the walk leaving its provider is asked and the
/// overseer moved to the entry it chose, with no resume beside the move.
/// Its first returned turn ends the episode and its rows.
#[test]
fn a_provider_stopped_controller_is_resumed_each_pass_then_moved_to_another_provider() {
    if !isolated_row(
        "a_provider_stopped_controller_is_resumed_each_pass_then_moved_to_another_provider",
    ) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let server = Server::start(&dir, "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = redrawing(&server, &dir, "overseer", "claude", "❯\u{a0}\n");
    await_drawn(&server, &pane, "❯");
    let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), &dir);
    let file = dir.join("session-rows.jsonl");
    record["session_rows"] = json!(file);
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    let state = fleet.read();
    let walks: RefCell<Vec<WalkRequest>> = RefCell::new(Vec::new());
    let walk = |request: &WalkRequest| {
        walks.borrow_mut().push(request.clone());
        walk_codex(request)
    };
    overseer_driver!(server, fleet, below, walk, readers, transfers, driver);
    let key = format!("{} {pane}", server.pid);
    std::fs::write(
        &file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"server_error\"}\n",
    )
    .unwrap();
    // Eight passes 240 seconds apart: the last at 1680 seconds, inside 30
    // minutes.
    let mut resumes = Vec::new();
    for _ in 0..8 {
        driver.pass(&state);
        resumes.push(
            driver
                .baseline
                .get("resume", "overseer")
                .expect("each pass asks a resume")
                .to_owned(),
        );
    }
    let prefix = format!("server_error|{key}|");
    assert!(
        resumes.iter().all(|r| r.starts_with(&prefix)),
        "{resumes:?}"
    );
    let mut distinct = resumes.clone();
    distinct.dedup();
    assert_eq!(distinct.len(), 8, "a fresh resume each pass: {resumes:?}");
    assert!(walks.borrow().is_empty(), "no walk inside the patience");
    assert!(transfers.borrow().is_empty());
    driver.pass(&state);
    {
        let asked = walks.borrow();
        assert_eq!(asked.len(), 1);
        assert!(
            asked[0].caller.is_none(),
            "the caller's own entry is not walked"
        );
        let preference = asked[0].preference.as_deref().unwrap_or_default();
        assert!(!preference.is_empty(), "the setting's other entries walk");
        assert!(
            !preference.split(',').any(|e| e.starts_with("claude:")),
            "{preference}"
        );
        let moved = transfers.borrow();
        assert_eq!(moved.len(), 1);
        assert_eq!(moved[0].cause, TransferCause::Walled);
        assert_eq!(
            moved[0].exclude_account.as_deref(),
            Some("/home/me/.eclaude")
        );
        assert_eq!(moved[0].successor.harness.as_deref(), Some("codex"));
        assert_eq!(
            moved[0].successor.account.as_deref(),
            Some("/home/me/.codex")
        );
    }
    assert_eq!(
        driver.baseline.get("resume", "overseer"),
        Some(resumes[7].as_str()),
        "no resume beside the move"
    );
    std::fs::write(&file, "{\"harness\":\"claude\",\"event\":\"Stop\"}\n").unwrap();
    driver.pass(&state);
    assert_eq!(driver.baseline.get("resume", "overseer"), None);
    assert_eq!(driver.baseline.get("overseer-provider-stop", &key), None);
}

/// The Claude overseer whose rows end on a `server_error` StopFailure, at
/// an idle prompt in its own pane: its pane key.
fn provider_stopped_overseer(dir: &Path, server: &Server, fleet: &Fleet) -> String {
    let (pane, identity) = redrawing(server, dir, "overseer", "claude", "❯\u{a0}\n");
    await_drawn(server, &pane, "❯");
    let file = dir.join("session-rows.jsonl");
    std::fs::write(
        &file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"server_error\"}\n",
    )
    .unwrap();
    let mut record = overseer_at(server, &pane, &window_of(server, &pane), dir);
    record["session_rows"] = json!(file);
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    format!("{} {pane}", server.pid)
}

/// The row `kind` holds for `key`, as an earlier pass would have left it.
fn plant(baseline: &mut Baseline, kind: &str, key: &str, value: String) {
    baseline.apply(Change::Set {
        kind: kind.to_owned(),
        identity: key.to_owned(),
        value,
    });
}

/// A provider stop that moves the overseer nowhere is resumed on every
/// pass with a fresh row: past the patience under succession off, past it
/// where the move the walk chose is refused, and where its episode went
/// stale, a failure read after a whole patience with none read opening a
/// new episode inside its own patience however long ago the old one began.
#[test]
fn a_provider_stopped_controller_that_moves_nowhere_is_resumed_each_pass() {
    if !isolated_row("a_provider_stopped_controller_that_moves_nowhere_is_resumed_each_pass") {
        return;
    }
    let now: u64 = 1_800_000_000;
    let past_patience = format!("{}|{}", now - 1900, now - 240);
    // case, the succession setting, the transfer's refusal, the episode
    // planted, the walks and transfers asked over two passes
    let cases: [(&str, Succession, Option<&str>, String, usize); 3] = [
        (
            "succession off",
            Succession::Off,
            None,
            past_patience.clone(),
            0,
        ),
        (
            "move refused",
            Succession::On,
            Some("succession-off"),
            past_patience,
            2,
        ),
        (
            "episode stale",
            Succession::On,
            None,
            format!("{}|{}", now - 7200, now - 3600),
            0,
        ),
    ];
    for (case, succession, refusal, episode, asked) in cases {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let key = provider_stopped_overseer(&dir, &server, &fleet);
        let state = fleet.read();
        let walks = Cell::new(0);
        let walk = |request: &WalkRequest| {
            walks.set(walks.get() + 1);
            walk_codex(request)
        };
        overseer_driver!(server, fleet, below, walk, readers, transfers, driver);
        driver.succession = succession;
        driver.refusal = refusal;
        plant(
            &mut driver.baseline,
            "overseer-provider-stop",
            &key,
            episode,
        );
        for _ in 0..2 {
            let at = driver.now;
            let produced = driver.pass(&state);
            let resume = driver
                .baseline
                .get("resume", "overseer")
                .unwrap_or_default();
            assert!(
                resume.starts_with(&format!("server_error|{key}|"))
                    && resume.ends_with(&format!("|pass:{at}")),
                "{case}: {resume}"
            );
            assert_eq!(
                produced.failed.is_some(),
                refusal.is_some(),
                "{case}: {:?}",
                produced.failed
            );
        }
        assert_eq!(walks.get(), asked, "{case}");
        assert_eq!(transfers.borrow().len(), asked, "{case}");
    }
}

/// A provider move whose transfer failed is settled as every walked
/// succession is: asked again where it left its successor's account
/// unproved, the next walk holding that account out, else asked no more and
/// the owner told once; the session is resumed on each pass it does not
/// move.
#[test]
fn a_provider_move_that_failed_is_asked_again_only_where_it_left_its_account_unproved() {
    if !isolated_row(
        "a_provider_move_that_failed_is_asked_again_only_where_it_left_its_account_unproved",
    ) {
        return;
    }
    let now: u64 = 1_800_000_000;
    // case, the record's unproved stamp, the move row after the settling
    // pass, the notices, the walks and transfers of the pass after
    type Row<'a> = (&'a str, Option<u64>, &'a str, &'a [&'a str], usize);
    let cases: [Row; 2] = [
        (
            "nothing unproved",
            None,
            "reported",
            &["overseer-no-successor.txt"],
            0,
        ),
        (
            "unproved after the attempt",
            Some(now - 30),
            "announced",
            &[],
            1,
        ),
    ];
    for (case, stamp, after, notices, moved) in cases {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let key = provider_stopped_overseer(&dir, &server, &fleet);
        let mut doc = fleet.runner.fleet();
        if let Some(at) = stamp {
            doc["controller"]["unproved"] = json!([
                {"account": "/home/me/.codex", "note": "successor-not-ready", "at": clock::iso_utc(at)}
            ]);
        }
        doc["intents"] = json!([{
            "id": "request-transfer:overseer:1", "op": "request-transfer", "target": "overseer",
            "created_at": clock::iso_utc(now - 60), "outcome": "failed",
            "observation": {"note": "successor-not-ready"}
        }]);
        fleet.runner.write_fleet(&doc);
        let state = fleet.read();
        let walks: RefCell<Vec<WalkRequest>> = RefCell::new(Vec::new());
        let walk = |request: &WalkRequest| {
            walks.borrow_mut().push(request.clone());
            walk_codex(request)
        };
        let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let noting = |file: &str, _: &str| {
            told.borrow_mut().push(file.to_owned());
            Ok(())
        };
        overseer_driver!(server, fleet, below, walk, readers, transfers, driver);
        driver.alert = &noting;
        for (kind, value) in [
            (
                "overseer-provider-stop",
                format!("{}|{}", now - 1900, now - 240),
            ),
            ("overseer-provider-move", "requested".to_owned()),
            (
                "overseer-transfer",
                "1:request-transfer:overseer:1".to_owned(),
            ),
        ] {
            plant(&mut driver.baseline, kind, &key, value);
        }
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-provider-move", &key),
            Some(after),
            "{case}"
        );
        let resume = driver
            .baseline
            .get("resume", "overseer")
            .unwrap_or_default();
        assert!(
            resume.ends_with(&format!("|pass:{now}")),
            "{case}: {resume}"
        );
        assert!(walks.borrow().is_empty(), "{case}");
        let at = driver.now;
        driver.pass(&state);
        assert_eq!(walks.borrow().len(), moved, "{case}");
        assert_eq!(transfers.borrow().len(), moved, "{case}");
        if moved == 0 {
            let resume = driver
                .baseline
                .get("resume", "overseer")
                .unwrap_or_default();
            assert!(resume.ends_with(&format!("|pass:{at}")), "{case}: {resume}");
        } else {
            assert!(
                walks.borrow()[0]
                    .exclude
                    .iter()
                    .any(|account| account == "/home/me/.codex"),
                "{case}: the unproved account is held out"
            );
        }
        assert_eq!(*told.borrow(), notices, "{case}");
    }
}

/// Codex's capacity refusal on the overseer's pane is a provider stop: each
/// pass asks a fresh `api-error` resume.
#[test]
fn a_codex_controller_at_capacity_is_resumed_each_pass() {
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
    let pane = server.open_window("overseer", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &pane, "codex");
    await_drawn(&server, &pane, "at capacity");
    let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), dir.path());
    record["harness"] = json!("codex");
    record["account"] = json!("/home/me/.codex");
    record["harness_pid"] = json!(identity.pid.to_string());
    record["harness_start"] = json!(identity.start);
    fleet.set_overseer(record);
    let state = fleet.read();
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    let prefix = format!("api-error|{} {pane}|", server.pid);
    let mut resumes = Vec::new();
    for _ in 0..2 {
        driver.pass(&state);
        resumes.push(driver.baseline.get("resume", "overseer").map(str::to_owned));
    }
    assert!(
        resumes
            .iter()
            .all(|r| r.as_deref().is_some_and(|r| r.starts_with(&prefix))),
        "{resumes:?}"
    );
    assert_ne!(resumes[0], resumes[1], "a fresh resume each pass");
    assert!(transfers.borrow().is_empty());
}

/// A Copilot overseer's failed turn is read from its own session record,
/// its screen an ordinary prompt and its account reading room up to a
/// monthly reset: the 429 rate limit walls it whatever the account reads,
/// so its succession is asked on the next run with the spent account left
/// out, and where no successor has room it stays pending and the owner is
/// told; a provider failure (`copilot-safety.jsonl`, recorded by
/// agent-runtime) resumes it each pass with no walk.
#[test]
fn a_copilot_controller_s_failed_turn_in_its_own_record_is_judged_by_its_kind() {
    let rate_limit = agent_runtime::session::Failure {
        error: Some("rate_limit".to_owned()),
        status: Some(429),
        message: "Sorry, you have been rate-limited.".to_owned(),
        at: Some(1_799_999_000),
    };
    let flagged = agent_runtime::session::Failure {
        error: Some("query".to_owned()),
        status: Some(400),
        message: "400 Invalid prompt: your prompt was flagged as potentially violating our usage policy. Please try again with a different prompt.".to_owned(),
        at: Some(1_799_999_000),
    };
    let walk_none = |_: &WalkRequest| {
        Ok(Walked {
            answer: WalkAnswer::None,
            walk: "copilot:standard:high".to_owned(),
            entries: 1,
            skipped: Vec::new(),
            walled: 1,
            unmeasured: 0,
            unread: Vec::new(),
            deprecated: Vec::new(),
        })
    };
    let monthly = |_: &Caller, _: Option<&str>| {
        let mut m = marks(MarkKey::Below, "", "", Succession::On, "/home/me/.copilot");
        m.resets = clock::iso_utc(1_802_000_000);
        Ok(m)
    };
    type Walk<'a> = &'a dyn Fn(&WalkRequest) -> orch_runtime::error::Result<Walked>;
    // case, the record's failure, the walk, the walled row after two
    // passes, the transfers, whether each pass resumes, the notices
    type Row<'a> = (
        &'a str,
        &'a agent_runtime::session::Failure,
        Walk<'a>,
        Option<&'a str>,
        usize,
        bool,
        &'a [&'a str],
    );
    let cases: [Row; 3] = [
        (
            "rate limit",
            &rate_limit,
            &walk_b,
            Some("requested"),
            1,
            false,
            &[],
        ),
        (
            "rate limit, no successor",
            &rate_limit,
            &walk_none,
            Some("pending"),
            0,
            false,
            &["overseer-no-successor.txt"],
        ),
        ("provider failure", &flagged, &no_walk, None, 0, true, &[]),
    ];
    for (case, failure, walk, walled, asked, resumed, notices) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let copilot = named_sleep(dir.path(), "copilot");
        // Copilot's framed composer at rest: an ordinary prompt.
        let screen = dir.path().join("copilot-screen.txt");
        let rule = "─".repeat(40);
        std::fs::write(&screen, format!("{rule}\n❯ \n{rule}\n")).unwrap();
        let pane = server.open_window(
            "overseer",
            dir.path(),
            &format!(
                "bash -c \"cat {}; exec {} 600\"",
                screen.display(),
                copilot.display()
            ),
        );
        let identity = await_named(&server, &pane, "copilot");
        await_drawn(&server, &pane, "❯");
        let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), dir.path());
        record["harness"] = json!("copilot");
        record["account"] = json!("/home/me/.copilot");
        record["session_id"] = json!("s1");
        record["harness_pid"] = json!(identity.pid.to_string());
        record["harness_start"] = json!(identity.start);
        fleet.set_overseer(record);
        let state = fleet.read();
        let cwd = dir.path().to_path_buf();
        let recorded = |harness: Harness, home: &Path, at: &Path, id: &str| {
            assert_eq!(
                (harness, home, at, id),
                (
                    Harness::Copilot,
                    Path::new("/home/me/.copilot"),
                    cwd.as_path(),
                    "s1"
                )
            );
            Reading::Live(Some(failure.clone()))
        };
        let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let noting = |file: &str, _: &str| {
            told.borrow_mut().push(file.to_owned());
            Ok(())
        };
        overseer_driver!(server, fleet, monthly, walk, readers, transfers, driver);
        driver.readers.session_failure = &recorded;
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        for _ in 0..2 {
            let at = driver.now;
            driver.pass(&state);
            let resume = driver.baseline.get("resume", "overseer");
            assert_eq!(
                resume.is_some_and(|r| r.starts_with(&format!("api-error|{key}|"))
                    && r.ends_with(&format!("|pass:{at}"))),
                resumed,
                "{case}: {resume:?}"
            );
            if !resumed {
                assert_eq!(resume, None, "{case}");
            }
        }
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            walled,
            "{case}"
        );
        let asked_for = transfers.borrow();
        assert_eq!(asked_for.len(), asked, "{case}");
        if let Some(asked) = asked_for.first() {
            assert_eq!(asked.cause, TransferCause::Walled, "{case}");
            assert_eq!(
                asked.exclude_account.as_deref(),
                Some("/home/me/.copilot"),
                "{case}"
            );
        }
        assert_eq!(*told.borrow(), notices, "{case}");
    }
}

/// An ended sign-in on the overseer's account starts its succession at
/// once and tells the owner once which account to sign in again.
#[test]
fn an_auth_walled_controller_moves_at_once_and_tells_the_owner_its_account_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
    std::fs::write(
        dir.path().join("session-rows.jsonl"),
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"authentication_failed\",\"message\":\"Invalid API key\"}\n",
    )
    .unwrap();
    let state = fleet.read();
    let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
    let noting = |file: &str, text: &str| {
        told.borrow_mut().push((file.to_owned(), text.to_owned()));
        Ok(())
    };
    overseer_driver!(server, fleet, reached, walk_b, readers, transfers, driver);
    driver.alert = &noting;
    let first = driver.pass(&state);
    assert!(
        event_lines(&first)[0].starts_with(&format!("EVENT overseer-walled {pane} ")),
        "{:?}",
        lines(&first)
    );
    for _ in 0..3 {
        driver.pass(&state);
    }
    assert_eq!(transfers.borrow().len(), 1);
    assert_eq!(transfers.borrow()[0].cause, TransferCause::Walled);
    let told = told.borrow();
    assert_eq!(
        told.iter().map(|(f, _)| f.as_str()).collect::<Vec<_>>(),
        ["overseer-auth-wall.txt"]
    );
    assert!(told[0].1.contains("/home/me/.eclaude"), "{}", told[0].1);
}

/// A walled overseer the walk finds no successor for stays pending: it is
/// walked again on each pass, nothing asked, and the owner is told once
/// for the episode, the notice saying the walk answered none, an account
/// that names a reset included. A send that failed is sent again on the
/// next pass until the owner holds it.
#[test]
fn a_walled_controller_with_no_successor_stays_pending_and_tells_the_owner_once() {
    let now: u64 = 1_800_000_000;
    let reset = now + 3600;
    let resets_at = |_: &Caller, _: Option<&str>| {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        Ok(m)
    };
    type Judge<'a> = &'a dyn Fn(&Caller, Option<&str>) -> Result<Marks, String>;
    let notice = "overseer-no-successor.txt";
    // case, the account judgement, the owner's sends that fail first, the
    // notices sent
    let cases: [(&str, Judge, usize, &[&str]); 3] = [
        ("its account names a reset", &resets_at, 0, &[notice]),
        ("no reset", &reached, 0, &[notice]),
        (
            "no reset, its first send failed",
            &reached,
            1,
            &[notice, notice],
        ),
    ];
    for (case, judge, failures, notices) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
        let state = fleet.read();
        let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
        let noting = |file: &str, text: &str| {
            let mut told = told.borrow_mut();
            told.push((file.to_owned(), text.to_owned()));
            if told.len() <= failures {
                return Err("channel=owner mailbox-busy".to_owned());
            }
            Ok(())
        };
        let walks = Cell::new(0);
        let walk = |request: &WalkRequest| {
            walks.set(walks.get() + 1);
            walk_none(request)
        };
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        for _ in 0..4 {
            driver.pass(&state);
        }
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("pending"),
            "{case}"
        );
        assert_eq!(walks.get(), 3, "{case}: each pass past the announce walks");
        assert!(transfers.borrow().is_empty(), "{case}");
        assert_eq!(driver.baseline.get("resume", "overseer"), None, "{case}");
        let told = told.borrow();
        assert_eq!(
            told.iter().map(|(f, _)| f.as_str()).collect::<Vec<_>>(),
            notices,
            "{case}"
        );
        assert!(
            told[0].1.starts_with("overseer-walled-pending:") && told[0].1.contains("walk-none"),
            "{case}: {}",
            told[0].1
        );
    }
}

/// The overseer walk choosing none, every entry walled.
fn walk_none(_: &WalkRequest) -> orch_runtime::error::Result<Walked> {
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
}

/// A notice still owed for a pane the controller has left, as a move that
/// replaced the pane leaves it, is sent on the next pass and goes once the
/// owner holds it; the rows of that pane go with it.
#[test]
fn a_notice_owed_for_a_pane_the_controller_left_is_sent_then_goes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    live_overseer(dir.path(), &server, &fleet);
    let state = fleet.read();
    let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
    let noting = |file: &str, text: &str| {
        told.borrow_mut().push((file.to_owned(), text.to_owned()));
        Ok(())
    };
    overseer_driver!(server, fleet, below, no_walk, readers, transfers, driver);
    driver.alert = &noting;
    let left = "1 %999";
    let owed = format!("{left}|auth|1799999000");
    let text = "overseer-auth-wall: sign in again on account /home/me/.eclaude.\n";
    plant(
        &mut driver.baseline,
        "overseer-notice-owed",
        &owed,
        text.to_owned(),
    );
    plant(
        &mut driver.baseline,
        "overseer-walled",
        left,
        "requested".to_owned(),
    );
    driver.pass(&state);
    assert_eq!(
        *told.borrow(),
        [("overseer-auth-wall.txt".to_owned(), text.to_owned())]
    );
    assert_eq!(driver.baseline.get("overseer-notice-owed", &owed), None);
    assert_eq!(driver.baseline.get("overseer-walled", left), None);
    driver.pass(&state);
    assert_eq!(told.borrow().len(), 1, "sent once");
}

/// A notice the mailbox did not take stays owed whatever its episode does
/// on the controller's own pane: an ended sign-in's notice that failed, the
/// session then read live, is sent on each pass until the mailbox takes it,
/// and once only after.
#[test]
fn a_notice_owed_on_the_controllers_own_pane_outlives_its_episode_until_sent() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
    let rows = dir.path().join("session-rows.jsonl");
    std::fs::write(
        &rows,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"authentication_failed\",\"message\":\"Invalid API key\"}\n",
    )
    .unwrap();
    let state = fleet.read();
    let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
    let noting = |file: &str, _: &str| {
        let mut told = told.borrow_mut();
        told.push(file.to_owned());
        if told.len() <= 2 {
            return Err("channel=owner mailbox-busy".to_owned());
        }
        Ok(())
    };
    overseer_driver!(server, fleet, below, walk_b, readers, transfers, driver);
    driver.alert = &noting;
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(transfers.borrow().len(), 1);
    assert_eq!(*told.borrow(), ["overseer-auth-wall.txt"]);
    std::fs::write(&rows, "{\"harness\":\"claude\",\"event\":\"Stop\"}\n").unwrap();
    for _ in 0..3 {
        let live = driver.pass(&state);
        assert!(
            !lines(&live)
                .iter()
                .any(|line| line.starts_with(&format!("EVENT overseer-walled {pane}"))),
            "{:?}",
            lines(&live)
        );
    }
    assert_eq!(*told.borrow(), ["overseer-auth-wall.txt"; 3]);
}

/// A walled succession's failed transfer is asked again only where it left
/// its successor's account unproved, so the next walk holds it out; a
/// failure that left none would choose the same successor, so it is
/// reported and the owner told once. A notice of another kind still owed
/// on the same pane stays owed beside it until the mailbox takes it.
#[test]
fn a_walled_transfer_that_failed_is_asked_again_only_where_it_left_its_account_unproved() {
    let now: u64 = 1_800_000_000;
    let auth = "overseer-auth-wall.txt";
    let none = "overseer-no-successor.txt";
    // case, the record's unproved stamp, whether an ended sign-in's notice
    // the mailbox refuses once is owed on the pane, the passes, the row
    // after, the notices
    type Row<'a> = (&'a str, Option<u64>, bool, usize, &'a str, &'a [&'a str]);
    let cases: [Row; 3] = [
        ("unproved", Some(now - 30), false, 1, "announced", &[]),
        ("nothing unproved", None, false, 1, "reported", &[none]),
        (
            "nothing unproved, a sign-in notice owed",
            None,
            true,
            2,
            "reported",
            &[auth, none, auth],
        ),
    ];
    for (case, stamp, owed, passes, after, notices) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
        let mut doc = fleet.runner.fleet();
        if let Some(at) = stamp {
            doc["controller"]["unproved"] = json!([
                {"account": "/home/me/.bclaude", "note": "successor-not-ready", "at": clock::iso_utc(at)}
            ]);
        }
        doc["intents"] = json!([{
            "id": "request-transfer:overseer:1", "op": "request-transfer", "target": "overseer",
            "created_at": clock::iso_utc(now - 60), "outcome": "failed",
            "observation": {"note": "successor-not-ready"}
        }]);
        fleet.runner.write_fleet(&doc);
        let state = fleet.read();
        let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let noting = |file: &str, _: &str| {
            let mut told = told.borrow_mut();
            told.push(file.to_owned());
            if owed && told.len() == 1 {
                return Err("channel=owner mailbox-busy".to_owned());
            }
            Ok(())
        };
        overseer_driver!(server, fleet, reached, no_walk, readers, transfers, driver);
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        for (kind, value) in [
            ("overseer-walled", "requested"),
            ("overseer-transfer", "1:request-transfer:overseer:1"),
        ] {
            driver.baseline.apply(Change::Set {
                kind: kind.to_owned(),
                identity: key.clone(),
                value: value.to_owned(),
            });
        }
        if owed {
            plant(
                &mut driver.baseline,
                "overseer-notice-owed",
                &format!("{key}|auth|{}", now - 600),
                "overseer-auth-wall: sign in again on account /home/me/.eclaude.\n".to_owned(),
            );
        }
        for _ in 0..passes {
            driver.pass(&state);
        }
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some(after),
            "{case}"
        );
        assert_eq!(*told.borrow(), notices, "{case}");
        assert!(transfers.borrow().is_empty(), "{case}");
    }
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
/// real one over fixture `/proc` and cgroup files without `memory.stat`.
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
    let memory = |_: u32| agent_runtime::process::oom_kills(&proc_root, &cgroup, 4242);
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
/// walk leaves out the spent account and each account the record holds
/// unproved inside its hold, never one whose hold has ended; the account
/// judgement reading room lifts it instead.
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
    let now = 1_800_000_000;
    record["unproved"] = json!([
        {"account": "/home/me/.cclaude", "at": clock::iso_utc(now - 60)},
        {"account": "/home/me/.dclaude", "at": clock::iso_utc(now - 7200)},
    ]);
    fleet.set_overseer(record);
    let state = fleet.read();
    let excluded = RefCell::new(Vec::new());
    let walk_noting = |request: &WalkRequest| {
        excluded.borrow_mut().push(request.exclude.clone());
        walk_b(request)
    };
    overseer_driver!(
        server,
        fleet,
        reached,
        walk_noting,
        readers,
        transfers,
        driver
    );
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
        assert_eq!(
            *excluded.borrow(),
            [["/home/me/.eclaude", "/home/me/.cclaude"]]
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
    let fleet_place = move |item: &str| support::item_record(&state_dir, item);
    std::fs::write(fleet_place("KEN-1"), handoff_state(HANDOFF_RECORD)).unwrap();
    // KEN-2's record stands only in its root's tmp, the fleet's place
    // holding a state with no record.
    std::fs::write(fleet_place("KEN-2"), "{\"cycles\":0}\n").unwrap();
    std::fs::write(
        support::item_record(&root.join("tmp"), "KEN-2"),
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
    let fleet_place = move |item: &str| support::item_record(&state_dir, item);
    std::fs::write(fleet_place("KEN-1"), "{\"cycles\":0}\n").unwrap();
    let torn = support::item_record(&root.join("tmp"), "KEN-1");
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

const SWITCHED: &str = "KEN-1";
const NATIVE: &str = "native-1";

/// A switched lane's checkout under `dir`: a repository whose own `tmp`
/// holds its item record, with the runtime's entry its recovery's job runs
/// held until `release` exists (bounded at 30 seconds), so the job runs
/// nothing of a real close or launch.
fn switched_root(dir: &Path, release: &Path) -> PathBuf {
    let root = dir.join("root-KEN-1");
    std::fs::create_dir_all(&root).unwrap();
    let init = program("git")
        .args(["init", "-q"])
        .arg(&root)
        .output()
        .unwrap();
    assert!(init.status.success(), "git init: {}", stderr(&init));
    // The row removes the root, so no background writer may race it.
    for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
        let out = program("git")
            .arg("-C")
            .arg(&root)
            .args(["config", key, value])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    let scripts = root.join(".agents/skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    write_executable(
        &scripts.join("orch-runtime"),
        format!(
            "#!/bin/sh\ni=0\nwhile [ ! -e '{}' ] && [ \"$i\" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n",
            release.display()
        ),
    );
    root
}

/// The switched lane's fleet record: launched on `opus` for the session
/// `NATIVE` by a harness process that is gone, with what a relaunch is
/// composed from.
fn switched_lane(server: &Server, root: &Path) -> Value {
    let gone = Identity {
        pid: u32::try_from(GONE_PID).unwrap(),
        start: "ticks:1".to_owned(),
    };
    let mut lane = lane_record(
        SWITCHED,
        "gh-1",
        "claude",
        server,
        "%999",
        Some(&gone),
        root,
    );
    for (key, value) in [
        ("model", "opus"),
        ("session_id", NATIVE),
        ("launched_at", "2026-11-12T10:00:00Z"),
        ("class", CLASS),
        ("class_reason", CLASS_REASON),
    ] {
        lane[key] = json!(value);
    }
    lane
}

/// The launch a check on `lane` is bound to.
fn bound_launch(lane: &Value) -> Value {
    json!({"launch": lane["launch"], "launched_at": lane["launched_at"]})
}

/// The check a lane's turn end keeps on its item record for its switch of
/// `session` from `launched`, marked started.
fn kept_switch(lane: &Value, session: &str, launched: &str) -> Value {
    json!({"model_checks": {session: {
        "outcome": "switched", "session_id": session, "launch_identity": bound_launch(lane),
        "launched": launched, "observed": "claude-sonnet-4-5", "cause": "",
        "at": "2026-11-12T10:05:00Z", "recovery_started": true,
    }}})
}

/// The runtime's entry the pass's recovery runs, the built binary on the
/// isolated tools' path, so the recovery's job reads the planted `loginctl`
/// and starts under `setsid`, never as a unit of the host's user manager.
fn entry_scripts(dir: &Path) -> PathBuf {
    let scripts = dir.join("watch-scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    write_executable(
        &scripts.join("orch-runtime"),
        format!(
            "#!/bin/bash\nexport PATH='{}'\nexec '{}' --no-private-env \"$@\"\n",
            tool_path(&[]),
            binary().display()
        ),
    );
    scripts
}

/// A switch a lane's turn end kept on its item record, marked started on
/// the session and launch the fleet record runs, is recovered once by the
/// lane pass: the fleet lane's check recorded with its one log row, then
/// the fleet's `recover-lane-model` claims it and starts its job. A
/// recovery the claim refuses at the limit since the lane's last reset is
/// said once with its refusal's key line, the switch spent. The same facts
/// on the next pass act and say nothing.
#[test]
fn a_switch_kept_on_a_lanes_item_record_is_recovered_once_by_the_lane_pass() {
    let replaced = |session: &str| {
        json!({"kind": "model-switched", "item": SWITCHED, "session_id": session,
               "recovery": "replaced", "launch_identity": {"launch": {"pane": "%2"}}})
    };
    for (case, log, said) in [
        ("recovered", json!([]), None),
        (
            "limit",
            json!([replaced("earlier"), replaced("before")]),
            Some("model-recovery-refused key=model-recovery-limit item=KEN-1 recoveries=2 limit=3"),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let release = dir.path().join("entry-release");
        let root = switched_root(dir.path(), &release);
        let lane = switched_lane(&server, &root);
        fleet.set_lanes(vec![lane.clone()]);
        let mut record = fleet.runner.fleet();
        record["fleet_log"] = log;
        fleet.runner.write_fleet(&record);
        std::fs::write(
            support::item_record(&root.join("tmp"), SWITCHED),
            kept_switch(&lane, NATIVE, "opus").to_string(),
        )
        .unwrap();
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = entry_scripts(dir.path());
        let job = driver
            .state_dir
            .join(format!("model-recovery-{SWITCHED}.unit"));
        let first = driver.pass(&state);
        let after = fleet.runner.fleet();
        let check = &after["lanes"][0]["model_check"];
        assert_eq!(check["outcome"], "switched", "{case}: {after}");
        assert_eq!(check["recovery_started"], true, "{case}: {after}");
        assert_eq!(check["launch_identity"], bound_launch(&lane), "{case}");
        let switched_rows = |fleet: &Value| {
            fleet["fleet_log"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|row| {
                    row["kind"] == "model-switched"
                        && row["item"] == SWITCHED
                        && row["session_id"] == NATIVE
                })
                .count()
        };
        assert_eq!(switched_rows(&after), 1, "{case}: {after}");
        assert_eq!(first.failed.as_deref(), said, "{case}");
        assert_eq!(job.exists(), said.is_none(), "{case}: the job");
        let second = driver.pass(&state);
        std::fs::write(&release, "").unwrap();
        assert_eq!(second.failed, None, "{case}: said again");
        assert_eq!(fleet.runner.fleet(), after, "{case}: acted again");
    }
}

/// Every value of a lane's item record is the lane's to write, so a fact
/// naming a session in a form its reader would not name a path by, or a
/// switch from a model the fleet record does not hold, writes nothing on
/// the fleet record and starts nothing: it is the pass's line once.
#[test]
fn an_item_records_fact_of_a_wrong_session_form_or_an_unheld_model_changes_nothing_and_is_said_once()
 {
    for (case, fact, cause) in [
        ("switch's session", "switch-session", "session-form"),
        ("switch's model", "switch-model", "model-unheld"),
        ("cleared start's session", "cleared", "session-form"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let release = dir.path().join("entry-release");
        let root = switched_root(dir.path(), &release);
        let lane = switched_lane(&server, &root);
        fleet.set_lanes(vec![lane.clone()]);
        let record = match fact {
            "switch-session" => kept_switch(&lane, "../native-1", "opus"),
            "switch-model" => kept_switch(&lane, NATIVE, "claude-fable-5-2"),
            _ => json!({"lane_session": {"session_id": "native/2", "launch": lane["launch"]}}),
        };
        std::fs::write(
            support::item_record(&root.join("tmp"), SWITCHED),
            record.to_string(),
        )
        .unwrap();
        let before = fleet.runner.fleet();
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = entry_scripts(dir.path());
        let first = driver.pass(&state);
        let second = driver.pass(&state);
        std::fs::write(&release, "").unwrap();
        assert_eq!(
            first.failed.as_deref(),
            Some(format!("model-facts-refused item={SWITCHED} cause={cause}").as_str()),
            "{case}"
        );
        assert_eq!(second.failed, None, "{case}: said again");
        assert_eq!(
            fleet.runner.fleet(),
            before,
            "{case}: the fleet record moved"
        );
        assert!(
            !driver
                .state_dir
                .join(format!("model-recovery-{SWITCHED}.unit"))
                .exists(),
            "{case}: a job started"
        );
    }
}

/// A cleared start's session a lane kept on its item record, in the launch
/// the fleet lane runs, binds the fleet lane to it; a replacement's first
/// turn end kept there, in the session and launch the fleet lane now runs,
/// resets the switched check its recovery started under the earlier launch
/// with one log row. A fact under another launch moves nothing.
#[test]
fn a_cleared_start_and_a_first_turn_end_kept_on_an_item_record_are_applied_by_the_lane_pass() {
    for (case, current) in [("this launch", true), ("another launch", false)] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let release = dir.path().join("entry-release");
        let root = switched_root(dir.path(), &release);
        let mut lane = switched_lane(&server, &root);
        lane["model_check"] = json!({
            "outcome": "switched", "session_id": NATIVE, "recovery_started": true,
            "launch_identity": {"launch": {"pid": 7, "start": "ticks:7"},
                                "launched_at": "2026-11-11T00:00:00Z"},
        });
        fleet.set_lanes(vec![lane.clone()]);
        let mut launch = lane["launch"].clone();
        let mut identity = bound_launch(&lane);
        if !current {
            launch["start"] = json!("ticks:9");
            identity["launched_at"] = json!("2026-11-13T00:00:00Z");
        }
        std::fs::write(
            support::item_record(&root.join("tmp"), SWITCHED),
            json!({"model_reset": {"session_id": NATIVE, "launch_identity": identity}}).to_string(),
        )
        .unwrap();
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = entry_scripts(dir.path());
        let first = driver.pass(&state);
        assert_eq!(first.failed, None, "{case}");
        let reset = fleet.runner.fleet();
        let resets = |fleet: &Value| {
            fleet["fleet_log"].as_array().map_or(0, |rows| {
                rows.iter()
                    .filter(|row| row["kind"] == "model-recovery-reset")
                    .count()
            })
        };
        let outcome = if current { "passed" } else { "switched" };
        assert_eq!(
            reset["lanes"][0]["model_check"]["outcome"], outcome,
            "{case}: {reset}"
        );
        assert_eq!(resets(&reset), usize::from(current), "{case}: {reset}");

        std::fs::write(
            support::item_record(&root.join("tmp"), SWITCHED),
            json!({"lane_session": {"session_id": "native-2", "launch": launch}}).to_string(),
        )
        .unwrap();
        driver.pass(&state);
        let bound = fleet.runner.fleet();
        let session = if current { "native-2" } else { NATIVE };
        assert_eq!(bound["lanes"][0]["session_id"], session, "{case}: {bound}");
        assert_eq!(resets(&bound), usize::from(current), "{case}: {bound}");
        std::fs::write(&release, "").unwrap();
    }
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
/// ([`provider_world`]) in the scripts directory the pass carries, where
/// the close verb's runtime entry is the real one ([`real_close_scripts`]),
/// and the `gh` fixture that entry and the pass's own reads share, its
/// answers and logs beside it in `bin`.
struct HostedWorld {
    scripts: PathBuf,
    bin: PathBuf,
}

impl HostedWorld {
    fn new(dir: &Path, server: &Server, fleet: &Fleet) -> HostedWorld {
        let scripts = provider_world(dir);
        assert_eq!(real_close_scripts(dir, server, fleet), scripts);
        let world = HostedWorld {
            scripts,
            bin: dir.join("bin"),
        };
        world.plant_host(&[]);
        world.plant_gh(json!({}));
        world
    }

    /// [`Self::new`]'s world with the shipped ssh provider ([`SshHost`]) at
    /// the provider's path in place of the planted one, `items` on its one
    /// host, each on a clone of its own.
    fn ssh(dir: &Path, server: &Server, fleet: &Fleet, items: &[&str]) -> (HostedWorld, SshHost) {
        let scripts = real_close_scripts(dir, server, fleet);
        let host = SshHost::new(dir, &scripts, items[0]);
        for item in &items[1..] {
            host.add(item);
        }
        let world = HostedWorld {
            scripts,
            bin: dir.join("bin"),
        };
        world.plant_gh(json!({}));
        (world, host)
    }

    fn gh(&self) -> PathBuf {
        self.bin.join("gh")
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

    /// The `gh api` answers, by path.
    fn plant_gh(&self, answers: Value) {
        std::fs::write(self.bin.join("gh.json"), answers.to_string()).unwrap();
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
}

/// How many closes of `item` the close verb carried to its transition: its
/// `close-resources` intents on the fleet record.
fn closes(fleet: &Fleet, item: &str) -> usize {
    fleet.runner.fleet()["intents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|i| i["op"] == "close-resources" && i["target"] == item)
        .count()
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    for item in ["CC-1", "CC-2", "CC-3"] {
        assert_eq!(closes(&fleet, item), 0, "no stall closes {item} here");
    }
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
/// `ORCH_CLOUD_STALL_MINUTES` old closes the lane once through the real
/// close verb (`close-lane ITEM` through the runtime's entry), the marker
/// created before the ask: `lane-closed` with the close's line, then
/// `cloud-stall-closed` with the directive's age, the record the verb wrote
/// done. A standing hold asks nothing; a standing marker beside the open
/// lane asks nothing and is the pass's failure; a marker of an earlier
/// launch is pruned and the close proceeds; a close that never started
/// takes its marker and the next pass closes.
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    world.plant_gh(json!({
        "repos/o/r/pulls?head=o:cc-1&state=open": open_pull("aaa111", "", Some(true)),
    }));
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
    let closed = driver.pass(&state);
    assert_eq!(
        lines(&closed),
        vec![
            "EVENT lane-closed CC-1",
            "kept=none",
            "EVENT cloud-stall-closed CC-1 directive_age=1900",
        ],
        "{:?}",
        closed.failed
    );
    assert_eq!(closed.failed, None);
    assert_eq!(closes(&fleet, "CC-1"), 1);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Done);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the marker stands until the record confirms the close"
    );
    // A pass that reads the lane open still: the operator's lane, named each
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
        closes(&fleet, "CC-1"),
        1,
        "no second close beside the marker"
    );
    // The record the close verb wrote, the lane out of flight: the marker
    // leaves.
    let after_close = driver.pass(&fleet.read());
    assert_eq!(after_close.failed, None);
    assert!(lines(&after_close).is_empty(), "{:?}", lines(&after_close));
    assert!(
        std::fs::metadata(&marker).is_err(),
        "the marker leaves once the record confirms the close"
    );
    // The lane launched again on the same record and stalled again (the
    // closed lane's row left with it).
    fleet.set_lanes(vec![lane.clone()]);
    let state = fleet.read();
    driver.baseline.apply(Change::Set {
        kind: "lane-stalled".into(),
        identity: "CC-1".into(),
        value: format!("aaa111|{}|{}||", digest(""), driver.now - 3700),
    });
    // The hold the tracker duty recorded: nothing asked, the stall said.
    driver.baseline.apply(Change::Set {
        kind: "tracker-quota".into(),
        identity: "fleet".into(),
        value: json!({"limit": "requests", "status": "future", "reset": clock::iso_utc(now + 7200), "reset_epoch": now + 7200}).to_string(),
    });
    let held = driver.pass(&state);
    assert_eq!(lines(&held), vec!["EVENT lane-stalled CC-1 age=3700"]);
    assert_eq!(closes(&fleet, "CC-1"), 1, "a standing hold asks nothing");
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
    assert_eq!(closes(&fleet, "CC-1"), 1, "a standing marker asks nothing");
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
            "EVENT cloud-stall-closed CC-1 directive_age=3100"
        ],
        "{:?}",
        again.failed
    );
    assert_eq!(again.failed, None);
    assert_eq!(closes(&fleet, "CC-1"), 2);
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "this close's own marker stands for the record read"
    );
    // A close that never started (its entry not executable) closed
    // nothing: no marker stands, and once it can run the next pass closes.
    use std::os::unix::fs::PermissionsExt;
    std::fs::remove_file(&marker).unwrap();
    fleet.set_lanes(vec![lane.clone()]);
    let close = world.scripts.join("orch-runtime");
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
            "EVENT cloud-stall-closed CC-1 directive_age=3580"
        ],
        "{:?}",
        closed.failed
    );
    assert_eq!(closes(&fleet, "CC-1"), 3);
}

/// A stopped record whose sandbox stands with a park owed is asked that park
/// through the real close verb each pass, with the wait the record kept,
/// over the provider's sandbox stop and GitHub's reading of the pull
/// request it waits on; each result unlike the last one told is told once,
/// a failed stop with the provider's refusal line, the same failure again
/// tells nothing, and a parked answer is told once,
/// the record parked, and its row leaves with the owed park. A sandbox kept
/// with no park owed, and a relaunch in flight over an owed park, are never
/// asked.
#[test]
fn a_stopped_record_owing_a_park_is_asked_it_each_pass_and_each_new_result_told_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let owing = |item: &str, status: &str, owed: Option<Value>| {
        let mut lane = hosted_lane(dir.path(), item, item, "/w/lane");
        lane["repo"] = json!("o/r");
        lane["status"] = json!(status);
        lane["sandbox"] = json!("standing");
        if let Some(owed) = owed {
            lane["park_owed"] = owed;
        }
        lane
    };
    let lanes = vec![
        owing(
            "KEN-1",
            "stopped",
            Some(json!({"until_pr": 1400, "head": "h2"})),
        ),
        owing("KEN-2", "stopped", None),
        owing("KEN-3", "preparing", Some(json!({"pr": 7}))),
    ];
    fleet.set_lanes(lanes.clone());
    let state = fleet.read();
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let told = |produced: &Produced| -> Vec<String> {
        event_lines(produced)
            .into_iter()
            .filter(|l| l.starts_with("EVENT park-owed "))
            .collect()
    };
    // The provider's sandbox stops the real park asks, by item.
    let stops = |item: &str| -> usize {
        let asked = format!(" stop-sandbox --item {item}");
        world
            .host_log()
            .iter()
            .filter(|l| l.ends_with(&asked))
            .count()
    };
    // GitHub's reading of the pull request the owed park waits on.
    let pull = |state: &str| {
        json!({"graphql number=1400 cursor=": {"body": {"data": {"repository": {"pullRequest": {
            "state": state, "headRefOid": "h2", "headRefName": "ken-1", "autoMergeRequest": null,
            "mergeStateStatus": "CLEAN", "isInMergeQueue": false, "mergeQueueEntry": null}}}}}})
    };
    let refused = json!({"exit": 3, "stderr": "lane-host-fixture: sandbox-stopping item=KEN-1\nlane-host-fixture: sandbox-stop-refused item=KEN-1 fix=retry-park\n"});
    world.plant_host(&[
        ("stop-sandbox --item KEN-1#1", refused.clone()),
        ("stop-sandbox --item KEN-1#2", refused),
        (
            "stop-sandbox --item KEN-1#3",
            ok("sandbox-stopped item=KEN-1\n"),
        ),
    ]);
    world.plant_gh(pull("OPEN"));
    let first = driver.pass(&state);
    assert_eq!(
        told(&first),
        vec![
            "EVENT park-owed KEN-1 result=park-failed cause=exit=3 lane-host-fixture: sandbox-stop-refused item=KEN-1 fix=retry-park"
        ],
        "{:?}",
        first.failed
    );
    assert_eq!(stops("KEN-1"), 1);
    let again = driver.pass(&state);
    assert!(told(&again).is_empty(), "{:?}", lines(&again));
    assert_eq!(stops("KEN-1"), 2);
    world.plant_gh(pull("MERGED"));
    let merged = driver.pass(&state);
    assert_eq!(
        told(&merged),
        vec!["EVENT park-owed KEN-1 result=park-refused reason=pr-not-open pr=1400 state=MERGED"]
    );
    assert_eq!(stops("KEN-1"), 2, "a refused park stops nothing");
    world.plant_gh(pull("OPEN"));
    let parked = driver.pass(&state);
    assert_eq!(told(&parked), vec!["EVENT park-owed KEN-1 result=parked"]);
    assert_eq!(stops("KEN-1"), 3);
    assert_eq!(
        fleet.read().lanes[0].status,
        state::LaneStatus::Parked,
        "the real park wrote the record"
    );
    let mut after = lanes;
    after[0]["status"] = json!("parked");
    after[0].as_object_mut().unwrap().remove("park_owed");
    after[0].as_object_mut().unwrap().remove("sandbox");
    fleet.set_lanes(after);
    let quiet = driver.pass(&fleet.read());
    assert!(told(&quiet).is_empty(), "{:?}", lines(&quiet));
    assert_eq!(driver.baseline.get(hosted::PARK_OWED_ROW, "KEN-1"), None);
    assert_eq!(stops("KEN-1"), 3);
    for item in ["KEN-2", "KEN-3"] {
        assert_eq!(
            (stops(item), closes(&fleet, item)),
            (0, 0),
            "a kept sandbox and a relaunch in flight are never asked: {item}"
        );
    }
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    world.plant_host(&[
        (&format!("{} capabilities", provider(dir.path())), ok(SSH_LINE)),
        ("status --item KEN-1 --harness claude", ok("running\n")),
        ("status --item KEN-2 --harness claude", ok("running\n")),
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/lane-status-KEN-1.md",
            ok("# Lane status\n- Step: dev round 1\n"),
        ),
        ("cat --item KEN-1 /remote/KEN-1/tmp/items/KEN-1/workflow-state-KEN-1.json", ok(COUNTS_STATE)),
        (
            "cat --item KEN-1 /remote/KEN-1/tmp/validation-runs",
            ok("dev-validate-runs-v1\ndev-validate-implement\ndev-validate-fix\ndev-validate-restack-a\ndev-validate-restack-b\n"),
        ),
        ("cat --item KEN-2 /remote/KEN-2/tmp/lane-status-KEN-2.md", answer(1, "")),
        ("cat --item KEN-2 /remote/KEN-2/tmp/items/KEN-2/workflow-state-KEN-2.json", answer(1, "")),
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
    // The launch's process ran and ended, as the launch recorded it.
    let mut launched = program("sleep").arg("600").spawn().unwrap();
    let Reading::Live(ended) = agent_runtime::process::identity(launched.id()) else {
        panic!("the launch's identity did not read");
    };
    launched.kill().unwrap();
    launched.wait().unwrap();
    lane["launch"] =
        json!({"pane": pane, "server": server.pid, "pid": ended.pid, "start": ended.start});
    (lane, pane)
}

/// A merged lane's close-out removes its item's live record, so a record
/// that stands in the clone is a close-out still running or a lane resumed.
/// A hosted lane the provider's status verb reads exited is `lane-exited`
/// on the second pass; one whose item the GitHub duty read merged and whose
/// `.git` the host has not, or whose `.git` stands with the item's record
/// gone from the clone it names, is closed through the real close verb
/// then, its request naming the merge as the delivery the close records as
/// the lane's cycle, `lane-closed` with the provider's archive line under
/// it (`kept=none` where no archive root is set); one whose record stands
/// is not; one with no merged row is closed
/// with its sandbox kept (`keep-sandbox`, `kept=sandbox`, the record
/// stopped); one whose provider refuses its close is `lane-close-refused`
/// with the checkout it kept, its record open. A closed lane's last notice,
/// which no pass read, is said as its `lane-notice` line before its
/// `lane-closed`. The next pass, on the records the close wrote, says
/// nothing and asks nothing.
#[test]
fn a_merged_hosted_lane_whose_work_left_nothing_on_its_host_is_closed_at_lane_exited_and_one_whose_record_stands_is_not()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let items = ["KEN-1", "KEN-2", "KEN-3", "KEN-4", "KEN-5"];
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &items);
    for item in items {
        // Each lane's group ended: the provider reads it exited.
        drop(host.lead(item, "claude"));
    }
    // Their worktrees gone; the one with no merged row is kept open by the
    // gate alone.
    for item in ["KEN-1", "KEN-3", "KEN-5"] {
        host.leave(item);
    }
    // A worktree that stands with its record in the clone its `.git` names;
    // the other standing one's close-out removed its record.
    let state_dir = host.clone_of("KEN-2").join("tmp");
    std::fs::create_dir_all(&state_dir).unwrap();
    std::fs::write(support::item_record(&state_dir, "KEN-2"), "{}").unwrap();
    // A clone holding a file no render owns: the host's `kendex` owns none,
    // so the provider refuses the close and keeps the clone.
    std::fs::write(host.clone_of("KEN-5").join("notes.txt"), "kept\n").unwrap();
    write_executable(&host.tools.join("kendex"), "#!/bin/sh\necho '[]'\n");
    // The last notice KEN-4 wrote, which no pass read before its close.
    let mailbox = host.lane_root("KEN-4").join("tmp/lane-mail/KEN-4");
    std::fs::create_dir_all(&mailbox).unwrap();
    std::fs::write(
        mailbox.join("to-overseer.jsonl"),
        "{\"kind\":\"notice\",\"id\":\"n-last\",\"text\":\"result: done\"}\n",
    )
    .unwrap();
    let lanes: Vec<Value> = items
        .iter()
        .zip(["gh-1", "gh-2", "gh-3", "gh-4", "gh-5"])
        .map(|(item, window)| {
            let mut lane = hosted_pane_lane(&server, item, window, dir.path()).0;
            lane["mail_root"] = json!(host.lane_root(item).display().to_string());
            lane
        })
        .collect();
    fleet.set_lanes(lanes);
    let state = fleet.read();
    // The merged pull requests the close records as the lanes' cycles.
    let timeline = |number: u64| {
        let mut pull = pull_seven_timeline();
        pull["body"]["data"]["repository"]["pullRequest"]["number"] = json!(number);
        (format!("graphql number={number} cursor="), pull)
    };
    world.plant_gh(Value::Object(
        [7, 9, 10].into_iter().map(timeline).collect(),
    ));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    for (item, key) in [
        ("KEN-1", "o/r#7"),
        ("KEN-2", "o/r#8"),
        ("KEN-4", "o/r#9"),
        ("KEN-5", "o/r#10"),
    ] {
        driver.baseline.apply(Change::Set {
            kind: "merged".into(),
            identity: item.into(),
            value: key.into(),
        });
    }
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    let kept = format!("path={}", host.clone_of("KEN-5").display());
    let owed = support::item_record(&state_dir, "KEN-2");
    assert_eq!(
        lines(&second),
        vec![
            "EVENT lane-exited gh-1",
            "EVENT lane-closed KEN-1",
            "kept=none",
            "EVENT lane-exited gh-2",
            &format!("close-out-owed item=KEN-2 path={}", owed.display()),
            "EVENT lane-exited gh-3",
            "EVENT lane-closed KEN-3",
            "kept=sandbox",
            "EVENT lane-exited gh-4",
            "EVENT lane-notice KEN-4 n-last",
            "  result: done",
            "EVENT lane-closed KEN-4",
            "kept=none",
            "EVENT lane-exited gh-5",
            "EVENT lane-close-refused KEN-5",
            &kept,
        ],
        "{:?}",
        second.failed
    );
    assert_eq!(second.failed, None);
    // The records the real close wrote: each merge its request named
    // recorded as the lane's cycle, the keep stopped, the refused and the
    // standing ones open.
    let written = fleet.runner.fleet();
    let record = |item: &str| -> (Value, Value) {
        let lane = written["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .unwrap();
        (lane["status"].clone(), lane["cycle"]["pr"].clone())
    };
    assert_eq!(
        items.map(record),
        [
            (json!("done"), json!(7)),
            (json!("running"), Value::Null),
            (json!("stopped"), Value::Null),
            (json!("done"), json!(9)),
            (json!("running"), Value::Null),
        ],
        "{written}"
    );
    let watch_dir = lanes::watch_state_dir(&driver.settings.claim_store).to_path_buf();
    let marker = |item: &str| hosted::close_marker_path(&watch_dir, item);
    assert!(
        std::fs::metadata(marker("KEN-1")).is_ok(),
        "the close's marker stands"
    );
    assert!(
        std::fs::metadata(marker("KEN-5")).is_err(),
        "a refused close takes its marker"
    );
    // The records the close verb wrote, read on the next pass: the markers
    // leave and nothing is asked again.
    let third = driver.pass(&fleet.read());
    assert!(event_lines(&third).is_empty(), "{:?}", lines(&third));
    assert_eq!(third.failed, None);
    assert_eq!(items.map(|item| closes(&fleet, item)), [1, 0, 1, 1, 1]);
    assert!(std::fs::metadata(marker("KEN-1")).is_err());
}

/// A merged hosted lane read at work is closed once its work left its host:
/// a GitHub issue's lane, its pane on the fleet server drawn at the
/// harness's working hint and its provider's status verb reading it
/// running, the GitHub duty's merged row standing and the host answering
/// its `.git` absent, the first pass asks the real close verb with the
/// merge as the delivery, which stops the harness through the provider and
/// records the merge as the lane's cycle: `lane-closed` with its archive
/// line, `kept=none` where no archive root is set; the next pass, the same
/// screen, asks nothing again.
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
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["issue-1"]);
    // The pass's read and the close's judge read it running until the
    // close's stop ends its group; its worktree left the host.
    let _lane = host.lead("issue-1", "claude");
    let gitfile = host.lane_root("issue-1").join(".git");
    let gitbytes = std::fs::read(&gitfile).unwrap();
    std::fs::write(&gitfile, "unreadable worktree link\n").unwrap();
    let root = host.lane_root("issue-1").display().to_string();
    let mut lane = hosted_lane(dir.path(), "issue-1", "gh-1", &root);
    lane["repo"] = json!("o/r");
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    world.plant_gh(json!({"graphql number=7 cursor=": pull_seven_timeline()}));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "issue-1".into(),
        value: "o/r#7".into(),
    });
    let unread = driver.pass(&state);
    assert!(
        unread.failed.as_deref().is_some_and(
            |cause| cause.starts_with("worktree-read-failed item=issue-1 cause=gitfile-unread")
        ),
        "{:?}",
        unread.failed
    );
    assert!(event_lines(&unread).is_empty(), "{:?}", lines(&unread));
    assert_eq!(closes(&fleet, "issue-1"), 0);
    std::fs::write(&gitfile, gitbytes).unwrap();
    host.leave("issue-1");
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first),
        vec!["EVENT lane-closed issue-1", "kept=none"],
        "{:?}",
        first.failed
    );
    let written = fleet.runner.fleet();
    assert_eq!(
        (
            &written["lanes"][0]["status"],
            &written["lanes"][0]["cycle"]["pr"]
        ),
        (&json!("done"), &json!(7)),
        "the close recorded the merge its request named: {written}"
    );
    assert!(
        world
            .host_log()
            .iter()
            .any(|l| l.ends_with(" stop --item issue-1 --harness claude")),
        "the harness was stopped through the provider: {:?}",
        world.host_log()
    );
    let second = driver.pass(&state);
    assert!(
        !lines(&second).contains(&"EVENT lane-closed issue-1".to_owned()),
        "{:?}",
        lines(&second)
    );
    assert_eq!(closes(&fleet, "issue-1"), 1, "one ask per screen");
}

/// A provider can refuse a file read with `item-unknown` while its list
/// still names the sandbox. The watch closes one case through the real
/// close verb and leaves the other in flight.
#[test]
fn a_hosted_handoff_read_is_skipped_after_a_same_pass_close() {
    use orch_runtime::schedule::Duty;
    use orch_runtime::watch;

    let results = [true, false].map(|close| {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["issue-1"]);
        drop(host.lead("issue-1", "codex"));
        host.leave("issue-1");
        let root = host.lane_root("issue-1");
        let mut lane = hosted_lane(dir.path(), "issue-1", "gh-1", root.to_str().unwrap());
        lane["repo"] = json!("o/r");
        lane["harness"] = json!("codex");
        lane["session_since"] = json!("2026-09-20T11:00:00Z");
        fleet.set_lanes(vec![lane]);
        world.plant_gh(json!({"graphql number=7 cursor=": pull_seven_timeline()}));

        let provider = world.scripts.join("provider");
        let ssh = world.scripts.join("ssh-provider");
        let refused = world.scripts.join("item-unknown");
        std::fs::rename(&provider, &ssh).unwrap();
        write_executable(
            &provider,
            format!(
                r#"#!/bin/sh
if [ "$1" = cat ] && [ "${{4-}}" = '{gitfile}' ]; then
  if [ '{close}' = false ] || jq -e '.lanes[] | select(.item == "issue-1" and .status == "done")' '{fleet}' >/dev/null; then
    : > '{refused}'
    echo 'lane-host-daytona: item-unknown item=issue-1' >&2
    exit 1
  fi
fi
if [ "$1" = list ]; then
  printf 'o/r/issue-1\trunning\t1m\tbox\n'
  exit 0
fi
exec '{ssh}' "$@"
"#,
                gitfile = root.join(".git").display(),
                fleet = fleet.path().display(),
                refused = refused.display(),
                ssh = ssh.display()
            ),
        );

        lane_driver!(server, fleet, readers, driver);
        driver.scripts = world.scripts.clone();
        if close {
            // The previous pass read the exited lane once.
            driver.baseline.apply(Change::Set {
                kind: "lane-exited".into(),
                identity: "gh-1".into(),
                value: String::new(),
            });
            let merged = clock::epoch_secs("2026-09-20T11:20:00Z").unwrap();
            driver.baseline.apply(Change::Set {
                kind: "merged".into(),
                identity: "issue-1".into(),
                value: format!("o/r#7@{merged}"),
            });
        }
        let mut produced = driver.pass(&fleet.read());
        let failure = produced.failed.clone();

        let paths = watch::Paths::of(&fleet.path()).unwrap();
        let clock = FakeClock::new();
        let pid = std::process::id();
        let identity = Identity { pid, start: start_of(pid) };
        let mut runner = watch::Runner::new(
            paths.clone(),
            &clock,
            &settings_in(fleet.runner.state_dir()),
            watch::Flags {
                interval: Duration::from_secs(240),
                max_loops: 25,
                since: None,
                repos: Vec::new(),
                fresh: true,
            },
            identity.clone(),
            watch::Recorded {
                pane: "none".into(),
                script: "orch-runtime".into(),
                cwd: dir.path().display().to_string(),
            },
        )
        .unwrap();
        runner.register(
            Duty::NativeObservation,
            Box::new(move |_| Ok(std::mem::take(&mut produced))),
        );
        run_driven(runner, &clock, &paths, &identity, || clock.await_sleepers(1)).unwrap();
        let log = std::fs::read_to_string(&paths.log).unwrap();
        assert_eq!(
            log.contains("EVENT lane-closed issue-1"),
            close,
            "{log} {failure:?} {:?}",
            host.calls(),
        );
        let status = fleet.read().lanes[0].status;
        if close {
            assert_eq!(status, state::LaneStatus::Done);
        } else {
            assert!(status.in_flight(), "{status:?}");
        }
        if !close {
            assert!(failure.as_deref().is_some_and(|cause| cause.starts_with("handoff-read-failed item=issue-1 ") && cause.contains("item-unknown item=issue-1")), "{failure:?}");
        }
        (
            failure,
            log.contains("EVENT watch-step-failed step=native-observation"),
            refused.exists(),
        )
    });
    assert!(results[1].1 && results[1].2, "{results:?}");
    assert_eq!(results[0], (None, false, false));
}

/// The mail duty can start its read before the watch settles a close. A
/// provider's list can still name the sandbox after its file read fails.
#[test]
fn a_failed_hosted_mail_read_is_judged_against_the_current_lane() {
    use orch_runtime::schedule::Duty;
    use orch_runtime::watch::{self, mail};

    for closed in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let root = dir.path().to_str().unwrap();
        fleet.set_lanes(vec![hosted_lane(dir.path(), "KEN-1", "gh-1", root)]);
        let current = fleet.path().with_extension("closed");
        let mut record = fleet.runner.fleet();
        record["lanes"][0]["status"] = json!("done");
        std::fs::write(&current, record.to_string()).unwrap();
        std::fs::create_dir(dir.path().join("scripts")).unwrap();
        write_executable(
            Path::new(&provider(dir.path())),
            format!(
                r#"#!/bin/sh
case "$1" in
  read-many)
    if [ '{closed}' = true ]; then mv '{current}' '{fleet}'; fi
    echo 'lane-host-daytona: item-unknown item=KEN-1' >&2
    exit 1 ;;
  list) printf 'o/r/KEN-1\trunning\t1m\tbox\n' ;;
  *) exit 64 ;;
esac
"#,
                current = current.display(),
                fleet = fleet.path().display(),
            ),
        );
        let settings = settings_in(fleet.runner.state_dir());
        let paths = watch::Paths::of(&fleet.path()).unwrap();
        let config = mail::Config::of(&settings, &paths).unwrap();
        let mut mail = mail::MailDuty::new(Mailbox::new(lane_mail().to_path_buf()), config);
        let clock = FakeClock::new();
        let produced = mail
            .run(&watch::Tick {
                duty: Duty::Mail,
                now: clock.now(),
                wall: clock.wall_secs(),
                baseline: &Baseline::default(),
                clock: &clock,
            })
            .unwrap();
        assert_eq!(fleet.read().lanes[0].status.in_flight(), !closed);
        match (closed, produced.failed.as_deref()) {
            (true, None) => {}
            (false, Some(cause)) => {
                assert!(cause.contains("item=KEN-1 mail-read-failed"), "{cause}")
            }
            (_, failure) => panic!("closed={closed}: {failure:?}"),
        }
    }
}

/// A hosted lane with a merge newer than its session still owns a
/// close-out while the state record stands. The idle key earns one line,
/// and removal of the record lets the pending close finish.
#[test]
fn a_merged_idle_hosted_lane_reports_close_out_owed_once_then_closes() {
    hosted_idle_close_out(FirstCloseOut::Live);
}

/// A reported idle key still owes the path when its first hosted read
/// refused the record or its merge was undated. A refusal after the path
/// was printed does not rearm the notice.
#[test]
fn a_hosted_idle_retry_reports_the_previously_unread_close_out_path_once() {
    hosted_idle_close_out(FirstCloseOut::Refused);
    hosted_idle_close_out(FirstCloseOut::Undated);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FirstCloseOut {
    Live,
    Refused,
    Undated,
}

fn hosted_idle_close_out(first: FirstCloseOut) {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["issue-1"]);
    let _group = host.lead("issue-1", "codex");
    let root = host.lane_root("issue-1");
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        "printf '%s\\n' '› complete' '› Type a prompt'; exec bash --norc --noprofile",
    );
    await_drawn(&server, &pane, "Type a prompt");
    let mut lane = hosted_lane(dir.path(), "issue-1", "gh-1", root.to_str().unwrap());
    lane["harness"] = json!("codex");
    lane["repo"] = json!("o/r");
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    lane["session_since"] = json!("2026-09-20T11:00:00Z");
    fleet.set_lanes(vec![lane]);
    let state_dir = host.clone_of("issue-1").join("tmp");
    std::fs::create_dir_all(&state_dir).unwrap();
    let record = support::item_record(&state_dir, "issue-1");
    std::fs::write(&record, "{}").unwrap();
    let refuse = world.scripts.join("refuse-record");
    if first == FirstCloseOut::Refused {
        let provider = world.scripts.join("provider");
        let ssh = world.scripts.join("ssh-provider");
        std::fs::rename(&provider, &ssh).unwrap();
        write_executable(
            &provider,
            format!(
                r#"#!/bin/sh
if [ "$1" = cat ] && [ "${{4-}}" = '{record}' ] && [ -f '{refuse}' ]; then
  echo 'lane-host-ssh: record read unavailable' >&2
  exit 1
fi
exec '{ssh}' "$@"
"#,
                record = record.display(),
                refuse = refuse.display(),
                ssh = ssh.display(),
            ),
        );
    }
    world.plant_gh(json!({"graphql number=7 cursor=": pull_seven_timeline()}));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let merged = clock::epoch_secs("2026-09-20T11:20:00Z").unwrap();
    let merge_row = |value: String| Change::Set {
        kind: "merged".into(),
        identity: "issue-1".into(),
        value,
    };
    let dated = format!("o/r#7@{merged}");
    driver
        .baseline
        .apply(merge_row(if first == FirstCloseOut::Undated {
            "o/r#7".into()
        } else {
            dated.clone()
        }));
    assert!(event_lines(&driver.pass(&fleet.read())).is_empty());
    if first == FirstCloseOut::Refused {
        std::fs::write(&refuse, "").unwrap();
    }
    let idle = driver.pass(&fleet.read());
    let header = "EVENT idle-after-return gh-1";
    assert_eq!(event_lines(&idle), [header], "{first:?}");
    let owed = format!("close-out-owed item=issue-1 path={}", record.display());
    let has_owed = |produced: &Produced| lines(produced).contains(&owed);
    let assert_refused = |produced: &Produced| {
        assert!(
            produced.failed.as_deref().is_some_and(|cause| {
                cause.starts_with("worktree-read-failed item=issue-1 ")
                    && cause.contains("record read unavailable")
            }),
            "{:?}",
            produced.failed
        );
    };
    let told = match first {
        FirstCloseOut::Live => idle,
        FirstCloseOut::Refused => {
            assert_refused(&idle);
            assert!(!has_owed(&idle));
            std::fs::remove_file(&refuse).unwrap();
            driver.pass(&fleet.read())
        }
        FirstCloseOut::Undated => {
            assert_eq!(idle.failed, None);
            assert!(!has_owed(&idle));
            driver.baseline.apply(merge_row(dated));
            driver.pass(&fleet.read())
        }
    };
    let said = lines(&told);
    assert_eq!(
        said.iter().filter(|line| **line == owed).count(),
        1,
        "{first:?}: {said:?}"
    );
    if first != FirstCloseOut::Live {
        assert_eq!(said, [header, &owed], "{first:?}");
    }
    assert_eq!(told.failed, None);
    if first == FirstCloseOut::Refused {
        std::fs::write(&refuse, "").unwrap();
        let unread = driver.pass(&fleet.read());
        assert_refused(&unread);
        assert!(lines(&unread).is_empty(), "{:?}", lines(&unread));
        std::fs::remove_file(&refuse).unwrap();
    }
    let repeated = driver.pass(&fleet.read());
    assert!(lines(&repeated).is_empty(), "{:?}", lines(&repeated));
    assert_eq!(closes(&fleet, "issue-1"), 0);
    assert_eq!(repeated.failed, None);

    std::fs::remove_file(&record).unwrap();
    let finished = driver.pass(&fleet.read());
    assert_eq!(finished.failed, None);
    assert_eq!(lines(&finished), ["EVENT lane-closed issue-1", "kept=none"]);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Done);
}

#[test]
fn a_finished_hosted_close_uses_the_latest_eligible_merge() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-1"]);
    drop(host.lead("KEN-1", "claude"));
    host.leave("KEN-1");
    let (mut lane, _) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    lane["mail_root"] = json!(host.lane_root("KEN-1").display().to_string());
    lane["session_since"] = json!("2026-09-20T11:00:00Z");
    fleet.set_lanes(vec![lane]);
    let mut earlier = pull_seven_timeline();
    let pull = &mut earlier["body"]["data"]["repository"]["pullRequest"];
    pull["number"] = json!(8);
    pull["mergedAt"] = json!("2026-09-20T11:19:00Z");
    world.plant_gh(json!({
        "graphql number=7 cursor=": pull_seven_timeline(),
        "graphql number=8 cursor=": earlier,
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let latest = clock::epoch_secs("2026-09-20T11:20:00Z").unwrap();
    let older = clock::epoch_secs("2026-09-20T11:19:00Z").unwrap();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: format!("o/r#7@{latest} o/r#8@{older}"),
    });
    assert_eq!(driver.pass(&fleet.read()).failed, None);
    assert_eq!(driver.pass(&fleet.read()).failed, None);
    let written = fleet.runner.fleet();
    let written = &written["lanes"][0];
    assert_eq!(written["status"], "done");
    assert_eq!(written["cycle"]["pr"], 7);
}

#[test]
fn a_merge_before_the_launch_leaves_a_working_hosted_lane_open() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        "printf '✻ Working… (esc to interrupt)\\n'; exec sleep 600",
    );
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["issue-1"]);
    let _lane = host.lead("issue-1", "claude");
    host.leave("issue-1");
    let root = host.lane_root("issue-1").display().to_string();
    let mut lane = hosted_lane(dir.path(), "issue-1", "gh-1", &root);
    lane["repo"] = json!("o/r");
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    lane["launched_at"] = json!("2026-09-20T11:20:01Z");
    fleet.set_lanes(vec![lane.clone()]);
    let state = fleet.read();
    let since = "2026-09-20T10:00:00Z";
    world.plant_gh(json!({
        "repos/o/r/actions/workflows?per_page=100&page=1": {"body": {"total_count": 0, "workflows": []}},
        "repos/o/r/pulls?state=closed&head=o%3Aissue-1&per_page=100&page=1": {"body": [{
            "number": 7, "state": "closed", "title": "work", "merged_at": "2026-09-20T11:20:00Z",
            "body": "", "author_association": "NONE", "merge_commit_sha": null, "user": null,
            "head": {"sha": "h2", "ref": "issue-1", "repo": {"full_name": "o/r", "owner": {"login": "o", "type": "User"}}},
            "base": {"ref": "main", "sha": "b1"}
        }]},
        "search/issues?q=repo%3Ao%2Fr%20is%3Apr%20is%3Amerged%20%22issue-1%22%20in%3Atitle%2Cbody%20merged%3A%3E%3D2026-09-20T10%3A00%3A00Z&per_page=100&page=1": {"body": {"total_count": 0, "incomplete_results": false, "items": []}},
        "graphql number=7 cursor=": pull_seven_timeline(),
    }));
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    let mut github = github::body(github::Context {
        fleet: fleet.path(),
        settings: driver.settings.clone(),
        since: clock::epoch_secs(since),
        since_iso: Some(since.to_owned()),
        repos: Vec::new(),
        gh: world.gh(),
        pr_watch: PathBuf::new(),
        shared: Default::default(),
    });
    let clock = FakeClock::new();
    let read = github(&orch_runtime::watch::Tick {
        duty: orch_runtime::schedule::Duty::GitHub,
        now: clock.now(),
        wall: driver.now,
        baseline: &driver.baseline,
        clock: &clock,
    })
    .unwrap();
    assert!(event_lines(&read).contains(&"EVENT merged 7 issue-1 o/r".to_owned()));
    apply(&mut driver.baseline, &read);

    let observed = driver.pass(&state);
    assert_eq!(observed.failed, None);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Running);
    assert_eq!(closes(&fleet, "issue-1"), 0);

    // A reused fleet row keeps the first launch and dates the new attempt.
    lane["launched_at"] = json!("2026-09-20T11:00:00Z");
    lane["session_since"] = json!("2026-09-20T11:30:00Z");
    fleet.set_lanes(vec![lane.clone()]);
    let observed = driver.pass(&fleet.read());
    assert_eq!(observed.failed, None);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Running);
    assert_eq!(closes(&fleet, "issue-1"), 0);

    // A merge at the current attempt's timestamp can still finish it.
    lane["session_since"] = json!("2026-09-20T11:20:00Z");
    fleet.set_lanes(vec![lane]);
    let observed = driver.pass(&fleet.read());
    assert_eq!(observed.failed, None);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Done);
    assert_eq!(closes(&fleet, "issue-1"), 1);
}

/// What a hosted lane's work leaves on its host, the finished close's proof
/// that nothing is left: a record standing under the root its host named
/// reads live, and a root still the launch's checkout proves nothing gone,
/// so the close keeps waiting rather than closing the lane.
#[test]
fn a_hosted_lanes_worktree_record_still_stands_for_the_finished_close() {
    let rows: [(&str, Option<&str>, hosted::Answer<()>); 2] = [
        ("named root", None, hosted::Answer::Live(())),
        (
            "pending root",
            Some("/remote/KEN-4"),
            hosted::Answer::Unreadable {
                cause: "root-pending".to_owned(),
            },
        ),
    ];
    for (case, checkout, expected) in rows {
        let dir = tempfile::tempdir().unwrap();
        let scripts = provider_world(dir.path());
        let root = "/remote/KEN-4";
        let disk = scripts.join("disk");
        // The pending row plants nothing: no read can make it live, and an
        // absent file must not read as gone.
        if checkout.is_none() {
            on_disk(
                &disk,
                "/remote/KEN-4/.git",
                "gitdir: /remote/clone/.git/worktrees/KEN-4\n",
            );
            on_disk(
                &disk,
                "/remote/KEN-4/kendex.settings.toml",
                "[env]\nORCH_STATE_DIR = \"tmp\"\n",
            );
            on_disk(
                &disk,
                "/remote/KEN-4/tmp/items/KEN-4/workflow-state-KEN-4.json",
                "{}",
            );
        }
        let mut record = hosted_lane(dir.path(), "KEN-4", "gh-4", root);
        if let Some(checkout) = checkout {
            record["checkout"] = json!(checkout);
        }
        let lane = serde_json::from_value(record).unwrap();
        assert_eq!(hosted::record_left(&scripts, &lane), expected, "{case}");
    }
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
    // The shipped entry runs the binary setup built for these sources: this
    // build's, for the mailbox's reads through the provider.
    let entry = project.join(".agents/skills/orch/scripts/orch-runtime");
    std::fs::remove_file(&entry).unwrap();
    std::os::unix::fs::symlink(binary(), &entry).unwrap();
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

/// End a harness the row started, whose pane its `exec` makes it the
/// whole of, by its own pid.
fn end_harness(identity: &Identity) {
    let out = std::process::Command::new("kill")
        .args(["-KILL", &identity.pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
}

/// A merged local lane whose worktree cannot be read is not one whose work
/// left: the lane of the row above, relaunched with its item's live state
/// record standing, its worktree under a parent the row makes unreadable,
/// is not closed by the pass; the record stays running and the harness
/// lives. Where the permission bits do not bind (a root run) the row
/// cannot make the read fail and says so.
#[test]
#[expect(
    clippy::print_stderr,
    reason = "a run the row cannot make fail says it skipped, never passes silently"
)]
fn a_merged_local_lane_whose_worktree_cannot_be_read_keeps_its_running_harness() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let locked = dir.path().join("locked");
    let worktree = locked.join("worktree");
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
    // The guard gives the mode back however the row ends, so the temporary
    // directory stays removable.
    struct Enterable<'a>(&'a Path);
    impl Drop for Enterable<'_> {
        fn drop(&mut self) {
            let _ = std::fs::set_permissions(self.0, std::fs::Permissions::from_mode(0o700));
        }
    }
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    let enterable = Enterable(&locked);
    if std::fs::symlink_metadata(&worktree).is_ok() {
        drop(enterable);
        end_harness(&identity);
        eprintln!("skipped: the permission bits do not bind for this user");
        return;
    }
    fleet.set_lanes(vec![lane]);
    std::fs::write(
        support::item_record(fleet.runner.state_dir(), "issue-1"),
        "{}\n",
    )
    .unwrap();
    let state = fleet.read();
    let scripts = real_close_scripts(dir.path(), &server, &fleet);
    std::fs::write(
        dir.path().join("bin/gh.json"),
        json!({"graphql number=7 cursor=": pull_seven_timeline()}).to_string(),
    )
    .unwrap();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts;
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "issue-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    drop(enterable);
    let said = lines(&first);
    assert!(
        !said.contains(&"EVENT lane-closed issue-1".to_owned()),
        "{said:?}"
    );
    let record = fleet.read();
    let record = record.lanes.iter().find(|l| l.item == "issue-1").unwrap();
    assert_eq!(record.status, state::LaneStatus::Running, "{record:?}");
    assert!(live(identity.pid), "the working harness was ended");
    end_harness(&identity);
}

/// A merged local lane whose work left nothing behind is closed by the
/// watch's own pass at its finished line, and its slot is free: one local
/// Claude Code lane at its composer on a provider stop, resumed while its
/// item is unmerged and, once the GitHub duty's merged row stands, told
/// (`idle-after-return`) and closed with no resume left; and one whose
/// harness ended and whose pane holds only its shell, read exited on two
/// passes (`lane-exited`) under its merged row. Each item's live state
/// record is gone from the fleet's state directory, so each lane is asked
/// closed through the real close verb with its merge as the delivery; the
/// pass says `lane-closed` for each, the records read done, the idle
/// lane's harness is ended, and `lane charges` no longer counts its
/// account, which it counted before the passes.
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
    // The idle lane's turn ended on a provider stop.
    let rows_file = dir
        .path()
        .join("worktree-1/tmp/lane-mail/issue-1/session-rows.jsonl");
    std::fs::create_dir_all(rows_file.parent().unwrap()).unwrap();
    std::fs::write(
        &rows_file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"server_error\"}\n",
    )
    .unwrap();
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
    let merge = |driver: &mut LaneDriver<'_>, item: &str, merged: &str| {
        driver.baseline.apply(Change::Set {
            kind: "merged".into(),
            identity: item.into(),
            value: merged.into(),
        });
    };
    merge(&mut driver, "issue-2", "o/r#8");
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    let said = event_lines(&second);
    for line in ["EVENT lane-exited gh-2", "EVENT lane-closed issue-2"] {
        assert!(
            said.contains(&line.to_owned()),
            "{line}: {said:?} {:?}",
            second.failed
        );
    }
    assert!(
        driver.baseline.get("resume", "gh-1").is_some(),
        "the unmerged stop is resumed: {said:?}"
    );
    // The merge lands after the stop's resume was asked: the lane takes
    // its finished line and the close, never the resume.
    merge(&mut driver, "issue-1", "o/r#7");
    let third = driver.pass(&state);
    let said = event_lines(&third);
    for line in [
        "EVENT idle-after-return gh-1 cause=server_error",
        "EVENT lane-closed issue-1",
    ] {
        assert!(
            said.contains(&line.to_owned()),
            "{line}: {said:?} {:?}",
            third.failed
        );
    }
    assert_eq!(driver.baseline.get("resume", "gh-1"), None);
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

/// A merged local lane whose post-merge work is live, its worktree present
/// and its state record standing with no close-out stamp, is resumed at a
/// provider stop like an unmerged one: the close would keep it, so the line
/// alone would leave it idle with nobody typing.
#[test]
fn a_merged_lane_whose_work_is_live_is_resumed_at_a_provider_stop() {
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
    fleet.set_lanes(vec![one]);
    let state = fleet.read();
    let rows_file = dir
        .path()
        .join("worktree-1/tmp/lane-mail/issue-1/session-rows.jsonl");
    std::fs::create_dir_all(rows_file.parent().unwrap()).unwrap();
    std::fs::write(
        &rows_file,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"server_error\"}\n",
    )
    .unwrap();
    lane_driver!(server, fleet, readers, driver);
    std::fs::write(
        support::item_record(&driver.state_dir, "issue-1"),
        "{\"cycles\":0}\n",
    )
    .unwrap();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "issue-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    let second = driver.pass(&state);
    let said: Vec<String> = [event_lines(&first), event_lines(&second)].concat();
    assert!(
        driver.baseline.get("resume", "gh-1").is_some(),
        "the merged lane with live work is resumed: {said:?} {:?}",
        second.failed
    );
    for word in ["EVENT idle-after-return", "EVENT lane-closed"] {
        assert!(
            !said.iter().any(|l| l.starts_with(word)),
            "{word}: {said:?}"
        );
    }
    let record = fleet.read();
    let record = record.lanes.iter().find(|l| l.item == "issue-1").unwrap();
    assert_ne!(record.status, state::LaneStatus::Done, "{record:?}");
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
        "reviews": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []},
        "timelineItems": {"pageInfo": {"hasNextPage": false}, "nodes": []}
    }}}}})
}

/// While the GitHub duty has yet to date its old baseline row, the watch
/// retains the close instead of ending the attempt with its sandbox kept.
/// Once dated, a tracker hold still defers the finished close until the
/// watch can retry on the already reported exit.
#[test]
fn a_finished_hosted_close_the_tracker_hold_deferred_is_retried_while_its_line_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-1"]);
    // The lane's group ended and its worktree left the host.
    drop(host.lead("KEN-1", "claude"));
    host.leave("KEN-1");
    let (mut one, pane) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    one["mail_root"] = json!(host.lane_root("KEN-1").display().to_string());
    one["launched_at"] = json!("2026-09-20T11:00:00Z");
    fleet.set_lanes(vec![one]);
    let state = fleet.read();
    world.plant_gh(json!({"graphql number=7 cursor=": pull_seven_timeline()}));
    lane_driver!(server, fleet, readers, driver);
    driver.now = clock::epoch_secs("2026-09-20T11:30:00Z").unwrap();
    driver.scripts = world.scripts.clone();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: "o/r#7".into(),
    });
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let second = driver.pass(&state);
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Running);
    assert_eq!(event_lines(&second), vec!["EVENT lane-exited gh-1"]);
    assert_eq!(second.failed, None);
    let pane_key = format!("{} {pane}", server.pid);
    assert_eq!(
        driver.baseline.get("close-pending", "gh-1"),
        Some(format!("lane-exited|{pane_key}").as_str())
    );
    assert_eq!(closes(&fleet, "KEN-1"), 0);

    let at = clock::epoch_secs("2026-09-20T11:20:00Z").unwrap();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: format!("o/r#7@{at}"),
    });
    let now = driver.now;
    driver.baseline.apply(Change::Set {
        kind: "tracker-quota".into(),
        identity: "fleet".into(),
        value: json!({"limit": "requests", "status": "future", "reset": clock::iso_utc(now + 7200), "reset_epoch": now + 7200}).to_string(),
    });
    let held = driver.pass(&state);
    assert!(event_lines(&held).is_empty(), "{:?}", lines(&held));
    assert_eq!(held.failed, None);
    assert_eq!(closes(&fleet, "KEN-1"), 0, "a standing hold asks nothing");
    driver.baseline.apply(Change::Clear {
        kind: "tracker-quota".into(),
        identity: "fleet".into(),
    });
    let third = driver.pass(&state);
    assert_eq!(
        lines(&third),
        vec!["EVENT lane-closed KEN-1", "kept=none"],
        "{:?}",
        third.failed
    );
    assert_eq!(driver.baseline.get("close-pending", "gh-1"), None);
    assert_eq!(closes(&fleet, "KEN-1"), 1);
    let fourth = driver.pass(&fleet.read());
    assert!(lines(&fourth).is_empty(), "{:?}", lines(&fourth));
    assert_eq!(fourth.failed, None);
    assert_eq!(closes(&fleet, "KEN-1"), 1);
}

#[test]
fn a_failed_finished_hosted_close_is_retried_without_repeating_the_exit_event() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-1"]);
    drop(host.lead("KEN-1", "claude"));
    host.leave("KEN-1");
    let (mut lane, _) = hosted_pane_lane(&server, "KEN-1", "gh-1", dir.path());
    lane["mail_root"] = json!(host.lane_root("KEN-1").display().to_string());
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-1".into(),
        value: "o/r#7".into(),
    });

    assert!(event_lines(&driver.pass(&state)).is_empty());
    let first = driver.pass(&state);
    let second = driver.pass(&state);
    let refusal = "lane-close-failed item=KEN-1 refused key=cycle-unrecorded item=KEN-1 cause=";
    for attempt in [&first, &second] {
        assert!(
            attempt
                .failed
                .as_deref()
                .is_some_and(|cause| cause.starts_with(refusal)),
            "{:?}: {:?}",
            lines(attempt),
            attempt.failed
        );
    }
    assert_eq!(event_lines(&first), vec!["EVENT lane-exited gh-1"]);
    assert_eq!(event_lines(&second), Vec::<String>::new());
}

/// A walled hosted lane's harness must not run on beside the successor the
/// relaunch opens: a walled lane whose kind declares a local pane has its
/// harness stopped through the provider's `stop --item --harness` under the
/// record's host before the relaunch starts. A stop the provider refuses
/// leaves the wall to the overseer with `wall-relaunch-refused
/// reason=stop-failed`, its status and its refusal line under the line, and
/// nothing starts; one that answers exit 0 with a line other than `stopped
/// item=ITEM processes=N` does the same with `cause=answer-unparsed` alone
/// (`hosted::stop` states both). So does a stop that gave no answer, a status
/// of 128 and above (a signal, the ssh provider's 255), said
/// `reason=stop-unanswered`, since the harness may still run.
#[test]
fn a_walled_hosted_pane_local_lane_is_stopped_through_the_provider_before_its_relaunch() {
    for (stop, refused) in [
        (ok("stopped item=KEN-4 processes=1\n"), None),
        (
            json!({"exit": 1, "stderr": "lane-host-fixture: stopping item=KEN-4\nlane-host-fixture: stop-refused item=KEN-4 fix=retry-stop\n"}),
            Some("stop-failed exit=1 lane-host-fixture: stop-refused item=KEN-4 fix=retry-stop"),
        ),
        (
            json!({"exit": 4, "stderr": "lane-host: stop-worktree-removed item=KEN-4\n"}),
            Some("stop-failed exit=4 stop-worktree-removed item=KEN-4"),
        ),
        (
            json!({"exit": 0, "stdout": "stopped item=KEN-4\n", "stderr": "lane-host-fixture: stopping item=KEN-4\n"}),
            Some("stop-failed cause=answer-unparsed"),
        ),
        (
            json!({"exit": 137}),
            Some("stop-unanswered stop exit=137 stderr=empty"),
        ),
        (
            json!({"exit": 255}),
            Some("stop-unanswered stop exit=255 stderr=empty"),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let mut record = relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ));
        record["host"] = json!(provider(dir.path()));
        record["kind"] = json!("ssh");
        // A hosted record: the lane's root is on its host, and the
        // checkout the launch ran from, where the relaunch runs again, is
        // the only local directory it names.
        let remote_root = dir.path().join("only-on-the-remote-host");
        record["mail_root"] = json!(remote_root.display().to_string());
        record["checkout"] = json!(dir.path().display().to_string());
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        let world = HostedWorld::new(dir.path(), &server, &fleet);
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
        // The fleet's host is the lane's, where the walk judges the lane's
        // own harness and model.
        let host = provider(dir.path());
        lane_driver!(
            server,
            fleet,
            readers,
            driver,
            &[("ORCH_LANE_HOST", host.as_str())]
        );
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

/// The SSH kind's line of a provider that owns its harness's session
/// (`pane=verb`).
const VERB_LINE: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb";

/// A lane on a provider that owns its harness's session (`pane=verb`),
/// walled by its Pi session rows read through the provider, has its harness
/// stopped through the provider's `stop --item --harness` before the relaunch
/// starts, as a `pane=local` lane's is: a relaunch beside the running
/// harness would run two sessions for one item. A stop the provider refuses
/// leaves the wall to the overseer with `reason=stop-failed` and nothing
/// starts.
#[test]
fn a_walled_pane_verb_lane_is_stopped_through_its_provider_before_its_relaunch() {
    for (stop, refused) in [
        (ok("stopped item=KEN-4 processes=1\n"), None),
        (
            json!({"exit": 4, "stderr": "lane-host: stop-worktree-removed item=KEN-4\n"}),
            Some("stop-failed exit=4 stop-worktree-removed item=KEN-4"),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let mut record = relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "pi",
            &server,
            "%0",
            None,
            dir.path(),
        ));
        record.as_object_mut().unwrap().remove("launch");
        record["host"] = json!(provider(dir.path()));
        record["kind"] = json!("ssh");
        let remote_root = dir.path().join("only-on-the-remote-host");
        record["mail_root"] = json!(remote_root.display().to_string());
        record["checkout"] = json!(dir.path().display().to_string());
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        let world = HostedWorld::new(dir.path(), &server, &fleet);
        let status_file = format!(
            "cat --item KEN-4 {}/tmp/lane-status-KEN-4.md",
            remote_root.display()
        );
        // The running watch's own state directory, where the relaunch's
        // marker is written.
        std::fs::create_dir_all(fleet.runner.state_dir().join("tmp/oversee-watch")).unwrap();
        let rows_file = format!(
            "cat --item KEN-4 {}/tmp/lane-mail/KEN-4/session-rows.jsonl",
            remote_root.display()
        );
        world.plant_host(&[
            ("capabilities", ok(VERB_LINE)),
            ("status --item KEN-4 --harness pi", ok("running\n")),
            ("capture --item KEN-4", ok("pi drew this\n")),
            (
                rows_file.as_str(),
                ok("{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"error\",\"message\":\"429 Usage limit reached for this model\",\"at\":3}\n"),
            ),
            (status_file.as_str(), ok("Step: start\n")),
            ("stop --item KEN-4 --harness pi", stop),
        ]);
        // The fleet's host is the lane's, where the walk judges the lane's
        // own harness and model.
        let host = provider(dir.path());
        lane_driver!(
            server,
            fleet,
            readers,
            driver,
            &[("ORCH_LANE_HOST", host.as_str())]
        );
        driver.scripts = world.scripts.clone();
        driver.pick = Pick::Lane("/home/me/.bclaude".to_owned());
        let produced = driver.pass(&state);
        let stop_line = format!(
            "ORCH_LANE_HOST={} stop --item KEN-4 --harness pi",
            provider(dir.path())
        );
        assert!(
            world.host_log().contains(&stop_line),
            "{:?} {:?}",
            world.host_log(),
            lines(&produced)
        );
        let started = driver.relaunches.borrow();
        match refused {
            Some(status) => {
                assert!(
                    lines(&produced)
                        .contains(&format!("wall-relaunch-refused lane=gh-4 reason={status}")),
                    "{:?}",
                    lines(&produced)
                );
                assert!(started.is_empty(), "nothing starts on a failed stop");
            }
            None => {
                assert!(
                    event_lines(&produced).contains(
                        &"EVENT lane-relaunched KEN-4 lane=/home/me/.bclaude from=/home/me/.eclaude"
                            .to_owned()
                    ),
                    "{:?}",
                    lines(&produced)
                );
                assert_eq!(started.len(), 1);
            }
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
    let mut lanes = vec![
        prepare("KEN-1", "preparing", now - 1801, "/l1", None),
        prepare("KEN-2", "running", now - 10, "/l2", None),
        prepare("KEN-3", "stopped", now - 20, "/l3", Some("create-failed")),
        prepare("KEN-4", "preparing", now - 100, "/l4", None),
    ];
    let running = ["KEN-1", "KEN-2", "KEN-4"];
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &running);
    let _lanes = running.map(|item| host.lead(item, "claude"));
    let checkout = fleet.runner.state_dir().display().to_string();
    for index in [0, 3] {
        lanes[index]["checkout"] = json!(checkout);
        lanes[index]["mail_root"] = json!(checkout);
    }
    lanes[1]["mail_root"] = json!(host.lane_root("KEN-2").display().to_string());
    fleet.set_lanes(lanes.clone());
    let state = fleet.read();
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
    init_checkout(&fleet, &checkout);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    let old_account = dir.path().join("old-account");
    let new_account = dir.path().join("new-account");
    std::fs::create_dir_all(&old_account).unwrap();
    plant_credential(&new_account);
    let mut record = relaunchable(lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        &checkout,
    ));
    // The record names its effort: the launch refuses a lane on an account
    // without one.
    record["effort"] = json!("high");
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

/// A walled worker whose recorded path another live lane took after it was
/// admitted is not retired by its wall recovery: the chain's close refuses
/// `launch-overlap` at exit 1, the walled harness runs on, the lane reads
/// `running` and no close is recorded.
#[test]
fn a_wall_relaunch_beside_a_live_holder_of_its_path_closes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let checkout = dir.path().join("checkout");
    init_checkout(&fleet, &checkout);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    let old_account = dir.path().join("old-account");
    let new_account = dir.path().join("new-account");
    std::fs::create_dir_all(&old_account).unwrap();
    plant_credential(&new_account);
    let mut record = relaunchable(lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        &checkout,
    ));
    record["effort"] = json!("high");
    record["account"] = json!(old_account.display().to_string());
    record["touched"] = json!(["src/a.sh"]);
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
    // The holder takes the path once the relaunch is composed, as another
    // lane's admission can while the walled lane stands.
    let holder = Owned::sleep();
    let mut lanes = fleet.runner.fleet()["lanes"].as_array().unwrap().clone();
    lanes.push(json!({
        "item": "KEN-H",
        "tracker": "linear",
        "harness": "copilot",
        "window": "fleet:KEN-H",
        "mail_root": "/w/holder",
        "session_since": "2026-01-29T15:00:00Z",
        "launched_at": "2026-01-29T15:00:00Z",
        "status": "running",
        "launch": {"pane": "%7", "server": 41020, "pid": holder.pid(), "start": holder.start()},
        "touched": ["src/a.sh"],
    }));
    fleet.set_lanes(lanes);
    let before = fleet.runner.fleet();
    let relaunch = driver.relaunches.borrow()[0].clone();
    let out = run_relaunch(&fleet, &relaunch);
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert_eq!(
        reply(&out)["refusal"]["key"],
        "launch-overlap",
        "{}",
        stderr(&out)
    );
    assert!(live(identity.pid), "the walled harness is not retired");
    assert_eq!(fleet.runner.fleet(), before, "nothing is written");
    assert_eq!(fleet.runner.fleet()["lanes"][0]["status"], "running");
}

/// A walled worker whose walk found no room is walked again on each later
/// pass under the same banner, quietly, before its reset and after it while
/// its own account still has no room; a refusal a later walk meets is said
/// once under the wall's line, and the first pass an account has room
/// relaunches it there with nobody starting it, its own-account resume
/// gone: the replacement takes its first turn on the start brief on that
/// account.
#[test]
fn a_walled_lane_the_walk_found_no_room_for_relaunches_when_an_account_has_room() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let checkout = dir.path().join("checkout");
    init_checkout(&fleet, &checkout);
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    let old_account = dir.path().join("old-account");
    let new_account = dir.path().join("new-account");
    std::fs::create_dir_all(&old_account).unwrap();
    plant_credential(&new_account);
    let mut record = relaunchable(lane_record(
        "KEN-4",
        "gh-4",
        "claude",
        &server,
        &pane,
        Some(&identity),
        &checkout,
    ));
    record["effort"] = json!("high");
    record["account"] = json!(old_account.display().to_string());
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    let scripts = dir.path().join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
    lane_driver!(
        server,
        fleet,
        readers,
        driver,
        &[("ORCH_WALL_RELAUNCH", "auto")]
    );
    driver.scripts = scripts;
    driver.pick = Pick::None;
    let first = driver.pass(&state);
    assert_eq!(
        lines(&first)[..2],
        [
            format!(
                "EVENT usage-limit gh-4 {} resets=2027-10-04T18:00:00Z",
                old_account.display()
            ),
            "pick none".to_owned()
        ]
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    // A later walk is held by a halt: said once while it stands.
    driver.halted = |_| Ok(true);
    assert_eq!(
        lines(&driver.pass(&state)),
        [
            format!(
                "EVENT usage-limit gh-4 {} resets=2027-10-04T18:00:00Z",
                old_account.display()
            ),
            "wall-relaunch-refused lane=gh-4 reason=halted".to_owned()
        ]
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    driver.halted = |_| Ok(false);
    // The reset passes with the account still walled.
    driver.now = BANNER_RESET + 60;
    let passed = driver.pass(&state);
    assert!(
        lines(&passed).contains(&"resume wake".to_owned()),
        "{:?}",
        lines(&passed)
    );
    let quiet = driver.pass(&state);
    assert!(lines(&quiet).is_empty(), "{:?}", lines(&quiet));
    assert!(driver.relaunches.borrow().is_empty());
    driver.pick = Pick::Lane(new_account.display().to_string());
    let room = driver.pass(&state);
    assert_eq!(
        event_lines(&room),
        vec![format!(
            "EVENT lane-relaunched KEN-4 lane={} from={}",
            new_account.display(),
            old_account.display()
        )]
    );
    assert_eq!(driver.relaunches.borrow().len(), 1);
    assert_eq!(driver.baseline.get("resume", "gh-4"), None);
    assert!(lines(&driver.pass(&state)).is_empty());
    assert_eq!(driver.relaunches.borrow().len(), 1, "relaunched once");
    let relaunch = driver.relaunches.borrow()[0].clone();
    let out = run_relaunch(&fleet, &relaunch);
    assert!(
        out.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    let lane = &fleet.runner.fleet()["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["account"], new_account.display().to_string(), "{lane}");
    let recorded: Value = serde_json::from_str(
        &std::fs::read_to_string(checkout.join("launch-record.json")).unwrap(),
    )
    .unwrap();
    assert!(
        recorded["argv"].as_array().unwrap().iter().any(|a| a
            .as_str()
            .is_some_and(|text| text.starts_with("/orch start KEN-4 This is an unattended"))),
        "the replacement takes its first turn on the start brief: {recorded}"
    );
    effect_report(&fleet.runner.op_fleet(&json!({
        "op": "close-owned-resources",
        "item": "KEN-4",
        "terminal": {"verdict": "completed", "source": "test"},
    })));
}

/// A wall no account has room for and nothing else recovers tells the
/// overseer once, with its cause, under its `usage-limit` line: a limit
/// whose banner names no reset, and an ended sign-in, which no reset
/// repairs. A limit with a reset waits for it and says nothing more.
#[test]
fn a_wall_nothing_can_recover_is_told_once_with_its_cause() {
    for (case, banner, cause) in [
        (
            "a limit with no reset",
            "  ⎿ \u{a0}You've hit your weekly limit",
            Some("no-room-no-reset"),
        ),
        (
            "an ended sign-in",
            "Not logged in · Please run /login",
            Some("no-other-account"),
        ),
        ("a limit with a reset", BANNER, None),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", banner);
        fleet.set_lanes(vec![relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        ))]);
        let state = fleet.read();
        lane_driver!(
            server,
            fleet,
            readers,
            driver,
            &[("ORCH_WALL_RELAUNCH", "auto")]
        );
        let notes = |produced: &Produced| -> Vec<String> {
            lines(produced)
                .into_iter()
                .filter(|l| l.starts_with("EVENT ") || l.starts_with("recovery-"))
                .collect()
        };
        let first = notes(&driver.pass(&state));
        assert_eq!(
            first.len(),
            1 + usize::from(cause.is_some()),
            "{case}: {first:?}"
        );
        assert!(
            first[0].starts_with("EVENT usage-limit gh-4"),
            "{case}: {first:?}"
        );
        if let Some(cause) = cause {
            assert_eq!(
                first[1],
                format!("recovery-stopped cause={cause}"),
                "{case}"
            );
        }
        for _ in 0..2 {
            assert!(notes(&driver.pass(&state)).is_empty(), "{case}: told once");
        }
    }
}

/// A Copilot or Pi lane at a wall whose named reset passed is resumed by
/// the wake on its own account, as a Claude lane is: the close's account
/// reading measures both harnesses, so the line says `resume wake` and the
/// wake's `resume` row is asked.
#[test]
fn a_copilot_or_pi_lane_resumes_after_its_usage_reset() {
    for harness in ["copilot", "pi"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let process = named_sleep(dir.path(), harness);
        let screen = dir.path().join("screen.txt");
        let drawn = match harness {
            "copilot" => format!("● Working through the queue.\n{BANNER}\n❯ \n"),
            _ => "pi drew this\n".to_owned(),
        };
        std::fs::write(&screen, &drawn).unwrap();
        let line = format!("cat {}; exec {} 600", screen.display(), process.display());
        let pane = server.open_window("gh-4", dir.path(), &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, harness);
        await_drawn(&server, &pane, drawn.lines().next().unwrap());
        fleet.set_lanes(vec![lane_record(
            "KEN-4",
            "gh-4",
            harness,
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        )]);
        if harness == "pi" {
            let rows = dir.path().join("tmp/lane-mail/KEN-4/session-rows.jsonl");
            std::fs::create_dir_all(rows.parent().unwrap()).unwrap();
            std::fs::write(
                &rows,
                format!(
                    "{}\n",
                    json!({"harness": "pi", "event": "Stop", "stop_reason": "error", "message": BANNER.trim_start_matches("  ⎿ \u{a0}"), "at": 1})
                ),
            )
            .unwrap();
        }
        let state = fleet.read();
        let started = |_: &Identity| Reading::Live(1_799_999_000);
        lane_driver!(server, fleet, readers, driver);
        driver.readers.start_epoch = &started;
        let walled = driver.pass(&state);
        assert!(
            event_lines(&walled)
                .iter()
                .any(|l| l.starts_with("EVENT usage-limit gh-4 /home/me/.eclaude resets=")),
            "{harness}: {:?}",
            lines(&walled)
        );
        driver.now = BANNER_RESET + 60;
        let passed = driver.pass(&state);
        assert!(
            lines(&passed).contains(&"resume wake".to_owned()),
            "{harness}: {:?}",
            lines(&passed)
        );
        assert!(
            driver
                .baseline
                .get("resume", "gh-4")
                .is_some_and(|row| row.starts_with("usage-limit|")),
            "{harness}: {:?}",
            driver.baseline.get("resume", "gh-4")
        );
    }
}

/// A worker its provider stopped is resumed on its own account with no
/// line while the stop is younger than the patience; the first pass past
/// `stop::PROVIDER_PATIENCE` walks the lane preference less the lane's own
/// provider. An entry the walk chose takes the lane, its brief naming the
/// prior session's transcript, under `lane-relaunched` and the move's
/// note, for a move to another harness and for a Pi lane's move to
/// another Pi provider alike, on the lane's own host. An entry judged on
/// another host is no move: with no other, nothing is walked and the
/// resumes go on. A walk that could not judge, and a move refused, here a
/// record that binds no session for the brief to name, are told once as
/// `idle-after-return` with the refusal under it, a changed refusal once
/// more; the lane is resumed still and nothing starts.
#[test]
fn a_provider_stop_past_the_patience_moves_the_lane_to_another_provider() {
    enum Then {
        /// Relaunched on this harness and account, the brief naming the
        /// prior transcript of the lane's harness, after a walk of this
        /// text.
        Moved(&'static str, &'static str, &'static str),
        /// Told once with this refusal.
        Refused(&'static str),
        /// No walk asked and nothing said: the resumes go on.
        Resumed,
    }
    struct Row {
        case: &'static str,
        harness: Harness,
        model: &'static str,
        preference: &'static str,
        screen: &'static str,
        stop: &'static str,
        session: bool,
        walk: Result<Option<Chosen>, String>,
        then: Then,
        /// A later walk of the same episode and the refusal it is told
        /// with, under a row a released watch marked `told`.
        after: Option<(Result<Option<Chosen>, String>, &'static str)>,
    }
    let claude_stop = r#"{"harness":"claude","event":"StopFailure","error":"server_error"}"#;
    let pi_stop = r#"{"harness":"pi","event":"Stop","stop_reason":"error","working_agents":0}"#;
    let codex = chosen(Harness::Codex, "gpt-6.2-sol", "high", "/home/me/.acodex");
    let rows = [
        Row {
            case: "another harness",
            harness: Harness::Claude,
            model: "opus",
            preference: "claude:opus:high,codex:gpt-6.2-sol:high",
            screen: "❯\u{a0}\n",
            stop: claude_stop,
            session: true,
            walk: Ok(Some(codex.clone())),
            then: Then::Moved("codex", "/home/me/.acodex", "codex:gpt-6.2-sol:high"),
            after: None,
        },
        Row {
            case: "another provider's only entry on another host",
            harness: Harness::Claude,
            model: "opus",
            preference: "claude:opus:high,codex@/opt/box:gpt-6.2-sol:high",
            screen: "❯\u{a0}\n",
            stop: claude_stop,
            session: true,
            walk: Ok(Some(codex.clone())),
            then: Then::Resumed,
            after: None,
        },
        Row {
            case: "another pi provider",
            harness: Harness::Pi,
            model: "anthropic/claude-x",
            preference: "pi:anthropic/claude-x:high,pi:openai/gpt-5:high",
            screen: "pi drew this\n",
            stop: pi_stop,
            session: true,
            walk: Ok(Some(chosen(
                Harness::Pi,
                "openai/gpt-5",
                "high",
                "/home/me/.api",
            ))),
            then: Then::Moved("pi", "/home/me/.api", "pi:openai/gpt-5:high"),
            after: None,
        },
        Row {
            case: "a record binding no session",
            harness: Harness::Claude,
            model: "opus",
            preference: "claude:opus:high,codex:gpt-6.2-sol:high",
            screen: "❯\u{a0}\n",
            stop: claude_stop,
            session: false,
            walk: Err("walk-unread codex:gpt-6.2-sol:high".to_owned()),
            then: Then::Refused("walk-unjudged walk-unread codex:gpt-6.2-sol:high"),
            after: Some((
                Ok(Some(codex.clone())),
                "context-unavailable cause=session-unrecorded",
            )),
        },
        Row {
            case: "a walk that could not judge",
            harness: Harness::Claude,
            model: "opus",
            preference: "claude:opus:high,codex:gpt-6.2-sol:high",
            screen: "❯\u{a0}\n",
            stop: claude_stop,
            session: true,
            walk: Err("preference-invalid entry=x".to_owned()),
            then: Then::Refused("walk-unjudged preference-invalid entry=x"),
            after: None,
        },
    ];
    for row in rows {
        let case = row.case;
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, &dir, "gh-1", row.harness.name(), row.screen);
        await_drawn(&server, &pane, row.screen.trim_end());
        let account = dir.join("account");
        let session = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let transcript = match row.harness {
            Harness::Pi => account
                .join("sessions")
                .join(agent_runtime::session::pi_slug(&dir))
                .join(format!("2026-11-26T00-00-00-000Z_{session}.jsonl")),
            _ => agent_runtime::effects::fixed_file(row.harness, &account, &dir, session).unwrap(),
        };
        std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        std::fs::write(&transcript, "{}\n").unwrap();
        let mut record = relaunchable(lane_record(
            "KEN-1",
            "gh-1",
            row.harness.name(),
            &server,
            &pane,
            Some(&identity),
            &dir,
        ));
        record["model"] = json!(row.model);
        record["account"] = json!(account);
        record["effort"] = json!("high");
        if row.session {
            record["session_id"] = json!(session);
        }
        fleet.set_lanes(vec![record]);
        let rows_file = dir.join("tmp/lane-mail/KEN-1/session-rows.jsonl");
        std::fs::create_dir_all(rows_file.parent().unwrap()).unwrap();
        std::fs::write(&rows_file, format!("{}\n", row.stop)).unwrap();
        let state = fleet.read();
        lane_driver!(
            server,
            fleet,
            readers,
            driver,
            &[("ORCH_WALL_RELAUNCH", "auto")]
        );
        driver.preference = Some(row.preference.to_owned());
        driver.provider_move = row.walk.clone();
        let patience = agent_runtime::stop::PROVIDER_PATIENCE.as_secs();
        // The move is due within the patience's passes at 240 seconds
        // each, past the two passes that judge the first stop.
        let bound = patience / 240 + 3;
        let mut first_stop = None;
        let mut said = None;
        for _ in 0..bound {
            let at = driver.now;
            let produced = driver.pass(&state);
            if first_stop.is_none() && driver.baseline.get("resume", "gh-1").is_some() {
                first_stop = Some(at);
            }
            if !lines(&produced).is_empty() || !driver.relaunches.borrow().is_empty() {
                said = Some((at, lines(&produced)));
                break;
            }
        }
        let since = first_stop.expect("the stop was resumed inside the patience");
        if let Then::Resumed = row.then {
            assert_eq!(said, None, "{case}");
            assert!(driver.provider_walks.borrow().is_empty(), "{case}");
            assert!(
                driver
                    .baseline
                    .get("resume", "gh-1")
                    .is_some_and(|r| r.starts_with("server_error|")),
                "{case}: resumed still: {:?}",
                driver.baseline.get("resume", "gh-1")
            );
            continue;
        }
        let (at, told) = said.unwrap_or_else(|| {
            panic!(
                "{case}: nothing past the patience; resume={:?} provider-stop={:?}",
                driver.baseline.get("resume", "gh-1"),
                driver.baseline.get("provider-stop", "gh-1")
            )
        });
        assert!(
            at - since >= patience,
            "{case}: said {} seconds past the stop, inside the patience: {told:?}",
            at - since
        );
        let walks = driver.provider_walks.borrow().clone();
        match row.then {
            Then::Moved(harness, to, walk) => {
                assert_eq!(
                    told,
                    vec![
                        format!(
                            "EVENT lane-relaunched KEN-1 lane={to} from={}",
                            account.display()
                        ),
                        format!(
                            "log={}",
                            driver.state_dir.join("wall-relaunch-KEN-1.log").display()
                        ),
                        format!(
                            "provider-move cause={} since={}",
                            if row.harness == Harness::Pi {
                                "error"
                            } else {
                                "server_error"
                            },
                            clock::iso_utc(since)
                        ),
                    ],
                    "{case}"
                );
                assert_eq!(
                    walks[0].preference.as_deref(),
                    Some(walk),
                    "{case}: the walk leaves the lane's own provider out"
                );
                assert!(walks[0].caller.is_none(), "{case}");
                let request: Value = serde_json::from_slice(
                    &std::fs::read(driver.state_dir.join("wall-relaunch-KEN-1.json")).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    (
                        &request["harness"],
                        &request["account"],
                        request.get("host")
                    ),
                    (&json!(harness), &json!(to), None),
                    "{case}: {request}"
                );
                let brief =
                    std::fs::read_to_string(driver.state_dir.join("wall-relaunch-KEN-1.md"))
                        .unwrap();
                assert!(
                    brief.contains(&format!(
                        "Continue KEN-1 from the prior {} transcript at {}; read it first, then resume the orch workflow.",
                        row.harness.name(),
                        transcript.display()
                    )),
                    "{case}: {brief}"
                );
                assert_eq!(driver.baseline.get("provider-stop", "gh-1"), None, "{case}");
            }
            Then::Refused(reason) => {
                let refused = |reason: &str| {
                    vec![
                        "EVENT idle-after-return gh-1 cause=server_error".to_owned(),
                        format!("provider-move-refused lane=gh-1 reason={reason}"),
                    ]
                };
                assert_eq!(told, refused(reason), "{case}");
                for _ in 0..2 {
                    let later = driver.pass(&state);
                    assert!(
                        lines(&later).is_empty(),
                        "{case}: told once: {:?}",
                        lines(&later)
                    );
                }
                if let Some((walk, reason)) = row.after {
                    let episode = driver.baseline.get("provider-stop", "gh-1").unwrap();
                    let legacy = episode.rsplit_once('|').unwrap().0;
                    driver.baseline.apply(Change::Set {
                        kind: "provider-stop".into(),
                        identity: "gh-1".into(),
                        value: format!("{legacy}|told"),
                    });
                    driver.provider_move = walk;
                    assert_eq!(lines(&driver.pass(&state)), refused(reason), "{case}");
                    for _ in 0..2 {
                        let later = driver.pass(&state);
                        assert!(
                            lines(&later).is_empty(),
                            "{case}: the changed refusal told once: {:?}",
                            lines(&later)
                        );
                    }
                }
                assert!(driver.relaunches.borrow().is_empty(), "{case}");
                assert!(
                    driver
                        .baseline
                        .get("resume", "gh-1")
                        .is_some_and(|r| r.starts_with("server_error|")),
                    "{case}: resumed still: {:?}",
                    driver.baseline.get("resume", "gh-1")
                );
            }
            Then::Resumed => unreachable!("{case}: a resumed row ends above"),
        }
    }
}

/// The identity of a harness that ran and is gone.
fn gone_harness() -> Identity {
    let mut harness = std::process::Command::new("sleep")
        .arg("600")
        .spawn()
        .unwrap();
    let Reading::Live(gone) = agent_runtime::process::identity(harness.id()) else {
        panic!("the harness stands while it runs")
    };
    harness.kill().unwrap();
    harness.wait().unwrap();
    gone
}

/// A local lane whose harness exited under its live window is started
/// again on the pass that reports it: the record's own relaunch, its close
/// on the `restart-recovery` ground first, then its launch on the record's
/// own account, which resumes the session the record binds, under
/// `lane-relaunched`; the next pass says nothing more. The assignment is
/// restarted once: its harness exiting again, on the relaunch's pane, is
/// said as `second-death` once and starts nothing, a parked pass between
/// the two exits included.
#[test]
fn an_exited_lane_is_relaunched_from_its_record() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let server = Server::start(&dir, "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("gh-2", &dir, "bash --norc --noprofile");
    let mut record = relaunchable(lane_record(
        "KEN-2",
        "gh-2",
        "claude",
        &server,
        &pane,
        Some(&gone_harness()),
        &dir,
    ));
    record.as_object_mut().unwrap().remove("account");
    record["session_id"] = json!("0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c");
    record["launched_at"] = json!(NOW_ISO);
    fleet.set_lanes(vec![record.clone()]);
    let state = fleet.read();
    lane_driver!(
        server,
        fleet,
        readers,
        driver,
        &[("ORCH_WALL_RELAUNCH", "auto")]
    );
    let first = driver.pass(&state);
    assert!(event_lines(&first).is_empty(), "{:?}", lines(&first));
    let exited = driver.pass(&state);
    assert_eq!(
        event_lines(&exited),
        vec![
            "EVENT lane-exited gh-2",
            "EVENT lane-relaunched KEN-2 lane=- from=-"
        ],
        "{:?}",
        lines(&exited)
    );
    assert_eq!(driver.relaunches.borrow().len(), 1);
    let relaunch = driver.relaunches.borrow()[0].clone();
    let close = driver.state_dir.join("restart-relaunch-KEN-2.close.json");
    let launch = driver.state_dir.join("restart-relaunch-KEN-2.json");
    assert_eq!(
        relaunch.args[relaunch.args.len() - 2..],
        [close.display().to_string(), launch.display().to_string()]
    );
    let close: Value = serde_json::from_slice(&std::fs::read(close).unwrap()).unwrap();
    assert_eq!(close["no_landing"]["reason"], "restart-recovery", "{close}");
    let launch: Value = serde_json::from_slice(&std::fs::read(launch).unwrap()).unwrap();
    assert_eq!(
        (&launch["op"], &launch["harness"], launch.get("account")),
        (&json!("launch-lane"), &json!("claude"), None),
        "{launch}"
    );
    assert!(event_lines(&driver.pass(&state)).is_empty());
    assert_eq!(driver.relaunches.borrow().len(), 1, "relaunched once");
    // The relaunched lane parks for a review and is relaunched once the
    // wait clears, its `launched_at` kept: the assignment's restart stays
    // spent across the parked pass.
    record["status"] = json!("parked");
    fleet.set_lanes(vec![record.clone()]);
    let parked = driver.pass(&fleet.read());
    assert!(event_lines(&parked).is_empty(), "{:?}", lines(&parked));
    record["status"] = json!("running");
    // The relaunch's close retired the old window; its own harness, on
    // its own pane, exits too.
    let retired = tmux(&server.socket, &["kill-pane", "-t", &pane]);
    assert!(retired.status.success(), "{}", stderr(&retired));
    let relaunched = server.open_window("gh-2", &dir, "bash --norc --noprofile");
    record["launch"] = json!({"pane": relaunched, "server": server.pid});
    let identity = gone_harness();
    record["launch"]["pid"] = json!(identity.pid);
    record["launch"]["start"] = json!(identity.start);
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    let first = driver.pass(&state);
    assert!(lines(&first).is_empty(), "{:?}", lines(&first));
    let again = driver.pass(&state);
    assert_eq!(
        event_lines(&again),
        vec!["EVENT lane-exited gh-2"],
        "{:?}",
        lines(&again)
    );
    assert_eq!(
        lines(&again).last().map(String::as_str),
        Some("relaunch-refused lane=gh-2 reason=second-death")
    );
    assert!(lines(&driver.pass(&state)).is_empty(), "said once");
    assert_eq!(driver.relaunches.borrow().len(), 1, "no second restart");
}

/// An exited lane under a standing halt is held, said once, and each later
/// pass asks the restart again until the halt lifts: whether the exit
/// closed its window, since a launched harness execs in its window's shell
/// (`exec /bin/sh` of the launch file, which execs the harness), or left
/// the window holding its shell, read exited on two passes. The restart
/// then starts once, from the record, and the next pass says nothing.
#[test]
fn an_exited_lane_held_by_a_halt_is_restarted_once_the_halt_lifts() {
    struct Row {
        case: &'static str,
        /// The window closes with its harness.
        closes: bool,
        /// The exit's line on every pass that reads it.
        exit: &'static [&'static str],
        /// The exit's line on the pass that reports it, after the first.
        reported: &'static str,
    }
    let rows = [
        Row {
            case: "the window closed",
            closes: true,
            exit: &["EVENT window-gone gh-3"],
            reported: "EVENT window-gone gh-3",
        },
        Row {
            case: "the window stands",
            closes: false,
            exit: &[],
            reported: "EVENT lane-exited gh-3",
        },
    ];
    for row in rows {
        let case = row.case;
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = if row.closes {
            let harness = named_sleep(&dir, "claude");
            let launch = dir.join("gh-3.launch");
            std::fs::write(&launch, format!("exec {} 600\n", harness.display())).unwrap();
            let pane =
                server.open_window("gh-3", &dir, &format!("exec /bin/sh {}", launch.display()));
            let identity = await_named(&server, &pane, "claude");
            (pane, identity)
        } else {
            let pane = server.open_window("gh-3", &dir, "bash --norc --noprofile");
            (pane, gone_harness())
        };
        let mut record = relaunchable(lane_record(
            "KEN-3",
            "gh-3",
            "claude",
            &server,
            &pane,
            Some(&identity),
            &dir,
        ));
        record.as_object_mut().unwrap().remove("account");
        record["session_id"] = json!("0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c");
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        if row.closes {
            let out = std::process::Command::new("kill")
                .args(["-KILL", &identity.pid.to_string()])
                .output()
                .unwrap();
            assert!(out.status.success(), "{}", stderr(&out));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while server.panes().contains(&pane) {
                assert!(std::time::Instant::now() < deadline, "the window stood");
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
        }
        lane_driver!(
            server,
            fleet,
            readers,
            driver,
            &[("ORCH_WALL_RELAUNCH", "auto")]
        );
        driver.halted = |_| Ok(true);
        if !row.closes {
            let first = driver.pass(&state);
            assert!(lines(&first).is_empty(), "{case}: {:?}", lines(&first));
        }
        let held = driver.pass(&state);
        assert_eq!(event_lines(&held), vec![row.reported], "{case}");
        assert_eq!(
            lines(&held).last().map(String::as_str),
            Some("relaunch-refused lane=gh-3 reason=halted"),
            "{case}"
        );
        assert_eq!(lines(&driver.pass(&state)), row.exit, "{case}: said once");
        assert!(driver.relaunches.borrow().is_empty(), "{case}");
        driver.halted = |_| Ok(false);
        let restarted = driver.pass(&state);
        let mut expected: Vec<&str> = row.exit.to_vec();
        expected.push("EVENT lane-relaunched KEN-3 lane=- from=-");
        assert_eq!(
            event_lines(&restarted),
            expected,
            "{case}: {:?}",
            lines(&restarted)
        );
        assert_eq!(driver.relaunches.borrow().len(), 1, "{case}");
        let launch: Value = serde_json::from_slice(
            &std::fs::read(driver.state_dir.join("restart-relaunch-KEN-3.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(
            (&launch["op"], &launch["harness"]),
            (&json!("launch-lane"), &json!("claude")),
            "{case}: {launch}"
        );
        // The window the restart opens is no `window-gone` while it opens.
        assert!(lines(&driver.pass(&state)).is_empty(), "{case}");
        assert_eq!(
            driver.relaunches.borrow().len(),
            1,
            "{case}: restarted once"
        );
    }
}

/// The 9claude stop of 6:40 pm PT on 2026-11-25, replayed with the figures
/// of the KEN-5803 review (§ 6.2): six workers walled at 9claude's 5-hour
/// limit, its reset at 7:40 pm; 2claude at 45 points of weekly headroom
/// with its reset 140 hours away, 10claude at 27 with its reset 64 hours
/// away, every other Claude account walled. The lane walk, over this
/// machine's listing of those accounts with each lane's own charge left
/// out, relaunches each worker on 2claude or 10claude in the pass that
/// reads its wall, with nobody starting it.
#[test]
fn the_9claude_stop_relaunches_each_walled_worker_on_an_account_with_room() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let server = Server::start(&dir, "fleet");
    let fleet = Fleet::new(&server);
    let now = clock::epoch_secs("2026-11-26T02:40:00Z").unwrap();
    let iso = |at: u64| clock::iso_utc(at);
    let account = |alias: &str, weekly_pct: u64, weekly_reset: u64, session_pct: u64| {
        json!({
            "alias": alias, "harness": "claude", "config_dir": format!("/home/me/.{alias}"),
            "measured_through": "local", "status": "ok",
            "weekly_pct": weekly_pct, "session_5h_pct": session_pct,
            "binding_resets_at": iso(weekly_reset),
            "resets": {"session": iso(now + 3600), "weekly": iso(weekly_reset), "model": null, "monthly": null},
            "model_buckets": [], "pool": "plan",
        })
    };
    let rows = [
        account("9claude", 60, now + 120 * 3600, 100),
        account("2claude", 55, now + 140 * 3600, 40),
        account("10claude", 73, now + 64 * 3600, 40),
        account("3claude", 97, now + 30 * 3600, 20),
        account("4claude", 100, now + 50 * 3600, 10),
    ];
    let accounts = dir.join("tmp/oversee-watch");
    let planted = plant_accounts(&dir, &accounts, None, &rows, now);
    let home = |alias: &str| {
        dir.join("home")
            .join(format!(".{alias}"))
            .display()
            .to_string()
    };
    let banner = "  ⎿ \u{a0}You've hit your session limit · resets 7:40pm (America/Los_Angeles)";
    let mut lanes = Vec::new();
    let mut identities = Vec::new();
    for n in 1..=6 {
        let (item, window) = (format!("KEN-{n}"), format!("gh-{n}"));
        let (pane, identity) = walled_claude(&server, &dir, &window, banner);
        let mut record = relaunchable(lane_record(
            &item,
            &window,
            "claude",
            &server,
            &pane,
            Some(&identity),
            &dir,
        ));
        record["effort"] = json!("high");
        record["account"] = json!(home("9claude"));
        lanes.push(record);
        identities.push(identity);
    }
    fleet.set_lanes(lanes);
    let state = fleet.read();
    lane_driver!(
        server,
        fleet,
        readers,
        driver,
        &[("ORCH_WALL_RELAUNCH", "auto")]
    );
    let env: Vec<(&str, &str)> = planted
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .chain([("ORCH_WALL_RELAUNCH", "auto")])
        .collect();
    driver.settings = settings_with(&driver.state_dir.clone(), &env);
    driver.now = now;
    let started = |_: &Identity| Reading::Live(now - 3600);
    driver.readers.start_epoch = &started;
    let settings = driver.settings.clone();
    let fleet_path = driver.fleet_path.clone();
    let walk = |item: &str, request: &WalkRequest| {
        ops::accounts::walk(
            &settings,
            &fleet_path,
            &ops::Host::kernel(),
            Some(item),
            request,
            now,
        )
        .map_err(|e| e.to_string())
    };
    let produced = driver.pass_with_walk(&state, &walk);
    let relaunched: Vec<(String, String)> = driver
        .relaunches
        .borrow()
        .iter()
        .map(|r| (r.item.clone(), r.to.clone()))
        .collect();
    assert_eq!(relaunched.len(), 6, "{:?}", lines(&produced));
    for (item, to) in &relaunched {
        assert!(
            [home("2claude"), home("10claude")].contains(to),
            "{item} relaunched on {to}"
        );
    }
    assert!(
        event_lines(&produced)
            .iter()
            .all(|l| l.starts_with("EVENT lane-relaunched ")),
        "{:?}",
        lines(&produced)
    );
}

/// An ended sign-in moves the lane to another account at once, never the
/// one it ended on: the walk leaves the spent account out, the relaunch
/// lands on the account it chose, and the overseer reads one
/// `usage-limit ... wall_kind=auth` line naming the spent account. A
/// replacement walled the same way before a turn of its own completed is
/// held for the overseer (`auth-recovery-unconfirmed`); after one, it moves
/// again.
#[test]
fn an_auth_wall_relaunches_on_another_account() {
    use lanes::WallSource;

    for (source, banner, named) in [
        (WallSource::Pane, "Not logged in · Please run /login", true),
        (WallSource::Rows, "Ready for work.", false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut fleet = Fleet::new(&server);
        let checkout = dir.path().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let checkout = checkout.canonicalize().unwrap();
        init_checkout(&fleet, &checkout);

        let account = dir.path().join("account");
        plant_credential(&account);
        let other = dir.path().join("other-account");
        plant_credential(&other);
        // The walk answers whichever account the lane does not spend.
        let (spent_word, other_word) = (account.display().to_string(), other.display().to_string());
        let elsewhere = |_: Harness, _: &str, spent: &str| {
            Pick::Lane(if spent == spent_word {
                other_word.clone()
            } else {
                spent_word.clone()
            })
        };
        let session = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
        let transcript =
            agent_runtime::effects::fixed_file(Harness::Claude, &account, &checkout, session)
                .unwrap();
        std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        std::fs::write(
            &transcript,
            format!("{{\"type\":\"permission-mode\",\"sessionId\":\"{session}\"}}\n"),
        )
        .unwrap();
        let name = "fleet:KEN-4";
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", banner);
        let mut record = relaunchable(lane_record(
            "KEN-4",
            name,
            "claude",
            &server,
            &pane,
            Some(&identity),
            &checkout,
        ));
        record["class"] = json!("light");
        record["effort"] = json!("high");
        if named {
            record["account"] = json!(account);
        } else {
            record.as_object_mut().unwrap().remove("account");
            record["home"] = json!(account);
        }
        record["session_id"] = json!(session);
        record["session_rows_at_launch"] = json!(0);
        fleet.set_lanes(vec![record]);

        let scripts = dir.path().join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
        lane_driver!(server, fleet, readers, driver);
        let started_before = driver.now - 1;
        let replacement_started = driver.now + 1;
        let predecessor = identity.pid;
        let read_started = |id: &Identity| {
            Reading::Live(if id.pid == predecessor {
                started_before
            } else {
                replacement_started
            })
        };
        driver.readers.start_epoch = &read_started;
        driver.scripts = scripts;
        let replay = |_: &Pane| Ok(wall_screen(banner));
        if source == WallSource::Pane {
            driver.readers.capture = &replay;
        }
        let mailbox = checkout.join("tmp/lane-mail/KEN-4");
        std::fs::create_dir_all(&mailbox).unwrap();
        let append = |event, at| {
            assert!(
                rows::write_lane(
                    &mailbox,
                    &rows::LaneRow {
                        event,
                        harness: "claude",
                        at,
                        transcript: None,
                        working_agents: None,
                    },
                    rows::WAIT,
                )
                .unwrap()
            );
        };
        let failure = rows::TurnEvent::StopFailure {
            error: Some("authentication_failed"),
        };
        let prompt = rows::TurnEvent::Prompt { digest: None };
        // A turn the predecessor completed supplies no proof for its replacement.
        append(rows::TurnEvent::Stop, driver.now);
        if source == WallSource::Rows {
            append(failure, driver.now);
        }
        let produced = driver.pass_with_pick(&fleet.read(), &elsewhere);
        assert_eq!(
            driver.relaunches.borrow().len(),
            1,
            "{source:?}: {:?}",
            lines(&produced)
        );
        let relaunch = driver.relaunches.borrow()[0].clone();
        let request: Value = serde_json::from_slice(
            &std::fs::read(driver.state_dir.join("wall-relaunch-KEN-4.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(request.get("account"), Some(&json!(other)), "{source:?}");
        assert_eq!(
            request.get("exclude_account"),
            Some(&json!(account)),
            "{source:?}"
        );
        assert_eq!(relaunch.to, other.display().to_string(), "{source:?}");
        let told: Vec<_> = produced
            .events
            .iter()
            .filter(|event| matches!(event, Event::UsageLimit { .. }))
            .collect();
        // A record naming no account spent its home's sign-in.
        let spent_line = format!("{name} {} wall_kind=auth", account.display());
        assert_eq!(
            told,
            vec![&Event::UsageLimit {
                passed: false,
                line: spent_line,
            }],
            "{source:?}: one notice naming the spent account"
        );
        if source == WallSource::Rows {
            fleet.runner.verify = Some(1);
            fleet.runner.stub = fixtures().join("stub-late/claude");
        }
        let out = run_relaunch(&fleet, &relaunch);
        if source == WallSource::Rows {
            assert_eq!(
                out.status.code(),
                Some(agent_runtime::effects::UNCONFIRMED_EXIT),
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                stderr(&out),
            );
            let preparing = fleet.runner.fleet();
            let lane = &preparing["lanes"][0];
            assert_eq!(lane["status"], "preparing");
            assert_eq!(lane.get("session_rows_at_launch"), None);
            let pane = lane["launch"]["pane"].as_str().unwrap();
            await_drawn(&server, pane, "starting up, no composer yet");
            let pass = driver.pass_with_pick(&fleet.read(), &elsewhere);
            assert_eq!(driver.relaunches.borrow().len(), 1, "{:?}", lines(&pass));
            assert!(
                !pass
                    .events
                    .iter()
                    .any(|event| matches!(event, Event::UsageLimit { .. })),
                "{:?}",
                lines(&pass)
            );
            assert!(relaunch.marker.exists());
            std::fs::write(checkout.join(".stub-composer"), "").unwrap();
            await_drawn(&server, pane, "? for shortcuts");
            let settled = fleet.runner.reconcile_one();
            assert_eq!(settled["intent"]["outcome"], "confirmed", "{settled}");
        } else {
            assert!(
                out.status.success(),
                "{source:?}: {}\n{}",
                String::from_utf8_lossy(&out.stdout),
                stderr(&out),
            );
        }
        let launched = fleet.runner.fleet();
        let lane = &launched["lanes"][0];
        assert_eq!(lane["account"], json!(other), "{source:?}");
        assert_eq!(lane["home"], json!(other), "{source:?}");
        assert_ne!(lane["session_id"], session, "{source:?}");
        assert_eq!(lane.get("class_missed"), None, "{source:?}");
        assert!(
            launched["fleet_log"]
                .as_array()
                .unwrap()
                .iter()
                .any(|row| row["kind"] == "close"
                    && row["source"] == "wall-route"
                    && row["reason"] == "auth-wall"),
            "{source:?}"
        );
        let launch = launched["intents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|intent| intent["op"] == "launch-session")
            .unwrap();
        if source == WallSource::Pane {
            assert_eq!(launch["observation"]["route"], "fresh", "{source:?}");
        }

        let replacement = lane["launch"]["pane"].as_str().unwrap();
        await_drawn(&server, replacement, "? for shortcuts");
        let auth_line = format!("{name} {} wall_kind=auth", other.display());
        let assert_held = |driver: &LaneDriver<'_>, held: &Produced| {
            let events: Vec<_> = held
                .events
                .iter()
                .filter(|event| matches!(event, Event::UsageLimit { .. }))
                .collect();
            assert_eq!(
                events,
                vec![&Event::UsageLimit {
                    passed: false,
                    line: auth_line.clone(),
                }],
                "{source:?}: {:?}",
                lines(held)
            );
            assert!(
                lines(held).contains(&format!(
                    "wall-relaunch-refused lane={name} reason=auth-recovery-unconfirmed"
                )),
                "{source:?}: {:?}",
                lines(held)
            );
            assert_eq!(driver.relaunches.borrow().len(), 1, "{source:?}");
            assert!(
                server
                    .session_panes()
                    .iter()
                    .any(|pane| pane == replacement)
            );
        };

        let no_rows = |_: &Path| Reading::Gone;
        if source == WallSource::Pane {
            // The replacement's first pass has both the intact old banner
            // and a failure from its own startup turn.
            append(failure, driver.now);
            let held = driver.pass_with_pick(&fleet.read(), &elsewhere);
            assert_held(&driver, &held);
            assert!(
                !driver
                    .pass_with_pick(&fleet.read(), &elsewhere)
                    .events
                    .iter()
                    .any(|event| matches!(event, Event::UsageLimit { .. }))
            );
            // The same pane without the current row is still old screen.
            driver.readers.rows = &no_rows;
            let replay_only = driver.pass_with_pick(&fleet.read(), &elsewhere);
            assert!(
                fleet.runner.fleet()["lanes"][0].get("walled").is_none(),
                "{:?}",
                lines(&replay_only)
            );
            driver.readers.rows = &lane_rows;
            driver.readers.capture = &capture;
        } else {
            driver.pass_with_pick(&fleet.read(), &elsewhere);
            assert_eq!(driver.relaunches.borrow().len(), 1, "{source:?}");
            assert_eq!(driver.baseline.get("usage-limit", name), None, "{source:?}");
        }

        for starting_turn in [false, true] {
            if source == WallSource::Pane && !starting_turn {
                continue;
            }
            if starting_turn {
                append(prompt, driver.now);
                driver.pass_with_pick(&fleet.read(), &elsewhere);
                assert_eq!(driver.baseline.get("usage-limit", name), None, "{source:?}");
            }
            append(failure, driver.now);
            let held = driver.pass_with_pick(&fleet.read(), &elsewhere);
            assert_held(&driver, &held);
        }

        // The watch never sees an Idle verdict for this completed turn.
        append(prompt, driver.now);
        append(rows::TurnEvent::Stop, driver.now);
        append(prompt, driver.now);
        driver.pass_with_pick(&fleet.read(), &elsewhere);
        append(failure, driver.now);
        let after_stop = driver.pass_with_pick(&fleet.read(), &elsewhere);
        assert_eq!(
            driver.relaunches.borrow().len(),
            2,
            "{source:?}: {:?}",
            lines(&after_stop)
        );
        effect_report(&fleet.runner.op_fleet(&json!({
            "op": "close-owned-resources",
            "item": "KEN-4",
            "terminal": {"verdict": "completed", "source": "test"},
        })));
    }
}

/// A wall relaunch onto an account whose `projects` leads to the walled
/// account's resumes the bound session, whose redrawn history holds the
/// banner that walled it above the brief's turn. That banner is the old
/// process's history on the new account, never its wall: no `usage-limit`,
/// no second relaunch, no wall recorded for the new account and no first
/// sighting left to mask a later wall, both as the route leaves the lane's
/// row and after the gone window's read once the relaunch settled.
/// The predecessor's failure row is still last at both reads. An
/// identical failure appended by the replacement is its own wall.
#[test]
fn a_resumed_relaunch_whose_screen_redraws_its_wall_is_no_wall_on_the_new_account() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut fleet = Fleet::new(&server);
    fleet.runner.stub = fixtures().join("stub-resume-banner/claude");
    let checkout = dir.path().join("checkout");
    init_checkout(&fleet, &checkout);
    let checkout = checkout.canonicalize().unwrap();
    let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
    // The seats stand outside `/tmp`, as an operator's do, since the
    // confinement mounts a private `/tmp` where a link under it would not
    // stand; the new seat's `projects` leads to the old seat's.
    let seats = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let old_account = seats.path().join("old-account");
    let new_account = seats.path().join("new-account");
    plant_credential(&new_account);
    let session = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
    let file =
        agent_runtime::effects::fixed_file(Harness::Claude, &old_account, &checkout, session)
            .unwrap();
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(
        &file,
        format!("{{\"type\":\"permission-mode\",\"sessionId\":\"{session}\"}}\n"),
    )
    .unwrap();
    std::os::unix::fs::symlink(old_account.join("projects"), new_account.join("projects")).unwrap();
    // The window name the launch records, so the replacement keeps the
    // lane's rows.
    let name = "fleet:KEN-4";
    let mut record = relaunchable(lane_record(
        "KEN-4",
        name,
        "claude",
        &server,
        &pane,
        Some(&identity),
        &checkout,
    ));
    record["effort"] = json!("high");
    record["account"] = json!(old_account.display().to_string());
    record["session_id"] = json!(session);
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    let scripts = dir.path().join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(binary(), scripts.join("orch-runtime")).unwrap();
    // The walled process started before the first pass's clock, every
    // later one after it.
    const FIRST_PASS: u64 = 1_800_000_000;
    let walled = identity.pid;
    let started = move |id: &Identity| match observe::start_epoch(id) {
        Reading::Live(_) if id.pid == walled => Reading::Live(FIRST_PASS - 10),
        Reading::Live(_) => Reading::Live(FIRST_PASS + 10),
        other => other,
    };
    lane_driver!(server, fleet, readers, driver);
    driver.readers.start_epoch = &started;
    driver.scripts = scripts;
    driver.pick = Pick::Lane(new_account.display().to_string());
    assert_eq!(driver.now, FIRST_PASS);
    let produced = driver.pass(&state);
    assert_eq!(
        driver.relaunches.borrow().len(),
        1,
        "{:?}",
        lines(&produced)
    );
    let relaunch = driver.relaunches.borrow()[0].clone();
    let mailbox = checkout.join("tmp/lane-mail/KEN-4");
    std::fs::create_dir_all(&mailbox).unwrap();
    let append_limit = || {
        assert!(
            rows::write_lane(
                &mailbox,
                &rows::LaneRow {
                    event: rows::TurnEvent::StopFailure {
                        error: Some("rate_limit")
                    },
                    harness: "claude",
                    at: FIRST_PASS,
                    transcript: None,
                    working_agents: None,
                },
                rows::WAIT,
            )
            .unwrap()
        );
    };
    // The predecessor appends after the watch has composed the relaunch.
    append_limit();
    let out = run_relaunch(&fleet, &relaunch);
    assert!(
        out.status.success(),
        "the relaunch's requests were refused: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    let launched = fleet.runner.fleet();
    let observation = launched["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["op"] == "launch-session")
        .map(|i| i["observation"].clone())
        .expect("the relaunch's launch is recorded");
    assert_eq!(observation["route"], "resume", "{observation}");
    let lane = &launched["lanes"][0];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["account"], new_account.display().to_string(), "{lane}");
    assert_eq!(lane["session_id"], session, "{lane}");
    assert_eq!(lane["window"], name, "{lane}");
    let replacement = lane["launch"]["pane"].as_str().unwrap().to_owned();
    await_drawn(&server, &replacement, "weekly limit");
    let next_account = seats.path().join("next-account");
    driver.pick = Pick::Lane(next_account.display().to_string());
    let wall = account_wall::account_wall_path(
        &driver.settings.account_state.get().unwrap(),
        &new_account.display().to_string(),
    );
    let quiet = |driver: &mut LaneDriver<'_>, sub_row: &str| {
        for _ in 0..2 {
            let produced = driver.pass(&fleet.read());
            assert!(
                !event_lines(&produced)
                    .iter()
                    .any(|l| l.starts_with("EVENT usage-limit")
                        || l.starts_with("EVENT lane-relaunched")),
                "predecessor failure must leave the resumed lane clear ({sub_row}): {:?}",
                lines(&produced)
            );
        }
        assert_eq!(driver.relaunches.borrow().len(), 1, "{sub_row}");
        assert!(
            driver.baseline.get("lane-idle", name).is_some(),
            "{sub_row}: the resumed composer is idle"
        );
        assert!(
            !wall.exists(),
            "{sub_row}: a wall recorded on the new account"
        );
        assert_eq!(driver.baseline.get("usage-limit", name), None, "{sub_row}");
    };
    quiet(&mut driver, "as the route left the row");
    // The relaunch settles as its outcome reader leaves it, then the gone
    // window of the snapshot read before it is judged.
    std::fs::write(overseer::relaunch_exit_path(&relaunch.marker), "0\n").unwrap();
    let settled = overseer::relaunch_outcomes(
        lanes::watch_state_dir(&driver.settings.claim_store),
        &fleet.read(),
        driver.settings.watch.get().unwrap().prepare,
        driver.now,
        &driver.baseline,
    );
    apply(&mut driver.baseline, &settled);
    assert!(!relaunch.marker.exists(), "the settled marker leaves");
    driver.pass(&state);
    quiet(&mut driver, "after the gone window's read");
    append_limit();
    driver.pass(&fleet.read());
    driver.pass(&fleet.read());
    let requests = driver.relaunches.borrow();
    assert_eq!(
        requests.len(),
        2,
        "one relaunch for the new account's failure"
    );
    assert_eq!(requests[1].spent, new_account.display().to_string());
    assert_eq!(requests[1].to, next_account.display().to_string());
    effect_report(&fleet.runner.op_fleet(&json!({
        "op": "close-owned-resources",
        "item": "KEN-4",
        "terminal": {"verdict": "completed", "source": "test"},
    })));
}

/// The detached line as its starter runs it: the entry's word first, in the
/// lane's checkout with the watch's session and the runner's environment.
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
        init_checkout(&fleet, &checkout);
        let checkout = checkout.canonicalize().unwrap();
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let old_account = dir.path().join("old-account");
        let new_account = dir.path().join("new-account");
        std::fs::create_dir_all(&old_account).unwrap();
        std::fs::create_dir_all(&new_account).unwrap();
        let account = new_account.display().to_string();
        let mut record = relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            &checkout,
        ));
        // The record names its effort: the launch refuses a lane on an
        // account without one.
        record["effort"] = json!("high");
        record["account"] = json!(old_account.display().to_string());
        let world = HostedWorld::new(dir.path(), &server, &fleet);
        // The relaunch runs this build's binary through its entry under
        // the row's own environment, in the close wrapper's place.
        std::fs::remove_file(world.scripts.join("orch-runtime")).unwrap();
        std::os::unix::fs::symlink(binary(), world.scripts.join("orch-runtime")).unwrap();
        if hosted {
            // The launch finds its provider under the checkout's package.
            let package = checkout.join(".agents/skills/orch");
            std::fs::create_dir_all(&package).unwrap();
            std::os::unix::fs::symlink(&world.scripts, package.join("scripts")).unwrap();
            let remote = dir.path().join("remote-worktree").display().to_string();
            record.as_object_mut().unwrap().remove("refresh");
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
        // A hosted lane's walk judges its own harness and model on the
        // fleet's host, which is the lane's.
        let host = provider(dir.path());
        let env: &[(&str, &str)] = if hosted {
            &[("ORCH_LANE_HOST", host.as_str())]
        } else {
            &[]
        };
        lane_driver!(server, fleet, readers, driver, env);
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
        init_checkout(&fleet, &checkout);
        let checkout = checkout.canonicalize().unwrap();
        let (pane, identity) = walled_claude(&server, dir.path(), "gh-4", BANNER);
        let old_account = dir.path().join("old-account");
        let new_account = dir.path().join("new-account");
        std::fs::create_dir_all(&old_account).unwrap();
        plant_credential(&new_account);
        let mut record = relaunchable(lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            &checkout,
        ));
        // The record names its effort: the launch refuses a lane on an
        // account without one.
        record["effort"] = json!("high");
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

/// The walk answering `none` leaves the row pending with no request made,
/// walked again on the next pass with no new line (what the owner is told
/// is `a_walled_controller_with_no_successor_stays_pending_and_tells_the_owner_once`'s);
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
    let accept = |_: &str, _: &str| Ok(());
    overseer_driver!(
        server, fleet, reached, walk_none, readers, transfers, driver
    );
    driver.alert = &accept;
    let key = format!("{} {pane}", server.pid);
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
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
    assert_eq!(asked.borrow().len(), 2, "a pending wall is walked again");
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

/// A walled overseer's succession decides nothing on evidence it could not
/// read: a walk that chose none past a provider it could not read, its
/// line naming each such provider and why, one that chose none past an
/// entry its judge could not answer, the line naming the entry and the
/// answer, and a walk refused, its refusal as the line. Each is the
/// pass's failure with its cause, the row stays announced and nobody is
/// told; the next pass judges again and carries out what it then finds.
#[test]
fn a_walled_succession_on_unread_evidence_decides_nothing_and_is_judged_again() {
    let busy = "host-busy count=4 cap=4 verb=accounts item=- step=accounts";
    let failed = "host-accounts-unreadable host=vm2 exit=1 down";
    let skip = |entry: &str, host: &str, cause: &str| json!({"entry": entry, "reason": "host-unread", "lane": null, "host": host, "cause": cause});
    let judged_none = |_: &WalkRequest| -> orch_runtime::error::Result<Walked> {
        Ok(Walked {
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
        })
    };
    let entry_unread = |_: &WalkRequest| -> orch_runtime::error::Result<Walked> {
        Ok(Walked {
            answer: WalkAnswer::None,
            walk: "codex:gpt:high,claude:opus:high".to_owned(),
            entries: 2,
            skipped: vec![
                json!({"entry": "codex:gpt:high", "reason": "no-record", "lane": null}),
                json!({"entry": "claude:opus:high", "reason": "walled", "lane": null}),
            ],
            walled: 1,
            unmeasured: 0,
            unread: vec!["codex:gpt:high".to_owned()],
            deprecated: Vec::new(),
        })
    };
    let refused = |_: &WalkRequest| -> orch_runtime::error::Result<Walked> {
        Err(agent_runtime::Error::refused(
            "account-unjudged",
            &[("step", "host"), ("host", "vm2"), ("cause", failed)],
        )
        .into())
    };
    type Answer<'a> = &'a dyn Fn(&WalkRequest) -> orch_runtime::error::Result<Walked>;
    // case, the two walks' answers, the line of the unread pass
    let cases: [(&str, [Answer; 2], String); 3] = [
        (
            "an entry unread",
            [&entry_unread, &walk_b],
            "account-unjudged step=entry entry=codex:gpt:high reason=no-record".to_owned(),
        ),
        (
            "a provider unread",
            [&judged_none, &walk_b],
            format!("account-unjudged step=host host=vm cause={busy} host=vm2 cause={failed}"),
        ),
        (
            "walk refused",
            [&refused, &walk_b],
            format!("account-unjudged step=host host=vm2 cause={failed}"),
        ),
    ];
    for (case, answers, line) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, window) = walled_overseer(dir.path(), &server, &fleet);
        let state = fleet.read();
        let walked = Cell::new(0);
        let walk = |request: &WalkRequest| {
            let at = walked.get();
            walked.set(at + 1);
            answers.get(at).expect("one walk per judgement")(request)
        };
        let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
        let noting = |file: &str, _: &str| {
            told.borrow_mut().push(file.to_owned());
            Ok(())
        };
        overseer_driver!(server, fleet, reached, walk, readers, transfers, driver);
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        let first = driver.pass(&state);
        assert!(
            lines(&first)[0].starts_with(&format!("EVENT overseer-walled {pane} window={window}")),
            "{case}: {:?}",
            lines(&first)
        );
        let unread = driver.pass(&state);
        assert_eq!(lines(&unread), [line], "{case}");
        assert!(
            unread
                .failed
                .as_deref()
                .is_some_and(|f| f.starts_with("successor-unread cause=")),
            "{case}: {:?}",
            unread.failed
        );
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("announced"),
            "{case}"
        );
        assert!(transfers.borrow().is_empty(), "{case}");
        assert!(told.borrow().is_empty(), "{case}");
        driver.pass(&state);
        assert_eq!(transfers.borrow().len(), 1, "{case}");
        assert!(told.borrow().is_empty(), "{case}");
    }
}

/// A walk left unread decides no successor and is walked again on each
/// pass, the row announced and nobody told; once a whole patience passed
/// since the walled case was announced the case is pending and the owner
/// is told once, the unread line the notice's cause. Later passes keep
/// walking with no second notice, and a host read again with a successor
/// that has room moves the overseer. A case announced with no instant kept
/// starts its patience on the pass that reads it.
#[test]
fn an_unread_walk_is_walked_on_each_pass_past_its_notice_until_a_successor_reads_room() {
    let unread_line = "account-unjudged step=host host=vm2 cause=host-accounts-unreadable";
    let readable = Cell::new(false);
    let walk = |request: &WalkRequest| -> orch_runtime::error::Result<Walked> {
        if readable.get() {
            return walk_b(request);
        }
        Ok(Walked {
            answer: WalkAnswer::None,
            walk: "claude@vm2:opus:high,claude:opus:high".to_owned(),
            entries: 2,
            skipped: vec![
                json!({"entry": "claude@vm2:opus:high", "reason": "host-unread", "lane": null, "host": "vm2", "cause": "host-accounts-unreadable"}),
                json!({"entry": "claude:opus:high", "reason": "walled", "lane": null}),
            ],
            walled: 1,
            unmeasured: 0,
            unread: vec!["claude@vm2:opus:high".to_owned()],
            deprecated: Vec::new(),
        })
    };
    // case, whether the walled row is planted announced with no instant
    for (case, planted) in [("announced", false), ("announced, no instant kept", true)] {
        readable.set(false);
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
        let state = fleet.read();
        let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
        let noting = |file: &str, text: &str| {
            told.borrow_mut().push((file.to_owned(), text.to_owned()));
            Ok(())
        };
        overseer_driver!(server, fleet, reached, walk, readers, transfers, driver);
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        if planted {
            plant(
                &mut driver.baseline,
                "overseer-walled",
                &key,
                "announced".to_owned(),
            );
        }
        let announced = driver.now;
        driver.pass(&state);
        for at in [announced + 60, announced + 1799] {
            driver.now = at;
            let within = driver.pass(&state);
            assert!(
                within
                    .failed
                    .as_deref()
                    .is_some_and(|f| f.starts_with("successor-unread cause=")),
                "{case}: {:?}",
                within.failed
            );
            assert_eq!(
                driver.baseline.get("overseer-walled", &key),
                Some("announced"),
                "{case}"
            );
            assert!(told.borrow().is_empty(), "{case}");
        }
        driver.now = announced + 1800;
        for _ in 0..3 {
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("overseer-walled", &key),
                Some("pending"),
                "{case}"
            );
        }
        {
            let told = told.borrow();
            assert_eq!(told.len(), 1, "{case}");
            assert_eq!(told[0].0, "overseer-no-successor.txt", "{case}");
            assert!(told[0].1.contains(unread_line), "{case}: {}", told[0].1);
        }
        assert!(transfers.borrow().is_empty(), "{case}");
        readable.set(true);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("requested"),
            "{case}"
        );
        let asked = transfers.borrow();
        assert_eq!(asked.len(), 1, "{case}");
        assert_eq!(asked[0].cause, TransferCause::Walled, "{case}");
        assert_eq!(
            asked[0].successor.account.as_deref(),
            Some("/home/me/.bclaude"),
            "{case}"
        );
        assert_eq!(told.borrow().len(), 1, "{case}: no second notice");
    }
}

/// A walled overseer's first walk answers none and its case stays
/// pending, the owner told once; the next walk with room asks the move,
/// whose launch fails with its account left unproved; the walk after it
/// holds that account out and asks the move again, and once that move is
/// confirmed the successor's pane is the controller and reads live, the
/// walled pane's rows gone with it.
#[test]
fn a_pending_walled_controller_moves_once_a_walk_reads_room_past_a_failed_launch() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
    let room = Cell::new(false);
    let walk = |request: &WalkRequest| {
        if !room.get() {
            return walk_none(request);
        }
        let mut walked = walk_b(request)?;
        if request.exclude.iter().any(|a| a == "/home/me/.bclaude")
            && let WalkAnswer::Lane(chosen) = &mut walked.answer
        {
            chosen.account = Some("/home/me/.cclaude".to_owned());
        }
        Ok(walked)
    };
    let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
    let noting = |file: &str, _: &str| {
        told.borrow_mut().push(file.to_owned());
        Ok(())
    };
    overseer_driver!(server, fleet, reached, walk, readers, transfers, driver);
    driver.alert = &noting;
    let key = format!("{} {pane}", server.pid);
    let state = fleet.read();
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    assert!(transfers.borrow().is_empty());
    room.set(true);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let intent = |id: &str, outcome: &str, at: u64| {
        json!({
            "id": id, "op": "request-transfer", "target": "overseer",
            "created_at": clock::iso_utc(at), "outcome": outcome,
            "observation": {"note": "successor-not-ready"}
        })
    };
    let failed_at = driver.now - 200;
    let mut doc = fleet.runner.fleet();
    doc["controller"]["unproved"] = json!([
        {"account": "/home/me/.bclaude", "note": "successor-not-ready", "at": clock::iso_utc(failed_at + 10)}
    ]);
    doc["intents"] = json!([intent("request-transfer:overseer:1", "failed", failed_at)]);
    fleet.runner.write_fleet(&doc);
    let state = fleet.read();
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let accounts: Vec<Option<String>> = transfers
        .borrow()
        .iter()
        .map(|t| t.successor.account.clone())
        .collect();
    assert_eq!(
        accounts,
        [
            Some("/home/me/.bclaude".to_owned()),
            Some("/home/me/.cclaude".to_owned())
        ]
    );
    let mut doc = fleet.runner.fleet();
    doc["intents"] = json!([
        intent("request-transfer:overseer:1", "failed", failed_at),
        intent("request-transfer:overseer:2", "confirmed", driver.now - 100),
    ]);
    fleet.runner.write_fleet(&doc);
    let (_, _, successor, _) = live_overseer(dir.path(), &server, &fleet);
    driver.pass(&fleet.read());
    let judged = driver.slot.read().unwrap();
    assert_eq!(judged.verdict, Verdict::Live);
    assert_eq!(judged.pane_key.as_deref(), Some(successor.as_str()));
    assert_eq!(driver.baseline.get("overseer-walled", &key), None);
    assert_eq!(*told.borrow(), ["overseer-no-successor.txt"]);
}

/// An ended sign-in read on the pane of a usage wall left pending, with no
/// live reading between, is walked as a sign-in: the overseer moves at
/// once and the owner gets the sign-in's one notice beside the wall's.
#[test]
fn an_ended_sign_in_after_a_pending_usage_wall_moves_and_tells_the_owner_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
    let room = Cell::new(false);
    let walk = |request: &WalkRequest| {
        if room.get() {
            walk_b(request)
        } else {
            walk_none(request)
        }
    };
    let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
    let noting = |file: &str, _: &str| {
        told.borrow_mut().push(file.to_owned());
        Ok(())
    };
    overseer_driver!(server, fleet, reached, walk, readers, transfers, driver);
    driver.alert = &noting;
    let key = format!("{} {pane}", server.pid);
    let state = fleet.read();
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    let rows = dir.path().join("session-rows.jsonl");
    let mut text = std::fs::read_to_string(&rows).unwrap();
    text.push_str("{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"authentication_failed\",\"message\":\"Invalid API key\"}\n");
    std::fs::write(&rows, text).unwrap();
    room.set(true);
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    assert_eq!(transfers.borrow().len(), 1);
    assert_eq!(transfers.borrow()[0].cause, TransferCause::Walled);
    assert_eq!(
        *told.borrow(),
        ["overseer-no-successor.txt", "overseer-auth-wall.txt"]
    );
}

/// The own account of a pending usage wall, read with room past its reset
/// though its rate is still unmeasured, resumes the overseer standing at
/// its usage banner through the wake's resume row, once for the wall:
/// a newer failure row on the same wall starts no episode and no notice,
/// the resume names the wall by its episode, and the resume wins over a
/// walk with room in the same pass. A new wall with the same reset asks
/// its own resume.
#[test]
fn a_pending_usage_wall_is_resumed_once_per_wall_when_its_own_account_reads_room() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (pane, _) = walled_overseer_drawing(
        dir.path(),
        &server,
        &fleet,
        wall_screen(BANNER).trim_end_matches("❯\u{a0}\n"),
    );
    let start: u64 = 1_800_000_000;
    let reset = start + 3600;
    let own_room = Cell::new(false);
    let judge = |_: &Caller, _: Option<&str>| {
        if own_room.get() {
            // An account fresh past its reset that nothing spends: its
            // headroom read with room, its rate one sample or not rising.
            let mut m = marks(
                MarkKey::Unmeasured(MarkKind::Rate),
                "",
                "",
                Succession::On,
                "",
            );
            m.reason = "not-increasing".to_owned();
            return Ok(m);
        }
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        Ok(m)
    };
    let room = Cell::new(false);
    let walk = |request: &WalkRequest| {
        if room.get() {
            walk_b(request)
        } else {
            walk_none(request)
        }
    };
    let told: RefCell<Vec<String>> = RefCell::new(Vec::new());
    let noting = |file: &str, _: &str| {
        told.borrow_mut().push(file.to_owned());
        Ok(())
    };
    overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
    driver.alert = &noting;
    let key = format!("{} {pane}", server.pid);
    let rows = dir.path().join("session-rows.jsonl");
    let fail_again = || {
        let mut text = std::fs::read_to_string(&rows).unwrap();
        text.push_str("{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\",\"message\":\"You've hit your weekly limit\"}\n");
        std::fs::write(&rows, text).unwrap();
    };
    let state = fleet.read();
    let first_wall = driver.now;
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    fail_again();
    let again = driver.pass(&state);
    assert!(event_lines(&again).is_empty(), "{:?}", lines(&again));
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    assert_eq!(told.borrow().len(), 1, "one notice for the wall");
    driver.now = reset + 60;
    own_room.set(true);
    room.set(true);
    driver.pass(&state);
    let asked = format!("usage-limit|{key}|{reset}|wall:{first_wall}");
    assert_eq!(
        driver.baseline.get("resume", "overseer"),
        Some(asked.as_str())
    );
    assert!(transfers.borrow().is_empty(), "the own resume wins");
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("resume", "overseer"),
        Some(asked.as_str())
    );
    // The resumed turn ends at a new wall whose reading names the same
    // reset.
    own_room.set(false);
    room.set(false);
    fail_again();
    let second_wall = driver.now;
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    own_room.set(true);
    driver.pass(&state);
    let asked_again = format!("usage-limit|{key}|{reset}|wall:{second_wall}");
    assert_eq!(
        driver.baseline.get("resume", "overseer"),
        Some(asked_again.as_str())
    );
    assert!(transfers.borrow().is_empty());
}

/// A pending account wall read live on a reading that leaves its own
/// account unread stays walled: the judge's unmeasured headroom, a due
/// context reading, which answers before the account is read, or a memory
/// mark reached over an unreadable account. No resume is asked, the walk
/// runs on each pass and the kept reset stands; an account still unread a
/// whole patience past that reset tells the owner once with its cause. A
/// later reading with room resumes it.
#[test]
fn a_pending_wall_read_live_on_a_reading_with_no_room_stays_walled_and_asks_no_resume() {
    let reset: u64 = 1_800_000_000 + 3600;
    let walled = || {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        m
    };
    let unmeasured = || {
        let mut m = marks(
            MarkKey::Unmeasured(MarkKind::Headroom),
            "",
            "",
            Succession::On,
            "",
        );
        m.reason = "headroom-unreadable".to_owned();
        m
    };
    let context_due = || {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Context),
            "190000",
            "90",
            Succession::On,
            "",
        );
        m.headroom = "unreadable".to_owned();
        m
    };
    let memory = || {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Memory),
            "95",
            "90",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.own = Some(AccountState::Unreadable);
        m
    };
    type Reading<'a> = &'a dyn Fn() -> Marks;
    // case, the reading past the reset, the owner's unread notice cause
    let cases: [(&str, Reading, &str); 3] = [
        ("headroom unmeasured", &unmeasured, "headroom-unreadable"),
        ("context due", &context_due, "account-not-read"),
        (
            "memory mark, account unreadable",
            &memory,
            "headroom-unreadable",
        ),
    ];
    for (case, unproved, cause) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (_, _, key, _) = live_overseer(dir.path(), &server, &fleet);
        // 0: the account walled, 1: the reading under test, 2: room.
        let phase = Cell::new(0);
        let judge = |_: &Caller, _: Option<&str>| {
            Ok(match phase.get() {
                0 => walled(),
                1 => unproved(),
                _ => marks(MarkKey::Below, "", "", Succession::On, ""),
            })
        };
        let walks = Cell::new(0);
        let walk = |request: &WalkRequest| {
            walks.set(walks.get() + 1);
            walk_none(request)
        };
        let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
        let noting = |file: &str, text: &str| {
            told.borrow_mut().push((file.to_owned(), text.to_owned()));
            Ok(())
        };
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &noting;
        let state = fleet.read();
        let wall = driver.now;
        driver.pass(&state);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("pending"),
            "{case}"
        );
        phase.set(1);
        let kept = reset.to_string();
        for at in [reset + 60, reset + 1800, reset + 2040] {
            driver.now = at;
            driver.pass(&state);
            assert!(
                matches!(driver.slot.read().unwrap().verdict, Verdict::Walled { .. }),
                "{case}"
            );
            assert_eq!(driver.baseline.get("resume", "overseer"), None, "{case}");
            assert_eq!(
                driver.baseline.get("overseer-walled", &key),
                Some("pending"),
                "{case}"
            );
            assert_eq!(
                driver.baseline.get("overseer-wall-reset", &key),
                Some(kept.as_str()),
                "{case}"
            );
        }
        assert_eq!(walks.get(), 4, "{case}: each pass past the announce walks");
        {
            let told = told.borrow();
            let keys: Vec<&str> = told
                .iter()
                .map(|(_, text)| text.split(':').next().unwrap_or_default())
                .collect();
            assert_eq!(
                keys,
                ["overseer-walled-pending", "overseer-account-unread"],
                "{case}"
            );
            assert!(told[1].1.contains(cause), "{case}: {}", told[1].1);
        }
        phase.set(2);
        driver.pass(&state);
        let asked = format!("usage-limit|{key}|{reset}|wall:{wall}");
        assert_eq!(
            driver.baseline.get("resume", "overseer"),
            Some(asked.as_str()),
            "{case}"
        );
        assert!(transfers.borrow().is_empty(), "{case}");
    }
}

/// A pending wall whose pane then runs a turn, as one the owner resumed by
/// hand, is held for every pass the turn runs: never announced again,
/// resumed or moved whatever its own account reads, a successor with room
/// standing by, its episode standing for the pass after the turn. The
/// readings are room, an unreadable or unmeasured account, zero headroom
/// on the plan or on the reserve, under the hook's standing failure row,
/// and a Pi screen that still shows the last turn's usage error above the
/// working one.
#[test]
fn a_pending_wall_whose_pane_runs_a_turn_is_held_with_no_resume_and_no_transfer() {
    let reset = 1_800_000_000 + 3600;
    let room = || marks(MarkKey::Below, "", "", Succession::On, "");
    let unread = |own: AccountState, reason: &str| {
        let mut m = marks(
            MarkKey::Unmeasured(MarkKind::Headroom),
            "",
            "",
            Succession::On,
            "",
        );
        m.own = Some(own);
        m.reason = reason.to_owned();
        m
    };
    let zero_on = |reserve_only: bool| {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        m.reserve_only = reserve_only;
        m
    };
    let unreadable = || unread(AccountState::Unreadable, "headroom-unreadable");
    let unmeasured = || unread(AccountState::Unmeasured, "headroom-none");
    let zero = || zero_on(false);
    let reserve_zero = || zero_on(true);
    let pi_working = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../tests/fixtures/oversee-watch/pi-working.txt"),
    )
    .unwrap();
    let turn = " Resume the orch workflow for CC-1 from where this session stopped.";
    assert!(pi_working.contains(turn));
    let pi_stale = pi_working.replace(
        turn,
        &format!(" Error: You've hit your usage limit · resets 6pm (UTC)\n\n{turn}"),
    );
    let claude_working = "❯ Resume the work\n✻ Working… (esc to interrupt)\n";
    type Reading<'a> = &'a dyn Fn() -> Marks;
    // case, the harness, its first screen, the reading once it works, the
    // screen it works on, whether the hook's failure row still stands
    let cases: [(&str, Harness, &str, Reading, &str, bool); 8] = [
        (
            "room",
            Harness::Claude,
            "❯\u{a0}\n",
            &room,
            claude_working,
            false,
        ),
        (
            "account unreadable",
            Harness::Claude,
            "❯\u{a0}\n",
            &unreadable,
            claude_working,
            false,
        ),
        (
            "account unmeasured",
            Harness::Claude,
            "❯\u{a0}\n",
            &unmeasured,
            claude_working,
            false,
        ),
        (
            "zero headroom",
            Harness::Claude,
            "❯\u{a0}\n",
            &zero,
            claude_working,
            false,
        ),
        (
            "zero headroom on the reserve",
            Harness::Claude,
            "❯\u{a0}\n",
            &reserve_zero,
            claude_working,
            false,
        ),
        (
            "standing failure row, account unreadable",
            Harness::Claude,
            "❯\u{a0}\n",
            &unreadable,
            claude_working,
            true,
        ),
        (
            "standing failure row, zero headroom",
            Harness::Claude,
            "❯\u{a0}\n",
            &zero,
            claude_working,
            true,
        ),
        (
            "Pi, the last turn's usage error on screen, account unreadable",
            Harness::Pi,
            &pi_working,
            &unreadable,
            &pi_stale,
            false,
        ),
    ];
    for (case, harness, first, reading, working, standing) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, dir.path(), "overseer", harness.name(), first);
        await_named(&server, &pane, harness.name());
        let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), dir.path());
        record["harness"] = json!(harness.name());
        record["harness_pid"] = json!(identity.pid.to_string());
        record["harness_start"] = json!(identity.start);
        if standing {
            let rows = dir.path().join("session-rows.jsonl");
            std::fs::write(
                &rows,
                "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\",\"message\":\"You've hit your weekly limit\"}\n",
            )
            .unwrap();
            record["session_rows"] = json!(rows.display().to_string());
        }
        fleet.set_overseer(record);
        let key = format!("{} {pane}", server.pid);
        let resumed = Cell::new(false);
        let judge =
            |_: &Caller, _: Option<&str>| Ok(if resumed.get() { reading() } else { zero() });
        let walk = |request: &WalkRequest| {
            if resumed.get() {
                walk_b(request)
            } else {
                walk_none(request)
            }
        };
        let accept = |_: &str, _: &str| Ok(());
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &accept;
        let state = fleet.read();
        driver.pass(&state);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("pending"),
            "{case}"
        );
        // A line only the working screen draws, then its working line.
        let drawn = match harness {
            Harness::Pi => "You've hit your usage limit",
            _ => "Resume the work",
        };
        redraw(
            &server,
            &pane,
            dir.path(),
            "overseer-working.txt",
            working,
            drawn,
        );
        await_drawn(&server, &pane, "Working");
        resumed.set(true);
        for at in 0..4 {
            let held = driver.pass(&state);
            assert!(
                event_lines(&held).is_empty(),
                "{case}, pass {at}: {:?}",
                lines(&held)
            );
            assert_eq!(
                driver.slot.read().unwrap().verdict,
                Verdict::Live,
                "{case}, pass {at}"
            );
            assert_eq!(
                driver.baseline.get("overseer-walled", &key),
                Some("pending"),
                "{case}, pass {at}"
            );
            assert_eq!(
                driver.baseline.get("resume", "overseer"),
                None,
                "{case}, pass {at}"
            );
            assert!(transfers.borrow().is_empty(), "{case}, pass {at}");
        }
    }
}

/// A pending wall's turn the owner typed is held while it runs, and once
/// it stops, its return in the hook's rows, the episode is the walk's or
/// the resume's again: with no room on the own account and none from the
/// walk it stays pending, with no resume and no move; its own account read
/// with room and its pane idle resumes it; a walk with room moves it.
#[test]
fn a_held_turn_that_stops_leaves_its_episode_to_the_walk_or_the_resume() {
    let reset = 1_800_000_000 + 3600;
    let zero = || {
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        m
    };
    let unread = || {
        let mut m = marks(
            MarkKey::Unmeasured(MarkKind::Headroom),
            "",
            "",
            Succession::On,
            "",
        );
        m.reason = "headroom-unreadable".to_owned();
        m
    };
    let room = || marks(MarkKey::Below, "", "", Succession::On, "");
    type Reading<'a> = &'a dyn Fn() -> Marks;
    // case, the reading once the turn stopped, whether the walk then has
    // room, the walled row after, whether a resume is asked, the transfers
    let cases: [(&str, Reading, bool, &str, bool, usize); 3] = [
        ("no room, no successor", &unread, false, "pending", false, 0),
        ("own account reads room", &room, false, "", true, 0),
        (
            "a successor with room",
            &unread,
            true,
            "requested",
            false,
            1,
        ),
    ];
    for (case, stopped, walk_room, walled, resumed, moved) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, dir.path(), "overseer", "claude", "❯\u{a0}\n");
        await_named(&server, &pane, "claude");
        let rows = dir.path().join("session-rows.jsonl");
        std::fs::write(
            &rows,
            "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\",\"message\":\"You've hit your weekly limit\"}\n",
        )
        .unwrap();
        let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), dir.path());
        record["harness_pid"] = json!(identity.pid.to_string());
        record["harness_start"] = json!(identity.start);
        record["session_rows"] = json!(rows.display().to_string());
        fleet.set_overseer(record);
        let key = format!("{} {pane}", server.pid);
        let ended = Cell::new(false);
        let judge = |_: &Caller, _: Option<&str>| Ok(if ended.get() { stopped() } else { zero() });
        let walk = |request: &WalkRequest| {
            if ended.get() && walk_room {
                walk_b(request)
            } else {
                walk_none(request)
            }
        };
        let accept = |_: &str, _: &str| Ok(());
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &accept;
        let state = fleet.read();
        driver.pass(&state);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("pending"),
            "{case}"
        );
        redraw(
            &server,
            &pane,
            dir.path(),
            "overseer-working.txt",
            "❯ Resume the work\n✻ Working… (esc to interrupt)\n",
            "Resume the work",
        );
        for _ in 0..2 {
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("overseer-walled", &key),
                Some("pending"),
                "{case}: held"
            );
        }
        // The turn returns: its rows, then the idle composer.
        let mut text = std::fs::read_to_string(&rows).unwrap();
        text.push_str("{\"harness\":\"claude\",\"event\":\"UserPromptSubmit\"}\n{\"harness\":\"claude\",\"event\":\"Stop\"}\n");
        std::fs::write(&rows, text).unwrap();
        redraw(
            &server,
            &pane,
            dir.path(),
            "overseer-returned.txt",
            "❯ Resume the work\n⏺ Done.\n❯\u{a0}\n",
            "Done.",
        );
        ended.set(true);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key).unwrap_or(""),
            walled,
            "{case}"
        );
        assert_eq!(
            driver.baseline.get("resume", "overseer").is_some(),
            resumed,
            "{case}"
        );
        assert_eq!(transfers.borrow().len(), moved, "{case}");
        if resumed {
            // The wake has not typed it yet: the next reading of the same
            // returned turn keeps it asked.
            let asked = driver.baseline.get("resume", "overseer").map(str::to_owned);
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("resume", "overseer").map(str::to_owned),
                asked,
                "{case}: kept"
            );
        }
    }
}

/// A pending account wall read live, its own account unread, settles the
/// transfer its walk asked before anything ends the wall: the launch fails
/// with its account left unproved, the case is asked again, and the next
/// walk holds that account out.
#[test]
fn a_pending_wall_read_live_settles_the_transfer_its_walk_asked() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (_, _, key, _) = live_overseer(dir.path(), &server, &fleet);
    let unread = Cell::new(false);
    let judge = |_: &Caller, _: Option<&str>| {
        if unread.get() {
            let mut m = marks(
                MarkKey::Unmeasured(MarkKind::Headroom),
                "",
                "",
                Succession::On,
                "",
            );
            m.reason = "headroom-unreadable".to_owned();
            return Ok(m);
        }
        Ok(marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        ))
    };
    let asked: RefCell<Vec<WalkRequest>> = RefCell::new(Vec::new());
    let walk = |request: &WalkRequest| {
        asked.borrow_mut().push(request.clone());
        if !unread.get() {
            return walk_none(request);
        }
        let mut walked = walk_b(request)?;
        if request.exclude.iter().any(|a| a == "/home/me/.bclaude")
            && let WalkAnswer::Lane(chosen) = &mut walked.answer
        {
            chosen.account = Some("/home/me/.cclaude".to_owned());
        }
        Ok(walked)
    };
    let accept = |_: &str, _: &str| Ok(());
    overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
    driver.alert = &accept;
    let state = fleet.read();
    driver.pass(&state);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    unread.set(true);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let failed_at = driver.now - 200;
    let mut doc = fleet.runner.fleet();
    doc["controller"]["unproved"] = json!([
        {"account": "/home/me/.bclaude", "note": "successor-not-ready", "at": clock::iso_utc(failed_at + 10)}
    ]);
    doc["intents"] = json!([{
        "id": "request-transfer:overseer:1", "op": "request-transfer", "target": "overseer",
        "created_at": clock::iso_utc(failed_at), "outcome": "failed",
        "observation": {"note": "successor-not-ready"}
    }]);
    fleet.runner.write_fleet(&doc);
    let state = fleet.read();
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let last = asked.borrow().last().cloned().unwrap();
    assert!(
        last.exclude.iter().any(|a| a == "/home/me/.bclaude"),
        "{:?}",
        last.exclude
    );
    let accounts: Vec<Option<String>> = transfers
        .borrow()
        .iter()
        .map(|t| t.successor.account.clone())
        .collect();
    assert_eq!(
        accounts,
        [
            Some("/home/me/.bclaude".to_owned()),
            Some("/home/me/.cclaude".to_owned())
        ]
    );
}

/// An announced usage wall on an overseer read live with its own account
/// read failed is no wall's end: the wall, its kept reset and its notice
/// rows stand, and the pass walks the case as a walled one. The row fails
/// where a live judgement ends the wall whatever its account reads.
#[test]
fn an_announced_wall_read_live_over_a_failed_account_read_keeps_its_rows_and_walks() {
    let reset = 1_800_000_000 + 3600;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (_, _, key, _) = live_overseer(dir.path(), &server, &fleet);
    let failed = Cell::new(false);
    let judge = |_: &Caller, _: Option<&str>| {
        if failed.get() {
            return Err("marks-unreadable".to_owned());
        }
        let mut m = marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        );
        m.resets = clock::iso_utc(reset);
        Ok(m)
    };
    let walked = Cell::new(0);
    let walk = |request: &WalkRequest| {
        walked.set(walked.get() + 1);
        walk_none(request)
    };
    let accept = |_: &str, _: &str| Ok(());
    overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
    driver.alert = &accept;
    let state = fleet.read();
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    let kept = reset.to_string();
    assert_eq!(
        driver.baseline.get("overseer-wall-reset", &key),
        Some(kept.as_str())
    );
    plant(
        &mut driver.baseline,
        "overseer-notice",
        &key,
        "account-unread".to_owned(),
    );
    failed.set(true);
    driver.pass(&state);
    assert_eq!(walked.get(), 1, "the pass walks");
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("pending")
    );
    assert_eq!(
        driver.baseline.get("overseer-wall-reset", &key),
        Some(kept.as_str())
    );
    let told = driver.baseline.get("overseer-notice", &key).unwrap_or("");
    assert!(
        told.split(' ').any(|told| told == "account-unread"),
        "{told}"
    );
    assert!(transfers.borrow().is_empty());
}

/// An announced wall whose walk finds a successor, read live with its own
/// account read failed, settles the transfer that walk asked before
/// anything ends the wall: the launch fails with its account left
/// unproved, the case is announced again, and the next walk holds that
/// account out.
#[test]
fn an_announced_wall_read_live_over_a_failed_account_read_settles_its_transfer() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (_, _, key, _) = live_overseer(dir.path(), &server, &fleet);
    let failed = Cell::new(false);
    let judge = |_: &Caller, _: Option<&str>| {
        if failed.get() {
            return Err("marks-unreadable".to_owned());
        }
        Ok(marks(
            MarkKey::Reached(MarkKind::Headroom),
            "0",
            "5",
            Succession::On,
            "/home/me/.eclaude",
        ))
    };
    let walk = |request: &WalkRequest| {
        let mut walked = walk_b(request)?;
        if request.exclude.iter().any(|a| a == "/home/me/.bclaude")
            && let WalkAnswer::Lane(chosen) = &mut walked.answer
        {
            chosen.account = Some("/home/me/.cclaude".to_owned());
        }
        Ok(walked)
    };
    let accept = |_: &str, _: &str| Ok(());
    overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
    driver.alert = &accept;
    let state = fleet.read();
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    failed.set(true);
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let failed_at = driver.now - 200;
    let mut doc = fleet.runner.fleet();
    doc["controller"]["unproved"] = json!([
        {"account": "/home/me/.bclaude", "note": "successor-not-ready", "at": clock::iso_utc(failed_at + 10)}
    ]);
    doc["intents"] = json!([{
        "id": "request-transfer:overseer:1", "op": "request-transfer", "target": "overseer",
        "created_at": clock::iso_utc(failed_at), "outcome": "failed",
        "observation": {"note": "successor-not-ready"}
    }]);
    fleet.runner.write_fleet(&doc);
    let state = fleet.read();
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("announced")
    );
    driver.pass(&state);
    assert_eq!(
        driver.baseline.get("overseer-walled", &key),
        Some("requested")
    );
    let accounts: Vec<Option<String>> = transfers
        .borrow()
        .iter()
        .map(|t| t.successor.account.clone())
        .collect();
    assert_eq!(
        accounts,
        [
            Some("/home/me/.bclaude".to_owned()),
            Some("/home/me/.cclaude".to_owned())
        ]
    );
}

/// An announced usage wall still ends on a live reading of its own account
/// with room, or on a turn the pane runs again while that read fails: the
/// wall, its reset and its notices go, and nothing walks.
#[test]
fn an_announced_wall_ends_on_a_reading_with_room_or_a_returned_turn() {
    let reset = 1_800_000_000 + 3600;
    let working = "❯ Resume the work\n✻ Working… (esc to interrupt)\n";
    // case, whether the second reading has room (else it fails), the
    // screen the pane then shows
    for (case, room, screen) in [
        ("a reading with room", true, None),
        ("a returned turn", false, Some(working)),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, dir.path(), "overseer", "claude", "❯\u{a0}\n");
        await_named(&server, &pane, "claude");
        let mut record = overseer_at(&server, &pane, &window_of(&server, &pane), dir.path());
        record["harness_pid"] = json!(identity.pid.to_string());
        record["harness_start"] = json!(identity.start);
        fleet.set_overseer(record);
        let key = format!("{} {pane}", server.pid);
        let second = Cell::new(false);
        let judge = |_: &Caller, _: Option<&str>| {
            if second.get() {
                return if room {
                    Ok(marks(MarkKey::Below, "", "", Succession::On, ""))
                } else {
                    Err("marks-unreadable".to_owned())
                };
            }
            let mut m = marks(
                MarkKey::Reached(MarkKind::Headroom),
                "0",
                "5",
                Succession::On,
                "/home/me/.eclaude",
            );
            m.resets = clock::iso_utc(reset);
            Ok(m)
        };
        let walked = Cell::new(0);
        let walk = |request: &WalkRequest| {
            walked.set(walked.get() + 1);
            walk_none(request)
        };
        let accept = |_: &str, _: &str| Ok(());
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &accept;
        let state = fleet.read();
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("announced"),
            "{case}"
        );
        plant(
            &mut driver.baseline,
            "overseer-notice",
            &key,
            "account-unread".to_owned(),
        );
        if let Some(screen) = screen {
            redraw(
                &server,
                &pane,
                dir.path(),
                "overseer-working.txt",
                screen,
                "Resume the work",
            );
        }
        second.set(true);
        driver.pass(&state);
        for row in ["overseer-walled", "overseer-wall-reset", "overseer-notice"] {
            assert_eq!(driver.baseline.get(row, &key), None, "{case}: {row}");
        }
        assert_eq!(walked.get(), 0, "{case}");
        assert!(transfers.borrow().is_empty(), "{case}");
    }
}

/// A pending usage wall's own account that cannot be read past its reset
/// keeps the reset it confirmed and is read again on each pass, walked
/// beside it; still unread a whole patience past the reset, the owner is
/// told once with the read's cause. The reset a pending pass read is kept,
/// and so is one only the announcing pass read.
#[test]
fn an_own_account_unread_past_its_reset_keeps_it_and_tells_the_owner_once() {
    // case, the passes that read the account before every read fails
    for (case, read) in [
        ("a pending pass read it", 2),
        ("only the announce read it", 1),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let (pane, _) = walled_overseer(dir.path(), &server, &fleet);
        let reset: u64 = 1_800_000_000 + 3600;
        let unread = Cell::new(false);
        let judge = |_: &Caller, _: Option<&str>| {
            if unread.get() {
                let mut m = marks(
                    MarkKey::Unmeasured(MarkKind::Headroom),
                    "",
                    "",
                    Succession::On,
                    "",
                );
                m.reason = "headroom-unreadable".to_owned();
                return Ok(m);
            }
            let mut m = marks(
                MarkKey::Reached(MarkKind::Headroom),
                "0",
                "5",
                Succession::On,
                "/home/me/.eclaude",
            );
            m.resets = clock::iso_utc(reset);
            Ok(m)
        };
        let walks = Cell::new(0);
        let walk = |request: &WalkRequest| {
            walks.set(walks.get() + 1);
            walk_none(request)
        };
        let told: RefCell<Vec<(String, String)>> = RefCell::new(Vec::new());
        let noting = |file: &str, text: &str| {
            told.borrow_mut().push((file.to_owned(), text.to_owned()));
            Ok(())
        };
        overseer_driver!(server, fleet, judge, walk, readers, transfers, driver);
        driver.alert = &noting;
        let key = format!("{} {pane}", server.pid);
        let state = fleet.read();
        for _ in 0..read {
            driver.pass(&state);
        }
        unread.set(true);
        for _ in read..2 {
            driver.pass(&state);
        }
        let kept = reset.to_string();
        assert_eq!(
            driver.baseline.get("overseer-wall-reset", &key),
            Some(kept.as_str()),
            "{case}"
        );
        for at in [reset + 60, reset + 1799] {
            driver.now = at;
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("overseer-wall-reset", &key),
                Some(kept.as_str())
            );
            assert_eq!(told.borrow().len(), 1, "only the wall's notice");
        }
        driver.now = reset + 1800;
        driver.pass(&state);
        driver.pass(&state);
        assert_eq!(
            driver.baseline.get("overseer-walled", &key),
            Some("pending")
        );
        assert_eq!(walks.get(), 5, "each pass past the announce walks");
        let told = told.borrow();
        let keys: Vec<&str> = told
            .iter()
            .map(|(_, text)| text.split(':').next().unwrap_or_default())
            .collect();
        assert_eq!(
            keys,
            ["overseer-walled-pending", "overseer-account-unread"],
            "{case}"
        );
        assert!(
            told[1].1.contains("headroom-unreadable"),
            "{case}: {}",
            told[1].1
        );
        assert!(transfers.borrow().is_empty(), "{case}");
    }
}

/// A Claude overseer walled by its weekly limit, its pane and window.
fn walled_overseer(dir: &Path, server: &Server, fleet: &Fleet) -> (String, String) {
    walled_overseer_drawing(dir, server, fleet, "")
}

/// [`walled_overseer`] with `above` drawn over its composer, such as the
/// usage banner Claude leaves standing at its wall.
fn walled_overseer_drawing(
    dir: &Path,
    server: &Server,
    fleet: &Fleet,
    above: &str,
) -> (String, String) {
    let claude = named_sleep(dir, "claude");
    let screen = dir.join("overseer-screen.txt");
    std::fs::write(&screen, format!("{above}❯\u{a0}\n")).unwrap();
    let pane = server.open_window(
        "overseer",
        dir,
        &format!(
            "bash -c \"cat {}; exec {} 600\"",
            screen.display(),
            claude.display()
        ),
    );
    let identity = await_named(server, &pane, "claude");
    await_drawn(server, &pane, "❯");
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
    let mut record = relaunchable(lane_record(
        "issue-12",
        "gh-12",
        "claude",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    ));
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
    let world = HostedWorld::new(dir.path(), &server, &fleet);
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

/// A Codex lane at its composer below a prior turn is idle on the first
/// pass where it is local, and on the second where it is hosted: a hosted
/// lane's screen between a finished tool call and the next reads the same.
#[test]
fn a_codex_lane_below_a_prior_turn_is_idle_on_its_first_pass_locally_and_on_its_second_hosted() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let drawn = "printf '%s\\n' '› complete' '› Type a prompt'";
    let codex = named_sleep(dir.path(), "codex");
    let line = format!("{drawn}; exec {} 600", codex.display());
    let local = server.open_window("gh-1", dir.path(), &format!("bash -c \"{line}\""));
    let identity = await_named(&server, &local, "codex");
    await_drawn(&server, &local, "Type a prompt");
    let shell = server.open_window(
        "gh-2",
        dir.path(),
        &format!("{drawn}; exec bash --norc --noprofile"),
    );
    await_drawn(&server, &shell, "Type a prompt");
    let mut hosted = hosted_lane(dir.path(), "KEN-2", "gh-2", "/remote/KEN-2");
    hosted["harness"] = json!("codex");
    hosted["launch"] = json!({"pane": shell, "server": server.pid});
    fleet.set_lanes(vec![
        lane_record(
            "KEN-1",
            "gh-1",
            "codex",
            &server,
            &local,
            Some(&identity),
            dir.path(),
        ),
        hosted,
    ]);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    world.plant_host(&[
        (
            &format!("{} capabilities", provider(dir.path())),
            ok(SSH_LINE),
        ),
        ("status --item KEN-2 --harness codex", ok("running\n")),
    ]);
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let idle = |produced: &Produced| -> Vec<String> {
        event_lines(produced)
            .into_iter()
            .filter(|l| l.starts_with("EVENT idle-after-return"))
            .collect()
    };
    assert_eq!(
        idle(&driver.pass(&state)),
        vec!["EVENT idle-after-return gh-1"]
    );
    assert_eq!(
        idle(&driver.pass(&state)),
        vec!["EVENT idle-after-return gh-2"]
    );
}

/// A hosted Copilot lane launched with allow-all keeps its session store on
/// its host: its asking line carries no policy note read from this
/// machine's store.
#[test]
fn a_hosted_copilot_lanes_prompt_carries_no_note_from_this_machines_store() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window(
        "gh-1",
        dir.path(),
        "printf '%s\\n' 'Do you want to proceed?' '❯ 1. Yes'; exec bash --norc --noprofile",
    );
    await_drawn(&server, &pane, "Do you want to proceed?");
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-1"]);
    let _lane = host.lead("KEN-1", "copilot");
    let root = host.lane_root("KEN-1").display().to_string();
    let mut lane = hosted_lane(dir.path(), "KEN-1", "gh-1", &root);
    lane["harness"] = json!("copilot");
    lane["allow_all"] = json!(true);
    lane["launch"] = json!({"pane": pane, "server": server.pid});
    fleet.set_lanes(vec![lane]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    let asking: Vec<String> = event_lines(&driver.pass(&state))
        .into_iter()
        .filter(|l| l.starts_with("EVENT lane-asking"))
        .collect();
    assert_eq!(asking, vec!["EVENT lane-asking gh-1"]);
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

/// Through the runtime's call to the shipped ssh provider, over a Pi lane
/// its `create` made and its prefix led: the host's last row, a turn ended
/// on the account's limit, is `usage-limit`, read by the provider's `cat` of
/// its path under the lane's root on the host. The fleet record is a hosted
/// record planted as `main` wrote it (`host` the provider, `kind` `ssh`,
/// `mail_root` the root on the host).
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
    let scripts = dir.path().join("scripts");
    let host = SshHost::new(dir.path(), &scripts, "KEN-5");
    let _lane = host.lead("KEN-5", "pi");
    let root = host.worktree();
    let rows = root.join("tmp/lane-mail/KEN-5/session-rows.jsonl");
    std::fs::create_dir_all(rows.parent().unwrap()).unwrap();
    std::fs::write(
        &rows,
        "{\"harness\":\"pi\",\"event\":\"Stop\",\"stop_reason\":\"error\",\"message\":\"429 Usage limit reached for this model\",\"at\":3}\n",
    )
    .unwrap();
    let mut record = lane_record(
        "KEN-5",
        "gh-5",
        "pi",
        &server,
        &pane,
        Some(&identity),
        dir.path(),
    );
    record["host"] = json!(host.provider());
    record["kind"] = json!("ssh");
    record["mail_root"] = json!(root.display().to_string());
    fleet.set_lanes(vec![record]);
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = scripts.clone();
    let produced = driver.pass(&state);
    let limits: Vec<String> = event_lines(&produced)
        .into_iter()
        .filter(|l| l.starts_with("EVENT usage-limit "))
        .collect();
    assert_eq!(
        limits,
        vec!["EVENT usage-limit gh-5 /home/me/.eclaude".to_owned()],
        "{:?} {:?}",
        lines(&produced),
        produced.failed
    );
    let asked = format!(
        "ORCH_LANE_HOST={SSH_PROVIDER} cat --item KEN-5 {}",
        rows.display()
    );
    assert!(host.calls().contains(&asked), "{:?}", host.calls());
}

/// Through the runtime's call to the shipped ssh provider, the record is
/// read in both places the local read names: the clone its `.git` names
/// under the state directory its settings name (none: `tmp`), and the lane
/// root's `tmp`, where a lane whose launch forbids writing the main checkout
/// keeps it. Either is `handoff` with the record under it once; a state the
/// host serves that is no JSON object is the pass's `handoff-read-failed`,
/// never no handoff. The fleet record is a hosted record planted as `main`
/// wrote it (`host` the provider, `kind` `ssh`, `mail_root` the root on the
/// host).
#[test]
fn a_hosted_lanes_handoff_is_read_through_its_provider() {
    for (case, in_clone, valid) in [
        ("the clone's state", true, true),
        ("the root's tmp", false, true),
        ("a state that is no JSON", true, false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let claude = named_sleep(dir.path(), "claude");
        let line = format!("printf 'working\\n'; exec {} 600", claude.display());
        let pane = server.open_window("gh-4", dir.path(), &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, "claude");
        let scripts = dir.path().join("scripts");
        let host = SshHost::new(dir.path(), &scripts, "KEN-4");
        let remote = dir.path().join("remote");
        let lane_root = remote.join("KEN-4");
        let handoff = format!(
            r#"{{"merged":[],"remaining":["review"],"branch":"b","worktree":"{}","open_pr":null,"traps":[]}}"#,
            lane_root.display()
        );
        let record_doc = format!("{{\"handoff\":{handoff}}}\n");
        let text = if valid {
            record_doc.as_str()
        } else {
            "not json\n"
        };
        let place = if in_clone {
            remote.join("clone/tmp/items/KEN-4/workflow-state-KEN-4.json")
        } else {
            lane_root.join("tmp/items/KEN-4/workflow-state-KEN-4.json")
        };
        let clone_root = remote.join("clone").display().to_string();
        for (path, text) in [
            (
                lane_root.join(".git"),
                format!("gitdir: {clone_root}/.git/worktrees/KEN-4\n"),
            ),
            (place.clone(), text.to_owned()),
        ] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        let place = place.display().to_string();
        let mut record = lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        );
        record["host"] = json!(host.provider());
        record["kind"] = json!("ssh");
        record["mail_root"] = json!(lane_root.display().to_string());
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = scripts.clone();
        let first = driver.pass(&state);
        if valid {
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
                Some(clone_root.as_str()),
                "{case}"
            );
            std::fs::remove_file(lane_root.join(".git")).unwrap();
            driver.pass(&state);
            assert_eq!(
                driver.baseline.get("clone-root", "KEN-4"),
                Some(clone_root.as_str()),
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

/// A hosted lane's handoff read its host refused is judged by the
/// provider's list. A sandbox the provider no longer lists, as after the
/// lane's own close-out, holds no handoff, so the item's handoff row is
/// cleared and no `handoff-read-failed` is said; a sandbox it still lists
/// keeps the refusal, and with it the row.
#[test]
fn a_refused_hosted_handoff_read_fails_only_while_the_provider_lists_the_sandbox() {
    for (case, listed) in [("sandbox gone", false), ("sandbox listed", true)] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let claude = named_sleep(dir.path(), "claude");
        let line = format!("printf 'working\\n'; exec {} 600", claude.display());
        let pane = server.open_window("gh-4", dir.path(), &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, "claude");
        let scripts = dir.path().join("scripts");
        // The provider holds a lane of KEN-4 only where its sandbox stands:
        // its list names an item whose clone carries the lane marker.
        let host = SshHost::new(dir.path(), &scripts, if listed { "KEN-4" } else { "KEN-9" });
        let marker = dir.path().join("clone/.git/lane-host-item");
        std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
        std::fs::write(&marker, "KEN-4\n").unwrap();
        // A `.git` that is a directory with no HEAD: the host refuses its
        // `cat`, which reads no clone.
        let lane_root = dir.path().join("remote/KEN-4");
        std::fs::create_dir_all(lane_root.join(".git")).unwrap();
        let mut record = lane_record(
            "KEN-4",
            "gh-4",
            "claude",
            &server,
            &pane,
            Some(&identity),
            dir.path(),
        );
        record["host"] = json!(host.provider());
        record["kind"] = json!("ssh");
        record["mail_root"] = json!(lane_root.display().to_string());
        fleet.set_lanes(vec![record]);
        let state = fleet.read();
        lane_driver!(server, fleet, readers, driver);
        driver.scripts = scripts.clone();
        driver.baseline.apply(Change::Set {
            kind: "handoff".into(),
            identity: "KEN-4".into(),
            value: "1".into(),
        });
        let produced = driver.pass(&state);
        // The pass keeps its first failure, and the lane's other host reads
        // fail on the same refused host first, so the handoff's own answer
        // is read from its row: a refusal kept leaves the row, no handoff
        // clears it.
        assert_eq!(
            driver.baseline.get("handoff", "KEN-4"),
            listed.then_some("1"),
            "{case}: {:?} {:?}",
            produced.failed,
            lines(&produced)
        );
    }
}

/// A hosted lane's files are asked of its provider only under the root its
/// host named. A launch still preparing, a first one or a relaunch, holds
/// the checkout it ran from as `mail_root` (equal to `checkout`), which the
/// host does not have: the pass asks nothing under it, says no failure, and
/// keeps the handoff row a running pass set, so the relaunched lane's record
/// is not said again. A lane running with its root still the checkout, as a
/// launch confirmed by the reconcile records it, is unread under its key,
/// never read as absent: each reader under it says its own failure, the
/// start stall's first, then, once the stall's row stands, the handoff's.
/// The provider refuses any path outside its root, as `lane-host-daytona`
/// does. The lane is Pi's, whose rows are read through the provider on every
/// pass, preparing included.
#[test]
fn a_hosted_lanes_files_are_asked_only_under_its_host_root() {
    #[derive(Clone, Copy, Debug)]
    enum Step {
        /// Running under the root its host named.
        Running,
        /// Preparing, `mail_root` the checkout.
        Preparing,
        /// Running, `mail_root` still the checkout.
        RunningAtCheckout,
        /// As [`Step::RunningAtCheckout`], its start already seen by the
        /// start stall, which then says nothing.
        RunningAtCheckoutStallSeen,
    }
    // Each step's record, whether `EVENT handoff` is said, and the pass's
    // failure, the first one a reader said.
    type Steps<'a> = &'a [(Step, bool, Option<&'a str>)];
    let cases: [(&str, Steps); 2] = [
        (
            "relaunch",
            &[
                (Step::Running, true, None),
                (Step::Preparing, false, None),
                (Step::Running, false, None),
            ],
        ),
        (
            "confirmed at the checkout",
            &[
                (
                    Step::RunningAtCheckout,
                    false,
                    Some("start-stall-unread item=KEN-4 cause=root-pending"),
                ),
                (
                    Step::RunningAtCheckoutStallSeen,
                    false,
                    Some("handoff-read-failed item=KEN-4 cause=root-pending"),
                ),
            ],
        ),
    ];
    for (case, steps) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let fleet = Fleet::new(&server);
        let pi = named_sleep(dir.path(), "pi");
        let line = format!("printf 'working\\n'; exec {} 600", pi.display());
        let pane = server.open_window("gh-4", dir.path(), &format!("bash -c \"{line}\""));
        let identity = await_named(&server, &pane, "pi");
        let checkout = dir.path().join("overseer");
        let host_root = dir.path().join("host");
        let lane_root = host_root.join("KEN-4");
        let clone = host_root.join("clone");
        let handoff =
            r#"{"merged":[],"remaining":["review"],"branch":"b","open_pr":null,"traps":[]}"#;
        for (path, text) in [
            (
                lane_root.join(".git"),
                format!("gitdir: {}/.git/worktrees/KEN-4\n", clone.display()),
            ),
            (
                clone.join("tmp/items/KEN-4/workflow-state-KEN-4.json"),
                format!("{{\"handoff\":{handoff}}}\n"),
            ),
        ] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        let log = dir.path().join("provider.log");
        let provider = dir.path().join("provider");
        write_executable(
            &provider,
            format!(
                "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '{log}'\nroot='{root}'\ncase \"$1\" in\n  capabilities) printf '{SSH_LINE}\\n' ;;\n  cat) case \"$4\" in \"$root\"/*) [ -f \"$4\" ] || exit 2; exec cat -- \"$4\" ;; esac\n       echo \"lane-host-fake: cat-path-outside-root item=$3 path=$4 root=$root\" >&2; exit 1 ;;\n  touch) exit 0 ;;\n  status) echo running ;;\n  *) exit 64 ;;\nesac\n",
                log = log.display(),
                root = host_root.display(),
            ),
        );
        let mut launched = lane_record(
            "KEN-4",
            "gh-4",
            "pi",
            &server,
            &pane,
            Some(&identity),
            &checkout,
        );
        launched["host"] = json!(provider.display().to_string());
        launched["kind"] = json!("ssh");
        launched["checkout"] = json!(checkout.display().to_string());
        lane_driver!(server, fleet, readers, driver);
        for (n, &(step, said, failure)) in steps.iter().enumerate() {
            let mut record = launched.clone();
            match step {
                Step::Running => record["mail_root"] = json!(lane_root.display().to_string()),
                Step::Preparing => {
                    record["status"] = json!("preparing");
                    record["running_at"] = Value::Null;
                }
                Step::RunningAtCheckout => {}
                // `lane_record`'s `running_at`, 2026-01-01T00:00:00Z.
                Step::RunningAtCheckoutStallSeen => driver.baseline.apply(Change::Set {
                    kind: "start-stalled".into(),
                    identity: "gh-4".into(),
                    value: "1767225600|seen".into(),
                }),
            }
            fleet.set_lanes(vec![record]);
            let produced = driver.pass(&fleet.read());
            let at = format!("{case} step {n} {step:?}: {:?}", lines(&produced));
            assert_eq!(produced.failed.as_deref(), failure, "{at}");
            let calls = std::fs::read_to_string(&log).unwrap_or_default();
            let outside: Vec<&str> = calls
                .lines()
                .filter(|l| l.starts_with("cat ") && !l.contains(&host_root.display().to_string()))
                .collect();
            assert_eq!(outside, Vec::<&str>::new(), "{at}");
            let handed = event_lines(&produced).contains(&"EVENT handoff KEN-4".to_owned());
            assert_eq!(handed, said, "{at}");
        }
    }
}

/// A detached hosted launch retains its confirmed host-exec phase. A
/// provider's failed capture of the running harness breaks the sequence of
/// exit readings, even though the watch could not read the harness's screen.
#[test]
fn a_hosted_lane_with_an_unreadable_native_observation_is_not_exited() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let pane = server.open_window("gh-4", dir.path(), "exec sleep 600");
    let mut lane = hosted_lane(dir.path(), "KEN-4", "gh-4", "/remote/KEN-4");
    lane["launched_at"] = json!(clock::iso_utc(1_799_999_940));
    lane["launch"] = json!({"pane": pane, "server": server.pid, "server_start": server.start});
    let mut doc = fleet.runner.fleet();
    doc["lanes"] = json!([lane]);
    doc["intents"] = json!([{
        "id": "launch-session:KEN-4:1-1", "op": "launch-session", "target": "KEN-4",
        "created_at": "2027-01-15T07:59:00Z", "outcome": "confirmed",
        "phase": {"phase": "preparing", "step": "host-exec", "at": provider(dir.path())},
        "observation": {"note": "session-hosted", "pane": pane, "server": server.pid}
    }]);
    fleet.runner.write_fleet(&doc);
    let state = fleet.read();
    let world = HostedWorld::new(dir.path(), &server, &fleet);
    write_executable(
        &world.scripts.join(hosted::ORCH_RUNTIME),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexit 1\n",
            world.scripts.join("close.log").display()
        ),
    );
    let plant = |capabilities, status| {
        world.plant_host(&[
            ("capabilities", capabilities),
            ("status --item KEN-4 --harness claude", status),
            (
                "capture --item KEN-4",
                json!({"exit": 1, "stderr": "lane-host: ssh-failed\n"}),
            ),
            ("cat --item KEN-4 /remote/KEN-4/.git", answer(2, "")),
            (
                "cat --item KEN-4 /remote/KEN-4/tmp/items/KEN-4/workflow-state-KEN-4.json",
                answer(2, ""),
            ),
            ("touch --item KEN-4", ok("")),
        ]);
    };
    let plant_status = |status| plant(ok(VERB_LINE), status);
    let status_failure = json!({"exit": 1, "stderr": "lane-host: status read failed\n"});
    let status_cause = "EVENT lane-unreadable gh-4 cause=harness-probe-failed item=KEN-4 status exit=1 lane-host: status read failed";
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    plant_status(ok("exited\n"));
    let before = driver.pass(&state);
    driver.baseline.apply(Change::Set {
        kind: "merged".into(),
        identity: "KEN-4".into(),
        value: "o/r#7@1799999970".into(),
    });
    plant_status(ok("running\n"));
    let unread = driver.pass(&state);
    driver.baseline.apply(Change::Clear {
        kind: "merged".into(),
        identity: "KEN-4".into(),
    });
    plant_status(ok("exited\n"));
    let after = driver.pass(&state);
    let observed = [
        event_lines(&before),
        event_lines(&unread),
        event_lines(&after),
    ];
    let attempts = world.log("close.log").len();
    assert!(
        !observed
            .iter()
            .flatten()
            .any(|l| l == "EVENT lane-exited gh-4")
            && attempts == 0,
        "events={observed:?} close-attempts={attempts} failure={:?}",
        after.failed
    );
    assert_eq!(
        observed[1],
        [
            "EVENT lane-unreadable gh-4 cause=capture-failed item=KEN-4 capture exit=1 lane-host: ssh-failed"
        ]
    );

    // Two clean reads report the exit. If that close fails, an unreadable
    // next pass neither retries it nor forgets that the exit was reported.
    let reported = driver.pass(&state);
    assert_eq!(event_lines(&reported), ["EVENT lane-exited gh-4"]);
    assert_eq!(world.log("close.log").len(), 1);
    plant_status(status_failure.clone());
    assert_eq!(event_lines(&driver.pass(&state)), [status_cause]);
    assert_eq!(world.log("close.log").len(), 1);
    plant_status(ok("exited\n"));
    assert!(event_lines(&driver.pass(&state)).is_empty());
    assert_eq!(world.log("close.log").len(), 2);

    // A successful running status invalidates the old exit even when the
    // capture fails. The first fresh exit cannot retry the old close.
    plant_status(ok("running\n"));
    assert_eq!(event_lines(&driver.pass(&state)), observed[1]);
    assert_eq!(world.log("close.log").len(), 2);
    plant_status(ok("exited\n"));
    assert!(event_lines(&driver.pass(&state)).is_empty());
    assert_eq!(world.log("close.log").len(), 2);

    let capability_cause = format!(
        "host-capabilities-unread host={} cause=capabilities exit=1 lane-host: capabilities read failed",
        provider(dir.path()),
    );
    for (capabilities, status, cause) in [
        (
            ok(VERB_LINE),
            status_failure.clone(),
            status_cause.to_owned(),
        ),
        (
            json!({"exit": 1, "stderr": "lane-host: capabilities read failed\n"}),
            ok("exited\n"),
            format!("EVENT lane-unreadable gh-4 cause={capability_cause}"),
        ),
    ] {
        plant(capabilities, status);
        let unread = driver.pass(&state);
        plant_status(ok("exited\n"));
        let fresh_exit = driver.pass(&state);
        assert!(
            event_lines(&fresh_exit).is_empty() && world.log("close.log").len() == 2,
            "after {cause}: events={:?} close-attempts={}",
            lines(&fresh_exit),
            world.log("close.log").len()
        );
        assert_eq!(event_lines(&unread), [cause]);
    }
    assert_eq!(
        event_lines(&driver.pass(&state)),
        ["EVENT lane-exited gh-4"]
    );
    assert_eq!(world.log("close.log").len(), 3);

    // A relaunch keeps the window's lane name and publishes a new pane.
    let retired = support::tmux(&server.socket, &["kill-pane", "-t", &pane]);
    assert!(retired.status.success(), "{}", stderr(&retired));
    let replacement = server.open_window("gh-4", dir.path(), "exec sleep 600");
    doc["lanes"][0]["launch"]["pane"] = json!(replacement);
    fleet.runner.write_fleet(&doc);
    plant_status(status_failure);
    assert_eq!(event_lines(&driver.pass(&fleet.read())), [status_cause]);
    assert_eq!(driver.baseline.get("lane-exited", "gh-4"), None);
    assert_eq!(driver.baseline.get("close-pending", "gh-4"), None);
    assert_eq!(world.log("close.log").len(), 3);
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
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-4"]);
    // The lane's group led and ended: the provider reads it exited.
    drop(host.lead("KEN-4", "codex"));
    let root = host.lane_root("KEN-4").display().to_string();
    let mut four = hosted_lane(dir.path(), "KEN-4", "gh-4", &root);
    four["harness"] = json!("codex");
    fleet.set_lanes(vec![four.clone()]);
    let state = fleet.read();
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
        ],
        "{:?}",
        second.failed
    );
    // The keep the request asked: the record the real close wrote reads
    // stopped.
    assert_eq!(fleet.read().lanes[0].status, state::LaneStatus::Stopped);
    let third = driver.pass(&fleet.read());
    assert_eq!(event_lines(&third), Vec::<String>::new());
    assert_eq!(third.failed, None);
    assert_eq!(closes(&fleet, "KEN-4"), 1);

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let fleet = Fleet::new(&server);
    let (world, host) = HostedWorld::ssh(dir.path(), &server, &fleet, &["KEN-4"]);
    host.refuse();
    four["host"] = json!(host.provider());
    four["mail_root"] = json!(host.lane_root("KEN-4").display().to_string());
    fleet.set_lanes(vec![four]);
    let state = fleet.read();
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
    assert_eq!(closes(&fleet, "KEN-4"), 0, "an unread host asks no close");
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
            "#!/bin/bash\n[ \"$1\" = --headless ] && exit 1\nhome=\"${{COPILOT_HOME:-$HOME/.copilot}}\"\nid=\"s-$(basename \"$PWD\")\"\nmkdir -p \"$home/session-state/$id\"\nprintf 'id: %s\\ncwd: %s\\n' \"$id\" \"$(pwd -P)\" > \"$home/session-state/$id/workspace.yaml\"\nprintf '%s\\n' '{{\"type\":\"user.message\"}}' > \"$home/session-state/$id/events.jsonl\"\nprintf '%s\\n' ' ~/work [⎇ main]' '{rule}' '❯ ' '{rule}'\nwhile IFS= read -r _line; do :; done\n"
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

#[test]
fn local_lane_rows_hold_the_turn_open_and_a_claude_failure_ends_it() {
    if !isolated_row("local_lane_rows_hold_the_turn_open_and_a_claude_failure_ends_it") {
        return;
    }
    for (harness, composer) in [
        ("claude", "❯\u{a0}\n"),
        ("codex", "› Ask Codex to do anything\n"),
        ("copilot", "❯ \n────────────────────────────────────────\n"),
    ] {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().canonicalize().unwrap();
        let server = Server::start(&dir, "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(&server, &dir, "gh-1", harness, composer);
        await_drawn(
            &server,
            &pane,
            if harness == "copilot" {
                "────"
            } else if harness == "codex" {
                "Ask Codex"
            } else {
                "❯"
            },
        );
        fleet.set_lanes(vec![lane_record(
            "KEN-1",
            "gh-1",
            harness,
            &server,
            &pane,
            Some(&identity),
            &dir,
        )]);
        let state = fleet.read();
        let file = dir.join("tmp/lane-mail/KEN-1/session-rows.jsonl");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        let prompt = json!({"harness": harness, "event": "UserPromptSubmit", "at": 1});
        std::fs::write(&file, format!("{prompt}\n")).unwrap();
        lane_driver!(server, fleet, readers, driver);
        for _ in 0..3 {
            assert!(event_lines(&driver.pass(&state)).is_empty(), "{harness}");
            assert_eq!(driver.baseline.get("lane-idle", "gh-1"), None, "{harness}");
        }
        let stop = json!({"harness": harness, "event": "Stop", "at": 2});
        std::fs::write(&file, format!("{prompt}\n{stop}\n")).unwrap();
        driver.pass(&state);
        assert_eq!(
            event_lines(&driver.pass(&state)),
            vec!["EVENT idle-after-return gh-1"],
            "{harness}"
        );
        assert!(event_lines(&driver.pass(&state)).is_empty());
        if harness == "claude" {
            let failure = json!({"harness": "claude", "event": "StopFailure", "error": "model_not_found", "at": 3});
            std::fs::write(&file, format!("{prompt}\n{stop}\n{prompt}\n{failure}\n")).unwrap();
            driver.pass(&state);
            assert_eq!(
                event_lines(&driver.pass(&state)),
                vec!["EVENT idle-after-return gh-1 cause=model_not_found"]
            );
            assert!(event_lines(&driver.pass(&state)).is_empty());
        }
    }
}

#[test]
fn lane_dialogs_and_pane_walls_precede_rows_except_on_pi() {
    if !isolated_row("lane_dialogs_and_pane_walls_precede_rows_except_on_pi") {
        return;
    }
    use lanes::{Inputs, LaneState, WallSource};
    let working = rows::last_row_in("{\"event\":\"UserPromptSubmit\"}\n");
    let idle = rows::last_row_in("{\"event\":\"Stop\"}\n");
    for harness in [
        Harness::Claude,
        Harness::Codex,
        Harness::Copilot,
        Harness::Pi,
    ] {
        for rows in [&working, &idle] {
            for (screen, expected) in [
                ("Do you want to continue?\n› 1. Yes\n", LaneState::Asking),
                (
                    "Switch to gpt-6-luna for lower credit usage?\n› 1. Switch\n",
                    LaneState::RateLimitSwitch,
                ),
                (
                    "You've hit your session limit\n",
                    LaneState::Walled {
                        kind: observe::WallKind::Usage,
                        banner: "You've hit your session limit".to_owned(),
                        source: WallSource::Pane,
                    },
                ),
                (
                    "Not logged in · Please run /login\n",
                    LaneState::Walled {
                        kind: observe::WallKind::Auth,
                        banner: "Not logged in · Please run /login".to_owned(),
                        source: WallSource::Pane,
                    },
                ),
            ] {
                let screen = Ok(screen.to_owned());
                let state = lanes::classify(&Inputs {
                    pane: None,
                    process: Some(&ProcessReading::HarnessUp),
                    screen: Some(&screen),
                    rows: Some(rows),
                    harness: Some(harness),
                    account_room: None,
                });
                let expected = if harness == Harness::Pi {
                    if rows == &working {
                        LaneState::Working
                    } else {
                        LaneState::Idle {
                            capacity: false,
                            cause: None,
                        }
                    }
                } else {
                    expected
                };
                assert_eq!(state, expected, "{harness:?} {screen:?} {rows:?}");
            }
        }
    }
}

#[test]
fn rows_none_uses_the_non_pi_pane_and_unreadable_rows_stay_unjudged() {
    if !isolated_row("rows_none_uses_the_non_pi_pane_and_unreadable_rows_stay_unjudged") {
        return;
    }
    use lanes::{Inputs, LaneState};
    for (harness, composer) in [
        (Harness::Claude, "❯\u{a0}\n"),
        (Harness::Codex, "› Ask Codex to do anything\n"),
        (
            Harness::Copilot,
            "❯ \n────────────────────────────────────────\n",
        ),
        (Harness::Pi, "› not a Pi composer\n"),
    ] {
        let screen = Ok(composer.to_owned());
        let classify = |rows| {
            lanes::classify(&Inputs {
                pane: None,
                process: Some(&ProcessReading::HarnessUp),
                screen: Some(&screen),
                rows,
                harness: Some(harness),
                account_room: None,
            })
        };
        let expected = if harness == Harness::Pi {
            LaneState::Unjudged {
                cause: "rows-none".to_owned(),
            }
        } else {
            LaneState::Idle {
                capacity: false,
                cause: None,
            }
        };
        assert_eq!(classify(Some(&Reading::Gone)), expected, "{harness:?}");
        assert_eq!(classify(None), expected, "{harness:?}");
        assert_eq!(
            classify(Some(&Reading::Unreadable {
                cause: "rows-invalid"
            })),
            LaneState::Unjudged {
                cause: "rows-invalid".to_owned()
            }
        );
    }
}

const CODEX_LIVE_FAILURE: &str = include_str!("../fixtures/oversee-watch/codex-api-error-live.txt");

/// The worktree script writes the map in a real linked checkout. Only the
/// session delivery endpoint is faked, so the tests can inspect every paste.
struct RestackWatch {
    _temp: tempfile::TempDir,
    main: PathBuf,
    tree: PathBuf,
    bin: PathBuf,
    state: PathBuf,
    delivery: &'static str,
    head: String,
    server: Server,
    fleet: Fleet,
    pane: String,
}

impl RestackWatch {
    fn new(dropped: bool, aliased: bool, direct: bool) -> Self {
        Self::with_replay(dropped, aliased, direct, false)
    }

    fn with_replay(dropped: bool, aliased: bool, direct: bool, replay: bool) -> Self {
        use std::fs;
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let main = root.join("main");
        let origin = root.join("origin.git");
        let bin = root.join("bin");
        for dir in [&main, &bin, &root.join("trees")] {
            fs::create_dir(dir).unwrap();
        }
        write_executable(&bin.join("gh"), "#!/bin/sh\n[ \"$1 $2\" = 'pr list' ]\n");
        Self::git(&root, &["init", "-q", "--bare", origin.to_str().unwrap()]);
        Self::git(&main, &["init", "-q", "-b", "main"]);
        for args in [
            ["config", "gc.auto", "0"],
            ["config", "maintenance.auto", "false"],
        ] {
            Self::git(&main, &args);
        }
        std::os::unix::fs::symlink(root.join("trees"), root.join("alias")).unwrap();
        let base = if aliased { "../alias" } else { "../trees" };
        let delivery = if direct { "push-base" } else { "pr" };
        fs::write(main.join("kendex.settings.toml"), format!(
            "[env]\nWORKTREE_DEFAULT_BRANCH = \"main\"\nWORKTREE_BASE_DIR = \"{base}\"\nORCH_DELIVERY = \"{delivery}\"\nDEV_VALIDATE_CMD = \"true\"\nDEV_VALIDATE_RANGE_CMD = \"true\"\n"
        )).unwrap();
        fs::write(
            main.join(".gitignore"),
            "tmp/\n.agents\ngh-1-bin/\ngh-1-screen-0.txt\n",
        )
        .unwrap();
        fs::write(
            main.join(".kendex-generated.json"),
            "[\".kendex-generated.json\"]\n",
        )
        .unwrap();
        Self::git(&main, &["add", "."]);
        Self::git(&main, &["commit", "-qm", "base"]);
        Self::git(
            &main,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        Self::git(&main, &["push", "-qu", "origin", "main"]);
        let created = Self::worktree(&main, &bin, &["create", "KEN-1"]);
        assert!(created.status.success(), "{}", stderr(&created));
        let tree = root
            .join(if aliased { "alias" } else { "trees" })
            .join("ken-1");
        let physical = tree.canonicalize().unwrap();
        let agents = Self::skill("../.agents").canonicalize().unwrap();
        for dir in [&tree, &main] {
            std::os::unix::fs::symlink(&agents, dir.join(".agents")).unwrap();
        }
        fs::write(tree.join("feature"), "feature\n").unwrap();
        Self::git(&tree, &["add", "feature"]);
        Self::git(&tree, &["commit", "-qm", "fix(KEN-1): feature"]);
        if direct && !dropped {
            fs::write(tree.join("followup"), "follow-up\n").unwrap();
            Self::git(&tree, &["add", "followup"]);
            Self::git(&tree, &["commit", "-qm", "fix(KEN-1): follow-up"]);
        }
        let original = Self::git(&tree, &["rev-parse", "HEAD"]);
        let file = if dropped { "feature" } else { "base-moved" };
        fs::write(main.join(file), "feature\n").unwrap();
        Self::git(&main, &["add", file]);
        Self::git(&main, &["commit", "-qm", "base advances"]);
        Self::git(&main, &["push", "-q", "origin", "main"]);
        let state = main.join("tmp");
        let item = item_record(&state, "KEN-1");
        fs::write(
            item,
            json!({"issue_id":"KEN-1","worktree":tree,"branch":"ken-1"}).to_string(),
        )
        .unwrap();
        let server = Server::start(&root, "fleet");
        let fleet = Fleet::new(&server);
        let (pane, identity) = redrawing(
            &server,
            &tree,
            "gh-1",
            "codex",
            "› Work on KEN-1\n• Restack finished\n› Ask Codex to do anything\n",
        );
        await_drawn(&server, &pane, "Restack finished");
        let cwd = support::tmux(
            &server.socket,
            &["display-message", "-p", "-t", &pane, "#{pane_current_path}"],
        );
        assert_eq!(
            String::from_utf8(cwd.stdout).unwrap().trim(),
            physical.to_str().unwrap()
        );
        fleet.set_lanes(vec![lane_record(
            "KEN-1",
            "gh-1",
            "codex",
            &server,
            &pane,
            Some(&identity),
            &tree,
        )]);
        fleet.set_overseer(json!({"server_socket":server.socket}));
        let mut fixture = Self {
            _temp: temp,
            main: main.clone(),
            tree,
            bin: bin.clone(),
            state,
            delivery,
            head: String::new(),
            server,
            fleet,
            pane,
        };
        fixture.op(json!({"mode":"check-live-round","landing":true}));
        let out = if replay {
            let paused = Self::worktree(&main, &bin, &["create", "KEN-1", "--restack", "--replay"]);
            assert_eq!(paused.status.code(), Some(1), "{}", stderr(&paused));
            assert!(
                stderr(&paused).contains("worktree-replay-conflicts:"),
                "{}",
                stderr(&paused)
            );
            Self::worktree(&main, &bin, &["restack", "skip", "KEN-1"])
        } else {
            Self::worktree(&main, &bin, &["create", "KEN-1", "--restack"])
        };
        assert!(out.status.success(), "{}", stderr(&out));
        fixture.head = Self::git(&fixture.tree, &["rev-parse", "HEAD"]);
        assert_ne!(fixture.head, original);
        if dropped {
            assert_eq!(
                fixture.head,
                Self::git(&fixture.main, &["rev-parse", "HEAD"])
            );
            assert!(
                stderr(&out)
                    .lines()
                    .any(|line| line == format!("rebase-map: {original} dropped"))
            );
        }
        let markers = fixture.main.join(".git/lane-mail");
        fs::create_dir_all(&markers).unwrap();
        fs::write(markers.join("ken-1"), format!("{}\n", physical.display())).unwrap();
        fs::create_dir_all(fixture.tree.join("tmp/lane-mail/KEN-1")).unwrap();
        fixture
    }

    fn skill(path: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join(path)
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = program("git").args(args).current_dir(dir).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        String::from_utf8(out.stdout).unwrap().trim_end().to_owned()
    }

    fn worktree(main: &Path, bin: &Path, args: &[&str]) -> std::process::Output {
        program(Self::skill("worktree/scripts/worktree"))
            .args(args)
            .env("ORCH_RUNTIME_BINARY", binary())
            .env("PATH", tool_path(&[bin]))
            .current_dir(main)
            .output()
            .unwrap()
    }

    fn op(&self, request: Value) -> Value {
        self.push_result(request, 0)
    }

    fn push_result(&self, mut request: Value, exit: i32) -> Value {
        request["op"] = json!("record-push");
        request["worktree"] = json!(self.tree);
        let out = isolated()
            .args([
                "op",
                "--item",
                "KEN-1",
                "--request-json",
                &request.to_string(),
            ])
            .env("WORKTREE_CLI", Self::skill("worktree/scripts/worktree"))
            .env("ORCH_STATE_DIR", &self.state)
            .env("WORKTREE_DEFAULT_BRANCH", "main")
            .env("ORCH_DELIVERY", self.delivery)
            .env("DEV_VALIDATE_CMD", "true")
            .env("DEV_VALIDATE_RANGE_CMD", "true")
            .env("PATH", tool_path(&[&self.bin]))
            .current_dir(&self.main)
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(exit),
            "{request}: {}{}",
            stderr(&out),
            String::from_utf8_lossy(&out.stdout)
        );
        reply(&out)["result"].clone()
    }

    fn hook(&self, arm: Option<&str>) -> std::process::Output {
        let payload = self.tree.join("tmp/hook-input.json");
        std::fs::write(&payload, r#"{"prompt":"Continue the landing."}"#).unwrap();
        isolated()
            .args(["turn-end", "--hook-dir"])
            .arg(self.tree.join(".codex/hooks"))
            .args(arm)
            .env("ORCH_STATE_DIR", &self.state)
            .env("LANE_MAIL_ITEM", "KEN-1")
            .env("LANE_MAIL_CLI", lane_mail())
            .stdin(std::fs::File::open(payload).unwrap())
            .current_dir(&self.tree)
            .output()
            .unwrap()
    }

    fn held_prompt(&self) {
        let rows = self.tree.join("tmp/lane-mail/KEN-1/session-rows.jsonl");
        let prompt = self.hook(Some("prompt"));
        assert!(prompt.status.success(), "{}", stderr(&prompt));
        self.stop();
        let Reading::Live(row) = lane_rows(&rows) else {
            panic!("prompt row missing");
        };
        assert_eq!(row.event.as_deref(), Some("UserPromptSubmit"));
    }

    fn stop(&self) {
        let out = self.hook(None);
        assert_eq!(
            out.status.code(),
            Some(2),
            "Stop did not hold the guarded landing: {}",
            stderr(&out)
        );
        assert!(
            stderr(&out).contains(&format!(
                "landing-step=restack-before-push head={}",
                self.head
            )),
            "{}",
            stderr(&out)
        );
    }

    fn landing(&self) -> Value {
        let path = item_record(&self.state, "KEN-1");
        serde_json::from_slice::<Value>(&std::fs::read(path).unwrap()).unwrap()["restack_landing"]
            .clone()
    }

    fn mail(&self, args: &[&str]) {
        let out = program(lane_mail())
            .current_dir(&self.tree)
            .args(args)
            .args(["--item", "KEN-1", "--root", self.tree.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(out.status.success(), "mail {args:?}: {}", stderr(&out));
    }

    fn asked(&self, driver: &mut LaneDriver<'_>) -> String {
        for _ in 0..2 {
            let out = driver.pass(&self.fleet.read());
            assert!(out.failed.is_none(), "{:?}", out.failed);
        }
        let row = format!("restack|{}", self.head);
        assert_eq!(
            driver.baseline.get("resume", "restack:KEN-1"),
            Some(row.as_str()),
            "watch did not request the exact restacked head"
        );
        row
    }

    fn wake(&self, driver: &LaneDriver<'_>) {
        let clock = FakeClock::new();
        let tick = orch_runtime::watch::Tick {
            duty: orch_runtime::schedule::Duty::Wake,
            now: clock.now(),
            wall: driver.now,
            baseline: &driver.baseline,
            clock: &clock,
        };
        let out =
            orch_runtime::watch::wake::body(&self.fleet.path(), &driver.settings)(&tick).unwrap();
        assert!(out.failed.is_none(), "{:?}", out.failed);
    }

    fn marks(&self) -> Value {
        let path = orch_runtime::watch::wake::record_path(&self.fleet.path());
        match std::fs::read(path) {
            Ok(raw) => serde_json::from_slice::<Value>(&raw).unwrap()["marks"].clone(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Null,
            Err(e) => panic!("{e}"),
        }
    }

    fn delivery_fake(&self) -> PathBuf {
        let fake = self.bin.join("agent-runtime");
        write_executable(
            &fake,
            format!(
                r#"#!/bin/sh
case " $* " in
  *" --line-digest "*) result='"delivery":"unconfirmed","cause":"turn-unmatched"' ;;
  *" --no-paste "*) result='"delivery":"read","turns":0' ;;
  *)
    while [ "$1" != --line ]; do
      [ "$#" -gt 0 ] || exit 1
      shift
    done
    printf '%s\n' "$2" >>'{log}'
    case "$2" in
      *"restacked head "*) result='"delivery":"unconfirmed","cause":"turn-unmatched"' ;;
      *) result='"delivery":"confirmed","turns_after":1' ;;
    esac
    ;;
esac
printf '{{"ok":true,"result":{{%s}}}}\n' "$result"
"#,
                log = self.bin.join("pastes").display()
            ),
        );
        fake
    }

    fn pastes(&self) -> Vec<String> {
        std::fs::read_to_string(self.bin.join("pastes"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

#[test]
fn guarded_restack_replay_skip_recovers_the_all_dropped_head() {
    if !isolated_row("guarded_restack_replay_skip_recovers_the_all_dropped_head") {
        return;
    }
    let fixture = RestackWatch::with_replay(true, false, false, true);
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
}

#[test]
fn renewed_restack_accepts_the_zero_topic_rebase_and_rejects_a_reset() {
    if !isolated_row("renewed_restack_accepts_the_zero_topic_rebase_and_rejects_a_reset") {
        return;
    }
    let mut fixture = RestackWatch::new(true, false, false);
    let prior = fixture.head.clone();
    fixture.op(json!({"mode":"check-live-round","landing":true}));
    assert_eq!(fixture.landing()["head"], prior);
    let map = PathBuf::from(RestackWatch::git(
        &fixture.tree,
        &["rev-parse", "--absolute-git-dir"],
    ))
    .join("kendex-rebase-map");
    let before = std::fs::read(&map).unwrap();
    RestackWatch::git(
        &fixture.main,
        &["commit", "--allow-empty", "-qm", "base moves again"],
    );
    RestackWatch::git(&fixture.main, &["push", "-q", "origin", "main"]);
    let next = RestackWatch::git(&fixture.main, &["rev-parse", "HEAD"]);
    RestackWatch::git(&fixture.tree, &["reset", "-q", "--hard", &next]);
    assert!(
        !stderr(&fixture.hook(None)).contains("landing-step=restack-before-push"),
        "a reset to the new base must not stand in for guarded restack"
    );
    RestackWatch::git(&fixture.tree, &["reset", "-q", "--hard", &prior]);
    let out = RestackWatch::worktree(
        &fixture.main,
        &fixture.bin,
        &["create", "KEN-1", "--restack"],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(
        std::fs::read(&map).unwrap(),
        before,
        "zero-topic rebase writes no new hop"
    );
    assert_eq!(
        RestackWatch::git(&fixture.tree, &["rev-parse", "HEAD"]),
        next
    );
    fixture.head = next;
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
}

#[test]
fn local_restack_observation_and_delivery_follow_the_exported_state_directory() {
    if !isolated_row("local_restack_observation_and_delivery_follow_the_exported_state_directory") {
        return;
    }
    let mut fixture = RestackWatch::new(false, false, false);
    let state = fixture.fleet.runner.state_dir().to_path_buf();
    std::fs::rename(
        item_record(&fixture.state, "KEN-1"),
        item_record(&state, "KEN-1"),
    )
    .unwrap();
    fixture.state = state;
    fixture.op(json!({"mode":"check-live-round","landing":true}));
    fixture.stop();
    let fake = fixture.delivery_fake();
    lane_driver!(
        fixture.server,
        fixture.fleet,
        readers,
        driver,
        &[
            ("ORCH_AGENT_RUNTIME", fake.to_str().unwrap()),
            ("LANE_MAIL_CLI", lane_mail().to_str().unwrap()),
        ]
    );
    driver.settings.roots.project = fixture.main.clone();
    driver.settings.roots.common = fixture.main.clone();
    fixture.asked(&mut driver);
    fixture.wake(&driver);
    assert_eq!(
        fixture.pastes().len(),
        1,
        "wake reopens the same state used by observation"
    );
    assert!(fixture.pastes()[0].contains(&fixture.head));
}

#[test]
fn restack_after_a_held_stop_keeps_the_open_prompt_eligible() {
    if !isolated_row("restack_after_a_held_stop_keeps_the_open_prompt_eligible") {
        return;
    }
    let fixture = RestackWatch::new(false, false, false);
    fixture.held_prompt();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
}

#[test]
fn restack_delivery_proceeds_past_a_confirmed_provider_row_left_by_held_stop() {
    if !isolated_row("restack_delivery_proceeds_past_a_confirmed_provider_row_left_by_held_stop") {
        return;
    }
    let fixture = RestackWatch::new(false, false, false);
    let fake = fixture.delivery_fake();
    lane_driver!(
        fixture.server,
        fixture.fleet,
        readers,
        driver,
        &[
            ("ORCH_AGENT_RUNTIME", fake.to_str().unwrap()),
            ("LANE_MAIL_CLI", lane_mail().to_str().unwrap()),
        ]
    );
    redraw(
        &fixture.server,
        &fixture.pane,
        &fixture.tree,
        "tmp/api-error.txt",
        CODEX_LIVE_FAILURE,
        "not supported",
    );
    let state = fixture.fleet.read();
    for _ in 0..2 {
        driver.pass(&state);
    }
    let ordinary = driver.baseline.get("resume", "gh-1").unwrap().to_owned();
    assert!(ordinary.starts_with("api-error|"));
    fixture.wake(&driver);
    assert_eq!(fixture.marks()["KEN-1"]["outcome"]["wake"], "delivered");
    redraw(
        &fixture.server,
        &fixture.pane,
        &fixture.tree,
        "tmp/idle.txt",
        "› Resume the orch workflow\n• Restack finished\n› Ask Codex to do anything\n",
        "Restack finished",
    );
    fixture.held_prompt();
    fixture.asked(&mut driver);
    assert_eq!(
        driver.baseline.get("resume", "gh-1"),
        Some(ordinary.as_str())
    );
    fixture.wake(&driver);
    assert_eq!(
        fixture.pastes().len(),
        2,
        "the confirmed ordinary row must let the restack through"
    );
    assert_eq!(
        fixture.marks()["restack:KEN-1"]["outcome"]["wake"],
        "unconfirmed"
    );
}

#[test]
fn direct_prepare_retires_an_all_dropped_restack_already_on_the_base() {
    if !isolated_row("direct_prepare_retires_an_all_dropped_restack_already_on_the_base") {
        return;
    }
    let fixture = RestackWatch::new(true, false, true);
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
    let prepared = fixture.push_result(json!({"mode":"prepare"}), 1);
    assert!(
        prepared["push"]["stderr"]
            .as_str()
            .unwrap()
            .contains("worktree-push-base-empty: ")
    );
    assert!(
        fixture.landing().is_null(),
        "empty direct prepare proves that the landing is integrated"
    );
    assert!(!stderr(&fixture.hook(None)).contains("landing-step=restack-before-push"));
    driver.pass(&fixture.fleet.read());
    assert!(driver.baseline.get("resume", "restack:KEN-1").is_none());
}

#[test]
fn guarded_all_dropped_restack_holds_stop_and_requests_its_final_head() {
    if !isolated_row("guarded_all_dropped_restack_holds_stop_and_requests_its_final_head") {
        return;
    }
    let fixture = RestackWatch::new(true, false, false);
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    let row = fixture.asked(&mut driver);
    let again = driver.pass(&fixture.fleet.read());
    assert!(
        !again
            .changes
            .iter()
            .any(|change| matches!(change, Change::Set {
        kind, identity, value
    } if kind == "resume" && identity == "restack:KEN-1" && value == &row))
    );
}

#[test]
fn guarded_restack_through_a_symlinked_base_requests_the_physical_launchs_head() {
    if !isolated_row("guarded_restack_through_a_symlinked_base_requests_the_physical_launchs_head")
    {
        return;
    }
    let fixture = RestackWatch::new(false, true, false);
    assert_ne!(fixture.tree, fixture.tree.canonicalize().unwrap());
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
}

#[test]
fn restack_request_survives_an_acknowledged_halt_before_delivery() {
    if !isolated_row("restack_request_survives_an_acknowledged_halt_before_delivery") {
        return;
    }
    let fixture = RestackWatch::new(false, false, false);
    let fake = fixture.delivery_fake();
    lane_driver!(
        fixture.server,
        fixture.fleet,
        readers,
        driver,
        &[
            ("ORCH_AGENT_RUNTIME", fake.to_str().unwrap()),
            ("LANE_MAIL_CLI", lane_mail().to_str().unwrap()),
        ]
    );
    driver.halted = |lane| Mailbox::new(lane_mail().to_path_buf()).lane_halted(lane);
    let row = fixture.asked(&mut driver);
    let directive = fixture.tree.join("tmp/directive");
    std::fs::write(&directive, "Hold for a restart.\n").unwrap();
    fixture.mail(&["send", "--halt", "--file", directive.to_str().unwrap()]);
    fixture.mail(&["inbox"]);
    let state = fixture.fleet.read();
    let mailbox = Mailbox::new(lane_mail().to_path_buf());
    assert!(
        mailbox
            .inbox_peek("KEN-1", &fixture.tree)
            .unwrap()
            .unread
            .is_empty()
    );
    assert!(mailbox.lane_halted(&state.lanes[0]).unwrap());
    let idle = driver.pass(&state);
    assert!(idle.failed.is_none(), "{:?}", idle.failed);
    assert_eq!(
        driver.baseline.get("resume", "restack:KEN-1"),
        Some(row.as_str())
    );
    fixture.wake(&driver);
    assert!(fixture.pastes().is_empty());
    assert!(fixture.marks()["restack:KEN-1"].is_null());
    std::fs::write(&directive, "Continue the landing.\n").unwrap();
    fixture.mail(&["send", "--directive", "--file", directive.to_str().unwrap()]);
    assert!(!mailbox.lane_halted(&state.lanes[0]).unwrap());
    fixture.wake(&driver);
    fixture.wake(&driver);
    let pasted = fixture.pastes();
    assert_eq!(pasted.len(), 1, "{pasted:?}");
    assert!(pasted[0].contains(&fixture.head));
    assert_eq!(fixture.marks()["restack:KEN-1"]["resume"], row);
}

#[test]
fn restack_delivery_receipt_survives_ordinary_mail_and_api_retry() {
    if !isolated_row("restack_delivery_receipt_survives_ordinary_mail_and_api_retry") {
        return;
    }
    let fixture = RestackWatch::new(false, false, false);
    let fake = fixture.delivery_fake();
    lane_driver!(
        fixture.server,
        fixture.fleet,
        readers,
        driver,
        &[
            ("ORCH_AGENT_RUNTIME", fake.to_str().unwrap()),
            ("LANE_MAIL_CLI", lane_mail().to_str().unwrap()),
        ]
    );
    fixture.asked(&mut driver);
    fixture.wake(&driver);
    let restack = fixture.marks()["restack:KEN-1"].clone();
    assert_eq!(restack["outcome"]["wake"], "unconfirmed");
    driver.baseline.apply(Change::Set {
        kind: "unread".to_owned(),
        identity: "KEN-1".to_owned(),
        value: "ordinary".to_owned(),
    });
    fixture.wake(&driver);
    assert_eq!(fixture.marks()["KEN-1"]["outcome"]["wake"], "delivered");
    assert_eq!(fixture.marks()["restack:KEN-1"], restack);
    redraw(
        &fixture.server,
        &fixture.pane,
        &fixture.tree,
        "tmp/api-error.txt",
        CODEX_LIVE_FAILURE,
        "not supported",
    );
    let state = fixture.fleet.read();
    for _ in 0..2 {
        driver.pass(&state);
    }
    let api_resume = driver.baseline.get("resume", "gh-1").unwrap().to_owned();
    assert!(api_resume.starts_with("api-error|"));
    fixture.wake(&driver);
    assert_eq!(fixture.marks()["KEN-1"]["resume"], api_resume);
    assert_eq!(fixture.marks()["KEN-1"]["outcome"]["wake"], "delivered");
    assert_eq!(fixture.marks()["restack:KEN-1"], restack);
    fixture.wake(&driver);
    assert_eq!(fixture.pastes().len(), 3);
    redraw(
        &fixture.server,
        &fixture.pane,
        &fixture.tree,
        "tmp/api-recovered.txt",
        "› Resume the orch workflow\n• Work resumed\n› Ask Codex to do anything\n",
        "Work resumed",
    );
    for _ in 0..2 {
        driver.pass(&state);
    }
    assert!(driver.baseline.get("resume", "gh-1").is_none());
    assert_eq!(fixture.marks()["restack:KEN-1"], restack);
}

#[test]
fn direct_prepare_keeps_the_guarded_restack_open_until_confirmed_publication() {
    if !isolated_row("direct_prepare_keeps_the_guarded_restack_open_until_confirmed_publication") {
        return;
    }
    let mut fixture = RestackWatch::new(false, false, true);
    assert!(RestackWatch::git(&fixture.tree, &["status", "--porcelain"]).is_empty());
    let prepared = fixture.op(json!({"mode":"prepare"}));
    let prepared_head = prepared["prepared"]["commit"].as_str().unwrap();
    assert_ne!(
        prepared_head, fixture.head,
        "prepare folded the restacked commits"
    );
    fixture.head = prepared_head.to_owned();
    fixture.stop();
    lane_driver!(fixture.server, fixture.fleet, readers, driver);
    fixture.asked(&mut driver);
    let published = fixture.op(json!({
        "mode":"publish", "base":prepared["prepared"]["before"], "head":fixture.head
    }));
    assert_eq!(published["delivery"]["commit"], fixture.head);
    let path = item_record(&fixture.main.join("tmp"), "KEN-1");
    let doc: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(doc.get("restack_landing").is_none());
    driver.pass(&fixture.fleet.read());
    assert!(driver.baseline.get("resume", "restack:KEN-1").is_none());
}

#[test]
fn a_current_codex_failure_ends_a_working_row_but_scrollback_does_not() {
    if !isolated_row("a_current_codex_failure_ends_a_working_row_but_scrollback_does_not") {
        return;
    }
    use lanes::{Inputs, LaneState};
    let prompt = rows::last_row_in("{\"harness\":\"codex\",\"event\":\"UserPromptSubmit\"}\n");
    let classify = |screen: &str| {
        lanes::classify(&Inputs {
            pane: None,
            process: Some(&ProcessReading::HarnessUp),
            screen: Some(&Ok(screen.to_owned())),
            rows: Some(&prompt),
            harness: Some(Harness::Codex),
            account_room: None,
        })
    };
    assert_eq!(
        classify(CODEX_LIVE_FAILURE),
        LaneState::Idle {
            capacity: false,
            cause: Some("api-error".to_owned())
        }
    );
    assert_eq!(
        classify(&format!(
            "{CODEX_LIVE_FAILURE}\n› Continue the task\n• Working (esc to interrupt)\n"
        )),
        LaneState::Working
    );
    assert_eq!(
        classify(&format!(
            "{CODEX_LIVE_FAILURE}\n› Continue the task\n› Ask Codex to do anything\n"
        )),
        LaneState::Working
    );
    assert_eq!(
        classify("› Work\n▲ Selected model is at capacity\n› Ask Codex to do anything\n"),
        LaneState::Idle {
            capacity: true,
            cause: None
        }
    );
    assert_eq!(
        classify("› Work\n■ A request failed\n• Working (esc to interrupt)\n"),
        LaneState::Working
    );
}

/// The wake's mark for `target` as a delivered resume of the row `resume`
/// leaves it.
fn wake_delivered(fleet: &Fleet, target: &str, resume: &str, at: u64) {
    let path = orch_runtime::watch::wake::record_path(&fleet.path());
    let mut record: Value = std::fs::read(&path)
        .ok()
        .map(|bytes| serde_json::from_slice(&bytes).unwrap())
        .unwrap_or_else(|| json!({"marks": {}}));
    record["marks"][target] = json!({"pane": "%1", "server": 1, "unread": "", "turns_before": 0, "line_digest": 0, "at": at, "outcome": {"wake": "delivered", "turns_after": 1}, "resume": resume});
    std::fs::write(path, record.to_string()).unwrap();
}

fn wake_stamp(fleet: &Fleet, target: &str, at: u64) {
    let path = orch_runtime::watch::wake::record_path(&fleet.path());
    let mut record: Value = std::fs::read(&path)
        .ok()
        .map(|bytes| serde_json::from_slice(&bytes).unwrap())
        .unwrap_or_else(|| json!({"marks": {}}));
    record["marks"][target] = json!({"pane": "%1", "server": 1, "unread": "resume", "turns_before": 0, "line_digest": 0, "at": at, "outcome": {"wake": "delivered", "turns_after": 1}});
    std::fs::write(path, record.to_string()).unwrap();
}

fn identical_codex_failures(hosted: bool) {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let server = Server::start(&dir, "fleet");
    let fleet = Fleet::new(&server);
    let world = HostedWorld::new(&dir, &server, &fleet);
    let pane = if hosted {
        server.open_window("gh-1", &dir, "exec bash --norc --noprofile")
    } else {
        let (pane, identity) = redrawing(&server, &dir, "gh-1", "codex", CODEX_LIVE_FAILURE);
        await_drawn(&server, &pane, "not supported");
        let lane = lane_record(
            "KEN-1",
            "gh-1",
            "codex",
            &server,
            &pane,
            Some(&identity),
            &dir,
        );
        fleet.set_lanes(vec![lane]);
        let file = dir.join("tmp/lane-mail/KEN-1/session-rows.jsonl");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(
            file,
            "{\"harness\":\"codex\",\"event\":\"UserPromptSubmit\",\"at\":1}\n",
        )
        .unwrap();
        pane
    };
    if hosted {
        let mut lane = hosted_lane(&dir, "KEN-1", "gh-1", "/remote/lane");
        lane["harness"] = json!("codex");
        lane["viewer"] = json!(true);
        lane["launch"] = json!({"pane": pane, "server": server.pid});
        fleet.set_lanes(vec![lane]);
        world.plant_host(&[
            ("capabilities", ok(VERB_LINE)),
            ("status --item KEN-1 --harness codex", ok("running\n")),
            ("capture --item KEN-1", ok(CODEX_LIVE_FAILURE)),
        ]);
    }
    let state = fleet.read();
    lane_driver!(server, fleet, readers, driver);
    driver.scripts = world.scripts.clone();
    driver.gh = world.gh();
    for _ in 0..3 {
        assert!(event_lines(&driver.pass(&state)).is_empty());
    }
    assert!(
        driver
            .baseline
            .get("resume", "gh-1")
            .unwrap()
            .starts_with("api-error|")
    );
    let first = driver.baseline.get("resume", "gh-1").unwrap().to_owned();
    wake_stamp(&fleet, "KEN-other", 2);
    assert!(event_lines(&driver.pass(&state)).is_empty());
    assert_eq!(driver.baseline.get("resume", "gh-1"), Some(first.as_str()));
    wake_delivered(&fleet, "KEN-1", &first, 2);
    let events: Vec<String> = (0..3)
        .flat_map(|_| event_lines(&driver.pass(&state)))
        .collect();
    assert_eq!(events, Vec::<String>::new());
    let fresh = driver.baseline.get("resume", "gh-1").unwrap().to_owned();
    assert!(fresh.starts_with("api-error|"), "{fresh}");
    assert_ne!(fresh, first);
    assert!(event_lines(&driver.pass(&state)).is_empty());
    let mark_path = orch_runtime::watch::wake::record_path(&fleet.path());
    std::fs::write(&mark_path, "{").unwrap();
    let unread = driver.pass(&state);
    assert!(
        unread.failed.is_some(),
        "unreadable wake record must not supply an idle key"
    );
    assert!(event_lines(&unread).is_empty());
}

#[test]
fn identical_local_codex_failures_are_resumed_again_after_the_targets_wake() {
    if !isolated_row("identical_local_codex_failures_are_resumed_again_after_the_targets_wake") {
        return;
    }
    identical_codex_failures(false);
}

#[test]
fn identical_hosted_codex_failures_are_resumed_again_after_the_targets_wake() {
    if !isolated_row("identical_hosted_codex_failures_are_resumed_again_after_the_targets_wake") {
        return;
    }
    identical_codex_failures(true);
}

#[test]
fn identical_claude_failures_at_one_second_are_new_rows_without_a_working_pass() {
    if !isolated_row("identical_claude_failures_at_one_second_are_new_rows_without_a_working_pass")
    {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().canonicalize().unwrap();
    let server = Server::start(&dir, "fleet");
    let fleet = Fleet::new(&server);
    let (pane, identity) = redrawing(&server, &dir, "gh-1", "claude", "❯\u{a0}\n");
    await_drawn(&server, &pane, "❯");
    fleet.set_lanes(vec![lane_record(
        "KEN-1",
        "gh-1",
        "claude",
        &server,
        &pane,
        Some(&identity),
        &dir,
    )]);
    let state = fleet.read();
    let file = dir.join("tmp/lane-mail/KEN-1/session-rows.jsonl");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let turn = "{\"harness\":\"claude\",\"event\":\"UserPromptSubmit\",\"at\":1}\n{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"model_not_found\",\"at\":1}\n";
    lane_driver!(server, fleet, readers, driver);
    for n in 1..=2 {
        std::fs::write(&file, turn.repeat(n)).unwrap();
        driver.pass(&state);
        assert_eq!(
            event_lines(&driver.pass(&state)),
            vec!["EVENT idle-after-return gh-1 cause=model_not_found"]
        );
        assert!(event_lines(&driver.pass(&state)).is_empty());
    }
    redraw(
        &server,
        &pane,
        &dir,
        "changed-tail.txt",
        "Second failure details\n❯\u{a0}\n",
        "Second failure details",
    );
    driver.pass(&state);
    assert_eq!(
        event_lines(&driver.pass(&state)),
        vec!["EVENT idle-after-return gh-1 cause=model_not_found"]
    );
}
