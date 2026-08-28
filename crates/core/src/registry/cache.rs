//! The directory cache: within the TTL the network is never touched;
//! past it a conditional GET revalidates for the cost of a 304; with the
//! network away the last fetch is served and labeled stale — the
//! Community tab is never blank because a train has no wifi. Storage and
//! the fresh/stale/refused ladder are [`super::generation`]'s.

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::registry::generation::GenerationFile;
use crate::registry::index::{self, DirectoryIndex};
use crate::registry::{Fetch, base_url};

pub const DEFAULT_TTL_SECS: u64 = 3600;
const CACHE_FILE: &str = "index.cache.json";

pub struct DirectoryLoad {
    pub index: DirectoryIndex,
    /// When the served body was actually fetched — the "as of" the UI
    /// shows when `stale` is true.
    pub fetched_at: u64,
    /// The network could not be asked and this is the last good fetch.
    pub stale: bool,
}

/// Read the directory: disk within the TTL, a conditional GET past it,
/// the stale copy when the network fails, an error only with nothing to
/// serve at all.
pub fn load(env: &Env, fetch: &dyn Fetch, force_refresh: bool) -> Result<DirectoryLoad> {
    let store = GenerationFile::new(env, CACHE_FILE);
    let cached = store.read(index::parse);
    let now = clock::unix_now();
    if let Some((generation, index)) = &cached
        && !force_refresh
        && now.saturating_sub(generation.fetched_at) < DEFAULT_TTL_SECS
    {
        return Ok(DirectoryLoad {
            index: index.clone(),
            fetched_at: generation.fetched_at,
            stale: false,
        });
    }

    let etag = cached
        .as_ref()
        .and_then(|(generation, _)| generation.etag.clone());
    let url = format!("{}/api/v1/index", base_url());
    let loaded = store.settle(
        cached,
        fetch.get(&url, etag.as_deref()),
        index::parse,
        |response| CoreError::RegistryUnavailable {
            why: format!("the directory answered {}", response.status),
        },
    )?;
    Ok(DirectoryLoad {
        index: loaded.value,
        fetched_at: loaded.fetched_at,
        stale: loaded.stale,
    })
}
