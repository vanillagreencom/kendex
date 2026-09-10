//! Whether a package's declared effect actually stands in one project.
//!
//! Installing a package and arming what it does to the repository are two
//! separate acts, and the second one can be declined, undone by hand, or
//! left behind by a clone. So a package's files being present says nothing
//! about whether its effect is in force, and every surface that shows one
//! project's copy of a package needs the other answer too.
//!
//! The answer is the package's, not kendex's. kendex locates the declared
//! check, decides whether it may be run at all, runs it, and reports the
//! outcome its exit status carries. Nothing here reads a hook file, a
//! config value or any other artifact the package owns: a second grammar
//! for what "armed" means diverges from the package's, and the
//! disagreement surfaces as a page contradicting the gate that actually
//! runs.
//!
//! ## What licenses the run
//!
//! The check is a script out of a checkout, and a checkout arrives with a
//! fetch. Opening a page must not run it. What separates a repository
//! somebody armed from one that merely carries the files is the package's
//! declared `evidence`: a path in the repository's common git directory,
//! which git clones for nobody, so anything of the package's sitting there
//! got there from a local act on this machine.
//!
//! Evidence absent is therefore an answer and not an error — nothing local
//! set this up — and it is reached without running anything.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::Scope;

use super::{Checker, DeclaredEffects};

/// What a package's declared setup is doing in one project.
///
/// No default among them. A surface never has to decide what an unread
/// state means, because a state nobody read is one of these.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum SetupState {
    /// The package says nothing about the repository, so there is no
    /// setup to have a state about and no row to draw. Almost every
    /// package is this.
    NotDeclared,
    /// The package's check ran and said the effect is in force.
    Active,
    /// Nothing on this machine has set the effect up in this project. No
    /// script was run to establish it: the package's own evidence is not
    /// there, and only a local act puts it there.
    NotActive,
    /// Something here set the effect up and the package now says it is not
    /// in force — a setup that was applied and has since broken. The
    /// remedy is to apply it again, which is what tells this from
    /// [`SetupState::NotActive`].
    NeedsRepair,
    /// The check ran and could not answer, or could not be run at all. Not
    /// a verdict about the repository: nothing here was measured.
    CouldNotCheck,
    /// The package declares an effect and no way to be asked about it, so
    /// there is no status to have. Its setup action is still offered.
    Unavailable,
}

/// One project's answer about one package's declared setup.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    pub state: SetupState,
    /// What the package said, or why kendex could not ask it. Display
    /// text: escaped once here, printed as it is.
    ///
    /// Empty where the state is what kendex read for itself and the
    /// package was never run: [`SetupState::NotDeclared`],
    /// [`SetupState::NotActive`] and [`SetupState::Unavailable`].
    pub said: Vec<String>,
    /// Whether the effect can be applied from here: the package declares
    /// an installer to run.
    pub can_apply: bool,
    /// Whether kendex has a check to run at all — what says a Check again
    /// would do something.
    pub can_check: bool,
    /// Whether the effect writes into the repository's common git
    /// directory, which every work tree of the repository shares — so
    /// setting it up here changes the repository for all of them, and a
    /// linked work tree is reporting the state its main checkout armed.
    ///
    /// Read off the declaration, so it is the same answer whether or not
    /// the check ran.
    pub shared: bool,
}

impl SetupStatus {
    /// The answer for a package that declares nothing about the
    /// repository — every field false and nothing said, so a surface that
    /// asks of every package it draws gets a state rather than an error.
    ///
    /// Here rather than at the caller so the one producer of every state
    /// in this enum is this module.
    pub fn not_declared() -> SetupStatus {
        SetupStatus {
            state: SetupState::NotDeclared,
            said: Vec::new(),
            can_apply: false,
            can_check: false,
            shared: false,
        }
    }
}

/// The declared setup's standing in this project.
///
/// A project scope, always: an effect is a change to a repository and the
/// global scope is not one — [`super::arm`] refuses it, so a status there
/// would describe something no yes could change.
pub fn status(scope: &Scope, declared: &DeclaredEffects) -> SetupStatus {
    let can_apply = declared.effects.installer.is_some();
    let shared = super::touches_git(&declared.effects);
    let Some(checker) = &declared.effects.checker else {
        return SetupStatus {
            state: SetupState::Unavailable,
            said: Vec::new(),
            can_apply,
            can_check: false,
            shared,
        };
    };
    let Scope::Project { root } = scope else {
        return could_not_check(
            can_apply,
            false,
            shared,
            "repository setup applies to a project, not the global scope",
        );
    };
    // Where the evidence really is, or why that cannot be said. The same
    // reading the disclosure makes, so the file licensing a run and the
    // file a person authorized are one file.
    let common_dir = match crate::guard::Repo::at(root) {
        Ok(repo) => repo.common_dir,
        Err(error) => {
            return could_not_check(
                can_apply,
                false,
                shared,
                format!(
                    "this repository's git directory could not be resolved, so where \
                     {} sets things up cannot be read ({error})",
                    declared.name
                ),
            );
        }
    };
    match armed_here(&common_dir, &checker.evidence) {
        // Nothing local set this up. Said without running anything, which
        // is the whole trust rule: a clone reaches here.
        Ok(false) => SetupStatus {
            state: SetupState::NotActive,
            said: Vec::new(),
            can_apply,
            can_check: true,
            shared,
        },
        Err(error) => could_not_check(can_apply, true, shared, error.to_string()),
        Ok(true) => run(scope, declared, checker, can_apply, shared),
    }
}

/// Run the declared check and report what its exit status carried.
///
/// The exit status is the whole answer, and it is the family contract the
/// package defines and every kendex surface relays unchanged: 0 the effect
/// stands, 1 it does not, anything else the check could not be taken. Its
/// own lines travel with it whatever it said — they are the remediation
/// text a person acts on, and a verdict without them is a state with no
/// way out of it.
fn run(
    scope: &Scope,
    declared: &DeclaredEffects,
    checker: &Checker,
    can_apply: bool,
    shared: bool,
) -> SetupStatus {
    let report = match super::run_script(scope, &declared.root, &checker.script) {
        Ok(report) => report,
        Err(error) => return could_not_check(can_apply, true, shared, error.to_string()),
    };
    let said = spoken(&report);
    SetupStatus {
        state: match report.code {
            0 => SetupState::Active,
            // Evidence of a local arming is on disk and the package says
            // the effect is not in force: something set this up and it has
            // since broken. Not "never set up", which the evidence
            // disproves.
            1 => SetupState::NeedsRepair,
            _ => SetupState::CouldNotCheck,
        },
        said,
        can_apply,
        can_check: true,
        shared,
    }
}

/// Whether the package's declared evidence of a local arming is there.
///
/// Three answers and not two, for the reason [`crate::guard::locally_armed`]
/// has three: a directory that would not open is a question nobody asked,
/// and folding it into "not there" turns it into a positive claim about a
/// repository nothing looked at.
fn armed_here(common_dir: &Path, evidence: &str) -> crate::error::Result<bool> {
    crate::fs::exists(&lands_at(common_dir, evidence))
}

/// Where a declared `.git/...` evidence path really sits.
///
/// The declaration was already refused unless the path lands in the common
/// git directory, so the leading `.git` is what is stripped and the rest
/// joined onto the directory git named. `super::disclosure::under_git` is
/// the one reader of that shape, here as everywhere.
fn lands_at(common_dir: &Path, evidence: &str) -> PathBuf {
    match super::disclosure::under_git(evidence) {
        Some(rest) if !rest.as_os_str().is_empty() => common_dir.join(rest),
        // The git directory named on its own, and the arm the declaration
        // reader has already excluded — a path that is not under `.git`
        // never becomes a checker's evidence. Kept as a path rather than a
        // panic: nothing here is worth aborting a page over.
        _ => common_dir.to_path_buf(),
    }
}

/// What the check wrote, both streams, escaped once.
///
/// Escaped because these are a third party's bytes going onto a status
/// line a person reads as kendex's answer, the same door
/// `crates/app/src/repo_effects.rs` puts an installer's output through.
/// Blank lines dropped: a status has no room for the shell's spacing.
///
/// stderr first, then stdout. The package's contract puts its summary on
/// stdout and its diagnostics on stderr, and a reader meets the diagnosis
/// last where it explains a verdict they have just read.
fn spoken(report: &crate::guard::GuardReport) -> Vec<String> {
    report
        .stdout
        .iter()
        .chain(&report.stderr)
        .map(|line| line.trim())
        .filter(|line| !line.is_empty())
        .map(crate::names::shown)
        .collect()
}

/// A state nobody could read, carrying the reason whole.
fn could_not_check(
    can_apply: bool,
    can_check: bool,
    shared: bool,
    why: impl Into<String>,
) -> SetupStatus {
    SetupStatus {
        state: SetupState::CouldNotCheck,
        said: vec![crate::names::shown(&why.into())],
        can_apply,
        can_check,
        shared,
    }
}

#[cfg(test)]
mod tests;
