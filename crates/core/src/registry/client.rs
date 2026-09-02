//! Rotation-safe bearer calls shared by every authenticated registry API.

use serde::Deserialize;

use crate::error::{CoreError, Result};
use crate::registry::credentials::{Credential, CredentialStore};
use crate::registry::login::TokenPair;
use crate::registry::{Fetch, FetchResponse, base_url};

/// Why an authenticated call did not answer, said in what its caller has
/// to do about it rather than in the error's name.
///
/// A caller holding a cache reads this to decide whether a cached
/// generation may stand in for the answer. Only `Unreachable` is a request
/// that went out; every other failure is this machine's or is news about
/// the sign-in itself, and serving a cache for one of those would tell the
/// user the directory was last reached on some date when nothing this read
/// needed was ever put on the network. A request that went out and found
/// no route is `Unreachable` too — it was sent, and the cache stands in
/// for the answer it did not get. Each variant is chosen at the site that
/// raises the failure, so a local failure added later cannot fall into the
/// remote half by nobody naming it.
#[derive(Debug)]
pub enum CallFailed {
    /// This machine holds no credential for the endpoint.
    NotSignedIn,
    /// The sign-in is dead server-side. The error carries the whole
    /// sentence, remedy included.
    Expired(CoreError),
    /// This machine stopped the request the call needed: the credential
    /// store refused a read or a write, the refresh lock could not be
    /// taken, the request could not be sent. An earlier request in the
    /// same call may well have gone out and come back; what did not is
    /// the one this call needed, so nothing was learned about the
    /// directory.
    Local(CoreError),
    /// The request went out and no usable answer came back, whether the
    /// directory refused it, answered badly, or was never found.
    Unreachable(CoreError),
}

impl From<CallFailed> for CoreError {
    fn from(failed: CallFailed) -> CoreError {
        match failed {
            CallFailed::NotSignedIn => CoreError::NotSignedIn,
            CallFailed::Expired(error)
            | CallFailed::Local(error)
            | CallFailed::Unreachable(error) => error,
        }
    }
}

/// One authenticated call's answer, or why there is none.
pub type Called = std::result::Result<FetchResponse, CallFailed>;

/// One attempt to send the request, read for whether it was ever sent.
///
/// The transport names that itself: a config file it could not write and a
/// curl it could not spawn both raise `CommandNotStarted`, and nothing a
/// sent request can fail with does. Reading that name here is reading the
/// classification the raising site made, not making a second one — which
/// is why this is a single name and never a list of them.
fn sent(attempt: Result<FetchResponse>) -> Called {
    match attempt {
        Ok(response) => Ok(response),
        Err(never_sent @ CoreError::CommandNotStarted { .. }) => Err(CallFailed::Local(never_sent)),
        Err(error) => Err(CallFailed::Unreachable(error)),
    }
}

/// Run one authenticated call, refreshing a rejected access token once.
/// Refresh rotation is locked across processes and saved before retry.
/// Every path that answers `Expired` removes the credential current
/// when its removal lock is acquired, and says in `why` when the store
/// would not give it up.
pub fn with_access(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: impl Fn(&str) -> Result<FetchResponse>,
) -> Called {
    let opened_under = current(store)?;
    let first = sent(call(&opened_under.access_token))?;
    if first.status != 401 {
        return Ok(first);
    }
    rotate_after_rejection(fetch, store, &call, opened_under)
}

/// The credential this call goes out under. A store that refuses the read
/// is not a machine with no credential, and the two answer differently.
fn current(store: &dyn CredentialStore) -> std::result::Result<Credential, CallFailed> {
    match store.load() {
        Ok(Some(credential)) => Ok(credential),
        Ok(None) => Err(CallFailed::NotSignedIn),
        Err(error) => Err(CallFailed::Local(error)),
    }
}

fn rotate_after_rejection(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: &impl Fn(&str) -> Result<FetchResponse>,
    mut rejected: Credential,
) -> Called {
    let mut newer_retries = 0;
    loop {
        let refresh_guard = store.refresh_guard().map_err(CallFailed::Local)?;
        let locked = current(store)?;
        if locked.access_token != rejected.access_token {
            drop(refresh_guard);
            let retried = sent(call(&locked.access_token))?;
            if retried.status != 401 {
                return Ok(retried);
            }
            if newer_retries == 1 {
                return Err(rejected_access(store));
            }
            newer_retries += 1;
            rejected = locked;
            continue;
        }
        return rotate_locked(fetch, store, call, locked, refresh_guard);
    }
}

fn rotate_locked(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: &impl Fn(&str) -> Result<FetchResponse>,
    credential: Credential,
    refresh_guard: Box<dyn crate::registry::credentials::CredentialRefreshGuard + '_>,
) -> Called {
    let pair = match refresh(fetch, &credential.refresh_token) {
        Ok(pair) => pair,
        Err(Refused::Definitive(why)) => {
            // Under the refresh guard this call holds: the family the
            // server just refused is the installed one, and it goes.
            let removal = match store.clear() {
                Ok(()) => Removal::Done,
                Err(error) => Removal::Failed(error),
            };
            return Err(expired(
                removal,
                format!("your sign-in has expired ({why})"),
            ));
        }
        Err(Refused::Transient(error)) => return Err(CallFailed::Unreachable(error)),
        Err(Refused::NeverSent(error)) => return Err(CallFailed::Local(error)),
    };
    let rotated = Credential {
        endpoint: base_url(),
        access_token: pair.access_token,
        refresh_token: pair.refresh_token,
        capabilities: pair.capabilities,
        // Rotation replaces the tokens, never the sign-in they belong to.
        sign_in: credential.sign_in.clone(),
    };
    store.save(&rotated).map_err(CallFailed::Local)?;
    drop(refresh_guard);

    let second = sent(call(&rotated.access_token))?;
    if second.status == 401 {
        return Err(rejected_access(store));
    }
    Ok(second)
}

/// Commit a completed device login without racing refresh or logout, and
/// answer the name minted for it. Surfaces call `me::commit_sign_in`,
/// which drops the previous account's cached identity around this.
pub fn commit_login(store: &dyn CredentialStore, credential: &Credential) -> Result<String> {
    let _guard = store.refresh_guard()?;
    // The sign-in is named here and nowhere else. A device flow mints a
    // refresh token no other sign-in has, so its digest names this one
    // without inventing a second source of uniqueness, and rotation
    // carries the name rather than recomputing it. It is answered rather
    // than left to be recomputed, which would be a second place that
    // decides what a sign-in is called.
    let sign_in = crate::hash::hash_bytes(credential.refresh_token.as_bytes());
    store.save(&Credential {
        sign_in: sign_in.clone(),
        ..credential.clone()
    })?;
    Ok(sign_in)
}

/// Revoke and clear the current sign-in under the credential transaction lock.
/// Returns false when the machine was already signed out. Surfaces call
/// `me::sign_out`, which forgets the cached identity around this.
pub fn logout(fetch: &dyn Fetch, store: &dyn CredentialStore) -> Result<bool> {
    let _guard = store.refresh_guard()?;
    let Some(credential) = store.load()? else {
        return Ok(false);
    };
    crate::registry::login::revoke(fetch, &credential.refresh_token).map_err(|error| {
        CoreError::RegistryUnavailable {
            why: format!("{error} — the local credential was kept so you can retry"),
        }
    })?;
    store.clear()?;
    Ok(true)
}

/// The server rejected the access token used by this call. Re-take the
/// credential transaction, then clear whichever sign-in is current. A login
/// completed while the rejected request was in flight is current here too.
fn rejected_access(store: &dyn CredentialStore) -> CallFailed {
    let removal = match store.refresh_guard() {
        Ok(_guard) => match store.clear() {
            Ok(()) => Removal::Done,
            Err(error) => Removal::Failed(error),
        },
        Err(error) => Removal::Failed(error),
    };
    expired(
        removal,
        "the server does not accept this sign-in".to_owned(),
    )
}

/// What removing the current sign-in did.
enum Removal {
    Done,
    /// It may still be installed: the store refused the guard or delete.
    Failed(CoreError),
}

/// The one verdict both producers answer with. A store that would not give
/// the current credential up never replaces the server's refusal; only
/// `why` grows. The remedy rides in `why` because it depends on what the
/// removal did: a credential still installed makes `kendex login` refuse,
/// and the next attempt removes it. A store that refused the removal does
/// not make this a local failure: the server has ended the sign-in either
/// way, and that is what every surface has to say.
fn expired(removal: Removal, why: String) -> CallFailed {
    CallFailed::Expired(match removal {
        Removal::Done => CoreError::SignInExpired {
            why: format!("{why} — run `kendex login` again"),
        },
        Removal::Failed(error) => CoreError::SignInExpired {
            why: format!(
                "{why}, and the local copy could not be removed: {error} — \
                 run this again once that clears, then `kendex login`"
            ),
        },
    })
}

enum Refused {
    Definitive(String),
    Transient(CoreError),
    /// The rotation request never went out, so nothing about the grant was
    /// learned. Separate from `Transient` because that one is the answer
    /// coming back wrong, which a cached generation may stand in for.
    NeverSent(CoreError),
}

fn refresh(fetch: &dyn Fetch, refresh_token: &str) -> std::result::Result<TokenPair, Refused> {
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    })
    .to_string();
    // Which half of the send failed is the transport's to say, and `sent`
    // is the one place that reads it; this hands the same answer on in
    // `Refused`'s terms rather than judging it a second time.
    let response =
        match sent(fetch.post_json(&format!("{}/api/v1/device/token", base_url()), &body)) {
            Ok(response) => response,
            Err(CallFailed::Local(error)) => return Err(Refused::NeverSent(error)),
            Err(failed) => return Err(Refused::Transient(failed.into())),
        };
    // Only these statuses prove the refresh grant is dead. Timeouts, rate
    // limits, and server failures keep the credential available for retry.
    if matches!(response.status, 400 | 401 | 403) {
        return Err(Refused::Definitive(server_message(&response)));
    }
    if response.status != 200 {
        return Err(Refused::Transient(CoreError::RegistryUnavailable {
            why: server_message(&response),
        }));
    }
    serde_json::from_slice(&response.body).map_err(|error| {
        Refused::Transient(CoreError::RegistryMalformed {
            why: error.to_string(),
        })
    })
}

#[derive(Deserialize)]
struct WireError {
    error: String,
}

pub(super) fn server_message(response: &FetchResponse) -> String {
    serde_json::from_slice::<WireError>(&response.body)
        .map(|wire| wire.error)
        .unwrap_or_else(|_| format!("status {}", response.status))
}
