use super::*;
use crate::config::remote_cache::test_support::*;
use crate::config::remote_cache::*;
use crate::config::source_repo_from_git_origin;
use std::time::Duration;

/// The TTL applies to the interactive refresh too: without it the TUI
/// re-fetched every source on every launch — twice, once per scope — and
/// an unreachable remote held a blank terminal until each deadline.
#[test]
fn a_second_refresh_within_the_ttl_issues_no_fetch() {
    with_sandboxed_cache("ttl-refresh", |cache| {
        let lock = cache.lock();
        let stamp = remote_cache_fetch_stamp(cache.dir());

        refresh_remote_caches(&lock);
        let after_first = std::fs::metadata(&stamp).unwrap().modified().unwrap();
        assert!(
            !any_remote_cache_due(&lock, Some(REMOTE_CACHE_TTL)),
            "the first refresh must satisfy the TTL"
        );

        refresh_remote_caches(&lock);
        assert_eq!(
            std::fs::metadata(&stamp).unwrap().modified().unwrap(),
            after_first,
            "a second refresh inside the TTL must not touch the cache at all"
        );

        // Control: past the TTL it does fetch again.
        std::fs::File::options()
            .write(true)
            .open(&stamp)
            .unwrap()
            .set_modified(
                std::time::SystemTime::now() - (REMOTE_CACHE_TTL + Duration::from_secs(60)),
            )
            .unwrap();
        refresh_remote_caches(&lock);
        assert_ne!(
            std::fs::metadata(&stamp).unwrap().modified().unwrap(),
            after_first
        );
    });
}

#[test]
fn a_failing_run_keeps_its_first_failure_across_retries_and_success_clears_it() {
    with_sandboxed_cache("first-failure", |cache| {
        let dir = cache.dir();
        let first = epoch_now() - 9_000;
        write_fetch_stamp(
            dir,
            FetchStamp::Failed {
                first,
                last: epoch_now() - 8_000,
                cause: Some(FetchFailure::Fetch),
            },
        )
        .unwrap();

        // A fresh failing attempt — the origin is gone, so the fetch fails
        // while the entry itself stays a perfectly good clone: the run's
        // start survives and the cause is recorded.
        cache.break_origin();
        assert!(matches!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND),
            Ok(FetchAttempt::FetchFailed(_))
        ));
        assert_eq!(
            read_fetch_stamp(dir),
            Some(FetchStamp::Failed {
                first,
                last: epoch_now(),
                cause: Some(FetchFailure::Fetch)
            }),
            "a retry must not restart the clock"
        );
        assert!(
            failing_for(dir).is_some_and(|age| age >= Duration::from_secs(8_000)),
            "age is measured from the FIRST failure"
        );

        // Control: a success clears the run entirely.
        write_fetch_stamp(dir, FetchStamp::Ok).unwrap();
        assert!(remote_cache_problem(dir).is_none());
    });
}

#[test]
fn fetch_guard_is_exclusive_and_released_when_its_holder_goes_away() {
    with_sandboxed_cache("guard", |cache| {
        let dir = cache.dir();
        let first = match RemoteCacheFetchGuard::acquire(dir) {
            GuardAcquire::Held(guard) => guard,
            _ => panic!("first acquire must win"),
        };
        assert!(
            matches!(RemoteCacheFetchGuard::acquire(dir), GuardAcquire::Busy),
            "a second acquire must be refused while the first is held"
        );
        // A caller that finds the guard held does nothing and says nothing.
        assert_eq!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND).unwrap(),
            FetchAttempt::Busy
        );
        drop(first);
        assert!(
            matches!(RemoteCacheFetchGuard::acquire(dir), GuardAcquire::Held(_)),
            "the lock must be free again once the holder drops it"
        );
    });
}

/// The guard is writer-vs-writer exclusion for a refresher and READ-vs-writer
/// exclusion for an install: the tree a held guard covers is being fetched and
/// `reset --hard`, so discovering, hashing and copying out of it installs
/// whatever bytes the reset happened to have written and records them as the
/// source's content. An installing caller therefore refuses, and — the
/// observable that matters — source resolution hands it no directory at all.
#[test]
fn an_install_refuses_a_cache_another_process_is_rewriting_while_a_refresher_stands_down() {
    with_sandboxed_cache("install-vs-refresh", |cache| {
        let dir = cache.dir();
        let holder = match RemoteCacheFetchGuard::acquire(dir) {
            GuardAcquire::Held(guard) => guard,
            _ => panic!("first acquire must win"),
        };

        // The mutating path: `add`, `refresh`, the TUI's install resolution.
        let err = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect_err("an install must not proceed into a tree being rewritten")
            .to_string();
        assert!(
            err.contains("another vstack process is using"),
            "the refusal must name the in-flight refresh: {err}"
        );

        // …and nothing downstream is handed a path to read: the source is
        // refused, so no item is discovered, hashed or copied from it.
        let records = crate::refresh_sources::resolve_source_records(&cache.lock());
        assert_eq!(
            records.sources.len(),
            0,
            "no source directory may reach the installer"
        );
        assert!(
            records
                .refused
                .reason(&cache.source)
                .is_some_and(|reason| reason.contains("another vstack process is using")),
            "the refusal must be carried, not dropped: {:?}",
            records.refused
        );

        // Control: the detached refresher wants exactly this outcome, and
        // says so without touching the tree.
        assert_eq!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND).unwrap(),
            FetchAttempt::Busy
        );
        assert!(
            read_fetch_stamp(dir).is_none(),
            "neither path may write a stamp while the guard is held elsewhere"
        );

        // Control: with the guard free, both behave exactly as before — the
        // install fetches and the refresher finds the stamp it just wrote.
        drop(holder);
        let (attempt, lease) = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect("the guard is free again");
        assert_eq!(attempt, FetchAttempt::Updated);
        assert!(
            lease.is_held(),
            "the install keeps the guard: it reads this tree next"
        );
        drop(lease);
        assert_eq!(
            refresh_remote_cache(
                &cache.remote,
                Some(REMOTE_CACHE_TTL),
                FetchBound::BACKGROUND
            )
            .unwrap(),
            FetchAttempt::Fresh
        );
    });
}

#[test]
fn a_second_caller_behind_a_fetch_sees_the_fresh_stamp_and_skips() {
    with_sandboxed_cache("re-due", |cache| {
        cache.break_origin();
        // First caller: due (no stamp), attempts, and the fetch fails.
        assert!(matches!(
            refresh_remote_cache(
                &cache.remote,
                Some(Duration::from_secs(3600)),
                FetchBound::BACKGROUND
            ),
            Ok(FetchAttempt::FetchFailed(_))
        ));
        // Second caller with the same bound: the due check re-runs inside the
        // guard, so the stamp the first caller just wrote suppresses it.
        assert_eq!(
            refresh_remote_cache(
                &cache.remote,
                Some(Duration::from_secs(3600)),
                FetchBound::BACKGROUND
            )
            .unwrap(),
            FetchAttempt::Fresh
        );
        // Control: no bound is always due.
        assert!(matches!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND),
            Ok(FetchAttempt::FetchFailed(_))
        ));
    });
}

#[cfg(unix)]
#[test]
fn an_unwritable_cache_is_reported_rather_than_discarded() {
    if is_root() {
        eprintln!("skipping: root ignores the permission bits this test sets");
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    with_sandboxed_cache("unwritable", |cache| {
        let dir = cache.dir();
        let git = dir.join(".git");
        std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o500)).unwrap();
        let attempt = refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND);
        // The READ path must see it too: no stamp can exist, so a cache that
        // can never refresh would otherwise be invisible forever.
        let read_path = cache_unwritable_reason(dir);
        std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(attempt, Ok(FetchAttempt::Unwritable(_))),
            "a .git that cannot be written must surface, not read as clean: {attempt:?}"
        );
        assert!(
            read_path.is_some(),
            "the read path must be able to see an unwritable cache"
        );
        assert!(
            cache_unwritable_reason(dir).is_none(),
            "control: a writable cache reports nothing"
        );
    });
}

#[test]
fn refresh_skips_fresh_stamp_and_reports_a_failed_attempt_when_due() {
    with_sandboxed_cache("wiring-home", |cache| {
        let dir = cache.dir();
        let lock = cache.lock();
        // The origin is gone, so any attempt that actually runs fails and is
        // observable as a `failed` stamp.
        cache.break_origin();

        // Fresh ok stamp + TTL: nothing may be attempted.
        write_fetch_stamp(dir, FetchStamp::Ok).unwrap();
        assert!(
            refresh_remote_caches_older_than(
                &lock,
                Some(Duration::from_secs(3600)),
                FetchBound::BACKGROUND,
            )
            .is_empty(),
            "a fresh stamp must suppress the fetch and report nothing"
        );
        assert_eq!(read_fetch_stamp(dir), Some(FetchStamp::Ok));
        assert!(!any_remote_cache_due(
            &lock,
            Some(Duration::from_secs(3600))
        ));

        // Zero TTL: due, attempted, and the attempt fails — reported for
        // check to surface.
        assert!(any_remote_cache_due(&lock, Some(Duration::ZERO)));
        let problems =
            refresh_remote_caches_older_than(&lock, Some(Duration::ZERO), FetchBound::BACKGROUND);
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert_eq!(problems[0].source, cache.source);
        assert!(
            matches!(problems[0].kind, RemoteCacheProblemKind::Failing { .. }),
            "{problems:?}"
        );
        assert!(
            !problems[0].kind.is_persistent(),
            "a first failure is not yet drift"
        );
        // The same state, read without touching the network at all.
        assert_eq!(recorded_remote_cache_problems(&lock), problems);
    });
}

/// A cache directory whose `.git` is not a real repository must fail as a
/// broken cache, never resolve to whatever repository ENCLOSES it. Git
/// discovery walks up out of a broken entry, `fetch origin` then succeeds
/// against the ENCLOSING repository's remote, and `reset --hard` rewrites
/// that working tree — which is exactly how this test came to exist. The
/// ownership proof is what refuses it: the entry's work tree must resolve to
/// the entry.
#[test]
fn a_broken_cache_inside_a_repository_never_touches_the_enclosing_repository() {
    let root = cache_root("no-escape");
    std::fs::create_dir_all(&root).unwrap();
    // A real remote, so a fetch from the enclosing repository WOULD succeed —
    // without that, an escape would stop at the failed fetch and this test
    // would pass for the wrong reason.
    let remote_repo = root.join("origin.git");
    std::fs::create_dir_all(&remote_repo).unwrap();
    git(&remote_repo, &["init", "-q", "--bare", "-b", "main"]);
    let work = root.join("work");
    init_git_repo(&work);
    let tracked = work.join("keep-me.txt");
    std::fs::write(&tracked, "pushed\n").unwrap();
    git(&work, &["add", "-A"]);
    git(&work, &["commit", "-qm", "first"]);
    git(
        &work,
        &["remote", "add", "origin", remote_repo.to_str().unwrap()],
    );
    git(&work, &["push", "-q", "-u", "origin", "main"]);
    git(&work, &["remote", "set-head", "origin", "-a"]);
    // Local work the enclosing repository has NOT pushed: a stray reset to
    // the remote's HEAD would destroy exactly this.
    std::fs::write(&tracked, "uncommitted local work\n").unwrap();
    let index = work.join(".git").join("index");
    let index_before = std::fs::read(&index).unwrap();

    // The cache root itself lives INSIDE that repository, so the cache is
    // both a legitimate mutation target and nested in a victim.
    let home = work.join("home");
    let config = home.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&home, &config, || {
        let source = RemoteSource::parse("owner/repo").unwrap().unwrap();
        write_fake_clone(&source.cache_dir, "https://github.com/owner/repo.git");

        let err = refresh_remote_cache(&source, None, FetchBound::BACKGROUND)
            .expect_err("a broken cache must be refused, not fetched")
            .to_string();
        assert!(
            err.contains("refusing cached source"),
            "the refusal must name itself: {err}"
        );
        assert_eq!(
            std::fs::read_to_string(&tracked).unwrap(),
            "uncommitted local work\n",
            "the enclosing repository's working tree must be untouched"
        );
        assert_eq!(
            std::fs::read(&index).unwrap(),
            index_before,
            "the enclosing repository's index must be untouched"
        );
        assert!(
            !source
                .cache_dir
                .join(".git")
                .join("vstack-fetch.lock")
                .exists(),
            "the refusal must precede every write, the lock included"
        );
        // The identity lookup must not borrow the enclosing repository's
        // origin either: that value is stamped into the lock as the source's
        // repository and routes issue reports.
        assert_eq!(
            source_repo_from_git_origin(&source.cache_dir),
            None,
            "a broken cache has no identity to borrow from its enclosure"
        );
    });
    let _ = std::fs::remove_dir_all(&root);
}

/// Containment is structural, not caller discipline: nothing but a parsed
/// [`RemoteSource`] can name what a fetch mutates, and every entry it names
/// is a DIRECT child of the cache root. A lock string that is a local path is
/// not a remote source at all, so no cache directory exists for it to reach.
#[test]
fn a_directory_outside_the_cache_root_is_never_fetched_or_reset() {
    let root = cache_root("containment");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // Everything a lock can name that is NOT a remote source: a project
        // root, an absolute local source, a relative one, a bare name, and a
        // nested path.
        for source in [
            root.to_string_lossy().into_owned(),
            root.join("project").to_string_lossy().into_owned(),
            ".".to_string(),
            "./sources/vstack".to_string(),
            "../vstack".to_string(),
            "source".to_string(),
            "owner/repo/nested".to_string(),
        ] {
            assert_eq!(
                RemoteSource::parse(&source).unwrap(),
                None,
                "{source} must not name a cache entry at all"
            );
        }
        // …and a real remote's entry is always a direct child of the root.
        for source in [
            "owner/repo",
            "https://github.com/owner/repo.git",
            "git@example.com:group/sub/repo.git",
            "ssh://git@example.com:2222/group/repo",
        ] {
            let remote = RemoteSource::parse(source).unwrap().expect("remote-shaped");
            assert_eq!(
                remote.cache_dir.parent(),
                Some(crate::refresh_sources::remote_cache_root().as_path()),
                "{source} must key a direct child of the cache root"
            );
            assert_eq!(
                remote.cache_dir.file_name().map(|n| n.to_string_lossy()),
                Some(remote.cache_key.as_str().into()),
                "{source}: the entry is named by its key and nothing else"
            );
        }
    });
    let _ = std::fs::remove_dir_all(&root);
}

/// A symlink placed at a cache key (or at a cache's `.git`) points the
/// fetch+reset at a tree OUTSIDE the root while every path string still
/// looks contained — against another clone of the same origin, `reset
/// --hard` would destroy that working tree's local changes.
#[cfg(unix)]
#[test]
fn a_symlinked_cache_directory_or_git_dir_is_refused_before_any_mutation() {
    let root = cache_root("symlink-containment");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // An external clone of the SAME origin, with local changes.
        let external = root.join("external-clone");
        write_fake_clone(&external, "https://github.com/owner/repo.git");
        std::fs::write(external.join("precious.txt"), "uncommitted work\n").unwrap();

        // Symlink at the cache key itself.
        let remote = RemoteSource::parse("owner/repo").unwrap().unwrap();
        let cache = remote.cache_dir.clone();
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&external, &cache).unwrap();
        let err = refresh_remote_cache(&remote, None, FetchBound::BACKGROUND)
            .expect_err("a symlinked cache dir must be refused")
            .to_string();
        assert!(err.contains("symlink"), "{err}");
        assert!(
            !external.join(".git").join("vstack-fetch.lock").exists(),
            "refusal must precede any write into the target"
        );
        assert_eq!(
            std::fs::read_to_string(external.join("precious.txt")).unwrap(),
            "uncommitted work\n"
        );
        std::fs::remove_file(&cache).unwrap();

        // Real directory whose `.git` is the symlink.
        std::fs::create_dir_all(&cache).unwrap();
        std::os::unix::fs::symlink(external.join(".git"), cache.join(".git")).unwrap();
        assert!(
            refresh_remote_cache(&remote, None, FetchBound::BACKGROUND).is_err(),
            "a symlinked .git must be refused"
        );
        assert!(!external.join(".git").join("vstack-fetch.lock").exists());
    });
    let _ = std::fs::remove_dir_all(&root);
}

/// The lease is the whole fix: the guard the fetch takes LEAVES with the
/// caller, so the tree stays exclusive for the read that follows — discovery,
/// hashing, copying — and not merely for the fetch. Against a fetch that
/// released its guard on the way out, the cache is free the moment the fetch
/// returns and a second install may `reset --hard` it mid-read, which records
/// lock hashes for a tree that never existed as a whole.
#[test]
fn an_install_holds_the_cache_for_the_whole_read_not_just_the_fetch() {
    with_sandboxed_cache("install-lease", |cache| {
        let dir = cache.dir();
        let (attempt, lease) = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect("a free cache installs");
        assert_eq!(attempt, FetchAttempt::Updated);

        // What another vstack process sees for as long as the install reads.
        assert!(
            matches!(RemoteCacheFetchGuard::acquire(dir), GuardAcquire::Busy),
            "the cache must still be held after the fetch returns — the read has not even started"
        );
        assert!(lease.is_held());

        // A new upstream revision cannot land underneath that read.
        let being_read = std::fs::read(dir.join("README.md")).unwrap();
        std::fs::write(cache.origin.join("README.md"), "rewritten\n").unwrap();
        git(&cache.origin, &["commit", "-qam", "second"]);
        assert_eq!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND).unwrap(),
            FetchAttempt::Busy,
            "a refresher stands down rather than resetting a tree being read"
        );
        assert_eq!(
            std::fs::read(dir.join("README.md")).unwrap(),
            being_read,
            "the bytes the install hashed are the bytes it copies"
        );

        // The read ends where the lease drops, and the cache moves on again.
        drop(lease);
        assert!(matches!(
            RemoteCacheFetchGuard::acquire(dir),
            GuardAcquire::Held(_)
        ));
        assert_eq!(
            refresh_remote_cache(&cache.remote, None, FetchBound::BACKGROUND).unwrap(),
            FetchAttempt::Updated
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("README.md")).unwrap(),
            "rewritten\n"
        );
    });
}

/// The lease has to reach the phase that reads. `resolve_source_records` is
/// where `refresh` gets its source directories from, so the record it hands
/// back carries the lease, and the cache stays held for exactly as long as the
/// caller keeps that record.
#[test]
fn resolved_source_records_carry_the_lease_their_reader_depends_on() {
    with_sandboxed_cache("records-lease", |cache| {
        let records = crate::refresh_sources::resolve_source_records(&cache.lock());
        assert_eq!(records.sources.len(), 1, "the fixture resolves one source");
        assert_eq!(records.sources[0].root, cache.dir());
        assert!(
            matches!(
                RemoteCacheFetchGuard::acquire(cache.dir()),
                GuardAcquire::Busy
            ),
            "the records hold the cache while the refresh reads them"
        );

        drop(records);
        assert!(
            matches!(
                RemoteCacheFetchGuard::acquire(cache.dir()),
                GuardAcquire::Held(_)
            ),
            "and release it when the refresh is done with them"
        );
    });
}

/// One process may resolve one remote twice — two lock entries can spell it
/// two ways — and `flock` is per open file description, so a naive second
/// acquire would contend with this process's own read, wait out
/// [`INSTALL_GUARD_WAIT`] and then refuse the install. The lease is shared
/// instead, and nothing fetches while a reader holds it.
#[test]
fn a_second_resolution_in_one_process_shares_the_lease_rather_than_refusing() {
    with_sandboxed_cache("self-contention", |cache| {
        let dir = cache.dir();
        let (_, first) = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect("a free cache installs");
        let being_read = std::fs::read(dir.join("README.md")).unwrap();
        std::fs::write(cache.origin.join("README.md"), "rewritten\n").unwrap();
        git(&cache.origin, &["commit", "-qam", "second"]);

        let (attempt, second) = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect("a process must not refuse its own lease");
        assert_eq!(
            attempt,
            FetchAttempt::Fresh,
            "a cache this process is already reading is not one to fetch and reset"
        );
        assert_eq!(std::fs::read(dir.join("README.md")).unwrap(), being_read);

        // Refcounted: the shared lease outlives whichever holder drops first.
        drop(first);
        assert!(
            matches!(RemoteCacheFetchGuard::acquire(dir), GuardAcquire::Busy),
            "the second reader still holds it"
        );
        drop(second);
        assert!(matches!(
            RemoteCacheFetchGuard::acquire(dir),
            GuardAcquire::Held(_)
        ));
    });
}

/// The read-only probe as its callers use it: `true` only while somebody ELSE
/// holds the cache.
///
/// A caller that already leased this cache is the reason the registry is
/// consulted first. `flock` is per open file description, so a bare probe
/// answers "busy" to an install asking about the tree it is itself holding —
/// and every read-only question that install asks on the way (which hooks the
/// other sources ship, which repository each entry came from) would then be
/// answered "not this run" against its own lease.
#[test]
fn the_probe_reports_another_holder_and_never_a_readers_own_lease() {
    with_sandboxed_cache("busy-probe", |cache| {
        let dir = cache.dir();
        assert!(
            !remote_cache_fetch_in_flight(dir),
            "an uncontended cache is not busy"
        );

        let (_, lease) = lease_remote_cache(&cache.remote, None, FetchBound::Unbounded)
            .expect("a free cache installs");
        assert!(
            !remote_cache_fetch_in_flight(dir),
            "a cache this process holds a lease on is nobody else's to rewrite"
        );
        // The read-only resolution agrees, and hands back the directory.
        assert_eq!(
            crate::refresh_sources::source_path_resolution(&cache.source),
            crate::refresh_sources::SourceResolution::Resolved(dir.to_path_buf())
        );
        drop(lease);

        // A guard held with no lease behind it is exactly what another
        // process's fetch looks like from here.
        let guard = match RemoteCacheFetchGuard::acquire(dir) {
            GuardAcquire::Held(guard) => guard,
            _ => panic!("the fixture cache must be free"),
        };
        assert!(remote_cache_fetch_in_flight(dir));
        assert_eq!(
            crate::refresh_sources::source_path_resolution(&cache.source),
            crate::refresh_sources::SourceResolution::Busy,
            "a read-only resolution reports the contention instead of reading through it"
        );
        drop(guard);
        assert!(!remote_cache_fetch_in_flight(dir));
    });
}
