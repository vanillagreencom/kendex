//! The wake duty: a lead or lane idle with unread mail is typed one line
//! through agent-runtime's `deliver`, confirmed only by a new user turn in
//! its own bound session file; the mark is in the watch's own record on
//! disk before the paste and a repeat for the same unread state types
//! nothing, whatever the fleet record's writers do to the lane meanwhile; a
//! session no record binds, a pane that is gone, unreadable or mid-turn, a
//! lane on another host or not running, and a lane whose record names a
//! print-mode turn still running are never typed into. Each row's
//! name carries the defect it catches. The stub harnesses are
//! `fixtures/stub-turns/{claude,codex}`. The runner runs on the fake clock;
//! the paste's confirming-turn wait runs in the `deliver` child on the
//! production bound, a bounded poll of the stub's own session file, and the
//! rows' other waits are bounded polls of a stub's own signal.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server and owned children, plant the records they read and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::FLEET_FILE_NAME;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use agent_runtime::accounts::wall::{self as account_wall, AccountWallWrite, WallChannel};
use agent_runtime::clock::Clock;
use agent_runtime::process::Identity;
use agent_runtime::settings::Roots;
use orch_runtime::error::Error;
use orch_runtime::ops::wake::{WakeMark, WakeOutcome, WakeRecord};
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::watch::wake::{self, OVERSEER_TARGET, UNREAD_KIND};
use orch_runtime::watch::{self, Baseline, Change, Flags, Paths, Produced, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

/// The settings a wake in `dir` runs under: the agent-runtime command
/// `agent_runtime`, the two stub harnesses, the mailbox fixture the owner
/// is alerted through (`lane-mail` in `dir`, which logs beside itself) and
/// the mail interval the scheduler's cadence is read from; the paste bound
/// is the production one, and nothing is read from the test's own tree.
fn settings_in(dir: &Path, agent_runtime: &Path) -> Settings {
    settings_with(dir, agent_runtime, &[])
}

/// [`settings_in`] with `extra` over its environment.
fn settings_with(dir: &Path, agent_runtime: &Path, extra: &[(&str, &str)]) -> Settings {
    let roots = Roots {
        project: dir.to_path_buf(),
        common: dir.to_path_buf(),
    };
    let binaries = format!(
        "claude={},codex={}",
        stub("stub-turns").display(),
        fixtures().join("stub-turns/codex").display()
    );
    let mut environment: Vec<(std::ffi::OsString, std::ffi::OsString)> = vec![
        (
            "ORCH_AGENT_RUNTIME".into(),
            agent_runtime.as_os_str().into(),
        ),
        ("AGENT_RUNTIME_HARNESS_BINARIES".into(), binaries.into()),
        (
            "LANE_MAIL_CLI".into(),
            dir.join("lane-mail").as_os_str().into(),
        ),
        ("ORCH_WATCH_MAIL_INTERVAL".into(), "20".into()),
    ];
    environment.extend(extra.iter().map(|(k, v)| ((*k).into(), (*v).into())));
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

fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

fn recorded() -> Recorded {
    Recorded {
        pane: "none".into(),
        script: "/w/orch-runtime".into(),
        cwd: "/w".into(),
    }
}

fn flags() -> Flags {
    Flags {
        interval: secs(240),
        max_loops: 25,
        since: None,
        replace: None,
    }
}

/// One fleet under test: its state directory (canonical, so the records'
/// paths match), a private server, the stubs' account home and work
/// directory, the settings and the record paths. Fields drop in declaration
/// order: the server, whose socket is in the directory, is killed before
/// the directory goes, else the kill finds no socket and the server stands.
struct Fleet {
    server: Server,
    /// Held for its removal at the end of the row.
    _dir: tempfile::TempDir,
    root: PathBuf,
    home: PathBuf,
    cwd: PathBuf,
    settings: Settings,
    paths: Paths,
}

impl Fleet {
    fn new() -> Fleet {
        Fleet::with_agent_runtime(agent_runtime())
    }

    fn with_agent_runtime(agent_runtime: &Path) -> Fleet {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let server = Server::start(&root, "fleet");
        let home = root.join("home");
        let cwd = root.join("work");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&cwd).unwrap();
        // The mailbox fixture under the name the duty runs, logging each
        // call beside that name: no wrapper is written at test time, which
        // another row's child between fork and exec would hold open.
        std::os::unix::fs::symlink(
            fixtures().join("lane-mail-owner/lane-mail"),
            root.join("lane-mail"),
        )
        .unwrap();
        let init = isolated()
            .args(["--state-dir", &root.display().to_string()])
            .args(["state", "init", "--fleet"])
            .current_dir(&root)
            .output()
            .expect("orch-runtime state init");
        assert!(init.status.success(), "init: {}", stderr(&init));
        let settings = settings_in(&root, agent_runtime);
        let paths = Paths::of(&root.join(FLEET_FILE_NAME)).unwrap();
        let fleet = Fleet {
            server,
            _dir: dir,
            root,
            home,
            cwd,
            settings,
            paths,
        };
        // The fleet server's socket, as every registered controller
        // record names it: a lane record names no socket of its own.
        fleet.set_overseer(json!({
            "server_socket": fleet.server.socket.display().to_string(),
        }));
        fleet
    }

    fn fleet_file(&self) -> PathBuf {
        self.root.join(FLEET_FILE_NAME)
    }

    fn read_fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_file()).unwrap()).unwrap()
    }

    fn write_fleet(&self, value: &Value) {
        std::fs::write(
            self.fleet_file(),
            serde_json::to_string_pretty(value).unwrap(),
        )
        .unwrap();
    }

    /// Open a stub harness pane: `stub` is the fixture's file name,
    /// `session` the Claude session id it records under, `env` further
    /// variables the stub reads. Returns the pane id and the harness
    /// identity the pane's process carries.
    fn open(&self, name: &str, stub: &str, session: &str, env: &[(&str, &str)]) -> StubPane {
        let mut words = vec![
            format!("CLAUDE_CONFIG_DIR={}", self.home.display()),
            format!("CODEX_HOME={}", self.home.display()),
        ];
        for (key, value) in env {
            words.push(format!("{key}={value}"));
        }
        let program = fixtures().join("stub-turns").join(stub);
        let command = format!(
            "exec env {} {} --session-id {session}",
            words.join(" "),
            program.display()
        );
        let pane = self.server.open_window(name, &self.cwd, &command);
        // The pane's shell has exec'd the stub once its process is named
        // for the harness.
        let pid = self.server.pane_pid(&pane);
        let deadline = Instant::now() + secs(5);
        loop {
            let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
            if comm.trim() == stub {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the {stub} stub never replaced the shell: {comm}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        let start = start_of(pid);
        StubPane {
            id: pane,
            pid,
            start,
            session: session.to_owned(),
        }
    }

    /// A lane record naming `pane` as its launch, on this fleet's server.
    fn lane(&self, item: &str, harness: &str, pane: &StubPane) -> Value {
        json!({
            "item": item,
            "harness": harness,
            "status": "running",
            "account": self.home.display().to_string(),
            "mail_root": self.cwd.display().to_string(),
            "session_id": pane.session,
            "session_since": "2026-01-29T15:20:00Z",
            "launch": {
                "pane": pane.id,
                "server": self.server.pid,
                "server_start": self.server.start,
                "pid": pane.pid,
                "start": pane.start,
            },
        })
    }

    /// The overseer record naming `pane` as the controller's session, in
    /// the shape the fleet record carries.
    fn overseer(&self, harness: &str, pane: &StubPane) -> Value {
        json!({
            "runtime": "tmux",
            "generation": 3,
            "server": self.server.pid.to_string(),
            "server_start": self.server.start,
            "server_socket": self.server.socket.display().to_string(),
            "pane": pane.id,
            "window": "@1",
            "harness_pid": pane.pid.to_string(),
            "harness_start": pane.start,
            "harness": harness,
            "account": self.home.display().to_string(),
            "home": self.home.display().to_string(),
            "cwd": self.cwd.display().to_string(),
            "session_id": pane.session,
            "launch_line": format!("cd {} && claude", self.cwd.display()),
        })
    }

    fn set_lanes(&self, lanes: Vec<Value>) {
        let mut fleet = self.read_fleet();
        fleet["lanes"] = Value::Array(lanes);
        self.write_fleet(&fleet);
    }

    fn set_overseer(&self, overseer: Value) {
        let mut fleet = self.read_fleet();
        fleet["overseer"] = overseer;
        self.write_fleet(&fleet);
    }

    fn session_file(&self, session: &str) -> PathBuf {
        project_dir(&self.home, &self.cwd).join(format!("{session}.jsonl"))
    }

    fn turns(&self, session: &str) -> Vec<String> {
        file_turns(&self.session_file(session))
    }

    fn record_file(&self) -> PathBuf {
        wake::record_path(&self.fleet_file())
    }

    /// The mark the watch's wake record holds for the target; none where
    /// no record was written.
    fn mark(&self, target: &str) -> Option<WakeMark> {
        let bytes = std::fs::read(self.record_file()).ok()?;
        let record: WakeRecord = serde_json::from_slice(&bytes).expect("the wake record parses");
        record.get(target).cloned()
    }

    fn body(&self) -> watch::Body<'static> {
        wake::body(&self.fleet_file(), &self.settings)
    }

    /// A runner with the wake registered, as `watch run` registers it.
    fn runner<'a>(&self, clock: &'a FakeClock) -> Runner<'a> {
        let mut runner = Runner::new(
            self.paths.clone(),
            clock,
            &self.settings,
            flags(),
            me(),
            recorded(),
        )
        .unwrap();
        wake::register(&mut runner, &self.fleet_file(), &self.settings);
        runner
    }

    fn log_lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.paths.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Every notice the mailbox fixture was asked to send, `to=<to>` and
    /// the notice's words as they stood at the call.
    fn notices(&self) -> Vec<String> {
        std::fs::read_to_string(self.root.join("lane-mail.log"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.strip_prefix("notice to=").map(|l| format!("to={l}")))
            .collect()
    }
}

struct StubPane {
    id: String,
    pid: u32,
    start: String,
    session: String,
}

/// A baseline holding one unread row per `(target, state)`.
fn unread(rows: &[(&str, &str)]) -> Baseline {
    let mut baseline = Baseline::default();
    for (target, state) in rows {
        baseline.apply(Change::Set {
            kind: UNREAD_KIND.into(),
            identity: (*target).to_owned(),
            value: (*state).to_owned(),
        });
    }
    baseline
}

/// Run `body` once on `baseline`, as the runner would at this instant.
fn run_once(
    body: &mut watch::Body<'_>,
    baseline: &Baseline,
    clock: &FakeClock,
) -> Result<Produced, Error> {
    let tick = Tick {
        duty: Duty::Wake,
        now: clock.now(),
        wall: clock.wall_secs(),
        baseline,
        clock,
    };
    body(&tick)
}

fn rendered(produced: &Produced) -> Vec<String> {
    produced.events.iter().map(|e| e.render()).collect()
}

fn state_of(path: &Path) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .trim()
        .to_owned()
}

fn await_state(path: &Path, wanted: &str) {
    let deadline = Instant::now() + secs(5);
    while state_of(path) != wanted {
        assert!(
            Instant::now() < deadline,
            "the stub never read {wanted}: {}",
            state_of(path)
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A test-owned follower on the event log, as `watch-delivery.md` §
/// Repeat watch numbers the lines for the controller session: `tail -F`
/// from line 1, each line prefixed by its number.
struct Follower {
    child: Owned,
    lines: std::sync::mpsc::Receiver<String>,
}

impl Follower {
    fn on(log: &Path) -> Follower {
        let script = "n=1; tail -n +1 -F \"$1\" 2>/dev/null | while IFS= read -r line; do printf '%s: %s\\n' \"$n\" \"$line\"; n=$((n + 1)); done";
        let mut child = Command::new(pane_shell())
            .args(["-c", script, "follow", &log.display().to_string()])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("follower");
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Follower {
            child: Owned(child),
            lines: rx,
        }
    }

    fn next(&self, bound: Duration) -> String {
        self.lines
            .recv_timeout(bound)
            .unwrap_or_else(|_| panic!("the follower printed no line within {bound:?}"))
    }
}

impl Drop for Follower {
    fn drop(&mut self) {
        // The pipeline's tail outlives the shell it was spawned under
        // unless the group goes; the shell is the owned child.
        let _ = Command::new("pkill")
            .args(["-P", &self.child.pid().to_string()])
            .output();
    }
}

/// Lead and subagent files sit in one home and cwd, the subagent's gaining
/// user rows throughout; the lead that records nothing is `unconfirmed`
/// once the production bound elapses in the `deliver` child, the one wait
/// of these rows that runs its length, and only a lead that records the
/// line in its own bound file is `delivered`. A second pass for the same
/// unread state types nothing again.
#[test]
fn a_subagent_s_file_never_confirms_the_lead_s_delivery() {
    let fleet = Fleet::new();
    let sub_dir = project_dir(&fleet.home, &fleet.cwd).join("subagents");
    std::fs::create_dir_all(&sub_dir).unwrap();
    let sub_file = sub_dir.join("agent-x.jsonl");
    let row = neighbour_row("user", &fleet.cwd);
    let script = "while :; do printf '%s\\n' \"$1\" >> \"$2\"; sleep 0.1; done";
    let _writer = Owned(
        Command::new(pane_shell())
            .args([
                "-c",
                script,
                "subagent",
                &row,
                &sub_file.display().to_string(),
            ])
            .spawn()
            .expect("subagent writer"),
    );
    let lost = fleet.open("KEN-1", "claude", "lead-1", &[("STUB_TURNS_DROP", "1")]);
    let keeps = fleet.open("KEN-2", "claude", "lead-2", &[]);
    fleet.server.await_composer(&lost.id);
    fleet.server.await_composer(&keeps.id);
    fleet.set_lanes(vec![
        fleet.lane("KEN-1", "claude", &lost),
        fleet.lane("KEN-2", "claude", &keeps),
    ]);
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let baseline = unread(&[("KEN-1", "m-1"), ("KEN-2", "m-1")]);
    let produced = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&produced),
        vec![
            "EVENT idle-unread KEN-1",
            "EVENT wake-unconfirmed KEN-1 cause=turn-pending",
            "EVENT idle-unread KEN-2",
            "EVENT wake-delivered KEN-2",
        ]
    );
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new());
    let delivered = fleet.turns("lead-2");
    assert_eq!(delivered.len(), 1, "{delivered:?}");
    assert!(
        delivered[0].contains("lane-mail inbox --item KEN-2"),
        "{delivered:?}"
    );
    assert!(
        file_turns(&sub_file).len() >= 2,
        "the subagent wrote throughout"
    );
    assert_eq!(
        fleet.mark("KEN-1").and_then(|m| m.outcome),
        Some(WakeOutcome::Unconfirmed {
            cause: "turn-pending".into()
        })
    );
    assert_eq!(
        fleet.mark("KEN-2").and_then(|m| m.outcome),
        Some(WakeOutcome::Delivered { turns_after: 1 })
    );
    let again = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new(), "the same state");
    assert_eq!(fleet.turns("lead-2").len(), 1, "typed once");
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new());
}

/// A stub controller idle at its composer after its turn, the scheduler
/// live and one unread event: a Claude controller gets one delivery
/// confirmed by its own session file, and a test-owned follower on the log
/// receives the numbered line while the controller's turn still runs; a
/// controller whose record binds no session gets the named limit and
/// nothing typed.
#[test]
fn an_idle_controller_gets_one_confirmed_delivery_or_a_named_limit_and_a_follower_reads_the_line() {
    // Claude: confirmed, the follower reading the line mid-turn.
    {
        let fleet = Fleet::new();
        let state = fleet.root.join("stub.state");
        let hold = fleet.root.join("hold.fifo");
        mkfifo(&hold);
        let pane = fleet.open(
            "overseer",
            "claude",
            "lead-o",
            &[
                ("STUB_TURNS_STATE", &state.display().to_string()),
                ("STUB_TURNS_HOLD", &hold.display().to_string()),
            ],
        );
        fleet.server.await_composer(&pane.id);
        await_state(&state, "idle");
        fleet.set_overseer(fleet.overseer("claude", &pane));
        unread(&[(OVERSEER_TARGET, "m-1")])
            .store(&fleet.paths.baseline)
            .unwrap();
        let follower = Follower::on(&fleet.paths.log);
        let clock = FakeClock::new();
        let identity = me();
        let runner = fleet.runner(&clock);
        let ended = run_driven(runner, &clock, &fleet.paths, &identity, || {
            // The line is typed: the stub's turn starts and holds before
            // it records the turn. The log append alone is never the
            // delivery: nothing reaches the log while no turn is recorded.
            await_state(&state, "working");
            assert!(
                !fleet
                    .log_lines()
                    .iter()
                    .any(|l| l.starts_with("EVENT wake-")),
                "a wake line reached the log before the harness recorded a turn: {:?}",
                fleet.log_lines()
            );
            release_hold(&hold, secs(5), || state_of(&state));
            let first = follower.next(secs(15));
            assert_eq!(first, "1: EVENT idle-unread overseer");
            let second = follower.next(secs(15));
            assert_eq!(second, "2: EVENT wake-delivered overseer");
            // The controller's turn still runs: the line reached the
            // follower during it.
            assert_eq!(state_of(&state), "working");
            assert_eq!(fleet.turns("lead-o").len(), 1);
            release_hold(&hold, secs(5), || state_of(&state));
            await_state(&state, "idle");
            clock.await_sleepers(1);
        })
        .unwrap();
        assert_eq!(ended.events, 2, "{:?}", fleet.log_lines());
        assert_eq!(fleet.turns("lead-o").len(), 1);
        assert_eq!(
            fleet.mark(OVERSEER_TARGET).and_then(|m| m.outcome),
            Some(WakeOutcome::Delivered { turns_after: 1 })
        );
        drop(follower);
        drop(fleet);
    }
    // No session bound: the limit, nothing typed.
    {
        let fleet = Fleet::new();
        let typed = fleet.root.join("typed.lines");
        let pane = fleet.open(
            "overseer",
            "codex",
            "lead-c",
            &[("STUB_TURNS_LINES", &typed.display().to_string())],
        );
        await_codex_composer(&fleet, &pane.id);
        fleet.set_overseer(unbound(fleet.overseer("codex", &pane)));
        unread(&[(OVERSEER_TARGET, "m-1")])
            .store(&fleet.paths.baseline)
            .unwrap();
        let clock = FakeClock::new();
        let identity = me();
        let runner = fleet.runner(&clock);
        run_driven(runner, &clock, &fleet.paths, &identity, || {
            clock.await_sleepers(1);
        })
        .unwrap();
        assert_eq!(
            fleet.log_lines(),
            vec![
                "EVENT idle-unread overseer",
                "EVENT wake-limit overseer harness=codex cause=session-unbound",
            ]
        );
        assert!(
            !typed.exists(),
            "typed into the unbound pane: {:?}",
            std::fs::read_to_string(&typed)
        );
        assert_eq!(
            fleet.mark(OVERSEER_TARGET).and_then(|m| m.outcome),
            Some(WakeOutcome::Limit {
                harness: "codex".into(),
                cause: "session-unbound".into()
            })
        );
    }
}

/// Two unread states twenty seconds apart, signalled through the mail
/// duty's slot on the live scheduler, are two user rows in the stub's own
/// session file, the stub idle between them by its state file.
#[test]
fn two_events_apart_give_two_user_rows_with_the_stub_idle_between() {
    let fleet = Fleet::new();
    let state = fleet.root.join("stub.state");
    let pane = fleet.open(
        "KEN-1",
        "claude",
        "lead-1",
        &[("STUB_TURNS_STATE", &state.display().to_string())],
    );
    fleet.server.await_composer(&pane.id);
    await_state(&state, "idle");
    fleet.set_lanes(vec![fleet.lane("KEN-1", "claude", &pane)]);
    let clock = FakeClock::new();
    let identity = me();
    let mut runner = fleet.runner(&clock);
    // The mail duty's slot: the next unread state the test hands it.
    let next: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let slot = next.clone();
    runner.register(
        Duty::Mail,
        Box::new(move |_: &Tick| {
            let mut produced = Produced::default();
            if let Some(state) = slot.lock().unwrap().take() {
                produced.changes.push(Change::Set {
                    kind: UNREAD_KIND.into(),
                    identity: "KEN-1".into(),
                    value: state,
                });
            }
            Ok(produced)
        }),
    );
    run_driven(runner, &clock, &fleet.paths, &identity, || {
        clock.await_sleepers(2);
        *next.lock().unwrap() = Some("m-1".into());
        clock.pass(secs(20));
        clock.pass(secs(20));
        assert_eq!(fleet.turns("lead-1").len(), 1, "{:?}", fleet.log_lines());
        // The turn is confirmed by the stub's row; it reads idle after it.
        await_state(&state, "idle");
        *next.lock().unwrap() = Some("m-2".into());
        clock.pass(secs(20));
        clock.pass(secs(20));
        assert_eq!(fleet.turns("lead-1").len(), 2, "{:?}", fleet.log_lines());
        await_state(&state, "idle");
    })
    .unwrap();
    let wakes: Vec<String> = fleet
        .log_lines()
        .into_iter()
        .filter(|l| l.starts_with("EVENT wake-") || l.starts_with("EVENT idle-unread"))
        .collect();
    assert_eq!(
        wakes,
        vec![
            "EVENT idle-unread KEN-1",
            "EVENT wake-delivered KEN-1",
            "EVENT idle-unread KEN-1",
            "EVENT wake-delivered KEN-1",
        ]
    );
}

/// A crash between the mark and the paste leaves the mark, never a repeat
/// that types the line again. The paste call dies after the mark is on disk
/// (an agent-runtime that exits without a reply on the paste alone, the
/// real one for the read): the pass fails loud, the mark stands for the
/// unread state, and the repeat for that state types nothing; a later
/// unread state types once.
#[test]
fn a_mark_before_the_paste_pastes_nothing_on_the_repeat_and_a_later_state_pastes_once() {
    let real = agent_runtime();
    let fleet = Fleet::new();
    let crash = fleet.root.join("agent-runtime-crash");
    write_executable(
        &crash,
        format!(
            "#!/bin/bash\ncase \" $* \" in *' --turns-before '*) exit 137 ;; esac\nexec '{}' \"$@\"\n",
            real.display()
        ),
    );
    let pane = fleet.open("KEN-1", "claude", "lead-1", &[]);
    fleet.server.await_composer(&pane.id);
    fleet.set_lanes(vec![fleet.lane("KEN-1", "claude", &pane)]);
    let clock = FakeClock::new();
    let crashing = settings_in(&fleet.root, &crash);
    let mut dying = wake::body(&fleet.fleet_file(), &crashing);
    let mut body = fleet.body();
    let first = unread(&[("KEN-1", "m-1")]);
    let err = run_once(&mut dying, &first, &clock).unwrap_err();
    assert!(err.to_string().contains("no reply"), "{err}");
    let mark = fleet.mark("KEN-1").expect("the mark on disk");
    assert_eq!(mark.unread, "m-1");
    assert_eq!(mark.turns_before, 0);
    assert_eq!(mark.outcome, None);
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new(), "nothing typed");
    // The repeat for the same state: nothing typed, nothing printed.
    let repeat = run_once(&mut body, &first, &clock).unwrap();
    assert_eq!(rendered(&repeat), Vec::<String>::new());
    assert_eq!(
        fleet.turns("lead-1"),
        Vec::<String>::new(),
        "the repeat typed the line again"
    );
    // A later unread state: one paste.
    let later = unread(&[("KEN-1", "m-2")]);
    let produced = run_once(&mut body, &later, &clock).unwrap();
    assert_eq!(
        rendered(&produced),
        vec!["EVENT idle-unread KEN-1", "EVENT wake-delivered KEN-1"]
    );
    assert_eq!(fleet.turns("lead-1").len(), 1);
    let again = run_once(&mut body, &later, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new());
    assert_eq!(fleet.turns("lead-1").len(), 1, "typed once");
}

#[test]
fn a_wake_whose_line_never_reached_the_pane_types_it_on_the_next_pass() {
    let real = agent_runtime();
    let fleet = Fleet::new();
    // The tmux the agent-runtime runs refuses its first load-buffer, before
    // any paste.
    let shims = fleet.root.join("refusing-tmux");
    std::fs::create_dir(&shims).unwrap();
    let count = fleet.root.join("load-count");
    write_executable(
        &shims.join("tmux"),
        format!(
            "#!/bin/bash\nfor arg in \"$@\"; do\n  if [ \"$arg\" = load-buffer ] && [ ! -e '{count}' ]; then\n    : > '{count}'\n    echo refused >&2\n    exit 1\n  fi\ndone\nexec '{tmux}' \"$@\"\n",
            count = count.display(),
            tmux = which_tmux(),
        ),
    );
    let refusing = fleet.root.join("agent-runtime-refusing");
    write_executable(
        &refusing,
        format!(
            "#!/bin/bash\nPATH='{}':\"$PATH\" exec '{}' \"$@\"\n",
            shims.display(),
            real.display()
        ),
    );
    let pane = fleet.open("KEN-1", "claude", "lead-1", &[]);
    fleet.server.await_composer(&pane.id);
    fleet.set_lanes(vec![fleet.lane("KEN-1", "claude", &pane)]);
    let clock = FakeClock::new();
    // The mark an earlier resume left: the refused paste restores it, so
    // the resume it carries is never typed again.
    let standing = WakeMark {
        pane: pane.id.clone(),
        server: u64::from(fleet.server.pid),
        server_start: Some(fleet.server.start),
        unread: "m-0".into(),
        turns_before: 0,
        at: 1,
        outcome: Some(WakeOutcome::Delivered { turns_after: 0 }),
        owner: None,
        resume: Some("usage-limit|1:ticks:1|1".into()),
    };
    let mut record = WakeRecord::default();
    record.set("KEN-1", standing.clone());
    std::fs::write(fleet.record_file(), serde_json::to_vec(&record).unwrap()).unwrap();
    let mut body = wake::body(&fleet.fleet_file(), &settings_in(&fleet.root, &refusing));
    let state = unread(&[("KEN-1", "m-1")]);
    let refused = run_once(&mut body, &state, &clock).unwrap();
    assert_eq!(rendered(&refused), Vec::<String>::new());
    assert!(count.exists(), "the load was refused");
    assert_eq!(
        fleet.mark("KEN-1"),
        Some(standing.clone()),
        "nothing typed, the mark that stood stands"
    );
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new());
    let typed = run_once(&mut body, &state, &clock).unwrap();
    assert_eq!(
        rendered(&typed),
        vec!["EVENT idle-unread KEN-1", "EVENT wake-delivered KEN-1"]
    );
    assert_eq!(fleet.turns("lead-1").len(), 1, "typed once");
    assert_eq!(
        fleet.mark("KEN-1").and_then(|m| m.resume),
        standing.resume,
        "the mail wake's mark carries the resume"
    );
}

/// An idle Codex lane with unread mail is typed the one inbox line and
/// confirmed by a user turn in its own rollout file, once per unread state,
/// with no relaunch; a passed wall on the same lane is one the wake resumes.
#[test]
fn an_idle_codex_lane_is_typed_one_line_confirmed_by_a_user_turn_in_its_own_rollout() {
    let fleet = Fleet::new();
    let pane = fleet.open("KEN-3", "codex", "lead-3", &[]);
    await_codex_composer(&fleet, &pane.id);
    let lane = fleet.lane("KEN-3", "codex", &pane);
    fleet.set_lanes(vec![lane.clone()]);
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let baseline = unread(&[("KEN-3", "m-1")]);
    let produced = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&produced),
        vec!["EVENT idle-unread KEN-3", "EVENT wake-delivered KEN-3"]
    );
    let typed = codex_turns(&fleet.home, "lead-3");
    assert_eq!(typed.len(), 1, "{typed:?}");
    assert!(
        typed[0].starts_with("Run .agents/skills/mailbox/scripts/lane-mail inbox --item KEN-3 "),
        "{typed:?}"
    );
    assert_eq!(
        fleet.mark("KEN-3").and_then(|m| m.outcome),
        Some(WakeOutcome::Delivered { turns_after: 1 })
    );
    let again = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new(), "the same state");
    assert_eq!(codex_turns(&fleet.home, "lead-3").len(), 1, "typed once");
    let lane: orch_runtime::state::Lane = serde_json::from_value(lane).unwrap();
    assert!(wake::resumable(&lane));
}

/// Wait until the Codex stub in `pane` has drawn its composer line.
fn await_codex_composer(fleet: &Fleet, pane: &str) {
    let deadline = Instant::now() + secs(5);
    loop {
        let cap = tmux(&fleet.server.socket, &["capture-pane", "-p", "-t", pane]);
        if String::from_utf8_lossy(&cap.stdout).contains("\u{203a} ") {
            return;
        }
        assert!(Instant::now() < deadline, "the composer was never drawn");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The user turns of the Codex session `session` under `home`, in order:
/// the text of each `event_msg` row completing a `UserMessage` item in the
/// rollout file its id names.
fn codex_turns(home: &Path, session: &str) -> Vec<String> {
    let suffix = format!("-{session}.jsonl");
    let mut files = Vec::new();
    for year in std::fs::read_dir(home.join("sessions")).unwrap() {
        for month in std::fs::read_dir(year.unwrap().path()).unwrap() {
            for day in std::fs::read_dir(month.unwrap().path()).unwrap() {
                for file in std::fs::read_dir(day.unwrap().path()).unwrap() {
                    let path = file.unwrap().path();
                    if path.to_string_lossy().ends_with(&suffix) {
                        files.push(path);
                    }
                }
            }
        }
    }
    assert_eq!(files.len(), 1, "{files:?}");
    std::fs::read_to_string(&files[0])
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap())
        .filter(|row| row["type"] == "event_msg" && row["payload"]["item"]["type"] == "UserMessage")
        .map(|row| {
            row["payload"]["item"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect()
}

/// `overseer` with its session id removed: a record that binds no session.
fn unbound(mut overseer: Value) -> Value {
    overseer.as_object_mut().unwrap().remove("session_id");
    overseer
}

/// The account a row of the local listing measures at `weekly` percent of
/// its weekly window at `now`.
fn account_row(weekly: u64, now: u64) -> Value {
    let reset = agent_runtime::clock::iso_utc(now + 7 * 86_400);
    json!({
        "alias": "aclaude", "harness": "claude", "config_dir": "/accounts/.aclaude",
        "measured_through": "local", "status": "ok", "headroom_pct": 100 - weekly,
        "binding_bucket": "weekly", "binding_resets_at": reset, "wall": weekly,
        "weekly_pct": weekly, "monthly_pct": null, "model_buckets": [],
        "resets": {"weekly": reset, "model": null, "monthly": null},
        "usage_rate_state": "one-sample", "usage_age_s": 0, "claims": 0, "pool": "plan"
    })
}

/// The lanes duty's resume row for a lane whose wall's reset passed: the
/// session stands at its usage banner, so a mail wake is refused there. While
/// its account reads walled nothing is typed or marked; once it reads room
/// the resume sentence and the inbox line are typed past the banner, once,
/// `wake-delivered <item> resume=usage-limit`; the repeat on the standing row
/// types nothing, and a later mail wake types the inbox line alone and keeps
/// the resume in its mark, so the standing row is never typed again.
#[test]
fn a_passed_wall_is_resumed_once_when_its_account_reads_room_and_a_later_mail_wake_types_no_resume()
{
    let mut fleet = Fleet::new();
    let clock = FakeClock::new();
    let now = clock.wall_secs();
    let accounts = fleet.root.join("accounts");
    let account_state = fleet.root.join("account-state");
    let account = accounts.join("home/.aclaude");
    let env = plant_listing(&accounts, &account_state, &[account_row(20, now)], now).env;
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    fleet.settings = settings_with(&fleet.root, agent_runtime(), &env);
    // The account's wall record, its reset a minute ahead: the account
    // reads walled until the clock passes it.
    let banner = "  ⎿ \u{a0}You've hit your weekly limit · resets Oct 4, 2025, 6pm (UTC)";
    account_wall::record_account_wall(
        &account_state,
        &AccountWallWrite {
            config_dir: account.display().to_string(),
            reset: Some(now + 60),
            now,
            first_seen: now,
            banner: banner.to_owned(),
            channel: WallChannel::Pane,
        },
    )
    .unwrap();
    let wall = fleet.root.join("wall.txt");
    std::fs::write(
        &wall,
        format!("⏺ Working through the queue.\n{banner}\nRun /usage-credits to raise it\n"),
    )
    .unwrap();
    let pane = fleet.open(
        "KEN-1",
        "claude",
        "lead-1",
        &[
            ("CLAUDE_CONFIG_DIR", &account.display().to_string()),
            ("STUB_TURNS_WALL", &wall.display().to_string()),
        ],
    );
    fleet.server.await_composer(&pane.id);
    let mut lane = fleet.lane("KEN-1", "claude", &pane);
    lane["account"] = json!(account.display().to_string());
    fleet.set_lanes(vec![lane]);
    let turns = || file_turns(&project_dir(&account, &fleet.cwd).join("lead-1.jsonl"));
    let asked = "usage-limit|1:ticks:1|1759600800";
    let mut baseline = Baseline::default();
    baseline.apply(Change::Set {
        kind: wake::RESUME_KIND.into(),
        identity: "KEN-1".into(),
        value: asked.into(),
    });
    let mut body = fleet.body();
    let walled = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&walled), Vec::<String>::new());
    assert_eq!(turns(), Vec::<String>::new(), "nothing typed into the wall");
    assert_eq!(fleet.mark("KEN-1"), None);
    clock.release(Duration::from_secs(120));
    let resumed = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&resumed),
        vec!["EVENT wake-delivered KEN-1 resume=usage-limit"]
    );
    let typed = turns();
    assert_eq!(typed.len(), 1, "{typed:?}");
    assert!(
        typed[0].starts_with("Resume the orch workflow for KEN-1 from where this session stopped: your last turn ended on its account's usage limit, which has since reset. Run .agents/skills/mailbox/scripts/lane-mail inbox --item KEN-1"),
        "{typed:?}"
    );
    assert_eq!(
        fleet.mark("KEN-1").and_then(|m| m.resume).as_deref(),
        Some(asked)
    );
    let repeat = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&repeat), Vec::<String>::new());
    baseline.apply(Change::Set {
        kind: UNREAD_KIND.into(),
        identity: "KEN-1".into(),
        value: "m-1".into(),
    });
    let mail = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&mail),
        vec!["EVENT idle-unread KEN-1", "EVENT wake-delivered KEN-1"]
    );
    let again = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new());
    assert_eq!(turns().len(), 2, "the resume typed once, the mail once");
}

/// A lane the wake may not type into is typed nothing and marked nothing:
/// its recorded pane gone; its recorded server one the socket does not
/// answer for; its harness mid-turn (the stub holding a line whose echo
/// reads working); its record naming another host; its record not
/// running; and an unread row naming an item no record holds, beside an
/// idle running lane no row names. A fleet state that does not parse then
/// fails the pass loud, never read as a fleet with no lanes.
#[test]
fn a_lane_the_wake_may_not_type_into_is_never_typed_into_and_leaves_no_mark() {
    let fleet = Fleet::new();
    let pane = fleet.open("KEN-2", "claude", "lead-2", &[]);
    let state = fleet.root.join("busy.state");
    let hold = fleet.root.join("busy.fifo");
    mkfifo(&hold);
    let busy = fleet.open(
        "KEN-4",
        "claude",
        "lead-4",
        &[
            ("STUB_TURNS_STATE", &state.display().to_string()),
            ("STUB_TURNS_HOLD", &hold.display().to_string()),
        ],
    );
    let hosted = fleet.open("KEN-5", "claude", "lead-5", &[]);
    let stopped = fleet.open("KEN-6", "claude", "lead-6", &[]);
    let unnamed = fleet.open("KEN-8", "claude", "lead-8", &[]);
    for stub in [&pane, &busy, &hosted, &stopped, &unnamed] {
        fleet.server.await_composer(&stub.id);
    }
    await_state(&state, "idle");
    fleet
        .server
        .send_line(&busy.id, "✻ Thinking… (esc to interrupt)");
    await_state(&state, "working");
    let mut gone = fleet.lane("KEN-1", "claude", &pane);
    gone["launch"]["pane"] = json!("%999");
    let mut unreadable = fleet.lane("KEN-2", "claude", &pane);
    unreadable["launch"]["server"] = json!(fleet.server.pid + 1);
    let mut elsewhere = fleet.lane("KEN-5", "claude", &hosted);
    elsewhere["host"] = json!("/srv/box");
    let mut ended = fleet.lane("KEN-6", "claude", &stopped);
    ended["status"] = json!("stopped");
    fleet.set_lanes(vec![
        fleet.lane("KEN-8", "claude", &unnamed),
        gone,
        unreadable,
        fleet.lane("KEN-4", "claude", &busy),
        elsewhere,
        ended,
    ]);
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let targets = ["KEN-1", "KEN-2", "KEN-4", "KEN-5", "KEN-6", "KEN-7"];
    let rows: Vec<(&str, &str)> = targets.iter().map(|t| (*t, "m-1")).collect();
    let produced = run_once(&mut body, &unread(&rows), &clock).unwrap();
    assert_eq!(rendered(&produced), Vec::<String>::new());
    for session in ["lead-2", "lead-4", "lead-5", "lead-6", "lead-8"] {
        assert_eq!(fleet.turns(session), Vec::<String>::new(), "{session}");
    }
    for target in targets {
        assert_eq!(fleet.mark(target), None, "{target}");
    }
    assert!(
        std::fs::symlink_metadata(fleet.record_file()).is_err(),
        "a pass that marked nothing wrote no record"
    );
    release_hold(&hold, secs(5), || state_of(&state));
    release_hold(&hold, secs(5), || state_of(&state));
    await_state(&state, "idle");
    assert_eq!(fleet.turns("lead-4").len(), 1, "the held line alone");
    // The delivery's bound or the harness programs outside their form fail
    // the pass by key and value before any mark or keystroke.
    for (key, value) in [
        ("AGENT_RUNTIME_TMUX_VERIFY_SECS", "0"),
        ("AGENT_RUNTIME_HARNESS_BINARIES", "claude=bin/claude"),
    ] {
        let settings = settings_with(&fleet.root, agent_runtime(), &[(key, value)]);
        let mut judged = wake::body(&fleet.fleet_file(), &settings);
        let failed = run_once(&mut judged, &unread(&[("KEN-8", "m-1")]), &clock)
            .map(|p| rendered(&p))
            .unwrap_err();
        assert_eq!(failed.key(), "setting-invalid", "{key}: {failed}");
        assert_eq!(
            failed.fields(),
            vec![("key".into(), key.into()), ("value".into(), value.into())],
            "{key}"
        );
        assert_eq!(fleet.mark("KEN-8"), None, "{key}");
    }
    assert_eq!(fleet.turns("lead-8"), Vec::<String>::new());
    std::fs::write(fleet.fleet_file(), "{ not json").unwrap();
    let unparsed = run_once(&mut body, &unread(&[("KEN-8", "m-1")]), &clock);
    assert!(unparsed.is_err(), "{:?}", unparsed.map(|p| rendered(&p)));
    assert_eq!(fleet.turns("lead-8"), Vec::<String>::new());
}

/// The bare `ps -o lstart` start of `pid`, its blanks squeezed, in the C
/// locale and UTC: the form a shell writer records a lane's `wake` in.
fn lstart_of(pid: u32) -> String {
    let out = Command::new("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .output()
        .expect("ps");
    assert!(out.status.success(), "ps: {}", stderr(&out));
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// A lane record naming a detached print-mode turn, `wake {pid, start}` in
/// the bare `lstart` form a shell writer records, holds the lane while that
/// process runs: the pane reads idle beside such a turn, and a paste then
/// would start a second turn on the session. Nothing is typed or marked
/// while it runs; once it has ended the next pass delivers once; a writer
/// rewriting the lane's `wake` meanwhile moves no mark, so a restarted
/// runner types nothing again for the same unread state.
#[test]
fn a_print_mode_turn_the_record_names_holds_the_lane_until_it_ends_and_moves_no_mark() {
    let fleet = Fleet::new();
    let pane = fleet.open("KEN-1", "claude", "lead-1", &[]);
    fleet.server.await_composer(&pane.id);
    let turn = Owned::sleep();
    let mut lane = fleet.lane("KEN-1", "claude", &pane);
    lane["wake"] = json!({"pid": turn.pid(), "start": lstart_of(turn.pid())});
    fleet.set_lanes(vec![lane.clone()]);
    let clock = FakeClock::new();
    let baseline = unread(&[("KEN-1", "m-1")]);
    let held = run_once(&mut fleet.body(), &baseline, &clock).unwrap();
    assert_eq!(rendered(&held), Vec::<String>::new());
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new());
    assert_eq!(fleet.mark("KEN-1"), None);
    drop(turn);
    let woken = run_once(&mut fleet.body(), &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&woken),
        vec!["EVENT idle-unread KEN-1", "EVENT wake-delivered KEN-1"]
    );
    assert_eq!(fleet.turns("lead-1").len(), 1);
    lane["wake"] = json!({"pid": 4242, "start": "Thu Jan 1 00:00:00 1970"});
    fleet.set_lanes(vec![lane]);
    let again = run_once(&mut fleet.body(), &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new(), "the same state");
    assert_eq!(fleet.turns("lead-1").len(), 1, "typed once");
    assert_eq!(
        fleet.mark("KEN-1").and_then(|m| m.outcome),
        Some(WakeOutcome::Delivered { turns_after: 1 })
    );
}

/// The idle overseer is the one reader of the log, so mail no wake reaches
/// it with goes to the owner. An overseer whose record binds no session,
/// with unread mail: pass one says `idle-unread` and `wake-limit` (the
/// verb's `session-unbound`); pass two sends the owner one notice
/// through the overseer mailbox naming the unread envelope and the cause;
/// pass three sends nothing; a restarted runner (a fresh body, holding
/// nothing in memory) sends nothing for the same state; a later unread
/// state is said and alerted once more. Nothing is typed into the pane at
/// any pass.
#[test]
fn an_overseer_the_wake_cannot_wake_is_told_to_the_owner_once_per_unread_state() {
    let fleet = Fleet::new();
    let typed = fleet.root.join("typed.lines");
    let pane = fleet.open(
        "overseer",
        "codex",
        "lead-c",
        &[("STUB_TURNS_LINES", &typed.display().to_string())],
    );
    await_codex_composer(&fleet, &pane.id);
    fleet.set_overseer(unbound(fleet.overseer("codex", &pane)));
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let first = unread(&[(OVERSEER_TARGET, "m-1")]);
    let told = run_once(&mut body, &first, &clock).unwrap();
    assert_eq!(
        rendered(&told),
        vec![
            "EVENT idle-unread overseer",
            "EVENT wake-limit overseer harness=codex cause=session-unbound",
        ]
    );
    assert_eq!(
        fleet.notices(),
        Vec::<String>::new(),
        "the owner is told on the pass after the log"
    );
    let alerted = run_once(&mut body, &first, &clock).unwrap();
    assert_eq!(rendered(&alerted), Vec::<String>::new());
    let notices = fleet.notices();
    assert_eq!(notices.len(), 1, "{notices:?}");
    assert!(notices[0].starts_with("to=owner "), "{notices:?}");
    assert!(
        notices[0].contains("wake-limit overseer harness=codex cause=session-unbound")
            && notices[0].contains("unread=m-1")
            && notices[0].contains(&format!("pane {}", pane.id)),
        "{notices:?}"
    );
    let quiet = run_once(&mut body, &first, &clock).unwrap();
    assert_eq!(rendered(&quiet), Vec::<String>::new());
    assert_eq!(
        fleet.notices().len(),
        1,
        "a second notice for the same unread state: {:?}",
        fleet.notices()
    );
    let mut restarted = fleet.body();
    let again = run_once(&mut restarted, &first, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new());
    assert_eq!(fleet.notices().len(), 1, "alerted again after a restart");
    let later = unread(&[(OVERSEER_TARGET, "m-2")]);
    let said = run_once(&mut restarted, &later, &clock).unwrap();
    assert_eq!(
        rendered(&said),
        vec![
            "EVENT idle-unread overseer",
            "EVENT wake-limit overseer harness=codex cause=session-unbound",
        ]
    );
    assert_eq!(fleet.notices().len(), 1);
    let alerted_again = run_once(&mut restarted, &later, &clock).unwrap();
    assert_eq!(rendered(&alerted_again), Vec::<String>::new());
    let notices = fleet.notices();
    assert_eq!(notices.len(), 2, "{notices:?}");
    assert!(notices[1].contains("unread=m-2"), "{notices:?}");
    assert!(
        !typed.exists(),
        "typed into the unbound pane: {:?}",
        std::fs::read_to_string(&typed)
    );
}

/// A running watch whose agent-runtime answers setup-required in the middle
/// of the wake's pass (its wrapper finding the key unbuilt, as while an
/// update builds it) fails that step and runs on: the claim stands, the log
/// says `watch-step-failed step=wake`, the failure's cause names orch's
/// setup, nothing is typed, and the first pass after the build delivers.
/// The world is the row's own: its private server, its mailbox fixture,
/// its claim.
#[test]
fn a_running_watch_whose_agent_runtime_answers_setup_required_fails_the_step_and_delivers_after_the_build()
 {
    let real = agent_runtime();
    let tools = tempfile::tempdir().unwrap();
    let unbuilt = tools.path().join("unbuilt");
    let calls = tools.path().join("calls");
    let helper = tools.path().join("agent-runtime");
    write_executable(
        &helper,
        format!(
            "#!/bin/bash\nif [ -e '{unbuilt}' ]; then\n  printf '%s\\n' \"$1\" >> '{calls}'\n  printf 'agent-runtime: setup-required key=k run=/elsewhere/setup\\n' >&2\n  exit 69\nfi\nexec '{real}' \"$@\"\n",
            unbuilt = unbuilt.display(),
            calls = calls.display(),
            real = real.display(),
        ),
    );
    std::fs::write(&unbuilt, "").unwrap();
    let fleet = Fleet::with_agent_runtime(&helper);
    let pane = fleet.open("KEN-1", "claude", "lead-1", &[]);
    fleet.server.await_composer(&pane.id);
    fleet.set_lanes(vec![fleet.lane("KEN-1", "claude", &pane)]);
    let state = unread(&[("KEN-1", "m-1")]);
    let clock = FakeClock::new();
    // The cause the runner writes under the step's line on its stderr.
    let err = run_once(&mut fleet.body(), &state, &clock).unwrap_err();
    assert_eq!(
        orch_runtime::protocol::diagnostic_line(&err),
        format!(
            "orch-runtime: unready duty=watch program=agent-runtime cause=unbuilt fix={}",
            fleet
                .settings
                .roots
                .project
                .join(".agents/skills/orch/scripts/setup")
                .display()
        )
    );
    state.store(&fleet.paths.baseline).unwrap();
    let identity = me();
    let runner = fleet.runner(&clock);
    let failed = "EVENT watch-step-failed step=wake count=1";
    let ended = run_driven(runner, &clock, &fleet.paths, &identity, || {
        // The first pass ran against the unbuilt key and the loop sleeps.
        clock.await_sleepers(1);
        assert_eq!(fleet.log_lines(), vec![failed]);
        assert!(
            watch::claim::names_runner(&fleet.paths, &identity).unwrap(),
            "the claim stands"
        );
        assert_eq!(fleet.turns("lead-1"), Vec::<String>::new(), "nothing typed");
        // The build ends: the next pass, one mail cadence on, delivers.
        std::fs::remove_file(&unbuilt).unwrap();
        clock.pass(secs(20));
        assert_eq!(fleet.turns("lead-1").len(), 1, "{:?}", fleet.log_lines());
    });
    ended.expect("the watch ran until its stop");
    assert_eq!(
        fleet.log_lines(),
        vec![
            failed,
            "EVENT idle-unread KEN-1",
            "EVENT wake-delivered KEN-1"
        ]
    );
    assert_eq!(
        std::fs::read_to_string(&calls).unwrap().lines().count(),
        2,
        "asked once by the body alone and once by the run's first pass"
    );
}
