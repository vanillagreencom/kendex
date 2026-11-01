//! The mail duty's record types (step5-map § A7, § A8; decisions 31, 121
//! Q1, Q2): the session-channel send's receipt the mailbox hands back and
//! the orch operation that stamps it onto the lane record, and the duty's
//! own memory of a mailbox. `lane-mail` prints the record on stderr and,
//! until a runtime verb owns the session send (decision 173), still writes
//! `lanes[].directive_send` itself as the legacy did (decisions 133, 94 (b));
//! [`record_directive_send`] is the runtime's writer for that verb, decision
//! 31's end state.

use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::Env;
use crate::state::{self, Document};

/// The one word a credit reads as when the account's credit could not be
/// read or carried no credit body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Word {
    Unread,
}

/// The account's cloud credit as `lanes list` read it at the send, or the
/// word `unread` (the legacy `lm_send_record`'s two forms).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Credit {
    Read {
        remaining_dollars: Option<f64>,
        locked_reason: Option<String>,
    },
    Unread(Word),
}

/// The receipt a session-channel directive send earned, as `lane-mail`
/// prints it (`lane-mail: directive-send item= record=`): the send's
/// result (`sent`, `archived` or `failed`), the CLI's words and the credit
/// read at the send. The epoch second is orch's to stamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirectiveSend {
    pub result: String,
    pub text: String,
    pub credit: Credit,
}

/// The operation `record-directive-send`: the receipt onto the lane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordDirectiveSend {
    pub item: String,
    pub send: DirectiveSend,
}

/// What the write recorded: the `directive_send` object as the lane now
/// holds it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirectiveSendRecorded {
    pub item: String,
    pub directive_send: Value,
}

/// The characters of the CLI's words the record keeps, the legacy
/// `.text | .[0:300]`.
const TEXT_CHARS: usize = 300;

/// The transition: `lanes[].directive_send = {at, result, text, credit}` on
/// the lane `r.item` names, `at` the request's epoch second, additive to
/// every other field of the record. A lane the fleet does not record
/// refuses `lane-missing` and writes nothing. Dispatched from the fleet
/// transition under its `Request` variant.
pub fn record_directive_send(
    path: &Path,
    doc: &mut Document,
    r: &RecordDirectiveSend,
    env: &Env,
) -> Result<DirectiveSendRecorded> {
    let lanes = state::array_mut(path, doc, "lanes")?;
    let index = lanes
        .iter()
        .position(|lane| lane.get("item").and_then(Value::as_str) == Some(r.item.as_str()))
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    let lane = state::element_mut(path, lanes, index, "lanes")?;
    let text: String = r.send.text.chars().take(TEXT_CHARS).collect();
    let directive_send = json!({
        "at": env.now_secs,
        "result": r.send.result,
        "text": text,
        "credit": r.send.credit,
    });
    state::set(lane, "directive_send", directive_send.clone());
    Ok(DirectiveSendRecorded {
        item: r.item.clone(),
        directive_send,
    })
}

/// The mail duty's memory of one mailbox: the envelope line it has
/// announced through and the id the box opened with, the legacy `.mail`
/// `lane-mail` row (step5-map A7). It is the watch's own cursor, never the
/// box's: the controller session's handler acknowledges the box (Q2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailCursor {
    pub announced: u64,
    pub first: String,
}

impl MailCursor {
    /// The row's value, `<announced> <first>`; a row that is not that reads
    /// as nothing announced, as the legacy read a row short of its count.
    pub fn parse(row: Option<&str>) -> MailCursor {
        let (announced, first) = row
            .and_then(|r| r.split_once(' '))
            .map(|(a, f)| (a, f.to_owned()))
            .unwrap_or((row.unwrap_or(""), String::new()));
        match announced.parse() {
            Ok(announced) => MailCursor { announced, first },
            Err(_) => MailCursor {
                announced: 0,
                first: String::new(),
            },
        }
    }

    pub fn render(&self) -> String {
        format!("{} {}", self.announced, self.first)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::Env;

    const FLEET: &str = include_str!("../../../tests/rust/fixtures/workflow-state-oversee.json");

    fn env() -> Env {
        Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 7,
            owner: None,
        }
    }

    /// Decision 31's hand-back stamped by orch: `directive_send` as the
    /// legacy `lm_send_record` wrote it, the epoch second the request's,
    /// the words cut at 300 characters, every other field of the lane as
    /// it was; a lane the fleet does not record refuses `lane-missing`
    /// and writes nothing. Defect: the record written under another shape
    /// than `lane-close` and `cloud-stall-closed` read, or onto the wrong
    /// lane.
    #[test]
    fn the_receipt_is_stamped_onto_its_lane_and_a_missing_lane_is_refused() {
        let path = Path::new("/w/workflow-state-oversee.json");
        let original: Document = serde_json::from_str(FLEET).unwrap();
        let mut doc = original.clone();
        let r = RecordDirectiveSend {
            item: "KEN-4437".into(),
            send: DirectiveSend {
                result: "archived".into(),
                text: "x".repeat(400),
                credit: Credit::Read {
                    remaining_dollars: Some(12.5),
                    locked_reason: None,
                },
            },
        };
        let recorded = record_directive_send(path, &mut doc, &r, &env()).unwrap();
        let expected = json!({
            "at": 1_769_700_000,
            "result": "archived",
            "text": "x".repeat(300),
            "credit": {"remaining_dollars": 12.5, "locked_reason": null},
        });
        assert_eq!(recorded.directive_send, expected);
        assert_eq!(doc["lanes"][0]["directive_send"], expected);
        let mut stamped = doc["lanes"][0].as_object().unwrap().clone();
        stamped.remove("directive_send");
        assert_eq!(
            Value::Object(stamped),
            original["lanes"][0],
            "every other field as it was"
        );
        assert_eq!(
            doc["lanes"][1], original["lanes"][1],
            "the other lane untouched"
        );
        let unread = RecordDirectiveSend {
            item: "KEN-4437".into(),
            send: DirectiveSend {
                result: "failed".into(),
                text: "Session not found".into(),
                credit: Credit::Unread(Word::Unread),
            },
        };
        let recorded = record_directive_send(path, &mut doc, &unread, &env()).unwrap();
        assert_eq!(recorded.directive_send["credit"], "unread");
        let missing = RecordDirectiveSend {
            item: "KEN-NONE".into(),
            ..unread
        };
        let before = doc.clone();
        let refused = record_directive_send(path, &mut doc, &missing, &env()).unwrap_err();
        assert_eq!(refused.key(), "lane-missing");
        assert_eq!(doc, before, "nothing written");
    }
}
