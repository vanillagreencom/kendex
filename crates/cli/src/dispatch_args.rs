//! The two dispatch helpers whose flag-untangling outgrew the command
//! table: `check` (catalog vs. scope) and `remove` (what happens to the
//! declaration, and the sweep answer).

use crate::scope::ScopeFilter;
use kendex_core::env::Env;
use std::process::ExitCode;

use crate::commands;
use crate::commands::remove::Removal;

pub(crate) fn check(
    env: &Env,
    global: bool,
    scope: Option<String>,
    json: bool,
    quiet: bool,
    catalog: Option<std::path::PathBuf>,
    strict: bool,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    match catalog {
        Some(catalog) => {
            commands::check_catalog::run(&catalog, strict, json).map(|()| ExitCode::SUCCESS)
        }
        None => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            commands::check::run(env, filter, json, quiet)
        }
    }
}

pub(crate) fn remove(
    env: &Env,
    names: Vec<String>,
    global: bool,
    scope: Option<String>,
    sweep: bool,
    no_sweep: bool,
    keep_declaration: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let mode = match (keep_declaration, sweep, no_sweep) {
        (true, _, _) => Removal::KeepDeclaration,
        (_, true, _) => Removal::Disown { sweep: Some(true) },
        (_, _, true) => Removal::Disown { sweep: Some(false) },
        _ => Removal::Disown { sweep: None },
    };
    commands::remove::run(env, names, filter, mode)
}
