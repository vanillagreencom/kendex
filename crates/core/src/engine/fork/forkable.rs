//! Which edited renderings a fork can take — the rule `fork` enforces,
//! asked ahead of time so no page offers an action the engine refuses.

use std::path::PathBuf;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};

/// Whether a fork can take this kind at all, or why not. Only a skill and
/// an agent are stored in the local source in a form the source parser
/// reads back, so only those two have a fork path — and every question a
/// fork asks about a name, its destinations included, is asked in terms of
/// how that kind renders. A fork entry does not prove the kind: detach
/// writes one for every kind it converts, and the manifest's own
/// `[forks.<kind>.<name>]` table takes any of them, so the gate is asked of
/// the kind rather than read off the table.
///
/// All three fork verbs ask it as their first statement. The dispatch in
/// `edited_rendering` still refuses an unadmitted kind, as the fallthrough
/// of a match that has to enumerate kinds anyway — defence in depth behind
/// this gate, not a second policy: the only way the two can disagree is
/// this one widening, which lands there on a refusal rather than a write.
pub(crate) fn forkable_kind(kind: ItemKind, name: &str) -> Result<()> {
    match kind {
        ItemKind::Skill | ItemKind::Agent => Ok(()),
        other => Err(unsupported_kind(other, name)),
    }
}

/// The refusal [`forkable_kind`] gives, for the one caller that has
/// already matched the two kinds it admits and needs the error rather
/// than the question.
pub(crate) fn unsupported_kind(kind: ItemKind, name: &str) -> CoreError {
    CoreError::ItemNotInSource {
        name: name.to_owned(),
        source_name: format!("fork does not support {} yet", kind.name()),
    }
}

/// Whether a harness rendering can be parsed as source form. This format check
/// does not prove capture will succeed.
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
/// here — [`super::fork`] refuses it first.
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

/// Full fork eligibility for Updates, using the read-only capture shared with
/// `fork` so the page offers no action that direct capture would refuse.
pub fn forkable_rendering(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    let Ok(manifest) = crate::engine::ops::manifest_for_mutation(env, scope) else {
        return false;
    };
    let Some(decl) = manifest.declared(kind).get(name) else {
        return false;
    };
    if decl.source == crate::manifest::LOCAL_SOURCE_NAME
        || decl.source == crate::manifest::INPLACE_SOURCE_NAME
    {
        return false;
    }
    super::capture_rendering(env, scope, kind, name, harness, &manifest, decl).is_ok()
}
