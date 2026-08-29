//! Where a plan's write targets land, the scope they may not leave, and
//! the promise a landing is afterwards.
//!
//! A derived target is a name joined onto a scope root, and the
//! directories in between are somebody else's to arrange: point
//! `.claude/hooks` at another folder and every write through it lands
//! there. So a plan that speaks the joined spelling describes writes that
//! happen somewhere else, and a containment check on that spelling passes
//! for a target that is not inside the scope at all.
//!
//! [`land`] settles both at plan time. Every target becomes the place it
//! reaches, and one that reaches out of the scope is refused by that
//! place's name. What that buys afterwards is an identity: a landed path
//! is one whose every directory is already real, so it lands on itself.
//! [`unmoved`] asks exactly that, of one path, immediately before it is
//! used.
//!
//! Asking it beats asking the containment question again, and the
//! difference is not a detail:
//!
//! - Containment needs a root, and a root re-read from disk is a root
//!   somebody can move. Rename the project directory and leave a link in
//!   its place and the re-derived root is the link's target, against which
//!   every planned path reads as deliberately outside the scope.
//! - Containment stays true when an ancestor is swapped for a link to
//!   another place in the same project. The write then lands somewhere the
//!   plan never showed anybody, and no containment test can see it.
//! - A landing is per path and per moment, so it holds for an op appended
//!   after the plan was shown, and for the op after the one that just
//!   created a link.
//!
//! The landing is what the person was shown, so the landing is what the
//! write is held to. Nothing here re-derives the root; the plan fixed it.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::model::Scope;

use super::{Op, PlannedOp};

/// Land every write target this plan carries, refusing one that lands
/// outside the scope. The paths are rewritten, so what the plan shows and
/// what apply writes is the one place the bytes reach.
pub(super) fn land(scope: &Scope, ops: &mut [PlannedOp]) -> Result<()> {
    let Scope::Project { root } = scope.canonical() else {
        // Nothing encloses the global scope: its roots are the machine's
        // own harness directories, which a person is free to keep
        // wherever they keep their dotfiles.
        return Ok(());
    };
    for planned in ops {
        // Read before the landing moves the link, because a link's text
        // is spelled from the parent it was to sit in.
        let intended = match &planned.op {
            Op::Symlink { link, target, .. } => {
                Some((link.clone(), crate::fs::resolved(link, target)))
            }
            _ => None,
        };
        for path in planned.op.touched_mut() {
            *path = landed_within(&root, path)?;
        }
        if let Some((was, Some(destination))) = intended {
            respell(&root, &was, &destination, &mut planned.op);
        }
    }
    Ok(())
}

/// A link the landing moved says something else from where it now sits:
/// its text steps out of the parent it was written for. Respelled from
/// the parent it landed in, by the same rule that spelled it, so it
/// reaches the destination it was made to reach.
fn respell(root: &Path, was: &Path, destination: &Path, op: &mut Op) {
    let Op::Symlink { link, target, .. } = op else {
        return;
    };
    if was.parent() == link.parent() {
        return;
    }
    *target = crate::fs::spelling(Some(root), destination, link);
}

/// Whether this path is still the place the plan landed it on.
///
/// A landed path's directories are all real, so landing it again returns
/// it unchanged. Anything else means a directory on the way to it has
/// become a link since, and the write would reach a place the plan never
/// named.
pub(super) fn unmoved(path: &Path) -> Result<()> {
    let now = landing(path);
    if now != path {
        return Err(CoreError::TargetMoved {
            path: path.to_path_buf(),
            now,
        });
    }
    Ok(())
}

/// [`unmoved`] for every path one op mutates.
pub(super) fn op_unmoved(op: &Op) -> Result<()> {
    op.touched().iter().try_for_each(|path| unmoved(path))
}

/// Where `path` lands, provided a target inside `root` stays inside it.
///
/// A path that was never under the root is landed but not judged. This
/// rule is about a target that reads as in-scope and is not. A path that
/// says outside is somewhere its own caller had to decide about: an
/// adoption captures the folder a link of the person's own points at, and
/// the boundary for that is adoption's. Landing it anyway is what lets
/// [`unmoved`] hold it to the same promise as the rest.
///
/// A `..` still standing in the landing is one no existing directory
/// resolved away, so where it reaches is not known and containment cannot
/// be established: refused rather than normalized, since nothing kendex
/// derives from a scope root carries one.
fn landed_within(root: &Path, path: &Path) -> Result<PathBuf> {
    let landed = landing(path);
    if !path.starts_with(root) {
        return Ok(landed);
    }
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
