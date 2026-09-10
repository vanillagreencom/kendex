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
//!
//! What git carries beside the contents is read beside them, from git. A
//! commit can change a file's mode and its text at once — restoring a
//! registration script's execute bit while rewriting it does exactly that —
//! and a viewer that inferred the mode from an empty comparison would show
//! the half it could see and hide the half it could not.

use std::io;
use std::path::{Component, Path, PathBuf};

use crate::package::diff::{PackageDiff, Tree, diff_trees};

use super::{Failed, Refusal, Scan, Step, git, pathspec};

/// The file's mode on each side, in git's own spelling: `100644` an
/// ordinary file, `100755` one that can be run, `120000` a symbolic link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModeChange {
    pub before: String,
    pub after: String,
}

/// One covered file's change, as the window draws it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Changed {
    /// The two sides' contents compared. Empty where the contents did not
    /// change and git carries the change some other way.
    pub diff: PackageDiff,
    /// The mode change the commit carries, or `None` where the mode
    /// stands. Read from git rather than derived from the comparison, so a
    /// file whose text and mode both change reports both.
    pub mode: Option<ModeChange>,
}

/// What the offer has to show for one of the files it covers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Changes {
    Shown(Changed),
    /// The offer does not cover this path.
    NotOffered,
}

/// The change in one file the offer covers.
///
/// Only the files kendex owns whole. The scan's `shared` set is the other
/// half of what it reports: whole configuration files of the person's own
/// that kendex writes one key in — `.mcp.json`, a harness `settings.json` —
/// and the rest of such a file is theirs, environment values and
/// credentials included. The offer names those files and commits nothing
/// of them, and this reads none of one either: a path outside `owned` is
/// not offered, whoever asks. The check is exact equality against paths
/// git itself reported, so nothing outside the project can be named at
/// all.
pub fn file_changes(scan: &Scan, path: &str) -> Result<Changes, Failed> {
    if !scan.owned.iter().any(|owned| owned.path == path) {
        return Ok(Changes::NotOffered);
    }
    // Read once, and every call that names `HEAD` asks it first: in a
    // repository whose first commit this would be, `HEAD` names nothing
    // and `git diff HEAD` and `git ls-tree HEAD` each refuse. That is the
    // state a first kendex write in a fresh `git init` reaches, and the
    // offer supports it, so it must read as a file being added rather than
    // as a step that failed.
    let born = git::previous_head(&scan.root)?.is_some();
    let mut before = Tree::new();
    if let Some(bytes) = committed(&scan.root, path, born)? {
        before.insert(path.to_owned(), bytes);
    }
    let mut after = Tree::new();
    if let Some(bytes) = working(&scan.root, path)? {
        after.insert(path.to_owned(), bytes);
    }
    Ok(Changes::Shown(Changed {
        diff: diff_trees(&before, &after),
        mode: match born {
            true => mode_change(&scan.root, path)?,
            false => None,
        },
    }))
}

/// What git records about this path beside its contents, where the commit
/// changes it.
///
/// git decides what a mode is and when it changed; this reads its answer
/// rather than comparing two readings of its own, which would have to know
/// that Windows carries no execute bit and that a link is a mode rather
/// than a kind. `--raw` opens each entry with the two modes, and a path
/// git lists no entry for — one this change adds, which `HEAD` has no side
/// of — has no mode change to report.
fn mode_change(root: &Path, path: &str) -> Result<Option<ModeChange>, Failed> {
    let listed = git::read_required(
        root,
        &["diff", "--raw", "HEAD", "--", &pathspec::literal(path)],
    )?;
    let text = String::from_utf8_lossy(&listed);
    let Some(entry) = text.lines().next() else {
        return Ok(None);
    };
    let mut fields = entry.trim_start_matches(':').split_whitespace();
    let (Some(before), Some(after)) = (fields.next(), fields.next()) else {
        return Ok(None);
    };
    // git spells "no mode on this side" as all zeroes, which a deletion
    // and an addition each carry on one side. Neither is a mode change:
    // the file arriving or going is the change, and the comparison already
    // says so.
    let missing = |mode: &str| mode.chars().all(|one| one == '0');
    if before == after || missing(before) || missing(after) {
        return Ok(None);
    }
    Ok(Some(ModeChange {
        before: before.to_owned(),
        after: after.to_owned(),
    }))
}

/// What `HEAD` holds as a file at this path, or `None` where it holds no
/// file there — one this change adds, one it replaced with a directory, or
/// a repository with no commit yet.
///
/// Whether `HEAD` holds the path is asked before it is read, because the
/// read cannot answer it: `git show HEAD:./<missing>` and a `git show` over
/// a repository git cannot read both exit 128, so a reader that took a
/// non-zero exit for "absent" would draw a corrupt repository as a file
/// being added. `ls-tree` answers the question it was asked — it exits 0
/// and prints nothing for a path `HEAD` does not hold — so a non-zero exit
/// from either call is git failing, and travels as the failure it is.
///
/// It answers what kind of thing is there, too. `HEAD:./<dir>` is a
/// directory listing, not a file, and rendering one as the before side
/// would put git's own inventory of a folder on screen as though the
/// commit were rewriting it.
///
/// The path sits in a pathspec position, so it goes through
/// [`pathspec::literal`] the way every other pathspec this module hands
/// git does. `ls-tree` was measured not to glob `[`, `*` or `?` against
/// tree paths, so the prefix is not what makes this read exact today; it
/// is what keeps it exact, and it is the whole of the answer for a path
/// opening with the `:` a pathspec magic prefix starts with. The
/// `HEAD:./<path>` read below is a revision spec rather than a pathspec
/// and names its object exactly.
fn committed(root: &Path, path: &str, born: bool) -> Result<Option<Vec<u8>>, Failed> {
    if !born {
        return Ok(None);
    }
    let listed = git::read_required(root, &["ls-tree", "HEAD", "--", &pathspec::literal(path)])?;
    let text = String::from_utf8_lossy(&listed);
    let Some(kind) = text.lines().next().and_then(entry_kind) else {
        return Ok(None);
    };
    if kind != "blob" {
        return Ok(None);
    }
    // The revision spec always opens with `HEAD:`, so a path that starts
    // with a hyphen cannot reach git as an option.
    git::read_required(root, &["show", &format!("HEAD:./{path}")]).map(Some)
}

/// The kind field of one `ls-tree` entry — `blob`, `tree`, `commit` — from
/// its `<mode> <kind> <oid>\t<path>` shape.
fn entry_kind(entry: &str) -> Option<&str> {
    entry.split_whitespace().nth(1)
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
///
/// A replacement reads as one in both directions. An update that swaps the
/// file `foo` for the folder `foo/bar` puts both in the scan, and so does
/// the swap back: `foo` has to read as the removal it is where a directory
/// now stands there, and `foo/bar` has to read as the removal it is where a
/// file now stands at `foo`. Neither is a read that failed.
fn working(root: &Path, path: &str) -> Result<Option<Vec<u8>>, Failed> {
    let whole = root.join(path);
    match ancestors(root, path)? {
        Ancestors::Link(link) => {
            return Err(refused(format!(
                "{} is a symbolic link, so {path} is no longer a file inside this project",
                crate::paths::slashed(&link)
            )));
        }
        Ancestors::NoLeaf => return Ok(None),
        Ancestors::Directories => {}
    }
    let Some(kind) = absent_or(whole.symlink_metadata(), &whole)? else {
        return Ok(None);
    };
    if kind.is_symlink() {
        let target = std::fs::read_link(&whole).map_err(|error| io_refused(&whole, &error))?;
        return Ok(Some(crate::paths::slashed(&target).into_bytes()));
    }
    if kind.is_dir() {
        return Ok(None);
    }
    canonical(root, path)
}

/// The bytes git would put in the commit for this path, which are not
/// always the bytes on disk. `.gitattributes` can name a clean filter for a
/// path, and `core.autocrlf` — on by default in a Git for Windows checkout —
/// rewrites line endings on the way in. The commit stages with `git add`, so
/// a comparison built from raw disk bytes shows a change git will not make:
/// under that setting, every line of every text file.
///
/// git is asked rather than imitated. `hash-object` applies exactly the
/// filters staging applies, `--path` names the path whose attributes decide
/// which, and the object it writes is the one `git add` writes moments
/// later. The path is passed after `--`, as the file it is rather than as a
/// pathspec, so a name holding `[`, `*`, `?` or a leading `:` reaches git
/// whole; it is relative because every call this module makes runs in the
/// checkout.
fn canonical(root: &Path, path: &str) -> Result<Option<Vec<u8>>, Failed> {
    let printed = git::read_required(root, &["hash-object", "-w", "--path", path, "--", path])?;
    let oid = String::from_utf8_lossy(&printed).trim().to_owned();
    git::read_required(root, &["cat-file", "blob", &oid]).map(Some)
}

/// What the walk from `root` down to `path`'s leaf found standing in place
/// of a directory.
///
/// Asked of what each component *is*, never of the one kind that needs
/// refusing: a component that is not a directory cannot be walked through
/// whatever it is, and reading the leaf under it would answer with the
/// machine's word for that rather than with the change.
enum Ancestors {
    /// Every component below `root` but the leaf is an ordinary directory,
    /// so the leaf's own metadata answers whether it is there.
    Directories,
    /// A symbolic link stands where a directory should. Reading through it
    /// would carry the read out of the project, so it is refused rather
    /// than answered.
    Link(PathBuf),
    /// A component below `root` is missing, or is something a path cannot
    /// continue through — a regular file where the working tree replaced a
    /// folder. Either way no file stands at the leaf, which is the deletion
    /// this offer is showing.
    NoLeaf,
}

/// Walk `path`'s components below `root`, stopping at the first that is not
/// an ordinary directory.
fn ancestors(root: &Path, path: &str) -> Result<Ancestors, Failed> {
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
            Ok(found) if found.is_symlink() => return Ok(Ancestors::Link(at)),
            Ok(found) if found.is_dir() => {}
            Ok(_) => return Ok(Ancestors::NoLeaf),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Ancestors::NoLeaf),
            Err(error) => return Err(io_refused(&at, &error)),
        }
    }
    Ok(Ancestors::Directories)
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
