//! The packages whose checkout files a commit of this offer would carry
//! out of date.
//!
//! A package can declare an effect on files in the checkout: bot-instructions
//! renders the review-bot files from its doctrine. A commit carries those
//! files, and the repository's own pre-commit chain judges them. commit-guards
//! runs `bot-instructions check --staged` wherever that package is installed.
//! A commit made while they are out of date is a commit kendex can already
//! predict will be refused. So before the offer is made, each such package
//! whose files the offer touches is asked, and one kendex cannot vouch for
//! holds the commit.
//!
//! Setting a held package up runs its declared installer. Only the renders
//! kendex reads back join the offer after it: today bot-instructions',
//! through `crate::bot_instructions::add_to_generated`. A package's declared
//! writes are never carried whole, since one of them can be a file kendex
//! owns a region of.
//!
//! An effect inside `.git` is out of scope. A commit carries none of those
//! files, and a hook that is not set up refuses nothing.

use std::path::Path;

use crate::env::Env;
use crate::model::Scope;
use crate::repo_effects::{Ask, DeclaredEffects, Disclosure, SetupState};

use super::Scan;

/// One package whose checkout files kendex cannot vouch for, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Stale {
    /// What setting the package up changes: the block every surface shows
    /// before a setup's yes, from `repo_effects::offers_for`. Its
    /// `declared` is what the setup arms.
    pub disclosure: Disclosure,
    pub why: Staleness,
}

/// Why a package's checkout files are not known to be current.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Staleness {
    /// kendex has not set the package up in this checkout, so the files it
    /// renders were not brought up to date after its own files changed.
    /// No package code ran to find this out: without the record nothing
    /// licenses running it.
    NotSetUp,
    /// The package's check ran and says its files are not current. Its
    /// own words, escaped.
    OutOfDate(Vec<String>),
    /// The package's check could not answer, or could not be run. Its
    /// words, or why it could not be run.
    Unchecked(Vec<String>),
}

/// Every installed package whose checkout files this offer would commit
/// out of date. Empty where the commit can be offered.
///
/// A package is asked only where the offer touches it: a changed path
/// under its own tree, which is what a refresh of its doctrine changes, or
/// under one of the paths it declares it writes. A package declaring no
/// installer holds nothing, since no setup could clear the hold. One not
/// set up here holds the commit without any of its code running. One set
/// up here is asked through its declared check, the same licensed run the
/// package page makes; declaring no check, it gives kendex nothing to
/// predict with and holds nothing.
///
/// A declaration that will not read is passed over: it names neither the
/// files nor the check, and `repo_effects::lapsed` is the reading that
/// reports it where kendex set it up.
pub fn stale(env: &Env, scope: &Scope, scan: &Scan) -> crate::error::Result<Vec<Stale>> {
    let mut held = Vec::new();
    for installed in crate::engine::installed_declarations(env, scope)? {
        let crate::engine::InstalledDeclaration::Declared(declared) = installed else {
            continue;
        };
        if crate::repo_effects::touches_git(&declared.effects)
            || declared.effects.installer.is_none()
            || !touched(scan, &declared)
        {
            continue;
        }
        let why = match crate::repo_effects::armed_here(scope, &declared)? {
            false => Staleness::NotSetUp,
            true => {
                let status = crate::repo_effects::status(scope, &declared, Ask::Surface);
                match status.state {
                    SetupState::Active | SetupState::Unavailable => continue,
                    SetupState::NeedsRepair => Staleness::OutOfDate(status.said),
                    SetupState::CouldNotCheck => Staleness::Unchecked(status.said),
                    // The record was there a moment ago; read again, it
                    // is not, and either way nothing ran here.
                    SetupState::NotActive => Staleness::NotSetUp,
                    SetupState::NotDeclared | SetupState::NotARepository => {
                        unreachable!("a declared package in a project read as {:?}", status.state)
                    }
                }
            }
        };
        held.push((declared, why));
    }
    disclosed(env, scope, held)
}

/// Each held package with the block its setup is shown under.
///
/// `offers_for` withholds only an effect inside `.git` whose repository
/// will not resolve, and a held package's effect is in the checkout, so
/// every one comes back shown. One that does not is refused rather than
/// offered a setup without its block.
fn disclosed(
    env: &Env,
    scope: &Scope,
    held: Vec<(DeclaredEffects, Staleness)>,
) -> crate::error::Result<Vec<Stale>> {
    let declared: Vec<DeclaredEffects> = held.iter().map(|(one, _)| one.clone()).collect();
    let mut shown = crate::repo_effects::offers_for(env, scope, &declared)?.shown;
    held.into_iter()
        .map(|(declared, why)| {
            let at = shown
                .iter()
                .position(|disclosure| disclosure.declared == declared)
                .ok_or_else(|| {
                    crate::repo_effects::err(format!(
                        "{}: its setup could not be disclosed, so none is offered",
                        crate::names::shown(&declared.name)
                    ))
                })?;
            Ok(Stale {
                disclosure: shown.remove(at),
                why,
            })
        })
        .collect()
}

/// Whether the offer carries a change to this package's own files or to a
/// path it declares it writes.
///
/// Compared as path components, so a declared directory spelled with a
/// trailing `/` covers what is under it and `docs` does not cover
/// `docsite`.
fn touched(scan: &Scan, declared: &DeclaredEffects) -> bool {
    let tree = declared.root.strip_prefix(&scan.root).ok();
    scan.owned.iter().any(|owned| {
        let path = Path::new(&owned.path);
        tree.is_some_and(|tree| path.starts_with(tree))
            || declared
                .effects
                .writes
                .iter()
                .any(|write| path.starts_with(write))
    })
}

#[cfg(test)]
mod tests;
