//! Mutating one remote source cache: the exclusion guard, the bounded
//! `git fetch` + `reset`, and the drivers that run them over a lock file.
//!
//! Stamp reading lives in the parent module. Every git process here is built
//! by [`crate::refresh_sources`], and every ownership question about the entry
//! is answered there too — this module owns the exclusion, the bound and the
//! record of what happened, and nothing else.

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
use std::path::{Path, PathBuf};

/// Exclusive guard over one cache's stamp → fetch → reset.
///
/// It is writer-vs-writer exclusion for an EXISTING cache: every command that
/// fetches and resets one takes it, so two of them can never run in the same
/// tree. The initial clone is not covered (there is no `.git` to lock yet),
/// and readers do not take it.
///
/// Two independent implementations, and the platform picks one. They are
/// separate types rather than `cfg` arms of a single struct so that the
/// portable one is COMPILED AND RUN by `cargo test` on unix: a branch no
/// build here ever type-checks is a branch nobody can trust.
#[cfg(unix)]
pub(super) type RemoteCacheFetchGuard = FlockGuard;
#[cfg(not(unix))]
pub(super) type RemoteCacheFetchGuard = PortableFetchLock;

/// Result of trying to take a guard.
pub(super) enum GuardAcquire<G> {
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
pub(super) struct FlockGuard {
    #[allow(dead_code)]
    file: std::fs::File,
}

#[cfg(unix)]
impl FlockGuard {
    pub(super) fn acquire(cache_dir: &Path) -> GuardAcquire<Self> {
        use std::os::unix::io::AsRawFd;
        let path = remote_cache_fetch_lock(cache_dir);
        let file = match std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
        {
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
            // process dies — so a crashed holder never leaves it stuck.
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

/// Without `flock`, creating the lock file IS taking the lock, so it must not
/// be pre-created: `create_new` is the whole mechanism. Drop unlinks it, and
/// only while it still records this holder. A holder that is killed leaves its
/// file behind, and nothing else would ever remove it — so a lock whose holder
/// is provably gone is taken over, by exactly one contender.
#[allow(dead_code)]
pub(super) struct PortableFetchLock {
    path: PathBuf,
    /// The record written into the lock file; Drop's proof it is still ours.
    owner: LockOwner,
}

#[allow(dead_code)]
impl PortableFetchLock {
    pub(super) fn acquire(cache_dir: &Path) -> GuardAcquire<Self> {
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

/// Take over a lock left behind by a holder that died, and say whether THIS
/// caller is the one that took it.
///
/// Two gates, both required. The mtime must have outlived the heartbeat by
/// [`STALE_LOCK_AFTER`] — a live fetch, bounded or unbounded, keeps touching
/// its lock, so a fresh mtime is proof of life. And the recorded holder must
/// not be provably alive: a slow machine's late heartbeat must not get a live
/// fetch's lock stolen out from under it and put two writers in one tree.
/// (A recycled pid reads as alive and conservatively delays the takeover
/// until that unrelated process exits — waiting is safe, two writers is not.)
///
/// The take-over is a rename to a unique name, not an unlink: two contenders
/// racing here both try to move the same path, and only one rename can find
/// it, so exactly one of them may go on to create a fresh lock. Unlinking
/// would let both proceed — and would let a slow contender delete a lock that
/// a third process had meanwhile created legitimately.
#[allow(dead_code)]
fn take_over_stale_lock(path: &Path, stale_after: std::time::Duration) -> bool {
    let stale = std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age >= stale_after);
    if !stale {
        return false;
    }
    if let Some(owner) = read_lock_owner(path)
        && process_is_alive(owner.pid) == Some(true)
    {
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

/// How long a fetch may run. `Bounded` carries its own deadline because the
/// two bounded callers want very different ones: the detached background
/// child can afford a full minute since nobody is waiting on it, while an
/// interactive path must not hold a terminal for more than a few seconds.
/// `add` and `refresh` are [`Unbounded`](Self::Unbounded) — a user asked for
/// that specific fetch and expects it to finish.
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
/// fetching again.
pub fn fetch_remote_cache(
    remote: &RemoteSource,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
) -> anyhow::Result<FetchAttempt> {
    let cache_dir = remote.cache_dir.as_path();
    if !remote_cache_fetch_due(cache_dir, max_age) {
        return Ok(FetchAttempt::Fresh);
    }
    // Before anything is written: this entry must be vstack's own clone of
    // THIS repository. Reads only, and it refuses rather than repairs.
    ensure_cache_entry_is_owned(remote)?;

    let guard = match RemoteCacheFetchGuard::acquire(cache_dir) {
        GuardAcquire::Held(guard) => guard,
        GuardAcquire::Busy => return Ok(FetchAttempt::Busy),
        GuardAcquire::Unusable(reason) => return Ok(FetchAttempt::Unwritable(reason)),
    };
    if !remote_cache_fetch_due(cache_dir, max_age) {
        return Ok(FetchAttempt::Fresh);
    }
    // Mark the attempt in flight before running it: the mtime rate-limits a
    // holder that crashes mid-fetch, and readers know not to call it failed.
    let first_failure = match read_fetch_stamp(cache_dir) {
        Some(FetchStamp::Failed { first, .. }) => Some(first),
        Some(FetchStamp::Pending { first_failure }) => first_failure,
        _ => None,
    };
    if let Err(err) = write_fetch_stamp(cache_dir, FetchStamp::Pending { first_failure }) {
        return Ok(FetchAttempt::Unwritable(err.to_string()));
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
            return Ok(FetchAttempt::Unwritable(err.to_string()));
        }
        drop(guard);
        // A failed fetch is tolerated: the clone is still the requested source
        // at an older revision.
        return Ok(FetchAttempt::FetchFailed(git_error_summary(&stderr, &[])));
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
        drop(guard);
        anyhow::bail!(
            "git reset failed for cached source {}: {summary}",
            remote.display
        );
    }
    if let Err(err) = record(None) {
        return Ok(FetchAttempt::Unwritable(err.to_string()));
    }
    drop(guard);
    Ok(FetchAttempt::Updated)
}

enum FetchWait {
    Ok,
    Failed,
    TimedOut,
}

/// How often a running fetch refreshes its lock file's mtime. This is the
/// liveness signal behind [`STALE_LOCK_AFTER`]: an unbounded fetch may
/// legitimately run for as long as its user is willing to wait, and only the
/// heartbeat keeps its lock distinguishable from a dead holder's.
const LOCK_HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(30);

/// Refresh the lock's mtime so contenders can see its holder is alive.
fn refresh_lock_liveness(lock_path: &Path) {
    let _ = std::fs::File::options()
        .write(true)
        .open(lock_path)
        .and_then(|file| file.set_modified(std::time::SystemTime::now()));
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
        let kind = match fetch_remote_cache(&remote, max_age, bound) {
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
