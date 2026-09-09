//! What one file the offer covers holds now, against what the last commit
//! holds.
//!
//! The offer names paths; this turns one of them into the change behind it,
//! so the window can show a person what they are about to commit rather
//! than a list of names. The comparison itself is
//! [`crate::package::diff::diff_trees`], the one the package pages already
//! draw — reading what changed is one thing in this app whatever produced
//! the change.
//!
//! Absent and unreadable are never the same answer here. A file this
//! change deletes is absent; a file the machine would not let this process
//! read is a step that failed, and it travels as one. Collapsing the two
//! would draw a diff nobody can trust in the one window that asks a person
//! to commit.

use std::io;
use std::path::{Component, Path, PathBuf};

use crate::package::diff::{PackageDiff, Tree, diff_trees};

use super::{Failed, Refusal, Scan, Step, git};

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
    if let Some(bytes) = working(&scan.root, path)? {
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

/// What `HEAD` holds at this path, or `None` where it holds nothing — a
/// file this change adds, or a repository with no commit yet.
///
/// Whether `HEAD` holds the path is asked before it is read, because the
/// read cannot answer it: `git show HEAD:./<missing>` and a `git show` over
/// a repository git cannot read both exit 128, so a reader that took a
/// non-zero exit for "absent" would draw a corrupt repository as a file
/// being added. `ls-tree` answers the question it was asked — it exits 0
/// and prints nothing for a path `HEAD` does not hold — so a non-zero exit
/// from either call is git failing, and travels as the failure it is.
fn committed(root: &Path, path: &str) -> Result<Option<Vec<u8>>, Failed> {
    // Nothing is committed yet, so `HEAD` names no tree to ask about and
    // every covered path is one this change adds.
    if git::previous_head(root)?.is_none() {
        return Ok(None);
    }
    let listed = git::read_required(root, &["ls-tree", "--name-only", "HEAD", "--", path])?;
    if listed.is_empty() {
        return Ok(None);
    }
    // The revision spec always opens with `HEAD:`, so a path that starts
    // with a hyphen cannot reach git as an option.
    git::read_required(root, &["show", &format!("HEAD:./{path}")]).map(Some)
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
///
/// The leaf is not the only component that can be a link. An ancestor
/// replaced by one would carry an ordinary read straight out of the
/// project, so every component below the root is checked and a link before
/// the leaf refuses the read outright: the path the offer named no longer
/// names a file inside this project, and no bytes from outside it may
/// reach the window.
fn working(root: &Path, path: &str) -> Result<Option<Vec<u8>>, Failed> {
    let whole = root.join(path);
    if let Some(link) = ancestor_link(root, path)? {
        return Err(refused(format!(
            "{} is a symbolic link, so {path} is no longer a file inside this project",
            crate::paths::slashed(&link)
        )));
    }
    let Some(kind) = absent_or(whole.symlink_metadata(), &whole)? else {
        return Ok(None);
    };
    if kind.is_symlink() {
        let target = std::fs::read_link(&whole).map_err(|error| io_refused(&whole, &error))?;
        return Ok(Some(crate::paths::slashed(&target).into_bytes()));
    }
    absent_or(std::fs::read(&whole), &whole)
}

/// The first component below `root` that is a symbolic link, or `None`
/// where the whole of the path but its leaf is ordinary directories.
///
/// A component that is not there is not a link: the path is simply gone,
/// which is what a deletion looks like and what [`working`] answers `None`
/// for.
fn ancestor_link(root: &Path, path: &str) -> Result<Option<PathBuf>, Failed> {
    let mut at = root.to_path_buf();
    let relative = Path::new(path);
    let mut components = relative.components().peekable();
    while let Some(component) = components.next() {
        if components.peek().is_none() {
            break;
        }
        let Component::Normal(name) = component else {
            // git reports paths relative to the root with no `.` or `..`
            // in them, and the coverage check compared against exactly
            // those, so anything else here is not a path this offer named.
            return Err(refused(format!("{path} is not a path inside this project")));
        };
        at.push(name);
        match at.symlink_metadata() {
            Ok(found) if found.is_symlink() => return Ok(Some(at)),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_refused(&at, &error)),
        }
    }
    Ok(None)
}

/// A read whose answer is `None` only where the path is not there, and a
/// failure for every other reason the machine gave.
fn absent_or<T>(read: io::Result<T>, at: &Path) -> Result<Option<T>, Failed> {
    match read {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_refused(at, &error)),
    }
}

fn io_refused(at: &Path, error: &io::Error) -> Failed {
    refused(format!("{}: {error}", crate::paths::slashed(at)))
}

/// A read this module could not make, said the way every other step's
/// failure is said: one line, whole, for the window to print.
fn refused(line: String) -> Failed {
    Failed {
        step: Step::Read,
        refusal: Refusal::Said(vec![line]),
    }
}
