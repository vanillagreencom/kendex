//! An agent's skill list: what the declaration holds, merged with what
//! upstream has gained since the last sync, and where that merge is written.

use crate::error::Result;
use crate::lock::entry_key;
use crate::manifest::Manifest;
use crate::mapping::{EffectiveSkills, effective_skills, skills_key};
use crate::model::ItemKind;
use crate::render::agent::Role;
use crate::source::list_items;

use super::desired::ItemCtx;

/// The agent's skill list, merging anything upstream gained since the last
/// sync back into the manifest so the declaration keeps saying what the
/// agent actually renders with. Held (`PlanOptions::hold_upstream_skills`),
/// nothing merges: the list is the declaration's, and `upstream_now`
/// carries the recorded list instead — it is what renders where nothing is
/// declared and what the lock keeps, both exactly as they were.
///
/// A fork's declaration naming a skill no source here offers refuses. That
/// is what a fork costs: the assignment stays while the catalog it names
/// stops being read, so it resolves against the scope, and the scope
/// losing the skill has to be said out loud rather than taking the agent's
/// `## Required Skills` section off in silence. Nothing else refuses — an
/// agent still reading its own catalog is a project that renders today,
/// and what its unreachable names should do is a separate question.
pub(super) fn assigned_skills(
    ctx: &ItemCtx,
    role: Option<Role>,
    updated_manifest: &mut Manifest,
    manifest_changed: &mut bool,
) -> Result<EffectiveSkills> {
    let available = list_items(ctx.sealed, ctx.config, ItemKind::Skill);
    let recorded = ctx.harnesses.iter().find_map(|h| {
        ctx.lock
            .entries
            .get(&entry_key(ItemKind::Agent, ctx.name, *h))
            .and_then(|entry| entry.upstream_skills.clone())
    });
    let held = ctx.hold_upstream_skills;
    let mut skills = effective_skills(
        ctx.name,
        role,
        ctx.manifest,
        ctx.config,
        &available,
        ctx.scope_skills.names(),
        recorded.as_deref().filter(|_| !held),
    );
    if ctx.recorded_fork(ItemKind::Agent)
        && let Some(refusal) = skills.refusal(ctx.name, ctx.scope_skills.names())
    {
        return Err(refusal);
    }
    if held {
        skills.upstream_now = recorded.unwrap_or(skills.upstream_now);
        return Ok(skills);
    }
    if skills.manifest_additions.is_empty() {
        return Ok(skills);
    }
    // The key the effective list was read from. Writing additions anywhere
    // else creates an entry that shadows the one being read, and the
    // shadowed skills silently vanish from the next rendering.
    let key = skills_key(ctx.manifest, ctx.name)
        .unwrap_or(ctx.name)
        .to_owned();
    let entry = updated_manifest.agent_skills.entry(key).or_default();
    for skill in &skills.manifest_additions {
        if !entry.contains(skill) {
            entry.push(skill.clone());
        }
    }
    *manifest_changed = true;
    Ok(skills)
}
