//! The exclusion around one cache's fetch and `reset --hard`: the lock file,
//! the two guard implementations that take it, and the liveness record that
//! tells a dead holder's leftover from a slow one's.
//!
//! Taking the guard is all that happens here. WHAT runs under it — the stamp,
//! the bounded fetch, the lease a reader keeps — is [`super`]'s, and every
//! question about which directory a cache is belongs to
//! [`crate::refresh_sources::RemoteSource`].

use crate::config::remote_cache::{
    REMOTE_CACHE_FETCH_DEADLINE, epoch_now, remote_cache_fetch_lock,
};
use std::path::{Path, PathBuf};

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
    #[allow(dead_code)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
enum Intent {
    Hold,
    Probe,
}

/// Without `flock`, creating the lock file IS taking the lock, so it must not
/// be pre-created: `create_new` is the whole mechanism. Drop unlinks it, and
/// only while it still records this holder. A holder that is killed leaves its
/// file behind, and nothing else would ever remove it — so a lock whose holder
/// is provably gone is taken over, by exactly one contender.
#[allow(dead_code)]
pub(in crate::config::remote_cache) struct PortableFetchLock {
    path: PathBuf,
    /// The record written into the lock file; Drop's proof it is still ours.
    owner: LockOwner,
}

#[allow(dead_code)]
impl PortableFetchLock {
    pub(in crate::config::remote_cache) fn acquire(cache_dir: &Path) -> GuardAcquire<Self> {
        let path = remote_cache_fetch_lock(cache_dir);
        match create_lock_file(&path) {
            Ok(owner) => GuardAcquire::Held(Self { path, owner }),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                if take_over_stale_lock(&path, STALE_LOCK_AFTER) {
                    match create_lock_file(&path) {
                        Ok(owner) => GuardAcquire::Held(Self { path, owner }),
                        Err(_) => GuardAcquire::Busy,
                    }
                } else {
                    GuardAcquire::Busy
                }
            }
            Err(err) => GuardAcquire::Unusable(err.to_string()),
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
        remove_lock_if_owned(&self.path, self.owner);
    }
}

/// A lock whose mtime is this old has missed several liveness heartbeats
/// ([`LOCK_HEARTBEAT`] refreshes it while a fetch runs, bounded or not), so
/// its holder is presumed dead — and the ownership record is still read back
/// before takeover, so a live holder whose heartbeat is merely late keeps its
/// lock. Only [`PortableFetchLock`] needs any of this; where `flock` exists
/// the kernel releases the lock when its holder dies.
#[allow(dead_code)]
const STALE_LOCK_AFTER: std::time::Duration =
    std::time::Duration::from_secs(REMOTE_CACHE_FETCH_DEADLINE.as_secs() * 2);

/// The pid + epoch a lock file records about its creator. The pair is the
/// guard's identity: Drop unlinks only a lock that still carries its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
struct LockOwner {
    pid: u32,
    epoch: u64,
}

/// Create the lock file, recording who holds it. `AlreadyExists` means
/// somebody else does.
#[allow(dead_code)]
fn create_lock_file(path: &Path) -> std::io::Result<LockOwner> {
    use std::io::Write as _;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    let owner = LockOwner {
        pid: std::process::id(),
        epoch: epoch_now(),
    };
    writeln!(file, "{} {}", owner.pid, owner.epoch)?;
    Ok(owner)
}

/// The ownership record inside a lock file, if it parses.
#[allow(dead_code)]
fn read_lock_owner(path: &Path) -> Option<LockOwner> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut fields = content.split_whitespace();
    Some(LockOwner {
        pid: fields.next()?.parse().ok()?,
        epoch: fields.next()?.parse().ok()?,
    })
}

/// Unlink the lock only when it still records `owner` — a contender that took
/// over a stale lock created its OWN file at this path, and blindly unlinking
/// would free the successor's lock for a third writer.
#[allow(dead_code)]
fn remove_lock_if_owned(path: &Path, owner: LockOwner) -> bool {
    if read_lock_owner(path) == Some(owner) {
        std::fs::remove_file(path).is_ok()
    } else {
        false
    }
}

/// Is the process with this pid still running? `None` when the platform has
/// no way to ask.
#[allow(dead_code)]
fn process_is_alive(pid: u32) -> Option<bool> {
    #[cfg(unix)]
    {
        // SAFETY: `kill` with signal 0 performs error checking only — no
        // signal is sent, no memory is touched, and no process is affected.
        let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
        if rc == 0 {
            return Some(true);
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(code) if code == libc::ESRCH => Some(false),
            // EPERM: it exists, we just may not signal it.
            Some(code) if code == libc::EPERM => Some(true),
            _ => None,
        }
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        None
    }
}

/// Whether a lock file's holder is gone: nothing to wait for, and nothing a
/// reader has to treat as an in-flight fetch.
///
/// Two gates, both required. The mtime must have outlived the heartbeat by
/// `stale_after` — a live fetch, bounded or unbounded, keeps touching its
/// lock, so a fresh mtime is proof of life. And the recorded holder must not
/// be provably alive: a slow machine's late heartbeat must not get a live
/// fetch's lock stolen out from under it and put two writers in one tree.
/// (A recycled pid reads as alive and conservatively delays the takeover
/// until that unrelated process exits — waiting is safe, two writers is not.)
#[allow(dead_code)]
fn lock_is_abandoned(path: &Path, stale_after: std::time::Duration) -> bool {
    let stale = std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age >= stale_after);
    stale && read_lock_owner(path).is_none_or(|owner| process_is_alive(owner.pid) != Some(true))
}

/// Take over a lock left behind by a holder that died, and say whether THIS
/// caller is the one that took it.
///
/// The take-over is a rename to a unique name, not an unlink: two contenders
/// racing here both try to move the same path, and only one rename can find
/// it, so exactly one of them may go on to create a fresh lock. Unlinking
/// would let both proceed — and would let a slow contender delete a lock that
/// a third process had meanwhile created legitimately.
#[allow(dead_code)]
fn take_over_stale_lock(path: &Path, stale_after: std::time::Duration) -> bool {
    if !lock_is_abandoned(path, stale_after) {
        return false;
    }
    let claim = path.with_extension(format!("taken.{}.{}", std::process::id(), epoch_now()));
    match std::fs::rename(path, &claim) {
        Ok(()) => {
            let _ = std::fs::remove_file(&claim);
            true
        }
        // Somebody else got there first — or it is gone already, in which
        // case they will create the next lock and we should not race them.
        Err(_) => false,
    }
}

/// How often a running fetch refreshes its lock file's mtime. This is the
/// liveness signal behind [`STALE_LOCK_AFTER`]: an unbounded fetch may
/// legitimately run for as long as its user is willing to wait, and only the
/// heartbeat keeps its lock distinguishable from a dead holder's.
pub(super) const LOCK_HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(30);

/// Refresh the lock's mtime so contenders can see its holder is alive.
pub(super) fn refresh_lock_liveness(lock_path: &Path) {
    let _ = std::fs::File::options()
        .write(true)
        .open(lock_path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
}

#[cfg(test)]
mod tests;
