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
use crate::quality::{AuditInput, Content, QualityScore, SafetyScore, SkippedRule};

use super::desired::DesiredState;

/// One installation's two scores and everything behind them. Safety and
/// quality sit side by side and are never combined: one answers whether the
/// content is dangerous, the other whether it is any good, and averaging
/// them would let a well-written attack outscore a clumsy honest skill.
///
/// This is the one advisory shape every surface reads — the plan preview,
/// the audit, the app and the CLI all speak in these rows.
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
    pub safety: SafetyScore,
    /// Advisory too, and absent for kinds with no authored prose.
    pub quality: Option<QualityScore>,
    pub findings: Vec<crate::quality::Finding>,
    /// Rules that apply to this kind but had no bytes to read here.
    pub skipped: Vec<SkippedRule>,
}

/// Score every desired installation.
pub(super) fn run(scope: &Scope, state: &DesiredState) -> Vec<ItemSafety> {
    state
        .items
        .iter()
        .map(|item| {
            let input = input_for(item);
            let root = input.location.clone();
            let result = crate::quality::audit(input);
            ItemSafety {
                kind: item.kind,
                name: item.name.clone(),
                harness: item.harness,
                scope: scope.clone(),
                location: root,
                safety: result.safety,
                quality: result.quality,
                findings: result.findings,
                skipped: result.skipped,
            }
        })
        .collect()
}

/// The identity of the bytes the rules read — the cache key browsing scores
/// under, so a re-read of the same content is answered without re-scoring.
pub(crate) fn content_hash(input: &AuditInput) -> String {
    // The location deliberately stays out of the material: the two scoring
    // paths read the same bytes at different paths — the plan at the
    // canonical tree, the audit at the harness-native link — and the same
    // files are the same content wherever they sit.
    let mut material = format!("{}|", input.kind.name());
    match &input.content {
        Content::Document { text } => material.push_str(text),
        // Sorted, because a plan builds the tree in render order and a scan
        // reads it back in directory order. The same files are the same
        // content whichever order they arrived in.
        Content::SkillTree { files } => {
            let mut entries: Vec<String> = files
                .iter()
                .map(|file| {
                    format!(
                        "{}:{}:{}\n",
                        file.path.display(),
                        file.bytes,
                        file.text.as_deref().unwrap_or_default()
                    )
                })
                .collect();
            entries.sort();
            material.push_str(&entries.concat());
        }
        Content::Hook {
            event,
            matcher,
            command,
            values,
            script,
        } => {
            material.push_str(&format!(
                "{event}|{}|{command}|{}",
                matcher.as_deref().unwrap_or_default(),
                script.as_deref().unwrap_or_default()
            ));
            // Appended, not slotted, so a planned hook — which stores no
            // values — hashes exactly as it did. Digested first, so a value
            // carrying the join character cannot move a boundary.
            if let Some(values) = values {
                material.push('|');
                material.push_str(&crate::hash::hash_bytes(values.as_bytes()));
            }
        }
        Content::Mcp(entry) => material.push_str(&format!("{entry:?}")),
        Content::Plugin(sources) => material.push_str(&format!("{sources:?}")),
        Content::Unread { why } => material.push_str(why),
    }
    crate::hash::hash_bytes(material.as_bytes())
}

mod input;
use input::input_for;
