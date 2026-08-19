//! What a completed refresh writes back into a lock entry about its SOURCE:
//! the durable repository identity it was refreshed from, and the migration
//! of a source recorded as a path into vstack's own cache onto the remote that
//! entry clones.
//!
//! Both run before the caller recomputes `source_hash`, so the hash is taken
//! against the source the entry now records.

use super::*;

fn observed_source_repo_for_lock_entry(
    source_records: &[ResolvedSource],
    entry: &config::LockEntry,
) -> Option<Option<String>> {
    if let Some(record) = source_records.iter().find(|source| {
        source.aliases.iter().any(|alias| alias == &entry.source)
            || (Path::new(&entry.source).is_absolute()
                && same_path(&source.root, Path::new(&entry.source)))
    }) {
        return Some(record.source_repo.clone());
    }
    if let Some(source_root) = config::resolve_source_path(&entry.source) {
        return Some(config::source_repo_for_source(
            Some(&source_root),
            &entry.source,
        ));
    }
    config::parse_github_slug(&entry.source).map(Some)
}

/// Record the durable repo identity of the source `entry` was just refreshed
/// from — its own source, never whichever source a caller happened to have
/// selected — and migrate a source recorded as a path into vstack's own cache
/// onto the remote that cache entry clones.
///
/// The migration runs here, before the caller recomputes `source_hash`, so the
/// hash is taken against the source the entry now records. It is what carries
/// an already-installed consumer across without a manual re-add: the entry
/// keeps resolving and fetching either way, and once the lock names the remote
/// every reader reaches it through the ordinary remote path.
pub(crate) fn sync_lock_entry_source(
    source_records: &[ResolvedSource],
    entry: &mut config::LockEntry,
) {
    if let Some(source_repo) = observed_source_repo_for_lock_entry(source_records, entry) {
        entry.source_repo = source_repo;
    }
    if let Some(spec) = crate::refresh_sources::migrated_cache_entry_source(&entry.source) {
        entry.source = spec;
    }
}

#[cfg(test)]
mod tests;
