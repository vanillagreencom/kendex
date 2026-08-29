//! Whether the name a fork or a rename lands under widens what the agent
//! may use.
//!
//! Every harness computes part of its deny list from the agent's own name —
//! Claude's `AskUserQuestion`, Pi's and OpenCode's `question` — so a
//! destination name can take a built-in restriction off, and the
//! declaration can target several harnesses while the operation is invoked
//! from one.
//!
//! The proof is derived, never diffed: for each harness the declaration
//! targets it asks that harness's own rule functions what they leave the
//! agent able to use under each name, and compares the two answers. A rule
//! the renderer grows is therefore answered without this reader being
//! taught about it — the failure the rendering comparison beside it has,
//! where an axis nobody thought to compare is an axis nobody proves.
//!
//! It is not the whole proof of a capture. What the person typed into their
//! own copy of a generated file exists in no declaration, so
//! [`super::stated`] reads that from the file itself; this reads the
//! declaration. The two answer different questions and neither covers the
//! other's.

use crate::engine::desired::target_harnesses;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::agent::{EffectiveAgent, SourceAgent, access};
use crate::render::permission::Widened;

/// Refuse a destination name that widens what any harness this declaration
/// targets leaves the agent able to use. `before` is the manifest the
/// operation started from and `after` the one it will write, each read
/// under the name that side answers to, so a table the move left behind
/// counts as the loss it is.
pub(super) fn refuse_if_widened(
    scope: &Scope,
    before: &Manifest,
    after: &Manifest,
    decl: &ItemDecl,
    source: &SourceAgent,
    old: &str,
    new: &str,
) -> Result<()> {
    if old == new {
        return Ok(());
    }
    let shown_new = crate::names::shown(new);
    for harness in target_harnesses(decl, after, ItemKind::Agent, scope) {
        let kept_source = under(source, harness, old);
        let given_source = under(source, harness, new);
        let kept = access(&effective(&kept_source, scope, before, harness, old));
        let given = access(&effective(&given_source, scope, after, harness, new));
        let problem = match (kept, given) {
            // The harness refuses this agent's tool intent under the new
            // name, so it installs no file for it: no wider artifact.
            (_, Err(_)) => continue,
            (Err(_), Ok(_)) => format!(
                "its {} refusal: {} cannot express this agent's tool intent under its own name, and installs a file for it under {}",
                harness.display_name(),
                harness.display_name(),
                shown_new
            ),
            (Ok(kept), Ok(given)) => match given.widened_over(&kept) {
                Widened::No => continue,
                Widened::Tools(tools) => format!(
                    "the {} tool{} its {} rendering keeps from it, and hands to any agent named {}: {}",
                    tools.len(),
                    if tools.len() == 1 { "" } else { "s" },
                    harness.display_name(),
                    shown_new,
                    tools.join(", ")
                ),
                Widened::PastAnAllowlist(allowed) => format!(
                    "the tool allowlist its {} rendering states, and drops for any agent named {}: {}",
                    harness.display_name(),
                    shown_new,
                    allowed.join(", ")
                ),
            },
        };
        return Err(CoreError::ForkWidensAccess {
            name: crate::names::shown(old),
            problem,
        });
    }
    Ok(())
}

/// The agent under the name one harness would list it by. A
/// plugin-registry catalog spells a namespaced name its own way, and the
/// rules that read the name read the spelling the rendering gives them.
fn under(source: &SourceAgent, harness: HarnessId, name: &str) -> SourceAgent {
    SourceAgent {
        name: crate::harness::rendered_name(harness, name),
        ..source.clone()
    }
}

/// This agent as one harness would render it under `name`, with what the
/// given manifest contributes to its tool policy folded in.
///
/// Skills, instructions and hooks are left out: they reach the prose and
/// the file's hook block, never the allow or deny list this compares, and
/// gathering them would have this reader open a catalog the operation has
/// already stopped reading.
fn effective<'a>(
    source: &'a SourceAgent,
    scope: &'a Scope,
    manifest: &Manifest,
    harness: HarnessId,
    name: &str,
) -> EffectiveAgent<'a> {
    let overrides = manifest
        .agent_frontmatter
        .get(harness.name())
        .and_then(|by_agent| by_agent.get(name))
        .cloned()
        .unwrap_or_default();
    EffectiveAgent {
        permissions: EffectiveAgent::intent(source, &overrides),
        source,
        harness,
        scope,
        skills: Vec::new(),
        overrides,
        launch_instructions: None,
        additional_instructions: None,
        custom_hooks: Vec::new(),
    }
}
