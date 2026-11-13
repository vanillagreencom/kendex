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
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

use agent_runtime::clock::Clock;
use agent_runtime::process::Identity;
use orch_runtime::error::Error;
use orch_runtime::watch;

#[path = "../../../agent-runtime/tests/rust/account_planters.rs"]
mod account_planters;
pub use account_planters::*;
#[path = "../../../agent-runtime/tests/rust/isolation.rs"]
mod isolation;
pub use isolation::*;

/// The one injected clock as a test drives it: time
/// moves only when the test passes it, and a `sleep` blocks its thread
/// until the clock has reached its wake time. Shared by the runner's two
/// duty threads and the operation handle alike, so one `pass` wakes every
/// wait that came due and the test proves order by what ran, never by
/// waiting real time.
pub struct FakeClock {
    state: Mutex<FakeState>,
    woke: Condvar,
    /// How long a `pass` waits, in real time, for the woken threads to come
    /// back to sleep before it reports them stuck.
    pub settle: Duration,
}

struct FakeState {
    start: Instant,
    now: Instant,
    /// The epoch second the fake wall clock reads.
    wall: u64,
    /// The wake time of every thread blocked in `sleep`.
    sleepers: Vec<Instant>,
}

impl Default for FakeClock {
    fn default() -> FakeClock {
        FakeClock::new()
    }
}

impl FakeClock {
    pub fn new() -> FakeClock {
        let start = Instant::now();
        FakeClock {
            state: Mutex::new(FakeState {
                start,
                now: start,
                wall: 1_769_700_000,
                sleepers: Vec::new(),
            }),
            woke: Condvar::new(),
            settle: Duration::from_secs(20),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, FakeState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Fake time since the clock was made.
    pub fn elapsed(&self) -> Duration {
        let s = self.lock();
        s.now.duration_since(s.start)
    }

    /// The fake wall clock's epoch second.
    pub fn wall_secs(&self) -> u64 {
        self.lock().wall
    }

    /// Advance `d` and wait until every sleeper that came due has run and
    /// gone back to sleep: the sleeper count is back to what it was and no
    /// sleeper's wake time has passed. A thread that ended instead of
    /// sleeping again makes this fail with the sleepers it still sees; use
    /// [`FakeClock::release`] to wake threads that are about to stop.
    pub fn pass(&self, d: Duration) {
        let mut s = self.lock();
        let before = s.sleepers.len();
        s.now += d;
        s.wall += d.as_secs();
        self.woke.notify_all();
        let deadline = Instant::now() + self.settle;
        loop {
            let settled = s.sleepers.len() >= before && s.sleepers.iter().all(|w| *w > s.now);
            if settled {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "the woken threads did not come back to sleep: {} of {before} sleeping, now+{:?}",
                s.sleepers.len(),
                s.now.duration_since(s.start)
            );
            let (guard, _) = self
                .woke
                .wait_timeout(s, Duration::from_millis(20))
                .unwrap_or_else(|p| p.into_inner());
            s = guard;
        }
    }

    /// Advance `d` and wake what came due, waiting for nothing: for a thread
    /// that will see a stop and end rather than sleep again.
    pub fn release(&self, d: Duration) {
        let mut s = self.lock();
        s.now += d;
        s.wall += d.as_secs();
        self.woke.notify_all();
    }

    /// How many threads are blocked in `sleep` now.
    pub fn sleepers(&self) -> usize {
        self.lock().sleepers.len()
    }

    /// Whether a thread sleeps and every sleeper's wake is still ahead: a
    /// woken thread keeps its wake listed until it runs again, so a count
    /// alone reads a thread mid-work as asleep.
    pub fn asleep(&self) -> bool {
        let s = self.lock();
        !s.sleepers.is_empty() && s.sleepers.iter().all(|wake| s.now < *wake)
    }

    /// Wait, in real time, until `n` threads are blocked in `sleep`.
    pub fn await_sleepers(&self, n: usize) {
        let mut s = self.lock();
        let deadline = Instant::now() + self.settle;
        while s.sleepers.len() < n {
            assert!(
                Instant::now() < deadline,
                "{} of {n} threads reached sleep",
                s.sleepers.len()
            );
            let (guard, _) = self
                .woke
                .wait_timeout(s, Duration::from_millis(20))
                .unwrap_or_else(|p| p.into_inner());
            s = guard;
        }
    }
}

impl Clock for FakeClock {
    fn now(&self) -> Instant {
        self.lock().now
    }

    fn wall(&self) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(self.lock().wall)
    }

    fn sleep(&self, d: Duration) {
        let mut s = self.lock();
        let wake = s.now + d;
        s.sleepers.push(wake);
        self.woke.notify_all();
        while s.now < wake {
            s = self.woke.wait(s).unwrap_or_else(|p| p.into_inner());
        }
        if let Some(i) = s.sleepers.iter().position(|w| *w == wake) {
            s.sleepers.swap_remove(i);
        }
        self.woke.notify_all();
    }
}

pub fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_orch-runtime"))
}

/// The agent-runtime binary, built once from the sibling crate into this
/// suite's own target directory: Cargo builds a dependency's library alone,
/// and no stable artifact dependency names its binary, so the suite asks for
/// it by the same command.
pub fn agent_runtime() -> &'static Path {
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

/// The binary as every suite starts it: its environment
/// selected by [`isolation_env`], never inherited, no private environment
/// file, and the temporary root as its working directory, so no caller's
/// settings, team, repositories, tokens or mailbox and no checkout above a
/// test directory reach a row whatever starts it. A duty's program then
/// defaults to a path under the test directory that does not exist and
/// fails loudly; a row that wants a duty to work names its program, and a
/// row that wants another directory sets it after.
pub fn isolated() -> Command {
    // A directory strictly below the ceiling: git exempts a working
    // directory that is the ceiling itself and would walk up from it.
    let cwd = std::env::temp_dir().join("isolated-cwd");
    std::fs::create_dir_all(&cwd).expect("the isolated working directory");
    let mut command = program(binary());
    command.arg("--no-private-env").current_dir(cwd);
    command
}

/// `program` behind a wrapper that runs it with the scratch home, no global
/// or system git configuration, no `XDG_CONFIG_HOME` (git's attributes file
/// and cargo's git configuration default under it, so the home's own
/// `.config` stands in) and none of the repository-local variables git
/// names (`git rev-parse --local-env-vars`), for a program a row hands
/// the runtime in-process: the one runner starts it with this test
/// process's own environment, so a `git` it runs would read the operator's
/// configuration, or, run inside a git hook, the hook's repository through
/// its `GIT_DIR`. The rest of the environment passes through, so a row's
/// own wrapper that exports a fixture's variables still reaches it. The
/// wrapper names the program's path, which differs per checkout, so it is
/// published once per text under this build's own temporary directory,
/// which goes with the build, never under the shared temporary root.
pub fn isolated_program(program: &Path) -> PathBuf {
    use std::hash::{Hash, Hasher};
    let home = std::env::temp_dir().join("isolated-home");
    std::fs::create_dir_all(&home).expect("the scratch home");
    let quote = |text: &str| format!("'{}'", text.replace('\'', "'\\''"));
    let text = format!(
        "#!/bin/sh\nexport HOME={} GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null\nunset XDG_CONFIG_HOME $(git rev-parse --local-env-vars)\nexec {} \"$@\"\n",
        quote(&home.display().to_string()),
        quote(&program.display().to_string())
    );
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("isolated-programs");
    std::fs::create_dir_all(&dir).expect("the isolated programs directory");
    let name = program.file_name().unwrap_or_default().to_string_lossy();
    publish(&dir, &format!("{:016x}-{name}", hasher.finish()), &text)
}

/// Whether the calling row runs here: a row that runs the runtime's code
/// in its own process calls this first with its whole name and returns
/// when it answers false. The runtime's git reads keep their caller's
/// configuration, and a test binary's environment is the operator's, so
/// the row runs again in a child of this binary under [`isolation_env`],
/// which answers true there; the parent asserts that the child ran the
/// row, alone, and passed.
pub fn isolated_row(name: &str) -> bool {
    const MARK: &str = "ORCH_TEST_ISOLATED_ROW";
    if std::env::var_os(MARK).is_some() {
        return true;
    }
    let out = program(std::env::current_exe().expect("the test binary"))
        .args([name, "--exact", "--test-threads=1"])
        .env(MARK, name)
        .output()
        .expect("the row's isolated child");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && stdout.contains("test result: ok. 1 passed;"),
        "{name} in its isolated child:\n{stdout}{}",
        stderr(&out)
    );
    false
}

/// A test child's `PATH` on which `absent` alone is missing: `bin` made to
/// hold a link to every other program [`tool_path`] names, the first of
/// each name, so the isolated tools still stand ahead of the inherited path.
pub fn path_without(bin: &Path, absent: &str) -> String {
    std::fs::create_dir_all(bin).unwrap();
    let path = tool_path(&[]);
    for dir in std::env::split_paths(&path) {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            if name == absent || std::fs::symlink_metadata(bin.join(&name)).is_ok() {
                continue;
            }
            std::os::unix::fs::symlink(entry.path(), bin.join(&name)).unwrap();
        }
    }
    bin.display().to_string()
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
/// user tmux configuration or login shell reaches a row.
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
/// on drop so a panicking test still reaps it, and by its guard when this
/// test process ends with no drop (a signal, `timeout`, an interrupted run).
/// It reads no configuration file and names its pane shell, so the host's
/// `~/.tmux.conf` and login shell reach no row.
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
    /// The child that ends the server once this process is gone: tmux
    /// detaches its server from the process that started it, so a test
    /// process ended by a signal, which runs no drop, would leave the server
    /// and every pane process standing. The guard blocks reading a pipe
    /// whose one writer is this process, in a process group of its own and
    /// ignoring the hangup, so no signal a terminal or `timeout` sends this
    /// process's group reaches it, and ends the server at the pipe's end of
    /// file, which the kernel gives however this process ends. `None` for a
    /// server a row stands in with no process of tmux's.
    pub guard: Option<Child>,
}

/// The guard's script: `$1` is the server's socket.
const SERVER_GUARD: &str = "trap '' HUP INT TERM; read -r _; exec tmux -S \"$1\" kill-server";

impl Server {
    pub fn start(dir: &Path, session: &str) -> Server {
        Server::start_with_config(dir, session, Path::new("/dev/null"))
    }

    /// A server reading `config` as its configuration file: the one way a
    /// row plants a hook on the server before any window opens.
    pub fn start_with_config(dir: &Path, session: &str, config: &Path) -> Server {
        let socket = dir.join("tmux.sock");
        // The server's environment is every pane's: selected, never the
        // test process's own.
        let mut command = Command::new("tmux");
        isolation_env(&mut command);
        // The first window opens before `default-shell` is set below and
        // would run the passwd login shell: name the pane shell here too.
        command.env("SHELL", pane_shell());
        let out = command
            .arg("-S")
            .arg(&socket)
            .args([
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
            ])
            .output()
            .expect("tmux");
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
        let guard = program("sh")
            .args(["-c", SERVER_GUARD, "server-guard"])
            .arg(&socket)
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("the server's guard");
        Server {
            socket,
            session: session.to_owned(),
            pid,
            start,
            process_start: start_of(pid),
            guard: Some(guard),
        }
    }

    /// The session's creator closing the window the session was born with,
    /// its first, once a window the runtime opened stands after it, a second
    /// session holding the server as a person's server holds others: the
    /// fleet session then holds only the windows the runtime opened.
    pub fn close_birth_window(&self) {
        let panes = self.session_panes();
        assert!(
            panes.len() > 1,
            "a window stands after the first: {panes:?}"
        );
        let held = tmux(&self.socket, &["new-session", "-d", "-s", "bystander"]);
        assert!(held.status.success(), "new-session: {}", stderr(&held));
        let closed = tmux(&self.socket, &["kill-window", "-t", &panes[0]]);
        assert!(closed.status.success(), "kill-window: {}", stderr(&closed));
    }

    /// The panes of the fleet session alone, in window order; none where the
    /// session is gone.
    pub fn session_panes(&self) -> Vec<String> {
        let out = tmux(
            &self.socket,
            &[
                "list-panes",
                "-s",
                "-t",
                &format!("={}", self.session),
                "-F",
                "#{pane_id}",
            ],
        );
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Whether the pane stands on the server kept dead after its process
    /// exited.
    pub fn pane_dead(&self, pane: &str) -> bool {
        let out = tmux(
            &self.socket,
            &["display-message", "-p", "-t", pane, "#{pane_dead}"],
        );
        out.status.success() && String::from_utf8_lossy(&out.stdout).trim() == "1"
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

    /// Open a window whose process exits once the window keeps its pane
    /// (`remain-on-exit`), as a harness's pane stands after it ended on a
    /// server that keeps such panes: the pane dead, its window standing.
    /// Returns the pane id once tmux reads it dead, bounded.
    pub fn open_kept_dead(&self, name: &str, cwd: &Path) -> String {
        let pane = self.open_window(name, cwd, "read line; exit 3");
        let kept = tmux(
            &self.socket,
            &["set-option", "-w", "-t", &pane, "remain-on-exit", "on"],
        );
        assert!(kept.status.success(), "remain-on-exit: {}", stderr(&kept));
        let enter = tmux(&self.socket, &["send-keys", "-t", &pane, "Enter"]);
        assert!(enter.status.success(), "send-keys: {}", stderr(&enter));
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let dead = tmux(
                &self.socket,
                &["display-message", "-p", "-t", &pane, "#{pane_dead}"],
            );
            if String::from_utf8_lossy(&dead.stdout).trim() == "1" {
                return pane;
            }
            assert!(Instant::now() < deadline, "the pane never died");
            std::thread::sleep(Duration::from_millis(20));
        }
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
        // The server's own socket first. Where a row's directory dropped
        // before the server, the socket is gone and `kill-server` reaches
        // nothing, whatever a row's drop order: then
        // the pid the server started as is signalled, by pid alone and only
        // while its command line still names this socket, so a reused pid
        // is never touched.
        let _ = tmux(&self.socket, &["kill-server"]);
        let cmdline = std::fs::read(format!("/proc/{}/cmdline", self.pid)).unwrap_or_default();
        let socket = self.socket.as_os_str().as_encoded_bytes();
        if cmdline.windows(socket.len()).any(|w| w == socket) {
            let _ = Command::new("kill")
                .args(["-TERM", &self.pid.to_string()])
                .output();
        }
        // The pipe's end lets the guard go; it is reaped here, so a row
        // leaves no process of its own behind.
        if let Some(mut guard) = self.guard.take() {
            drop(guard.stdin.take());
            let _ = guard.wait();
        }
    }
}

/// A tmux client on the private server at `socket`, under [`isolation_env`]:
/// a window a client outside every session opens takes that client's
/// `PATH`, so a client with the test process's own would hand every such
/// pane the operator's tools.
pub fn tmux(socket: &Path, args: &[&str]) -> Output {
    let mut command = Command::new("tmux");
    isolation_env(&mut command);
    command
        .arg("-S")
        .arg(socket)
        .args(args)
        .output()
        .expect("tmux")
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

/// An unfinished validation run under `worktree` as the validation runner
/// leaves it while its command runs: its `start` record and the command's
/// identity, the command a process group the test leads and holds. Returns
/// the command and the run's directory.
pub fn validation_run(worktree: &Path) -> (Owned, PathBuf) {
    let command = Owned(
        Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .expect("sleep"),
    );
    let dir = worktree.join("tmp/dev-validate-planted");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("start"), "start=1\n").unwrap();
    std::fs::write(
        dir.join("command"),
        json!({"pid": command.pid(), "start": command.start()}).to_string(),
    )
    .unwrap();
    (command, dir)
}

/// Whether the run's own record reads stopped: the stop mark its stop
/// writes before it signals.
pub fn run_stopped(run_dir: &Path) -> bool {
    std::fs::read_to_string(run_dir.join("stop")).is_ok_and(|text| text == "stop-requested\n")
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
            env: Vec::new(),
        }
    }

    /// The environment a run of the binary carries, as `NAME=VALUE` words
    /// for a line typed into a pane: the fleet server, the session, the
    /// stub and the bound, the same the runner sets on its own runs.
    pub fn env_words(&self) -> Vec<String> {
        let mut words = vec![
            format!("AGENT_RUNTIME_TMUX_SESSION={}", self.session),
            format!(
                "AGENT_RUNTIME_HARNESS_BINARIES=claude={}",
                self.stub.display()
            ),
            "ORCH_STATE_DIR=".to_owned(),
        ];
        if let Some(verify) = self.verify {
            words.push(format!("AGENT_RUNTIME_TMUX_VERIFY_SECS={verify}"));
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
    /// could and exited), and the notice its outcome owes is marked or its
    /// owner is gone, bounded; the intent as recorded. The mark is the owner's
    /// last write to the record after its outcome, so a row that acts on the
    /// record once this returns meets no write of the job's.
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
                let marked = intent["notice"]["owner"] != "owed" || owner_gone;
                if (ended || (intent["outcome"] == "unconfirmed" && owner_gone)) && marked {
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
        let mut command = isolated();
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(args)
            .current_dir(self.state_dir());
        self.apply_env(&mut command);
        for (name, value) in extra {
            command.env(name, value);
        }
        command.output().expect("orch-runtime")
    }

    /// The runner's environment on `command`: the fleet server and session,
    /// the stub harness, the quiet mailbox and validation stubs (a row
    /// plants asks through `LANE_MAIL_ASKS` in `env`), an agent-runtime the
    /// readiness judge reads built, the bound, the tools and the runner's
    /// own entries; the same for a child that is not the binary itself,
    /// such as the detached line the wall route starts.
    pub fn apply_env(&self, command: &mut Command) {
        command
            .env("TMUX", format!("{},0,0", self.server_socket.display()))
            .env("AGENT_RUNTIME_TMUX_SESSION", &self.session)
            .env(
                "AGENT_RUNTIME_HARNESS_BINARIES",
                format!("claude={}", self.stub.display()),
            )
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "ORCH_AGENT_RUNTIME",
                fixtures().join("agent-runtime-built/agent-runtime"),
            )
            .env(
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                self.state_dir().join("tmp/oversee-watch"),
            );
        if let Some(verify) = self.verify {
            command.env("AGENT_RUNTIME_TMUX_VERIFY_SECS", verify.to_string());
        }
        if let Some(tools) = &self.tools {
            command.env("PATH", tool_path(&[tools.as_path()]));
        }
        for (name, value) in &self.env {
            command.env(name, value);
        }
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
        let combined = tool_path(&[path_prefix]);
        let mut command = isolated();
        command
            .args(["--state-dir", &self.state_dir().display().to_string()])
            .args(["op", "--fleet", "--request", &path.display().to_string()])
            .env("TMUX", format!("{},0,0", self.server_socket.display()))
            .env("AGENT_RUNTIME_TMUX_SESSION", &self.session)
            .env(
                "AGENT_RUNTIME_HARNESS_BINARIES",
                format!("claude={}", self.stub.display()),
            )
            // The mailbox and validation runner a close asks, as stubs that
            // answer no asks and stop nothing; a row plants asks through
            // `LANE_MAIL_ASKS` in `env`.
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env("PATH", combined)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .current_dir(self.state_dir());
        if let Some(verify) = self.verify {
            command.env("AGENT_RUNTIME_TMUX_VERIFY_SECS", verify.to_string());
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

    /// The fleet state initialized, in a state directory that is also a
    /// checkout: a launch into it writes the launch record under its git
    /// directory, as every lane's root holds one.
    pub fn init_fleet(&self) {
        let out = program("git")
            .args(["-C", &self.state_dir().display().to_string(), "init", "-q"])
            .output()
            .expect("git");
        assert!(out.status.success(), "git init: {}", stderr(&out));
        // The checkout installs the github package, whose resolver names its
        // repository; git excludes the link, so its tree reads as made.
        github_skill_under(self.state_dir());
        std::fs::write(
            self.state_dir().join(".git/info/exclude"),
            "/.agents/skills/github\n",
        )
        .unwrap();
        let out = self.run(&["state", "init", "--fleet"]);
        assert!(out.status.success(), "init: {}", stderr(&out));
        // The account `pending` names is the state directory: signed in.
        plant_credential(self.state_dir());
    }

    pub fn fleet(&self) -> Value {
        let text =
            std::fs::read_to_string(self.state_dir().join("workflow-state-oversee.json")).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    /// The fleet state, and, where its record names a generation, the
    /// predecessor's handoff snapshot at the default handoff under the state
    /// directory, written by the real `handoff` verb: the neutral world a
    /// live succession is admitted in. A row that judges the snapshot
    /// writes its own.
    pub fn write_fleet(&self, value: &Value) {
        std::fs::write(
            self.state_dir().join("workflow-state-oversee.json"),
            serde_json::to_string_pretty(value).unwrap(),
        )
        .unwrap();
        if value["overseer"]["generation"].is_u64() {
            self.snapshot(&self.state_dir().join("tmp/handoffs/OVERSEER-HANDOFF.md"));
        }
    }

    /// The overseer's snapshot at `handoff` for the record as it stands,
    /// through the real `handoff` verb, as the workflow writes it before a
    /// live succession.
    pub fn snapshot(&self, handoff: &Path) {
        let body = self.state_dir().join("snapshot-body.md");
        std::fs::write(&body, "## State\nSession: live\n").unwrap();
        let out = self.run(&[
            "handoff",
            "--fleet",
            "--body",
            &body.display().to_string(),
            "--handoff",
            &handoff.display().to_string(),
        ]);
        assert_eq!(reply(&out)["ok"], true, "handoff: {}", stderr(&out));
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
/// newest file whenever the runtime looks.
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

/// A launch of `item` on an account, naming the model and effort a launch
/// on an account must.
pub fn launch_request(item: &str, mail_root: &Path) -> Value {
    json!({
        "op": "launch-lane",
        "item": item,
        "harness": "claude",
        "mail_root": mail_root.display().to_string(),
        "account": mail_root.display().to_string(),
        "model": "claude-fable-5-1",
        "effort": "high",
    })
}

/// The overseer record a succession reads: a predecessor whose harness
/// process is `pid`, on the test's server. `harness_pid` is the string a
/// shell writer's jq `--arg` writes.
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

/// A Claude account's sign-in in `dir`: the credential file the harness
/// signs in with on Linux, holding an access token with no stated expiry.
pub fn plant_credential(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join(".credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"planted","subscriptionType":"max"}}"#,
    )
    .unwrap();
}

/// A Codex account's sign-in in `dir`: the `auth.json` the harness signs
/// in with, holding an access token.
pub fn plant_codex_credential(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join("auth.json"),
        r#"{"tokens":{"access_token":"planted"}}"#,
    )
    .unwrap();
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
/// opens: the recorded server and floor, and the pane once the effect's own
/// `new-window` printed one.
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
/// directory.
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

/// Release the hold fixture waiting on `fifo` with one line, within `bound`:
/// the write blocks until the fixture opens its end, so it runs on its own
/// thread and the row waits on it with a deadline. A hold the effect never
/// reaches, a job that failed before its held verb, fails the row here with
/// `evidence` rather than blocking it for the suite's whole timeout. Each
/// hold fixture gives up its read after `HOLD_BOUND_SECS`, 120 by default,
/// four times the longest `bound` a row passes here, so a row that dies
/// before its release leaves no held child behind it.
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
/// observation's `remaining` carries it: the first of
/// that kind, or `Null` where none stands.
pub fn remaining<'a>(observation: &'a Value, kind: &str) -> &'a Value {
    observation["remaining"]
        .as_array()
        .and_then(|standing| standing.iter().find(|o| o["kind"] == kind))
        .unwrap_or(&Value::Null)
}

/// `n` seconds, the unit every row's clock step is in.
pub fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

/// A duty body that counts its runs and records the fake epoch second of
/// each, emitting `event` (with a tick-specific id where it takes one) and
/// the changes `changes` gives.
pub struct Counting {
    pub runs: Arc<AtomicUsize>,
    pub at: Arc<std::sync::Mutex<Vec<u64>>>,
}

impl Counting {
    pub fn new() -> Counting {
        Counting {
            runs: Arc::new(AtomicUsize::new(0)),
            at: Arc::new(std::sync::Mutex::new(Vec::new())),
        }
    }

    pub fn body(
        &self,
        mut produce: impl FnMut(&watch::Tick) -> watch::Produced + Send + 'static,
    ) -> watch::Body<'static> {
        self.body_result(move |tick| Ok(produce(tick)))
    }

    /// A body whose runs may refuse: the count and the stamps are taken
    /// before the result is known.
    pub fn body_result(
        &self,
        mut produce: impl FnMut(&watch::Tick) -> Result<watch::Produced, Error> + Send + 'static,
    ) -> watch::Body<'static> {
        let runs = self.runs.clone();
        let at = self.at.clone();
        Box::new(move |tick: &watch::Tick| {
            runs.fetch_add(1, Ordering::SeqCst);
            at.lock().unwrap().push(tick.wall);
            produce(tick)
        })
    }

    pub fn runs(&self) -> usize {
        self.runs.load(Ordering::SeqCst)
    }

    pub fn at(&self) -> Vec<u64> {
        self.at.lock().unwrap().clone()
    }
}

/// Run `runner` to its end on a thread while `drive` works the clock; the
/// run's result. A `drive` that fails still stops the runner, so a failed
/// assertion is reported rather than hanging the row on the scope's join.
/// The stop wakes only threads asleep on the clock, so a drive returns with
/// every runner thread asleep (a strict `pass` or `await_sleepers` leaves
/// them so).
pub fn run_driven(
    runner: watch::Runner<'_>,
    clock: &FakeClock,
    paths: &watch::Paths,
    identity: &Identity,
    drive: impl FnOnce(),
) -> Result<watch::Ended, Error> {
    std::thread::scope(|s| {
        let handle = s.spawn(move || runner.run());
        let drove = std::panic::catch_unwind(std::panic::AssertUnwindSafe(drive));
        if let Err(panic) = &drove {
            // Said before the join, which a body the drive was to release
            // can hold.
            let text = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| (*s).to_owned()))
                .unwrap_or_default();
            let _ = std::io::Write::write_all(
                &mut std::io::stderr(),
                format!("drive failed before the runner stopped: {text}\n").as_bytes(),
            );
        }
        let _ = watch::claim::request_stop(paths, identity);
        // One release wakes the threads asleep now; a thread still in a body
        // sleeps again past the clock, so the release repeats, in real time,
        // until the runner has ended or the bound passes.
        let bound = Instant::now() + secs(10);
        loop {
            clock.release(secs(1));
            if handle.is_finished() || Instant::now() >= bound {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if let Err(panic) = drove {
            std::panic::resume_unwind(panic);
        }
        handle.join().expect("the runner thread")
    })
}

// --- the accounts a listing lists ----------------------------------------------------------

/// Installs orch where the runtime finds its scripts, under the checkout
/// `project`'s `.agents/skills`, with the skills its scripts reach by
/// path beside it (orch's required skills and `harness-ci`'s classifier),
/// one link per skill as a package install places them; the checkout's git
/// excludes each link, so its tree reads as the row made it.
pub fn install_orch_scripts(project: &Path) {
    let skills = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    let install = project.join(".agents/skills");
    std::fs::create_dir_all(&install).unwrap();
    let mut exclude = String::new();
    for name in [
        "orch",
        "communication",
        "mailbox",
        "github",
        "worktree",
        "dev",
        "decider",
        "reviewer",
        "change-scope",
        "agent-runtime",
        "harness-ci",
    ] {
        std::os::unix::fs::symlink(skills.join(name), install.join(name)).unwrap();
        exclude.push_str(&format!("/.agents/skills/{name}\n"));
    }
    if project.join(".git").is_dir() {
        let path = project.join(".git/info/exclude");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut text = std::fs::read_to_string(&path).unwrap_or_default();
        text.push_str(&exclude);
        std::fs::write(&path, text).unwrap();
    }
}

/// The github package linked under `root`'s install layout,
/// `.agents/skills/github`, where the runtime finds its repository resolver
/// and its credential ladder; a root that already links it keeps its link.
pub fn github_skill_under(root: &Path) {
    let skills = root.join(".agents/skills");
    std::fs::create_dir_all(&skills).unwrap();
    let link = skills.join("github");
    if std::fs::symlink_metadata(&link).is_err() {
        std::os::unix::fs::symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../github"),
            link,
        )
        .unwrap();
    }
}

/// Installs the `lane-host` planted at `planted` where the runtime runs
/// it, the orch scripts directory under the `project`: the fixture
/// answers from and logs to the files beside the path it runs as, so those
/// are linked to `planted` too.
pub fn install_lane_host(project: &Path, planted: &Path) {
    let orch = project.join(".agents/skills/orch");
    assert!(
        !std::fs::symlink_metadata(&orch).is_ok_and(|m| m.file_type().is_symlink()),
        "{} links the repository's own orch: a fixture planted there would land in it",
        orch.display()
    );
    let scripts = orch.join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    for name in ["lane-host", "lane-host.json", "lane-host.log"] {
        let link = scripts.join(name);
        if std::fs::symlink_metadata(&link).is_err() {
            std::os::unix::fs::symlink(planted.join(name), link).unwrap();
        }
    }
}

/// The accounts a listing lists ([`plant_listing`]), and under `host` the
/// provider's rows as its `accounts` answer in `root/lane-host.json`, the
/// host fixture linked into `root` and its capability line an SSH host's
/// where none is planted. The environment the listing reads the world under:
/// the planted listing's, the state directory and the provider.
pub fn plant_accounts(
    root: &Path,
    state: &Path,
    host: Option<&str>,
    rows: &[Value],
    now: u64,
) -> Vec<(String, String)> {
    std::fs::create_dir_all(root).unwrap();
    if host.is_some() {
        let link = root.join("lane-host");
        if std::fs::symlink_metadata(&link).is_err() {
            std::os::unix::fs::symlink(fixtures().join("lane-host/lane-host"), &link).unwrap();
        }
        install_lane_host(root, root);
    }
    let Planted {
        mut env,
        provider_lines,
    } = plant_listing(root, state, rows, now);
    env.push((
        "OVERSEE_WATCH_STATE_DIR".to_owned(),
        state.display().to_string(),
    ));
    if let Some(host) = host {
        env.push(("ORCH_LANE_HOST".to_owned(), host.to_owned()));
        let path = root.join("lane-host.json");
        let mut map: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_else(|| json!({}));
        map[format!("{host} accounts")] = json!({"stdout": provider_lines.join("")});
        if map[format!("{host} capabilities")].is_null() {
            map[format!("{host} capabilities")] = json!({"stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\tpool=plan\n"});
        }
        std::fs::write(&path, map.to_string()).unwrap();
    }
    env
}

/// A judge's reply as the hook suites' fixtures store it
/// (`hooks/tests/fixtures/pick-replies.json`): the world's home `home`
/// spelled `/home/me`.
pub fn spelled_home(reply: &Value, home: &Path) -> Value {
    let spelled = reply
        .to_string()
        .replace(&home.display().to_string(), "/home/me");
    serde_json::from_str(&spelled).unwrap()
}

/// A judge's reply as a planted one is compared with it: in
/// [`spelled_home`]'s spelling, each reset instant, reading instant,
/// reading age and selection score, figures the world's clock sets, by
/// presence.
pub fn planted_form(reply: &Value, home: &Path) -> Value {
    fn timed(reply: &Value) -> Value {
        match reply {
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| {
                        let at = k == "resets"
                            || k.ends_with("resets_at")
                            || k == "measured_at"
                            || k == "usage_age_s"
                            || k == "selection_score";
                        let v = if at && !v.is_null() {
                            json!("present")
                        } else {
                            timed(v)
                        };
                        (k.clone(), v)
                    })
                    .collect(),
            ),
            Value::Array(items) => Value::Array(items.iter().map(timed).collect()),
            other => other.clone(),
        }
    }
    timed(&spelled_home(reply, home))
}

/// The reply `hooks/tests/fixtures/pick-replies.json` plants under `shape`.
pub fn planted_pick(shape: &str) -> Value {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../hooks/tests/fixtures/pick-replies.json");
    let planted: Value = serde_json::from_str(&std::fs::read_to_string(&fixture).unwrap()).unwrap();
    planted[shape]["reply"].clone()
}

/// A copy of `sleep` named `name` under `dir`, so a pane holds a process the
/// kernel names as a harness; written by a child shell (support's reason).
pub fn named_sleep(dir: &Path, name: &str) -> PathBuf {
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

/// The identity of the pane's process once its shell has exec'd `name`.
pub fn await_named(server: &Server, pane: &str, name: &str) -> Identity {
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
pub fn await_drawn(server: &Server, pane: &str, needle: &str) {
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

/// The server start the turn-end world's stand-in answers until a row plants
/// another.
pub const TURN_SERVER_START: u64 = 1_700_000_000;

/// Every form the turn-end world's `tmux` stand-in answers, as the shell
/// `case` reads its arguments joined, and its answer: the server read a turn
/// end makes, then the reads Jarvis's terminal check makes through orch's
/// `tmux_pane_live` and Jarvis's `session-backend.sh live` (the server's pid,
/// its pane list, and one field of a pane). `$answer` is the planted server,
/// `$panes` the planted pane list; a per-pane form names the field the
/// planted pane answers. Every other call is refused.
pub const TURN_TMUX_TABLE: &[(&str, &str)] = &[
    (
        "'display-message -p #{pid} #{start_time}'",
        "exec cat '$answer'",
    ),
    (
        "'display-message -p #{pid}'",
        "read -r pid _ <'$answer'; printf '%s\\n' \"$pid\"; exit 0",
    ),
    (
        "'list-panes -a -F #{pid} #{start_time} #{pane_id} #{pane_dead}'",
        "exec cat '$panes'",
    ),
    (
        "\"display-message -p -t $4 #{session_name}\"",
        "field=session_name",
    ),
    (
        "\"display-message -p -t $4 #{window_id}\"",
        "field=window_id",
    ),
    (
        "\"display-message -p -t $4 #{@jarvis-generation}\"",
        "field=generation",
    ),
];

/// A turn end's planted world for a session with no lane item: a fleet's
/// checkout, the user's home, the fleet record under the checkout's state
/// directory, a Jarvis record under the root's state directory, and a `tmux`
/// stand-in first on `PATH`. The stand-in answers the forms of
/// [`TURN_TMUX_TABLE`] on the world's socket alone, named by `-S` or else by
/// `$TMUX`: the server read with the pid of a process the world holds that
/// the kernel names `tmux` and the start the row plants, and the pane reads
/// from the panes the row plants; it logs every call and refuses every
/// other, so no row reaches a real server. The fleet record's controller
/// names a harness process the world holds, so its liveness is read off a
/// live process and never asks a server.
pub struct TurnWorld {
    _dir: TempDir,
    pub root: PathBuf,
    pub home: PathBuf,
    pub checkout: PathBuf,
    pub socket: PathBuf,
    server: Owned,
    harness: Owned,
}

/// What the harness was handed.
pub struct TurnOut {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl TurnOut {
    /// The keyed lines on stderr: each `lane-mail-check: key=value` line,
    /// the explanation under it left out.
    pub fn keyed(&self) -> Vec<&str> {
        self.stderr
            .lines()
            .filter_map(|line| line.strip_prefix("lane-mail-check: "))
            .collect()
    }
}

impl TurnWorld {
    pub fn new() -> TurnWorld {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let home = root.join("home");
        let checkout = root.join("fleet");
        for made in [
            &home,
            &checkout,
            &root.join("stand-ins"),
            &root.join("state"),
        ] {
            std::fs::create_dir_all(made).unwrap();
        }
        for args in [
            &["init", "-q"][..],
            &["config", "gc.auto", "0"],
            &["config", "maintenance.auto", "false"],
            &["checkout", "-q", "-b", "main"],
            &["commit", "-q", "--allow-empty", "-m", "base"],
        ] {
            let out = program("git")
                .arg("-C")
                .arg(&checkout)
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        }
        let named = named_sleep(&root, "tmux");
        let server = Owned(Command::new(named).arg("600").spawn().expect("tmux holder"));
        let socket = root.join("tmux-socket");
        let world = TurnWorld {
            _dir: dir,
            home,
            checkout,
            socket,
            server,
            harness: Owned::sleep(),
            root,
        };
        let table: String = TURN_TMUX_TABLE
            .iter()
            .map(|(form, answer)| format!("  {form}) {answer} ;;\n"))
            .collect();
        let text = format!(
            "#!/bin/sh\nsocket=${{TMUX%%,*}}\nif [ \"$1\" = -S ]; then socket=$2; shift 2; fi\nprintf '%s\\n' \"$*\" >>'{calls}'\nif [ \"$socket\" != '{socket}' ]; then\n  printf 'no server running on %s\\n' \"$socket\" >&2\n  exit 1\nfi\nfield=\ncase \"$*\" in\n{table}esac\nif [ -n \"$field\" ]; then\n  [ -f \"$planted/$4/$field\" ] || {{ printf \"can't find pane: %s\\n\" \"$4\" >&2; exit 1; }}\n  exec cat \"$planted/$4/$field\"\nfi\nprintf 'tmux stand-in: no answer for: %s\\n' \"$*\" >&2\nexit 1\n",
            calls = world.root.join("tmux-calls").display(),
            socket = world.socket.display(),
        )
        .replace("$answer", &world.root.join("tmux-server").display().to_string())
        .replace("$panes", &world.root.join("tmux-panes").display().to_string())
        .replace("$planted", &world.root.join("tmux-pane").display().to_string());
        write_executable(&world.stand_ins().join("tmux"), text);
        world.serve(TURN_SERVER_START);
        world
    }

    /// Plants `pane` on the stand-in's server at the start it serves now:
    /// its row in the server's pane list, dead or alive, and the session
    /// name, window id and Jarvis generation a per-pane read answers.
    pub fn plant_pane(
        &self,
        pane: &str,
        session: &str,
        window: &str,
        generation: &str,
        dead: bool,
    ) {
        use std::io::Write;
        let served = std::fs::read_to_string(self.root.join("tmux-server")).unwrap();
        let mut panes = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.root.join("tmux-panes"))
            .unwrap();
        writeln!(panes, "{} {pane} {}", served.trim_end(), u8::from(dead)).unwrap();
        let dir = self.root.join("tmux-pane").join(pane);
        std::fs::create_dir_all(&dir).unwrap();
        for (field, value) in [
            ("session_name", session),
            ("window_id", window),
            ("generation", generation),
        ] {
            std::fs::write(dir.join(field), format!("{value}\n")).unwrap();
        }
    }

    /// Installs Jarvis's session owner under `project`'s `.agents/skills`
    /// as a package install lays it: the `scripts` of jarvis, and of the
    /// mailbox and orch it sources beside it, each linked to this
    /// checkout's own; the checkout's git excludes the install.
    pub fn install_jarvis(&self, project: &Path) {
        let skills = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap();
        for name in ["jarvis", "mailbox", "orch"] {
            let package = project.join(".agents/skills").join(name);
            std::fs::create_dir_all(&package).unwrap();
            std::os::unix::fs::symlink(skills.join(name).join("scripts"), package.join("scripts"))
                .unwrap();
        }
        let exclude = project.join(".git/info/exclude");
        if exclude.parent().unwrap().is_dir() {
            let mut text = std::fs::read_to_string(&exclude).unwrap_or_default();
            text.push_str("/.agents/\n");
            std::fs::write(&exclude, text).unwrap();
        }
    }

    /// A running Jarvis record of a `harness` session with the native id
    /// `session`, launched as `generation` with `account` its account
    /// directory, on `pane` (window `@7`) of the stand-in's server at its
    /// planted start: what [`TurnWorld::plant_jarvis`] completes and
    /// [`TurnWorld::plant_pane`] answers for.
    pub fn jarvis_session(
        &self,
        pane: &str,
        harness: &str,
        session: &str,
        generation: &str,
        account: &Path,
    ) -> Value {
        json!({
            "state": "running",
            "reason": "resumed",
            "harness": harness,
            "account": account.display().to_string(),
            "generation": generation,
            "pending": { "generation": generation, "native_session_id": session, "started_at": 1 },
            "terminal": { "server": self.socket.display().to_string(), "pane": pane, "window": "@7" },
            "server_pid": self.server_pid(),
            "server_started_at": TURN_SERVER_START,
        })
    }

    /// The directory first on the verb's `PATH`.
    pub fn stand_ins(&self) -> PathBuf {
        self.root.join("stand-ins")
    }

    /// The install directory of `harness` under the root.
    pub fn hooks(&self, harness: &str) -> PathBuf {
        let dir = match harness {
            "claude" => ".claude/hooks",
            "codex" => ".codex/hooks",
            "copilot" => ".github/hooks",
            "pi" => ".pi/kendex/hooks",
            other => panic!("no install directory for {other}"),
        };
        self.root.join("install").join(dir)
    }

    /// The pid of the server the stand-in answers for.
    pub fn server_pid(&self) -> u32 {
        self.server.pid()
    }

    /// The stand-in's server answers `start` from now on.
    pub fn serve(&self, start: u64) {
        std::fs::write(
            self.root.join("tmux-server"),
            format!("{} {start}\n", self.server_pid()),
        )
        .unwrap();
    }

    /// The calls the stand-in took, one line each, the socket left out.
    pub fn tmux_calls(&self) -> Vec<String> {
        std::fs::read_to_string(self.root.join("tmux-calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The environment of a session on `pane` of the stand-in's server.
    pub fn on_pane(&self, pane: &str) -> Vec<(String, String)> {
        vec![
            (
                "TMUX".to_owned(),
                format!("{},{},0", self.socket.display(), self.server_pid()),
            ),
            ("TMUX_PANE".to_owned(), pane.to_owned()),
        ]
    }

    /// The fleet record under the checkout's default state directory.
    pub fn fleet_path(&self) -> PathBuf {
        self.checkout
            .join("tmp")
            .join(agent_runtime::record::FLEET_FILE_NAME)
    }

    /// A controller member naming `pane` on the stand-in's server at its
    /// planted start, the world's harness process, and the harness, launch
    /// home and native session id given; for a harness the planter measures,
    /// the account [`TurnWorld::overseer_account`] plants, so its marks read a
    /// measured answer.
    pub fn controller(&self, pane: &str, harness: &str, home: &Path, session: &str) -> Value {
        let mut member = self.member(pane, harness, home, session);
        if let Some(account) = self.overseer_account(harness) {
            member["account"] = json!(account.display().to_string());
        }
        member
    }

    /// The account records' root a turn reads: the default under the
    /// `XDG_STATE_HOME` [`TurnWorld::turn`] names.
    pub fn account_state(&self) -> PathBuf {
        self.root.join("state/kendex/agent-runtime/accounts")
    }

    /// The account a bound overseer on `harness` spends, planted measured
    /// under the root: its directory with its credential, and under
    /// [`TurnWorld::account_state`] its usage record, 90 percent headroom,
    /// rated far from the wall. `None` for a harness the planter has no usage
    /// body for (Pi).
    pub fn overseer_account(&self, harness: &str) -> Option<PathBuf> {
        if !matches!(harness, "claude" | "codex" | "copilot") {
            return None;
        }
        let now = now_ms() / 1000;
        let iso = |secs: u64| agent_runtime::clock::iso_utc(now + secs);
        let monthly = harness == "copilot";
        let mut row = json!({
            "alias": format!("{harness}-overseer"),
            "harness": harness,
            "config_dir": format!("/overseer/.{harness}"),
            "measured_through": "local",
            "status": "ok",
            "headroom_pct": 90,
            "binding_bucket": if monthly { "monthly" } else { "weekly" },
            "binding_resets_at": iso(60 * 3600),
            "session_5h_pct": 5,
            "weekly_pct": 10,
            "monthly_pct": if monthly { json!(10) } else { Value::Null },
            "model_buckets": [],
            "resets": {"session": iso(3600), "weekly": iso(60 * 3600), "model": null,
                       "monthly": if monthly { json!(iso(60 * 3600)) } else { Value::Null }},
            "usage_rate_state": "measured",
            "usage_rate_pct_per_min": 0.005,
            "usage_age_s": 0,
        });
        if monthly {
            row["plan"] = json!("individual");
        }
        let root = self.root.join("overseer").join(harness);
        plant_listing(&root, &self.account_state(), &[row], now);
        Some(root.join("home").join(format!(".{harness}")))
    }

    /// Removes the account [`TurnWorld::overseer_account`] planted for
    /// `harness`, its directory and its usage record, so a member naming it
    /// spends an account nothing measures.
    pub fn unmeasure_overseer(&self, harness: &str) {
        let root = self.root.join("overseer").join(harness);
        let dir = root.join("home").join(format!(".{harness}"));
        let dir_text = dir.display().to_string();
        let record = self.account_state().join("usage").join(format!(
            "{harness}-{}-{}.json",
            agent_runtime::record::cksum(dir_text.as_bytes()),
            dir_text.len()
        ));
        if record.exists() {
            std::fs::remove_file(&record).unwrap();
        }
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
    }

    fn member(&self, pane: &str, harness: &str, home: &Path, session: &str) -> Value {
        json!({
            "runtime": "tmux",
            "generation": 1,
            "server": self.server_pid().to_string(),
            "server_start": TURN_SERVER_START,
            "server_socket": self.socket.display().to_string(),
            "pane": pane,
            "window": "@1",
            "harness_pid": self.harness.pid().to_string(),
            "harness_start": self.harness.start(),
            "harness": harness,
            "home": home.display().to_string(),
            "session_id": session,
            "cwd": self.checkout.display().to_string(),
        })
    }

    /// The fleet record holding `member` as its controller.
    pub fn plant_fleet(&self, member: Value) {
        let path = self.fleet_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, json!({ "overseer": member }).to_string()).unwrap();
    }

    pub fn fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_path()).unwrap()).unwrap()
    }

    /// The Jarvis runtime record of the managed home `home`, where Jarvis's
    /// own reader looks for it under the root's state directory, holding
    /// `record` with the home and record version Jarvis writes.
    pub fn plant_jarvis(&self, home: &Path, mut record: Value) -> PathBuf {
        let home = std::fs::canonicalize(home).unwrap();
        let out = program("python3")
            .args([
                "-I",
                "-c",
                "import hashlib, os, sys; print(hashlib.sha256(os.fsencode(sys.argv[1])).hexdigest())",
            ])
            .arg(&home)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let key = String::from_utf8(out.stdout).unwrap();
        let path = self
            .root
            .join("state/kendex/jarvis")
            .join(key.trim())
            .join("jarvis-session.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        record["v"] = json!(1);
        record["home"] = json!(home.display().to_string());
        std::fs::write(&path, record.to_string()).unwrap();
        path
    }

    /// The verb run from `dir` under `harness`'s install, with `env` added.
    pub fn turn(
        &self,
        dir: &Path,
        harness: &str,
        args: &[&str],
        payload: &str,
        env: &[(String, String)],
    ) -> TurnOut {
        use std::io::Write;
        let mut command = isolated();
        command
            .arg("turn-end")
            .arg("--hook-dir")
            .arg(self.hooks(harness))
            .args(args)
            .current_dir(dir)
            .env("PWD", dir)
            .env("HOME", &self.home)
            .env("XDG_STATE_HOME", self.root.join("state"))
            .env("PATH", tool_path(&[&self.stand_ins()]))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (name, value) in env {
            command.env(name, value);
        }
        let mut child = command.spawn().expect("orch-runtime");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(payload.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        TurnOut {
            code: out.status.code().expect("an exit status"),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }
}
