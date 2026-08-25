//! What the safety rules found in what is installed right now: every
//! installation in a scope, its score, its findings, and the checks that
//! had nothing to read. A listing and nothing more — the score is
//! advisory, and nothing here decides anything.

use clap::Args;
use kendex_core::engine::observed_rows;
use kendex_core::env::Env;

use super::engine_common::print_safety_row;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct FindingsArgs {
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
}

/// Every installation in each scope, lowest score first. The clean rows
/// are listed too: a package with nothing found still has a score, and a
/// listing that skipped it would leave "not shown" and "not checked"
/// reading alike.
pub fn findings(env: &Env, args: FindingsArgs) -> CliResult {
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::All)?;
    for scope in resolve_scopes(env, filter)? {
        let mut rows = observed_rows(env, &scope)?;
        if rows.is_empty() {
            say(&format!("{}: nothing installed", scope.label()));
            continue;
        }
        rows.sort_by_key(|row| row.safety.score);
        say(&format!("{}:", scope.label()));
        for row in &rows {
            print_safety_row(row);
        }
    }
    Ok(())
}
