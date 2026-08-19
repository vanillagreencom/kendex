//! What [`super`] writes back into a lock entry's source fields, and what it
//! deliberately leaves alone.

use super::*;
use crate::commands::refresh::tests::{lock_entry, make_source, tmpdir};
use crate::config::ItemKind;
use std::path::Path;

#[test]
fn source_repo_for_lock_entry_uses_resolved_source_record_identity() {
    let root = tmpdir("refresh-source-repo");
    let source = root.join("source");
    std::fs::create_dir_all(&source).unwrap();
    let entry = lock_entry(
        "rust",
        ItemKind::Agent,
        Path::new("/moved/source"),
        vec!["codex"],
    );
    let records = vec![crate::refresh_sources::ResolvedSource::for_test(
        source,
        "/moved/source",
        Some("vanillagreencom/vstack"),
    )];

    assert_eq!(
        observed_source_repo_for_lock_entry(&records, &entry)
            .flatten()
            .as_deref(),
        Some("vanillagreencom/vstack")
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_clears_stale_identity_for_resolved_local_source_without_origin() {
    let root = tmpdir("refresh-source-repo-clear-stale");
    let source = make_source(&root, "local-source");
    let mut entry = lock_entry("rust", ItemKind::Agent, &source, vec!["codex"]);
    entry.source_repo = Some("vanillagreencom/vstack".to_string());

    sync_lock_entry_source(&[], &mut entry);

    assert_eq!(entry.source_repo, None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_clears_stale_identity_for_resolved_record_without_identity() {
    let root = tmpdir("refresh-source-repo-clear-record");
    let source = make_source(&root, "local-source");
    let mut entry = lock_entry(
        "rust",
        ItemKind::Agent,
        Path::new("/moved/source"),
        vec!["codex"],
    );
    entry.source_repo = Some("vanillagreencom/vstack".to_string());
    let records = vec![crate::refresh_sources::ResolvedSource::for_test(
        source,
        "/moved/source",
        None,
    )];

    sync_lock_entry_source(&records, &mut entry);

    assert_eq!(entry.source_repo, None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_preserves_identity_when_source_unavailable() {
    let root = tmpdir("refresh-source-repo-preserve-moved");
    let source = root.join("moved-source");
    let mut entry = lock_entry("rust", ItemKind::Agent, &source, vec!["codex"]);
    entry.source_repo = Some("vanillagreencom/vstack".to_string());

    sync_lock_entry_source(&[], &mut entry);

    assert_eq!(entry.source_repo.as_deref(), Some("vanillagreencom/vstack"));
}

/// The migration a refresh performs in the same pass that repairs
/// `source_repo`: an entry whose source is a path into vstack's own cache is
/// rewritten to the remote that entry clones, so an already-installed consumer
/// crosses over without a manual re-add.
///
/// It runs BEFORE the caller recomputes `source_hash`, so the hash is taken
/// against the source the entry now records.
#[test]
fn sync_lock_entry_source_rewrites_a_cache_entry_path_to_its_remote_spec() {
    let root = tmpdir("refresh-source-cache-migration");
    let home = root.join("home");
    let origin = root.join("origin");
    crate::refresh_sources::tests::init_git_repo(&origin);
    let origin_url = format!("file://{}", origin.display());

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache_root = crate::refresh_sources::remote_cache_root();
        let legacy = cache_root.join("legacy_key");
        crate::refresh_sources::tests::clone_into(&origin, &legacy);
        let canonical = crate::refresh_sources::RemoteSource::parse(&origin_url)
            .unwrap()
            .unwrap();
        crate::refresh_sources::tests::clone_into(&origin, &canonical.cache_dir);

        let mut entry = lock_entry("rust", ItemKind::Agent, &legacy, vec!["codex"]);
        sync_lock_entry_source(&[], &mut entry);
        assert_eq!(entry.source, origin_url);

        // Control: a source that is not a cache entry keeps whatever it
        // recorded — the rewrite is keyed on the cache root, not on being a
        // path.
        let outside = make_source(&root, "local-source");
        let mut entry = lock_entry("rust", ItemKind::Agent, &outside, vec!["codex"]);
        sync_lock_entry_source(&[], &mut entry);
        assert_eq!(entry.source, outside.to_string_lossy());
    });
    let _ = std::fs::remove_dir_all(root);
}
