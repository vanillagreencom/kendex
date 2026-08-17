//! The liveness record a portable lock carries, and what a contender may do
//! about a holder that has stopped keeping it fresh.

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
    // A beat must never re-create a lock its lease already released.
    std::fs::remove_file(&lock).unwrap();
    refresh_lock_liveness(&lock);
    assert!(!lock.exists(), "a beat must not resurrect a released lock");
    let _ = std::fs::remove_dir_all(dir);
}

/// The liveness probe itself, on the platform that has one.
#[cfg(unix)]
#[test]
fn process_liveness_answers_for_live_and_dead_pids() {
    assert_eq!(process_is_alive(std::process::id()), Some(true));
    assert_eq!(process_is_alive(dead_pid()), Some(false));
}
