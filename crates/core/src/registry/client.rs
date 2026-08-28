//! Rotation-safe bearer calls shared by every authenticated registry API.

use serde::Deserialize;

use crate::error::{CoreError, Result};
use crate::registry::credentials::{Credential, CredentialStore};
use crate::registry::login::TokenPair;
use crate::registry::{Fetch, FetchResponse, base_url};

/// One answer and the credential it finally went out under.
///
/// A call reaches that credential three ways: it answers under what it
/// opened with, it rotates to a replacement it made itself, or it adopts
/// one another writer installed while it was in flight. A rotation keeps
/// `sign_in`; the other two carry whatever sign-in they belong to. So a
/// caller that read state before the call compares that state's sign-in
/// against this credential's, and the three routes need no telling apart.
pub struct Authenticated {
    pub response: FetchResponse,
    pub credential: Credential,
}

/// Run one authenticated call, refreshing a rejected access token once.
/// Refresh rotation is locked across processes and saved before retry.
pub fn with_access(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: impl Fn(&str) -> Result<FetchResponse>,
) -> Result<Authenticated> {
    let opened_under = required(store.load()?)?;
    let first = call(&opened_under.access_token)?;
    if first.status != 401 {
        return Ok(Authenticated {
            response: first,
            credential: opened_under,
        });
    }
    rotate_after_rejection(fetch, store, &call, opened_under)
}

fn rotate_after_rejection(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: &impl Fn(&str) -> Result<FetchResponse>,
    mut rejected: Credential,
) -> Result<Authenticated> {
    let mut newer_retries = 0;
    loop {
        let refresh_guard = store.refresh_guard()?;
        let locked = required(store.load()?)?;
        if locked.access_token != rejected.access_token {
            drop(refresh_guard);
            let retried = call(&locked.access_token)?;
            if retried.status != 401 {
                // Somebody else installed this credential mid-call. The
                // answer is theirs, and carries their sign-in.
                return Ok(Authenticated {
                    response: retried,
                    credential: locked,
                });
            }
            if newer_retries == 1 {
                return Err(rejected_access(store, &locked));
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
) -> Result<Authenticated> {
    let pair = match refresh(fetch, &credential.refresh_token) {
        Ok(pair) => pair,
        Err(Refused::Definitive(why)) => {
            // Older installed clients do not take this guard. A network call
            // gives one time to replace the family, so re-read before clearing.
            match store.load()? {
                Some(kept) if kept.refresh_token != credential.refresh_token => {
                    return Err(sign_in_changed("refreshing"));
                }
                Some(_) => store.clear()?,
                None => {}
            }
            return Err(CoreError::SignInExpired {
                why: format!("your sign-in has expired ({why})"),
            });
        }
        Err(Refused::Transient(error)) => return Err(error),
    };
    let rotated = Credential {
        endpoint: base_url(),
        access_token: pair.access_token,
        refresh_token: pair.refresh_token,
        capabilities: pair.capabilities,
        // Rotation replaces the tokens, never the sign-in they belong to.
        sign_in: credential.sign_in.clone(),
    };
    // Mixed-version writers do not know this guard. Never replace a family
    // an older client committed during the refresh request.
    let current = required(store.load()?)?;
    if current.refresh_token != credential.refresh_token {
        return Err(sign_in_changed("refreshing"));
    }
    store.save(&rotated)?;
    drop(refresh_guard);

    let second = call(&rotated.access_token)?;
    if second.status == 401 {
        return Err(rejected_access(store, &rotated));
    }
    Ok(Authenticated {
        response: second,
        credential: rotated,
    })
}

/// Commit a completed device login without racing refresh or logout.
/// Surfaces call `me::commit_sign_in`, which drops the previous
/// account's cached identity around this.
pub fn commit_login(store: &dyn CredentialStore, credential: &Credential) -> Result<()> {
    let _guard = store.refresh_guard()?;
    // The sign-in is named here and nowhere else. A device flow mints a
    // refresh token no other sign-in has, so its digest names this one
    // without inventing a second source of uniqueness, and rotation
    // carries the name rather than recomputing it.
    store.save(&Credential {
        sign_in: crate::hash::hash_bytes(credential.refresh_token.as_bytes()),
        ..credential.clone()
    })
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
    // An older client can commit another family without taking this guard.
    // Re-read after revocation so logout cannot clear that newer sign-in.
    let Some(current) = store.load()? else {
        return Ok(true);
    };
    if current.refresh_token != credential.refresh_token {
        return Err(sign_in_changed("logging out"));
    }
    store.clear()?;
    Ok(true)
}

fn required(credential: Option<Credential>) -> Result<Credential> {
    credential.ok_or(CoreError::NotSignedIn)
}

/// The server rejected the access token this call is authenticated as.
/// That is an expiry only while the sign-in it belongs to is the one
/// installed: a sign-in landing while the request was in flight makes the
/// rejection somebody else's, and calling it an expiry pins one account's
/// answer on another. Only whether the expiry is produced is decided here;
/// what the expiry means for the stored credential is unchanged.
fn rejected_access(store: &dyn CredentialStore, authenticated_as: &Credential) -> CoreError {
    match still_installed(store, authenticated_as) {
        Ok(true) => CoreError::SignInExpired {
            why: "the server does not accept this sign-in".to_owned(),
        },
        Ok(false) => sign_in_changed("authenticating"),
        Err(error) => error,
    }
}

/// Whether the installed sign-in is still this credential's, read under
/// the credential transaction so the answer is not itself racing a
/// rotation. A machine signed out in the meantime is not this
/// credential's either.
fn still_installed(store: &dyn CredentialStore, credential: &Credential) -> Result<bool> {
    let _guard = store.refresh_guard()?;
    Ok(store
        .load()?
        .is_some_and(|installed| installed.refresh_token == credential.refresh_token))
}

pub(super) fn sign_in_changed(action: &str) -> CoreError {
    CoreError::RegistryUnavailable {
        why: format!("the sign-in changed while {action}; retry the request"),
    }
}

enum Refused {
    Definitive(String),
    Transient(CoreError),
}

fn refresh(fetch: &dyn Fetch, refresh_token: &str) -> std::result::Result<TokenPair, Refused> {
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    })
    .to_string();
    let response = fetch
        .post_json(&format!("{}/api/v1/device/token", base_url()), &body)
        .map_err(Refused::Transient)?;
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
