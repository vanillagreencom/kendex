use std::fs;
use std::path::Path;

/// A file held under the OS's exclusive lock, released on drop. The one
/// owner of the lock-file ritual: callers hold this value and never touch
/// fd-lock, `mem::forget`, or the release themselves.
pub(crate) struct LockedFile {
    file: fs::File,
}

impl LockedFile {
    /// Take the exclusive lock at `path`, creating the file as needed.
    /// `Ok(None)` is contention. Any other failure stays an error; a
    /// filesystem that cannot lock must not be reported as merely busy.
    pub(crate) fn try_exclusive(path: &Path) -> std::io::Result<Option<LockedFile>> {
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)?;
        Self::from_file(file)
    }

    /// Lock an owned state file without accepting a symlink as its identity.
    pub(crate) fn try_exclusive_no_follow(path: &Path) -> std::io::Result<Option<LockedFile>> {
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(false).write(true);
        add_no_follow(&mut options);
        let file = options.open(path)?;
        if file.metadata()?.file_type().is_symlink() {
            return Err(std::io::Error::other("lock path is a symlink"));
        }
        Self::from_file(file)
    }

    fn from_file(file: fs::File) -> std::io::Result<Option<LockedFile>> {
        // The OS lock belongs to the open file description. Keep the file
        // and forget fd-lock's borrow guard; Drop releases it explicitly.
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

/// Open one owned file descriptor without following the final component.
pub(crate) fn open_read_no_follow(path: &Path) -> std::io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    add_no_follow(&mut options);
    let file = options.open(path)?;
    if file.metadata()?.file_type().is_symlink() {
        return Err(std::io::Error::other("path is a symlink"));
    }
    Ok(file)
}

#[cfg(unix)]
fn add_no_follow(options: &mut fs::OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
}

#[cfg(windows)]
fn add_no_follow(options: &mut fs::OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
}

#[cfg(not(any(unix, windows)))]
fn add_no_follow(_options: &mut fs::OpenOptions) {}

/// Release before close. On unix a fork can keep a copy of the open file
/// description alive until exec, so close alone can leave a spurious holder.
/// Windows has no fork window and releases when the handle closes.
impl Drop for LockedFile {
    fn drop(&mut self) {
        // Unlocking a valid fd has no actionable failure. Close follows as
        // the fallback once any forked description copies are gone.
        #[cfg(all(unix, not(target_os = "solaris")))]
        let _ = rustix::fs::flock(&self.file, rustix::fs::FlockOperation::Unlock);
        #[cfg(target_os = "solaris")]
        let _ = rustix::fs::fcntl_lock(&self.file, rustix::fs::FlockOperation::Unlock);
    }
}
