pub mod add;
pub mod add_collection;
pub mod adopt;
pub mod advisory;
pub mod apply_cmd;
pub mod blocked;
pub mod check;
pub mod check_catalog;
pub mod commit_offer;
pub mod diff_cmd;
pub mod drift_hook;
pub mod engine_common;
pub mod fork_cmd;
pub mod guard_cmd;
pub mod harness_picker;
pub mod index_cmd;
pub mod init;
pub mod ledger;
pub mod list;
pub mod login;
pub mod marketplace_author;
pub mod marketplace_browse;
pub mod marketplace_cmd;
pub mod offers;
pub mod pin;
pub mod project;
pub mod refresh;
pub mod remove;
pub mod repo_effects;
pub mod report;
pub mod show;
pub mod source_cmd;
pub mod update;
pub mod update_pi;
pub mod updates_cmd;
pub mod verify;
pub mod version_compare;
pub mod versions;

use std::path::PathBuf;

use kendex_core::discover;
use kendex_core::env::Env;
use kendex_core::model::Scope;

use crate::scope::ScopeFilter;

// Every human line a command says leaves through the presentation module,
// which decides between the plain lines a script parses and the framed
// session a terminal gets. A command never writes to a stream itself.
pub use crate::ui::{Lines, answer, escaped, fail, fail_refusal, note, out, payload, say, warn};

pub type CliResult = Result<(), Box<dyn std::error::Error>>;

/// A scope as a human line names it. The label is a path somebody chose,
/// and a path carries whatever the filesystem allowed; the `ui` seam
/// escapes it on the way out, wherever it was composed in.
pub fn scope_label(scope: &Scope) -> String {
    scope.label()
}

/// The scopes a filter selects on this machine: the current project (walked
/// up from CWD) and/or global.
pub fn resolve_scopes(env: &Env, filter: ScopeFilter) -> Result<Vec<Scope>, String> {
    let current = current_project(env);
    match filter {
        ScopeFilter::Global => Ok(vec![Scope::Global]),
        ScopeFilter::Project => match current {
            Some(root) => Ok(vec![Scope::Project { root }]),
            None => Err("not inside a project (no harness marker found walking up)".to_owned()),
        },
        ScopeFilter::All => {
            let mut scopes: Vec<Scope> = current
                .map(|root| Scope::Project { root })
                .into_iter()
                .collect();
            scopes.push(Scope::Global);
            Ok(scopes)
        }
    }
}

fn current_project(env: &Env) -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    discover::project_root_from(&cwd, env.real_home())
}

/// Where a project-scope install lands.
///
/// An established project answers for itself: the walk up from the working
/// directory is unchanged, so a command typed inside one installs into it
/// however deep the caller stands.
///
/// Where that walk answers with nothing, the destination is the folder the
/// command was typed in. kendex used to refuse until a harness directory
/// was created there by hand, which is a step nobody can guess at; and the
/// walk's own answer is the only ancestor there is, so there is nothing to
/// fall back to that the person named. A folder that becomes a project is
/// a change worth asking about, so it is asked before anything is planned
/// or written, and a session with nobody to ask refuses and names the flag
/// that would have answered.
pub fn install_destination(env: &Env, yes: bool) -> Result<Scope, Box<dyn std::error::Error>> {
    let here = std::env::current_dir()
        .and_then(|cwd| kendex_core::paths::canonical(&cwd))
        .map_err(|e| format!("the current folder could not be read: {e}"))?;
    destination(current_project(env), here, yes)
}

/// The choice itself, over the two answers it is made from: what the walk
/// up found, and where the command was typed. Separated from the reads so
/// the rule can be asked directly — a walk starts at a working directory
/// this process cannot move.
fn destination(
    established: Option<PathBuf>,
    here: PathBuf,
    yes: bool,
) -> Result<Scope, Box<dyn std::error::Error>> {
    if let Some(root) = established {
        return Ok(Scope::Project { root });
    }
    start_a_project_here(&here, yes)?;
    Ok(Scope::Project { root: here })
}

/// The question a fresh destination is settled by. Asked before the plan,
/// so a no costs nothing: no manifest, no lock and no harness directory
/// exists in a folder that was never installed into.
fn start_a_project_here(here: &std::path::Path, yes: bool) -> CliResult {
    if yes {
        return Ok(());
    }
    let here = here.display().to_string();
    if !std::io::IsTerminal::is_terminal(&std::io::stdin()) {
        return Err(format!(
            "{here} is not a project yet — installing here makes it one; pass --yes to install into it, or --global for the personal scope"
        )
        .into());
    }
    say(&format!(
        "{here} is not a project yet — installing here makes it one, and puts it on your projects list"
    ));
    match crate::ui::confirm("install into this folder?")? {
        true => Ok(()),
        false => Err("install cancelled".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole rule, over both answers the walk can give. An established
    /// project is the destination however deep the command was typed; with
    /// no project above it, the folder it was typed in is — and never an
    /// ancestor, which is the one thing a person cannot see happening.
    ///
    /// A run with nobody to ask refuses rather than making a project out of
    /// whatever directory a script happened to be in, and it names the two
    /// flags that answer it. `cargo test` gives this no terminal, so the
    /// unanswered row is the one that runs here.
    #[test]
    fn a_walk_that_found_nothing_settles_on_the_folder_the_command_was_typed_in() {
        let here = PathBuf::from("/w/dev/vsys-view");
        let above = PathBuf::from("/w/dev");

        assert_eq!(
            destination(Some(above.clone()), here.clone(), true).unwrap(),
            Scope::Project { root: above }
        );
        assert_eq!(
            destination(None, here.clone(), true).unwrap(),
            Scope::Project { root: here.clone() }
        );

        let refused = destination(None, here, false).unwrap_err().to_string();
        assert!(refused.contains("/w/dev/vsys-view"), "{refused}");
        assert!(refused.contains("--yes"), "{refused}");
        assert!(refused.contains("--global"), "{refused}");
    }
}
