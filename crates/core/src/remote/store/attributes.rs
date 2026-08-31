//! A catalog's own `.gitattributes`, held out of the checkout it would
//! otherwise decide.
//!
//! `process::MATERIALISING` silences what the *host* says about line
//! endings. This is the other half, and the answer is the same in both
//! directions: what kendex hashes, compares and installs is what the
//! source committed, on every machine. `text eol=crlf` would convert the
//! checkout — wrong on every host, at least equally. `filter=<driver>` is
//! worse, because the driver's `smudge` command lives in configuration:
//! one commit then lands one way on a host that defines the driver and
//! another way on a host that does not, which is the host dependence the
//! pins exist to remove.
//!
//! Both are answered by taking the rules out of the write rather than
//! arguing with each one. The attributes files leave the index before git
//! materializes the tree, so no rule is in force for any path, and their
//! own committed bytes are laid down afterwards from the blobs.

use std::path::{Path, PathBuf};

use super::{captured, run};
use crate::error::{CoreError, Result};
use crate::fs;
use crate::process::Hardened;

/// Every `.gitattributes` in the tree, at the root and at any depth: a
/// leading `**/` matches no leading directory as readily as many. Written
/// once and used twice, to list them and to remove them, because two
/// spellings of one set could drift and the drift would be a file removed
/// from the index and never written back.
const ATTRIBUTES: &str = ":(glob)**/.gitattributes";

/// One committed `.gitattributes`: what leaves the index before the write,
/// and what has to land afterwards for the checkout to be the commit.
pub(super) struct Committed {
    /// Relative to the tree root, exactly as git spells it.
    path: PathBuf,
    /// The index entry's mode, six octal digits.
    mode: String,
    oid: String,
}

/// Take every `.gitattributes` out of the index `checkout-index` is about
/// to write from, and hand back what has to land once it has.
///
/// The listing reads the index rather than the commit, because the index
/// is what the write reads and what the removal takes them out of.
pub(super) fn withhold(mirror: &Path, into: &Path) -> Result<Vec<Committed>> {
    let listed = captured(Hardened::git_into(
        mirror,
        into,
        &["ls-files", "-s", "-z", "--", ATTRIBUTES],
    ))?;
    let withheld: Vec<Committed> = listed
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .map(listed_entry)
        .collect::<Result<_>>()?;
    if !withheld.is_empty() {
        run(Hardened::git_into(
            mirror,
            into,
            &["rm", "--cached", "--force", "--quiet", "--", ATTRIBUTES],
        ))?;
    }
    Ok(withheld)
}

/// `<mode> SP <oid> SP <stage> TAB <path>`, and the path is whatever bytes
/// the catalog named it with — which is why the split is on the tab rather
/// than on whitespace, and why only the half before it is read as text.
fn listed_entry(record: &[u8]) -> Result<Committed> {
    let unreadable = || CoreError::GitFailed {
        command: "git ls-files".to_owned(),
        stderr: format!(
            "unreadable index entry: {}",
            String::from_utf8_lossy(record)
        ),
    };
    let tab = record.iter().position(|byte| *byte == b'\t');
    let (fields, path) = tab.map(|at| record.split_at(at)).ok_or_else(unreadable)?;
    let mut fields = std::str::from_utf8(fields)
        .map_err(|_| unreadable())?
        .split(' ');
    let (Some(mode), Some(oid)) = (fields.next(), fields.next()) else {
        return Err(unreadable());
    };
    Ok(Committed {
        path: as_path(&path[1..]).ok_or_else(unreadable)?,
        mode: mode.to_owned(),
        oid: oid.to_owned(),
    })
}

/// Lay the withheld files down as the source committed them, now that
/// nothing git writes can consult them.
pub(super) fn restore(mirror: &Path, into: &Path, withheld: &[Committed]) -> Result<()> {
    withheld
        .iter()
        .try_for_each(|entry| write_committed(mirror, into, entry))
}

/// The blob as the source committed it, written where git was told not to
/// write it.
///
/// The path is the one git just handed back out of the index it wrote from
/// the commit, so it is relative and holds no `..`: git refuses to read
/// such a path into an index at all, which is the same promise
/// `checkout-index` writes the rest of the tree under.
///
/// Mode is the tree's own. Git records one permission bit and whether the
/// entry is a link, `tree_signature` hashes both, and a checkout that lost
/// either would not be the commit.
fn write_committed(mirror: &Path, into: &Path, entry: &Committed) -> Result<()> {
    let path = into.join(&entry.path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    let blob = captured(Hardened::git_bare(
        mirror,
        &["cat-file", "blob", &entry.oid],
    ))?;
    if entry.mode == LINK {
        let target = as_path(&blob).ok_or_else(|| CoreError::io(&path, unspellable()))?;
        return fs::make_symlink(&target, &path);
    }
    std::fs::write(&path, &blob).map_err(|e| CoreError::io(&path, e))?;
    if entry.mode == EXECUTABLE {
        make_executable(&path)?;
    }
    Ok(())
}

/// The two index modes a `.gitattributes` can carry beyond a plain file.
/// git reads no attributes out of a link — it declines to follow one and
/// says so — but the entry is still the commit's, so it is written back
/// the way git would have written it.
const EXECUTABLE: &str = "100755";
const LINK: &str = "120000";

/// git spells a path in the bytes the catalog stored, and on Unix those
/// need not be text. Nothing on Windows can be named in bytes that are not
/// UTF-8, so a name that is not is one this platform cannot hold.
#[cfg(unix)]
fn as_path(bytes: &[u8]) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt as _;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

#[cfg(not(unix))]
fn as_path(bytes: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(bytes).ok().map(PathBuf::from)
}

fn unspellable() -> std::io::Error {
    std::io::Error::other("the commit names it with bytes this platform cannot spell")
}

/// The bit git records, set the way git sets it: on the checkout, not from
/// the catalog's own permissions, which nothing here reads.
#[cfg(unix)]
fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    let mut permissions = std::fs::metadata(path)
        .map_err(|e| CoreError::io(path, e))?
        .permissions();
    permissions.set_mode(permissions.mode() | 0o111);
    std::fs::set_permissions(path, permissions).map_err(|e| CoreError::io(path, e))
}

#[cfg(not(unix))]
fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}
