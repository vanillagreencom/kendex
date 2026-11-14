//! The hosted readings of the lane duty: the preparation, stall, start-stall,
//! long-lane and handoff readings of a hosted lane, a Pi lane's session rows,
//! its status verb, over the fleet record's hosted lanes and inside the lane
//! duty's pass (`watch::lanes`); the finished close of a merged lane, local
//! or hosted; and the provider calls a hosted launch makes, the run of a
//! `pane=verb` provider's prefix among them.
//!
//! Every provider read is one `provider::call` on the record's host,
//! three-valued: a `cat` that exits 2 is a missing file only once a `touch`
//! of the host answers, and every other status, and every call the dispatch
//! refused (`host-kind-verb`, `host-local`, `host-busy`), is unreadable with
//! its cause and never "no file". The capability line a host declares is
//! read once per host per pass; a record naming no host is the `local`
//! kind, whose line the dispatch answers in process.
//!
//! The one close: the close verb (`orch-runtime --state-dir DIR op --fleet`
//! over a `close-lane` request, from the scripts directory the pass
//! carries) is the irreversible step's owner and writes the lane record;
//! the watch says it asked by a marker it creates exclusively under its own
//! state directory before the verb starts, beside the wall relaunch
//! markers. An answer that closed nothing removes the marker; a
//! close that answered `closed` keeps it until the next pass reads the lane
//! record out of flight. A marker standing beside a lane still in flight is
//! a close whose end this runtime did not see: nothing is closed again, the
//! pass names it as its failure each pass, and the lane is the operator's.
//! The baseline rows (`lane-stalled`, `start-stalled`, `lane-long`,
//! `lane-prepare`, `close-pending`, `park-owed`) go through the runner's commit as every
//! row does.

// Every reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::verify::wire::{Branch, Nullable, Pull};

use super::Produced;
use super::baseline::Change;
use super::events::Event;
use super::lanes::{
    Counters, HandoffReading, Pass, clear, counters_of, doc_of, fail, handoff_places, lane_name,
    set, standing_record, step_of, validation_runs_of, watch_state_dir,
};
use super::tracker::{QUOTA_ROW, Quota};
use crate::marker;
use crate::ops::CLOUD_KIND;
use crate::settings;
use crate::state::{self, Lane, LaneStatus};
use agent_runtime::accounts::Roster;

/// The tag the lane duty's provider calls are counted under.
const TAG: &str = "lanes";
/// The bound on one provider read: an ssh round trip behind the slot wait
/// (`ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS`, 30 s).
/// The close's fetch of the landed base takes it too: one network read.
pub(crate) const READ_BOUND: Duration = Duration::from_secs(120);
/// The bound on the provider's close: a host close archives the lane's
/// records and removes its worktree before it answers.
const CLOSE_BOUND: Duration = Duration::from_secs(900);
/// The bound on the close verb: its provider reads, each under
/// [`READ_BOUND`], the tracker's verdict and the mailbox, then the
/// provider's close under [`CLOSE_BOUND`].
const CLOSE_VERB_BOUND: Duration = Duration::from_secs(1800);
/// The runtime's own entry under the scripts directory the pass carries,
/// which the close verb runs through as its own process.
pub const ORCH_RUNTIME: &str = "orch-runtime";
/// The rows this module keeps.
pub const STALLED_ROW: &str = "lane-stalled";
pub const PREPARE_ROW: &str = "lane-prepare";
/// `close-pending<TAB><lane><TAB><row>|<key>`: a finished close the
/// tracker's quota hold deferred, retried while the notification row still
/// reads `<key>|reported`.
pub const CLOSE_PENDING_ROW: &str = "close-pending";
/// `lane-left<TAB><lane><TAB><screen key>|reported`: the screen under which
/// a merged lane read neither idle nor exited was asked whether its work
/// left nothing behind.
pub const LEFT_ROW: &str = "lane-left";
/// `park-owed<TAB><item><TAB><result>`: the last result told of the park a
/// stopped record still owes, cleared once the record owes none.
pub const PARK_OWED_ROW: &str = "park-owed";
/// `clone-root<TAB><item><TAB><clone>`: the clone a hosted lane's worktree
/// `.git` named on the last pass that read it, kept once the worktree is
/// gone, since the merge's saved state stays in that clone.
pub const CLONE_ROW: &str = "clone-root";
/// The row the GitHub duty writes for an item's merged pull requests, which
/// admits the finished close.
const MERGED_ROW: &str = super::github::MERGED_ROW;

/// The reads the hosted arms take beyond the scripts directory, injected
/// so a row plants them: `gh` as the GitHub duty resolves it, the account
/// roster for a draft pull request's credit, and the fleet's checkout and
/// settings, whose repositories a lane naming none is read in.
pub struct Reads<'a> {
    pub gh: &'a Path,
    /// `lanes list --json` (`accounts::roster`), read once per pass and
    /// only for a cloud lane whose pull request is a draft.
    pub roster: &'a dyn Fn() -> Result<Roster, String>,
    /// The fleet's checkout, whose own repository comes first.
    pub project: &'a Path,
    /// The connected repositories, after the fleet's own.
    pub reads: &'a crate::settings::ReadSettings,
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
    /// How a kind's lane is stopped (`stop=`); `None` where the line names
    /// none, which no close has an arm for.
    pub stop: Option<StopKind>,
    /// The credit a kind's lane spends (`pool=`).
    pub pool: CreditPool,
}

/// The credit a kind's lane spends (`pool=`): an account's plan, or the
/// cloud's credit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreditPool {
    Plan,
    CloudCredit,
}

impl CreditPool {
    pub fn word(self) -> &'static str {
        match self {
            CreditPool::Plan => "plan",
            CreditPool::CloudCredit => "cloud-credit",
        }
    }
}

/// The closed set of values each key of a capability line takes; a key
/// outside it is no capability (`schemas/lane-host.md` § Host kinds).
const CAPABILITY_SETS: [(&str, &[&str]); 12] = [
    ("kind", &["local", "ssh", "claude-cloud", "codex-cloud"]),
    ("launch", &["window", "ssh", "cloud-session", "cloud-task"]),
    ("channel", &["mailbox", "session", "task"]),
    ("files", &["local", "verb", "none"]),
    ("status", &["pane", "verb", "task", "none"]),
    ("stop", &["window", "verb", "none"]),
    ("relaunch", &["resume", "fresh"]),
    ("park", &["verb", "none"]),
    ("accounts", &["verb", "none"]),
    ("pool", &["plan", "cloud-credit"]),
    ("land", &["lane", "handoff"]),
    ("pane", &["local", "verb"]),
];

/// How a kind's lane is stopped (`stop=`): its window's harness through this
/// host's process table, the provider's `stop` verb, or nothing this machine
/// can reach (a cloud session, which the operator archives).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopKind {
    Window,
    Verb,
    None,
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
    /// The `local` kind's line, the one a record naming no other host runs
    /// under.
    pub fn local() -> Capabilities {
        Capabilities::parse(crate::provider::LOCAL_LINE)
            .expect("the local kind's line is a whole line")
    }

    /// One tab-separated `key=value` line holding every key of
    /// [`CAPABILITY_SETS`] once, each with a value from its set: a line
    /// with a key missing, repeated or outside the sets, or a value outside
    /// its key's set, is refused `capability-invalid key=KEY value=VALUE`,
    /// so no line is half read and no key guessed.
    pub fn parse(line: &str) -> Result<Capabilities, String> {
        let line = line.strip_suffix('\n').unwrap_or(line);
        if line.contains('\n') {
            return Err("capability-invalid key=line value=lines".to_owned());
        }
        let mut given: BTreeMap<&str, &str> = BTreeMap::new();
        for field in line.split('\t') {
            let (key, value) = field.split_once('=').unwrap_or((field, ""));
            let allowed = CAPABILITY_SETS
                .iter()
                .find(|(k, _)| *k == key)
                .is_some_and(|(_, set)| set.contains(&value));
            if !allowed || given.insert(key, value).is_some() {
                return Err(format!("capability-invalid key={key} value={value}"));
            }
        }
        if let Some((key, _)) = CAPABILITY_SETS.iter().find(|(k, _)| !given.contains_key(k)) {
            return Err(format!("capability-invalid key={key} value="));
        }
        let of = |key: &str| given.get(key).copied().unwrap_or("");
        Ok(Capabilities {
            files: match of("files") {
                "local" => Files::Local,
                "verb" => Files::Verb,
                _ => Files::None,
            },
            status: match of("status") {
                "pane" => Status::Pane,
                "verb" => Status::Verb,
                "task" => Status::Task,
                _ => Status::None,
            },
            pane: match of("pane") {
                "verb" => PaneKind::Verb,
                _ => PaneKind::Local,
            },
            launch: Some(match of("launch") {
                "window" => Launch::Window,
                "ssh" => Launch::Ssh,
                "cloud-session" => Launch::CloudSession,
                _ => Launch::CloudTask,
            }),
            stop: Some(match of("stop") {
                "window" => StopKind::Window,
                "verb" => StopKind::Verb,
                _ => StopKind::None,
            }),
            pool: match of("pool") {
                "plan" => CreditPool::Plan,
                _ => CreditPool::CloudCredit,
            },
        })
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
/// per pass: the `local` kind answers in-process; any other host through
/// [`capabilities`]. A line that could not be read or parsed
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
            return Ok(Capabilities::local());
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

/// One provider read on `host` under [`READ_BOUND`]; `Err` is a call the
/// dispatch refused (`host-busy` among them), or one that could not run or
/// answer within the bound. The scripts directory the hosted readings carry
/// names the runtime's own entry, never the provider.
fn lane_host(_scripts: &Path, host: &str, args: &[&str]) -> Result<std::process::Output, String> {
    crate::provider::call(host, args, None, READ_BOUND, TAG).map_err(|f| f.to_string())
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

/// The capability line `host` declares, parsed, or the cause.
pub fn capabilities(_scripts: &Path, host: &str) -> Result<Capabilities, String> {
    crate::provider::capabilities(host, READ_BOUND, TAG)
        .map_err(|cause| format!("host-capabilities-unread host={host} cause={cause}"))
}

/// `cat --item ITEM PATH`; a `2` is a missing file only once
/// `touch --item ITEM` answers, since a provider's own refusals exit `2`
/// as well; a `touch` that fails, a call the dispatch refused and any other
/// status are unreadable with their cause.
pub fn fetch(scripts: &Path, host: &str, item: &str, path: &str) -> Answer<String> {
    let out = match lane_host(scripts, host, &["cat", "--item", item, path]) {
        Ok(out) => out,
        Err(cause) => {
            return Answer::Unreadable {
                cause: format!("cat {cause}"),
            };
        }
    };
    match out.status.code() {
        Some(0) => Answer::Live(String::from_utf8_lossy(&out.stdout).into_owned()),
        Some(2) => match lane_host(scripts, host, &["touch", "--item", item]) {
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

/// `status --item ITEM --harness H`: `running` or `exited` on
/// exit 0; any other
/// answer is a failed read, never an exit (`schemas/lane-host.md` § `status`).
pub fn status(scripts: &Path, host: &str, item: &str, harness: &str) -> Result<HostStatus, String> {
    let unread = |cause: String| format!("harness-probe-failed item={item} {cause}");
    let out = lane_host(
        scripts,
        host,
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

/// `capture --item ITEM`: the
/// provider's own pane for a `pane=verb` kind, the screen on exit 0; any
/// other answer is a failed read, never a screen.
pub fn capture(scripts: &Path, host: &str, item: &str) -> Result<String, String> {
    let out = lane_host(scripts, host, &["capture", "--item", item])
        .map_err(|cause| format!("capture-failed item={item} {cause}"))?;
    if !out.status.success() {
        return Err(format!(
            "capture-failed item={item} {}",
            cause_of("capture", &out)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `viewer-prefix --item ITEM`: the command a viewer of the lane's window
/// on this machine runs, the one nonempty line of exit 0, its trailing line
/// breaks dropped; `None` on exit 2, a provider with no such verb. Any
/// other status, or a call that never ran, is `host-viewer-failed`; an
/// empty answer, or one holding a line break, is `host-viewer-invalid`.
pub fn viewer_prefix(scripts: &Path, host: &str, item: &str) -> Result<Option<String>, String> {
    let out = lane_host(scripts, host, &["viewer-prefix", "--item", item])
        .map_err(|cause| format!("host-viewer-failed item={item} {cause}"))?;
    match out.status.code() {
        Some(0) => {}
        Some(2) => return Ok(None),
        Some(_) | None => {
            return Err(format!(
                "host-viewer-failed item={item} exit={}",
                exit_code(&out)
            ));
        }
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.trim_end_matches('\n');
    if line.is_empty() || line.contains('\n') {
        return Err(format!("host-viewer-invalid item={item}"));
    }
    Ok(Some(line.to_owned()))
}

/// `stop --item ITEM --harness H` before a hosted relaunch and after a
/// `pane=verb` launch that failed past its exec,
/// confirmed by exit 0 and the one line `stopped item=ITEM
/// processes=N`, read by `call`'s three values: `Failed` a refusal or an
/// unconfirmed answer (`stop-failed exit=N`), `Unknown` a stop that may
/// have signalled the harness or not (`stop-unanswered`).
pub fn stop(scripts: &Path, host: &str, item: &str, harness: &str) -> Result<(), Asked> {
    let code = match stop_answer(scripts, host, item, harness)? {
        HostStopped::Stopped { .. } => return Ok(()),
        HostStopped::WorktreeRemoved => WORKTREE_REMOVED,
        HostStopped::Refused { status } => status,
        HostStopped::Unparsed => 0,
    };
    Err(Asked::Failed(format!("stop-failed exit={code}")))
}

/// What the provider's stop answered: the harness stopped, the count of
/// processes it signalled; the item's
/// worktree gone (status 4 beside `stop-worktree-removed item=ITEM` on its
/// stderr), which only a provider finding the harness by that directory
/// answers, a status 4 without the line being the provider's own 4; any
/// other non-zero status; or exit 0 without the confirming line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostStopped {
    Stopped { processes: u32 },
    WorktreeRemoved,
    Refused { status: i32 },
    Unparsed,
}

/// The status a provider answers on any verb for an item whose worktree
/// its own close-out removed.
const WORKTREE_REMOVED: i32 = 4;

/// The word every cause of a call refused at the provider-call bound
/// leads with: nothing ran.
pub const BUSY: &str = "host-busy";

/// `stop --item ITEM --harness H`, its answer read as a [`HostStopped`]; a
/// stop that never started, gave no answer or was refused at the bound is
/// `call`'s `Asked`.
pub fn stop_answer(
    scripts: &Path,
    host: &str,
    item: &str,
    harness: &str,
) -> Result<HostStopped, Asked> {
    let out = call(
        scripts,
        host,
        "stop",
        &["stop", "--item", item, "--harness", harness],
        READ_BOUND,
        "stop",
    )?;
    let code = exit_code(&out);
    let stderr = host::stderr_text(&out);
    if code == WORKTREE_REMOVED
        && stderr
            .split_whitespace()
            .collect::<Vec<_>>()
            .windows(2)
            .any(|w| w[0] == "stop-worktree-removed" && w[1] == format!("item={item}"))
    {
        return Ok(HostStopped::WorktreeRemoved);
    }
    if code != 0 {
        return Ok(HostStopped::Refused { status: code });
    }
    let text = host::stdout_text(&out);
    let processes = text
        .strip_prefix(&format!("stopped item={item} processes="))
        .filter(|count| !count.is_empty() && count.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|count| count.parse().ok());
    match processes {
        Some(processes) => Ok(HostStopped::Stopped { processes }),
        None => Ok(HostStopped::Unparsed),
    }
}

/// `send --item ITEM --key KEY`: one key, `C-c` among them, as the
/// provider's own input to its pane, confirmed by exit 0; any other answer
/// is its cause.
pub fn send_key(scripts: &Path, host: &str, item: &str, key: &str) -> Result<(), String> {
    let out = lane_host(scripts, host, &["send", "--item", item, "--key", key])?;
    if out.status.success() {
        Ok(())
    } else {
        Err(cause_of("send", &out))
    }
}

/// `send --item ITEM --file FILE` of `text`, the one way a text reaches a
/// hosted harness, through a file of the state directory's own written for
/// the call and removed after it. `Failed` is a send that typed nothing,
/// its cause leading with [`BUSY`] where every slot stayed taken, or one
/// the provider answered with a status (`send-failed exit=N`), which may
/// have typed part of the text; `Unknown` is a send with no answer
/// (`send-unanswered`).
#[allow(
    clippy::disallowed_methods,
    reason = "the send's own input file under the state directory, written for the one call and removed after it"
)]
pub fn send_text(
    scripts: &Path,
    host: &str,
    item: &str,
    state_dir: &Path,
    text: &str,
) -> Result<(), Asked> {
    let input = state_dir.join(format!("send.{item}.{}", std::process::id()));
    std::fs::write(&input, text).map_err(|e| {
        Asked::Failed(format!(
            "send-input-unwritten path={} cause={e}",
            input.display()
        ))
    })?;
    let path = input.display().to_string();
    let out = call(
        scripts,
        host,
        "send",
        &["send", "--item", item, "--file", &path],
        READ_BOUND,
        "send",
    );
    let _ = std::fs::remove_file(&input);
    let out = out?;
    if out.status.success() {
        return Ok(());
    }
    Err(Asked::Failed(
        format!(
            "send-failed exit={} {}",
            exit_code(&out),
            first_line(&host::stderr_text(&out))
        )
        .trim_end()
        .to_owned(),
    ))
}

/// What the provider's close answered: the archive line its close printed
/// (`kept=PATH`, `kept=none` where it printed none, or `closed=absent
/// item=ITEM` from a host that no longer holds the item), or its refusal
/// (exit 3, `close-refused path=` naming the checkout it kept).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostClosed {
    Closed { line: String },
    Refused { path: String },
}

/// `close --item ITEM [--merged]` under the close's bound, read by
/// `call`'s three values: a close that never started or answered a status is
/// `Asked::Failed` with the cause (leading with [`BUSY`] at the bound),
/// one with no answer `Asked::Unknown`, which its caller never asks again.
pub fn close(scripts: &Path, host: &str, item: &str, merged: bool) -> Result<HostClosed, Asked> {
    let mut args = vec!["close", "--item", item];
    if merged {
        args.push("--merged");
    }
    let out = call(scripts, host, "close", &args, CLOSE_BOUND, "host-close")?;
    let text = host::stdout_text(&out);
    let stderr = host::stderr_text(&out);
    match exit_code(&out) {
        0 => {
            let absent = format!("closed=absent item={item}");
            let line = text
                .lines()
                .find(|l| l.starts_with("kept=") || *l == absent)
                .map_or_else(|| "kept=none".to_owned(), str::to_owned);
            Ok(HostClosed::Closed { line })
        }
        3 => Ok(HostClosed::Refused {
            path: stderr
                .lines()
                .chain(text.lines())
                .find_map(|l| {
                    l.split_once("close-refused path=")
                        .map(|(_, p)| p.to_owned())
                })
                .unwrap_or_else(|| "unknown".to_owned()),
        }),
        _ => Err(Asked::Failed(format!(
            "host-close-failed {}",
            cause_of("close", &out)
        ))),
    }
}

/// `stop-sandbox [--check] --item ITEM`: the check confirmed by
/// `sandbox-stoppable item=ITEM`, the stop by `sandbox-stopped item=ITEM`.
/// A refusal is `Asked::Failed` with `exit=N` (2 the absent-verb status of a
/// provider without the pair), `cause=answer-unparsed` or [`BUSY`].
pub fn stop_sandbox(scripts: &Path, host: &str, item: &str, check: bool) -> Result<(), Asked> {
    let mut args = vec!["stop-sandbox"];
    if check {
        args.push("--check");
    }
    args.extend(["--item", item]);
    let (step, word) = if check {
        ("stop-sandbox-check", "sandbox-stoppable")
    } else {
        ("stop-sandbox", "sandbox-stopped")
    };
    let out = call(scripts, host, "stop-sandbox", &args, READ_BOUND, step)?;
    match exit_code(&out) {
        0 => {}
        code => return Err(Asked::Failed(format!("exit={code}"))),
    }
    if host::stdout_text(&out) == format!("{word} item={item}") {
        Ok(())
    } else {
        Err(Asked::Failed("cause=answer-unparsed".to_owned()))
    }
}

/// `start --item ITEM`, confirmed by `sandbox-started item=ITEM`,
/// which a provider answers for a sandbox already up as for a stopped one.
/// A refusal is `Asked::Failed` with `exit=N`, `cause=answer-unparsed` or
/// [`BUSY`].
pub fn start(scripts: &Path, host: &str, item: &str) -> Result<(), Asked> {
    let out = call(
        scripts,
        host,
        "start",
        &["start", "--item", item],
        PREPARE_BOUND,
        "start",
    )?;
    match exit_code(&out) {
        0 => {}
        code => return Err(Asked::Failed(format!("exit={code}"))),
    }
    if host::stdout_text(&out) == format!("sandbox-started item={item}") {
        Ok(())
    } else {
        Err(Asked::Failed("cause=answer-unparsed".to_owned()))
    }
}

/// The state of the sandbox the provider's `list` names for `item`: the
/// second field of a row whose first ends in `/ITEM`, in any case, outside
/// an `available` row; `None` where no such row stands, the sandbox gone.
/// `list` is the protocol's one presence read. `Err` is a list that failed
/// or was refused at the bound ([`BUSY`]).
pub fn lists_item(
    scripts: &Path,
    host: &str,
    item: &str,
) -> std::result::Result<Option<String>, String> {
    let out = lane_host(scripts, host, &["list"])?;
    if exit_code(&out) != 0 {
        return Err(cause_of("list", &out));
    }
    let suffix = format!("/{}", item.to_ascii_lowercase());
    Ok(host::stdout_text(&out).lines().find_map(|row| {
        let mut fields = row.split('\t');
        let name = fields.next().unwrap_or("").to_ascii_lowercase();
        let state = fields.next().unwrap_or("");
        (state != "available" && name.ends_with(&suffix)).then(|| state.to_owned())
    }))
}

// --- the launch's calls --------------------------------------------------------

/// The bound on `create` and `wait`: a provider clones, installs and builds
/// the lane's checkout before it answers.
const PREPARE_BOUND: Duration = Duration::from_secs(1800);

/// Why a provider's `create`, `wait` or `stop` gave no ready answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Asked {
    /// The provider answered a refusal or an unusable line, never started,
    /// or the dispatch refused the call.
    Failed(String),
    /// The call started and gave no answer within its bound, or ended with
    /// a status of 128 and above (a signal, or the shipped ssh provider's
    /// 255 for a failed ssh): the provider may have acted on the item.
    Unknown(String),
}

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
    /// The Copilot home a Copilot lane runs under on the host, where the
    /// provider named one.
    pub copilot_home: Option<String>,
    /// `tree=unrebased`: the item's retained tree stands on its own head,
    /// its rebase onto the base aborted on a conflict, the work intact.
    pub unrebased: bool,
}

/// The provider's `create` line parsed, or the cause. A `75` is an item
/// another session owns, named `item-owned`; a `75` whose line carries
/// `state=preparing` is an accepted preparation; a create that never
/// answered is `Asked::Unknown`.
pub fn create(
    scripts: &Path,
    host: &str,
    item: &str,
    repo: &str,
    harness: &str,
    account: &str,
    relaunch: bool,
) -> Result<Created, Asked> {
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
    let out = call(scripts, host, "create", &args, PREPARE_BOUND, "host-create")?;
    let line = host::stdout_text(&out);
    let mut created = Created {
        target: String::new(),
        path: String::new(),
        prefix: String::new(),
        preparing: false,
        pi_root: None,
        copilot_home: None,
        unrebased: kept_unrebased(&line),
    };
    for field in line.split('\t') {
        match field.split_once('=') {
            Some(("pi-root", v)) => created.pi_root = Some(v.to_owned()),
            Some(("copilot-home", v)) => created.copilot_home = Some(v.to_owned()),
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
        // The ssh provider's lock: another lifecycle call holds the item's
        // clone, the item's own earlier create among them.
        75 if host::stderr_text(&out).contains("lane-host-ssh: ownership-busy") => {
            return Err(Asked::Failed(format!(
                "host-create-busy {}",
                cause_of("create", &out)
            )));
        }
        75 => return Err(Asked::Failed("item-owned exit=75".to_owned())),
        _ => {
            return Err(Asked::Failed(format!(
                "host-create-failed {}",
                cause_of("create", &out)
            )));
        }
    }
    if created.target.is_empty()
        || created.path.is_empty()
        || created.prefix.is_empty()
        || line.contains('\n')
    {
        return Err(Asked::Failed("host-line-invalid".to_owned()));
    }
    Ok(created)
}

/// Whether a provider's answer line carries `tree=unrebased`.
fn kept_unrebased(line: &str) -> bool {
    line.split('\t').any(|field| field == "tree=unrebased")
}

/// After an accepted preparation: ready, with whether its answer carries
/// `tree=unrebased` (a preparing create learns the kept tree only here),
/// the cause the provider gave, or `Asked::Unknown` for a wait that never
/// answered.
pub fn wait(scripts: &Path, host: &str, item: &str) -> Result<bool, Asked> {
    let out = call(
        scripts,
        host,
        "wait",
        &["wait", "--item", item],
        PREPARE_BOUND,
        "host-wait",
    )?;
    if out.status.success() {
        Ok(kept_unrebased(&host::stdout_text(&out)))
    } else {
        Err(Asked::Failed(format!(
            "host-wait-failed {}",
            cause_of("wait", &out)
        )))
    }
}

/// `bytes` written to the host's `path`, or the cause.
pub fn put(
    _scripts: &Path,
    host: &str,
    item: &str,
    path: &str,
    bytes: &[u8],
) -> Result<(), String> {
    let out = crate::provider::call(
        host,
        &["put", "--item", item, path],
        Some(bytes),
        READ_BOUND,
        TAG,
    )
    .map_err(|f| format!("put {f}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(cause_of("put", &out))
    }
}

/// The ssh client's run of a `pane=verb` provider's prefix, `program` and
/// `args` as the launch's builder spelled them (`-T`, so no terminal is
/// asked for): the prefix starts the harness in a session the provider
/// owns on its host and returns. Stdin is closed, so nothing waits on this
/// machine's input. Exit 0 is the session started; a status of 1 to 127 a
/// prefix or client that refused (`host-exec-failed`); ssh's 255, a signal
/// or no answer within [`READ_BOUND`] may have started it
/// (`host-exec-unanswered`). Either failure may leave a harness, which the
/// caller asks the provider to stop.
#[allow(
    clippy::disallowed_methods,
    reason = "the hosted launch's one exec of a provider's prefix, through the one runner under this module's tag, its phase recorded by the launch first"
)]
pub fn run_prefix(program: &Path, args: &[String]) -> Result<(), Asked> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = match host::run_tagged(TAG, "ssh", program, "host-exec", &args, READ_BOUND) {
        Ok(out) => out,
        Err(e @ agent_runtime::Error::NotStarted { .. }) => {
            return Err(Asked::Failed(format!("host-exec-failed cause={e}")));
        }
        Err(e) => return Err(Asked::Unknown(format!("host-exec-unanswered cause={e}"))),
    };
    match out.status.code() {
        Some(0) => Ok(()),
        Some(1..=127) => Err(Asked::Failed(format!(
            "host-exec-failed {}",
            cause_of("ssh", &out)
        ))),
        Some(_) | None => Err(Asked::Unknown(format!(
            "host-exec-unanswered {}",
            cause_of("ssh", &out)
        ))),
    }
}

/// One provider call under `bound`, for the launch's long verbs, its
/// answer read by the runner's three values: a provider that never
/// started, or a call the dispatch refused, made nothing (`<key>-failed`,
/// or the [`BUSY`] cause at the bound); one whose bound passed, or that a
/// signal ended, may have acted (`<key>-unanswered`). A status of 128 and
/// above is a provider a signal ended, or one that passed such a status
/// up: the shipped ssh provider exits with ssh's 255 for a failed ssh, a
/// connection lost mid-call or one never opened alike. Either may have
/// acted, and none is held on: the launch fails and the next create asks
/// again, the wall route asks its stop again on its next pass.
fn call(
    _scripts: &Path,
    host: &str,
    operation: &'static str,
    args: &[&str],
    bound: Duration,
    key: &str,
) -> Result<std::process::Output, Asked> {
    use crate::provider::Failure;
    let out =
        crate::provider::call(host, args, None, bound, TAG).map_err(|failure| match failure {
            Failure::Busy { .. } => Asked::Failed(failure.to_string()),
            Failure::Unanswered(cause) => Asked::Unknown(format!("{key}-unanswered cause={cause}")),
            Failure::Refused { .. }
            | Failure::Invalid(_)
            | Failure::Exit { .. }
            | Failure::NotStarted(_) => Asked::Failed(format!("{key}-failed cause={failure}")),
        })?;
    if out.status.code().is_none_or(|code| code >= 128) {
        return Err(Asked::Unknown(format!(
            "{key}-unanswered {}",
            cause_of(operation, &out)
        )));
    }
    Ok(out)
}

// --- the one close ------------------------------------------------------------

/// How the close verb answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Closed {
    /// The lane closed, its harness ended with its sandbox kept, or its
    /// sandbox parked; `line` is the provider's `kept=` or `closed=absent`
    /// line, else `kept=` the item's own archive, `kept=none` with neither,
    /// and `kept=sandbox` for a sandbox kept.
    Closed { line: String },
    /// The provider refused its close; `path` the checkout its
    /// `close-refused path=` line names, `unknown` without one.
    Refused { path: String },
    /// The tracker's quota hold refused the verdict the close needs:
    /// nothing closed, asked again once the hold ends.
    Deferred,
    /// The verb refused, its effect failed or stood open with a cause, it
    /// never started, or it exited 1 or 2 with no reply: its key or cause.
    Failed { cause: String },
    /// No answer: the verb started and its bound passed, a signal ended
    /// it, it exited another status with no reply, or the provider's close
    /// gave none, so it may have happened. Its marker stands for the next
    /// pass, which leaves the lane to the operator.
    Unanswered { cause: String },
}

/// The close verb's request for `lane` at `reason`: a lane read exited on
/// two passes keeps its sandbox; a stopped record's owed park is that park
/// again, its wait alone, as an operator asks it: the verb takes the judged
/// head from the record; a finished lane's delivery is the merge the GitHub
/// duty read last for its item (`merged`, `REPO#N ...`).
fn close_request(pass: &Pass, lane: &Lane, reason: &str) -> Value {
    let mut request = serde_json::json!({"op": "close-lane", "item": lane.item});
    if reason == KEEP_REASON {
        request["mode"] = Value::from("keep-sandbox");
    }
    if reason == PARK_REASON
        && let Some(owed) = lane.extra.get(state::PARK_OWED)
    {
        let mut wait = owed.clone();
        if let Some(mark) = wait.as_object_mut() {
            mark.remove("head");
        }
        request["mode"] = serde_json::json!({ "park": wait });
    }
    let merged = pass
        .baseline
        .get(MERGED_ROW, &lane.item)
        .and_then(|row| row.split(' ').next_back())
        .and_then(|key| key.rsplit_once('#'))
        .and_then(|(repo, number)| Some((repo, number.parse::<u64>().ok()?)));
    if reason == "finished"
        && let Some((repo, pr)) = merged
    {
        request["delivery"] = serde_json::json!({"pr": {"pr": pr, "repo": repo}});
    }
    request
}

/// The reason the watch asks a close that keeps the sandbox.
pub const KEEP_REASON: &str = "exited-twice";

/// The reason the watch asks the park a stopped record still owes.
const PARK_REASON: &str = "park-owed";

/// The close verb through the runtime's entry, `--state-dir DIR op --fleet
/// --request FILE`, under its bound: the reply it printed, read by its word.
#[allow(
    clippy::disallowed_methods,
    reason = "the lane duty's one irreversible call, the close verb through the runtime's entry from the scripts directory the pass carries, through the one runner under the duty's tag, its marker written first"
)]
fn run_close(scripts: &Path, state_dir: &Path, request: &Path) -> Closed {
    let dir = state_dir.display().to_string();
    let file = request.display().to_string();
    let out = match host::run_tagged(
        TAG,
        ORCH_RUNTIME,
        &scripts.join(ORCH_RUNTIME),
        "close",
        &["--state-dir", &dir, "op", "--fleet", "--request", &file],
        CLOSE_VERB_BOUND,
    ) {
        Ok(out) => out,
        // A close that never started closed nothing.
        Err(e @ agent_runtime::Error::NotStarted { .. }) => {
            return Closed::Failed {
                cause: e.to_string(),
            };
        }
        Err(e) => {
            return Closed::Unanswered {
                cause: e.to_string(),
            };
        }
    };
    let stderr = String::from_utf8_lossy(&out.stderr);
    let Ok(reply) = serde_json::from_slice::<Value>(&out.stdout) else {
        let line = first_line(&stderr);
        // The verb answers 0 or 1 with its reply, and its argument parser
        // 2 before it acts; any other end without a reply, a panic's 101 or
        // a signal, may follow its act.
        return match out.status.code() {
            Some(rc @ (1 | 2)) => Closed::Failed {
                cause: format!("exit={rc} {line}").trim_end().to_owned(),
            },
            Some(_) | None => Closed::Unanswered {
                cause: format!("{} {line}", out.status).trim_end().to_owned(),
            },
        };
    };
    closed_of(&reply)
}

/// The close verb's reply by its word: a refusal by its key (the tracker's
/// quota hold the one deferral), an answer by the record it left and the
/// provider's close it observed.
fn closed_of(reply: &Value) -> Closed {
    let text = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or("").to_owned();
    if reply.get("ok") != Some(&Value::Bool(true)) {
        let refusal = reply.get("refusal");
        let key = text(refusal.and_then(|r| r.get("key")));
        let fields: Vec<(String, String)> = refusal
            .and_then(|r| r.get("fields"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|pair| {
                Some((
                    pair.get(0)?.as_str()?.to_owned(),
                    pair.get(1)?.as_str()?.to_owned(),
                ))
            })
            .collect();
        if key == "tracker-read-failed" && fields.iter().any(|(k, v)| k == "cause" && v == "quota")
        {
            return Closed::Deferred;
        }
        let mut cause = format!(
            "refused key={}",
            if key.is_empty() { "unread" } else { &key }
        );
        for (k, v) in fields {
            cause.push_str(&format!(" {k}={v}"));
        }
        return Closed::Failed { cause };
    }
    let result = reply.get("result");
    let observation = result.and_then(|r| r.get("observation"));
    let seen = |key: &str| text(observation.and_then(|o| o.get(key)));
    let host_close = seen("host_close");
    match text(result.and_then(|r| r.get("word"))).as_str() {
        // The harness ended with its sandbox kept.
        "stopped" => Closed::Closed {
            line: "kept=sandbox".to_owned(),
        },
        "closed" | "parked" => {
            let archive = seen("archive");
            let line = if host_close.starts_with("kept=") || host_close.starts_with("closed=absent")
            {
                host_close
            } else if !archive.is_empty() {
                format!("kept={archive}")
            } else {
                "kept=none".to_owned()
            };
            Closed::Closed { line }
        }
        "unconfirmed" if host_close == "refused" => Closed::Refused {
            path: Some(seen("path"))
                .filter(|p| !p.is_empty())
                .unwrap_or_else(|| "unknown".to_owned()),
        },
        "unconfirmed" if host_close == "unanswered" => Closed::Unanswered {
            cause: format!("host-close-unanswered {}", seen("cause"))
                .trim_end()
                .to_owned(),
        },
        word => Closed::Failed {
            cause: format!(
                "word={} cause={}",
                if word.is_empty() { "unread" } else { word },
                seen("cause")
            ),
        },
    }
}

/// Where the close's request is written for the verb to read: beside the
/// markers, under a name no marker carries.
fn close_request_path(watch_state_dir: &Path, item: &str) -> PathBuf {
    let marker = close_marker_path(watch_state_dir, item);
    let name = marker
        .file_name()
        .map(|n| {
            n.to_string_lossy()
                .replacen("lane-close.", "close-request.", 1)
        })
        .unwrap_or_default();
    watch_state_dir.join(format!("{name}.json"))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the close request, the watch's own file under its state directory, written for the verb to read and removed once it answered"
)]
fn write_request(path: &Path, request: &Value) -> Result<(), String> {
    std::fs::write(path, request.to_string()).map_err(|e| format!("write {}: {e}", path.display()))
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
    reason = "the close marker, the watch's own file under its state directory, created exclusively before the close verb starts so a close whose end this runtime does not see is never asked again"
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
    reason = "the close marker's removal once the close verb answered, and the close request's, the watch's own files"
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
/// launch it recorded is a close whose record the close verb wrote (or a lane
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
/// exclusively before the close verb runs; an answer that closed nothing
/// (refused, deferred, failed) removes it, since nothing irreversible
/// happened and the next pass may ask again; a close that answered `closed`
/// keeps it until the next pass reads the lane record the verb wrote
/// and finds the lane out of flight (`prune_close_markers`), so a record
/// that still reads open is the operator's lane, never a second close; so
/// does a close that gave no answer.
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
    let dir = watch_state_dir(pass.claim_store);
    let request = close_request_path(dir, item);
    let closed = match write_request(&request, &close_request(pass, lane, reason)) {
        Ok(()) => run_close(pass.scripts, pass.state_dir, &request),
        Err(cause) => Closed::Failed {
            cause: format!("request-unwritten {cause}"),
        },
    };
    if let Err(cause) = remove_marker(&request) {
        fail(
            out,
            format!(
                "state-write-failed path={} cause={cause}",
                request.display()
            ),
        );
    }
    match closed {
        // The lane record the close verb wrote confirms the close on the next
        // pass's read; the marker stands until then, and stands for a close
        // that may have happened with no answer.
        Closed::Closed { .. } | Closed::Unanswered { .. } => {}
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

/// The lines a close prints: `lane-closed` with the
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
        Closed::Unanswered { cause } => {
            fail(out, format!("lane-close-unanswered item={item} {cause}"));
        }
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

/// A record field as jq's `join` prints it: a string as is, null or
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

/// The lane's open pull request: its head, a digest of its body and its
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

/// The repositories a lane is read in: the one its record names, else the
/// fleet's own and then the connected ones, in order. A fleet repository
/// that cannot be named is the cause, never a search of the rest alone.
fn repos_of(pass: &Pass, lane: &Lane) -> Result<Vec<String>, String> {
    if let Some(repo) = lane.repo.as_deref().filter(|r| !r.is_empty()) {
        return Ok(vec![repo.to_owned()]);
    }
    let project = pass.hosted.project;
    let own = crate::repo::of(&crate::repo::resolver(project), project)
        .map_err(|unread| format!("repo-unresolved cause={unread}"))?;
    Ok(pass.hosted.reads.watched([own.as_str()]))
}

/// The open pull request on the item's branch in the first repository that
/// holds one, through `gh`: the branch is the item key in
/// lower case, the list filtered to heads the repository's owner holds
/// (`lane_own`: a fork's pull request on a guessable branch name stands for
/// nothing), the body digested by the same POSIX `cksum` the record's
/// account walls are keyed by. With
/// none open, each repository's branch head and committed date. A list or a
/// branch read that fails is the failure, never "none open".
pub fn open_pr(pass: &Pass, lane: &Lane) -> PullRead {
    let gh = super::github::handle(pass.hosted.gh);
    let branch = lane.item.to_ascii_lowercase();
    let mut branches = Branches::default();
    let repos = match repos_of(pass, lane) {
        Ok(repos) => repos,
        Err(cause) => return PullRead::Failed(cause),
    };
    for repo in repos.iter().map(String::as_str) {
        let owner = repo.split('/').next().unwrap_or(repo);
        let path = format!("repos/{repo}/pulls?head={owner}:{branch}&state=open");
        let pulls = match gh.object::<Vec<Pull>>("lane-pr", &path) {
            Ok(Some(pulls)) => pulls,
            Ok(None) => return PullRead::Failed(format!("pr-read-failed repo={repo} cause=404")),
            Err(e) => return PullRead::Failed(format!("pr-read-failed repo={repo} cause={e}")),
        };
        if let Some(pull) = pulls.into_iter().next() {
            let mut body = match pull.body {
                Nullable::Present(body) => body,
                Nullable::Absent | Nullable::Null => String::new(),
            };
            body.push('\n');
            return PullRead::Open(OpenPull {
                head: pull.head.sha,
                digest: agent_runtime::record::cksum(body.as_bytes()).to_string(),
                draft: pull.draft.present().copied(),
            });
        }
        let path = format!("repos/{repo}/branches/{branch}");
        match gh.object::<Branch>("lane-branch", &path) {
            Ok(Some(head)) => {
                // The committer's date is the branch's age; a null
                // committer is no date the stall reads.
                let Nullable::Present(committer) = &head.commit.commit.committer else {
                    return PullRead::Failed(format!(
                        "branch-read-failed repo={repo} cause={}",
                        super::github::refused(
                            "github-response-invalid",
                            &[
                                ("read", "lane-branch"),
                                ("path", &path),
                                ("field", "committer")
                            ],
                        )
                    ));
                };
                if !branches.heads.is_empty() {
                    branches.heads.push(',');
                }
                branches
                    .heads
                    .push_str(&format!("{repo}:{}", head.commit.sha));
                if let Some(date) = committer.date.present().and_then(|date| epoch_of(date))
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

/// Whether the roster reads the lane's account out of credit: its
/// `credits` object carries a
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

/// The cloud stall over every running
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

/// The lane's
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
        Closed::Refused { .. }
        | Closed::Deferred
        | Closed::Failed { .. }
        | Closed::Unanswered { .. } => false,
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

/// The lane's status file through the provider, under its root on its host.
pub fn status_file(scripts: &Path, lane: &Lane) -> Answer<String> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    fetch(
        scripts,
        host_of(lane),
        &lane.item,
        &state::status_file(Path::new(root), &lane.item).to_string_lossy(),
    )
}

/// Whether the lane's worktree stands on its host: its `.git` through
/// `cat`; a file the
/// host has not, confirmed by `touch`, is the worktree the lane's own
/// close-out removed.
pub fn worktree(scripts: &Path, lane: &Lane) -> Answer<()> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    match fetch(scripts, host_of(lane), &lane.item, &format!("{root}/.git")) {
        Answer::Live(_) => Answer::Live(()),
        Answer::Gone => Answer::Gone,
        Answer::Unreadable { cause } => Answer::Unreadable { cause },
    }
}

/// The `Step` line of a hosted lane's status file: `unread` where the
/// fetch failed, `none`
/// where the host has no file or it names no step.
pub fn step(scripts: &Path, lane: &Lane) -> String {
    match status_file(scripts, lane) {
        Answer::Live(text) => step_of(&text),
        Answer::Gone => "none".to_owned(),
        Answer::Unreadable { .. } => "unread".to_owned(),
    }
}

/// A hosted lane's `lane-long` counters: the run index and the item's
/// workflow state under the lane's root on its host, each through `cat`; a
/// state absent there is read where the checkout's own files put it
/// ([`configured_state`]); a state the lane has not written, or one that
/// could not be read, counts nothing and the read's failure is said.
pub fn counters(scripts: &Path, lane: &Lane, out: &mut Produced) -> Counters {
    let Some(root) = root_of(lane) else {
        return Counters::unread();
    };
    let host = host_of(lane);
    let runs = match fetch(
        scripts,
        host,
        &lane.item,
        &format!("{root}/tmp/validation-runs"),
    ) {
        Answer::Live(text) => validation_runs_of(&text),
        Answer::Gone | Answer::Unreadable { .. } => None,
    };
    let unread = |out: &mut Produced, cause: String| {
        fail(
            out,
            format!("lane-long-rounds-unread item={} cause={cause}", lane.item),
        );
        Counters::unread()
    };
    let state = match fetch(
        scripts,
        host,
        &lane.item,
        &format!("{root}/tmp/workflow-state-{}.json", lane.item),
    ) {
        Answer::Live(text) => text,
        Answer::Unreadable { cause } => return unread(out, cause),
        Answer::Gone => match configured_state(scripts, lane, root) {
            Ok(Answer::Live(text)) => text,
            Ok(Answer::Gone) => return Counters::unread(),
            Ok(Answer::Unreadable { cause }) | Err(cause) => return unread(out, cause),
        },
    };
    match serde_json::from_str::<Value>(&state) {
        Ok(Value::Object(doc)) => counters_of(&doc, runs).unwrap_or_else(Counters::unread),
        Ok(
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_),
        )
        | Err(_) => Counters::unread(),
    }
}

/// The item's workflow state where a hosted checkout's own files put it,
/// through the provider ([`configured_state_dir`]). `Gone` is a worktree
/// the host no longer has, or a checkout holding no state there; `Err` a
/// file the host could not read, or one this reader cannot parse.
fn configured_state(scripts: &Path, lane: &Lane, root: &str) -> Result<Answer<String>, String> {
    Ok(match configured_state_dir(scripts, lane, root)? {
        Some((dir, _)) => fetch(
            scripts,
            host_of(lane),
            &lane.item,
            &state::item_path(&dir, &lane.item).display().to_string(),
        ),
        None => Answer::Gone,
    })
}

/// The host path of the state directory a hosted checkout's settings files
/// and private env file name (`settings::state_dir_named`), relative to the
/// clone its `.git` names, as the checkout's own `workflow-state` resolves
/// it, with that clone. A `.git` the host cannot `cat` is a clone's own
/// directory, confirmed by its `HEAD`, and the clone is the root. `None` is
/// a worktree the host no longer has, whose clone [`retained_clone`] keeps.
pub(crate) fn configured_state_dir(
    scripts: &Path,
    lane: &Lane,
    root: &str,
) -> Result<Option<(PathBuf, PathBuf)>, String> {
    let host = host_of(lane);
    let clone = match fetch(scripts, host, &lane.item, &format!("{root}/.git")) {
        Answer::Live(gitfile) => match clone_of(&gitfile) {
            Some(clone) => clone,
            None => return Err(format!("gitfile-unread path={root}/.git")),
        },
        Answer::Gone => return Ok(None),
        Answer::Unreadable { cause } => {
            match fetch(scripts, host, &lane.item, &format!("{root}/.git/HEAD")) {
                Answer::Live(_) => PathBuf::from(root),
                Answer::Gone | Answer::Unreadable { .. } => return Err(cause),
            }
        }
    };
    let read = |path: &Path| -> agent_runtime::Result<Option<String>> {
        let shown = path.display().to_string();
        match fetch(scripts, host, &lane.item, &shown) {
            Answer::Live(text) => Ok(Some(text)),
            Answer::Gone => Ok(None),
            Answer::Unreadable { cause } => Err(agent_runtime::Error::refused(
                "host-file-unread",
                &[("path", &shown), ("cause", &cause)],
            )),
        }
    };
    let dir = settings::state_dir_named(Path::new(root), &read).map_err(|e| e.to_string())?;
    let dir = if dir.is_absolute() {
        dir
    } else {
        clone.join(dir)
    };
    Ok(Some((dir, clone)))
}

/// The clone a linked worktree's `.git` file names: its common directory's
/// parent.
fn clone_of(gitfile: &str) -> Option<PathBuf> {
    marker::git_dirs_of(gitfile).and_then(|(_, common)| common.parent().map(Path::to_path_buf))
}

/// What a hosted lane's work leaves on its host, the proof a merged lane is
/// done: its worktree's `.git`, then the item's live state record
/// `<clone>/tmp/workflow-state-<ITEM>.json`, each through `cat`, the clone the
/// one that `.git` names. `Gone` is the close-out done, the worktree gone or
/// the record removed; `Live` the record standing, a close-out still running
/// or a lane resumed; `Unreadable` a read that failed, the provider's cause
/// kept, or a `.git` naming no linked worktree's clone. The host's state
/// directory is read as the clone's `tmp/`, the default: a state directory
/// set elsewhere on the host is not seen from the control machine, and its
/// item reads closed out once the worktree's `.git` stands without a record
/// there.
pub fn record_left(scripts: &Path, lane: &Lane) -> Answer<()> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    let host = host_of(lane);
    let gitfile = match fetch(scripts, host, &lane.item, &format!("{root}/.git")) {
        Answer::Live(gitfile) => gitfile,
        Answer::Gone => return Answer::Gone,
        Answer::Unreadable { cause } => return Answer::Unreadable { cause },
    };
    let Some(clone) = clone_of(&gitfile) else {
        return Answer::Unreadable {
            cause: format!("gitfile-unread path={root}/.git"),
        };
    };
    let record = state::item_path(&clone.join("tmp"), &lane.item);
    match fetch(scripts, host, &lane.item, &record.display().to_string()) {
        Answer::Live(_) => Answer::Live(()),
        Answer::Gone => Answer::Gone,
        Answer::Unreadable { cause } => Answer::Unreadable { cause },
    }
}

/// [`record_left`] for a lane on this machine, read by the close verb and
/// the watch alike: its worktree (the record's `mail_root`) gone, else the
/// item's live state record under `state_dir`, the fleet's, which the
/// close-out removes. `Unreadable` carries the state record's read error.
pub fn left_locally(state_dir: &Path, lane: &Lane) -> Answer<()> {
    let root = lane.mail_root.as_deref().unwrap_or("");
    if std::fs::symlink_metadata(root).is_err() {
        return Answer::Gone;
    }
    match std::fs::metadata(state::item_path(state_dir, &lane.item)) {
        Ok(_) => Answer::Live(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Answer::Gone,
        Err(e) => Answer::Unreadable {
            cause: e.to_string(),
        },
    }
}

/// The clone [`CLONE_ROW`] keeps for `item` in the watch's baseline beside
/// the fleet state at `fleet`. `None` is a lane no pass read standing; `Err`
/// a baseline that does not read.
pub fn retained_clone(fleet: &Path, item: &str) -> Result<Option<PathBuf>, String> {
    let paths = super::Paths::of(fleet).map_err(|e| e.to_string())?;
    let baseline = super::Baseline::load(&paths.baseline).map_err(|e| e.to_string())?;
    Ok(baseline
        .get(CLONE_ROW, item)
        .map(PathBuf::from)
        .filter(|clone| clone.is_absolute()))
}

/// A hosted lane's standing handoff through the provider, read in the
/// places the local read names ([`handoff_places`]) on the lane's host: the
/// checkout's configured state directory ([`configured_state_dir`]) and the
/// lane root's `tmp`, the root's alone for a worktree the host no longer
/// has. The first standing record wins, else a place that could not be read
/// or holds no JSON object, else none. `Err` is the read that failed, as the
/// fields after `item=`. The clone the worktree's `.git` names is kept in
/// [`CLONE_ROW`] where it moved.
pub fn handoff(pass: &Pass, lane: &Lane, out: &mut Produced) -> Result<HandoffReading, String> {
    let scripts = pass.scripts;
    let Some(root) = root_of(lane) else {
        return Ok(HandoffReading::None);
    };
    let places =
        match configured_state_dir(scripts, lane, root).map_err(|c| format!("cause={c}"))? {
            Some((dir, clone)) => {
                let clone = clone.display().to_string();
                if pass.baseline.get(CLONE_ROW, &lane.item) != Some(clone.as_str()) {
                    out.changes.push(set(CLONE_ROW, &lane.item, clone));
                }
                handoff_places(&dir, &lane.item, Some(Path::new(root)))
            }
            None => vec![state::item_path(&Path::new(root).join("tmp"), &lane.item)],
        };
    let mut unread = None;
    for place in places {
        let place = place.display().to_string();
        match fetch(scripts, host_of(lane), &lane.item, &place) {
            Answer::Live(text) => match doc_of(&text) {
                Some(doc) => {
                    if let Some(record) = standing_record(&doc) {
                        return Ok(HandoffReading::Stands { record });
                    }
                }
                None => {
                    unread.get_or_insert(format!("path={place} cause=state-unreadable"));
                }
            },
            Answer::Gone => {}
            Answer::Unreadable { cause } => {
                unread.get_or_insert(format!("path={place} cause={cause}"));
            }
        }
    }
    unread.map_or(Ok(HandoffReading::None), Err)
}

/// A Pi lane's session rows through the provider: the file the lane's hook
/// writes under its root's mailbox on the host.
pub fn session_rows(scripts: &Path, lane: &Lane) -> Answer<String> {
    let Some(root) = root_of(lane) else {
        return Answer::Gone;
    };
    fetch(
        scripts,
        host_of(lane),
        &lane.item,
        &format!("{root}/tmp/lane-mail/{}/session-rows.jsonl", lane.item),
    )
}

// --- the finished close -------------------------------------------------------

/// The finished close at a lane's
/// `lane-exited`, `lane-idle` or `lane-left` line: a lane whose item the GitHub duty read
/// merged and whose work left nothing behind ([`left_locally`] on this
/// machine, [`record_left`] on its host) is
/// closed through the one close; one whose item's record stands is inside
/// its merge close-out or resumed and is left. A lane its provider's status
/// verb read exited on two passes (`lane-exited`) whose item has no merge
/// is closed with its
/// sandbox kept: the attempt ends and its record stops charging a slot,
/// the sandbox standing for a relaunch; a host whose status read fails
/// reads no exit and keeps the slot. A failed close un-reports the
/// notification row, so the next pass asks again; a deferred one keeps
/// `close-pending` for the retry; a close that ended clears it. `row` and
/// `key` are the notification row and the key it reported under.
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
    let merged = pass
        .baseline
        .get(MERGED_ROW, &lane.item)
        .is_some_and(|row| !row.is_empty());
    let reason = if merged {
        let left = if host_of(lane) == "local" {
            left_locally(pass.state_dir, lane)
        } else if caps.files == Files::Verb {
            record_left(pass.scripts, lane)
        } else {
            return;
        };
        match left {
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
        "finished"
    } else if row == "lane-exited" && caps.status == Status::Verb {
        KEEP_REASON
    } else {
        return;
    };
    let pending = format!("{row}|{key}");
    if reason == "finished" && tracker_held(pass, lane) {
        out.changes.push(set(CLOSE_PENDING_ROW, &name, pending));
        return;
    }
    let Some(closed) = close_once(pass, lane, reason, out) else {
        return;
    };
    say_closed(&lane.item, &closed, out);
    match closed {
        Closed::Failed { .. } | Closed::Unanswered { .. } => {
            out.changes.push(set(row, &name, key.to_owned()));
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
        }
        Closed::Deferred => out.changes.push(set(CLOSE_PENDING_ROW, &name, pending)),
        Closed::Closed { .. } | Closed::Refused { .. } => {
            out.changes.push(clear(CLOSE_PENDING_ROW, &name));
        }
    }
}

/// A lane, local or hosted, read neither idle nor exited: where the GitHub
/// duty read its item merged, it is asked once per screen `key` whether its
/// work left nothing behind, and closed through [`close_finished`] where it
/// did, since the screen of a lane whose work is over proves nothing. A
/// close that failed un-reports the row, so the next pass asks again.
pub fn close_left(lane: &Lane, pass: &Pass, hosts: &Hosts, key: &str, out: &mut Produced) {
    let merged = pass
        .baseline
        .get(MERGED_ROW, &lane.item)
        .is_some_and(|row| !row.is_empty());
    if !merged {
        return;
    }
    let name = lane_name(lane);
    let reported = format!("{key}|reported");
    if pass.baseline.get(LEFT_ROW, &name) == Some(reported.as_str()) {
        return;
    }
    out.changes.push(set(LEFT_ROW, &name, reported));
    close_finished(lane, pass, hosts, LEFT_ROW, key, out);
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

/// The parks stopped records still owe: each record `stopped` whose sandbox
/// stands with a `park_owed` is asked that park through the one close, each
/// pass, judged by the verb's answer alone; a result unlike the last one
/// told is told once. A sandbox kept with no park owed is never asked.
pub fn complete_parks(pass: &Pass, out: &mut Produced) {
    let owed: Vec<&Lane> = pass.fleet.lanes.iter().filter(|l| owes_park(l)).collect();
    for item in pass.baseline.identities(PARK_OWED_ROW) {
        if !owed.iter().any(|l| l.item == item) {
            out.changes.push(clear(PARK_OWED_ROW, &item));
        }
    }
    for lane in owed {
        let Some(closed) = close_once(pass, lane, PARK_REASON, out) else {
            continue;
        };
        let result = park_result(&lane.item, &closed);
        if pass.baseline.get(PARK_OWED_ROW, &lane.item) != Some(result.as_str()) {
            out.events.push(Event::ParkOwed {
                item: lane.item.clone(),
                result: result.clone(),
            });
            out.changes.push(set(PARK_OWED_ROW, &lane.item, result));
        }
    }
}

fn owes_park(lane: &Lane) -> bool {
    lane.status == LaneStatus::Stopped
        && lane.extra.get(state::SANDBOX).and_then(Value::as_str) == Some(state::STANDING)
        && lane
            .extra
            .get(state::PARK_OWED)
            .is_some_and(Value::is_object)
}

/// What a park's answer tells: `parked`, the refusal's key and fields
/// without the item, or the cause of an answer that parked nothing.
fn park_result(item: &str, closed: &Closed) -> String {
    match closed {
        Closed::Closed { .. } => "parked".to_owned(),
        Closed::Failed { cause } => match cause.strip_prefix("refused key=") {
            Some(refusal) => refusal.replacen(&format!(" item={item}"), "", 1),
            None => cause.clone(),
        },
        Closed::Unanswered { cause } => format!("unanswered {cause}"),
        Closed::Refused { path } => format!("refused path={path}"),
        Closed::Deferred => "deferred".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A provider call read by the runner's three values: a provider that
    /// is not there made nothing (`host-create-failed`); one whose bound
    /// passed, or that a signal ended, may hold the item
    /// (`host-create-unanswered`): a create or wait past its bound read as
    /// failed would settle the launch while the provider holds the item.
    #[test]
    fn a_provider_call_that_never_started_fails_and_one_with_no_answer_is_unknown() {
        let dir = tempfile::tempdir().unwrap();
        let ask = |name: &str, body: Option<&str>, bound: Duration| {
            let path = dir.path().join(name);
            if let Some(body) = body {
                crate::write_executable(&path, format!("#!/bin/sh\n{body}\n"));
            }
            call(
                dir.path(),
                path.to_str().unwrap(),
                "capabilities",
                &["capabilities"],
                bound,
                "host-create",
            )
        };
        assert!(matches!(
            ask("absent", None, Duration::from_secs(10)),
            Err(Asked::Failed(cause)) if cause.starts_with("host-create-failed cause=host-unavailable")
        ));
        assert!(matches!(
            ask("slow", Some("exec sleep 5"), Duration::from_millis(300)),
            Err(Asked::Unknown(cause)) if cause.starts_with("host-create-unanswered cause=")
        ));
        assert!(matches!(
            ask("killed", Some("kill -KILL $$"), Duration::from_secs(10)),
            Err(Asked::Unknown(cause)) if cause.starts_with("host-create-unanswered capabilities exit=-1")
        ));
        assert!(ask("answers", Some("exit 0"), Duration::from_secs(10)).is_ok());
    }

    /// The capability line read whole: every key once, each value in its
    /// set; a line short of any key (`pane` among them), with a key outside
    /// the sets, a key twice, a value outside its key's set or a second
    /// line is refused by the key it fails on.
    #[test]
    fn the_capability_line_is_read_whole() {
        const SSH: &str = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local";
        assert_eq!(
            Capabilities::parse(&format!("{SSH}\n")),
            Ok(Capabilities {
                files: Files::Verb,
                status: Status::Verb,
                pane: PaneKind::Local,
                launch: Some(Launch::Ssh),
                stop: Some(StopKind::Verb),
                pool: CreditPool::Plan,
            })
        );
        let refused = |line: String| Capabilities::parse(&line).unwrap_err();
        for (line, key) in [
            (
                SSH.replace("\tpane=local", ""),
                "capability-invalid key=pane value=",
            ),
            (
                SSH.replace("pool=plan", "pool=free"),
                "capability-invalid key=pool value=free",
            ),
            (
                format!("{SSH}\tcolour=red"),
                "capability-invalid key=colour value=red",
            ),
            (
                format!("{SSH}\tkind=ssh"),
                "capability-invalid key=kind value=ssh",
            ),
            (
                format!("{SSH}\nkind=ssh"),
                "capability-invalid key=line value=lines",
            ),
            (String::new(), "capability-invalid key= value="),
        ] {
            assert_eq!(refused(line.clone()), key, "{line:?}");
        }
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
