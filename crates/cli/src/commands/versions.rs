use clap::Args;

use kendex_core::env::Env;

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct VersionsArgs {
    /// agent | skill | hook | command | mcp-server | pi-extension
    kind: String,
    name: String,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: VersionsArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    let name = args.name;
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let rows = kendex_core::package::versions(env, &scope, kind, &name)?;
    if rows.is_empty() {
        say("no versions known — refresh the source first");
        return Ok(());
    }
    for row in rows {
        let marker = if row.installed { "*" } else { " " };
        let label = row
            .label
            .map(|label| format!("  ({})", label))
            .unwrap_or_default();
        say(&format!(
            "{marker} {}  {}{label}  {}",
            &row.id[..7.min(row.id.len())],
            row.date,
            row.summary
        ));
    }
    Ok(())
}
