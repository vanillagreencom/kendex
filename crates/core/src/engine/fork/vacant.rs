//! Whether a name is free for a fork to claim. Everything that could
//! already own the name — or refuse it — is asked here, before the first
//! durable write: the manifest, the lock, the local source's slot and its
//! folding neighbours, every render destination, and each target loader's
//! own naming rules.

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

/// Whether `new` can be declared here as a local item, proven before any
/// durable write: a legal name every target tool's loader will hold, no
/// declaration or lock entry of this kind under it (a derived bundle
/// member or dependency is installed without a declaration, and is no less
/// there), nothing in the local source's slot for it — a dangling link
/// included, which exists to the OS and to nothing that follows it —
/// nothing that folds to it, nothing standing between the local source's
/// root and that slot, and nothing already sitting where it would
/// render. A declared `Docs` beside a new `docs`, or a `café` spelled two
/// ways, renders to one path on a case- or composition-folding filesystem,
/// where the planner would refuse both and sweep the one that was there;
/// each tool's rendered name and a local-source sibling fold the same way.
/// `from` is the name being left, whose configuration has to mean the same
/// under `new` for the move to mean what it says.
pub(super) fn vacant_name(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    decl: &ItemDecl,
    from: &str,
    new: &str,
) -> Result<()> {
    // Shown, not raw: the name reaches a terminal in the refusal, and an
    // escape sequence inside it is printed rather than run.
    let unusable = |problem: String| CoreError::ForkNameUnusable {
        name: crate::names::shown(new),
        problem,
    };
    if let Some(problem) = crate::names::item_problem(new) {
        return Err(unusable(problem));
    }
    // The check each target's renderer would apply, asked now: a name a
    // loader refuses would record the fork and then install nothing.
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
    // An agent answers to its name in the manifest's own tables as well as
    // in its declaration, and that configuration has to travel to the new
    // name and mean the same thing there.
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
    // Anything already at a path the fork would render to is not the
    // fork's to sweep: with the name unclaimed above, the occupant is
    // unmanaged, and the render pass would refuse to touch it after the
    // fork was already recorded.
    for target in render_targets(env, scope, kind, decl, manifest, new) {
        // The same three-valued read the slot above gets: a destination the
        // filesystem will not describe is not a destination proven empty.
        if crate::fs::entry(&target)?.is_some() {
            return Err(unusable(format!(
                "something kendex doesn't manage already sits at {} — move it, or pick another name",
                target.display()
            )));
        }
    }
    Ok(())
}

/// Whether two names reach one slot: the same name after folding, the same
/// rendered name under any tool, or the same canonical spelling. A volume
/// that folds case or composition hands one file back under both, so a
/// declaration under either is a declaration under the other.
fn same_slot(a: &str, b: &str) -> bool {
    crate::names::fold(a) == crate::names::fold(b)
        || HarnessId::ALL.iter().any(|harness| {
            crate::names::fold(&crate::harness::rendered_name(*harness, a))
                == crate::names::fold(&crate::harness::rendered_name(*harness, b))
        })
        || crate::names::fold(&crate::harness::canonical_name(a))
            == crate::names::fold(&crate::harness::canonical_name(b))
}

/// Every path an item of this kind under `name` would render to in this
/// scope: the shared canonical tree for a skill the shared method writes,
/// plus each target tool's own file or link. Each destination comes from the helper the render
/// itself asks rather than a second spelling of it — `skill_dir` for a
/// skill, which is the tool's own directory under a copy delivery and the
/// shared tree under a symlink, and `written_at` for an agent, which
/// answers to the declaration's switch so a disabled one lands under
/// `.disabled`. A disabled skill keeps its directory and renames
/// `SKILL.md` inside it, so its destination is the same either way.
///
/// Only a skill and an agent reach here, because `forkable_kind` refuses
/// every other one at the top of both fork paths. That gate is the reason
/// two arms answer for every kind there is: a fork entry does not prove
/// the kind — detach writes one for every kind it converts, and the
/// manifest table takes any of them — so nothing downstream of the gate
/// re-derives what a hook or a command would render to.
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
    // Copy keeps every tool's own directory; only the shared method puts a
    // tree where several tools read one copy. The two methods write to
    // different directories for a tool that reads both, so the question is
    // asked the same way the install answers it — the same distinction
    // `unmanaged.rs` draws for the same question.
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
