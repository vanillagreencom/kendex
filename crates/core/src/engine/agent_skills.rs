//! An agent's skill list: what the declaration holds, merged with what
//! upstream added since the last sync, and where that merge is written.

use crate::error::{CoreError, Result};
use crate::lock::entry_key;
use crate::manifest::Manifest;
use crate::mapping::{EffectiveSkills, effective_skills, skills_key};
use crate::model::ItemKind;
use crate::render::agent::Role;
use crate::source::list_items;

use super::desired::ItemCtx;

/// The agent's skill list, merging anything upstream added since the last
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
        ctx.scope_skills,
        recorded.as_deref().filter(|_| !held),
    );
    if let Some((skill, source_name)) = skills.unresolved.first().zip(fork_source(ctx)) {
        return Err(CoreError::AgentSkillUnavailable {
            name: crate::names::shown(ctx.name),
            skill: crate::names::shown(skill),
            source_name: source_name.to_owned(),
        });
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

/// The catalog this agent was forked out of, or `None` where it is no
/// fork. A fork stops reading that catalog while keeping what the catalog
/// assigned, so it is the source worth naming when the assignment stops
/// resolving — never the local source the fork now reads. Being a fork is
/// also the whole condition for refusing: it is the one case where this
/// change made an agent depend on a source its declaration does not name.
fn fork_source<'a>(ctx: &'a ItemCtx) -> Option<&'a str> {
    ctx.manifest
        .forks
        .get(&ItemKind::Agent)
        .and_then(|forked| forked.get(ctx.name))
        .map(|fork| fork.source.as_str())
}
