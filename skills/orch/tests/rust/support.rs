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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

use agent_runtime::process::Identity;
use orch_runtime::error::Error;
use orch_runtime::schedule::Clock;
use orch_runtime::watch;

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

/// `name` as a test child under [`isolation_env`]: the one constructor for
/// every program a row starts that reads a home or a configuration (`git`,
/// a shipped script), so no row's own start reaches the operator's files,
/// such as `~/.gitconfig` and its includes.
pub fn program(name: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(name);
    isolation_env(&mut command);
    command
}

/// Git's ceilings for a test child: the temporary root and, where these
/// tests live in a repository (a clean copy of the index does not), its
/// root, so a row that hands the binary a fixture path inside the
/// repository (`tests/rust/fixtures/...`) resolves no project root there
/// either; git stops below each ceiling, never at it.
fn ceilings(root: &Path) -> std::ffi::OsString {
    let mut ceilings = root.as_os_str().to_owned();
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while dir.pop() {
        if std::fs::symlink_metadata(dir.join(".git")).is_ok() {
            ceilings.push(":");
            ceilings.push(dir.as_os_str());
            break;
        }
    }
    ceilings
}

/// The environment a test child runs with: cleared, then the tools' path,
/// the locale, the temporary root, a scratch home under that root (a tool
/// that reads a home, `gh` or `git`, finds nothing of the operator there),
/// a fixed git identity (a fixture commit needs one, and the operator's
/// is in the configuration no child reads) and git's ceiling at the root,
/// so no checkout above a test directory is a project root
/// (`settings::roots` then reads the working directory). A row adds what
/// it needs after. [`program`] applies it to a program a row starts,
/// [`isolated`] to the binary, and the private tmux server to every pane.
pub fn isolation_env(command: &mut Command) -> &mut Command {
    let root = std::env::temp_dir();
    let home = root.join("isolated-home");
    std::fs::create_dir_all(&home).expect("the scratch home");
    command
        .env_clear()
        .env("PATH", tool_path(&[]))
        .env(
            "LANG",
            std::env::var_os("LANG").unwrap_or_else(|| "C.UTF-8".into()),
        )
        .env("TMPDIR", &root)
        .env("HOME", &home)
        .env("GIT_CEILING_DIRECTORIES", ceilings(&root));
    for (name, value) in [
        ("GIT_AUTHOR_NAME", "t"),
        ("GIT_AUTHOR_EMAIL", "t@t"),
        ("GIT_COMMITTER_NAME", "t"),
        ("GIT_COMMITTER_EMAIL", "t@t"),
    ] {
        command.env(name, value);
    }
    command
}

/// The tools directory under the temporary root that every test child sees
/// on `PATH` after a row's own prefixes: a `gh` that refuses, so a row that
/// names no `gh` fixture never reaches the operator's real `gh` by omission
/// (a real `gh` under the scratch home starts `gh send-telemetry` and
/// connects out), and a `loginctl` answering that the user manager does not
/// linger, so a detached job's launcher takes its `setsid` route and no row
/// starts a unit on the operator's user manager; a row that wants the unit
/// route plants its own manager fakes ahead of this directory. Each tool is
/// written once per process through [`publish`] (the rows of one test
/// binary start together on a cold temporary root).
fn isolated_bin() -> PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join("isolated-bin");
        std::fs::create_dir_all(&dir).expect("the isolated tools directory");
        for (name, text) in [
            (
                "gh",
                "#!/bin/sh\nprintf 'gh: no fixture on PATH answers: %s\\n' \"$*\" >&2\nexit 4\n",
            ),
            ("loginctl", "#!/bin/sh\necho no\n"),
        ] {
            publish(&dir, name, text);
        }
        dir
    })
    .clone()
}

/// `text` as the executable `dir/name`, kept where the file already holds
/// it, else written under a name no other process or thread uses and
/// renamed into place, so test binaries writing it at once all read one
/// whole file.
fn publish(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    if std::fs::read_to_string(&path).is_ok_and(|held| held == text) {
        return path;
    }
    let tmp = dir.join(format!(
        ".{name}.{}.{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    write_executable(&tmp, text);
    std::fs::rename(&tmp, &path).expect("a published executable in place");
    path
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

/// A test child's `PATH`: a row's own `prefixes` first, then the isolated
/// tools directory, then the path this process inherited. Every row that
/// sets `PATH` composes it here, so a prefix never drops the refusing `gh`.
pub fn tool_path(prefixes: &[&Path]) -> String {
    let mut parts: Vec<String> = prefixes.iter().map(|p| p.display().to_string()).collect();
    parts.push(isolated_bin().display().to_string());
    parts.push(std::env::var("PATH").unwrap_or_default());
    parts.join(":")
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

/// `text` as the executable `path`, written by a child process. A file this
/// test process holds open for writing is held by every other test thread's
/// child between its fork and its exec as well, and running it then fails
/// `ETXTBSY`; a rename into place keeps that same file, so it does not help.
/// The child takes this process's `PATH`, not [`isolation_env`]'s: the tools
/// that path names are written here.
pub fn write_executable(path: &Path, text: impl AsRef<str>) {
    let out = Command::new("sh")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args([
            "-c",
            "printf '%s' \"$1\" > \"$2\" && chmod 755 \"$2\"",
            "write-executable",
        ])
        .arg(text.as_ref())
        .arg(path)
        .output()
        .expect("sh");
    assert!(
        out.status.success(),
        "write-executable {}: {}",
        path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
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
/// on drop so a panicking test still reaps it. It reads no configuration
/// file and names its pane shell, so the host's `~/.tmux.conf` and login
/// shell reach no row.
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
            env: Vec::new(),
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
    /// plants asks through `LANE_MAIL_ASKS` in `env`), the bound, the tools
    /// and the runner's own entries; the same for a child that is not the
    /// binary itself, such as the detached line the wall route starts.
    pub fn apply_env(&self, command: &mut Command) {
        command
            .env("TMUX", format!("{},0,0", self.server_socket.display()))
            .env("ORCH_TMUX_SESSION", &self.session)
            .env(
                "ORCH_HARNESS_BINARIES",
                format!("claude={}", self.stub.display()),
            )
            .env(
                "LANE_MAIL_CLI",
                fixtures().join("lane-mail-quiet/lane-mail"),
            )
            .env(
                "DEV_VALIDATE_CLI",
                fixtures().join("dev-validate-quiet/dev-validate-run"),
            );
        if let Some(verify) = self.verify {
            command.env("ORCH_TMUX_VERIFY_SECS", verify.to_string());
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

    /// The fleet state initialized, in a state directory that is also a
    /// checkout: a launch into it writes the launch record under its git
    /// directory, as every lane's root holds one.
    pub fn init_fleet(&self) {
        let out = program("git")
            .args(["-C", &self.state_dir().display().to_string(), "init", "-q"])
            .output()
            .expect("git");
        assert!(out.status.success(), "git init: {}", stderr(&out));
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

/// A usage record as the listing's cache holds it, planted beside the
/// account: `<state>/usage/<harness>-<cksum>-<len>.json`.
fn usage_record_path(state: &Path, harness: &str, config_dir: &str) -> PathBuf {
    state.join("usage").join(format!(
        "{harness}-{}-{}.json",
        orch_runtime::ops::wall::cksum(config_dir.as_bytes()),
        config_dir.len()
    ))
}

/// A Claude usage body that reads as the row's windows: the 5-hour and
/// weekly windows with their resets, the model-scoped windows, and the
/// cloud credit where the row carries a dollar grant. A row naming no
/// weekly window but a headroom takes `100 - headroom` as its weekly use.
fn claude_body(row: &Value) -> Value {
    let resets = &row["resets"];
    let mut body = json!({});
    if let Some(session) = row["session_5h_pct"].as_f64() {
        body["five_hour"] = json!({"utilization": session, "resets_at": resets["session"]});
    }
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    if let Some(weekly) = weekly {
        let reset = if resets["weekly"].is_null() {
            row["binding_resets_at"].clone()
        } else {
            resets["weekly"].clone()
        };
        body["seven_day"] = json!({"utilization": weekly, "resets_at": reset});
    }
    if let Some(buckets) = row["model_buckets"].as_array() {
        body["limits"] = Value::Array(
            buckets
                .iter()
                .map(|b| {
                    json!({"kind": "weekly_scoped", "percent": b["pct"], "resets_at": b["resets_at"],
                           "scope": {"model": {"display_name": b["label"]}}})
                })
                .collect(),
        );
    }
    if row["credits"]["unit"] == json!("usd") {
        let c = &row["credits"];
        body["iguana_necktie"] = json!({
            "limit_dollars": c["limit_dollars"], "used_dollars": c["used_dollars"],
            "remaining_dollars": c["remaining_dollars"], "resets_at": c["resets_at"],
            "locked_reason": c["locked_reason"],
        });
    }
    body
}

/// A Codex usage body that reads as the row's windows and credits.
fn codex_body(row: &Value) -> Value {
    let resets = &row["resets"];
    let epoch = |v: &Value| v.as_str().and_then(agent_runtime::clock::epoch_secs);
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    let mut body = json!({"rate_limit": {
        "primary_window": row["session_5h_pct"].as_f64().map(|p| json!({
            "used_percent": p, "reset_at": epoch(&resets["session"]), "limit_window_seconds": 18_000})),
        "secondary_window": weekly.map(|p| json!({
            "used_percent": p,
            "reset_at": epoch(if resets["weekly"].is_null() { &row["binding_resets_at"] } else { &resets["weekly"] }),
            "limit_window_seconds": 604_800})),
    }});
    if row["credits"].is_object() {
        let c = &row["credits"];
        body["credits"] = json!({"has_credits": c["has_credits"], "unlimited": c["unlimited"],
            "overage_limit_reached": c["overage_limit_reached"], "balance": c["balance"]});
        body["spend_control"] = json!({"reached": c["spend_control_reached"]});
    }
    body
}

/// A Copilot usage body that reads as the row's monthly pool.
fn copilot_body(row: &Value) -> Value {
    let granted = row["credits"]["granted"].as_f64().unwrap_or(100.0);
    let pct = row["monthly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h))
        .unwrap_or(0.0);
    json!({
        "copilot_plan": row["plan"],
        "quota_reset_date_utc": row["resets"]["monthly"],
        "quota_snapshots": {"premium_interactions": {
            "entitlement": granted, "remaining": granted - (pct * granted / 100.0).ceil()}},
    })
}

/// The accounts a listing lists, planted from rows in the listing's own
/// record shape: a row measured through `local` is a directory under
/// `root/home` named as the row's `config_dir` is (under the planted
/// path itself where two rows share a name), holding the credential its
/// `status` reads as (`expired` a token past its expiry, `no_credentials`
/// none, `error` a file that is not JSON) and, under `state/usage`, the
/// record its figure or refusal reads as; a row measured through `host` is
/// one line of the provider's `accounts` answer in `root/lane-host.json`
/// under `host`, the host fixture linked into `root` and its capability
/// line an SSH host's where none is planted. Directories under `root/home`
/// the rows no longer name are removed, and the provider's cached answer
/// with them. The environment the listing reads the world under: the
/// home, the state directory, the provider, and the planted directories as
/// the configured ones, since a planted name need not carry its harness's
/// word.
pub fn plant_accounts(
    root: &Path,
    state: &Path,
    host: Option<&str>,
    rows: &[Value],
    now: u64,
) -> Vec<(String, String)> {
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mut env = vec![
        ("HOME".to_owned(), home.display().to_string()),
        (
            "OVERSEE_WATCH_STATE_DIR".to_owned(),
            state.display().to_string(),
        ),
    ];
    if let Some(host) = host {
        env.push(("ORCH_LANE_HOST".to_owned(), host.to_owned()));
        env.push((
            "OVERSEE_WATCH_LANES".to_owned(),
            root.join("lanes").display().to_string(),
        ));
        let link = root.join("lane-host");
        if std::fs::symlink_metadata(&link).is_err() {
            std::os::unix::fs::symlink(fixtures().join("lane-host/lane-host"), &link).unwrap();
        }
    }
    let mut provider_lines = Vec::new();
    let mut local_dirs: Vec<PathBuf> = Vec::new();
    for row in rows {
        let through = row["measured_through"].as_str().unwrap_or("local");
        let config_dir = row["config_dir"].as_str().unwrap().to_owned();
        if through == "host" {
            provider_lines.push(provider_line(row, &config_dir));
            continue;
        }
        let name = Path::new(&config_dir).file_name().unwrap().to_owned();
        let dir = if local_dirs.iter().any(|d| d.file_name() == Some(&name)) {
            root.join(config_dir.trim_start_matches('/'))
        } else {
            home.join(&name)
        };
        plant_local(&dir, state, row, now);
        local_dirs.push(dir);
    }
    for entry in std::fs::read_dir(&home).unwrap().flatten() {
        let keep = local_dirs.iter().any(|d| *d == entry.path());
        if !keep && entry.file_name().to_string_lossy().starts_with('.') {
            std::fs::remove_dir_all(entry.path()).unwrap();
        }
    }
    env.push((
        "ORCH_LANE_DIRS".to_owned(),
        local_dirs
            .iter()
            .map(|d| d.display().to_string())
            .collect::<Vec<String>>()
            .join(":"),
    ));
    for entry in std::fs::read_dir(state.join("usage"))
        .into_iter()
        .flatten()
        .flatten()
    {
        if entry
            .file_name()
            .to_string_lossy()
            .starts_with("lane-host-")
        {
            std::fs::remove_file(entry.path()).unwrap();
        }
    }
    if let Some(host) = host {
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

/// One `accounts` line for a provider's row: the words and windows the
/// row carries, as the provider states them.
fn provider_line(row: &Value, account: &str) -> String {
    let mut fields = vec![
        format!("account={account}"),
        format!("harness={}", row["harness"].as_str().unwrap_or("claude")),
    ];
    if let Some(status) = row["status"].as_str().filter(|s| *s != "ok") {
        fields.push(format!("status={status}"));
    }
    if let Some(detail) = row["detail"].as_str() {
        fields.push(format!("detail={detail}"));
    }
    let resets = &row["resets"];
    let weekly = row["weekly_pct"]
        .as_f64()
        .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h));
    let weekly_reset = if resets["weekly"].is_null() {
        &row["binding_resets_at"]
    } else {
        &resets["weekly"]
    };
    for (key, value, reset_key, reset) in [
        (
            "session-5h",
            row["session_5h_pct"].as_f64(),
            "session",
            &resets["session"],
        ),
        ("weekly", weekly, "weekly", weekly_reset),
        (
            "monthly",
            row["monthly_pct"].as_f64(),
            "monthly",
            &resets["monthly"],
        ),
    ] {
        if let Some(pct) = value {
            fields.push(format!("{key}-pct={}", pct as u64));
            if let Some(reset) = reset.as_str() {
                fields.push(format!("{reset_key}-resets={reset}"));
            }
        }
    }
    if let Some(bucket) = row["model_buckets"].as_array().and_then(|b| b.first()) {
        if let Some(pct) = bucket["pct"].as_f64() {
            fields.push(format!("model-pct={}", pct as u64));
        }
        if let Some(label) = bucket["label"].as_str() {
            fields.push(format!("model-label={label}"));
        }
        if let Some(reset) = bucket["resets_at"].as_str() {
            fields.push(format!("model-resets={reset}"));
        }
    }
    if row["credits"]["unit"] == json!("usd") {
        let c = &row["credits"];
        fields.push(format!(
            "credit-limit={}",
            c["limit_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-spent={}",
            c["used_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-remaining={}",
            c["remaining_dollars"].as_f64().unwrap_or(0.0)
        ));
        fields.push(format!(
            "credit-expires={}",
            c["resets_at"].as_str().unwrap_or("")
        ));
    }
    for (key, name) in [
        ("plan_ends", "plan-ends"),
        ("plan-ends", "plan-ends"),
        ("reserved", "reserved"),
        ("seat", "seat"),
    ] {
        match &row[key] {
            Value::Null => {}
            Value::String(s) => fields.push(format!("{name}={s}")),
            other => fields.push(format!("{name}={other}")),
        }
    }
    format!("{}\n", fields.join("\t"))
}

/// One local account: its directory, its credential as the row's status
/// reads, and its usage record.
fn plant_local(dir: &Path, state: &Path, row: &Value, now: u64) {
    let harness = row["harness"].as_str().unwrap_or("claude");
    let alias = row["alias"].as_str().unwrap_or("account");
    let status = row["status"].as_str().unwrap_or("ok");
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).unwrap();
    let config_dir = dir.display().to_string();
    let expires_ms = if status == "expired" {
        (now - 3600) * 1000
    } else {
        (now + 365 * 86_400) * 1000
    };
    let credential = match harness {
        "claude" => json!({"claudeAiOauth": {
            "accessToken": format!("token-{alias}"), "refreshToken": format!("refresh-{alias}"),
            "expiresAt": expires_ms, "refreshTokenExpiresAt": expires_ms,
            "subscriptionType": row["plan"].as_str().unwrap_or("max")}})
        .to_string(),
        "codex" => json!({"tokens": {"access_token": format!("token-{alias}"), "account_id": format!("acct-{alias}")}}).to_string(),
        _ => json!({"copilotTokens": format!("token-{alias}")}).to_string(),
    };
    let file = match harness {
        "claude" => ".credentials.json",
        "codex" => "auth.json",
        _ => "config.json",
    };
    match status {
        "no_credentials" => std::fs::write(dir.join(".claude.json"), "{}\n").unwrap(),
        "error" => std::fs::write(dir.join(file), "not json\n").unwrap(),
        _ => std::fs::write(dir.join(file), credential).unwrap(),
    }
    let record = usage_record_path(state, harness, &config_dir);
    std::fs::create_dir_all(record.parent().unwrap()).unwrap();
    let _ = std::fs::remove_file(&record);
    let age = row["usage_age_s"].as_u64().unwrap_or(0);
    let body = match harness {
        "claude" => claude_body(row),
        "codex" => codex_body(row),
        _ => copilot_body(row),
    };
    let refusal = |status: &str, code: &str| {
        json!({"endpoint": "usage", "status": status, "code": code,
               "detail": row["detail"].as_str().unwrap_or(&format!("usage query refused with HTTP {code}")),
               "expires_at": now + 300})
    };
    // A row the listing rated carries the sample it rated against: the
    // binding window three points lower, as many seconds earlier as the
    // rate names.
    let prior = row["usage_rate_pct_per_min"]
        .as_f64()
        .filter(|r| *r > 0.0 && row["usage_rate_state"] == json!("measured"))
        .map(|rate| {
            let elapsed = (3.0 * 60.0 / rate).round() as u64;
            let mut earlier = row.clone();
            if row["binding_bucket"] == json!("model") {
                let buckets = earlier["model_buckets"].as_array_mut().unwrap();
                let fullest = (0..buckets.len())
                    .max_by(|a, b| {
                        buckets[*a]["pct"]
                            .as_f64()
                            .unwrap_or(0.0)
                            .total_cmp(&buckets[*b]["pct"].as_f64().unwrap_or(0.0))
                    })
                    .unwrap();
                let pct = buckets[fullest]["pct"].as_f64().unwrap();
                buckets[fullest]["pct"] = json!(pct - 3.0);
            } else {
                let key = match row["binding_bucket"].as_str() {
                    Some("session") => "session_5h_pct",
                    Some("monthly") => "monthly_pct",
                    _ => "weekly_pct",
                };
                let pct = row[key]
                    .as_f64()
                    .or_else(|| row["headroom_pct"].as_f64().map(|h| 100.0 - h))
                    .unwrap_or(0.0);
                earlier[key] = json!(pct - 3.0);
            }
            let body = match harness {
                "claude" => claude_body(&earlier),
                "codex" => codex_body(&earlier),
                _ => copilot_body(&earlier),
            };
            json!({"fetched_at": now - age - elapsed, "usage": body})
        })
        .unwrap_or(Value::Null);
    let value = match status {
        "ok" | "no_usage_data" => json!({"harness": harness, "config_dir": config_dir,
            "fetched_at": now - age, "usage": body, "sample_claims": 1, "prior": prior}),
        "rate_limited" => json!({"harness": harness, "config_dir": config_dir, "fetched_at": now,
            "usage_fetched_at": now - age, "usage": body, "sample_claims": 1,
            "refusal": refusal("rate_limited", "429")}),
        "unreachable" => {
            json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("unreachable", "503")})
        }
        "refused" => json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("refused", "403")}),
        "plan_ended" => {
            json!({"harness": harness, "config_dir": config_dir, "fetched_at": now - age,
            "refusal": refusal("plan_ended", "403")})
        }
        _ => return,
    };
    std::fs::write(&record, value.to_string()).unwrap();
    // The record is older than the credential it reads: a credential newer
    // than the record is a renewed login whose figure is another's.
    let at = std::time::UNIX_EPOCH + Duration::from_secs(now.saturating_sub(age + 1));
    for path in [dir.join(file), dir.join(".claude.json")] {
        if let Ok(f) = std::fs::File::open(&path) {
            let _ = f.set_modified(at);
        }
    }
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
