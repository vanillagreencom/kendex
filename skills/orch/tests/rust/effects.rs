//! Live-effect process tests of the `orch-runtime` executable: each creates
//! its own private tmux server, drives the binary against a stub harness
//! that never launches a real model, and reaps what it started.
//!
//! The stub harnesses are the scripts beside this file, `fixtures/<stub>/
//! claude`: each is named for the harness it stands in for and run by bash
//! directly, so the kernel records the harness's process name for the pane's
//! foreground process, which the judge requires before it reads the pane
//! idle (decision 60). They are selected through the `ORCH_HARNESS_BINARIES`
//! product setting for a custom install path. The tmux server each test
//! makes lives on its own socket under a `TempDir`, reads no configuration
//! file and runs a named pane shell (decision 69); the test ends it with
//! `tmux -S <sock> kill-server` on that socket alone and never signals by
//! name.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tempfile::TempDir;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_orch-runtime"))
}

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("tests/rust/fixtures")
}

/// The stub harness `name` as the executable the runtime launches.
fn stub(name: &str) -> PathBuf {
    fixtures().join(name).join("claude")
}

/// The shell every private server's panes run, resolved once: bash from
/// this process's PATH, else `/bin/sh`. Set explicitly on each server so no
/// user tmux configuration or login shell reaches a row (decision 69).
fn pane_shell() -> &'static str {
    static SHELL: OnceLock<String> = OnceLock::new();
    SHELL.get_or_init(|| {
        std::env::var_os("PATH")
            .and_then(|path| {
                std::env::split_paths(&path)
                    .map(|dir| dir.join("bash"))
                    .find(|p| p.is_file())
            })
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "/bin/sh".to_owned())
    })
}

/// A private tmux server on its own socket with one detached session, ended
/// on drop so a panicking test still reaps it. It reads no configuration
/// file and names its pane shell, so the host's `~/.tmux.conf` and login
/// shell reach no row (decision 69).
struct Server {
    socket: PathBuf,
    session: String,
    pid: u32,
    /// tmux's `start_time`, epoch seconds: with the pid and socket, the
    /// server identity a recorded phase names.
    start: u64,
    /// The server process's start as the runtime's identity reader records
    /// it, which a recorded phase carries beside the tmux start.
    process_start: String,
}

impl Server {
    fn start(dir: &Path, session: &str) -> Server {
        let socket = dir.join("tmux.sock");
        let out = tmux(
            &socket,
            &[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                session,
                "-x",
                "200",
                "-y",
                "50",
                "-c",
                &dir.display().to_string(),
            ],
        );
        assert!(out.status.success(), "new-session: {}", stderr(&out));
        let shell = tmux(
            &socket,
            &["set-option", "-g", "default-shell", pane_shell()],
        );
        assert!(shell.status.success(), "default-shell: {}", stderr(&shell));
        let id = tmux(&socket, &["display-message", "-p", "#{pid} #{start_time}"]);
        let text = String::from_utf8_lossy(&id.stdout);
        let mut parts = text.split_whitespace();
        let pid = parts.next().unwrap().parse().expect("server pid");
        let start = parts.next().unwrap().parse().expect("server start");
        Server {
            socket,
            session: session.to_owned(),
            pid,
            start,
            process_start: start_of(pid),
        }
    }

    fn panes(&self) -> Vec<String> {
        let out = tmux(&self.socket, &["list-panes", "-a", "-F", "#{pane_id}"]);
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Open a window whose shell execs a stub, as a launch's pane stands
    /// once the pane's shell has exec'd the harness, with `home` as the
    /// stub's account home. Returns the pane id.
    fn open_stub(&self, name: &str, stub_name: &str, cwd: &Path, home: &Path) -> String {
        let out = tmux(
            &self.socket,
            &[
                "new-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "-t",
                &format!("={}:", self.session),
                "-n",
                name,
                "-c",
                &cwd.display().to_string(),
                "-e",
                &format!("CLAUDE_CONFIG_DIR={}", home.display()),
                &format!("exec {}", stub(stub_name).display()),
            ],
        );
        assert!(out.status.success(), "new-window: {}", stderr(&out));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// Wait until the pane's shell has exec'd the harness: its process is
    /// named for it. For a stub that draws nothing, where no composer can be
    /// waited for.
    fn await_harness(&self, pane: &str) {
        let pid = self.pane_pid(pane);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
            if comm.trim() == "claude" {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "the harness never replaced the shell"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The pid of the pane's process.
    fn pane_pid(&self, pane: &str) -> u32 {
        let out = tmux(
            &self.socket,
            &["display-message", "-p", "-t", pane, "#{pane_pid}"],
        );
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .expect("pane pid")
    }

    /// Wait until a pane's capture shows the Claude composer marker, bounded.
    fn await_composer(&self, pane: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let cap = tmux(&self.socket, &["capture-pane", "-p", "-t", pane]);
            if String::from_utf8_lossy(&cap.stdout).contains('\u{276f}') {
                return;
            }
            assert!(Instant::now() < deadline, "the composer was never drawn");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // The server's own socket only; never a kill by name.
        let _ = tmux(&self.socket, &["kill-server"]);
    }
}

fn tmux(socket: &Path, args: &[&str]) -> Output {
    Command::new("tmux")
        .arg("-S")
        .arg(socket)
        .args(args)
        .output()
        .expect("tmux")
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

/// A child the test holds and reaps, so a stop test can plant its live pid.
struct Owned(Child);

impl Owned {
    fn sleep() -> Owned {
        Owned(Command::new("sleep").arg("30").spawn().expect("sleep"))
    }
    fn pid(&self) -> u32 {
        self.0.id()
    }
    fn start(&self) -> String {
        start_of(self.pid())
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The start string the runtime records for a live pid, read the way its
/// `process` module reads it so a planted record matches.
fn start_of(pid: u32) -> String {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).expect("stat");
    let after = stat.rsplit_once(')').unwrap().1;
    let field = after.split_whitespace().nth(19).unwrap();
    format!("ticks:{field}")
}

/// Whether a pid names a live, non-zombie process. A process the test owns
/// that a stop ended is a zombie until the test reaps it, and its `/proc`
/// entry still stands, so the stat state decides.
fn live(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => {
            let state = stat
                .rsplit_once(')')
                .and_then(|(_, rest)| rest.split_whitespace().next())
                .and_then(|f| f.chars().next());
            !matches!(state, Some('Z') | Some('X') | None)
        }
        Err(_) => false,
    }
}

/// A pid no process holds here, with a start no process carries: a recorded
/// identity that is confirmed gone.
const GONE_PID: u64 = 2_000_000_000;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// The binary run with the fleet server in `$TMUX`, the session named and a
/// stub selected as `claude`. `verify` bounds the launch wait.
struct Runner {
    dir: TempDir,
    server_socket: PathBuf,
    session: String,
    stub: PathBuf,
    verify: u64,
}

impl Runner {
    fn new(server: &Server, stub_name: &str) -> Runner {
        Runner {
            dir: tempfile::tempdir().unwrap(),
            server_socket: server.socket.clone(),
            session: server.session.clone(),
            stub: stub(stub_name),
            verify: 5,
        }
    }

    fn state_dir(&self) -> &Path {
        self.dir.path()
    }

    fn run(&self, args: &[&str]) -> Output {
        self.run_env(args, &[])
    }

    /// The binary with `extra` environment over the runner's own.
    fn run_env(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = Command::new(binary());
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(args)
            .env("TMUX", format!("{},0,0", self.server_socket.display()))
            .env("ORCH_TMUX_SESSION", &self.session)
            .env(
                "ORCH_HARNESS_BINARIES",
                format!("claude={}", self.stub.display()),
            )
            .env("ORCH_TMUX_VERIFY_SECS", self.verify.to_string())
            // No project settings or private env reach the test's own tree.
            .env("ORCH_STATE_DIR", "")
            .current_dir(self.state_dir());
        for (name, value) in extra {
            command.env(name, value);
        }
        command.output().expect("orch-runtime")
    }

    /// Write `request` to a file and apply it to the fleet state.
    fn op_fleet(&self, request: &Value) -> Output {
        self.op_fleet_env(request, &[])
    }

    fn op_fleet_env(&self, request: &Value, extra: &[(&str, &str)]) -> Output {
        let path = self.state_dir().join("request.json");
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        self.run_env(
            &["op", "--fleet", "--request", &path.display().to_string()],
            extra,
        )
    }

    fn init_fleet(&self) {
        let out = self.run(&["state", "init", "--fleet"]);
        assert!(out.status.success(), "init: {}", stderr(&out));
    }

    /// The fleet state as JSON.
    fn fleet(&self) -> Value {
        let text =
            std::fs::read_to_string(self.state_dir().join("workflow-state-oversee.json")).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    fn write_fleet(&self, value: &Value) {
        std::fs::write(
            self.state_dir().join("workflow-state-oversee.json"),
            serde_json::to_string_pretty(value).unwrap(),
        )
        .unwrap();
    }

    /// The one reconcile report of a fleet with one open intent.
    fn reconcile_one(&self) -> Value {
        let out = self.run(&["reconcile", "--fleet"]);
        let answer = reply(&out);
        assert!(answer["ok"].as_bool().unwrap_or(false), "{}", stderr(&out));
        let reconciled = answer["result"]["reconciled"].as_array().unwrap();
        assert_eq!(reconciled.len(), 1, "one open intent: {reconciled:?}");
        reconciled[0]["report"].clone()
    }

    /// The user turns every Claude-shaped session file under the account
    /// home `home` for `cwd` records, as lines.
    fn stub_turns(&self, home: &Path, cwd: &Path) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(project_dir(home, cwd)) else {
            return Vec::new();
        };
        let mut turns = Vec::new();
        for entry in entries.flatten() {
            turns.extend(file_turns(&entry.path()));
        }
        turns
    }
}

/// Claude Code's project directory for `cwd` under `home`.
fn project_dir(home: &Path, cwd: &Path) -> PathBuf {
    let slug: String = cwd
        .display()
        .to_string()
        .chars()
        .map(|c| if c == '/' || c == '.' { '-' } else { c })
        .collect();
    home.join("projects").join(slug)
}

/// The user turns one Claude-shaped session file records, as lines; none
/// for a file not written.
fn file_turns(file: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(file) else {
        return Vec::new();
    };
    text.lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|row| row["type"] == "user")
        .map(|row| row["message"]["content"].as_str().unwrap().to_owned())
        .collect()
}

/// A Claude-shaped row of a neighbouring lead session for `cwd`: `kind` is
/// `user` for a typed turn, `assistant` for a reply.
fn neighbour_row(kind: &str, cwd: &Path) -> String {
    let content = match kind {
        "user" => json!("a neighbour's turn"),
        _ => json!([{"type": "text", "text": "a neighbour's reply"}]),
    };
    json!({
        "parentUuid": null,
        "isSidechain": false,
        "type": kind,
        "message": {"role": kind, "content": content},
        "sessionId": "neighbour",
        "cwd": cwd.display().to_string(),
    })
    .to_string()
}

/// A neighbouring lead session in the same home and cwd as the runner's,
/// written to throughout a test by a child the test owns, so it is the
/// newest file whenever the runtime looks (R-U19 probes A and B).
struct Neighbour {
    file: PathBuf,
    _writer: Owned,
}

impl Neighbour {
    /// Write `turns` user rows now, then append a `kind` row every 100 ms.
    fn writing(home: &Path, cwd: &Path, turns: usize, kind: &str) -> Neighbour {
        let dir = project_dir(home, cwd);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("neighbour.jsonl");
        let rows: String = (0..turns)
            .map(|_| format!("{}\n", neighbour_row("user", cwd)))
            .collect();
        std::fs::write(&file, rows).unwrap();
        let row = neighbour_row(kind, cwd);
        let script = "while :; do printf '%s\\n' \"$1\" >> \"$2\"; sleep 0.1; done";
        let child = Command::new(pane_shell())
            .args(["-c", script, "neighbour", &row, &file.display().to_string()])
            .spawn()
            .expect("neighbour writer");
        Neighbour {
            file,
            _writer: Owned(child),
        }
    }

    fn user_turns(&self) -> usize {
        file_turns(&self.file).len()
    }

    fn rows(&self) -> usize {
        std::fs::read_to_string(&self.file)
            .map(|t| t.lines().count())
            .unwrap_or(0)
    }
}

fn reply(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            stderr(out)
        )
    })
}

/// The committed outcome transition an `op` that ran an effect returns.
fn effect_report(out: &Output) -> Value {
    let answer = reply(out);
    assert!(
        answer["ok"].as_bool().unwrap_or(false),
        "refused: {}",
        stderr(out)
    );
    answer["result"]["effect"]["report"].clone()
}

fn launch_request(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
        "account": mail_root.display().to_string(),
    })
}

/// The overseer record a succession reads: a predecessor whose harness
/// process is `pid`, on the test's server. `harness_pid` is the string the
/// legacy `ol_record_start` wrote through jq's `--arg` (decision 63).
fn overseer_record(pid: u32, start: &str, server: &Server, cwd: &Path) -> Value {
    json!({
        "runtime": "tmux",
        "generation": 3,
        "server": server.pid.to_string(),
        "server_start": 1,
        "server_socket": server.socket.display().to_string(),
        "pane": "%99",
        "window": "@99",
        "harness_pid": pid.to_string(),
        "harness_start": start,
        "harness": "claude",
        "account": cwd.display().to_string(),
        "home": cwd.display().to_string(),
        "model": "opus",
        "cwd": cwd.display().to_string(),
        "launch_line": "cd /r && claude",
    })
}

fn pending(cwd: &Path) -> Value {
    json!({
        "launch_line": "cd /r && claude --model opus",
        "harness": "claude",
        "account": cwd.display().to_string(),
        "home": cwd.display().to_string(),
        "model": "opus",
        "cwd": cwd.display().to_string(),
    })
}

/// The request json a succession of `overseer_record` builds; the expected
/// set matches that record.
fn transfer_request(server: &Server, cwd: &Path) -> Value {
    json!({
        "op": "request-transfer",
        "expected": {
            "server": server.pid.to_string(),
            "server_start": 1,
            "pane": "%99",
            "generation": 3,
            "launch_line": "cd /r && claude",
            "cwd": cwd.display().to_string(),
            "pending": pending(cwd),
        },
        "successor": pending(cwd),
    })
}

/// Write the overseer record with `predecessor` as its harness process and
/// the successor pending.
fn plant_transfer(runner: &Runner, server: &Server, pid: u32, start: &str) {
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(pid, start, server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
}

/// A recorded phase naming `pane` on the test's server, its session floor
/// `since_ms`, holding `brief` for a succession.
fn phase(word: &str, server: &Server, pane: &str, since_ms: u64, brief: Option<&Path>) -> Value {
    let mut phase = json!({
        "phase": word,
        "pane": pane,
        "server": server.pid,
        "server_start": server.start,
        "server_process_start": server.process_start,
        "socket": server.socket.display().to_string(),
        "since_ms": since_ms,
    });
    if let Some(brief) = brief {
        phase["brief"] = json!(brief.display().to_string());
    }
    phase
}

fn lane(item: &str, status: &str, runner: &Runner, launch: Value) -> Value {
    json!({
        "item": item,
        "harness": "claude",
        "status": status,
        "session_since": "2026-01-29T15:20:00Z",
        "mail_root": runner.state_dir().display().to_string(),
        "account": runner.state_dir().display().to_string(),
        "launch": launch,
    })
}

fn lane_intent(op: &str, item: &str, outcome: &str, phase: Option<Value>) -> Value {
    let mut intent = json!({
        "id": format!("{op}:{item}:1-1"),
        "op": op,
        "target": item,
        "expected_revision": 0,
        "created_at": "2026-01-29T15:20:00Z",
        "outcome": outcome,
        "lane_since": "2026-01-29T15:20:00Z",
    });
    if let Some(phase) = phase {
        intent["phase"] = phase;
    }
    intent
}

fn transfer_intent(phase: Option<Value>, original_pending: Option<Value>) -> Value {
    let mut intent = json!({
        "id": "request-transfer:overseer:3:1-1",
        "op": "request-transfer",
        "target": "overseer:3",
        "expected_revision": 0,
        "created_at": "2026-01-29T15:20:00Z",
        "outcome": "not-started",
    });
    if let Some(phase) = phase {
        intent["phase"] = phase;
    }
    if let Some(original) = original_pending {
        intent["original_pending"] = original;
    }
    intent
}

#[test]
fn a_launch_confirmed_records_the_running_lane_with_its_pane_identity() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-1", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["op"], "record-outcome");
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["lane"]["status"], "running");
    let launch = &report["lane"]["launch"];
    assert!(launch["pane"].as_str().unwrap().starts_with('%'));
    assert_eq!(launch["server"], server.pid);
    // The identity is the pane's foreground process, the stub itself, which
    // the kernel names for the harness (decision 60).
    let pid = launch["pid"].as_u64().expect("the pane process pid") as u32;
    assert_eq!(launch["pane"].as_str().unwrap(), {
        let pane = launch["pane"].as_str().unwrap();
        assert_eq!(server.pane_pid(pane), pid);
        pane
    });
    assert_eq!(
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .unwrap()
            .trim(),
        "claude"
    );
    assert!(launch["start"].as_str().is_some());
    // The lane's `window` is the legacy `session:title` form, the title the
    // item (decision 56); the pane id stays in `launch.pane`.
    assert_eq!(report["lane"]["window"], "fleet:KEN-1");
    // The window the launch opened stands on the server, and the intent
    // recorded it before the wait (decision 62).
    assert!(
        server
            .panes()
            .iter()
            .any(|p| p == launch["pane"].as_str().unwrap())
    );
    let intent = &report["intent"];
    assert_eq!(intent["phase"]["phase"], "window-opened");
    assert_eq!(intent["phase"]["pane"], launch["pane"]);
    assert_eq!(
        intent["phase"]["socket"],
        server.socket.display().to_string()
    );
}

#[test]
fn a_launch_whose_harness_exits_at_once_records_failed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-fail");
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-2", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
}

#[test]
fn a_launch_that_never_draws_its_composer_records_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = 1; // a short injected bound: the stub never settles
    runner.init_fleet();
    let out = runner.op_fleet(&launch_request("KEN-3", runner.state_dir()));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert!(report["intent"]["completed_at"].is_null(), "an open intent");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "preparing",
        "the lane is left preparing"
    );
    // The pane the effect opened is persisted on the lane's `launch` and in
    // the intent's phase, so a reconcile can re-observe it.
    let launch = runner.fleet()["lanes"][0]["launch"].clone();
    assert!(
        launch["pane"].as_str().unwrap().starts_with('%'),
        "the pane is persisted for reconcile"
    );
    assert_eq!(launch["server"], server.pid);
    assert_eq!(report["intent"]["phase"]["pane"], launch["pane"]);
    // A reconcile reads that pane; the stub still never draws, so the launch
    // stays unconfirmed and the intent stays open, with the reading kept.
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(again["intent"]["observation"]["state"]["state"], "unjudged");
}

/// Decision 60, R-U18 high 1: a pane whose screen carries the composer
/// marker while a shell holds its terminal never reads idle, so the launch
/// never confirms; a reconcile reads the same.
#[test]
fn a_pane_whose_foreground_is_a_shell_never_reads_idle_whatever_it_draws() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-shell");
    runner.verify = 1;
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-40", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
    let pane = report["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let screen = tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]);
    assert!(
        String::from_utf8_lossy(&screen.stdout).contains('\u{276f}'),
        "the screen does carry the composer marker"
    );
    let reading = report["intent"]["observation"]["process"]["reading"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        reading == "shells-only" || reading == "foreground-shell",
        "a shell holds the pane: {reading}"
    );
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
}

/// Decision 60, R-U18 P9: a harness that exits before its first draw never
/// confirms, whatever the pane's shell drew while typing the launch line.
#[test]
fn a_launch_whose_harness_dies_before_drawing_never_confirms() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-dying");
    runner.init_fleet();
    for n in 0..12 {
        let item = format!("KEN-D{n}");
        let report = effect_report(&runner.op_fleet(&launch_request(&item, runner.state_dir())));
        assert_eq!(report["intent"]["outcome"], "failed", "{item}");
        assert_eq!(report["lane"]["status"], "stopped", "{item}");
    }
}

#[test]
fn a_stop_ends_the_recorded_identity_and_closes_the_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-4", runner.state_dir())));
    let pid = launched["lane"]["launch"]["pid"].as_u64().unwrap() as u32;
    let pane = launched["lane"]["launch"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(live(pid));
    let out = runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-4"}));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["lane"]["status"], "done");
    // The recorded process is gone and its window is closed.
    assert!(!live(pid), "the harness process is stopped");
    assert!(!server.panes().contains(&pane), "the window is closed");
}

#[test]
fn a_stop_whose_recorded_start_no_longer_matches_records_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    // A live process the test owns, recorded under a start that is not its.
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-5",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    runner.write_fleet(&fleet);
    let out = runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-5"}));
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "running",
        "the lane is left as it stood"
    );
    assert!(live(owned.pid()), "the mismatched process was not killed");
}

/// Decision 64, R-U18 P2d: a close interrupted before its signal leaves an
/// open intent over a live, matching identity. The repeated close reconciles
/// it as a stop still owed and runs that stop.
#[test]
fn a_repeated_close_runs_the_stop_its_reconcile_reads_pending() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-41",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": owned.start()}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-41",
        "not-started",
        None
    )]);
    runner.write_fleet(&fleet);
    let report =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-41"})));
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["lane"]["status"], "done");
    assert!(!live(owned.pid()), "the stop ran on the repeat");
    assert_eq!(
        runner.fleet()["intents"].as_array().unwrap().len(),
        1,
        "no second intent"
    );
}

#[test]
fn a_succession_retires_the_predecessor_then_publishes_the_successor() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let report = effect_report(&runner.op_fleet(&transfer_request(&server, runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(report["generation"], 4);
    assert!(!live(predecessor.pid()), "the predecessor was retired");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    // The published record names the successor's own pane on the server,
    // with the tmux server start and socket, so its watch start keeps it.
    assert_eq!(overseer["server"], server.pid.to_string());
    assert_eq!(overseer["server_start"], server.start);
    assert_eq!(
        overseer["server_socket"],
        server.socket.display().to_string()
    );
    let pane = overseer["pane"].as_str().unwrap().to_owned();
    assert!(pane.starts_with('%'));
    // The successor's identity is the runner's own process, written as the
    // number the runtime writes (decision 63 reads the legacy string).
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert!(overseer["pending"].is_null(), "pending dropped on publish");
    // The intent recorded every phase on its way (decision 62).
    assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
    assert_eq!(report["intent"]["phase"]["pid"], server.pane_pid(&pane));
}

/// Decision 61, R-U18 high 2: the brief is delivered only after retirement
/// and the runner's composer, and the successor is published only once the
/// runner's own session file records that turn.
#[test]
fn a_succession_delivers_the_brief_after_retirement_and_publishes_on_the_runner_s_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF line one\nHANDOFF line two\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["generation"], 4);
    assert!(!live(predecessor.pid()));
    let turns = runner.stub_turns(runner.state_dir(), runner.state_dir());
    assert_eq!(
        turns,
        vec!["HANDOFF line one".to_owned(), "HANDOFF line two".to_owned()],
        "the runner recorded the brief as its turns"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
}

/// Decision 61, R-U18 P12: a runner that lost the pasted brief records no
/// turn, so the succession never publishes it; the runner is kept for a
/// reconcile, which reads the same.
#[test]
fn a_succession_whose_brief_is_lost_never_publishes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-mute");
    runner.verify = 1;
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
    assert_eq!(report["intent"]["phase"]["phase"], "delivered");
    assert!(!live(predecessor.pid()), "retired before delivery");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3, "nothing published");
    let kept = &overseer["pending"]["runner"];
    assert!(kept["pane"].as_str().unwrap().starts_with('%'));
    assert_eq!(kept["socket"], server.socket.display().to_string());
    assert!(
        kept["pid"].as_u64().is_some(),
        "the runner identity is kept"
    );
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
}

/// Decision 61, R-U18 high 4: a precondition read before retirement refuses
/// `failed` with the predecessor in control and no runner left.
#[test]
fn a_succession_whose_preconditions_fail_never_retires() {
    struct Row {
        name: &'static str,
        env: &'static [(&'static str, &'static str)],
        brief: Option<&'static str>,
        cwd: Option<&'static str>,
        note: &'static str,
    }
    let rows = [
        Row {
            name: "missing binary",
            env: &[("ORCH_HARNESS_BINARIES", "claude=/nonexistent/bin/claude")],
            brief: None,
            cwd: None,
            note: "harness-binary-missing",
        },
        Row {
            name: "unreadable brief",
            env: &[],
            brief: Some("/nonexistent/handoff.md"),
            cwd: None,
            note: "brief-unreadable",
        },
        Row {
            name: "missing directory",
            env: &[],
            brief: None,
            cwd: Some("/nonexistent/successor/dir"),
            note: "cwd-missing",
        },
        Row {
            name: "never-drawing successor",
            env: &[("ORCH_HARNESS_BINARIES", "claude=STUB_UNCONFIRMED")],
            brief: None,
            cwd: None,
            note: "successor-not-ready",
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = 1;
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let mut request = transfer_request(&server, runner.state_dir());
        if let Some(cwd) = row.cwd {
            let mut p = pending(runner.state_dir());
            p["cwd"] = json!(cwd);
            let mut fleet = runner.fleet();
            fleet["overseer"]["pending"] = p.clone();
            runner.write_fleet(&fleet);
            request["expected"]["pending"] = p.clone();
            request["successor"] = p;
        }
        if let Some(brief) = row.brief {
            request["brief_file"] = json!(brief);
        }
        let unconfirmed = stub("stub-unconfirmed").display().to_string();
        let env: Vec<(&str, String)> = row
            .env
            .iter()
            .map(|(k, v)| (*k, v.replace("STUB_UNCONFIRMED", &unconfirmed).to_owned()))
            .collect();
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let report = effect_report(&runner.op_fleet_env(&request, &env));
        assert_eq!(report["intent"]["outcome"], "failed", "{}", row.name);
        assert_eq!(
            report["intent"]["observation"]["note"], row.note,
            "{}",
            row.name
        );
        assert_eq!(
            report["intent"]["observation"]["retired"], false,
            "{}",
            row.name
        );
        assert_eq!(
            report["generation"], 3,
            "{}: the predecessor keeps control",
            row.name
        );
        assert!(
            live(predecessor.pid()),
            "{}: the predecessor still runs",
            row.name
        );
        assert_eq!(
            server.panes().len(),
            1,
            "{}: no runner window is left",
            row.name
        );
        assert_eq!(runner.fleet()["overseer"]["generation"], 3, "{}", row.name);
    }
}

#[test]
fn a_succession_that_cannot_retire_the_predecessor_leaves_it_in_control() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    // A recorded start that is not the live process's: the stop reads the
    // identity as stale and never signals it (failure before retirement).
    plant_transfer(&runner, &server, predecessor.pid(), "ticks:1");
    let report = effect_report(&runner.op_fleet(&transfer_request(&server, runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(
        report["intent"]["observation"]["note"],
        "predecessor-not-retired"
    );
    assert_eq!(report["generation"], 3, "the predecessor keeps control");
    assert!(live(predecessor.pid()), "the predecessor still runs");
    // The runner opened at its composer was stopped: the only pane is the
    // server's own.
    assert_eq!(server.panes().len(), 1);
}

#[test]
fn a_succession_whose_predecessor_has_no_recorded_identity_refuses_before_retirement() {
    // An unknown predecessor stop cannot authorize a second controller; the
    // succession refuses before retirement.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    let mut overseer = overseer_record(
        predecessor.pid(),
        &predecessor.start(),
        &server,
        runner.state_dir(),
    );
    overseer.as_object_mut().unwrap().remove("harness_pid");
    overseer.as_object_mut().unwrap().remove("harness_start");
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer;
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
    let report = effect_report(&runner.op_fleet(&transfer_request(&server, runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["generation"], 3);
    assert!(
        live(predecessor.pid()),
        "the predecessor is left in control"
    );
    assert_eq!(server.panes().len(), 1, "no waiting runner was opened");
}

/// Decision 62, R-U18 P13: the effect's process ends after retirement with
/// the runner at its composer and no brief owed; a reconcile completes the
/// succession from the recorded phase and publishes that runner.
#[test]
fn reconcile_publishes_a_runner_recorded_at_the_retired_phase() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    // The predecessor is gone: its recorded identity holds no process.
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    fleet["intents"] = json!([transfer_intent(
        Some(phase("retired", &server, &pane, since, None)),
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert_eq!(overseer["pane"], pane);
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert_eq!(
        overseer["server_socket"],
        server.socket.display().to_string()
    );
}

/// Decision 62, R-U18 P14: the effect's process ends during the launch poll;
/// a reconcile completes the launch from the recorded pane, confirming it
/// with the identity it reads, or failing it once that pane is gone.
#[test]
fn reconcile_completes_a_launch_from_its_recorded_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "KEN-42",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-42", "preparing", &runner, Value::Null)]);
    fleet["intents"] = json!([lane_intent(
        "launch-lane",
        "KEN-42",
        "not-started",
        Some(phase("window-opened", &server, &pane, since, None)),
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = runner.fleet()["lanes"][0].clone();
    assert_eq!(lane["status"], "running");
    assert_eq!(lane["launch"]["pane"], pane);
    assert_eq!(lane["launch"]["pid"], server.pane_pid(&pane));
    assert_eq!(lane["window"], "fleet:KEN-42");
    // The close that follows stops it by that identity and the lane is done,
    // its window closed.
    let closed =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-42"})));
    assert_eq!(closed["intent"]["outcome"], "confirmed");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(server.panes().len(), 1);
}

#[test]
fn reconcile_marks_a_transfer_intent_stale_when_the_generation_moved() {
    // Decision 44: a transfer intent still open after a legacy succession
    // moved the overseer's generation reconciles as intent-stale with the
    // observed generation, never a second controller.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mut fleet = runner.fleet();
    fleet["overseer"] = json!({"runtime": "tmux", "generation": 4, "pane": "%0"});
    fleet["intents"] = json!([transfer_intent(None, None)]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["reconciled"], "intent-stale");
    assert_eq!(report["intent"]["observed_generation"], 4);
    assert_eq!(runner.fleet()["overseer"]["generation"], 4, "unmoved");
}

#[test]
fn two_launch_processes_mint_distinct_intent_ids_on_an_unstamped_file() {
    // R-U10 finding 1 through the binary: each `op` process mints its own
    // stamp, so a relaunch after a close gets a new id, and the file the
    // legacy writers still read stays unstamped.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let first = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    assert_eq!(first["intent"]["outcome"], "confirmed");
    let first_id = first["intent"]["id"].as_str().unwrap().to_owned();
    assert!(first_id.starts_with("launch-lane:KEN-1:"), "{first_id}");
    effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-1"})));
    let second = effect_report(&runner.op_fleet(&launch_request("KEN-1", runner.state_dir())));
    let second_id = second["intent"]["id"].as_str().unwrap().to_owned();
    assert_ne!(second_id, first_id, "a distinct id per process");
    assert_eq!(second["intent"]["outcome"], "confirmed");
    assert!(
        runner.fleet().get("record_version").is_none(),
        "the file stays unstamped"
    );
}

#[test]
fn a_launch_with_no_tmux_session_records_failed() {
    // A refusal the effect knows before any window opens records `failed`,
    // never a bare error that wedges the intent at not-started.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let out = runner.op_fleet_env(
        &launch_request("KEN-10", runner.state_dir()),
        &[("ORCH_TMUX_SESSION", "nosuch")],
    );
    let report = effect_report(&out);
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
    assert_eq!(server.panes().len(), 1, "no window ever opened");
}

#[test]
fn a_launch_whose_harness_exits_during_the_poll_records_failed() {
    // The harness exits while the launch polls its pane; the pane goes, and
    // the launch records `failed`, not an error.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-slow-exit");
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-11", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "failed");
    assert_eq!(report["lane"]["status"], "stopped");
}

#[test]
fn reconcile_close_on_a_start_mismatch_records_unconfirmed() {
    // Decision 59: a live pid whose recorded start no longer matches is an
    // identity change, not gone, so the close stays unconfirmed, not done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-20",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-20",
        "unconfirmed",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["status"],
        "running",
        "the lane is not done"
    );
    assert!(live(owned.pid()), "reconcile starts no effect");
}

#[test]
fn reconcile_close_marks_done_only_when_the_identity_is_confirmed_gone() {
    // Decision 59: a pid no process holds is confirmed gone, so the close
    // completes and the lane reads done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-21",
        "running",
        &runner,
        json!({"pane": "%99", "server": server.pid, "pid": GONE_PID, "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-21",
        "unconfirmed",
        None
    )]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "done");
}

#[test]
fn a_close_stops_the_detached_wake_turn_before_the_lane_reads_done() {
    // The lane's `wake` turn runs outside the pane's process tree, so the
    // close stops it by the identity the record names before the lane reads
    // done.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-30", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "confirmed");
    // A detached turn the test owns, recorded as the lane's `wake`.
    let wake = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"][0]["wake"] = json!({"pid": wake.pid(), "start": wake.start()});
    runner.write_fleet(&fleet);
    assert!(live(wake.pid()));
    let closed =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-30"})));
    assert_eq!(closed["intent"]["outcome"], "confirmed");
    assert_eq!(closed["lane"]["status"], "done");
    assert!(!live(wake.pid()), "the wake turn was stopped");
}

/// Decision 65, R-U19 probe A: a neighbouring lead session in the runner's
/// home and cwd takes user rows throughout the succession while the runner
/// records nothing. Only the runner's own file, the one its fixed session
/// id names, is read, so the succession never publishes.
#[test]
fn a_neighbour_session_s_turns_never_confirm_the_runner_s_delivery() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-mute");
    runner.verify = 2;
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let neighbour = Neighbour::writing(runner.state_dir(), runner.state_dir(), 0, "user");
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
    assert!(
        neighbour.user_turns() >= 2,
        "the neighbour took user rows while the succession waited"
    );
    // The bound file is the runner's own, named by the id the launch fixed,
    // with no turn before the paste.
    let phase = &report["intent"]["phase"];
    assert_eq!(phase["phase"], "delivered");
    let session_id = phase["session_id"].as_str().expect("the fixed session id");
    assert_eq!(phase["session"]["session_id"], session_id);
    let file = phase["session"]["file"].as_str().unwrap();
    assert_eq!(
        Path::new(file),
        project_dir(runner.state_dir(), runner.state_dir()).join(format!("{session_id}.jsonl"))
    );
    assert_eq!(phase["turns_before"], 0);
    assert!(!live(predecessor.pid()), "retired before delivery");
    assert_eq!(
        runner.fleet()["overseer"]["generation"],
        3,
        "nothing published"
    );
    assert!(runner.fleet()["overseer"]["pending"]["runner"].is_object());
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
}

/// Decision 65, R-U19 probe B: a neighbouring lead session holding more
/// turns than the runner is kept the newest file by replies; the runner's
/// recorded turn in its own file still publishes the succession.
#[test]
fn a_neighbour_holding_more_turns_never_hides_the_runner_s_recorded_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let neighbour = Neighbour::writing(runner.state_dir(), runner.state_dir(), 3, "assistant");
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["generation"], 4);
    assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
    let session_id = report["intent"]["phase"]["session_id"]
        .as_str()
        .expect("the fixed session id");
    let own =
        project_dir(runner.state_dir(), runner.state_dir()).join(format!("{session_id}.jsonl"));
    assert_eq!(file_turns(&own), vec!["HANDOFF".to_owned()]);
    assert_eq!(
        neighbour.user_turns(),
        3,
        "the neighbour's turns are its own"
    );
    assert!(neighbour.rows() > 3, "the neighbour was written throughout");
    assert_eq!(runner.fleet()["overseer"]["generation"], 4);
}

/// Decision 66, R-U19 probe C: the private server a launch opened on is
/// killed and another started on the same socket. One socket is held by one
/// server, so the recorded pane is gone: the launch fails on reconcile and
/// the close that follows ends the lane.
#[test]
fn a_launch_whose_server_was_replaced_fails_on_reconcile_and_closes() {
    let dir = tempfile::tempdir().unwrap();
    let first = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&first, "stub-unconfirmed");
    runner.verify = 1;
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet(&launch_request("KEN-C", runner.state_dir())));
    assert_eq!(report["intent"]["outcome"], "unconfirmed");
    let killed = tmux(&first.socket, &["kill-server"]);
    assert!(killed.status.success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while live(first.pid) {
        assert!(Instant::now() < deadline, "the first server never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
    let second = Server::start(dir.path(), "fleet");
    assert_eq!(second.socket, first.socket);
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "failed", "{again}");
    assert_eq!(again["intent"]["observation"]["cause"], "server-replaced");
    assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
    let closed =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-C"})));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(
        second.panes().len(),
        1,
        "nothing opened on the second server"
    );
}

/// Decision 67, R-U18 P1n: a launch whose harness never draws is left
/// unconfirmed, and a close then supersedes it: the launch intent closes
/// `failed` with `superseded-by-close`, the close stops the pane's foreground
/// harness by the identity read then, and the lane is done.
#[test]
fn a_close_supersedes_a_launch_that_never_drew() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = 1;
    runner.init_fleet();
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-P", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "unconfirmed");
    let launch_id = launched["intent"]["id"].as_str().unwrap().to_owned();
    let pane = launched["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let harness_pid = server.pane_pid(&pane);
    assert!(live(harness_pid));
    let closed =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-P"})));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(closed["intent"]["observation"]["stop"], "pane-foreground");
    assert_eq!(
        closed["intent"]["observation"]["process"]["identity"]["pid"],
        harness_pid
    );
    assert!(!live(harness_pid), "the harness in the pane was stopped");
    assert_eq!(server.panes().len(), 1, "the window is closed");
    let intents = runner.fleet()["intents"].as_array().unwrap().clone();
    assert_eq!(intents.len(), 2);
    let launch = intents.iter().find(|i| i["id"] == launch_id).unwrap();
    assert_eq!(launch["outcome"], "failed");
    assert_eq!(launch["observation"]["cause"], "superseded-by-close");
    assert!(launch["completed_at"].is_string());
}

/// R-U20 finding 1: a `stopped` lane recorded under one harness word is
/// relaunched under another and never draws, so the lane keeps its earlier
/// word. The close that supersedes the launch judges the pane's foreground
/// by the harness the launch selected and stops it by identity, never by
/// the lane's earlier word, which would read the harness as foreign and kill
/// the window alone.
#[test]
fn a_superseding_close_stops_the_relaunched_harness_not_the_lane_s_earlier_word() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-unconfirmed");
    runner.verify = 1;
    runner.init_fleet();
    let mut fleet = runner.fleet();
    let mut stopped = lane("KEN-H", "stopped", &runner, Value::Null);
    stopped["harness"] = json!("codex");
    fleet["lanes"] = json!([stopped]);
    runner.write_fleet(&fleet);
    let launched = effect_report(&runner.op_fleet(&launch_request("KEN-H", runner.state_dir())));
    assert_eq!(launched["intent"]["outcome"], "unconfirmed");
    assert_eq!(
        runner.fleet()["lanes"][0]["harness"],
        "codex",
        "the lane keeps its earlier word until a launch confirms"
    );
    let pane = launched["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let harness_pid = server.pane_pid(&pane);
    assert!(live(harness_pid));
    let closed =
        effect_report(&runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-H"})));
    assert_eq!(closed["intent"]["outcome"], "confirmed", "{closed}");
    assert_eq!(closed["lane"]["status"], "done");
    assert_eq!(closed["intent"]["observation"]["stop"], "pane-foreground");
    assert_eq!(
        closed["intent"]["observation"]["process"]["identity"]["pid"],
        harness_pid
    );
    assert!(!live(harness_pid), "the harness in the pane was stopped");
    assert_eq!(server.panes().len(), 1, "the window is closed");
}

/// Decision 68, R-U18 P2b: a close whose recorded pid runs under another
/// start, with no pane recorded. The first reconcile reading is `unconfirmed`
/// with `identity: stale` (decision 59); a second, independent reading
/// confirms the close, and the live process is never signalled.
#[test]
fn a_close_over_a_reused_pid_confirms_on_the_second_independent_reading() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let owned = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane(
        "KEN-R",
        "running",
        &runner,
        json!({"pane": null, "server": null, "pid": owned.pid(), "start": "ticks:1"}),
    )]);
    fleet["intents"] = json!([lane_intent(
        "close-owned-resources",
        "KEN-R",
        "not-started",
        None
    )]);
    runner.write_fleet(&fleet);
    let first = runner.reconcile_one();
    assert_eq!(first["intent"]["outcome"], "unconfirmed", "{first}");
    assert_eq!(first["intent"]["observation"]["identity"], "stale");
    assert_eq!(first["intent"]["observation"]["readings"], 1);
    assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
    let second = runner.reconcile_one();
    assert_eq!(second["intent"]["outcome"], "confirmed", "{second}");
    assert_eq!(second["intent"]["observation"]["identity"], "stale");
    assert_eq!(second["intent"]["observation"]["readings"], 2);
    assert_eq!(runner.fleet()["lanes"][0]["status"], "done");
    assert!(
        live(owned.pid()),
        "the process under the reused pid was never signalled"
    );
}

/// What one matrix cell plants: the fleet state, and what it holds open so
/// the planted processes and panes outlive the reconcile.
struct Planted {
    fleet: Value,
    owned: Vec<Owned>,
}

/// One cell of the reconcile matrix (decision 64): the intent's operation
/// and recorded phase, whether a recorded identity is present, the observed
/// state the row plants, and the outcome the reconcile must record.
struct Cell {
    op: &'static str,
    phase: &'static str,
    identity: &'static str,
    observed: &'static str,
    expect: &'static str,
    plant: fn(&Runner, &Server) -> Planted,
    check: fn(&Runner, &Server, &Value),
}

const ORIGINAL_PENDING: &str =
    r#"{"launch_line": "cd /r && claude --model older", "harness": "claude"}"#;

fn original_pending() -> Value {
    serde_json::from_str(ORIGINAL_PENDING).unwrap()
}

/// The fleet with one lane and one launch or close intent.
fn lane_fleet(
    runner: &Runner,
    op: &str,
    status: &str,
    launch: Value,
    phase: Option<Value>,
) -> Value {
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([lane("KEN-M", status, runner, launch)]);
    fleet["intents"] = json!([lane_intent(op, "KEN-M", "not-started", phase)]);
    fleet
}

/// The fleet with the overseer record naming `predecessor`, the successor
/// pending, and one transfer intent at `phase` holding the original pending.
fn transfer_fleet(
    runner: &Runner,
    server: &Server,
    predecessor: (u32, &str),
    phase: Option<Value>,
) -> Value {
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(predecessor.0, predecessor.1, server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    fleet["intents"] = json!([transfer_intent(phase, Some(original_pending()))]);
    fleet
}

fn no_check(_: &Runner, _: &Server, _: &Value) {}

/// An unanswering socket whose recorded server process still runs: a
/// process the test owns stands for the server (decision 66's one
/// unobservable case).
fn unanswering_server(runner: &Runner, process: &Owned) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: process.pid(),
        start: 1,
        process_start: process.start(),
    }
}

/// An unanswering socket whose recorded server process is gone: the server
/// and every pane it held are gone (decision 66).
fn gone_server(runner: &Runner) -> Server {
    Server {
        socket: runner.state_dir().join("dead.sock"),
        session: "fleet".to_owned(),
        pid: GONE_PID as u32,
        start: 1,
        process_start: "ticks:1".to_owned(),
    }
}

/// A `delivered` phase bound to `file`, the runner's own session file.
fn delivered(server: &Server, pane: &str, since_ms: u64, file: &Path) -> Value {
    let mut phase = phase(
        "delivered",
        server,
        pane,
        since_ms,
        Some(Path::new("/h/handoff.md")),
    );
    phase["turns_before"] = json!(0);
    phase["session"] = json!({
        "session_id": file.file_stem().unwrap().to_str().unwrap(),
        "file": file.display().to_string(),
    });
    phase
}

/// Decision 64: the reconcile matrix over (operation, recorded phase,
/// recorded identity, observed state), one cell per row, each yielding its
/// outcome and none left without one. `retired` is read from the
/// predecessor's identity, an unobservable pane is `unconfirmed`, a failed
/// transfer keeps the original pending, and a confirmed launch binds a
/// session read since its own window opened.
#[test]
fn the_reconcile_matrix_is_total() {
    let cells: Vec<Cell> = vec![
        Cell {
            op: "launch",
            phase: "none",
            identity: "-",
            observed: "nothing opened",
            expect: "failed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(runner, "launch-lane", "preparing", Value::Null, None),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "pane gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-lane",
                    "preparing",
                    Value::Null,
                    Some(phase("window-opened", server, "%77", now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, _| {
                let process = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "launch-lane",
                    "preparing",
                    Value::Null,
                    Some(phase(
                        "window-opened",
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        None,
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["observed"], "unobservable");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "server gone",
            expect: "failed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(
                    runner,
                    "launch-lane",
                    "preparing",
                    Value::Null,
                    Some(phase(
                        "window-opened",
                        &gone_server(runner),
                        "%1",
                        now_ms(),
                        None,
                    )),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["cause"], "server-gone");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "stopped");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "pane present, harness word unknown",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = lane_fleet(
                    runner,
                    "launch-lane",
                    "preparing",
                    Value::Null,
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                fleet["lanes"][0]["harness"] = json!("nosuch");
                fleet["intents"][0]["selection"] = json!({"harness": "nosuch"});
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["cause"], "harness-unknown");
                assert_eq!(report["intent"]["observation"]["observed"], "present");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "shell foreground",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-shell",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing"),
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "harness undrawn",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-unconfirmed",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_harness(&pane);
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["state"]["state"],
                    "unjudged"
                );
                assert_eq!(runner.fleet()["lanes"][0]["status"], "preparing");
            },
        },
        Cell {
            op: "launch",
            phase: "window-opened",
            identity: "-",
            observed: "harness idle",
            expect: "confirmed",
            plant: |runner, server| {
                // A lead session an earlier run left for the cwd, written
                // before the window opened; the floor excludes it.
                let dir = project_dir(runner.state_dir(), runner.state_dir());
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(
                    dir.join("older.jsonl"),
                    format!("{}\n", neighbour_row("user", runner.state_dir())),
                )
                .unwrap();
                std::thread::sleep(Duration::from_millis(20));
                let since = now_ms();
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The stub's first turn, as a lane's brief is: the row that
                // names the session's cwd.
                let own = dir.join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                let typed = tmux(
                    &server.socket,
                    &["send-keys", "-t", &pane, "BRIEF", "Enter"],
                );
                assert!(typed.status.success());
                let deadline = Instant::now() + Duration::from_secs(5);
                while file_turns(&own).is_empty() {
                    assert!(Instant::now() < deadline, "the stub recorded no turn");
                    std::thread::sleep(Duration::from_millis(50));
                }
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "launch-lane",
                        "preparing",
                        Value::Null,
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, _| {
                let lane = runner.fleet()["lanes"][0].clone();
                assert_eq!(lane["status"], "running");
                let pane = lane["launch"]["pane"].as_str().unwrap().to_owned();
                let pid = server.pane_pid(&pane);
                assert_eq!(lane["launch"]["pid"], pid);
                // The session bound is the stub's own, written since the
                // window opened, never the older lead in the same directory.
                assert_eq!(lane["session_id"], format!("stub-{pid}"));
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane gone",
            expect: "confirmed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": null, "start": null}),
                    None,
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "done"),
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane present",
            expect: "unconfirmed",
            plant: |runner, server| {
                let pane = server.open_stub(
                    "KEN-M",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                Planted {
                    fleet: lane_fleet(
                        runner,
                        "close-owned-resources",
                        "running",
                        json!({"pane": pane, "server": server.pid, "pid": null, "start": null}),
                        None,
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["pane"], "present");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "none",
            observed: "pane unrecorded",
            expect: "unconfirmed",
            plant: |runner, _| Planted {
                fleet: lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    Value::Null,
                    None,
                ),
                owned: vec![],
            },
            check: no_check,
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "gone",
            expect: "confirmed",
            plant: |runner, server| Planted {
                fleet: lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": GONE_PID, "start": "ticks:1"}),
                    None,
                ),
                owned: vec![],
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["lanes"][0]["status"], "done"),
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "live, same start",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": owned.pid(), "start": owned.start()}),
                    None,
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["stop"], "pending");
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "close",
            phase: "-",
            identity: "pid+start",
            observed: "live, other start",
            expect: "unconfirmed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = lane_fleet(
                    runner,
                    "close-owned-resources",
                    "running",
                    json!({"pane": "%77", "server": server.pid, "pid": owned.pid(), "start": "ticks:1"}),
                    None,
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["identity"], "stale");
                assert_eq!(report["intent"]["observation"]["readings"], 1);
                assert_eq!(runner.fleet()["lanes"][0]["status"], "running");
            },
        },
        Cell {
            op: "transfer",
            phase: "none",
            identity: "predecessor",
            observed: "predecessor live",
            expect: "failed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let fleet = transfer_fleet(runner, server, (owned.pid(), &owned.start()), None);
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert_eq!(
                    runner.fleet()["overseer"]["pending"],
                    original_pending(),
                    "the original pending is put back"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "none",
            identity: "predecessor",
            observed: "predecessor gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(runner, server, (GONE_PID as u32, "ticks:1"), None),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor",
            observed: "predecessor live, runner present",
            expect: "failed",
            plant: |runner, server| {
                let owned = Owned::sleep();
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (owned.pid(), &owned.start()),
                    Some(phase("window-opened", server, &pane, since, None)),
                );
                Planted {
                    fleet,
                    owned: vec![owned],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["retired"], false);
                assert_eq!(
                    server.panes().len(),
                    1,
                    "the runner was stopped and its window closed"
                );
                assert_eq!(runner.fleet()["overseer"]["pending"], original_pending());
            },
        },
        Cell {
            op: "transfer",
            phase: "window-opened",
            identity: "predecessor gone",
            observed: "runner idle, no brief",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("window-opened", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                let overseer = runner.fleet()["overseer"].clone();
                assert_eq!(overseer["generation"], 4);
                let pane = overseer["pane"].as_str().unwrap().to_owned();
                assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", server, "%77", now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase(
                        "retired",
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        None,
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                let overseer = runner.fleet()["overseer"].clone();
                assert_eq!(overseer["generation"], 3);
                assert_eq!(
                    overseer["pending"]["runner"]["pane"], "%1",
                    "the runner is kept"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "server gone",
            expect: "failed",
            plant: |runner, server| Planted {
                fleet: transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", &gone_server(runner), "%1", now_ms(), None)),
                ),
                owned: vec![],
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(report["intent"]["observation"]["cause"], "server-gone");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner up, not idle, no brief",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-unconfirmed",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_harness(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("retired", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "successor-not-idle"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert!(runner.fleet()["overseer"]["pending"]["runner"].is_object());
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner idle, pending's directory gone",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", server, &pane, since, None)),
                );
                fleet["overseer"]["pending"]["cwd"] = json!("/nonexistent/successor/dir");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "cwd-missing");
                assert_eq!(report["intent"]["observation"]["retired"], true);
                let overseer = runner.fleet()["overseer"].clone();
                assert_eq!(overseer["generation"], 3);
                let kept = overseer["pending"]["runner"]["pane"].as_str().unwrap();
                assert!(
                    server.panes().iter().any(|p| p == kept),
                    "the runner is kept, its pane standing"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner idle, pending missing",
            expect: "failed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(phase("retired", server, &pane, since, None)),
                );
                fleet["overseer"].as_object_mut().unwrap().remove("pending");
                Planted {
                    fleet,
                    owned: vec![],
                }
            },
            check: |runner, server, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pending-missing");
                assert_eq!(report["intent"]["observation"]["runner"], "stopped");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert_eq!(server.panes().len(), 1, "the runner's window is closed");
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner idle, no brief",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("retired", server, &pane, since, None)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, server, _| {
                let overseer = runner.fleet()["overseer"].clone();
                assert_eq!(overseer["generation"], 4);
                let pane = overseer["pane"].as_str().unwrap().to_owned();
                assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner idle, brief held",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let brief = runner.state_dir().join("handoff.md");
                std::fs::write(&brief, "HANDOFF\n").unwrap();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The id the launch fixed, which names the runner's file
                // before it carries a turn (decision 65).
                let mut phase = phase("retired", server, &pane, since, Some(&brief));
                phase["session_id"] = json!(format!("stub-{}", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
                assert_eq!(
                    runner.stub_turns(runner.state_dir(), runner.state_dir()),
                    vec!["HANDOFF".to_owned()]
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 4);
            },
        },
        Cell {
            op: "transfer",
            phase: "retired",
            identity: "predecessor gone",
            observed: "runner not idle, brief held",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let brief = runner.state_dir().join("handoff.md");
                std::fs::write(&brief, "HANDOFF\n").unwrap();
                let pane = server.open_stub(
                    "overseer",
                    "stub-shell",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase("retired", server, &pane, since, Some(&brief))),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(
                    report["intent"]["observation"]["note"],
                    "successor-not-idle"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "no turn recorded",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-mute",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert!(
                    runner.fleet()["overseer"]["pending"]["runner"].is_object(),
                    "the runner is kept"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "a neighbour's turn only",
            expect: "unconfirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-mute",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let neighbour =
                    Neighbour::writing(runner.state_dir(), runner.state_dir(), 1, "user");
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![neighbour._writer],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "brief-unconfirmed");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let fleet = transfer_fleet(
                    runner,
                    server,
                    (GONE_PID as u32, "ticks:1"),
                    Some(delivered(
                        &unanswering_server(runner, &process),
                        "%1",
                        now_ms(),
                        Path::new("/h/projects/-w/0f6e.jsonl"),
                    )),
                );
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
                assert_eq!(
                    runner.fleet()["overseer"]["pending"]["runner"]["pane"],
                    "%1"
                );
            },
        },
        Cell {
            op: "transfer",
            phase: "delivered",
            identity: "predecessor gone",
            observed: "turn recorded",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                // The turn the delivery produced, typed as the paste would be.
                let typed = tmux(
                    &server.socket,
                    &["send-keys", "-t", &pane, "HANDOFF", "Enter"],
                );
                assert!(typed.status.success());
                let deadline = Instant::now() + Duration::from_secs(5);
                let file = project_dir(runner.state_dir(), runner.state_dir())
                    .join(format!("stub-{}.jsonl", server.pane_pid(&pane)));
                while file_turns(&file).is_empty() {
                    assert!(Instant::now() < deadline, "the stub recorded no turn");
                    std::thread::sleep(Duration::from_millis(50));
                }
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(delivered(server, &pane, since, &file)),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(runner.fleet()["overseer"]["generation"], 4);
                assert_eq!(report["intent"]["phase"]["phase"], "identity-read");
            },
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner live",
            observed: "runner present",
            expect: "confirmed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let pid = server.pane_pid(&pane);
                let mut phase = phase("identity-read", server, &pane, since, None);
                phase["pid"] = json!(pid);
                phase["start"] = json!(start_of(pid));
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, _| assert_eq!(runner.fleet()["overseer"]["generation"], 4),
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner live",
            observed: "server unanswering, its process live",
            expect: "unconfirmed",
            plant: |runner, server| {
                let process = Owned::sleep();
                let mut phase = phase(
                    "identity-read",
                    &unanswering_server(runner, &process),
                    "%1",
                    now_ms(),
                    None,
                );
                phase["pid"] = json!(process.pid());
                phase["start"] = json!(process.start());
                let fleet =
                    transfer_fleet(runner, server, (GONE_PID as u32, "ticks:1"), Some(phase));
                Planted {
                    fleet,
                    owned: vec![process],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["note"], "pane-unobservable");
                let kept = runner.fleet()["overseer"]["pending"]["runner"].clone();
                assert_eq!(kept["pane"], "%1");
                assert!(
                    kept["pid"].as_u64().is_some(),
                    "the recorded identity is kept"
                );
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
        Cell {
            op: "transfer",
            phase: "identity-read",
            identity: "runner gone",
            observed: "runner present under another identity",
            expect: "failed",
            plant: |runner, server| {
                let since = now_ms();
                let pane = server.open_stub(
                    "overseer",
                    "stub-confirm",
                    runner.state_dir(),
                    runner.state_dir(),
                );
                server.await_composer(&pane);
                let mut phase = phase("identity-read", server, &pane, since, None);
                phase["pid"] = json!(GONE_PID);
                phase["start"] = json!("ticks:1");
                Planted {
                    fleet: transfer_fleet(
                        runner,
                        server,
                        (GONE_PID as u32, "ticks:1"),
                        Some(phase),
                    ),
                    owned: vec![],
                }
            },
            check: |runner, _, report| {
                assert_eq!(report["intent"]["observation"]["retired"], true);
                assert_eq!(runner.fleet()["overseer"]["generation"], 3);
            },
        },
    ];
    for cell in cells {
        let name = format!(
            "{} / {} / {} / {}",
            cell.op, cell.phase, cell.identity, cell.observed
        );
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = 1;
        runner.init_fleet();
        let planted = (cell.plant)(&runner, &server);
        runner.write_fleet(&planted.fleet);
        let report = runner.reconcile_one();
        assert_eq!(report["intent"]["outcome"], cell.expect, "{name}: {report}");
        (cell.check)(&runner, &server, &report);
        // An intent with a final outcome is closed; an unconfirmed one stays
        // open with its observation for the next reconcile.
        let intent = runner.fleet()["intents"][0].clone();
        assert_eq!(
            intent["completed_at"].is_null(),
            cell.expect == "unconfirmed",
            "{name}"
        );
        assert!(
            intent["observation"].is_object(),
            "{name}: an observation is recorded"
        );
        drop(planted.owned);
    }
}
