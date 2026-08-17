use super::liveness::abandoned_by;
use super::*;
use crate::config::remote_cache::test_support::*;
use std::time::Duration;

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
    assert_eq!(
        held.heartbeat.as_ref().map(|beat| beat.beat),
        Some(LOCK_HEARTBEAT),
        "the production acquire beats for the lease's lifetime, not a test's"
    );
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

/// The lock's liveness must hold for the LEASE's lifetime, not for the fetch
/// inside it: the install that follows a fetch reads the tree for as long as
/// discovery, hashing, copying and any human take, and a holder that stopped
/// beating when the fetch ended looked abandoned for all of it.
///
/// Asserted against a liveness answer of `None` — what a platform without
/// `kill(0)` returns — so what refuses the takeover here is the beat itself
/// and not the pid probe.
#[test]
fn a_held_lease_beats_for_its_whole_lifetime_and_stops_when_it_ends() {
    let root = cache_root("lease-lifetime-heartbeat");
    let dir = root.join("cache");
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    let lock = remote_cache_fetch_lock(&dir);
    let beat = Duration::from_millis(20);

    let held = match PortableFetchLock::acquire_beating(&dir, beat) {
        GuardAcquire::Held(guard) => guard,
        _ => panic!("first acquire must win"),
    };
    // The fetch phase is over; the lease is not. Age the lock past any
    // staleness window and let the holder's own heartbeat answer for it.
    backdate_lock(&lock);
    assert!(
        wait_for_fresh_mtime(&lock, beat * 50),
        "a held lease must keep refreshing its own lock's mtime"
    );
    assert!(
        !abandoned_by(&lock, Duration::from_secs(1), |_| None),
        "a beating lock is not abandoned, even where liveness is unknowable"
    );
    assert!(
        matches!(PortableFetchLock::acquire(&dir), GuardAcquire::Busy),
        "a contender must wait or refuse, never take over a live lease"
    );

    drop(held);
    assert!(!lock.exists(), "Drop unlinks the lock it still owns");

    // The refresher does not outlive the lease: a lock created at the same
    // path afterwards ages normally instead of being held alive by a thread
    // nobody owns — so a dead holder is still taken over and no cache wedges.
    std::fs::write(&lock, format!("{} {}\n", dead_pid(), epoch_now())).unwrap();
    backdate_lock(&lock);
    std::thread::sleep(beat * 5);
    assert!(
        abandoned_by(&lock, Duration::from_secs(60), |_| None),
        "a released lease's refresher must not keep a successor's lock fresh"
    );
    assert!(
        take_over_stale_lock(&lock, Duration::from_secs(60)),
        "a genuinely dead holder's lock is still recoverable"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Poll until the lock's mtime is fresh again, up to `limit`.
fn wait_for_fresh_mtime(lock: &Path, limit: Duration) -> bool {
    let started = std::time::Instant::now();
    while started.elapsed() < limit {
        let fresh = std::fs::metadata(lock)
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age < Duration::from_secs(60));
        if fresh {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    false
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
