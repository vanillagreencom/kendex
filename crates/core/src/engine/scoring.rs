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
    /// Planned rows group renderings with the same result. Installed rows
    /// describe one scanned installation each.
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

/// Audit byte-distinct renderings once, then group matching results for output.
pub(super) fn run(scope: &Scope, state: &DesiredState) -> Vec<ItemSafety> {
    let mut rows: Vec<ItemSafety> = Vec::new();
    let mut input_rows: HashMap<crate::quality::observe::AuditInputKey, usize> = HashMap::new();
    let mut result_rows: HashMap<(ItemKind, String, AuditResult), usize> = HashMap::new();
    for item in &state.items {
        let input = input_for(item);
        let input_key = input.grouping_key();
        let target = SafetyTarget {
            harness: item.harness,
            location: input.location.clone(),
        };
        if let Some(&row) = input_rows.get(&input_key) {
            rows[row].targets.push(target);
            continue;
        }

        let advisory = crate::quality::audit(input);
        let result_key = (
            item.kind,
            item.name.clone(),
            advisory.grouping_key(&target.location),
        );
        let row = match result_rows.get(&result_key) {
            Some(&row) => {
                rows[row].targets.push(target);
                row
            }
            None => {
                let row = rows.len();
                rows.push(ItemSafety {
                    kind: item.kind,
                    name: item.name.clone(),
                    targets: vec![target],
                    scope: scope.clone(),
                    advisory,
                });
                result_rows.insert(result_key, row);
                row
            }
        };
        input_rows.insert(input_key, row);
    }
    rows
}

mod input;
use input::input_for;

#[cfg(test)]
mod tests;
