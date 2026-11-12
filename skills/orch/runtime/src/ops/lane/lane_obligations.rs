//! The lane operation's own obligation set on a close intent: the worktree's
//! validation runs and the lane's local worktree, the kinds the effect
//! engine does not know. It is the intent's `lane_obligations` member, which
//! the intent's frame keeps as written across its own writes; this module is
//! its one reader and its one store transition.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::super::controller::{Progress, ProgressRecorded, yielded_to};
use super::super::intents;
use crate::error::{Error, Result};
use crate::state::{self, Document, Intent, Owner};

/// The intent member the lane set is recorded under.
pub const LANE_OBLIGATIONS: &str = "lane_obligations";

/// The prefix of the word a worktree obligation is discharged by when the
/// close keeps the worktree: `kept:<reason>`, the reason being what the
/// lane record's `kept` field carries.
pub const WORKTREE_KEPT: &str = "kept:";

/// The prefix of the word a worktree obligation is discharged by when the
/// close released the worktree but the worktree package kept a lane mailbox
/// beside the main checkout's: `released:mail-kept:<path>`, the path being
/// what the lane record's `kept_mail` field carries.
pub const WORKTREE_MAIL_KEPT: &str = "released:mail-kept:";

/// One lane obligation of a close, typed by what it is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum LaneObligation {
    /// The worktree's validation runs, owed to their stop.
    Validation,
    /// The lane's local worktree at `path`, an owned resource of the close:
    /// released through the worktree package's removal, or kept with its
    /// reason recorded where removal would lose work.
    Worktree { path: String },
}

/// A lane obligation settled, with the evidence word that settled it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaneDischarged {
    pub obligation: LaneObligation,
    pub by: String,
}

/// The durable lane set of a close intent: what stands, what was discharged
/// and by what. `revision` counts the set's replacements, as the engine's
/// set's does: a write naming an older revision is refused `set-replaced`.
/// Whether anything was signalled is the engine's record alone, which every
/// lane act writes first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LaneObligationRecord {
    #[serde(default)]
    pub standing: Vec<LaneObligation>,
    #[serde(default)]
    pub discharged: Vec<LaneDischarged>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub revision: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
}

impl LaneObligationRecord {
    /// The lane set `intent` records, `None` where it records none; a member
    /// that is not a lane set refuses `record-shape` naming it.
    pub fn of(path: &Path, intent: &Intent) -> Result<Option<LaneObligationRecord>> {
        state::field(path, &intent.extra, LANE_OBLIGATIONS)
    }

    /// Whether the two records hold the same set: everything but the
    /// revision the store assigns.
    fn same_set(&self, other: &LaneObligationRecord) -> bool {
        self.standing == other.standing && self.discharged == other.discharged
    }

    /// The reason the close kept the lane's worktree, where its worktree
    /// obligation was discharged `kept:<reason>`; `None` where it was
    /// released, read gone, or never acquired. The one reader of that word,
    /// which the close's outcome writes onto the lane record as `kept`.
    pub fn worktree_kept(&self) -> Option<&str> {
        self.worktree_word()?.strip_prefix(WORKTREE_KEPT)
    }

    /// The path of a lane mailbox the worktree package kept beside the main
    /// checkout's when the close released the lane's worktree, where its
    /// worktree obligation was discharged `released:mail-kept:<path>`;
    /// `None` otherwise. The one reader of that word, which the close's
    /// outcome writes onto the lane record as `kept_mail`.
    pub fn worktree_mail_kept(&self) -> Option<&str> {
        self.worktree_word()?.strip_prefix(WORKTREE_MAIL_KEPT)
    }

    fn worktree_word(&self) -> Option<&str> {
        self.discharged.iter().find_map(|d| match &d.obligation {
            LaneObligation::Worktree { .. } => Some(d.by.as_str()),
            LaneObligation::Validation => None,
        })
    }
}

/// Write the lane set of an open intent before the act that follows: the
/// lane operation's progress write, made under the owner its handle read,
/// as the engine's is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordLaneProgress {
    pub intent_id: String,
    pub lane_obligations: LaneObligationRecord,
    /// The owner the handle writes under: the write is yielded to a
    /// claimant that holds the intent since; `None` writes always.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub while_owner: Option<Owner>,
}

/// The lane set's compare-and-swap: the write names the revision its handle
/// read the set at and is refused `set-replaced` where the record holds
/// another; a changed set takes the next revision, the same set keeps its
/// own. A write that leaves the document as it was is written nowhere.
pub(in crate::ops) fn record_lane_progress(
    path: &Path,
    doc: &mut Document,
    r: &RecordLaneProgress,
) -> Result<ProgressRecorded> {
    let intents = intents(path, doc)?;
    let index = intents
        .iter()
        .position(|i| i.id == r.intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: r.intent_id.clone(),
        })?;
    let mut intent = intents[index].clone();
    if let Some(owner) = yielded_to(&intent, r.while_owner.as_ref()) {
        return Ok(ProgressRecorded {
            intent,
            progress: Progress::Yielded { owner },
        });
    }
    if !intent.open() {
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    let current = LaneObligationRecord::of(path, &intent)?;
    let mut next = r.lane_obligations.clone();
    if let Some(current) = &current
        && current.revision != next.revision
    {
        return Err(Error::SetReplaced {
            id: intent.id.clone(),
            expected: next.revision,
            found: current.revision,
        });
    }
    next.revision = match &current {
        Some(current) if current.same_set(&next) => current.revision,
        Some(current) => current.revision + 1,
        None => 1,
    };
    let before = doc.clone();
    let value = serde_json::to_value(&next)?;
    intent
        .extra
        .insert(LANE_OBLIGATIONS.to_owned(), value.clone());
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, LANE_OBLIGATIONS, value);
    let progress = if state::same_document(path, doc, &before)? {
        Progress::Unchanged
    } else {
        Progress::Recorded
    };
    Ok(ProgressRecorded { intent, progress })
}
