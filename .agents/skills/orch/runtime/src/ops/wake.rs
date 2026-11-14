//! The wake duty's record. A wake is a duty action with no intent, phases or
//! obligations: it delivers one line to a lead or lane read positively idle
//! with unread mail, confirms by a new user turn in that session's own
//! bound file, else reports the harness's capability limit; a hosted lane's
//! line is typed into its window and confirmed by nothing here. Before it
//! types, it records one mark, pane key and unread state, in the watch's own
//! record, and reads that record at the start of each pass, so a crash
//! between the mark and the paste never repeats a nudge for the same unread
//! state; a later unread state is a new wake.
//!
//! The record is the runner's `oversee-watch.wake.json` beside the fleet
//! state, one [`WakeRecord`] written whole by the duty alone
//! (`watch::wake`), never a field of the lane or overseer record, whose
//! other writers replace those records whole. A lane record's own `wake
//! {pid, start}` names a detached print-mode turn run beside the lane's
//! pane on its session: [`wake_identity`] is its one reader, for the
//! duty's hold, the occupancy charge and the close's stop.

use std::collections::BTreeMap;

use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Host;
use crate::state::Lane;
use crate::watch::owner_alert::Word;

/// The target word of the controller's own record.
pub const OVERSEER_TARGET: &str = "overseer";

/// The detached turn a lane record's `wake {pid, start}` names, where it
/// names one: the pid as the number the runtime writes or the string a
/// shell writer's jq `--arg` writes, the start in whatever form its writer
/// read it (`agent_runtime::process::still_runs` reads each).
pub(crate) fn wake_identity(lane: &Lane) -> Option<Identity> {
    let wake = lane.extra.get("wake")?;
    let pid = match wake.get("pid")? {
        Value::Number(n) => n.as_u64()?,
        Value::String(s) => s.parse().ok()?,
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => return None,
    };
    Some(Identity {
        pid: u32::try_from(pid).ok()?,
        start: wake.get("start")?.as_str()?.to_owned(),
    })
}

/// Whether the lane record names a detached print-mode turn that may still
/// run on the lane's session: one `host` reads live under its start, or
/// cannot read. The lane's pane reads idle while such a turn runs, so a
/// paste then starts a second turn beside it; an ended turn, or a later
/// process under its pid, is none.
pub fn turn_runs(lane: &Lane, host: &Host) -> bool {
    wake_identity(lane).is_some_and(|id| !matches!((host.still_runs)(&id), Reading::Gone))
}

/// What a wake answered for the unread state its mark names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "wake", rename_all = "kebab-case")]
pub enum WakeOutcome {
    /// A user turn beyond `turns_before` in the bound session file.
    Delivered { turns_after: u64 },
    /// The paste went in and the bound passed with no such turn; a repeat
    /// re-reads the file and never types again. A hosted lane's paste is
    /// unconfirmed at once (`session-hosted`), and its repeat reads nothing.
    Unconfirmed { cause: String },
    /// No confirmable route for this harness in this state: nothing typed.
    Limit { harness: String, cause: String },
}

/// The mark a wake writes before it types: the pane it types into by its
/// exact key on its server, the unread state the wake is for
/// (the mail duty's row value), the bound file's user-turn count the
/// delivery is confirmed against, the epoch second of the mark, the
/// outcome once known, and, for the overseer alone, where the owner's turn
/// stands for an outcome that left the mail unread (`watch::owner_alert`):
/// `told` once the outcome is on the log, `alerted` once the owner holds
/// the words, none where nothing is owed. `resume` is the last resume typed
/// into the target (the lanes duty's `resume` row as it stood), carried by
/// every later mark for the target, so a resume is typed once whatever mail
/// wake replaces its mark.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WakeMark {
    pub pane: String,
    pub server: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_start: Option<u64>,
    pub unread: String,
    pub turns_before: u64,
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<WakeOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<Word>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
}

impl WakeMark {
    /// Whether this mark is the one for `unread` on the pane `pane` at
    /// `server`: the same unread state typed into the same place.
    pub fn stands_for(&self, unread: &str, pane: &str, server: u64) -> bool {
        self.unread == unread && self.pane == pane && self.server == server
    }
}

/// The watch's wake record: one standing mark per target (an item key or
/// [`OVERSEER_TARGET`]), the latest for that target replacing the earlier;
/// and `follow_start`, the start line of the last follow of the watch's log
/// the duty saw running for the claim (the number its command line carries
/// after the log's path), which is what the controller had consumed. None
/// where no follow was seen.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WakeRecord {
    #[serde(default)]
    pub marks: BTreeMap<String, WakeMark>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_start: Option<u64>,
}

impl WakeRecord {
    /// The target's standing mark.
    pub fn get(&self, target: &str) -> Option<&WakeMark> {
        self.marks.get(target)
    }

    /// Hold `mark` as the target's one mark.
    pub fn set(&mut self, target: &str, mark: WakeMark) {
        self.marks.insert(target.to_owned(), mark);
    }

    /// Drop the target's mark: a paste refused before anything was typed
    /// stands for nothing.
    pub fn clear(&mut self, target: &str) {
        self.marks.remove(target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(unread: &str, outcome: Option<WakeOutcome>) -> WakeMark {
        WakeMark {
            pane: "%3".to_owned(),
            server: 42,
            server_start: Some(7),
            unread: unread.to_owned(),
            turns_before: 2,
            at: 1_769_700_000,
            outcome,
            owner: None,
            resume: None,
        }
    }

    /// The record holds one mark per target, the latest replacing the
    /// earlier; a mark stands for its unread state on its pane and server
    /// alone; a clear drops the target's mark and no other; the bytes
    /// round-trip with the outcome's tag and the follow's start, which an
    /// absent member reads as none seen. Defect: a second mark kept beside
    /// the first so the repeat reads the earlier state and types again, or
    /// one target's clear dropping another's mark.
    #[test]
    fn one_mark_per_target_stands_for_its_unread_state_on_its_pane() {
        let mut record = WakeRecord::default();
        record.set("KEN-1", mark("m-1", None));
        record.set(
            "KEN-1",
            mark("m-2", Some(WakeOutcome::Delivered { turns_after: 3 })),
        );
        record.set(
            OVERSEER_TARGET,
            mark(
                "m-4",
                Some(WakeOutcome::Limit {
                    harness: "codex".into(),
                    cause: "process-running".into(),
                }),
            ),
        );
        record.follow_start = Some(12);
        let held = record.get("KEN-1").unwrap();
        assert!(held.stands_for("m-2", "%3", 42));
        assert!(!held.stands_for("m-1", "%3", 42), "an earlier unread state");
        assert!(!held.stands_for("m-2", "%4", 42), "another pane");
        assert!(!held.stands_for("m-2", "%3", 43), "another server");
        let bytes = serde_json::to_vec(&record).unwrap();
        let read: WakeRecord = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(read, record);
        assert_eq!(
            serde_json::to_value(&record).unwrap()["marks"]["KEN-1"]["outcome"]["wake"],
            "delivered"
        );
        record.clear("KEN-1");
        assert_eq!(record.get("KEN-1"), None);
        assert_eq!(
            record.get(OVERSEER_TARGET).map(|m| m.unread.as_str()),
            Some("m-4")
        );
        assert_eq!(read.follow_start, Some(12));
        let empty: WakeRecord = serde_json::from_str("{}").unwrap();
        assert_eq!(empty, WakeRecord::default());
        let unfollowed: WakeRecord = serde_json::from_str(r#"{"marks":{}}"#).unwrap();
        assert_eq!(unfollowed.follow_start, None, "no follow seen");
    }
}
