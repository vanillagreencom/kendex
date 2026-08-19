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
//! [`fetch`]; what a recorded state MEANS for a report lives in [`problems`].

use super::LockFile;
use crate::refresh_sources::{RemoteSource, cache_entry_present, remote_for_source};
use std::path::{Path, PathBuf};

mod fetch;
mod problems;
#[cfg(test)]
mod test_support;

pub use fetch::{
    CacheLease, FetchAttempt, FetchBound, lease_cached_source, lease_remote_cache,
    refresh_remote_caches, refresh_remote_caches_older_than, remote_cache_fetch_in_flight,
    spawn_detached_cache_refresh,
};
use fetch::{GuardAcquire, RemoteCacheFetchGuard};
pub(crate) use problems::recorded_remote_cache_problems;
pub use problems::{RemoteCacheProblem, RemoteCacheProblemKind, remote_cache_problem};

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
/// it names, and the ones it must refuse. Local reads only — nothing here
/// fetches, so the session-start report never waits on the network. A source
/// recorded as a path into the cache costs one local `git remote get-url` to
/// establish which remote its entry clones; every other shape is answered from
/// the string alone.
///
/// Which entry belongs to a source is [`remote_for_source`]'s answer, not this
/// module's, so an entry a fetch mutates and an entry a report reads can never
/// be two different directories — including for a source recorded as a path
/// into the cache, which resolves to the remote its entry clones rather than
/// to a local directory nothing ever fetches.
///
/// A refusal is RETURNED rather than dropped. Dropping it made the one command
/// whose entire job is making the caches current — `vstack cache-refresh` —
/// print nothing and exit 0 on a source it could not have refreshed, while
/// `check` and `verify` exited 1 on that same state. Which callers report it
/// is theirs to decide: the refresher owes the user an account of a cache it
/// left un-current, while the session-start report reads recorded disk state
/// and has the refusal already, from the resolution path that names it.
pub(crate) struct LockRemotes {
    /// Distinct lock sources whose clone is on this machine, as the remote
    /// each names, sorted by source.
    pub present: Vec<(String, RemoteSource)>,
    /// Distinct lock sources that name a remote vstack must not use, with the
    /// refusal, sorted by source.
    pub refused: Vec<(String, String)>,
}

pub(crate) fn cached_remote_sources(lock: &LockFile) -> LockRemotes {
    let mut seen = std::collections::HashSet::new();
    let mut present = Vec::new();
    let mut refused = Vec::new();
    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        match remote_for_source(&entry.source) {
            Ok(Some(remote)) if cache_entry_present(&remote) => {
                present.push((entry.source.clone(), remote));
            }
            Ok(_) => {}
            Err(err) => refused.push((entry.source.clone(), format!("{err:#}"))),
        }
    }
    present.sort_by(|a, b| a.0.cmp(&b.0));
    refused.sort_by(|a, b| a.0.cmp(&b.0));
    LockRemotes { present, refused }
}

/// True when any of this lock's caches is due for a refresh.
///
/// A refused source is not due: no fetch of it is possible, so spawning a
/// refresher for one would achieve nothing. It is reported by the resolution
/// path that names it.
pub(crate) fn any_remote_cache_due(lock: &LockFile, max_age: Option<std::time::Duration>) -> bool {
    cached_remote_sources(lock)
        .present
        .iter()
        .any(|(_, remote)| remote_cache_fetch_due(&remote.cache_dir, max_age))
}

#[cfg(test)]
mod tests;
