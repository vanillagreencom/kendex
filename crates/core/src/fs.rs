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
    fs::write(&tmp, contents).map_err(|e| CoreError::io(&tmp, e))?;
    if durable {
        fs::File::open(&tmp)
            .and_then(|f| f.sync_all())
            .map_err(|e| CoreError::io(&tmp, e))?;
    }
    fs::rename(&tmp, &path).map_err(|e| CoreError::io(&path, e))?;
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
                bodies.iter().any(|body| *body == written),
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
