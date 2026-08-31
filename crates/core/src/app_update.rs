//! Cached app release checks shared by the desktop command and its tests.

use std::io::Read;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{LockedFile, atomic_write_no_follow, open_read_no_follow};
use crate::registry::Fetch;
use crate::update_feed::{ReleaseFeed, VersionRelation, release_notes_url};

pub const DEFAULT_TTL_SECS: u64 = 6 * 60 * 60;
const MAX_CACHE_BYTES: u64 = crate::update_feed::MAX_FEED_BYTES as u64 * 3;
const MAX_ETAG_BYTES: usize = 512;
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AppUpdateStatus {
    NeverChecked,
    UpToDate {
        version: String,
    },
    UpdateAvailable {
        version: String,
        release_notes_url: String,
        cli_asset_available: bool,
        muted: bool,
    },
    FeedOlder {
        version: String,
    },
}

/// One check at a time in this process. Two run on every launch — the
/// startup schedule and the webview asking as it mounts — and without this
/// both read a cache neither has written yet, both fetch, and the second
/// write puts its own generation over the first. Held across the read, the
/// fetch and the write, so the second caller reads what the first left and
/// finds the interval already served. Another process is held off by
/// [`update_lock`], which this one saves the cost of taking twice.
static CHECK_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// What the last check left behind: which feed it read, the validator to
/// send back, when it was attempted, and the document itself. Nothing
/// about how the attempt went — the notice card names a release or says
/// nothing, and an attempt that failed is an attempt for the interval
/// either way.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Cache {
    #[serde(default)]
    feed_url: String,
    etag: Option<String>,
    last_attempt_at: Option<u64>,
    body: Option<String>,
}

/// Runtime inputs that identify the build and the requested check.
pub struct CheckRequest<'a> {
    pub current_version: &'a str,
    pub target: &'a str,
    pub feed_url: &'a str,
    pub refresh: bool,
    pub muted_version: Option<&'a str>,
}

/// Return the remembered standing and, when due, refresh it through the
/// caller's transport. `refresh` is the explicit manual-check path and
/// fetches whether or not the interval has elapsed.
pub fn check(env: &Env, fetch: &dyn Fetch, request: CheckRequest<'_>) -> Result<AppUpdateStatus> {
    check_with_clock(env, fetch, request, clock::unix_now)
}

#[cfg(test)]
fn check_at(
    env: &Env,
    fetch: &dyn Fetch,
    request: CheckRequest<'_>,
    now: u64,
) -> Result<AppUpdateStatus> {
    check_with_clock(env, fetch, request, || now)
}

fn check_with_clock(
    env: &Env,
    fetch: &dyn Fetch,
    request: CheckRequest<'_>,
    clock: impl FnOnce() -> u64,
) -> Result<AppUpdateStatus> {
    // No protected state lives in memory. A prior panic releases the mutex,
    // and the atomic cache file is either the old or the new generation.
    let _one_at_a_time = CHECK_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _one_process_at_a_time = update_lock(env)?;
    let now = clock();
    let mut cached = read_cache(env)?.unwrap_or_default();
    let feed_url = request.feed_url.trim();
    if feed_url.is_empty() {
        return Err(CoreError::UpdateFeedMalformed {
            why: "the feed URL is empty".to_owned(),
        });
    }
    if cached.feed_url != feed_url {
        cached = Cache {
            feed_url: feed_url.to_owned(),
            ..Cache::default()
        };
    }
    let due = cached
        .last_attempt_at
        .is_none_or(|attempt| attempt > now || now - attempt >= DEFAULT_TTL_SECS);
    if !due && !request.refresh {
        return view(
            &cached,
            request.current_version,
            request.target,
            request.muted_version,
        );
    }

    // The attempt is recorded whatever comes back, so a server that is
    // down does not put this on the network every time the app opens. A
    // reply that is not a usable feed leaves the last good document in
    // place: the card names a release or says nothing, and a failed read
    // is no evidence either way.
    cached.last_attempt_at = Some(now);
    match fetch.get(feed_url, cached.etag.as_deref()) {
        Ok(response) if response.status == 200 => {
            if ReleaseFeed::parse(&response.body).is_ok()
                && let Ok(body) = String::from_utf8(response.body)
            {
                cached.etag = response.etag.filter(|etag| etag.len() <= MAX_ETAG_BYTES);
                cached.body = Some(body);
            }
        }
        Ok(_) | Err(_) => {}
    }
    write_cache(env, &cached)?;
    view(
        &cached,
        request.current_version,
        request.target,
        request.muted_version,
    )
}

fn view(
    cached: &Cache,
    current_version: &str,
    target: &str,
    muted_version: Option<&str>,
) -> Result<AppUpdateStatus> {
    Ok(match cached.body.as_deref() {
        None => AppUpdateStatus::NeverChecked,
        Some(body) => {
            let feed = ReleaseFeed::parse(body.as_bytes())?;
            match feed.relation_to(current_version)? {
                VersionRelation::Older => AppUpdateStatus::FeedOlder {
                    version: feed.version,
                },
                VersionRelation::Current => AppUpdateStatus::UpToDate {
                    version: feed.version,
                },
                VersionRelation::Newer => {
                    let notes = release_notes_url(&feed.version)?;
                    AppUpdateStatus::UpdateAvailable {
                        cli_asset_available: feed.asset_for(target).is_some(),
                        muted: muted_version == Some(feed.version.as_str()),
                        version: feed.version,
                        release_notes_url: notes,
                    }
                }
            }
        }
    })
}

/// The same one-at-a-time, held against every other kendex process.
///
/// The read, the fetch and the write are one transaction because the write
/// puts back the whole document, the body read before the fetch included.
/// Two processes overlapping without this both read the old cache; the one
/// whose fetch succeeds writes the new feed, and the one whose fetch fails
/// writes the old body back over it under a fresh `last_attempt_at` — the
/// release is gone and no automatic attempt is due for six hours. Re-reading
/// just before the write would narrow that window and not close it, so the
/// whole transaction is serialised instead.
///
/// The loser waits rather than skipping: it goes on to read what the winner
/// left, finds the interval already served, and answers from that without a
/// fetch or a write of its own. Nothing is guarded in memory, so a process
/// that died holding this released it with its file descriptors; one still
/// running after `LOCK_WAIT` is named rather than written over.
fn update_lock(env: &Env) -> Result<LockedFile> {
    let path = env.app_update_lock_file();
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::io(&path, std::io::Error::other("path has no parent")))?;
    std::fs::create_dir_all(parent).map_err(|error| CoreError::io(parent, error))?;
    let deadline = std::time::Instant::now() + LOCK_WAIT;
    loop {
        match LockedFile::try_exclusive_no_follow(&path) {
            Ok(Some(lock)) => return Ok(lock),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Ok(None) => return Err(CoreError::AppUpdateBusy { lock: path }),
            Err(error) => return Err(CoreError::io(&path, error)),
        }
    }
}

fn read_cache(env: &Env) -> Result<Option<Cache>> {
    let path = env.app_update_cache_file();
    let file = match open_read_no_follow(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_)
            if std::fs::symlink_metadata(&path)
                .is_ok_and(|metadata| metadata.file_type().is_symlink()) =>
        {
            return Ok(None);
        }
        Err(error) => return Err(CoreError::io(&path, error)),
    };
    let metadata = file
        .metadata()
        .map_err(|error| CoreError::io(&path, error))?;
    if !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    file.take(MAX_CACHE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| CoreError::io(&path, error))?;
    if bytes.len() as u64 > MAX_CACHE_BYTES {
        return Ok(None);
    }
    let Ok(text) = String::from_utf8(bytes) else {
        return Ok(None);
    };
    let Ok(cache) = serde_json::from_str::<Cache>(&text) else {
        return Ok(None);
    };
    if let Some(body) = cache.body.as_deref()
        && ReleaseFeed::parse(body.as_bytes()).is_err()
    {
        return Ok(None);
    }
    Ok(Some(cache))
}

fn write_cache(env: &Env, cache: &Cache) -> Result<()> {
    let path = env.app_update_cache_file();
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::io(&path, std::io::Error::other("path has no parent")))?;
    std::fs::create_dir_all(parent).map_err(|error| CoreError::io(parent, error))?;
    let json = serde_json::to_string(cache).map_err(|error| CoreError::UpdateFeedMalformed {
        why: error.to_string(),
    })?;
    atomic_write_no_follow(&path, &json)
}

#[cfg(test)]
mod tests;
