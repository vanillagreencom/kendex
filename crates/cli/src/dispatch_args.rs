//! The two dispatch helpers whose flag-untangling outgrew the command
//! table: `check` (catalog vs. scope) and `remove` (what happens to the
//! declaration, and the sweep answer).

use crate::scope::ScopeFilter;
use kendex_core::env::Env;
use std::process::ExitCode;

use crate::commands;
use crate::commands::remove::Removal;

/// `kendex check`'s flags.
#[derive(clap::Args)]
pub(crate) struct CheckArgs {
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
    /// Machine-readable report
    #[arg(long)]
    json: bool,
    /// Print a short report, or nothing when all checks pass
    #[arg(short = 'q', long)]
    quiet: bool,
    /// Leave the project's install record as it is, and report what it
    /// lacks
    #[arg(long, conflicts_with = "catalog")]
    report_only: bool,
    /// Check this marketplace directory instead of this computer
    #[arg(long)]
    pub(crate) catalog: Option<std::path::PathBuf>,
    /// With --catalog, also fail on advisories
    #[arg(long)]
    strict: bool,
}

pub(crate) fn check(env: &Env, args: CheckArgs) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let CheckArgs {
        global,
        scope,
        json,
        quiet,
        report_only,
        catalog,
        strict,
    } = args;
    match catalog {
        Some(catalog) => {
            commands::check_catalog::run(&catalog, strict, json).map(|()| ExitCode::SUCCESS)
        }
        None => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            let mode = match report_only {
                true => kendex_core::drift::copies::CheckMode::ReportOnly,
                false => kendex_core::drift::copies::CheckMode::Settle,
            };
            commands::check::run(env, filter, json, quiet, mode)
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
