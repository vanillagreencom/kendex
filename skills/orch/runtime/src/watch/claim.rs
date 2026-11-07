//! The runner's claim on one fleet state: `oversee-watch.pid` beside the
//! state file, naming the runner's identity, its pid and its process start,
//! the state file it holds, its pane, origin, script and working directory.
//! A second runner reads the claim's identity three-valued: live refuses
//! `watch-running`, gone (a dead pid, or its pid reused under another
//! start) is taken over, unreadable is refused and never taken. A record
//! naming a pid with no start, the one a released repeat loop wrote, names
//! no identity and is read by its pid alone: a pid no process holds reads
//! gone and is taken over with `start=none`; a running pid reads unreadable
//! (`start-missing`) and is never taken or signalled. The one start that
//! takes it is a runner named to replace that pid: the loop's own pass
//! starts that runner and ends the loop, whose exit releases the record,
//! and the runner waits that release out.
//!
//! One reader answers whether a record names an identity, [`Claim::names`]:
//! the pid and the start, both.
//!
//! The record's `key=value` form is the one a released loop's record
//! carries, with `start=` after its fields, so one reader reads both.
//!
//! The record is published by linking a whole, synced, pid-named temporary
//! onto the record's path, which fails where a record already stands, so of
//! two starts that both read the path free exactly one claims. A runner
//! re-reads the record every slice and ends `watch-claim-moved` when it no
//! longer names it, without touching what stands. `--replace <pid>` is a
//! stop request on that identity waited out through the stop route below.
//!
//! A stop is a request file beside the claim naming the identity to stop;
//! the runner reads it between duties and ends, releasing the claim. A
//! terminal signal ends the process at its default disposition and leaves
//! the claim, which the next runner reads gone and takes over.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde::Serialize;

use crate::error::{Result, WatchError};
use crate::schedule::Clock;
use crate::state::FLEET_FILE_NAME;

/// The claim record.
pub const PID_FILE: &str = "oversee-watch.pid";
/// The event log the controller session follows.
pub const LOG_FILE: &str = "oversee-watch.log";
/// The typed baseline record.
pub const BASELINE_FILE: &str = "oversee-watch.baseline.json";
/// The stop request a `watch stop` writes and the runner reads.
pub const STOP_FILE: &str = "oversee-watch.stop";
/// What [`read_live`] answers for a record with no start whose pid runs.
pub const START_MISSING: &str = "start-missing";

/// How long a stop waits for the claimed runner to release its claim: the
/// runner reads the request between duties, so a duty in flight is waited
/// out.
pub const STOP_BOUND: Duration = Duration::from_secs(60);
/// How often the stop re-reads the claim within its bound.
const STOP_POLL: Duration = Duration::from_millis(100);

/// The record files beside the fleet state: the directory canonical, so two
/// spellings of one state file name one record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub dir: PathBuf,
    /// The fleet state as the record's `state=` names it.
    pub state: PathBuf,
    pub pid: PathBuf,
    pub log: PathBuf,
    pub baseline: PathBuf,
    pub stop: PathBuf,
}

impl Paths {
    /// The record paths for the fleet state at `state`.
    pub fn of(state: &Path) -> Result<Paths> {
        let dir = state.parent().unwrap_or(Path::new("."));
        let dir = std::fs::canonicalize(dir).map_err(|e| WatchError::Record {
            path: dir.to_path_buf(),
            op: "resolve",
            cause: e.to_string(),
        })?;
        let name = state
            .file_name()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(FLEET_FILE_NAME));
        Ok(Paths {
            state: dir.join(name),
            pid: dir.join(PID_FILE),
            log: dir.join(LOG_FILE),
            baseline: dir.join(BASELINE_FILE),
            stop: dir.join(STOP_FILE),
            dir,
        })
    }
}

/// The claim as recorded: the runner's identity and what it recorded of
/// itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Claim {
    pub pid: u32,
    /// `None` on a record that carries no `start=` line.
    pub start: Option<String>,
    pub state: String,
    pub pane: String,
    pub origin: String,
    pub script: String,
    pub cwd: String,
}

impl Claim {
    /// Whether the record names `identity`: its pid and its start. A record
    /// with no start names no identity.
    pub fn names(&self, identity: &Identity) -> bool {
        self.pid == identity.pid && self.start.as_deref() == Some(identity.start.as_str())
    }
}

fn record_error(path: &Path, op: &'static str, e: std::io::Error) -> WatchError {
    WatchError::Record {
        path: path.to_path_buf(),
        op,
        cause: e.to_string(),
    }
}

/// The claim `paths.pid` holds; `None` where no record stands or the record
/// names another state file or no pid, as `watch_pid_live` reads those. A
/// record of this state naming a pid with no start is a claim with no
/// start, never read as free: [`read_live`] reads it by its pid.
pub fn read(paths: &Paths) -> Result<Option<Claim>> {
    let text = match std::fs::read_to_string(&paths.pid) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(record_error(&paths.pid, "read", e).into()),
    };
    let mut claim = Claim {
        pid: 0,
        start: None,
        state: String::new(),
        pane: String::new(),
        origin: String::new(),
        script: String::new(),
        cwd: String::new(),
    };
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "pid" => claim.pid = value.parse().unwrap_or(0),
            "start" => claim.start = Some(value.to_owned()),
            "state" => claim.state = value.to_owned(),
            "pane" => claim.pane = value.to_owned(),
            "origin" => claim.origin = value.to_owned(),
            "script" => claim.script = value.to_owned(),
            "cwd" => claim.cwd = value.to_owned(),
            _ => {}
        }
    }
    if claim.pid == 0 || claim.state != paths.state.display().to_string() {
        return Ok(None);
    }
    Ok(Some(claim))
}

/// Whether the record at `paths.pid` still names `identity`: the runner's
/// own re-read each slice. An absent record names no one.
pub fn names_runner(paths: &Paths, identity: &Identity) -> Result<bool> {
    Ok(read(paths)?.is_some_and(|c| c.names(identity)))
}

/// Whether the claim's process still runs, by its recorded identity: live
/// under the same start, gone where the pid is dead or reused under
/// another start, unreadable where the process table cannot be read. A
/// claim with no start is read by its pid alone: gone where no process
/// holds it, else unreadable (`start-missing`), since a running pid with no
/// start to match is no identity to refuse or stop by.
#[allow(
    clippy::disallowed_methods,
    reason = "the claim's one identity read: the runner it refuses or takes over by"
)]
pub fn read_live(claim: &Claim) -> Reading<Identity> {
    let Some(start) = &claim.start else {
        return match process::identity(claim.pid) {
            Reading::Live(_) => Reading::Unreadable {
                cause: START_MISSING,
            },
            Reading::Gone => Reading::Gone,
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        };
    };
    process::still_runs(&Identity {
        pid: claim.pid,
        start: start.clone(),
    })
}

/// What the runner records of itself.
pub struct Record<'a> {
    pub identity: &'a Identity,
    pub pane: &'a str,
    pub origin: &'a str,
    pub script: &'a str,
    pub cwd: &'a str,
}

/// How a write of the claim ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Written {
    /// The record now names this runner.
    Claimed,
    /// A record already stood when the link was tried: another start
    /// claimed first. Nothing of this runner's is left on disk.
    Held,
}

/// Write the claim as this runner: the record whole in a pid-named
/// temporary, synced, then linked onto the record's path, which fails where
/// one stands, so two starts cannot both claim.
#[allow(
    clippy::disallowed_methods,
    reason = "the claim's one writer: the record beside the fleet state, linked into place exclusively"
)]
pub fn write(paths: &Paths, record: &Record) -> Result<Written> {
    let whole = |tmp: &Path, bytes: &[u8]| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(tmp)?;
        file.write_all(bytes)?;
        file.sync_data()
    };
    let pid = format!(
        "pid={}\nstate={}\npane={}\norigin={}\nscript={}\ncwd={}\nstart={}\n",
        record.identity.pid,
        paths.state.display(),
        record.pane,
        record.origin,
        record.script,
        record.cwd,
        record.identity.start
    );
    let tmp = paths
        .pid
        .with_extension(format!("{}.tmp", record.identity.pid));
    let link = || -> std::io::Result<Written> {
        whole(&tmp, pid.as_bytes())?;
        let linked = std::fs::hard_link(&tmp, &paths.pid);
        std::fs::remove_file(&tmp)?;
        match linked {
            Ok(()) => Ok(Written::Claimed),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(Written::Held),
            Err(e) => Err(e),
        }
    };
    let written = link().map_err(|e| record_error(&paths.pid, "write", e))?;
    Ok(written)
}

/// Remove a record read gone, so the taker's link can land. A record that
/// is already gone is nothing to remove.
#[allow(
    clippy::disallowed_methods,
    reason = "the takeover's removal of a record whose identity read gone, before the taker's claim is linked"
)]
pub fn remove_gone(paths: &Paths) -> Result<()> {
    match std::fs::remove_file(&paths.pid) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(record_error(&paths.pid, "remove", e).into()),
    }
}

/// Remove the claim where it still names `identity` (`watch_pid_release`),
/// so a runner already replaced never removes its successor's.
#[allow(
    clippy::disallowed_methods,
    reason = "the claim's release: the runner removes the record it wrote"
)]
pub fn release(paths: &Paths, identity: &Identity) -> Result<()> {
    if names_runner(paths, identity)?
        && let Err(e) = std::fs::remove_file(&paths.pid)
    {
        return Err(record_error(&paths.pid, "remove", e).into());
    }
    Ok(())
}

/// Ask the runner `identity` to stop: the request names it, so a request
/// left for a runner that is gone never stops the one that took over.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop request's one writer, beside the claim it names"
)]
pub fn request_stop(paths: &Paths, identity: &Identity) -> Result<()> {
    let text = format!("pid={}\nstart={}\n", identity.pid, identity.start);
    std::fs::write(&paths.stop, text).map_err(|e| record_error(&paths.stop, "write", e).into())
}

/// Whether a stop request naming `identity` stands.
pub fn stop_requested(paths: &Paths, identity: &Identity) -> Result<bool> {
    let text = match std::fs::read_to_string(&paths.stop) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(record_error(&paths.stop, "read", e).into()),
    };
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
    };
    Ok(field("pid") == Some(identity.pid.to_string().as_str())
        && field("start") == Some(identity.start.as_str()))
}

/// Remove a stop request, served or stale.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop request's removal by the runner it was for, or by the claim that supersedes it"
)]
pub fn clear_stop(paths: &Paths) -> Result<()> {
    match std::fs::remove_file(&paths.stop) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(record_error(&paths.stop, "remove", e).into()),
    }
}

/// Wait, on `clock`, until the start-less record naming `pid` stands no
/// more: removed, replaced, or naming a pid that reads gone. Nothing is
/// sent: the loop that wrote it reads no stop request, and its own exit
/// releases it.
#[allow(
    clippy::disallowed_methods,
    reason = "the replacement's wait on the one injected clock for a start-less record's release"
)]
pub fn await_release(paths: &Paths, pid: u32, clock: &dyn Clock) -> Result<()> {
    let deadline = clock.now() + STOP_BOUND;
    loop {
        match read(paths)? {
            Some(claim) if claim.pid == pid && claim.start.is_none() => {
                if read_live(&claim) == Reading::Gone {
                    return Ok(());
                }
            }
            Some(_) | None => return Ok(()),
        }
        if clock.now() >= deadline {
            return Err(WatchError::StopTimeout {
                pid,
                start: "none".to_owned(),
            }
            .into());
        }
        clock.sleep(STOP_POLL);
    }
}

/// How a stop ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "claim", rename_all = "kebab-case")]
pub enum Stopped {
    /// The claimed runner released its claim within the bound.
    Released { pid: u32, start: String },
    /// No live claim stood: nothing was running, and a gone record is left
    /// for the next runner to take over.
    None,
}

/// Stop the runner that holds the claim, where one does: write the request
/// and wait, on `clock`, until the claim no longer names that identity or
/// the bound passes (`watch_stop`). A claim whose identity reads gone or
/// which stands on no record is nothing to stop; one that reads unreadable
/// is refused, never signalled.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop's wait on the one injected clock for the claim's release"
)]
pub fn stop(paths: &Paths, clock: &dyn Clock) -> Result<Stopped> {
    let Some(claim) = read(paths)? else {
        return Ok(Stopped::None);
    };
    let identity = match read_live(&claim) {
        Reading::Live(identity) => identity,
        Reading::Gone => return Ok(Stopped::None),
        Reading::Unreadable { cause } => {
            return Err(WatchError::ClaimUnreadable {
                path: paths.pid.clone(),
                pid: claim.pid,
                cause: cause.to_owned(),
            }
            .into());
        }
    };
    request_stop(paths, &identity)?;
    let deadline = clock.now() + STOP_BOUND;
    loop {
        if !names_runner(paths, &identity)? {
            return Ok(Stopped::Released {
                pid: identity.pid,
                start: identity.start,
            });
        }
        if clock.now() >= deadline {
            return Err(WatchError::StopTimeout {
                pid: identity.pid,
                start: identity.start,
            }
            .into());
        }
        clock.sleep(STOP_POLL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The record is read whole: a record naming another state file or no
    /// pid is no claim, and a record of this state naming a pid with no
    /// start is a claim with no start, never read as free.
    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row writes the record file it reads"
    )]
    fn a_claim_is_read_whole_and_a_record_without_a_start_is_a_claim_with_none() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::of(&dir.path().join(FLEET_FILE_NAME)).unwrap();
        assert_eq!(read(&paths).unwrap(), None, "no record");
        let state = paths.state.display().to_string();
        std::fs::write(
            &paths.pid,
            format!(
                "pid=4242\nstate={state}\npane=%3\norigin=hand\nscript=/w\ncwd=/c\nstart=ticks:9\n"
            ),
        )
        .unwrap();
        let claim = read(&paths).unwrap().expect("a claim");
        assert_eq!(
            (claim.pid, claim.start.as_deref(), claim.pane.as_str()),
            (4242, Some("ticks:9"), "%3")
        );
        std::fs::write(
            &paths.pid,
            "pid=4242\nstate=/elsewhere/x.json\nstart=ticks:9\n",
        )
        .unwrap();
        assert_eq!(read(&paths).unwrap(), None, "another state file");
        std::fs::write(&paths.pid, format!("state={state}\nstart=ticks:9\n")).unwrap();
        assert_eq!(read(&paths).unwrap(), None, "no pid");
        std::fs::write(
            &paths.pid,
            format!("pid=4242\nstate={state}\npane=%3\norigin=hand\nscript=/w\ncwd=/c\n"),
        )
        .unwrap();
        let startless = read(&paths).unwrap().expect("a claim with no start");
        assert_eq!((startless.pid, startless.start), (4242, None));
    }

    /// A reader by pid alone beside one by pid and start lets a stop read
    /// another runner's claim as released: the one reader takes the pid
    /// and the start, both.
    #[test]
    fn a_record_names_an_identity_by_its_pid_and_start() {
        let claim = |pid: u32, start: Option<&str>| Claim {
            pid,
            start: start.map(str::to_owned),
            state: String::new(),
            pane: String::new(),
            origin: String::new(),
            script: String::new(),
            cwd: String::new(),
        };
        let identity = Identity {
            pid: 7,
            start: "ticks:70".into(),
        };
        let rows = [
            (claim(7, Some("ticks:70")), true, "pid and start equal"),
            (claim(7, Some("ticks:71")), false, "another start"),
            (claim(8, Some("ticks:70")), false, "another pid, same start"),
            (claim(7, None), false, "same pid, no start"),
        ];
        for (record, named, why) in rows {
            assert_eq!(record.names(&identity), named, "{why}");
        }
    }

    /// A clock whose waits pass no time and stand for the loop's exit: its
    /// first wait removes the record, as the loop's trap does.
    struct LoopExit<'a> {
        record: &'a Path,
        waits: std::sync::atomic::AtomicU32,
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the row's clock: the real instant, and the record's removal the loop's exit makes"
    )]
    impl Clock for LoopExit<'_> {
        fn now(&self) -> std::time::Instant {
            std::time::Instant::now()
        }
        fn wall(&self) -> std::time::SystemTime {
            std::time::SystemTime::now()
        }
        fn sleep(&self, _: Duration) {
            self.waits
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let _ = std::fs::remove_file(self.record);
        }
    }

    #[test]
    #[allow(
        clippy::disallowed_methods,
        reason = "the row writes the record file it reads"
    )]
    fn a_replacement_waits_out_a_running_loops_start_less_record_until_its_exit_releases_it() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::of(&dir.path().join(FLEET_FILE_NAME)).unwrap();
        let running = std::process::id();
        std::fs::write(
            &paths.pid,
            format!(
                "pid={running}\nstate={}\npane=%3\norigin=hand\nscript=/w\ncwd=/c\n",
                paths.state.display()
            ),
        )
        .unwrap();
        let clock = LoopExit {
            record: &paths.pid,
            waits: std::sync::atomic::AtomicU32::new(0),
        };
        await_release(&paths, running, &clock).unwrap();
        assert_eq!(
            clock.waits.load(std::sync::atomic::Ordering::Relaxed),
            1,
            "held while the loop ran, released at its exit"
        );
        assert_eq!(read(&paths).unwrap(), None);
    }

    /// A stop request is read only by the identity it names: a request a
    /// gone runner was left never stops the runner that took over.
    #[test]
    fn a_stop_request_names_one_identity() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::of(&dir.path().join(FLEET_FILE_NAME)).unwrap();
        let me = Identity {
            pid: 7,
            start: "ticks:7".into(),
        };
        let other = Identity {
            pid: 7,
            start: "ticks:8".into(),
        };
        assert!(!stop_requested(&paths, &me).unwrap());
        request_stop(&paths, &other).unwrap();
        assert!(
            !stop_requested(&paths, &me).unwrap(),
            "same pid, other start"
        );
        assert!(stop_requested(&paths, &other).unwrap());
        clear_stop(&paths).unwrap();
        assert!(!stop_requested(&paths, &other).unwrap());
        clear_stop(&paths).unwrap();
    }
}
