//! Error categories. Every failure names the operation that refused and the
//! identity it refused on; a caller routes on the variant, never on the text,
//! and the diagnostic line opens with `key()`. A field value never carries
//! a serializer's or parser's own message: that text is the human line.

use std::path::PathBuf;

use agent_runtime::protocol::Outcome;

use crate::state::{EffectOp, Kind, LaneStatus};

/// Why a field of a record is not the shape the operations read. The word
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
    /// A record, lock, process or protocol failure agent-runtime reported.
    #[error(transparent)]
    Runtime(#[from] agent_runtime::Error),
    #[error("{path}: no state file")]
    RecordMissing { path: PathBuf },
    /// A field of the record is not the shape an operation reads; `field`
    /// is the top-level key, with `/<index>` for an array element, and the
    /// empty field is the record itself.
    #[error("{path}: field {field:?} {}: {cause}", reason.word())]
    Shape {
        path: PathBuf,
        field: String,
        reason: ShapeReason,
        cause: String,
    },
    /// The request's operation belongs to the other kind of state file.
    #[error("{op} applies to the {wanted:?} state, {path} is the {kind:?} state")]
    OpKind {
        op: &'static str,
        path: PathBuf,
        kind: Kind,
        wanted: Kind,
    },
    #[error("{path}: not an operation request: {cause}")]
    Request { path: PathBuf, cause: String },
    #[error("no lane record names {item}")]
    LaneMissing { item: String },
    /// The lane is in flight, so a launch or an adoption would make a second
    /// controller for the item.
    #[error("the lane for {item} is {}", status.word())]
    LaneLive { item: String, status: LaneStatus },
    #[error("the lane for {item} is done")]
    LaneDone { item: String },
    /// Another operation's intent on the target has not ended; the request
    /// waits for its outcome instead of racing it.
    #[error("intent {intent} ({}) is open on {target}", op.word())]
    IntentOpen {
        intent: String,
        op: EffectOp,
        target: String,
    },
    /// The lane was relaunched after the intent was written, so the outcome
    /// describes a session the record no longer holds.
    #[error("intent {intent} predates the relaunch of {target}")]
    IntentStale { intent: String, target: String },
    #[error("no round stage carries {round_id}")]
    RoundUnknown { round_id: String },
    /// No validation stage of the round names the run directory.
    #[error("no validation stage of round {round_id} names {run_dir}")]
    RunUnknown { round_id: String, run_dir: String },
    /// A later round of the same kind superseded this one; its result is
    /// kept as history and is not the current round's.
    #[error("round {round_id} was superseded")]
    RoundSuperseded { round_id: String },
    #[error("{path}: the fleet state records no overseer")]
    OverseerMissing { path: PathBuf },
    /// The overseer record differs from the one the requester saw in the
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
    #[error("no intent carries the id {id}")]
    IntentUnknown { id: String },
    /// An intent with this id already stands. The id carries the stamp the
    /// caller minted for the call, so this is a replayed stamp, a programming
    /// error; the standing intent is never written over.
    #[error("an intent already carries the id {id}")]
    IntentDuplicate { id: String },
    #[error("intent {id} already ended as {outcome:?}")]
    IntentComplete { id: String, outcome: Outcome },
    /// `not-started` is the state an intent is created in, never an outcome
    /// an effect reports.
    #[error("{outcome:?} is not an outcome an effect can report")]
    OutcomeInvalid { outcome: Outcome },
}

fn word(outcome: Outcome) -> String {
    serde_json::to_value(outcome)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

impl Error {
    /// The stable key a diagnostic line opens with.
    pub fn key(&self) -> &'static str {
        match self {
            Error::Runtime(e) => e.key(),
            Error::RecordMissing { .. } => "record-missing",
            Error::Shape { .. } => "record-shape",
            Error::OpKind { .. } => "op-kind",
            Error::Request { .. } => "request-invalid",
            Error::LaneMissing { .. } => "lane-missing",
            Error::LaneLive { .. } => "lane-live",
            Error::LaneDone { .. } => "lane-done",
            Error::IntentOpen { .. } => "intent-open",
            Error::IntentStale { .. } => "intent-stale",
            Error::RoundUnknown { .. } => "round-unknown",
            Error::RunUnknown { .. } => "run-unknown",
            Error::RoundSuperseded { .. } => "round-superseded",
            Error::OverseerMissing { .. } => "overseer-missing",
            Error::OverseerChanged { .. } => "overseer-changed",
            Error::PendingMissing { .. } => "pending-missing",
            Error::LaunchMissing { .. } => "launch-missing",
            Error::IntentUnknown { .. } => "intent-unknown",
            Error::IntentDuplicate { .. } => "intent-duplicate",
            Error::IntentComplete { .. } => "intent-complete",
            Error::OutcomeInvalid { .. } => "outcome-invalid",
        }
    }

    /// The values the refusal acted on, as `field=value` pairs. A cause or
    /// a parser's message is not among them.
    pub fn fields(&self) -> Vec<(String, String)> {
        let pair = |k: &str, v: String| (k.to_owned(), v);
        match self {
            Error::Runtime(e) => agent_runtime::protocol::Refusal::from(e).fields,
            Error::RecordMissing { path }
            | Error::Request { path, .. }
            | Error::OverseerMissing { path }
            | Error::PendingMissing { path } => vec![pair("path", path.display().to_string())],
            Error::Shape {
                path,
                field,
                reason,
                ..
            } => vec![
                pair("path", path.display().to_string()),
                pair("field", field.clone()),
                pair("reason", reason.word().to_owned()),
            ],
            Error::OpKind {
                op,
                path,
                kind,
                wanted,
            } => vec![
                pair("op", (*op).to_owned()),
                pair("path", path.display().to_string()),
                pair("kind", kind.word().to_owned()),
                pair("wanted", wanted.word().to_owned()),
            ],
            Error::LaneMissing { item } | Error::LaneDone { item } => {
                vec![pair("item", item.clone())]
            }
            Error::LaneLive { item, status } => vec![
                pair("item", item.clone()),
                pair("status", status.word().to_owned()),
            ],
            Error::IntentOpen { intent, op, target } => vec![
                pair("intent", intent.clone()),
                pair("op", op.word().to_owned()),
                pair("target", target.clone()),
            ],
            Error::IntentStale { intent, target } => vec![
                pair("intent", intent.clone()),
                pair("target", target.clone()),
            ],
            Error::LaunchMissing { intent, field } => vec![
                pair("intent_id", intent.clone()),
                pair("field", (*field).to_owned()),
            ],
            Error::RoundUnknown { round_id } | Error::RoundSuperseded { round_id } => {
                vec![pair("round_id", round_id.clone())]
            }
            Error::RunUnknown { round_id, run_dir } => vec![
                pair("round_id", round_id.clone()),
                pair("run_dir", run_dir.clone()),
            ],
            Error::OverseerChanged { path, fields } => vec![
                pair("path", path.display().to_string()),
                pair("fields", fields.join(",")),
            ],
            Error::IntentUnknown { id } | Error::IntentDuplicate { id } => {
                vec![pair("intent_id", id.clone())]
            }
            Error::IntentComplete { id, outcome } => vec![
                pair("intent_id", id.clone()),
                pair("outcome", word(*outcome)),
            ],
            Error::OutcomeInvalid { outcome } => vec![pair("outcome", word(*outcome))],
        }
    }
}

/// A reply or request value that would not serialize; the path names the
/// in-process value, there being no file.
impl From<serde_json::Error> for Error {
    fn from(source: serde_json::Error) -> Self {
        Error::Runtime(agent_runtime::Error::Json {
            path: PathBuf::from("<value>"),
            source,
        })
    }
}

pub type Result<T> = std::result::Result<T, Error>;
