//! Whether a bound controller's fleet watch can wake it at its turn end,
//! and the start command it is told where nothing can. A live watch claim
//! is followed by the controller's waiter, `follow.sh` on the watch's log
//! in a `tmp/waiter.*` directory of the claim's working directory; with no
//! live claim, a home whose settings name `ORCH_WAKE_PROCESS` and
//! `ORCH_WAKE_START` (Jarvis's watch loop) is woken by the process that
//! pattern names; any other session with no live claim is woken by a
//! single pass's exit and is not checked. The check reads the claim, the
//! settings and the process table and starts nothing: the start command is
//! printed, never run. What it cannot judge is said under its own key and
//! the turn goes on to its other checks.

use std::os::unix::fs::MetadataExt;
use std::path::Path;

use agent_runtime::reading::Reading;
use agent_runtime::settings::{self as shared, Keys};
use regex::Regex;

use super::answer::Said;
use super::identity::Lane;
use super::payload::Payload;
use super::{Flow, Turn, Vars};
use crate::watch::claim;

/// The home's own wake pattern and start command, for a home no watch
/// claim covers.
const PROCESS_KEY: &str = "ORCH_WAKE_PROCESS";
const START_KEY: &str = "ORCH_WAKE_START";
/// The waiter a live claim's controller runs on the watch's log.
const FOLLOW: &str = "sh \"[RUN_DIR]/follow.sh\" \"[RUN_DIR]/watch.log\" [NEXT_LINE]";

/// What wakes the controller: the processes `pattern` matches, `None`
/// where nothing can, and the command that starts one.
struct Wake {
    pattern: Option<Regex>,
    start: String,
}

/// A gap in the check: its key, the input it names and the cause.
type Gap = (&'static str, String, String);

/// The bound controller's wake at its turn end: held under `wake=unarmed`
/// with the start command where nothing can wake it, told and passed on a
/// continued turn, whose hold is the loop `stop_hook_active` ends. A gap is
/// said under its own key; every note this check writes is carried into a
/// later refusal of the same turn end. The watch's facts follow the
/// binding: the caller hands the fleet record `fleet` that binds it.
pub(super) fn check(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
    fleet: &Path,
) -> Flow {
    let wake = match wake(lane, vars, fleet) {
        Ok(Some(wake)) => wake,
        Ok(None) => return Ok(()),
        Err((gap, value, cause)) => {
            report(turn, &Said::WakeUnjudged { gap, value }, &cause);
            return Ok(());
        }
    };
    let Some(pattern) = &wake.pattern else {
        return unarmed(turn, payload, &wake.start);
    };
    match running(pattern) {
        Ok(true) => Ok(()),
        Ok(false) => unarmed(turn, payload, &wake.start),
        Err(cause) => {
            let gap = Said::WakeUnjudged {
                gap: "wake-process",
                value: pattern.as_str().to_owned(),
            };
            report(turn, &gap, &cause);
            Ok(())
        }
    }
}

/// No process can wake the controller: a continued turn is told, any other
/// turn end held.
fn unarmed(turn: &mut Turn, payload: &Payload, start: &str) -> Flow {
    if payload.active {
        report(turn, &Said::WakeUnarmed, start);
        return Ok(());
    }
    Err(turn.refuse(Said::WakeUnarmed, start))
}

/// Said on stderr, and kept for a later refusal's text.
fn report(turn: &mut Turn, said: &Said, cause: &str) {
    turn.note(said, cause);
    turn.wake = Some(said.text(cause));
}

/// What wakes the controller of the fleet record at `fleet`: the live
/// claim's waiter, else the home's own setting, else nothing to check.
fn wake(lane: &Lane, vars: &Vars, fleet: &Path) -> Result<Option<Wake>, Gap> {
    let record = |path: &Path, cause: String| ("wake-record", path.display().to_string(), cause);
    if let Ok(paths) = claim::Paths::of(fleet) {
        let held = claim::read(&paths).map_err(|e| record(&paths.pid, e.to_string()))?;
        if let Some(held) = held {
            match claim::read_live(&held) {
                Reading::Live(_) => {
                    if held.cwd.is_empty() {
                        let cause = "the live watch claim names no cwd".to_owned();
                        return Err(record(&paths.pid, cause));
                    }
                    return Ok(Some(waiter(Path::new(&held.cwd), &held.origin, &paths.log)));
                }
                Reading::Gone => {}
                Reading::Unreadable { cause } => return Err(record(&paths.pid, cause.to_owned())),
            }
        }
    }
    let setting = |key: &'static str, cause: String| ("wake-setting", key.to_owned(), cause);
    let roots = shared::roots(&lane.root)
        .map_err(|e| setting(PROCESS_KEY, crate::Error::from(e).to_string()))?;
    let environment: Vec<_> = std::env::vars_os().collect();
    let keys = Keys {
        read: &[],
        load: &[PROCESS_KEY, START_KEY],
    };
    let values = shared::layered(&roots.project, &environment, vars.private_env, &keys)
        .map_err(|e| setting(PROCESS_KEY, crate::Error::from(e).to_string()))?;
    let Some(process) = values.get(PROCESS_KEY) else {
        return Ok(None);
    };
    // No command means no remedy that could clear a refusal.
    let Some(start) = values.get(START_KEY) else {
        let cause = format!("{PROCESS_KEY} is set but no start command is set");
        return Err(setting(START_KEY, cause));
    };
    let pattern =
        Regex::new(process).map_err(|e| ("wake-process", process.to_owned(), e.to_string()))?;
    Ok(Some(Wake {
        pattern: Some(pattern),
        start: start.to_owned(),
    }))
}

/// The waiter of a live claim working in `cwd`: `follow.sh` on the
/// `watch.log` of any of its waiter directories; a watch a succession
/// restarted is followed only through a waiter whose log is the watch's
/// own `log`, linked there first.
fn waiter(cwd: &Path, origin: &str, log: &Path) -> Wake {
    if origin != "succession" {
        let pattern = format!(
            "follow[.]sh {}/tmp/waiter[.][^/]*/watch[.]log",
            regex::escape(&cwd.display().to_string())
        );
        return Wake {
            pattern: Regex::new(&pattern).ok(),
            start: FOLLOW.to_owned(),
        };
    }
    let alternatives: Vec<String> = std::fs::read_dir(cwd.join("tmp"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("waiter."))
        .map(|entry| entry.path())
        .filter(|dir| same_file(&dir.join("watch.log"), log))
        .map(|dir| {
            format!(
                "follow[.]sh {}/watch[.]log([[:space:]]|$)",
                regex::escape(&dir.display().to_string())
            )
        })
        .collect();
    let pattern = (!alternatives.is_empty())
        .then(|| Regex::new(&alternatives.join("|")).ok())
        .flatten();
    Wake {
        pattern,
        start: format!(
            "Link [RUN_DIR]/watch.log to {}, then {FOLLOW}",
            log.display()
        ),
    }
}

/// Whether `a` and `b` name one file, links followed.
fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// Whether a process other than this one runs a command line `pattern`
/// matches, the line's words joined by spaces. A process that exits while
/// it is read is left out; a table that cannot be read is the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the wake check's one process table read: which processes run, matched by command line, nothing signalled"
)]
fn running(pattern: &Regex) -> Result<bool, String> {
    let own = std::process::id();
    #[cfg(target_os = "linux")]
    {
        let rows = agent_runtime::process::table().map_err(|e| e.cause.to_owned())?;
        Ok(rows.iter().filter(|row| row.pid != own).any(|row| {
            std::fs::read(format!("/proc/{}/cmdline", row.pid)).is_ok_and(|bytes| {
                let line = String::from_utf8_lossy(&bytes);
                let line = line.trim_end_matches('\0').replace('\0', " ");
                !line.is_empty() && pattern.is_match(&line)
            })
        }))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let output = agent_runtime::host::run(
            "ps",
            Path::new("ps"),
            "wake-processes",
            &["-A", "-ww", "-o", "pid=", "-o", "args="],
            std::time::Duration::from_secs(15),
        )
        .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(agent_runtime::host::stderr_text(&output));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        Ok(text.lines().any(|line| {
            let line = line.trim_start();
            let (pid, args) = line.split_once(' ').unwrap_or((line, ""));
            pid.parse::<u32>().is_ok_and(|pid| pid != own) && pattern.is_match(args.trim_start())
        }))
    }
}
