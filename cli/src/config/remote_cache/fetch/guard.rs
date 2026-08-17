//! The exclusion around one cache's fetch and `reset --hard`: the lock file
//! and the two guard implementations that take it.
//!
//! Taking the guard is all that happens here. WHAT runs under it — the stamp,
//! the bounded fetch, the lease a reader keeps — is [`super`]'s; who holds a
//! portable lock and whether they are still alive is [`liveness`]'s; and every
//! question about which directory a cache is belongs to
//! [`crate::refresh_sources::RemoteSource`].

use crate::config::remote_cache::{
    REMOTE_CACHE_FETCH_DEADLINE, epoch_now, remote_cache_fetch_lock,
};
use liveness::{
    LOCK_HEARTBEAT, LockHeartbeat, LockOwner, STALE_LOCK_AFTER, create_lock_file,
    lock_is_abandoned, remove_lock_if_owned, take_over_stale_lock,
};
use std::path::{Path, PathBuf};

mod liveness;

/// Exclusive guard over one cache's stamp → fetch → reset.
///
/// It is writer-vs-writer exclusion for an EXISTING cache: every command that
/// fetches and resets one takes it, so two of them can never run in the same
/// tree. The initial clone is not covered (there is no `.git` to lock yet),
/// and readers do not take it — they [`probe`](FlockGuard::probe) it instead.
///
/// Two independent implementations, and the platform picks one. They are
/// separate types rather than `cfg` arms of a single struct so that the
/// portable one is COMPILED AND RUN by `cargo test` on unix: a branch no
/// build here ever type-checks is a branch nobody can trust.
#[cfg(unix)]
pub(in crate::config::remote_cache) type RemoteCacheFetchGuard = FlockGuard;
#[cfg(not(unix))]
pub(in crate::config::remote_cache) type RemoteCacheFetchGuard = PortableFetchLock;

/// Result of trying to take a guard.
pub(in crate::config::remote_cache) enum GuardAcquire<G> {
    Held(G),
    /// Another process is fetching this cache right now.
    Busy,
    /// The lock file itself cannot be created (permissions).
    Unusable(String),
}

/// `flock(LOCK_EX | LOCK_NB)` on a lock file inside `.git/`: the kernel
/// releases it when the holder exits, so a crashed holder leaves nothing stale
/// behind and there is no staleness heuristic for two contenders to race on.
/// The lock file is never unlinked — unlinking a flocked path lets a second
/// waiter lock a file nobody else can see.
#[cfg(unix)]
pub(in crate::config::remote_cache) struct FlockGuard {
    #[allow(
        dead_code,
        reason = "held for its Drop: the kernel releases the flock when this open file closes"
    )]
    file: std::fs::File,
}

#[cfg(unix)]
impl FlockGuard {
    pub(in crate::config::remote_cache) fn acquire(cache_dir: &Path) -> GuardAcquire<Self> {
        Self::try_lock(cache_dir, Intent::Hold)
    }

    /// Whether another process holds the guard, WITHOUT taking it: the try
    /// that answers is released before this returns.
    ///
    /// The lock file is never created here. A cache nothing has ever fetched
    /// has no lock file, and a reader must not write into `.git` to find that
    /// out — nor may an unwritable cache read as busy, which is why the probe
    /// opens read-only and a path that cannot be opened at all answers "no
    /// holder" rather than "busy".
    pub(in crate::config::remote_cache) fn probe(cache_dir: &Path) -> bool {
        matches!(Self::try_lock(cache_dir, Intent::Probe), GuardAcquire::Busy)
    }

    fn try_lock(cache_dir: &Path, intent: Intent) -> GuardAcquire<Self> {
        use std::os::unix::io::AsRawFd;
        let path = remote_cache_fetch_lock(cache_dir);
        let opened = match intent {
            Intent::Hold => std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path),
            Intent::Probe => std::fs::OpenOptions::new().read(true).open(&path),
        };
        let file = match opened {
            Ok(file) => file,
            Err(err) => return GuardAcquire::Unusable(err.to_string()),
        };
        // A `fork` anywhere in this process copies every open file
        // description, and the copy holds the flock until the child execs.
        // That window is milliseconds, so a contended try is retried briefly
        // before calling the cache busy — a real in-flight fetch outlasts it.
        for attempt in 0..5 {
            // SAFETY: `file` owns a live fd for the duration of the call;
            // flock reads no memory and only inspects the descriptor. The
            // lock is released by the kernel when `file` is dropped, when
            // every inherited copy of the description is closed, or when the
            // process dies — so a crashed holder never leaves it stuck. A
            // read-only descriptor locks exactly as a writable one does:
            // flock's exclusion is per open file description, not per access
            // mode, so the probe sees precisely what a holder would.
            let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if rc == 0 {
                return GuardAcquire::Held(Self { file });
            }
            let err = std::io::Error::last_os_error();
            match err.raw_os_error() {
                Some(code) if code == libc::EWOULDBLOCK || code == libc::EINTR => {}
                _ => return GuardAcquire::Unusable(err.to_string()),
            }
            if attempt < 4 {
                std::thread::sleep(std::time::Duration::from_millis(40));
            }
        }
        GuardAcquire::Busy
    }
}

/// Whether a try means to KEEP the guard or only to ask whether it is free.
/// The difference is the lock file: a holder creates it, a probe never does.
#[cfg(unix)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Intent {
    Hold,
    Probe,
}

/// Without `flock`, creating the lock file IS taking the lock, so it must not
/// be pre-created: `create_new` is the whole mechanism. Drop unlinks it, and
/// only while it still records this holder. A holder that is killed leaves its
/// file behind, and nothing else would ever remove it — so a lock whose holder
/// is provably gone is taken over, by exactly one contender.
///
/// Being alive is something this lock has to keep SAYING. Its holder goes on
/// reading the tree long after any fetch is over — discovering, hashing,
/// copying, waiting on a person — so the [`LockHeartbeat`] runs for the whole
/// lifetime of the value, not for one phase of it, and stops when it drops.
#[allow(
    dead_code,
    reason = "fallback implementation for targets no CI lane builds; on unix it is compiled only so the tests exercise it"
)]
pub(in crate::config::remote_cache) struct PortableFetchLock {
    path: PathBuf,
    /// The record written into the lock file; Drop's proof it is still ours.
    owner: LockOwner,
    /// `Option` only so [`Drop`] can stop it BEFORE the unlink.
    heartbeat: Option<LockHeartbeat>,
}

#[allow(
    dead_code,
    reason = "fallback implementation for targets no CI lane builds; on unix it is compiled only so the tests exercise it"
)]
impl PortableFetchLock {
    pub(in crate::config::remote_cache) fn acquire(cache_dir: &Path) -> GuardAcquire<Self> {
        Self::acquire_beating(cache_dir, LOCK_HEARTBEAT)
    }

    /// [`acquire`](Self::acquire) with the heartbeat interval named, so a test
    /// can watch a whole lifetime's worth of beats without waiting minutes.
    fn acquire_beating(cache_dir: &Path, beat: std::time::Duration) -> GuardAcquire<Self> {
        let path = remote_cache_fetch_lock(cache_dir);
        match create_lock_file(&path) {
            Ok(owner) => GuardAcquire::Held(Self::held(path, owner, beat)),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                if take_over_stale_lock(&path, STALE_LOCK_AFTER) {
                    match create_lock_file(&path) {
                        Ok(owner) => GuardAcquire::Held(Self::held(path, owner, beat)),
                        Err(_) => GuardAcquire::Busy,
                    }
                } else {
                    GuardAcquire::Busy
                }
            }
            Err(err) => GuardAcquire::Unusable(err.to_string()),
        }
    }

    fn held(path: PathBuf, owner: LockOwner, beat: std::time::Duration) -> Self {
        let heartbeat = LockHeartbeat::start(path.clone(), owner, beat);
        Self {
            path,
            owner,
            heartbeat,
        }
    }

    /// Whether another process holds the guard, WITHOUT taking it.
    ///
    /// Here the lock file IS the lock, so the probe is a read: a file that
    /// exists and has not been abandoned by its holder is one somebody holds.
    /// It must not `create_new` and unlink the way [`acquire`](Self::acquire)
    /// does — that would make every reader briefly indistinguishable from a
    /// fetcher, and would delete a successor's lock on the way out.
    pub(in crate::config::remote_cache) fn probe(cache_dir: &Path) -> bool {
        let path = remote_cache_fetch_lock(cache_dir);
        path.exists() && !lock_is_abandoned(&path, STALE_LOCK_AFTER)
    }
}

impl Drop for PortableFetchLock {
    fn drop(&mut self) {
        // Stopped first, and joined: after this line the lease is over, and a
        // refresher that outlived it would keep touching a path that is about
        // to be unlinked and re-created by somebody else.
        drop(self.heartbeat.take());
        remove_lock_if_owned(&self.path, self.owner);
    }
}

#[cfg(test)]
mod tests;
