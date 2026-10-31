//! The fakes the live-effect suites of the `orch-runtime` executable share:
//! a private tmux server, a child the test owns, the binary run with that
//! server in `$TMUX` and a stub harness selected, the request builders and
//! the planted records. Each suite is a `[[test]]` target of its own, so this
//! module is included by path; what one suite leaves unused is dead to it.
#![allow(
    dead_code,
    reason = "each suite includes this module by path and uses a subset of its fakes"
)]
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and read them directly"
)]

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

pub fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_orch-runtime"))
}

pub fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("tests/rust/fixtures")
}

/// The stub harness `name` as the executable the runtime launches.
pub fn stub(name: &str) -> PathBuf {
    fixtures().join(name).join("claude")
}

/// The shell every private server's panes run, resolved once: bash from
/// this process's PATH, else `/bin/sh`. Set explicitly on each server so no
/// user tmux configuration or login shell reaches a row (decision 69).
pub fn pane_shell() -> &'static str {
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
pub struct Server {
    pub socket: PathBuf,
    pub session: String,
    pub pid: u32,
    /// tmux's `start_time`, epoch seconds: with the pid and socket, the
    /// server identity a recorded phase names.
    pub start: u64,
    /// The server process's start as the runtime's identity reader records
    /// it, which a recorded phase carries beside the tmux start.
    pub process_start: String,
}

impl Server {
    pub fn start(dir: &Path, session: &str) -> Server {
        Server::start_with_config(dir, session, Path::new("/dev/null"))
    }

    /// A server reading `config` as its configuration file: the one way a
    /// row plants a hook on the server before any window opens.
    pub fn start_with_config(dir: &Path, session: &str, config: &Path) -> Server {
        let socket = dir.join("tmux.sock");
        let out = tmux(
            &socket,
            &[
                "-f",
                &config.display().to_string(),
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

    pub fn panes(&self) -> Vec<String> {
        let out = tmux(&self.socket, &["list-panes", "-a", "-F", "#{pane_id}"]);
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Open a window running `command` in `cwd`, as a window something other
    /// than the runtime opened. Returns the pane id.
    pub fn open_window(&self, name: &str, cwd: &Path, command: &str) -> String {
        let target = format!("={}:", self.session);
        let cwd = cwd.display().to_string();
        let out = tmux(
            &self.socket,
            &[
                "new-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "-t",
                &target,
                "-n",
                name,
                "-c",
                &cwd,
                command,
            ],
        );
        assert!(out.status.success(), "new-window: {}", stderr(&out));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// Open a window whose shell execs a stub, as a launch's pane stands
    /// once the pane's shell has exec'd the harness, with `home` as the
    /// stub's account home. Returns the pane id.
    pub fn open_stub(&self, name: &str, stub_name: &str, cwd: &Path, home: &Path) -> String {
        self.open_window(
            name,
            cwd,
            &format!(
                "exec env CLAUDE_CONFIG_DIR={} {}",
                home.display(),
                stub(stub_name).display()
            ),
        )
    }

    /// Open a window holding a process that is no harness and never runs a
    /// launch line, as the runtime's own pane stands before its line runs.
    /// Returns the pane id.
    pub fn open_idle(&self, name: &str, cwd: &Path) -> String {
        self.open_window(name, cwd, "exec sleep 600")
    }

    /// Split a second pane into `pane`'s window, holding a process that is
    /// no harness, as an `after-new-window` hook that splits the fresh
    /// window would leave it. Returns the new pane's id.
    pub fn split(&self, pane: &str) -> String {
        let out = tmux(
            &self.socket,
            &[
                "split-window",
                "-d",
                "-t",
                pane,
                "-P",
                "-F",
                "#{pane_id}",
                "exec sleep 600",
            ],
        );
        assert!(out.status.success(), "split-window: {}", stderr(&out));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// The names of the server's windows, in index order.
    pub fn window_names(&self) -> Vec<String> {
        let out = tmux(
            &self.socket,
            &["list-windows", "-a", "-F", "#{window_name}"],
        );
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Wait until the pane's shell has exec'd the harness: its process is
    /// named for it. For a stub that draws nothing, where no composer can be
    /// waited for.
    pub fn await_harness(&self, pane: &str) {
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

    /// Type `text` and Enter into `pane`, as a person or a harness's tool
    /// would.
    pub fn send_line(&self, pane: &str, text: &str) {
        let typed = tmux(&self.socket, &["send-keys", "-t", pane, "-l", text]);
        assert!(typed.status.success(), "send-keys: {}", stderr(&typed));
        let enter = tmux(&self.socket, &["send-keys", "-t", pane, "Enter"]);
        assert!(
            enter.status.success(),
            "send-keys Enter: {}",
            stderr(&enter)
        );
    }

    /// The pid of the pane's process.
    pub fn pane_pid(&self, pane: &str) -> u32 {
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
    pub fn await_composer(&self, pane: &str) {
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

pub fn tmux(socket: &Path, args: &[&str]) -> Output {
    Command::new("tmux")
        .arg("-S")
        .arg(socket)
        .args(args)
        .output()
        .expect("tmux")
}

pub fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

/// A child the test holds and reaps, so a stop test can plant its live pid.
pub struct Owned(pub Child);

impl Owned {
    pub fn sleep() -> Owned {
        Owned(Command::new("sleep").arg("30").spawn().expect("sleep"))
    }
    pub fn pid(&self) -> u32 {
        self.0.id()
    }
    pub fn start(&self) -> String {
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
pub fn start_of(pid: u32) -> String {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).expect("stat");
    let after = stat.rsplit_once(')').unwrap().1;
    let field = after.split_whitespace().nth(19).unwrap();
    format!("ticks:{field}")
}

/// Whether a pid names a live, non-zombie process. A process the test owns
/// that a stop ended is a zombie until the test reaps it, and its `/proc`
/// entry still stands, so the stat state decides.
pub fn live(pid: u32) -> bool {
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
pub const GONE_PID: u64 = 2_000_000_000;

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// The binary run with the fleet server in `$TMUX`, the session named and a
/// stub selected as `claude`. `verify` bounds the launch wait, the job's
/// claim and the successor's readiness; `None` leaves the binary's own
/// default, the production bound. `tools` names a directory put ahead of
/// the inherited `PATH`, so a wrapper there (a tmux shim) intercepts the
/// tool, and `env` is environment every run carries over the runner's own.
pub struct Runner {
    pub dir: TempDir,
    pub server_socket: PathBuf,
    pub session: String,
    pub stub: PathBuf,
    pub verify: Option<u64>,
    pub tools: Option<PathBuf>,
    pub env: Vec<(String, String)>,
}

impl Runner {
    pub fn new(server: &Server, stub_name: &str) -> Runner {
        Runner {
            dir: tempfile::tempdir().unwrap(),
            server_socket: server.socket.clone(),
            session: server.session.clone(),
            stub: stub(stub_name),
            verify: Some(5),
            tools: None,
            // The job-unit launcher a transfer detaches its effect through
            // (decision 76): the orch package's own, beside these tests.
            env: vec![("ORCH_JOB_UNIT".to_owned(), job_unit().display().to_string())],
        }
    }

    /// The environment a run of the binary carries, as `NAME=VALUE` words
    /// for a line typed into a pane: the fleet server, the session, the
    /// stub and the bound, the same the runner sets on its own runs.
    pub fn env_words(&self) -> Vec<String> {
        let mut words = vec![
            format!("ORCH_TMUX_SESSION={}", self.session),
            format!("ORCH_HARNESS_BINARIES=claude={}", self.stub.display()),
            "ORCH_STATE_DIR=".to_owned(),
        ];
        if let Some(verify) = self.verify {
            words.push(format!("ORCH_TMUX_VERIFY_SECS={verify}"));
        }
        for (name, value) in &self.env {
            words.push(format!("{name}={value}"));
        }
        words
    }

    /// Apply a transfer request and return the job's start the reply
    /// carries (`transfer-started`), refusing a reply that recorded the
    /// effect in this process instead.
    pub fn transfer_started(&self, request: &Value) -> Value {
        self.transfer_started_env(request, &[])
    }

    pub fn transfer_started_env(&self, request: &Value, extra: &[(&str, &str)]) -> Value {
        let out = self.op_fleet_env(request, extra);
        let answer = reply(&out);
        assert!(
            answer["ok"].as_bool().unwrap_or(false),
            "refused: {}",
            stderr(&out)
        );
        let effect = answer["result"]["effect"].clone();
        assert_eq!(effect["started"], "transfer-started", "{effect}");
        effect
    }

    /// Poll the fleet until the intent whose id begins `prefix` has ended,
    /// or stands `unconfirmed` with its owner gone (the job recorded what it
    /// could and exited), bounded; the intent as recorded.
    pub fn wait_intent_settled(&self, prefix: &str, bound: Duration) -> Value {
        let deadline = Instant::now() + bound;
        loop {
            let fleet = self.fleet();
            let intent = fleet["intents"]
                .as_array()
                .and_then(|intents| {
                    intents
                        .iter()
                        .find(|i| i["id"].as_str().is_some_and(|id| id.starts_with(prefix)))
                })
                .cloned();
            if let Some(intent) = intent {
                let ended = intent["completed_at"].is_string();
                let owner_gone = intent["owner"]["pid"]
                    .as_u64()
                    .is_none_or(|pid| !live(pid as u32));
                if ended || (intent["outcome"] == "unconfirmed" && owner_gone) {
                    return intent;
                }
                assert!(
                    Instant::now() < deadline,
                    "the intent never settled: {intent}"
                );
            } else {
                assert!(Instant::now() < deadline, "no intent begins {prefix}");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn state_dir(&self) -> &Path {
        self.dir.path()
    }

    pub fn run(&self, args: &[&str]) -> Output {
        self.run_env(args, &[])
    }

    /// The binary with `extra` environment over the runner's own.
    pub fn run_env(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
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
            // The mailbox and validation runner a close asks, as stubs that
            // answer no asks and stop nothing; a row plants asks through
            // `LANE_MAIL_ASKS` in `env`.
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "DEV_VALIDATE_CLI",
                fixtures().join("dev-validate-quiet/dev-validate-run"),
            )
            // The watch handover owner a publication runs, as a lib that
            // starts no watch and records its call in `WATCH_HANDOVER_LOG`.
            .env(
                "ORCH_WATCH_HANDOVER",
                fixtures().join("watch-handover-quiet/watch-handover.sh"),
            )
            // No project settings or private env reach the test's own tree.
            .env("ORCH_STATE_DIR", "")
            .current_dir(self.state_dir());
        if let Some(verify) = self.verify {
            command.env("ORCH_TMUX_VERIFY_SECS", verify.to_string());
        }
        if let Some(tools) = &self.tools {
            let inherited = std::env::var("PATH").unwrap_or_default();
            command.env("PATH", format!("{}:{inherited}", tools.display()));
        }
        for (name, value) in &self.env {
            command.env(name, value);
        }
        for (name, value) in extra {
            command.env(name, value);
        }
        command.output().expect("orch-runtime")
    }

    /// Spawn a fleet `op` as a background child with `extra` environment and
    /// `path_prefix` ahead of the inherited `PATH`, so a wrapper there (the
    /// tmux-hold shim) intercepts the tool. The child blocks where the shim
    /// blocks; the test drives it and reaps it.
    pub fn spawn_op_fleet(
        &self,
        request: &Value,
        extra: &[(&str, &str)],
        path_prefix: &Path,
    ) -> Child {
        let path = self.state_dir().join("request.json");
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        let inherited = std::env::var("PATH").unwrap_or_default();
        let combined = format!("{}:{inherited}", path_prefix.display());
        let mut command = Command::new(binary());
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(["op", "--fleet", "--request", &path.display().to_string()])
            .env("TMUX", format!("{},0,0", self.server_socket.display()))
            .env("ORCH_TMUX_SESSION", &self.session)
            .env(
                "ORCH_HARNESS_BINARIES",
                format!("claude={}", self.stub.display()),
            )
            // The mailbox and validation runner a close asks, as stubs that
            // answer no asks and stop nothing; a row plants asks through
            // `LANE_MAIL_ASKS` in `env`.
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "DEV_VALIDATE_CLI",
                fixtures().join("dev-validate-quiet/dev-validate-run"),
            )
            .env(
                "ORCH_WATCH_HANDOVER",
                fixtures().join("watch-handover-quiet/watch-handover.sh"),
            )
            .env("ORCH_STATE_DIR", "")
            .env("PATH", combined)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .current_dir(self.state_dir());
        if let Some(verify) = self.verify {
            command.env("ORCH_TMUX_VERIFY_SECS", verify.to_string());
        }
        for (name, value) in extra {
            command.env(name, value);
        }
        command.spawn().expect("spawn orch-runtime op")
    }

    /// Write `request` to a file and apply it to the fleet state.
    pub fn op_fleet(&self, request: &Value) -> Output {
        self.op_fleet_env(request, &[])
    }

    pub fn op_fleet_env(&self, request: &Value, extra: &[(&str, &str)]) -> Output {
        let path = self.state_dir().join("request.json");
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        self.run_env(
            &["op", "--fleet", "--request", &path.display().to_string()],
            extra,
        )
    }

    pub fn init_fleet(&self) {
        let out = self.run(&["state", "init", "--fleet"]);
        assert!(out.status.success(), "init: {}", stderr(&out));
    }

    /// The fleet state as JSON.
    pub fn fleet(&self) -> Value {
        let text =
            std::fs::read_to_string(self.state_dir().join("workflow-state-oversee.json")).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    pub fn write_fleet(&self, value: &Value) {
        std::fs::write(
            self.state_dir().join("workflow-state-oversee.json"),
            serde_json::to_string_pretty(value).unwrap(),
        )
        .unwrap();
    }

    /// The one reconcile report of a fleet with one open intent.
    pub fn reconcile_one(&self) -> Value {
        let out = self.run(&["reconcile", "--fleet"]);
        let answer = reply(&out);
        assert!(answer["ok"].as_bool().unwrap_or(false), "{}", stderr(&out));
        let reconciled = answer["result"]["reconciled"].as_array().unwrap();
        assert_eq!(reconciled.len(), 1, "one open intent: {reconciled:?}");
        reconciled[0]["report"].clone()
    }

    /// The user turns every Claude-shaped session file under the account
    /// home `home` for `cwd` records, as lines.
    pub fn stub_turns(&self, home: &Path, cwd: &Path) -> Vec<String> {
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

/// The orch package's job-unit launcher, beside these tests.
pub fn job_unit() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts/lib/job-unit.sh")
}

/// Claude Code's project directory for `cwd` under `home`.
pub fn project_dir(home: &Path, cwd: &Path) -> PathBuf {
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
pub fn file_turns(file: &Path) -> Vec<String> {
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
pub fn neighbour_row(kind: &str, cwd: &Path) -> String {
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
pub struct Neighbour {
    pub file: PathBuf,
    pub _writer: Owned,
}

impl Neighbour {
    /// Write `turns` user rows now, then append a `kind` row every 100 ms.
    pub fn writing(home: &Path, cwd: &Path, turns: usize, kind: &str) -> Neighbour {
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

    pub fn user_turns(&self) -> usize {
        file_turns(&self.file).len()
    }

    pub fn rows(&self) -> usize {
        std::fs::read_to_string(&self.file)
            .map(|t| t.lines().count())
            .unwrap_or(0)
    }
}

pub fn reply(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            stderr(out)
        )
    })
}

/// The committed outcome transition an `op` that ran an effect returns.
pub fn effect_report(out: &Output) -> Value {
    let answer = reply(out);
    assert!(
        answer["ok"].as_bool().unwrap_or(false),
        "refused: {}",
        stderr(out)
    );
    answer["result"]["effect"]["report"].clone()
}

pub fn launch_request(item: &str, mail_root: &Path) -> Value {
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
pub fn overseer_record(pid: u32, start: &str, server: &Server, cwd: &Path) -> Value {
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

pub fn pending(cwd: &Path) -> Value {
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
pub fn transfer_request(server: &Server, cwd: &Path) -> Value {
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
pub fn plant_transfer(runner: &Runner, server: &Server, pid: u32, start: &str) {
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(pid, start, server, runner.state_dir());
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
}

/// A recorded phase naming `pane` on the test's server, its session floor
/// `since_ms`, holding `brief` for a succession.
pub fn phase(
    word: &str,
    server: &Server,
    pane: &str,
    since_ms: u64,
    brief: Option<&Path>,
) -> Value {
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

/// The `opening` phase a launch or succession records before its window
/// opens (decision 73): the recorded server and floor, and the pane once
/// the effect's own `new-window` printed one (decision 96).
pub fn opening_phase(server: &Server, since_ms: u64, pane: Option<&str>) -> Value {
    let mut phase = json!({
        "phase": "opening",
        "server": server.pid,
        "server_start": server.start,
        "server_process_start": server.process_start,
        "socket": server.socket.display().to_string(),
        "since_ms": since_ms,
    });
    if let Some(pane) = pane {
        phase["pane"] = json!(pane);
    }
    phase
}

/// Where the pane of `intent_id` registers itself under the runner's state
/// directory (decision 96).
pub fn receipt_path(runner: &Runner, intent_id: &str) -> PathBuf {
    runner
        .state_dir()
        .join("intents")
        .join(format!("{intent_id}.pane"))
}

/// Write the receipt a pane's launch line writes before it execs the
/// harness: `pane` and `pid` as the pane's shell would have written them.
pub fn plant_receipt(runner: &Runner, intent_id: &str, pane: &str, pid: u32) {
    plant_receipt_text(
        runner,
        intent_id,
        &json!({
            "intent": intent_id,
            "pane": pane,
            "pid": pid,
            "written_at": "2026-10-26T10:00:00Z",
        })
        .to_string(),
    );
}

pub fn plant_receipt_text(runner: &Runner, intent_id: &str, text: &str) {
    let path = receipt_path(runner, intent_id);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, text).unwrap();
}

/// The receipt the runtime's own launch wrote for `intent_id`, parsed.
pub fn read_receipt(runner: &Runner, intent_id: &str) -> Value {
    let text = std::fs::read_to_string(receipt_path(runner, intent_id))
        .unwrap_or_else(|e| panic!("no receipt for {intent_id}: {e}"));
    serde_json::from_str(&text).expect("a JSON receipt")
}

/// The real tmux on this host's `PATH`, which the tmux-hold shim execs.
pub fn which_tmux() -> String {
    let out = Command::new("sh")
        .args(["-c", "command -v tmux"])
        .output()
        .expect("which tmux");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// Create a FIFO at `path` through `mkfifo`, the one blocking channel the
/// tmux-hold shim waits on.
pub fn mkfifo(path: &Path) {
    let out = Command::new("mkfifo").arg(path).output().expect("mkfifo");
    assert!(out.status.success(), "mkfifo: {}", stderr(&out));
}

/// Release the tmux-hold shim waiting on `fifo`, within `bound`: the write
/// blocks until the shim opens its end, so it runs on its own thread and the
/// row waits on it with a deadline. A hold the effect never reaches, a job
/// that failed before its held verb, fails the row here with `evidence`
/// rather than blocking it for the suite's whole timeout.
pub fn release_hold(fifo: &Path, bound: Duration, evidence: impl Fn() -> String) {
    let path = fifo.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let written = std::fs::write(&path, b"go\n");
        let _ = tx.send(written);
    });
    match rx.recv_timeout(bound) {
        Ok(Ok(())) => {}
        Ok(Err(e)) => panic!("the hold at {} could not be released: {e}", fifo.display()),
        Err(_) => panic!(
            "nothing reached the hold at {} within {:?}\n{}",
            fifo.display(),
            bound,
            evidence()
        ),
    }
}

/// Poll the fleet until the intent whose id begins `prefix` records `phase`,
/// bounded, so a test can tell a held op reached that step.
pub fn wait_for_phase(runner: &Runner, prefix: &str, phase: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(intents) = runner.fleet()["intents"].as_array()
            && intents.iter().any(|i| {
                i["id"].as_str().is_some_and(|id| id.starts_with(prefix))
                    && i["phase"]["phase"] == phase
            })
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the intent never reached {phase}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub fn lane(item: &str, status: &str, runner: &Runner, launch: Value) -> Value {
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

pub fn lane_intent(op: &str, item: &str, outcome: &str, phase: Option<Value>) -> Value {
    let mut intent = json!({
        "id": format!("{op}:{item}:1-1"),
        "op": op,
        "target": item,
        "created_at": "2026-01-29T15:20:00Z",
        "outcome": outcome,
        "lane_since": "2026-01-29T15:20:00Z",
    });
    if let Some(phase) = phase {
        intent["phase"] = phase;
    }
    intent
}

pub fn transfer_intent(phase: Option<Value>, original_pending: Option<Value>) -> Value {
    let mut intent = json!({
        "id": "request-transfer:overseer:3:1-1",
        "op": "request-transfer",
        "target": "overseer:3",
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

/// The obligation of `kind` an `unconfirmed` outcome left standing, as the
/// observation's `remaining` carries it (decision 111 (A)): the first of
/// that kind, or `Null` where none stands.
pub fn remaining<'a>(observation: &'a Value, kind: &str) -> &'a Value {
    observation["remaining"]
        .as_array()
        .and_then(|standing| standing.iter().find(|o| o["kind"] == kind))
        .unwrap_or(&Value::Null)
}
