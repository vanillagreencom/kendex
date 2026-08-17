use super::*;
use crate::config::remote_cache::test_support::*;
use std::time::Duration;

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

/// The guard platforms without `flock` use, compiled and RUN here. It is a
/// plain type rather than a `cfg` arm precisely so this test can exist — no CI
/// lane builds for a non-unix target, so nothing else would ever type-check it.
#[test]
fn the_portable_guard_is_exclusive_recovers_a_dead_holders_lock_and_reports_an_unusable_path() {
    let root = cache_root("portable-guard");
    let dir = root.join("cache");
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    let lock = remote_cache_fetch_lock(&dir);

    let held = match PortableFetchLock::acquire(&dir) {
        GuardAcquire::Held(guard) => guard,
        _ => panic!("first acquire must win"),
    };
    assert!(lock.exists(), "taking the lock IS creating the file");
    assert!(
        matches!(PortableFetchLock::acquire(&dir), GuardAcquire::Busy),
        "a second acquire must be refused while the first is held"
    );
    drop(held);
    assert!(!lock.exists(), "Drop unlinks the lock it still owns");

    // A lock left behind by a holder that is provably dead: fresh, it is
    // still nobody else's to take; past the staleness gate it is.
    std::fs::write(&lock, format!("{} {}\n", dead_pid(), epoch_now())).unwrap();
    assert!(
        matches!(PortableFetchLock::acquire(&dir), GuardAcquire::Busy),
        "a lock whose mtime is fresh is never taken over"
    );
    backdate_lock(&lock);
    let taken = match PortableFetchLock::acquire(&dir) {
        GuardAcquire::Held(guard) => guard,
        other => panic!(
            "a dead holder's stale lock must be recoverable: {}",
            match other {
                GuardAcquire::Busy => "busy",
                _ => "unusable",
            }
        ),
    };
    assert!(
        std::fs::read_to_string(&lock)
            .unwrap()
            .starts_with(&std::process::id().to_string()),
        "the successor records ITS OWN ownership"
    );
    drop(taken);
    assert!(!lock.exists());

    // A lock file that cannot be created at all is neither held nor busy.
    let no_such_cache = root.join("absent");
    assert!(
        matches!(
            PortableFetchLock::acquire(&no_such_cache),
            GuardAcquire::Unusable(_)
        ),
        "an uncreatable lock path must report itself, not read as free"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// The read-only probe both guards owe a reader: it answers whether a fetch
/// holds the lock, takes nothing, and writes nothing.
#[test]
fn a_probe_reports_a_held_guard_and_leaves_the_lock_file_alone() {
    let root = cache_root("guard-probe");
    let dir = root.join("cache");
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    let lock = remote_cache_fetch_lock(&dir);

    // Nothing has ever fetched this cache: no holder, and the probe must not
    // create the lock file to find that out.
    assert!(!RemoteCacheFetchGuard::probe(&dir));
    assert!(!PortableFetchLock::probe(&dir));
    assert!(!lock.exists(), "a read-only probe must not write into .git");

    // The portable guard answers off the file itself: held while its holder
    // lives, free once that holder is provably gone. It runs first because
    // its Drop unlinks the lock, which `flock` deliberately never does.
    let portable = match PortableFetchLock::acquire(&dir) {
        GuardAcquire::Held(guard) => guard,
        _ => panic!("the portable acquire must win an uncontended lock"),
    };
    assert!(PortableFetchLock::probe(&dir));
    drop(portable);
    assert!(!PortableFetchLock::probe(&dir));
    std::fs::write(&lock, format!("{} {}\n", dead_pid(), epoch_now())).unwrap();
    backdate_lock(&lock);
    assert!(
        !PortableFetchLock::probe(&dir),
        "an abandoned lock is not an in-flight fetch"
    );
    std::fs::remove_file(&lock).unwrap();

    let held = match RemoteCacheFetchGuard::acquire(&dir) {
        GuardAcquire::Held(guard) => guard,
        _ => panic!("acquire must win an uncontended lock"),
    };
    assert!(
        RemoteCacheFetchGuard::probe(&dir),
        "a held guard must read as busy"
    );
    drop(held);
    assert!(
        !RemoteCacheFetchGuard::probe(&dir),
        "a released guard must read as free again"
    );
    let _ = std::fs::remove_dir_all(&root);
}
