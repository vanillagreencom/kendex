//! Error categories. Every failure names the operation that failed and the
//! identity it failed on; a caller routes on the variant, never on the text.

use std::path::PathBuf;

use crate::intent::Owner;
use crate::protocol::Outcome;

/// Why a field of a record is not the shape its reader reads. The word
/// is the `reason=` value of a `record-shape` line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShapeReason {
    NotObject,
    NotArray,
    /// The value parsed, but not as the type the field carries.
    TypeMismatch,
}

impl ShapeReason {
    /// The stable word a diagnostic carries.
    pub fn word(self) -> &'static str {
        match self {
            ShapeReason::NotObject => "not-object",
            ShapeReason::NotArray => "not-array",
            ShapeReason::TypeMismatch => "type-mismatch",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{operation} on {path}: {source}")]
    Io {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{path}: not valid JSON: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    /// The record carries a `record_version` this build does not read.
    #[error("{path}: record version {found} is not one of {supported:?}")]
    RecordVersion {
        path: PathBuf,
        found: u64,
        supported: &'static [u64],
    },
    /// A write was asked against a revision the file has moved past.
    #[error("{path}: revision {expected} expected, {found} found")]
    RevisionMismatch {
        path: PathBuf,
        expected: u64,
        found: u64,
    },
    /// A field of a record is not the shape its reader reads; `field`
    /// is the top-level key, with `/<index>` for an array element, and the
    /// empty field is the record itself.
    #[error("{path}: field {field:?} {}: {cause}", reason.word())]
    RecordShape {
        path: PathBuf,
        field: String,
        reason: ShapeReason,
        cause: String,
    },
    #[error("{path}: no state file")]
    RecordMissing { path: PathBuf },
    /// Another operation's intent on the target has not ended; the request
    /// waits for its outcome instead of racing it.
    #[error("intent {intent} ({op}) is open on {target}")]
    IntentOpen {
        intent: String,
        op: &'static str,
        target: String,
    },
    #[error("no intent carries the id {id}")]
    IntentUnknown { id: String },
    /// An intent with this id already stands. The id carries the stamp the
    /// caller minted for the call, so this is a replayed stamp, a programming
    /// error; the standing intent is never written over.
    #[error("an intent already carries the id {id}")]
    IntentDuplicate { id: String },
    #[error("intent {id} already ended as {outcome:?}")]
    IntentComplete { id: String, outcome: Outcome },
    /// A claim of an intent whose effect already recorded a phase: the
    /// prior owner opened something, so a second owner would be a second
    /// effect.
    #[error("intent {id} has started under its owner")]
    IntentStarted { id: String },
    /// A progress write names the obligation set at a revision the record no
    /// longer holds: another handle or process replaced the set since the
    /// writer read it, so the writer's view is stale and it acts on nothing.
    #[error(
        "intent {id}: the obligation set was replaced (revision {expected} written, {found} recorded)"
    )]
    SetReplaced {
        id: String,
        expected: u64,
        found: u64,
    },
    /// `not-started` is the state an intent is created in, never an outcome
    /// an effect reports.
    #[error("{outcome:?} is not an outcome an effect can report")]
    OutcomeInvalid { outcome: Outcome },
    /// The operation persists an intent, and the process asking has no
    /// readable identity to own it with. A contender could not
    /// tell such an intent's live effect from a dead one, so none is written.
    #[error("{op}: no readable process identity to own the intent")]
    OwnerUnreadable { op: &'static str },
    /// A process operation could not be performed or could not be judged.
    #[error("process {operation} pid={pid}: {cause}")]
    Process {
        operation: &'static str,
        pid: u32,
        cause: String,
    },
    /// An external program this crate drives did not answer as expected.
    #[error("{program} {operation}: {cause}")]
    External {
        program: &'static str,
        operation: &'static str,
        cause: String,
    },
    /// An external program this crate drives never started: it could not
    /// be spawned, or its working directory entered. Nothing it would do
    /// was done, where a program that started and gave no answer may have
    /// acted.
    #[error("{program} {operation}: {cause}")]
    NotStarted {
        program: &'static str,
        operation: &'static str,
        cause: String,
    },
    /// The requested operation is outside what the named harness or host
    /// supports; the cause names the missing native capability.
    #[error("{operation} unsupported on {subject}: {cause}")]
    Unsupported {
        operation: &'static str,
        subject: String,
        cause: String,
    },
    #[error("{path}: the fleet state records no overseer")]
    OverseerMissing { path: PathBuf },
    /// A launcher-side write found the intent under another owner: the store
    /// yielded the write to that claimant and the handle acts on nothing;
    /// its caller hands the claimant's state back
    /// through its own route.
    #[error("intent {id} yielded to its claimant {}:{}", owner.pid, owner.start)]
    Yielded { id: String, owner: Owner },
    /// An intent's recorded obligation set carries a row without a role.
    /// The set alone selects the harness, the pane and the wake by role, so
    /// no handle opens on it; the record is closed by hand.
    #[error("intent {id}: an obligation is recorded without a role")]
    RoleMissing { id: String },
    /// A controller is live where a start or an adoption would make a
    /// second one.
    #[error("{path}: the recorded controller (pid {pid}) is live")]
    OverseerLive { path: PathBuf, pid: u64 },
    /// The recorded controller cannot be resolved: its
    /// server start is unrecorded, its record names no server and pane, or
    /// its server is gone or replaced. Nothing proves it terminal, so
    /// nothing replaces it; the remedy is adoption from its pane.
    #[error("{path}: the recorded controller is unproven: {cause}")]
    PredecessorUnproven { path: PathBuf, cause: String },
    /// Whether the recorded controller is live could not be read.
    #[error("{path}: the recorded controller could not be read: {cause}")]
    OverseerUnreadable { path: PathBuf, cause: String },
    /// The pane an adoption names does not hold the harness in its
    /// foreground, so there is no identity to adopt.
    #[error(
        "pane {pane} does not hold the harness: {reading}; open the harness in that pane, or run the request from the pane that holds it"
    )]
    PaneNotHarness { pane: String, reading: String },
    /// The controller record differs from the one the requester saw in the
    /// named fields; the succession compare-and-swap refuses to act on a
    /// record another writer moved.
    #[error("{path}: the overseer record changed in {}", fields.join(","))]
    OverseerChanged { path: PathBuf, fields: Vec<String> },
    /// A confirmed transfer found no `pending` successor to publish.
    #[error("{path}: the overseer records no pending successor")]
    PendingMissing { path: PathBuf },
    /// A transfer confirmation names no successor pane on a server. The
    /// record it publishes is the successor's own, and the successor's watch
    /// start keeps a record only where it names that pane on that server.
    #[error("intent {intent}: the transfer confirmation names no {field}")]
    LaunchMissing { intent: String, field: &'static str },
    /// `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`: no succession is asked for and no
    /// intent persists.
    #[error("succession is off, so no transfer is requested")]
    SuccessionOff,
    /// The controller was stopped on purpose (`off` recorded); no recovery
    /// relaunches it, only an explicit start.
    #[error("{path}: the controller at generation {generation} is off")]
    ControllerOff { path: PathBuf, generation: u64 },
    /// A walled succession's successor would run on the account the wall
    /// spent.
    #[error("the successor account {account} is the spent one")]
    SuccessorAccountSpent { account: String },
    /// A recovery from a standing handoff names a session other than the
    /// recorded controller's.
    #[error("the handoff names session {expected:?}, the record {recorded:?}")]
    HandoffSessionMismatch {
        expected: String,
        recorded: Option<String>,
    },
    /// A transfer cause needs a field the request left out.
    #[error("a {cause} transfer needs {field}")]
    TransferFieldMissing {
        cause: &'static str,
        field: &'static str,
    },
    /// A model-recovery transfer whose binding no longer holds against the
    /// record: the recovery predicate (`controller::transition`'s
    /// `recovery_bound`) read false, and nothing is written.
    #[error("{path}: the recovery request is not bound to the record: {cause}")]
    RecoveryUnbound { path: PathBuf, cause: &'static str },
    /// The detached job that runs a transfer or a stop could not be started;
    /// the request is recorded `failed` and the controller keeps control.
    #[error("intent {intent}: the detached job could not be launched: {cause}")]
    JobLaunchFailed { intent: String, cause: String },
    /// The job launched but never took the intent's owner lease within the
    /// bound; the request is recorded `failed`.
    #[error("intent {intent}: the detached job never claimed the intent")]
    JobUnclaimed { intent: String },
    /// A request refused before any effect. `key` is the stable diagnostic
    /// key and `fields` the values it acted on.
    #[error("refused {key}: {fields:?}")]
    Refused {
        key: &'static str,
        fields: Vec<(String, String)>,
    },
}

impl Error {
    pub fn io(operation: &'static str, path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Error::Io {
            operation,
            path: path.into(),
            source,
        }
    }

    pub fn refused(key: &'static str, fields: &[(&str, &str)]) -> Self {
        Error::Refused {
            key,
            fields: fields
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
        }
    }

    /// The stable key a diagnostic line opens with.
    pub fn key(&self) -> &'static str {
        match self {
            Error::Io { .. } => "io-failed",
            Error::Json { .. } => "json-invalid",
            Error::RecordVersion { .. } => "record-version",
            Error::RevisionMismatch { .. } => "revision-mismatch",
            Error::RecordShape { .. } => "record-shape",
            Error::RecordMissing { .. } => "record-missing",
            Error::IntentOpen { .. } => "intent-open",
            Error::IntentUnknown { .. } => "intent-unknown",
            Error::IntentDuplicate { .. } => "intent-duplicate",
            Error::IntentComplete { .. } => "intent-complete",
            Error::IntentStarted { .. } => "intent-started",
            Error::SetReplaced { .. } => "set-replaced",
            Error::OutcomeInvalid { .. } => "outcome-invalid",
            Error::OwnerUnreadable { .. } => "owner-unreadable",
            Error::Process { .. } => "process-failed",
            Error::External { .. } => "external-failed",
            Error::NotStarted { .. } => "not-started",
            Error::Unsupported { .. } => "unsupported",
            Error::OverseerMissing { .. } => "overseer-missing",
            Error::Yielded { .. } => "intent-yielded",
            Error::RoleMissing { .. } => "role-missing",
            Error::OverseerLive { .. } => "overseer-live",
            Error::PredecessorUnproven { .. } => "predecessor-unproven",
            Error::OverseerUnreadable { .. } => "overseer-unreadable",
            Error::PaneNotHarness { .. } => "pane-not-harness",
            Error::OverseerChanged { .. } => "overseer-changed",
            Error::PendingMissing { .. } => "pending-missing",
            Error::LaunchMissing { .. } => "launch-missing",
            Error::SuccessionOff => "succession-off",
            Error::ControllerOff { .. } => "controller-off",
            Error::SuccessorAccountSpent { .. } => "successor-account-spent",
            Error::HandoffSessionMismatch { .. } => "handoff-session-mismatch",
            Error::TransferFieldMissing { .. } => "transfer-field-missing",
            Error::RecoveryUnbound { .. } => "recovery-unbound",
            Error::JobLaunchFailed { .. } => "job-launch-failed",
            Error::JobUnclaimed { .. } => "job-unclaimed",
            Error::Refused { key, .. } => key,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
