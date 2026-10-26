//! Where a session's process runs. A host owns opening the place the
//! harness runs in, reading its screen, typing into it and closing it; the
//! harness adapter owns everything the harness itself emits.

pub mod tmux;

use std::ffi::OsStr;
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use crate::error::{Error, Result};

/// Every external program this crate drives starts here: prompts closed,
/// a bound on every call.
pub(crate) fn run_with(
    program: &'static str,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<Output> {
    let mut command = Command::new(program);
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
    if let Some(bytes) = stdin {
        use std::io::Write;
        if let Some(mut pipe) = child.stdin.take() {
            let _ = pipe.write_all(bytes);
        }
    }
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if started.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(Error::External {
                        program,
                        operation,
                        cause: format!("no answer within {}s", timeout.as_secs()),
                    });
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => {
                return Err(Error::External {
                    program,
                    operation,
                    cause: e.to_string(),
                });
            }
        }
    }
    child.wait_with_output().map_err(|e| Error::External {
        program,
        operation,
        cause: e.to_string(),
    })
}

pub(crate) fn stdout_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .to_owned()
}

pub(crate) fn stderr_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_owned()
}
