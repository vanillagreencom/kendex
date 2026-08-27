//! What a package does outside the folders kendex manages.
//!
//! Almost every package is inert: installing it writes files into the tool
//! directories and changes nothing else, so the plan preview is the whole
//! story. A few are not. growth-guards writes into `.git/hooks` and changes
//! what happens on every commit in the repository, for everyone who commits
//! there — an effect no line of the plan describes, because the plan only
//! knows about the skill tree.
//!
//! A package declares that itself, in its own frontmatter, and kendex shows
//! the declaration and asks a separate question about it. Not before writing
//! anything: the package's own files land with the rest of the plan, and
//! what waits for the second answer is the effect — the part that outlives
//! removing the package.
//!
//! Declared rather than hard-coded on purpose: the previous generation
//! special-cased growth-guards by name in the installer, so the
//! behaviour could never generalize and the documentation describing it
//! drifted out of true the moment that code moved.
//!
//! This is not a safety finding. The safety rules score risk in content
//! nobody vouched for; arming a hook the person asked for is a contract,
//! and rendering it as a warning teaches people to click past the one
//! notice they most need to read.
mod declaration;
pub mod disclosure;
use declaration::split_script;
pub use declaration::{RepoEffects, declared};
pub use disclosure::{Companion, Disclosure, Offers, Withheld, Written, installed_skills, offers};

use serde::{Deserialize, Serialize};
use specta::Type;

/// The frontmatter key a package declares its effects under.
pub const KEY: &str = "repo-effects";

/// Run one package's declared script, from the repository root.
///
/// The program is resolved under `root`, the installed package's own
/// directory, and canonicalized back into it: a symlink placed inside the
/// package after install must not reach a program outside it. Arguments are
/// passed as words, never through a shell.
pub fn run_script(
    scope: &crate::model::Scope,
    root: &std::path::Path,
    spec: &str,
) -> crate::error::Result<crate::guard::GuardReport> {
    let crate::model::Scope::Project { root: repo } = scope else {
        return Err(err(
            "repository effects apply to a project, not the global scope",
        ));
    };
    let (program, args) = split_script(spec);
    let path = root.join(program);
    let resolved = path
        .canonicalize()
        .map_err(|error| crate::error::CoreError::io(&path, error))?;
    let inside = root
        .canonicalize()
        .map(|base| resolved.starts_with(base))
        .unwrap_or(false);
    if !inside {
        return Err(err(format!(
            "{} resolves outside {} — refusing to run it",
            path.display(),
            root.display()
        )));
    }
    // Run from the repository root and pass only the package's own
    // arguments. kendex injects nothing: a declared script that needed a
    // flag kendex invented would be a script only kendex could run, and the
    // point of the declaration is that a person can run it too.
    // The declaration is text, so its arguments are text; paths that reach
    // the child as bytes are the ones kendex resolves, not these.
    let argv: Vec<std::ffi::OsString> = args.into_iter().map(Into::into).collect();
    let output = crate::process::Hardened::guard_script(&resolved, argv, repo)
        .run()
        .map_err(|error| err(error.to_string()))?;
    Ok(crate::guard::relay(&output))
}

fn err(message: impl Into<String>) -> crate::error::CoreError {
    crate::error::CoreError::Guard {
        check: "repo-effects".to_owned(),
        message: message.into(),
    }
}

/// One package's declaration, with the package it came from — what a plan
/// carries out to the surfaces that disclose it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredEffects {
    pub name: String,
    /// The package directory the scripts resolve against, once installed.
    ///
    /// A path, not a string of one. `display().to_string()` turns any byte
    /// that is not UTF-8 into U+FFFD, which is a different filename — so an
    /// authorized effect resolved a path nobody has, for a package that had
    /// just landed perfectly well. The same class #1669 closed on the guard
    /// side, here for the same reason.
    pub root: std::path::PathBuf,
    #[serde(flatten)]
    pub effects: RepoEffects,
}
