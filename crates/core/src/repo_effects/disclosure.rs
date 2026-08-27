//! A declaration mapped onto the repository it is about to change.
//!
//! The block a person reads is the package's own words plus facts only
//! kendex knows about this machine: where a declared path really lands,
//! whether every work tree shares it, and which companions are installed
//! here. Those facts are settled once, here, and every surface that asks
//! for a yes — the terminal, the app — shows the same answer.
//!
//! Settled as what goes on the screen, too. Every value a package chose is
//! catalog text read immediately before a consent prompt: a summary
//! carrying an escape sequence repaints the terminal lines above it, and a
//! path carrying a direction-flipping character reads as a different file
//! from the one being authorized in the app. So the display fields here
//! have been through `names::shown` once, and a surface prints them as
//! they are. The raw declaration rides beside them for the yes to run.
//!
//! Nothing here explains what a declaration MEANS. That is the package's
//! contract, and kendex is not a party to it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::model::Scope;
use crate::names::shown;

use super::{DeclaredEffects, RepoEffects};

/// One path the package writes, where it actually lands.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Written {
    /// Absolute, because the whole value of the line is that a reader can
    /// go and look. Display text: shown once, printed as it is.
    pub path: String,
    /// Inside the repository's common git directory, which every work tree
    /// of the repository shares — so this file is the repository's, not
    /// this checkout's.
    pub shared: bool,
}

/// A package whose presence changes what this one does, and whether it is
/// installed in this scope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Companion {
    /// Display text: shown once, printed as it is.
    pub name: String,
    pub installed: bool,
}

/// What a person reads before saying yes to one package's effect, and the
/// declaration that yes runs.
///
/// The display fields are the declaration's own words as they go on the
/// screen; `declared` is the same words untouched, for the command that
/// runs the effect. A surface reads the former and hands back the latter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Disclosure {
    pub declared: DeclaredEffects,
    pub name: String,
    pub summary: String,
    pub writes: Vec<Written>,
    pub companions: Vec<Companion>,
    pub notes: Vec<String>,
    pub removal: Option<String>,
}

/// An effect that was neither shown nor offered, and why.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Withheld {
    /// Display text: shown once, printed as it is.
    pub name: String,
    pub reason: String,
}

/// Everything a run has to say about repository effects: the blocks to
/// read and ask about, and the packages it could not account for.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Offers {
    pub shown: Vec<Disclosure>,
    pub withheld: Vec<Withheld>,
}

impl Offers {
    pub fn is_empty(&self) -> bool {
        self.shown.is_empty() && self.withheld.is_empty()
    }
}

/// The offers an applied plan's effects earn, against the scope as it
/// stands now — read after the write, so a companion that landed in the
/// same plan counts as installed. What every surface calls.
pub fn offers_for(
    env: &Env,
    scope: &Scope,
    effects: &[DeclaredEffects],
) -> crate::error::Result<Offers> {
    if effects.is_empty() {
        return Ok(Offers::default());
    }
    let installed = installed_skills(env, scope)?;
    Ok(offers(scope, effects, &installed))
}

/// The offers a plan's effects earn in this scope.
///
/// Empty outside a project. A repository effect is a change to a
/// repository, and the global scope is not one: `run_script` refuses it, so
/// an effect offered there is a question whose yes cannot be honoured.
///
/// `installed` names the skills the scope carries now.
pub fn offers(scope: &Scope, effects: &[DeclaredEffects], installed: &BTreeSet<String>) -> Offers {
    let Scope::Project { root } = scope else {
        return Offers::default();
    };
    // Where `.git/...` actually is, or why that cannot be said.
    //
    // Guessing `<root>/.git` was wrong in the case the guess exists for: a
    // linked worktree or a `--separate-git-dir` layout puts the hooks
    // somewhere else, and a repository whose common dir cannot be resolved
    // is exactly the one whose layout kendex has not understood. A block
    // naming a path that does not exist, immediately before asking somebody
    // to authorize writing to it, is worse than no block. The error is
    // kept whole: not inside a repository, a bare one, and git failing to
    // run each want a different remedy.
    let git_dir = crate::guard::Repo::at(root).map(|repo| repo.common_dir);
    let mut offers = Offers::default();
    for declared in effects {
        // An effect that writes into `.git` is not disclosed where the
        // repository could not be read: nothing here can say where those
        // files land. One that writes nowhere near it is unaffected.
        if let Err(error) = &git_dir
            && touches_git(&declared.effects)
        {
            offers.withheld.push(Withheld {
                name: shown(&declared.name),
                reason: format!(
                    "this repository's git directory could not be resolved, so where \
                     it writes cannot be named; nothing was offered or run ({error})"
                ),
            });
            continue;
        }
        let git_dir = git_dir.as_deref().ok();
        let writes = declared
            .effects
            .writes
            .iter()
            .map(|path| {
                let target = lands_at(root, git_dir, path);
                Written {
                    // By path components, not by text. A string prefix
                    // reads `<root>/.github/config` as sitting under
                    // `<root>/.git`, and this flag is a claim about who
                    // else sees the file.
                    shared: git_dir.is_some_and(|dir| target.starts_with(dir)),
                    path: shown(&target.display().to_string()),
                }
            })
            .collect();
        let companions = declared
            .effects
            .companions
            .iter()
            .map(|name| Companion {
                installed: installed.contains(name),
                name: shown(name),
            })
            .collect();
        offers.shown.push(Disclosure {
            name: shown(&declared.name),
            summary: shown(&declared.effects.summary),
            notes: declared.effects.notes.iter().map(|n| shown(n)).collect(),
            removal: declared.effects.removal.as_deref().map(shown),
            declared: declared.clone(),
            writes,
            companions,
        });
    }
    offers
}

/// The skills a scope carries, by name — what `offers` answers companion
/// presence from.
pub fn installed_skills(env: &Env, scope: &Scope) -> crate::error::Result<BTreeSet<String>> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    Ok(crate::lock::skill_names(&lock))
}

/// A declared target, as the absolute path it really lands at.
///
/// `.git/...` goes to the repository's common git directory; everything else
/// is under the project.
fn lands_at(root: &Path, git_dir: Option<&Path>, declared: &str) -> PathBuf {
    match (under_git(declared), git_dir) {
        (Some(rest), Some(dir)) => dir.join(rest),
        // Unreachable while a package with any `.git` target is withheld
        // above; a path is still the honest answer if that ever changes.
        (Some(_), None) | (None, _) => root.join(declared),
    }
}

/// The part of a declared path that sits under the git directory.
fn under_git(declared: &str) -> Option<&str> {
    declared
        .strip_prefix(".git/")
        .or_else(|| declared.strip_prefix("./.git/"))
}

/// Whether anything this package declares lands in the git directory.
fn touches_git(effects: &RepoEffects) -> bool {
    effects.writes.iter().any(|path| under_git(path).is_some())
}

#[cfg(test)]
mod tests;
