//! Where an item of a kind lives for one harness at one scope.
//!
//! Every answer comes from the adapter's own surface declarations, the same
//! ones the scanner reads, so what an install writes and what a scan reads
//! back can never be two different rules. A harness that reads both the
//! project's shared tree and a directory of its own has two answers: the
//! shared one is where an install goes, and its own is where a per-tool
//! copy goes.

use std::path::PathBuf;

use crate::env::Env;
use crate::harness::{Surface, adapter};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

/// The dir a harness natively reads `kind` from at this scope, taken from
/// the same adapter surface declarations the scanner uses.
pub fn native_dir(env: &Env, scope: &Scope, harness: HarnessId, kind: ItemKind) -> Option<PathBuf> {
    let a = adapter(harness);
    item_dirs(a, kind, scope, env).into_iter().next()
}

/// The directory this harness reads `kind` from on its own, rather than the
/// one it shares with the other tools. Where a harness reads both — a skill
/// in `.agents/skills` and one in its own folder — this is the second, and
/// it is where a copy delivery writes: the person who asked for a real tree
/// per tool asked for it in the place only that tool reads.
pub fn own_dir(env: &Env, scope: &Scope, harness: HarnessId, kind: ItemKind) -> Option<PathBuf> {
    let a = crate::harness::adapter(harness);
    item_dirs(a, kind, scope, env).pop()
}

/// How this declaration is delivered: its own choice, or the scope's
/// default where it made none. One owner, because [`skill_dir`] holds the
/// pass that plans a write and the check that proves its destination free
/// to one directory only while both resolve the method the same way.
pub(crate) fn effective_method(decl: &ItemDecl, manifest: &Manifest) -> crate::manifest::Method {
    decl.method.unwrap_or(manifest.install.method)
}

/// Where a skill lands for one harness under this delivery method. A copy
/// is a tree only this tool reads, so it goes in the tool's own directory
/// where it has one; a symlink goes in the shared tree every tool reads.
/// The pass that plans the write and the check that proves the
/// destination free both ask here, so the two cannot name different
/// paths.
pub(crate) fn skill_dir(
    env: &Env,
    scope: &Scope,
    harness: HarnessId,
    method: crate::manifest::Method,
) -> Option<PathBuf> {
    match method {
        crate::manifest::Method::Copy => own_dir(env, scope, harness, ItemKind::Skill),
        crate::manifest::Method::Symlink => native_dir(env, scope, harness, ItemKind::Skill),
    }
}

/// Every place this harness reads `kind` from at this scope, the one an
/// install writes to first. A tool that reads both the shared tree and its
/// own has two, and a surface looking for what is already on disk has to
/// look in both — the person's own copy may predate the shared convention.
pub fn read_dirs(env: &Env, scope: &Scope, harness: HarnessId, kind: ItemKind) -> Vec<PathBuf> {
    item_dirs(adapter(harness), kind, scope, env)
}

/// Every directory a kind is stored in for one harness, in the order the
/// adapter declares them.
fn item_dirs(
    a: &dyn crate::harness::HarnessAdapter,
    kind: ItemKind,
    scope: &Scope,
    env: &Env,
) -> Vec<PathBuf> {
    let surfaces = match scope {
        Scope::Global => a.global_surfaces(kind, &a.default_global_root(env), env),
        Scope::Project { root } => a.project_surfaces(kind, root, env),
    };
    surfaces
        .into_iter()
        .filter_map(|surface| match surface {
            Surface::FileDir { dir, .. } | Surface::SubdirPerItem { dir, .. } => Some(dir),
            // A structured surface holds entries, not one file per item, so
            // there is no directory an item of this kind is written into.
            Surface::Structured { .. } | Surface::StructuredDir { .. } => None,
        })
        .collect()
}

/// The shared tree several tools read one skill from. Its name holds the
/// plugin a plugin-registry catalog put the skill in, joined the way the
/// directory itself spells it.
pub fn skill_canonical(env: &Env, scope: &Scope, name: &str) -> PathBuf {
    let name = crate::harness::canonical_name(name);
    match scope {
        Scope::Global => env.rendered_skills_dir().join(name),
        Scope::Project { root } => root.join(".agents/skills").join(name),
    }
}

pub(crate) fn target_harnesses(
    decl: &ItemDecl,
    manifest: &Manifest,
    kind: ItemKind,
    scope: &Scope,
) -> Vec<HarnessId> {
    harnesses_for(decl.harnesses.as_deref(), manifest, kind, scope)
}

/// The same from a declaration's `harnesses` list alone, so a reading with
/// no declaration to hand — nothing here has asked for this item yet — gets
/// its answer from this derivation rather than from a second spelling of
/// it.
pub(crate) fn harnesses_for(
    requested: Option<&[HarnessId]>,
    manifest: &Manifest,
    kind: ItemKind,
    scope: &Scope,
) -> Vec<HarnessId> {
    requested
        .map(<[HarnessId]>::to_vec)
        .unwrap_or_else(|| manifest.install.harnesses.clone())
        .into_iter()
        .filter(|harness| crate::harness::installs_here(*harness, kind, scope))
        .collect()
}
