//! Plan-time safety scoring, run over what a plan would write.
//!
//! An item that is not installed yet has nothing to observe, so the only
//! bytes a fresh install can be scored on are the ones the renderers just
//! produced. Every distinct desired rendering is audited here before its
//! ops are planned. Advisory only: the rows inform every surface that shows
//! a score, and nothing is refused or held back over them.

use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::HashMap;

use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::AuditResult;

use super::desired::DesiredState;

/// One reported advisory payload and every rendering it describes. Safety and
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
    /// Groups equal plan content; installed rows describe one scan.
    pub targets: Vec<SafetyTarget>,
    pub scope: Scope,
    /// Flattened, so every reader of a serialized row — the app, the CLI,
    /// a fixture — sees `safety`, `quality`, `findings` and `skipped` at
    /// the top level, the same paths `PackageSafety` serves them at.
    #[serde(flatten)]
    pub advisory: AuditResult,
}

/// One rendering covered by a reported advisory payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SafetyTarget {
    pub harness: HarnessId,
    /// The artifact's path, or the config file holding the entry.
    pub location: String,
}

/// Audit each byte-distinct rendering once.
pub(super) fn run(scope: &Scope, state: &DesiredState) -> Vec<ItemSafety> {
    run_with(scope, state, crate::quality::audit)
}

fn run_with(
    scope: &Scope,
    state: &DesiredState,
    mut audit: impl FnMut(crate::quality::AuditInput) -> AuditResult,
) -> Vec<ItemSafety> {
    let mut rows: Vec<ItemSafety> = Vec::new();
    let mut input_rows: HashMap<(String, String), usize> = HashMap::new();
    for item in &state.items {
        let input = input_for(item);
        let input_key = (item.name.clone(), input.content_hash());
        let target = SafetyTarget {
            harness: item.harness,
            location: input.location.clone(),
        };
        if let Some(&row) = input_rows.get(&input_key) {
            rows[row].targets.push(target);
            continue;
        }

        let row = rows.len();
        rows.push(ItemSafety {
            kind: item.kind,
            name: item.name.clone(),
            targets: vec![target],
            scope: scope.clone(),
            advisory: audit(input),
        });
        input_rows.insert(input_key, row);
    }
    rows
}

mod input;
use input::input_for;

#[cfg(test)]
mod tests;
