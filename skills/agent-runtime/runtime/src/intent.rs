//! The intent row's parts that name no lane or worktree: the process that
//! persisted an intent, the identity of what a launch opened, the failure
//! notice an intent makes and why a reconcile closed it, in the shape the
//! fleet record holds them.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The observation note a reconcile writes when it found the intent's owner
/// still live and deferred to it. The outcome records only
/// this observation; it moves no record.
pub const OWNER_LIVE: &str = "owner-live";
/// The observation note a reconcile writes when the intent's owner could
/// not be read: neither live nor dead is established, so the
/// outcome records the observation and its cause and moves no record, as
/// [`OWNER_LIVE`] does.
pub const OWNER_UNREAD: &str = "owner-unreadable";

/// A lane's launch identity `{pane, server, server_start, pid, start}`.
/// `server_start` is the tmux server's start the runtime's launch published,
/// so the pane is keyed on the server's pid and start; a
/// record the released launcher wrote carries none.
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

/// The process that persisted an intent: its pid and start, read through
/// agent-runtime's one identity reader when the intent was written.
/// A reconcile that finds this process still live defers to
/// it and touches nothing; only a dead or absent owner lets a reconcile
/// complete or fail the intent. An intent may carry none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    /// The runtime writes the number; a string form is read too, so a
    /// record a jq writer produced is not refused.
    #[serde(deserialize_with = "de_pid")]
    pub pid: u64,
    pub start: String,
}

/// Read a pid written as a JSON number or the string a jq `--arg` produced.
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

/// The one failure announcement an intent makes: the keyed line the fleet
/// log holds under `item: overseer`, an `orch-runtime: <note> op=<op>
/// intent=<id> outcome=<outcome>` row, and how the owner notice went. The outcome's own
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
