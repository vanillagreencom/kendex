//! Who is signed in: GET /api/v1/me through the rotation-safe bearer
//! client. The last good answer is cached through [`super::generation`]
//! with no TTL, because "signed in", "offline" and "expired" can only be
//! told apart by asking the server; when the network is away the cached
//! identity is served as the offline state instead of nothing.

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::registry::client::{self, server_message, sign_in_changed};
use crate::registry::credentials::{Credential, CredentialStore};
use crate::registry::generation::GenerationFile;
use crate::registry::{Fetch, base_url};

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

/// Ask who is signed in. No credential is `SignedOut` without a network
/// call; a dead credential is `Expired` and its cached identity is
/// dropped; an unreachable or misbehaving server serves the cached
/// identity as `Offline`, and errors only with nothing cached to serve. A
/// credential gone by the time the answer lands is `SignedOut` too, and
/// nothing is written back over the sign-out. Everything this read
/// settles belongs to one sign-in: the cache it opens with, the call it
/// sends, and the answer it caches. A sign-in as somebody else at any
/// point across that span is refused as retryable rather than served,
/// because the identity in hand is the previous account's. A refresh
/// rotation mid-read is the same sign-in throughout and settles as
/// usual.
pub fn load(env: &Env, fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<AccountState> {
    let Some(credential) = store.load()? else {
        return Ok(AccountState::SignedOut);
    };
    // The token family names the sign-in. The cache read next, the call
    // sent after it, and the answer settled at the end all have to be
    // this one.
    let issued_under = credential.refresh_token;
    let cache = cache(env);
    let cached = cache.read(parse);
    let etag = cached
        .as_ref()
        .and_then(|(generation, _)| generation.etag.clone());
    let url = format!("{}/api/v1/me", base_url());
    let (fetched, opened_under, answered_for) = match client::with_access(fetch, store, |access| {
        fetch.get_auth(&url, etag.as_deref(), Some(access))
    }) {
        // Logout won a race with this read: the re-login state without
        // refreshing, exactly as if the credential had been gone up front.
        Err(CoreError::NotSignedIn) => return Ok(AccountState::SignedOut),
        // The credential is dead and the client cleared it; a cached
        // identity kept here could resurface as another account's
        // "offline" after the next sign-in.
        Err(CoreError::SignInExpired { .. }) => {
            cache.forget()?;
            return Ok(AccountState::Expired);
        }
        Ok(authenticated) => (
            Ok(authenticated.response),
            authenticated.opened_under.refresh_token,
            authenticated.credential.refresh_token,
        ),
        // Nothing came back, so the cache is the whole answer, and it
        // belongs to whoever was signed in when the read began.
        Err(error) => (Err(error), issued_under.clone(), issued_under.clone()),
    };
    // A sign-out that landed while this read was in flight already forgot
    // the cache; settling now would write the identity straight back. The
    // module's rule throughout: a missing credential means logout won.
    let Some(installed) = store.load()? else {
        return Ok(AccountState::SignedOut);
    };
    // Existence is not identity: a sign-out followed by a sign-in leaves
    // a credential here too, and nothing here belongs to either of them.
    // Two spans to close. A sign-in landing before the call leaves the
    // previous account's identity in `cached`, which a 304 hands back and
    // any failure serves as offline. One landing after it settles this
    // answer under a stranger. A rotation is neither: it saves its
    // replacement before the call goes out, so both comparisons hold.
    if opened_under != issued_under || answered_for != installed.refresh_token {
        return Err(sign_in_changed("reading your account"));
    }
    let loaded = cache.settle(cached, fetched, parse, |response| {
        CoreError::RegistryUnavailable {
            why: server_message(response),
        }
    })?;
    Ok(match loaded.stale {
        false => AccountState::SignedIn {
            identity: loaded.value,
        },
        true => AccountState::Offline {
            identity: loaded.value,
        },
    })
}

/// Commit a fresh sign-in and drop the previous account's cached
/// identity, so the new credential never pairs with the old name. The
/// cache is forgotten twice: once before the save, so a crash between the
/// two leaves no inherited identity, and once after, because a read
/// settling in that window was still holding the credential the old
/// identity belongs to and had every right to cache it.
pub fn commit_sign_in(
    env: &Env,
    store: &dyn CredentialStore,
    credential: &Credential,
) -> Result<()> {
    let cache = cache(env);
    cache.forget()?;
    client::commit_login(store, credential)?;
    cache.forget()
}

/// Revoke, clear, and forget the cached identity — the one sign-out
/// every surface calls. When revocation fails the credential is kept for
/// retry, and so is the cache. Returns false when already signed out.
pub fn sign_out(env: &Env, fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<bool> {
    let was_signed_in = client::logout(fetch, store)?;
    cache(env).forget()?;
    Ok(was_signed_in)
}

fn cache(env: &Env) -> GenerationFile<'_> {
    GenerationFile::new(env, CACHE_FILE)
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
