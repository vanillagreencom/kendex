//! The hosted readings of the lane duty: the preparation, stall, start-stall
//! and long-lane readings of a hosted lane, its status verb and its
//! finished-hosted close, over the fleet record's hosted lanes and inside
//! the lane duty's pass (`watch::lanes`); and the provider calls a hosted
//! launch makes.
//!
//! Every provider read is one `lane-host` call through the one runner under
//! `ORCH_LANE_HOST=<the record's host>`, from the scripts directory the pass
//! carries, three-valued: a `cat` that exits 2 is a
//! missing file only once a `touch` of the host answers, and every other
//! status, the dispatcher's own refusals among them (`host-kind-verb`,
//! `host-local`, `lane-host-busy`, a verb it does not know), is unreadable
//! with its cause and never "no file". The capability line a host declares
//! is read once per host per pass through `lane-host capabilities`; a record
//! naming no host is the `local` kind, whose line the dispatcher answers for
//! it, and asks nothing.
//!
//! The one close: `lane-close --state-dir
//! [DIR] [ITEM]` is the irreversible step's owner and writes the lane
//! record; the watch says it asked by a marker it creates exclusively under
//! its own state directory before the program starts, beside the wall
//! relaunch markers. An answer that closed nothing removes the marker; a
//! close that answered `closed` keeps it until the next pass reads the lane
//! record out of flight. A marker standing beside a lane still in flight is
//! a close whose end this runtime did not see: nothing is closed again, the
//! pass names it as its failure each pass, and the lane is the operator's.
//! The baseline rows (`lane-stalled`, `start-stalled`, `lane-long`,
//! `lane-prepare`, `close-pending`) go through the runner's commit as every
//! row does.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Produced;
use super::baseline::Change;
use super::events::Event;
use super::github::Gh;
use super::lanes::{
    Counters, Pass, clear, counters_of, fail, lane_name, set, step_of, validation_runs_of,
    watch_state_dir,
};
use super::tracker::{QUOTA_ROW, Quota};
use crate::ops::CLOUD_KIND;
use crate::ops::accounts::Roster;
use crate::ops::wall;
use crate::state::{Lane, LaneStatus};

/// The tag the lane duty's provider calls are counted under.
const TAG: &str = "lanes";
/// The bound on one provider read: an ssh round trip behind the
/// dispatcher's own busy wait (`ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS`, 30 s).
const READ_BOUND: Duration = Duration::from_secs(120);
/// The bound on `lane-close`: a host close archives the lane's records and
/// removes its worktree before it answers.
const CLOSE_BOUND: Duration = Duration::from_secs(900);
/// The two programs, under the scripts directory the pass carries.
pub const LANE_HOST: &str = "lane-host";
pub const LANE_CLOSE: &str = "lane-close";
/// The rows this module keeps.
pub const STALLED_ROW: &str = "lane-stalled";
pub const PREPARE_ROW: &str = "lane-prepare";
/// `close-pending<TAB><lane><TAB><row>|<key>`: a finished-hosted close the
/// tracker's quota hold deferred, retried while the notification row still
/// reads `<key>|reported`.
pub const CLOSE_PENDING_ROW: &str = "close-pending";
/// The row the GitHub duty writes for an item's merged pull requests, which
/// admits the finished-hosted close (`finished_hosted_lane_eligible`).
const MERGED_ROW: &str = super::github::MERGED_ROW;

/// The reads the hosted arms take beyond the scripts directory, injected
/// so a row plants them: `gh` as the GitHub duty resolves it, the account
/// roster for a draft pull request's credit, and the repositories a lane
/// naming none is read in.
pub struct Reads<'a> {
    pub gh: &'a Path,
    /// `lanes list --json` (`accounts::roster`), read once per pass and
    /// only for a cloud lane whose pull request is a draft.
    pub roster: &'a dyn Fn() -> Result<Roster, String>,
    /// The fleet's repositories, in order; the first with an open pull
    /// request on the lane's branch answers.
    pub repos: &'a [String],
}

/// A provider's answer about a file or a process on its host:
/// the subject read, a read that found none, or a read that failed, with
/// the cause as one line.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer<T> {
    Live(T),
    Gone,
    Unreadable { cause: String },
}

// --- the capability line ----------------------------------------------------

/// Where a kind's lane files are read (`files=`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Files {
    Local,
    Verb,
    None,
}

/// How a kind's lane is judged (`status=`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Pane,
    Verb,
    Task,
    None,
}

/// Where a kind's pane is captured and written (`pane=`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneKind {
    Local,
    Verb,
}

/// The keys of a host kind's capability line the lane duty acts on
/// (`schemas/lane-host.md` § Host kinds).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    pub files: Files,
    pub status: Status,
    pub pane: PaneKind,
    /// How the kind launches a lane (`launch=`); `None` where the line
    /// names none. The accounts judge admits a `cloud-session` host's
    /// account only with repository access.
    pub launch: Option<Launch>,
}

/// How a kind launches a lane (`launch=`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Launch {
    Window,
    Ssh,
    CloudSession,
    CloudTask,
}

impl Capabilities {
    /// The `local` kind's line, the dispatcher's own answer for a record
    /// naming no other host.
    pub const LOCAL: Capabilities = Capabilities {
        files: Files::Local,
        status: Status::Pane,
        pane: PaneKind::Local,
        launch: Some(Launch::Window),
    };

    /// One tab-separated `key=value` line; `pane` absent reads `local`, an
    /// older provider line. A value outside its key's set is refused as the
    /// dispatcher refuses it (`capability-invalid`), so a line that reaches a
    /// caller is one both validated; a key this duty does not act on passes.
    pub fn parse(line: &str) -> Result<Capabilities, String> {
        let mut files = None;
        let mut status = None;
        let mut pane = PaneKind::Local;
        let mut launch = None;
        for field in line.trim_end_matches('\n').split('\t') {
            let Some((key, value)) = field.split_once('=') else {
                return Err(format!("capability-invalid field={field}"));
            };
            let invalid = || format!("capability-invalid key={key} value={value}");
            match key {
                "files" => {
                    files = Some(match value {
                        "local" => Files::Local,
                        "verb" => Files::Verb,
                        "none" => Files::None,
                        _ => return Err(invalid()),
                    });
                }
                "status" => {
                    status = Some(match value {
                        "pane" => Status::Pane,
                        "verb" => Status::Verb,
                        "task" => Status::Task,
                        "none" => Status::None,
                        _ => return Err(invalid()),
                    });
                }
                "pane" => {
                    pane = match value {
                        "local" => PaneKind::Local,
                        "verb" => PaneKind::Verb,
                        _ => return Err(invalid()),
                    };
                }
                "launch" => {
                    launch = Some(match value {
                        "window" => Launch::Window,
                        "ssh" => Launch::Ssh,
                        "cloud-session" => Launch::CloudSession,
                        "cloud-task" => Launch::CloudTask,
                        _ => return Err(invalid()),
                    });
                }
                _ => {}
            }
        }
        match (files, status) {
            (Some(files), Some(status)) => Ok(Capabilities {
                files,
                status,
                pane,
                launch,
            }),
            (None, _) => Err("capability-invalid key=files value=missing".to_owned()),
            (_, None) => Err("capability-invalid key=status value=missing".to_owned()),
        }
    }
}

/// The host a lane's provider reads run under: the record's `host`, the
/// cloud kind for a record whose `kind` is the cloud kind and names no
/// host, else `local`.
pub fn host_of(lane: &Lane) -> &str {
    match lane.host.as_deref() {
        Some(host) if !host.is_empty() => host,
        Some(_) | None => {
            if lane.kind.as_deref() == Some(CLOUD_KIND) {
                CLOUD_KIND
            } else {
                "local"
            }
        }
    }
}

/// The capability line of every host the lanes given name, read once each
/// per pass (`host_capabilities`, `lib/watch-host-kinds.sh:278`): the
/// `local` kind answers in-process; any other host through `lane-host
/// capabilities` under its name. A line that could not be read or parsed
/// keeps its cause, and every read of a lane on that host is then
/// unreadable with it, never judged off the local kind. The caller hands
/// the lanes the pass judges, the in-flight ones alone: a `parked`, `done`
/// or `stopped` record keeps its host, and a provider that is gone would
/// otherwise be asked every pass and its failure said ahead of a live
/// lane's.
pub struct Hosts {
    lines: BTreeMap<String, Result<Capabilities, String>>,
}

impl Hosts {
    pub fn read<'a>(scripts: &Path, lanes: impl IntoIterator<Item = &'a Lane>) -> Hosts {
        let mut lines = BTreeMap::new();
        for lane in lanes {
            let host = host_of(lane);
            if host == "local" || lines.contains_key(host) {
                continue;
            }
            lines.insert(host.to_owned(), capabilities(scripts, host));
        }
        Hosts { lines }
    }

    /// The line the lane's host declares, or the cause it could not be read.
    pub fn of(&self, lane: &Lane) -> Result<Capabilities, String> {
        let host = host_of(lane);
        if host == "local" {
            return Ok(Capabilities::LOCAL);
        }
        self.lines.get(host).cloned().unwrap_or_else(|| {
            Err(format!(
                "host-capabilities-unread host={host} cause=host-unread"
            ))
        })
    }

    /// The hosts whose line could not be read, with the cause, for the pass
    /// to say once each.
    pub fn unreadable(&self) -> impl Iterator<Item = &str> {
        self.lines
            .values()
            .filter_map(|line| line.as_ref().err().map(String::as_str))
    }
}

// --- the provider calls -----------------------------------------------------

fn exit_code(out: &std::process::Output) -> i32 {
    out.status.code().unwrap_or(-1)
}

fn first_line(text: &str) -> &str {
    text.lines().find(|l| !l.trim().is_empty()).unwrap_or("")
}

/// `lane-host VERB ARGS` under `ORCH_LANE_HOST=<host>` from the scripts
/// directory, through the one runner; `Err` is a call that could not run or
/// answer within the bound.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane duty's provider reads: `lane-host` from the scripts directory the pass carries through the one runner under the duty's tag, `ORCH_LANE_HOST` naming the record's host"
)]
fn lane_host(
    scripts: &Path,
    host: &str,
    operation: &'static str,
    args: &[&str],
) -> Result<std::process::Output, String> {
    let env: [(&str, &OsStr); 1] = [("ORCH_LANE_HOST", OsStr::new(host))];
    host::run_tagged_in(
        TAG,
        LANE_HOST,
        &scripts.join(LANE_HOST),
        operation,
        args,
        Place {
            cwd: None,
            env: &env,
        },
        READ_BOUND,
    )
    .map_err(|e| e.to_string())
}

/// The cause word of a call that answered non-zero: the verb, the status
/// and the first line of its stderr.
fn cause_of(verb: &str, out: &std::process::Output) -> String {
    format!(
        "{verb} exit={} {}",
        exit_code(out),
        first_line(&host::stderr_text(out))
    )
    .trim_end()
    .to_owned()
}

/// `lane-host capabilities` under `host`: the line, or the cause.
pub fn capabilities(scripts: &Path, host: &str) -> Result<Capabilities, String> {
    let unread = |cause: String| format!("host-capabilities-unread host={host} cause={cause}");
    let out = lane_host(scripts, host, "capabilities", &["capabilities"]).map_err(&unread)?;
    if !out.status.success() {
        return Err(unread(cause_of("capabilities", &out)));
    }
    Capabilities::parse(&host::stdout_text(&out)).map_err(unread)
}

/// `lane_host_fetch` (`lib/lane-gitfile.sh:53`): `lane-host cat --item ITEM
/// PATH`; a `2` is a missing file only once `touch --item ITEM` answers,
/// since the dispatcher's own refusals exit `2` as well; a `touch` that
/// fails, the busy refusal (69) and any other status are unreadable with
/// their cause.
pub fn fetch(scripts: &Path, host: &str, item: &str, path: &str) -> Answer<String> {
    let out = match lane_host(scripts, host, "cat", &["cat", "--item", item, path]) {
        Ok(out) => out,
        Err(cause) => {
            return Answer::Unreadable {
                cause: format!("cat {cause}"),
            };
        }
    };
    match out.status.code() {
        Some(0) => Answer::Live(String::from_utf8_lossy(&out.stdout).into_owned()),
        Some(2) => match lane_host(scripts, host, "touch", &["touch", "--item", item]) {
            Ok(touched) if touched.status.success() => Answer::Gone,
            Ok(touched) => Answer::Unreadable {
                cause: cause_of("touch", &touched),
            },
            Err(cause) => Answer::Unreadable {
                cause: format!("touch {cause}"),
            },
        },
        Some(_) | None => Answer::Unreadable {
            cause: cause_of("cat", &out),
        },
    }
}

/// What the provider's status verb answered of the lane's harness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostStatus {
    Running,
    Exited,
}

/// `lane-host status --item ITEM --harness H` (`pane_has_remote_harness`,
/// `lib/lane-state.sh:361`): `running` or `exited` on exit 0; any other
/// answer is a failed read, never an exit (`schemas/lane-host.md` § `status`).
pub fn status(scripts: &Path, host: &str, item: &str, harness: &str) -> Result<HostStatus, String> {
    let unread = |cause: String| format!("harness-probe-failed item={item} {cause}");
    let out = lane_host(
        scripts,
        host,
        "status",
        &["status", "--item", item, "--harness", harness],
    )
    .map_err(&unread)?;
    if !out.status.success() {
        return Err(unread(cause_of("status", &out)));
    }
    match host::stdout_text(&out).as_str() {
        "running" => Ok(HostStatus::Running),
        "exited" => Ok(HostStatus::Exited),
        other => Err(unread(format!("status answer={other}"))),
    }
}

/// `lane-host stop --item ITEM --harness H` before a hosted `pane=local`
/// relaunch, confirmed by exit 0 and the one line `stopped item=ITEM
/// processes=N`; `Err` is the status the refusal names.
pub fn stop(scripts: &Path, host: &str, item: &str, harness: &str) -> Result<(), i32> {
    let out = lane_host(
        scripts,
        host,
        "stop",
        &["stop", "--item", item, "--harness", harness],
    )
    .map_err(|_| -1)?;
    if !out.status.success() {
        return Err(exit_code(&out));
    }
    let text = host::stdout_text(&out);
    let confirmed = text
        .strip_prefix(&format!("stopped item={item} processes="))
        .is_some_and(|count| !count.is_empty() && count.bytes().all(|b| b.is_ascii_digit()));
    if confirmed { Ok(()) } else { Err(0) }
}

// --- the launch's calls --------------------------------------------------------

/// The bound on `create` and `wait`: a provider clones, installs and builds
/// the lane's checkout before it answers.
const PREPARE_BOUND: Duration = Duration::from_secs(1800);

/// What `create` answered: the ssh target, the worktree path on the host,
/// the prefix the launch line runs under, and whether the preparation is
/// still going.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Created {
    pub target: String,
    pub path: String,
    pub prefix: String,
    pub preparing: bool,
    /// The Pi root a Pi lane runs under on the host, where the provider
    /// named one.
    pub pi_root: Option<String>,
}

/// The provider's `create` line parsed, or the cause. A `75` is an item
/// another session owns, named `item-owned`; a `75` whose line carries
/// `state=preparing` is an accepted preparation.
pub fn create(
    scripts: &Path,
    host: &str,
    item: &str,
    repo: &str,
    harness: &str,
    account: &str,
    relaunch: bool,
) -> Result<Created, String> {
    let mut args = vec![
        "create",
        "--item",
        item,
        "--repo",
        repo,
        "--harness",
        harness,
        "--account",
        account,
    ];
    if relaunch {
        args.push("--relaunch");
    }
    let out = call(scripts, host, "create", &args, PREPARE_BOUND)
        .map_err(|cause| format!("host-create-failed cause={cause}"))?;
    let line = host::stdout_text(&out);
    let mut created = Created {
        target: String::new(),
        path: String::new(),
        prefix: String::new(),
        preparing: false,
        pi_root: None,
    };
    for field in line.split('\t') {
        match field.split_once('=') {
            Some(("pi-root", v)) => created.pi_root = Some(v.to_owned()),
            Some(("ssh-target", v)) => created.target = v.to_owned(),
            Some(("path", v)) => created.path = v.to_owned(),
            Some(("remote-prefix", v)) => created.prefix = v.to_owned(),
            Some(("state", "preparing")) => created.preparing = true,
            Some(_) | None => {}
        }
    }
    match exit_code(&out) {
        0 => {}
        75 if created.preparing => {}
        75 => return Err("item-owned exit=75".to_owned()),
        _ => return Err(format!("host-create-failed {}", cause_of("create", &out))),
    }
    if created.target.is_empty()
        || created.path.is_empty()
        || created.prefix.is_empty()
        || line.contains('\n')
    {
        return Err("host-line-invalid".to_owned());
    }
    Ok(created)
}

/// After an accepted preparation: ready, or the cause the provider gave.
pub fn wait(scripts: &Path, host: &str, item: &str) -> Result<(), String> {
    let out = call(
        scripts,
        host,
        "wait",
        &["wait", "--item", item],
        PREPARE_BOUND,
    )
    .map_err(|cause| format!("host-wait-failed cause={cause}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("host-wait-failed {}", cause_of("wait", &out)))
    }
}

/// `bytes` written to the host's `path`, or the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's provider write through the one runner under the record's host, the bytes on the provider's stdin"
)]
pub fn put(scripts: &Path, host: &str, item: &str, path: &str, bytes: &[u8]) -> Result<(), String> {
    let env: [(&str, &OsStr); 1] = [("ORCH_LANE_HOST", OsStr::new(host))];
    let out = host::run_tagged_fed(
        TAG,
        LANE_HOST,
        &scripts.join(LANE_HOST),
        "put",
        &["put", "--item", item, path],
        Place {
            cwd: None,
            env: &env,
        },
        bytes,
        READ_BOUND,
    )
    .map_err(|e| format!("put {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(cause_of("put", &out))
    }
}

/// One provider call under `bound`, for the launch's long verbs.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch's provider calls, `lane-host` through the one runner under the record's host, each verb's bound its own"
)]
fn call(
    scripts: &Path,
    host: &str,
    operation: &'static str,
    args: &[&str],
    bound: Duration,
) -> Result<std::process::Output, String> {
    let env: [(&str, &OsStr); 1] = [("ORCH_LANE_HOST", OsStr::new(host))];
    host::run_tagged_in(
        TAG,
        LANE_HOST,
        &scripts.join(LANE_HOST),
        operation,
        args,
        Place {
            cwd: None,
            env: &env,
        },
        bound,
    )
    .map_err(|e| e.to_string())
}

// --- the one close ------------------------------------------------------------

/// How `lane-close` answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Closed {
    /// Exit 0: the lane closed; `line` is the `kept=` or `closed=absent`
    /// line it printed, `kept=none` without one.
    Closed { line: String },
    /// Exit 3: the close refused the lane; `path` the checkout its
    /// `close-refused path=` line names, `unknown` without one.
    Refused { path: String },
    /// A tracker quota receipt on the output: nothing closed, asked again
    /// once the hold ends.
    Deferred,
    /// Any other end: the status and the output's first line.
    Failed { cause: String },
}

/// `lane-close --state-dir [DIR] [ITEM]` through the one runner, both
/// streams read as one (`2>&1`), since the program's refusal lines land on
/// either.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane duty's one irreversible call, `lane-close` from the scripts directory the pass carries through the one runner under the duty's tag, its marker written first"
)]
fn run_close(scripts: &Path, state_dir: &Path, item: &str) -> Closed {
    let dir = state_dir.display().to_string();
    let out = match host::run_tagged(
        TAG,
        LANE_CLOSE,
        &scripts.join(LANE_CLOSE),
        "close",
        &["--state-dir", &dir, item],
        CLOSE_BOUND,
    ) {
        Ok(out) => out,
        Err(e) => {
            return Closed::Failed {
                cause: e.to_string(),
            };
        }
    };
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if !out.status.success() && Quota::of_stderr(&text).is_some() {
        return Closed::Deferred;
    }
    match out.status.code() {
        Some(0) => {
            // A host that no longer held the item ran no archive pass, so
            // its `closed=absent` line stands in the `kept=` line's place.
            let absent = format!("closed=absent item={item}");
            let line = text
                .lines()
                .find(|l| l.starts_with("kept=") || *l == absent)
                .map_or_else(|| "kept=none".to_owned(), str::to_owned);
            Closed::Closed { line }
        }
        Some(3) => {
            let path = text
                .lines()
                .find_map(|l| {
                    l.split_once("close-refused path=")
                        .map(|(_, p)| p.to_owned())
                })
                .unwrap_or_else(|| "unknown".to_owned());
            Closed::Refused { path }
        }
        Some(rc) => Closed::Failed {
            cause: format!("exit={rc} {}", first_line(&text))
                .trim_end()
                .to_owned(),
        },
        None => Closed::Failed {
            cause: format!("{} {}", out.status, first_line(&text))
                .trim_end()
                .to_owned(),
        },
    }
}

/// The marker a close writes before it runs: `lane-close.<item>` under the
/// watch's state directory, beside the wall relaunch markers.
pub fn close_marker_path(watch_state_dir: &Path, item: &str) -> PathBuf {
    let safe: String = item
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    watch_state_dir.join(format!("lane-close.{safe}"))
}

/// What the marker records: the item, why the watch asked, the pass that
/// asked and the launch the record carried, so a marker left by a close
/// that ended after this runtime died is told from the lane's next launch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseMarker {
    pub item: String,
    pub reason: String,
    pub at: u64,
    #[serde(default)]
    pub launch: Option<String>,
}

enum Written {
    Created,
    Standing,
}

/// Create the marker exclusively; one already there is an earlier close
/// whose end was not read.
#[allow(
    clippy::disallowed_methods,
    reason = "the close marker, the watch's own file under its state directory, created exclusively before `lane-close` starts so a close whose end this runtime does not see is never asked again"
)]
fn write_marker(path: &Path, marker: &CloseMarker) -> Result<Written, String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    let mut file = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return Ok(Written::Standing),
        Err(e) => return Err(format!("create {}: {e}", path.display())),
    };
    let text = serde_json::to_string(marker).map_err(|e| e.to_string())?;
    file.write_all(text.as_bytes())
        .and_then(|()| file.sync_data())
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(Written::Created)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the close marker's removal once `lane-close` answered, the watch's own file"
)]
fn remove_marker(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("remove {}: {e}", path.display())),
    }
}

/// The marker at `path`, three-valued.
pub fn close_marker(path: &Path) -> Answer<CloseMarker> {
    match std::fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str::<CloseMarker>(&text) {
            Ok(marker) => Answer::Live(marker),
            Err(e) => Answer::Unreadable {
                cause: e.to_string(),
            },
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Answer::Gone,
        Err(e) => Answer::Unreadable {
            cause: e.to_string(),
        },
    }
}

/// The markers under the watch's state directory, sorted; an absent
/// directory holds none.
fn close_markers(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let mut markers = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with("lane-close.")
        {
            continue;
        }
        let path = entry.path();
        if std::fs::metadata(&path).is_ok_and(|m| m.is_file()) {
            markers.push(path);
        }
    }
    markers.sort();
    Ok(markers)
}

/// The markers read against the fleet record at the start of every pass
/// a marker whose item no in-flight lane carries with the
/// launch it recorded is a close whose record `lane-close` wrote (or a lane
/// launched afresh), and leaves; a marker beside its in-flight lane is a
/// close this runtime did not see end, named as the operator's lane as the
/// pass's failure and never closed again; a directory or a marker that
/// cannot be read is the pass's failure and never "no marker".
pub fn prune_close_markers(pass: &Pass, out: &mut Produced) {
    let dir = watch_state_dir(pass.claim_store);
    let markers = match close_markers(dir) {
        Ok(markers) => markers,
        Err(cause) => {
            fail(
                out,
                format!("state-read-failed path={} cause={cause}", dir.display()),
            );
            return;
        }
    };
    for path in markers {
        let marker = match close_marker(&path) {
            Answer::Live(marker) => marker,
            Answer::Gone => continue,
            Answer::Unreadable { cause } => {
                fail(
                    out,
                    format!("state-read-failed path={} cause={cause}", path.display()),
                );
                continue;
            }
        };
        let stands = pass.fleet.lanes.iter().any(|l| {
            l.status.in_flight() && l.item == marker.item && l.launched_at == marker.launch
        });
        if stands {
            fail(out, unconfirmed(&marker.item, &path));
            continue;
        }
        if let Err(cause) = remove_marker(&path) {
            fail(
                out,
                format!("state-write-failed path={} cause={cause}", path.display()),
            );
        }
    }
}

/// Whether the tracker's quota hold stands over this lane's tracker
/// the receipt the tracker duty
/// recorded still holds at `now`, and the lane's tracker is linear (the
/// record's word, else the item key's: `issue-N` is GitHub's).
fn tracker_held(pass: &Pass, lane: &Lane) -> bool {
    let held = pass
        .baseline
        .get(QUOTA_ROW, "fleet")
        .and_then(|row| serde_json::from_str::<Quota>(row).ok())
        .is_some_and(|quota| quota.holds(pass.now));
    if !held {
        return false;
    }
    match lane.tracker.as_deref() {
        Some(tracker) => tracker == "linear",
        None => !lane.item.starts_with("issue-"),
    }
}

/// The failure line of a marker standing beside its open lane.
fn unconfirmed(item: &str, marker: &Path) -> String {
    format!(
        "lane-close-unconfirmed item={item} marker={}: an earlier close's end was not read, the lane is the operator's",
        marker.display()
    )
}

/// The one close: the marker created
/// exclusively before `lane-close` runs; an answer that closed nothing
/// (refused, deferred, failed) removes it, since nothing irreversible
/// happened and the next pass may ask again; a close that answered `closed`
/// keeps it until the next pass reads the lane record `lane-close` wrote
/// and finds the lane out of flight (`prune_close_markers`), so a record
/// that still reads open is the operator's lane, never a second close.
/// `None` is a close not asked: a marker standing from an earlier close, or
/// one this pass could not write, each the pass's failure.
fn close_once(pass: &Pass, lane: &Lane, reason: &str, out: &mut Produced) -> Option<Closed> {
    let item = &lane.item;
    let path = close_marker_path(watch_state_dir(pass.claim_store), item);
    let marker = CloseMarker {
        item: item.clone(),
        reason: reason.to_owned(),
        at: pass.now,
        launch: lane.launched_at.clone(),
    };
    match write_marker(&path, &marker) {
        Ok(Written::Created) => {}
        Ok(Written::Standing) => {
            fail(out, unconfirmed(item, &path));
            return None;
        }
        Err(cause) => {
            fail(
                out,
                format!(
                    "lane-close-unwritten item={item} marker={} cause={cause}",
                    path.display()
                ),
            );
            return None;
        }
    }
    let closed = run_close(pass.scripts, pass.state_dir, item);
    match closed {
        // The lane record `lane-close` wrote confirms the close on the next
        // pass's read; the marker stands until then.
        Closed::Closed { .. } => {}
        Closed::Refused { .. } | Closed::Deferred | Closed::Failed { .. } => {
            if let Err(cause) = remove_marker(&path) {
                fail(
                    out,
                    format!("state-write-failed path={} cause={cause}", path.display()),
                );
            }
        }
    }
    Some(closed)
}

/// The lines a close prints (`close_hosted_lane`): `lane-closed` with the
/// archive line, or `lane-close-refused` with the refused path.
fn say_closed(item: &str, closed: &Closed, out: &mut Produced) {
    match closed {
        Closed::Closed { line } => {
            out.events.push(Event::LaneClosed {
                item: item.to_owned(),
            });
            out.events.push(Event::Tail(line.clone()));
        }
        Closed::Refused { path } => {
            out.events.push(Event::LaneCloseRefused {
                item: item.to_owned(),
            });
            out.events.push(Event::Tail(format!("path={path}")));
        }
        Closed::Deferred => {}
        Closed::Failed { cause } => fail(out, format!("lane-close-failed item={item} {cause}")),
    }
}

// --- the stamps -------------------------------------------------------------

/// The epoch second a record stamp names, a fractional second stripped, as
/// every reader of a fleet stamp strips one.
pub fn epoch_of(stamp: &str) -> Option<u64> {
    if let Some(whole) = stamp.strip_suffix('Z')
        && let Some((seconds, fraction)) = whole.rsplit_once('.')
        && !fraction.is_empty()
        && fraction.bytes().all(|b| b.is_ascii_digit())
    {
        return clock::epoch_secs(&format!("{seconds}Z"));
    }
    clock::epoch_secs(stamp)
}

/// A record field as jq's `join` printed it: a string as is, null or
/// absent as nothing, any other value as its JSON.
fn text_of(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

// --- the prepare records ------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Prepare {
    Pending,
    Ready,
    Failed,
}

/// The hosted `prepare` records: a lane record carrying a `prepare`
/// object is `pending` while `preparing`, `ready` once `running`, `failed`
/// once `stopped` with a `prepare.reason`. Past `ORCH_WATCH_PREPARE_SECS` a
/// pending one is `lane-prepare-stuck` with its age and log, a ready one
/// `lane-ready`, a failed one `lane-prepare-failed` with the reason and log,
/// each once per `<since>|<outcome>` key; rows of items with no `prepare`
/// record go. The wall relaunch's own outcomes, read off its marker, keep
/// their `reason=relaunch-pending` lines in `overseer::relaunch_outcomes`:
/// the two records differ and so do their lines.
pub fn prepare(pass: &Pass, out: &mut Produced) {
    let bound = pass.settings.prepare.as_secs();
    let mut items = BTreeSet::new();
    for lane in &pass.fleet.lanes {
        let Some(record) = lane.extra.get("prepare").and_then(Value::as_object) else {
            continue;
        };
        let outcome = match lane.status {
            LaneStatus::Preparing => Prepare::Pending,
            LaneStatus::Running => Prepare::Ready,
            LaneStatus::Stopped if record.get("reason").is_some_and(|r| !r.is_null()) => {
                Prepare::Failed
            }
            LaneStatus::Stopped | LaneStatus::Parked | LaneStatus::Done => continue,
        };
        let item = lane.item.clone();
        items.insert(item.clone());
        let Some(since) = record
            .get("since")
            .and_then(Value::as_str)
            .and_then(epoch_of)
        else {
            fail(
                out,
                format!("state-invalid item={item} field=prepare.since"),
            );
            continue;
        };
        let age = pass.now.saturating_sub(since);
        let log = text_of(record.get("log"));
        let key = match outcome {
            Prepare::Pending => {
                if age <= bound {
                    continue;
                }
                format!("{since}|stuck")
            }
            Prepare::Ready => format!("{since}|ready"),
            Prepare::Failed => format!("{since}|failed"),
        };
        if pass.baseline.get(PREPARE_ROW, &item) == Some(key.as_str()) {
            continue;
        }
        out.changes.push(set(PREPARE_ROW, &item, key));
        out.events.push(match outcome {
            Prepare::Pending => Event::LanePrepareStuck {
                item,
                age,
                log,
                reason: None,
            },
            Prepare::Ready => Event::LaneReady { item },
            Prepare::Failed => Event::LanePrepareFailed {
                item,
                reason: text_of(record.get("reason")),
                exit: None,
                log,
            },
        });
    }
    for identity in pass.baseline.identities(PREPARE_ROW) {
        if !items.contains(&identity) {
            out.changes.push(clear(PREPARE_ROW, &identity));
        }
    }
}

// --- the pull request -------------------------------------------------------

/// The lane's open pull request as `item_open_pr` read it
/// (`lib/watch-host-kinds.sh:310`): its head, a digest of its body and its
/// draft flag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenPull {
    pub head: String,
    pub digest: String,
    pub draft: Option<bool>,
}

/// With no pull request open: the item branch's heads by repository
/// (`repo:sha`, comma-joined, a repository with no branch left out) and the
/// newest of their committed dates.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Branches {
    pub heads: String,
    pub newest: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PullRead {
    Open(OpenPull),
    None(Branches),
    Failed(String),
}

#[derive(Deserialize)]
struct ListedPull {
    head: ListedHead,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    draft: Option<bool>,
}

#[derive(Deserialize)]
struct ListedHead {
    sha: String,
}

#[derive(Deserialize)]
struct Branch {
    commit: BranchCommit,
}

#[derive(Deserialize)]
struct BranchCommit {
    sha: String,
    commit: CommitBody,
}

#[derive(Deserialize)]
struct CommitBody {
    committer: Committer,
}

#[derive(Deserialize)]
struct Committer {
    #[serde(default)]
    date: Option<String>,
}

/// The repositories a lane is read in: the one its record names, else the
/// fleet's in order.
fn repos_of<'a>(pass: &'a Pass, lane: &'a Lane) -> Vec<&'a str> {
    match lane.repo.as_deref().filter(|r| !r.is_empty()) {
        Some(repo) => vec![repo],
        None => pass.hosted.repos.iter().map(String::as_str).collect(),
    }
}

/// The open pull request on the item's branch in the first repository that
/// holds one, through `gh` (`item_open_pr`): the branch is the item key in
/// lower case, the list filtered to heads the repository's owner holds
/// (`lane_own`: a fork's pull request on a guessable branch name stands for
/// nothing), the body digested by the same POSIX `cksum` the record's
/// account walls are keyed by. With
/// none open, each repository's branch head and committed date. A list or a
/// branch read that fails is the failure, never "none open".
pub fn open_pr(pass: &Pass, lane: &Lane) -> PullRead {
    let gh = Gh {
        cli: pass.hosted.gh,
    };
    let branch = lane.item.to_ascii_lowercase();
    let mut branches = Branches::default();
    for repo in repos_of(pass, lane) {
        let owner = repo.split('/').next().unwrap_or(repo);
        let path = format!("repos/{repo}/pulls?head={owner}:{branch}&state=open");
        let pulls = match gh.object::<Vec<ListedPull>>("lane-pr", &path) {
            Ok(Some(pulls)) => pulls,
            Ok(None) => return PullRead::Failed(format!("pr-read-failed repo={repo} cause=404")),
            Err(e) => return PullRead::Failed(format!("pr-read-failed repo={repo} cause={e}")),
        };
        if let Some(pull) = pulls.into_iter().next() {
            let mut body = pull.body.unwrap_or_default();
            body.push('\n');
            return PullRead::Open(OpenPull {
                head: pull.head.sha,
                digest: wall::cksum(body.as_bytes()).to_string(),
                draft: pull.draft,
            });
        }
        let path = format!("repos/{repo}/branches/{branch}");
        match gh.object::<Branch>("lane-branch", &path) {
            Ok(Some(head)) => {
                if !branches.heads.is_empty() {
                    branches.heads.push(',');
                }
                branches
                    .heads
                    .push_str(&format!("{repo}:{}", head.commit.sha));
                if let Some(date) = head
                    .commit
                    .commit
                    .committer
                    .date
                    .as_deref()
                    .and_then(epoch_of)
                    && branches.newest.is_none_or(|newest| date > newest)
                {
                    branches.newest = Some(date);
                }
            }
            Ok(None) => {}
            Err(e) => {
                return PullRead::Failed(format!("branch-read-failed repo={repo} cause={e}"));
            }
        }
    }
    PullRead::None(branches)
}

/// Whether the roster reads the lane's account out of credit
/// (`check_lane_stall`'s jq): its `credits` object carries a
/// `locked_reason`, or `remaining_dollars` at or below zero.
fn credit_locked(roster: &Roster, lane: &Lane) -> bool {
    let Some(account) = lane.account.as_deref() else {
        return false;
    };
    roster
        .rows
        .iter()
        .filter(|row| row.config_dir == account)
        .filter_map(|row| row.credits.as_ref())
        .any(|credits| {
            credits.get("locked_reason").is_some_and(|r| !r.is_null())
                || credits
                    .get("remaining_dollars")
                    .and_then(Value::as_f64)
                    .is_some_and(|d| d <= 0.0)
        })
}

// --- the cloud stall --------------------------------------------------------

/// `check_lane_stall` (`lib/watch-host-kinds.sh:368`) over every running
/// lane whose kind declares `status=none`, a cloud session no process read
/// reaches: a ready pull request is `state=finished` at once and never
/// closed, a draft on an account the roster reads out of credit
/// `state=out-of-credit`; otherwise the pull request's head and body digest
/// standing still for `ORCH_WATCH_LANE_STALL_SECS` is `lane-stalled` with the
/// age, once and then every `mark_repeat` passes, the row keeping the head,
/// the digest, the epoch either last moved, the pass count and the reported
/// state. At the bound a directive left unanswered closes the lane
/// (`cloud_stall_close`). A lane with no pull request has no row; one whose
/// read failed keeps its row and is the pass's failure.
pub fn cloud_stalls(pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    let mut items = BTreeSet::new();
    let mut roster: Option<Result<Roster, String>> = None;
    for lane in pass
        .fleet
        .lanes
        .iter()
        .filter(|l| l.status == LaneStatus::Running)
    {
        let Ok(caps) = hosts.of(lane) else {
            continue;
        };
        if caps.status != Status::None {
            continue;
        }
        let item = lane.item.as_str();
        items.insert(item.to_owned());
        let pull = match open_pr(pass, lane) {
            PullRead::Open(pull) => pull,
            PullRead::None(_) => {
                out.changes.push(clear(STALLED_ROW, item));
                continue;
            }
            PullRead::Failed(cause) => {
                fail(out, format!("lane-stall-unread item={item} {cause}"));
                continue;
            }
        };
        let state = match pull.draft {
            Some(false) => "finished",
            Some(true) => {
                let roster = roster.get_or_insert_with(|| (pass.hosted.roster)());
                match roster {
                    Ok(roster) if credit_locked(roster, lane) => "out-of-credit",
                    Ok(_) | Err(_) => "",
                }
            }
            None => "",
        };
        let prior = pass.baseline.get(STALLED_ROW, item).unwrap_or("");
        let mut fields = prior.split('|');
        let (_, _, prior_since, prior_passes, reported) = (
            fields.next().unwrap_or(""),
            fields.next().unwrap_or(""),
            fields.next().unwrap_or(""),
            fields.next().unwrap_or(""),
            fields.next().unwrap_or(""),
        );
        let moved = !prior.starts_with(&format!("{}|{}|", pull.head, pull.digest));
        let since = if moved {
            pass.now
        } else {
            prior_since.parse::<u64>().unwrap_or(pass.now)
        };
        let mut passes = if moved && state.is_empty() {
            ""
        } else {
            prior_passes
        };
        let age = pass.now.saturating_sub(since);
        let bound = pass.settings.lane_stall.as_secs();
        let row = |passes: &str, state: &str| {
            format!("{}|{}|{since}|{passes}|{state}", pull.head, pull.digest)
        };
        if state.is_empty() && age < bound {
            out.changes.push(set(STALLED_ROW, item, row("", "")));
            continue;
        }
        // A ready pull request waits for landing; closing it would relaunch
        // completed work.
        if state != "finished" && age >= bound && cloud_stall_close(pass, lane, since, out) {
            continue;
        }
        if state != reported {
            passes = "";
        }
        let passes = match passes.parse::<u32>() {
            Ok(count) => {
                let next = count + 1;
                if next < pass.settings.mark_repeat {
                    next
                } else {
                    0
                }
            }
            Err(_) => 0,
        };
        if passes == 0 {
            out.events.push(Event::LaneStalled {
                item: item.to_owned(),
                age,
                state: (!state.is_empty()).then(|| state.to_owned()),
            });
        }
        out.changes
            .push(set(STALLED_ROW, item, row(&passes.to_string(), state)));
    }
    for identity in pass.baseline.identities(STALLED_ROW) {
        if !items.contains(&identity) {
            out.changes.push(clear(STALLED_ROW, &identity));
        }
    }
}

/// `cloud_stall_close` (`lib/watch-host-kinds.sh:431`): the lane's
/// `directive_send.at` at or after `since`, the last move the stall saw, and
/// `ORCH_CLOUD_STALL_MINUTES` old, closes the lane through the one close:
/// `lane-closed` with its archive line, then `cloud-stall-closed` with the
/// directive's age. A refusal is `lane-close-refused` and the lane kept; a
/// tracker quota hold, before the call or on its answer, defers it; a
/// failed call is the pass's failure. `true` for a lane closed.
fn cloud_stall_close(pass: &Pass, lane: &Lane, since: u64, out: &mut Produced) -> bool {
    let Some(at) = lane
        .extra
        .get("directive_send")
        .and_then(|d| d.get("at"))
        .and_then(Value::as_u64)
    else {
        return false;
    };
    if at < since || at > pass.now || pass.now - at < pass.settings.cloud_stall.as_secs() {
        return false;
    }
    if tracker_held(pass, lane) {
        return false;
    }
    let Some(closed) = close_once(pass, lane, "cloud-stall", out) else {
        return false;
    };
    say_closed(&lane.item, &closed, out);
    match closed {
        Closed::Closed { .. } => {
            out.events.push(Event::CloudStallClosed {
                item: lane.item.clone(),
                directive_age: pass.now - at,
            });
            true
        }
        Closed::Refused { .. } | Closed::Deferred | Closed::Failed { .. } => false,
    }
}

/// The start stall of a cloud lane: a running
/// cloud lane with no pull request yet. A push since the launch starts the
/// session and the row keeps it as `pushed`, so `start-stalled` never goes
/// out for it: a branch head committed at or after the record's
/// `session_since`, or a head that moved between two reads of the running
/// record. A push dates `since`, which bounds a directive the session leaves
/// unanswered before its pull request opens, as `cloud_stalls` bounds one
/// after; a started session with no move for `ORCH_WATCH_LANE_STALL_SECS` is
/// `lane-stalled`. A session that never pushed is `start-stalled` past
/// `ORCH_WATCH_START_STALL_SECS`, counted as the local arm counts it. An open
/// pull request ends the watch as a status file does; a read that failed is
/// `start-stall-unread`, no line.
pub fn cloud_start_stall(lane: &Lane, pass: &Pass, out: &mut Produced) {
    let name = lane_name(lane);
    let item = lane.item.as_str();
    let Some(running) = lane.running_at.as_deref().and_then(epoch_of) else {
        return;
    };
    if lane.mail_root.as_deref().is_none_or(str::is_empty) {
        return;
    }
    let prior = pass
        .baseline
        .get("start-stalled", &name)
        .unwrap_or_default();
    if prior == format!("{running}|seen") {
        return;
    }
    let branches = match open_pr(pass, lane) {
        PullRead::Open(_) => {
            out.changes
                .push(set("start-stalled", &name, format!("{running}|seen")));
            return;
        }
        PullRead::None(branches) => branches,
        PullRead::Failed(cause) => {
            fail(out, format!("start-stall-unread item={item} {cause}"));
            return;
        }
    };
    let mut fields = prior.split('|');
    let (prior_running, second, prior_head, prior_since, prior_stalled) = (
        fields.next().unwrap_or(""),
        fields.next().unwrap_or(""),
        fields.next().unwrap_or(""),
        fields.next().unwrap_or(""),
        fields.next().unwrap_or(""),
    );
    let same_launch = prior_running == running.to_string();
    let session_since = lane.session_since.as_deref().and_then(epoch_of);
    let started = (same_launch && (second == "pushed" || prior_head != branches.heads))
        || matches!((session_since, branches.newest), (Some(since), Some(date)) if date >= since);
    let (since, stalled) = if !same_launch || prior_head != branches.heads || prior_since.is_empty()
    {
        let since = if branches.heads.is_empty() && prior_head.is_empty() {
            running
        } else {
            pass.now
        };
        (since, "")
    } else {
        (
            prior_since.parse::<u64>().unwrap_or(pass.now),
            prior_stalled,
        )
    };
    let started_word = if started { "pushed" } else { "" };
    let row = |second: &str, stalled: &str| {
        format!("{running}|{second}|{}|{since}|{stalled}", branches.heads)
    };
    let age = pass.now.saturating_sub(running);
    if age < pass.settings.start_stall.as_secs() {
        out.changes
            .push(set("start-stalled", &name, row(started_word, "")));
        return;
    }
    if cloud_stall_close(pass, lane, since, out) {
        return;
    }
    if started {
        let mut stalled = stalled.to_owned();
        if pass.now.saturating_sub(since) >= pass.settings.lane_stall.as_secs() {
            let count = match stalled.parse::<u32>() {
                Ok(count) => {
                    let next = count + 1;
                    if next < pass.settings.mark_repeat {
                        next
                    } else {
                        0
                    }
                }
                Err(_) => 0,
            };
            if count == 0 {
                out.events.push(Event::LaneStalled {
                    item: item.to_owned(),
                    age: pass.now.saturating_sub(since),
                    state: None,
                });
            }
            stalled = count.to_string();
        }
        out.changes
            .push(set("start-stalled", &name, row("pushed", &stalled)));
        return;
    }
    let passes = match second.parse::<u32>() {
        Ok(count) if same_launch => {
            let next = count + 1;
            if next < pass.settings.mark_repeat {
                next
            } else {
                0
            }
        }
        Ok(_) | Err(_) => 0,
    };
    if passes == 0 {
        out.events.push(Event::StartStalled {
            item: name.clone(),
            age,
        });
    }
    out.changes
        .push(set("start-stalled", &name, row(&passes.to_string(), "")));
}

// --- the hosted files -------------------------------------------------------

/// The lane's root on its host, the record's `mail_root`; none for a record
/// naming no root.
fn root_of(lane: &Lane) -> Option<&str> {
    lane.mail_root.as_deref().filter(|r| !r.is_empty())
}

/// The lane's status file through the provider: `<root>/tmp/lane-status-
/// <item>.md`.
pub fn status_file(pass: &Pass, lane: &Lane) -> Answer<String> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    fetch(
        pass.scripts,
        host_of(lane),
        &lane.item,
        &format!("{root}/tmp/lane-status-{}.md", lane.item),
    )
}

/// Whether the lane's worktree stands on its host, read as `lane_hosted_clone`
/// read it (`lib/lane-gitfile.sh:97`): its `.git` through `cat`; a file the
/// host has not, confirmed by `touch`, is the worktree the lane's own
/// close-out removed.
pub fn worktree(pass: &Pass, lane: &Lane) -> Answer<()> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    match fetch(
        pass.scripts,
        host_of(lane),
        &lane.item,
        &format!("{root}/.git"),
    ) {
        Answer::Live(_) => Answer::Live(()),
        Answer::Gone => Answer::Gone,
        Answer::Unreadable { cause } => Answer::Unreadable { cause },
    }
}

/// The `Step` line of a hosted lane's status file (`lane_step`,
/// `lib/watch-host-kinds.sh:498`): `unread` where the fetch failed, `none`
/// where the host has no file or it names no step.
pub fn step(pass: &Pass, lane: &Lane) -> String {
    match status_file(pass, lane) {
        Answer::Live(text) => step_of(&text),
        Answer::Gone => "none".to_owned(),
        Answer::Unreadable { .. } => "unread".to_owned(),
    }
}

/// A hosted lane's `lane-long` counters (`lane_long_rounds`,
/// `lib/watch-host-kinds.sh:472`; `lane_item_state`'s hosted arm): the
/// item's workflow state and the run index under the lane's root on its
/// host, each through `cat`; a state the lane has not written, or one that
/// could not be read, counts nothing and the read's failure is said.
pub fn counters(pass: &Pass, lane: &Lane, out: &mut Produced) -> Counters {
    let Some(root) = root_of(lane) else {
        return Counters::unread();
    };
    let host = host_of(lane);
    let runs = match fetch(
        pass.scripts,
        host,
        &lane.item,
        &format!("{root}/tmp/validation-runs"),
    ) {
        Answer::Live(text) => validation_runs_of(&text),
        Answer::Gone | Answer::Unreadable { .. } => None,
    };
    match fetch(
        pass.scripts,
        host,
        &lane.item,
        &format!("{root}/tmp/workflow-state-{}.json", lane.item),
    ) {
        Answer::Live(text) => match serde_json::from_str::<Value>(&text) {
            Ok(Value::Object(doc)) => counters_of(&doc, runs).unwrap_or_else(Counters::unread),
            Ok(
                Value::Null
                | Value::Bool(_)
                | Value::Number(_)
                | Value::String(_)
                | Value::Array(_),
            )
            | Err(_) => Counters::unread(),
        },
        Answer::Gone => Counters::unread(),
        Answer::Unreadable { cause } => {
            fail(
                out,
                format!("lane-long-rounds-unread item={} cause={cause}", lane.item),
            );
            Counters::unread()
        }
    }
}

// --- the finished-hosted close ------------------------------------------------

/// The finished-hosted close at a hosted lane's
/// `lane-exited` or `lane-idle` line: a lane whose item the GitHub duty read
/// merged and whose worktree the host no longer has is closed through the
/// one close; one whose worktree stands is inside its merge close-out or
/// resumed and is left. A failed close un-reports the notification row, so
/// the next pass asks again; a deferred one keeps `close-pending` for the
/// retry; a close that ended clears it. `row` and `key` are the notification
/// row and the key it reported under.
pub fn close_finished(
    lane: &Lane,
    pass: &Pass,
    hosts: &Hosts,
    row: &str,
    key: &str,
    out: &mut Produced,
) {
    let name = lane_name(lane);
    let Ok(caps) = hosts.of(lane) else {
        return;
    };
    if host_of(lane) == "local" || caps.files != Files::Verb {
        return;
    }
    if pass
        .baseline
        .get(MERGED_ROW, &lane.item)
        .is_none_or(str::is_empty)
    {
        return;
    }
    match worktree(pass, lane) {
        Answer::Live(()) => return,
        Answer::Gone => {}
        Answer::Unreadable { cause } => {
            fail(
                out,
                format!("worktree-read-failed item={} cause={cause}", lane.item),
            );
            return;
        }
    }
    let pending = format!("{row}|{key}");
    if tracker_held(pass, lane) {
        out.changes.push(set(CLOSE_PENDING_ROW, &name, pending));
        return;
    }
    let Some(closed) = close_once(pass, lane, "finished", out) else {
        return;
    };
    say_closed(&lane.item, &closed, out);
    match closed {
        Closed::Failed { .. } => {
            out.changes.push(set(row, &name, key.to_owned()));
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
        }
        Closed::Deferred => out.changes.push(set(CLOSE_PENDING_ROW, &name, pending)),
        Closed::Closed { .. } | Closed::Refused { .. } => {
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
        }
    }
}

/// The retry of closes the tracker's hold deferred:
/// only one pending at the pass's entry and untouched by it, while its
/// notification row still reads `<key>|reported`; a new pane or state ends
/// the earlier pending close.
pub fn retry_pending_closes(lanes: &[&Lane], pass: &Pass, hosts: &Hosts, out: &mut Produced) {
    for lane in lanes {
        let name = lane_name(lane);
        let Some(pending) = pass.baseline.get(CLOSE_PENDING_ROW, &name) else {
            continue;
        };
        let touched = out.changes.iter().any(|change| match change {
            Change::Set { kind, identity, .. } | Change::Clear { kind, identity } => {
                identity == &name
                    && (kind == CLOSE_PENDING_ROW || pending.starts_with(&format!("{kind}|")))
            }
            Change::Pass { .. } => false,
        });
        if touched {
            continue;
        }
        let Some((row, key)) = pending.split_once('|') else {
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
            continue;
        };
        if pass.baseline.get(row, &name) == Some(format!("{key}|reported").as_str()) {
            close_finished(lane, pass, hosts, row, key, out);
        } else {
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The capability line as the dispatcher validates it: the three keys
    /// this duty acts on, `pane` absent reading `local`, a value outside
    /// its set refused, a key outside the set passed.
    #[test]
    fn the_capability_line_is_read_by_its_keys() {
        let ssh = Capabilities::parse(
            "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\tpool=plan\n",
        )
        .unwrap();
        assert_eq!(
            ssh,
            Capabilities {
                files: Files::Verb,
                status: Status::Verb,
                pane: PaneKind::Local,
                launch: Some(Launch::Ssh),
            }
        );
        let cloud =
            Capabilities::parse("kind=claude-cloud\tfiles=none\tstatus=none\tpane=verb").unwrap();
        assert_eq!(cloud.files, Files::None);
        assert_eq!(cloud.status, Status::None);
        assert_eq!(cloud.pane, PaneKind::Verb);
        assert!(Capabilities::parse("kind=ssh\tfiles=verb").is_err());
        assert!(Capabilities::parse("files=verb\tstatus=elsewhere").is_err());
        assert!(Capabilities::parse("files=verb\tstatus=verb\tbroken").is_err());
    }

    /// The stamps a record carries, with and without a fractional second.
    #[test]
    fn a_stamp_reads_with_or_without_a_fractional_second() {
        assert_eq!(epoch_of("2027-01-15T04:29:59Z"), Some(1_799_987_399));
        assert_eq!(epoch_of("2027-01-15T04:29:59.123Z"), Some(1_799_987_399));
        assert_eq!(epoch_of("2027-01-15T04:29:59.Z"), None);
        assert_eq!(epoch_of("yesterday"), None);
    }
}
