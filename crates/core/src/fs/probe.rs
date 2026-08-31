//! Two probes: what is at a path, and whether it would run. The first
//! keeps the filesystem's refusal to answer apart from its saying nothing
//! is there; the second collapses both into a no, which is all a caller
//! asking "would a shell run this" can act on.

use std::fs;
use std::io::ErrorKind::{NotADirectory, NotFound};
use std::path::Path;

use crate::error::{CoreError, Result};

/// Whether a path is something a shell would run: a regular file with an
/// execute bit. Being present is a different question — a directory, or a
/// data file, can carry the name of a command and answer yes to it.
pub fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// What is at `path`: `Some` metadata, `None` when nothing is, an error when
/// the filesystem will not say. The one place the three answers are kept
/// apart, for a caller deciding what a write would land on: absent and
/// unanswerable are the same word in a boolean, and that word is how a guard
/// deletes what it exists to protect. A link is not looked through — one
/// whose target is gone still stands in that name's way.
pub(crate) fn entry(path: &Path) -> Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(meta) => Ok(Some(meta)),
        Err(e) if absent(&e) => Ok(None),
        Err(e) => Err(CoreError::io(path, e)),
    }
}

/// Whether the filesystem said nothing is there, rather than declining to
/// say. Absent has two spellings — no such name, and a name built under a
/// file — and every probe that keeps the third answer apart from the
/// second reads them from here, so a spelling added for one is not missed
/// by another in the opposite fail direction.
pub(crate) fn absent(error: &std::io::Error) -> bool {
    matches!(error.kind(), NotFound | NotADirectory)
}
