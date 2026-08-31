use std::fs;
use std::io::ErrorKind::{AlreadyExists, NotFound, PermissionDenied};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::{CoreError, Result};

mod links;
mod lock;
mod probe;
pub(crate) use links::{points_at, resolved, spelling};
pub(crate) use lock::{LockedFile, open_read_no_follow};
pub use probe::is_executable;
pub(crate) use probe::{absent, entry};

/// Give a file the execute bit. On Windows there is none to give, and the
/// file being there is the whole of what a caller can arrange.
#[cfg(unix)]
pub(crate) fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
        .map_err(|error| CoreError::io(path, error))
}

#[cfg(not(unix))]
pub(crate) fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}

/// Give a file the execute bit if its bytes open with a shebang. A tree
/// carries bytes and not modes, so every path that writes one out asks this
/// same question: a skill's helper that lands 644 fails its own hook the
/// first time something calls it.
pub(crate) fn executable_if_script(path: &Path, bytes: &[u8]) -> Result<()> {
    match bytes.starts_with(b"#!") {
        true => make_executable(path),
        false => Ok(()),
    }
}

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
            Err(error) if error.kind() == AlreadyExists => continue,
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
    if durable {
        sync_dir(parent);
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
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == NotFound => Ok(None),
        Err(e) => Err(CoreError::io(path, e)),
    }
}

/// Reproduce a file at `to` and have it on disk before this returns.
///
/// The copy is the platform's own, because a pre-image has to come back
/// carrying whatever the platform hangs off a file and a hand-rolled byte
/// loop would reproduce the bytes alone. On Windows `fs::copy` is
/// `CopyFileExW`, documented to preserve extended attributes, OLE
/// structured storage, NTFS alternate data streams, security resource
/// attributes and file attributes; on Unix it carries the mode, which a
/// restored hook needs to still be executable. Neither carries the
/// owner or the access-control list: a new file's ACLs are inherited
/// from its parent directory, on both platforms and before this helper
/// existed too.
pub(crate) fn copy_file_durable(from: &Path, to: &Path) -> Result<()> {
    fs::copy(from, to).map_err(|e| CoreError::io(from, e))?;
    sync_written_file(to)
}

/// Flush a file this process has just written, leaving its mode on disk
/// alongside its bytes.
///
/// A read-only handle is enough on Unix and refused on Windows, whose
/// `FlushFileBuffers` documents `GENERIC_WRITE` as a requirement, so the
/// write handle is what this asks for. A file that came from a read-only
/// source refuses one — `fs::copy` carries `FILE_ATTRIBUTE_READONLY`
/// across on Windows and the mode on Unix — so a refusal relaxes the
/// mode, flushes, puts the mode back through that same handle and
/// flushes again. The second flush is what makes the restored mode
/// durable; a chmod by path after the last flush would leave the file
/// read-only to a reader and writable on disk.
///
/// On Ok, what is on disk is the bytes and the mode the copy carried
/// over. The window this cannot close is between relaxing the mode and
/// that second flush: a crash inside it leaves the copy owner-writable
/// on disk, and the only way to avoid opening it would be a flush the
/// platform refuses. Nothing reads a pre-image through that window — a
/// journal whose `meta.json` was never written is swept rather than
/// replayed, and a rollback a crash interrupts is re-run, laying the
/// pre-image down again.
fn sync_written_file(path: &Path) -> Result<()> {
    let write_handle = || fs::OpenOptions::new().write(true).open(path);
    let refused = match write_handle() {
        Ok(file) => return file.sync_all().map_err(|e| CoreError::io(path, e)),
        Err(refused) if refused.kind() == PermissionDenied => refused,
        Err(other) => return Err(CoreError::io(path, other)),
    };
    let Ok(mode) = fs::metadata(path).map(|meta| meta.permissions()) else {
        return Err(CoreError::io(path, refused));
    };
    fs::set_permissions(path, writable(&mode)).map_err(|e| CoreError::io(path, e))?;
    let flushed = write_handle().and_then(|file| {
        file.sync_all()?;
        file.set_permissions(mode.clone())?;
        file.sync_all()
    });
    // The mode goes back whether any of that worked or not, and by path,
    // because what failed may have been the handle itself. Where the
    // block above reached its own restore this repeats a mode already on
    // disk, so a crash losing this chmod cannot leave the file writable.
    fs::set_permissions(path, mode).map_err(|e| CoreError::io(path, e))?;
    flushed.map_err(|e| CoreError::io(path, e))
}

/// `mode` with this process able to write and nothing else relaxed.
/// `Permissions::set_readonly(false)` sets every write bit on Unix, group
/// and other along with owner, which is wider than a flush needs.
fn writable(mode: &fs::Permissions) -> fs::Permissions {
    let mut relaxed = mode.clone();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        relaxed.set_mode(mode.mode() | 0o200);
    }
    #[cfg(not(unix))]
    {
        relaxed.set_readonly(false);
    }
    relaxed
}

/// Persist a directory's own entries — the names in it, not the bytes of
/// what they name. Unix only: Windows has no handle to a directory to
/// flush, so there a new or renamed *name* rides on the volume flush
/// while the *bytes* under it are already durable, through
/// `copy_file_durable` or `atomic_write_durable`. That asymmetry is the
/// whole of the platform gap — file contents are guaranteed on both,
/// directory entries only on Unix.
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

/// Reproduce a whole tree at `to`, with every file on disk before this
/// returns: each file copied and flushed by `copy_file_durable`, each
/// directory synced through `sync_dir_durable` once its entries are in
/// it. A directory sync that fails stops the copy — the best-effort
/// `sync_dir` would let this return Ok over a name that never reached
/// disk, and the journal writes its meta on the strength of that Ok.
/// Nothing outside the tree is opened — a link is reproduced as a link
/// and never read through — so the sync reaches exactly what this copy
/// created and nothing else.
pub(crate) fn copy_tree_durable(from: &Path, to: &Path) -> Result<()> {
    copy_tree_inner(from, to, true)
}

fn copy_tree_inner(from: &Path, to: &Path, durable: bool) -> Result<()> {
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
        copy_any_inner(&source, &to.join(name), durable)?;
    }
    if durable {
        sync_dir_durable(to)?;
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
    copy_any_inner(from, to, false)
}

fn copy_any_inner(from: &Path, to: &Path, durable: bool) -> Result<()> {
    if from.is_symlink() {
        let target = fs::read_link(from).map_err(|e| CoreError::io(from, e))?;
        make_symlink(&target, to)
    } else if from.is_dir() {
        copy_tree_inner(from, to, durable)
    } else if durable {
        copy_file_durable(from, to)
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
    match links::leads_to_dir(link, target) {
        true => std::os::windows::fs::symlink_dir(target, link).map_err(|e| CoreError::io(link, e)),
        false => {
            std::os::windows::fs::symlink_file(target, link).map_err(|e| CoreError::io(link, e))
        }
    }
}

#[cfg(test)]
mod tests;
