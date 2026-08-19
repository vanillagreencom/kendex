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
        let listed = config::cached_remote_sources(&lock).present;
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
            config::cached_remote_sources(&local_lock)
                .present
                .is_empty(),
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
        // It is not something `cache-refresh` can fetch, and it is not
        // something `cache-refresh` may pass over in silence either.
        let listed = config::cached_remote_sources(&lock_of(&source));
        assert!(listed.present.is_empty(), "there is no remote to refresh");
        assert_eq!(listed.refused.len(), 1, "{:?}", listed.refused);
        assert_eq!(listed.refused[0].0, source);
        let problems = config::refresh_remote_caches_older_than(
            &lock_of(&source),
            None,
            config::FetchBound::BACKGROUND,
        );
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert!(
            matches!(
                &problems[0].kind,
                config::RemoteCacheProblemKind::Refused { reason }
                    if reason.contains("is not a remote vstack can fetch")
            ),
            "{problems:?}"
        );
        assert!(problems[0].kind.is_persistent(), "no rerun clears this");

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

/// Cache membership is ANCESTRY: the whole subtree belongs to the entry it
/// sits in, and the split says which entry and how far below it. A predicate
/// that matched only direct children left `<cache>/<entry>/<subdir>` on the
/// local-directory branch, reproducing the original defect verbatim.
///
/// Everything genuinely outside — the root itself, a sibling whose name merely
/// starts the same way, a relative spelling — stays where it has always been.
#[test]
fn every_path_under_the_cache_root_belongs_to_its_entry() {
    let root = tmpdir("cache-path-boundary");
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache_root = remote_cache_root();
        let entry = cache_root.join("owner_repo");
        assert_eq!(
            remote_cache_entry_for_path(&entry),
            Some((entry.clone(), PathBuf::new()))
        );
        assert_eq!(
            remote_cache_entry_for_path(&entry.join("skills")),
            Some((entry.clone(), PathBuf::from("skills")))
        );
        assert_eq!(
            remote_cache_entry_for_path(&entry.join("a").join("b")),
            Some((entry, PathBuf::from("a").join("b")))
        );
        assert_eq!(remote_cache_entry_for_path(&cache_root), None);
        assert_eq!(
            remote_cache_entry_for_path(&cache_root.parent().unwrap().join("cache-sibling")),
            None
        );
        assert_eq!(remote_cache_entry_for_path(Path::new("owner_repo")), None);
    });
    let _ = std::fs::remove_dir_all(root);
}

/// #1495's defect, one directory deeper. A source recorded as
/// `<cache>/<entry>/<subdir>` — what `vstack add <cache>/<entry>/sub` writes
/// for a repository whose catalog is nested — was read as an ordinary local
/// checkout, so nothing fetched it and every command called the stale bytes
/// clean. It resolves through its ENTRY: the entry is fetched and leased, and
/// the subdirectory is taken inside the tree that fetch left behind.
#[test]
fn a_path_below_a_cache_entry_resolves_through_that_entry() {
    let root = tmpdir("cache-path-subdir");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);
    std::fs::create_dir_all(origin.join("nested")).unwrap();
    std::fs::write(origin.join("nested").join("README.md"), "upstream\n").unwrap();
    git(&origin, &["add", "-A"]);
    git(&origin, &["commit", "-q", "-m", "nested"]);
    // The must-fail control: the same shape OUTSIDE the cache is still an
    // ordinary local directory, so only the location decides the branch.
    let outside = make_vstack_source(&root, "local-checkout");
    std::fs::create_dir_all(outside.join("nested")).unwrap();

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let entry = PathBuf::from(cache_entry_source(&origin, "legacy_key"));
        let sub = entry.join("nested");
        let source = sub.to_string_lossy().into_owned();
        std::fs::write(origin.join("nested").join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "advance"]);
        assert_eq!(
            std::fs::read_to_string(sub.join("README.md")).unwrap(),
            "upstream\n",
            "the fixture must start behind, or the fetch below proves nothing"
        );

        // `cache-refresh` and `check`'s dueness probe reach it through the
        // entry, which is the clone git actually fetches.
        let listed = config::cached_remote_sources(&lock_of(&source)).present;
        assert_eq!(listed.len(), 1, "the subdirectory source must be listed");
        assert_eq!(listed[0].1.cache_dir, entry);

        let records = resolve_source_records(&lock_of(&source));
        assert!(records.refused.reason(&source).is_none());
        assert_eq!(records.sources.len(), 1);
        assert!(same_path(&records.sources[0].root, &sub));
        assert_eq!(
            std::fs::read_to_string(sub.join("README.md")).unwrap(),
            "newer\n",
            "resolving a path below a cache entry must fetch that entry"
        );

        // A subdirectory the fetch removed is absent, not a resolved path
        // that is not a directory.
        let gone = entry.join("no-such-dir").to_string_lossy().into_owned();
        assert_eq!(source_path_resolution(&gone), SourceResolution::Absent);

        // Control: a subdirectory of a local checkout is still local.
        let local_sub = outside.join("nested");
        assert_eq!(
            source_path_resolution(&local_sub.to_string_lossy()),
            SourceResolution::Resolved(local_sub)
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The migration `refresh` performs, and the one shape it is sound for: a
/// source recorded at the entry the remote spec itself resolves to. Then
/// resolution, the fetch, the hash and the rewritten spec all name ONE
/// directory, and the lease resolution already holds covers the whole of it.
///
/// It must hold under that lease, which is the state every real refresh is in
/// — a gate that asked the cache whether it had just been fetched answered
/// `Fresh` here and refused the one migration that was free and correct.
#[test]
fn a_source_at_the_canonical_entry_migrates_to_its_remote_spec() {
    let root = tmpdir("cache-path-migrate-canonical");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let local = make_vstack_source(&root, "local-checkout");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let canonical = RemoteSource::parse(&file_url(&origin)).unwrap().unwrap();
        clone_into(&origin, &canonical.cache_dir);
        let source = canonical.cache_dir.to_string_lossy().into_owned();

        // Under the lease a refresh holds across its whole lock-write pass.
        let records = resolve_source_records(&lock_of(&source));
        assert!(same_path(&records.sources[0].root, &canonical.cache_dir));
        assert_eq!(
            migrated_cache_entry_source(&source),
            Some(file_url(&origin)),
            "the entry the spec resolves to is the entry resolution just leased"
        );
        drop(records);

        // Controls: neither a local checkout nor an already-remote source is
        // a cache path, so neither is rewritten.
        assert_eq!(migrated_cache_entry_source(&local.to_string_lossy()), None);
        assert_eq!(migrated_cache_entry_source(&file_url(&origin)), None);
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A legacy-key entry is NEVER migrated, however current the current-key entry
/// beside it is. Every key vstack mints today carries a `-<digest>` suffix, so
/// every pre-suffix entry on disk is this case — including the seventeen-entry
/// install this defect was found on.
///
/// Rewriting it would commit the lock to a directory the install did not come
/// from, and the only thing that could close that gap is a fetch of the other
/// clone run inside the lock-write loop, once per entry. The recorded path
/// costs nothing where it is: it resolves through its own entry and is fetched
/// on every refresh. `vstack add` is what moves it.
#[test]
fn a_legacy_key_source_is_never_migrated_onto_a_second_clone() {
    let root = tmpdir("cache-path-migrate-legacy");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = cache_entry_source(&origin, "legacy_key");
        let legacy = PathBuf::from(&source);
        let canonical = RemoteSource::parse(&file_url(&origin)).unwrap().unwrap();
        assert_ne!(
            canonical.cache_dir, legacy,
            "the fixture must be two clones"
        );

        assert_eq!(
            migrated_cache_entry_source(&source),
            None,
            "no rewrite while the remote has no clone of its own"
        );

        // Present AND at the same revision changes nothing: the objection is
        // that it is a different DIRECTORY, not that it is behind.
        clone_into(&origin, &canonical.cache_dir);
        assert_eq!(migrated_cache_entry_source(&source), None);

        // And the entry keeps working: it resolves through its own path and
        // is fetched, which is what makes leaving it alone free.
        std::fs::write(origin.join("README.md"), "newer\n").unwrap();
        git(&origin, &["commit", "-q", "-am", "advance"]);
        let records = resolve_source_records(&lock_of(&source));
        assert!(same_path(&records.sources[0].root, &legacy));
        assert_eq!(
            std::fs::read_to_string(legacy.join("README.md")).unwrap(),
            "newer\n"
        );
        drop(records);

        // The recorded source and the hashed tree stay the same directory, so
        // no refresh can report an outcome the install did not have.
        let mut entry = lock_entry("demo", &source);
        entry.source_hash = "recorded".into();
        crate::commands::refresh::sync_lock_entry_source(&[], &mut entry);
        assert_eq!(entry.source, source);
        assert_eq!(entry.source_hash, "recorded");
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A clone that is genuinely there but cannot be READ is reported as exactly
/// that. `Path::exists` answers false for a permission error the same way it
/// does for a missing file, so a valid clone whose directory went unreadable
/// fell to the not-a-clone arm — which still passes, because `is_dir` only
/// needs the parent readable — and was refused with a definite cause nothing
/// had established, plus advice to DELETE it.
#[test]
fn an_unreadable_cache_entry_is_not_reported_as_missing_its_git() {
    // Root ignores the mode bits, so the state under test cannot be built.
    // SAFETY: `geteuid` reads the calling process's effective uid; it takes no
    // arguments, touches no memory, and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let root = tmpdir("cache-path-unreadable");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let source = cache_entry_source(&origin, "legacy_key");
        let entry = PathBuf::from(&source);
        // Control: readable, this fixture resolves — so the refusal below is
        // the permissions' doing and not the fixture's.
        assert_eq!(
            source_path_resolution(&source),
            SourceResolution::Resolved(entry.clone())
        );

        let mut perms = std::fs::metadata(&entry).unwrap().permissions();
        let restore = perms.clone();
        std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o000);
        std::fs::set_permissions(&entry, perms).unwrap();

        let refusal = source_path_resolution(&source);
        std::fs::set_permissions(&entry, restore).unwrap();

        let SourceResolution::Refused(reason) = &refusal else {
            panic!("expected a refusal, got {refusal:?}");
        };
        assert!(reason.contains(&source), "must name the entry: {reason}");
        assert!(
            reason.contains("could not be read"),
            "must report the read it could not complete: {reason}"
        );
        assert!(
            !reason.contains("is not one of its clones"),
            "must not claim a cause nothing established: {reason}"
        );
        assert!(
            !reason.contains("Remove it from"),
            "must not advise deleting a clone it could not look at: {reason}"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The same clone, the same permission bit, spelled two ways in the lock. Both
/// spellings ask "is this entry present?" and the answer must not depend on
/// which one the lock happens to carry: fixing the probe for the path spelling
/// and leaving the URL spelling on `Path::exists` reported an unreadable clone
/// as absent, with a cause that is false and a remedy that deletes it.
#[test]
fn an_unreadable_entry_reads_the_same_for_both_spellings_of_its_source() {
    // Root ignores the mode bits, so the state under test cannot be built.
    // SAFETY: `geteuid` reads the calling process's effective uid; it takes no
    // arguments, touches no memory, and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let root = tmpdir("cache-path-unreadable-both");
    let home = root.join("home");
    let origin = root.join("origin");
    init_git_repo(&origin);

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let url = file_url(&origin);
        let canonical = RemoteSource::parse(&url).unwrap().unwrap();
        clone_into(&origin, &canonical.cache_dir);
        let as_path = canonical.cache_dir.to_string_lossy().into_owned();

        // Control: readable, both spellings resolve to the same tree.
        for source in [&url, &as_path] {
            assert_eq!(
                source_path_resolution(source),
                SourceResolution::Resolved(canonical.cache_dir.clone()),
                "{source}"
            );
        }

        let mut perms = std::fs::metadata(&canonical.cache_dir)
            .unwrap()
            .permissions();
        let restore = perms.clone();
        std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o000);
        std::fs::set_permissions(&canonical.cache_dir, perms).unwrap();

        let answers: Vec<SourceResolution> = [&url, &as_path]
            .iter()
            .map(|source| source_path_resolution(source))
            .collect();
        let listed = config::cached_remote_sources(&lock_of(&url));
        std::fs::set_permissions(&canonical.cache_dir, restore).unwrap();

        for (source, answer) in [&url, &as_path].iter().zip(&answers) {
            let SourceResolution::Refused(reason) = answer else {
                panic!("{source}: expected a refusal, got {answer:?}");
            };
            assert!(
                reason.contains("could not be read"),
                "{source}: must report the read it could not complete: {reason}"
            );
            assert!(
                !reason.contains("not present"),
                "{source}: a clone that is right there is not absent: {reason}"
            );
            assert!(
                !reason.contains("Remove"),
                "{source}: must not advise deleting a clone it could not look at: {reason}"
            );
        }
        // And the enumeration every refresher walks carries it too, rather
        // than dropping the entry as if it had nothing to fetch.
        assert!(listed.present.is_empty(), "{:?}", listed.present);
        assert_eq!(listed.refused.len(), 1, "{:?}", listed.refused);
    });
    let _ = std::fs::remove_dir_all(root);
}
