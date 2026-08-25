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
    let mut credential = store.load()?.ok_or_else(|| CoreError::Authoring {
        message: "not signed in — run `kendex login` first".to_owned(),
    })?;
    let first = call(&credential.access_token)?;
    if first.status != 401 {
        return Ok(first);
    }

    let refresh_guard = store.refresh_guard()?;
    let locked = store.load()?.ok_or_else(|| CoreError::Authoring {
        message: "not signed in — run `kendex login` first".to_owned(),
    })?;
    if locked.access_token != credential.access_token {
        credential = locked;
        let retried = call(&credential.access_token)?;
        if retried.status != 401 {
            return Ok(retried);
        }
    } else {
        credential = locked;
    }

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
    store.save(&rotated)?;
    drop(refresh_guard);

    let second = call(&rotated.access_token)?;
    if second.status == 401 {
        return Err(CoreError::Authoring {
            message: "the server does not accept this sign-in — run `kendex login` again"
                .to_owned(),
        });
    }
    Ok(second)
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
    if (400..500).contains(&response.status) {
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
