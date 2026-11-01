//! The mail duty's request and record types (step5-map § A7, § A8; decision
//! 121 Q1, Q2): the shapes U5c fills with the batched mailbox read, the
//! overseer-box announcement and the session-channel receipt handed back
//! under decision 31. Defined here so the duty's unit touches no shared
//! file; nothing reads them yet.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The receipt a lane directive's send earned, as the legacy `lm_send_record`
/// wrote it onto `lanes[].directive_send` through `workflow-state update`
/// (decision 31 forbids that write from the mailbox): the send's result and
/// the CLI's words, with the account's cloud credit read at the send.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirectiveSend {
    pub result: String,
    pub words: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_dollars: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked_reason: Option<String>,
}

/// The orch operation that records a directive send's receipt on the lane
/// (U5c): the hand-back the mailbox prints and orch writes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordDirectiveSend {
    pub item: String,
    pub send: DirectiveSend,
}

/// The mail duty's memory of one mailbox: the envelope index it has
/// announced through, the legacy `.mail` `lane-mail` row (step5-map A7).
/// It is the watch's own cursor, never the box's: the controller session's
/// handler acknowledges the box (Q2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailCursor {
    pub item: String,
    pub announced: u64,
}
