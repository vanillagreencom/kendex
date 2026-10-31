//! Where a session's process runs. A host owns opening the place the
//! harness runs in, reading its screen, typing into it and closing it; the
//! harness adapter owns everything the harness itself emits.

// Every pane reading and close is matched variant by variant, here and in
// the tmux host below (decision 105).
#![deny(clippy::wildcard_enum_match_arm)]

pub mod tmux;

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use crate::error::{Error, Result};

/// Every external program this crate drives starts here: prompts closed,
/// a bound on every call. `program` is the executable as found on `PATH`
/// and the name a failure reports.
pub(crate) fn run_with(
    program: &'static str,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<Output> {
    run_executable(
        program,
        OsStr::new(program),
        operation,
        args,
        env,
        stdin,
        timeout,
    )
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
    run_executable(
        program,
        executable.as_os_str(),
        operation,
        args,
        &[],
        None,
        timeout,
    )
}

fn run_executable(
    program: &'static str,
    executable: &OsStr,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<Output> {
    let mut command = Command::new(executable);
    command.args(args);
    for (name, value) in env {
        command.env(name, value);
    }
    command.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| Error::External {
        program,
        operation,
        cause: e.to_string(),
    })?;
    let external = |cause: String| Error::External {
        program,
        operation,
        cause,
    };
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
