//! The client half of `kendex login`: start a device authorization, poll
//! for its outcome, revoke on logout. The protocol peer is kendex.ai's
//! device routes; nothing here ever sees a GitHub credential.

use crate::error::{CoreError, Result};
use crate::registry::{Fetch, base_url};
use serde::Deserialize;

pub const DEFAULT_CAPABILITIES: &[&str] = &["submission:read", "submission:write"];

#[derive(Debug, Clone)]
pub struct DeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub interval_seconds: u64,
    pub expires_in_seconds: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TokenPair {
    pub access_token: String,
    pub refresh_token: String,
    pub capabilities: Vec<String>,
}

#[derive(Debug)]
pub enum Poll {
    Pending,
    SlowDown,
    Signed(TokenPair),
}

#[derive(Deserialize)]
struct WireStart {
    device_code: String,
    user_code: String,
    verification_url: String,
    interval: u64,
    expires_in: u64,
}

#[derive(Deserialize)]
struct WireError {
    error: String,
}

/// `client_label` names the asking surface ("kendex app", "kendex CLI") in
/// the request. The server does not read the field yet.
pub fn start(fetch: &dyn Fetch, client_label: &str) -> Result<DeviceStart> {
    let body = serde_json::json!({
        "capabilities": DEFAULT_CAPABILITIES,
        "client": client_label,
    })
    .to_string();
    let response = fetch.post_json(&format!("{}/api/v1/device/code", base_url()), &body)?;
    if response.status != 200 {
        return Err(CoreError::RegistryUnavailable {
            why: format!("sign-in could not start ({})", response.status),
        });
    }
    let wire: WireStart =
        serde_json::from_slice(&response.body).map_err(|error| CoreError::RegistryMalformed {
            why: error.to_string(),
        })?;
    Ok(DeviceStart {
        device_code: wire.device_code,
        user_code: wire.user_code,
        verification_url: wire.verification_url,
        interval_seconds: wire.interval.clamp(1, 60),
        expires_in_seconds: wire.expires_in,
    })
}

/// One poll. Pending and slow-down are states to wait through; denial and
/// expiry are final answers, said as errors with the person's words.
pub fn poll_once(fetch: &dyn Fetch, device_code: &str) -> Result<Poll> {
    let body = serde_json::json!({ "device_code": device_code }).to_string();
    let response = fetch.post_json(&format!("{}/api/v1/device/token", base_url()), &body)?;
    if response.status == 200 {
        let pair: TokenPair = serde_json::from_slice(&response.body).map_err(|error| {
            CoreError::RegistryMalformed {
                why: error.to_string(),
            }
        })?;
        return Ok(Poll::Signed(pair));
    }
    let wire: WireError = serde_json::from_slice(&response.body).unwrap_or(WireError {
        error: format!("status {}", response.status),
    });
    match wire.error.as_str() {
        "authorization_pending" => Ok(Poll::Pending),
        "slow_down" => Ok(Poll::SlowDown),
        "denied" => Err(CoreError::RegistryUnavailable {
            why: "you denied this sign-in at kendex.ai/device".into(),
        }),
        "expired" => Err(CoreError::RegistryUnavailable {
            why: "the code expired before it was approved — run login again".into(),
        }),
        other => Err(CoreError::RegistryUnavailable {
            why: format!("sign-in failed ({other})"),
        }),
    }
}

/// Revoking either token ends the whole family server-side; the server
/// answers ok even for unknown tokens, so logout never fails loudly for
/// a credential that is already gone.
pub fn revoke(fetch: &dyn Fetch, token: &str) -> Result<()> {
    let body = serde_json::json!({ "token": token }).to_string();
    let response = fetch.post_json(&format!("{}/api/v1/tokens/revoke", base_url()), &body)?;
    if response.status != 200 {
        return Err(CoreError::RegistryUnavailable {
            why: format!("the sign-out could not be recorded ({})", response.status),
        });
    }
    Ok(())
}
