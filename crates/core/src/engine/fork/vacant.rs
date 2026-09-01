//! Prove a fork name and every destination free before writing.

use std::path::PathBuf;

use super::local_item;
use crate::engine::desired::{
    effective_method, native_dir, refusal_reason, skill_canonical, skill_dir, target_harnesses,
};
use crate::engine::desired_agent::written_at;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

/// Prove `new` legal, unclaimed, reachable, and vacant at every destination.
pub(super) fn vacant_name(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    decl: &ItemDecl,
    from: &str,
    new: &str,
) -> Result<()> {
    let unusable = |problem: String| CoreError::ForkNameUnusable {
        name: crate::names::shown(new),
        problem,
    };
    if let Some(problem) = crate::names::item_problem(new) {
        return Err(unusable(problem));
    }
    for harness in target_harnesses(decl, manifest, kind, scope) {
        let rendered = crate::harness::rendered_name(harness, new);
        let findings = crate::render::validate::validate_name(harness, &rendered);
        if let Some(reason) = refusal_reason(&findings) {
            return Err(unusable(reason));
        }
    }
    let collision = |existing: &str| CoreError::SourceCollision {
        name: new.to_owned(),
        existing: existing.to_owned(),
        requested: LOCAL_SOURCE_NAME.to_owned(),
    };
    if manifest
        .declared(kind)
        .keys()
        .any(|existing| same_slot(existing, new))
    {
        return Err(collision("this scope's manifest"));
    }
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    if lock
        .entries
        .values()
        .any(|entry| entry.kind == kind && same_slot(&entry.name, new))
    {
        return Err(collision("this scope's installed items"));
    }
    if kind == ItemKind::Agent
        && let Some(problem) = crate::engine::agent_carry::cannot_carry(manifest, from, new)
    {
        return Err(unusable(problem));
    }
    let slot = local_item(env, scope, kind, new);
    if !crate::source::slot_free(&slot)? {
        return Err(collision("this scope's local source"));
    }
    if let Some(problem) = crate::source::slot_unreachable(env, scope, kind, new, &slot)? {
        return Err(unusable(problem));
    }
    for target in render_targets(env, scope, kind, decl, manifest, new) {
        if crate::fs::entry(&target)?.is_some() {
            return Err(unusable(format!(
                "something kendex doesn't manage already sits at {} — move it, or pick another name",
                target.display()
            )));
        }
    }
    Ok(())
}

/// Whether two names fold onto one source or rendered slot.
fn same_slot(a: &str, b: &str) -> bool {
    crate::names::fold(a) == crate::names::fold(b)
        || HarnessId::ALL.iter().any(|harness| {
            crate::names::fold(&crate::harness::rendered_name(*harness, a))
                == crate::names::fold(&crate::harness::rendered_name(*harness, b))
        })
        || crate::names::fold(&crate::harness::canonical_name(a))
            == crate::names::fold(&crate::harness::canonical_name(b))
}

/// Every canonical and harness-native destination this fork would write.
fn render_targets(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    decl: &ItemDecl,
    manifest: &Manifest,
    name: &str,
) -> Vec<PathBuf> {
    let mut targets = Vec::new();
    let method = effective_method(decl, manifest);
    let copies = method == crate::manifest::Method::Copy;
    if kind == ItemKind::Skill && !copies {
        targets.push(skill_canonical(env, scope, name));
    }
    for harness in target_harnesses(decl, manifest, kind, scope) {
        let dir = match kind {
            ItemKind::Skill => skill_dir(env, scope, harness, method),
            _ => native_dir(env, scope, harness, kind),
        };
        let Some(dir) = dir else {
            continue;
        };
        targets.push(match kind {
            ItemKind::Skill => dir.join(crate::harness::rendered_name(harness, name)),
            _ => written_at(&dir, harness, name, decl.enabled),
        });
    }
    targets
}
