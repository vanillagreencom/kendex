//! The tracker read duty: each tracker inventory read once per pass, in
//! complete bounded batches through the linear package's CLI via the one
//! runner, decoded at the boundary into typed records, with a refusal that
//! is never an empty set: a failed call, a chain the CLI left open at its
//! page cap or a malformed member refuses the inventory with its cause,
//! which the runner prints as `watch-step-failed step=tracker` and the
//! duty's next run repeats; nothing of that pass moves.
//!
//! One body runs the reads in order: the tracker's own (the team's
//! statuses, its open items once, the lane items' terminal states, the
//! owner's tracker answers, the due tracker asks and the closed asks'
//! tracker marks through the mailbox, the comments the triage key needs),
//! the GitHub-tracked lane items' ends
//! (the tracker of those items is GitHub), then the closes the terminal
//! verdicts call for, last so a refused read never discards a close's
//! line. The GitHub inventories are the GitHub duty's (`github`): its
//! refusal discards nothing here. The tracker's own quota refusal
//! (`RATELIMITED`, the linear package's receipt) is the one limit event:
//! held as a typed record in the baseline, it stops the tracker reads until
//! its reset and nothing else; the GitHub duty and the mail thread go on.
//!
//! Baselines: the triage row keys an item on its state and its newest
//! comment time; an item whose key is unchanged since the line that raised
//! it prints nothing, and a moved key raises it once more. An owner ask's
//! marks row keeps each tracker mark landed or its standing cause, so a
//! failed mark is said once per cause and tried again.
//!
//! The results the heartbeat and verification duties read (the owed
//! items, the Verifying items, the open unblocked items no lane holds) are
//! handed over through `Shared`, written once per pass; those duties make
//! no second read.

use agent_runtime::intent::Owner;
use agent_runtime::record::Locking;
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::mailbox::{Envelope, Mailbox, Replied, Resolved};
use crate::ops::{self, CloseOwnedResources, Delivery, Request, Terminal};
use crate::settings::Settings;
use crate::state::{self, CycleRow, FleetState, Lane, LaneStatus, TerminalVerdict};
use crate::verify::wire::Nullable;
use crate::watch::events::OwnerMark;
use crate::watch::{Body, Change, Event, Produced, Tick};
use agent_runtime::journal::Env;

use super::github;

pub mod reconcile_items;

/// The bound on one tracker call: a `--max` read walks every page inside
/// the CLI, so the bound covers a chain, not a page.
const TRACKER_TIMEOUT: Duration = Duration::from_secs(300);

/// The start-counter tag every tracker call is counted under.
const TAG: &str = "tracker";

/// Baseline row kinds this duty owns.
pub const QUOTA_ROW: &str = "tracker-quota";
pub const TRIAGE_ROW: &str = "triage";
pub const TERMINAL_CLOSE_ROW: &str = "terminal-close";
/// An owner ask's tracker marks, keyed by the ask's id; its `fleet` row is
/// the floor the first mailbox read set.
pub const OWNER_MARK_ROW: &str = "owner-ask-mark";

/// A refused close's `terminal-close` value as its key and its cause:
/// `<state word>|<session_since>|<cause>`. The row's other form,
/// `held|<cause>`, is told apart by its first field, which no state word is.
pub(crate) fn refused_close(value: &str) -> Option<(&str, &str)> {
    let first = value.find('|')?;
    let second = first + 1 + value[first + 1..].find('|')?;
    Some((&value[..second], &value[second + 1..]))
}

/// The row identity the quota receipt is held under.
const FLEET: &str = "fleet";

// --- the shared slot -------------------------------------------------------

/// What a tracker pass hands the heartbeat and verification duties.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct TrackerInventory {
    /// The epoch second of the pass that read it.
    pub read_at: u64,
    /// The work the fleet owes, one row per item, sorted by id.
    pub owed: Vec<OwedItem>,
    /// The Verifying items and the containers whose children all ended.
    pub verifying: Vec<VerifyingItem>,
    /// The team's open items with no open blocker that no lane holds and
    /// the launch queue does not name, sorted.
    pub open_unblocked: Vec<String>,
}

/// The latest results of the read duties; `None` until the first
/// successful read of each. The tracker duty writes `tracker`, `quota`
/// and `terminal`, the GitHub duty `github`: one `Arc<Mutex>` both bodies
/// hold, each writing its own members.
#[derive(Debug, Default)]
pub struct Latest {
    pub tracker: Option<TrackerInventory>,
    pub quota: Option<Quota>,
    /// The terminal state of every parked or stopped lane item the last
    /// tracker pass answered for, which the GitHub duty's parked-merged
    /// hand consults; an item not here has no verdict yet.
    pub terminal: BTreeMap<String, TerminalState>,
    pub github: Option<github::Inventory>,
}

pub type Shared = Arc<Mutex<Latest>>;

/// The owed states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum OwedState {
    InProgress,
    InReview,
    Verifying,
}

impl OwedState {
    fn of_name(name: &str) -> Option<OwedState> {
        match name {
            "In Progress" => Some(OwedState::InProgress),
            "In Review" => Some(OwedState::InReview),
            "Verifying" => Some(OwedState::Verifying),
            _ => None,
        }
    }

    pub fn word(self) -> &'static str {
        match self {
            OwedState::InProgress => "in-progress",
            OwedState::InReview => "in-review",
            OwedState::Verifying => "verifying",
        }
    }
}

/// One owed item with what its `owed` line carries before the wall
/// verdict: the account judge is the heartbeat's.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OwedItem {
    pub id: String,
    pub state: OwedState,
    /// The tracker's priority, `-` for none or Linear's 0.
    pub priority: String,
    /// The last lane record's status word, `none` with no record.
    pub lane: String,
    pub host: String,
    pub harness: String,
    pub model: String,
    /// `pr=N` or `commit=SHA` from the record's cycle; `None` with none.
    pub delivery: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VerifyingItem {
    pub id: String,
    pub created_at: String,
    pub description: String,
    pub priority: String,
    pub container: bool,
    /// The open items blocking this one, which the box judge
    /// (`watch::verifying`) reads as `blocked` and its line carries.
    pub blocked_by_open: Vec<String>,
}

// --- the quota receipt -----------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaStatus {
    Future,
    Elapsed,
    Missing,
    Invalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaLimit {
    Requests,
    Complexity,
    Endpoint,
    Unknown,
}

/// The linear package's quota receipt, `{"code":"RATELIMITED","quota":…}`
/// on a refused call's stderr, held to one shape: a `future` or `elapsed`
/// status carries the reset epoch and its ISO rendering, the others
/// `unavailable` and no epoch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Quota {
    pub limit: QuotaLimit,
    pub status: QuotaStatus,
    pub reset: String,
    pub reset_epoch: Option<u64>,
}

impl Quota {
    fn well_formed(&self) -> bool {
        match self.status {
            QuotaStatus::Future | QuotaStatus::Elapsed => self
                .reset_epoch
                .is_some_and(|epoch| self.reset == clock::iso_utc(epoch)),
            QuotaStatus::Missing | QuotaStatus::Invalid => {
                self.reset_epoch.is_none() && self.reset == "unavailable"
            }
        }
    }

    /// The receipt on a refused call's stderr: the last JSON object line
    /// with the code and a well-formed quota, none otherwise.
    pub fn of_stderr(text: &str) -> Option<Quota> {
        text.lines()
            .rev()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|v| v.get("code").and_then(|c| c.as_str()) == Some("RATELIMITED"))
            .filter_map(|v| serde_json::from_value::<Quota>(v.get("quota")?.clone()).ok())
            .find(Quota::well_formed)
    }

    /// The two resets the last quota receipt on `text` names, the requests
    /// window's (`requests_reset`) and the hold's (`quota.reset`), each
    /// `unavailable` where the line names none; `None` where no line is a
    /// receipt.
    pub fn receipt_resets(text: &str) -> Option<(String, String)> {
        let line = text
            .lines()
            .rev()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .find(|v| v.get("code").and_then(|c| c.as_str()) == Some("RATELIMITED"))?;
        let word = |v: Option<&serde_json::Value>| {
            v.and_then(|v| v.as_str())
                .unwrap_or("unavailable")
                .to_owned()
        };
        Some((
            word(line.get("requests_reset")),
            word(line.pointer("/quota/reset")),
        ))
    }

    /// Whether the receipt still holds tracker reads at `now`.
    pub fn holds(&self, now: u64) -> bool {
        self.status == QuotaStatus::Future && self.reset_epoch.is_some_and(|epoch| now < epoch)
    }

    /// The `tracker-quota` line's body: a future reset already reached at
    /// `now` reads `elapsed`.
    pub fn line(&self, now: u64) -> String {
        let status = match self.status {
            QuotaStatus::Future if self.reset_epoch.is_some_and(|epoch| epoch <= now) => "elapsed",
            QuotaStatus::Future => "future",
            QuotaStatus::Elapsed => "elapsed",
            QuotaStatus::Missing => "missing",
            QuotaStatus::Invalid => "invalid",
        };
        let limit = match self.limit {
            QuotaLimit::Requests => "requests",
            QuotaLimit::Complexity => "complexity",
            QuotaLimit::Endpoint => "endpoint",
            QuotaLimit::Unknown => "unknown",
        };
        format!(
            "tracker-quota status={status} reset={} limit={limit}",
            self.reset
        )
    }

    /// The row value, the receipt's JSON.
    fn row_value(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

// --- the transport ----------------------------------------------------------

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// What one tracker read answered: the typed value, or the quota receipt
/// that refused it.
pub(super) enum Answered<T> {
    Value(T),
    Quota(Quota),
}

macro_rules! quota {
    ($answered:expr) => {
        match $answered {
            Answered::Value(value) => value,
            Answered::Quota(quota) => return Ok(Answered::Quota(quota)),
        }
    };
}

/// The linear package's CLI through agent-runtime's one runner, every call
/// counted under the duty's tag.
pub(super) struct Linear<'a> {
    cli: &'a Path,
}

impl Linear<'_> {
    /// One call, its stdout as printed. A call that could not run or
    /// exited nonzero without a quota receipt refuses
    /// `tracker-list-failed`; a quota receipt is the answer.
    #[allow(
        clippy::disallowed_methods,
        reason = "the tracker duty reads the tracker through the linear CLI for its inventories and repairs an owner ask's description through it, no effect on a lane or a controller"
    )]
    fn call(&self, read: &'static str, args: &[&str]) -> Result<Answered<Vec<u8>>> {
        let output = host::run_tagged(TAG, "linear", self.cli, read, args, TRACKER_TIMEOUT)
            .map_err(|e| {
                refused(
                    "tracker-list-failed",
                    &[("read", read), ("cause", &e.to_string())],
                )
            })?;
        if !output.status.success() {
            let stderr = host::stderr_text(&output);
            if let Some(quota) = Quota::of_stderr(&stderr) {
                return Ok(Answered::Quota(quota));
            }
            let detail = stderr
                .lines()
                .find(|l| !l.trim().is_empty())
                .map(str::trim)
                .unwrap_or("")
                .to_owned();
            return Err(refused(
                "tracker-list-failed",
                &[
                    ("read", read),
                    ("exit", &output.status.to_string()),
                    ("cause", &detail),
                ],
            ));
        }
        Ok(Answered::Value(output.stdout))
    }

    /// One call, its stdout decoded as `T`; an answer `T` cannot decode
    /// refuses `tracker-list-invalid`.
    fn json<T: DeserializeOwned>(&self, read: &'static str, args: &[&str]) -> Result<Answered<T>> {
        let bytes = quota!(self.call(read, args)?);
        serde_json::from_slice::<T>(&bytes)
            .map(Answered::Value)
            .map_err(|e| {
                refused(
                    "tracker-list-invalid",
                    &[("read", read), ("cause", &e.to_string())],
                )
            })
    }
}

// --- the wire shapes ---------------------------------------------------------

/// `statuses list --format=safe`: `[{name, type}]`.
#[derive(Debug, Deserialize)]
struct StatusRow {
    name: String,
    #[serde(rename = "type")]
    kind: String,
}

/// `issues list --select owed --format=safe` (`commands/issues.sh`'s `owed`
/// selection).
#[derive(Debug, Clone, Deserialize)]
struct OpenItem {
    id: String,
    description: Nullable<String>,
    in_pr_bundle: bool,
    priority: Nullable<u64>,
    state: String,
    state_type: String,
    parent_id: String,
    created_at: String,
    blocked_by_open: Vec<String>,
}

/// `issues bulk-get --format=raw`: the public result, one node per asked
/// identifier with its state type, description and children.
#[derive(Debug, Deserialize)]
struct BulkReply {
    issues: BulkNodes,
}

#[derive(Debug, Deserialize)]
struct BulkNodes {
    nodes: Vec<BulkNode>,
}

#[derive(Debug, Deserialize)]
struct BulkNode {
    identifier: String,
    #[serde(default)]
    description: Nullable<String>,
    state: StateType,
    #[serde(default)]
    children: Nullable<ChildNodes>,
}

#[derive(Debug, Deserialize)]
struct StateType {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Debug, Deserialize)]
struct ChildNodes {
    nodes: Vec<ChildNode>,
}

#[derive(Debug, Deserialize)]
struct ChildNode {
    identifier: String,
    state: StateType,
}

/// `comments bulk-list --format=safe`: `{ID: [comment_safe]}`
/// (`lib/formatters.sh`'s `COMMENT_SAFE_JQ`).
#[derive(Debug, Clone, Deserialize)]
struct CommentRow {
    id: String,
    body: String,
    user_email: String,
    created_at: String,
}

/// `issues list --assignee … --label … --format=safe`: the fields the
/// owner-tracker read uses (`lib/formatters.sh`'s `format_issues_list`).
#[derive(Debug, Clone, Deserialize)]
struct OwnerItem {
    id: String,
    #[serde(default)]
    assignee: String,
    #[serde(default)]
    description: Nullable<String>,
}

/// The repaired item read back: whether its description carries the repair.
const OWNER_ITEM: &str =
    "query OwnerItem($id: String!) { issue(id: $id) { identifier description } }";

#[derive(Debug, Deserialize)]
struct OwnerReadBack {
    issue: OwnerReadBackIssue,
}

#[derive(Debug, Deserialize)]
struct OwnerReadBackIssue {
    identifier: String,
    description: Option<String>,
}

/// `done-when parse`: the boxes of a description's Done-when section.
#[derive(Debug, Deserialize)]
struct DoneWhen {
    boxes: Vec<DoneWhenBox>,
}

#[derive(Debug, Deserialize)]
struct DoneWhenBox {
    checked: bool,
}

fn is_word(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The epoch second of a tracker stamp, its fractional seconds before a
/// closing `Z` dropped.
pub(super) fn stamp_epoch(stamp: &str) -> Option<u64> {
    let whole = match stamp.find('.') {
        Some(dot) if stamp.ends_with('Z') => format!("{}Z", &stamp[..dot]),
        Some(_) | None => stamp.to_owned(),
    };
    clock::epoch_secs(&whole)
}

fn invalid(read: &'static str, field: &str, value: &str) -> Error {
    refused(
        "tracker-list-invalid",
        &[("read", read), ("field", field), ("value", value)],
    )
}

fn tracker_of(lane: &Lane) -> &str {
    match lane.tracker.as_deref() {
        Some(tracker) => tracker,
        None if lane.item.starts_with("issue-") => "",
        None => "linear",
    }
}

/// What the tracker says of a lane's item (`close-lane`'s `terminal-state`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalState {
    Completed,
    Canceled,
    Open,
}

/// One lane's item judged for the close (`close-lane`): its retained pull
/// request waits first where `waits` (a parked record, a `pending_pr`, a
/// parked status naming none), an open one holding the item open; then its
/// tracker, `tracker` and `repo` the identity the close resolved. A linear
/// item Done with an unchecked Done-when box reads open where `boxes`. `Err`
/// is the cause word of a read that did not answer, as the tracker
/// refusal names it.
pub(crate) fn lane_verdict(
    settings: &Settings,
    lane: &Lane,
    tracker: &str,
    repo: Option<&str>,
    waits: bool,
) -> std::result::Result<TerminalState, String> {
    let gh = github::handle(Path::new("gh"));
    let mut boxes = false;
    if waits {
        let record = lane
            .extra
            .get("parked")
            .filter(|v| !v.is_null())
            .or_else(|| lane.extra.get("pending_pr").filter(|v| !v.is_null()));
        if record.is_none() && lane.status == LaneStatus::Parked {
            return Err("parked-record-invalid".to_owned());
        }
        if let Some(record) = record {
            boxes = true;
            for (wait_repo, number) in pull_waits(record)? {
                let pull = gh
                    .object::<crate::verify::wire::Pull>(
                        "terminal",
                        &format!("repos/{wait_repo}/pulls/{number}"),
                    )
                    .map_err(|_| "pr-read-failed".to_owned())?
                    .ok_or_else(|| "pr-read-failed".to_owned())?;
                match pull.state.as_str() {
                    "open" => return Ok(TerminalState::Open),
                    "closed" => {}
                    _ => return Err("pr-state-invalid".to_owned()),
                }
            }
        }
        boxes |= matches!(lane.status, LaneStatus::Parked | LaneStatus::Stopped);
    }
    match tracker {
        "linear" => {
            let linear = Linear {
                cli: &settings.reads.tracker_cli,
            };
            let reply: BulkReply = match linear.json(
                "terminal",
                &["issues", "bulk-get", &lane.item, "--format=raw"],
            ) {
                Ok(Answered::Value(reply)) => reply,
                // The quota hold is its own cause: a caller defers on it.
                Ok(Answered::Quota(_)) => return Err("quota".to_owned()),
                Err(_) => return Err("read-failed".to_owned()),
            };
            let Some(node) = reply
                .issues
                .nodes
                .into_iter()
                .find(|n| n.identifier == lane.item)
            else {
                return Err("read-failed".to_owned());
            };
            match node.state.kind.as_str() {
                "" => Err("no-state-type".to_owned()),
                kind if dropped(kind) => Ok(TerminalState::Canceled),
                "completed" if boxes => {
                    let description = match node.description {
                        Nullable::Present(d) => d,
                        Nullable::Absent | Nullable::Null => String::new(),
                    };
                    match all_boxes_checked(&linear, &description) {
                        Ok(true) => Ok(TerminalState::Completed),
                        Ok(false) => Ok(TerminalState::Open),
                        Err(_) => Err("checklist-unparsed".to_owned()),
                    }
                }
                "completed" => Ok(TerminalState::Completed),
                _ => Ok(TerminalState::Open),
            }
        }
        "github" => {
            if !lane.item.starts_with("issue-") {
                return Err("key-not-issue".to_owned());
            }
            let Some(repo) = repo.filter(|r| !r.is_empty()) else {
                return Err("repo-missing".to_owned());
            };
            let with_repo = Lane {
                repo: Some(repo.to_owned()),
                ..lane.clone()
            };
            github::terminal_of(&gh, &with_repo).map_err(|_| "read-failed".to_owned())
        }
        "" if lane.item.starts_with("issue-") => Err("key-ambiguous".to_owned()),
        _ => Err("tracker-unknown".to_owned()),
    }
}

/// The pull requests a retained wait names, `(repo, number)` each once: the
/// lane's own and a dependency, the dependency in its own repository where
/// the record names one; a park on the lane's own ask names none. A record
/// naming neither, or a number or repository of the wrong shape, is
/// `parked-record-invalid`.
fn pull_waits(record: &serde_json::Value) -> std::result::Result<Vec<(String, u64)>, String> {
    let invalid = || "parked-record-invalid".to_owned();
    let repo = record
        .get("repo")
        .and_then(serde_json::Value::as_str)
        .filter(|r| !r.is_empty())
        .ok_or_else(invalid)?;
    let until_repo = match record.get("until_repo") {
        None | Some(serde_json::Value::Null) => repo,
        Some(v) => v.as_str().filter(|r| !r.is_empty()).ok_or_else(invalid)?,
    };
    let mut waits = Vec::new();
    for (wait_repo, key) in [(repo, "pr"), (until_repo, "until_pr")] {
        match record.get(key) {
            None | Some(serde_json::Value::Null) => {}
            Some(v) => {
                let number = v.as_u64().filter(|n| *n > 0).ok_or_else(invalid)?;
                let wait = (wait_repo.to_owned(), number);
                if !waits.contains(&wait) {
                    waits.push(wait);
                }
            }
        }
    }
    let asked = record
        .get("ask")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|ask| !ask.is_empty());
    if waits.is_empty() && !asked {
        return Err(invalid());
    }
    Ok(waits)
}

/// Whether a tracker state type ends the item's work unshipped: Linear's
/// `canceled` and `duplicate` (an item marked Duplicate is done as another).
pub(crate) fn dropped(state_type: &str) -> bool {
    matches!(state_type, "canceled" | "duplicate")
}

/// Whether a tracker state type ends the item's work, shipped or not.
pub(crate) fn finished(state_type: &str) -> bool {
    state_type == "completed" || dropped(state_type)
}

impl TerminalState {
    pub(crate) fn verdict(self) -> Option<TerminalVerdict> {
        match self {
            TerminalState::Completed => Some(TerminalVerdict::Completed),
            TerminalState::Canceled => Some(TerminalVerdict::Canceled),
            TerminalState::Open => None,
        }
    }

    pub(crate) fn word(self) -> &'static str {
        match self {
            TerminalState::Completed => "completed",
            TerminalState::Canceled => "canceled",
            TerminalState::Open => "open",
        }
    }
}

// --- the duty ------------------------------------------------------------------

/// What the duty runs with, fixed at registration.
pub struct Context {
    /// The fleet state file.
    pub fleet: PathBuf,
    pub settings: Settings,
    /// The discovery floor the run was started with (`--since`), as an
    /// epoch second; none disables triage.
    pub since: Option<u64>,
    /// The `gh` program the GitHub-tracked items' ends are read through;
    /// `gh` on `PATH` in production.
    pub gh: PathBuf,
    /// The watch's `--repo` names, the GitHub duty's own, which a terminal
    /// close's merge read covers beside the lane's repository.
    pub repos: Vec<String>,
    pub locking: Locking,
    pub nonce: u32,
    pub owner: Option<Owner>,
    pub shared: Shared,
}

/// The duty's body; the count of passes in a row whose due-ask close was
/// refused is this run's, as the mail duty counts its refused turns.
pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

/// Register the duty on `runner` for the fleet at `path`: `--since` is one
/// UTC stamp (`since-invalid` otherwise), read here as the discovery floor;
/// `gh` is found on `PATH`. The slot the heartbeat, verification and GitHub
/// duties read is returned.
pub fn register(
    runner: &mut crate::watch::Runner<'_>,
    path: &Path,
    settings: &Settings,
    env: &Env,
    locking: Locking,
    since: Option<String>,
    repos: Vec<String>,
) -> Result<Shared> {
    let since_epoch = match since.as_deref() {
        None => None,
        Some(stamp) => Some(
            clock::epoch_secs(stamp)
                .ok_or_else(|| refused("since-invalid", &[("value", stamp)]))?,
        ),
    };
    let shared = Shared::default();
    runner.register(
        crate::schedule::Duty::Tracker,
        body(Context {
            fleet: path.to_path_buf(),
            settings: settings.clone(),
            since: since_epoch,
            gh: PathBuf::from("gh"),
            repos,
            locking,
            nonce: env.nonce,
            owner: env.owner.clone(),
            shared: shared.clone(),
        }),
    );
    Ok(shared)
}

/// The fleet record, read once per pass.
#[allow(
    clippy::disallowed_methods,
    reason = "the tracker duty's one read of the fleet record per pass, which it judges and never writes"
)]
fn load_fleet(path: &Path) -> Result<FleetState> {
    state::load(path)?
        .ok_or_else(|| {
            Error::Runtime(agent_runtime::Error::RecordMissing {
                path: path.to_path_buf(),
            })
        })?
        .view::<FleetState>(path)
}

/// What the tracker reads settle in one pass.
struct TrackerRead {
    inventory: TrackerInventory,
    /// The triage rows as they should stand after this pass, keyed by id.
    triage: BTreeMap<String, String>,
    /// The tracker's terminal state of each linear-tracked lane item.
    terminal: BTreeMap<String, TerminalState>,
}

fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let fleet = load_fleet(&ctx.fleet)?;
    let mut produced = Produced::default();
    let linear = Linear {
        cli: &ctx.settings.reads.tracker_cli,
    };
    // The standing receipt: an elapsed one is cleared, a future one holds.
    let mut held = match tick.baseline.get(QUOTA_ROW, FLEET) {
        None => None,
        Some(value) => {
            let quota: Quota = serde_json::from_str(value)
                .ok()
                .filter(Quota::well_formed)
                .ok_or_else(|| invalid("quota-row", "value", value))?;
            if quota.holds(tick.wall) {
                Some(quota)
            } else {
                produced.changes.push(Change::Clear {
                    kind: QUOTA_ROW.to_owned(),
                    identity: FLEET.to_owned(),
                });
                None
            }
        }
    };
    let mut tracker = None;
    let mut owner = OwnerPass::default();
    if let (Some(team), None) = (&ctx.settings.linear_team, &held) {
        match read_tracker(&linear, team, &fleet, ctx, tick, &mut owner)? {
            Answered::Value(read) => tracker = Some(read),
            Answered::Quota(quota) => {
                // The one limit event: printed when the receipt is taken,
                // held as the row until its reset.
                produced.events.push(Event::TrackerQuota {
                    line: quota.line(tick.wall),
                });
                produced.changes.push(Change::Set {
                    kind: QUOTA_ROW.to_owned(),
                    identity: FLEET.to_owned(),
                    value: quota.row_value(),
                });
                held = Some(quota);
            }
        }
    }
    produced.events.append(&mut owner.events);
    produced.changes.append(&mut owner.changes);
    let mut terminal: BTreeMap<String, TerminalState> = BTreeMap::new();
    if let Some(read) = &tracker {
        terminal.extend(read.terminal.iter().map(|(k, v)| (k.clone(), *v)));
        // The triage rows: a line for a new or moved key, the row set; a
        // row for an item no longer a candidate cleared.
        for (id, key) in &read.triage {
            if tick.baseline.get(TRIAGE_ROW, id) != Some(key.as_str()) {
                produced.events.push(Event::Triage { id: id.clone() });
                produced.changes.push(Change::Set {
                    kind: TRIAGE_ROW.to_owned(),
                    identity: id.clone(),
                    value: key.clone(),
                });
            }
        }
        for id in tick.baseline.identities(TRIAGE_ROW) {
            if !read.triage.contains_key(&id) {
                produced.changes.push(Change::Clear {
                    kind: TRIAGE_ROW.to_owned(),
                    identity: id,
                });
            }
        }
    }
    // The GitHub-tracked lane items' ends: their tracker is GitHub. A
    // refused read leaves its item with no verdict, so no close, and is
    // the pass's partial failure, a per-item `lane-close-failed`; the
    // tracker's lines, rows and other closes stand.
    let gh = github::handle(&ctx.gh);
    let mut failed = Vec::new();
    for (item, read) in github::terminal_github(&gh, &fleet.lanes) {
        match read {
            Ok(state) => {
                terminal.insert(item, state);
            }
            Err(cause) => failed.push(format!("lane-close-failed item={item} cause={cause}")),
        }
    }
    // The closes, last: every parked or stopped lane whose item the tracker
    // shows ended, with no refused close recorded under the same key.
    let closes = close_terminal_lanes(ctx, tick, &fleet, &terminal)?;
    produced.events.extend(closes.events);
    produced.changes.extend(closes.changes);
    // A refused terminal read, due-ask close or owner-ask mailbox read is
    // the pass's partial failure, counted and said by the runner under its
    // one rule, as the mail duty's refused turn is; the pass's own lines
    // stand.
    failed.append(&mut owner.failed);
    produced.failed = (!failed.is_empty()).then(|| failed.join("\n"));
    {
        let mut latest = ctx.shared.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(read) = tracker {
            latest.tracker = Some(read.inventory);
            latest.terminal = terminal;
        }
        latest.quota = held;
    }
    Ok(produced)
}

fn completed_containers<'a>(
    candidates: impl Iterator<Item = (&'a str, &'a str, bool)>,
    children: impl Iterator<Item = (&'a str, &'a str)>,
) -> BTreeSet<String> {
    let mut by_parent: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (parent, kind) in children {
        if !parent.is_empty() {
            by_parent.entry(parent).or_default().push(kind);
        }
    }
    candidates
        .filter(|(_, kind, bundle)| !bundle && !finished(kind))
        .filter(|(id, _, _)| {
            by_parent
                .get(id)
                .is_some_and(|kinds| kinds.iter().all(|kind| finished(kind)))
        })
        .map(|(id, _, _)| id.to_owned())
        .collect()
}

/// The Verifying list of a process that runs no tracker duty: the duty's
/// own list read for `team` over the fleet record at `fleet`.
pub(super) fn verifying_read(
    settings: &Settings,
    team: &str,
    fleet: &Path,
    now: u64,
) -> Result<Answered<TrackerInventory>> {
    let fleet = load_fleet(fleet)?;
    let linear = Linear {
        cli: &settings.reads.tracker_cli,
    };
    let (_, inventory) = quota!(read_list(&linear, team, &fleet, now)?);
    Ok(Answered::Value(inventory))
}

/// The tracker's own reads, in order, each once: the team's open items
/// (`read_list`), the lane items' terminal states, the owner's tracker
/// answers, the due tracker asks and the closed asks' marks, and the
/// newest comment of each triage candidate.
fn read_tracker(
    linear: &Linear,
    team: &str,
    fleet: &FleetState,
    ctx: &Context,
    tick: &Tick,
    owner: &mut OwnerPass,
) -> Result<Answered<TrackerRead>> {
    let (items, inventory) = quota!(read_list(linear, team, fleet, tick.wall)?);
    // The lane items' terminal states, one batch (`close-lane`'s
    // `terminal-state`), for every parked or stopped linear-tracked lane.
    let lane_items: Vec<&str> = fleet
        .lanes
        .iter()
        .filter(|l| matches!(l.status, LaneStatus::Parked | LaneStatus::Stopped))
        .filter(|l| tracker_of(l) == "linear")
        .map(|l| l.item.as_str())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut terminal = BTreeMap::new();
    if !lane_items.is_empty() {
        let mut args = vec!["issues", "bulk-get"];
        args.extend(lane_items.iter().copied());
        args.push("--format=raw");
        let reply: BulkReply = quota!(linear.json("terminal", &args)?);
        let mut nodes: BTreeMap<String, BulkNode> = reply
            .issues
            .nodes
            .into_iter()
            .map(|n| (n.identifier.clone(), n))
            .collect();
        for item in &lane_items {
            let Some(node) = nodes.remove(*item) else {
                return Err(refused("tracker-item-unread", &[("item", item)]));
            };
            let state = match node.state.kind.as_str() {
                kind if dropped(kind) => TerminalState::Canceled,
                "completed" => {
                    // Done at merge before the lane's close-out ticked its
                    // boxes is not ended: an open box keeps it open.
                    let description = match node.description {
                        Nullable::Present(d) => d,
                        Nullable::Absent | Nullable::Null => String::new(),
                    };
                    if all_boxes_checked(linear, &description)? {
                        TerminalState::Completed
                    } else {
                        TerminalState::Open
                    }
                }
                "" => return Err(invalid("terminal", "state_type", item)),
                _ => TerminalState::Open,
            };
            terminal.insert((*item).to_owned(), state);
        }
    }
    // The owner's tracker answers, then the due tracker asks once the
    // tracker was read: an unread tracker
    // cannot establish that the person left a recommendation unanswered.
    let reach = crate::effects::fleet_reach(&ctx.settings)?;
    let mailbox = Mailbox::new(reach.mail_program);
    let owner_read = quota!(read_owner_tracker_answers(
        linear,
        ctx,
        &mailbox,
        &reach.mail_root,
        tick,
        owner
    )?);
    if owner_read == OwnerRead::Read {
        owner
            .failed
            .extend(resolve_due_tracker_asks(&mailbox, &reach.mail_root));
    }
    if let Some(configured) = &ctx.settings.reads.owner_tracker {
        quota!(mark_closed_owner_asks(
            linear,
            &mailbox,
            &reach.mail_root,
            &configured.label,
            tick,
            owner
        )?);
    }
    // The triage candidates: open items created at or after the floor
    // whose verdict is not kept or canceled, keyed on state and newest
    // comment.
    let mut triage = BTreeMap::new();
    if let Some(since) = ctx.since {
        let acknowledged = fleet.acknowledged_issues();
        let candidates: Vec<&OpenItem> = items
            .iter()
            .filter(|i| stamp_epoch(&i.created_at).is_some_and(|at| at >= since))
            .filter(|i| !acknowledged.contains(&i.id))
            .collect();
        if !candidates.is_empty() {
            let mut args = vec!["comments", "bulk-list"];
            args.extend(candidates.iter().map(|i| i.id.as_str()));
            args.push("--format=safe");
            let comments: BTreeMap<String, Vec<CommentRow>> =
                quota!(linear.json("comments", &args)?);
            for item in candidates {
                let Some(rows) = comments.get(&item.id) else {
                    return Err(invalid("comments", "issue", &item.id));
                };
                let newest = rows
                    .iter()
                    .map(|r| r.created_at.as_str())
                    .max()
                    .unwrap_or("-");
                triage.insert(item.id.clone(), format!("{}|{newest}", item.state));
            }
        }
    }
    Ok(Answered::Value(TrackerRead {
        inventory,
        triage,
        terminal,
    }))
}

/// The team's open items and the inventory they make, read at `read_at`:
/// the team's statuses, its items in every open state, and the children of
/// the container candidates.
fn read_list(
    linear: &Linear,
    team: &str,
    fleet: &FleetState,
    read_at: u64,
) -> Result<Answered<(Vec<OpenItem>, TrackerInventory)>> {
    let statuses: Vec<StatusRow> = quota!(linear.json(
        "statuses",
        &["statuses", "list", "--team", team, "--format=safe"]
    )?);
    if statuses.is_empty() {
        return Err(invalid("statuses", "statuses", "[]"));
    }
    let open_states: Vec<&str> = statuses
        .iter()
        .filter(|s| !finished(&s.kind))
        .map(|s| s.name.as_str())
        .collect();
    let mut items: Vec<OpenItem> = Vec::new();
    if !open_states.is_empty() {
        let states = open_states.join(",");
        items = quota!(linear.json(
            "issues",
            &[
                "issues",
                "list",
                "--team",
                team,
                "--state",
                &states,
                "--select",
                "owed",
                "--max",
                "--format=safe",
            ]
        )?);
    }
    for item in &items {
        if !is_word(&item.id) {
            return Err(invalid("issues", "id", &item.id));
        }
        if stamp_epoch(&item.created_at).is_none() {
            return Err(invalid("issues", "created_at", &item.created_at));
        }
        if item.state_type.is_empty() {
            return Err(invalid("issues", "state_type", &item.state_type));
        }
    }
    let candidates: Vec<&str> = items
        .iter()
        .filter(|i| !i.in_pr_bundle)
        .map(|i| i.id.as_str())
        .collect();
    let mut state_types: BTreeMap<String, (String, String)> = items
        .iter()
        .map(|i| (i.id.clone(), (i.parent_id.clone(), i.state_type.clone())))
        .collect();
    if !candidates.is_empty() {
        let mut args = vec!["issues", "bulk-get"];
        args.extend(candidates.iter().copied());
        args.push("--format=raw");
        let reply: BulkReply = quota!(linear.json("children", &args)?);
        for node in reply.issues.nodes {
            if !is_word(&node.identifier) {
                return Err(invalid("children", "identifier", &node.identifier));
            }
            let children = match node.children {
                Nullable::Present(children) => children.nodes,
                Nullable::Absent | Nullable::Null => {
                    return Err(invalid("children", "children", &node.identifier));
                }
            };
            for child in children {
                if !is_word(&child.identifier) || child.state.kind.is_empty() {
                    return Err(invalid("children", "child", &child.identifier));
                }
                state_types
                    .entry(child.identifier)
                    .or_insert((node.identifier.clone(), child.state.kind));
            }
        }
    }
    let containers = completed_containers(
        items
            .iter()
            .map(|i| (i.id.as_str(), i.state_type.as_str(), i.in_pr_bundle)),
        state_types
            .values()
            .map(|(parent, kind)| (parent.as_str(), kind.as_str())),
    );
    let inventory = inventory_of(&items, &containers, fleet, read_at);
    Ok(Answered::Value((items, inventory)))
}

/// Whether every Done-when box of `description` is checked, through the
/// linear package's parser; a description with no section
/// has no open box.
fn all_boxes_checked(linear: &Linear, description: &str) -> Result<bool> {
    if !description.contains("## Done when") {
        return Ok(true);
    }
    match linear.json::<DoneWhen>(
        "done-when",
        &["done-when", "parse", "--description", description],
    )? {
        Answered::Value(parsed) => Ok(parsed.boxes.iter().all(|b| b.checked)),
        Answered::Quota(_) => Err(invalid("done-when", "quota", "unexpected")),
    }
}

fn priority_word(priority: &Nullable<u64>) -> String {
    match priority {
        Nullable::Present(n) if *n > 0 => n.to_string(),
        Nullable::Present(_) | Nullable::Absent | Nullable::Null => "-".to_owned(),
    }
}

/// The inventory the heartbeat and verification read, from the open items
/// and the fleet: the owed rows (`LANE_RUNNING_JQ`), the Verifying items
/// and containers, the open unblocked items no lane holds.
fn inventory_of(
    items: &[OpenItem],
    containers: &BTreeSet<String>,
    fleet: &FleetState,
    read_at: u64,
) -> TrackerInventory {
    let last_lane = |item: &str| fleet.lanes.iter().rfind(|l| l.item == item);
    let mut owed = Vec::new();
    let mut verifying = Vec::new();
    for item in items {
        let container = containers.contains(&item.id);
        let state = if container {
            Some(OwedState::Verifying)
        } else {
            OwedState::of_name(&item.state)
        };
        let Some(state) = state else { continue };
        let priority = priority_word(&item.priority);
        if state == OwedState::Verifying {
            verifying.push(VerifyingItem {
                id: item.id.clone(),
                created_at: item.created_at.clone(),
                description: match &item.description {
                    Nullable::Present(d) => d.clone(),
                    Nullable::Absent | Nullable::Null => String::new(),
                },
                priority,
                container,
                blocked_by_open: item.blocked_by_open.clone(),
            });
            continue;
        }
        if fleet.launch_queue.contains(&item.id) {
            continue;
        }
        let record = last_lane(&item.id);
        let in_flight = record.is_some_and(|r| {
            matches!(
                r.status,
                LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Parked
            )
        });
        if in_flight {
            continue;
        }
        let delivery = record.and_then(|r| r.extra.get("cycle")).and_then(|cycle| {
            let pr = cycle.get("pr").and_then(|v| v.as_u64());
            let commit = cycle.get("commit").and_then(|v| v.as_str());
            match (pr, commit) {
                (Some(pr), None) => Some(format!("pr={pr}")),
                (None, Some(commit)) => Some(format!("commit={commit}")),
                (Some(_), Some(_)) | (None, None) => None,
            }
        });
        let text = |value: Option<&str>, none: &str| {
            value.filter(|v| !v.is_empty()).unwrap_or(none).to_owned()
        };
        owed.push(OwedItem {
            id: item.id.clone(),
            state,
            priority,
            lane: record.map_or("none".to_owned(), |r| r.status.word().to_owned()),
            host: text(record.and_then(|r| r.host.as_deref()), "local"),
            harness: text(record.and_then(|r| r.harness.as_deref()), "-"),
            model: text(record.and_then(|r| r.model.as_deref()), "-"),
            delivery,
        });
    }
    let held: BTreeSet<&str> = fleet
        .lanes
        .iter()
        .filter(|l| l.status != LaneStatus::Done)
        .map(|l| l.item.as_str())
        .chain(fleet.launch_queue.iter().map(String::as_str))
        .collect();
    // The rows sorted by id.
    owed.sort_by(|a, b| a.id.cmp(&b.id));
    let open_unblocked = items
        .iter()
        .filter(|i| i.blocked_by_open.is_empty() && !held.contains(i.id.as_str()))
        .map(|i| i.id.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    TrackerInventory {
        read_at,
        owed,
        verifying,
        open_unblocked,
    }
}

// --- the owner's tracker answers and the due tracker asks -----------------------

/// How the owner-tracker read ended: off with no owner tracker configured,
/// read whole, or unread with its cause, named once on stderr as the pass
/// goes on; the due tracker asks are resolved only after a whole read.
#[derive(Debug, Clone, PartialEq, Eq)]
enum OwnerRead {
    Disabled,
    Read,
    Unread(&'static str),
}

/// `owner_action_line` (`mailbox-append.sh`): the owner's first name,
/// the stored action and the description with any earlier action line
/// removed; none where the assignee has no word.
fn owner_action_line(assignee: &str, action: &str, description: &str) -> Option<String> {
    let name = assignee.split_whitespace().next()?;
    let body = strip_action_line(description);
    Some(format!("**{name}, what you do:** {action}\n\n{body}"))
}

/// Whether a description opens with an action line
/// (`^\*\*[^*\r\n]+, what you do:\*\* `).
fn has_action_line(description: &str) -> bool {
    action_line_end(description).is_some()
}

/// The byte past the action line's `** ` where the description opens with
/// one: `**<name>, what you do:** `.
fn action_line_end(description: &str) -> Option<usize> {
    let rest = description.strip_prefix("**")?;
    let marker = ", what you do:** ";
    let at = rest.find(marker)?;
    let name = &rest[..at];
    if name.is_empty() || name.contains(['*', '\r', '\n']) {
        return None;
    }
    Some(2 + at + marker.len())
}

/// `owner_action_body`: the description without its action line, the rest
/// of that line and the blank line after it.
fn strip_action_line(description: &str) -> String {
    let Some(end) = action_line_end(description).or_else(|| {
        // The line form without the trailing space (`[^\r\n]*` after `**`).
        let rest = description.strip_prefix("**")?;
        let at = rest.find(", what you do:**")?;
        let name = &rest[..at];
        (!name.is_empty() && !name.contains(['*', '\r', '\n']))
            .then_some(2 + at + ", what you do:**".len())
    }) else {
        return description.to_owned();
    };
    let mut rest = &description[end..];
    // The rest of the line, then the line's end and one blank line where
    // both stand (`(\r?\n\r?\n)?`): a lone line end stays.
    let line_end = rest.find(['\r', '\n']).unwrap_or(rest.len());
    rest = &rest[line_end..];
    let newline = |text: &str| -> Option<usize> {
        if text.starts_with("\r\n") {
            Some(2)
        } else if text.starts_with('\n') {
            Some(1)
        } else {
            None
        }
    };
    if let Some(first) = newline(rest)
        && let Some(second) = newline(&rest[first..])
    {
        rest = &rest[first + second..];
    }
    rest.to_owned()
}

/// The owner's answer text handed to the mailbox program through the one
/// form it takes, a file beside the watch's records.
#[allow(
    clippy::disallowed_methods,
    reason = "the tracker duty's one scratch file: the owner's answer text the mailbox program reads with --file, beside the watch's own records, overwritten per answer"
)]
fn write_answer(path: &Path, text: &str) -> Result<()> {
    std::fs::write(path, text).map_err(|e| {
        Error::Runtime(agent_runtime::Error::io(
            "write-answer",
            path.to_path_buf(),
            e,
        ))
    })
}

/// The owner's tracker answers: the posted owner asks' labels, the owner's
/// items under each, the description repair (`owner_action_line`) of an
/// item whose posted ask has an action and whose description lost its
/// action line, the comments of those items in one batch, and each owner
/// comment after the posted question handed back as the ask's answer under
/// the comment's delivery id, then marked delivered by a reply under it. A
/// quota receipt is the answer; a read that fails is named once and ends
/// the read as unread. A repair or a delivery mark that did not land is an
/// `owner-ask-unmarked` line and stops nothing.
fn read_owner_tracker_answers(
    linear: &Linear,
    ctx: &Context,
    mailbox: &Mailbox,
    root: &Path,
    tick: &Tick,
    owner_pass: &mut OwnerPass,
) -> Result<Answered<OwnerRead>> {
    let Some(owner) = &ctx.settings.reads.owner_tracker else {
        return Ok(Answered::Value(OwnerRead::Disabled));
    };
    let unread = |cause: &'static str| {
        let _ = writeln!(std::io::stderr(), "owner-tracker-unread cause={cause}");
        Ok(Answered::Value(OwnerRead::Unread(cause)))
    };
    let asks = match mailbox.pending_owner_asks(root) {
        Ok(asks) => asks,
        Err(_) => return unread("asks"),
    };
    let posted: Vec<&Envelope> = asks
        .iter()
        .filter(|a| a.tracker_posted == Some(true))
        .collect();
    if posted.is_empty() {
        return Ok(Answered::Value(OwnerRead::Read));
    }
    let labels: BTreeSet<&str> = posted
        .iter()
        .map(|a| a.tracker_label.as_deref().unwrap_or(owner.label.as_str()))
        .collect();
    let mut items: BTreeMap<String, OwnerItem> = BTreeMap::new();
    for label in labels {
        let listed = linear.json::<Vec<OwnerItem>>(
            "owner-items",
            &[
                "issues",
                "list",
                "--assignee",
                &owner.email,
                "--label",
                label,
                "--max",
                "--format=safe",
            ],
        );
        let listed: Vec<OwnerItem> = match listed {
            Ok(Answered::Value(items)) => items,
            Ok(Answered::Quota(quota)) => return Ok(Answered::Quota(quota)),
            Err(e) if e.key() == "tracker-list-invalid" => return unread("issues-format"),
            Err(_) => return unread("issues"),
        };
        for item in listed {
            items.entry(item.id.clone()).or_insert(item);
        }
    }
    // The description repair.
    for item in items.values() {
        let ask = posted.iter().rev().find(|a| {
            a.issue.as_deref() == Some(item.id.as_str())
                && a.action.as_deref().is_some_and(|d| !d.is_empty())
        });
        let Some(ask) = ask else { continue };
        let description = match &item.description {
            Nullable::Present(d) => d.as_str(),
            Nullable::Absent | Nullable::Null => "",
        };
        if has_action_line(description) {
            owner_pass.line_outcome(tick, ask, &item.id, None)?;
            continue;
        }
        let Some(repaired) = owner_action_line(
            &item.assignee,
            ask.action.as_deref().unwrap_or(""),
            description,
        ) else {
            return unread("issues-format");
        };
        if let Ok(Answered::Quota(quota)) = linear.call(
            "owner-repair",
            &["issues", "update", &item.id, "--description", &repaired],
        ) {
            return Ok(Answered::Quota(quota));
        }
        // The write's own reply can be lost or claim a write that did not
        // land: the item read back says whether it carries the repair. A
        // tracker write is advisory, so one that did not land is said and
        // holds none of the owner's answers; the next pass reads the
        // description again and repairs only one still missing.
        let variables = serde_json::json!({ "id": item.id }).to_string();
        let unlanded = match linear.json::<OwnerReadBack>(
            "owner-repair-read-back",
            &["graphql", "--query", OWNER_ITEM, "--variables", &variables],
        ) {
            Ok(Answered::Value(OwnerReadBack { issue })) => (issue.identifier != item.id
                || issue.description.as_ref() != Some(&repaired))
            .then(|| "unlanded".to_owned()),
            Ok(Answered::Quota(quota)) => return Ok(Answered::Quota(quota)),
            Err(e) => Some(e.key().to_owned()),
        };
        owner_pass.line_outcome(tick, ask, &item.id, unlanded)?;
    }
    if items.is_empty() {
        return Ok(Answered::Value(OwnerRead::Read));
    }
    let mut args = vec!["comments", "bulk-list"];
    args.extend(items.keys().map(String::as_str));
    args.push("--format=safe");
    let comments: BTreeMap<String, Vec<CommentRow>> = match linear.json("owner-comments", &args) {
        Ok(Answered::Value(comments)) => comments,
        Ok(Answered::Quota(quota)) => return Ok(Answered::Quota(quota)),
        Err(e) if e.key() == "tracker-list-invalid" => return unread("comments-format"),
        Err(_) => return unread("comments"),
    };
    let answer_file = ctx
        .fleet
        .parent()
        .unwrap_or(Path::new("."))
        .join("oversee-watch.tracker-answer");
    let email = owner.email.to_ascii_lowercase();
    for ask in posted {
        let Some(issue) = ask.issue.as_deref() else {
            continue;
        };
        let mut rows: Vec<&CommentRow> = comments
            .get(issue)
            .map(|r| r.iter().collect())
            .unwrap_or_default();
        rows.sort_by(|a, b| a.created_at.cmp(&b.created_at));
        // A record with no comment id finds its comment by its ask= line.
        let question = rows.iter().find(|c| match &ask.tracker_comment {
            Some(id) => c.id == *id,
            None => c.body.lines().any(|l| l == format!("ask={}", ask.id())),
        });
        let Some(question) = question else { continue };
        for comment in &rows {
            if comment.user_email.to_ascii_lowercase() != email
                || comment.created_at <= question.created_at
                || comment.id == question.id
            {
                continue;
            }
            write_answer(&answer_file, &comment.body)?;
            let delivery = format!("linear:{}", comment.id);
            match mailbox.send_answer(root, ask.id(), &delivery, &answer_file) {
                Ok(Replied::Sent { .. }) => {
                    let marked = linear.call(
                        "owner-delivered",
                        &[
                            "comments",
                            "create",
                            issue,
                            "--parent",
                            &comment.id,
                            "--body",
                            DELIVERED,
                        ],
                    );
                    // The answer is handed over once: a mark that did not
                    // land is said, never tried again.
                    let cause = match &marked {
                        Ok(Answered::Value(_)) => continue,
                        Ok(Answered::Quota(_)) => "quota",
                        Err(e) => e.key(),
                    };
                    owner_pass
                        .events
                        .push(unmarked(ask.id(), issue, OwnerMark::Delivery, cause));
                    if let Ok(Answered::Quota(quota)) = marked {
                        return Ok(Answered::Quota(quota));
                    }
                }
                Ok(Replied::Repeated { .. }) => {}
                Err(_) => return unread("delivery"),
            }
        }
    }
    Ok(Answered::Value(OwnerRead::Read))
}

/// The due tracker asks: every due owner ask posted to the tracker closed
/// with its recommendation through the mailbox client; another close
/// winning the lock is no failure; a read or close that fails is the pass's
/// partial failure, its causes keyed `ask-due-unread` and
/// `ask-resolve-failed`, said by the runner.
fn resolve_due_tracker_asks(mailbox: &Mailbox, root: &Path) -> Option<String> {
    let due = match mailbox.due_owner_asks(root) {
        Ok(due) => due,
        Err(refusal) => return Some(format!("ask-due-unread cause={refusal}")),
    };
    let mut failed = Vec::new();
    for ask in due {
        if ask.tracker_posted != Some(true) || ask.id().is_empty() {
            continue;
        }
        match mailbox.resolve_default(root, ask.id()) {
            Ok(Resolved::Closed { .. } | Resolved::Already { .. }) => {}
            Err(refusal) => {
                failed.push(format!(
                    "ask-resolve-failed id={} cause={refusal}",
                    ask.id()
                ));
            }
        }
    }
    (!failed.is_empty()).then(|| failed.join("\n"))
}

// --- the owner asks' tracker marks ----------------------------------------------

/// The reply under a delivered owner comment. Ids stay in the mailbox: the
/// comment it replies to names the answer.
const DELIVERED: &str = "Delivered to the overseer that asked.";

/// The item a closed ask's write reads: its description, assignee name and
/// label names, the label page closed (`linear.sh graphql` refuses one left
/// open, and the write sends the whole set).
const OWNER_ASK_ITEM: &str = "query OwnerAskItem($id: String!) { issue(id: $id) { description assignee { name } labels(first: 250) { pageInfo { hasNextPage } nodes { name } } } }";

#[derive(Debug, Deserialize)]
struct OwnerAskItem {
    issue: OwnerAskIssue,
}

#[derive(Debug, Deserialize)]
struct OwnerAskIssue {
    description: Option<String>,
    assignee: Option<AssigneeName>,
    labels: LabelNodes,
}

#[derive(Debug, Deserialize)]
struct AssigneeName {
    name: String,
}

#[derive(Debug, Deserialize)]
struct LabelNodes {
    nodes: Vec<LabelName>,
}

#[derive(Debug, Deserialize)]
struct LabelName {
    name: String,
}

/// What the owner-ask work of one pass hands back beside the tracker read:
/// its lines, its rows and its partial failures.
#[derive(Default)]
struct OwnerPass {
    events: Vec<Event>,
    changes: Vec<Change>,
    failed: Vec<String>,
}

/// One close step as the ask's row keeps it: landed, or standing with the
/// cause it was said under.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Mark {
    Landed,
    Standing(String),
}

/// One owner ask's marks as its row keeps them, space-separated
/// `step=state` words: each close step `ok` or its standing cause, absent
/// while untried, and the line repair's standing cause.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct Marks {
    ruling: Option<Mark>,
    item: Option<Mark>,
    line: Option<String>,
}

impl Marks {
    fn of_marks_row(value: Option<&str>) -> Result<Marks> {
        let mut marks = Marks::default();
        for word in value.unwrap_or("").split_whitespace() {
            let mark = |state: &str| match state {
                "ok" => Mark::Landed,
                cause => Mark::Standing(cause.to_owned()),
            };
            match word.split_once('=') {
                Some(("ruling", state)) if !state.is_empty() => marks.ruling = Some(mark(state)),
                Some(("item", state)) if !state.is_empty() => marks.item = Some(mark(state)),
                Some(("line", cause)) if !cause.is_empty() && cause != "ok" => {
                    marks.line = Some(cause.to_owned());
                }
                _ => return Err(invalid("owner-mark-row", "value", value.unwrap_or(""))),
            }
        }
        Ok(marks)
    }

    fn marks_row(&self) -> String {
        let mut words = Vec::new();
        for (step, mark) in [("ruling", &self.ruling), ("item", &self.item)] {
            match mark {
                Some(Mark::Landed) => words.push(format!("{step}=ok")),
                Some(Mark::Standing(cause)) => words.push(format!("{step}={cause}")),
                None => {}
            }
        }
        if let Some(cause) = &self.line {
            words.push(format!("line={cause}"));
        }
        words.join(" ")
    }
}

fn unmarked(ask: &str, issue: &str, step: OwnerMark, cause: &str) -> Event {
    Event::OwnerAskUnmarked {
        ask: ask.to_owned(),
        issue: issue.to_owned(),
        step,
        cause: cause.to_owned(),
    }
}

impl OwnerPass {
    /// The row of `ask` moved from what the tick's baseline holds to
    /// `marks`: set, cleared when nothing stands, untouched when unchanged.
    fn keep_marks(&mut self, tick: &Tick, ask: &str, marks: &Marks) {
        let before = tick.baseline.get(OWNER_MARK_ROW, ask);
        let after = marks.marks_row();
        if before == Some(after.as_str()) || (before.is_none() && after.is_empty()) {
            return;
        }
        self.changes.push(if after.is_empty() {
            Change::Clear {
                kind: OWNER_MARK_ROW.to_owned(),
                identity: ask.to_owned(),
            }
        } else {
            Change::Set {
                kind: OWNER_MARK_ROW.to_owned(),
                identity: ask.to_owned(),
                value: after,
            }
        });
    }

    /// The line repair's outcome for `ask` on `issue`: a cause not standing
    /// before is said; a landed or unneeded repair ends a standing one.
    fn line_outcome(
        &mut self,
        tick: &Tick,
        ask: &Envelope,
        issue: &str,
        cause: Option<String>,
    ) -> Result<()> {
        let mut marks = Marks::of_marks_row(tick.baseline.get(OWNER_MARK_ROW, ask.id()))?;
        if let Some(cause) = &cause
            && marks.line.as_ref() != Some(cause)
        {
            self.events
                .push(unmarked(ask.id(), issue, OwnerMark::Line, cause));
        }
        marks.line = cause;
        self.keep_marks(tick, ask.id(), &marks);
        Ok(())
    }
}

/// The tracker marks of every owner ask posted to an item and closed by any
/// route: the ruling comment, a reply under the question where its comment
/// id is recorded, and one item write of labels, assignee and action line.
/// The two steps run alone, so a refused one stops neither; a refused step
/// is said once per cause and tried again at every pass. The first pass
/// that reads the mailbox records the asks closed before it as marked and
/// writes nothing. A refused mailbox read is the pass's partial failure.
fn mark_closed_owner_asks(
    linear: &Linear,
    mailbox: &Mailbox,
    root: &Path,
    configured: &str,
    tick: &Tick,
    owner: &mut OwnerPass,
) -> Result<Answered<()>> {
    let envelopes = match mailbox.events(root) {
        Ok(envelopes) => envelopes,
        Err(refusal) => {
            owner
                .failed
                .push(format!("owner-asks-unread cause={refusal}"));
            return Ok(Answered::Value(()));
        }
    };
    let asks: Vec<&Envelope> = envelopes
        .iter()
        .filter(|e| e.kind() == "ask" && e.to.as_deref() == Some("owner") && !e.id().is_empty())
        .collect();
    let closes: BTreeMap<&str, &Envelope> = envelopes
        .iter()
        .filter(|e| e.kind() == "resolution")
        .filter_map(|e| Some((e.re.as_deref()?, e)))
        .collect();
    // A row of an ask no longer in the mailbox leaves with it.
    let held: BTreeSet<&str> = asks.iter().map(|a| a.id()).collect();
    for id in tick.baseline.identities(OWNER_MARK_ROW) {
        if id != FLEET && !held.contains(id.as_str()) {
            owner.changes.push(Change::Clear {
                kind: OWNER_MARK_ROW.to_owned(),
                identity: id,
            });
        }
    }
    let posted = |a: &&&Envelope| a.tracker_posted == Some(true) && a.issue.is_some();
    let closed: Vec<(&Envelope, &Envelope)> = asks
        .iter()
        .filter(posted)
        .filter_map(|a| Some((*a, *closes.get(a.id())?)))
        .collect();
    let landed = Marks {
        ruling: Some(Mark::Landed),
        item: Some(Mark::Landed),
        line: None,
    };
    if tick.baseline.get(OWNER_MARK_ROW, FLEET).is_none() {
        owner.changes.push(Change::Set {
            kind: OWNER_MARK_ROW.to_owned(),
            identity: FLEET.to_owned(),
            value: "floor".to_owned(),
        });
        for (ask, _) in closed {
            owner.keep_marks(tick, ask.id(), &landed);
        }
        return Ok(Answered::Value(()));
    }
    let open: Vec<&Envelope> = asks
        .iter()
        .filter(posted)
        .filter(|a| !closes.contains_key(a.id()))
        .copied()
        .collect();
    for (ask, close) in closed {
        let mut marks = Marks::of_marks_row(tick.baseline.get(OWNER_MARK_ROW, ask.id()))?;
        if marks == landed {
            continue;
        }
        let issue = ask.issue.as_deref().unwrap_or("");
        marks.line = None;
        if marks.ruling != Some(Mark::Landed) {
            let ruling = envelopes
                .iter()
                .rfind(|e| e.kind() == "answer" && e.re.as_deref() == Some(ask.id()))
                .and_then(|e| e.text.as_deref())
                .unwrap_or("");
            let body = format!(
                "ask={} closed ({}): {ruling}",
                ask.id(),
                close.by.as_deref().unwrap_or("")
            );
            let mut args = vec!["comments", "create", issue, "--body", &body];
            if let Some(question) = &ask.tracker_comment {
                args.extend(["--parent", question.as_str()]);
            }
            let written = linear.call("owner-ruling", &args).map(|a| match a {
                Answered::Value(_) => Answered::Value(()),
                Answered::Quota(quota) => Answered::Quota(quota),
            });
            marks.ruling = Some(quota!(settle_mark(
                written,
                &marks.ruling,
                ask,
                issue,
                OwnerMark::Ruling,
                owner
            )?));
        }
        if marks.item != Some(Mark::Landed) {
            let written = clear_owner_item(linear, ask, issue, &open, configured);
            marks.item = Some(quota!(settle_mark(
                written,
                &marks.item,
                ask,
                issue,
                OwnerMark::Item,
                owner
            )?));
        }
        owner.keep_marks(tick, ask.id(), &marks);
    }
    Ok(Answered::Value(()))
}

/// One close step's outcome as its mark: a refusal whose cause was not the
/// one standing before is said.
fn settle_mark(
    written: Result<Answered<()>>,
    before: &Option<Mark>,
    ask: &Envelope,
    issue: &str,
    step: OwnerMark,
    owner: &mut OwnerPass,
) -> Result<Answered<Mark>> {
    match written {
        Ok(Answered::Value(())) => Ok(Answered::Value(Mark::Landed)),
        Ok(Answered::Quota(quota)) => Ok(Answered::Quota(quota)),
        Err(e) => {
            let mark = Mark::Standing(e.key().to_owned());
            if before.as_ref() != Some(&mark) {
                owner.events.push(unmarked(ask.id(), issue, step, e.key()));
            }
            Ok(Answered::Value(mark))
        }
    }
}

/// The closed `ask`'s item write: its label dropped unless an `open` ask on
/// the same item was posted under it, the assignee cleared once no open
/// ask stands there, and its action line removed, or replaced by the
/// latest open ask's, only where the description still opens with it.
fn clear_owner_item(
    linear: &Linear,
    ask: &Envelope,
    issue: &str,
    open: &[&Envelope],
    configured: &str,
) -> Result<Answered<()>> {
    let variables = serde_json::json!({ "id": issue }).to_string();
    let item = quota!(linear.json::<OwnerAskItem>(
        "owner-ask-item",
        &[
            "graphql",
            "--query",
            OWNER_ASK_ITEM,
            "--variables",
            &variables
        ],
    )?)
    .issue;
    let label_of = |a: &Envelope| {
        a.tracker_label
            .clone()
            .unwrap_or_else(|| configured.to_owned())
    };
    let remaining: Vec<&Envelope> = open
        .iter()
        .filter(|a| a.issue.as_deref() == Some(issue))
        .copied()
        .collect();
    let closing = label_of(ask);
    let labels: BTreeSet<String> = item
        .labels
        .nodes
        .into_iter()
        .map(|l| l.name)
        .filter(|l| *l != closing)
        .chain(remaining.iter().copied().map(label_of))
        .collect();
    let name = item.assignee.map(|a| a.name).unwrap_or_default();
    let mut description = item.description.unwrap_or_default();
    if let Some(action) = ask.action.as_deref().filter(|d| !d.is_empty())
        && let Some(prefix) = owner_action_line(&name, action, "")
        && let Some(body) = description.strip_prefix(&prefix)
    {
        description = match remaining
            .last()
            .and_then(|next| next.action.as_deref())
            .filter(|d| !d.is_empty())
            .and_then(|next| owner_action_line(&name, next, ""))
        {
            Some(line) => format!("{line}{body}"),
            None => body.to_owned(),
        };
    }
    let joined = labels.into_iter().collect::<Vec<_>>().join(",");
    let mut args = vec!["issues", "update", issue];
    if joined.is_empty() {
        args.push("--clear-labels");
    } else {
        args.extend(["--labels", joined.as_str()]);
    }
    if remaining.is_empty() {
        args.push("--clear-assignee");
    }
    args.extend(["--description", description.as_str()]);
    quota!(linear.call("owner-ask-close", &args)?);
    Ok(Answered::Value(()))
}

// --- the closes ---------------------------------------------------------------

/// The runtime's close, `close-owned-resources` with `terminal {verdict,
/// source: tracker}`, for every parked or stopped lane whose item the
/// tracker shows ended and whose refusal, if one stands, was under another
/// key: one line per close, a refused close reported and held under its
/// key so it is not asked again until the record or the verdict moves.
fn close_terminal_lanes(
    ctx: &Context,
    tick: &Tick,
    fleet: &FleetState,
    terminal: &BTreeMap<String, TerminalState>,
) -> Result<Produced> {
    let mut produced = Produced::default();
    let mut carried: BTreeSet<String> = BTreeSet::new();
    for (i, lane) in fleet
        .lanes
        .iter()
        .filter(|l| matches!(l.status, LaneStatus::Parked | LaneStatus::Stopped))
        .enumerate()
    {
        carried.insert(lane.item.clone());
        let Some(state) = terminal.get(&lane.item) else {
            continue;
        };
        let Some(verdict) = state.verdict() else {
            produced.changes.push(Change::Clear {
                kind: TERMINAL_CLOSE_ROW.to_owned(),
                identity: lane.item.clone(),
            });
            continue;
        };
        let key = format!(
            "{}|{}",
            state.word(),
            lane.session_since.as_deref().unwrap_or("-")
        );
        if tick
            .baseline
            .get(TERMINAL_CLOSE_ROW, &lane.item)
            .and_then(refused_close)
            .is_some_and(|(held, _)| held == key)
        {
            continue;
        }
        // Read before the close removes the lane-side state it is read
        // from, and carried by the close's own request. A landing that
        // cannot be recorded holds the close: its line is said once per
        // cause, and every pass asks again, since a GitHub read can clear on
        // any of them.
        let cycle = match cycle_of(ctx, tick, lane) {
            Ok(cycle) => cycle,
            Err(cause) => {
                let held = format!("held|{cause}");
                if tick.baseline.get(TERMINAL_CLOSE_ROW, &lane.item) != Some(held.as_str()) {
                    let _ = writeln!(
                        std::io::stderr(),
                        "lane-close-failed item={} step=cycle cause={cause}",
                        lane.item
                    );
                    produced.changes.push(Change::Set {
                        kind: TERMINAL_CLOSE_ROW.to_owned(),
                        identity: lane.item.clone(),
                        value: held,
                    });
                }
                continue;
            }
        };
        let lines = cycle.as_ref().map(|c| c.lines.clone()).unwrap_or_default();
        let env = Env {
            now_secs: tick.wall,
            now_nanos: u128::from(tick.wall) * 1_000_000_000 + i as u128,
            nonce: ctx.nonce,
            owner: ctx.owner.clone(),
        };
        let closed =
            close_one(ctx, tick, &env, &lane.item, verdict, cycle).and_then(
                |closed| match closed {
                    Closed::Confirmed => Ok(true),
                    Closed::Open => Ok(false),
                    Closed::Failed(cause) => Err(Error::Runtime(agent_runtime::Error::refused(
                        "close-failed",
                        &[("cause", &cause)],
                    ))),
                },
            );
        match closed {
            Ok(true) => {
                produced.events.extend(lines.into_iter().map(Event::Tail));
                produced.events.push(Event::LaneClosed {
                    item: lane.item.clone(),
                });
                produced.changes.push(Change::Clear {
                    kind: TERMINAL_CLOSE_ROW.to_owned(),
                    identity: lane.item.clone(),
                });
            }
            // The close's intent stands open, and the next pass's request,
            // this watch's own, reconciles it: nothing is said of it yet.
            Ok(false) => {
                let _ = writeln!(
                    std::io::stderr(),
                    "lane-close-pending item={} outcome=unconfirmed",
                    lane.item
                );
            }
            Err(cause) => {
                // The cause is said once, here, for the launcher's record
                // of this run's stderr, and kept in the row for the report;
                // the line carries the item alone.
                let _ = writeln!(
                    std::io::stderr(),
                    "lane-close-refused item={} cause={cause}",
                    lane.item
                );
                produced.events.push(Event::LaneCloseRefused {
                    item: lane.item.clone(),
                });
                produced.changes.push(Change::Set {
                    kind: TERMINAL_CLOSE_ROW.to_owned(),
                    identity: lane.item.clone(),
                    value: format!("{key}|{cause}"),
                });
            }
        }
    }
    for item in tick.baseline.identities(TERMINAL_CLOSE_ROW) {
        if !carried.contains(&item) {
            produced.changes.push(Change::Clear {
                kind: TERMINAL_CLOSE_ROW.to_owned(),
                identity: item,
            });
        }
    }
    Ok(produced)
}

/// An ended lane's merge cycle (`ops::cycle`), for the first of the item's
/// merged pull requests that is the lane's own: the parked or pending pull
/// request its record names, else one in its repository. The merges are the
/// merged index's current read for the lane ([`github::merged_keys`]), made
/// before every terminal close whatever `merged` row stands: the item often
/// ends at the merge, this duty runs before the GitHub duty on the shared
/// cadence, and a row an earlier pass wrote can name an earlier pull request
/// only. A merge its record's `cycle` already names is not recorded again.
/// The row rides the close's request and is written with the close when it
/// confirms, its lines said then; the recorder's notes are said on stderr.
/// `Ok(None)` is a lane with no merge of its own to record; `Err` is the
/// cause of a merge read that failed, a merge key that does not parse or a
/// recorder refusal, which holds the close.
fn cycle_of(
    ctx: &Context,
    tick: &Tick,
    lane: &Lane,
) -> std::result::Result<Option<CycleRow>, String> {
    let gh = github::handle(&ctx.gh);
    let since_iso = ctx.since.map(clock::iso_utc);
    let merged = match github::merged_keys(
        &gh,
        lane,
        &ctx.repos,
        &ctx.settings,
        ctx.since,
        since_iso.as_deref(),
        tick.wall,
    ) {
        Ok(keys) => keys,
        Err(e) => return Err(format!("merged-unread {e}")),
    };
    let repo_of = |v: &serde_json::Value| {
        v.get("repo")
            .and_then(serde_json::Value::as_str)
            .map(str::to_ascii_lowercase)
    };
    let recorded = lane
        .extra
        .get("parked")
        .or_else(|| lane.extra.get("pending_pr"))
        .and_then(|p| Some(format!("{}#{}", repo_of(p)?, p.get("pr")?.as_u64()?)));
    let repo = lane
        .repo
        .as_deref()
        .map(str::to_ascii_lowercase)
        .filter(|r| !r.is_empty());
    let cycle_pr = lane
        .extra
        .get("cycle")
        .and_then(|c| c.get("pr"))
        .and_then(serde_json::Value::as_u64);
    let own = merged.iter().find_map(|key| {
        let (key_repo, number) = key.rsplit_once('#')?;
        let mine = match (&recorded, &repo) {
            (Some(recorded), _) => recorded == key,
            (None, Some(repo)) => repo == key_repo,
            (None, None) => true,
        };
        mine.then_some((key_repo, number))
    });
    let Some((key_repo, number)) = own else {
        return Ok(None);
    };
    if cycle_pr.is_some() && cycle_pr == number.parse().ok() {
        return Ok(None);
    }
    let Ok(pr) = number.parse::<u64>() else {
        return Err(format!("pr-unparsed key={key_repo}#{number}"));
    };
    let delivery = Delivery::Pr {
        pr,
        repo: Some(key_repo.to_owned()),
    };
    match ops::cycle::recorded(
        &ctx.settings,
        &ctx.gh,
        &ctx.fleet,
        lane,
        &delivery,
        tick.wall,
    ) {
        Ok(row) => {
            let mut stderr = std::io::stderr();
            for note in &row.notes {
                let _ = writeln!(stderr, "{note}");
            }
            Ok(Some(row))
        }
        Err(cause) => Err(cause),
    }
}

/// How a close's effect ended, by the outcome it recorded.
enum Closed {
    Confirmed,
    /// Failed, with the intent's note.
    Failed(String),
    /// Unconfirmed, the intent left open.
    Open,
}

/// One close through the store and the effect module, as the `op` command
/// runs it: the request persisted on the host's facts, then its effect run
/// and recorded, read by the outcome it recorded.
#[allow(
    clippy::disallowed_methods,
    reason = "the terminal-lanes step's one store call per ended item: the close request the fleet record's own close effect runs on"
)]
fn close_one(
    ctx: &Context,
    tick: &Tick,
    env: &Env,
    item: &str,
    verdict: TerminalVerdict,
    cycle: Option<CycleRow>,
) -> Result<Closed> {
    let request = Request::CloseOwnedResources(CloseOwnedResources {
        item: item.to_owned(),
        terminal: Some(Terminal {
            verdict,
            source: "tracker".to_owned(),
        }),
        no_landing: None,
        ended: None,
        identity: None,
        cycle,
        disposed: None,
    });
    // The close's bounds are judged before its intent persists, as the
    // command's admission judges them.
    ops::judge_effect_settings(&request, &ctx.settings)?;
    let host = ops::Host::kernel();
    let applied = ops::apply_on(&ctx.fleet, &request, env, ctx.locking, &host)?;
    let effected = crate::effects::run(
        &ctx.fleet,
        &request,
        &applied.report,
        &ctx.settings,
        env,
        ctx.locking,
        tick.clock,
    )?;
    let Some(crate::effects::Effected::Recorded(recorded)) = effected else {
        return Ok(Closed::Open);
    };
    let ops::Report::RecordOutcome(outcome) = &recorded.report else {
        return Ok(Closed::Open);
    };
    let intent = &outcome.intent;
    if intent.open() {
        return Ok(Closed::Open);
    }
    if intent.outcome == agent_runtime::protocol::Outcome::Confirmed {
        return Ok(Closed::Confirmed);
    }
    let note = intent
        .observation
        .as_ref()
        .and_then(|o| o.get("note").or_else(|| o.get("cause")))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("failed");
    Ok(Closed::Failed(note.to_owned()))
}

pub fn row_kinds() -> [&'static str; 4] {
    [QUOTA_ROW, TRIAGE_ROW, TERMINAL_CLOSE_ROW, OWNER_MARK_ROW]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The receipt's shape: a future or elapsed status
    /// needs its epoch and the matching ISO reset, the others `unavailable`
    /// and no epoch; the last well-formed receipt on stderr is the one;
    /// a future reset holds until its epoch and not from it.
    #[test]
    fn a_quota_receipt_is_read_in_the_clis_shape_and_holds_until_its_reset() {
        let future = r#"{"code":"RATELIMITED","quota":{"limit":"requests","status":"future","reset":"2026-01-01T00:10:00Z","reset_epoch":1767226200}}"#;
        let quota = Quota::of_stderr(&format!("noise\n{future}\n")).unwrap();
        assert_eq!(quota.limit, QuotaLimit::Requests);
        assert!(quota.holds(1767226199));
        assert!(!quota.holds(1767226200));
        let malformed = [
            r#"{"code":"RATELIMITED","quota":{"limit":"requests","status":"future","reset":"2026-01-01T00:10:01Z","reset_epoch":1767226200}}"#,
            r#"{"code":"RATELIMITED","quota":{"limit":"requests","status":"missing","reset":"unavailable","reset_epoch":5}}"#,
            r#"{"code":"RATELIMITED","quota":{"limit":"bytes","status":"missing","reset":"unavailable","reset_epoch":null}}"#,
            r#"{"code":"OTHER","quota":{"limit":"requests","status":"future","reset":"2026-01-01T00:10:00Z","reset_epoch":1767226200}}"#,
        ];
        for text in malformed {
            assert_eq!(Quota::of_stderr(text), None, "{text}");
        }
        let missing = r#"{"code":"RATELIMITED","quota":{"limit":"unknown","status":"missing","reset":"unavailable","reset_epoch":null}}"#;
        let quota = Quota::of_stderr(&format!("{future}\n{missing}\n")).unwrap();
        assert_eq!(quota.status, QuotaStatus::Missing);
        assert!(!quota.holds(0));
        let row: Quota = serde_json::from_str(&quota.row_value()).unwrap();
        assert_eq!(row, quota);
    }

    /// `owner_action_line` and `owner_action_body` (`mailbox-append.sh`):
    /// the first name, the action, one blank line, the body; an earlier
    /// action line is replaced; an assignee with no word repairs nothing.
    #[test]
    fn the_owner_action_line_opens_the_description_and_replaces_an_earlier_one() {
        let body = "Engineering body.\n\nKeep these bytes.\n\n";
        let action = "Post the message. Copy its link. The link closes this ask.";
        let line = format!("**Maya, what you do:** {action}\n\n{body}");
        assert_eq!(
            owner_action_line("Maya Owner", action, body),
            Some(line.clone())
        );
        assert!(has_action_line(&line));
        assert!(!has_action_line(body));
        let replaced = format!("**Previous, what you do:** Old action.\n\n{body}");
        assert_eq!(
            owner_action_line("Maya Owner", action, &replaced),
            Some(line.clone())
        );
        // The blank line after an earlier action line goes with it only as
        // a pair (`(\r?\n\r?\n)?`): a body on the very next line keeps its
        // line end, and a CRLF pair is one pair.
        assert_eq!(
            strip_action_line("**Previous, what you do:** Old.\nbody\n"),
            "\nbody\n"
        );
        assert_eq!(
            strip_action_line("**Previous, what you do:** Old.\r\n\r\nbody"),
            "body"
        );
        assert_eq!(owner_action_line("", action, body), None);
    }

    /// A tracker stamp with fractional seconds reads as its whole second;
    /// a stamp of another shape reads as none.
    #[test]
    fn a_stamp_drops_its_fraction_before_the_epoch_read() {
        assert_eq!(stamp_epoch("2026-01-01T00:00:00.123Z"), Some(1767225600));
        assert_eq!(stamp_epoch("2026-01-01T00:00:00Z"), Some(1767225600));
        assert_eq!(stamp_epoch("2026-01-01"), None);
        assert_eq!(stamp_epoch(""), None);
    }
}
