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
mod undo;
use declaration::split_script;
pub use declaration::{Declaration, RepoEffects, declaration, declared};
pub use disclosure::{
    Companion, Disclosure, Offers, Withheld, Written, installed_skills, offers, offers_for,
    touches_git,
};
pub use undo::{Spoken, UndoError, undo};

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

/// Run one of a package's declared scripts and hand back what it said.
///
/// Whichever script it is: `arm` is the installer's path and judges the
/// exit itself, because a failed install is a half-written repository with
/// one account to give. A caller undoing an effect reads the same verdict
/// against a different plan, so it takes the report and decides.
pub fn run_script(
    scope: &crate::model::Scope,
    root: &std::path::Path,
    spec: &str,
) -> crate::error::Result<crate::guard::GuardReport> {
    let (repo, program, argv) = resolve_script(scope, root, spec)?;
    launch_script(repo, &program, argv)
}

pub(crate) fn err(message: impl Into<String>) -> crate::error::CoreError {
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
    let report = launch_script(repo, &program, argv)?;
    if report.code != 0 {
        return Err(ArmError::Failed {
            name: declared.name.clone(),
            installer: installer.clone(),
            code: report.code,
            undo: declared.undo(repo),
            report: Box::new(report),
        });
    }
    Ok(report)
}

/// Where this scope recorded one installed skill's tree, as the install
/// wrote it down.
///
/// What a surface asks before arming a declaration it took back from
/// something it does not control. `arm` checks only that the program sits
/// inside the root it was handed, which is the caller's answer checked
/// against itself: a root of `/` passes it with any program underneath.
///
/// Read off the lock rather than derived. A copy delivery puts the tree in
/// the harness's own directory instead of the shared one, so a derivation
/// naming `.agents/skills/<name>` would refuse a package that is installed
/// perfectly well — the same reason removal and refresh read the record
/// instead of deriving a path the install never took.
pub fn recorded_roots(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    name: &str,
) -> crate::error::Result<std::collections::BTreeSet<std::path::PathBuf>> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    Ok(lock
        .entries
        .values()
        .filter(|entry| entry.kind == crate::model::ItemKind::Skill && entry.name == name)
        .filter_map(|entry| entry.emitted.as_ref())
        // The tree, never the link beside it: a link is where a tool reads
        // the package through, not a directory its scripts live in.
        .filter_map(|emitted| emitted.paths.first().cloned())
        .collect())
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
    /// The installer could not be run at all. Boxed: the error is a rare
    /// path and the common `Ok` should not pay for its size.
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
                write!(
                    f,
                    "{}: {} exited {code} — anything it wrote before that is still there; ",
                    shown(name),
                    shown(installer)
                )?;
                match undo {
                    Some(undo) => write!(f, "to undo: {}", shown(undo)),
                    None => write!(f, "the package declares no way to undo it"),
                }
            }
            ArmError::Run(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ArmError {}

impl From<crate::error::CoreError> for ArmError {
    fn from(error: crate::error::CoreError) -> Self {
        ArmError::Run(Box::new(error))
    }
}

impl DeclaredEffects {
    /// What the package says undoes its effect: the uninstaller it declared
    /// where there is one, else its removal text, else nothing.
    ///
    /// The uninstaller is a package-relative script and this line sends a
    /// person to `repo` to run it, where that relative path names nothing.
    /// So the declared program is joined onto the package directory and
    /// written relative to `repo`, which is where the sentence already tells
    /// them to stand — the spelling a project install always has, since the
    /// package sits under the project. A program somewhere else is written
    /// whole.
    ///
    /// The join is all of it. Whether that path exists and stays inside the
    /// package is `arm`'s question, settled in `resolve_script` for the
    /// program it is about to run; this one is a line to read.
    ///
    /// Half of the joined path is a native join and half is a `/`-spelled
    /// literal the package declared, so it goes out through
    /// `crate::paths::slashed`: a shell reads `\` as an escape, and a
    /// command a person pastes has to be one a shell runs.
    ///
    /// Every word goes out through `names::quoted`, the program and each
    /// declared argument alike. This is a command to paste: a checkout at
    /// `~/My Project` would otherwise name a program ending at `My`, and a
    /// `;` or a backtick a package declared would be live in the shell it
    /// is pasted into rather than the argument kendex itself passes.
    fn undo(&self, repo: &std::path::Path) -> Option<String> {
        self.effects
            .uninstaller
            .as_ref()
            .map(|script| {
                let (program, args) = split_script(script);
                let whole = self.root.join(program);
                let path =
                    crate::paths::slashed(whole.strip_prefix(repo).unwrap_or(whole.as_path()));
                let command = std::iter::once(crate::names::quoted(&path))
                    .chain(args.into_iter().map(crate::names::quoted))
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
