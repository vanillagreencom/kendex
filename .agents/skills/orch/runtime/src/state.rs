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

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use agent_runtime::controller::Overseer;
use agent_runtime::intent::{Intent, LaunchIdentity, Notice};
use agent_runtime::record::{self, Document, FLEET_FILE_NAME, field};
use serde::de::DeserializeOwned;
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
    /// A group that is not the last committed its work and passed it to
    /// the group after it, which owns validation: no acceptance is claimed.
    HandedOver,
    /// The round's run failed only on checks the exception its round began
    /// with excuses; the run keeps its own `fail`.
    PassExcused,
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
            StageOutcome::HandedOver => "handed-over",
            StageOutcome::PassExcused => "pass-excused",
        }
    }
}

/// Known failures a round may end with, granted by the delegating side
/// when the round begins: the authority and the exact checks excused. A
/// worker cites the exception its round began with and never grants one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Exception {
    #[serde(flatten)]
    pub authorization: Authorization,
    pub excused: BTreeSet<String>,
}

impl Exception {
    /// The exception a file holds, refused `exception-invalid` where it is
    /// not one.
    pub fn read(path: &Path) -> Result<Exception> {
        let invalid = |cause: String| {
            agent_runtime::Error::refused(
                "exception-invalid",
                &[("path", &path.display().to_string()), ("cause", &cause)],
            )
        };
        let text = fs::read_to_string(path).map_err(|e| invalid(e.kind().to_string()))?;
        let exception: Exception =
            serde_json::from_str(&text).map_err(|e| invalid(e.to_string()))?;
        exception.check().map_err(invalid)?;
        Ok(exception)
    }

    /// An exception excuses at least one check, each named as a
    /// receipt's `FAILING:` list names it.
    pub fn check(&self) -> std::result::Result<(), String> {
        if self.authorization.id.trim().is_empty() {
            return Err("id=empty".into());
        }
        if self.excused.is_empty() {
            return Err("excused=empty".into());
        }
        match self
            .excused
            .iter()
            .find(|name| name.is_empty() || name.trim() != name.as_str() || name.contains(','))
        {
            Some(name) => Err(format!("excused={name:?}")),
            None => Ok(()),
        }
    }
}

/// A round's place among the groups its delegating side runs one after
/// another: group `n` of `of`, counted from 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoundGroup {
    pub n: u32,
    pub of: u32,
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
    #[serde(default)]
    pub group: Option<RoundGroup>,
    #[serde(default)]
    pub exception: Option<Exception>,
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

/// A landing whose outcome the close could not record, given up by an
/// authority with its reason: the one way a close ends a lane over a merge
/// cycle it could not write or merged boxes it could not settle. It names
/// what it gives up, and the close writes it once, as the fleet log's
/// `landing-disposed` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LandingDisposal {
    #[serde(flatten)]
    pub authority: Authorization,
    pub reason: String,
    pub of: Disposed,
}

/// What a landing's disposal gives up: the merge cycle's record, the merged
/// item's box completion, or both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Disposed {
    Record,
    Boxes,
    Both,
}

impl Disposed {
    pub fn record(self) -> bool {
        matches!(self, Disposed::Record | Disposed::Both)
    }

    pub fn boxes(self) -> bool {
        matches!(self, Disposed::Boxes | Disposed::Both)
    }
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

    /// Whether the lane's sandbox is a provider's, which the provider's own
    /// close ends: a record naming a host that is not the cloud kind.
    pub fn provider_hosted(&self) -> bool {
        self.host.as_deref().is_some_and(|h| !h.is_empty())
            && self.kind.as_deref() != Some(crate::ops::CLOUD_KIND)
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
        /// The wait a park asked for, whose sandbox stop follows this
        /// close: the park stays owed on the lane until that stop confirms.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        park: Option<crate::ops::ParkWait>,
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

/// The lane field, and the failed launch's observation member it is
/// written from, that names a sandbox its provider answered as started or
/// created, or that a no-landing close kept, and no close or park has
/// confirmed gone (`standing`): the lane keeps its slot until a confirmed
/// close, park or launch.
pub const SANDBOX: &str = "sandbox";
pub const STANDING: &str = "standing";

/// The lane field holding the wait a park asked for whose sandbox stop has
/// not confirmed: a stopped lane whose sandbox stands because its park
/// failed, told apart from one an operator kept.
pub const PARK_OWED: &str = "park_owed";

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

/// The members of an intent row that are a lane's: orch's one typed view of
/// them, read from and written to the members the intent's frame keeps as
/// written. A lane intent's own writes go through [`LaneMembers::write`]; no
/// other code reads or writes these keys of an intent.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LaneMembers {
    /// The lane's `session_since` when a lane intent was written; a lane
    /// relaunched since carries another, and the outcome is stale.
    pub lane_since: Option<String>,
    /// What a launch intent writes on the lane when its outcome confirms.
    pub selection: Option<Selection>,
    /// The account a wall relaunch must not run on, canonical, recorded on
    /// the launch intent that refused it. Absent elsewhere.
    pub exclude_account: Option<String>,
    /// What authorized a close; its confirmed outcome
    /// moves the lane as that ground allows. Absent on the other operations
    /// and on a close recorded without one, which ends the lane
    /// as done.
    pub close: Option<CloseGround>,
    /// The merge cycle a close writes on its lane when it confirms.
    pub cycle: Option<CycleRow>,
    /// The landing a close gave up, written as its fleet-log row when it
    /// confirms.
    pub disposed: Option<LandingDisposal>,
    /// The lane status an outcome read when the lane had moved under its
    /// intent.
    pub observed_status: Option<LaneStatus>,
}

impl LaneMembers {
    /// The lane members `intent` records. A member that is not its type
    /// refuses `record-shape` naming it.
    pub fn of(path: &Path, intent: &Intent) -> Result<LaneMembers> {
        let row = &intent.extra;
        Ok(LaneMembers {
            lane_since: field(path, row, "lane_since")?,
            selection: field(path, row, "selection")?,
            exclude_account: field(path, row, "exclude_account")?,
            close: field(path, row, "close")?,
            cycle: field(path, row, "cycle")?,
            disposed: field(path, row, "disposed")?,
            observed_status: field(path, row, "observed_status")?,
        })
    }

    /// Write the members onto `row`, an intent's kept members or its row in
    /// the record: a member set is written in place, or appended where the
    /// row lacks it; a member unset removes a value the row holds. A view
    /// written back unchanged leaves the row as it was.
    pub fn write(&self, row: &mut Document) -> Result<()> {
        put(row, "lane_since", self.lane_since.as_ref())?;
        put(row, "selection", self.selection.as_ref())?;
        put(row, "exclude_account", self.exclude_account.as_ref())?;
        put(row, "close", self.close.as_ref())?;
        put(row, "cycle", self.cycle.as_ref())?;
        put(row, "disposed", self.disposed.as_ref())?;
        put(row, "observed_status", self.observed_status.as_ref())
    }
}

/// Write one member: a value the row already holds as the same member, in
/// whatever spelling, is left as it is.
fn put<T>(row: &mut Document, key: &str, value: Option<&T>) -> Result<()>
where
    T: Serialize + DeserializeOwned + PartialEq,
{
    let held = row
        .get(key)
        .filter(|held| !held.is_null())
        .and_then(|held| serde_json::from_value::<T>(held.clone()).ok());
    if held.as_ref() == value {
        return Ok(());
    }
    match value {
        Some(value) => record::set(row, key, serde_json::to_value(value)?),
        None => {
            record::delete(row, key);
        }
    }
    Ok(())
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
        queue_read(path, &doc)?;
    }
    Ok(Some(Snapshot { kind, doc }))
}

/// The one field a fleet read refuses the whole file on: a `launch_queue`
/// entry that is not a string refuses `record-shape`. Every fleet
/// transition reads it before it moves the record.
pub fn queue_read(path: &Path, doc: &Document) -> Result<()> {
    field::<Vec<String>>(path, doc, "launch_queue")?;
    Ok(())
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

/// Create the state file at `path` with the init object through the store's
/// one creation (`record::create_document`): refused `state-exists` where one already
/// stands, the object pretty-printed with jq's two-space indent and final
/// newline, in the shape the shell writers read.
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
    record::create_document(path, &init_document(&issue_id, fields))?;
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
