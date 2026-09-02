//! Plan-time safety scoring, run over what a plan would write.
//!
//! An item that is not installed yet has nothing to observe, so the only
//! bytes a fresh install can be scored on are the ones the renderers just
//! produced. Every distinct desired rendering is audited here before its
//! ops are planned. Advisory only: the rows inform every surface that shows a
//! score, and nothing is refused or held back over them.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::AuditResult;

use super::desired::DesiredState;

/// One rendered reading's advisory payload and where it applies. Safety and
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
    /// Every harness whose rendering produced this exact content.
    pub harnesses: Vec<HarnessId>,
    pub scope: Scope,
    /// The first artifact path carrying this reading, or the config file
    /// holding the entry. Every finding's location is relative to it.
    pub location: String,
    /// Flattened, so every reader of a serialized row — the app, the CLI,
    /// a fixture — sees `safety`, `quality`, `findings` and `skipped` at
    /// the top level, the same paths `PackageSafety` serves them at.
    #[serde(flatten)]
    pub advisory: AuditResult,
}

/// Score every distinct rendering, collecting the harnesses that share it.
pub(super) fn run(scope: &Scope, state: &DesiredState) -> Vec<ItemSafety> {
    let mut rows = Vec::new();
    for (input, harnesses) in readings(state) {
        let location = input.location.clone();
        let candidate = ItemSafety {
            kind: input.kind,
            name: input.name.clone(),
            harnesses,
            scope: scope.clone(),
            location,
            advisory: crate::quality::audit(input),
        };
        if let Some(existing) = rows.iter_mut().find(|existing| {
            same_item(existing, &candidate)
                && same_advisory(
                    &existing.advisory,
                    &existing.location,
                    &candidate.advisory,
                    &candidate.location,
                )
        }) {
            existing.harnesses.extend(candidate.harnesses);
        } else {
            rows.push(candidate);
        }
    }
    rows
}

fn readings(state: &DesiredState) -> Vec<(crate::quality::AuditInput, Vec<HarnessId>)> {
    let mut readings: Vec<(crate::quality::AuditInput, Vec<HarnessId>)> = Vec::new();
    for item in &state.items {
        let input = input_for(item);
        // Harness-specific paths do not change what the rules read. Equal
        // rendered content therefore has one audit and one shared result.
        if let Some((_, harnesses)) = readings.iter_mut().find(|(existing, _)| {
            existing.kind == input.kind
                && existing.name == input.name
                && existing.content == input.content
        }) {
            harnesses.push(item.harness);
        } else {
            readings.push((input, vec![item.harness]));
        }
    }
    readings
}

fn same_item(left: &ItemSafety, right: &ItemSafety) -> bool {
    left.kind == right.kind && left.name == right.name
}

fn same_advisory(
    left: &AuditResult,
    left_root: &str,
    right: &AuditResult,
    right_root: &str,
) -> bool {
    left.safety == right.safety
        && left.quality == right.quality
        && left.ruleset == right.ruleset
        && left.skipped == right.skipped
        && left.findings.len() == right.findings.len()
        && left
            .findings
            .iter()
            .zip(&right.findings)
            .all(|(left, right)| {
                left.rule == right.rule
                    && left.severity == right.severity
                    && relative(&left.location, left_root) == relative(&right.location, right_root)
                    && left.line == right.line
                    && left.message == right.message
                    && left.remediation == right.remediation
            })
}

fn relative<'a>(location: &'a str, root: &str) -> &'a str {
    if location == root {
        return "";
    }
    location
        .strip_prefix(root)
        .and_then(|rest| rest.strip_prefix('/'))
        .unwrap_or(location)
}

mod input;
use input::input_for;

#[cfg(test)]
mod tests;
