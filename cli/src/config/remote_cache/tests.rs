use super::test_support::*;
use super::*;
use std::time::Duration;

#[test]
fn the_drift_threshold_is_derived_from_the_ttl_not_a_second_literal() {
    assert_eq!(REMOTE_CACHE_FAILURE_IS_DRIFT, REMOTE_CACHE_TTL * 2);
    // The low-speed abort must be able to fire before the wall-clock kill,
    // or it is decoration.
    assert!(
        Duration::from_secs(REMOTE_CACHE_LOW_SPEED_SECS) < REMOTE_CACHE_FETCH_DEADLINE,
        "the low-speed window must be strictly inside the deadline"
    );
}

#[test]
fn unstamped_cache_is_due_and_no_bound_is_always_due() {
    let dir = cache_with_git_dir("unstamped");
    assert!(remote_cache_fetch_due(
        &dir,
        Some(Duration::from_secs(3600))
    ));
    assert!(remote_cache_fetch_due(&dir, None));
    write_fetch_stamp(&dir, FetchStamp::Ok).unwrap();
    assert!(remote_cache_fetch_due(&dir, None));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_fresh_clone_is_trusted_for_its_full_ttl() {
    // A clone is the newest possible fetch. Unstamped, the TTL predicate
    // reads it as due and the next `check` spawns a background refresh of
    // a cache made seconds ago.
    let dir = cache_with_git_dir("cloned");
    assert!(
        remote_cache_fetch_due(&dir, Some(REMOTE_CACHE_TTL)),
        "control: an unstamped clone is due"
    );
    record_cache_clone(&dir);
    assert!(!remote_cache_fetch_due(&dir, Some(REMOTE_CACHE_TTL)));
    assert_eq!(read_fetch_stamp(&dir), Some(FetchStamp::Ok));
    // And it is a clean stamp: nothing reports the fresh clone as a
    // failing cache.
    assert!(remote_cache_problem(&dir).is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn fresh_stamp_suppresses_fetch_until_ttl_passes() {
    let dir = cache_with_git_dir("fresh");
    write_fetch_stamp(&dir, FetchStamp::Ok).unwrap();
    assert!(
        !remote_cache_fetch_due(&dir, Some(Duration::from_secs(3600))),
        "a just-written stamp must not be due"
    );
    // Control: a zero TTL is always due — proves the predicate reads age,
    // not mere stamp presence.
    assert!(remote_cache_fetch_due(&dir, Some(Duration::ZERO)));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn stamp_round_trips_every_state_and_only_failure_is_a_problem() {
    let dir = cache_with_git_dir("outcome");
    assert!(read_fetch_stamp(&dir).is_none(), "unstamped");
    assert!(remote_cache_problem(&dir).is_none(), "unstamped");

    write_fetch_stamp(&dir, FetchStamp::Ok).unwrap();
    assert_eq!(read_fetch_stamp(&dir), Some(FetchStamp::Ok));
    assert!(remote_cache_problem(&dir).is_none(), "ok stamp");

    // A fetch in flight must never be read as a failure.
    write_fetch_stamp(
        &dir,
        FetchStamp::Pending {
            first_failure: Some(1000),
        },
    )
    .unwrap();
    assert_eq!(
        read_fetch_stamp(&dir),
        Some(FetchStamp::Pending {
            first_failure: Some(1000)
        })
    );
    assert!(
        remote_cache_problem(&dir).is_none(),
        "a fetch in flight is not a failure"
    );

    let now = epoch_now();
    write_fetch_stamp(
        &dir,
        FetchStamp::Failed {
            first: now,
            last: now,
            cause: Some(FetchFailure::Reset),
        },
    )
    .unwrap();
    assert!(failing_for(&dir).is_some(), "failed stamp");
    assert!(matches!(
        remote_cache_problem(&dir),
        Some(RemoteCacheProblemKind::Failing {
            cause: Some(FetchFailure::Reset),
            ..
        })
    ));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn an_abandoned_pending_attempt_becomes_a_failure_instead_of_silence() {
    let dir = cache_with_git_dir("abandoned");
    let first = epoch_now() - (REMOTE_CACHE_FAILURE_IS_DRIFT.as_secs() + 60);
    write_fetch_stamp(
        &dir,
        FetchStamp::Pending {
            first_failure: Some(first),
        },
    )
    .unwrap();
    // Backdate the stamp past the fetch deadline: its holder was killed
    // before it could record anything, and the guard is free.
    let killed_at =
        std::time::SystemTime::now() - (REMOTE_CACHE_FETCH_DEADLINE + Duration::from_secs(60));
    std::fs::File::options()
        .write(true)
        .open(remote_cache_fetch_stamp(&dir))
        .unwrap()
        .set_modified(killed_at)
        .unwrap();

    let problem = remote_cache_problem(&dir).expect("an abandoned attempt is a failure");
    assert!(matches!(
        problem,
        RemoteCacheProblemKind::Failing {
            cause: Some(FetchFailure::Interrupted),
            ..
        }
    ));
    assert!(
        problem.is_persistent(),
        "the run started more than two TTLs ago"
    );
    // It is recorded, so the next reader sees a failure without re-deriving it.
    assert!(matches!(
        read_fetch_stamp(&dir),
        Some(FetchStamp::Failed {
            cause: Some(FetchFailure::Interrupted),
            ..
        })
    ));
    // And the conversion did NOT reset the file mtime to now: dueness
    // reads the mtime, so a now-stamped conversion would defer the next
    // refresh a full TTL from this observation instead of from the
    // attempt. The attempt is ~deadline+60s old, so a shorter max_age
    // must still see the cache as due.
    assert!(
        remote_cache_fetch_due(&dir, Some(REMOTE_CACHE_FETCH_DEADLINE)),
        "the converted stamp must keep the attempt's own mtime"
    );
    // Control: a fresh Pending stays silent.
    write_fetch_stamp(
        &dir,
        FetchStamp::Pending {
            first_failure: None,
        },
    )
    .unwrap();
    assert!(remote_cache_problem(&dir).is_none());
    let _ = std::fs::remove_dir_all(dir);
}

/// A checker that waits for the guard must re-read before condemning: the
/// fetch it was about to call abandoned may have finished while it
/// waited, and overwriting that verdict would record an up-to-date cache
/// as failing.
#[test]
fn a_waiting_checker_never_clobbers_a_fetch_that_just_succeeded() {
    with_sandboxed_cache("no-clobber", |dir| {
        // An attempt that looks abandoned: Pending, older than the
        // deadline, so a checker would normally promote it to Failed.
        write_fetch_stamp(
            dir,
            FetchStamp::Pending {
                first_failure: None,
            },
        )
        .unwrap();
        std::fs::File::options()
            .write(true)
            .open(remote_cache_fetch_stamp(dir))
            .unwrap()
            .set_modified(
                std::time::SystemTime::now()
                    - (REMOTE_CACHE_FETCH_DEADLINE + Duration::from_secs(60)),
            )
            .unwrap();

        // The real holder finishes while the checker is waiting for the
        // guard the holder still owns.
        let cache = dir.to_path_buf();
        let winner = std::thread::spawn(move || {
            let guard = match RemoteCacheFetchGuard::acquire(&cache) {
                GuardAcquire::Held(guard) => guard,
                _ => panic!("the winner must get the guard first"),
            };
            std::thread::sleep(Duration::from_millis(60));
            write_fetch_stamp(&cache, FetchStamp::Ok).unwrap();
            drop(guard);
        });
        // Give the winner the guard before the checker starts.
        std::thread::sleep(Duration::from_millis(10));

        let verdict = remote_cache_problem(dir);
        winner.join().unwrap();

        assert!(
            verdict.is_none(),
            "a cache that just refreshed successfully is not failing: {verdict:?}"
        );
        assert_eq!(
            read_fetch_stamp(dir),
            Some(FetchStamp::Ok),
            "the winner's verdict must survive"
        );
    });
}

#[test]
fn a_failure_run_is_drift_only_after_it_outlives_two_ttls() {
    let dir = cache_with_git_dir("persistence");
    let now = epoch_now();
    // A blip: first failure moments ago, retried since.
    write_fetch_stamp(
        &dir,
        FetchStamp::Failed {
            first: now - 60,
            last: now,
            cause: Some(FetchFailure::Fetch),
        },
    )
    .unwrap();
    let blip = remote_cache_problem(&dir).expect("a failure is recorded");
    assert!(!blip.is_persistent(), "one offline blip must stay quiet");

    // The same remote, still failing after two TTL windows of retries.
    write_fetch_stamp(
        &dir,
        FetchStamp::Failed {
            first: now - (REMOTE_CACHE_FAILURE_IS_DRIFT.as_secs() + 60),
            last: now,
            cause: Some(FetchFailure::Fetch),
        },
    )
    .unwrap();
    let stuck = remote_cache_problem(&dir).expect("a failure is recorded");
    assert!(
        stuck.is_persistent(),
        "a permanently broken remote is drift"
    );
    assert!(
        RemoteCacheProblemKind::Unwritable {
            reason: "denied".into()
        }
        .is_persistent(),
        "a cache that cannot be written can never fix itself"
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn remote_slug_keys_on_host_and_normalizes_every_accepted_form() {
    // Shorthand IS GitHub, and says so.
    assert_eq!(
        remote_source_slug("owner/repo").as_deref(),
        Some("github.com/owner/repo")
    );
    for url in [
        "https://github.com/owner/repo",
        "https://github.com/owner/repo.git",
        "https://github.com/owner/repo/",
        "git@github.com:owner/repo.git",
        "ssh://git@github.com/owner/repo.git",
    ] {
        assert_eq!(
            remote_source_slug(url).as_deref(),
            Some("github.com/owner/repo"),
            "{url}"
        );
    }
    // Cross-host control: the SAME owner/repo on another host is a
    // different source and must never share a cache.
    assert_eq!(
        remote_source_slug("https://gitlab.example/owner/repo").as_deref(),
        Some("gitlab.example/owner/repo")
    );
    assert_ne!(
        remote_cache_dir("https://gitlab.example/owner/repo"),
        remote_cache_dir("owner/repo")
    );
    // Subgroups are kept, not collapsed onto the last two segments.
    assert_eq!(
        remote_source_slug("https://gitlab.com/group/sub/repo.git").as_deref(),
        Some("gitlab.com/group/sub/repo")
    );
    assert_ne!(
        remote_cache_dir("https://gitlab.com/group/sub/repo"),
        remote_cache_dir("https://gitlab.com/sub/repo")
    );
    // The HOST is case-insensitive, so it normalizes...
    assert_eq!(
        remote_source_slug("https://GitHub.com/owner/repo").as_deref(),
        Some("github.com/owner/repo")
    );
    // ...but the PATH is not: two repositories that differ only in case
    // are two repositories on a case-sensitive forge, and must not share
    // one cache.
    assert_eq!(
        remote_source_slug("https://github.com/Owner/Repo").as_deref(),
        Some("github.com/Owner/Repo")
    );
    assert_ne!(
        remote_cache_dir("https://github.com/Owner/Repo"),
        remote_cache_dir("owner/repo")
    );
    // A nonstandard port is part of the endpoint's identity.
    assert_eq!(
        remote_source_slug("ssh://git@example.com:2222/owner/repo.git").as_deref(),
        Some("example.com:2222/owner/repo")
    );
    assert_ne!(
        remote_cache_dir("ssh://git@example.com:2222/owner/repo.git"),
        remote_cache_dir("ssh://git@example.com/owner/repo.git")
    );
    // …and the key stays a single path component.
    let ported = remote_cache_dir("ssh://git@example.com:2222/owner/repo.git").unwrap();
    assert_eq!(ported.parent(), Some(remote_cache_root().as_path()));
    assert_eq!(
        ported.file_name().unwrap(),
        "example.com%3A2222%2Fowner%2Frepo"
    );
    // Cleartext transport is refused outright.
    assert!(remote_source_slug("http://github.com/owner/repo").is_none());
    for bad in [
        "",
        "owner",
        "/abs/path",
        "./rel",
        "../up/x",
        "owner/..",
        "../repo",
        "owner\\..\\..\\etc",
        "https://github.com/owner/repo with space",
        "owner/re\npo",
        "file:///etc/passwd",
    ] {
        assert!(remote_source_slug(bad).is_none(), "{bad:?}");
        assert!(remote_cache_dir(bad).is_none(), "{bad:?}");
    }
    assert!(!is_remote_source_slug("owner/repo/extra"));
}

#[test]
fn remote_cache_dir_stays_directly_under_the_cache_root() {
    let dir = remote_cache_dir("owner/repo").unwrap();
    let root = global_base_dir().join(".vstack").join("cache");
    assert_eq!(dir.parent(), Some(root.as_path()));
    assert_eq!(dir.file_name().unwrap(), "github.com%2Fowner%2Frepo");
}

#[test]
fn distinct_sources_never_share_a_cache_directory() {
    // `_` is legal inside a slug segment, so flattening `/` to `_` mapped
    // these two valid, DIFFERENT repositories onto one directory.
    let underscore_owner = remote_cache_dir("https://github.com/a_b/c").unwrap();
    let underscore_repo = remote_cache_dir("https://github.com/a/b_c").unwrap();
    assert_ne!(underscore_owner, underscore_repo);
    // Both still sit directly under the cache root, which is what keeps
    // every cache mutation inside the containment check.
    let root = remote_cache_root();
    for dir in [&underscore_owner, &underscore_repo] {
        assert_eq!(dir.parent(), Some(root.as_path()));
        assert!(is_under_remote_cache_root(dir), "{dir:?}");
    }
    // And nothing escapes the root through the key itself.
    assert!(remote_cache_dir("https://github.com/../../etc").is_none());
}

#[test]
fn a_cache_is_only_used_when_its_recorded_origin_is_this_source() {
    let root = cache_root("origin");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        let dir = remote_cache_dir("owner/repo").unwrap();
        assert_eq!(remote_cache_lookup("owner/repo"), RemoteCacheLookup::Absent);

        write_fake_clone(&dir, "https://github.com/owner/repo.git");
        assert_eq!(
            remote_cache_lookup("owner/repo"),
            RemoteCacheLookup::Usable(dir.clone())
        );
        assert_eq!(usable_remote_cache("owner/repo").as_ref(), Some(&dir));

        // Another repository's clone sitting at this key is never used:
        // installing from it would install its agents and hooks.
        write_fake_clone(&dir, "https://github.com/attacker/repo.git");
        assert!(matches!(
            remote_cache_lookup("owner/repo"),
            RemoteCacheLookup::Unverifiable { .. }
        ));
        assert!(usable_remote_cache("owner/repo").is_none());

        // A clone with no recorded origin cannot be proven either.
        std::fs::write(dir.join(".git").join("config"), "[core]\n").unwrap();
        assert!(matches!(
            remote_cache_lookup("owner/repo"),
            RemoteCacheLookup::Unverifiable { .. }
        ));
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_legacy_cache_directory_is_adopted_instead_of_re_cloned() {
    let root = cache_root("legacy");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // What releases before the host-aware key wrote.
        let legacy = global_base_dir()
            .join(".vstack")
            .join("cache")
            .join("owner_repo");
        write_fake_clone(&legacy, "git@github.com:owner/repo.git");
        assert_eq!(
            remote_cache_lookup("owner/repo"),
            RemoteCacheLookup::Usable(legacy.clone()),
            "an existing clone must be adopted, not abandoned"
        );

        // Control: a legacy directory holding a DIFFERENT repo is not
        // adopted just because its name matches. It is not refused
        // either — a legacy key is lossy, so a mismatch means the
        // directory belongs to somebody else, and this source simply has
        // no cache yet.
        write_fake_clone(&legacy, "https://github.com/other/repo.git");
        assert_eq!(remote_cache_lookup("owner/repo"), RemoteCacheLookup::Absent);
        assert!(usable_remote_cache("owner/repo").is_none());
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_pre_encoding_cache_is_adopted_and_never_blocks_its_colliding_twin() {
    let root = cache_root("legacy-flat");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // What the `_`-flattened key wrote for `github.com/a_b/c`.
        let legacy = remote_cache_root().join("github.com_a_b_c");
        write_fake_clone(&legacy, "https://github.com/a_b/c.git");
        assert_eq!(
            remote_cache_lookup("https://github.com/a_b/c"),
            RemoteCacheLookup::Usable(legacy.clone()),
            "an existing clone must be adopted, not re-cloned"
        );
        // The source that used to collide with it now has no cache of
        // its own — and is free to clone one, rather than being refused
        // forever because somebody else's directory shares the old key.
        assert_eq!(
            remote_cache_lookup("https://github.com/a/b_c"),
            RemoteCacheLookup::Absent
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_legacy_scp_shaped_cache_directory_is_adopted_too() {
    let root = cache_root("legacy-scp");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        // The other shape earlier releases wrote: the scp URL flattened.
        let legacy = remote_cache_root().join("git@github.com:owner_repo");
        write_fake_clone(&legacy, "git@github.com:owner/repo.git");
        assert_eq!(
            remote_cache_lookup("owner/repo"),
            RemoteCacheLookup::Usable(legacy.clone()),
            "an scp-shaped clone must be adopted, not abandoned"
        );
        // Control: same directory name, different repository — not ours,
        // and not a refusal either (see the legacy adoption test).
        write_fake_clone(&legacy, "git@github.com:someone/else.git");
        assert_eq!(remote_cache_lookup("owner/repo"), RemoteCacheLookup::Absent);
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A read-only stamp or lock under a WRITABLE `.git` lets every refresh
/// run and then fail to record anything, so a stale `ok` is trusted
/// forever. The read path must probe the files the refresh actually
/// needs, not just the directory.
#[cfg(unix)]
#[test]
fn a_read_only_stamp_or_lock_surfaces_as_unwritable_when_due() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: `geteuid` reads the calling process's effective uid; it
    // takes no arguments and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return; // root ignores the permission bits this test relies on
    }
    let root = cache_root("readonly-stamp");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        let cache = remote_cache_dir("owner/repo").unwrap();
        write_fake_clone(&cache, "https://github.com/owner/repo.git");
        let lock = demo_lock("owner/repo");

        // A stale `ok` stamp: due for a refresh, nothing recorded as
        // failing — the exact state a silent recording failure hides in.
        write_fetch_stamp(&cache, FetchStamp::Ok).unwrap();
        let stamp = remote_cache_fetch_stamp(&cache);
        std::fs::File::options()
            .write(true)
            .open(&stamp)
            .unwrap()
            .set_modified(
                std::time::SystemTime::now() - (REMOTE_CACHE_TTL + Duration::from_secs(60)),
            )
            .unwrap();

        // Control: writable files report nothing.
        assert!(recorded_remote_cache_problems(&lock).is_empty());

        // Read-only STAMP.
        std::fs::set_permissions(&stamp, std::fs::Permissions::from_mode(0o444)).unwrap();
        let problems = recorded_remote_cache_problems(&lock);
        assert!(
            matches!(
                problems.as_slice(),
                [RemoteCacheProblem {
                    kind: RemoteCacheProblemKind::Unwritable { reason },
                    ..
                }] if reason.contains("vstack-fetch-stamp")
            ),
            "a read-only stamp must surface: {problems:?}"
        );
        std::fs::set_permissions(&stamp, std::fs::Permissions::from_mode(0o644)).unwrap();

        // Read-only LOCK.
        let lock_path = cache.join(".git").join("vstack-fetch.lock");
        std::fs::write(&lock_path, "").unwrap();
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o444)).unwrap();
        let problems = recorded_remote_cache_problems(&lock);
        assert!(
            matches!(
                problems.as_slice(),
                [RemoteCacheProblem {
                    kind: RemoteCacheProblemKind::Unwritable { reason },
                    ..
                }] if reason.contains("vstack-fetch.lock")
            ),
            "a read-only lock must surface: {problems:?}"
        );
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o644)).unwrap();

        // Fresh stamp: not due, so nothing probes and nothing reports.
        write_fetch_stamp(&cache, FetchStamp::Ok).unwrap();
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o444)).unwrap();
        assert!(
            recorded_remote_cache_problems(&lock).is_empty(),
            "a cache that is not due needs no writability yet"
        );
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o644)).unwrap();
    });
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_cache_whose_origin_does_not_match_is_neither_fetched_nor_read() {
    let root = cache_root("mismatch-refresh");
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    crate::test_util::with_home_and_config(&root, &config, || {
        let cache = remote_cache_dir("owner/repo").unwrap();
        write_fake_clone(&cache, "https://github.com/someone-else/repo.git");
        let lock = demo_lock("owner/repo");
        assert!(cached_remote_sources(&lock).is_empty());
        assert!(recorded_remote_cache_problems(&lock).is_empty());
        assert!(!any_remote_cache_due(&lock, Some(Duration::ZERO)));
        assert!(read_fetch_stamp(&cache).is_none(), "never touched");
    });
    let _ = std::fs::remove_dir_all(root);
}
