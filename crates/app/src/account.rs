//! Sign-in and submission commands: the device flow from the app's side,
//! the keychain credential, and the submit + status calls the Mine tab
//! uses. The app never sees a GitHub password — a code, a browser tab,
//! done.

use std::path::PathBuf;

use kendex_core::author::{self, SubmitPreflight};
use kendex_core::env::Env;
use kendex_core::error::CoreError;
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

/// Where one poll of the device flow left the sign-in.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum LoginPoll {
    Pending,
    SlowDown,
    Signed,
}

/// One poll; the frontend owns the timer so a closed dialog stops asking.
#[tauri::command(async)]
#[specta::specta]
pub fn account_login_poll(device_code: String) -> Result<LoginPoll, String> {
    match login::poll_once(&CurlFetch, &device_code).map_err(|e| e.to_string())? {
        Poll::Pending => Ok(LoginPoll::Pending),
        Poll::SlowDown => Ok(LoginPoll::SlowDown),
        Poll::Signed(pair) => {
            let env = Env::detect().map_err(|e| e.to_string())?;
            me::commit_sign_in(
                &env,
                &KeyringStore,
                &Credential {
                    endpoint: base_url(),
                    access_token: pair.access_token,
                    refresh_token: pair.refresh_token,
                    capabilities: pair.capabilities,
                    // `commit_login` names the sign-in.
                    sign_in: String::new(),
                },
            )
            .map_err(|e| e.to_string())?;
            Ok(LoginPoll::Signed)
        }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn account_logout() -> Result<(), String> {
    let env = Env::detect().map_err(|e| e.to_string())?;
    me::sign_out(&env, &CurlFetch, &KeyringStore)
        .map(|_| ())
        .map_err(|e| e.to_string())
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

/// Why a call made under the stored sign-in did not answer.
///
/// Expiry is the account ending, not one action failing: the sign-in is
/// dead, and every surface built on the account has to say so. As a
/// message it reaches only the surface that asked, which is how a person
/// gets told their sign-in expired by a dialog while the sidebar goes on
/// naming them. So it is a shape the caller can act on rather than a
/// sentence it would have to recognise by its words.
///
/// `Expired`'s message is the whole sentence, the remedy included,
/// because the surface that shows it has nothing else to say. What
/// became of the local copy is the producer's to state in that sentence,
/// which says so when the copy could not be removed. It is named here
/// rather than documented on the variant because specta hoists a
/// variant's doc above the whole union, where it would read as
/// describing `Failed` too.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum AccountCallRefused {
    Expired { message: String },
    Failed { message: String },
}

/// What a failed authenticated call means to the surfaces the account
/// feeds. Expiry is the one failure that is news about the account
/// itself; every other is this action's alone.
///
/// `NotSignedIn` is among the others deliberately. It says this machine
/// holds no credential, which is the question the account read already
/// answers; moving the account from a call that met it would put a
/// second judge on what `me::load` owns.
fn refused(error: CoreError) -> AccountCallRefused {
    match error {
        expired @ CoreError::SignInExpired { .. } => AccountCallRefused::Expired {
            message: expired.to_string(),
        },
        other => AccountCallRefused::Failed {
            message: other.to_string(),
        },
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_submit(repo: String) -> Result<SubmittedView, AccountCallRefused> {
    let outcome = submit::submit(&CurlFetch, &KeyringStore, &repo).map_err(refused)?;
    Ok(SubmittedView {
        repo: outcome.repo,
        status: outcome.status,
    })
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_submissions() -> Result<Vec<SubmissionRow>, AccountCallRefused> {
    submit::submissions(&CurlFetch, &KeyringStore).map_err(refused)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The account moves on expiry and on nothing else. A refusal that
    /// says the server would not take the submission is about the
    /// submission, and signing the person out over it would be a lie.
    #[test]
    fn expiry_is_the_one_refusal_that_is_news_about_the_account() {
        assert!(matches!(
            refused(CoreError::SignInExpired {
                why: "the server does not accept this sign-in".to_owned()
            }),
            AccountCallRefused::Expired { .. }
        ));
        assert!(matches!(
            refused(CoreError::Authoring {
                message: "that repository is already submitted".to_owned()
            }),
            AccountCallRefused::Failed { .. }
        ));
        assert!(matches!(
            refused(CoreError::NotSignedIn),
            AccountCallRefused::Failed { .. }
        ));
    }

    /// The expired refusal is all the surface has to show, and the whole
    /// sentence is the producer's: the diagnosis and the remedy that fits
    /// what the removal did. This layer passes it through and adds
    /// nothing, so a remedy chosen upstream cannot be overwritten here.
    #[test]
    fn the_expired_refusal_carries_the_remedy_with_the_reason() {
        let sentence = "your sign-in has expired (invalid_grant) \u{2014} run `kendex login` again";
        let refusal = refused(CoreError::SignInExpired {
            why: sentence.to_owned(),
        });
        let AccountCallRefused::Expired { message } = refusal else {
            panic!("a dead sign-in is an expiry");
        };
        assert_eq!(message, sentence);
    }
}
