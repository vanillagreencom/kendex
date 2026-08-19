//! What a cache's recorded state MEANS for a report: the problem kinds, their
//! remedies, and the read that derives one from a stamp.
//!
//! The stamp file itself — where it lives, how it is written, when a refresh
//! becomes due — is the parent module's; this module only interprets it. The
//! fetch drivers construct the two kinds no stamp can record ([`super::fetch`]).

use super::{
    FetchFailure, FetchStamp, GuardAcquire, LockFile, REMOTE_CACHE_FAILURE_IS_DRIFT,
    REMOTE_CACHE_FETCH_DEADLINE, REMOTE_CACHE_TTL, RemoteCacheFetchGuard, age_since,
    cache_refresh_unwritable_reason, cached_remote_sources, epoch_now, read_fetch_stamp,
    remote_cache_fetch_due, remote_cache_fetch_stamp, write_fetch_stamp,
};
use std::path::Path;

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

    /// One line, for a command that reports this as it happens rather than
    /// building a report out of it. `check` renders its own report-shaped
    /// wording, which carries the humanized ages and the `--offline` caveat a
    /// live refresher has no use for.
    pub fn describe(&self) -> String {
        match self {
            Self::Failing { cause, .. } => cause
                .map_or("the refresh did not complete", FetchFailure::describe)
                .to_string(),
            Self::Unwritable { reason } => format!("cache cannot be written: {reason}"),
            // The refusal already names the entry and the next step.
            Self::Refused { reason } => reason.clone(),
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

/// Problems recorded on disk for this lock's caches, without fetching
/// anything. This is what the session-start check reports: the news is at
/// most one refresh late, and a permanently broken remote still surfaces.
/// A refused source is deliberately absent: `check` is this function's caller
/// and already reports the refusal as an unverifiable source, from the
/// resolution path that names the entries it leaves unanswered. Repeating it
/// here would give one state two vocabularies in one report.
pub(crate) fn recorded_remote_cache_problems(lock: &LockFile) -> Vec<RemoteCacheProblem> {
    let mut problems: Vec<RemoteCacheProblem> = cached_remote_sources(lock)
        .present
        .into_iter()
        .filter_map(|(source, remote)| {
            let kind = cache_problem(&remote.cache_dir)?;
            Some(RemoteCacheProblem { source, kind })
        })
        .collect();
    problems.sort_by(|a, b| a.source.cmp(&b.source));
    problems
}

/// One cache's problem, with the two that can be true at once put in the order
/// their remedies have to happen in.
///
/// A cache whose stamp or lock cannot be written can never record anything, so
/// every refresh of it fails silently forever — and that is true whether or not
/// a stamp from before the permissions changed says a fetch was failing. Read
/// in the other order, the recorded failure answered for the cache: its
/// `failing_for` is frozen at whatever the last writable attempt recorded, so
/// it can never age past [`REMOTE_CACHE_FAILURE_IS_DRIFT`], while the unwritable
/// state — drift the moment it is seen — went unreported for good.
///
/// The probe is limited to a cache a refresh is DUE for: nothing will write
/// before then, so nothing is blocked.
fn cache_problem(dir: &Path) -> Option<RemoteCacheProblemKind> {
    let recorded = remote_cache_problem(dir);
    if matches!(recorded, Some(RemoteCacheProblemKind::Unwritable { .. }))
        || !remote_cache_fetch_due(dir, Some(REMOTE_CACHE_TTL))
    {
        return recorded;
    }
    let Some(reason) = cache_refresh_unwritable_reason(dir) else {
        return recorded;
    };
    // Both faults, in one line: the repair comes first, and what the frozen
    // stamp last recorded rides along so the fetch failure is not news the
    // next report has to break all over again.
    let reason = match recorded {
        Some(RemoteCacheProblemKind::Failing { cause, .. }) => format!(
            "{reason}; the last recorded refresh also failed ({})",
            cause.map_or("cause unrecorded", FetchFailure::describe)
        ),
        _ => reason,
    };
    Some(RemoteCacheProblemKind::Unwritable { reason })
}
