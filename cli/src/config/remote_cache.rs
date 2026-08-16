//! Remote source caches: which directory belongs to a source, whether it
//! provably belongs to that source, and what the last fetch attempt left
//! behind. Everything here reads disk; nothing here mutates a cache.
//!
//! Fetching, the exclusion guard around it, and the refresh drivers live in
//! [`fetch`].

use super::{LockFile, global_base_dir};
use std::path::{Path, PathBuf};

mod fetch;
#[cfg(test)]
mod test_support;

pub(crate) use fetch::git_command_for_cache;
pub use fetch::{
    FetchAttempt, FetchBound, fetch_remote_cache, refresh_remote_caches,
    refresh_remote_caches_older_than, spawn_detached_cache_refresh,
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

/// True for the `owner/repo` GitHub shorthand: two non-empty segments of
/// `[A-Za-z0-9._-]`, neither `.` nor `..`. Anything else — paths, URLs,
/// backslashes, extra segments — is not shorthand; [`remote_source_slug`]
/// normalizes every accepted form, shorthand included.
pub fn is_remote_source_slug(source: &str) -> bool {
    let mut parts = source.split('/');
    let (Some(owner), Some(repo), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    is_slug_segment(owner) && is_slug_segment(repo)
}

fn is_slug_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && segment
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The shape of an accepted remote source.
enum RemoteSourceForm<'a> {
    /// Already a git URL — `https://host/path`, `ssh://[user@]host/path`, or
    /// scp-style `[user@]host:path`. `host` may still carry `user@` and
    /// `:port`.
    GitUrl { host: &'a str, path: &'a str },
    /// `owner/repo`, which means github.com.
    GitHubShorthand,
}

/// The ONE definition of what each remote form looks like. The cache key
/// ([`remote_source_slug`]) and the URL git is handed ([`remote_git_url`])
/// both derive from it, so a source can never be keyed as one endpoint and
/// cloned from another.
fn remote_source_form(trimmed: &str) -> Option<RemoteSourceForm<'_>> {
    if let Some(rest) = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("ssh://"))
    {
        let (host, path) = rest.split_once('/')?;
        return Some(RemoteSourceForm::GitUrl { host, path });
    }
    if trimmed.contains("://") {
        // Includes http:// — see [`remote_source_slug`].
        return None;
    }
    if let Some((user_host, path)) = trimmed.split_once(':') {
        // scp-style `[user@]host:owner/repo`; shorthand has no colon. A `/`
        // before the colon means the colon sits inside a path, not after a
        // host.
        if user_host.contains('/') {
            return None;
        }
        return Some(RemoteSourceForm::GitUrl {
            host: user_host,
            path,
        });
    }
    // No transport: the only remaining remote form is GitHub shorthand,
    // which is exactly two segments. A local path — absolute, `./x`,
    // `a/b/c` — is not a remote source and must never key a cache.
    is_remote_source_slug(trimmed).then_some(RemoteSourceForm::GitHubShorthand)
}

/// The URL git is handed for a remote source, or None when the source is not
/// one vstack can fetch — the same answer [`remote_source_slug`] gives, since
/// vstack only ever clones into a cache it can key.
///
/// The GitHub shorthand is the only form rewritten. Every other accepted form
/// is already a git URL and passes through verbatim, credentials, port and
/// `.git` suffix included: rewriting `alice@gitlab.example:team/repo` into a
/// github.com URL would clone an unrelated repository into the cache the slug
/// says belongs to gitlab.example.
pub fn remote_git_url(source: &str) -> Option<String> {
    let trimmed = source.trim_end_matches('/');
    remote_source_slug(trimmed)?;
    match remote_source_form(trimmed)? {
        RemoteSourceForm::GitUrl { .. } => Some(trimmed.to_string()),
        RemoteSourceForm::GitHubShorthand => Some(format!("https://github.com/{trimmed}.git")),
    }
}

/// The canonical identity of a remote source: `host/path…`, lowercased.
///
/// Every accepted form maps here — `owner/repo` shorthand (GitHub),
/// `https://host/path`, `ssh://[user@]host/path`, `[user@]host:path` — so the
/// clone, `check` and `refresh` agree on which cache belongs to which source.
/// The HOST is part of the identity: without it `gitlab.example/acme/kit` and
/// the GitHub shorthand `acme/kit` would share one cache and whichever cloned
/// first would silently supply the other's agents and hooks. `http://` is
/// rejected outright — a cache feeds executable content into a project, and
/// cleartext transport is not an acceptable way to receive it. None when
/// `source` is not a remote form.
pub fn remote_source_slug(source: &str) -> Option<String> {
    let trimmed = source.trim_end_matches('/');
    let (host, path) = match remote_source_form(trimmed)? {
        RemoteSourceForm::GitUrl { host, path } => (host, path),
        RemoteSourceForm::GitHubShorthand => ("github.com", trimmed),
    };

    let host = host.rsplit('@').next()?; // drop any `user@`
    // A nonstandard port is part of the endpoint's identity: two services on
    // one host are two sources, not one cache.
    let (host, port) = match host.split_once(':') {
        Some((host, port)) if !port.is_empty() => (host, Some(port)),
        _ => (host, None),
    };
    // Hostnames are case-insensitive, paths are NOT: lowercasing the path
    // would alias two distinct repositories on a case-sensitive forge.
    let host = host.to_ascii_lowercase();
    if !is_slug_segment(&host) || port.is_some_and(|port| !port.chars().all(|c| c.is_ascii_digit()))
    {
        return None;
    }
    let host = match port {
        Some(port) => format!("{host}:{port}"),
        None => host,
    };

    let path = path.trim_start_matches('/').trim_end_matches(".git");
    let mut segments = Vec::new();
    for segment in path.split('/') {
        // Subgroups are kept, not collapsed: `group/sub/repo` is not
        // `sub/repo`.
        if !is_slug_segment(segment) {
            return None;
        }
        segments.push(segment.to_string());
    }
    if segments.is_empty() {
        return None;
    }
    Some(format!("{host}/{}", segments.join("/")))
}

/// Cache directory key for a source: its slug flattened to ONE path
/// component, so a cache always sits directly under the cache root.
fn remote_cache_key(source: &str) -> Option<String> {
    Some(encode_remote_cache_key(&remote_source_slug(source)?))
}

/// Flatten a slug to ONE path component, INJECTIVELY. Percent-encoding is
/// what makes it injective: `_` is a legal character inside a slug segment,
/// so the old `/`→`_` flattening mapped `github.com/a_b/c` and
/// `github.com/a/b_c` onto one directory, and whichever cloned first left the
/// other unverifiable — two valid sources that could not coexist on one
/// machine. `%` is escaped first so the escapes themselves cannot collide,
/// and `:` (a port) goes too, which every filesystem accepts and Windows
/// requires.
fn encode_remote_cache_key(slug: &str) -> String {
    let mut key = String::with_capacity(slug.len());
    for ch in slug.chars() {
        match ch {
            '%' => key.push_str("%25"),
            '/' => key.push_str("%2F"),
            ':' => key.push_str("%3A"),
            other => key.push(other),
        }
    }
    key
}

fn remote_cache_root() -> PathBuf {
    global_base_dir().join(".vstack").join("cache")
}

/// Is this directory one vstack may fetch into and reset?
///
/// Containment, not caller discipline: a cache is ALWAYS a direct child of the
/// cache root (current key or a legacy one), so anything else — a local source
/// path, a project root, the checkout vstack is running from — is structurally
/// unable to reach a mutation, whatever a caller passes. Compared lexically
/// after normalization so a missing directory still answers.
pub(crate) fn is_under_remote_cache_root(dir: &Path) -> bool {
    // A symlink AT the cache directory or at its `.git` passes every path
    // comparison while the mutation follows it into somebody else's clone —
    // `reset --hard` would then destroy that working tree's local changes.
    // The link itself is rejected, before any resolution.
    let is_symlink = |path: &Path| {
        std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink())
    };
    if is_symlink(dir) || is_symlink(&dir.join(".git")) {
        return false;
    }
    let normalize = |path: &Path| -> PathBuf {
        std::fs::canonicalize(path).unwrap_or_else(|_| {
            let mut normalized = PathBuf::new();
            for component in path.components() {
                match component {
                    std::path::Component::CurDir => {}
                    std::path::Component::ParentDir => {
                        normalized.pop();
                    }
                    other => normalized.push(other.as_os_str()),
                }
            }
            normalized
        })
    };
    let root = normalize(&remote_cache_root());
    if dir.parent().is_none_or(|parent| normalize(parent) != root) {
        return false;
    }
    // With the dir itself proven non-symlink and its parent canonicalized,
    // an existing dir's canonical self must agree — the belt-and-braces
    // answer to any resolution path the two checks above did not cover.
    match std::fs::canonicalize(dir) {
        Ok(canonical) => canonical.parent().is_some_and(|parent| parent == root),
        // Missing is fine: there is nothing to mutate through yet.
        Err(_) => true,
    }
}

/// Where a fresh clone of `source` belongs. Existing clones are found with
/// [`remote_cache_lookup`], which also adopts pre-host-key directories.
pub fn remote_cache_dir(source: &str) -> Option<PathBuf> {
    Some(remote_cache_root().join(remote_cache_key(source)?))
}

/// Cache directories written by earlier releases, which keyed on the last two
/// path segments only. Adopted (never re-cloned) when their recorded origin
/// matches the source being resolved.
fn legacy_remote_cache_dirs(source: &str) -> Vec<PathBuf> {
    let Some(slug) = remote_source_slug(source) else {
        return Vec::new();
    };
    let mut segments = slug.split('/');
    let Some(host) = segments.next() else {
        return Vec::new();
    };
    let tail: Vec<&str> = segments.collect();
    let Some((repo, owner)) = tail.last().zip(tail.get(tail.len().wrapping_sub(2))) else {
        return Vec::new();
    };
    let root = remote_cache_root();
    vec![
        // Pre-percent-encoding: the whole slug flattened with `_`.
        root.join(slug.replace(['/', ':'], "_")),
        root.join(format!("{owner}_{repo}")),
        root.join(format!("git@{host}:{owner}_{repo}")),
    ]
}

/// What `.git/config` records as this clone's origin, read as a file so the
/// session-start path never spawns git.
pub(super) fn cache_origin_url(cache_dir: &Path) -> Option<String> {
    let content = std::fs::read_to_string(cache_dir.join(".git").join("config")).ok()?;
    let mut in_origin = false;
    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_origin = line.replace(char::is_whitespace, "") == "[remote\"origin\"]";
            continue;
        }
        if in_origin && let Some(url) = line.strip_prefix("url") {
            let url = url.trim_start();
            if let Some(url) = url.strip_prefix('=') {
                return Some(url.trim().to_string());
            }
        }
    }
    None
}

/// Where a source's cache actually is, and whether it may be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteCacheLookup {
    /// Not a remote source at all.
    NotRemote,
    /// Remote, but nothing is cloned yet.
    Absent,
    /// A clone whose recorded origin is this source.
    Usable(PathBuf),
    /// A clone exists but cannot be proven to be this source's. Never used:
    /// installing from it would install another repository's executables.
    Unverifiable { dir: PathBuf, reason: String },
}

pub fn remote_cache_lookup(source: &str) -> RemoteCacheLookup {
    let Some(canonical) = remote_cache_dir(source) else {
        return RemoteCacheLookup::NotRemote;
    };
    // Only the CANONICAL directory can be unverifiable. A legacy-key
    // directory that does not prove out simply belongs to somebody else —
    // its key is lossy by construction, so refusing on it would let one
    // source's old cache permanently block a different source that merely
    // flattens to the same legacy name.
    let mut candidates = vec![(canonical, true)];
    candidates.extend(
        legacy_remote_cache_dirs(source)
            .into_iter()
            .map(|dir| (dir, false)),
    );
    let mut first_problem = None;
    for (dir, canonical) in candidates {
        if !dir.join(".git").exists() {
            continue;
        }
        match cache_origin_url(&dir) {
            Some(origin) if remote_source_slug(&origin) == remote_source_slug(source) => {
                return RemoteCacheLookup::Usable(dir);
            }
            Some(origin) if canonical => {
                first_problem.get_or_insert(RemoteCacheLookup::Unverifiable {
                    reason: format!(
                        "cache {} was cloned from {origin}",
                        dir.file_name().unwrap_or_default().to_string_lossy()
                    ),
                    dir,
                });
            }
            None if canonical => {
                first_problem.get_or_insert(RemoteCacheLookup::Unverifiable {
                    reason: format!(
                        "cache {} records no origin URL",
                        dir.file_name().unwrap_or_default().to_string_lossy()
                    ),
                    dir,
                });
            }
            _ => {}
        }
    }
    first_problem.unwrap_or(RemoteCacheLookup::Absent)
}

/// The cache directory to read this source from, or None when there is none
/// that provably belongs to it.
pub fn usable_remote_cache(source: &str) -> Option<PathBuf> {
    match remote_cache_lookup(source) {
        RemoteCacheLookup::Usable(dir) => Some(dir),
        _ => None,
    }
}

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
}

impl RemoteCacheProblemKind {
    /// True when the problem has outlived [`REMOTE_CACHE_FAILURE_IS_DRIFT`] or
    /// cannot resolve itself at all. A single offline session stays quiet.
    pub fn is_persistent(&self) -> bool {
        match self {
            Self::Failing { failing_for, .. } => *failing_for >= REMOTE_CACHE_FAILURE_IS_DRIFT,
            Self::Unwritable { .. } => true,
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

/// Every distinct lock source that has a usable cache on disk, with its
/// directory. Pure disk reads.
pub fn cached_remote_sources(lock: &LockFile) -> Vec<(String, PathBuf)> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        if let Some(dir) = usable_remote_cache(&entry.source) {
            out.push((entry.source.clone(), dir));
        }
    }
    out.sort();
    out
}

/// Problems recorded on disk for this lock's caches, without fetching
/// anything. This is what the session-start check reports: the news is at
/// most one refresh late, and a permanently broken remote still surfaces.
pub fn recorded_remote_cache_problems(lock: &LockFile) -> Vec<RemoteCacheProblem> {
    let mut problems: Vec<RemoteCacheProblem> = cached_remote_sources(lock)
        .into_iter()
        .filter_map(|(source, dir)| {
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
pub fn any_remote_cache_due(lock: &LockFile, max_age: Option<std::time::Duration>) -> bool {
    cached_remote_sources(lock)
        .iter()
        .any(|(_, dir)| remote_cache_fetch_due(dir, max_age))
}

#[cfg(test)]
mod tests;
