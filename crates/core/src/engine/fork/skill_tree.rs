//! Where a skill's content actually lives for one harness. Every tool
//! reads the same skill through a different path — the shared canonical
//! tree it reads directly, a link into that tree, or its own copied tree —
//! and an operation that captures or compares bytes has to land on the
//! tree that tool really reads, never on whichever one shares the name.

use std::path::PathBuf;

use crate::engine::desired::{native_dir, skill_canonical};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

/// The tree that holds a skill's content for one harness: its own native
/// tree when it was copied there (each tool a real directory), or the
/// shared canonical tree when tools symlink to one. Picking canonical-first
/// would capture whichever tool happens to share it, not the one asked for.
pub(crate) fn skill_content_path(
    env: &Env,
    scope: &Scope,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    if let Some(dir) = native_dir(env, scope, harness, ItemKind::Skill) {
        let native = dir.join(crate::harness::rendered_name(harness, name));
        // A real directory here is this tool's own tree: its copy, or the
        // shared tree where this tool reads that itself. A symlink is
        // followed to the shared canonical tree it reads instead.
        // Resolving it gives a real directory either way, never the wrong
        // tool's bytes.
        if native.is_symlink() {
            if let Ok(target) = std::fs::read_link(&native) {
                let resolved = if target.is_absolute() {
                    target
                } else {
                    dir.join(target)
                };
                // Only a link into a location kendex itself manages is
                // followed — this scope's shared canonical tree. A foreign
                // link the user pointed elsewhere is not this skill's
                // content, and reading (then trashing) it would expose and
                // move whatever it happens to point at.
                if resolved.is_dir() && managed_skill_tree(env, scope, name, &resolved) {
                    return Some(resolved);
                }
            }
        } else if native.is_dir() {
            return Some(native);
        }
    }
    let canonical = skill_canonical(env, scope, name);
    canonical.is_dir().then_some(canonical)
}

/// Whether `path` is a skill tree kendex manages for `name`: the scope's
/// shared canonical tree. Compared canonically so a `..`-laden link cannot
/// dress a foreign directory up as a managed one.
fn managed_skill_tree(env: &Env, scope: &Scope, name: &str, path: &std::path::Path) -> bool {
    let real = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let canonical = skill_canonical(env, scope, name);
    real == canonical.canonicalize().unwrap_or(canonical)
}
