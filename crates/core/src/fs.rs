use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::{CoreError, Result};

/// Write via a sibling temp file + rename so readers never see a torn file.
/// A symlink at the path is followed: the file it points at is replaced and
/// the link stays — renaming over the link itself would swap a user's
/// dotfiles link for a detached copy.
pub fn atomic_write(path: &Path, contents: &str) -> Result<()> {
    write_then_rename(path, contents, false)
}

/// `atomic_write` plus full crash durability: the temp file syncs before
/// the rename and the parent directory syncs after, so after this returns
/// the file either exists complete or not at all — even across power loss.
pub fn atomic_write_durable(path: &Path, contents: &str) -> Result<()> {
    write_then_rename(path, contents, true)
}

fn write_then_rename(path: &Path, contents: &str, durable: bool) -> Result<()> {
    let path = follow_link(path);
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::io(&path, std::io::Error::other("path has no parent")))?;
    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    // One temp name per write, not per process: two writers sharing a name
    // truncate each other's bytes, and the one that loses the rename either
    // fails with ENOENT or writes its payload straight over the live file
    // the winner just moved into place. The app writes settings from a
    // thread pool, so same-path writes really do overlap.
    let tmp = path.with_extension(format!(
        "tmp.{}.{}",
        std::process::id(),
        NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
    ));
    // A failed write leaves nothing behind. With a name per attempt there is
    // no next writer to overwrite an abandoned temp file, so it would just
    // sit there beside the real one — a full copy of whatever was being
    // saved, growing by one file per failure.
    let discard = |error: std::io::Error, at: &Path| {
        let _ = fs::remove_file(&tmp);
        CoreError::io(at, error)
    };
    fs::write(&tmp, contents).map_err(|e| discard(e, &tmp))?;
    if durable {
        fs::File::open(&tmp)
            .and_then(|f| f.sync_all())
            .map_err(|e| discard(e, &tmp))?;
    }
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

/// A file held under the OS's exclusive lock, released on drop. The one
/// owner of the lock-file ritual: callers hold a `LockedFile` and never
/// touch fd-lock, `mem::forget`, or the release themselves.
pub(crate) struct LockedFile {
    file: fs::File,
}

impl LockedFile {
    /// Take the exclusive lock at `path`, creating the file as needed.
    /// `Ok(None)` is contention — a live holder exists. Any other failure
    /// is an error: a filesystem that cannot lock at all must say so, or
    /// every caller would read it as "busy" and wait on nobody.
    pub(crate) fn try_exclusive(path: &Path) -> std::io::Result<Option<LockedFile>> {
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)?;
        // fd-lock ties its guard lifetime to the RwLock borrow; the OS
        // lock is really held by the open fd, so forget the guard and
        // keep the file — Drop below releases explicitly.
        let mut lock = fd_lock::RwLock::new(file);
        match lock.try_write() {
            Ok(guard) => std::mem::forget(guard),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(None),
            Err(error) => return Err(error),
        }
        Ok(Some(LockedFile {
            file: lock.into_inner(),
        }))
    }

    /// Test-only view of the fd, for cloning a description copy.
    #[cfg(test)]
    pub(crate) fn file(&self) -> &fs::File {
        &self.file
    }
}

/// Release the OS lock before the fd closes. On unix, close alone is not
/// release: a child forked by any thread while this fd was open holds a
/// copy of the open file description until it execs — O_CLOEXEC closes at
/// exec, not at fork — and the lock stays held until every copy is gone.
/// That window turns an unlock-by-close into a spurious "busy" for whoever
/// re-locks the path next, with no holder actually alive. An explicit
/// unlock frees the description immediately, no matter who still holds a
/// copy. Windows spawns without fork, so no copy outlives the guard; the
/// handle's close is the release there, which LockFileEx documents may lag
/// briefly — accepted, since the safe unlock APIs do not reach Windows and
/// there is no fork window to defend against.
impl Drop for LockedFile {
    fn drop(&mut self) {
        // Unlocking a valid fd has no failure mode worth surfacing from a
        // Drop, and the close that follows releases too once stray
        // description copies are gone; best-effort is honest here.
        // Solaris has no flock in rustix; fd-lock locks there via fcntl,
        // so the release mirrors it.
        #[cfg(all(unix, not(target_os = "solaris")))]
        let _ = rustix::fs::flock(&self.file, rustix::fs::FlockOperation::Unlock);
        #[cfg(target_os = "solaris")]
        let _ = rustix::fs::fcntl_lock(&self.file, rustix::fs::FlockOperation::Unlock);
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

pub(crate) fn sync_tree(root: &Path) -> Result<()> {
    if root.is_file() {
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
    for entry in fs::read_dir(from)
        .map_err(|e| CoreError::io(from, e))?
        .flatten()
    {
        let source = entry.path();
        let Some(name) = source.file_name() else {
            continue;
        };
        let dest = to.join(name);
        if source.is_symlink() {
            let target = fs::read_link(&source).map_err(|e| CoreError::io(&source, e))?;
            make_symlink(&target, &dest)?;
        } else if source.is_dir() {
            copy_tree(&source, &dest)?;
        } else {
            fs::copy(&source, &dest).map_err(|e| CoreError::io(&source, e))?;
        }
    }
    Ok(())
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
mod tests {
    use super::*;

    /// The app saves settings from a Tokio thread pool, so a slider drag can
    /// put several writes of one file in flight at once. Sharing a temp name
    /// made them collide: the loser either failed to rename or wrote its
    /// payload over the live file, leaving it half one write and half the
    /// other.
    #[test]
    fn concurrent_writers_of_one_file_all_succeed_and_leave_it_whole() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("settings.toml");
        let bodies: Vec<String> = (0..8)
            .map(|writer| {
                format!(
                    "writer = {writer}\npadding = \"{}\"\n",
                    "x".repeat(writer * 40)
                )
            })
            .collect();

        for _ in 0..50 {
            std::thread::scope(|scope| {
                for body in &bodies {
                    scope.spawn(|| atomic_write(&path, body).expect("every writer succeeds"));
                }
            });
            let written = fs::read_to_string(&path).unwrap();
            assert!(
                bodies.contains(&written),
                "the file is one writer's bytes, not a mixture: {written:?}"
            );
        }
        // Nothing is left behind for the next reader to trip over.
        let leftovers: Vec<_> = fs::read_dir(tmp.path())
            .unwrap()
            .filter_map(|entry| entry.ok().map(|e| e.file_name()))
            .filter(|name| name != "settings.toml")
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    /// Renaming onto a directory is the failure this can force; every other
    /// one leaves the same debris. Both entry points share the helper, so
    /// both are checked.
    #[test]
    fn a_write_that_cannot_finish_leaves_no_temp_file_behind() {
        let tmp = tempfile::tempdir().unwrap();
        let occupied = tmp.path().join("settings.toml");
        fs::create_dir(&occupied).unwrap();

        for write in [atomic_write, atomic_write_durable] {
            assert!(write(&occupied, "schema = 1\n").is_err());
        }

        let leftovers: Vec<_> = fs::read_dir(tmp.path())
            .unwrap()
            .filter_map(|entry| entry.ok().map(|e| e.file_name()))
            .filter(|name| name != "settings.toml")
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_file_is_rewritten_through_the_link() {
        let tmp = tempfile::tempdir().unwrap();
        let real = tmp.path().join("dotfiles/kendex.toml");
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::write(&real, "old").unwrap();
        let link = tmp.path().join("kendex.toml");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        atomic_write(&link, "new").unwrap();
        atomic_write_durable(&link, "newer").unwrap();

        assert!(link.is_symlink());
        assert_eq!(fs::read_to_string(&real).unwrap(), "newer");
    }
}
