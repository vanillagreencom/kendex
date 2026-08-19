//! `add` given a source that names a path inside vstack's own cache.
//!
//! The cache is TTL-managed state vstack fetches and `reset --hard`s, so such
//! a path is fetched, leased and proved vstack's own before a byte is read out
//! of it — the same treatment a URL gets. Reading one as a plain local
//! directory was the whole defect on this side.

use super::*;

/// A source that names a path in vstack's own cache, resolved the way every
/// other reader of that cache resolves one: fetched, leased, and proved
/// vstack's own before a byte is read out of it.
///
/// `None` leaves the caller's ordinary chain alone — only a path inside the
/// cache comes through here, so no other source can change which clone it
/// installs from. Inside the cache the local-directory shortcut was the whole
/// defect: it installed whatever bytes were sitting in a TTL-managed clone, so
/// `add` printed `(updated)` while writing a revision behind upstream and
/// leaving the cache untouched.
///
/// A path at the entry ROOT resolves through the remote itself — the entry is
/// one machine's clone of a repository, and `add` is the one command that may
/// mint the canonical clone if this machine lacks it — so what gets recorded
/// is the remote spec. A path BELOW the entry cannot be spelled as a remote,
/// so its entry is fetched and leased and the subdirectory is read inside the
/// tree that fetch left behind.
pub(super) fn resolve_cache_path_source(
    source: &str,
    fetch: SourceFetch,
) -> Option<Result<(LeasedSourceDir, String)>> {
    let found = crate::refresh_sources::cache_path_install_source(source)?;
    Some(resolve_cache_path_source_inner(found, fetch))
}

fn resolve_cache_path_source_inner(
    found: Result<crate::refresh_sources::CachePathSource>,
    fetch: SourceFetch,
) -> Result<(LeasedSourceDir, String)> {
    let found = found?;
    if found.is_entry_root() {
        let spec = found.remote.git_url.clone();
        let leased = clone_or_update(&spec, fetch)?;
        return Ok((leased, spec));
    }
    // Pinned to the entry the path named rather than redirected to the
    // canonical key: the subdirectory is the caller's, and only this entry is
    // known to hold it.
    let (max_age, bound) = fetch.policy();
    if crate::config::remote_cache_fetch_due(&found.remote.cache_dir, max_age) {
        eprintln!("Updating cached repo {}...", found.remote.display);
    }
    let lease = crate::refresh_sources::update_cached_repo_bounded(&found.remote, max_age, bound)?;
    let dir = found.entry.join(&found.below);
    if !dir.is_dir() {
        anyhow::bail!(
            "source not found in cached repo {}: {} names no directory in it",
            found.remote.display,
            crate::refresh_sources::remote_source_display(&dir.to_string_lossy())
        );
    }
    let recorded = dir.to_string_lossy().into_owned();
    Ok((LeasedSourceDir { dir, lease }, recorded))
}

#[cfg(test)]
mod tests;
