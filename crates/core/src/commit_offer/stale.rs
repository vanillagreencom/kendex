//! The packages whose checkout files a commit of this offer would carry
//! out of date.
//!
//! A package can declare an effect on files in the checkout: the selected
//! configuration owner renders review files from its inputs. A commit carries those
//! files, and the repository's own pre-commit chain judges them. commit-guards
//! selects the configuration owner's staged check.
//! A commit made while they are out of date is a commit kendex can already
//! predict will be refused. So before the offer is made, each such package
//! whose files the offer touches is asked, and one kendex cannot vouch for
//! holds the commit.
//!
//! Setting a held package up runs its declared installer. Only the renders
//! kendex reads back join the offer after it: the selected configuration owner's,
//! through `crate::bot_instructions::add_to_generated`. A package's declared
//! writes are never carried whole, since one of them can be a file kendex
//! owns a region of.
//!
//! An effect inside `.git` is out of scope. A commit carries none of those
//! files, and a hook that is not set up refuses nothing.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::engine::GeneratedPaths;
use crate::engine::generated_paths::INVENTORY;
use crate::env::Env;
use crate::model::Scope;
use crate::repo_effects::{Ask, DeclaredEffects, Disclosure, SetupState, SetupStatus};

use super::Scan;
use super::candidate::Candidate;

/// One package whose checkout files kendex cannot vouch for, and why.
#[derive(Debug, Clone, PartialEq)]
pub struct Stale {
    /// What setting the package up changes: the block every surface shows
    /// before a setup's yes, from `repo_effects::offers_for`. Its
    /// `declared` is what the setup arms.
    pub disclosure: Disclosure,
    pub why: Staleness,
}

/// What the action making the offer sets up only after it, which a commit
/// made now would leave out. Empty for a surface that sets nothing up after
/// its offer.
#[derive(Debug, Clone, Copy, Default)]
pub struct Deferred<'a> {
    /// A configuration successor the action installed whose setup it leaves
    /// until after this offer:
    /// [`crate::bot_instructions::pending_successor`]. That setup moves the
    /// review files after the commit, so the successor holds the commit as
    /// [`Staleness::NotSetUp`] under the same configuring-table rule, though
    /// no check of the predecessor that judges its files holds it.
    pub successor: Option<&'a DeclaredEffects>,
    /// The packages the action's walkthrough after this offer sets up once
    /// it has its yes, read by the configuring-table rule.
    pub walked: &'a [DeclaredEffects],
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
    /// The package's declared staged checker fails over the commit, run
    /// against the index the commit would hand the repository's pre-commit
    /// chain, the last commit with the carried paths over it, while its
    /// working-tree check passes or is not declared. The commit carries the
    /// package's files without a changed input they were rendered from. No
    /// setup clears this; the way on is to leave the files and commit them
    /// together.
    Split {
        /// The changed inputs the commit leaves out: the package's paths
        /// under its tree or its declared writes, the manifest where the
        /// commit does not carry it, and the inventory. Empty where the
        /// input left out is a change kendex does not own.
        left: Vec<String>,
        /// What the staged checker said over the commit, escaped.
        said: Vec<String>,
    },
}

/// Every installed package whose checkout files the commit of `carried`,
/// paths the scan names, would hold out of date. Empty where that commit can be
/// offered. The one owner of the rule for both surfaces: each asks it of
/// the commit it offers, with the `generated` set that commit is made
/// from.
///
/// A package is asked only where the commit carries one of its changed
/// paths: under its own tree, which is what a refresh of its doctrine
/// changes, or under one of the paths it declares it writes. A package
/// selected to judge a renderer dependency also includes that dependency's
/// changed paths, even where none of its own paths changed. A package
/// declaring no installer holds nothing, since no setup could clear the
/// hold. One not set up here holds the commit without any of its code
/// running, unless its declared configuring table is absent: from the
/// commit's manifest, and for a package `deferred` names as walked, from
/// the working tree's too.
///
/// One set up here that declares a staged checker is judged by it, run
/// over the commit itself, built once per call in an index of its own. It
/// passes, and the commit is offered whatever the working tree says. It
/// exits 1, and the working-tree check decides why: it fails too, and the
/// files are [`Staleness::OutOfDate`], which a setup can clear; it passes,
/// or none is declared, and the commit is [`Staleness::Split`]. Either
/// check that cannot answer is [`Staleness::Unchecked`]. So a changed
/// input the commit leaves out holds it only where the check over the
/// commit reads it.
///
/// One set up here that declares no staged checker is judged by its
/// declared check over the working tree alone, the same licensed run the
/// package page makes; declaring no check at all, it gives kendex nothing
/// to predict with and holds nothing.
///
/// A declaration that will not read is passed over: it names neither the
/// files nor the check, and `repo_effects::lapsed` is the reading that
/// reports it where kendex set it up.
///
/// `deferred` is what the action making this offer sets up only after it.
pub fn stale(
    env: &Env,
    scope: &Scope,
    scan: &Scan,
    generated: &GeneratedPaths,
    carried: &BTreeSet<String>,
    deferred: Deferred<'_>,
) -> crate::error::Result<Vec<Stale>> {
    let mut candidate: Option<Candidate> = None;
    let mut held = Vec::new();
    let mut owners = BTreeMap::new();
    for installed in crate::engine::installed_declarations(env, scope)? {
        let crate::engine::InstalledDeclaration::Declared(declared) = installed else {
            continue;
        };
        let declared = *declared;
        let owner = crate::bot_instructions::commit_owner(env, scope, &declared)?;
        owners
            .entry(owner.name.clone())
            .or_insert_with(|| (owner, Vec::new()))
            .1
            .push(declared);
    }
    for (declared, inputs) in owners.into_values() {
        if crate::repo_effects::touches_git(&declared.effects) {
            continue;
        }
        let (taken, left): (Vec<&str>, Vec<&str>) = scan
            .owned
            .iter()
            .map(|owned| owned.path.as_str())
            .filter(|path| inputs.iter().any(|input| belongs(&scan.root, input, path)))
            .partition(|path| carried.contains(*path));
        if taken.is_empty() || declared.effects.installer.is_none() {
            continue;
        }
        let why = match crate::repo_effects::armed_here(scope, &declared)? {
            false => {
                if !configured(
                    &mut candidate,
                    scan,
                    generated,
                    carried,
                    &declared,
                    deferred,
                )? {
                    continue;
                }
                Staleness::NotSetUp
            }
            true => {
                let working = || crate::repo_effects::status(scope, &declared, Ask::Surface);
                let holds = match &declared.effects.staged_checker {
                    None => standing(working(), Staleness::OutOfDate),
                    Some(_) => {
                        let candidate =
                            Candidate::ensure(&mut candidate, &scan.root, generated, carried)?;
                        standing(candidate.status(scope, &declared), |said| {
                            standing(working(), Staleness::OutOfDate).unwrap_or_else(|| {
                                Staleness::Split {
                                    left: left_out(scan, carried, left),
                                    said,
                                }
                            })
                        })
                    }
                };
                match holds {
                    Some(why) => why,
                    None => continue,
                }
            }
        };
        held.push((declared, why));
    }
    if let Some(successor) = deferred.successor
        && !held
            .iter()
            .any(|(declared, _)| declared.name == successor.name)
        && configured(
            &mut candidate,
            scan,
            generated,
            carried,
            successor,
            deferred,
        )?
    {
        held.push((successor.clone(), Staleness::NotSetUp));
    }
    if let Some(candidate) = candidate {
        candidate.close()?;
    }
    disclosed(env, scope, held)
}

/// Whether a package not set up here has anything to render from: a
/// package naming a configuring table the commit's manifest lacks renders
/// nothing once set up, so it holds nothing. A setup the action's
/// walkthrough runs after the commit reads the working tree's manifest
/// instead, which can carry a table the commit leaves out, so for a walked
/// package that table holds the commit too.
fn configured(
    candidate: &mut Option<Candidate>,
    scan: &Scan,
    generated: &GeneratedPaths,
    carried: &BTreeSet<String>,
    declared: &DeclaredEffects,
    deferred: Deferred<'_>,
) -> crate::error::Result<bool> {
    let Some(key) = &declared.effects.configured_by else {
        return Ok(true);
    };
    if Candidate::ensure(candidate, &scan.root, generated, carried)?.configured(&scan.root, key)? {
        return Ok(true);
    }
    match deferred
        .walked
        .iter()
        .any(|walked| walked.name == declared.name)
    {
        true => configured_on_disk(&scan.root, key),
        false => Ok(false),
    }
}

/// Whether the working tree's manifest, the one a setup reads, declares
/// the table `key`. A manifest that will not parse refuses rather than
/// reading as one without the table.
fn configured_on_disk(root: &Path, key: &str) -> crate::error::Result<bool> {
    let path = crate::manifest::project_manifest_path(root);
    let Some(text) = crate::fs::read_if_exists(&path)? else {
        return Ok(false);
    };
    let table: toml::Table =
        text.parse().map_err(
            |error: toml::de::Error| crate::error::CoreError::TomlParse {
                path,
                message: error.to_string(),
            },
        )?;
    Ok(table.contains_key(key))
}

/// What one reading of a set-up package's check holds the commit with,
/// `None` where it holds nothing. `failed` names a check that exits 1: out
/// of date over the working tree; over the commit, the working-tree
/// check's own standing, or a split where that holds nothing.
fn standing(
    status: SetupStatus,
    failed: impl FnOnce(Vec<String>) -> Staleness,
) -> Option<Staleness> {
    match status.state {
        SetupState::Active | SetupState::Unavailable => None,
        SetupState::NeedsRepair => Some(failed(status.said)),
        SetupState::CouldNotCheck => Some(Staleness::Unchecked(status.said)),
        // The record was there a moment ago; read again, it is not, and
        // either way nothing ran here.
        SetupState::NotActive => Some(Staleness::NotSetUp),
        SetupState::NotDeclared | SetupState::NotARepository => {
            unreachable!("a declared package in a project read as {:?}", status.state)
        }
    }
}

/// A split package's changed inputs the commit leaves out: its own paths
/// the commit does not carry, the manifest where it changed, whatever the
/// action did to it, and the commit does not carry it, and the inventory
/// where it changed and is not carried. The package renders from the whole manifest and from the
/// inventory, so each is named where it is left behind; which of them the
/// check read, only its own words say.
fn left_out(scan: &Scan, carried: &BTreeSet<String>, left: Vec<&str>) -> Vec<String> {
    let inventory = scan
        .owned
        .iter()
        .map(|owned| owned.path.as_str())
        .filter(|path| *path == INVENTORY);
    left.into_iter()
        .chain(scan.manifest.as_deref())
        .chain(inventory)
        .filter(|path| !carried.contains(*path))
        .map(str::to_owned)
        .collect()
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
