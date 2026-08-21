//! Where the signed-in credential lives: the OS credential store, keyed
//! by the endpoint it belongs to and by whether the build is sandboxed —
//! a staging token can never be replayed against production because the
//! credential says where it is from, and a build kept off the real machine
//! can neither spend nor delete the sign-in the installed app holds. No
//! silent plaintext fallback exists: where no store answers, the caller
//! says so and offers session-only auth.

use crate::error::{CoreError, Result};
use crate::registry::base_url;
use serde::{Deserialize, Serialize};

const SERVICE: &str = "kendex";
/// What a sandboxed build asks for instead. The keyring is named, not
/// pathed, so a debug build sent to its own home still reaches this entry —
/// and `logout` deletes what it reaches, which would be the sign-in the
/// installed app is holding. Separating the name separates the account the
/// same way the endpoint already separates staging from production.
const DEV_SERVICE: &str = "kendex-dev";

fn service(sandboxed: bool) -> &'static str {
    match sandboxed {
        true => DEV_SERVICE,
        false => SERVICE,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Credential {
    pub endpoint: String,
    pub access_token: String,
    pub refresh_token: String,
    pub capabilities: Vec<String>,
}

/// The seam tests replace: the real store is the OS keychain.
pub trait CredentialStore {
    fn save(&self, credential: &Credential) -> Result<()>;
    fn load(&self) -> Result<Option<Credential>>;
    fn clear(&self) -> Result<()>;
}

pub struct KeyringStore;

fn entry() -> Result<keyring::Entry> {
    let endpoint = base_url();
    keyring::Entry::new(service(crate::env::sandboxed()), &endpoint).map_err(|error| {
        CoreError::RegistryUnavailable {
            why: format!("no usable credential store: {error}"),
        }
    })
}

impl CredentialStore for KeyringStore {
    fn save(&self, credential: &Credential) -> Result<()> {
        let json =
            serde_json::to_string(credential).map_err(|error| CoreError::RegistryMalformed {
                why: error.to_string(),
            })?;
        entry()?
            .set_password(&json)
            .map_err(|error| CoreError::RegistryUnavailable {
                why: format!(
                    "the credential store refused to hold the sign-in: {error}. \
                     Nothing was written anywhere else — there is no plaintext fallback."
                ),
            })
    }

    fn load(&self) -> Result<Option<Credential>> {
        match entry()?.get_password() {
            Ok(json) => {
                let credential: Credential =
                    serde_json::from_str(&json).map_err(|error| CoreError::RegistryMalformed {
                        why: format!("the stored credential is unreadable: {error}"),
                    })?;
                // A credential from another endpoint must not be used here.
                if credential.endpoint != base_url() {
                    return Ok(None);
                }
                Ok(Some(credential))
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(CoreError::RegistryUnavailable {
                why: format!("the credential store could not be read: {error}"),
            }),
        }
    }

    fn clear(&self) -> Result<()> {
        match entry()?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(CoreError::RegistryUnavailable {
                why: format!("the credential store refused the removal: {error}"),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sandboxed_build_never_reaches_the_real_sign_in() {
        assert_ne!(service(true), service(false));
    }

    #[test]
    fn only_a_sandboxed_build_gets_the_sandbox_entry() {
        assert_eq!(service(false), SERVICE);
        assert_eq!(service(true), DEV_SERVICE);
    }
}
