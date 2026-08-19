//! Whether a cache entry is THERE — and what it means when that cannot be
//! told.
//!
//! One probe for both spellings of a cache source. `Path::exists` answers
//! false for a permission or I/O error exactly as it does for a missing file,
//! and while two functions asked this question separately, fixing the collapse
//! for one spelling left the other reporting an unreadable clone as absent —
//! a cause that is false and a remedy that deletes a good clone.

use super::*;

/// Whether a cache entry's `.git` is there, with a read that could not be
/// COMPLETED kept distinct from an answer of "no".
///
/// The one place that question is asked. `Path::exists` collapses the two — it
/// answers false for a permission or I/O error exactly as it does for a
/// missing file — and both spellings of a cache source ask it: a path-recorded
/// one through [`cache_entry_is_present`], a URL-recorded one through
/// [`cache_entry_present`]. Fixing it for one spelling and not the other left
/// a root-owned or unreadable clone reported as "not present" depending only
/// on how the lock spelled it, with a cause that is false and a remedy that
/// deletes a good clone.
fn cache_git_dir_presence(cache_dir: &Path) -> std::io::Result<bool> {
    match std::fs::metadata(cache_dir.join(".git")) {
        Ok(_) => Ok(true),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(err) => Err(err),
    }
}

/// [`cache_git_dir_presence`] for a URL-recorded source, whose `cache_dir` is
/// DERIVED rather than named by a user.
///
/// It stops at the probe: a directory sitting at a derived key with no `.git`
/// is a stale artifact rather than a source anyone pointed at, and
/// [`clone_cached_repo`] already decides what to do with one — clone into it
/// while it is empty, refuse it once it is not. That judgement is the half
/// these two spellings do NOT share, which is why the probe is what was
/// unified and not the whole function.
pub(crate) fn cache_entry_present(remote: &RemoteSource) -> Result<bool> {
    cache_git_dir_presence(&remote.cache_dir).map_err(|err| {
        // Deliberately not [`refusal`]: that ends with "Remove its cache
        // entry", which is the one thing not to do about a permission bit.
        anyhow::anyhow!(
            "refusing cached source {}: its `.git` could not be read: {err}",
            remote.display
        )
    })
}

pub(super) fn cache_entry_is_present(entry: &Path) -> Result<bool> {
    match cache_git_dir_presence(entry) {
        Ok(true) => Ok(true),
        Ok(false) => {
            if !entry.is_dir() {
                return Ok(false);
            }
            bail!(
                "refusing source {}: it is inside vstack's cache but is not one of its clones — it has no `.git`, so no remote can be established for it. Remove it from {} and re-add the source it should come from",
                entry.display(),
                remote_cache_root().display()
            )
        }
        // A read that could not be completed, reported as exactly that — no
        // verdict on what is there, and no advice to remove anything.
        Err(err) => bail!(
            "refusing source {}: its `.git` could not be read: {err}",
            entry.display()
        ),
    }
}
