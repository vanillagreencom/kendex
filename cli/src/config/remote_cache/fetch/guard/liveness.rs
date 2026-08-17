//! Who holds a portable lock, whether they are still alive, and what a
//! contender may do about a holder that is not.
//!
//! All of it exists because a lock file outlives the process that made it:
//! without `flock` there is no kernel to release it, so the holder has to keep
//! SAYING it is alive ([`LockHeartbeat`]) and a contender has to be able to
//! tell a dead holder's leftover from a slow one's ([`lock_is_abandoned`]).
//! Taking the guard itself is [`super`]'s.
//!
//! Unused on unix, where [`super::FlockGuard`] is the guard — compiled and
//! exercised by this crate's tests all the same, since no CI lane builds for a
//! target where it is the live implementation.

use super::{Path, PathBuf, REMOTE_CACHE_FETCH_DEADLINE, epoch_now};

/// Keeps a held lock's mtime fresh for as long as its holder is alive.
///
/// This is the whole liveness signal on the portable path. A lock's mtime is
/// what [`lock_is_abandoned`] measures, so anything that stops refreshing it
/// starts looking dead — and the holder is NOT dead for most of a lease: the
/// fetch is the short part, and discovering, hashing and copying the tree, or
/// waiting on a person, is the long one. A heartbeat that ran only while a
/// fetch was in flight left a live reader's lock looking abandoned after
/// [`STALE_LOCK_AFTER`], and a contender took over and `reset --hard` under
/// the read.
///
/// Two bounds it must respect. It cannot outlive its lease: [`Drop`] signals
/// and JOINS, so the thread is gone before the lock file is unlinked. And it
/// cannot keep a process alive: a plain thread does not, so an exit that skips
/// the lease's `Drop` leaves a lock file whose pid is dead — takeable after
/// the staleness window, which is exactly the no-permanent-wedge case.
pub(super) struct LockHeartbeat {
    /// Set under the mutex, announced on the condvar: the thread wakes at
    /// once instead of sleeping out the rest of a beat.
    stop: std::sync::Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// The interval it beats at. Read by the tests that prove the production
    /// path beats at [`LOCK_HEARTBEAT`] rather than a test's own interval.
    #[allow(
        dead_code,
        reason = "fallback implementation for targets no CI lane builds; only the tests read this field"
    )]
    pub(super) beat: std::time::Duration,
}

impl LockHeartbeat {
    /// Start beating for `owner`'s lock at `path`.
    ///
    /// `None` when the thread cannot be spawned: the lock is still exclusive
    /// and still unlinked on drop — it just ages the way it did before, so a
    /// long hold can be taken over. Failing the acquire instead would refuse
    /// installs on a machine that is merely out of threads.
    pub(super) fn start(
        path: PathBuf,
        owner: LockOwner,
        beat: std::time::Duration,
    ) -> Option<Self> {
        let stop = std::sync::Arc::new((std::sync::Mutex::new(false), std::sync::Condvar::new()));
        let signal = std::sync::Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name("vstack-lock-heartbeat".into())
            .spawn(move || {
                let (stopped, wake) = &*signal;
                let mut done = stopped
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                while !*done {
                    done = wake
                        .wait_timeout(done, beat)
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .0;
                    if *done {
                        break;
                    }
                    // Only ours. A lock the file no longer credits us with is
                    // a successor's, and refreshing THAT would keep somebody
                    // else's lock alive on our behalf.
                    if read_lock_owner(&path) != Some(owner) {
                        break;
                    }
                    refresh_lock_liveness(&path);
                }
            })
            .ok()?;
        Some(Self {
            stop,
            thread: Some(thread),
            beat,
        })
    }
}

impl Drop for LockHeartbeat {
    fn drop(&mut self) {
        let (stopped, wake) = &*self.stop;
        {
            let mut done = stopped
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *done = true;
        }
        wake.notify_all();
        // The join is the guarantee: no beat can land after the lease ends.
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// How often a HELD lock's mtime is refreshed. This is the liveness signal
/// behind [`STALE_LOCK_AFTER`]: an unbounded fetch may legitimately run for as
/// long as its user is willing to wait, and the install that follows it holds
/// the same lock for as long as the tree takes to read — only the heartbeat
/// keeps either distinguishable from a dead holder's leftover.
pub(super) const LOCK_HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(30);

/// Refresh the lock's mtime so contenders can see its holder is alive. Never
/// creates the file: a beat that raced its own lease's unlink must not put the
/// lock back.
fn refresh_lock_liveness(lock_path: &Path) {
    let _ = std::fs::File::options()
        .write(true)
        .open(lock_path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
}

/// A lock whose mtime is this old has missed several liveness heartbeats
/// ([`LockHeartbeat`] refreshes it every [`LOCK_HEARTBEAT`] for as long as the
/// lock is HELD — through the fetch, and through the read that follows it), so
/// its holder is presumed dead — and the ownership record is still read back
/// before takeover, so a live holder whose heartbeat is merely late keeps its
/// lock. Only [`super::PortableFetchLock`] needs any of this; where `flock`
/// exists the kernel releases the lock when its holder dies.
pub(super) const STALE_LOCK_AFTER: std::time::Duration =
    std::time::Duration::from_secs(REMOTE_CACHE_FETCH_DEADLINE.as_secs() * 2);

/// The pid + epoch a lock file records about its creator. The pair is the
/// guard's identity: Drop unlinks only a lock that still carries its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct LockOwner {
    pid: u32,
    epoch: u64,
}

/// Create the lock file, recording who holds it. `AlreadyExists` means
/// somebody else does.
pub(super) fn create_lock_file(path: &Path) -> std::io::Result<LockOwner> {
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
pub(super) fn read_lock_owner(path: &Path) -> Option<LockOwner> {
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
pub(super) fn remove_lock_if_owned(path: &Path, owner: LockOwner) -> bool {
    if read_lock_owner(path) == Some(owner) {
        std::fs::remove_file(path).is_ok()
    } else {
        false
    }
}

/// Is the process with this pid still running? `None` when the platform has
/// no way to ask.
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
/// `stale_after` — a held lock is beaten on for its whole lifetime, so a fresh
/// mtime is proof of life and this gate alone answers on every platform. And
/// the recorded holder must not be provably alive, which is belt-and-braces
/// where the platform can tell: a machine so loaded that four beats in a row
/// were missed must not get a live holder's lock stolen out from under it and
/// put two writers in one tree. An UNKNOWN liveness answer never opens the
/// takeover by itself — the stale mtime is what opened it — and it must not
/// close it either, or a crashed holder on a platform with no `kill(0)` would
/// wedge the cache for good.
/// (A recycled pid reads as alive and conservatively delays the takeover
/// until that unrelated process exits — waiting is safe, two writers is not.)
pub(super) fn lock_is_abandoned(path: &Path, stale_after: std::time::Duration) -> bool {
    abandoned_by(path, stale_after, process_is_alive)
}

/// [`lock_is_abandoned`] with the liveness answer supplied, so the verdict a
/// platform WITHOUT one gets is testable where `kill(0)` exists.
pub(super) fn abandoned_by(
    path: &Path,
    stale_after: std::time::Duration,
    liveness: fn(u32) -> Option<bool>,
) -> bool {
    let stale = std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age >= stale_after);
    stale && read_lock_owner(path).is_none_or(|owner| liveness(owner.pid) != Some(true))
}

/// Take over a lock left behind by a holder that died, and say whether THIS
/// caller is the one that took it.
///
/// The take-over is a rename to a unique name, not an unlink: two contenders
/// racing here both try to move the same path, and only one rename can find
/// it, so exactly one of them may go on to create a fresh lock. Unlinking
/// would let both proceed — and would let a slow contender delete a lock that
/// a third process had meanwhile created legitimately.
pub(super) fn take_over_stale_lock(path: &Path, stale_after: std::time::Duration) -> bool {
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

#[cfg(test)]
mod tests;
