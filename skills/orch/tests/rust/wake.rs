//! The wake duty: a lead or lane idle with unread mail is typed one line
//! through agent-runtime's `deliver`, confirmed only by a new user turn in
//! its own bound session file; the mark is in the watch's own record on
//! disk before the paste and a repeat for the same unread state types
//! nothing, whatever the fleet record's writers do to the lane meanwhile; a
//! Codex target and an unreadable pane are never typed into. Each row's
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

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use agent_runtime::process::Identity;
use orch_runtime::error::Error;
use orch_runtime::ops::wake::{WakeMark, WakeOutcome, WakeRecord};
use orch_runtime::schedule::{Clock, Duty};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::FLEET_FILE_NAME;
use orch_runtime::watch::wake::{self, OVERSEER_TARGET, UNREAD_KIND};
use orch_runtime::watch::{self, Baseline, Change, Flags, Paths, Produced, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

/// The agent-runtime binary the duty delivers through, built once from
/// the sibling crate into this suite's own target directory: Cargo builds
/// a dependency's library alone, and no stable artifact dependency names
/// its binary, so the suite asks for it by the same command.
fn agent_runtime() -> &'static Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| {
        let own = binary();
        let profile_dir = own.parent().expect("the binary's directory");
        let target = profile_dir.parent().expect("the target directory");
        let mut args = vec![
            "build",
            "-q",
            "-p",
            "agent-runtime",
            "--bin",
            "agent-runtime",
        ];
        if profile_dir.file_name().is_some_and(|n| n == "release") {
            args.push("--release");
        }
        let out = Command::new(env!("CARGO"))
            .args(&args)
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .env("CARGO_TARGET_DIR", target)
            .output()
            .expect("cargo");
        assert!(
            out.status.success(),
            "building agent-runtime: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let bin = profile_dir.join("agent-runtime");
        assert!(bin.is_file(), "{}", bin.display());
        bin
    })
}

/// The settings a wake in `dir` runs under: the agent-runtime command
/// `agent_runtime`, the two stub harnesses, the mailbox fixture the owner
/// is alerted through (`lane-mail` in `dir`, which logs beside itself) and
/// the mail interval the scheduler's cadence is read from; the paste bound
/// is the production one, and nothing is read from the test's own tree.
fn settings_in(dir: &Path, agent_runtime: &Path) -> Settings {
    let roots = Roots {
        project: dir.to_path_buf(),
        common: dir.to_path_buf(),
    };
    let binaries = format!(
        "claude={},codex={}",
        stub("stub-turns").display(),
        fixtures().join("stub-turns/codex").display()
    );
    settings::load(
        &roots,
        &[
            (
                "ORCH_AGENT_RUNTIME".into(),
                agent_runtime.as_os_str().into(),
            ),
            ("ORCH_HARNESS_BINARIES".into(), binaries.into()),
            (
                "LANE_MAIL_CLI".into(),
                dir.join("lane-mail").as_os_str().into(),
            ),
            ("ORCH_WATCH_MAIL_INTERVAL".into(), "20".into()),
        ],
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

    /// Open-terminal's wake-mode patch on the lane's record
    /// (`open-terminal` `update-report oversee`, mode `wake`): the lane row
    /// gains `{session_id, status, wake, obligation}` from the wake's own
    /// record, `wake` the detached turn's `{pid, start}`, replacing whatever
    /// `wake` object stood.
    fn apply_open_terminal_wake(&self, item: &str, session: &str) {
        let mut fleet = self.read_fleet();
        let lane = fleet["lanes"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|l| l["item"] == item)
            .expect("the lane row");
        let patch = json!({
            "session_id": session,
            "status": "running",
            "wake": {"pid": 4242, "start": "ticks:77"},
            "obligation": Value::Null,
        });
        for (key, value) in patch.as_object().unwrap() {
            lane[key] = value.clone();
        }
        self.write_fleet(&fleet);
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
        );
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
/// Codex controller gets the named limit and nothing typed.
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
    // Codex: the limit, nothing typed.
    {
        let fleet = Fleet::new();
        let typed = fleet.root.join("typed.lines");
        let pane = fleet.open(
            "overseer",
            "codex",
            "lead-c",
            &[("STUB_TURNS_LINES", &typed.display().to_string())],
        );
        fleet.set_overseer(fleet.overseer("codex", &pane));
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
                "EVENT wake-limit overseer harness=codex cause=process-running",
            ]
        );
        assert!(
            !typed.exists(),
            "typed into the Codex pane: {:?}",
            std::fs::read_to_string(&typed)
        );
        assert_eq!(
            fleet.mark(OVERSEER_TARGET).and_then(|m| m.outcome),
            Some(WakeOutcome::Limit {
                harness: "codex".into(),
                cause: "process-running".into()
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
    let mut body = wake::body(&fleet.fleet_file(), &settings_in(&fleet.root, &refusing));
    let state = unread(&[("KEN-1", "m-1")]);
    let refused = run_once(&mut body, &state, &clock).unwrap();
    assert_eq!(rendered(&refused), Vec::<String>::new());
    assert!(count.exists(), "the load was refused");
    assert_eq!(fleet.mark("KEN-1"), None, "nothing typed, no mark stands");
    assert_eq!(fleet.turns("lead-1"), Vec::<String>::new());
    let typed = run_once(&mut body, &state, &clock).unwrap();
    assert_eq!(
        rendered(&typed),
        vec!["EVENT idle-unread KEN-1", "EVENT wake-delivered KEN-1"]
    );
    assert_eq!(fleet.turns("lead-1").len(), 1, "typed once");
}

/// The paste route is unproved on Codex, where a paste would run again over
/// the live history. The lane is read idle, reported `wake-limit`, and
/// nothing reaches its pane.
#[test]
fn a_codex_shaped_lane_reads_wake_limit_and_is_not_typed_into() {
    let fleet = Fleet::new();
    let typed = fleet.root.join("typed.lines");
    let pane = fleet.open(
        "KEN-3",
        "codex",
        "lead-3",
        &[("STUB_TURNS_LINES", &typed.display().to_string())],
    );
    fleet.set_lanes(vec![fleet.lane("KEN-3", "codex", &pane)]);
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let baseline = unread(&[("KEN-3", "m-1")]);
    let produced = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&produced),
        vec![
            "EVENT idle-unread KEN-3",
            "EVENT wake-limit KEN-3 harness=codex cause=process-running",
        ]
    );
    assert!(!typed.exists(), "{:?}", std::fs::read_to_string(&typed));
    let again = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new(), "reported once");
}

/// `open-terminal --wake`, the overseer's route for a Codex lane the duty
/// reported, rewrites the lane's `wake` object from its own record, so the
/// mark lives off the lane record. A Codex lane and a Claude lane are
/// served once; the wake-mode patch lands on both lane rows between the
/// passes; a fresh body (a restarted runner, holding nothing in memory)
/// reads the marks standing and reports and types nothing again.
#[test]
fn an_open_terminal_wake_on_the_lane_record_moves_no_mark_and_nothing_is_reported_or_typed_again() {
    let fleet = Fleet::new();
    let typed = fleet.root.join("typed.lines");
    let codex = fleet.open(
        "KEN-3",
        "codex",
        "lead-3",
        &[("STUB_TURNS_LINES", &typed.display().to_string())],
    );
    let claude = fleet.open("KEN-1", "claude", "lead-1", &[]);
    fleet.server.await_composer(&claude.id);
    fleet.set_lanes(vec![
        fleet.lane("KEN-1", "claude", &claude),
        fleet.lane("KEN-3", "codex", &codex),
    ]);
    let clock = FakeClock::new();
    let baseline = unread(&[("KEN-1", "m-1"), ("KEN-3", "m-1")]);
    let produced = run_once(&mut fleet.body(), &baseline, &clock).unwrap();
    assert_eq!(
        rendered(&produced),
        vec![
            "EVENT idle-unread KEN-1",
            "EVENT wake-delivered KEN-1",
            "EVENT idle-unread KEN-3",
            "EVENT wake-limit KEN-3 harness=codex cause=process-running",
        ]
    );
    assert_eq!(fleet.turns("lead-1").len(), 1);
    fleet.apply_open_terminal_wake("KEN-3", "lead-3");
    fleet.apply_open_terminal_wake("KEN-1", "lead-1");
    assert_eq!(
        fleet.read_fleet()["lanes"][1]["wake"],
        json!({"pid": 4242, "start": "ticks:77"}),
        "open-terminal's wake identity stands on the lane row"
    );
    let again = run_once(&mut fleet.body(), &baseline, &clock).unwrap();
    assert_eq!(rendered(&again), Vec::<String>::new(), "the same state");
    assert_eq!(fleet.turns("lead-1").len(), 1, "typed once");
    assert!(!typed.exists(), "{:?}", std::fs::read_to_string(&typed));
    assert_eq!(
        fleet.mark("KEN-1").and_then(|m| m.outcome),
        Some(WakeOutcome::Delivered { turns_after: 1 })
    );
    assert_eq!(
        fleet.mark("KEN-3").and_then(|m| m.outcome),
        Some(WakeOutcome::Limit {
            harness: "codex".into(),
            cause: "process-running".into()
        })
    );
}

/// A lane whose recorded pane is gone and one whose recorded server the
/// socket does not answer for are never typed into, print nothing and leave
/// no mark.
#[test]
fn a_gone_or_unreadable_pane_is_never_typed_into_and_leaves_no_mark() {
    let fleet = Fleet::new();
    let pane = fleet.open("KEN-2", "claude", "lead-2", &[]);
    fleet.server.await_composer(&pane.id);
    let mut gone = fleet.lane("KEN-1", "claude", &pane);
    gone["launch"]["pane"] = json!("%999");
    let mut unreadable = fleet.lane("KEN-2", "claude", &pane);
    unreadable["launch"]["server"] = json!(fleet.server.pid + 1);
    fleet.set_lanes(vec![gone, unreadable]);
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let baseline = unread(&[("KEN-1", "m-1"), ("KEN-2", "m-1")]);
    let produced = run_once(&mut body, &baseline, &clock).unwrap();
    assert_eq!(rendered(&produced), Vec::<String>::new());
    assert_eq!(fleet.turns("lead-2"), Vec::<String>::new());
    assert_eq!(fleet.mark("KEN-1"), None);
    assert_eq!(fleet.mark("KEN-2"), None);
    assert!(
        std::fs::symlink_metadata(fleet.record_file()).is_err(),
        "a pass that marked nothing wrote no record"
    );
}

/// The idle overseer is the one reader of the log, so mail no wake reaches
/// it with goes to the owner. A Codex overseer with unread mail: pass one
/// says `idle-unread` and `wake-limit`; pass two sends the owner one notice
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
    fleet.set_overseer(fleet.overseer("codex", &pane));
    let clock = FakeClock::new();
    let mut body = fleet.body();
    let first = unread(&[(OVERSEER_TARGET, "m-1")]);
    let told = run_once(&mut body, &first, &clock).unwrap();
    assert_eq!(
        rendered(&told),
        vec![
            "EVENT idle-unread overseer",
            "EVENT wake-limit overseer harness=codex cause=process-running",
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
        notices[0].contains("wake-limit overseer harness=codex cause=process-running")
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
            "EVENT wake-limit overseer harness=codex cause=process-running",
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
        "typed into the Codex pane: {:?}",
        std::fs::read_to_string(&typed)
    );
}
