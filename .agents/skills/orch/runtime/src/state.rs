//! Workflow records: the item state `<state-dir>/workflow-state-<ITEM>.json`
//! and the fleet state `workflow-state-oversee.json`, in the shape the legacy
//! `workflow-state` script writes.
//!
//! A record is held as the document the file holds, a `serde_json::Map` in
//! the file's own key order. The typed structs here are read views derived
//! from that document; an operation changes the document by patching named
//! keys, so every key it does not touch keeps its value and its position,
//! and a key it adds appends. No typed struct is ever the serialized form of
//! a file, so no absent optional field is written back as `null`.
//!
//! agent-runtime's `record` module owns the lock and the atomic replacement.
//! This module owns the document model, the read views and the write check:
//! the content comparison under the lock. A file agent-runtime's `record`
//! module stamped with `record_version` and `revision` is not a workflow
//! record and is refused by name.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use agent_runtime::launch::Permission;
use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use agent_runtime::record::{self, RECORD_VERSION_KEY, REVISION_KEY, Wait};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Error, Result, ShapeReason};

/// The observation note a reconcile writes when it found the intent's owner
/// still live and deferred to it (decision 72). The outcome records only
/// this observation; it moves no record.
pub const OWNER_LIVE: &str = "owner-live";
/// The observation note a reconcile writes when the intent's owner could
/// not be read (decision 99): neither live nor dead is established, so the
/// outcome records the observation and its cause and moves no record, as
/// [`OWNER_LIVE`] does.
pub const OWNER_UNREAD: &str = "owner-unreadable";
/// The fleet state's fixed file name: `workflow-state` writes the key
/// `oversee` into `workflow-state-<KEY>.json`.
pub const FLEET_FILE_NAME: &str = "workflow-state-oversee.json";

/// A record as the file holds it: one JSON object in its own key order.
pub type Document = Map<String, Value>;

/// The item state file for `item` under `dir`:
/// `workflow-state-<ITEM>.json`, the legacy `get_state_file`.
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

/// U6c: the directive id of an owner-directed micro change's item, keyed
/// `directive-<id>` (decisions 168 (4), 182 Q4): the hook's item alphabet
/// (`hooks/lane-mail-check.sh` `item_alphabet`) and the mailbox's
/// (`lane-mail` `item-invalid`) admit `A-Za-z0-9._-` alone, so the word and
/// the id join with a hyphen, never a colon. `None` for every other item.
pub fn directive_of(path: &Path) -> Option<&str> {
    item_of(path).and_then(|item| item.strip_prefix("directive-"))
}

/// The fleet state file under `dir`.
pub fn fleet_path(dir: &Path) -> PathBuf {
    dir.join(FLEET_FILE_NAME)
}

/// The receipt the pane an effect opened writes for its intent (decision
/// 96), beside the records under `dir`: `intents/<intent id>.pane`. An
/// intent id is `<op>:<target>:<stamp>` and carries no path separator.
pub fn receipt_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.pane"))
}

/// The request a transfer's detached job runs (decision 76), written by the
/// caller beside the receipt before the job starts: `intents/<intent
/// id>.request`.
pub fn job_request_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.request"))
}

/// The job-unit record of that job, `intents/<intent id>.job`, which names
/// how the job runs (its unit, or its process group).
pub fn job_record_path(dir: &Path, intent_id: &str) -> PathBuf {
    dir.join("intents").join(format!("{intent_id}.job"))
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

/// How a write takes the file's lock. `wait` bounds the acquisition, the
/// flock and the mutex together; with `legacy_mutex` the file is also
/// written under the `mkdir` mutex the legacy shell writers take where the
/// host has no `flock(1)`, so those writers are excluded.
#[derive(Debug, Clone, Copy)]
pub struct Locking {
    pub wait: Wait,
    pub legacy_mutex: bool,
}

impl Locking {
    /// A host with `flock(1)`: the flock alone, with the legacy wait. The
    /// command resolves a host's policy itself, from its own `PATH`.
    pub const FLOCK: Locking = Locking {
        wait: Wait::LEGACY,
        legacy_mutex: false,
    };
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
// Document access
// ---------------------------------------------------------------------------

fn shape(path: &Path, field: &str, reason: ShapeReason, cause: impl Into<String>) -> Error {
    Error::Shape {
        path: path.to_path_buf(),
        field: field.to_owned(),
        reason,
        cause: cause.into(),
    }
}

/// Read the top-level `key` as `T`. An absent key or a `null` reads as
/// `None`, the way the legacy `.key // default` reads do; another value that
/// is not a `T` refuses `record-shape` naming the key.
pub fn field<T: DeserializeOwned>(path: &Path, doc: &Document, key: &str) -> Result<Option<T>> {
    match doc.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|e| shape(path, key, ShapeReason::TypeMismatch, e.to_string())),
    }
}

/// Set `key` to `value`: in place when the key exists, appended otherwise.
pub fn set(doc: &mut Document, key: &str, value: impl Into<Value>) {
    doc.insert(key.to_owned(), value.into());
}

/// Remove `key`, keeping every other key in place. Returns whether it stood.
pub fn delete(doc: &mut Document, key: &str) -> bool {
    doc.shift_remove(key).is_some()
}

/// The array under `key`, created empty when the key is absent or `null`
/// (the legacy writers' `.key // []`). Another value refuses `record-shape`.
pub fn array_mut<'a>(path: &Path, doc: &'a mut Document, key: &str) -> Result<&'a mut Vec<Value>> {
    if matches!(doc.get(key), None | Some(Value::Null)) {
        doc.insert(key.to_owned(), Value::Array(Vec::new()));
    }
    match doc.get_mut(key) {
        Some(Value::Array(items)) => Ok(items),
        Some(other) => Err(shape(
            path,
            key,
            ShapeReason::NotArray,
            format!("found {}", json_type(other)),
        )),
        None => unreachable!("inserted above"),
    }
}

/// The object under `key`; an absent key refuses `record-shape` too, since
/// the callers patch an object the file already holds.
pub fn object_mut<'a>(path: &Path, doc: &'a mut Document, key: &str) -> Result<&'a mut Document> {
    match doc.get_mut(key) {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(shape(
            path,
            key,
            ShapeReason::NotObject,
            format!("found {}", json_type(other)),
        )),
        None => Err(shape(path, key, ShapeReason::NotObject, "absent")),
    }
}

/// Element `index` of the array under `key` as an object.
pub fn element_mut<'a>(
    path: &Path,
    items: &'a mut [Value],
    index: usize,
    key: &str,
) -> Result<&'a mut Document> {
    let field = format!("{key}/{index}");
    match items.get_mut(index) {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(shape(
            path,
            &field,
            ShapeReason::NotObject,
            format!("found {}", json_type(other)),
        )),
        None => Err(shape(path, &field, ShapeReason::NotObject, "absent")),
    }
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
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
/// run's verdict, or how an admitted run ended without one. A request
/// names the word; none is assumed.
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
        }
    }
}

/// One `stages[]` entry as read: `{kind, round_id, start, end}` in epoch
/// seconds, `superseded: true` once a later round of the kind opened over
/// it, `run_dir` on a validation run's entry, `outcome` once `accept-result`
/// closed it. A validation run `validate start` owns carries its `proof`
/// and its `job` from before its launch, and its `notice` from its close
/// (U6a, step6-map § C).
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
    // U6c: who accepted the step, and the item body revision the round
    // read (step6-map § A3, § A8).
    #[serde(default)]
    pub authorization: Option<Authorization>,
    #[serde(default)]
    pub body_revision: Option<String>,
    // U6l: the intentional stop a `validate stop` recorded on the open
    // stage before it ended the run's job (decision 188 (c)).
    #[serde(default)]
    pub stop: Option<Stop>,
}

/// U6l: an intentional stop of a validation run, recorded on its open stage
/// before the job is ended, a record before the effect (decision 120). A
/// job then read gone with no sentinel closes `stopped`; one with no such
/// record closes `lost`, since no one recorded an intent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stop {
    pub at: u64,
}

/// U6c: who accepted a round's step, recorded on its stage at the close
/// (decisions 142 (5), 168 (4)): the overseer's acceptance, or the owner's
/// directive a micro change was made under, each by its id. The field is
/// part of the acceptance's identity: a closed stage keeps the one it was
/// closed under, and a request naming another refuses (decision 100).
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

/// U6c, U7e: the item's Completion Summary comment on the tracker, the
/// item's `summary_comment` (step6-map § A8, decision 192 Q10): the
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
}

impl ValidateMode {
    /// The word as the file and the run's `start` record hold it.
    pub fn word(self) -> &'static str {
        match self {
            ValidateMode::Full => "full",
            ValidateMode::Range => "range",
            ValidateMode::Ci => "ci",
        }
    }
}

/// The proof facts of one validation run, written on its stage before the
/// launch (step6-map § C): the tree the run validated, the check selection
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

/// The detached job a validation run runs in, as job-unit records it
/// (decision 115 (B)): the record's path from before the launcher is asked,
/// then the identity the launcher's record names. `reconcile-round` reads
/// the identity three-valued, never the child's bare pid (ML:87).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidateJob {
    /// The launcher's record, `<run_dir>/runner`.
    pub record: String,
    /// `systemd`, `setsid`, or `none` where the start ran nothing.
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

/// A lane record's `status` word, as `open-terminal`, `lane-close` and
/// `oversee-watch` read it.
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
    /// `parked` or `done` lane admits a relaunch, the parked one being the
    /// `parked-merged` route the legacy launcher admits in the same cap.
    pub fn in_flight(self) -> bool {
        match self {
            LaneStatus::Preparing | LaneStatus::Running => true,
            LaneStatus::Stopped | LaneStatus::Parked | LaneStatus::Done => false,
        }
    }
}

/// A deliberate, finite hold on a lane's slot in the fleet cap (decision
/// 97): `reason` names why an op wrote it and `until` the ISO 8601 UTC
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
/// record (decision 118 (3)): a holder of a path the item touches whose
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

/// A lane's launch identity `{pane, server, server_start, pid, start}`.
/// `server_start` is the tmux server's start the runtime's launch published
/// (decision 120, L4), so the pane is keyed on the server's pid and start; a
/// record the legacy launcher wrote carries none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchIdentity {
    #[serde(default)]
    pub pane: Option<String>,
    #[serde(default)]
    pub server: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_start: Option<u64>,
    #[serde(default)]
    pub pid: Option<u64>,
    #[serde(default)]
    pub start: Option<String>,
}

/// One `lanes[]` record as read. The named fields are the ones the lane
/// operations read or write; `extra` carries the rest for a report. Only
/// `item` and `status` are required, the two every legacy reader selects
/// on; a record a hand or an older launcher wrote may lack any other.
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
    /// session there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
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
    /// The touched set the admission judged (decision 118 (4)): the union
    /// of the item's Location paths, the brief's paths, the change-scope
    /// paths over the named range and the paths a running lane added,
    /// sorted and unique. `None` on a record the legacy launcher wrote
    /// with no judgement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub touched: Option<Vec<String>>,
    /// The paths the launch named in scope: a file the brief names as an
    /// append-only addition, left out of the overlap judgement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_scope: Option<Vec<String>>,
    /// The rebase obligations the admission recorded (decision 118 (3)).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rebase: Vec<RebaseObligation>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

// U6d: the one reading of a lane's channel the runtime makes.
impl Lane {
    /// Whether the lane runs in a Claude cloud session, reached through a
    /// directive send and no mailbox: its kind or host is the cloud kind.
    pub fn session_channel(&self) -> bool {
        let cloud = Some(crate::ops::CLOUD_KIND);
        self.kind.as_deref() == cloud || self.host.as_deref() == cloud
    }
}

/// The successor a succession is about to open, `overseer.pending`: the
/// identity fields the record carries, the launch line it judged, the typed
/// launch fields the runtime builds the command from (the permission posture
/// and the caller's own words) and the native session it continues where it
/// resumes one. The line is recorded for display and a dead-pane replay's
/// identity read; the runtime never executes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_line: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<String>,
    /// The native session the launch continues in place of starting one:
    /// its file must stand under `home` for `cwd`, and Pi has no form for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
    /// The permission posture the launch runs under: `bypass`, or `native`
    /// with the caller's own permission words among `extra_args`. Left out,
    /// the runtime's launch permission setting decides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<Permission>,
    /// The caller's own launch words beyond what the builder spells from the
    /// typed fields: its permission words under `native`, and whatever else
    /// the walk carried over, as given.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_args: Vec<String>,
    /// The overseer handoff the controller's brief names, the launch's own
    /// `--handoff`; left out, the default handoff. The record keeps it, so a
    /// recovery the watch asks names the same file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handoff: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
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

/// The keys a confirmed succession writes from `pending` onto the overseer
/// record, and nulls where the pending names none: the launch's identity
/// plus the launch line. `class` is not among them: a record carries it
/// only where its launch knew it, so the successor record has the key only
/// when `pending` does.
pub const SUCCESSOR_IDENTITY_KEYS: &[&str] = &[
    "launch_line",
    "harness",
    "account",
    "home",
    "model",
    "effort",
    "cwd",
];

/// The binding `ol_record_write` reads afresh from the session it writes for
/// and a transfer confirmation does not know: a different session inherits
/// none of the prior's. The successor's watch start fills them; until then a
/// confirmed succession nulls each the record holds. `pane`, `server` and
/// `server_start` are not among them: the confirmation writes the first two
/// from the successor's launch identity, and the third where it carries it,
/// so the record passes `ol_owns` from the successor's pane and that watch
/// start keeps it.
pub const SUCCESSOR_BINDING_KEYS: &[&str] = &["window", "session_rows"];

/// The keys of the session that ended, which a different session's record
/// leaves out: the native session id, the harness process and its model
/// check, the recorded exit, the pending it just opened, and the succession
/// command of the owner that recorded it.
pub const PREDECESSOR_SESSION_KEYS: &[&str] = &[
    "session_id",
    "harness_pid",
    "harness_start",
    "model_check",
    "exit",
    "pending",
    "succession",
];

/// The keys the legacy succession compare-and-swap requires equal, less
/// `session_id` and `pending`, which it judges on their own
/// (`ol_succession_owned`).
pub const OVERSEER_COMPARE_KEYS: &[&str] = &[
    "server",
    "server_start",
    "pane",
    "generation",
    "launch_line",
    "cwd",
];

/// The overseer session record as read: the fields a succession reads.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Overseer {
    #[serde(default)]
    pub generation: Option<u64>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pending: Option<Pending>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// The fleet watch the controller record carries as `overseer.watch`
/// (step6-map A7): the job identity the launcher recorded for the watch a
/// start launched (`runner=systemd` with its unit, or `runner=setsid` with
/// the leader's pid and start), or `runner=claimed` with the claim's own
/// identity where a start found the watch already claimed. The claim beside
/// the fleet state stays the watch's liveness record; this field names what
/// started it. An additive field: a succession keeps it as it stands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchJob {
    pub runner: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,
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
    /// The explicit off of decision 78: the controller retired exactly by
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

/// Why a succession was asked for (step4-map A4 to A8). The judges that
/// settle on a cause stay legacy (decision 75); the cause tells the effect
/// what proves the predecessor terminal and the transition what it must
/// refuse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransferCause {
    /// The controller succeeds itself at one of its marks.
    #[default]
    Live,
    /// The watch read the controller dead: the held line is the successor
    /// and a predecessor with no recorded identity is proven terminal by
    /// the exit record or the pane (decision 77).
    Dead,
    /// The controller's account is walled: the successor must not run on
    /// the spent account.
    Walled,
    /// A refused succession left a standing handoff; a fresh session takes
    /// over from it, retiring the still-live predecessor first.
    RefusedRecovery,
}

impl TransferCause {
    /// The cause's word as a request and the record carry it.
    pub fn word(self) -> &'static str {
        match self {
            TransferCause::Live => "live",
            TransferCause::Dead => "dead",
            TransferCause::Walled => "walled",
            TransferCause::RefusedRecovery => "refused-recovery",
        }
    }
}

/// What the tracker judged the lane's item: shipped, or ended any other
/// way. The judge stays the tracker package's; the close op takes its
/// verdict as evidence (decision 83).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalVerdict {
    Completed,
    Canceled,
}

/// What authorizes a close to end a lane's harness, recorded on the close
/// intent so its outcome moves the record the way that ground allows
/// (decisions 83, 98). `exited` and `terminal` end the lane as done;
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
    /// item stays open, on idle-or-gone proof of its harness. `source`
    /// names who recorded it.
    NoLanding { reason: String, source: String },
}

/// The harness, account, model and effort a launch was asked for. The
/// legacy launcher writes them on the lane when it records `running`, not
/// `preparing` (`open-terminal`'s relaunch patch deletes them unless the
/// hosted selection step is done), so a launch intent carries them until
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

/// The process that persisted an intent: its pid and start, read through
/// agent-runtime's one identity reader when the intent was written
/// (decision 72). A reconcile that finds this process still live defers to
/// it and touches nothing; only a dead or absent owner lets a reconcile
/// complete or fail the intent. Legacy intents carry none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    /// The runtime writes the number; a string form is read too (decision
    /// 63), so a record a jq writer produced is not refused.
    #[serde(deserialize_with = "de_pid")]
    pub pid: u64,
    pub start: String,
}

/// Read a pid written as a JSON number or the string a jq `--arg` produced
/// (decision 63).
fn de_pid<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n
            .as_u64()
            .ok_or_else(|| serde::de::Error::custom("pid is not a non-negative integer")),
        Value::String(s) => s
            .parse()
            .map_err(|_| serde::de::Error::custom(format!("pid {s:?} is not an integer"))),
        other => Err(serde::de::Error::custom(format!(
            "pid is {other}, not a number or string"
        ))),
    }
}

/// What an effect recorded around opening its window (decisions 73, 96):
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
    /// launch line is typed into it (decision 96); `None` until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// Whether the launcher has been asked for the window (decision 111
    /// (5)): written before `new-window` runs, so a phase with no pane and
    /// `asked` names a window possibly opened, and one without it nothing.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it: every reconcile reads the runner there, never a home
    /// resolved again in its own process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
}

impl Opening {
    /// The [`OpenedPane`] this opening becomes once its window is found: the
    /// recorded server and floor with the pane (decision 73), and the
    /// identity the pane's receipt proved where a reconcile adopted it
    /// (decision 99).
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
        }
    }
}

/// The pane an effect opened and the floor its native session is read
/// above: the data every phase after `window-opened` carries. The server is
/// named by its socket, pid and start, so a reconcile observes the pane on
/// the recorded server whatever socket its own `$TMUX` names. Another
/// server answering on that socket, or no server with the recorded server
/// process gone, proves the pane gone; only an unanswering socket whose
/// server process still runs is unobservable (decision 66).
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
    /// that takes one: the runner's own native file is then known by name
    /// (decision 65).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The lead sessions for the runner's cwd that stood before the window
    /// opened, for a harness whose launch fixes no id: the runner's own
    /// file is the one lead that appears and is absent here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub baseline: Vec<String>,
    /// The harness identity this attempt runs under, once read: the
    /// receipt's pid confirmed live at adoption, or the identity the judge
    /// read in the pane (decision 99). It is the one identity every later
    /// read, publication and retirement of the attempt uses; none selects
    /// another process in its place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<Identity>,
    /// The home the runner's native sessions are read under, as its launch
    /// prepared it ([`Opening::home`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
}

/// The runner's own native session file, bound once before the brief is
/// pasted: the effect and every reconcile count that file alone, never a
/// neighbour in the same home and directory (decision 65).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundSession {
    pub session_id: String,
    pub file: String,
}

/// How far an effect got, written into its intent before each wait so a
/// `reconcile` completes the effect from the recorded step (decision 62).
/// A launch reaches `window-opened` and then its outcome; a succession
/// passes `retired` (the predecessor confirmed terminal), `delivered` (the
/// brief pasted, with the runner's own session file and its user-turn count
/// before the paste) and
/// `identity-read` (the runner's own process identity, the last read before
/// publication).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "kebab-case")]
pub enum Phase {
    /// Written before any window opens (decision 73) and again with the
    /// pane once one is created (decision 96). A reconcile here adopts the
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
    Retired {
        #[serde(flatten)]
        opened: OpenedPane,
    },
    /// Written before the brief is typed (decision 124e (23)): a reconcile
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
    /// rather than reading nothing opened.
    CloudCreate { worktree: String },
    /// Written before a launch asks a preparation whose answer can be lost:
    /// a hosted provider's `create` (`step` `host-create`, `at` the host;
    /// the `wait` after it included), a cloud lane's worktree `create` and
    /// branch `push` (`worktree-create` at the claim root, `worktree-push`
    /// at the worktree). Its effect may stand though nothing answered, so a
    /// reconcile holds the launch until a close settles it.
    Preparing { step: String, at: String },
}

impl Phase {
    /// The pane a phase names, or `None` at `opening`, before a window
    /// exists.
    pub fn opened(&self) -> Option<&OpenedPane> {
        match self {
            Phase::WindowOpened { opened }
            | Phase::Retired { opened }
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
    /// The process that persisted the intent (decision 72); a reconcile
    /// that finds it live defers to it. Absent on a legacy intent.
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
    /// the transfer fails, as the legacy succession restores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_pending: Option<Value>,
    /// Why a transfer was asked for; a reconcile reads it to know what
    /// proves the predecessor terminal (decision 77). Absent on the other
    /// operations and on transfers recorded before the cause existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<TransferCause>,
    /// The owner that persisted the intent and handed it to the detached
    /// job that now owns it (decision 76), written by the claim: the job
    /// lets that process answer and exit before it retires the pane the
    /// process asked from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handed_from: Option<Owner>,
    /// The account a wall relaunch must not run on, canonical, recorded on
    /// the launch intent that refused it (step4-map A11). Absent elsewhere.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude_account: Option<String>,
    /// The fleet watch's launch line a start carries (step6-map A7): the
    /// `oversee-watch` entry and its arguments, which the start's effect
    /// launches through the job launcher once the controller's lane is
    /// confirmed, and a reconcile launches again where no watch claims.
    /// Absent on the other operations and on a start whose caller holds
    /// the watch's start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watch: Option<Vec<String>>,
    /// What authorized a close (decisions 83, 98); its confirmed outcome
    /// moves the lane as that ground allows. Absent on the other operations
    /// and on closes recorded before the ground existed, which end the lane
    /// as done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close: Option<CloseGround>,
    /// The failure the detached job's outcome announced (decision 109 (7)):
    /// the fleet-log row and the owner notice the legacy `die_status`
    /// emitted, sent once per intent and recorded here so a repeated
    /// reconcile of the same outcome emits nothing again. Absent until an
    /// outcome of a transfer or a stop failed or stayed unconfirmed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
    /// How far the effect got, written before each wait (decision 62); a
    /// reconciliation completes the effect from it. Absent until the effect
    /// has opened something.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<Phase>,
    /// The obligations the effect stands under (decision 115 (A)): every
    /// handle it acquired, written before the wait that follows the
    /// acquisition, with the discharges made so far and whether anything was
    /// signalled. Every later step and every reconcile reads this set and
    /// never rebuilds it from the lane or the phase. Absent on an intent
    /// recorded before the field existed; its next step writes it.
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
}

/// One recorded handle of an operation's target (decisions 111 (A) (1), 115
/// (A)), typed by what it is. A pane and a window carry the server's pid and
/// tmux start, the only form this host addresses a pane in; a lane record
/// written by the legacy launcher carries the pid alone (decision 35), so
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
    /// A pane recorded with no server (decision 35 admits the record): this
    /// host cannot address it, and the record does not prove it absent.
    PaneUnaddressed { pane: String },
    /// A launcher was asked for a window on this server and no pane id was
    /// recorded yet (decision 111 (5)): a window possibly opened.
    Window { server: u64, server_start: u64 },
    /// The pane's receipt was armed (decision 96): an obligation until read.
    Receipt,
    /// The worktree's validation runs, owed to orch's own runner's stop
    /// (decision 108 (7)).
    Validation,
    /// The job launcher was asked and its record not yet read (decision 115
    /// (B)): a job possibly started. `record` is the launcher record's path
    /// the ask named, the one address the record is read at (decision 184
    /// (6)): the intent's own job record for a transfer or a stop, the
    /// watch's runner record beside the fleet state for a start's watch.
    JobSidecar { record: String },
    /// The detached job runs as this transient user unit.
    JobUnit { unit: String },
    /// The detached job leads this process group, by the identity its child
    /// wrote before it ran.
    JobGroup(Identity),
    /// The detached job's process group by its key alone: the launcher ended
    /// the launch `unwound-failed` without reading the leader's start, and
    /// the group is read in the kernel's table until it empties (decision
    /// 124h (33)).
    JobPgid { pgid: u32 },
    /// The lane's local worktree at `path`, an owned resource of the close
    /// (decision 128 (9)): released through `git worktree remove`, or kept
    /// with its reason recorded where removal would lose work.
    Worktree { path: String },
}

/// The part a recorded handle plays in its intent (decision 124d (15)): the
/// lane's own harness and pane, its detached wake turn, the runner a
/// succession opens, the predecessor it retires, the worktree's validation
/// runs, the detached job, or the lane's worktree itself. A selection from
/// the set reads the role and never the target's record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    Harness,
    Wake,
    Runner,
    Predecessor,
    Validation,
    Job,
    Worktree,
}

/// One standing obligation as the record holds it: the handle, flattened
/// under its `kind`, its role, and, under the harness role, the harness
/// kind the lane ran when the handle was acquired (decision 124g (29)): what
/// names the processes below the recorded root that a stop may signal,
/// never the harness a relaunched session runs. A record written before the
/// role existed carries none, and the handle bootstraps it once at open.
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

/// The durable obligation set of an intent (decision 115 (A)): what stands,
/// what was discharged and by what, and whether the effect has signalled
/// anything, after which no refusal is expressible on the intent. `revision`
/// counts the set's replacements: the store advances it on every write that
/// changes the set, and a handle whose write names an older revision is
/// refused `set-replaced` (decisions 124d (16), 124g (26)).
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
    /// settles the identity (decision 124c).
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub stale: std::collections::BTreeMap<String, u64>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub revision: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// The prefix of the word a worktree obligation is discharged by when the
/// close keeps the worktree: `kept:<reason>`, the reason being what the
/// lane record's `kept` field carries.
pub const WORKTREE_KEPT: &str = "kept:";

/// The prefix of the word a worktree obligation is discharged by when the
/// close released the worktree but the worktree package kept a lane mailbox
/// beside the main checkout's: `released:mail-kept:<path>`, the path being
/// what the lane record's `kept_mail` field carries.
pub const WORKTREE_MAIL_KEPT: &str = "released:mail-kept:";

/// The keys a lane intent's terminal carries (decision 124d (14)): the
/// lane's `session_since` when the intent was written and every identity,
/// pid and pane key the intent's set recorded under the harness role, the
/// launch record's own and the harness read in its pane. The store applies a
/// terminal to the lane only when the lane's launch names nothing but these.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaneKeys {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_since: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub harness: Vec<Obligation>,
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
    /// discharged (decision 124g (29)).
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

    /// The lane keys the record holds under the harness role, standing or
    /// discharged: every process, pid and pane key (decision 124d (14)).
    pub fn lane_keys(&self, lane_since: Option<String>) -> LaneKeys {
        let harness = self
            .standing_obligations()
            .chain(self.discharged.iter().map(|d| &d.obligation))
            .filter(|o| self.role_of(o) == Some(Role::Harness))
            .filter(|o| match o {
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. } => true,
                Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::Validation
                | Obligation::JobSidecar { .. }
                | Obligation::JobUnit { .. }
                | Obligation::JobGroup(_)
                | Obligation::JobPgid { .. }
                | Obligation::Worktree { .. } => false,
            })
            .cloned()
            .collect();
        LaneKeys {
            lane_since,
            harness,
        }
    }

    /// The reason the close kept the lane's worktree, where its worktree
    /// obligation was discharged `kept:<reason>` (decision 128 (9)); `None`
    /// where it was released, read gone, or never acquired. The one reader
    /// of that word, which the close's outcome writes onto the lane record
    /// as `kept`.
    pub fn worktree_kept(&self) -> Option<&str> {
        self.worktree_word()?.strip_prefix(WORKTREE_KEPT)
    }

    /// The path of a lane mailbox the worktree package kept beside the main
    /// checkout's when the close released the lane's worktree, where its
    /// worktree obligation was discharged `released:mail-kept:<path>`;
    /// `None` otherwise. The one reader of that word, which the close's
    /// outcome writes onto the lane record as `kept_mail`.
    pub fn worktree_mail_kept(&self) -> Option<&str> {
        self.worktree_word()?.strip_prefix(WORKTREE_MAIL_KEPT)
    }

    /// The word the worktree obligation was discharged by, where one was.
    fn worktree_word(&self) -> Option<&str> {
        self.discharged.iter().find_map(|d| match &d.obligation {
            Obligation::Worktree { .. } => Some(d.by.as_str()),
            Obligation::Process(_)
            | Obligation::Pid { .. }
            | Obligation::Pane { .. }
            | Obligation::PaneUnaddressed { .. }
            | Obligation::Window { .. }
            | Obligation::Receipt
            | Obligation::Validation
            | Obligation::JobSidecar { .. }
            | Obligation::JobUnit { .. }
            | Obligation::JobGroup(_)
            | Obligation::JobPgid { .. } => None,
        })
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

/// The one failure announcement an intent makes: the keyed line the fleet
/// log holds under `item: overseer`, an `oversee-succeed: <key>
/// field=value...` row, and how the owner notice went. The outcome's own
/// write records the notice `owed`, with its row; the send follows, and a
/// later write marks it `sent`, `unsent:<cause>` where the mailbox CLI
/// refused, or `unanswered:<cause>` where it gave no answer. A notice still
/// `owed` on a closed intent is a continuation every reconcile and request
/// runs once, under the owner; an `unanswered` one is sent once more by the
/// watch's heartbeat. `to` names the item whose lane the notice goes to;
/// absent, it goes to the owner through the overseer's box, the shape every
/// intent notice has.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    pub key: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    pub owner: String,
}

/// The `owner` word of a notice recorded with its outcome and not yet sent.
pub const NOTICE_OWED: &str = "owed";

/// The `owner` word's prefix for a notice whose send got no answer.
pub const NOTICE_UNANSWERED: &str = "unanswered:";

impl Notice {
    /// Whether the notice is recorded and still to be sent.
    pub fn owed(&self) -> bool {
        self.owner == NOTICE_OWED
    }

    /// Whether the notice's send got no answer, so it may not have gone.
    pub fn unanswered(&self) -> bool {
        self.owner.starts_with(NOTICE_UNANSWERED)
    }
}

/// Why an intent was closed apart from its effect's own outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reconciled {
    /// The target's record moved under the open intent: a lane relaunched,
    /// closed or removed since, or an overseer whose generation moved past
    /// the one the intent names. The record is left as found.
    IntentStale,
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
/// read. `triaged` rows stay untyped: the triage writer once supplied a
/// string or an `item` key, and the watch reads such rows without refusing
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
    /// object row whose verdict is `kept` or `canceled`
    /// (`oversee-watch`'s `check_triage` filter). A string row or an
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

fn json(path: &Path, source: serde_json::Error) -> agent_runtime::Error {
    agent_runtime::Error::Json {
        path: path.to_path_buf(),
        source,
    }
}

fn snapshot_of(path: &Path, value: Value) -> Result<Snapshot> {
    let kind = Kind::of_path(path);
    let Value::Object(doc) = value else {
        return Err(shape(
            path,
            "",
            ShapeReason::NotObject,
            format!("found {}", json_type(&value)),
        ));
    };
    // A file stamped with agent-runtime's record meta keys (the retired
    // `state migrate` wrote one) is no workflow record this runtime reads:
    // the legacy writers patch the file beside it and keep no revision, so
    // the content comparison is the one write check, and a file carrying
    // either key is refused by name rather than read as if unstamped.
    if let Some(key) = [RECORD_VERSION_KEY, REVISION_KEY]
        .into_iter()
        .find(|key| doc.contains_key(*key))
    {
        return Err(agent_runtime::Error::refused(
            "record-stamped",
            &[("path", &path.display().to_string()), ("key", key)],
        )
        .into());
    }
    if kind == Kind::Fleet {
        // The one field the legacy watch refuses the whole file on.
        field::<Vec<String>>(path, &doc, "launch_queue")?;
    }
    Ok(Snapshot { kind, doc })
}

/// Read a state file. The reader refuses what the legacy readers refuse on
/// the same file: unparsable bytes (`json-invalid`), a non-object, a
/// `launch_queue` entry that is not a string (`record-shape`), and a file
/// stamped with `record_version` or `revision` (`record-stamped`). Every
/// other field is read when an operation needs it.
#[allow(
    clippy::disallowed_methods,
    reason = "the one reader of a state file, whose typed snapshot every transition and effect reads"
)]
pub fn load(path: &Path) -> Result<Option<Snapshot>> {
    let Some(value) = record::read_value(path)? else {
        return Ok(None);
    };
    Ok(Some(snapshot_of(path, value)?))
}

fn validate(path: &Path, snapshot: &Snapshot) -> Result<()> {
    match snapshot.kind {
        Kind::Item => snapshot.view::<ItemState>(path).map(|_| ()),
        Kind::Fleet => snapshot.view::<FleetState>(path).map(|_| ()),
    }
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Run `f` under the lock beside `path` (`<path>.lock`), bounded by
/// `locking.wait`, and under the legacy `mkdir` mutex where the policy says
/// the host's legacy writers take one. Both locks are taken under one
/// deadline, so the whole acquisition waits at most the legacy 10 s. The
/// lane admission takes the legacy fleet launch lock through the same
/// helper (`ops`), so one lock discipline serves both legacy locks.
#[allow(
    clippy::disallowed_methods,
    reason = "the one acquisition of a record's locks, under the legacy wait's clock"
)]
pub(crate) fn locked<R>(path: &Path, locking: Locking, f: impl FnOnce() -> Result<R>) -> Result<R> {
    let deadline = locking.wait.start();
    let mut guard = record::lock(path)?;
    guard.with_wait(&deadline, || {
        let _mutex = if locking.legacy_mutex {
            Some(record::mutex_lock(path, &deadline)?)
        } else {
            None
        };
        Ok(f())
    })?
}

/// Write `doc` over the file `snapshot` was read from, refusing
/// `record-changed` when the file's content moved since the read: the check
/// the legacy writers' lock cannot give it otherwise. A `doc` whose record
/// bytes equal the snapshot's passes the same check and then writes nothing
/// (decision 89), so a repeated request that reconciles its standing intent
/// leaves the file as it found it. The comparison is of the serialized
/// bytes with key order kept (decision 95), never of the values: a key that
/// moved is a changed record.
#[allow(
    clippy::disallowed_methods,
    reason = "the one writer of a state file, behind the write check"
)]
pub fn store(path: &Path, snapshot: &Snapshot, doc: &Document, locking: Locking) -> Result<()> {
    let unchanged = same_document(path, doc, &snapshot.doc)?;
    locked(path, locking, || {
        match record::read_value(path)? {
            Some(Value::Object(current)) if current == snapshot.doc => {}
            _ => {
                return Err(agent_runtime::Error::refused(
                    "record-changed",
                    &[("path", &path.display().to_string())],
                )
                .into());
            }
        }
        if !unchanged {
            record::replace_atomically(path, &Value::Object(doc.clone()))?;
        }
        Ok(())
    })
}

/// Whether two documents are one record byte for byte, key order included
/// (decisions 89, 95): what the store's no-change check compares, and what a
/// transition compares before it reports a record changed.
pub(crate) fn same_document(path: &Path, a: &Document, b: &Document) -> Result<bool> {
    Ok(serialized(path, a)? == serialized(path, b)?)
}

/// The bytes the record writer puts on disk for `doc`, key order included:
/// the form the no-change check compares, since two documents equal as
/// values are different records once a key moved.
fn serialized(path: &Path, doc: &Document) -> Result<Vec<u8>> {
    serde_json::to_vec_pretty(doc).map_err(|source| {
        agent_runtime::Error::Json {
            path: path.to_path_buf(),
            source,
        }
        .into()
    })
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
/// jq's two-space indent and final newline, in the shape the legacy writers
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
        .map_err(|e| json(path, e))?;
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
    /// an operation stands on a target, the legacy watch's succession guard
    /// among them, takes the judgement from here rather than from the
    /// outcome words. Empty on an item file.
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
        return Err(Error::RecordMissing {
            path: path.to_path_buf(),
        });
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
    //! The legacy-shaped samples, checked in beside the integration harness
    //! and shared with it.
    pub const ITEM: &str = include_str!("../../tests/rust/fixtures/workflow-state-KEN-4687.json");
    pub const FLEET: &str = include_str!("../../tests/rust/fixtures/workflow-state-oversee.json");
    pub const NEWER: &str = include_str!("../../tests/rust/fixtures/workflow-state-newer.json");

    /// The init fields later than 2026-09-02 removed, the shape of a state
    /// file an older `workflow-state init` wrote and a live fleet never
    /// re-initialized.
    pub const PRE_2026_INIT_FIELDS: &[&str] = &[
        "finding_occurrences",
        "near_ceiling",
        "post_pr_budgets",
        "post_pr_stop",
    ];

    /// `text` without the keys in `PRE_2026_INIT_FIELDS`, serialized the way
    /// this runtime writes, so a byte comparison after an unchanged store
    /// is exact.
    pub fn without_init_fields(text: &str) -> String {
        let serde_json::Value::Object(mut map) = serde_json::from_str(text).unwrap() else {
            panic!("fixture is not an object")
        };
        for key in PRE_2026_INIT_FIELDS {
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
    use std::ffi::OsStr;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

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

    /// Finding 1, probe P1: a file an older init wrote lacks the newest init
    /// fields and still reads and stores.
    #[test]
    fn a_file_missing_the_newer_init_fields_reads_and_stores() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            ("workflow-state-KEN-4687.json", fixtures::ITEM),
            (FLEET_FILE_NAME, fixtures::FLEET),
        ];
        for (name, text) in rows {
            let legacy = fixtures::without_init_fields(text);
            let path = write(dir.path(), name, &legacy);
            let s = snapshot(&path);
            validate(&path, &s).unwrap();
            for key in fixtures::PRE_2026_INIT_FIELDS {
                assert!(!s.doc.contains_key(*key), "{name}: {key}");
            }
            // An unchanged store writes the same bytes back.
            store(&path, &s, &s.doc, Locking::FLOCK).unwrap();
            assert_eq!(fs::read_to_string(&path).unwrap(), legacy, "{name}");
            inspect(&path).unwrap();
        }
    }

    /// Finding 9, probes P3, P4 and P6, and decision 34: a store on either
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
            store(&path, &s, &doc, Locking::FLOCK).unwrap();
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

    /// Finding 9, probes P2 and P7: a hand-written lane without the
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
        store(&path, &s, &doc, Locking::FLOCK).unwrap();
        let after = object(&path);
        assert_eq!(keys(after["lanes"][0].as_object().unwrap()), hand_keys);
        assert_eq!(
            keys(after["overseer"].as_object().unwrap()),
            keys(before["overseer"].as_object().unwrap())
        );
        assert!(after["overseer"].get("generation").is_none());
        assert_eq!(after["lanes"][1]["status"], Value::from("stopped"));
    }

    /// Finding 3 and decision 35: `triaged` rows with an `item` key or a
    /// bare string read as the watch reads them, never refusing the file.
    #[test]
    fn legacy_triaged_rows_are_admitted_and_read_as_the_watch_reads_them() {
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

    /// Finding 2, probe P10b: a legacy-style edit between the read and the
    /// store refuses `record-changed`, and the edit stands.
    #[test]
    fn a_legacy_edit_between_load_and_store_refuses_record_changed() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let s = snapshot(&path);
        let moved = fixtures::ITEM.replacen("\"cycles\": 0", "\"cycles\": 5", 1);
        fs::write(&path, &moved).unwrap();
        let mut doc = s.doc.clone();
        set(&mut doc, "cycles", 1);
        let err = store(&path, &s, &doc, Locking::FLOCK).unwrap_err();
        assert_eq!(err.key(), "record-changed");
        assert_eq!(fs::read_to_string(&path).unwrap(), moved);
    }

    /// Decisions 89 and 95: a document whose record bytes equal the
    /// snapshot's writes nothing, so a repeated request that changes no
    /// record leaves the file as it found it. A document equal as a value
    /// but with a key moved is a changed record: it is written, as a changed
    /// value is.
    #[test]
    fn an_unchanged_document_writes_nothing_and_a_moved_key_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let s = snapshot(&path);
        let before = fs::read(&path).unwrap();
        store(&path, &s, &s.doc, Locking::FLOCK).unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        // The same values with `cycles` moved to the end of the document.
        let mut reordered = s.doc.clone();
        let cycles = reordered.shift_remove("cycles").unwrap();
        reordered.insert("cycles".to_owned(), cycles);
        assert_eq!(reordered, s.doc, "equal as values");
        assert_ne!(keys(&reordered), keys(&s.doc), "a key moved");
        store(&path, &s, &reordered, Locking::FLOCK).unwrap();
        assert_ne!(
            fs::read(&path).unwrap(),
            before,
            "an order-only change is written"
        );
        assert_eq!(
            keys(&object(&path)).last().map(String::as_str),
            Some("cycles")
        );
        let s = snapshot(&path);
        let mut doc = s.doc.clone();
        set(&mut doc, "cycles", 7);
        store(&path, &s, &doc, Locking::FLOCK).unwrap();
        assert_eq!(object(&path)["cycles"], Value::from(7));
    }

    /// A file stamped with agent-runtime's record meta keys, under any
    /// version, is no workflow record: the reader and the inspection refuse
    /// `record-stamped` naming the key, and the file is left as it was.
    #[test]
    fn a_stamped_file_refuses_record_stamped_without_touching_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            (
                "workflow-state-KEN-9999.json",
                fixtures::NEWER.to_owned(),
                "record_version",
            ),
            (
                "workflow-state-KEN-4687.json",
                fixtures::ITEM.replacen("{", "{\"record_version\": 1, \"revision\": 4,", 1),
                "record_version",
            ),
            (
                "workflow-state-KEN-1.json",
                "{\"revision\": 3, \"issue_id\": \"KEN-1\"}".to_owned(),
                "revision",
            ),
        ];
        for (name, text, key) in rows {
            let path = write(dir.path(), name, &text);
            let before = fs::read(&path).unwrap();
            for err in [load(&path).unwrap_err(), inspect(&path).unwrap_err()] {
                assert_eq!(err.key(), "record-stamped", "{name}: {err:?}");
                let Error::Runtime(agent_runtime::Error::Refused { fields, .. }) = &err else {
                    panic!("{name}: {err:?}")
                };
                assert_eq!(fields[1], ("key".to_owned(), key.to_owned()), "{name}");
            }
            assert_eq!(fs::read(&path).unwrap(), before, "{name}");
        }
    }

    /// Finding 12 and decision 35: unparsable bytes are `json-invalid`; a
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
                let Error::Shape { field, .. } = &err else {
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

    /// A clock that moves only when a wait sleeps on it, so a timeout row
    /// runs without real time passing. agent-runtime's tests hold the same
    /// fake behind their own test boundary. `on_first_sleep` runs once, in
    /// the waiter's thread, before the first sleep moves the clock: a row
    /// that needs a lock released after the waiter's first poll hands the
    /// release over here, so the order is the timer's and not the
    /// scheduler's.
    struct FakeTimer {
        now: Mutex<Instant>,
        slept: Mutex<Vec<Duration>>,
        on_first_sleep: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    }

    impl FakeTimer {
        fn leaked() -> &'static FakeTimer {
            Box::leak(Box::new(FakeTimer {
                now: Mutex::new(Instant::now()),
                slept: Mutex::new(Vec::new()),
                on_first_sleep: Mutex::new(None),
            }))
        }

        fn releasing_on_first_sleep(release: impl FnOnce() + Send + 'static) -> &'static FakeTimer {
            let timer = FakeTimer::leaked();
            *timer.on_first_sleep.lock().unwrap() = Some(Box::new(release));
            timer
        }

        fn slept(&self) -> Vec<Duration> {
            self.slept.lock().unwrap().clone()
        }
    }

    impl record::Timer for FakeTimer {
        fn now(&self) -> Instant {
            *self.now.lock().unwrap()
        }

        fn sleep(&self, duration: Duration) {
            if let Some(release) = self.on_first_sleep.lock().unwrap().take() {
                release();
            }
            *self.now.lock().unwrap() += duration;
            self.slept.lock().unwrap().push(duration);
        }
    }

    /// 250 ms in 100 ms polls: two whole polls and one clamped to the rest.
    /// The policy the command resolves for a host whose `PATH` is
    /// `path_var` (`main.rs`'s `host_locking`): the legacy wait, and the
    /// mutex wherever `flock(1)` is not on that path.
    fn for_host(path_var: Option<&OsStr>) -> Locking {
        Locking {
            wait: Wait::LEGACY,
            legacy_mutex: !record::flock_on_path(path_var),
        }
    }

    fn short(timer: &'static FakeTimer) -> Wait {
        Wait {
            limit: Duration::from_millis(250),
            poll: Duration::from_millis(100),
            timer,
        }
    }

    const CLAMPED: [Duration; 3] = [
        Duration::from_millis(100),
        Duration::from_millis(100),
        Duration::from_millis(50),
    ];

    /// Finding 11 and decision 39: on a host whose `PATH` lacks `flock(1)`
    /// the write takes the legacy `mkdir` mutex, so a legacy writer holding
    /// it excludes the store, and the store removes its own mutex
    /// afterwards. The wait runs on the fake clock and stops at the limit.
    #[test]
    fn without_flock_on_path_the_write_takes_the_legacy_mutex() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path_var = std::env::join_paths([&bin]).unwrap();
        let timer = FakeTimer::leaked();
        let locking = Locking {
            wait: short(timer),
            ..for_host(Some(&path_var))
        };
        assert!(locking.legacy_mutex);
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let mutex = record::mutex_path(&path);
        fs::create_dir(&mutex).unwrap();
        let s = snapshot(&path);
        let started = Instant::now();
        let err = store(&path, &s, &s.doc, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        let Error::Runtime(agent_runtime::Error::Refused { fields, .. }) = &err else {
            panic!("{err:?}")
        };
        assert_eq!(fields[0], ("path".to_owned(), mutex.display().to_string()));
        assert_eq!(timer.slept(), CLAMPED);
        fs::remove_dir(&mutex).unwrap();
        store(&path, &s, &s.doc, locking).unwrap();
        assert!(!mutex.exists());
        // With flock on the path the policy takes no mutex.
        fs::write(bin.join("flock"), "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(bin.join("flock"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(!for_host(Some(&path_var)).legacy_mutex);
    }

    /// Finding 11: the flock wait is bounded and refuses `lock-timeout` at
    /// the limit, on the fake clock.
    #[test]
    fn a_held_flock_bounds_the_store_wait() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let s = snapshot(&path);
        let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder_path = path.clone();
        let holder = std::thread::spawn(move || {
            let mut guard = record::lock(&holder_path).unwrap();
            guard
                .with(|| {
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .unwrap();
        });
        held_rx.recv().unwrap();
        let timer = FakeTimer::leaked();
        let locking = Locking {
            wait: short(timer),
            legacy_mutex: false,
        };
        let started = Instant::now();
        let err = store(&path, &s, &s.doc, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        assert_eq!(timer.slept(), CLAMPED);
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        store(&path, &s, &s.doc, locking).unwrap();
        assert_eq!(
            timer.slept().len(),
            CLAMPED.len(),
            "a free lock sleeps nothing"
        );
    }

    /// The flock and the mutex share one deadline: a mutex wait that starts
    /// after the flock took part of the limit gets only what is left, so the
    /// two never add up past the bound R-U10 found doubled. A holder keeps
    /// the flock through the waiter's first poll and lets go from inside
    /// that poll's sleep, so the flock is acquired on the second attempt
    /// with one poll of the limit spent; the mutex the test planted then
    /// holds the rest, and is the lock the refusal names.
    #[test]
    fn the_flock_and_the_mutex_share_one_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path_var = std::env::join_paths([&bin]).unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let s = snapshot(&path);
        let mutex = record::mutex_path(&path);
        fs::create_dir(&mutex).unwrap();
        let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder_path = path.clone();
        let holder = std::thread::spawn(move || {
            let mut guard = record::lock(&holder_path).unwrap();
            guard
                .with(|| {
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .unwrap();
        });
        held_rx.recv().unwrap();
        // The join acknowledges the release: the holder's guard has dropped
        // the flock before its thread ends, so the waiter's next attempt
        // takes it.
        let timer = FakeTimer::releasing_on_first_sleep(move || {
            release_tx.send(()).unwrap();
            holder.join().unwrap();
        });
        let locking = Locking {
            wait: short(timer),
            ..for_host(Some(&path_var))
        };
        assert!(locking.legacy_mutex);
        let started = Instant::now();
        let err = store(&path, &s, &s.doc, locking).unwrap_err();
        assert!(started.elapsed() < locking.wait.limit, "no real sleep");
        assert_eq!(err.key(), "lock-timeout");
        let Error::Runtime(agent_runtime::Error::Refused { fields, .. }) = &err else {
            panic!("{err:?}")
        };
        assert_eq!(
            fields[0],
            ("path".to_owned(), mutex.display().to_string()),
            "the mutex, not the flock, is the lock the wait ran out on"
        );
        assert_eq!(
            timer.slept(),
            CLAMPED,
            "one poll on the flock, then the rest of the one limit on the mutex"
        );
        assert_eq!(
            timer.slept().iter().sum::<Duration>(),
            locking.wait.limit,
            "flock and mutex waits sum to one limit"
        );
        assert!(
            mutex.is_dir(),
            "the planted mutex stands; the store removed nothing"
        );
    }
}
