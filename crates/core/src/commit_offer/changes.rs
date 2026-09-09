//! What one file the offer covers holds now, against what the last commit
//! holds.
//!
//! The offer names paths; this turns one of them into the change behind it,
//! so the window can show a person what they are about to commit rather
//! than a list of names. The comparison itself is
//! [`crate::package::diff::diff_trees`], the one the package pages already
//! draw — reading what changed is one thing in this app whatever produced
//! the change.

use std::path::Path;

use crate::package::diff::{PackageDiff, Tree, diff_trees};

use super::{Failed, Scan, git};

/// What the offer has to show for one of the files it covers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Changes {
    /// What the last commit holds against what the file holds now.
    Shown(PackageDiff),
    /// The offer covers this path and git reports it changed, and both
    /// sides hold the same bytes. What the commit carries for it is a
    /// change git records beside the contents — the file's mode, which is
    /// what restoring a registration script's execute bit changes and
    /// nothing else about the file.
    SameContent,
    /// The offer does not cover this path.
    NotOffered,
}

/// The change in one file the offer covers.
///
/// The scan is the whole of what may be read. A path outside it is not a
/// file kendex wrote or shares a key in, so it is one of the person's own —
/// their unrelated work in progress, an ignored file holding a secret — and
/// the window has no business showing it. The check is exact equality
/// against paths git itself reported, so nothing outside the project can
/// be named either.
pub fn file_changes(scan: &Scan, path: &str) -> Result<Changes, Failed> {
    let covered = scan.owned.iter().any(|owned| owned.path == path)
        || scan.shared.iter().any(|shared| shared == path);
    if !covered {
        return Ok(Changes::NotOffered);
    }
    let mut before = Tree::new();
    if let Some(bytes) = committed(&scan.root, path)? {
        before.insert(path.to_owned(), bytes);
    }
    let mut after = Tree::new();
    if let Some(bytes) = working(&scan.root, path) {
        after.insert(path.to_owned(), bytes);
    }
    let diff = diff_trees(&before, &after);
    // git put this path in the scan, so something about it changed. With
    // both sides holding the same bytes that something is not the
    // contents, and a comparison drawn as empty would say the opposite.
    Ok(match diff.files.is_empty() {
        true => Changes::SameContent,
        false => Changes::Shown(diff),
    })
}

/// What `HEAD` holds at this path, or `None` where it holds nothing —
/// a file this change adds, or a repository with no commit yet. The
/// revision spec always opens with `HEAD:`, so a path that starts with a
/// hyphen cannot reach git as an option.
fn committed(root: &Path, path: &str) -> Result<Option<Vec<u8>>, Failed> {
    git::read(root, &["show", &format!("HEAD:./{path}")])
}

/// What the working tree holds at this path, or `None` where it holds
/// nothing — a file this change deletes.
///
/// A symlink is read as the link, never through it. Following one would
/// show bytes from wherever it points, which is not the file the offer
/// named and need not be inside the project at all; the link's own target
/// text is the whole of what git stores for it, and is what `HEAD:./<path>`
/// answers with on the other side. kendex writes these links itself — the
/// tree plan emits one per project skill — so a link it rewrites has to
/// read as a rewrite rather than as a deletion.
fn working(root: &Path, path: &str) -> Option<Vec<u8>> {
    let whole = root.join(path);
    if whole.is_symlink() {
        let target = std::fs::read_link(&whole).ok()?;
        return Some(crate::paths::slashed(&target).into_bytes());
    }
    std::fs::read(&whole).ok()
}
