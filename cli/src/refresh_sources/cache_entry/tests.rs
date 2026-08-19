//! Sources recorded as a path into vstack's own cache: that they resolve as
//! the remote their entry clones, that an entry whose remote cannot be
//! established fails closed, and that `refresh` migrates the recorded source
//! onto the remote spec.

use super::*;
use crate::config;
use crate::refresh_sources::records::tests::{lock_entry, make_vstack_source};
use crate::refresh_sources::tests::{clone_into, file_url, git, init_git_repo, tmpdir};
use crate::refresh_sources::{SourceResolution, resolve_source_records, source_path_resolution};
use std::path::PathBuf;

/// Clone `origin` into `entry` under the sandbox's cache root and return the
/// lock-source string a `vstack add <cache-dir>` writes for it.
fn cache_entry_source(origin: &Path, entry: &str) -> String {
    let dir = remote_cache_root().join(entry);
    clone_into(origin, &dir);
    dir.to_string_lossy().into_owned()
}

fn lock_of(source: &str) -> config::LockFile {
    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", source));
    lock
}

/// The defect: an entry whose recorded source is a directory inside
/// `~/.vstack/cache` was resolved as an ordinary local checkout, so nothing
/// ever fetched it — `refresh` copied stale bytes and `check` called them
/// clean. It must resolve as the remote its cache entry clones instead, which
/// puts it back in the fetch AND in the list every TTL and staleness reader
/// walks.
///
/// The entry is deliberately keyed `legacy_key`, which is NOT the key its URL
/// hashes to: a real machine holds `vanillagreencom_vstack` beside
/// `vanillagreencom_vstack-ff0070a84862081c` for one repository, so a fix that
/// recovered the remote by parsing the directory name would pass here and fail
/// there.
#[test]
fn cache_entry_path_source_resolves_and_fetches_as_its_remote() {
    let root = tmpdir("cache-path-source");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);
    // A plain local checkout OUTSIDE the cache: the must-fail control for the
    // containment test. It is absolute and it is a vstack-shaped directory, so
    // only its location keeps it on the local branch.
    let local = make_vstack_source(&root, "local-checkout");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = cache_entry_source(&origin, "legacy_key");
        let cache = PathBuf::from(&source);
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "advance"]);

        // The fixture is genuinely behind before anything fetches it —
        // otherwise the assertion below passes on a clone that was never
        // stale.
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "upstream\n"
        );

        let lock = lock_of(&source);

        // `vstack cache-refresh` and `check`'s dueness probe both walk this
        // list; the entry was missing from it entirely.
        let listed = config::cached_remote_sources(&lock);
        assert_eq!(listed.len(), 1, "the cache-root source must be listed");
        assert_eq!(listed[0].0, source);
        assert_eq!(
            listed[0].1.cache_dir, cache,
            "the remote must stay pinned to the entry the lock named, not to \
             whichever key its URL hashes to"
        );
        assert_eq!(listed[0].1.git_url, file_url(&origin));
        assert!(config::any_remote_cache_due(&lock, None));

        // The `refresh` path itself: resolution fetches, and hands back the
        // same directory holding the updated tree.
        let records = resolve_source_records(&lock);
        assert!(records.refused.reason(&source).is_none());
        assert_eq!(records.sources.len(), 1);
        assert!(same_path(&records.sources[0].root, &cache));
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "newer\n",
            "resolving a cache-root source must fetch it"
        );

        // Control: an absolute local directory outside the cache root is still
        // a local directory — no git process, no remote, no fetch.
        let local_source = local.to_string_lossy().into_owned();
        let local_lock = lock_of(&local_source);
        assert!(
            config::cached_remote_sources(&local_lock).is_empty(),
            "a local checkout must never be listed as a remote cache"
        );
        assert_eq!(
            source_path_resolution(&local_source),
            SourceResolution::Resolved(local.clone())
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// Fail closed. A cache entry whose origin names no remote vstack can fetch
/// cannot be kept fresh, and the bytes sitting in it are not evidence that the
/// install matches its source — so resolution REFUSES it, which is what `check`
/// renders as unverifiable and what keeps it out of the clean count.
#[test]
fn cache_entry_path_source_whose_remote_cannot_be_established_is_refused() {
    let root = tmpdir("cache-path-unmappable");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = cache_entry_source(&origin, "legacy_key");
        let cache = PathBuf::from(&source);

        // An origin that is a bare local path: remote-shaped it is not, so
        // there is no URL to fetch from.
        git(
            &cache,
            &["remote", "set-url", "origin", origin.to_str().unwrap()],
        );
        let refusal = source_path_resolution(&source);
        let SourceResolution::Refused(reason) = &refusal else {
            panic!("expected a refusal, got {refusal:?}");
        };
        assert!(reason.contains(&source), "must name the file: {reason}");
        assert!(
            reason.contains("is not a remote vstack can fetch"),
            "must give the reason: {reason}"
        );
        assert!(
            config::cached_remote_sources(&lock_of(&source)).is_empty(),
            "an unmappable entry has no remote to refresh"
        );

        // An origin git cannot report at all fails the same way.
        git(&cache, &["remote", "remove", "origin"]);
        let refusal = source_path_resolution(&source);
        let SourceResolution::Refused(reason) = &refusal else {
            panic!("expected a refusal, got {refusal:?}");
        };
        assert!(
            reason.contains("origin could not be read"),
            "must give the reason: {reason}"
        );

        // Control: the same entry, with the origin a real clone records,
        // resolves. Without this the refusals above could come from the
        // fixture rather than from the origin under test.
        git(&cache, &["remote", "add", "origin", &file_url(&origin)]);
        assert_eq!(
            source_path_resolution(&source),
            SourceResolution::Resolved(cache)
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A cache entry that is simply not there is ABSENT, not refused: nothing is
/// broken, `vstack add` puts it back, and the two states are repaired
/// differently.
#[test]
fn missing_cache_entry_path_source_is_absent_not_refused() {
    let root = tmpdir("cache-path-absent");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = remote_cache_root()
            .join("never_cloned")
            .to_string_lossy()
            .into_owned();
        assert_eq!(source_path_resolution(&source), SourceResolution::Absent);
    });
    let _ = std::fs::remove_dir_all(root);
}

/// Only a direct child of the cache root is a cache entry. Everything else
/// that merely lives near one — the root itself, a grandchild, a sibling whose
/// name starts with `cache` — stays on the local-directory branch it has
/// always taken.
#[test]
fn only_direct_children_of_the_cache_root_are_cache_entries() {
    let root = tmpdir("cache-path-boundary");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache_root = remote_cache_root();
        assert!(is_remote_cache_entry_path(&cache_root.join("owner_repo")));
        assert!(!is_remote_cache_entry_path(&cache_root));
        assert!(!is_remote_cache_entry_path(
            &cache_root.join("owner_repo").join("skills")
        ));
        assert!(!is_remote_cache_entry_path(
            &cache_root.parent().unwrap().join("cache-sibling")
        ));
        assert!(!is_remote_cache_entry_path(Path::new("owner_repo")));
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The migration `refresh` performs: a source recorded as a cache-entry path
/// becomes the remote spec, so every later reader reaches it through the
/// ordinary remote path — but only once vstack's own entry for that remote
/// exists, because a lock naming a remote with no clone on this machine
/// resolves to nothing, and only once that entry has been brought to the
/// revision the caller is about to hash it at.
#[test]
fn cache_entry_path_source_migrates_to_its_remote_spec_once_the_canonical_entry_is_current() {
    let root = tmpdir("cache-path-migrate");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let local = make_vstack_source(&root, "local-checkout");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = cache_entry_source(&origin, "legacy_key");
        let canonical = RemoteSource::parse(&file_url(&origin)).unwrap().unwrap();
        assert_ne!(canonical.cache_dir, PathBuf::from(&source));

        assert_eq!(
            migrated_cache_entry_source(&source),
            None,
            "no rewrite while the remote has no clone to resolve to"
        );

        // The canonical entry exists but is BEHIND the revision the recorded
        // path resolves to. Rewriting without fetching it would hand the
        // caller a source whose tree the install never came from.
        clone_into(&origin, &canonical.cache_dir);
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "advance"]);
        assert_eq!(
            std::fs::read_to_string(canonical.cache_dir.join("README.md")).unwrap(),
            "upstream\n",
            "the canonical entry must start behind, or the fetch below proves nothing"
        );

        assert_eq!(
            migrated_cache_entry_source(&source),
            Some(file_url(&origin))
        );
        assert_eq!(
            std::fs::read_to_string(canonical.cache_dir.join("README.md")).unwrap(),
            "newer\n",
            "the entry the rewritten source names must be current"
        );

        // Controls: neither a local checkout nor an already-remote source is
        // a cache-entry path, so neither is rewritten.
        assert_eq!(migrated_cache_entry_source(&local.to_string_lossy()), None);
        assert_eq!(migrated_cache_entry_source(&file_url(&origin)), None);
    });
    let _ = std::fs::remove_dir_all(root);
}
