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
pub use disclosure::{
    Companion, Disclosure, Offers, Withheld, Written, installed_skills, offers, offers_for,
};

use serde::{Deserialize, Serialize};
use specta::Type;

/// The frontmatter key a package declares its effects under.
pub const KEY: &str = "repo-effects";

/// One package's declared script, ready to run: the repository to run it
/// in, the program, and its arguments.
///
/// The program is resolved under `root`, the installed package's own
/// directory, and canonicalized back into it: a symlink placed inside the
/// package after install must not reach a program outside it. Arguments are
/// passed as words, never through a shell.
///
/// Split from the launch on purpose. Nothing here starts a process, so a
/// failure at this stage is one where the script provably never ran — and
/// that is the only thing that lets `arm` tell "could not run it" apart
/// from "ran, and may have written something".
fn resolve_script<'a>(
    scope: &'a crate::model::Scope,
    root: &std::path::Path,
    spec: &str,
) -> crate::error::Result<(
    &'a std::path::Path,
    std::path::PathBuf,
    Vec<std::ffi::OsString>,
)> {
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
    // Only the package's own arguments. kendex injects nothing: a declared
    // script that needed a flag kendex invented would be a script only
    // kendex could run, and the point of the declaration is that a person
    // can run it too.
    // The declaration is text, so its arguments are text; paths that reach
    // the child as bytes are the ones kendex resolves, not these.
    let argv = args.into_iter().map(Into::into).collect();
    Ok((repo.as_path(), resolved, argv))
}

/// Run a resolved script from the repository root and relay what it said.
fn launch_script(
    repo: &std::path::Path,
    program: &std::path::Path,
    argv: Vec<std::ffi::OsString>,
) -> crate::error::Result<crate::guard::GuardReport> {
    let output = crate::process::Hardened::guard_script(program, argv, repo)
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

/// Run one package's declared installer, here and now, and judge its exit.
///
/// The run is the whole of it: what it wrote is on disk for anyone to look
/// at, and nothing kendex stores decides what a later run does. Every
/// surface that has a yes calls this, so a package with nothing to run and
/// an installer that failed read the same on each of them.
pub fn arm(
    scope: &crate::model::Scope,
    declared: &DeclaredEffects,
) -> std::result::Result<crate::guard::GuardReport, ArmError> {
    let Some(installer) = &declared.effects.installer else {
        return Err(ArmError::NothingToRun {
            name: declared.name.clone(),
        });
    };
    let (repo, program, argv) = resolve_script(scope, &declared.root, installer)?;
    // Past this line the installer has been handed to the operating system,
    // so every failure is one where it may already have written something —
    // a kill, a timeout, an exec that failed for a reason nobody can see
    // from here. That reads like a nonzero exit, not like "could not run".
    let report = launch_script(repo, &program, argv).map_err(|error| ArmError::Unfinished {
        name: declared.name.clone(),
        installer: installer.clone(),
        undo: declared.undo(),
        error: Box::new(error),
    })?;
    if report.code != 0 {
        return Err(ArmError::Failed {
            name: declared.name.clone(),
            installer: installer.clone(),
            code: report.code,
            undo: declared.undo(),
            report: Box::new(report),
        });
    }
    Ok(report)
}

/// Why a yes did not arm the repository.
#[derive(Debug)]
pub enum ArmError {
    /// The package declared no installer: the disclosure ends with what the
    /// reader runs themselves, and kendex has nothing to launch.
    NothingToRun { name: String },
    /// The installer ran and exited nonzero. kendex takes no pre-image and
    /// rolls nothing back, so an installer that wrote three files and
    /// failed on the fourth leaves three files, and a message promising
    /// otherwise is the one thing that would stop somebody looking. The
    /// package's own lines are carried so a surface can show them.
    Failed {
        name: String,
        installer: String,
        code: u8,
        /// How the package says to undo it, or nothing where it said
        /// nothing — never a claim the package did not make.
        undo: Option<String>,
        report: Box<crate::guard::GuardReport>,
    },
    /// The installer was handed to the operating system and no exit status
    /// came back — a timeout, a kill, an exec that failed after the fork.
    /// Whether it wrote anything is unknowable from here, so this says what
    /// `Failed` says: what it wrote is still there, and here is the undo.
    Unfinished {
        name: String,
        installer: String,
        undo: Option<String>,
        /// Boxed for the same reason as `Run`.
        error: Box<crate::error::CoreError>,
    },
    /// The installer could not be run at all: the scope is not a project,
    /// or the program does not resolve inside the package. Every one of
    /// those is settled before anything is launched, so nothing ran and
    /// nothing was written. Boxed: the error is a rare path and the common
    /// `Ok` should not pay for its size.
    Run(Box<crate::error::CoreError>),
}

impl std::fmt::Display for ArmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use crate::names::shown;
        match self {
            ArmError::NothingToRun { name } => write!(
                f,
                "{}: no installer to run — arm it yourself when you are ready",
                shown(name)
            ),
            ArmError::Failed {
                name,
                installer,
                code,
                undo,
                ..
            } => {
                write!(f, "{}: {} exited {code}", shown(name), shown(installer))?;
                aftermath(f, undo.as_deref())
            }
            ArmError::Unfinished {
                name,
                installer,
                undo,
                error,
            } => {
                write!(
                    f,
                    "{}: {} did not finish ({error})",
                    shown(name),
                    shown(installer)
                )?;
                aftermath(f, undo.as_deref())
            }
            ArmError::Run(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ArmError {}

/// The tail every outcome that may have written something carries: nothing
/// was rolled back, and what the package itself says undoes it.
fn aftermath(f: &mut std::fmt::Formatter<'_>, undo: Option<&str>) -> std::fmt::Result {
    use crate::names::shown;
    write!(f, " — anything it wrote before that is still there; ")?;
    match undo {
        Some(undo) => write!(f, "to undo: {}", shown(undo)),
        None => write!(f, "the package declares no way to undo it"),
    }
}

impl From<crate::error::CoreError> for ArmError {
    fn from(error: crate::error::CoreError) -> Self {
        ArmError::Run(Box::new(error))
    }
}

impl DeclaredEffects {
    /// What the package says undoes its effect: the uninstaller it declared
    /// where there is one, else its removal text, else nothing.
    ///
    /// The uninstaller is resolved under the package the way `arm` resolves
    /// the installer, because a declared script is package-relative and this
    /// line sends a person to the repository root, where that relative path
    /// names nothing. Only the program is resolved; the declared arguments
    /// go out as the package wrote them, and the cwd the line asks for is
    /// still the one kendex would have run it in.
    fn undo(&self) -> Option<String> {
        self.effects
            .uninstaller
            .as_ref()
            .map(|script| {
                let (program, args) = split_script(script);
                let command = std::iter::once(self.root.join(program).display().to_string())
                    .chain(args.into_iter().map(str::to_owned))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("run `{command}` from the repository root")
            })
            .or_else(|| self.effects.removal.clone())
    }
}

#[cfg(test)]
mod tests;

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
