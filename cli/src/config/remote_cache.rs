//! What the last fetch attempt on a remote source cache left behind, and
//! which of this machine's caches a lock file names. Everything here reads
//! disk; nothing here mutates a cache.
//!
//! WHICH directory a source's cache is, whether git may be pointed at it, and
//! what URL it is fetched from are [`crate::refresh_sources::RemoteSource`]'s
//! answers, never this module's — a source becomes a display string, a git URL
//! and a cache key in exactly one place.
//!
//! Fetching, the exclusion guard around it, and the refresh drivers live in
//! [`fetch`].

use super::LockFile;
use crate::refresh_sources::{RemoteSource, cache_entry_present};
use std::path::{Path, PathBuf};

mod fetch;
#[cfg(test)]
mod test_support;

pub use fetch::{
    CacheLease, FetchBound, lease_cached_source, lease_remote_cache, refresh_remote_caches,
    refresh_remote_caches_older_than, remote_cache_fetch_in_flight, spawn_detached_cache_refresh,
};
use fetch::{GuardAcquire, RemoteCacheFetchGuard};

/// How long a remote source cache is trusted before a refresh becomes due.
/// `check` never fetches on its own thread — it hands a due cache to a
/// detached background process — so this is the rate limit on that spawn.
pub const REMOTE_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// A failure run that has outlived two whole retry windows is no longer a
/// transient offline blip, so `check` counts it as drift. Derived from the
/// TTL so the "2x" every doc states cannot drift from the code.
pub const REMOTE_CACHE_FAILURE_IS_DRIFT: std::time::Duration =
    std::time::Duration::from_secs(REMOTE_CACHE_TTL.as_secs() * 2);

/// Wall-clock bound on one bounded fetch. Nothing waits on a bounded fetch
/// any more — `check` spawns it detached — so this exists only to stop a
/// background process from living forever. It is THE bound: git's low-speed
/// abort is set strictly below it so that knob can actually fire first, and
/// it holds for ssh remotes, where no `http.*` setting applies at all.
const REMOTE_CACHE_FETCH_DEADLINE: std::time::Duration = std::time::Duration::from_secs(60);

/// git aborts a transfer that stays under `lowSpeedLimit` bytes/s for this
/// long. Strictly below the wall-clock deadline, or it could never fire.
const REMOTE_CACHE_LOW_SPEED_SECS: u64 = 30;

/// Stamp file recording the last fetch ATTEMPT for a cached remote source.
/// It lives inside `.git/` so `reset --hard` and `clean` never touch it, and
/// it is written before the attempt too — an offline attempt must not retry
/// every session until the TTL passes. Its content distinguishes a fetch in
/// flight from a real failure, carries the FIRST failure of the current run
/// so a permanently broken remote can be told from a blip, and names the
/// cause so the report can say what actually went wrong.
fn remote_cache_fetch_stamp(cache_dir: &Path) -> PathBuf {
    cache_dir.join(".git").join("vstack-fetch-stamp")
}

fn remote_cache_fetch_lock(cache_dir: &Path) -> PathBuf {
    cache_dir.join(".git").join("vstack-fetch.lock")
}

/// Why a fetch attempt did not leave the cache up to date.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchFailure {
    /// `git fetch` returned non-zero (network, auth, renamed repo).
    Fetch,
    /// The fetch worked but `reset --hard origin/HEAD` did not.
    Reset,
    /// No `git` on PATH.
    GitMissing,
    /// Killed at the wall-clock deadline.
    TimedOut,
    /// A previous attempt was killed before it recorded anything.
    Interrupted,
}

impl FetchFailure {
    fn token(self) -> &'static str {
        match self {
            Self::Fetch => "fetch",
            Self::Reset => "reset",
            Self::GitMissing => "git-missing",
            Self::TimedOut => "timeout",
            Self::Interrupted => "interrupted",
        }
    }

    fn parse(token: &str) -> Option<Self> {
        match token {
            "fetch" => Some(Self::Fetch),
            "reset" => Some(Self::Reset),
            "git-missing" => Some(Self::GitMissing),
            "timeout" => Some(Self::TimedOut),
            "interrupted" => Some(Self::Interrupted),
            _ => None,
        }
    }

    /// One clause naming the cause, for the drift report.
    pub fn describe(self) -> &'static str {
        match self {
            Self::Fetch => "git fetch failed",
            Self::Reset => "git reset failed",
            Self::GitMissing => "git was not found",
            Self::TimedOut => "the fetch timed out",
            Self::Interrupted => "the fetch was interrupted",
        }
    }
}

/// Recorded state of a cache's fetch attempts. Epochs are seconds since the
/// UNIX epoch; mtime is not enough because it only records the LAST attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FetchStamp {
    /// The last attempt succeeded.
    Ok,
    /// An attempt is in flight. Carries the first failure of the run it is
    /// retrying, so a later verdict does not lose it.
    Pending { first_failure: Option<u64> },
    /// Attempts have been failing since `first`; the last was at `last`.
    Failed {
        first: u64,
        last: u64,
        cause: Option<FetchFailure>,
    },
}

fn epoch_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

fn age_since(epoch: u64) -> std::time::Duration {
    std::time::Duration::from_secs(epoch_now().saturating_sub(epoch))
}

fn read_fetch_stamp(cache_dir: &Path) -> Option<FetchStamp> {
    let content = std::fs::read_to_string(remote_cache_fetch_stamp(cache_dir)).ok()?;
    let mut fields = content.split_whitespace();
    match fields.next()? {
        "ok" => Some(FetchStamp::Ok),
        "pending" => Some(FetchStamp::Pending {
            first_failure: fields.next().and_then(|f| f.parse().ok()),
        }),
        "failed" => {
            let first = fields.next()?.parse().ok()?;
            let last = fields.next().and_then(|f| f.parse().ok()).unwrap_or(first);
            let cause = fields.next().and_then(FetchFailure::parse);
            Some(FetchStamp::Failed { first, last, cause })
        }
        _ => None,
    }
}

fn write_fetch_stamp(cache_dir: &Path, stamp: FetchStamp) -> std::io::Result<()> {
    let content = match stamp {
        FetchStamp::Ok => "ok\n".to_string(),
        FetchStamp::Pending {
            first_failure: None,
        } => "pending\n".to_string(),
        FetchStamp::Pending {
            first_failure: Some(first),
        } => format!("pending {first}\n"),
        FetchStamp::Failed {
            first,
            last,
            cause: None,
        } => format!("failed {first} {last}\n"),
        FetchStamp::Failed {
            first,
            last,
            cause: Some(cause),
        } => format!("failed {first} {last} {}\n", cause.token()),
    };
    std::fs::write(remote_cache_fetch_stamp(cache_dir), content)
}

/// Record a fresh clone as an up-to-date fetch.
///
/// A clone IS the newest possible fetch, but it writes no stamp of its own,
/// and [`remote_cache_fetch_due`] reads an unstamped cache as due — so
/// without this the very next `check` spawns a background refresh of a clone
/// made seconds ago. Best-effort: a cache that cannot be stamped is only
/// refreshed more often than it needs to be, never wrong.
pub fn record_cache_clone(cache_dir: &Path) {
    let _ = write_fetch_stamp(cache_dir, FetchStamp::Ok);
}

/// True when the cache has not been fetched within `max_age`. `None` means
/// always due.
pub fn remote_cache_fetch_due(cache_dir: &Path, max_age: Option<std::time::Duration>) -> bool {
    let Some(max_age) = max_age else {
        return true;
    };
    let Ok(meta) = std::fs::metadata(remote_cache_fetch_stamp(cache_dir)) else {
        return true;
    };
    let Ok(modified) = meta.modified() else {
        return true;
    };
    // A future mtime (clock skew) counts as fresh: `elapsed()` errors, and
    // treating that as due would refetch on every call until the clock passes it.
    modified.elapsed().is_ok_and(|age| age >= max_age)
}

/// Why a remote source cache could not be brought up to date.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteCacheProblemKind {
    /// Fetch attempts have been failing since `failing_for` ago; the most
    /// recent attempt was `last_attempt` ago and failed for `cause`.
    Failing {
        failing_for: std::time::Duration,
        last_attempt: std::time::Duration,
        cause: Option<FetchFailure>,
    },
    /// The cache cannot be locked or stamped at all (permissions on `.git`).
    /// It can never refresh itself, so this is reported the first time.
    Unwritable { reason: String },
    /// The entry is not vstack's own clone of this source, so it was neither
    /// fetched nor reset. Only a human removing the entry clears it.
    Refused { reason: String },
}

impl RemoteCacheProblemKind {
    /// True when the problem has outlived [`REMOTE_CACHE_FAILURE_IS_DRIFT`] or
    /// cannot resolve itself at all. A single offline session stays quiet.
    pub fn is_persistent(&self) -> bool {
        match self {
            Self::Failing { failing_for, .. } => *failing_for >= REMOTE_CACHE_FAILURE_IS_DRIFT,
            Self::Unwritable { .. } | Self::Refused { .. } => true,
        }
    }
}

/// One cache's problem, tagged with the lock `source` string it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteCacheProblem {
    pub source: String,
    pub kind: RemoteCacheProblemKind,
}

/// The problem recorded for a cache, or None when the last attempt succeeded,
/// none was ever made, or one is in flight right now.
///
/// Reading is all this does in the ordinary case. The ONE exception is an
/// abandoned attempt: a `Pending` stamp older than the fetch deadline whose
/// guard is free belongs to a process that was killed before it could record
/// anything, and converting it to a failure (a single small write, under the
/// guard) is what stops an externally killed fetch from buying silence for a
/// whole TTL.
pub fn remote_cache_problem(cache_dir: &Path) -> Option<RemoteCacheProblemKind> {
    match read_fetch_stamp(cache_dir)? {
        FetchStamp::Ok => None,
        FetchStamp::Pending { .. } => {
            if !remote_cache_fetch_due(cache_dir, Some(REMOTE_CACHE_FETCH_DEADLINE)) {
                return None; // plausibly still running
            }
            let guard = match RemoteCacheFetchGuard::acquire(cache_dir) {
                GuardAcquire::Held(guard) => guard,
                // Still held: a fetch really is in flight, whatever the age.
                GuardAcquire::Busy => return None,
                GuardAcquire::Unusable(reason) => {
                    return Some(RemoteCacheProblemKind::Unwritable { reason });
                }
            };
            // Re-read under the guard. Waiting for it takes time, and the
            // fetch we were about to condemn may have finished and written
            // its own verdict in the meantime; overwriting THAT would record
            // an up-to-date cache as failing since the attempt began.
            let (first_failure, started) = match read_fetch_stamp(cache_dir) {
                Some(FetchStamp::Pending { first_failure })
                    if remote_cache_fetch_due(cache_dir, Some(REMOTE_CACHE_FETCH_DEADLINE)) =>
                {
                    (first_failure, stamp_epoch(cache_dir))
                }
                // Somebody finished while we waited: report what they wrote.
                Some(fresh) => {
                    drop(guard);
                    return problem_from_stamp(fresh);
                }
                None => {
                    drop(guard);
                    return None;
                }
            };
            // The abandoned attempt's own mtime is when it last happened, so
            // the TTL measures from the attempt rather than from this read.
            let last = started.unwrap_or_else(epoch_now);
            let first = first_failure.unwrap_or(last);
            let _ = write_fetch_stamp(
                cache_dir,
                FetchStamp::Failed {
                    first,
                    last,
                    cause: Some(FetchFailure::Interrupted),
                },
            );
            // The write above reset the FILE mtime to now — and dueness
            // ([`remote_cache_fetch_due`]) reads the mtime, not the recorded
            // `last`, so leaving it would defer the next refresh a full TTL
            // from this OBSERVATION rather than from the attempt. Put the
            // mtime back where the attempt left it.
            let _ = std::fs::File::options()
                .write(true)
                .open(remote_cache_fetch_stamp(cache_dir))
                .and_then(|file| {
                    file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(last))
                });
            drop(guard);
            Some(RemoteCacheProblemKind::Failing {
                failing_for: age_since(first),
                last_attempt: age_since(last),
                cause: Some(FetchFailure::Interrupted),
            })
        }
        stamp => problem_from_stamp(stamp),
    }
}

fn problem_from_stamp(stamp: FetchStamp) -> Option<RemoteCacheProblemKind> {
    match stamp {
        FetchStamp::Ok | FetchStamp::Pending { .. } => None,
        FetchStamp::Failed { first, last, cause } => Some(RemoteCacheProblemKind::Failing {
            failing_for: age_since(first),
            last_attempt: age_since(last),
            cause,
        }),
    }
}

/// When the stamp was last written, as an epoch.
fn stamp_epoch(cache_dir: &Path) -> Option<u64> {
    std::fs::metadata(remote_cache_fetch_stamp(cache_dir))
        .and_then(|meta| meta.modified())
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|since| since.as_secs())
}

/// Can this cache record anything at all? A cache whose `.git` cannot be
/// written never produces a stamp, so nothing else on the read path would
/// ever notice it — the refresh would simply be re-attempted, and fail
/// silently, at every session start forever.
fn cache_unwritable_reason(cache_dir: &Path) -> Option<String> {
    // A probe file rather than the lock or the stamp: writing the stamp would
    // fake a fresh attempt and suppress the next refresh, and creating the
    // lock would take it.
    let probe = cache_dir.join(".git").join("vstack-write-probe");
    match std::fs::File::create(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            None
        }
        Err(err) => Some(err.to_string()),
    }
}

/// Why the next refresh of this cache cannot record its outcome, if it
/// cannot. The refresh needs to REWRITE the stamp and OPEN the lock, so the
/// probe covers those actual files when they exist — a read-only stamp under
/// a writable `.git` would otherwise pass a directory probe while every
/// refresh silently fails to record anything, leaving a stale `ok` trusted
/// forever. Opening for write without truncating alters no content, fakes no
/// attempt, and takes no lock; the paths that would have to be CREATED are
/// covered by the directory probe.
fn cache_refresh_unwritable_reason(cache_dir: &Path) -> Option<String> {
    for path in [
        remote_cache_fetch_stamp(cache_dir),
        remote_cache_fetch_lock(cache_dir),
    ] {
        if !path.exists() {
            continue;
        }
        if let Err(err) = std::fs::OpenOptions::new().write(true).open(&path) {
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            return Some(format!("{name}: {err}"));
        }
    }
    cache_unwritable_reason(cache_dir)
}

/// Every distinct lock source whose clone is on this machine, as the remote
/// it names. Pure disk reads — no git process, so the session-start report
/// never starts one.
///
/// Which entry belongs to a source is [`RemoteSource::parse`]'s answer, not
/// this module's, so an entry a fetch mutates and an entry a report reads can
/// never be two different directories. A source that parse REFUSES is not
/// listed: it has no entry vstack would use, and the refusal is reported by
/// the resolution path that names it.
pub(crate) fn cached_remote_sources(lock: &LockFile) -> Vec<(String, RemoteSource)> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        if let Ok(Some(remote)) = RemoteSource::parse(&entry.source)
            && cache_entry_present(&remote)
        {
            out.push((entry.source.clone(), remote));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// Problems recorded on disk for this lock's caches, without fetching
/// anything. This is what the session-start check reports: the news is at
/// most one refresh late, and a permanently broken remote still surfaces.
pub(crate) fn recorded_remote_cache_problems(lock: &LockFile) -> Vec<RemoteCacheProblem> {
    let mut problems: Vec<RemoteCacheProblem> = cached_remote_sources(lock)
        .into_iter()
        .filter_map(|(source, remote)| {
            let dir = remote.cache_dir;
            let kind = remote_cache_problem(&dir).or_else(|| {
                // Nothing recorded as failing. When a refresh is DUE, the
                // stamp and lock are about to be needed — and a cache whose
                // stamp or lock cannot be written can never record anything,
                // so its refreshes would fail silently at every session
                // start forever, with a stale `ok` (or no stamp at all)
                // trusted the whole time. Not due means nothing will write,
                // so there is nothing to probe.
                if !remote_cache_fetch_due(&dir, Some(REMOTE_CACHE_TTL)) {
                    return None;
                }
                cache_refresh_unwritable_reason(&dir)
                    .map(|reason| RemoteCacheProblemKind::Unwritable { reason })
            })?;
            Some(RemoteCacheProblem { source, kind })
        })
        .collect();
    problems.sort_by(|a, b| a.source.cmp(&b.source));
    problems
}

/// True when any of this lock's caches is due for a refresh.
pub(crate) fn any_remote_cache_due(lock: &LockFile, max_age: Option<std::time::Duration>) -> bool {
    cached_remote_sources(lock)
        .iter()
        .any(|(_, remote)| remote_cache_fetch_due(&remote.cache_dir, max_age))
}

#[cfg(test)]
mod tests;
