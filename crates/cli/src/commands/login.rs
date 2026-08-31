//! `kendex login` and `kendex logout`: the device flow from the terminal
//! side. Sign-in needs no password here — a code, a browser tab, done —
//! and the credential lives in the OS keychain or nowhere.

use super::say;
use kendex_core::env::Env;
use kendex_core::error::Result;
use kendex_core::registry::credentials::{Credential, CredentialStore, KeyringStore};
use kendex_core::registry::login::{self, Poll};
use kendex_core::registry::me;
use kendex_core::registry::{CurlFetch, base_url};

pub fn login() -> Result<()> {
    let fetch = CurlFetch;
    let store = KeyringStore;
    if let Ok(Some(_)) = store.load() {
        say(&format!(
            "Already signed in to {} — run `kendex logout` first to switch.",
            base_url()
        ));
        return Ok(());
    }
    let started = login::start(&fetch, "kendex CLI")?;
    say(&format!(
        "First, open:  {}?code={}",
        started.verification_url, started.user_code
    ));
    say(&format!("Your code:    {}", started.user_code));
    say("");
    say(&format!(
        "Waiting for approval… (expires in {} minutes)",
        started.expires_in_seconds / 60
    ));

    let mut interval = started.interval_seconds;
    loop {
        std::thread::sleep(std::time::Duration::from_secs(interval));
        match login::poll_once(&fetch, &started.device_code)? {
            Poll::Pending => {}
            Poll::SlowDown => interval += 5,
            Poll::Signed(pair) => {
                me::commit_sign_in(
                    &Env::detect()?,
                    &store,
                    &Credential {
                        endpoint: base_url(),
                        access_token: pair.access_token,
                        refresh_token: pair.refresh_token,
                        capabilities: pair.capabilities,
                        // `commit_login` names the sign-in.
                        sign_in: String::new(),
                    },
                )?;
                say("Signed in. The credential is in your system keychain.");
                return Ok(());
            }
        }
    }
}

pub fn logout() -> Result<()> {
    if !me::sign_out(&Env::detect()?, &CurlFetch, &KeyringStore)? {
        say("Not signed in.");
        return Ok(());
    }
    say("Signed out — every device credential in that sign-in is now dead.");
    Ok(())
}
