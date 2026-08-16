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
    let root = cache_root("ttl-refresh");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        let cache = remote_cache_dir("owner/repo").unwrap();
        write_fake_clone(&cache, "https://github.com/owner/repo.git");
        let lock = demo_lock("owner/repo");

        refresh_remote_caches(&lock);
        let stamp = remote_cache_fetch_stamp(&cache);
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
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_failing_run_keeps_its_first_failure_across_retries_and_success_clears_it() {
    with_sandboxed_cache("first-failure", |dir| {
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

        // A fresh failing attempt against a fake .git: the run's start survives
        // and the cause is recorded.
        assert_eq!(
            fetch_remote_cache(dir, None, FetchBound::BACKGROUND),
            FetchAttempt::Attempted(false)
        );
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
fn a_stale_lock_is_taken_over_by_exactly_one_contender() {
    let dir = cache_root("stale-lock");
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("vstack-fetch.lock");
    let owner = create_lock_file(&lock).unwrap();
    assert!(
        create_lock_file(&lock).is_err(),
        "a held lock refuses a second holder"
    );
    assert_eq!(read_lock_owner(&lock), Some(owner));

    // Fresh: never taken over, whatever a contender wants.
    assert!(!take_over_stale_lock(&lock, Duration::from_secs(3600)));
    assert!(lock.exists());

    // Old, but its recorded holder is provably DEAD: the FIRST contender
    // wins and the second finds nothing to take.
    std::fs::write(&lock, format!("{} {}\n", dead_pid(), epoch_now())).unwrap();
    backdate_lock(&lock);
    assert!(take_over_stale_lock(&lock, Duration::from_secs(60)));
    assert!(!take_over_stale_lock(&lock, Duration::from_secs(60)));
    assert!(!lock.exists(), "the stale lock is gone, not left behind");
    // And the winner can now hold it.
    create_lock_file(&lock).unwrap();
    let recorded = std::fs::read_to_string(&lock).unwrap();
    assert!(
        recorded.starts_with(&std::process::id().to_string()),
        "the lock records its owner: {recorded:?}"
    );
    assert!(STALE_LOCK_AFTER > REMOTE_CACHE_FETCH_DEADLINE);
    assert!(
        STALE_LOCK_AFTER > LOCK_HEARTBEAT * 2,
        "staleness must mean several MISSED heartbeats"
    );
    let _ = std::fs::remove_dir_all(dir);
}

/// An old mtime alone is not death: an unbounded `vstack refresh` on a
/// slow link runs as long as its user is willing to wait, and stealing
/// its live lock would put two writers in one tree.
#[test]
fn a_stale_lock_with_a_live_owner_is_never_taken_over() {
    let dir = cache_root("live-owner-lock");
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("vstack-fetch.lock");
    // Recorded holder: THIS process — alive by construction.
    create_lock_file(&lock).unwrap();
    backdate_lock(&lock);
    assert!(
        !take_over_stale_lock(&lock, Duration::from_secs(60)),
        "a provably live holder keeps its lock at any age"
    );
    assert!(lock.exists());

    // Control: an unparsable record cannot prove life, so staleness
    // decides — the pre-ownership behavior, not a frozen cache.
    std::fs::write(&lock, "not an ownership record\n").unwrap();
    backdate_lock(&lock);
    assert!(take_over_stale_lock(&lock, Duration::from_secs(60)));
    let _ = std::fs::remove_dir_all(dir);
}

/// Drop's ownership check, exercised on this platform: a guard must not
/// unlink a lock that a takeover has since re-created under a new owner.
#[test]
fn a_lock_is_unlinked_only_by_its_recorded_owner() {
    let dir = cache_root("lock-ownership");
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("vstack-fetch.lock");
    let owner = create_lock_file(&lock).unwrap();

    // A successor rewrote the lock: the original owner's unlink is a no-op.
    std::fs::write(&lock, format!("{} {}\n", dead_pid(), epoch_now())).unwrap();
    assert!(!remove_lock_if_owned(&lock, owner));
    assert!(lock.exists(), "somebody else's lock survives");

    // Still ours: the unlink happens.
    std::fs::remove_file(&lock).unwrap();
    let owner = create_lock_file(&lock).unwrap();
    assert!(remove_lock_if_owned(&lock, owner));
    assert!(!lock.exists());
    let _ = std::fs::remove_dir_all(dir);
}

/// The liveness signal takeover staleness is measured against.
#[test]
fn a_heartbeat_refreshes_the_lock_mtime() {
    let dir = cache_root("lock-heartbeat");
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("vstack-fetch.lock");
    create_lock_file(&lock).unwrap();
    backdate_lock(&lock);
    refresh_lock_liveness(&lock);
    let age = std::fs::metadata(&lock)
        .unwrap()
        .modified()
        .unwrap()
        .elapsed()
        .unwrap();
    assert!(age < Duration::from_secs(60), "mtime refreshed: {age:?}");
    let _ = std::fs::remove_dir_all(dir);
}

/// The liveness probe itself, on the platform that has one.
#[cfg(unix)]
#[test]
fn process_liveness_answers_for_live_and_dead_pids() {
    assert_eq!(process_is_alive(std::process::id()), Some(true));
    assert_eq!(process_is_alive(dead_pid()), Some(false));
}

#[test]
fn fetch_guard_is_exclusive_and_released_when_its_holder_goes_away() {
    with_sandboxed_cache("guard", |dir| {
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
            fetch_remote_cache(dir, None, FetchBound::BACKGROUND),
            FetchAttempt::Busy
        );
        drop(first);
        assert!(
            matches!(RemoteCacheFetchGuard::acquire(dir), GuardAcquire::Held(_)),
            "the lock must be free again once the holder drops it"
        );
    });
}

#[test]
fn a_second_caller_behind_a_fetch_sees_the_fresh_stamp_and_skips() {
    with_sandboxed_cache("re-due", |dir| {
        // First caller: due (no stamp), attempts, fails against a fake .git.
        assert_eq!(
            fetch_remote_cache(dir, Some(Duration::from_secs(3600)), FetchBound::BACKGROUND),
            FetchAttempt::Attempted(false)
        );
        // Second caller with the same bound: the due check re-runs inside the
        // guard, so the stamp the first caller just wrote suppresses it.
        assert_eq!(
            fetch_remote_cache(dir, Some(Duration::from_secs(3600)), FetchBound::BACKGROUND),
            FetchAttempt::Fresh
        );
        // Control: no bound is always due.
        assert_eq!(
            fetch_remote_cache(dir, None, FetchBound::BACKGROUND),
            FetchAttempt::Attempted(false)
        );
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
    with_sandboxed_cache("unwritable", |dir| {
        let git = dir.join(".git");
        std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o500)).unwrap();
        let attempt = fetch_remote_cache(dir, None, FetchBound::BACKGROUND);
        // The READ path must see it too: no stamp can exist, so a cache that
        // can never refresh would otherwise be invisible forever.
        let read_path = cache_unwritable_reason(dir);
        std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(attempt, FetchAttempt::Unwritable(_)),
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
    let root = cache_root("wiring-home");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        let cache = remote_cache_dir("owner/repo").unwrap();
        // A `.git` marker that is not a repository: any fetch attempt
        // fails fast, so an attempt is observable as a `failed` stamp.
        write_fake_clone(&cache, "https://github.com/owner/repo.git");
        let lock = demo_lock("owner/repo");

        // Fresh ok stamp + TTL: nothing may be attempted.
        write_fetch_stamp(&cache, FetchStamp::Ok).unwrap();
        assert!(
            refresh_remote_caches_older_than(
                &lock,
                Some(Duration::from_secs(3600)),
                FetchBound::BACKGROUND
            )
            .is_empty(),
            "a fresh stamp must suppress the fetch and report nothing"
        );
        assert_eq!(read_fetch_stamp(&cache), Some(FetchStamp::Ok));
        assert!(!any_remote_cache_due(
            &lock,
            Some(Duration::from_secs(3600))
        ));

        // Zero TTL: due, attempted, and the attempt fails against a fake
        // .git — reported for check to surface.
        assert!(any_remote_cache_due(&lock, Some(Duration::ZERO)));
        let problems =
            refresh_remote_caches_older_than(&lock, Some(Duration::ZERO), FetchBound::BACKGROUND);
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert_eq!(problems[0].source, "owner/repo");
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
    let _ = std::fs::remove_dir_all(root);
}

/// A cache directory whose `.git` is not a real repository must fail as a
/// broken cache, never resolve to whatever repository ENCLOSES it. Without
/// the pinned `GIT_DIR`, git discovery walks up, `fetch origin` succeeds
/// against the ENCLOSING repository's remote, and `reset --hard
/// origin/HEAD` then rewrites that working tree — which is exactly how
/// this test came to exist.
#[test]
fn a_broken_cache_inside_a_repository_never_touches_the_enclosing_repository() {
    let root = cache_root("no-escape");
    std::fs::create_dir_all(&root).unwrap();
    let git = |args: &[&str], dir: &Path| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    };
    // A real remote, so a fetch from the enclosing repository SUCCEEDS —
    // without that, an escape would stop at the failed fetch and this
    // test would pass for the wrong reason. git is required, not
    // optional: skipping here would retire the regression silently.
    let remote = root.join("origin.git");
    std::fs::create_dir_all(&remote).unwrap();
    assert!(
        git(&["init", "-q", "--bare", "-b", "main", "."], &remote),
        "git is required to run this regression test"
    );
    let work = root.join("work");
    std::fs::create_dir_all(&work).unwrap();
    assert!(git(&["init", "-q", "-b", "main", "."], &work));
    for args in [
        &["config", "user.email", "t@example.com"][..],
        &["config", "user.name", "t"][..],
    ] {
        assert!(git(args, &work));
    }
    let tracked = work.join("keep-me.txt");
    std::fs::write(&tracked, "pushed\n").unwrap();
    assert!(git(&["add", "-A"], &work));
    assert!(git(&["commit", "-qm", "first"], &work));
    assert!(git(
        &["remote", "add", "origin", remote.to_str().unwrap()],
        &work
    ));
    assert!(git(&["push", "-q", "-u", "origin", "main"], &work));
    assert!(git(&["remote", "set-head", "origin", "-a"], &work));
    // Local work the enclosing repository has NOT pushed: a stray reset
    // to origin/HEAD would destroy exactly this.
    std::fs::write(&tracked, "uncommitted local work\n").unwrap();
    let index = work.join(".git").join("index");
    let index_before = std::fs::read(&index).unwrap();

    // The cache root itself lives INSIDE that repository, so the cache is
    // both a legitimate mutation target and nested in a victim.
    let home = work.join("home");
    let config = home.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&home, &config, || {
        let cache = remote_cache_dir("owner/repo").unwrap();
        write_fake_clone(&cache, "https://github.com/owner/repo.git");

        assert_eq!(
            fetch_remote_cache(&cache, None, FetchBound::BACKGROUND),
            FetchAttempt::Attempted(false),
            "a broken cache must fail as a broken cache"
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
        // The identity lookup answers from the cache's OWN recorded
        // origin, never by walking up: that value is stamped into the
        // lock as the source's repository and routes issue reports.
        assert_eq!(
            source_repo_from_git_origin(&cache),
            Some("owner/repo".to_string())
        );
        std::fs::write(cache.join(".git").join("config"), "[core]\n").unwrap();
        assert_eq!(
            source_repo_from_git_origin(&cache),
            None,
            "a cache with no recorded origin has no identity to borrow"
        );
    });
    let _ = std::fs::remove_dir_all(&root);
}

/// Nothing inherited from the caller's environment may redirect a cache
/// git command at another repository's index, objects, or config — the
/// same destruction class as discovery escape, through `GIT_INDEX_FILE`
/// and its family. Asserted on the command itself, because setting these
/// process-wide in a parallel test run would endanger real repositories.
#[test]
fn cache_git_commands_scrub_every_inherited_repository_pointer() {
    let command = git_command_for_cache();
    let envs: std::collections::HashMap<String, Option<String>> = command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|value| value.to_string_lossy().into_owned()),
            )
        })
        .collect();
    // Named INDEPENDENTLY of the array, so dropping a key from the
    // production list cannot silently shrink this loop with it.
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_CEILING_DIRECTORIES",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_NAMESPACE",
        "GIT_GRAFT_FILE",
        "GIT_CONFIG",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
    ] {
        assert_eq!(
            envs.get(key),
            Some(&None),
            "{key} must be removed, not inherited"
        );
    }
    // Prompting stays available on the BASE builder (an unbounded
    // interactive fetch may want a typed credential)…
    assert_eq!(envs.get("GIT_TERMINAL_PROMPT"), None);
    // …and is fully disabled once a call site opts in: a bounded fetch
    // has no terminal (or a raw one) to ask in.
    let mut suppressed = git_command_for_cache();
    suppress_git_prompts(&mut suppressed);
    let envs: std::collections::HashMap<String, Option<String>> = suppressed
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|value| value.to_string_lossy().into_owned()),
            )
        })
        .collect();
    for key in ["GIT_ASKPASS", "SSH_ASKPASS", "DISPLAY"] {
        assert_eq!(envs.get(key), Some(&None), "{key} must be removed");
    }
    assert_eq!(
        envs.get("GIT_TERMINAL_PROMPT"),
        Some(&Some("0".to_string()))
    );
    assert_eq!(
        envs.get("SSH_ASKPASS_REQUIRE"),
        Some(&Some("never".to_string()))
    );
    // The pinned variant keeps all of that and adds the pinning.
    let pinned = git_in_cache(Path::new("/tmp/whatever"));
    let pinned: std::collections::HashMap<String, Option<String>> = pinned
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|value| value.to_string_lossy().into_owned()),
            )
        })
        .collect();
    assert_eq!(pinned.get("GIT_INDEX_FILE"), Some(&None));
    // The pins are re-SET after the scrub: an inherited GIT_WORK_TREE
    // pointed the initial clone's checkout at a victim tree, so the base
    // builder removes all three and the pinned variant sets its own.
    assert!(pinned.get("GIT_DIR").is_some_and(|dir| dir.is_some()));
    assert!(
        pinned
            .get("GIT_WORK_TREE")
            .is_some_and(|tree| tree.is_some())
    );
    assert!(
        pinned
            .get("GIT_CEILING_DIRECTORIES")
            .is_some_and(|ceiling| ceiling.is_some())
    );
}

/// Containment, not caller discipline: a directory that is not a cache is
/// refused before any git process exists.
#[test]
fn a_directory_outside_the_cache_root_is_never_fetched_or_reset() {
    let root = cache_root("containment");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // Everything a lock can name that is NOT a cache: a project root,
        // an absolute local source, a relative one, and a nested path
        // under the cache root that is not a direct child.
        let project = root.join("project");
        std::fs::create_dir_all(project.join(".git")).unwrap();
        let nested = remote_cache_dir("owner/repo").unwrap().join("inner");
        std::fs::create_dir_all(&nested).unwrap();
        for dir in [
            project.as_path(),
            root.as_path(),
            Path::new("."),
            nested.as_path(),
        ] {
            assert_eq!(
                fetch_remote_cache(dir, None, FetchBound::BACKGROUND),
                FetchAttempt::OutOfCacheRoot,
                "{} must be refused",
                dir.display()
            );
            assert!(
                !dir.join(".git").join("vstack-fetch.lock").exists(),
                "refusal must happen before anything is created"
            );
        }
        // Control: the real cache directory IS accepted.
        let cache = remote_cache_dir("owner/repo").unwrap();
        write_fake_clone(&cache, "https://github.com/owner/repo.git");
        assert_eq!(
            fetch_remote_cache(&cache, None, FetchBound::BACKGROUND),
            FetchAttempt::Attempted(false)
        );
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
        let cache = remote_cache_dir("owner/repo").unwrap();
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&external, &cache).unwrap();
        assert_eq!(
            fetch_remote_cache(&cache, None, FetchBound::BACKGROUND),
            FetchAttempt::OutOfCacheRoot,
            "a symlinked cache dir must be refused"
        );
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
        assert_eq!(
            fetch_remote_cache(&cache, None, FetchBound::BACKGROUND),
            FetchAttempt::OutOfCacheRoot,
            "a symlinked .git must be refused"
        );
        assert!(!external.join(".git").join("vstack-fetch.lock").exists());
    });
    let _ = std::fs::remove_dir_all(&root);
}
