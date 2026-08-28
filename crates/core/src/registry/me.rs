//! Who is signed in: GET /api/v1/me through the rotation-safe bearer
//! client. The last good answer is cached like the directory index —
//! one atomically-written generation, revalidated by ETag — but with no
//! TTL, because "signed in", "offline" and "expired" can only be told
//! apart by asking the server. The account page can still say who you
//! are on a train with no wifi; it just says "offline" next to it.

use serde::{Deserialize, Serialize};

use crate::clock;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::registry::client::{self, server_message};
use crate::registry::credentials::CredentialStore;
use crate::registry::{Fetch, MAX_RESPONSE_BYTES, base_url};

const CACHE_FILE: &str = "me.cache.json";

/// Who the credential belongs to, as the identity endpoint answers it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub name: String,
    /// The linked GitHub provider's immutable account id; `None` after unlink.
    pub github_login: Option<String>,
}

/// What the account surfaces render, every one of them settled: the UI
/// holds its own "not read yet" until the first answer comes back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum AccountState {
    SignedOut,
    SignedIn {
        identity: Identity,
    },
    /// The server could not be asked; the identity is the last good fetch.
    Offline {
        identity: Identity,
    },
    /// The credential is dead server-side — signing in again is the fix.
    Expired,
}

/// The wire shape of GET /api/v1/me, exactly as the contract fixture says.
#[derive(Deserialize)]
struct WireMe {
    name: String,
    github_login: Option<String>,
}

/// One fetch, whole, keyed to the endpoint it came from so switching
/// `KENDEX_API` can never serve another server's identity.
#[derive(Serialize, Deserialize)]
struct Generation {
    endpoint: String,
    etag: Option<String>,
    fetched_at: u64,
    body: String,
}

/// Ask who is signed in. No credential is `SignedOut` without a network
/// call; a dead credential is `Expired`; an unreachable or misbehaving
/// server serves the cached identity as `Offline`, and errors only with
/// nothing cached to serve.
pub fn load(env: &Env, fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<AccountState> {
    if store.load()?.is_none() {
        return Ok(AccountState::SignedOut);
    }
    let cached = read_cached(env);
    let etag = cached
        .as_ref()
        .and_then(|(generation, _)| generation.etag.clone());
    let url = format!("{}/api/v1/me", base_url());
    let response = match client::with_access(fetch, store, |access| {
        fetch.get_auth(&url, etag.as_deref(), Some(access))
    }) {
        Ok(response) => response,
        // Logout won a race with this read: the re-login state without
        // refreshing, exactly as if the credential had been gone up front.
        Err(CoreError::NotSignedIn) => return Ok(AccountState::SignedOut),
        Err(CoreError::SignInExpired { .. }) => return Ok(AccountState::Expired),
        Err(error) => return offline_or(cached, error),
    };
    let now = clock::unix_now();
    match response.status {
        200 => match parse(&response.body) {
            Ok(identity) => {
                write_generation(
                    env,
                    &Generation {
                        endpoint: base_url(),
                        etag: response.etag,
                        fetched_at: now,
                        body: String::from_utf8_lossy(&response.body).into_owned(),
                    },
                )?;
                Ok(AccountState::SignedIn { identity })
            }
            Err(error) => offline_or(cached, error),
        },
        304 => {
            let (generation, identity) = cached.ok_or_else(|| CoreError::RegistryMalformed {
                why: "the server said 'unchanged' but nothing is cached".into(),
            })?;
            write_generation(
                env,
                &Generation {
                    fetched_at: now,
                    ..generation
                },
            )?;
            Ok(AccountState::SignedIn { identity })
        }
        _ => offline_or(
            cached,
            CoreError::RegistryUnavailable {
                why: server_message(&response),
            },
        ),
    }
}

/// Forget the cached identity — the other half of logout.
pub fn forget(env: &Env) -> Result<()> {
    let path = env.registry_cache_dir().join(CACHE_FILE);
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CoreError::io(&path, error)),
    }
}

fn parse(body: &[u8]) -> Result<Identity> {
    let wire: WireMe =
        serde_json::from_slice(body).map_err(|error| CoreError::RegistryMalformed {
            why: error.to_string(),
        })?;
    Ok(Identity {
        name: wire.name,
        github_login: wire.github_login,
    })
}

fn offline_or(cached: Option<(Generation, Identity)>, error: CoreError) -> Result<AccountState> {
    match cached {
        Some((_, identity)) => Ok(AccountState::Offline { identity }),
        None => Err(error),
    }
}

fn read_cached(env: &Env) -> Option<(Generation, Identity)> {
    let path = env.registry_cache_dir().join(CACHE_FILE);
    // Local, but not trusted to be well-formed: the same size cap and the
    // same strict parse the network response passed.
    let size = std::fs::metadata(&path).ok()?.len();
    if size > MAX_RESPONSE_BYTES as u64 * 2 {
        return None;
    }
    let generation: Generation = serde_json::from_str(&read_if_exists(&path).ok()??).ok()?;
    if generation.endpoint != base_url() {
        return None;
    }
    let identity = parse(generation.body.as_bytes()).ok()?;
    Some((generation, identity))
}

fn write_generation(env: &Env, generation: &Generation) -> Result<()> {
    let dir = env.registry_cache_dir();
    std::fs::create_dir_all(&dir).map_err(|error| CoreError::io(&dir, error))?;
    let json = serde_json::to_string(generation).map_err(|error| CoreError::RegistryMalformed {
        why: error.to_string(),
    })?;
    atomic_write(&dir.join(CACHE_FILE), &json)
}
