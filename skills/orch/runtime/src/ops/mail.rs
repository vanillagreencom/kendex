//! The mail duty's record types (step5-map § A7, § A8; step6-map § A6;
//! decisions 31, 121 Q1, Q2, 182): the session-channel send's receipt the
//! mailbox hands back, the one operation that writes `lanes[].directive_send`
//! in its two stages, and the duty's own memory of a mailbox. The mailbox
//! writes no orch state (decision 31): `lane-mail` prints the receipt on
//! stderr, and the `send` verb (`crate::send`) applies
//! [`record_directive_send`] before and after the one irreversible send.

use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::ops::Env;
use crate::state::{self, Document, Lane};

/// The one word a credit reads as when the account's credit could not be
/// read or carried no credit body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Word {
    Unread,
}

/// The account's cloud credit as `lanes list` read it at the send, or the
/// word `unread` (the legacy `lm_send_record`'s two forms). The dollars
/// stay the number the listing printed, `0` or `12.5`, so the close row
/// that prints them reads as the legacy's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Credit {
    Read {
        remaining_dollars: Option<serde_json::Number>,
        locked_reason: Option<String>,
    },
    Unread(Word),
}

/// How a session send ended, the three words the legacy record carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SendResult {
    /// The CLI answered `{ok: true}`: the directive is queued.
    Sent,
    /// The CLI's error names an archived session: nothing was delivered.
    Archived,
    /// Any other answer, or a refusal of the mailbox program before the
    /// CLI ran: nothing says the directive was queued.
    Failed,
}

/// The receipt a session-channel directive send earned, as `lane-mail`
/// prints it (`lane-mail: directive-send item= record=`): the send's
/// result, the CLI's words and the credit read at the send. The epoch
/// second is orch's to stamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirectiveSend {
    pub result: SendResult,
    pub text: String,
    pub credit: Credit,
}

/// The `result` word of a send recorded before the CLI runs and not yet
/// settled by its receipt: the owed stage.
pub const OWED: &str = "owed";

/// The writes of one send, in order. `owed` goes on the lane before the
/// mailbox program starts, so a crash after the send leaves a record that
/// says a send is out and a repeat is refused rather than queued twice;
/// `settled` is the receipt stamped over it; `failed` is the operator's
/// mark through the `op` entry for an owed send no receipt settles (the
/// watch's `directive-send-unsettled` line; decision 184 (5)). A send made
/// under a `key` (the validation end notice's `validate-<run_id>`, decision
/// 188 (d)) carries it from the owed write through every settle, so a
/// replay of that notice reads whether this send was its own.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "stage", rename_all = "lowercase")]
pub enum DirectiveWrite {
    /// The directive's text, kept until the receipt replaces it with the
    /// CLI's words. The write names the receipt it will take, by the
    /// request's stamp, so a receipt another send kept settles nothing.
    Owed {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        key: Option<String>,
    },
    /// The receipt, with the epoch second the send ran at.
    Settled { at: u64, send: DirectiveSend },
    /// The operator's cause, recorded as the send's words with the credit
    /// unread and `owner: operator`, so a reader of the record knows the
    /// program's receipt did not settle it.
    Failed { cause: String },
}

/// The `owner` word of a record the operator settled.
const OWNER_OPERATOR: &str = "operator";

/// The operation `record-directive-send`: one stage of a send onto the lane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordDirectiveSend {
    pub item: String,
    pub write: DirectiveWrite,
}

/// What the write recorded: the `directive_send` object as the lane now
/// holds it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirectiveSendRecorded {
    pub item: String,
    pub directive_send: Value,
}

/// The characters of the text the record keeps, the legacy
/// `.text | .[0:300]`.
const TEXT_CHARS: usize = 300;

/// Whether a lane object's `directive_send` stands at the owed stage; read
/// here and by the send's settle over the lane's extra fields.
pub fn owed(lane: &Document) -> bool {
    lane.get("directive_send")
        .and_then(|send| send.get("result"))
        .and_then(Value::as_str)
        == Some(OWED)
}

/// The key a lane object's `directive_send` was made under, where the owed
/// write carried one; a settle keeps it on the record it writes.
fn send_key(lane: &Document) -> Option<String> {
    lane.get("directive_send")
        .and_then(|send| send.get("key"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// `record` with the send's key beside its fields, where one stands.
fn keyed(mut record: Value, key: Option<String>) -> Value {
    if let (Some(key), Some(fields)) = (key, record.as_object_mut()) {
        fields.insert("key".to_owned(), Value::String(key));
    }
    record
}

/// The transition over `lanes[].directive_send` of the lane `r.item` names,
/// additive to every other field of the record. A lane the fleet does not
/// record refuses `lane-missing`. The owed stage, `{result: owed, text,
/// receipt}` with `receipt` the request's stamp, is written only on a lane
/// whose channel is a cloud session (`lane-channel` otherwise: a mailbox
/// lane's send is the mailbox's own, repeatable under its delivery id) and
/// only where no send stands owed (`directive-send-owed`: the earlier send's
/// receipt settles first, or the directive would be queued twice). The
/// settled stage, `{at, result, text, credit}` as the legacy wrote it, is
/// written only over an owed record (`directive-send-unowed`: a record
/// replaced under the send takes no stale receipt), and so is the failed
/// stage, `{at, result: failed, text, credit: unread, owner: operator}`
/// with `at` the request's second (an operator's mark settles only a send
/// that stands owed). A `key` the owed write carried stays on the record
/// through both settles. Dispatched from the fleet transition under its
/// `Request` variant.
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
    let field = format!("lanes/{index}");
    let lane = state::element_mut(path, lanes, index, "lanes")?;
    let directive_send = match &r.write {
        DirectiveWrite::Owed { text, key } => {
            let record: Lane =
                serde_json::from_value(Value::Object(lane.clone())).map_err(|e| Error::Shape {
                    path: path.to_path_buf(),
                    field,
                    reason: crate::error::ShapeReason::TypeMismatch,
                    cause: e.to_string(),
                })?;
            if !record.session_channel() {
                return Err(Error::LaneChannel {
                    item: r.item.clone(),
                });
            }
            if owed(lane) {
                return Err(Error::DirectiveSendOwed {
                    item: r.item.clone(),
                });
            }
            let text: String = text.chars().take(TEXT_CHARS).collect();
            keyed(
                json!({ "result": OWED, "text": text, "receipt": env.round_id() }),
                key.clone(),
            )
        }
        DirectiveWrite::Settled { at, send } => {
            if !owed(lane) {
                return Err(Error::DirectiveSendUnowed {
                    item: r.item.clone(),
                });
            }
            let text: String = send.text.chars().take(TEXT_CHARS).collect();
            keyed(
                json!({
                    "at": at,
                    "result": send.result,
                    "text": text,
                    "credit": send.credit,
                }),
                send_key(lane),
            )
        }
        DirectiveWrite::Failed { cause } => {
            if !owed(lane) {
                return Err(Error::DirectiveSendUnowed {
                    item: r.item.clone(),
                });
            }
            let text: String = cause.chars().take(TEXT_CHARS).collect();
            keyed(
                json!({
                    "at": env.now_secs,
                    "result": SendResult::Failed,
                    "text": text,
                    "credit": Credit::Unread(Word::Unread),
                    "owner": OWNER_OPERATOR,
                }),
                send_key(lane),
            )
        }
    };
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

    /// The fleet fixture with its first lane a cloud session.
    fn cloud_fleet() -> Document {
        let mut doc: Document = serde_json::from_str(FLEET).unwrap();
        doc["lanes"][0]["kind"] = json!("claude-cloud");
        doc["lanes"][0]["host"] = json!("claude-cloud");
        doc
    }

    fn write(item: &str, write: DirectiveWrite) -> RecordDirectiveSend {
        RecordDirectiveSend {
            item: item.into(),
            write,
        }
    }

    fn receipt(result: SendResult, text: &str, credit: Credit) -> DirectiveSend {
        DirectiveSend {
            result,
            text: text.into(),
            credit,
        }
    }

    /// Decision 31's two stages on the lane: `owed` holds the directive's
    /// words and names its receipt by the request's stamp, the receipt
    /// replaces it with the legacy shape, the epoch
    /// second the request's, the words cut at 300 characters, every other
    /// field of the lane as it was; the operator's mark settles an owed
    /// record `failed` with the cause as its words, the credit unread and
    /// `owner: operator`, at the request's second; a second owed write over
    /// a standing one refuses `directive-send-owed`, a receipt or an
    /// operator's mark over a lane not owed refuses `directive-send-unowed`,
    /// a mailbox lane refuses `lane-channel`, a lane the fleet does not
    /// record refuses `lane-missing`, and every refusal writes nothing.
    /// Defect: a send queued twice because its record said nothing was out,
    /// a stale receipt stamped over a replaced record, an operator's mark
    /// overwriting a receipt's, or the record written under another shape
    /// than `lane-close` and `cloud-stall-closed` read.
    #[test]
    fn a_send_is_owed_then_settled_and_each_stage_refuses_out_of_order() {
        let path = Path::new("/w/workflow-state-oversee.json");
        let original = cloud_fleet();
        let mut doc = original.clone();
        let owed = write(
            "KEN-4437",
            DirectiveWrite::Owed {
                text: "x".repeat(400),
                key: None,
            },
        );
        let recorded = record_directive_send(path, &mut doc, &owed, &env()).unwrap();
        let expected = json!({
            "result": "owed",
            "text": "x".repeat(300),
            "receipt": "1769700000000000000-7",
        });
        assert_eq!(recorded.directive_send, expected);
        assert_eq!(doc["lanes"][0]["directive_send"], expected);
        let mut before = doc.clone();
        let again = record_directive_send(path, &mut doc, &owed, &env()).unwrap_err();
        assert_eq!(again.key(), "directive-send-owed");
        assert_eq!(doc, before, "nothing written");
        let settled = write(
            "KEN-4437",
            DirectiveWrite::Settled {
                at: 1_769_700_000,
                send: receipt(
                    SendResult::Archived,
                    &"y".repeat(400),
                    Credit::Read {
                        remaining_dollars: serde_json::Number::from_f64(12.5),
                        locked_reason: None,
                    },
                ),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &settled, &env()).unwrap();
        let expected = json!({
            "at": 1_769_700_000,
            "result": "archived",
            "text": "y".repeat(300),
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
        // A receipt over a settled record: not owed, refused.
        before = doc.clone();
        let unowed = record_directive_send(path, &mut doc, &settled, &env()).unwrap_err();
        assert_eq!(unowed.key(), "directive-send-unowed");
        assert_eq!(doc, before, "nothing written");
        // The next send starts over, and its failed receipt carries the
        // unread credit word.
        record_directive_send(path, &mut doc, &owed, &env()).unwrap();
        let failed = write(
            "KEN-4437",
            DirectiveWrite::Settled {
                at: 1_769_700_001,
                send: receipt(
                    SendResult::Failed,
                    "Session not found",
                    Credit::Unread(Word::Unread),
                ),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &failed, &env()).unwrap();
        assert_eq!(recorded.directive_send["credit"], "unread");
        assert_eq!(recorded.directive_send["result"], "failed");
        // The operator's mark over an owed send no receipt settles, and
        // the same mark over the settled record: refused.
        record_directive_send(path, &mut doc, &owed, &env()).unwrap();
        let by_hand = write(
            "KEN-4437",
            DirectiveWrite::Failed {
                cause: "session reset by hand".into(),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &by_hand, &env()).unwrap();
        let expected = json!({
            "at": 1_769_700_000,
            "result": "failed",
            "text": "session reset by hand",
            "credit": "unread",
            "owner": "operator",
        });
        assert_eq!(recorded.directive_send, expected);
        assert_eq!(doc["lanes"][0]["directive_send"], expected);
        before = doc.clone();
        let unowed = record_directive_send(path, &mut doc, &by_hand, &env()).unwrap_err();
        assert_eq!(unowed.key(), "directive-send-unowed");
        assert_eq!(doc, before, "nothing written");
        // A mailbox lane and a missing lane: refused before any write.
        let mut mailbox: Document = serde_json::from_str(FLEET).unwrap();
        before = mailbox.clone();
        let channel = record_directive_send(path, &mut mailbox, &owed, &env()).unwrap_err();
        assert_eq!(channel.key(), "lane-channel");
        assert_eq!(mailbox, before, "nothing written");
        let missing = write(
            "KEN-NONE",
            DirectiveWrite::Owed {
                text: "Rebase.".into(),
                key: None,
            },
        );
        before = doc.clone();
        let refused = record_directive_send(path, &mut doc, &missing, &env()).unwrap_err();
        assert_eq!(refused.key(), "lane-missing");
        assert_eq!(doc, before, "nothing written");
    }

    /// Decision 188 (d): a send made under a key carries it from the owed
    /// write through the receipt's settle and the operator's mark, and a
    /// send made under none writes no `key`. Defect: a keyed notice's
    /// replay unable to tell the lane's settled send from another send's,
    /// and so sending again or taking another send's result as its own.
    #[test]
    fn a_keyed_send_keeps_its_key_through_every_settle() {
        let path = Path::new("/w/workflow-state-oversee.json");
        let mut doc = cloud_fleet();
        let owed = write(
            "KEN-4437",
            DirectiveWrite::Owed {
                text: "validation-end run=x state=pass".into(),
                key: Some("validate-x".into()),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &owed, &env()).unwrap();
        assert_eq!(
            recorded.directive_send,
            json!({
                "result": "owed",
                "text": "validation-end run=x state=pass",
                "receipt": "1769700000000000000-7",
                "key": "validate-x",
            })
        );
        let settled = write(
            "KEN-4437",
            DirectiveWrite::Settled {
                at: 1_769_700_000,
                send: receipt(SendResult::Sent, "", Credit::Unread(Word::Unread)),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &settled, &env()).unwrap();
        assert_eq!(
            recorded.directive_send,
            json!({
                "at": 1_769_700_000,
                "result": "sent",
                "text": "",
                "credit": "unread",
                "key": "validate-x",
            })
        );
        record_directive_send(path, &mut doc, &owed, &env()).unwrap();
        let by_hand = write(
            "KEN-4437",
            DirectiveWrite::Failed {
                cause: "session reset by hand".into(),
            },
        );
        let recorded = record_directive_send(path, &mut doc, &by_hand, &env()).unwrap();
        assert_eq!(recorded.directive_send["key"], "validate-x");
        assert_eq!(recorded.directive_send["owner"], "operator");
        // A send under no key writes none, and a settle over it adds none.
        let bare = write(
            "KEN-4437",
            DirectiveWrite::Owed {
                text: "Rebase.".into(),
                key: None,
            },
        );
        let recorded = record_directive_send(path, &mut doc, &bare, &env()).unwrap();
        assert!(recorded.directive_send.get("key").is_none(), "{recorded:?}");
        let recorded = record_directive_send(path, &mut doc, &settled, &env()).unwrap();
        assert!(recorded.directive_send.get("key").is_none(), "{recorded:?}");
    }
}
