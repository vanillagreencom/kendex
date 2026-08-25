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
const MAX_ERROR_BYTES: usize = 512;
const MAX_ETAG_BYTES: usize = 512;
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

static CHECK_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateView {
    pub automatic_check_enabled: bool,
    pub status: AppUpdateStatus,
    pub last_attempt_at: Option<String>,
    pub last_success_at: Option<String>,
    pub served_feed_at: Option<String>,
    pub served_feed_age_secs: Option<u32>,
    pub served_feed_in_future: bool,
    pub last_error: Option<AppUpdateError>,
}

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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateError {
    pub kind: AppUpdateErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum AppUpdateErrorKind {
    Network,
    Http,
    InvalidFeed,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Cache {
    #[serde(default)]
    feed_url: String,
    etag: Option<String>,
    fetched_at: Option<u64>,
    last_attempt_at: Option<u64>,
    last_success_at: Option<u64>,
    body: Option<String>,
    last_error: Option<AppUpdateError>,
}

/// Runtime inputs that identify the build and the requested check.
pub struct CheckRequest<'a> {
    pub current_version: &'a str,
    pub target: &'a str,
    pub feed_url: &'a str,
    pub refresh: bool,
    pub automatic_check_enabled: bool,
    pub muted_version: Option<&'a str>,
}

/// Return the remembered result and, when due, refresh it through the
/// caller's transport. `refresh` is the explicit manual-check path and may
/// fetch while automatic checks are off.
pub fn check(env: &Env, fetch: &dyn Fetch, request: CheckRequest<'_>) -> Result<AppUpdateView> {
    check_at(env, fetch, request, clock::unix_now())
}

fn check_at(
    env: &Env,
    fetch: &dyn Fetch,
    request: CheckRequest<'_>,
    now: u64,
) -> Result<AppUpdateView> {
    // No protected state lives in memory. A prior panic releases the mutex,
    // and the atomic cache file is either the old or new generation.
    let _guard = CHECK_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let _process_guard = update_lock(env)?;
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
    if (!due || !request.automatic_check_enabled) && !request.refresh {
        return view(
            &cached,
            now,
            request.current_version,
            request.target,
            request.automatic_check_enabled,
            request.muted_version,
        );
    }

    cached.last_attempt_at = Some(now);
    let response = fetch.get(feed_url, cached.etag.as_deref());
    match response {
        Ok(response) if response.status == 304 && cached.body.is_some() => {
            cached.fetched_at = Some(now);
            cached.last_success_at = Some(now);
            cached.last_error = None;
        }
        Ok(response) if response.status == 200 => match ReleaseFeed::parse(&response.body) {
            Ok(_) => match String::from_utf8(response.body) {
                Ok(body) => {
                    cached.etag = response.etag.filter(|etag| etag.len() <= MAX_ETAG_BYTES);
                    cached.fetched_at = Some(now);
                    cached.last_success_at = Some(now);
                    cached.body = Some(body);
                    cached.last_error = None;
                }
                Err(error) => {
                    cached.last_error = Some(update_error(
                        AppUpdateErrorKind::InvalidFeed,
                        &error.to_string(),
                    ));
                }
            },
            Err(error) => {
                cached.last_error = Some(update_error(
                    AppUpdateErrorKind::InvalidFeed,
                    &error.to_string(),
                ));
            }
        },
        Ok(response) => {
            cached.last_error = Some(update_error(
                AppUpdateErrorKind::Http,
                &format!("the release feed answered {}", response.status),
            ));
        }
        Err(error) => {
            cached.last_error = Some(update_error(
                AppUpdateErrorKind::Network,
                &error.to_string(),
            ));
        }
    }
    write_cache(env, &cached)?;
    view(
        &cached,
        now,
        request.current_version,
        request.target,
        request.automatic_check_enabled,
        request.muted_version,
    )
}

fn view(
    cached: &Cache,
    now: u64,
    current_version: &str,
    target: &str,
    automatic_check_enabled: bool,
    muted_version: Option<&str>,
) -> Result<AppUpdateView> {
    let status = match cached.body.as_deref() {
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
    };
    Ok(AppUpdateView {
        automatic_check_enabled,
        status,
        last_attempt_at: cached.last_attempt_at.map(clock::iso_from_unix),
        last_success_at: cached.last_success_at.map(clock::iso_from_unix),
        served_feed_at: cached.fetched_at.map(clock::iso_from_unix),
        served_feed_age_secs: cached
            .fetched_at
            .filter(|at| *at <= now)
            .map(|at| u32::try_from(now - at).unwrap_or(u32::MAX)),
        served_feed_in_future: cached.fetched_at.is_some_and(|at| at > now),
        last_error: cached.last_error.clone(),
    })
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

fn update_error(kind: AppUpdateErrorKind, message: &str) -> AppUpdateError {
    let message = match message.len() <= MAX_ERROR_BYTES {
        true => message.to_owned(),
        false => {
            const MARKER: &str = "...";
            let content_limit = MAX_ERROR_BYTES - MARKER.len();
            let end = message
                .char_indices()
                .map(|(at, character)| at + character.len_utf8())
                .take_while(|end| *end <= content_limit)
                .last()
                .unwrap_or(0);
            format!("{}{MARKER}", &message[..end])
        }
    };
    AppUpdateError { kind, message }
}

#[cfg(test)]
mod tests;
