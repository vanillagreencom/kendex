//! Which changed paths the offer covers, and which it only counts.
//!
//! git decides what changed, in one call over the whole checkout. `git
//! status` takes no `--pathspec-from-file`, and a pathspec argument per
//! path would not fit a Windows command line, so the call is unscoped and
//! the rows are matched against the set here.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::engine::{GeneratedPaths, Recorded};

use super::pending::{Before, Pending};
use super::{Branch, Carry, Failed, Operation, Owned, Rebase, Scan, git};

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

    /// This path is not in the last commit: git has never seen it, or it
    /// is staged as an addition. A different question from `untracked`
    /// above, which is about what `git add` still has to do; a person who
    /// staged kendex's new file themselves changed that answer and not
    /// this one.
    fn added(&self) -> bool {
        self.untracked() || self.x == b'A'
    }

    fn deleted(&self) -> bool {
        self.x == b'D' || self.y == b'D'
    }

    fn owned(&self, path: String) -> Owned {
        Owned {
            untracked: self.untracked(),
            added: self.added(),
            path,
        }
    }
}

/// Read the project: what changed, where the checkout stands, and what a
/// commit after the action `before` was read for carries. `None` where
/// that commit would carry nothing.
///
/// A read the offer is built from that would not run leaves the offer
/// unbuildable, and its words reach the person as that step's failure, the
/// way every other step's do.
pub fn scan(
    root: &Path,
    generated: &GeneratedPaths,
    before: &Before,
) -> Result<Option<Scan>, Failed> {
    let sorted = sort(root, generated, before.writes())?;
    let mut others = sorted.others.len() + sorted.unnamed;
    let (beside, carry) = match before {
        Before::Read(baseline) => {
            let pending = Pending::read(root, &sorted.owned, &sorted.beside, baseline);
            // A file the action left as it found it is the person's.
            let (written, untouched): (Vec<Owned>, Vec<Owned>) = sorted
                .beside
                .into_iter()
                .partition(|one| pending.beside.iter().any(|file| file.path == one.path));
            others += untouched.len();
            (written, Carry::Read(pending))
        }
        Before::Unread { failed, .. } => (sorted.beside, Carry::Unread(failed.clone())),
        // Nothing was read, so nothing was sorted apart from the person's
        // own files.
        Before::Untaken => (sorted.beside, Carry::Untaken),
    };
    let carries = carry
        .pending()
        .is_some_and(|pending| !pending.carried().is_empty());
    if sorted.owned.is_empty() && !carries {
        return Ok(None);
    }
    Ok(Some(Scan {
        root: root.to_owned(),
        owned: sorted.owned,
        beside,
        carry,
        others,
        manifest: sorted.manifest,
        branch: branch(root)?,
    }))
}

/// One `git status` over the checkout, sorted by what kendex wrote.
pub(super) struct Sorted {
    /// Changed files kendex owns whole, sorted: [`Scan::owned`].
    pub owned: Vec<Owned>,
    /// Changed files the action may have written beside them, sorted: what
    /// [`Scan::beside`] is drawn from.
    pub beside: Vec<Owned>,
    /// Every other changed path, by name.
    pub others: Vec<String>,
    /// Other changed paths that are not named in [`Sorted::others`]: a
    /// path whose bytes are not text, and a file kendex owns a region of
    /// whose region is unchanged. Neither is a path a reading before an
    /// action has to record: the first is no path kendex writes, and the
    /// second is judged by its region alone.
    pub unnamed: usize,
    /// The project's manifest where git reports it changed, in whichever
    /// list above it sits: [`Scan::manifest`].
    pub manifest: Option<String>,
}

/// Sort what git reports changed. The read every other one here is made
/// from, and the one [`Before::read`] records before an action. A file the
/// action may write is one of `writes` or a shared edit target of
/// `generated`; with no `writes`, where nothing was read before the action,
/// none is set apart from the person's own files.
///
/// A deleted path the inventory at `HEAD` names is kendex's whole, the
/// render a sweep or a removal took away, however the person edited it:
/// a removal's plan names that render among the paths it touches, and it
/// is still sorted here and not among `writes`. Every file kendex writes
/// into rather than owns ([`GeneratedPaths::beside`]) is not, whatever
/// the inventory says and whichever reader asks: the person's own keys sit
/// in a shared edit target, so its deletion is judged as every other file
/// kendex writes into is, or counted as the person's. Where the record at
/// `HEAD` cannot say which files those are ([`Recorded::Unknown`]), only a
/// deletion the record on disk names as a render is kendex's whole; any
/// other is judged as a file kendex writes into is.
pub(super) fn sort(
    root: &Path,
    generated: &GeneratedPaths,
    writes: Option<&BTreeSet<String>>,
) -> Result<Sorted, Failed> {
    let owned = relative(root, &generated.owned(root));
    let written_into = relative(root, &generated.beside(root));
    let vouched: Option<Vec<PathBuf>> = match &generated.recorded {
        Recorded::Known(_) => None,
        Recorded::Unknown { rendered } => Some(
            rendered
                .iter()
                .filter_map(|path| path.strip_prefix(root).ok().map(Path::to_path_buf))
                .collect(),
        ),
    };
    let beside: BTreeSet<String> = match writes {
        None => BTreeSet::new(),
        Some(writes) => writes
            .iter()
            .cloned()
            .chain(relative(root, &generated.shared))
            .collect(),
    };
    let status = git::read_required(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    // Read once and only where it can matter: the rule it feeds adds the
    // renders a sweep or a removal took away, and those are deletions.
    let mut committed: Option<BTreeSet<String>> = None;
    let declared = declaration(root);
    let mut sorted = Sorted {
        owned: Vec::new(),
        beside: Vec::new(),
        others: Vec::new(),
        unnamed: 0,
        manifest: None,
    };
    for row in rows(&status) {
        let Some(path) = text(row.path) else {
            // A path git reports in bytes that are not text is not a path
            // this offer can pass back to git as a pathspec, and it is not
            // one kendex wrote: every path kendex renders is text. It is
            // one of the person's own changed files.
            sorted.unnamed += 1;
            continue;
        };
        if declared.as_deref() == Some(path.as_str()) {
            sorted.manifest = Some(path.clone());
        }
        if owned.contains(&path) {
            if let Some(region) = generated.region(root, &path)
                && !super::regions::changed(root, region)?
            {
                sorted.unnamed += 1;
                continue;
            }
            sorted.owned.push(row.owned(path));
            continue;
        }
        let claimable = vouched
            .as_ref()
            .is_none_or(|vouched| vouched.iter().any(|at| Path::new(&path).starts_with(at)));
        if row.deleted() && claimable && !written_into.contains(&path) {
            let inventory = match &committed {
                Some(read) => read,
                None => committed.insert(git::committed_inventory(root)?),
            };
            if inventory.contains(&path) {
                sorted.owned.push(Owned {
                    untracked: row.untracked(),
                    // A path the committed inventory holds is one the last
                    // commit has, whatever git says about it now: this row
                    // is its deletion, not an addition.
                    added: false,
                    path,
                });
                continue;
            }
        }
        if beside.contains(&path) {
            sorted.beside.push(row.owned(path));
            continue;
        }
        sorted.others.push(path);
    }
    for list in [&mut sorted.owned, &mut sorted.beside] {
        list.sort_by(|a, b| a.path.cmp(&b.path));
        list.dedup_by(|a, b| a.path == b.path);
    }
    Ok(sorted)
}

/// Where this project declares what it asks kendex for, spelled the way
/// `git status` spells a path.
///
/// `crate::manifest::project_manifest_path` is the one place that decides
/// which file that is: a source catalog publishes its own kendex.toml and
/// declares its installs in the sibling file. `None` where that path is
/// not under this root, which no project scope produces.
pub(super) fn declaration(root: &Path) -> Option<String> {
    crate::manifest::project_manifest_path(root)
        .strip_prefix(root)
        .ok()
        .map(crate::paths::slashed)
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
        ("rebase-merge", Operation::Rebase(Rebase::Merge)),
        ("rebase-apply", Operation::Rebase(Rebase::Apply)),
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
