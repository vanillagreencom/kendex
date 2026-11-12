//! Error categories. Every failure names the operation that failed and the
//! identity it failed on; a caller routes on the variant, never on the text.

use std::path::PathBuf;

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
            Error::Refused { key, .. } => key,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
