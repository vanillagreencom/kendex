//! An agent's skill list: what the declaration holds, merged with what
//! upstream added since the last sync, and where that merge is written.

use crate::lock::entry_key;
use crate::manifest::Manifest;
use crate::mapping::{EffectiveSkills, effective_skills};
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
pub(super) fn assigned_skills(
    ctx: &ItemCtx,
    role: Option<Role>,
    updated_manifest: &mut Manifest,
    manifest_changed: &mut bool,
) -> EffectiveSkills {
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
        recorded.as_deref().filter(|_| !held),
    );
    if held {
        skills.upstream_now = recorded.unwrap_or(skills.upstream_now);
        return skills;
    }
    if skills.manifest_additions.is_empty() {
        return skills;
    }
    let entry = updated_manifest
        .agent_skills
        .entry(merge_key(ctx.manifest, ctx.name))
        .or_default();
    for skill in &skills.manifest_additions {
        if !entry.contains(skill) {
            entry.push(skill.clone());
        }
    }
    *manifest_changed = true;
    skills
}

/// The `agent_skills` key the effective list was read from. Writing
/// additions anywhere else creates an entry that shadows the one being read,
/// and the shadowed skills silently vanish from the next rendering.
fn merge_key(manifest: &Manifest, name: &str) -> String {
    if manifest.agent_skills.contains_key(name) {
        return name.to_owned();
    }
    let stripped = crate::mapping::skill_match_prefix(name);
    match manifest.agent_skills.contains_key(stripped) {
        true => stripped.to_owned(),
        false => name.to_owned(),
    }
}

/// Which `[agent-skills]` key this agent's assignment is written under —
/// its own name, or the base name a reviewer agent falls back to — and
/// `None` where neither holds a row. Asked for the key rather than the
/// value, a caller can tell a row the agent owns from one it only reaches,
/// which is the difference between shadowing someone's assignment and
/// moving the agent's own.
pub(super) fn skills_key<'a>(manifest: &'a Manifest, name: &str) -> Option<&'a str> {
    let base = crate::mapping::skill_match_prefix(name);
    manifest
        .agent_skills
        .get_key_value(name)
        .or_else(|| manifest.agent_skills.get_key_value(base))
        .map(|(key, _)| key.as_str())
}

/// The `[agent-skills]` entry this agent reads, at the key above. Asking
/// for the exact name alone would call a real assignment absent and render
/// the upstream list over the top of it, which is the removal the person
/// made coming back.
pub(super) fn declared_skills<'a>(manifest: &'a Manifest, name: &str) -> Option<&'a Vec<String>> {
    skills_key(manifest, name).and_then(|key| manifest.agent_skills.get(key))
}
