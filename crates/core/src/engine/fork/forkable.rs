//! Which edited renderings a fork can take — the rule `fork` enforces,
//! asked ahead of time so no page offers an action the engine refuses.

use std::path::PathBuf;

use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

use super::skill_content_path;

/// Whether keeping an edit as a fork can capture this rendering: a skill's
/// canonical tree always round-trips, an agent's only from the tools whose
/// format the source parser reads back. The Updates page asks before it
/// offers the action, so the answer is the same one `fork` enforces.
pub fn forkable_harness(kind: ItemKind, harness: HarnessId) -> bool {
    match kind {
        ItemKind::Skill => true,
        ItemKind::Agent => forkable_agent_harness(harness),
        _ => false,
    }
}

fn forkable_agent_harness(harness: HarnessId) -> bool {
    matches!(
        harness,
        HarnessId::Claude | HarnessId::Gemini | HarnessId::Pi
    )
}

/// A captured skill tree in source form: a disabled rendering's
/// `SKILL.md.disabled` becomes `SKILL.md`. A tree holding both never gets
/// here — [`fork`] refuses it first.
pub(super) fn source_form(files: Vec<(PathBuf, Vec<u8>)>) -> Vec<(PathBuf, Vec<u8>)> {
    files
        .into_iter()
        .map(|(rel, bytes)| match rel.to_str() {
            Some("SKILL.md.disabled") => (PathBuf::from("SKILL.md"), bytes),
            _ => (rel, bytes),
        })
        .collect()
}

/// Whether a skill tree carries both `SKILL.md` and `SKILL.md.disabled`:
/// two claims on one source file, which no fork can honour — an apply
/// would rename one onto the other, and discovery reads only one.
pub(super) fn ambiguous_skill_tree(tree: &std::path::Path) -> bool {
    tree.join("SKILL.md").exists() && tree.join("SKILL.md.disabled").exists()
}

/// Whether keeping this rendering's edit as a fork can succeed: the kind
/// and tool allow it, and a skill's tree is unambiguous. The Updates page
/// asks before it offers the action, so the answer is the one `fork`
/// enforces.
pub fn forkable_rendering(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    forkable_harness(kind, harness)
        && (kind != ItemKind::Skill
            || skill_content_path(env, scope, name, harness)
                .is_some_and(|tree| !ambiguous_skill_tree(&tree)))
}
