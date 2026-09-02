//! Who is signed in: GET /api/v1/me through the rotation-safe bearer
//! client. The last good answer is cached through [`super::generation`]
//! with no TTL, because "signed in", "offline" and "expired" can only be
//! told apart by asking the server; when the network is away this
//! sign-in's cached identity is served as the offline state instead of
//! nothing.

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::registry::client::{self, CallFailed, server_message};
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

/// Why an account read could not answer at all.
///
/// [`AccountState`] is what a read settles on; this is the absence of an
/// answer. A surface holding a name from an earlier read has to choose
/// between showing it as the last one confirmed and saying nothing new
/// was learned, and only the difference between "the directory did not
/// answer" and "this machine refused" settles that choice.
#[derive(Debug)]
pub enum AccountUnread {
    /// This machine stopped the read: the credential store refused, the
    /// refresh lock could not be taken, the request could not be sent. An
    /// earlier request may well have gone out and come back; the answer
    /// this read needed did not, so nothing about the directory is known.
    Local(CoreError),
    /// The request went out and no identity could be settled from what
    /// came back, with nothing cached to stand in.
    Unreachable(CoreError),
}

impl AccountUnread {
    /// The failure itself, for a surface that shows its sentence.
    pub fn error(&self) -> &CoreError {
        match self {
            AccountUnread::Local(error) | AccountUnread::Unreachable(error) => error,
        }
    }
}

/// The wire shape of GET /api/v1/me, exactly as the contract fixture says.
#[derive(Deserialize)]
struct WireMe {
    name: String,
    github_login: Option<String>,
}

/// Ask who is signed in. An absent credential is `SignedOut`; a dead credential is
/// `Expired` and its cached identity is dropped; an unreachable or
/// misbehaving server serves the cached identity as `Offline`, and errors
/// only with nothing cached to serve. A failure on this machine is none of
/// those: [`client::with_access`] hands back which half of the call failed,
/// so a local one errors with its own sentence however warm the cache is
/// and never reaches [`GenerationFile::settle`], whose every error is a
/// fetch that did not land. A store that refused the removal behind the
/// server's rejection rides in that `SignInExpired`'s `why` and still
/// answers `Expired`. The cache key names the sign-in this read opened with
/// rather than either token, so a refresh rotation leaves it readable. The
/// store gets no final read after the authenticated call: a sign-out or
/// account switch landing in that final request window does not change this
/// call's answer.
pub fn load(
    env: &Env,
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
) -> std::result::Result<AccountState, AccountUnread> {
    let Some(credential) = store.load().map_err(AccountUnread::Local)? else {
        return Ok(AccountState::SignedOut);
    };
    // The sign-in's own name, which a rotation carries and only a new
    // sign-in changes. The cache read next belongs to this one.
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
        Ok(response) => Ok(response),
        // Logout won a race with this read: the re-login state without
        // refreshing, exactly as if the credential had been gone up front.
        Err(CallFailed::NotSignedIn) => return Ok(AccountState::SignedOut),
        // Producing this removed whichever credential was current when the
        // removal lock was acquired, or said in `why` that the store would
        // not give it up. The identity this read opened with is forgotten;
        // another sign-in would discard it by key anyway.
        //
        // A generation that will not delete is left where it is, for the
        // same reason one that will not be written does not fail a read:
        // the expiry is what this read learned, and reporting a refused
        // unlink instead would leave the surface naming the person as
        // signed in under a credential the server has already ended. What
        // stays behind is keyed to a sign-in nothing will open with again.
        Err(CallFailed::Expired(_)) => {
            let _ = cache.forget();
            return Ok(AccountState::Expired);
        }
        // This machine stopped the request this read needed. Serving the
        // cache as `Offline` would tell the user the directory was last
        // reached on some date, when nothing about it was ever in doubt.
        Err(CallFailed::Local(error)) => return Err(AccountUnread::Local(error)),
        // The request went out and no usable answer came back, which is
        // exactly what a cached generation stands in for.
        Err(CallFailed::Unreachable(error)) => Err(error),
    };
    let loaded = cache
        .settle(cached, fetched, parse, |response| {
            CoreError::RegistryUnavailable {
                why: server_message(response),
            }
        })
        .map_err(AccountUnread::Unreachable)?;
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
