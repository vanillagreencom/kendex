//! Which changed paths the offer covers, and which it only counts.
//!
//! git decides what changed, in one call over the whole checkout. `git
//! status` takes no `--pathspec-from-file`, and a pathspec argument per
//! path would not fit a Windows command line, so the call is unscoped and
//! the rows are matched against the set here.

use std::collections::BTreeSet;
use std::path::Path;

use crate::engine::GeneratedPaths;

use super::{Branch, Failed, Operation, Owned, Scan, git};

/// One `git status` row: the two status letters and the path.
struct Row<'a> {
    x: u8,
    y: u8,
    path: &'a [u8],
}

impl Row<'_> {
    fn untracked(&self) -> bool {
        self.x == b'?' && self.y == b'?'
    }

    fn deleted(&self) -> bool {
        self.x == b'D' || self.y == b'D'
    }
}

/// Read the project: what changed, and where the checkout stands.
///
/// A read the offer is built from that would not run leaves the offer
/// unbuildable, and its words reach the person as that step's failure, the
/// way every other step's do.
pub fn scan(root: &Path, generated: &GeneratedPaths) -> Result<Option<Scan>, Failed> {
    let whole = generated.owned(root);
    let owned = relative(root, &whole);
    let shared = relative(root, &generated.shared);
    let status = git::read_required(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    // Read once and only where it can matter: the rule it feeds adds the
    // paths a sweep removed, and a sweep's removals are deletions.
    let mut committed: Option<BTreeSet<String>> = None;
    let mut ours: Vec<Owned> = Vec::new();
    let mut theirs: Vec<String> = Vec::new();
    let mut others = 0usize;
    for row in rows(&status) {
        let Some(path) = text(row.path) else {
            // A path git reports in bytes that are not text is not a path
            // this offer can pass back to git as a pathspec, and it is not
            // one kendex wrote: every path kendex renders is text. It is
            // one of the person's own changed files.
            others += 1;
            continue;
        };
        if owned.contains(&path) {
            ours.push(Owned {
                untracked: row.untracked(),
                path,
            });
            continue;
        }
        if shared.contains(&path) {
            theirs.push(path);
            continue;
        }
        // A path that left the inventory and is gone from the working tree
        // is a sweep's removal, and the deletion is part of the same
        // change. Only a deleted one: a path that left the inventory but
        // still exists left it for another reason, most often a hand edit
        // putting the item in `Conflict`, and that file is the person's.
        if row.deleted() {
            let inventory = match &committed {
                Some(read) => read,
                None => committed.insert(git::committed_inventory(root)?),
            };
            if inventory.contains(&path) {
                ours.push(Owned {
                    untracked: row.untracked(),
                    path,
                });
                continue;
            }
        }
        others += 1;
    }
    if ours.is_empty() {
        return Ok(None);
    }
    ours.sort_by(|a, b| a.path.cmp(&b.path));
    ours.dedup_by(|a, b| a.path == b.path);
    theirs.sort();
    theirs.dedup();
    Ok(Some(Scan {
        root: root.to_owned(),
        owned: ours,
        shared: theirs,
        others,
        branch: branch(root)?,
    }))
}

/// Where the checkout stands, and whether a commit could land at all.
fn branch(root: &Path) -> Result<Branch, Failed> {
    // The operation comes first: a rebase leaves `HEAD` detached, and
    // saying so instead of naming the rebase would send the person looking
    // for a branch rather than for the operation they are in the middle of.
    if let Some(operation) = in_progress(root)? {
        return Ok(Branch::InProgress(operation));
    }
    Ok(match git::head_branch(root)? {
        Some(name) => Branch::On(name),
        None => Branch::Detached,
    })
}

/// The marker a git operation leaves in the git directory while it runs.
///
/// Read from `--git-dir` rather than from `<root>/.git`, which is a file
/// rather than a directory in a linked work tree.
fn in_progress(root: &Path) -> Result<Option<Operation>, Failed> {
    let Some(bytes) = git::read(root, &["rev-parse", "--absolute-git-dir"])? else {
        return Ok(None);
    };
    let Some(dir) = text(String::from_utf8_lossy(&bytes).trim_end().as_bytes()) else {
        return Ok(None);
    };
    let dir = Path::new(&dir);
    for (marker, operation) in [
        ("MERGE_HEAD", Operation::Merge),
        ("REBASE_HEAD", Operation::Rebase),
        ("rebase-merge", Operation::Rebase),
        ("rebase-apply", Operation::Rebase),
        ("CHERRY_PICK_HEAD", Operation::CherryPick),
        ("BISECT_LOG", Operation::Bisect),
    ] {
        if dir.join(marker).exists() {
            return Ok(Some(operation));
        }
    }
    Ok(None)
}

/// The rows of one `git status --porcelain=v1 -z` answer.
///
/// `-z` because a path may hold any byte but NUL, and because it turns off
/// the quoting git otherwise applies to an unusual name. A rename or copy
/// row is followed by a second NUL-terminated field naming where the path
/// came from. A rename's origin is gone from the working tree under that
/// name, which is what a deletion is, and is classified like any other
/// row; a copy's origin is still there and is no change of its own.
fn rows(status: &[u8]) -> Vec<Row<'_>> {
    let mut rows = Vec::new();
    let mut fields = status.split(|byte| *byte == 0).filter(|f| !f.is_empty());
    while let Some(field) = fields.next() {
        // `XY ` then the path: three bytes of prefix, and a shorter field
        // is not a row git wrote.
        if field.len() < 4 {
            continue;
        }
        let (x, y) = (field[0], field[1]);
        rows.push(Row {
            x,
            y,
            path: &field[3..],
        });
        if x == b'R' || x == b'C' {
            let Some(origin) = fields.next() else {
                break;
            };
            if x == b'R' {
                rows.push(Row {
                    x: b'D',
                    y: b' ',
                    path: origin,
                });
            }
        }
    }
    rows
}

/// A path git wrote, as text. `None` where the bytes are not text: such a
/// path is not one kendex rendered, and it cannot travel back to git as a
/// pathspec through a file this module writes as text.
fn text(bytes: &[u8]) -> Option<String> {
    String::from_utf8(bytes.to_vec()).ok()
}

/// The paths under `root`, spelled the way `git status` spells them.
fn relative<'a>(
    root: &Path,
    paths: impl IntoIterator<Item = &'a std::path::PathBuf>,
) -> BTreeSet<String> {
    paths
        .into_iter()
        .filter_map(|path| path.strip_prefix(root).ok().map(crate::paths::slashed))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::rows;

    /// git's `--porcelain=v1 -z` rows as documented: a rename or copy row
    /// is followed by its origin field. A rename's origin is emitted as a
    /// deletion; a copy's origin is consumed and is no row of its own.
    #[test]
    fn a_renames_origin_is_a_deletion_and_a_copys_is_consumed() {
        let status = b"R  new.md\0old.md\0C  copy.md\0src.md\0?? loose.md\0";
        let seen: Vec<(u8, u8, &str)> = rows(status)
            .iter()
            .map(|row| (row.x, row.y, std::str::from_utf8(row.path).unwrap()))
            .collect();
        assert_eq!(
            seen,
            [
                (b'R', b' ', "new.md"),
                (b'D', b' ', "old.md"),
                (b'C', b' ', "copy.md"),
                (b'?', b'?', "loose.md"),
            ]
        );
        assert!(rows(status)[1].deleted());
        assert!(rows(status)[3].untracked());
    }
}
