//! What an operation hands a person, the same for the terminal and the
//! window: how much an item needs from them, the changes a yes covers, and
//! which of those changes a later plan of the same run still covers.
//!
//! A vocabulary, not an owner. Whether an install may run is the engine's
//! answer ([`crate::engine::EngineReport`]), whether a commit is on offer is
//! [`crate::commit_offer`]'s, and both shells draw what those owners decide
//! through the words here. Nothing in this module runs anything.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::PlannedOp;
use crate::engine::{EngineReport, SetChange};

/// How much an item needs from the person. The producer decides which: a
/// renderer draws the class it is handed and never infers it from words.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum Need {
    /// The run cannot go on with this item until something outside the run
    /// changes. Drawn as a failure, with the way out where there is one.
    Blocked,
    /// The run waits on a choice among the ways it offers.
    Decision,
    /// Information. Nothing to choose.
    Notice,
}

/// A declared Pi package a settle brings to its source, read before the yes
/// that lets it write. The settle installs outside any plan, so its change
/// is counted in packages beside the plan's ops.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PiSettle {
    pub name: String,
    pub change: PiChange,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PiChange {
    /// Declared and not installed in this scope yet.
    Missing,
    /// Installed from a source that has moved on since: the version and
    /// the source identity it moves from and to.
    Stale {
        from_version: Option<String>,
        to_version: Option<String>,
        from: String,
        to: String,
    },
}

/// One change a yes covers, in the unit of the writer that makes it.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// One op of a scope's plan, which the plan's apply counts.
    Op(PlannedOp),
    /// One package a Pi settle installs or updates, which the settle
    /// counts.
    Pi(PiSettle),
}

/// The changes one question asks about. The list the question draws and
/// the number it asks about are both read off this one value, so a
/// question cannot count a change it did not show.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Consent {
    pub effects: Vec<Effect>,
}

impl Consent {
    /// Every op the plan writes and every package the settle lands, in the
    /// order they run: the settle first, then the plan derived after it.
    pub fn of(report: &EngineReport, settles: &[PiSettle]) -> Consent {
        let settles = settles.iter().cloned().map(Effect::Pi);
        let ops = report.plan.ops.iter().cloned().map(Effect::Op);
        Consent {
            effects: settles.chain(ops).collect(),
        }
    }

    /// How many changes the question asks about.
    pub fn count(&self) -> usize {
        self.effects.len()
    }

    pub fn is_empty(&self) -> bool {
        self.effects.is_empty()
    }
}

/// What a yes approved, held so a plan derived later in the same run can be
/// read against it. Bound to each op's kind, landed position and content,
/// never to the words a preview drew for it, so an op whose words match
/// one approved but writes something else is a change nobody approved.
#[derive(Debug, Clone, Default)]
pub struct Approved {
    ops: Vec<PlannedOp>,
    set_changes: Vec<SetChange>,
}

/// What a later plan writes that its run's yes did not cover.
#[derive(Debug, Default)]
pub struct Added<'a> {
    /// The ops no approved op makes the same change as: what the further
    /// question counts.
    pub consent: Consent,
    /// The installs and removals it names that the yes did not. Said
    /// beside the question; what is asked about is the ops that make them.
    pub set_changes: Vec<&'a SetChange>,
}

impl Approved {
    /// What a yes to `consent`, asked over `report`, approved.
    pub fn of(report: &EngineReport, consent: &Consent) -> Approved {
        Approved {
            ops: consent
                .effects
                .iter()
                .filter_map(|effect| match effect {
                    Effect::Op(planned) => Some(planned.clone()),
                    Effect::Pi(_) => None,
                })
                .collect(),
            set_changes: report.set_changes.clone(),
        }
    }

    /// What `later` writes beyond this approval. An op this approval holds
    /// that `later` drops is no new change: writing less than was approved
    /// asks nothing.
    pub fn added<'a>(&self, later: &'a EngineReport) -> Added<'a> {
        Added {
            consent: Consent {
                effects: later
                    .plan
                    .ops
                    .iter()
                    .filter(|planned| {
                        !self
                            .ops
                            .iter()
                            .any(|approved| approved.op.same_effect(&planned.op))
                    })
                    .cloned()
                    .map(Effect::Op)
                    .collect(),
            },
            set_changes: later
                .set_changes
                .iter()
                .filter(|change| !self.set_changes.contains(change))
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests;
