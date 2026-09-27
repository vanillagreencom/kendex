//! `kendex login` and `kendex logout`: the device flow from the terminal
//! side. Sign-in needs no password here — a code, a browser tab, done —
//! and the credential lives in the OS keychain or nowhere.

use crate::ui::{self, Span, Status, Style};
use kendex_core::env::Env;
use kendex_core::error::Result;
use kendex_core::registry::credentials::{Credential, CredentialStore, KeyringStore};
use kendex_core::registry::login::{self, Poll};
use kendex_core::registry::me;
use kendex_core::registry::{CurlFetch, base_url};

pub fn login() -> Result<()> {
    let style = ui::style();
    ui::stderr(&style.header("login", &base_url()));
    let fetch = CurlFetch;
    let store = KeyringStore;
    // A store that refuses the read is not a machine with no credential:
    // starting the device flow would spend the user's approval on a
    // sign-in the keychain has already said it will not hold.
    if store.load()?.is_some() {
        ui::stderr(&already_signed_in(&style, &base_url()));
        return Ok(());
    }
    let started = login::start(&fetch, "kendex CLI")?;
    ui::stderr(&approval(&style, &started));

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
                ui::stderr(&outcome(&style, Outcome::SignedIn));
                return Ok(());
            }
        }
    }
}

pub fn logout() -> Result<()> {
    let style = ui::style();
    ui::stderr(&style.header("logout", &base_url()));
    if !me::sign_out(&Env::detect()?, &CurlFetch, &KeyringStore)? {
        ui::stderr(&outcome(&style, Outcome::NotSignedIn));
        return Ok(());
    }
    ui::stderr(&outcome(&style, Outcome::SignedOut));
    Ok(())
}

#[derive(Clone, Copy)]
enum Outcome {
    SignedIn,
    SignedOut,
    NotSignedIn,
}

fn outcome(style: &Style, outcome: Outcome) -> Vec<String> {
    let (status, text) = match outcome {
        Outcome::SignedIn => (
            Status::Done,
            "Signed in. Your sign-in is kept in your system keychain.",
        ),
        Outcome::SignedOut => (
            Status::Done,
            "Signed out. kendex.ai no longer accepts this sign-in.",
        ),
        Outcome::NotSignedIn => (Status::Notice, "Not signed in."),
    };
    style.summary(status, text)
}

fn already_signed_in(style: &Style, endpoint: &str) -> Vec<String> {
    style.note(&[
        Span::Prose("Already signed in to "),
        Span::Command(endpoint),
        Span::Prose(" — run `"),
        Span::Command("kendex logout"),
        Span::Prose("` first to switch."),
    ])
}

fn approval(style: &Style, started: &login::DeviceStart) -> Vec<String> {
    let url = format!("{}?code={}", started.verification_url, started.user_code);
    let mut lines = style.note(&[Span::Prose("First, open:  "), Span::Command(&url)]);
    lines.extend(style.note(&[
        Span::Prose("Your code:    "),
        Span::Command(&started.user_code),
    ]));
    lines.extend(style.note(&[Span::Prose("")]));
    lines.extend(style.note(&[Span::Prose(&format!(
        "Waiting for approval… (expires in {} minutes)",
        started.expires_in_seconds / 60
    ))]));
    lines
}

#[cfg(test)]
mod tests;
