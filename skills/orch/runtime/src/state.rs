//! Workflow records: the item state `<state-dir>/workflow-state-<ITEM>.json`
//! and the fleet state `workflow-state-oversee.json`, in the shape the legacy
//! `workflow-state` script writes, with `record_version` and `revision` as
//! top-level keys once `migrate` has stamped a file.
//!
//! A record is held as the document the file holds, a `serde_json::Map` in
//! the file's own key order. The typed structs here are read views derived
//! from that document; an operation changes the document by patching named
//! keys, so every key it does not touch keeps its value and its position,
//! and a key it adds appends. No typed struct is ever the serialized form of
//! a file, so no absent optional field is written back as `null`.
//!
//! agent-runtime's `record` module owns the lock, the atomic replacement and
//! the meta keys. This module owns the document model, the read views, the
//! two write checks (content for an unstamped file, revision for a stamped
//! one) and the one migration that stamps a file.

use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use agent_runtime::protocol::Outcome;
use agent_runtime::record::{self, RECORD_VERSION_KEY, REVISION_KEY, Wait};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Error, Result, ShapeReason};

/// The version `migrate` writes.
pub const RECORD_VERSION: u64 = 1;
/// The versions this build reads once a file is stamped.
pub const SUPPORTED_VERSIONS: &[u64] = &[1];
/// The fleet state's fixed file name: `workflow-state` writes the key
/// `oversee` into `workflow-state-<KEY>.json`.
pub const FLEET_FILE_NAME: &str = "workflow-state-oversee.json";
/// The suffix the migration gives the copy of the original bytes.
pub const PRE_MIGRATION_SUFFIX: &str = ".pre-migration";

/// A record as the file holds it: one JSON object in its own key order.
pub type Document = Map<String, Value>;

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

/// What the file carried for `record_version` and `revision`: nothing (a
/// file `migrate` has not stamped) or both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Stamp {
    Legacy,
    Stamped { record_version: u64, revision: u64 },
}

impl Stamp {
    /// The revision a write expects to find, 0 for a file not yet stamped.
    pub fn revision(self) -> u64 {
        match self {
            Stamp::Legacy => 0,
            Stamp::Stamped { revision, .. } => revision,
        }
    }
}

/// How a write takes the file's lock. `wait` bounds the acquisition, the
/// flock and the mutex together; with `legacy_mutex` an unstamped file is
/// also written under the `mkdir` mutex the legacy shell writers take where
/// the host has no `flock(1)`, so those writers are excluded until `migrate`
/// makes this runtime the only writer.
#[derive(Debug, Clone, Copy)]
pub struct Locking {
    pub wait: Wait,
    pub legacy_mutex: bool,
}

impl Locking {
    /// The policy for a host whose `PATH` is `path_var`: the legacy wait,
    /// and the mutex wherever `flock(1)` is not on that path.
    pub fn for_host(path_var: Option<&OsStr>) -> Locking {
        Locking {
            wait: Wait::LEGACY,
            legacy_mutex: !record::flock_on_path(path_var),
        }
    }

    /// A host with `flock(1)`: the flock alone, with the legacy wait.
    pub const FLOCK: Locking = Locking {
        wait: Wait::LEGACY,
        legacy_mutex: false,
    };
}

/// A state file as read: the document, its kind and the stamp a later
/// write is checked against.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub kind: Kind,
    pub stamp: Stamp,
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

/// One `stages[]` entry as read: `{kind, round_id, start, end}` in epoch
/// seconds, `superseded: true` once a later round of the kind opened over
/// it, `run_dir` on a validation run's entry.
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

/// A lane's launch identity `{pane, server, pid, start}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchIdentity {
    #[serde(default)]
    pub pane: Option<String>,
    #[serde(default)]
    pub server: Option<u64>,
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
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// The successor a succession is about to open, `overseer.pending`: the
/// identity fields the legacy `ol_identity` names plus the launch line.
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
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// The keys a confirmed succession writes from `pending` onto the overseer
/// record, and nulls where the pending names none: the legacy launch's
/// identity object plus the launch line (`overseer-launch.sh`,
/// `ol_record_write`'s `$identity | map_values(null)` then `$fresh`).
/// `class` is not among them: the legacy identity carries it only where
/// known, so the successor record has the key only when `pending` does.
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

/// The keys of the session that ended, which `ol_record_write` leaves out of
/// a different session's record: the native session id, the harness process
/// and its model check, the recorded exit, and the pending it just opened.
pub const PREDECESSOR_SESSION_KEYS: &[&str] = &[
    "session_id",
    "harness_pid",
    "harness_start",
    "model_check",
    "exit",
    "pending",
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

/// The operations that start an external effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EffectOp {
    LaunchLane,
    RequestTransfer,
    CloseOwnedResources,
}

impl EffectOp {
    /// The operation's word, the `op` of a request.
    pub fn word(self) -> &'static str {
        match self {
            EffectOp::LaunchLane => "launch-lane",
            EffectOp::RequestTransfer => "request-transfer",
            EffectOp::CloseOwnedResources => "close-owned-resources",
        }
    }
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
}

/// The persisted intent of one external effect: written before the effect
/// starts, its `outcome` written after. The id is
/// `<op>:<target>:<nanos>-<nonce>`, the operation's word, its target and
/// the stamp the caller's `Env` minted for the call, so two intents on one
/// target never share an id whatever the file's stamp. One intent per
/// target may be open; a repeated request of the same operation finds it
/// and reconciles, a request of another operation on the target refuses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    pub id: String,
    pub op: EffectOp,
    pub target: String,
    pub expected_revision: u64,
    pub created_at: String,
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
}

impl Intent {
    /// Whether the effect may still be in flight.
    pub fn open(&self) -> bool {
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
    let stamp = if doc.contains_key(RECORD_VERSION_KEY) {
        let (record_version, revision, _) =
            record::split_meta(path, Value::Object(doc.clone()), SUPPORTED_VERSIONS)?;
        Stamp::Stamped {
            record_version,
            revision,
        }
    } else if doc.contains_key(REVISION_KEY) {
        return Err(shape(
            path,
            REVISION_KEY,
            ShapeReason::TypeMismatch,
            format!("{REVISION_KEY} without {RECORD_VERSION_KEY}"),
        ));
    } else {
        Stamp::Legacy
    };
    if kind == Kind::Fleet {
        // The one field the legacy watch refuses the whole file on.
        field::<Vec<String>>(path, &doc, "launch_queue")?;
    }
    Ok(Snapshot { kind, stamp, doc })
}

/// Read a state file. The reader refuses what the legacy readers refuse on
/// the same file: unparsable bytes (`json-invalid`), a non-object, a
/// `launch_queue` entry that is not a string (`record-shape`), and a
/// `record_version` this build does not know. Every other field is read
/// when an operation needs it.
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

/// Run `f` under the file's lock, bounded by `locking.wait`. With
/// `legacy_writers` the file is also held under the legacy `mkdir` mutex
/// where the policy says the host's legacy writers take one: an unstamped
/// file still has them. Both locks are taken under one deadline, so the
/// whole acquisition waits at most the legacy 10 s.
fn locked<R>(
    path: &Path,
    locking: Locking,
    legacy_writers: bool,
    f: impl FnOnce() -> Result<R>,
) -> Result<R> {
    let deadline = locking.wait.start();
    let mut guard = record::lock(path)?;
    guard.with_wait(&deadline, || {
        let _mutex = if legacy_writers && locking.legacy_mutex {
            Some(record::mutex_lock(path, &deadline)?)
        } else {
            None
        };
        Ok(f())
    })?
}

/// Write `doc` over the file `snapshot` was read from. An unstamped file is
/// written back unstamped and refuses `record-changed` when its content
/// moved since the read, the check the legacy writers' lock cannot give it
/// otherwise; a stamped file refuses `revision-mismatch` unless the file
/// still holds the snapshot's revision, and gains the next one in place.
/// Only `migrate` adds the two meta keys.
pub fn store(path: &Path, snapshot: &Snapshot, doc: &Document, locking: Locking) -> Result<Stamp> {
    let legacy_writers = snapshot.stamp == Stamp::Legacy;
    locked(path, locking, legacy_writers, || match snapshot.stamp {
        Stamp::Legacy => {
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
            record::replace_atomically(path, &Value::Object(doc.clone()))?;
            Ok(Stamp::Legacy)
        }
        Stamp::Stamped {
            record_version,
            revision,
        } => {
            let found = match record::read_value(path)? {
                Some(Value::Object(current)) => current
                    .get(REVISION_KEY)
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                Some(_) | None => 0,
            };
            if found != revision {
                return Err(agent_runtime::Error::RevisionMismatch {
                    path: path.to_path_buf(),
                    expected: revision,
                    found,
                }
                .into());
            }
            let next = revision + 1;
            let mut out = doc.clone();
            out.insert(REVISION_KEY.to_owned(), Value::from(next));
            record::replace_atomically(path, &Value::Object(out))?;
            Ok(Stamp::Stamped {
                record_version,
                revision: next,
            })
        }
    })
}

// ---------------------------------------------------------------------------
// Inspection and migration
// ---------------------------------------------------------------------------

/// A read-only view of a state file for diagnostics and compatibility.
#[derive(Debug, Clone, Serialize)]
pub struct Inspection {
    pub path: PathBuf,
    pub kind: Kind,
    pub stamp: Stamp,
    /// The object exactly as the file holds it.
    pub state: Value,
}

/// Read every typed field of the file by its kind and return it unchanged.
pub fn inspect(path: &Path) -> Result<Inspection> {
    let Some(snapshot) = load(path)? else {
        return Err(Error::RecordMissing {
            path: path.to_path_buf(),
        });
    };
    validate(path, &snapshot)?;
    Ok(Inspection {
        path: path.to_path_buf(),
        kind: snapshot.kind,
        stamp: snapshot.stamp,
        state: Value::Object(snapshot.doc),
    })
}

/// Where `migrate` keeps the original bytes: `<file>.pre-migration`.
pub fn pre_migration_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(PRE_MIGRATION_SUFFIX);
    path.with_file_name(name)
}

/// What `migrate` did.
#[derive(Debug, Clone, Serialize)]
pub struct Migration {
    pub path: PathBuf,
    pub kind: Kind,
    /// False when the file already carried the current version.
    pub migrated: bool,
    pub stamp: Stamp,
    /// Where the original bytes were kept, when the file was migrated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original: Option<PathBuf>,
}

/// `record_version` and `revision` first, then `fields` in their order,
/// minus any copy of the two keys.
fn stamped(revision: u64, fields: Document) -> Value {
    let mut ordered = Map::new();
    ordered.insert(RECORD_VERSION_KEY.to_owned(), Value::from(RECORD_VERSION));
    ordered.insert(REVISION_KEY.to_owned(), Value::from(revision));
    for (key, value) in fields {
        if key != RECORD_VERSION_KEY && key != REVISION_KEY {
            ordered.insert(key, value);
        }
    }
    Value::Object(ordered)
}

/// Create `<file>.pre-migration` holding `bytes`. A standing copy whose
/// bytes equal the file's is this flow's own leftover from a run that died
/// before the replacement, and is kept as the copy; one that differs refuses
/// `migration-exists`.
fn keep_original(original: &Path, bytes: &[u8]) -> agent_runtime::Result<()> {
    let mut copy = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(original)
    {
        Ok(copy) => copy,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let standing = fs::read(original)
                .map_err(|e| agent_runtime::Error::io("read-original", original, e))?;
            if standing == bytes {
                return Ok(());
            }
            return Err(agent_runtime::Error::refused(
                "migration-exists",
                &[("path", &original.display().to_string())],
            ));
        }
        Err(e) => return Err(agent_runtime::Error::io("create-original", original, e)),
    };
    let kept = copy.write_all(bytes).and_then(|_| copy.sync_all());
    drop(copy);
    if let Err(e) = kept {
        // The copy is this call's own, created exclusively above; with the
        // file untouched there is nothing it preserves.
        let _ = fs::remove_file(original);
        return Err(agent_runtime::Error::io("write-original", original, e));
    }
    Ok(())
}

/// Stamp a legacy file with `record_version` and `revision`, keeping its
/// own bytes beside it as `<file>.pre-migration`. Everything happens under
/// the file's lock (and the legacy mutex where the policy takes one): the
/// whole input is read by its kind, the copy is created, then the stamped
/// record replaces the file with every field in its original order. A newer
/// version, malformed input or a differing standing copy refuses without
/// touching the file; a standing copy equal to the file is a retry of an
/// interrupted run and completes.
pub fn migrate(path: &Path, locking: Locking) -> Result<Migration> {
    let kind = Kind::of_path(path);
    let original = pre_migration_path(path);
    // Judged before the lock, so a missing file gains no lock sidecar; the
    // locked read below is the one that decides.
    if let Err(e) = fs::metadata(path) {
        return Err(match e.kind() {
            std::io::ErrorKind::NotFound => Error::RecordMissing {
                path: path.to_path_buf(),
            },
            _ => agent_runtime::Error::io("stat", path, e).into(),
        });
    }
    locked(path, locking, true, || {
        let bytes = match fs::read(path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Error::RecordMissing {
                    path: path.to_path_buf(),
                });
            }
            Err(e) => return Err(agent_runtime::Error::io("read", path, e).into()),
        };
        let value: Value = serde_json::from_slice(&bytes).map_err(|e| json(path, e))?;
        let snapshot = snapshot_of(path, value)?;
        validate(path, &snapshot)?;
        if let Stamp::Stamped { .. } = snapshot.stamp {
            return Ok(Migration {
                path: path.to_path_buf(),
                kind,
                migrated: false,
                stamp: snapshot.stamp,
                original: None,
            });
        }
        keep_original(&original, &bytes)?;
        record::replace_atomically(path, &stamped(1, snapshot.doc))?;
        Ok(Migration {
            path: path.to_path_buf(),
            kind,
            migrated: true,
            stamp: Stamp::Stamped {
                record_version: RECORD_VERSION,
                revision: 1,
            },
            original: Some(original.clone()),
        })
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

#[cfg(test)]
mod tests {
    use super::*;
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
            ("/x/workflow-state-oversee.json.pre-migration", Kind::Item),
        ];
        for (path, kind) in rows {
            assert_eq!(Kind::of_path(Path::new(path)), kind, "{path}");
        }
    }

    /// Finding 1, probe P1: a file an older init wrote lacks the newest init
    /// fields and still reads, stores and migrates.
    #[test]
    fn a_file_missing_the_newer_init_fields_reads_stores_and_migrates() {
        let dir = tempfile::tempdir().unwrap();
        let rows = [
            ("workflow-state-KEN-4687.json", fixtures::ITEM),
            (FLEET_FILE_NAME, fixtures::FLEET),
        ];
        for (name, text) in rows {
            let legacy = fixtures::without_init_fields(text);
            let path = write(dir.path(), name, &legacy);
            let s = snapshot(&path);
            assert_eq!(s.stamp, Stamp::Legacy, "{name}");
            validate(&path, &s).unwrap();
            for key in fixtures::PRE_2026_INIT_FIELDS {
                assert!(!s.doc.contains_key(*key), "{name}: {key}");
            }
            // An unchanged store writes the same bytes back.
            assert_eq!(
                store(&path, &s, &s.doc, Locking::FLOCK).unwrap(),
                Stamp::Legacy
            );
            assert_eq!(fs::read_to_string(&path).unwrap(), legacy, "{name}");
            inspect(&path).unwrap();
            let migration = migrate(&path, Locking::FLOCK).unwrap();
            assert!(migration.migrated, "{name}");
            let after = object(&path);
            let mut expected = vec!["record_version".to_owned(), "revision".to_owned()];
            expected.extend(keys(&s.doc));
            assert_eq!(keys(&after), expected, "{name}");
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

    /// Finding 2 and decision 33: a store never stamps; only `migrate` adds
    /// the two meta keys.
    #[test]
    fn a_store_on_an_unstamped_file_leaves_it_unstamped() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        let s = snapshot(&path);
        let mut doc = s.doc.clone();
        set(&mut doc, "cycles", 1);
        assert_eq!(
            store(&path, &s, &doc, Locking::FLOCK).unwrap(),
            Stamp::Legacy
        );
        let after = object(&path);
        assert!(!after.contains_key(RECORD_VERSION_KEY));
        assert!(!after.contains_key(REVISION_KEY));
        assert_eq!(after["cycles"], Value::from(1));
        assert_eq!(snapshot(&path).stamp, Stamp::Legacy);
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
        // Stamped by someone else in between: the content check refuses too.
        migrate(&path, Locking::FLOCK).unwrap();
        let err = store(&path, &s, &doc, Locking::FLOCK).unwrap_err();
        assert_eq!(err.key(), "record-changed");
    }

    #[test]
    fn a_stale_revision_refuses_and_the_newer_write_stands() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        migrate(&path, Locking::FLOCK).unwrap();
        let first = snapshot(&path);
        let second = snapshot(&path);
        let mut doc = second.doc.clone();
        set(&mut doc, "cycles", 7);
        assert_eq!(
            store(&path, &second, &doc, Locking::FLOCK).unwrap(),
            Stamp::Stamped {
                record_version: 1,
                revision: 2
            }
        );
        let mut stale = first.doc.clone();
        set(&mut stale, "cycles", 1);
        let err = store(&path, &first, &stale, Locking::FLOCK).unwrap_err();
        assert!(matches!(
            err,
            Error::Runtime(agent_runtime::Error::RevisionMismatch {
                expected: 1,
                found: 2,
                ..
            })
        ));
        let after = object(&path);
        assert_eq!(after["cycles"], Value::from(7));
        assert_eq!(keys(&after)[..2], ["record_version", "revision"]);
    }

    #[test]
    fn a_newer_record_version_refuses_without_touching_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-9999.json", fixtures::NEWER);
        let before = fs::read(&path).unwrap();
        let err = load(&path).unwrap_err();
        assert!(matches!(
            err,
            Error::Runtime(agent_runtime::Error::RecordVersion { found: 99, .. })
        ));
        let err = inspect(&path).unwrap_err();
        assert_eq!(err.key(), "record-version");
        let err = migrate(&path, Locking::FLOCK).unwrap_err();
        assert_eq!(err.key(), "record-version");
        assert_eq!(fs::read(&path).unwrap(), before);
        assert!(!pre_migration_path(&path).exists());
    }

    /// Finding 12 and decision 35: unparsable bytes are `json-invalid`; a
    /// shape this build cannot read is `record-shape`, naming the field.
    #[test]
    fn malformed_input_refuses_by_cause_without_touching_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let rows: [(&str, String, &str, Option<&str>); 6] = [
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
                "revision-without-version",
                "{\"revision\": 3, \"issue_id\": \"KEN-1\"}".to_owned(),
                "record-shape",
                Some("revision"),
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
            let err = migrate(&path, Locking::FLOCK).unwrap_err();
            assert_eq!(err.key(), key, "{name}");
            if let Some(expected) = field {
                let Error::Shape { field, .. } = &err else {
                    panic!("{name}: {err:?}")
                };
                assert_eq!(field, expected, "{name}");
            }
            assert_eq!(fs::read(&path).unwrap(), before, "{name}");
            assert!(!pre_migration_path(&path).exists(), "{name}");
            assert_eq!(inspect(&path).unwrap_err().key(), key, "{name}");
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
    fn migration_keeps_the_original_bytes_and_the_field_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), FLEET_FILE_NAME, fixtures::FLEET);
        let migration = migrate(&path, Locking::FLOCK).unwrap();
        assert!(migration.migrated);
        assert_eq!(migration.kind, Kind::Fleet);
        let original = migration.original.unwrap();
        assert_eq!(fs::read_to_string(&original).unwrap(), fixtures::FLEET);
        let after = object(&path);
        let before_keys: Vec<String> = match serde_json::from_str(fixtures::FLEET).unwrap() {
            Value::Object(map) => map.keys().cloned().collect(),
            _ => unreachable!(),
        };
        let mut expected = vec!["record_version".to_owned(), "revision".to_owned()];
        expected.extend(before_keys);
        assert_eq!(keys(&after), expected);
        assert_eq!(after["revision"], Value::from(1));
        // A second run has nothing to do and makes no second copy.
        let again = migrate(&path, Locking::FLOCK).unwrap();
        assert!(!again.migrated);
        assert_eq!(
            again.stamp,
            Stamp::Stamped {
                record_version: 1,
                revision: 1
            }
        );
        assert!(again.original.is_none());
    }

    /// Finding 10, probe P9, and decision 38: a copy equal to the file is an
    /// interrupted run's leftover and the retry completes; a differing copy
    /// refuses and keeps both files.
    #[test]
    fn a_standing_copy_completes_the_retry_when_equal_and_refuses_when_not() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "workflow-state-KEN-4687.json", fixtures::ITEM);
        fs::write(pre_migration_path(&path), fixtures::ITEM).unwrap();
        let migration = migrate(&path, Locking::FLOCK).unwrap();
        assert!(migration.migrated);
        assert_eq!(
            fs::read_to_string(pre_migration_path(&path)).unwrap(),
            fixtures::ITEM
        );
        assert_eq!(object(&path)["revision"], Value::from(1));

        let path = write(dir.path(), "workflow-state-KEN-4688.json", fixtures::ITEM);
        fs::write(pre_migration_path(&path), "earlier copy").unwrap();
        let err = migrate(&path, Locking::FLOCK).unwrap_err();
        assert_eq!(err.key(), "migration-exists");
        let Error::Runtime(agent_runtime::Error::Refused { fields, .. }) = &err else {
            panic!("{err:?}")
        };
        assert_eq!(
            fields[0],
            (
                "path".to_owned(),
                pre_migration_path(&path).display().to_string()
            )
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), fixtures::ITEM);
        assert_eq!(
            fs::read_to_string(pre_migration_path(&path)).unwrap(),
            "earlier copy"
        );
    }

    #[test]
    fn a_missing_file_reads_as_none_and_inspects_as_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workflow-state-KEN-1.json");
        assert!(load(&path).unwrap().is_none());
        assert_eq!(inspect(&path).unwrap_err().key(), "record-missing");
        assert_eq!(
            migrate(&path, Locking::FLOCK).unwrap_err().key(),
            "record-missing"
        );
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
    /// the unstamped write takes the legacy `mkdir` mutex, so a legacy
    /// writer holding it excludes the store, and the store removes its own
    /// mutex afterwards. After migration the mutex is not taken. The wait
    /// runs on the fake clock and stops at the limit.
    #[test]
    fn without_flock_on_path_the_unstamped_write_takes_the_legacy_mutex() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path_var = std::env::join_paths([&bin]).unwrap();
        let timer = FakeTimer::leaked();
        let locking = Locking {
            wait: short(timer),
            ..Locking::for_host(Some(&path_var))
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
        assert_eq!(migrate(&path, locking).unwrap_err().key(), "lock-timeout");
        assert_eq!(timer.slept().len(), 2 * CLAMPED.len());
        fs::remove_dir(&mutex).unwrap();
        store(&path, &s, &s.doc, locking).unwrap();
        assert!(!mutex.exists());
        migrate(&path, locking).unwrap();
        assert!(!mutex.exists());
        // Stamped: the mutex standing again excludes nothing.
        fs::create_dir(&mutex).unwrap();
        let s = snapshot(&path);
        store(&path, &s, &s.doc, locking).unwrap();
        fs::remove_dir(&mutex).unwrap();
        // With flock on the path the policy takes no mutex.
        fs::write(bin.join("flock"), "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(bin.join("flock"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(!Locking::for_host(Some(&path_var)).legacy_mutex);
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
            ..Locking::for_host(Some(&path_var))
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
