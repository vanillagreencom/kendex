//! Where a plan's write targets land, and the scope they may not leave.
//!
//! A derived target is a name joined onto a scope root, and the
//! directories in between are somebody else's to arrange: point
//! `.claude/hooks` at another folder and every write through it lands
//! there. So a plan that speaks the joined spelling describes writes that
//! happen somewhere else — and a containment check on that spelling passes
//! for a target that is not inside the scope at all.
//!
//! Both answers come from landing the target once: follow the directories
//! on the way to it, then judge the place it reaches.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::model::Scope;

use super::PlannedOp;

/// Land every write target this plan carries, refusing one that lands
/// outside the scope. The paths are rewritten, so what the plan shows,
/// records and writes is the one place the bytes reach.
pub(super) fn land(scope: &Scope, ops: &mut [PlannedOp]) -> Result<()> {
    let Scope::Project { root } = scope.canonical() else {
        // Nothing encloses the global scope: its roots are the machine's
        // own harness directories, which a person is free to keep
        // wherever they keep their dotfiles.
        return Ok(());
    };
    for planned in ops {
        for path in planned.op.touched_mut() {
            *path = landed_within(&root, path)?;
        }
    }
    Ok(())
}

/// The same judgement over a plan already built, taking nothing back.
///
/// This is the one every apply passes through, whoever built the plan and
/// whatever was appended to it afterwards, so a write site that never
/// landed its own targets still cannot reach out of the scope. It is also
/// the second look: a directory swapped for a link after the plan was
/// shown moves the target, and the write must not follow it.
pub(super) fn check(scope: &Scope, ops: &[PlannedOp]) -> Result<()> {
    let Scope::Project { root } = scope.canonical() else {
        return Ok(());
    };
    for planned in ops {
        for path in planned.op.touched() {
            landed_within(&root, &path)?;
        }
    }
    Ok(())
}

/// Where `path` lands, provided a target inside `root` stays inside it.
///
/// A path that was never under the root is left alone. This rule is about
/// a target that reads as in-scope and is not — the spelling says inside
/// while the write lands elsewhere. A path that says outside is somewhere
/// its own caller had to decide about: an adoption captures the folder a
/// link of the person's own points at, and the boundary for that is
/// adoption's.
///
/// A `..` still standing in the landing is one no existing directory
/// resolved away, so where it reaches is not known and containment cannot
/// be established: refused rather than normalized, since nothing kendex
/// derives from a scope root carries one.
fn landed_within(root: &Path, path: &Path) -> Result<PathBuf> {
    if !path.starts_with(root) {
        return Ok(path.to_path_buf());
    }
    let landed = landing(path);
    if !landed.starts_with(root) || landed.components().any(|part| part == Component::ParentDir) {
        return Err(CoreError::ScopeEscape {
            path: path.to_path_buf(),
            landed,
            root: root.to_path_buf(),
        });
    }
    Ok(landed)
}

/// Where a target lands once the directories on the way to it are
/// followed.
///
/// The target's own name is left as it was. Whether that position is
/// itself a link is a separate question with answers of its own — a
/// foreign link is a conflict, a shared tree's link is one kendex wrote —
/// and resolving it here would take those answers away.
fn landing(path: &Path) -> PathBuf {
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => resolved_dir(parent).join(name),
        _ => path.to_path_buf(),
    }
}

/// The longest existing prefix of `dir` followed, with the rest joined
/// back on. A target's directories need not exist yet, and the ones that
/// do are the only ones that can point anywhere.
fn resolved_dir(dir: &Path) -> PathBuf {
    if let Ok(resolved) = dir.canonicalize() {
        return resolved;
    }
    match (dir.parent(), dir.file_name()) {
        (Some(parent), Some(name)) => resolved_dir(parent).join(name),
        _ => dir.to_path_buf(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `..` under a directory that does not exist is resolved by
    /// nothing, so the landing still holds it. Read lexically it is inside
    /// the root; followed it is not, and the refusal is what says so.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_landing_that_still_walks_back_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let target = root.join("absent/../../elsewhere/x");
        assert!(target.starts_with(&root), "it reads as inside the root");
        assert!(matches!(
            landed_within(&root, &target),
            Err(CoreError::ScopeEscape { .. })
        ));
    }
}
