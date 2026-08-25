//! Rotation-safe bearer calls shared by every authenticated registry API.

use serde::Deserialize;

use crate::error::{CoreError, Result};
use crate::registry::credentials::{Credential, CredentialStore};
use crate::registry::login::TokenPair;
use crate::registry::{Fetch, FetchResponse, base_url};

/// Run one authenticated call, refreshing a rejected access token once.
/// Refresh rotation is locked across processes and saved before retry.
pub fn with_access(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: impl Fn(&str) -> Result<FetchResponse>,
) -> Result<FetchResponse> {
    let credential = required(store.load()?)?;
    let first = call(&credential.access_token)?;
    if first.status != 401 {
        return Ok(first);
    }
    rotate_after_rejection(fetch, store, &call, credential)
}

fn rotate_after_rejection(
    fetch: &dyn Fetch,
    store: &dyn CredentialStore,
    call: &impl Fn(&str) -> Result<FetchResponse>,
    mut rejected: Credential,
) -> Result<FetchResponse> {
    let mut newer_retries = 0;
    loop {
        let refresh_guard = store.refresh_guard()?;
        let locked = required(store.load()?)?;
        if locked.access_token != rejected.access_token {
            drop(refresh_guard);
            let retried = call(&locked.access_token)?;
            if retried.status != 401 {
                return Ok(retried);
            }
            if newer_retries == 1 {
                return Err(rejected_access());
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
) -> Result<FetchResponse> {
    let pair = match refresh(fetch, &credential.refresh_token) {
        Ok(pair) => pair,
        Err(Refused::Definitive(why)) => {
            let ours = store
                .load()?
                .is_none_or(|kept| kept.refresh_token == credential.refresh_token);
            if ours {
                store.clear()?;
            }
            return Err(CoreError::Authoring {
                message: format!("your sign-in has expired ({why}) — run `kendex login` again"),
            });
        }
        Err(Refused::Transient(error)) => return Err(error),
    };
    let rotated = Credential {
        endpoint: base_url(),
        access_token: pair.access_token,
        refresh_token: pair.refresh_token,
        capabilities: pair.capabilities,
    };
    let current = required(store.load()?)?;
    if current.refresh_token != credential.refresh_token {
        drop(refresh_guard);
        let retried = call(&current.access_token)?;
        return match retried.status {
            401 => Err(rejected_access()),
            _ => Ok(retried),
        };
    }
    store.save(&rotated)?;
    drop(refresh_guard);

    let second = call(&rotated.access_token)?;
    if second.status == 401 {
        return Err(rejected_access());
    }
    Ok(second)
}

/// Commit a completed device login without racing refresh or logout.
pub fn commit_login(store: &dyn CredentialStore, credential: &Credential) -> Result<()> {
    let _guard = store.refresh_guard()?;
    store.save(credential)
}

/// Revoke and clear the current sign-in under the credential transaction lock.
/// Returns false when the machine was already signed out.
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
    let current = required(store.load()?)?;
    if current.refresh_token != credential.refresh_token {
        return Err(CoreError::RegistryUnavailable {
            why: "the sign-in changed during logout; retry against the current sign-in".to_owned(),
        });
    }
    store.clear()?;
    Ok(true)
}

fn required(credential: Option<Credential>) -> Result<Credential> {
    credential.ok_or_else(|| CoreError::Authoring {
        message: "not signed in — run `kendex login` first".to_owned(),
    })
}

fn rejected_access() -> CoreError {
    CoreError::Authoring {
        message: "the server does not accept this sign-in — run `kendex login` again".to_owned(),
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
