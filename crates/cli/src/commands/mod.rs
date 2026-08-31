pub mod add;
pub mod add_collection;
pub mod adopt;
pub mod apply_cmd;
pub mod blocked;
pub mod check;
pub mod check_catalog;
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
/// up from CWD, v1 rules) and/or global.
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
