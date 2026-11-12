//! The versioned JSON boundary the `orch-runtime` executable answers on. It
//! has agent-runtime's reply shape under its own protocol name, so a reader
//! that knows one knows the other and still cannot mistake the two.

use agent_runtime::protocol::Refusal;
use serde::{Deserialize, Serialize};

use crate::error::Error;

/// The protocol name every reply carries.
pub const PROTOCOL: &str = "orch-runtime-v1";

/// One reply: the protocol, then either a result or a refusal, never both.
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
    /// A successful reply carrying `result`.
    pub fn ok(result: T) -> Self {
        Reply {
            protocol: PROTOCOL.to_owned(),
            ok: true,
            result: Some(result),
            refusal: None,
        }
    }

    /// A refused reply carrying the error's key, fields and text.
    pub fn refused(error: &Error) -> Self {
        Reply {
            protocol: PROTOCOL.to_owned(),
            ok: false,
            result: None,
            refusal: Some(refusal(error)),
        }
    }
}

/// The refusal an error renders as: its key, the values it acted on, and
/// the human text, which alone may carry a parser's or serializer's message.
pub fn refusal(error: &Error) -> Refusal {
    Refusal {
        key: error.key().to_owned(),
        fields: error.fields(),
        text: error.to_string(),
    }
}

/// The one keyed line a refusal opens with on stderr:
/// `orch-runtime: <key> field=value ...`. Values are written as they are,
/// as agent-runtime's line writes them; every field this crate emits is a
/// path, an identifier or a word, never free text.
pub fn diagnostic_line(error: &Error) -> String {
    let mut line = format!("orch-runtime: {}", error.key());
    for (field, value) in error.fields() {
        line.push(' ');
        line.push_str(&field);
        line.push('=');
        line.push_str(&value);
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::LaneStatus;
    use agent_runtime::error::ShapeReason;
    use agent_runtime::intent::EffectOp;

    #[test]
    fn refusals_open_with_their_key_and_fields() {
        let rows: &[(Error, &str)] = &[
            (
                Error::LaneLive {
                    item: "KEN-1".into(),
                    status: LaneStatus::Running,
                },
                "orch-runtime: lane-live item=KEN-1 status=running",
            ),
            (
                Error::OverseerChanged {
                    path: "/s.json".into(),
                    fields: vec!["server".into(), "pane".into()],
                },
                "orch-runtime: overseer-changed path=/s.json fields=server,pane",
            ),
            (
                Error::Runtime(agent_runtime::Error::IntentOpen {
                    intent: "close-resources:KEN-1:1769700000123456789-4242".into(),
                    op: EffectOp::CloseResources.word(),
                    target: "KEN-1".into(),
                }),
                "orch-runtime: intent-open intent=close-resources:KEN-1:1769700000123456789-4242 op=close-resources target=KEN-1",
            ),
            (
                Error::Runtime(agent_runtime::Error::RevisionMismatch {
                    path: "/s.json".into(),
                    expected: 1,
                    found: 2,
                }),
                "orch-runtime: revision-mismatch expected=1 found=2",
            ),
            (
                Error::Runtime(agent_runtime::Error::OverseerMissing {
                    path: "/s.json".into(),
                }),
                "orch-runtime: overseer-missing path=/s.json",
            ),
        ];
        for (error, line) in rows {
            assert_eq!(diagnostic_line(error), *line);
            let reply: Reply<()> = Reply::refused(error);
            assert!(!reply.ok);
            assert_eq!(reply.protocol, PROTOCOL);
            assert_eq!(reply.refusal.unwrap().key, error.key());
        }
    }

    /// Finding 12: a parser's message stays in the text; the fields carry
    /// no value with whitespace, so the line parses as `field=value` pairs.
    #[test]
    fn free_text_stays_out_of_the_fields() {
        let request_cause = "missing field `item` at line 1 column 30";
        let shape_cause = "unknown variant `closing`, expected one of five";
        let rows = [
            (
                Error::Request {
                    path: "/r.json".into(),
                    cause: request_cause.into(),
                },
                request_cause,
            ),
            (
                Error::Runtime(agent_runtime::Error::RecordShape {
                    path: "/s.json".into(),
                    field: "lanes/0".into(),
                    reason: ShapeReason::TypeMismatch,
                    cause: shape_cause.into(),
                }),
                shape_cause,
            ),
        ];
        for (error, cause) in &rows {
            for (field, value) in error.fields() {
                assert!(
                    !value.contains(char::is_whitespace) && !value.contains('='),
                    "{}: {field}={value}",
                    error.key()
                );
            }
            assert!(refusal(error).text.contains(cause), "{}", error.key());
        }
        assert_eq!(
            diagnostic_line(&rows[1].0),
            "orch-runtime: record-shape path=/s.json field=lanes/0 reason=type-mismatch"
        );
    }
}
