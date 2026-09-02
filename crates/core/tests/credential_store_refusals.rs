//! What the real `KeyringStore` reports when the OS keychain refuses.
//!
//! The keychain is replaced through keyring's own builder seam rather than
//! faked at the `CredentialStore` trait, so the four call sites in
//! `credentials.rs` are the code under test. `set_default_credential_builder`
//! is process-global, which is why this is its own test binary and why the
//! cases hold `BACKEND` across the swap.

use std::any::Any;
use std::sync::{Mutex, MutexGuard};

use kendex_core::error::CoreError;
use kendex_core::registry::credentials::{Credential as SignIn, CredentialStore, KeyringStore};
use keyring::credential::{Credential, CredentialApi, CredentialBuilderApi, CredentialPersistence};

/// Serializes the swap of the process-global builder with the call that
/// reads it. Poisoning is ignored: a failed case has already reported
/// itself, and blocking the rest behind it would hide theirs.
static BACKEND: Mutex<()> = Mutex::new(());

fn held() -> MutexGuard<'static, ()> {
    BACKEND.lock().unwrap_or_else(|held| held.into_inner())
}

/// What a locked keyring answers. Every case uses it, so the assertion
/// that the message still carries the OS reason has one string to look for.
fn locked() -> keyring::Error {
    keyring::Error::NoStorageAccess(Box::new(std::io::Error::other("the keyring is locked")))
}

/// A keychain that refuses. `at_build` refuses before an entry exists,
/// which is the only way to reach `entry()`'s refusal; otherwise the entry
/// is built and every call on it refuses.
struct Refusing {
    at_build: bool,
}

impl CredentialBuilderApi for Refusing {
    fn build(
        &self,
        _target: Option<&str>,
        _service: &str,
        _user: &str,
    ) -> keyring::Result<Box<Credential>> {
        match self.at_build {
            true => Err(locked()),
            false => Ok(Box::new(RefusingEntry)),
        }
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn persistence(&self) -> CredentialPersistence {
        CredentialPersistence::EntryOnly
    }
}

struct RefusingEntry;

impl CredentialApi for RefusingEntry {
    fn set_secret(&self, _secret: &[u8]) -> keyring::Result<()> {
        Err(locked())
    }

    fn get_secret(&self) -> keyring::Result<Vec<u8>> {
        Err(locked())
    }

    fn delete_credential(&self) -> keyring::Result<()> {
        Err(locked())
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

fn install(at_build: bool) {
    keyring::set_default_credential_builder(Box::new(Refusing { at_build }));
}

fn stored() -> SignIn {
    SignIn {
        endpoint: "https://kendex.ai".to_owned(),
        access_token: "kxa".to_owned(),
        refresh_token: "kxr".to_owned(),
        capabilities: Vec::new(),
        sign_in: "sign-in-ada".to_owned(),
    }
}

#[track_caller]
fn names_the_store(error: &CoreError, cause: &str) {
    assert!(
        matches!(error, CoreError::CredentialStoreUnavailable { .. }),
        "a keychain refusal is not a registry outage: {error:?}"
    );
    let shown = error.to_string();
    assert!(
        !shown.contains("community directory"),
        "the user is sent to check a working network: {shown}"
    );
    assert!(
        shown.contains(cause),
        "the call that refused is unnamed: {shown}"
    );
    assert!(
        shown.contains("the keyring is locked"),
        "the reason the OS gave is dropped: {shown}"
    );
}

#[test]
fn no_keychain_at_all_refuses_every_call_as_the_store() {
    let _held = held();
    install(true);

    for error in [
        KeyringStore.save(&stored()).expect_err("save refuses"),
        KeyringStore.load().expect_err("load refuses"),
        KeyringStore.clear().expect_err("clear refuses"),
    ] {
        names_the_store(&error, "no keychain answered");
    }
}

#[test]
fn a_refused_write_names_the_store() {
    let _held = held();
    install(false);

    names_the_store(
        &KeyringStore.save(&stored()).expect_err("save refuses"),
        "the sign-in was refused",
    );
}

#[test]
fn a_refused_read_names_the_store() {
    let _held = held();
    install(false);

    names_the_store(
        &KeyringStore.load().expect_err("load refuses"),
        "the stored sign-in could not be read",
    );
}

#[test]
fn a_refused_removal_names_the_store() {
    let _held = held();
    install(false);

    names_the_store(
        &KeyringStore.clear().expect_err("clear refuses"),
        "the removal was refused",
    );
}
