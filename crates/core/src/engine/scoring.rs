//! Plan-time safety scoring, run over what a plan would write.
//!
//! An item that is not installed yet has nothing to observe, so the only
//! bytes a fresh install can be scored on are the ones the renderers just
//! produced. Every desired installation is audited here before its ops are
//! planned. Advisory only: the rows inform every surface that shows a
//! score, and nothing is refused or held back over them.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::AuditResult;

use super::desired::DesiredState;

/// One installation's advisory payload and where it applies. Safety and
/// quality sit side by side inside it and are never combined: one answers
/// whether the content is dangerous, the other whether it is any good, and
/// averaging them would let a well-written attack outscore a clumsy honest
/// skill.
///
/// Planned and installed rows share this shape: the plan preview scores
/// what it would write, the audit scores what is on disk, and the app and
/// the CLI read both. Content not yet installed is scored into
/// `browse::PackageSafety` and `check_catalog::CheckedItem`, which embed
/// the same advisory payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemSafety {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub scope: Scope,
    /// The artifact's path, or the config file holding the entry — what
    /// every finding's location is relative to.
    pub location: String,
    /// Flattened, so every reader of a serialized row — the app, the CLI,
    /// a fixture — sees `safety`, `quality`, `findings` and `skipped` at
    /// the top level, the same paths `PackageSafety` serves them at.
    #[serde(flatten)]
    pub advisory: AuditResult,
}

/// Score every desired installation.
pub(super) fn run(scope: &Scope, state: &DesiredState) -> Vec<ItemSafety> {
    state
        .items
        .iter()
        .map(|item| {
            let input = input_for(item);
            let root = input.location.clone();
            ItemSafety {
                kind: item.kind,
                name: item.name.clone(),
                harness: item.harness,
                scope: scope.clone(),
                location: root,
                advisory: crate::quality::audit(input),
            }
        })
        .collect()
}

mod input;
use input::input_for;
