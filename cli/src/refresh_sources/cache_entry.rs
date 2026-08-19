//! Vstack's own cache entries, as sources.
//!
//! Which entry a recorded source names — including one recorded as a PATH into
//! the cache rather than as a URL — and what resolving that entry produces.
//! The cache is state vstack fetches and `reset --hard`s on a TTL, never a
//! checkout a user maintains, so an entry reached by either spelling arrives
//! at the same fetch, the same lease and the same ownership proofs.
//!
//! Choosing between the local, relative and remote branches for one source
//! string stays in [`super`]; this is the remote branch and the mapping that
//! reaches it.

use super::*;
use crate::config;
use std::path::Path;

/// Whether `path` names an entry directly under vstack's own remote cache.
///
/// Judged from the path's PARENT, never from the entry itself: an entry that
/// is a symlink pointing out of the cache is still an entry the cache owns,
/// and classifying it by where it leads is what let it be read as an ordinary
/// local directory — skipping the very ownership proofs that exist to refuse
/// it.
pub(crate) fn is_remote_cache_entry_path(path: &Path) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    path.is_absolute()
        && path.file_name().is_some()
        && canonicalish(parent) == canonicalish(&remote_cache_root())
}

/// The remote a cache entry is a clone of, read from the entry's own `origin`.
///
/// The origin is the only reliable answer. A cache key is derived FROM the
/// repository identity and is not reversible back into one: an entry minted by
/// an older vstack carries a different key for the same repository, and this
/// machine can hold both — `vanillagreencom_vstack` beside
/// `vanillagreencom_vstack-ff0070a84862081c`, one repository, two keys. So the
/// directory name is never parsed back into a remote.
///
/// The remote is PINNED to the entry the caller named: `cache_dir` stays that
/// directory rather than becoming whichever key the URL hashes to today, so
/// the fetch, the lease and the drift comparison all act on the tree the
/// entries were installed from, and resolution never redirects an install to a
/// different clone — or to one that was never cloned at all. Migrating the
/// recorded source onto the URL itself is `refresh`'s job, and it happens only
/// once the canonical entry is present and current: see
/// [`migrated_cache_entry_source`].
fn cache_entry_remote(path: &Path) -> Result<RemoteSource> {
    let entry = path.display();
    let output = hardened_cache_git_command(path)?
        .args(["remote", "get-url", "origin"])
        .output()
        .with_context(|| format!("reading the origin of cache entry {entry}"))?;
    if !output.status.success() {
        bail!(
            "refusing source {entry}: it is an entry in vstack's own cache whose origin could not be read ({}), so the remote it must be fetched from is unknown",
            git_output_summary(&output)
        );
    }
    let origin = git_stdout_line(&output.stdout);
    let remote = RemoteSource::parse(&origin)
        .with_context(|| format!("refusing source {entry}: it is an entry in vstack's own cache"))?
        .ok_or_else(|| {
            anyhow::anyhow!(
                "refusing source {entry}: it is an entry in vstack's own cache whose origin {} is not a remote vstack can fetch, so it cannot be kept up to date",
                remote_source_display(&origin)
            )
        })?;
    Ok(RemoteSource {
        cache_key: path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        cache_dir: path.to_path_buf(),
        ..remote
    })
}

/// The remote spec a source recorded as a cache-entry path should be rewritten
/// to, so the lock records the remote rather than one machine's clone of it —
/// with vstack's own entry for that remote brought up to date first.
///
/// `None` unless both halves of the migration hold. The canonical entry must
/// already be on this machine, because nothing short of `vstack add` mints one
/// and a lock naming a remote with no clone resolves to nothing. And its fetch
/// must succeed, because the caller hashes the entry against the source it now
/// records: recording the spec while the canonical clone still sat at an older
/// revision wrote a `source_hash` for a tree the install did not come from,
/// which the next `check` then reported as drift in the wrong direction. Until
/// both hold, the recorded path keeps resolving and keeps fetching, so waiting
/// costs the entry nothing.
///
/// Past the rewrite the question cannot arise again: resolution and hashing
/// name the same one directory, where before they named two clones free to sit
/// at different revisions with nothing to converge them.
pub(crate) fn migrated_cache_entry_source(source: &str) -> Option<String> {
    let path = Path::new(source);
    if !is_remote_cache_entry_path(path) {
        return None;
    }
    let remote = cache_entry_remote(path).ok()?;
    let canonical = RemoteSource::parse(&remote.git_url).ok()??;
    if !cache_entry_present(&canonical) {
        return None;
    }
    // The lease is released here: what the caller reads next is the hash of
    // this entry, taken through the same unleased read every `source_hash`
    // takes.
    drop(update_cached_repo(&canonical).ok()?);
    Some(canonical.git_url)
}

/// The remote a recorded source names, whether it is spelled as a URL, as
/// GitHub shorthand, or as a path into vstack's own cache.
///
/// `Ok(None)` when the source names no remote at all; `Err` when it names one
/// that must not be used. Callers that enumerate a lock's caches read this
/// rather than [`RemoteSource::parse`], so a cache entry a fetch mutates and a
/// cache entry a report reads can never be two different directories.
pub(crate) fn remote_for_source(source: &str) -> Result<Option<RemoteSource>> {
    let path = Path::new(source);
    if is_remote_cache_entry_path(path) {
        if !path.join(".git").exists() {
            return Ok(None);
        }
        return cache_entry_remote(path).map(Some);
    }
    RemoteSource::parse(source)
}

/// The remote half of [`resolve_single_source_with`], reached by a source
/// spelled as a URL and by one spelled as a path into the cache alike — so
/// both arrive at the same fetch, the same lease and the same ownership
/// proofs, and neither can be given a freshness the other is denied.
pub(super) fn resolve_remote_source(remote: RemoteSource, update_remote: bool) -> LeasedResolution {
    if !cache_entry_present(&remote) {
        return SourceResolution::Absent.into();
    }
    if update_remote {
        eprintln!("Updating cached repo {}...", remote.display);
        // The update path runs the filesystem checks itself, on its way to the
        // git-level ones that guard `reset --hard`.
        return match update_cached_repo(&remote) {
            // The lease travels with the directory it protects: whoever reads
            // this root holds it until the read is done.
            Ok(lease) => LeasedResolution {
                resolution: SourceResolution::Resolved(remote.cache_dir),
                lease,
            },
            Err(err) => SourceResolution::refused(&err).into(),
        };
    } else if config::remote_cache_fetch_in_flight(&remote.cache_dir) {
        // Read-only, and another process is mid-fetch: this tree is being
        // `reset --hard` right now, so every question asked of it — which
        // assets it ships, what they hash to, even which repository its
        // `.git/config` names — can be answered wrongly rather than not at
        // all. Probed, never waited on: the session-start check runs this path
        // and must stay local, so the answer is "not this run" rather than a
        // lease taken out from under an install.
        return SourceResolution::Busy.into();
    } else if let Err(err) = ensure_cache_entry_is_owned(&remote) {
        // The same question the update path asks, because reading an entry is
        // how its content becomes the installed asset: a symlinked entry or a
        // redirected `.git` is some other checkout, and an entry whose origin
        // is a different repository would be installed as this source. Every
        // check is a read; only the fetch and reset the update path adds are
        // not.
        return SourceResolution::refused(&err).into();
    }
    SourceResolution::Resolved(remote.cache_dir).into()
}

#[cfg(test)]
mod tests;
