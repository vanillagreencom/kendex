//! Sign-in and submission commands: the device flow from the app's side,
//! the keychain credential, and the submit + status calls the Mine tab
//! uses. The app never sees a GitHub password — a code, a browser tab,
//! done.

use std::path::PathBuf;

use kendex_core::author::{self, SubmitPreflight};
use kendex_core::env::Env;
use kendex_core::registry::client;
use kendex_core::registry::credentials::{Credential, KeyringStore};
use kendex_core::registry::login::{self, Poll};
use kendex_core::registry::me::{self, AccountState};
use kendex_core::registry::submit::{self, SubmissionRow};
use kendex_core::registry::{CurlFetch, base_url};
use serde::{Deserialize, Serialize};
use specta::Type;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AccountStatus {
    pub state: AccountState,
    pub endpoint: String,
}

#[tauri::command(async)]
#[specta::specta]
pub fn account_status() -> Result<AccountStatus, String> {
    let env = Env::detect().map_err(|e| e.to_string())?;
    let state = me::load(&env, &CurlFetch, &KeyringStore).map_err(|e| e.to_string())?;
    Ok(AccountStatus {
        state,
        endpoint: base_url(),
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct LoginStart {
    pub device_code: String,
    pub user_code: String,
    /// The page to open, with the code already in it.
    pub verification_url: String,
    pub interval_seconds: u32,
}

#[tauri::command(async)]
#[specta::specta]
pub fn account_login_start() -> Result<LoginStart, String> {
    let started = login::start(&CurlFetch, "kendex app").map_err(|e| e.to_string())?;
    Ok(LoginStart {
        verification_url: format!("{}?code={}", started.verification_url, started.user_code),
        device_code: started.device_code,
        user_code: started.user_code,
        interval_seconds: started.interval_seconds as u32,
    })
}

/// One poll; the frontend owns the timer so a closed dialog stops asking.
#[tauri::command(async)]
#[specta::specta]
pub fn account_login_poll(device_code: String) -> Result<String, String> {
    match login::poll_once(&CurlFetch, &device_code).map_err(|e| e.to_string())? {
        Poll::Pending => Ok("pending".to_owned()),
        Poll::SlowDown => Ok("slow-down".to_owned()),
        Poll::Signed(pair) => {
            client::commit_login(
                &KeyringStore,
                &Credential {
                    endpoint: base_url(),
                    access_token: pair.access_token,
                    refresh_token: pair.refresh_token,
                    capabilities: pair.capabilities,
                },
            )
            .map_err(|e| e.to_string())?;
            Ok("signed".to_owned())
        }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn account_logout() -> Result<(), String> {
    client::logout(&CurlFetch, &KeyringStore).map_err(|e| e.to_string())?;
    let env = Env::detect().map_err(|e| e.to_string())?;
    me::forget(&env).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_submit_preflight(path: PathBuf) -> Result<SubmitPreflight, String> {
    author::submit_preflight(&path, &CurlFetch).map_err(|e| e.to_string())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SubmittedView {
    pub repo: String,
    pub status: String,
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_submit(repo: String) -> Result<SubmittedView, String> {
    let outcome = submit::submit(&CurlFetch, &KeyringStore, &repo).map_err(|e| e.to_string())?;
    Ok(SubmittedView {
        repo: outcome.repo,
        status: outcome.status,
    })
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_submissions() -> Result<Vec<SubmissionRow>, String> {
    submit::submissions(&CurlFetch, &KeyringStore).map_err(|e| e.to_string())
}
