//! One fetch, held whole: a generation file pairs body, ETag, endpoint
//! and fetch time in a single atomic write, so no crash can mix two
//! fetches and no other endpoint's answer is ever served. The directory
//! index and the signed-in identity both cache through this mechanism;
//! each caller keeps its own transport, parser, and refusal message.

use serde::{Deserialize, Serialize};

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::registry::{FetchResponse, MAX_RESPONSE_BYTES, base_url};

#[derive(Serialize, Deserialize)]
pub(super) struct Generation {
    pub endpoint: String,
    pub etag: Option<String>,
    pub fetched_at: u64,
    pub body: String,
}

/// A settled load: the parsed value, when its body was really fetched,
/// and whether the network stood behind it or the last fetch stood in.
pub(super) struct Loaded<T> {
    pub value: T,
    pub fetched_at: u64,
    pub stale: bool,
}

pub(super) struct GenerationFile<'e> {
    env: &'e Env,
    file: &'static str,
}

impl<'e> GenerationFile<'e> {
    pub fn new(env: &'e Env, file: &'static str) -> GenerationFile<'e> {
        GenerationFile { env, file }
    }

    fn path(&self) -> std::path::PathBuf {
        self.env.registry_cache_dir().join(self.file)
    }

    /// The cached generation, or `None`: absent, over the size cap,
    /// unreadable, another endpoint's, or a body the caller's strict
    /// parse refuses. The cache lives on this machine, but "on this
    /// machine" is not "trusted to be well-formed": the same cap and the
    /// same parse the network response passed.
    pub fn read<T>(&self, parse: impl Fn(&[u8]) -> Result<T>) -> Option<(Generation, T)> {
        let path = self.path();
        let size = std::fs::metadata(&path).ok()?.len();
        if size > MAX_RESPONSE_BYTES as u64 * 2 {
            return None;
        }
        let generation: Generation = serde_json::from_str(&read_if_exists(&path).ok()??).ok()?;
        if generation.endpoint != base_url() {
            return None;
        }
        let value = parse(generation.body.as_bytes()).ok()?;
        Some((generation, value))
    }

    /// Remove the cached generation; already-gone is fine.
    pub fn forget(&self) -> Result<()> {
        let path = self.path();
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(CoreError::io(&path, error)),
        }
    }

    /// Settle one fetch against the cache: a 200 replaces the generation,
    /// a 304 re-dates the cached one, and any failure — transport error,
    /// refused status, unparseable body — serves the cached value as
    /// stale, erring only with nothing to serve. `refused` words the
    /// error for a status that is neither 200 nor 304.
    pub fn settle<T>(
        &self,
        cached: Option<(Generation, T)>,
        fetched: Result<FetchResponse>,
        parse: impl Fn(&[u8]) -> Result<T>,
        refused: impl Fn(&FetchResponse) -> CoreError,
    ) -> Result<Loaded<T>> {
        let now = clock::unix_now();
        let response = match fetched {
            Ok(response) => response,
            Err(error) => return stale_or(cached, error),
        };
        match response.status {
            200 => match parse(&response.body) {
                Ok(value) => {
                    self.write(&Generation {
                        endpoint: base_url(),
                        etag: response.etag,
                        fetched_at: now,
                        body: String::from_utf8_lossy(&response.body).into_owned(),
                    })?;
                    Ok(Loaded {
                        value,
                        fetched_at: now,
                        stale: false,
                    })
                }
                Err(error) => stale_or(cached, error),
            },
            304 => {
                let (generation, value) = cached.ok_or_else(|| CoreError::RegistryMalformed {
                    why: "the server said 'unchanged' but nothing is cached".into(),
                })?;
                self.write(&Generation {
                    fetched_at: now,
                    ..generation
                })?;
                Ok(Loaded {
                    value,
                    fetched_at: now,
                    stale: false,
                })
            }
            _ => stale_or(cached, refused(&response)),
        }
    }

    fn write(&self, generation: &Generation) -> Result<()> {
        let dir = self.env.registry_cache_dir();
        std::fs::create_dir_all(&dir).map_err(|error| CoreError::io(&dir, error))?;
        let json =
            serde_json::to_string(generation).map_err(|error| CoreError::RegistryMalformed {
                why: error.to_string(),
            })?;
        atomic_write(&dir.join(self.file), &json)
    }
}

fn stale_or<T>(cached: Option<(Generation, T)>, error: CoreError) -> Result<Loaded<T>> {
    match cached {
        Some((generation, value)) => Ok(Loaded {
            value,
            fetched_at: generation.fetched_at,
            stale: true,
        }),
        None => Err(error),
    }
}
