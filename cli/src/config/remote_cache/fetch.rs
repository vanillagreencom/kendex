//! Mutating one remote source cache: the bounded `git fetch` + `reset`, the
//! lease a reader holds over it, and the drivers that run them.
//!
//! Stamp reading lives in the parent module and the exclusion itself in
//! [`guard`]. Every git process here is built by [`crate::refresh_sources`],
//! and every ownership question about the entry is answered there too — this
//! module owns the bound, the lease and the record of what happened, and
//! nothing else.

use super::{
    FetchFailure, FetchStamp, REMOTE_CACHE_FETCH_DEADLINE, REMOTE_CACHE_LOW_SPEED_SECS,
    REMOTE_CACHE_TTL, RemoteCacheProblem, RemoteCacheProblemKind, cached_remote_sources, epoch_now,
    read_fetch_stamp, remote_cache_fetch_due, remote_cache_fetch_lock, remote_cache_problem,
    write_fetch_stamp,
};
use crate::config::LockFile;
use crate::refresh_sources::{
    RemoteSource, ensure_cache_entry_is_owned, git_error_summary, hardened_cache_git_command,
    hardened_git_network_command, point_cache_origin_at,
};
use guard::{LOCK_HEARTBEAT, refresh_lock_liveness};
use std::path::{Path, PathBuf};

mod guard;

pub(super) use guard::{GuardAcquire, RemoteCacheFetchGuard};

/// What the caller does with the cache once this call returns, and therefore
/// what another process holding the guard means for it.
///
/// Not a parameter any caller passes: it is decided by WHICH entry point was
/// called — [`lease_remote_cache`] hands back the lease a reader must keep,
/// [`refresh_remote_cache`] hands back nothing to read with. The two answers
/// are opposites and the permissive one is not safe to inherit: a caller that
/// goes on to install from a tree being `reset --hard` copies whatever bytes
/// it happened to catch and records them as the source's content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CacheAccess {
    /// The caller READS the cache after this returns — discovers it, hashes
    /// it, copies out of it. A tree another process is rewriting is not a
    /// source to install from, so contention is waited out for
    /// [`INSTALL_GUARD_WAIT`] and then refused. Freshness does not short-
    /// circuit this caller either: a holder writes its `pending` stamp before
    /// it starts, which reads as fresh to everyone else. The guard it takes
    /// leaves with the caller as a [`CacheLease`], because the read it
    /// protects begins after this call returns.
    Install,
    /// Nothing reads the tree after this call — it exists only to bring the
    /// cache up to date. Another process already doing that is exactly the
    /// outcome this caller wanted, so it stands down.
    RefreshOnly,
}

/// A read lease on one cached source tree: proof, for as long as the value is
/// alive, that no other vstack process is fetching or resetting it.
///
/// The install path is why it exists. Discovering a source, hashing it and
/// copying out of it all happen AFTER the fetch returns, and a guard released
/// when the fetch ended left exactly that window open: a second `add` could
/// take the guard and `reset --hard` underneath the first one's read, which
/// then records lock hashes for a tree that never existed as a whole. So the
/// fetch hands its guard to the caller that reads, and the read ends when the
/// lease drops.
///
/// [`CacheLease::none`] is the honest answer where there is nothing to hold: a
/// local source directory, or a cache whose lock file could not be created at
/// all (the caller was told so, and warned it is reading a cache it cannot
/// hold still).
#[derive(Clone, Default)]
#[must_use = "the cache is only held still while its lease is alive"]
pub struct CacheLease(Option<std::sync::Arc<HeldLease>>);

impl CacheLease {
    /// No lease is held, and none is owed.
    pub fn none() -> Self {
        Self(None)
    }

    /// Whether this value actually holds a cache still.
    pub fn is_held(&self) -> bool {
        self.0.is_some()
    }
}

impl std::fmt::Debug for CacheLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.0 {
            Some(held) => write!(f, "CacheLease({})", held.key.display()),
            None => f.write_str("CacheLease(none)"),
        }
    }
}

/// One process-wide hold on one cache directory, released when the last
/// [`CacheLease`] naming it drops.
struct HeldLease {
    key: PathBuf,
    /// `Option` only so [`Drop`] can release it while the registry is locked.
    guard: Option<RemoteCacheFetchGuard>,
}

impl Drop for HeldLease {
    fn drop(&mut self) {
        let mut registry = lease_registry();
        // Only our own, now-dead entry: a contender that took the path after
        // us has a live one there, and removing that would let a third caller
        // take a lease this process still holds.
        if registry
            .get(&self.key)
            .is_some_and(|held| held.strong_count() == 0)
        {
            registry.remove(&self.key);
        }
        // Under the registry lock, so nobody can see the path free in the
        // registry while the descriptor holding it is still open.
        drop(self.guard.take());
    }
}

/// Which caches THIS process holds, so it never contends with itself.
///
/// `flock` is per open file description: a second acquire from the same
/// process blocks exactly as another process's would. Two lock entries can
/// spell one remote two ways (`owner/repo` and its URL), and both resolve to
/// this directory — without this, the second would wait out
/// [`INSTALL_GUARD_WAIT`] and then refuse the install over the first one's own
/// lease.
fn lease_registry() -> std::sync::MutexGuard<'static, LeaseRegistry> {
    static REGISTRY: std::sync::OnceLock<std::sync::Mutex<LeaseRegistry>> =
        std::sync::OnceLock::new();
    REGISTRY
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

type LeaseRegistry = std::collections::HashMap<PathBuf, std::sync::Weak<HeldLease>>;

/// A lease, and whether it was already this process's when it was asked for.
struct TakenLease {
    lease: CacheLease,
    /// A reader in this process holds this cache RIGHT NOW. Nothing may fetch
    /// or reset it until that read ends.
    already_held: bool,
}

/// Take a lease on `cache_dir`, on `access`'s terms.
///
/// A lease this process already holds is SHARED with another install and
/// stands a refresher down: the reader that holds it is not finished, and its
/// tree must not be rewritten under it — which is the same answer a refresher
/// gets when the holder is somebody else.
fn acquire_cache_lease(cache_dir: &Path, access: CacheAccess) -> GuardAcquire<TakenLease> {
    let key = cache_dir.to_path_buf();
    if let Some(held) = lease_registry()
        .get(&key)
        .and_then(std::sync::Weak::upgrade)
    {
        return match access {
            CacheAccess::Install => GuardAcquire::Held(TakenLease {
                lease: CacheLease(Some(held)),
                already_held: true,
            }),
            CacheAccess::RefreshOnly => GuardAcquire::Busy,
        };
    }
    // The OS acquire runs WITHOUT the registry locked: an installing caller
    // waits here, and holding the registry across that wait would stop the
    // very lease it is waiting on from being released.
    match acquire_fetch_guard(cache_dir, access) {
        GuardAcquire::Held(guard) => {
            let held = std::sync::Arc::new(HeldLease {
                key: key.clone(),
                guard: Some(guard),
            });
            lease_registry().insert(key, std::sync::Arc::downgrade(&held));
            GuardAcquire::Held(TakenLease {
                lease: CacheLease(Some(held)),
                already_held: false,
            })
        }
        GuardAcquire::Busy => GuardAcquire::Busy,
        GuardAcquire::Unusable(reason) => GuardAcquire::Unusable(reason),
    }
}

/// Whether another vstack process is fetching or resetting this cache RIGHT
/// NOW — asked without taking anything and without waiting for anything.
///
/// This is what a READ-ONLY caller owes the tree it is about to read. It
/// cannot take the lease an installer takes: the session-start check runs on
/// every session and must never wait on somebody else's network fetch, and a
/// reader that held the guard would make a concurrent `add` wait on IT. So it
/// probes instead, and a cache that answers "busy" is reported as temporarily
/// unverifiable rather than measured — a tree mid-`reset --hard` is missing
/// files that exist, and calling those entries removed or outdated is a false
/// verdict with a destructive remedy.
///
/// The probe is a point-in-time answer, and deliberately so: a fetch that
/// starts the instant after it returns is the same fetch the NEXT run reports.
/// What it removes is the case that misleads — a refresh already in flight
/// when the read begins, which is the whole window a detached
/// `vstack cache-refresh` occupies.
///
/// A cache THIS process already holds a lease on is never busy: the lease is
/// itself the proof that nobody else may rewrite the tree, and `flock` is
/// per open file description, so a naive probe would report a process's own
/// install as contention against itself.
pub fn remote_cache_fetch_in_flight(cache_dir: &Path) -> bool {
    // The guard is dropped before the upgrade's own strong reference, so this
    // never runs `HeldLease::drop` while the registry lock is held.
    let held = lease_registry()
        .get(cache_dir)
        .and_then(std::sync::Weak::upgrade);
    if held.is_some() {
        return false;
    }
    RemoteCacheFetchGuard::probe(cache_dir)
}

/// How long an installing caller waits for an in-flight refresh before it
/// refuses. A refresh of a catalog repo is seconds; the bound is what stops a
/// wedged holder from owning a terminal for the whole fetch deadline. Past it
/// the install fails and says to retry, which is recoverable — installing from
/// a half-reset tree is not.
///
/// It is also what makes holding a [`CacheLease`] across a read safe: a
/// `refresh` resolving several remotes holds each lease while it takes the
/// next, so two of them can want each other's caches. Every wait here is
/// bounded and ends in a refusal that names the contention, so the worst case
/// is two runs that both say to retry — never two that wait on each other
/// forever.
const INSTALL_GUARD_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// Take the guard on `access`'s terms.
///
/// An installing caller waits, because the alternative is reading a tree
/// mid-`reset`; a refresher does not, because standing down is exactly what it
/// should do when somebody else is already refreshing.
fn acquire_fetch_guard(
    cache_dir: &Path,
    access: CacheAccess,
) -> GuardAcquire<RemoteCacheFetchGuard> {
    let mut acquired = RemoteCacheFetchGuard::acquire(cache_dir);
    if access == CacheAccess::RefreshOnly {
        return acquired;
    }
    let started = std::time::Instant::now();
    while matches!(acquired, GuardAcquire::Busy) && started.elapsed() < INSTALL_GUARD_WAIT {
        std::thread::sleep(std::time::Duration::from_millis(100));
        acquired = RemoteCacheFetchGuard::acquire(cache_dir);
    }
    acquired
}

/// How long a fetch may run. `Bounded` carries its own deadline because the
/// two bounded callers want very different ones: the detached background
/// child can afford a full minute since nobody is waiting on it, while an
/// interactive path must not hold a terminal for more than a few seconds.
/// A source named on the command line and every `refresh` are
/// [`Unbounded`](Self::Unbounded) — somebody asked for that specific fetch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchBound {
    Bounded(std::time::Duration),
    Unbounded,
}

impl FetchBound {
    /// The background refresh nobody waits on.
    pub const BACKGROUND: Self = Self::Bounded(REMOTE_CACHE_FETCH_DEADLINE);
    /// A refresh a user is watching a terminal for.
    pub const INTERACTIVE: Self = Self::Bounded(std::time::Duration::from_secs(5));

    fn deadline(self) -> Option<std::time::Duration> {
        match self {
            Self::Bounded(deadline) => Some(deadline),
            Self::Unbounded => None,
        }
    }
}

/// What one call to [`fetch_remote_cache`] did. A refusal, a failed reset and
/// a failed origin write are not outcomes here — they are errors, because the
/// entry is then not known to hold this source at any revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchAttempt {
    /// The fetch and reset ran; the cache now matches its remote.
    Updated,
    /// The fetch ran and failed. The clone is still the requested source at an
    /// older revision, so it is kept; carries git's sanitized output.
    FetchFailed(String),
    /// The cache was already fresh enough for the caller's bound.
    Fresh,
    /// Another process holds the guard; nothing was done.
    Busy,
    /// The cache cannot be locked or stamped.
    Unwritable(String),
}

impl FetchAttempt {
    /// Say what the fetch did, for every outcome its caller tolerates. One
    /// place, so a variant can never be silently dropped at one call site and
    /// leave a user installing from a stale cache with no marker.
    ///
    /// Deduped per source: an offline run resolves the same source from the
    /// TUI's startup refresh and again from the top-level resolve.
    pub fn report(self, remote: &RemoteSource) {
        let display = &remote.display;
        let message = match self {
            Self::Updated | Self::Fresh => return,
            Self::FetchFailed(summary) => format!(
                "git fetch failed for cached source {display}: {summary}; using cached version"
            ),
            Self::Busy => format!(
                "another vstack process is refreshing cached source {display} — using cached version"
            ),
            Self::Unwritable(reason) => format!(
                "cached source {display} cannot be refreshed ({reason}) — using cached version"
            ),
        };
        crate::refresh_sources::warn_once(&remote.cache_key, &message);
    }
}

/// Bring a cache up to date for a caller that READS it next, and hand back the
/// lease that keeps it still until that read is done.
///
/// The lease is the API: a caller cannot reach the tree through this function
/// without also receiving the thing that stops another process from rewriting
/// it, and the read ends where the lease drops. Holding it costs other
/// processes nothing they were not already owed — a refresher stands down, and
/// a second install waits [`INSTALL_GUARD_WAIT`] and then refuses, exactly as
/// it did while only the fetch itself was guarded.
pub fn lease_remote_cache(
    remote: &RemoteSource,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
) -> anyhow::Result<(FetchAttempt, CacheLease)> {
    fetch_remote_cache(remote, max_age, bound, CacheAccess::Install)
}

/// Lease a cache the caller has just CREATED, with no fetch of any kind: a
/// clone is already the newest revision there is, and there is no stamp to
/// write that the clone's own does not cover.
///
/// The read that follows is the same read every install does, so it takes the
/// same lease on the same terms — a second install waits and then refuses, a
/// refresher stands down.
pub fn lease_cached_source(remote: &RemoteSource) -> anyhow::Result<(FetchAttempt, CacheLease)> {
    match acquire_cache_lease(&remote.cache_dir, CacheAccess::Install) {
        GuardAcquire::Held(taken) => Ok((FetchAttempt::Fresh, taken.lease)),
        GuardAcquire::Busy => anyhow::bail!(
            "another vstack process is using cached source {} — refusing to install from a cache that may be rewritten mid-read; retry once it finishes",
            remote.display
        ),
        GuardAcquire::Unusable(reason) => {
            Ok((FetchAttempt::Unwritable(reason), CacheLease::none()))
        }
    }
}

/// Bring a cache up to date for a caller that reads nothing out of it
/// afterwards. No lease comes back, because there is no read to protect.
pub fn refresh_remote_cache(
    remote: &RemoteSource,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
) -> anyhow::Result<FetchAttempt> {
    fetch_remote_cache(remote, max_age, bound, CacheAccess::RefreshOnly).map(|(attempt, _)| attempt)
}

/// Fetch + reset one cache under the guard, recording the outcome in the
/// stamp. This is the only place an EXISTING cache is mutated: `add`,
/// `refresh`, the TUI and the background `cache-refresh` all route through
/// it, so the ownership proof, the guard, the bound and the stamp are one
/// mechanism rather than four. (The initial clone in `add` creates a cache
/// rather than mutating one, and runs before there is a `.git` to lock.)
///
/// Which directory is mutated, which URL is fetched and which revision the
/// reset lands on are all `remote`'s — the caller cannot name a path of its
/// own, so nothing outside [`crate::refresh_sources::remote_cache_root`] is
/// reachable from here at all.
///
/// `max_age` is checked before the ownership proof — a cache still inside its
/// TTL costs no git process at all — and again INSIDE the guard, so a second
/// caller that queued behind a fetch sees its fresh stamp and skips instead of
/// fetching again. A [`CacheAccess::Install`] caller skips the cheap first
/// check: it is about to READ this tree, and freshness says nothing about
/// whether somebody is rewriting it right now.
///
/// What an installing caller gets is a tree no other process was rewriting
/// when this returned, plus a stamp written under the guard — and it keeps the
/// guard as a [`CacheLease`], so the tree is still no other process's to
/// rewrite while it is being discovered, hashed and copied. A fresh stamp
/// stands every TTL-gated refresher down; the writers that ignore the TTL are
/// the other installs, and the lease is what they wait on.
fn fetch_remote_cache(
    remote: &RemoteSource,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
    access: CacheAccess,
) -> anyhow::Result<(FetchAttempt, CacheLease)> {
    let cache_dir = remote.cache_dir.as_path();
    if access == CacheAccess::RefreshOnly && !remote_cache_fetch_due(cache_dir, max_age) {
        return Ok((FetchAttempt::Fresh, CacheLease::none()));
    }
    // Before anything is written: this entry must be vstack's own clone of
    // THIS repository. Reads only, and it refuses rather than repairs.
    ensure_cache_entry_is_owned(remote)?;

    let taken = match acquire_cache_lease(cache_dir, access) {
        GuardAcquire::Held(taken) => taken,
        GuardAcquire::Busy => match access {
            CacheAccess::RefreshOnly => return Ok((FetchAttempt::Busy, CacheLease::none())),
            // The caller installs from this tree next. Another process is
            // still fetching, resetting or installing from it, so there is no
            // settled revision to install: refuse, name the contention, and
            // leave the project exactly as it was.
            CacheAccess::Install => anyhow::bail!(
                "another vstack process is using cached source {} — refusing to install from a cache that may be rewritten mid-read; retry once it finishes",
                remote.display
            ),
        },
        // Nothing can be excluded here, and the caller is told: it reads a
        // cache no lease can hold still.
        GuardAcquire::Unusable(reason) => {
            return Ok((FetchAttempt::Unwritable(reason), CacheLease::none()));
        }
    };
    let TakenLease {
        lease,
        already_held,
    } = taken;
    // Somebody in this process is READING this tree right now — its lease is
    // still alive — and this caller is about to as well. Fetching would reset
    // it under that read, and there is nothing to gain: the holder fetched it
    // moments ago, in this same command.
    if already_held || !remote_cache_fetch_due(cache_dir, max_age) {
        return Ok((FetchAttempt::Fresh, lease));
    }
    // Mark the attempt in flight before running it: the mtime rate-limits a
    // holder that crashes mid-fetch, and readers know not to call it failed.
    let first_failure = match read_fetch_stamp(cache_dir) {
        Some(FetchStamp::Failed { first, .. }) => Some(first),
        Some(FetchStamp::Pending { first_failure }) => first_failure,
        _ => None,
    };
    if let Err(err) = write_fetch_stamp(cache_dir, FetchStamp::Pending { first_failure }) {
        return Ok((FetchAttempt::Unwritable(err.to_string()), lease));
    }
    let record = |cause: Option<FetchFailure>| {
        let now = epoch_now();
        let stamp = match cause {
            None => FetchStamp::Ok,
            Some(cause) => FetchStamp::Failed {
                first: first_failure.unwrap_or(now),
                last: now,
                cause: Some(cause),
            },
        };
        write_fetch_stamp(cache_dir, stamp)
    };

    // The URL this invocation selected is the one to fetch over. A write, so
    // it happens under the guard and only once the entry has proved to be
    // vstack's own clone of this repository.
    point_cache_origin_at(remote)?;

    let mut command = hardened_git_network_command(cache_dir)?;
    if let Some(deadline) = bound.deadline() {
        // Strictly inside the wall-clock kill, or the knob could never fire.
        let low_speed = REMOTE_CACHE_LOW_SPEED_SECS
            .min(deadline.as_secs().saturating_sub(1))
            .max(1);
        command.args([
            "-c",
            "http.lowSpeedLimit=1000",
            "-c",
            &format!("http.lowSpeedTime={low_speed}"),
        ]);
    }
    // The remote's own `HEAD`, into a ref only vstack writes — never the
    // entry's stored refspec or its clone-time `origin/HEAD`.
    command
        .args([
            "fetch",
            "origin",
            "--quiet",
            "--force",
            crate::refresh_sources::CACHE_HEAD_REFSPEC,
        ])
        .stdout(std::process::Stdio::null());
    // Captured to a file rather than a pipe: nothing reads a pipe while the
    // deadline is being waited out, and a full pipe buffer would wedge the
    // very fetch this is bounding.
    let stderr_path = cache_dir.join(".git").join("vstack-fetch.err");
    let stderr = std::fs::File::create(&stderr_path).ok();
    match &stderr {
        Some(file) => {
            command.stderr(
                file.try_clone()
                    .map_or_else(|_| std::process::Stdio::null(), std::process::Stdio::from),
            );
        }
        None => {
            command.stderr(std::process::Stdio::null());
        }
    }
    #[cfg(unix)]
    if bound.deadline().is_some() {
        use std::os::unix::process::CommandExt;
        // SAFETY: runs between fork and exec, where only async-signal-safe
        // calls are allowed. `setpgid(0, 0)` is one; it allocates nothing and
        // only makes this child its own process-group leader, which is what
        // lets the deadline kill reach git's transport children too.
        unsafe {
            command.pre_exec(|| {
                libc::setpgid(0, 0);
                // The deadline is enforced by THIS process; if it dies, the
                // fetch it was bounding must not outlive it as an orphan.
                #[cfg(target_os = "linux")]
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL as libc::c_ulong);
                Ok(())
            });
        }
    }
    let failure = match command.spawn() {
        Err(_) => Some(FetchFailure::GitMissing),
        Ok(child) => match wait_for_fetch(child, bound, &remote_cache_fetch_lock(cache_dir)) {
            FetchWait::Ok => None,
            FetchWait::Failed => Some(FetchFailure::Fetch),
            FetchWait::TimedOut => Some(FetchFailure::TimedOut),
        },
    };
    let stderr = std::fs::read(&stderr_path).unwrap_or_default();
    let _ = std::fs::remove_file(&stderr_path);
    if let Some(cause) = failure {
        if let Err(err) = record(Some(cause)) {
            return Ok((FetchAttempt::Unwritable(err.to_string()), lease));
        }
        // A failed fetch is tolerated: the clone is still the requested source
        // at an older revision — and the lease still protects reading it.
        return Ok((
            FetchAttempt::FetchFailed(git_error_summary(&stderr, &[])),
            lease,
        ));
    }

    // Local, fast, and pointless to bound: the network is already done. A
    // failed reset IS an error — the entry no longer matches any revision.
    let reset = hardened_cache_git_command(cache_dir)?
        .args(["reset", "--hard", crate::refresh_sources::CACHE_HEAD_REF])
        .stdout(std::process::Stdio::null())
        .output();
    let reset_failure = match &reset {
        Ok(output) if output.status.success() => None,
        Ok(output) => Some(git_error_summary(&output.stderr, &output.stdout)),
        Err(err) => Some(err.to_string()),
    };
    if let Some(summary) = reset_failure {
        let _ = record(Some(FetchFailure::Reset));
        drop(lease);
        anyhow::bail!(
            "git reset failed for cached source {}: {summary}",
            remote.display
        );
    }
    if let Err(err) = record(None) {
        return Ok((FetchAttempt::Unwritable(err.to_string()), lease));
    }
    Ok((FetchAttempt::Updated, lease))
}

enum FetchWait {
    Ok,
    Failed,
    TimedOut,
}

/// Wait for `child`, killing it at the deadline when bounded. The kill is the
/// real bound: git's `http.*` knobs do nothing for an ssh-cloned cache.
///
/// The whole process GROUP is killed, not just git: git delegates the
/// transfer to `ssh` or `git-remote-https` children, and killing only the
/// parent leaves the transport running with nothing left to bound it.
///
/// While waiting — bounded or not — the cache's lock file gets a
/// [`LOCK_HEARTBEAT`] mtime refresh, so a long-running fetch can never look
/// like a dead holder's leftover to the staleness takeover.
fn wait_for_fetch(
    mut child: std::process::Child,
    bound: FetchBound,
    lock_path: &Path,
) -> FetchWait {
    let deadline = bound.deadline();
    let started = std::time::Instant::now();
    let mut last_beat = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return FetchWait::Ok,
            Ok(Some(_)) => return FetchWait::Failed,
            Ok(None) => {}
            Err(_) => return FetchWait::Failed,
        }
        if let Some(deadline) = deadline
            && started.elapsed() >= deadline
        {
            kill_process_group(&mut child);
            return FetchWait::TimedOut;
        }
        if last_beat.elapsed() >= LOCK_HEARTBEAT {
            refresh_lock_liveness(lock_path);
            last_beat = std::time::Instant::now();
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
}

fn kill_process_group(child: &mut std::process::Child) {
    #[cfg(unix)]
    {
        let pid = child.id() as i32;
        // SAFETY: `kill` with a negative pid signals the process group whose
        // leader is `pid`. The child was made its own group leader in
        // `pre_exec` below, so this reaches git and its transport children
        // and nothing else. It takes no memory and cannot fail destructively;
        // ESRCH (already gone) is ignored.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Refresh cached repos for all remote sources found in installed lock
/// entries. Called at TUI startup so staleness checks see the latest content;
/// bounded, because the user is waiting on a UI, not on this.
///
/// Refresh-only: this brings caches up to date and reads none of them.
/// Everything the TUI later installs from re-resolves through the install
/// path, which takes its own lease.
pub fn refresh_remote_caches(lock: &LockFile) -> Vec<RemoteCacheProblem> {
    // TTL-bounded like every other caller: without it the TUI re-fetched every
    // remote source on every launch — twice, once per scope — and a user
    // offline or behind a dead VPN watched a blank terminal until each fetch
    // hit its deadline.
    refresh_remote_caches_older_than(lock, Some(REMOTE_CACHE_TTL), FetchBound::INTERACTIVE)
}

/// [`refresh_remote_caches`] with a freshness bound: a cache fetched (or
/// attempted) within `max_age` is left alone. `None` always fetches. Returns
/// every cache that is not up to date afterwards — a run of failures with its
/// age and cause, or a cache that cannot be written at all — so callers can
/// report the true state instead of silently trusting stale contents.
pub fn refresh_remote_caches_older_than(
    lock: &LockFile,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
) -> Vec<RemoteCacheProblem> {
    let mut problems = Vec::new();
    for (source, remote) in cached_remote_sources(lock) {
        let kind = match refresh_remote_cache(&remote, max_age, bound) {
            // A cache entry that is not vstack's own, an origin that cannot be
            // written, a reset that did not land: the entry is not known to
            // hold this source, and no later run repairs itself.
            Err(err) => Some(RemoteCacheProblemKind::Refused {
                reason: format!("{err:#}"),
            }),
            // A fetch in flight elsewhere is not a failure; stay quiet.
            Ok(FetchAttempt::Busy) => None,
            Ok(FetchAttempt::Unwritable(reason)) => {
                Some(RemoteCacheProblemKind::Unwritable { reason })
            }
            Ok(FetchAttempt::Updated | FetchAttempt::FetchFailed(_) | FetchAttempt::Fresh) => {
                remote_cache_problem(&remote.cache_dir)
            }
        };
        if let Some(kind) = kind {
            problems.push(RemoteCacheProblem { source, kind });
        }
    }
    problems.sort_by(|a, b| a.source.cmp(&b.source));
    problems
}

/// Hand a due cache refresh to a detached background process and return
/// immediately.
///
/// The session-start check must never wait on the network: it reads what is
/// on disk and, when something is due, spawns `vstack cache-refresh` in its
/// own session with no stdio. Nothing waits on the child, so a slow or
/// unreachable remote cannot delay a session start; its outcome lands in the
/// stamp and the NEXT check reports it.
pub fn spawn_detached_cache_refresh(scope: &str) -> std::io::Result<()> {
    let exe = std::env::current_exe()?;
    let mut command = std::process::Command::new(exe);
    command
        .arg("cache-refresh")
        .arg("--scope")
        .arg(scope)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: the closure runs between fork and exec, where only
        // async-signal-safe calls are allowed. `setsid` is one, allocates
        // nothing, and touches no shared state; its failure (already a
        // session leader) is not fatal, so the error is dropped.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    // The child is deliberately never waited on: this process exits within
    // moments and init reaps it.
    command.spawn().map(|_| ())
}

#[cfg(test)]
mod tests;
