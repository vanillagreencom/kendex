//! One fetch, held whole: a generation file pairs body, ETag, endpoint
//! and fetch time in a single atomic write, so no crash can mix two
//! fetches and no other endpoint's answer is ever served. The directory
//! index and the signed-in identity both cache through this mechanism;
//! each caller keeps its own transport, parser, and refusal message.
//! The file is kendex's own and never a user-managed link, so a final
//! symlink at the path is replaced on write and refused on read.

use std::io::Read;

use serde::{Deserialize, Serialize};

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write_no_follow, open_read_no_follow};
use crate::registry::{FetchResponse, MAX_RESPONSE_BYTES, base_url};

/// A cached generation is one response plus its meta, so the cap is the
/// response cap with room for the wrapper.
const MAX_CACHE_BYTES: u64 = MAX_RESPONSE_BYTES as u64 * 2;

#[derive(Serialize, Deserialize)]
pub(super) struct Generation {
    pub endpoint: String,
    /// Which sign-in this generation belongs to, as [`GenerationFile::bound_to`]
    /// names it. Absent on a generation no credential produced.
    #[serde(default)]
    pub credential: Option<String>,
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
    credential: Option<String>,
}

impl<'e> GenerationFile<'e> {
    pub fn new(env: &'e Env, file: &'static str) -> GenerationFile<'e> {
        GenerationFile {
            env,
            file,
            credential: None,
        }
    }

    /// Key this file to one sign-in, named by whatever the caller uses to
    /// tell one sign-in from the next. A generation carrying another key
    /// is discarded on read just as another endpoint's is, so a cache
    /// outliving the sign-in that filled it can never be served under the
    /// next one. The name is hashed here rather than stored, so a caller
    /// that hands over a secret still leaves none on disk: this is a
    /// cache, not the keychain. A caller with no sign-in — the community
    /// directory — leaves the key unset and reads only unkeyed
    /// generations.
    pub fn bound_to(self, sign_in: &str) -> GenerationFile<'e> {
        GenerationFile {
            credential: Some(crate::hash::hash_bytes(sign_in.as_bytes())),
            ..self
        }
    }

    fn path(&self) -> std::path::PathBuf {
        self.env.registry_cache_dir().join(self.file)
    }

    /// The cached generation, or `None`: absent, a symlink or anything
    /// but a plain file, over the size cap, unreadable, another
    /// endpoint's, or a body the caller's strict parse refuses. The
    /// cache lives on this machine, but "on this machine" is not
    /// "trusted to be well-formed": the same cap and the same parse the
    /// network response passed. Another sign-in's is refused the same
    /// way, so nothing here has to reason about how the file outlived
    /// the credential that wrote it.
    pub fn read<T>(&self, parse: impl Fn(&[u8]) -> Result<T>) -> Option<(Generation, T)> {
        let file = open_read_no_follow(&self.path()).ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES {
            return None;
        }
        let mut text = String::new();
        file.take(MAX_CACHE_BYTES).read_to_string(&mut text).ok()?;
        let generation: Generation = serde_json::from_str(&text).ok()?;
        if generation.endpoint != base_url() || generation.credential != self.credential {
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
    /// error for a status that is neither 200 nor 304. Every error out of
    /// this call is the fetch not landing, which is what lets a caller
    /// holding one judgment about the network read them all the same way.
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
                        credential: self.credential.clone(),
                        etag: response.etag,
                        fetched_at: now,
                        body: String::from_utf8_lossy(&response.body).into_owned(),
                    });
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
                    credential: self.credential.clone(),
                    ..generation
                });
                Ok(Loaded {
                    value,
                    fetched_at: now,
                    stale: false,
                })
            }
            _ => stale_or(cached, refused(&response)),
        }
    }

    /// Leave this fetch where the next read will find it, or leave nothing.
    ///
    /// A generation that could not be written — a full or read-only home, a
    /// cache path taken by something else — is never the caller's failure.
    /// The answer is what the server sent and the caller parsed; this file
    /// is only how the next read avoids asking for it again. Raising here
    /// would report a refusal by this machine as the fetch not landing,
    /// which is what every error out of [`GenerationFile::settle`] means.
    /// The cost of swallowing is one re-fetch, which is what an unwritten
    /// cache is for.
    fn write(&self, generation: &Generation) {
        let dir = self.env.registry_cache_dir();
        if std::fs::create_dir_all(&dir).is_err() {
            return;
        }
        let Ok(json) = serde_json::to_string(generation) else {
            return;
        };
        let _ = atomic_write_no_follow(&dir.join(self.file), &json);
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
