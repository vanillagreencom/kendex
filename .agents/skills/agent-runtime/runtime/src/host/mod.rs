//! Where a session's process runs. A host owns opening the place the
//! harness runs in, reading its screen, typing into it and closing it; the
//! harness adapter owns everything the harness itself emits.

// Every pane reading and close is matched variant by variant, here and in
// the tmux host below (decision 105).
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
        Error::External {
            program: caller.program,
            operation: caller.operation,
            cause: self.cause(),
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
    /// runs a legacy script still reads `PATH`, `HOME` and the harness
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
    start(caller, OsStr::new(program), args, place, stdin, timeout)
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
/// its repository from the directory it runs in, or a legacy script that
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
    start(caller, executable.as_os_str(), args, place, None, timeout)
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
        timeout,
    )
    .map_err(|failed| failed.into_error(caller))
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

/// The one spawn site: start `executable` in `place`, count it, and read
/// its whole answer within `timeout`.
pub(crate) fn start(
    caller: Caller,
    executable: &OsStr,
    args: &[&str],
    place: Place,
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> std::result::Result<Output, Failed> {
    if let Some(cwd) = place.cwd {
        enterable(cwd)?;
    }
    let mut command = Command::new(executable);
    command.args(args);
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
    let stdout = drain(child.stdout.take());
    let stderr = drain(child.stderr.take());
    if let (Some(bytes), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let bytes = bytes.to_vec();
        std::thread::spawn(move || {
            use std::io::Write;
            let _ = pipe.write_all(&bytes);
        });
    }
    let started = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if started.elapsed() > timeout {
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
    let stdout = stdout
        .recv_timeout(remaining())
        .map_err(|_| external(format!("no answer within {}s", timeout.as_secs())))?
        .map_err(|e| external(e.to_string()))?;
    let stderr = stderr
        .recv_timeout(remaining())
        .map_err(|_| external(format!("no answer within {}s", timeout.as_secs())))?
        .map_err(|e| external(e.to_string()))?;
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

/// Read one of the child's output pipes to its end on its own thread; the
/// bytes arrive on the returned channel once the child closes the pipe.
fn drain<R: std::io::Read + Send + 'static>(
    pipe: Option<R>,
) -> std::sync::mpsc::Receiver<std::io::Result<Vec<u8>>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let read = match pipe {
            Some(mut pipe) => pipe.read_to_end(&mut bytes).map(|_| bytes),
            None => Ok(bytes),
        };
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

#[cfg(test)]
mod tests {
    use super::*;

    const BOUND: Duration = Duration::from_secs(10);

    /// An executable of this test's own under `dir`, named `name` so the
    /// counter's key is nobody else's in this test binary, running `script`
    /// as `sh`. A child shell writes it: a write descriptor open in this
    /// process leaks into any sibling test's child between its fork and
    /// exec, and an exec of the file meanwhile fails with ETXTBSY.
    fn stub(dir: &Path, name: &str, script: &str) -> std::path::PathBuf {
        let path = dir.join(name);
        let written = Command::new("sh")
            .args(["-c", "printf '%s' \"$2\" > \"$1\" && chmod 755 \"$1\"", "_"])
            .arg(&path)
            .arg(format!("#!/bin/sh\n{script}"))
            .status()
            .unwrap();
        assert!(written.success());
        path
    }

    const EXIT_0: &str = "exit 0\n";

    /// One run is one start under the executable's file name, not its
    /// path, and a tagged run lands under its tag beside the name. Defects:
    /// a run that counts nothing or twice, a path-named executable split
    /// across keys by install location, a tag that lands under the bare
    /// name. No test here resets the counter: the test binary's other
    /// tests read it in parallel.
    #[test]
    fn one_run_counts_one_start_under_the_file_name_and_the_tag() {
        let dir = tempfile::tempdir().unwrap();
        let exe = stub(dir.path(), "u5b-row-a", EXIT_0);
        let before = counts();
        run("u5b-row-a", &exe, "noop", &[], BOUND).unwrap();
        let after = counts();
        assert_eq!(
            after.of("u5b-row-a", None) - before.of("u5b-row-a", None),
            1
        );
        assert_eq!(after.of("u5b-row-a", Some("row-a")), 0);
        run_tagged("row-a", "u5b-row-a", &exe, "noop", &[], BOUND).unwrap();
        let tagged = counts();
        assert_eq!(tagged.of("u5b-row-a", Some("row-a")), 1);
        assert_eq!(tagged.of("u5b-row-a", None), after.of("u5b-row-a", None));
    }

    /// An executable that never starts is no start. Defect: counting the
    /// attempt, which would put a missing program's refusals into a
    /// measurement of process starts.
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
            BOUND,
        )
        .unwrap_err();
        assert!(
            matches!(&failed, Failed::Spawn(e) if e.kind() == std::io::ErrorKind::NotFound),
            "{failed:?}"
        );
        assert_eq!(counts().of("u5b-missing", Some("row-a-missing")), 0);
    }

    /// Starts from several threads at once all land. Defect: an
    /// unsynchronised read-modify-write or a thread-local count losing
    /// increments under the concurrent duties the orch runtime runs.
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
    /// and counts under its tag. Defects: the directory not entered (the
    /// worktree package would read the runtime's own repository); an
    /// environment replaced instead of added to, which loses `PATH` and the
    /// harness variables the legacy passes read; the first of two values
    /// kept.
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
    /// starts, as its own cause, and counts nothing. Defects: the child
    /// started anyway or the attempt counted; the missing directory read as
    /// a missing executable.
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
        let failed = start(caller, exe.as_os_str(), &[], place, None, BOUND).unwrap_err();
        assert!(matches!(failed, Failed::Cwd(_)), "{failed:?}");
        assert_eq!(counts().of("u5b2-no-cwd", Some("row-e")), 0);
    }

    /// The bound applies to a placed run: a child that outlives it is ended
    /// and the run reads as no answer, after one counted start. Defect: the
    /// new entry passing an unbounded wait, which the worktree package's
    /// hold (R-U5j S4) relies on never happening.
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
}
