//! Where a session's process runs. A host owns opening the place the
//! harness runs in, reading its screen, typing into it and closing it; the
//! harness adapter owns everything the harness itself emits.

// Every pane reading and close is matched variant by variant, here and in
// the tmux host below.
#![deny(clippy::wildcard_enum_match_arm)]

pub mod tmux;

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use crate::error::{Error, Result};

/// Who asked for a run: the name a failure reports, the step it was on and
/// the duty the start is counted under.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Caller {
    /// The program as the caller knows it, the name a failure reports.
    pub program: &'static str,
    pub operation: &'static str,
    /// The duty the start is counted under; `None` counts it under the
    /// executable's name alone.
    pub tag: Option<&'static str>,
}

/// A run that gave no `Output`.
#[derive(Debug)]
pub(crate) enum Failed {
    /// The executable never started; the error's kind tells a program
    /// missing from `PATH` from the rest.
    Spawn(std::io::Error),
    /// It started and gave no answer within the bound, or a pipe could not
    /// be read.
    Answer(String),
    /// The working directory asked for cannot be entered; nothing started.
    /// Read before the spawn, since a child's failed `chdir` reports the
    /// same `NotFound` as a missing executable.
    Cwd(String),
}

impl Failed {
    pub fn cause(&self) -> String {
        match self {
            Failed::Spawn(e) => e.to_string(),
            Failed::Answer(cause) | Failed::Cwd(cause) => cause.clone(),
        }
    }

    pub fn into_error(self, caller: Caller) -> Error {
        let cause = self.cause();
        match self {
            Failed::Spawn(_) | Failed::Cwd(_) => Error::NotStarted {
                program: caller.program,
                operation: caller.operation,
                cause,
            },
            Failed::Answer(_) => Error::External {
                program: caller.program,
                operation: caller.operation,
                cause,
            },
        }
    }
}

/// One key of the start counter: the executable's file name and the
/// caller's tag.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct StartKey {
    pub program: String,
    pub tag: Option<&'static str>,
}

/// Every process the runner has started in this process since it began or
/// since the last `reset_counts`, by key. The total is the sum over keys.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Counts(BTreeMap<StartKey, u64>);

impl Counts {
    pub fn total(&self) -> u64 {
        self.0.values().sum()
    }

    pub fn of(&self, program: &str, tag: Option<&'static str>) -> u64 {
        let key = StartKey {
            program: program.to_owned(),
            tag,
        };
        self.0.get(&key).copied().unwrap_or(0)
    }

    pub fn by_key(&self) -> impl Iterator<Item = (&StartKey, u64)> {
        self.0.iter().map(|(key, n)| (key, *n))
    }
}

// One lock over the whole map, not an atomic per key: the key set is open
// (any executable name), so there is no table to hold atomics in before
// the first start, and a snapshot read under the same lock is consistent
// across keys. The guarded work is one map increment beside a fork+exec.
// A panic cannot leave the map half-updated, so a poisoned lock is read
// through.
static STARTS: Mutex<BTreeMap<StartKey, u64>> = Mutex::new(BTreeMap::new());

fn count_start(executable: &OsStr, tag: Option<&'static str>) {
    let program = Path::new(executable)
        .file_name()
        .unwrap_or(executable)
        .to_string_lossy()
        .into_owned();
    let mut starts = STARTS.lock().unwrap_or_else(PoisonError::into_inner);
    *starts.entry(StartKey { program, tag }).or_insert(0) += 1;
}

/// A snapshot of the start counter.
pub fn counts() -> Counts {
    Counts(
        STARTS
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone(),
    )
}

/// Zero the start counter, so a measurement window starts from nothing.
pub fn reset_counts() {
    STARTS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
}

/// Where a child runs: its working directory and what its environment adds
/// to the runtime's own. The default is the runtime's own directory and
/// environment.
#[derive(Debug, Clone, Copy, Default)]
pub struct Place<'a> {
    /// The child's working directory; `None` is the runtime's own. It is
    /// read before anything starts: a directory that cannot be entered fails
    /// the run with its cause, and no process starts or is counted.
    pub cwd: Option<&'a Path>,
    /// Added to the environment the child inherits, in order, so a name
    /// given twice takes its last value. Nothing is removed: a child that
    /// runs a shell script still reads `PATH`, `HOME` and the harness
    /// variables.
    pub env: &'a [(&'a str, &'a OsStr)],
}

/// Every external program this crate drives starts here: prompts closed,
/// a bound on every call, every start counted. `program` is the executable
/// as found on `PATH` and the name a failure reports.
pub(crate) fn run_with(
    program: &'static str,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: None,
    };
    let place = Place { cwd: None, env };
    start(
        caller,
        OsStr::new(program),
        args,
        place,
        stdin,
        false,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// The same runner for an executable named by path, for a consumer crate
/// that drives a program at a configured location: `program` is the name
/// a failure reports, `executable` what runs. The child inherits the
/// caller's environment plus `env`.
pub fn run(
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: None,
    };
    start(
        caller,
        executable.as_os_str(),
        args,
        Place::default(),
        None,
        false,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// `run` with the start counted under `tag` as well as the executable's
/// name: a short static label for the duty that asked, so a measurement
/// reads starts per duty.
pub fn run_tagged(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    timeout: Duration,
) -> Result<Output> {
    run_tagged_in(
        tag,
        program,
        executable,
        operation,
        args,
        Place::default(),
        timeout,
    )
}

/// `run_tagged` with the child started in `place`: for a program that takes
/// its repository from the directory it runs in, or a shell script that
/// reads its subject from a variable. The same spawn site, bound and count
/// as every run.
pub fn run_tagged_in(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    start(
        caller,
        executable.as_os_str(),
        args,
        place,
        None,
        false,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// `run_tagged_in` with the child leading its own process group, which the
/// bound ends whole: for a program whose own children (a git hook, a
/// validation it starts) would otherwise outlive a call that gave no answer.
pub fn run_tagged_in_own_group(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    start(
        caller,
        executable.as_os_str(),
        args,
        place,
        None,
        true,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// `run_tagged_in` with `stdin` fed to the child: for a program that takes
/// its subject on its standard input, such as a provider's `put`. The same
/// spawn site, bound and count as every run.
#[allow(clippy::too_many_arguments)]
pub fn run_tagged_fed(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    stdin: &[u8],
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    start(
        caller,
        executable.as_os_str(),
        args,
        place,
        Some(stdin),
        false,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// `run_tagged_fed` with the child leading its own process group: a group
/// signal to the caller (a hook's `timeout` ending the runtime) does not
/// reach the child. Where `hold` is given, the child's stdin stays open
/// after `stdin` is written, for a server that stops at the end of its
/// input before it answers. The same spawn site, bound and count.
#[allow(clippy::too_many_arguments)]
pub fn run_tagged_fed_own_group(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    stdin: &[u8],
    hold: Option<Hold>,
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    spawn(
        caller,
        executable.as_os_str(),
        args,
        place,
        Some((stdin, hold)),
        true,
        false,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// `run_tagged` with the child's whole environment `env`, nothing inherited:
/// for a client whose answer the caller reads by its text, so no setting of
/// the caller's own (a logging level, a locale) changes what it prints.
pub fn run_tagged_alone(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
    timeout: Duration,
) -> Result<Output> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    let place = Place { cwd: None, env };
    spawn(
        caller,
        executable.as_os_str(),
        args,
        place,
        None,
        false,
        true,
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// How long a fed child's stdin stays open once its bytes are written:
/// until its standard output so far is `answered`, it closes that output
/// or exits, or `limit` passes.
#[derive(Debug, Clone, Copy)]
pub struct Hold {
    pub answered: fn(&[u8]) -> bool,
    pub limit: Duration,
}

/// A child the runner started and does not wait on: its standard input
/// and output are the null device, its standard error the file the caller
/// opened for it or the null device, and no pipe of this process reaches
/// it, so it outlives the caller. The caller reads it through the process
/// identity reader and may reap it by this handle once it has exited; a
/// handle dropped while the child runs leaves it running and hands it to a
/// thread that reaps it when it exits, so a long-lived launcher keeps no
/// zombie per job it started.
pub struct Detached {
    /// `None` only once the handle is dropped.
    child: Option<std::process::Child>,
}

impl Detached {
    fn child(&mut self) -> &mut std::process::Child {
        self.child.as_mut().expect("a live handle holds its child")
    }

    pub fn pid(&self) -> u32 {
        self.child
            .as_ref()
            .expect("a live handle holds its child")
            .id()
    }

    pub fn exited(&mut self) -> std::io::Result<Option<std::process::ExitStatus>> {
        self.child().try_wait()
    }

    pub fn reap(&mut self) -> std::io::Result<std::process::ExitStatus> {
        self.child().wait()
    }
}

impl Drop for Detached {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take()
            && matches!(child.try_wait(), Ok(None))
        {
            // A thread that cannot be started leaves the child a zombie
            // until this process exits, which is all a reap would end.
            let _ = std::thread::Builder::new()
                .name("detached-reap".to_owned())
                .spawn(move || {
                    let _ = child.wait();
                });
        }
    }
}

/// Start `executable` in `place` as a [`Detached`] child, counted under
/// `tag` as every run is, with `stderr` as its standard error where the
/// caller hands a file. The spawn is the one site a detached process starts
/// at; a spawn that fails is `not-started` with its cause and counts
/// nothing.
pub fn start_detached(
    tag: &'static str,
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    stderr: Option<std::fs::File>,
) -> Result<Detached> {
    let caller = Caller {
        program,
        operation,
        tag: Some(tag),
    };
    if let Some(cwd) = place.cwd {
        enterable(cwd).map_err(|failed| failed.into_error(caller))?;
    }
    let mut command = Command::new(executable);
    command.args(args);
    if let Some(cwd) = place.cwd {
        command.current_dir(cwd);
    }
    for (name, value) in place.env {
        command.env(name, value);
    }
    command.stdin(Stdio::null()).stdout(Stdio::null());
    command.stderr(match stderr {
        Some(file) => Stdio::from(file),
        None => Stdio::null(),
    });
    let child = command
        .spawn()
        .map_err(|e| Failed::Spawn(e).into_error(caller))?;
    count_start(executable.as_os_str(), caller.tag);
    Ok(Detached { child: Some(child) })
}

/// `cwd` as a directory a child can start in. Read three-valued through
/// `metadata`: an unreadable directory is its own cause, never absent.
fn enterable(cwd: &Path) -> std::result::Result<(), Failed> {
    let cause = match std::fs::metadata(cwd) {
        Ok(meta) if meta.is_dir() => return Ok(()),
        Ok(_) => "not a directory".to_owned(),
        Err(e) => e.to_string(),
    };
    Err(Failed::Cwd(format!(
        "working directory {}: {cause}",
        cwd.display()
    )))
}

/// Start `executable` in `place`, count it, and read its whole answer
/// within `timeout`; a fed child's stdin closes once its bytes are written.
pub(crate) fn start(
    caller: Caller,
    executable: &OsStr,
    args: &[&str],
    place: Place,
    stdin: Option<&[u8]>,
    own_group: bool,
    timeout: Duration,
) -> std::result::Result<Output, Failed> {
    spawn(
        caller,
        executable,
        args,
        place,
        stdin.map(|bytes| (bytes, None)),
        own_group,
        false,
        timeout,
    )
}

/// The one spawn site. `alone`: the child's environment is `place.env`
/// alone, nothing inherited.
#[allow(clippy::too_many_arguments)]
fn spawn(
    caller: Caller,
    executable: &OsStr,
    args: &[&str],
    place: Place,
    stdin: Option<(&[u8], Option<Hold>)>,
    own_group: bool,
    alone: bool,
    timeout: Duration,
) -> std::result::Result<Output, Failed> {
    if let Some(cwd) = place.cwd {
        enterable(cwd)?;
    }
    let mut command = Command::new(executable);
    command.args(args);
    if alone {
        command.env_clear();
    }
    if own_group {
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
    }
    if let Some(cwd) = place.cwd {
        command.current_dir(cwd);
    }
    for (name, value) in place.env {
        command.env(name, value);
    }
    command.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let mut child = command.spawn().map_err(Failed::Spawn)?;
    count_start(executable, caller.tag);
    let external = Failed::Answer;
    // Both pipes are drained while the child runs: a child that writes more
    // than a pipe holds blocks until something reads, so a reader that
    // starts after exit would wait on a child waiting on it. The readers
    // hand their bytes back over channels so the wait below stays bounded
    // by the one timeout; the stdin writer runs apart for the same reason.
    // A held stdin is released by the stdout reader: on the answer, or by
    // dropping its sender when the output ends.
    let hold = stdin.and_then(|(_, hold)| hold);
    let (release, released) = std::sync::mpsc::channel::<()>();
    let stdout = drain(
        child.stdout.take(),
        hold.map(|hold| Release {
            answered: hold.answered,
            release,
        }),
    );
    let stderr = drain(child.stderr.take(), None);
    if let (Some((bytes, _)), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let bytes = bytes.to_vec();
        std::thread::spawn(move || {
            use std::io::Write;
            let _ = pipe.write_all(&bytes);
            if let Some(hold) = hold {
                let _ = released.recv_timeout(hold.limit);
            }
        });
    }
    let started = std::time::Instant::now();
    // A child leading its own group is ended with the group, so nothing it
    // started outlives a call that gave no answer.
    let leader = child.id();
    let end_group = || {
        if own_group {
            let _ = Command::new("kill")
                .args(["-KILL", "--", &format!("-{leader}")])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if started.elapsed() > timeout {
                    end_group();
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(external(format!("no answer within {}s", timeout.as_secs())));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => return Err(external(e.to_string())),
        }
    };
    let remaining = || timeout.saturating_sub(started.elapsed());
    let unanswered = || {
        end_group();
        external(format!("no answer within {}s", timeout.as_secs()))
    };
    let stdout = stdout
        .recv_timeout(remaining())
        .map_err(|_| unanswered())?
        .map_err(|e| external(e.to_string()))?;
    let stderr = stderr
        .recv_timeout(remaining())
        .map_err(|_| unanswered())?
        .map_err(|e| external(e.to_string()))?;
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

/// What releases a held stdin from the output side: the bytes read so far
/// `answered`, or the output's end, which drops `release`.
struct Release {
    answered: fn(&[u8]) -> bool,
    release: std::sync::mpsc::Sender<()>,
}

/// Read one of the child's output pipes to its end on its own thread; the
/// bytes arrive on the returned channel once the child closes the pipe.
fn drain<R: std::io::Read + Send + 'static>(
    pipe: Option<R>,
    watch: Option<Release>,
) -> std::sync::mpsc::Receiver<std::io::Result<Vec<u8>>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut watch = watch;
        let mut bytes = Vec::new();
        let read = match pipe {
            Some(mut pipe) => loop {
                let mut chunk = [0u8; 8192];
                match pipe.read(&mut chunk) {
                    Ok(0) => break Ok(bytes),
                    Ok(n) => {
                        bytes.extend_from_slice(&chunk[..n]);
                        if watch.as_ref().is_some_and(|w| (w.answered)(&bytes)) {
                            let _ = watch.take().map(|w| w.release.send(()));
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(e) => break Err(e),
                }
            },
            None => Ok(bytes),
        };
        drop(watch);
        let _ = tx.send(read);
    });
    rx
}

pub fn stdout_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .to_owned()
}

pub fn stderr_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_owned()
}

/// `text` as the executable `path`, written by a child shell: a write
/// descriptor open in this process leaks into any sibling test's child
/// between its fork and exec, and an exec of the file meanwhile fails with
/// ETXTBSY.
#[cfg(test)]
pub(crate) fn write_executable(path: &Path, text: impl AsRef<str>) {
    let written = Command::new("sh")
        .args(["-c", "printf '%s' \"$2\" > \"$1\" && chmod 755 \"$1\"", "_"])
        .arg(path)
        .arg(text.as_ref())
        .status()
        .unwrap();
    assert!(written.success(), "write-executable {}", path.display());
}

#[cfg(test)]
mod tests {
    use super::*;

    const BOUND: Duration = Duration::from_secs(10);

    /// An executable of this test's own under `dir`, named `name` so the
    /// counter's key is nobody else's in this test binary, running `script`
    /// as `sh`.
    fn stub(dir: &Path, name: &str, script: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        write_executable(&path, format!("#!/bin/sh\n{script}"));
        path
    }

    const EXIT_0: &str = "exit 0\n";

    /// One run is one start under the executable's file name, not its
    /// path, and a tagged run lands under its tag beside the name. No test
    /// here resets the counter: the test binary's other tests read it in
    /// parallel.
    #[test]
    fn one_run_counts_one_start_under_the_file_name_and_the_tag() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "counted-run", EXIT_0);
        let before = counts();
        run("counted-run", &exe, "noop", &[], BOUND).unwrap();
        let after = counts();
        assert_eq!(
            after.of("counted-run", None) - before.of("counted-run", None),
            1
        );
        assert_eq!(after.of("counted-run", Some("row-a")), 0);
        run_tagged("row-a", "counted-run", &exe, "noop", &[], BOUND).unwrap();
        let tagged = counts();
        assert_eq!(tagged.of("counted-run", Some("row-a")), 1);
        assert_eq!(
            tagged.of("counted-run", None),
            after.of("counted-run", None)
        );
    }

    /// A detached start counts one start under its tag, holds no pipe of
    /// this process (a child that writes to its streams blocks on nothing
    /// and ends), and is reaped by its handle.
    #[test]
    fn a_detached_start_counts_once_and_is_reaped_by_its_handle() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(
            dir.path(),
            "u8u-detached",
            "yes | head -c 200000 >/dev/null; echo out; echo err >&2; exit 3\n",
        );
        let before = counts();
        let mut child = start_detached(
            "row-d",
            "u8u-detached",
            &exe,
            "noop",
            &[],
            Place::default(),
            None,
        )
        .unwrap();
        assert_eq!(
            counts().of("u8u-detached", Some("row-d")) - before.of("u8u-detached", Some("row-d")),
            1
        );
        assert!(child.pid() > 0);
        let status = child.reap().unwrap();
        assert_eq!(status.code(), Some(3));
        assert_eq!(
            child.exited().ok().flatten().map(|s| s.code()),
            Some(Some(3)),
            "a reaped child answers its status again"
        );
    }

    #[test]
    fn a_dropped_detached_child_is_reaped_once_it_exits() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "detached-dropped", "sleep 0.2\n");
        let child = start_detached(
            "row-z",
            "detached-dropped",
            &exe,
            "noop",
            &[],
            Place::default(),
            None,
        )
        .unwrap();
        let pid = child.pid().to_string();
        drop(child);
        // `kill -0` answers for a zombie too: only a reaped pid refuses it.
        let stands = || {
            Command::new("kill")
                .args(["-0", &pid])
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        };
        let deadline = std::time::Instant::now() + BOUND;
        while stands() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!stands(), "the dropped child {pid} stands unreaped");
    }

    /// An executable that never starts is no start, so a missing program's
    /// refusals stay out of a measurement of process starts.
    #[test]
    fn a_failed_spawn_counts_nothing_and_keeps_the_error_kind() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("u5b-missing");
        let caller = Caller {
            program: "u5b-missing",
            operation: "noop",
            tag: Some("row-a-missing"),
        };
        let failed = start(
            caller,
            missing.as_os_str(),
            &[],
            Place::default(),
            None,
            false,
            BOUND,
        )
        .unwrap_err();
        assert!(
            matches!(&failed, Failed::Spawn(e) if e.kind() == std::io::ErrorKind::NotFound),
            "{failed:?}"
        );
        assert_eq!(counts().of("u5b-missing", Some("row-a-missing")), 0);
    }

    /// Starts from several threads at once all land, as the orch runtime's
    /// concurrent duties start them.
    #[test]
    fn concurrent_runs_each_count() {
        use std::sync::{Arc, Barrier};
        const THREADS: usize = 8;
        const RUNS: u64 = 4;
        let dir = tempfile::tempdir().unwrap();
        let exe = Arc::new(stub(dir.path(), "u5b-concurrent", EXIT_0));
        let before = counts().of("u5b-concurrent", Some("row-a-threads"));
        let gate = Arc::new(Barrier::new(THREADS));
        let threads: Vec<_> = (0..THREADS)
            .map(|_| {
                let exe = Arc::clone(&exe);
                let gate = Arc::clone(&gate);
                std::thread::spawn(move || {
                    gate.wait();
                    for _ in 0..RUNS {
                        run_tagged("row-a-threads", "u5b-concurrent", &exe, "noop", &[], BOUND)
                            .unwrap();
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(
            counts().of("u5b-concurrent", Some("row-a-threads")) - before,
            THREADS as u64 * RUNS
        );
    }

    /// A placed run starts in its working directory with the added variables
    /// beside the inherited ones, the last value of a repeated name winning,
    /// and counts under its tag. The worktree package reads its repository
    /// from the directory, and a shell script reads `PATH` and the harness
    /// variables from the inherited environment.
    #[test]
    fn a_placed_run_enters_its_cwd_and_adds_to_the_inherited_environment() {
        let dir = tempfile::tempdir().unwrap();
        let inside = dir.path().join("inside");
        std::fs::create_dir(&inside).unwrap();
        let exe = stub(
            dir.path(),
            "u5b2-placed",
            "pwd -P\nprintf '%s\\n' \"$U5B2_ADDED\" \"$PATH\"\n",
        );
        let env = [
            ("U5B2_ADDED", OsStr::new("first")),
            ("U5B2_ADDED", OsStr::new("second")),
        ];
        let place = Place {
            cwd: Some(&inside),
            env: &env,
        };
        let out = run_tagged_in("row-d", "u5b2-placed", &exe, "place", &[], place, BOUND).unwrap();
        assert!(out.status.success(), "{out:?}");
        let entered = inside.canonicalize().unwrap().display().to_string();
        let inherited = std::env::var("PATH").unwrap();
        let text = stdout_text(&out);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines, [entered.as_str(), "second", inherited.as_str()]);
        assert_eq!(counts().of("u5b2-placed", Some("row-d")), 1);
    }

    /// A working directory that is not there fails the run before anything
    /// starts, as its own cause, and counts nothing.
    #[test]
    fn a_missing_cwd_fails_before_spawning_and_counts_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "u5b2-no-cwd", EXIT_0);
        let gone = dir.path().join("gone");
        let caller = Caller {
            program: "u5b2-no-cwd",
            operation: "place",
            tag: Some("row-e"),
        };
        let place = Place {
            cwd: Some(&gone),
            env: &[],
        };
        let failed = start(caller, exe.as_os_str(), &[], place, None, false, BOUND).unwrap_err();
        assert!(matches!(failed, Failed::Cwd(_)), "{failed:?}");
        // Through the public runner, a run that never started is told from
        // one that gave no answer.
        let err =
            run_tagged_in("row-e", "u5b2-no-cwd", &exe, "place", &[], place, BOUND).unwrap_err();
        assert!(matches!(err, Error::NotStarted { .. }), "{err:?}");
        assert_eq!(counts().of("u5b2-no-cwd", Some("row-e")), 0);
    }

    /// The bound applies to a placed run: a child that outlives it is ended
    /// and the run reads as no answer, after one counted start. The worktree
    /// package's hold relies on that bound.
    #[test]
    fn the_bound_applies_to_a_placed_run() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "u5b2-bounded", "exec sleep 30\n");
        let place = Place {
            cwd: Some(dir.path()),
            env: &[],
        };
        let err = run_tagged_in(
            "row-f",
            "u5b2-bounded",
            &exe,
            "place",
            &[],
            place,
            Duration::from_millis(300),
        )
        .unwrap_err();
        assert!(matches!(err, Error::External { .. }), "{err:?}");
        assert_eq!(counts().of("u5b2-bounded", Some("row-f")), 1);
    }

    #[test]
    fn a_group_leader_past_its_bound_is_ended_with_what_it_started() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("grandchild");
        let exe = stub(
            dir.path(),
            "u8ac-group-bound",
            &format!("sleep 30 &\necho $! > '{}'\nwait\n", pidfile.display()),
        );
        let err = run_tagged_in_own_group(
            "u8ac-group-bound",
            "u8ac-group-bound",
            &exe,
            "bounded",
            &[],
            Place::default(),
            Duration::from_millis(500),
        )
        .unwrap_err();
        assert!(matches!(err, Error::External { .. }), "{err:?}");
        let grandchild = std::fs::read_to_string(&pidfile).unwrap();
        let alive = |pid: &str| {
            Command::new("kill")
                .args(["-0", pid.trim()])
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        };
        let mut waited = 0;
        while alive(&grandchild) && waited < 200 {
            std::thread::sleep(Duration::from_millis(10));
            waited += 1;
        }
        assert!(
            !alive(&grandchild),
            "the grandchild outlived its group's bound"
        );
    }

    /// A child started apart leads its own process group, so a signal to
    /// this process's group does not reach it; an ordinary child shares
    /// the group.
    #[test]
    fn a_child_started_apart_leads_its_own_process_group() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "u8j-group", "echo $$; ps -o pgid= -p $$");
        let read = |out: Output| {
            let text = String::from_utf8_lossy(&out.stdout).to_string();
            let mut lines = text.lines();
            let pid = lines.next().unwrap_or("").trim().to_owned();
            let pgid = lines.next().unwrap_or("").trim().to_owned();
            (pid, pgid)
        };
        let own = String::from_utf8_lossy(
            &Command::new("ps")
                .args(["-o", "pgid=", "-p", &std::process::id().to_string()])
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_owned();
        let (pid, pgid) = read(
            run_tagged_fed_own_group(
                "u8j-group",
                "u8j-group",
                &exe,
                "apart",
                &[],
                Place::default(),
                b"",
                None,
                BOUND,
            )
            .unwrap(),
        );
        assert_eq!(pgid, pid, "a child started apart leads its own group");
        let (_, shared) = read(
            run_tagged_fed(
                "u8j-group",
                "u8j-group",
                &exe,
                "shared",
                &[],
                Place::default(),
                b"",
                BOUND,
            )
            .unwrap(),
        );
        assert_eq!(shared, own, "an ordinary child shares the runtime's group");
    }
}
