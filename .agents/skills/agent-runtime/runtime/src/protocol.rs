//! The versioned JSON boundary other languages and hosts speak to this
//! runtime through. Inside the process the typed values are used directly;
//! this module is only their wire shape.

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// The protocol name every reply carries. A reader that does not know it
/// refuses the reply rather than guessing at its fields.
pub const PROTOCOL: &str = "agent-runtime-v1";

/// How far an external effect got. An effect that was asked for and whose
/// outcome could not be read stays `Unconfirmed`: a caller reconciles it
/// before asking for the same effect again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Outcome {
    NotStarted,
    Confirmed,
    Failed,
    Unconfirmed,
}

impl Outcome {
    /// The outcome's word, as a record and a refusal's `outcome=` carry it.
    pub fn word(self) -> &'static str {
        match self {
            Outcome::NotStarted => "not-started",
            Outcome::Confirmed => "confirmed",
            Outcome::Failed => "failed",
            Outcome::Unconfirmed => "unconfirmed",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Refusal {
    pub key: String,
    pub fields: Vec<(String, String)>,
    pub text: String,
}

impl From<&Error> for Refusal {
    /// Every variant renders the values it acted on; a cause or a source
    /// error is the human explanation and stays in `text`.
    fn from(error: &Error) -> Self {
        let pair = |k: &str, v: String| (k.to_owned(), v);
        let fields = match error {
            Error::Refused { fields, .. } => fields.clone(),
            Error::Io {
                operation, path, ..
            } => vec![
                pair("operation", (*operation).to_owned()),
                pair("path", path.display().to_string()),
            ],
            Error::Json { path, .. } | Error::RecordMissing { path } => {
                vec![pair("path", path.display().to_string())]
            }
            Error::RecordVersion {
                path,
                found,
                supported,
            } => vec![
                pair("path", path.display().to_string()),
                pair("found", found.to_string()),
                pair(
                    "supported",
                    supported
                        .iter()
                        .map(u64::to_string)
                        .collect::<Vec<_>>()
                        .join(","),
                ),
            ],
            Error::RevisionMismatch {
                expected, found, ..
            } => vec![
                pair("expected", expected.to_string()),
                pair("found", found.to_string()),
            ],
            Error::RecordShape {
                path,
                field,
                reason,
                ..
            } => vec![
                pair("path", path.display().to_string()),
                pair("field", field.clone()),
                pair("reason", reason.word().to_owned()),
            ],
            Error::IntentOpen { intent, op, target } => vec![
                pair("intent", intent.clone()),
                pair("op", (*op).to_owned()),
                pair("target", target.clone()),
            ],
            Error::IntentUnknown { id }
            | Error::IntentDuplicate { id }
            | Error::IntentStarted { id } => {
                vec![pair("intent_id", id.clone())]
            }
            Error::IntentComplete { id, outcome } => vec![
                pair("intent_id", id.clone()),
                pair("outcome", outcome.word().to_owned()),
            ],
            Error::SetReplaced {
                id,
                expected,
                found,
            } => vec![
                pair("intent_id", id.clone()),
                pair("expected", expected.to_string()),
                pair("found", found.to_string()),
            ],
            Error::OutcomeInvalid { outcome } => vec![pair("outcome", outcome.word().to_owned())],
            Error::OwnerUnreadable { op } => vec![pair("op", (*op).to_owned())],
            Error::Process { pid, operation, .. } => vec![
                pair("pid", pid.to_string()),
                pair("operation", (*operation).to_owned()),
            ],
            Error::External {
                program, operation, ..
            }
            | Error::NotStarted {
                program, operation, ..
            } => vec![
                pair("program", (*program).to_owned()),
                pair("operation", (*operation).to_owned()),
            ],
            Error::Unsupported {
                operation, subject, ..
            } => vec![
                pair("operation", (*operation).to_owned()),
                pair("subject", subject.clone()),
            ],
            Error::OverseerMissing { path } | Error::PendingMissing { path } => {
                vec![pair("path", path.display().to_string())]
            }
            Error::OverseerChanged { path, fields } => vec![
                pair("path", path.display().to_string()),
                pair("fields", fields.join(",")),
            ],
            Error::LaunchMissing { intent, field } => vec![
                pair("intent_id", intent.clone()),
                pair("field", (*field).to_owned()),
            ],
            Error::SuccessionOff => vec![pair(
                "AGENT_RUNTIME_CONTROLLER_SUCCESSION",
                "off".to_owned(),
            )],
            Error::ControllerOff { path, generation } => vec![
                pair("path", path.display().to_string()),
                pair("generation", generation.to_string()),
            ],
            Error::SuccessorAccountSpent { account } => vec![pair("account", account.clone())],
            Error::HandoffSessionMismatch { expected, recorded } => vec![
                pair("expected", expected.clone()),
                pair("recorded", recorded.clone().unwrap_or_default()),
            ],
            Error::TransferFieldMissing { cause, field } => vec![
                pair("cause", (*cause).to_owned()),
                pair("field", (*field).to_owned()),
            ],
            Error::RecoveryUnbound { path, cause } => vec![
                pair("path", path.display().to_string()),
                pair("cause", (*cause).to_owned()),
            ],
            Error::Yielded { id, owner } => vec![
                pair("intent_id", id.clone()),
                pair("owner_pid", owner.pid.to_string()),
                pair("owner_start", owner.start.clone()),
            ],
            Error::RoleMissing { id } => vec![pair("intent_id", id.clone())],
            Error::OverseerLive { path, pid } => vec![
                pair("path", path.display().to_string()),
                pair("pid", pid.to_string()),
            ],
            Error::OverseerUnreadable { path, cause }
            | Error::PredecessorUnproven { path, cause } => vec![
                pair("path", path.display().to_string()),
                pair("cause", cause.clone()),
            ],
            Error::PaneNotHarness { pane, reading } => {
                vec![pair("pane", pane.clone()), pair("reading", reading.clone())]
            }
            Error::JobLaunchFailed { intent, .. } | Error::JobUnclaimed { intent } => {
                vec![pair("intent_id", intent.clone())]
            }
        };
        Refusal {
            key: error.key().to_owned(),
            fields,
            text: error.to_string(),
        }
    }
}

/// One reply on the executable boundary: the protocol, then either a
/// result or a refusal, never both.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reply<T> {
    pub protocol: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
}

impl<T> Reply<T> {
    pub fn ok(result: T) -> Self {
        Reply {
            protocol: PROTOCOL.to_owned(),
            ok: true,
            result: Some(result),
            refusal: None,
        }
    }

    pub fn refused(error: &Error) -> Self {
        Reply {
            protocol: PROTOCOL.to_owned(),
            ok: false,
            result: None,
            refusal: Some(Refusal::from(error)),
        }
    }
}

/// The one keyed diagnostic line a refusal opens with on stderr:
/// `agent-runtime: <key> field=value ...`.
pub fn diagnostic_line(error: &Error) -> String {
    let refusal = Refusal::from(error);
    let mut line = format!("agent-runtime: {}", refusal.key);
    for (field, value) in &refusal.fields {
        line.push(' ');
        line.push_str(field);
        line.push('=');
        line.push_str(value);
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ShapeReason;

    #[test]
    fn a_refusal_opens_with_its_key_and_fields() {
        let error = Error::refused("pane-missing", &[("pane", "%7")]);
        assert_eq!(
            diagnostic_line(&error),
            "agent-runtime: pane-missing pane=%7"
        );
        let reply: Reply<()> = Reply::refused(&error);
        assert!(!reply.ok);
        assert_eq!(reply.protocol, PROTOCOL);
        assert_eq!(reply.refusal.unwrap().key, "pane-missing");
    }

    /// The record errors carry the path and the value the reader refused,
    /// so a caller can act on the line without parsing the text.
    #[test]
    fn record_and_io_refusals_carry_their_path_and_value() {
        let io = std::io::Error::other("denied");
        let json = serde_json::from_str::<serde_json::Value>("{").unwrap_err();
        let rows: [(Error, &[(&str, &str)]); 4] = [
            (
                Error::io("open", "/r/s.json", io),
                &[("operation", "open"), ("path", "/r/s.json")],
            ),
            (
                Error::Json {
                    path: "/r/s.json".into(),
                    source: json,
                },
                &[("path", "/r/s.json")],
            ),
            (
                Error::RecordVersion {
                    path: "/r/s.json".into(),
                    found: 9,
                    supported: &[1, 2],
                },
                &[("path", "/r/s.json"), ("found", "9"), ("supported", "1,2")],
            ),
            (
                Error::RecordShape {
                    path: "/r/s.json".into(),
                    field: "revision".into(),
                    reason: ShapeReason::TypeMismatch,
                    cause: "absent".into(),
                },
                &[
                    ("path", "/r/s.json"),
                    ("field", "revision"),
                    ("reason", "type-mismatch"),
                ],
            ),
        ];
        for (error, expected) in &rows {
            let expected: Vec<(String, String)> = expected
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect();
            assert_eq!(Refusal::from(error).fields, expected, "{}", error.key());
        }
    }

    #[test]
    fn outcomes_serialize_as_kebab_case_words() {
        assert_eq!(
            serde_json::to_string(&Outcome::NotStarted).unwrap(),
            "\"not-started\""
        );
        assert_eq!(
            serde_json::to_string(&Outcome::Unconfirmed).unwrap(),
            "\"unconfirmed\""
        );
    }
}
