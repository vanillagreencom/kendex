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
//! One handle has to carry everything the two steps carried, not merely
//! look like them. What the pair held, and holds here:
//!
//! - **Not a link.** `plain_tree` asked `symlink_metadata`; the open
//!   refuses to follow one, on every platform that can be told to — and
//!   where none can, the operation refuses rather than quietly writing
//!   through. A guarantee the type promises everywhere cannot be true on
//!   one platform only.
//! - **Not a directory, pipe, socket or device.** `plain_tree` asked
//!   before opening; here the handle's own `fstat` answers. The open
//!   happens first, so it carries `O_NONBLOCK` — a pipe must not be able
//!   to hold the apply still — and the refusal follows immediately.
//! - **The plan's bytes.** `hash_tree` of a lone file and `hash_bytes` of
//!   its content are the same function, which `base.rs` pins.
//! - **The real cause.** A world that moved under the plan is
//!   [`CoreError::PlanStale`]; a permission, an encoding, a full disk is
//!   the error actually met. Re-plan and retry is a remedy for the first
//!   and useless for the rest.
//! - **Nothing mutated before a refusal.** Every refusal here happens
//!   before a byte is written, which is what the op contract requires:
//!   the rollback reads `PlanStale` as proof the op ran nothing.
//! - **The file's identity.** Truncating through the handle keeps the
//!   inode, so mode, owner and hard links survive as they did under
//!   `fs::write`.
//! - **Nothing made for a write that does not happen.** The absent half
//!   creates at write time, so an edit that changes nothing leaves the
//!   place as it found it.
//!
//! What this does not close: the final component is resolved once, the
//! parent directories as every other path in the apply resolves them. A
//! hard link is a plain file to this and to `plain_tree` both. Closing
//! either reaches every read and write kendex makes.

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
pub(super) fn open(path: &Path, pre: &Pre) -> Result<Option<Plain>> {
    match pre {
        Pre::PlainHashIs { hash } => {
            let mut file = open_existing(path).map_err(|error| classify(path, error))?;
            // fstat through the handle: a second look at the name could
            // answer for a different file. This is what `plain_tree` asked
            // of a path before anything opened it.
            let kind = file.metadata().map_err(|e| CoreError::io(path, e))?;
            if !kind.file_type().is_file() {
                return Err(stale(path));
            }
            let mut content = Vec::new();
            file.read_to_end(&mut content)
                .map_err(|e| CoreError::io(path, e))?;
            if hash_bytes(&content) != *hash {
                return Err(stale(path));
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

    /// The content as text, refusing bytes that are not UTF-8 exactly as
    /// [`crate::fs::read_if_exists`] does. A lossy read would put U+FFFD
    /// where somebody's bytes were and write the replacement back.
    pub(super) fn text(&self, path: &Path) -> Result<String> {
        String::from_utf8(self.content().to_vec()).map_err(|_| {
            CoreError::io(
                path,
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "stream did not contain valid UTF-8",
                ),
            )
        })
    }

    /// Put these bytes in the file, through the handle it was proved on.
    /// In place, as `fs::write` is: a crash mid-write is what the
    /// journal's pre-image exists to undo.
    pub(super) fn write(self, path: &Path, bytes: &[u8]) -> Result<()> {
        let io = |e| CoreError::io(path, e);
        let mut file = match self {
            Plain::Held { file, .. } => file,
            Plain::Create => create_exclusively(path)?,
        };
        file.set_len(0).map_err(io)?;
        file.rewind().map_err(io)?;
        file.write_all(bytes).map_err(io)?;
        file.flush().map_err(io)
    }
}

/// Create the file, and the directory it needs, in the order that keeps
/// `PlanStale` honest.
///
/// The exclusive create comes first, so a name somebody else won is
/// refused before anything is made — `PlanStale` is the rollback's proof
/// that the failing op ran nothing, and a directory left behind would make
/// it a lie. Only a missing parent sends us back to make one, and after
/// that the op HAS mutated, so a second failure is reported as itself
/// however it looks.
fn create_exclusively(path: &Path) -> Result<fs::File> {
    match create_new(path) {
        Ok(file) => Ok(file),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ensure_parent(path)?;
            create_new(path).map_err(|error| CoreError::io(path, error))
        }
        Err(error) => Err(classify(path, error)),
    }
}

/// The directory a write lands in, made if it is not there.
pub(super) fn ensure_parent(path: &Path) -> Result<()> {
    match path.parent() {
        Some(parent) => fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e)),
        None => Ok(()),
    }
}

fn stale(path: &Path) -> CoreError {
    CoreError::PlanStale {
        path: path.to_path_buf(),
    }
}

/// Why an open failed, in terms a person can act on.
///
/// A world that moved under the plan is a stale plan, and re-planning is
/// the way out. Everything else — a permission, a read-only mount, a full
/// disk — is reported as itself, because "re-plan and retry" is a remedy
/// that cannot fix any of them and hides the one thing that would have
/// said what went wrong.
fn classify(path: &Path, error: std::io::Error) -> CoreError {
    match moved_under_the_plan(&error) {
        true => stale(path),
        false => CoreError::io(path, error),
    }
}

/// Whether this open failure says the thing at the path is not the thing
/// the plan looked at.
///
/// Every way a swap shows up, rather than the ones that came to mind: the
/// file gone or arrived, a link, a directory, a parent that stopped being
/// one, and the kinds `open(2)` refuses outright — a socket answers `ENXIO`
/// on Linux and `EOPNOTSUPP` on the BSDs, a device whose driver is absent
/// answers `ENODEV`. A permission or a full disk is not on the list and
/// never should be: those are the file, said honestly.
fn moved_under_the_plan(error: &std::io::Error) -> bool {
    use std::io::ErrorKind;
    matches!(error.kind(), ErrorKind::NotFound | ErrorKind::AlreadyExists) || moved_by_errno(error)
}

/// The same question in the codes only unix spells: a link where a file
/// was, a directory where a file was, a parent that stopped being one.
/// `std::io::ErrorKind` has names for these and they are not stable yet.
#[cfg(unix)]
fn moved_by_errno(error: &std::io::Error) -> bool {
    use rustix::io::Errno;
    let moved = [
        Errno::LOOP,
        Errno::ISDIR,
        Errno::NOTDIR,
        Errno::NXIO,
        Errno::NODEV,
        Errno::OPNOTSUPP,
    ];
    error
        .raw_os_error()
        .is_some_and(|code| moved.iter().any(|errno| errno.raw_os_error() == code))
}

#[cfg(not(unix))]
fn moved_by_errno(_error: &std::io::Error) -> bool {
    false
}

/// Open the file itself, never a link standing in for it, and never in a
/// way a pipe could hold open.
#[cfg(unix)]
fn open_existing(path: &Path) -> std::io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let flags = rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(flags.bits() as i32)
        .open(path)
}

/// Windows opens the reparse point rather than what it points at; the
/// `fstat` above then refuses it, because a reparse point is not a file.
#[cfg(windows)]
fn open_existing(path: &Path) -> std::io::Result<fs::File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

/// Somewhere that cannot be told not to follow a link. The precondition
/// promises the path IS the file, and this build cannot keep that promise
/// here, so the operation refuses instead of writing through whatever the
/// name reaches. A refusal that says so is honest; a write that silently
/// lost the guarantee is not.
#[cfg(not(any(unix, windows)))]
fn open_existing(_path: &Path) -> std::io::Result<fs::File> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "this platform cannot open a file without following a link, and this write is only allowed to touch the file itself",
    ))
}

fn create_new(path: &Path) -> std::io::Result<fs::File> {
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(path)
}

#[cfg(test)]
mod tests;
