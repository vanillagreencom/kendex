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
//!
//! Both sides are derived from one source form, which is what a fork
//! installs: one file in the local source that every harness renders from
//! afterwards. Before it, each harness renders from its own installed
//! revision, and those can differ — so a source form read at one revision
//! answers for a harness only if that harness is installed from it.
//! [`one_revision`] is where that is established, and the proof cannot run
//! without it.

use crate::engine::desired::target_harnesses;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::agent::{EffectiveAgent, SourceAgent, access};
use crate::render::permission::Widened;

/// Evidence that one source form answers for every harness the proof
/// covers. Only [`one_revision`] and [`no_catalog`] make one, so a caller
/// cannot reach [`refuse_if_widened`] without having established it.
pub(super) struct OneRevision(());

/// The answer for a renamed fork: its source form is the local file every
/// harness already renders from, so there is no catalog revision behind it
/// and nothing to be at odds about.
pub(super) fn no_catalog() -> OneRevision {
    OneRevision(())
}

/// Refuse a capture whose targeted harnesses are not all installed from
/// the revision it was read at. `read_at` is that revision.
///
/// The proof derives both its sides from one published file, and a
/// harness installed from another revision renders from a different one —
/// which can state tools this file does not, so what that rendering
/// restricts is not readable here and its loss would pass unseen. Reading
/// each harness's own revision instead would mean opening the catalog at
/// every one of them, which is the thing this proof does not do; refusing
/// keeps that boundary and fails closed.
///
/// One rule with two reasons: a harness recorded at another revision, and
/// a harness whose revision is not recorded at all. Both leave the file
/// unable to answer for it, so neither is agreement.
pub(super) fn one_revision(
    env: &Env,
    scope: &Scope,
    after: &Manifest,
    decl: &ItemDecl,
    name: &str,
    read_at: Option<&str>,
) -> Result<OneRevision> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let mut elsewhere: Vec<String> = Vec::new();
    for harness in target_harnesses(decl, after, ItemKind::Agent, scope) {
        // No lock entry is no installation on this harness: nothing was
        // rendered there, so there is no artifact for a name to take a deny
        // off. An entry holding no revision is the opposite case — something
        // is installed and what it was rendered from cannot be established,
        // which is not the same answer as rendering from the same revision.
        let Some(entry) = lock
            .entries
            .get(&crate::lock::entry_key(ItemKind::Agent, name, harness))
        else {
            continue;
        };
        // Compared as written, absence included: a source whose revisions
        // are not commits records none for anybody, and every harness
        // reading that one mutable directory does agree. One recorded and
        // one absent is a disagreement like any other.
        let at = entry.source_commit.as_deref();
        if at == read_at {
            continue;
        }
        elsewhere.push(match at {
            Some(commit) => format!("{} from {commit}", harness.display_name()),
            None => format!(
                "{}, whose revision the lock does not record",
                harness.display_name()
            ),
        });
    }
    if elsewhere.is_empty() {
        return Ok(OneRevision(()));
    }
    Err(CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem: format!(
            "the tool settings {} state{}: {} — this copy is taken from {}, and a published file at one revision does not say what another one restricts. Refresh so every tool sits at the same revision, then keep it",
            match elsewhere.len() {
                1 => "the rendering it leaves behind".to_owned(),
                n => format!("the {n} renderings it leaves behind"),
            },
            if elsewhere.len() == 1 { "s" } else { "" },
            elsewhere.join(", "),
            read_at.unwrap_or("a revision nothing recorded")
        ),
    })
}

/// One side of the comparison: the declaration as that side holds it, and
/// the name the agent answers to there. `kept` is what stands now, `given`
/// what the operation would write.
pub(super) struct Side<'a> {
    pub manifest: &'a Manifest,
    pub name: &'a str,
}

/// Refuse a destination name that widens what any harness this declaration
/// targets leaves the agent able to use. Each side is read under the name
/// it answers to, so a table the move left behind counts as the loss it is.
///
/// Both manifests must already hold everything the rendering they stand
/// for reads, and `source` must answer for every targeted harness —
/// [`OneRevision`] is that second obligation. A value on one side alone is
/// a difference this reports, and the name is the only difference it is
/// meant to find.
pub(super) fn refuse_if_widened(
    scope: &Scope,
    decl: &ItemDecl,
    source: &SourceAgent,
    kept_side: Side,
    given_side: Side,
    _: OneRevision,
) -> Result<()> {
    let (old, new) = (kept_side.name, given_side.name);
    if old == new {
        return Ok(());
    }
    let shown_new = crate::names::shown(new);
    for harness in target_harnesses(decl, given_side.manifest, ItemKind::Agent, scope) {
        let kept_source = under(source, harness, old);
        let given_source = under(source, harness, new);
        let kept = access(&effective(
            &kept_source,
            scope,
            kept_side.manifest,
            harness,
            old,
        ));
        let given = access(&effective(
            &given_source,
            scope,
            given_side.manifest,
            harness,
            new,
        ));
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
/// The manifest is the whole of it. A catalog's own per-harness defaults
/// sit beneath the project's in a rendering, and they reach a fork through
/// the carry its caller folds into both manifests — read from the catalog
/// once, by the capture, rather than opened again here by a proof whose
/// whole subject is an item that has stopped reading it.
///
/// Skills, instructions and hooks are left out: they reach the prose and
/// the file's hook block, never the allow or deny list this compares.
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
