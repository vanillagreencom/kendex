//! The whole-lock refresh drivers: bringing every cache a lock names up to
//! date, and handing that job to a detached process when the caller must not
//! wait on the network.
//!
//! One cache's fetch, its exclusion guard and its lease are [`super`]'s; this
//! is what a lock's worth of them adds up to and who runs it.

use super::*;

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
    let LockRemotes { present, refused } = cached_remote_sources(lock);
    // A source whose remote cannot be established can never be refreshed, so
    // it belongs in this function's answer rather than in its silence.
    for (source, reason) in refused {
        problems.push(RemoteCacheProblem {
            source,
            kind: RemoteCacheProblemKind::Refused { reason },
        });
    }
    for (source, remote) in present {
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
