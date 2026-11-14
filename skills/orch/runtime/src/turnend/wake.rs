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
    match claim::running(pattern) {
        Ok(Some(_)) => Ok(()),
        Ok(None) => unarmed(turn, payload, &wake.start),
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
                    let claim::Follow { pattern, start } =
                        claim::waiter(Path::new(&held.cwd), &held.origin, &paths.log);
                    return Ok(Some(Wake { pattern, start }));
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
