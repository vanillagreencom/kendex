//! Whether a name is free for a fork to claim. Everything that could
//! already own the name — or refuse it — is asked here, before the first
//! durable write: the manifest, the lock, the local source's slot and its
//! folding neighbours, every render destination, and each target loader's
//! own naming rules.

use std::fs;
use std::path::PathBuf;

use super::local_item;
use crate::engine::desired::{native_dir, refusal_reason, skill_canonical, target_harnesses};
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
pub(super) fn vacant_name(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    decl: &ItemDecl,
    new: &str,
) -> Result<()> {
    let unusable = |problem: String| CoreError::ForkNameUnusable {
        name: new.to_owned(),
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
    let same_slot = |a: &str, b: &str| {
        crate::names::fold(a) == crate::names::fold(b)
            || HarnessId::ALL.iter().any(|harness| {
                crate::names::fold(&crate::harness::rendered_name(*harness, a))
                    == crate::names::fold(&crate::harness::rendered_name(*harness, b))
            })
            || crate::names::fold(&crate::harness::canonical_name(a))
                == crate::names::fold(&crate::harness::canonical_name(b))
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
    let slot = local_item(env, scope, kind, new);
    if fs::symlink_metadata(&slot).is_ok() || crate::names::folding_sibling(&slot).is_some() {
        return Err(collision("this scope's local source"));
    }
    if let Some(problem) = slot_unreachable(env, scope, kind, new, &slot)? {
        return Err(unusable(problem));
    }
    // Anything already at a path the fork would render to is not the
    // fork's to sweep: with the name unclaimed above, the occupant is
    // unmanaged, and the render pass would refuse to touch it after the
    // fork was already recorded.
    for target in render_targets(env, scope, kind, decl, manifest, new) {
        if fs::symlink_metadata(&target).is_ok() {
            return Err(unusable(format!(
                "something kendex doesn't manage already sits at {} — move it, or pick another name",
                target.display()
            )));
        }
    }
    Ok(())
}

/// Why the local source cannot hold the fork's bytes at `slot`, in words
/// for the person who typed the name.
///
/// Every render destination is one component under its directory — the
/// separators fold a namespaced name into a single leaf — so the slot is
/// the one destination whose name spells a path. `plugin/item` is stored
/// at `<local>/skills/plugin/item`, and the leaf being free says nothing
/// about what stands above it: the plugin half may be a package of its
/// own, in which case the capture writes the fork inside that package's
/// tree, where every later render of it carries the fork's files as its
/// own content; or a component may be a symlink, which the sealed reader
/// refuses to look through, so bytes written past one are bytes kendex
/// can never read back. Both answers come from the reader the rest of the
/// engine resolves this source with, not from a second spelling of the
/// local source's layout here.
fn slot_unreachable(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    new: &str,
    slot: &std::path::Path,
) -> Result<Option<String>> {
    let root = crate::source::local_source_root(env, scope);
    if !root.is_dir() {
        return Ok(None);
    }
    let sealed = crate::source_read::SealedSource::open(&root)?;
    if let Err(escape) = sealed.contained(slot) {
        return Ok(Some(format!(
            "the local source cannot be written there — {escape}"
        )));
    }
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME)?;
    let Some((plugin, _)) = crate::names::split(new) else {
        return Ok(None);
    };
    if crate::source::find_item(&sealed, &config, kind, plugin).is_some() {
        return Ok(Some(format!(
            "`{}` is a package of its own here, and this name would be stored inside it",
            crate::names::shown(plugin)
        )));
    }
    Ok(None)
}

/// Every path an item of this kind under `name` would render to in this
/// scope: the shared canonical tree for a skill, plus each target tool's
/// own file or link. An agent's file answers to the declaration's switch —
/// a disabled one lands under `.disabled` — so the destination comes from
/// the renderer's own rule rather than a second spelling of it. A disabled
/// skill keeps its directory and renames `SKILL.md` inside it, so its
/// destination is the same either way.
fn render_targets(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    decl: &ItemDecl,
    manifest: &Manifest,
    name: &str,
) -> Vec<PathBuf> {
    let mut targets = Vec::new();
    if kind == ItemKind::Skill {
        targets.push(skill_canonical(env, scope, name));
    }
    for harness in target_harnesses(decl, manifest, kind, scope) {
        let Some(dir) = native_dir(env, scope, harness, kind) else {
            continue;
        };
        targets.push(match kind {
            ItemKind::Skill => dir.join(crate::harness::rendered_name(harness, name)),
            _ => written_at(&dir, harness, name, decl.enabled),
        });
    }
    targets
}
