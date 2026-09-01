//! The disclosure a repo-mutating package gets, and the separate yes that
//! applies it.
//!
//! Not before anything is written. The package's own files land first — they
//! go where kendex manages, and removing the package undoes them — and what
//! stays pending is the repository effect: the thing that changes what
//! happens on every commit, for everyone who commits here, and that trashing
//! the package's files does not undo. Undoing it is the package's declared
//! uninstaller, which `undo` runs when the package leaves.
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
//! Every value a package declared goes out through the `ui` seam, which
//! escapes it. This block is read immediately before a consent prompt, and
//! it is catalog-controlled text: a summary carrying an escape sequence
//! repaints the lines above it, and one carrying a newline forges the shape
//! of the block itself. What is being consented to has to be what is on the
//! screen.
//!
//! What a package's installer prints when it runs is not part of that
//! block: [`apply`] relays it after the consent, each stream on the
//! channel it was written to. Its summary is what a caller pipes for, so
//! that one goes out byte for byte; its stderr is read by a person and
//! goes out escaped like any other line.

use std::io::IsTerminal;

use kendex_core::engine::EngineReport;
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::repo_effects::{DeclaredEffects, Disclosure, Spoken};

use super::{CliResult, answer, say};

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
/// The repository-effects account and its separate yes, run so that what
/// the caller owes for what it already wrote happens whatever the answer.
///
/// The prompt comes after the write by design: the script an effect runs
/// is the one the install just put on disk. That puts a fallible call
/// between a write and the run's closing line, and a `?` there returned
/// to `main` with disk changed, no snapshot recorded and no ledger said —
/// so the next session-start check read a stale snapshot for a scope that
/// had just been written.
///
/// `finalize` runs on every path: a yes, a decline, a failure, and a
/// cancel. Only then does the error propagate, carrying the code the
/// prompt produced, so a cancel still ends the run and still exits 130.
pub fn disclose_and_finish(
    env: &Env,
    scope: &Scope,
    effects: &[DeclaredEffects],
    allowed: bool,
    finalize: impl FnOnce(),
) -> CliResult {
    let walked = disclose(env, scope, effects)
        .and_then(|shown_to_them| walkthrough(scope, &shown_to_them, allowed));
    finalize();
    walked
}

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
pub fn confirm(pending: &[Disclosure], allowed: bool) -> Result<bool, Box<dyn std::error::Error>> {
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
        1 => format!("apply {}'s repository changes?", pending[0].name),
        n => format!("apply the repository changes of {n} packages?"),
    };
    // The shared prompt, not a write of our own: it draws whatever block
    // is still open before it reads, so the question cannot reach the
    // reader ahead of the disclosure it is about. Its plain rendering is
    // the same bytes this site used to write itself, `[y/N] ` included.
    // Handed on as it came back, never as its text: a cancel is an
    // io::Error whose kind main reads to exit 130, and a String would
    // leave it looking like any other failure.
    Ok(crate::ui::confirm(&question)?)
}

/// Run one package's installer, here and now, and relay what it said.
///
/// Each of the package's streams goes out on the channel it was written
/// to: its summary is what a caller pipes for, so that one is relayed byte
/// for byte rather than escaped like a line of kendex's own.
/// The consent that let this run was given against the disclosure above,
/// which is escaped; this is the program the person said yes to talking.
/// A package with nothing to run is a state to name, not a failure.
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

/// The package's two streams, each on the channel it was written to. Its
/// stdout goes through the door that escapes nothing: those bytes are the
/// program's answer, and a caller piping them is reading for what the
/// program said rather than for a line kendex composed. Its stderr is read
/// by a person, so it goes out as a line like any other.
fn relay(report: &kendex_core::guard::GuardReport) {
    for line in &report.stderr {
        say(line);
    }
    for line in &report.stdout {
        answer(line);
    }
}

/// Run the uninstaller of every package this plan takes away, before the
/// plan takes it, and say what ran.
///
/// The loop and its wording are core's, because the window owes the same
/// account. This side is only which channel each line goes out on: the
/// package's stdout is what a caller pipes for, so those bytes are relayed
/// as they came, and everything else is a line to read.
pub fn undo(scope: &Scope, report: &EngineReport) -> CliResult {
    kendex_core::repo_effects::undo(
        scope,
        &report.repo_effects_leaving,
        &mut |spoken| match spoken {
            Spoken::Stdout(line) => answer(&line),
            Spoken::Note(line) | Spoken::Stderr(line) => say(&line),
        },
    )
    .map_err(|error| error.to_string().into())
}
