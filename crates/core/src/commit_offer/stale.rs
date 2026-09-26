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

use crate::engine::generated_paths::INVENTORY;
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
    /// The commit carries some of the package's changed paths and leaves
    /// these out: files under its tree or its declared writes the commit
    /// does not carry, the changed manifest, which no commit kendex makes
    /// carries, or the changed inventory the commit does not carry. A
    /// package renders from the whole manifest and from the inventory, and
    /// the repository's check renders from what the commit holds, so it
    /// compares the carried files against inputs left behind. No setup
    /// clears this; the way on is to leave the files and commit them
    /// together.
    Split(Vec<String>),
}

/// Which of the scan's changed paths a commit carries.
#[derive(Debug, Clone, Copy)]
pub enum Carried<'a> {
    /// Every changed path kendex owns: the terminal's commit, and the
    /// window's commit of every pending change.
    Everything,
    /// Only these paths: the window's commit of one action's work.
    Only(&'a std::collections::BTreeSet<String>),
}

impl Carried<'_> {
    fn carries(self, path: &str) -> bool {
        match self {
            Carried::Everything => true,
            Carried::Only(paths) => paths.contains(path),
        }
    }
}

/// Every installed package whose checkout files the commit carrying
/// `carried` would hold out of date. Empty where that commit can be
/// offered. The one owner of the rule for both surfaces: each asks it of
/// the commit it offers.
///
/// A package is asked only where the commit carries one of its changed
/// paths: under its own tree, which is what a refresh of its doctrine
/// changes, or under one of the paths it declares it writes. First, the
/// commit never splits a package's pending paths ([`Staleness::Split`]):
/// one that carries some of them and leaves others behind is held however
/// the package stands, because the repository's check renders from the
/// commit's inputs. The changed manifest and an uncarried changed
/// inventory count among the paths left behind for every package. Then a package declaring no installer holds nothing,
/// since no setup could clear the hold. One not set up here holds the
/// commit without any of its code running. One set up here is asked
/// through its declared check, the same licensed run the package page
/// makes, over the working tree; declaring no check, it gives kendex
/// nothing to predict with and holds nothing. The split rule is what
/// makes that working-tree check stand for the commit: with every changed
/// input carried, the tree the check reads is the one the commit holds.
///
/// A declaration that will not read is passed over: it names neither the
/// files nor the check, and `repo_effects::lapsed` is the reading that
/// reports it where kendex set it up.
pub fn stale(
    env: &Env,
    scope: &Scope,
    scan: &Scan,
    carried: Carried,
) -> crate::error::Result<Vec<Stale>> {
    let behind: Vec<&str> = scan
        .manifest
        .iter()
        .map(String::as_str)
        .chain(
            scan.owned
                .iter()
                .map(|owned| owned.path.as_str())
                .filter(|path| *path == INVENTORY && !carried.carries(path)),
        )
        .collect();
    let mut held = Vec::new();
    for installed in crate::engine::installed_declarations(env, scope)? {
        let crate::engine::InstalledDeclaration::Declared(declared) = installed else {
            continue;
        };
        if crate::repo_effects::touches_git(&declared.effects) {
            continue;
        }
        let (taken, mut left): (Vec<&str>, Vec<&str>) = scan
            .owned
            .iter()
            .map(|owned| owned.path.as_str())
            .filter(|path| belongs(&scan.root, &declared, path))
            .partition(|path| carried.carries(path));
        if taken.is_empty() {
            continue;
        }
        left.extend(&behind);
        if !left.is_empty() {
            let left = left.into_iter().map(str::to_owned).collect();
            held.push((declared, Staleness::Split(left)));
            continue;
        }
        if declared.effects.installer.is_none() {
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

/// Whether a changed path is this package's: under its own tree or under
/// a path it declares it writes.
///
/// Compared as path components, so a declared directory spelled with a
/// trailing `/` covers what is under it and `docs` does not cover
/// `docsite`.
fn belongs(root: &Path, declared: &DeclaredEffects, path: &str) -> bool {
    let path = Path::new(path);
    declared
        .root
        .strip_prefix(root)
        .is_ok_and(|tree| path.starts_with(tree))
        || declared
            .effects
            .writes
            .iter()
            .any(|write| path.starts_with(write))
}

#[cfg(test)]
mod tests;
