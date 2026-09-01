//! Undoing a package's repository effect when the package leaves.
//!
//! One loop for both surfaces. The terminal writes its lines as it goes and
//! the window shows them beside the action's result, but they owe the same
//! account — a second spelling of this would be a second answer to "was
//! that repository disarmed".

use super::{DeclaredEffects, run_script, touches_git};

/// A line an undo produced, tagged with where it came from.
///
/// Three tags rather than one stream, because two distinctions matter and
/// neither surface can recover them afterwards. kendex's own account is
/// told from the package's, so a surface knows which lines are already
/// escaped and which are a third party's to escape. And the package's
/// stdout is told from its stderr, so a terminal can hand the summary on
/// byte for byte for whatever is piping it while everything else goes out
/// as a line to read. A window has no pipe and escapes both.
#[derive(Debug, Clone, PartialEq)]
pub enum Spoken {
    /// kendex's account of what it did about one package's effect.
    Note(String),
    /// A line the package's uninstaller wrote for a person to read.
    Stderr(String),
    /// A line the package's uninstaller wrote as its answer.
    Stdout(String),
}

impl Spoken {
    /// The line itself, for a surface that shows all three the same way.
    pub fn into_line(self) -> String {
        match self {
            Spoken::Note(line) | Spoken::Stderr(line) | Spoken::Stdout(line) => line,
        }
    }
}

/// Why a plan's removal stopped before it took anything away.
#[derive(Debug)]
pub enum UndoError {
    /// The uninstaller ran and exited nonzero. The package stays installed:
    /// the plan is stopped here with its files in place, so the person can
    /// fix what the script reported and remove again. The other order
    /// leaves a repository armed against scripts that are gone.
    Failed {
        name: String,
        uninstaller: String,
        code: u8,
    },
    /// The uninstaller could not be run at all.
    Run(Box<crate::error::CoreError>),
}

impl std::fmt::Display for UndoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use crate::names::shown;
        match self {
            UndoError::Failed {
                name,
                uninstaller,
                code,
            } => write!(
                f,
                "{}: {} exited {code} — its files stay in place; \
                 fix what it reported and run this again",
                shown(name),
                shown(uninstaller)
            ),
            UndoError::Run(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for UndoError {}

impl From<crate::error::CoreError> for UndoError {
    fn from(error: crate::error::CoreError) -> Self {
        UndoError::Run(Box::new(error))
    }
}

/// Run the uninstaller of every package a plan takes away, before the plan
/// takes it, and hand each line to `spoke`.
///
/// Before, because the uninstaller is one of the files going: after the
/// plan there is nothing to run, and the effect outlives its package as
/// shims that exec a script that is not there and fail every commit
/// closed. Not asked about — removing the package is the ask — and said
/// out loud, so the person knows what ran in their repository.
///
/// Here rather than at a surface, because both of them owe the same
/// account: the terminal writes the lines as it goes and a window shows
/// them beside the action's result, and a second spelling of this loop is
/// a second answer to "was that repository disarmed".
///
/// A package that declares no uninstaller has nothing to run, and the
/// removal goes ahead with that said — its files were going either way,
/// and the disclosure named this the day it was installed.
///
/// The same stand-down as the disclosure's: an effect that writes into
/// `.git` was never offered where the project has no git work tree, so
/// there is nothing armed to undo and the uninstaller — which exits 2
/// outside a repository — is not run. Otherwise removing a package from a
/// plain directory failed every time, over hooks it could never have had.
pub fn undo(
    scope: &crate::model::Scope,
    leaving: &[DeclaredEffects],
    spoke: &mut dyn FnMut(Spoken),
) -> std::result::Result<(), UndoError> {
    use crate::names::shown;
    let crate::model::Scope::Project { root } = scope else {
        return Ok(());
    };
    // Asked once, and only when something leaving would need the answer:
    // the probe is git processes, and a package that writes nowhere near
    // `.git` never asks. `touches_git` is the same reading the disclosure
    // was made under, so an effect is armed and disarmed on one answer
    // rather than two spellings of one.
    //
    // `probe`, not the disclosure's `at`: that one withholds an offer where
    // git will not answer, because it is about to ask somebody to authorize
    // a path it cannot name. This side only asks whether the work tree that
    // could have been armed is here.
    let git_here = leaving
        .iter()
        .any(|declared| touches_git(&declared.effects))
        && crate::guard::Repo::probe(root)?.is_some();
    for declared in leaving {
        let name = shown(&declared.name);
        if touches_git(&declared.effects) && !git_here {
            spoke(Spoken::Note(format!(
                "{name}: not inside a git work tree, so nothing it armed is here to undo"
            )));
            continue;
        }
        let Some(uninstaller) = &declared.effects.uninstaller else {
            spoke(Spoken::Note(format!(
                "{name}: declares no uninstaller — what it changed about this repository stays{}",
                match &declared.effects.removal {
                    Some(removal) => format!("; to undo: {}", shown(removal)),
                    None => String::new(),
                }
            )));
            continue;
        };
        spoke(Spoken::Note(format!(
            "{name}: running {}",
            shown(uninstaller)
        )));
        let report = run_script(scope, &declared.root, uninstaller)?;
        for line in report.stderr {
            spoke(Spoken::Stderr(line));
        }
        for line in report.stdout {
            spoke(Spoken::Stdout(line));
        }
        if report.code != 0 {
            // No verb named: under an apply or a refresh the package is
            // already out of the manifest, and "remove it again" would
            // answer "Nothing removed".
            return Err(UndoError::Failed {
                name: declared.name.clone(),
                uninstaller: uninstaller.clone(),
                code: report.code,
            });
        }
    }
    Ok(())
}
