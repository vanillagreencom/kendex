//! A launched job's end, told to its owner. `launch-job` starts the
//! caller's command under [`VERB`], which runs it with its output in the
//! run's log, writes its exit code, and only then, where the launch named an
//! owner, sends the owner's lane one directive naming the end through the
//! lane notice sender. The exit file is written before the send, so a
//! notice the mailbox refuses or never answers loses no result; the log's
//! last line says how the send went. A job stopped whole before its end
//! writes neither.

use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use agent_runtime::effects::Reach;
use agent_runtime::journal::Env;
use agent_runtime::record::Locking;
use serde::Serialize;

use crate::error::{Error, Result};
use crate::send::{self, NoticeSend};
use crate::settings::Settings;

/// The hidden verb `launch-job` starts the caller's command under.
pub const VERB: &str = "run-job";

/// The run's file `PATH.<suffix>`: `runner` the launcher's record, `log`
/// the runner line and the command's output, `exit` its exit code, `err`
/// the job's own standard error.
pub fn file(run: &Path, suffix: &str) -> PathBuf {
    let mut name = OsString::from(run.as_os_str());
    name.push(".");
    name.push(suffix);
    PathBuf::from(name)
}

/// The argv `launch-job` starts: this program's [`VERB`] over the run, and
/// with an owner the state directory and the mailbox `settings` reach,
/// named on the command line since the job inherits a directory that may
/// stand in another checkout.
pub fn argv(
    exe: &Path,
    name: &str,
    run: &Path,
    owner: Option<(&str, &Settings)>,
    command: &[String],
) -> Vec<String> {
    let mut words = vec![exe.display().to_string()];
    if let Some((_, settings)) = owner {
        words.extend([
            "--state-dir".to_owned(),
            settings.state_dir.display().to_string(),
        ]);
    }
    words.extend(
        [VERB, "--name", name, "--run"]
            .map(str::to_owned)
            .into_iter()
            .chain([run.display().to_string()]),
    );
    if let Some((item, settings)) = owner {
        words.extend(["--owner".to_owned(), item.to_owned()]);
        words.extend(agent_runtime::controller::run::reach_words(
            &crate::effects::fleet_mailbox(settings),
        ));
    }
    words.push("--".to_owned());
    words.extend(command.iter().cloned());
    words
}

/// What the job reports when it ends.
#[derive(Debug, Serialize)]
pub struct Ended {
    pub exit: i32,
    /// How the owner's notice went: `sent`, `unsent:<cause>` or `held`
    /// (the send's answer unknown); none where no owner was named.
    pub notice: Option<String>,
}

/// The job's main: the runner line as the log's first line, `command` run
/// with its output appended there, the exit code written, then with an
/// `owner` the notice sent under the key `job-<name>` through the mailbox
/// `reach` resolves and its mark appended to the log. A reach that cannot be
/// resolved is the mark `unsent:<key>`.
#[allow(
    clippy::disallowed_methods,
    reason = "the job's own run files under the run path its launch named, and the caller's command it runs and waits on"
)]
pub fn run(
    name: &str,
    run: &Path,
    command: &[String],
    owner: Option<&str>,
    reach: impl FnOnce() -> Result<(Settings, Reach, Env)>,
    locking: Locking,
) -> Result<Ended> {
    let Some((program, args)) = command.split_first() else {
        return Err(Error::Runtime(agent_runtime::Error::refused(
            "job-command-missing",
            &[("run", &run.display().to_string())],
        )));
    };
    let io = |op: &'static str, path: PathBuf| {
        move |e: std::io::Error| Error::Runtime(agent_runtime::Error::io(op, path, e))
    };
    let log_path = file(run, "log");
    let mut log = fs::File::create(&log_path).map_err(io("job-log", log_path.clone()))?;
    writeln!(log, "{}", runner_line(&file(run, "runner")))
        .map_err(io("job-log", log_path.clone()))?;
    let exit = execute(program, args, &log);
    let exit_path = file(run, "exit");
    let part = file(run, "exit.part");
    fs::write(&part, format!("{exit}\n"))
        .and_then(|()| fs::rename(&part, &exit_path))
        .map_err(io("job-exit", exit_path.clone()))?;
    let Some(item) = owner else {
        return Ok(Ended { exit, notice: None });
    };
    let notice = match reach() {
        Ok((settings, reach, env)) => {
            let text = format!(
                "job-end name={name} exit={exit} log={} exit-file={}",
                log_path.display(),
                exit_path.display()
            );
            let key = format!("job-{name}");
            match send::send_notice(&settings, &reach, item, &key, &text, &env, locking) {
                NoticeSend::Marked(mark) => mark,
                NoticeSend::Held => "held".to_owned(),
            }
        }
        Err(e) => format!("unsent:{}", e.key()),
    };
    writeln!(log, "job-end-notice={notice}").map_err(io("job-log", log_path))?;
    Ok(Ended {
        exit,
        notice: Some(notice),
    })
}

/// The record's `line=` value, the runner line the launcher wrote before
/// it started this job; empty where none reads, so the log's first line is
/// still the runner's.
fn runner_line(record: &Path) -> String {
    fs::read_to_string(record)
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.strip_prefix("line="))
                .map(str::to_owned)
        })
        .unwrap_or_default()
}

/// Run `program` in this job's process group, which a `stop-job` ends whole,
/// its output appended to `log`, and answer its exit code in the shell's
/// form (128 plus the signal for a signalled command; 127 for a command not
/// found and 126 for one that could not start, its cause on the log), so a
/// reader routes the code as it routes a shell's.
#[allow(
    clippy::disallowed_methods,
    reason = "the caller's own command, the one child this job runs and waits on"
)]
fn execute(program: &str, args: &[String], log: &fs::File) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Command, Stdio};
    let started = log.try_clone().and_then(|out| {
        let err = log.try_clone()?;
        Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(out)
            .stderr(err)
            .spawn()
    });
    let status = started.and_then(|mut child| child.wait());
    match status {
        Ok(status) => status
            .code()
            .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
        Err(e) => {
            let mut log = log;
            let _ = writeln!(log, "job-start-failed program={program} cause={e}");
            if e.kind() == std::io::ErrorKind::NotFound {
                127
            } else {
                126
            }
        }
    }
}
