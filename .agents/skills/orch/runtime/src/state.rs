//! Workflow records: the item state `<state-dir>/workflow-state-<ITEM>.json`
//! and the fleet state `workflow-state-oversee.json`, in the shape the
//! `workflow-state` script writes.
//!
//! A record is held as the document the file holds, a `serde_json::Map` in
//! the file's own key order. The typed structs here are read views derived
//! from that document; an operation changes the document by patching named
//! keys, so every key it does not touch keeps its value and its position,
//! and a key it adds appends. No typed struct is ever the serialized form of
//! a file, so no absent optional field is written back as `null`.
//!
//! agent-runtime's `record` module owns the document store: the lock, the
//! atomic replacement, the write check and the refusal of a stamped file.
//! This module owns the read views and the kind a file's name selects.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use agent_runtime::controller::{Overseer, TransferCause};
use agent_runtime::harness::Harness;
use agent_runtime::intent::{LaunchIdentity, Notice, Owner, Reconciled};
use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::record::{self, Document, FLEET_FILE_NAME, field};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Error, Result};

/// The item state file for `item` under `dir`:
/// `workflow-state-<ITEM>.json`, the name `workflow-state`'s `get_state_file`
/// builds.
pub fn item_path(dir: &Path, item: &str) -> PathBuf {
    dir.join(format!("workflow-state-{item}.json"))
}

/// The item an item state file's path names, the inverse of [`item_path`];
/// `None` for a path outside that naming.
pub fn item_of(path: &Path) -> Option<&str> {
    path.file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_prefix("workflow-state-"))
        .and_then(|n| n.strip_suffix(".json"))
}

/// The directive id of an owner-directed micro change's item, keyed
/// `directive-<id>`: the hook's item alphabet
/// (`hooks/lane-mail-check.sh` `item_alphabet`) and the mailbox's
/// (`lane-mail` `item-invalid`) admit `A-Za-z0-9._-` alone, so the word and
/// the id join with a hyphen, never a colon. `None` for every other item.
pub fn directive_of(path: &Path) -> Option<&str> {
    item_of(path).and_then(|item| item.strip_prefix("directive-"))
}

/// Which state file a path names. The fleet state has one fixed name; every
/// other `workflow-state-*.json` is an item's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Item,
    Fleet,
}

impl Kind {
    /// The kind the file name selects.
    pub fn of_path(path: &Path) -> Kind {
        if path.file_name().and_then(|n| n.to_str()) == Some(FLEET_FILE_NAME) {
            Kind::Fleet
        } else {
            Kind::Item
        }
    }

    /// The kind's word in a diagnostic.
    pub fn word(self) -> &'static str {
        match self {
            Kind::Item => "item",
            Kind::Fleet => "fleet",
        }
    }
}

/// A state file as read: the document a later write is checked against,
/// and its kind.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub kind: Kind,
    pub doc: Document,
}

impl Snapshot {
    /// The typed read view of the document, refusing `record-shape` on the
    /// first field the view cannot read.
    pub fn view<T: Record>(&self, path: &Path) -> Result<T> {
        T::view(path, &self.doc)
    }
}

/// A typed read view of one kind of state file.
pub trait Record: Sized {
    /// Derive the view from the document, refusing `record-shape` on a
    /// field whose value is not the shape the operations read.
    fn view(path: &Path, doc: &Document) -> Result<Self>;
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

/// The kinds a `stages[]` entry carries: `dev` and `review` opened by
/// `new-round-id`, `implement` and `fix` set on a dev stage by
/// `dev-artifact-check`, `validate` written per validation run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StageKind {
    Dev,
    Review,
    Implement,
    Fix,
    Validate,
}

impl StageKind {
    /// The kind's word as the file holds it.
    pub fn word(self) -> &'static str {
        match self {
            StageKind::Dev => "dev",
            StageKind::Review => "review",
            StageKind::Implement => "implement",
            StageKind::Fix => "fix",
            StageKind::Validate => "validate",
        }
    }
}

/// The word `accept-result` and `reconcile-round` close a stage with: the
/// run's verdict, how an admitted run ended without one, or a round its
/// item let end with no change. A request names the word; none is assumed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum StageOutcome {
    Pass,
    Fail,
    /// The run ended by its bound or an unavailable host check.
    NoVerdict,
    /// The run's process went away before a verdict.
    Lost,
    /// The run was stopped before a verdict.
    Stopped,
    /// The round changed nothing, as its item's own text permits, and ran
    /// no check.
    NoChange,
}

impl StageOutcome {
    /// The word as the file holds it.
    pub fn word(self) -> &'static str {
        match self {
            StageOutcome::Pass => "pass",
            StageOutcome::Fail => "fail",
            StageOutcome::NoVerdict => "no-verdict",
            StageOutcome::Lost => "lost",
            StageOutcome::Stopped => "stopped",
            StageOutcome::NoChange => "no-change",
        }
    }
}

/// One `stages[]` entry as read: `{kind, round_id, start, end}` in epoch
/// seconds, `superseded: true` once a later round of the kind opened over
/// it, `run_dir` on a validation run's entry, `outcome` once `accept-result`
/// closed it. A validation run `validate start` owns carries its `proof`
/// and its `job` from before its launch, and its `notice` from its close.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Stage {
    pub kind: StageKind,
    #[serde(default)]
    pub round_id: Option<String>,
    pub start: u64,
    #[serde(default)]
    pub end: Option<u64>,
    #[serde(default)]
    pub superseded: Option<bool>,
    #[serde(default)]
    pub run_dir: Option<String>,
    #[serde(default)]
    pub outcome: Option<StageOutcome>,
    #[serde(default)]
    pub proof: Option<Proof>,
    #[serde(default)]
    pub job: Option<ValidateJob>,
    #[serde(default)]
    pub notice: Option<Notice>,
    // Who accepted the step, and the item body revision the round
    // read.
    #[serde(default)]
    pub authorization: Option<Authorization>,
    #[serde(default)]
    pub body_revision: Option<String>,
    // The intentional stop a `validate stop` recorded on the open
    // stage before it ended the run's job.
    #[serde(default)]
    pub stop: Option<Stop>,
}

/// An intentional stop of a validation run, recorded on its open stage
/// before the job is ended, a record before the effect. A
/// job then read gone closes `stopped`, whatever sentinel its executor wrote
/// for the ending the stop caused; one with no such record closes by its
/// sentinel, or `lost` with none, since no one recorded an intent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stop {
    pub at: u64,
}

/// Who accepted a round's step, recorded on its stage at the close:
/// the overseer's acceptance, or the owner's
/// directive a micro change was made under, each by its id. The field is
/// part of the acceptance's identity: a closed stage keeps the one it was
/// closed under, and a request naming another refuses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Authorization {
    pub by: AuthorizedBy,
    pub id: String,
}

/// The two authorities an acceptance records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthorizedBy {
    Overseer,
    OwnerDirective,
}

/// The item's Completion Summary comment on the tracker, the
/// item's `summary_comment`: the
/// comment's id, the stamp of the acceptance's last post, and the
/// attachments its body carries. The acceptance updates the comment in
/// place by its id; on Linear a comment's attachments are links in its
/// body, so the record keeps them for every update's body to render. A
/// record written with an `origin` word reads without it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SummaryComment {
    pub id: String,
    pub at: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Attachment>,
}

/// One attachment of the summary comment: the link line the tracker CLI
/// appended under the body, as `![name](url)` for an image and
/// `[name](url)` otherwise.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub image: bool,
}

/// The validation mode a run records: the project's whole battery, its
/// range command over the changes since a base, or a round deferred to
/// required CI after publication (`dev-validate-run --help` § Validation
/// modes).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ValidateMode {
    Full,
    Range,
    Ci,
    Docs,
}

impl ValidateMode {
    /// The word as the file and the run's `start` record hold it.
    pub fn word(self) -> &'static str {
        match self {
            ValidateMode::Full => "full",
            ValidateMode::Range => "range",
            ValidateMode::Ci => "ci",
            ValidateMode::Docs => "docs",
        }
    }
}

/// The proof facts of one validation run, written on its stage before the
/// launch: the tree the run validated, the check selection
/// it ran, and the mode the declaration resolved with the cause a wider
/// mode was asked for. A stage closed `pass` with these is a proof row; a
/// `ci` row records CI pending and proves nothing locally.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proof {
    /// The worktree's snapshot tree as the classifier read it, committed
    /// or not; empty where the snapshot could not be written.
    pub tree: String,
    /// The worktree's HEAD when the run started; empty with no commit.
    pub head: String,
    /// The base commit a range or ci run judges from; empty for a full run.
    pub base: String,
    pub mode: ValidateMode,
    /// Why a wider mode than the declaration's narrowest was run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
    /// The caller's word: `dev`, `submit` or `restack`.
    pub caller: String,
    /// The command text the run executes, as the run's `cmd` file holds it.
    pub cmd: String,
    pub class: String,
    pub docs_only: bool,
    /// A stable digest of the changed paths the class read, one per line.
    pub paths_hash: String,
    pub scoped: bool,
    /// `all`, `subset`, `battery` or `unreported`, as the selector's preview
    /// or the command's own `validate:` line reports it.
    pub selection: String,
    pub finding_prefix: String,
    pub timeout_secs: u64,
    pub poll_secs: u64,
    pub cap_secs: u64,
    /// The class base a range or scoped run read its class from; absent
    /// for the whole branch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_base: Option<String>,
    /// Why a ci request ran locally instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ci_fallback: Option<String>,
    /// `pull_request` or `merge_group` on a ci row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ci_event: Option<String>,
    /// The class read fell back to standard: the cause.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_fallback: Option<String>,
    /// An earlier row answered this run and it ran nothing: the run
    /// directory of the pass it carries, or of the bound-ended run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reused: Option<Reused>,
}

/// The earlier run a start reused in place of running its command
/// (`dev-validate-run --help`: the `pass-run=` and `bound-run=` lines).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Reused {
    PassRun { run_dir: String },
    BoundRun { run_dir: String },
}

/// The detached job a validation run runs in, as job-unit records it:
/// the record's path from before the launcher is asked,
/// then the identity the launcher's record names. `reconcile-round` reads
/// the identity three-valued, never the child's bare pid.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidateJob {
    /// The launcher's record, `<run_dir>/runner`.
    pub record: String,
    /// `systemd`, `setsid`, `attached` where the caller's own process runs
    /// it in the foreground, or `none` where the start ran nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,
    /// The launcher's runner line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
    /// Why the launch was refused, on a stage closed `stopped` by it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

/// An item's workflow state: the fields the round operations read. Every
/// other field stays in the document, unread.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemState {
    pub dev_round_id: Option<String>,
    pub review_round_id: Option<String>,
    pub stages: Vec<Stage>,
}

impl Record for ItemState {
    fn view(path: &Path, doc: &Document) -> Result<Self> {
        Ok(ItemState {
            dev_round_id: field(path, doc, "dev_round_id")?,
            review_round_id: field(path, doc, "review_round_id")?,
            stages: field(path, doc, "stages")?.unwrap_or_default(),
        })
    }
}

/// A lane record's `status` word, as the launch, `close-lane` and the
/// watch read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LaneStatus {
    Preparing,
    Running,
    Stopped,
    Parked,
    Done,
}

impl LaneStatus {
    /// The status word as the file holds it.
    pub fn word(self) -> &'static str {
        match self {
            LaneStatus::Preparing => "preparing",
            LaneStatus::Running => "running",
            LaneStatus::Stopped => "stopped",
            LaneStatus::Parked => "parked",
            LaneStatus::Done => "done",
        }
    }

    /// A lane a launch is still on: `preparing` or `running`. A `stopped`,
    /// `parked` or `done` lane admits a relaunch, the parked one through the
    /// `parked-merged` route, in the same cap.
    pub fn in_flight(self) -> bool {
        match self {
            LaneStatus::Preparing | LaneStatus::Running => true,
            LaneStatus::Stopped | LaneStatus::Parked | LaneStatus::Done => false,
        }
    }
}

/// A deliberate, finite hold on a lane's slot in the fleet cap:
/// `reason` names why an op wrote it and `until` the ISO 8601 UTC
/// stamp it lapses at. The cap charges the lane while the hold stands, and
/// nothing else about the lane does once its harness is gone; a relaunch,
/// `release-lane` and a confirmed close drop it. Expiry never slides on a
/// read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reservation {
    pub reason: String,
    pub until: String,
}

/// A rebase obligation the admission recorded on the launching item's lane
/// record: a holder of a path the item touches whose
/// lane read stopped or held yielded the path, and the lane rebases onto
/// the holder's branch, or after it merges, before it publishes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RebaseObligation {
    /// The holder's item.
    pub holder: String,
    /// The holder's branch, where its item state records one.
    #[serde(default)]
    pub branch: Option<String>,
    /// The paths both touch, the longer of each overlapping pair.
    pub paths: Vec<String>,
    /// When the obligation was recorded.
    pub at: String,
}

/// One `lanes[]` record as read. The named fields are the ones the lane
/// operations read or write; `extra` carries the rest for a report. Only
/// `item` and `status` are required, the two every shell reader selects
/// on; a record a hand or the released launcher wrote may lack any other.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lane {
    pub item: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracker: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    /// The home the lane's last confirmed local launch ran its sessions
    /// under, as that launch prepared it; a relaunch reads the bound
    /// session there. No released writer writes it: a record without it is
    /// read by the rule the released reader used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// That launch named no home: an accountless Claude launch on its
    /// implicit default config dir, which a resume repeats.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mail_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_since: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launched_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running_at: Option<String>,
    pub status: LaneStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub over_cap: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<LaunchIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reservation: Option<Reservation>,
    /// The touched set the admission judged: the union
    /// of the item's Location paths, the brief's paths, the change-scope
    /// paths over the named range and the paths a running lane added,
    /// sorted and unique. `None` on a record the released launcher wrote
    /// with no judgement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub touched: Option<Vec<String>>,
    /// The paths the launch named in scope: a file the brief names as an
    /// append-only addition, left out of the overlap judgement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_scope: Option<Vec<String>>,
    /// The rebase obligations the admission recorded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rebase: Vec<RebaseObligation>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

// The one reading of a lane's channel the runtime makes.
impl Lane {
    /// Whether the lane runs in a Claude cloud session, reached through a
    /// directive send and no mailbox: its kind or host is the cloud kind.
    pub fn session_channel(&self) -> bool {
        let cloud = Some(crate::ops::CLOUD_KIND);
        self.kind.as_deref() == cloud || self.host.as_deref() == cloud
    }
}

/// The command of the owner whose lifecycle keeps a controller record, as
/// the record's `succession` names it: a list of words with at least one.
/// The transfer's refusal and the watch read it here alike, so a value
/// neither can run names no owner to either.
pub fn succession_command(value: Option<&Value>) -> Option<Vec<String>> {
    value?
        .as_array()?
        .iter()
        .map(|word| word.as_str().map(str::to_owned))
        .collect::<Option<Vec<String>>>()
        .filter(|words| !words.is_empty())
}

/// The operations that start an external effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EffectOp {
    LaunchLane,
    RequestTransfer,
    CloseOwnedResources,
    /// A controller's first launch, or its launch after an explicit `off`:
    /// a succession with no predecessor to retire.
    StartController,
    /// The explicit off: the controller retired exactly by
    /// identity and the record marked so no recovery relaunches it.
    StopController,
}

impl EffectOp {
    /// The operation's word, the `op` of a request.
    pub fn word(self) -> &'static str {
        match self {
            EffectOp::LaunchLane => "launch-lane",
            EffectOp::RequestTransfer => "request-transfer",
            EffectOp::CloseOwnedResources => "close-owned-resources",
            EffectOp::StartController => "start-controller",
            EffectOp::StopController => "stop-controller",
        }
    }

    /// Whether the operation moves the controller record, its target an
    /// `overseer:<generation>`.
    pub fn on_controller(self) -> bool {
        match self {
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
                true
            }
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources => false,
        }
    }
}

/// What the tracker judged the lane's item: shipped, or ended any other
/// way. The judge stays the tracker package's; the close op takes its
/// verdict as evidence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalVerdict {
    Completed,
    Canceled,
}

/// What authorizes a close to end a lane's harness, recorded on the close
/// intent so its outcome moves the record the way that ground allows.
/// `exited` and `terminal` end the lane as done;
/// `no-landing` retires the attempt alone and keeps the item's work and
/// history, the lane reading `stopped`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "ground", rename_all = "kebab-case")]
pub enum CloseGround {
    /// The recorded harness read gone when the close was asked: there is
    /// nothing live to protect.
    Exited,
    /// The tracker read the item terminal; `source` names the read.
    Terminal {
        verdict: TerminalVerdict,
        source: String,
    },
    /// An explicit disposition: the attempt ends with no landing while the
    /// item stays open, on idle-or-gone proof of its harness, or, under
    /// `interrupt`, with the harness stopped mid-turn: the session it runs
    /// is unusable (a model switch), so its idle proof is not asked for.
    /// `source` names who recorded it.
    NoLanding {
        reason: String,
        source: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        interrupt: bool,
    },
    /// The close judged the lane ended while its item stays open: its merge
    /// cycle stands and its work is over (its worktree gone, or a local
    /// lane's item closed out), or its host kind declares no
    /// stop this machine can make (a cloud session). The lane ends done
    /// whatever its harness reads, the item's files kept. `source` names the
    /// reading; [`HOST_ABSENT`] is the one that ends an item its tracker
    /// ended, whose sandbox its provider no longer holds: its files leave
    /// and no provider close is asked.
    Ended { source: String },
}

/// The [`CloseGround::Ended`] source of a terminal close whose provider
/// lists no sandbox for the item.
pub const HOST_ABSENT: &str = "host-absent";

impl CloseGround {
    /// Whether the ground is a terminal close of a sandbox its provider no
    /// longer holds.
    pub fn host_absent(&self) -> bool {
        matches!(self, CloseGround::Ended { source } if source == HOST_ABSENT)
    }

    /// Whether the close ends the item: the tracker's terminal verdict, or
    /// a terminal close of an absent sandbox. Its files leave with it.
    pub fn ends_item(&self) -> bool {
        matches!(self, CloseGround::Terminal { .. }) || self.host_absent()
    }
}

/// A merge cycle a close records on its lane when it confirms: the cycle
/// object (`lanes[].cycle`) and the lines the recorder printed, each joining
/// the fleet log as a `cycle` row in the same write.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CycleRow {
    pub cycle: Value,
    pub lines: Vec<String>,
    /// What the recorder could not read, in its own lines
    /// (`oversee-cycle: class-unread cause=`, `rounds-unread`,
    /// `merged-unread`, `negative-interval`), for the close's answer.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

impl CycleRow {
    /// The fleet-log rows of the lines, stamped `at`.
    pub fn rows(&self, item: &str, at: &str) -> Vec<Value> {
        self.lines
            .iter()
            .map(|text| serde_json::json!({"at": at, "kind": "cycle", "item": item, "text": text}))
            .collect()
    }
}

/// The harness, account, model and effort a launch was asked for. The
/// lane takes them when it records `running`, not `preparing`, so a
/// launch intent carries them until
/// its outcome confirms. `account`, `model` and `effort` left out keep the
/// record's values.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Selection {
    pub harness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Whether the launch re-enters a standing record, so a provider reuses
    /// the worktree it holds.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub relaunch: bool,
}

/// What an effect recorded around opening its window:
/// the server a window is about to open on and the floor its native session
/// is read above, every field of [`OpenedPane`] but the pane, and then the
/// pane id the creating `new-window` call printed, written before anything
/// is typed into it. A reconcile at this phase reads the pane's own receipt
/// first, else judges the recorded pane; a window neither receipted nor
/// recorded is never adopted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Opening {
    pub server: u64,
    pub server_start: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_process_start: Option<String>,
    pub socket: String,
    pub since_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub baseline: Vec<String>,
    /// The pane the effect's own `new-window` created, recorded before the
    /// launch line is typed into it; `None` until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// Whether the launcher has been asked for the window: written before
    /// `new-window` runs, so a phase with no pane and
    /// `asked` names a window possibly opened, and one without it nothing.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it: every reconcile reads the runner there, never a home
    /// resolved again in its own process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// The launch named no home ([`Lane::home_implicit`]).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
}

impl Opening {
    /// The [`OpenedPane`] this opening becomes once its window is found: the
    /// recorded server and floor with the pane, and the
    /// identity the pane's receipt proved where a reconcile adopted it.
    pub fn into_opened(&self, pane: String, identity: Option<Identity>) -> OpenedPane {
        OpenedPane {
            pane,
            server: self.server,
            server_start: self.server_start,
            server_process_start: self.server_process_start.clone(),
            socket: self.socket.clone(),
            since_ms: self.since_ms,
            brief: self.brief.clone(),
            session_id: self.session_id.clone(),
            baseline: self.baseline.clone(),
            identity,
            home: self.home.clone(),
            home_implicit: self.home_implicit,
        }
    }
}

/// The pane an effect opened and the floor its native session is read
/// above: the data every phase after `window-opened` carries. The server is
/// named by its socket, pid and start, so a reconcile observes the pane on
/// the recorded server whatever socket its own `$TMUX` names. Another
/// server answering on that socket, or no server with the recorded server
/// process gone, proves the pane gone; only an unanswering socket whose
/// server process still runs is unobservable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenedPane {
    pub pane: String,
    pub server: u64,
    pub server_start: u64,
    /// The server process's start as the one identity reader records it,
    /// read when the window opened, so a socket that stops answering can be
    /// told from a server that is gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_process_start: Option<String>,
    pub socket: String,
    /// Milliseconds since the epoch just before the window opened: the
    /// floor a native session must be created above to be this launch's.
    pub since_ms: u64,
    /// The handoff a succession holds for the runner, delivered after
    /// retirement; a launch spells its brief into the command and holds
    /// none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief: Option<String>,
    /// The session id the launch fixed on the command line, for a harness
    /// that takes one: the runner's own native file is then known by name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The lead sessions for the runner's cwd that stood before the window
    /// opened, for a harness whose launch fixes no id: the runner's own
    /// file is the one lead that appears and is absent here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub baseline: Vec<String>,
    /// The harness identity this attempt runs under, once read: the
    /// receipt's pid confirmed live at adoption, or the identity the judge
    /// read in the pane. It is the one identity every later
    /// read, publication and retirement of the attempt uses; none selects
    /// another process in its place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<Identity>,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it ([`Opening::home`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// The launch named no home ([`Lane::home_implicit`]).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
}

/// The runner's own native session file, bound once before the brief is
/// pasted: the effect and every reconcile count that file alone, never a
/// neighbour in the same home and directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundSession {
    pub session_id: String,
    pub file: String,
}

/// How far an effect got, written into its intent before each wait so a
/// `reconcile` completes the effect from the recorded step.
/// A launch reaches `window-opened` and then its outcome; a succession
/// passes `delivered` (the brief pasted while the predecessor still runs,
/// with the runner's own session file and its user-turn count before the
/// paste), retires the predecessor, which a reconcile reads from the
/// predecessor itself, and reaches `identity-read` (the runner's own
/// process identity, the last read before publication).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "kebab-case")]
pub enum Phase {
    /// Written before any window opens and again with the
    /// pane once one is created. A reconcile here adopts the
    /// pane the intent's receipt names, fails the recorded pane that never
    /// registered, or fails `nothing-opened` with neither.
    Opening {
        #[serde(flatten)]
        opening: Opening,
    },
    WindowOpened {
        #[serde(flatten)]
        opened: OpenedPane,
    },
    /// Written before the brief is typed: a reconcile
    /// that finds it reads the brief as possibly delivered and waits for the
    /// turn, never pasting again.
    Delivering {
        #[serde(flatten)]
        opened: OpenedPane,
        /// The user turns the bound file held before the paste.
        turns_before: u64,
        session: BoundSession,
        /// The lines the brief holds, as typed.
        lines: u64,
    },
    Delivered {
        #[serde(flatten)]
        opened: OpenedPane,
        /// The user turns the bound file held before the paste.
        turns_before: u64,
        session: BoundSession,
    },
    IdentityRead {
        #[serde(flatten)]
        opened: OpenedPane,
        pid: u64,
        start: String,
    },
    /// Written before a cloud session's create is asked: a create whose
    /// answer is lost, the asking process ended included, may have made a
    /// session nothing here can name, so a reconcile holds the launch
    /// rather than reading nothing opened. `answer_by` is when the create's
    /// bound ends: a session it makes may appear until then.
    CloudCreate {
        worktree: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        answer_by: Option<String>,
    },
    /// Written before a launch asks a preparation whose answer can be lost:
    /// a hosted provider's `create` (`step` `host-create`, `at` the host;
    /// the `wait` after it included), a cloud lane's worktree `create` and
    /// branch `push` (`worktree-create` at the claim root, `worktree-push`
    /// at the worktree). Its effect may stand though nothing answered. A
    /// reconcile fails a hosted create, since the provider's next create
    /// reuses what it holds, and holds a worktree step until a close
    /// settles it.
    Preparing { step: String, at: String },
}

impl Phase {
    /// The pane a phase names, or `None` at `opening`, before a window
    /// exists.
    pub fn opened(&self) -> Option<&OpenedPane> {
        match self {
            Phase::WindowOpened { opened }
            | Phase::Delivering { opened, .. }
            | Phase::Delivered { opened, .. }
            | Phase::IdentityRead { opened, .. } => Some(opened),
            Phase::Opening { .. } | Phase::CloudCreate { .. } | Phase::Preparing { .. } => None,
        }
    }
}

/// The persisted intent of one external effect: written before the effect
/// starts, its `outcome` written after. The id is
/// `<op>:<target>:<nanos>-<nonce>`, the operation's word, its target and
/// the stamp the caller's `Env` minted for the call, so two intents on one
/// target never share an id whatever the file holds. One intent per
/// target may be open; a repeated request of the same operation finds it
/// and reconciles, a request of another operation on the target refuses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    pub id: String,
    pub op: EffectOp,
    pub target: String,
    pub created_at: String,
    /// The process that persisted the intent; a reconcile
    /// that finds it live defers to it. An intent may carry none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<Owner>,
    pub outcome: Outcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// The lane's `session_since` when a lane intent was written; a lane
    /// relaunched since carries another, and the outcome is stale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_since: Option<String>,
    /// What a launch intent writes on the lane when its outcome confirms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<Selection>,
    /// The `overseer.pending` a transfer request overwrote, put back when
    /// the transfer fails.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_pending: Option<Value>,
    /// Why a transfer was asked for; a reconcile reads it to know what
    /// proves the predecessor terminal. Absent on the other
    /// operations and on a transfer recorded without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<TransferCause>,
    /// The owner that persisted the intent and handed it to the detached
    /// job that now owns it, written by the claim: the job
    /// lets that process answer and exit before it retires the pane the
    /// process asked from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handed_from: Option<Owner>,
    /// The account a wall relaunch must not run on, canonical, recorded on
    /// the launch intent that refused it. Absent elsewhere.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude_account: Option<String>,
    /// The fleet watch's launch line a start carries: `orch-runtime watch
    /// run` and its arguments, which the start's effect
    /// launches through the job launcher once the controller's lane is
    /// confirmed, and a reconcile launches again where no watch claims.
    /// Absent on the other operations and on a start whose caller holds
    /// the watch's start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watch: Option<Vec<String>>,
    /// What authorized a close; its confirmed outcome
    /// moves the lane as that ground allows. Absent on the other operations
    /// and on a close recorded without one, which ends the lane
    /// as done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close: Option<CloseGround>,
    /// The merge cycle a close writes on its lane when it confirms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle: Option<CycleRow>,
    /// The failure the detached job's outcome announced:
    /// the fleet-log row and the owner notice,
    /// sent once per intent and recorded here so a repeated
    /// reconcile of the same outcome emits nothing again. Absent until an
    /// outcome of a transfer or a stop failed or stayed unconfirmed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
    /// How far the effect got, written before each wait; a
    /// reconciliation completes the effect from it. Absent until the effect
    /// has opened something.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<Phase>,
    /// The obligations the effect stands under: every
    /// handle it acquired, written before the wait that follows the
    /// acquisition, with the discharges made so far and whether anything was
    /// signalled. Every later step and every reconcile reads this set and
    /// never rebuilds it from the lane or the phase. Absent on an intent
    /// recorded without it; its next step writes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obligations: Option<ObligationRecord>,
    /// What the effect last observed of its target: the pane it opened or
    /// found, the process and screen it read, and for a succession whether
    /// the predecessor was retired. A reconciliation re-observes from it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observation: Option<Value>,
    /// Set when the intent was closed because its target's record moved
    /// under it, with the status or generation the record then read; the
    /// outcome word stays what the effect reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reconciled: Option<Reconciled>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_status: Option<LaneStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_generation: Option<u64>,
    /// Members the intent's frame does not own, such as the lane
    /// operation's own obligation set, kept as written across every write
    /// of the frame.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}

/// One recorded handle of an operation's target, typed by what it is. A
/// pane and a window carry the server's pid and
/// tmux start, the only form this host addresses a pane in; a lane record
/// the released launcher wrote carries the pid alone, so
/// its pane's start is unknown and `None`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Obligation {
    /// A process identity (pid and start) the record names or the effect
    /// read.
    Process(Identity),
    /// A pid recorded with no start: no identity reads it, but a pid nothing
    /// holds proves the recorded process gone.
    Pid { pid: u32 },
    Pane {
        pane: String,
        server: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        server_start: Option<u64>,
    },
    /// A pane recorded with no server, which a record may carry: this
    /// host cannot address it, and the record does not prove it absent.
    PaneUnaddressed { pane: String },
    /// A launcher was asked for a window on this server and no pane id was
    /// recorded yet: a window possibly opened.
    Window { server: u64, server_start: u64 },
    /// The pane's receipt was armed: an obligation until read.
    Receipt,
    /// The job launcher was asked and its record not yet read: a job
    /// possibly started. `record` is the launcher record's path
    /// the ask named, the one address the record is read at:
    /// the intent's own job record for a transfer or a stop, the
    /// watch's runner record beside the fleet state for a start's watch.
    JobSidecar { record: String },
    /// The detached job runs as this transient user unit.
    JobUnit { unit: String },
    /// The detached job leads this process group, by the identity its child
    /// wrote before it ran.
    JobGroup(Identity),
    /// The detached job by its group key alone: the launcher ended the launch
    /// `unwound-failed` without reading the leader's start, and the key is
    /// read in the kernel's table, the child whose pid it is and every member
    /// of its group, until neither stands.
    JobPgid { pgid: u32 },
}

/// The part a recorded handle plays in its intent: the target's own harness
/// and pane, the runner a succession opens, the predecessor it retires, the
/// detached job, or an auxiliary process the opener names beside the
/// harness. A selection from the set reads the role and never the target's
/// record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    Harness,
    Runner,
    Predecessor,
    Job,
    Auxiliary,
}

/// One standing obligation as the record holds it: the handle, flattened
/// under its `kind`, its role, and, under the harness role, the harness
/// kind the lane ran when the handle was acquired: what
/// names the processes below the recorded root that a stop may signal,
/// never the harness a relaunched session runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Held {
    #[serde(flatten)]
    pub obligation: Obligation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<Harness>,
}

/// An obligation settled, with the evidence word that settled it, the role
/// it held and the harness kind recorded on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Discharged {
    pub obligation: Obligation,
    pub by: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<Harness>,
}

/// The durable obligation set of an intent: what stands,
/// what was discharged and by what, and whether the effect has signalled
/// anything, after which no refusal is expressible on the intent. `revision`
/// counts the set's replacements: the store advances it on every write that
/// changes the set, and a handle whose write names an older revision is
/// refused `set-replaced`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ObligationRecord {
    #[serde(default)]
    pub standing: Vec<Held>,
    #[serde(default)]
    pub discharged: Vec<Discharged>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub signalled: bool,
    /// Independent stale readings per recorded identity (`pid:start`), one
    /// per run that read the pid live under another start; the second
    /// settles the identity.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub stale: std::collections::BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub revision: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// The keys a terminal carries for its target's record: the target's stamp
/// when the intent was written and every identity, pid and pane key the
/// intent's set recorded under the principal's role. The store applies a
/// terminal to the target only when the target's record names nothing but
/// these.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrincipalKeys {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keys: Vec<Obligation>,
}

/// What a lane's `launch` record names as obligations: a pane with its
/// server, else the pane unaddressable; an identity with its start, else
/// the pid alone. The one reading of a launch record both the store's
/// moved-lane judgement and the handle's bootstrap take.
pub fn launch_obligations(launch: Option<&LaunchIdentity>) -> Vec<Obligation> {
    let Some(launch) = launch else {
        return Vec::new();
    };
    let mut named = Vec::new();
    match (&launch.pane, launch.server) {
        (Some(pane), Some(server)) => named.push(Obligation::Pane {
            pane: pane.clone(),
            server,
            server_start: launch.server_start,
        }),
        (Some(pane), None) => named.push(Obligation::PaneUnaddressed { pane: pane.clone() }),
        (None, Some(_) | None) => {}
    }
    match (
        launch.pid.and_then(|pid| u32::try_from(pid).ok()),
        &launch.start,
    ) {
        (Some(pid), Some(start)) => named.push(Obligation::Process(Identity {
            pid,
            start: start.clone(),
        })),
        (Some(pid), None) => named.push(Obligation::Pid { pid }),
        (None, _) => {}
    }
    named
}

impl ObligationRecord {
    /// Move every standing obligation `which` selects to the discharged set
    /// under `by`, each keeping its role; how many moved.
    pub fn discharge_where(&mut self, which: impl Fn(&Obligation) -> bool, by: &str) -> usize {
        let (moved, kept): (Vec<Held>, Vec<Held>) = std::mem::take(&mut self.standing)
            .into_iter()
            .partition(|h| which(&h.obligation));
        self.standing = kept;
        let count = moved.len();
        self.discharged
            .extend(moved.into_iter().map(|held| Discharged {
                obligation: held.obligation,
                by: by.to_owned(),
                role: held.role,
                harness: held.harness,
            }));
        count
    }

    /// The harness kind recorded under the harness role, standing or
    /// discharged.
    pub fn recorded_harness(&self) -> Option<Harness> {
        self.standing
            .iter()
            .filter(|h| h.role == Some(Role::Harness))
            .find_map(|h| h.harness)
            .or_else(|| {
                self.discharged
                    .iter()
                    .filter(|d| d.role == Some(Role::Harness))
                    .find_map(|d| d.harness)
            })
    }

    /// Whether `obligation` stands.
    pub fn stands(&self, obligation: &Obligation) -> bool {
        self.standing.iter().any(|h| h.obligation == *obligation)
    }

    /// Whether the record carries `obligation`, standing or discharged.
    pub fn holds(&self, obligation: &Obligation) -> bool {
        self.stands(obligation) || self.discharged.iter().any(|d| d.obligation == *obligation)
    }

    /// The role `obligation` holds or held, where the record names one.
    pub fn role_of(&self, obligation: &Obligation) -> Option<Role> {
        self.standing
            .iter()
            .find(|h| h.obligation == *obligation)
            .and_then(|h| h.role)
            .or_else(|| {
                self.discharged
                    .iter()
                    .find(|d| d.obligation == *obligation)
                    .and_then(|d| d.role)
            })
    }

    /// Every standing obligation, in record order.
    pub fn standing_obligations(&self) -> impl Iterator<Item = &Obligation> {
        self.standing.iter().map(|h| &h.obligation)
    }

    /// Whether the two records hold the same set: everything but the
    /// revision the store assigns.
    pub fn same_set(&self, other: &ObligationRecord) -> bool {
        self.standing == other.standing
            && self.discharged == other.discharged
            && self.signalled == other.signalled
            && self.stale == other.stale
    }

    /// The keys the record holds under `role`, standing or discharged:
    /// every process, pid and pane key.
    pub fn principal_keys(&self, role: Role) -> Vec<Obligation> {
        self.standing_obligations()
            .chain(self.discharged.iter().map(|d| &d.obligation))
            .filter(|o| self.role_of(o) == Some(role))
            .filter(|o| match o {
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. } => true,
                Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. } => false,
            })
            .cloned()
            .collect()
    }

    /// Whether `obligation` is a detached job's handle or its unread record.
    pub fn is_job(obligation: &Obligation) -> bool {
        matches!(
            obligation,
            Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. }
        )
    }
}

impl Intent {
    /// Whether the effect may still be in flight: its outcome is not final
    /// and no reconciliation closed it.
    pub fn open(&self) -> bool {
        if self.reconciled.is_some() {
            return false;
        }
        match self.outcome {
            Outcome::NotStarted | Outcome::Unconfirmed => true,
            Outcome::Confirmed | Outcome::Failed => false,
        }
    }
}

/// The verdict words the watch rebuilds its acknowledged triage keys from.
pub const ACKNOWLEDGED_VERDICTS: &[&str] = &["kept", "canceled"];

/// The fleet state: the fields the lane, overseer and intent operations
/// read. `triaged` rows stay untyped: a row may be a string or carry an
/// `item` key, and the watch reads such rows without refusing
/// the file.
#[derive(Debug, Clone, PartialEq)]
pub struct FleetState {
    pub lanes: Vec<Lane>,
    pub overseer: Option<Overseer>,
    pub fleet_log: Vec<Value>,
    pub triaged: Vec<Value>,
    pub launch_queue: Vec<String>,
    pub intents: Vec<Intent>,
}

impl FleetState {
    /// The issue keys the watch reads as acknowledged: `issue` of every
    /// object row whose verdict is `kept` or `canceled`. A string row or an
    /// `item`-keyed row names no key and is skipped.
    pub fn acknowledged_issues(&self) -> Vec<String> {
        self.triaged
            .iter()
            .filter_map(|row| {
                let verdict = row.get("verdict")?.as_str()?;
                if !ACKNOWLEDGED_VERDICTS.contains(&verdict) {
                    return None;
                }
                row.get("issue")?.as_str().map(str::to_owned)
            })
            .collect()
    }
}

impl Record for FleetState {
    fn view(path: &Path, doc: &Document) -> Result<Self> {
        Ok(FleetState {
            lanes: field(path, doc, "lanes")?.unwrap_or_default(),
            overseer: field(path, doc, "overseer")?,
            fleet_log: field(path, doc, "fleet_log")?.unwrap_or_default(),
            triaged: field(path, doc, "triaged")?.unwrap_or_default(),
            launch_queue: field(path, doc, "launch_queue")?.unwrap_or_default(),
            intents: field(path, doc, "intents")?.unwrap_or_default(),
        })
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// Read a state file. The reader refuses what the shell readers refuse on
/// the same file: unparsable bytes (`json-invalid`), a non-object, a
/// `launch_queue` entry that is not a string (`record-shape`), and a file
/// stamped with `record_version` or `revision` (`record-stamped`). Every
/// other field is read when an operation needs it.
#[allow(
    clippy::disallowed_methods,
    reason = "the one reader of a state file, whose typed snapshot every transition and effect reads"
)]
pub fn load(path: &Path) -> Result<Option<Snapshot>> {
    let Some(doc) = record::read_document(path)? else {
        return Ok(None);
    };
    let kind = Kind::of_path(path);
    if kind == Kind::Fleet {
        // The one field a fleet read refuses the whole file on.
        field::<Vec<String>>(path, &doc, "launch_queue")?;
    }
    Ok(Some(Snapshot { kind, doc }))
}

fn validate(path: &Path, snapshot: &Snapshot) -> Result<()> {
    match snapshot.kind {
        Kind::Item => snapshot.view::<ItemState>(path).map(|_| ()),
        Kind::Fleet => snapshot.view::<FleetState>(path).map(|_| ()),
    }
}

// ---------------------------------------------------------------------------
// Initialization and inspection
// ---------------------------------------------------------------------------

/// What `workflow-state init` takes beside the item: the fields a caller
/// knows at creation, each written empty where it names none.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct InitFields {
    pub agent: String,
    pub worktree: String,
    pub branch: String,
    /// JSON, `[]` when unnamed.
    pub qa_labels: Option<Value>,
    /// JSON, `[]` when unnamed.
    pub sub_issues: Option<Value>,
}

/// The object `workflow-state init` writes (`cmd_init`), key for key and in
/// its order. `issue_id` is the item, or `oversee` for the fleet state.
pub fn init_document(issue_id: &str, fields: &InitFields) -> Document {
    let value = serde_json::json!({
        "issue_id": issue_id,
        "sub_issues": fields.sub_issues.clone().unwrap_or_else(|| Value::Array(Vec::new())),
        "agent": fields.agent,
        "worktree": fields.worktree,
        "branch": fields.branch,
        "qa_labels": fields.qa_labels.clone().unwrap_or_else(|| Value::Array(Vec::new())),
        "near_ceiling": [],
        "finding_occurrences": {"prior": "none", "records": []},
        "child_sessions": {},
        "review_agents": [],
        "review_agent_ids": {},
        "review_agent_runtime_types": {},
        "pre_delegate_sha": Value::Null,
        "skip_qa": false,
        "cycles": 0,
        "rereview_cycles": 0,
        "json_paths": [],
        "fixed_items": [],
        "escalated_items": [],
        "audit_issues_created": [],
        "pr_review_baseline": Value::Null,
        "pr_comment_review": {
            "iterations": 0,
            "fixes": [],
            "issues_created": [],
            "skipped": []
        },
        "post_pr_budgets": {
            "review_wait": Value::Null,
            "ci_fix": Value::Null
        },
        "post_pr_stop": Value::Null
    });
    match value {
        Value::Object(doc) => doc,
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) | Value::Array(_) => {
            unreachable!("the literal above is an object")
        }
    }
}

/// A state file created.
#[derive(Debug, Clone, Serialize)]
pub struct Initialized {
    pub path: PathBuf,
    pub kind: Kind,
}

/// Create the state file at `path` with the init object, as `cmd_init`
/// writes it: the directory made, the file created exclusively and refused
/// `state-exists` where one already stands, the object pretty-printed with
/// jq's two-space indent and final newline, in the shape the shell writers
/// read.
#[allow(
    clippy::disallowed_methods,
    reason = "the one creation of a state file, exclusive, for the `state init` command"
)]
pub fn init(path: &Path, fields: &InitFields) -> Result<Initialized> {
    let kind = Kind::of_path(path);
    let issue_id = match kind {
        Kind::Fleet => "oversee".to_owned(),
        Kind::Item => path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_prefix("workflow-state-"))
            .and_then(|n| n.strip_suffix(".json"))
            .map(str::to_owned)
            .ok_or_else(|| {
                agent_runtime::Error::refused(
                    "state-path-invalid",
                    &[("path", &path.display().to_string())],
                )
            })?,
    };
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| agent_runtime::Error::io("mkdir", dir, e))?;
    }
    let mut file = match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(agent_runtime::Error::refused(
                "state-exists",
                &[("path", &path.display().to_string())],
            )
            .into());
        }
        Err(e) => return Err(agent_runtime::Error::io("create", path, e).into()),
    };
    let mut text = serde_json::to_string_pretty(&Value::Object(init_document(&issue_id, fields)))
        .map_err(|source| agent_runtime::Error::Json {
        path: path.to_path_buf(),
        source,
    })?;
    text.push('\n');
    file.write_all(text.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| agent_runtime::Error::io("write", path, e))?;
    Ok(Initialized {
        path: path.to_path_buf(),
        kind,
    })
}

/// A read-only view of a state file for diagnostics and compatibility.
#[derive(Debug, Clone, Serialize)]
pub struct Inspection {
    pub path: PathBuf,
    pub kind: Kind,
    /// The object exactly as the file holds it.
    pub state: Value,
    /// The fleet's intents whose effect may still be in flight, as this
    /// runtime judges them (`Intent::open`): a reader that must know whether
    /// an operation stands on a target takes the judgement from here rather
    /// than from the outcome words. Empty on an item file.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub open_intents: Vec<Intent>,
}

/// Read every typed field of the file by its kind and return it unchanged.
#[allow(
    clippy::disallowed_methods,
    reason = "the inspection's one read of the state file, for the `state inspect` command"
)]
pub fn inspect(path: &Path) -> Result<Inspection> {
    let Some(snapshot) = load(path)? else {
        return Err(Error::Runtime(agent_runtime::Error::RecordMissing {
            path: path.to_path_buf(),
        }));
    };
    validate(path, &snapshot)?;
    let open_intents = match snapshot.kind {
        Kind::Fleet => snapshot
            .view::<FleetState>(path)?
            .intents
            .into_iter()
            .filter(Intent::open)
            .collect(),
        Kind::Item => Vec::new(),
    };
    Ok(Inspection {
        path: path.to_path_buf(),
        kind: snapshot.kind,
        state: Value::Object(snapshot.doc),
        open_intents,
    })
}

#[cfg(test)]
pub(crate) mod fixtures {
    //! The samples in the shell writers' shape, checked in beside the
    //! integration harness and shared with it.
    pub const ITEM: &str = include_str!("../../tests/rust/fixtures/workflow-state-KEN-4687.json");
    pub const FLEET: &str = include_str!("../../tests/rust/fixtures/workflow-state-oversee.json");

    /// The init fields a standing record may lack: one written before the
    /// init object named them still loads, since nothing re-initializes a
    /// standing record.
    pub const LATER_INIT_FIELDS: &[&str] = &[
        "finding_occurrences",
        "near_ceiling",
        "post_pr_budgets",
        "post_pr_stop",
    ];

    /// `text` without the keys in `LATER_INIT_FIELDS`, serialized the way
    /// this runtime writes, so a byte comparison after an unchanged store
    /// is exact.
    pub fn without_init_fields(text: &str) -> String {
        let serde_json::Value::Object(mut map) = serde_json::from_str(text).unwrap() else {
            panic!("fixture is not an object")
        };
        for key in LATER_INIT_FIELDS {
            assert!(map.shift_remove(*key).is_some(), "{key} in the fixture");
        }
        let mut out = serde_json::to_string_pretty(&serde_json::Value::Object(map)).unwrap();
        out.push('\n');
        out
    }

    /// The surface-2 lane record `workflows/oversee.md` has the overseer
    /// append by hand, in its key order.
    pub const HAND_WRITTEN_LANE: &str = r#"{"item":"KEN-4500","tracker":"linear","repo":null,"harness":"codex","window":null,"account":null,"host":null,"mail_root":"/home/u/dev/.worktrees/kendex/ken-4500","surface":"gui","model":"gpt-5.5-codex","session_id":null,"launched_at":"2026-10-24T19:00:00Z","status":"running","obligation":null}"#;
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows measure the store's real lock waits"
)]
#[cfg(test)]
mod tests {
    use super::*;
    use agent_runtime::record::{Locking, array_mut, element_mut, object_mut, set};

    fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, text).unwrap();
        path
    }

    fn object(path: &Path) -> Document {
        match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
            Value::Object(map) => map,
            other => panic!("not an object: {other}"),
        }
    }

    fn keys(doc: &Document) -> Vec<String> {
        doc.keys().cloned().collect()
    }

    fn snapshot(path: &Path) -> Snapshot {
        load(path).unwrap().unwrap()
    }

    #[test]
    fn the_fleet_file_name_selects_the_fleet_kind() {
        let rows = [
            ("tmp/workflow-state-oversee.json", Kind::Fleet),
            ("tmp/workflow-state-KEN-1.json", Kind::Item),
            ("tmp/workflow-state-issue-12.json", Kind::Item),
        ];
        for (path, kind) in rows {
            assert_eq!(Kind::of_path(Path::new(path)), kind, "{path}");
        }
    }

    /// A file an older init wrote lacks the newest init
    /// fields and still reads and stores.
    #[test]
    fn a_file_missing_the_newer_init_fields_reads_and_stores() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            ("workflow-state-KEN-4687.json", fixtures::ITEM),
            (FLEET_FILE_NAME, fixtures::FLEET),
        ];
        for (name, text) in rows {
            let uninitialized = fixtures::without_init_fields(text);
            let path = write(dir.path(), name, &uninitialized);
            let s = snapshot(&path);
            validate(&path, &s).unwrap();
            for key in fixtures::LATER_INIT_FIELDS {
                assert!(!s.doc.contains_key(*key), "{name}: {key}");
            }
            // An unchanged store writes the same bytes back.
            record::store(&path, &s.doc, &s.doc, Locking::FLOCK).unwrap();
            assert_eq!(fs::read_to_string(&path).unwrap(), uninitialized, "{name}");
            inspect(&path).unwrap();
        }
    }

    /// A store on either
    /// kind of file keeps the full top-level key sequence and every nested
    /// key sequence; it adds no key and reorders none.
    #[test]
    fn a_store_keeps_every_key_sequence_and_adds_no_key() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            ("workflow-state-KEN-4687.json", fixtures::ITEM),
            (FLEET_FILE_NAME, fixtures::FLEET),
        ];
        for (name, text) in rows {
            let path = write(dir.path(), name, text);
            let before = object(&path);
            let s = snapshot(&path);
            // The patch an operation makes: one top-level key, one nested.
            let mut doc = s.doc.clone();
            set(&mut doc, "cycles", 5);
            match Kind::of_path(&path) {
                Kind::Item => {
                    let stages = array_mut(&path, &mut doc, "stages").unwrap();
                    set(element_mut(&path, stages, 0, "stages").unwrap(), "end", 1);
                }
                Kind::Fleet => {
                    let lanes = array_mut(&path, &mut doc, "lanes").unwrap();
                    set(
                        element_mut(&path, lanes, 0, "lanes").unwrap(),
                        "status",
                        "stopped",
                    );
                    set(
                        object_mut(&path, &mut doc, "overseer").unwrap(),
                        "generation",
                        4,
                    );
                }
            }
            record::store(&path, &s.doc, &doc, Locking::FLOCK).unwrap();
            let after = object(&path);
            assert_eq!(
                keys(&after),
                keys(&before),
                "{name}: top-level key sequence"
            );
            assert_eq!(after["cycles"], Value::from(5), "{name}");
            for (key, value) in &before {
                if key == "cycles" || key == "stages" || key == "lanes" || key == "overseer" {
                    continue;
                }
                assert_eq!(&after[key], value, "{name}: {key}");
            }
            match Kind::of_path(&path) {
                Kind::Item => {
                    let (b, a) = (
                        before["stages"][0].as_object().unwrap(),
                        after["stages"][0].as_object().unwrap(),
                    );
                    assert_eq!(keys(a), keys(b), "{name}: stage key sequence");
                    assert_eq!(a["end"], Value::from(1));
                }
                Kind::Fleet => {
                    let (b, a) = (
                        before["lanes"][0].as_object().unwrap(),
                        after["lanes"][0].as_object().unwrap(),
                    );
                    assert_eq!(keys(a), keys(b), "{name}: lane key sequence");
                    assert_eq!(a["status"], Value::from("stopped"));
                    let (b, a) = (
                        before["overseer"].as_object().unwrap(),
                        after["overseer"].as_object().unwrap(),
                    );
                    assert_eq!(keys(a), keys(b), "{name}: overseer key sequence");
                    assert_eq!(a["generation"], Value::from(4));
                    let (b, a) = (
                        before["triaged"][0].as_object().unwrap(),
                        after["triaged"][0].as_object().unwrap(),
                    );
                    assert_eq!(keys(a), keys(b), "{name}: triaged row key sequence");
                }
            }
        }
    }

    /// A hand-written lane without the
    /// launcher's optional fields and an overseer without `generation` gain
    /// no key through a store that patches beside them.
    #[test]
    fn absent_optional_fields_stay_absent_through_a_store() {
        let dir = tempfile::tempdir().unwrap();
        let text = fixtures::FLEET.replacen(
            "\"lanes\": [\n",
            &format!("\"lanes\": [\n    {},\n", fixtures::HAND_WRITTEN_LANE),
            1,
        );
        let text = text.replacen("    \"generation\": 3,\n", "", 1);
        let path = write(dir.path(), FLEET_FILE_NAME, &text);
        let before = object(&path);
        let hand_keys: Vec<String> = keys(before["lanes"][0].as_object().unwrap());
        assert_eq!(hand_keys[0], "item");
        assert!(!hand_keys.contains(&"kind".to_owned()));
        let s = snapshot(&path);
        let fleet = s.view::<FleetState>(&path).unwrap();
        assert_eq!(fleet.lanes[0].kind, None);
        assert_eq!(fleet.lanes[0].status, LaneStatus::Running);
        assert_eq!(fleet.overseer.as_ref().unwrap().generation, None);
        let mut doc = s.doc.clone();
        let lanes = array_mut(&path, &mut doc, "lanes").unwrap();
        set(
            element_mut(&path, lanes, 1, "lanes").unwrap(),
            "status",
            "stopped",
        );
        record::store(&path, &s.doc, &doc, Locking::FLOCK).unwrap();
        let after = object(&path);
        assert_eq!(keys(after["lanes"][0].as_object().unwrap()), hand_keys);
        assert_eq!(
            keys(after["overseer"].as_object().unwrap()),
            keys(before["overseer"].as_object().unwrap())
        );
        assert!(after["overseer"].get("generation").is_none());
        assert_eq!(after["lanes"][1]["status"], Value::from("stopped"));
    }

    /// `triaged` rows with an `item` key or a
    /// bare string read as the watch reads them, never refusing the file.
    #[test]
    fn released_triaged_rows_are_admitted_and_read_as_the_watch_reads_them() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), FLEET_FILE_NAME, fixtures::FLEET);
        let s = snapshot(&path);
        let fleet = s.view::<FleetState>(&path).unwrap();
        assert_eq!(
            fleet.triaged.len(),
            3,
            "the fixture plants the three row shapes"
        );
        assert!(fleet.triaged[1].get("item").is_some());
        assert!(fleet.triaged[2].is_string());
        assert_eq!(fleet.acknowledged_issues(), vec!["KEN-4411".to_owned()]);
        inspect(&path).unwrap();
    }

    /// Unparsable bytes are `json-invalid`; a
    /// shape this build cannot read is `record-shape`, naming the field.
    #[test]
    fn malformed_input_refuses_by_cause_without_touching_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let rows: [(&str, String, &str, Option<&str>); 5] = [
            (
                "truncated",
                "{\"issue_id\": \"KEN-1\",".to_owned(),
                "json-invalid",
                None,
            ),
            (
                "not-an-object",
                "[1, 2]".to_owned(),
                "record-shape",
                Some(""),
            ),
            (
                "stage-start-text",
                fixtures::ITEM.replacen("\"start\": 1769600000", "\"start\": \"soon\"", 1),
                "record-shape",
                Some("stages"),
            ),
            (
                "unknown-lane-status",
                fixtures::FLEET.replacen("\"done\"", "\"closing\"", 1),
                "record-shape",
                Some("lanes"),
            ),
            (
                "launch-queue-number",
                fixtures::FLEET.replacen("\"KEN-4470\"", "4470", 1),
                "record-shape",
                Some("launch_queue"),
            ),
        ];
        for (name, text, key, field) in rows {
            let file = if name.contains("lane") || name.contains("launch-queue") {
                FLEET_FILE_NAME.to_owned()
            } else {
                format!("workflow-state-{name}.json")
            };
            let path = write(dir.path(), &file, &text);
            let before = fs::read(&path).unwrap();
            let err = inspect(&path).unwrap_err();
            assert_eq!(err.key(), key, "{name}");
            if let Some(expected) = field {
                let Error::Runtime(agent_runtime::Error::RecordShape { field, .. }) = &err else {
                    panic!("{name}: {err:?}")
                };
                assert_eq!(field, expected, "{name}");
            }
            assert_eq!(fs::read(&path).unwrap(), before, "{name}");
        }
        // The one field `load` itself reads on a fleet file.
        let path = write(
            dir.path(),
            FLEET_FILE_NAME,
            &fixtures::FLEET.replacen("\"KEN-4470\"", "4470", 1),
        );
        assert_eq!(load(&path).unwrap_err().key(), "record-shape");
        // A missing init field is not a shape.
        let path = write(
            dir.path(),
            "workflow-state-KEN-1.json",
            "{\"issue_id\": \"KEN-1\"}",
        );
        validate(&path, &snapshot(&path)).unwrap();
    }

    #[test]
    fn a_missing_file_reads_as_none_and_inspects_as_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workflow-state-KEN-1.json");
        assert!(load(&path).unwrap().is_none());
        assert_eq!(inspect(&path).unwrap_err().key(), "record-missing");
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}
