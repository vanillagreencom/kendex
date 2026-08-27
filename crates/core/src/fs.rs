use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::{CoreError, Result};

mod links;
mod lock;
pub(crate) use links::{points_at, spelling};
pub(crate) use lock::{LockedFile, open_read_no_follow};

/// Write via a sibling temp file + rename so readers never see a torn file.
/// A symlink at the path is followed: the file it points at is replaced and
/// the link stays — renaming over the link itself would swap a user's
/// dotfiles link for a detached copy.
pub fn atomic_write(path: &Path, contents: &str) -> Result<()> {
    write_then_rename(path, contents, false, true)
}

/// `atomic_write` plus full crash durability: the temp file syncs before
/// the rename and the parent directory syncs after, so after this returns
/// the file either exists complete or not at all — even across power loss.
pub fn atomic_write_durable(path: &Path, contents: &str) -> Result<()> {
    write_then_rename(path, contents, true, true)
}

/// Atomic cache write that replaces a final symlink instead of writing
/// through it. Cache entries are owned files, never user-managed links.
pub(crate) fn atomic_write_no_follow(path: &Path, contents: &str) -> Result<()> {
    write_then_rename(path, contents, false, false)
}

fn write_then_rename(
    path: &Path,
    contents: &str,
    durable: bool,
    follow_final_link: bool,
) -> Result<()> {
    let path = match follow_final_link {
        true => follow_link(path),
        false => path.to_path_buf(),
    };
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::io(&path, std::io::Error::other("path has no parent")))?;
    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    // One temp name per write, not per process: two writers sharing a name
    // truncate each other's bytes, and the one that loses the rename either
    // fails with ENOENT or writes its payload straight over the live file
    // the winner just moved into place. The app writes settings from a
    // thread pool, so same-path writes really do overlap.
    let (tmp, mut temp_file) = loop {
        let candidate = path.with_extension(format!(
            "tmp.{}.{}",
            std::process::id(),
            NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
        ));
        match fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&candidate)
        {
            Ok(file) => break (candidate, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(CoreError::io(&candidate, error)),
        }
    };
    // A failed write leaves nothing behind. With a name per attempt there is
    // no next writer to overwrite an abandoned temp file, so it would just
    // sit there beside the real one — a full copy of whatever was being
    // saved, growing by one file per failure.
    let discard = |error: std::io::Error, at: &Path| {
        let _ = fs::remove_file(&tmp);
        CoreError::io(at, error)
    };
    if let Err(error) = temp_file.write_all(contents.as_bytes()) {
        drop(temp_file);
        return Err(discard(error, &tmp));
    }
    if durable && let Err(error) = temp_file.sync_all() {
        drop(temp_file);
        return Err(discard(error, &tmp));
    }
    drop(temp_file);
    fs::rename(&tmp, &path).map_err(|e| discard(e, &path))?;
    #[cfg(unix)]
    if durable && let Ok(dir) = fs::File::open(parent) {
        let _ = dir.sync_all();
    }
    Ok(())
}

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

/// The file a symlink chain ends at; the path itself when it is not a link
/// or the link is broken (nothing to preserve, the rename replaces it).
fn follow_link(path: &Path) -> PathBuf {
    match path.is_symlink() {
        true => fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()),
        false => path.to_path_buf(),
    }
}

pub fn read_if_exists(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(CoreError::io(path, e)),
    }
}

pub(crate) fn sync_file(path: &Path) -> Result<()> {
    fs::File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|e| CoreError::io(path, e))
}

/// Directory fsync is a no-op on platforms where directories cannot be
/// opened (Windows); rename durability there rides on the volume flush.
pub(crate) fn sync_dir(path: &Path) {
    #[cfg(unix)]
    if let Ok(dir) = fs::File::open(path) {
        let _ = dir.sync_all();
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// `sync_dir` with the outcome kept: for a transition that must be on
/// disk before the next step may run. Unix only; elsewhere the volume
/// flush is all there is, and the call reports nothing.
pub(crate) fn sync_dir_durable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        fs::File::open(path)
            .and_then(|dir| dir.sync_all())
            .map_err(|e| CoreError::io(path, e))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

/// Sync a tree's files and directories, a link treated as a leaf: the
/// parent's sync persists the entry itself, and what it points at is not
/// this tree's — following it would sync files outside the tree, or the
/// same tree again through a link back into it until the kernel refuses
/// the path. The same reading of a link as `hash_tree_as_is`.
pub(crate) fn sync_tree(root: &Path) -> Result<()> {
    let Ok(kind) = fs::symlink_metadata(root).map(|meta| meta.file_type()) else {
        return Ok(());
    };
    if kind.is_symlink() {
        return Ok(());
    }
    if kind.is_file() {
        return sync_file(root);
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            sync_tree(&entry.path())?;
        }
        sync_dir(root);
    }
    Ok(())
}

/// Remove whatever is at `path`, if anything is. A remove-if-present: the
/// journal's restore of an absent pre-image asks for it on paths nothing
/// ever wrote to, and failing there would strand the journal and take
/// every later apply in the scope down with it.
pub(crate) fn remove_any(path: &Path) -> Result<()> {
    if path.is_symlink() || path.is_file() {
        fs::remove_file(path).map_err(|e| CoreError::io(path, e))?;
    } else if path.is_dir() {
        fs::remove_dir_all(path).map_err(|e| CoreError::io(path, e))?;
    }
    Ok(())
}

pub(crate) fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    fs::create_dir_all(to).map_err(|e| CoreError::io(to, e))?;
    // An entry the listing could not produce is an entry nothing was
    // proven about, so it stops the copy rather than dropping out of it —
    // the same rule `plain_tree` states in pre.rs. This is the journal's
    // pre-image writer: a shortened copy would be recorded as a whole one,
    // and the rollback that trusts it would put back less than it took.
    for entry in fs::read_dir(from).map_err(|e| CoreError::io(from, e))? {
        let source = entry.map_err(|e| CoreError::io(from, e))?.path();
        let Some(name) = source.file_name() else {
            continue;
        };
        copy_any(&source, &to.join(name))?;
    }
    Ok(())
}

/// Reproduce one entry at another path: a link as a link, a directory as
/// its whole tree, anything else by its bytes.
///
/// The link question is asked first, because both of the others read
/// through one. `is_dir` on a link to a directory would reproduce the tree
/// it points at while the link is all that was asked for, and `copy` on a
/// link whose target is gone fails with the target's ENOENT under the
/// link's name.
pub(crate) fn copy_any(from: &Path, to: &Path) -> Result<()> {
    if from.is_symlink() {
        let target = fs::read_link(from).map_err(|e| CoreError::io(from, e))?;
        make_symlink(&target, to)
    } else if from.is_dir() {
        copy_tree(from, to)
    } else {
        fs::copy(from, to)
            .map(|_| ())
            .map_err(|e| CoreError::io(from, e))
    }
}

/// Move an entry to `to`, whether or not the two share a filesystem.
///
/// `to` must be a free name, proven against a link as well as against
/// existence: rename(2) replaces an occupied destination silently, and the
/// copy the other branch makes merges into a directory already sitting
/// there. Both callers prove it — `unique_in` and pi_ext's own free-name
/// loop.
///
/// rename(2) does it in one step where they share a filesystem, and
/// refuses where they do not — the everyday shape for the trash, which a
/// project on its own mount is removed into under the home directory.
/// Across that boundary the entry is reproduced and the original taken
/// away. Its refusal is carried into whatever the second attempt fails
/// with: rename can refuse for reasons a copy does not share, and without
/// it the caller reads only that the original could not be removed.
pub(crate) fn move_any(from: &Path, to: &Path) -> Result<()> {
    let Err(refused) = fs::rename(from, to) else {
        return Ok(());
    };
    copy_any(from, to)
        .and_then(|()| remove_any(from))
        .map_err(|failed| {
            CoreError::io(
                from,
                std::io::Error::other(format!(
                    "rename refused it ({refused}) and moving it across by hand failed ({failed})"
                )),
            )
        })
}

#[cfg(unix)]
pub(crate) fn make_symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link).map_err(|e| CoreError::io(link, e))
}

#[cfg(windows)]
pub(crate) fn make_symlink(target: &Path, link: &Path) -> Result<()> {
    if target.is_dir() {
        std::os::windows::fs::symlink_dir(target, link).map_err(|e| CoreError::io(link, e))
    } else {
        std::os::windows::fs::symlink_file(target, link).map_err(|e| CoreError::io(link, e))
    }
}

#[cfg(test)]
mod tests;
