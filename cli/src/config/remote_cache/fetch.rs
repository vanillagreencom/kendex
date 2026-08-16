//! Mutating one remote source cache: the exclusion guard, the bounded
//! `git fetch` + `reset`, and the drivers that run them over a lock file.
//!
//! Identity, location and stamp reading live in the parent module.

use super::{
    FetchFailure, FetchStamp, REMOTE_CACHE_FETCH_DEADLINE, REMOTE_CACHE_LOW_SPEED_SECS,
    REMOTE_CACHE_TTL, RemoteCacheProblem, RemoteCacheProblemKind, cached_remote_sources, epoch_now,
    is_under_remote_cache_root, read_fetch_stamp, remote_cache_fetch_due, remote_cache_fetch_lock,
    remote_cache_problem, write_fetch_stamp,
};
use crate::config::LockFile;
use std::path::Path;

/// Exclusive guard over one cache's stamp → fetch → reset.
///
/// It is writer-vs-writer exclusion for an EXISTING cache: every command that
/// fetches and resets one takes it, so two of them can never run in the same
/// tree. The initial clone is not covered (there is no `.git` to lock yet),
/// and readers do not take it.
///
/// On unix the exclusion is a `flock(LOCK_EX | LOCK_NB)` on a lock file inside
/// `.git/`: the kernel releases it when the holder exits, so a crashed holder
/// leaves nothing stale behind and there is no staleness heuristic for two
/// contenders to race on. The lock file is never unlinked — unlinking a
/// flocked path lets a second waiter lock a file nobody else can see.
/// Elsewhere the lock file's `create_new` IS the lock, and Drop removes it.
pub(super) struct RemoteCacheFetchGuard {
    #[cfg(unix)]
    #[allow(dead_code)]
    file: std::fs::File,
    #[cfg(not(unix))]
    path: PathBuf,
    /// The record written into the lock file; Drop's proof it is still ours.
    #[cfg(not(unix))]
    owner: LockOwner,
}

/// Result of trying to take the guard.
pub(super) enum GuardAcquire {
    Held(RemoteCacheFetchGuard),
    /// Another process is fetching this cache right now.
    Busy,
    /// The lock file itself cannot be created (permissions).
    Unusable(String),
}

impl RemoteCacheFetchGuard {
    #[cfg(unix)]
    pub(super) fn acquire(cache_dir: &Path) -> GuardAcquire {
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

    /// Without `flock`, creating the lock file IS taking the lock, so it must
    /// not be pre-created: `create_new` is the whole mechanism. A holder that
    /// is killed leaves its file behind, and nothing else would ever remove
    /// it — so a lock whose holder is provably gone is taken over, by exactly
    /// one contender.
    #[cfg(not(unix))]
    pub(super) fn acquire(cache_dir: &Path) -> GuardAcquire {
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

#[cfg(not(unix))]
impl Drop for RemoteCacheFetchGuard {
    fn drop(&mut self) {
        remove_lock_if_owned(&self.path, self.owner);
    }
}

/// A lock whose mtime is this old has missed several liveness heartbeats
/// ([`LOCK_HEARTBEAT`] refreshes it while a fetch runs, bounded or not), so
/// its holder is presumed dead — and the ownership record is still read back
/// before takeover, so a live holder whose heartbeat is merely late keeps its
/// lock. Only the platforms without `flock` need any of this; elsewhere the
/// kernel releases the lock when its holder dies.
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

/// What one call to [`fetch_remote_cache`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchAttempt {
    /// The fetch ran; `true` when the cache now matches its remote.
    Attempted(bool),
    /// The cache was already fresh enough for the caller's bound.
    Fresh,
    /// Another process holds the guard; nothing was done.
    Busy,
    /// The cache cannot be locked or stamped.
    Unwritable(String),
    /// The path is not a cache directory. Nothing was run.
    OutOfCacheRoot,
}

/// Fetch + reset one cache under the guard, recording the outcome in the
/// stamp. This is the only place an EXISTING cache is mutated: `add`,
/// `refresh`, the TUI and the background `cache-refresh` all route through
/// it, so the guard, the bound and the stamp are one mechanism rather than
/// four. (The initial clone in `add` creates a cache rather than mutating
/// one, and runs before there is a `.git` to lock.)
///
/// `max_age` is re-checked INSIDE the guard, so a second caller that queued
/// behind a fetch sees its fresh stamp and skips instead of fetching again.
pub fn fetch_remote_cache(
    cache_dir: &Path,
    max_age: Option<std::time::Duration>,
    bound: FetchBound,
) -> FetchAttempt {
    // Nothing outside the cache root is ever fetched or reset — see
    // [`is_under_remote_cache_root`]. This runs before any git process
    // exists, so a mistaken caller cannot mutate anything at all.
    if !is_under_remote_cache_root(cache_dir) {
        return FetchAttempt::OutOfCacheRoot;
    }
    let guard = match RemoteCacheFetchGuard::acquire(cache_dir) {
        GuardAcquire::Held(guard) => guard,
        GuardAcquire::Busy => return FetchAttempt::Busy,
        GuardAcquire::Unusable(reason) => return FetchAttempt::Unwritable(reason),
    };
    if !remote_cache_fetch_due(cache_dir, max_age) {
        return FetchAttempt::Fresh;
    }
    // Mark the attempt in flight before running it: the mtime rate-limits a
    // holder that crashes mid-fetch, and readers know not to call it failed.
    let first_failure = match read_fetch_stamp(cache_dir) {
        Some(FetchStamp::Failed { first, .. }) => Some(first),
        Some(FetchStamp::Pending { first_failure }) => first_failure,
        _ => None,
    };
    if let Err(err) = write_fetch_stamp(cache_dir, FetchStamp::Pending { first_failure }) {
        return FetchAttempt::Unwritable(err.to_string());
    }

    let mut command = git_in_cache(cache_dir);
    if let Some(deadline) = bound.deadline() {
        // A bounded fetch has nobody available to answer a prompt.
        suppress_git_prompts(&mut command);
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
    command
        .args(["fetch", "origin", "--quiet"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
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
    let failure = failure.or_else(|| {
        // Local, fast, and pointless to bound: the network is already done.
        git_in_cache(cache_dir)
            .args(["reset", "--hard", "origin/HEAD", "--quiet"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
            .then_some(())
            .map_or(Some(FetchFailure::Reset), |()| None)
    });

    let now = epoch_now();
    let stamp = match failure {
        None => FetchStamp::Ok,
        Some(cause) => FetchStamp::Failed {
            first: first_failure.unwrap_or(now),
            last: now,
            cause: Some(cause),
        },
    };
    if let Err(err) = write_fetch_stamp(cache_dir, stamp) {
        return FetchAttempt::Unwritable(err.to_string());
    }
    drop(guard);
    FetchAttempt::Attempted(failure.is_none())
}

/// Every environment variable that can point git at a repository, an index,
/// an object store, or injected configuration. A vstack process inherits its
/// caller's environment, and the detached refresh child inherits vstack's, so
/// any of these silently redirects a cache mutation at somebody else's data —
/// `GIT_INDEX_FILE` alone is enough to write a cache's tree into another
/// repository's index and leave it unusable.
const INHERITED_GIT_REPOSITORY_ENV: [&str; 12] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_GRAFT_FILE",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
];

/// A git invocation for cache work: nothing inherited may redirect it at
/// another repository.
///
/// Prompting is NOT decided here: an unbounded `add`/`refresh` is a user at a
/// terminal who may well want to type a credential, while a bounded fetch has
/// nobody to answer one — [`suppress_git_prompts`] is applied per call site.
pub(crate) fn git_command_for_cache() -> std::process::Command {
    let mut command = std::process::Command::new("git");
    for key in INHERITED_GIT_REPOSITORY_ENV {
        command.env_remove(key);
    }
    command
}

/// Forbid this git invocation from stopping to ask a human anything.
///
/// Applied to every BOUNDED fetch: the detached refresh child has no terminal
/// and would otherwise raise a GUI askpass dialog at session start or block
/// on a prompt nobody can answer, and the TUI's short fetch runs under a raw
/// terminal a prompt would corrupt. Unbounded interactive fetches keep git's
/// normal prompting.
fn suppress_git_prompts(command: &mut std::process::Command) {
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_ASKPASS")
        .env_remove("DISPLAY");
}

/// A cache git invocation PINNED to this cache.
///
/// Without `GIT_DIR`/`GIT_WORK_TREE`, git walks up from its working
/// directory looking for a repository: a cache whose `.git` is damaged (or
/// merely not a repository yet) would silently resolve to whatever repo
/// encloses the cache root, and `reset --hard origin/HEAD` would then rewrite
/// THAT working tree. Pinning both makes a broken cache fail as a broken
/// cache. `GIT_CEILING_DIRECTORIES` is belt and braces for any git that still
/// tries to discover.
fn git_in_cache(cache_dir: &Path) -> std::process::Command {
    let mut command = git_command_for_cache();
    command
        .current_dir(cache_dir)
        .env("GIT_DIR", cache_dir.join(".git"))
        .env("GIT_WORK_TREE", cache_dir)
        .env("GIT_CEILING_DIRECTORIES", cache_dir);
    command
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
    for (source, cache_dir) in cached_remote_sources(lock) {
        let kind = match fetch_remote_cache(&cache_dir, max_age, bound) {
            // A fetch in flight elsewhere is not a failure; stay quiet.
            FetchAttempt::Busy => None,
            FetchAttempt::Unwritable(reason) => Some(RemoteCacheProblemKind::Unwritable { reason }),
            // Unreachable for a directory this function itself resolved, but
            // reported rather than swallowed if the invariant ever breaks.
            FetchAttempt::OutOfCacheRoot => Some(RemoteCacheProblemKind::Unwritable {
                reason: format!("{} is not a cache directory", cache_dir.display()),
            }),
            FetchAttempt::Attempted(_) | FetchAttempt::Fresh => remote_cache_problem(&cache_dir),
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
