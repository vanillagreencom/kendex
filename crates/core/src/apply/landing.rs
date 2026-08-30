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
//! place's name. So the plan a person is shown names the places the bytes
//! go, and an op joining that plan afterwards is landed against the root
//! the plan fixed — never a root re-derived from disk, which is a root
//! somebody can move.

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

/// Where `path` lands, provided a target inside `root` stays inside it.
///
/// Landing is unconditional; only the judgement needs a root. A global
/// target has none, and a path that reads as outside a project root may
/// have none either — see [`Outside`]. They land anyway, so what the plan
/// shows is the place the write reaches either way.
///
/// A `..` still standing in the landing is one no existing directory
/// resolved away, so where it reaches is not known and containment cannot
/// be established: refused rather than normalized, since nothing kendex
/// derives from a scope root carries one.
///
/// Both sides reach here through `crate::paths::canonical`, so they are
/// one spelling. Its reduction is per path, though, and a root that loses
/// the extended-length prefix can hold a target long enough to keep it.
/// That pair does not compare and the write is refused, which is the side
/// to be wrong on.
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
fn landing(path: &Path) -> PathBuf {
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => resolved_dir(parent).join(name),
        _ => path.to_path_buf(),
    }
}

/// The longest existing prefix of `dir` followed, with the rest joined
/// back on. A target's directories need not exist yet, and the ones that
/// do are the only ones that can point anywhere.
///
/// Followed through `crate::paths::canonical`, because a landing is about
/// to be tested against a root that rule reduced. `std::fs::canonicalize`
/// answers every Windows path in the verbatim `\\?\` form, so resolving
/// here and reducing there would put a verbatim landing against a plain
/// root and refuse every write inside the scope.
fn resolved_dir(dir: &Path) -> PathBuf {
    if let Ok(resolved) = crate::paths::canonical(dir) {
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
    ///
    /// The root is reduced, because that is the spelling `resolved_dir`
    /// answers in and the setup has to meet it. The tail is joined a
    /// segment at a time rather than as one `absent/../../elsewhere/x`:
    /// `/` is a separator to Windows only outside the verbatim form, and
    /// `paths::canonical` reduces per path, so a root it cannot reduce
    /// would take the tail as a single filename and this would stop
    /// testing what it names.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_landing_that_still_walks_back_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap();
        let target = ["absent", "..", "..", "elsewhere", "x"]
            .iter()
            .fold(root.clone(), |path, segment| path.join(segment));
        assert!(target.starts_with(&root), "it reads as inside the root");
        assert!(matches!(
            landed_within(Some(&root), Outside::Theirs, &target),
            Err(CoreError::ScopeEscape { .. })
        ));
    }
}
