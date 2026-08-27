//! The disclosure a repo-mutating package gets, and the separate yes that
//! applies it.
//!
//! Not before anything is written. The package's own files land first — they
//! go where kendex manages, and removing the package undoes them — and what
//! stays pending is the repository effect: the thing that changes what
//! happens on every commit, for everyone who commits here, and that removing
//! the package does not undo.
//!
//! Separate on purpose. `apply? [y/N]` is a question about files landing in
//! tool folders, and it never asked about any of that. Declining the effect
//! still installs the package: the person keeps the scripts and arms them
//! later.
//!
//! The yes is spent where it is given. Nothing here writes it down, so no
//! later run inherits it: `kendex refresh` repairs the files a package
//! installs and never arms anything, and a repository is armed by the
//! invocation that says so — this one, or `kendex guard install`.
//!
//! Every value a package chose goes out through `names::shown`. This block
//! is read immediately before a consent prompt, and it is catalog-controlled
//! text: a summary carrying an escape sequence repaints the lines above it,
//! and one carrying a newline forges the shape of the block itself. What is
//! being consented to has to be what is on the screen.

use std::io::{IsTerminal, Write};

use kendex_core::model::Scope;
use kendex_core::repo_effects::{DeclaredEffects, Disclosure};

use super::{CliResult, out, say};

mod disclose;
pub use disclose::disclose;

/// Ask about the disclosed effects and apply the ones that get a yes.
///
/// Asked after the files land, because the scripts an effect runs are the
/// ones this install just wrote. Declining leaves the package installed and
/// its effect unapplied, which is a state and not a failure: the person can
/// change it later with `kendex guard install`.
///
/// Only that. A second `add` of an installed package adds nothing to what
/// the scope carries, so it brings no effect to offer — naming `add` here
/// sent people to a command that would do nothing and say nothing.
pub fn walkthrough(scope: &Scope, shown_to_them: &[Disclosure], allowed: bool) -> CliResult {
    if confirm(shown_to_them, allowed)? {
        for disclosure in shown_to_them {
            apply(scope, &disclosure.declared)?;
        }
        return Ok(());
    }
    for disclosure in shown_to_them {
        say(&format!(
            "{}: installed; its repository changes were not applied",
            disclosure.name
        ));
    }
    Ok(())
}

/// Ask, once, for every pending package at once. A session with no terminal
/// needs `--allow-repo-effects` said out loud: a scripted install or a CI
/// run must never arm a repository's hooks because nobody was there to
/// decline.
pub fn confirm(pending: &[Disclosure], allowed: bool) -> Result<bool, String> {
    if pending.is_empty() {
        return Ok(false);
    }
    if allowed {
        return Ok(true);
    }
    if !std::io::stdin().is_terminal() {
        say("not applied: no terminal to ask at — pass --allow-repo-effects to say yes here");
        return Ok(false);
    }
    let question = match pending.len() {
        1 => format!("apply {}'s repository changes? [y/N] ", pending[0].name),
        n => format!("apply the repository changes of {n} packages? [y/N] "),
    };
    let _ = write!(std::io::stderr(), "{question}");
    let mut answer = String::new();
    std::io::stdin()
        .read_line(&mut answer)
        .map_err(|error| error.to_string())?;
    Ok(matches!(answer.trim(), "y" | "Y" | "yes"))
}

/// Run one package's installer, here and now, and relay what it said.
///
/// Each of the package's streams goes out on its own channel, the way the
/// package wrote them: its summary is what a caller pipes for. A package
/// with nothing to run is a state to name, not a failure.
pub fn apply(scope: &Scope, declared: &DeclaredEffects) -> CliResult {
    match kendex_core::repo_effects::arm(scope, declared) {
        Ok(report) => {
            relay(&report);
            Ok(())
        }
        Err(error @ kendex_core::repo_effects::ArmError::NothingToRun { .. }) => {
            say(&error.to_string());
            Ok(())
        }
        Err(error) => {
            if let kendex_core::repo_effects::ArmError::Failed { report, .. } = &error {
                relay(report);
            }
            Err(error.to_string().into())
        }
    }
}

fn relay(report: &kendex_core::guard::GuardReport) {
    for line in &report.stderr {
        say(line);
    }
    for line in &report.stdout {
        out(line);
    }
}
