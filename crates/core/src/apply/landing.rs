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

use super::{Op, PlannedOp};

/// What a target that reads as outside the root is taken to be.
#[derive(Clone, Copy)]
enum Outside {
    /// Its builder's business. A plan arrives whole from something that
    /// knows why a target of its own sits outside the scope: an adoption
    /// captures the folder a link of the person's own points at, and that
    /// boundary is adoption's to draw.
    Theirs,
    /// Refused. An op joining a plan already made carries no such account,
    /// and what joins one is this scope's own record.
    Refused,
}

/// Land every write target this plan carries, refusing one that reads as
/// inside the root and lands outside it. The paths are rewritten, so what
/// the plan shows and what apply writes is the one place the bytes reach.
///
/// `root` is the canonical scope root, fixed by the caller and never read
/// again here. `None` is the global scope, which nothing encloses: its
/// targets still land — everything downstream is held to a landing — but
/// they have no root to leave, and somebody keeping `~/.claude` in a
/// dotfiles repo is describing their layout.
pub(super) fn land(root: Option<&Path>, ops: &mut [PlannedOp]) -> Result<()> {
    land_with(root, Outside::Theirs, ops)
}

/// The same for an op joining a plan already made, which must land inside
/// the root that plan fixed.
pub(super) fn land_inside(root: Option<&Path>, ops: &mut [PlannedOp]) -> Result<()> {
    land_with(root, Outside::Refused, ops)
}

fn land_with(root: Option<&Path>, outside: Outside, ops: &mut [PlannedOp]) -> Result<()> {
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
            *path = landed_within(root, outside, path)?;
        }
        if let Some((was, Some(destination))) = intended {
            respell(root, &was, &destination, &mut planned.op);
        }
    }
    Ok(())
}

/// A link the landing moved says something else from where it now sits:
/// its text steps out of the parent it was written for. Respelled from
/// the parent it landed in, by the same rule that spelled it, so it
/// reaches the destination it was made to reach.
fn respell(root: Option<&Path>, was: &Path, destination: &Path, op: &mut Op) {
    let Op::Symlink { link, target, .. } = op else {
        return;
    };
    if was.parent() == link.parent() {
        return;
    }
    *target = crate::fs::spelling(root, destination, link);
}

/// Whether this path still reaches the place a record says it reached.
///
/// The comparison is against the record, never against a property of the
/// spelling: whether a path is its own landing says something about how
/// it was written down, not about whether it has moved. A caller's own
/// path need not be a landing, and under a temp root reached through a
/// link — every one on macOS, where `/var` fronts `/private/var` — none
/// of them is.
///
/// The window between this answer and the syscall after it is KEN-813.
pub(super) fn still_reaches(recorded: &Path, path: &Path) -> Result<()> {
    let now = landing(path);
    if now != recorded {
        return Err(CoreError::TargetMoved {
            path: path.to_path_buf(),
            now,
        });
    }
    Ok(())
}

/// The same for a path whose record is itself: a plan's targets, which
/// [`land`] fixed at their landings. A landed path's directories are all
/// real, so landing it again returns it unchanged, and anything else
/// means one of them has become a link since.
pub(super) fn unmoved(path: &Path) -> Result<()> {
    still_reaches(path, path)
}

/// [`unmoved`] for every path one op mutates.
pub(super) fn op_unmoved(op: &Op) -> Result<()> {
    op.touched().iter().try_for_each(|path| unmoved(path))
}

/// Where `path` lands, provided a target inside `root` stays inside it.
///
/// Landing is unconditional; only the judgement needs a root. A global
/// target has none, and a path that reads as outside a project root may
/// have none either — see [`Outside`]. Landing them anyway is what lets
/// [`unmoved`] hold them to the same promise as the rest.
///
/// A `..` still standing in the landing is one no existing directory
/// resolved away, so where it reaches is not known and containment cannot
/// be established: refused rather than normalized, since nothing kendex
/// derives from a scope root carries one.
fn landed_within(root: Option<&Path>, outside: Outside, path: &Path) -> Result<PathBuf> {
    let landed = landing(path);
    let Some(root) = root else {
        return Ok(landed);
    };
    if !path.starts_with(root) && matches!(outside, Outside::Theirs) {
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

/// Where a path reaches once the directories on the way to it are
/// followed.
///
/// The target's own name is left as it was. Whether that position is
/// itself a link is a separate question with answers of its own — a
/// foreign link is a conflict, a shared tree's link is one kendex wrote —
/// and resolving it here would take those answers away.
pub(super) fn landing(path: &Path) -> PathBuf {
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
            landed_within(Some(&root), Outside::Theirs, &target),
            Err(CoreError::ScopeEscape { .. })
        ));
    }
}
