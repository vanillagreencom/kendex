//! Where the signed-in credential lives: the OS credential store, keyed
//! by the endpoint it belongs to and by whether the build is sandboxed —
//! a staging token can never be replayed against production because the
//! credential says where it is from, and a build kept off the real machine
//! can neither spend nor delete the sign-in the installed app holds. No
//! silent plaintext fallback exists: where no store answers, the caller
//! says so.

use crate::error::{CoreError, Result};
use crate::fs::LockedFile;
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
    /// Names the sign-in itself. Minted when one is committed and copied
    /// through every rotation, so the tokens say who is talking now and
    /// this says which sign-in they belong to — the thing a cache has to
    /// be keyed to, since a rotation would otherwise strand it. Defaulted
    /// because this is read back from the keychain: a credential stored
    /// before the name existed still parses, and its empty name matches
    /// no cache written since, which costs one refetch. Only one such
    /// credential can exist, because every sign-in since mints a name.
    #[serde(default)]
    pub sign_in: String,
}

/// The seam tests replace: the real store is the OS keychain.
pub trait CredentialStore {
    fn save(&self, credential: &Credential) -> Result<()>;
    fn load(&self) -> Result<Option<Credential>>;
    fn clear(&self) -> Result<()>;
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>>;
}

/// Held for the load-refresh-save credential transaction; dropping releases it.
pub trait CredentialRefreshGuard {}

impl CredentialRefreshGuard for LockedFile {}

pub struct KeyringStore;

struct CredentialIdentity {
    service: &'static str,
    endpoint: String,
}

/// The named keychain entry and its transaction lock share this identity.
fn active_identity() -> CredentialIdentity {
    CredentialIdentity {
        service: service(crate::env::sandboxed()),
        endpoint: base_url(),
    }
}

fn transaction_lock_file(
    env: &crate::env::Env,
    identity: &CredentialIdentity,
) -> std::path::PathBuf {
    let material = format!("{}\0{}", identity.service, identity.endpoint);
    let digest = crate::hash::hash_bytes(material.as_bytes());
    env.real_home()
        .join(format!(".kendex-credential-{digest}.lock"))
}

/// Which keychain call would not answer. Every arm answers with
/// `CoreError::CredentialStoreUnavailable`, whose doc holds why.
enum StoreRefusal {
    /// No keychain answered, so no entry could be opened.
    NoStore,
    /// The sign-in could not be written.
    Save,
    /// The stored sign-in could not be read back.
    Load,
    /// The stored sign-in could not be removed.
    Clear,
}

impl StoreRefusal {
    fn refused(self, error: &keyring::Error) -> CoreError {
        CoreError::CredentialStoreUnavailable {
            why: match self {
                Self::NoStore => format!("no keychain answered: {error}"),
                Self::Save => format!(
                    "the sign-in was refused: {error}. Nothing was written anywhere \
                     else — there is no plaintext fallback."
                ),
                Self::Load => format!("the stored sign-in could not be read: {error}"),
                Self::Clear => format!("the removal was refused: {error}"),
            },
        }
    }
}

fn entry() -> Result<keyring::Entry> {
    let identity = active_identity();
    keyring::Entry::new(identity.service, &identity.endpoint)
        .map_err(|error| StoreRefusal::NoStore.refused(&error))
}

impl CredentialStore for KeyringStore {
    fn save(&self, credential: &Credential) -> Result<()> {
        let json =
            serde_json::to_string(credential).map_err(|error| CoreError::RegistryMalformed {
                why: error.to_string(),
            })?;
        entry()?
            .set_password(&json)
            .map_err(|error| StoreRefusal::Save.refused(&error))
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
            Err(error) => Err(StoreRefusal::Load.refused(&error)),
        }
    }

    fn clear(&self) -> Result<()> {
        match entry()?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(StoreRefusal::Clear.refused(&error)),
        }
    }

    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        let env = crate::env::Env::detect()?;
        let path = transaction_lock_file(&env, &active_identity());
        let parent = path
            .parent()
            .ok_or_else(|| CoreError::io(&path, std::io::Error::other("path has no parent")))?;
        std::fs::create_dir_all(parent).map_err(|error| CoreError::io(parent, error))?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            match LockedFile::try_exclusive_no_follow(&path) {
                Ok(Some(lock)) => return Ok(Box::new(lock)),
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Ok(None) => return Err(CoreError::CredentialRefreshBusy { lock: path }),
                Err(error) => return Err(CoreError::io(&path, error)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The keychain holds credentials written by earlier builds. A field
    /// they cannot carry must never decide whether they parse: failing
    /// here signs the machine out, where an unnamed sign-in only costs a
    /// refetch.
    #[test]
    fn a_credential_stored_before_the_sign_in_had_a_name_still_reads() {
        let stored = r#"{"endpoint":"https://kendex.ai","access_token":"kxa",
                         "refresh_token":"kxr","capabilities":[]}"#;
        let credential: Credential =
            serde_json::from_str(stored).expect("a stored credential still reads");
        assert_eq!(credential.refresh_token, "kxr");
        assert!(credential.sign_in.is_empty());
    }

    #[test]
    fn a_sandboxed_build_never_reaches_the_real_sign_in() {
        assert_ne!(service(true), service(false));
    }

    /// The wiring, not the outcome: which service is right depends on the
    /// profile and on the opt-out, so an absolute answer here would be
    /// wrong under `cargo test --release` and wrong again in a shell that
    /// exports `KENDEX_REAL_HOME=1`. What must hold in every one of those
    /// is that the entry takes its service from the sandbox rather than
    /// naming one itself; which service that yields is the case above.
    #[test]
    fn the_entry_takes_its_service_from_the_sandbox() {
        assert_eq!(active_identity().service, service(crate::env::sandboxed()));
    }

    #[test]
    fn only_a_sandboxed_build_gets_the_sandbox_entry() {
        assert_eq!(service(false), SERVICE);
        assert_eq!(service(true), DEV_SERVICE);
    }

    #[test]
    fn transaction_lock_uses_named_identity_not_data_root() {
        let first = crate::env::Env::fake("/data/one", crate::env::FakeOs::Linux)
            .with_real_home("/home/pat");
        let second = crate::env::Env::fake("/data/two", crate::env::FakeOs::Linux)
            .with_real_home("/home/pat");
        let identity = CredentialIdentity {
            service: SERVICE,
            endpoint: "https://kendex.ai".to_owned(),
        };

        assert_eq!(
            transaction_lock_file(&first, &identity),
            transaction_lock_file(&second, &identity)
        );
        assert_ne!(
            transaction_lock_file(
                &first,
                &CredentialIdentity {
                    service: DEV_SERVICE,
                    endpoint: identity.endpoint.clone(),
                }
            ),
            transaction_lock_file(&first, &identity)
        );
    }
}
