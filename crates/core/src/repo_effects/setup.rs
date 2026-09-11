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
//! fetch. Opening a page must not run it. The licence is kendex's own
//! record of having armed this effect in this repository — written by
//! [`super::arm`], kept where git clones nothing, and argued in
//! [`super::armed`].
//!
//! No record is therefore an answer and not an error — kendex did not set
//! this up here — and it is reached without running anything. It is not a
//! claim that the effect is not in force: somebody may have run the
//! package's installer themselves. That is what [`Ask::Person`] is for,
//! and why the surface reporting it offers a way to ask the package
//! directly.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::Scope;

use super::DeclaredEffects;

/// Who wants the status, which is what decides whether the package's
/// script may run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum Ask {
    /// A surface reading a page. It gets the check only where kendex's own
    /// record licenses one, so opening a package's page in a repository
    /// nothing here armed runs none of its code.
    Surface,
    /// Somebody asked for this status, by pressing the control that asks.
    /// Their act is its own licence and needs no record — the same
    /// standing a guard verb typed at a prompt has, and the route to a
    /// true answer in a repository armed at a terminal or by hand.
    Person,
}

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
    /// A scope that is not a project. A personal install writes into the
    /// tool directories and changes no repository, so there is nothing
    /// here to set up and nothing to report.
    NotARepository,
    /// The package's check ran and said the effect is in force.
    Active,
    /// kendex has no record of setting this effect up in this project, or
    /// the package says it is not in force where there is no such record.
    /// No verdict is claimed about a repository nothing measured — the
    /// surface showing this offers a way to ask the package itself.
    NotActive,
    /// kendex set this effect up here and the package now says it is not
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
    /// [`SetupState::NotARepository`], [`SetupState::NotActive`] and
    /// [`SetupState::Unavailable`].
    pub said: Vec<String>,
    /// Whether the effect can be applied from here: the package declares
    /// an installer to run.
    pub can_apply: bool,
    /// Whether kendex has a check to run at all — what says asking the
    /// package again would do something.
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
pub fn status(scope: &Scope, declared: &DeclaredEffects, ask: Ask) -> SetupStatus {
    let can_apply = declared.effects.installer.is_some();
    let shared = super::touches_git(&declared.effects);
    // Not a project, so there is no repository for an effect to stand in.
    // A state of its own rather than a check that could not be taken: the
    // personal scope is a place the app draws a card for, and a
    // read-failure verdict over a place that has no state to read is a
    // failure report about nothing.
    let Scope::Project { root } = scope else {
        return SetupStatus {
            state: SetupState::NotARepository,
            said: Vec::new(),
            can_apply: false,
            can_check: false,
            shared,
        };
    };
    let Some(checker) = &declared.effects.checker else {
        return SetupStatus {
            state: SetupState::Unavailable,
            said: Vec::new(),
            can_apply,
            can_check: false,
            shared,
        };
    };
    // Where kendex's record would be, or why that cannot be said.
    //
    // Three answers, the same three [`super::undo`] takes: a work tree, no
    // work tree, and git declining to answer. No work tree is not a
    // failure — there is nothing git-private to have recorded anything in,
    // so there is no standing licence and the honest state is the one a
    // person can act on.
    let record_dir = match crate::guard::Repo::probe(root) {
        Ok(Some(repo)) => Some(super::armed::record_dir(&repo, shared).to_path_buf()),
        Ok(None) => None,
        Err(error) => {
            return could_not_check(
                can_apply,
                true,
                shared,
                format!("this repository could not be read, so its setup could not be: {error}"),
            );
        }
    };
    let armed_here = match &record_dir {
        Some(dir) => super::armed::recorded(dir, &declared.name),
        None => Ok(false),
    };
    let armed_here = match armed_here {
        Ok(armed) => armed,
        Err(error) => return could_not_check(can_apply, true, shared, error.to_string()),
    };
    // A record licenses the run on its own. So does somebody pressing the
    // control that asks, which is the route to a true answer where the
    // repository was armed at a terminal or by hand.
    if !armed_here && ask == Ask::Surface {
        return SetupStatus {
            state: SetupState::NotActive,
            said: Vec::new(),
            can_apply,
            can_check: true,
            shared,
        };
    }
    run(scope, declared, checker, can_apply, shared, armed_here)
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
    checker: &str,
    can_apply: bool,
    shared: bool,
    armed_here: bool,
) -> SetupStatus {
    let report = match super::run_script(scope, &declared.root, checker) {
        Ok(report) => report,
        Err(error) => return could_not_check(can_apply, true, shared, error.to_string()),
    };
    let said = spoken(&report);
    SetupStatus {
        state: match report.code {
            0 => SetupState::Active,
            // kendex armed this here and the package says the effect is
            // not in force: something set it up and it has since broken.
            // Without that record the package is simply saying no, which
            // is not a repair.
            1 if armed_here => SetupState::NeedsRepair,
            1 => SetupState::NotActive,
            _ => SetupState::CouldNotCheck,
        },
        said,
        can_apply,
        can_check: true,
        shared,
    }
}

/// What the check wrote, both streams, escaped once.
///
/// Escaped because these are a third party's bytes going onto a status
/// line a person reads as kendex's answer, the same door
/// `crates/app/src/repo_effects.rs` puts an installer's output through.
/// Blank lines dropped: a status has no room for the shell's spacing.
///
/// stdout, then stderr. The package's contract puts its summary on stdout
/// and its diagnostics on stderr, so a reader meets the diagnosis last,
/// where it explains a verdict they have just read.
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

/// One installed package whose recorded arming no longer holds.
#[derive(Debug, Clone, PartialEq)]
pub struct Lapsed {
    pub name: String,
    pub lapse: Lapse,
    /// What the package said, or why it could not be asked: the
    /// [`SetupStatus::said`] of the status this was read from.
    pub said: Vec<String>,
}

/// How a recorded arming stopped holding. Two of the states in
/// [`SetupState`] and only those, so a surface naming one has no other
/// state to have an answer for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lapse {
    /// kendex recorded arming the effect here and the package's check says
    /// it is not in force: [`SetupState::NeedsRepair`].
    NotInForce,
    /// The check could not be taken, the record could not be read, or the
    /// declaration naming the check will not read under a record, so
    /// nothing was measured: [`SetupState::CouldNotCheck`].
    Unchecked,
}

/// Every installed package in this scope whose recorded arming no longer
/// holds — the one reading `kendex verify` fails on and `kendex refresh`
/// names, so the two verbs cannot disagree about a repository.
///
/// Read under [`Ask::Surface`]: a package kendex never recorded arming
/// here runs no script and is not in the list, whatever state its effect
/// is in, because absence of a record is not a claim about the repository.
/// A check that could not be taken IS in the list, record or none: a verb
/// that reports the gate as standing has to have measured it, and one that
/// could not measure it says so rather than passing. The reason travels in
/// `said`.
///
/// The same two answers for a declaration that will not read. Its reach is
/// unknown, so the record is looked for in both of the repository's git
/// directories: none in either and the package is skipped, whatever its
/// frontmatter says, because a scope that never armed it — a clone, a
/// project that declined — has nothing to report; one in either and the
/// check kendex owes could not be run, which is a lapse with its reason.
///
/// Empty outside a project, where there is no repository for an effect to
/// stand in.
pub fn lapsed(env: &crate::env::Env, scope: &Scope) -> crate::error::Result<Vec<Lapsed>> {
    let Scope::Project { root } = scope else {
        return Ok(Vec::new());
    };
    let mut lapsed = Vec::new();
    for installed in crate::engine::installed_declarations(env, scope)? {
        let (name, lapse, said) = match installed {
            crate::engine::InstalledDeclaration::Declared(declared) => {
                let status = status(scope, &declared, Ask::Surface);
                let lapse = match status.state {
                    SetupState::NeedsRepair => Lapse::NotInForce,
                    SetupState::CouldNotCheck => Lapse::Unchecked,
                    SetupState::NotDeclared
                    | SetupState::NotARepository
                    | SetupState::Active
                    | SetupState::NotActive
                    | SetupState::Unavailable => continue,
                };
                (declared.name, lapse, status.said)
            }
            crate::engine::InstalledDeclaration::Unreadable { name, at } => {
                let said = match recorded_in_either(root, &name) {
                    Ok(true) => format!(
                        "its repo-effects declaration at {} will not read, so the check kendex owes this repository could not be run",
                        at.display()
                    ),
                    Ok(false) => continue,
                    Err(error) => error.to_string(),
                };
                (name, Lapse::Unchecked, vec![crate::names::shown(&said)])
            }
        };
        lapsed.push(Lapsed { name, lapse, said });
    }
    Ok(lapsed)
}

/// Whether kendex recorded arming this package in either of the
/// repository's git directories — the question for a package whose reach
/// cannot be read off its declaration. No work tree is no record.
fn recorded_in_either(root: &std::path::Path, name: &str) -> crate::error::Result<bool> {
    let Some(repo) = crate::guard::Repo::probe(root)? else {
        return Ok(false);
    };
    for shared in [true, false] {
        if super::armed::recorded(super::armed::record_dir(&repo, shared), name)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Where a project's arming records live, for the callers that arm and
/// disarm one: `None` outside a work tree, where there is nothing
/// git-private to write into.
///
/// `shared` is the effect's reach, which is what picks between the
/// repository's two git directories — [`super::armed::record_dir`] holds
/// that rule, so arming, disarming and reading cannot disagree about where
/// one package's record is.
pub(super) fn record_dir(
    root: &std::path::Path,
    shared: bool,
) -> crate::error::Result<Option<PathBuf>> {
    Ok(crate::guard::Repo::probe(root)?
        .map(|repo| super::armed::record_dir(&repo, shared).to_path_buf()))
}

#[cfg(test)]
mod tests;
