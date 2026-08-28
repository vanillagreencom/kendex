//! Writing a file whose precondition names its KIND, with the path
//! resolved exactly once.
//!
//! [`Pre::PlainHashIs`] and [`Pre::PlainAbsent`] say more than "these
//! bytes": they say the path IS the file, not a link to one. Checking that
//! and then calling `fs::write` resolves the name a second time, and a
//! link arriving between the two is followed — so the bytes land wherever
//! it points, past a refusal the plan already made. The window is narrow
//! and it is a race all the same: a precondition naming a property the
//! next syscall re-resolves cannot hold.
//!
//! So the check and the mutation share one handle. The file is opened
//! without following a link, its kind and content are read through that
//! handle, and the same handle is what the bytes go into. Nothing between
//! the two touches the name.
//!
//! What this closes is the final component. A parent directory is still
//! resolved the way every other path in the apply resolves one — closing
//! that means walking each component with `openat`, which is a different
//! change reaching every read and write kendex makes.

use std::fs;
use std::io::{Read, Seek, Write};
use std::path::Path;

use super::pre::Pre;
use crate::error::{CoreError, Result};
use crate::hash::hash_bytes;

/// What a `Plain*` precondition proved, ready to be written through.
pub(super) enum Plain {
    /// An existing plain file, open, with what it held.
    Held { file: fs::File, content: Vec<u8> },
    /// Nothing is there. Creating it exclusively IS the check, made at
    /// the moment of the write, so there is no window for a link to
    /// arrive in — and nothing is created for an edit that turns out to
    /// change nothing.
    Create,
}

/// Open and verify, or `Ok(None)` where this precondition names no kind
/// and the ordinary check-then-write applies.
///
/// Every refusal here is [`CoreError::PlanStale`] and happens before a
/// byte is written, which is what the op contract requires: the rollback
/// reads that error as proof the op mutated nothing.
pub(super) fn open(path: &Path, pre: &Pre) -> Result<Option<Plain>> {
    let stale = || CoreError::PlanStale {
        path: path.to_path_buf(),
    };
    match pre {
        Pre::PlainHashIs { hash } => {
            let mut file = open_existing(path).ok_or_else(stale)?;
            // fstat through the handle: a second look at the name could
            // answer for a different file.
            let kind = file.metadata().map_err(|e| CoreError::io(path, e))?;
            if !kind.file_type().is_file() {
                return Err(stale());
            }
            let mut content = Vec::new();
            file.read_to_end(&mut content)
                .map_err(|e| CoreError::io(path, e))?;
            if hash_bytes(&content) != *hash {
                return Err(stale());
            }
            Ok(Some(Plain::Held { file, content }))
        }
        Pre::PlainAbsent => Ok(Some(Plain::Create)),
        _ => Ok(None),
    }
}

impl Plain {
    /// What the file held when its precondition was checked — read once,
    /// through the handle, so a caller needing the old content is not
    /// reading a second time from a name that may have moved.
    pub(super) fn content(&self) -> &[u8] {
        match self {
            Plain::Held { content, .. } => content,
            Plain::Create => &[],
        }
    }

    /// Put these bytes in the file, through the handle it was proved on.
    /// In place, as `fs::write` is: a crash mid-write is what the
    /// journal's pre-image exists to undo.
    pub(super) fn write(self, path: &Path, bytes: &[u8]) -> Result<()> {
        let io = |e| CoreError::io(path, e);
        ensure_parent(path)?;
        let mut file = match self {
            Plain::Held { file, .. } => file,
            Plain::Create => create_new(path).ok_or(CoreError::PlanStale {
                path: path.to_path_buf(),
            })?,
        };
        file.set_len(0).map_err(io)?;
        file.rewind().map_err(io)?;
        file.write_all(bytes).map_err(io)?;
        file.flush().map_err(io)
    }
}

/// The directory a write lands in, made if it is not there.
pub(super) fn ensure_parent(path: &Path) -> Result<()> {
    match path.parent() {
        Some(parent) => fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e)),
        None => Ok(()),
    }
}

#[cfg(unix)]
fn open_existing(path: &Path) -> Option<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)
        .ok()
}

/// Elsewhere the open resolves the name as the platform does, and the
/// precondition's own check is what refuses a link it can see — the same
/// posture the content reader in `engine::compared` takes, and for the
/// same reason: closing the window needs a flag this build does not reach
/// for here.
#[cfg(not(unix))]
fn open_existing(path: &Path) -> Option<fs::File> {
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .ok()
}

fn create_new(path: &Path) -> Option<fs::File> {
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(path)
        .ok()
}

#[cfg(test)]
mod tests;
