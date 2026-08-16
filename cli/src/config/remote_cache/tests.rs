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
    // The guard and the stamp are all this exercises — no git runs, so the
    // entry needs no clone.
    let dir = cache_with_git_dir("no-clobber");
    {
        let dir = dir.as_path();
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
    }
    let _ = std::fs::remove_dir_all(dir);
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
        let cache = RemoteSource::parse("owner/repo")
            .unwrap()
            .unwrap()
            .cache_dir;
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

/// A cache entry holding another repository's clone must never be fetched or
/// reset — its contents would be installed as this source. The refresh driver
/// reports the refusal rather than swallowing it, and nothing in the entry is
/// written on the way.
#[test]
fn a_cache_whose_origin_does_not_match_is_neither_fetched_nor_read() {
    with_sandboxed_cache("mismatch-refresh", |cache| {
        let intruder = cache.origin.parent().unwrap().join("someone-else");
        init_git_repo(&intruder);
        git(
            cache.dir(),
            &[
                "remote",
                "set-url",
                "origin",
                &format!("file://{}", intruder.display()),
            ],
        );
        let head_before = std::fs::read(cache.dir().join(".git").join("HEAD")).unwrap();

        let problems = refresh_remote_caches_older_than(
            &cache.lock(),
            Some(Duration::ZERO),
            FetchBound::BACKGROUND,
        );
        assert!(
            matches!(
                problems.as_slice(),
                [RemoteCacheProblem {
                    kind: RemoteCacheProblemKind::Refused { reason },
                    ..
                }] if reason.contains("its origin is")
            ),
            "a foreign clone must be reported as refused: {problems:?}"
        );
        assert!(
            problems[0].kind.is_persistent(),
            "only a human removing the entry clears this, so it is drift"
        );
        assert_eq!(
            std::fs::read(cache.dir().join(".git").join("HEAD")).unwrap(),
            head_before,
            "the refused entry must not be touched"
        );
        assert!(read_fetch_stamp(cache.dir()).is_none(), "never stamped");
    });
}
