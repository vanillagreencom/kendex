use clap::Args;
use kendex_core::env::Env;

use super::advisory::Listing;
use super::engine_common::{confirm_and_execute, print_report};
use super::{CliResult, resolve_scopes};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct ToggleArgs {
    #[arg(required = true)]
    names: Vec<String>,
    /// Narrow to agent | skill | hook | command | mcp-server | plugin | pi-extension
    #[arg(long)]
    kind: Option<String>,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip confirmation prompts
    #[arg(short = 'y', long)]
    yes: bool,
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

pub fn run(env: &Env, args: ToggleArgs, enabled: bool) -> CliResult {
    let kind = args
        .kind
        .as_deref()
        .map(super::pin::parse_kind_or_plugin)
        .transpose()?;
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    for scope in resolve_scopes(env, filter)? {
        let report =
            kendex_core::engine::ops::toggle(env, &scope, &args.names, kind, enabled, None)?;
        print_report(env, &report, Listing::Every);
        confirm_and_execute(env, &report, args.yes)?;
    }
    Ok(())
}
