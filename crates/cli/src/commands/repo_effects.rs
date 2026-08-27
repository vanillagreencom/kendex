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

use kendex_core::engine::EngineReport;
use kendex_core::model::Scope;
use kendex_core::names::shown;
use kendex_core::repo_effects::DeclaredEffects;

use super::{CliResult, out, say};

mod disclose;
pub use disclose::disclose;

/// The repository effects this plan brings — the ones this run has to
/// disclose and ask about, because no earlier run's answer carries.
///
/// Empty outside a project. A repository effect is a change to a
/// repository, and the global scope is not one: `run_script` refuses it, so
/// an effect offered there is a question whose yes cannot be honoured.
/// Filtered here, at the one place the list is built, rather than in the
/// disclosure — that skipped the block and left the same list to be asked
/// about, so a global install prompted for an effect it had not named and
/// `--allow-repo-effects` wrote the files before the refusal landed.
pub fn pending<'a>(scope: &Scope, report: &'a EngineReport) -> Vec<&'a DeclaredEffects> {
    match scope {
        Scope::Project { .. } => report.repo_effects.iter().collect(),
        _ => Vec::new(),
    }
}

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
pub fn walkthrough(scope: &Scope, pending: &[&DeclaredEffects], allowed: bool) -> CliResult {
    if confirm(pending, allowed)? {
        for declared in pending {
            apply(scope, declared)?;
        }
        return Ok(());
    }
    for declared in pending {
        say(&format!(
            "{}: installed; its repository changes were not applied",
            shown(&declared.name)
        ));
    }
    Ok(())
}

/// Ask, once, for every pending package at once. A session with no terminal
/// needs `--allow-repo-effects` said out loud: a scripted install or a CI
/// run must never arm a repository's hooks because nobody was there to
/// decline.
pub fn confirm(pending: &[&DeclaredEffects], allowed: bool) -> Result<bool, String> {
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
        1 => format!(
            "apply {}'s repository changes? [y/N] ",
            shown(&pending[0].name)
        ),
        n => format!("apply the repository changes of {n} packages? [y/N] "),
    };
    let _ = write!(std::io::stderr(), "{question}");
    let mut answer = String::new();
    std::io::stdin()
        .read_line(&mut answer)
        .map_err(|error| error.to_string())?;
    Ok(matches!(answer.trim(), "y" | "Y" | "yes"))
}

/// Run one package's installer, here and now. The run is the whole of it:
/// what it wrote is on disk for anyone to look at, and nothing kendex
/// stores decides what a later run does.
pub fn apply(scope: &Scope, declared: &DeclaredEffects) -> CliResult {
    let Some(installer) = &declared.effects.installer else {
        say(&format!(
            "{}: no installer to run — arm it yourself when you are ready",
            shown(&declared.name)
        ));
        return Ok(());
    };
    let report = kendex_core::repo_effects::run_script(scope, &declared.root, installer)?;
    // Each of the package's streams on its own channel, the way the package
    // wrote them: its summary is what a caller pipes for.
    for line in &report.stderr {
        say(line);
    }
    for line in &report.stdout {
        out(line);
    }
    if report.code != 0 {
        // Not "the repository is unchanged". kendex takes no pre-image and
        // rolls nothing back, so an installer that wrote three files and
        // failed on the fourth leaves three files — and a message promising
        // otherwise is the one thing that would stop somebody looking. The
        // declaration names what the package writes, which is where to look.
        return Err(format!(
            "{}: {} exited {} — anything it wrote before that is still \
             there; `{}` is what the package says undoes it",
            shown(&declared.name),
            shown(installer),
            report.code,
            shown(
                declared
                    .effects
                    .uninstaller
                    .as_deref()
                    .unwrap_or("its uninstaller")
            )
        )
        .into());
    }
    Ok(())
}
