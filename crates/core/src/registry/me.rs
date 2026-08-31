//! Who is signed in: GET /api/v1/me through the rotation-safe bearer
//! client. The last good answer is cached through [`super::generation`]
//! with no TTL, because "signed in", "offline" and "expired" can only be
//! told apart by asking the server; when the network is away this
//! sign-in's cached identity is served as the offline state instead of
//! nothing.

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
/// settles belongs to one sign-in: the cache it opens with and the
/// credential still installed when it settles. That sign-in is named on
/// the credential, so what is compared is the name and not the tokens,
/// which move. A rotation keeps the name whichever call performed it, so
/// it settles as usual and leaves a cache the next read can still use.
/// Only a different sign-in is refused as retryable, because then the
/// identity in hand is the previous account's. An expiry ends the read
/// ahead of that comparison and is named for the sign-in it opened under:
/// `client.rs` removes the credential the refusal belongs to, and where
/// the server's own rejection lands on a sign-in another writer installed
/// in the moment the refresh guard was down, it answers a retryable
/// refusal and removes nothing.
pub fn load(env: &Env, fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<AccountState> {
    let Some(credential) = store.load()? else {
        return Ok(AccountState::SignedOut);
    };
    // The sign-in's own name, which a rotation carries and only a new
    // sign-in changes. The cache read next and the credential installed
    // when this settles both have to be this one.
    let issued_under = credential.sign_in;
    // Keyed to this sign-in, so a generation the previous one left behind
    // is not a cache at all here.
    let cache = cache(env).bound_to(&issued_under);
    let cached = cache.read(parse);
    let etag = cached
        .as_ref()
        .and_then(|(generation, _)| generation.etag.clone());
    let url = format!("{}/api/v1/me", base_url());
    let fetched = match client::with_access(fetch, store, |access| {
        fetch.get_auth(&url, etag.as_deref(), Some(access))
    }) {
        // Logout won a race with this read: the re-login state without
        // refreshing, exactly as if the credential had been gone up front.
        Err(CoreError::NotSignedIn) => return Ok(AccountState::SignedOut),
        // Producing this removed the rejected credential, or said in `why`
        // that the store would not give it up. Either way the identity it
        // named has no reason to outlive it on disk, and the next sign-in
        // would find it keyed to this one and discard it unread.
        Err(CoreError::SignInExpired { .. }) => {
            cache.forget()?;
            return Ok(AccountState::Expired);
        }
        fetched => fetched,
    };
    // A sign-out that landed while this read was in flight already forgot
    // the cache; settling now would write the identity straight back. The
    // module's rule throughout: a missing credential means logout won.
    let Some(installed) = store.load()? else {
        return Ok(AccountState::SignedOut);
    };
    // Existence is not identity: a sign-out followed by a sign-in leaves
    // a credential here too, and nothing here belongs to either of them.
    // The sign-in `cached` was read under has to be the one still
    // installed. A sign-in landing before the call leaves the previous
    // account's identity in hand, which a 304 gives back whole and any
    // failure serves as offline; one landing after settles this answer
    // under a stranger. A rotation is neither, because it keeps the name.
    if installed.sign_in != issued_under {
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
/// identity, so the new credential never pairs with the old name.
///
/// The cache is forgotten twice. The first runs before anything is
/// installed and fails the call, because failing there leaves nothing
/// half-done. The second clears what a read settled between the two
/// writes, holding a credential that was still genuinely installed, and
/// cannot fail the call: the sign-in is committed by then, and saying it
/// failed would leave the caller telling the user the opposite of what
/// the machine holds. A generation surviving that forget is keyed to the
/// previous sign-in and is discarded on read.
pub fn commit_sign_in(
    env: &Env,
    store: &dyn CredentialStore,
    credential: &Credential,
) -> Result<()> {
    let cache = cache(env);
    cache.forget()?;
    client::commit_login(store, credential)?;
    let _ = cache.forget();
    Ok(())
}

/// Revoke, clear, and forget the cached identity — the one sign-out
/// every surface calls. When revocation fails the credential is kept for
/// retry, and so is the cache. Returns false when already signed out.
pub fn sign_out(env: &Env, fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<bool> {
    let was_signed_in = client::logout(fetch, store)?;
    cache(env).forget()?;
    Ok(was_signed_in)
}

/// The identity cache file, named but not yet keyed to a sign-in.
/// `forget` needs no key; the one caller that reads takes one first.
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
