//! The wake duty's record (step5-map § A9; decisions 118 (2), 121 Q6,
//! 135a, 159). A wake is a duty action with no intent, phases or
//! obligations: it delivers one line to a lead or lane read positively idle
//! with unread mail, confirms by a new user turn in that session's own
//! bound file (decisions 61, 65), else reports the harness's capability
//! limit. Before it types, it records one mark, pane key and unread state,
//! in the watch's own record, and reads that record at the start of each
//! pass, so a crash between the mark and the paste never repeats a nudge
//! for the same unread state; a later unread state is a new wake.
//!
//! The record is the runner's `oversee-watch.wake.json` beside the fleet
//! state, one [`WakeRecord`] written whole by the duty alone
//! (`watch::wake`), never a field of the lane or overseer record (decision
//! 159): the legacy `open-terminal --wake` rewrites a lane's `wake {pid,
//! start}` from its own record, so a mark kept there goes with that write
//! and the same unread state is reported, and on a pasting harness typed,
//! again. The lane's `wake {pid, start}` stays the Codex wake process's
//! identity, charged by occupancy and stopped by the close.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The target word of the controller's own record.
pub const OVERSEER_TARGET: &str = "overseer";

/// What a wake answered for the unread state its mark names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "wake", rename_all = "kebab-case")]
pub enum WakeOutcome {
    /// A user turn beyond `turns_before` in the bound session file.
    Delivered { turns_after: u64 },
    /// The paste went in and the bound passed with no such turn; a repeat
    /// re-reads the file and never types again.
    Unconfirmed { cause: String },
    /// No confirmable route for this harness in this state: nothing typed.
    Limit { harness: String, cause: String },
}

/// The mark a wake writes before it types: the pane it types into by its
/// exact key on its server (decision 99), the unread state the wake is for
/// (the mail duty's row value), the bound file's user-turn count the
/// delivery is confirmed against, the epoch second of the mark, and the
/// outcome once known.
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
}

impl WakeMark {
    /// Whether this mark is the one for `unread` on the pane `pane` at
    /// `server`: the same unread state typed into the same place.
    pub fn stands_for(&self, unread: &str, pane: &str, server: u64) -> bool {
        self.unread == unread && self.pane == pane && self.server == server
    }
}

/// The watch's wake record: one standing mark per target (an item key or
/// [`OVERSEER_TARGET`]), the latest for that target replacing the earlier.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WakeRecord {
    #[serde(default)]
    pub marks: BTreeMap<String, WakeMark>,
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
        }
    }

    /// The record holds one mark per target, the latest replacing the
    /// earlier; a mark stands for its unread state on its pane and server
    /// alone; a clear drops the target's mark and no other; the bytes
    /// round-trip with the outcome's tag. Defect: a second mark kept beside
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
        let empty: WakeRecord = serde_json::from_str("{}").unwrap();
        assert_eq!(empty, WakeRecord::default());
    }
}
