use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::{remote, source_ops};

use super::engine_common::apply_report;
use super::{CliResult, out, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;

#[derive(Subcommand)]
pub enum SourceCommand {
    /// List declared sources for the scope
    List,
    /// Declare a source: `owner/repo[@rev]`, a git URL, or a local path
    Add { name: String, reference: String },
    /// Remove a source (blocked while items still reference it)
    Remove { name: String },
    /// Re-enable a source and restore its installations
    Enable { name: String },
    /// Disable a source; its installations deactivate but stay declared
    Disable { name: String },
    /// Re-resolve remote source caches
    Refresh {
        /// Only fetch mirrors whose freshness stamp is old, then re-derive
        /// the drift snapshot — the detached job `kendex check` spawns
        #[arg(long)]
        stale: bool,
    },
}

pub fn run(env: &Env, command: SourceCommand, filter: ScopeFilter) -> CliResult {
    // The stale refresh serves the session check, which reads project AND
    // global — a project-scoped default here would leave global mirrors
    // stale forever (and die outright when run outside a project).
    if let SourceCommand::Refresh { stale: true } = &command {
        let scopes = resolve_scopes(env, ScopeFilter::All)?;
        for note in kendex_core::drift::refresh::refresh_stale(env, &scopes) {
            say(&format!("note: {}", note));
        }
        return Ok(());
    }
    for scope in resolve_scopes(env, filter)? {
        match &command {
            SourceCommand::List => {
                for row in source_ops::list_sources(env, &scope)? {
                    let state = if row.enabled { "" } else { "  (disabled)" };
                    let head = row
                        .head
                        .as_deref()
                        .map(|h| format!("  @{h}"))
                        .unwrap_or_default();
                    out(&format!(
                        "{}  {}  {}{head}{state}  [{} item(s)]",
                        scope.label(),
                        row.name,
                        row.reference,
                        row.declared_items.len()
                    ));
                }
            }
            SourceCommand::Add { name, reference } => {
                let report = source_ops::add_source(env, &scope, name, reference)?;
                apply_report(env, &report)?;
                say(&format!(
                    "{}: declared source '{name}'",
                    scope_label(&scope)
                ));
            }
            SourceCommand::Remove { name } => {
                let report = source_ops::remove_source(env, &scope, name)?;
                apply_report(env, &report)?;
                say(&format!("{}: removed source '{name}'", scope_label(&scope)));
            }
            SourceCommand::Enable { name } | SourceCommand::Disable { name } => {
                let enabled = matches!(command, SourceCommand::Enable { .. });
                let report = source_ops::toggle_source(env, &scope, name, enabled)?;
                apply_report(env, &report)?;
                say(&format!(
                    "{}: source '{name}' {}",
                    scope_label(&scope),
                    if enabled { "enabled" } else { "disabled" }
                ));
            }
            SourceCommand::Refresh { stale: true } => unreachable!("handled above the scope loop"),
            SourceCommand::Refresh { stale: false } => {
                let Some(manifest) = kendex_core::manifest::load_for_mutation(
                    &kendex_core::manifest::manifest_path(env, &scope),
                )?
                else {
                    continue;
                };
                for warning in remote::sync_sources(env, &manifest)? {
                    say(&format!("warning: {}", warning));
                }
                // The fetches above stamped every mirror; the snapshot makes
                // the fresh verdicts what the next session check reads.
                if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
                    say(&format!("warning: snapshot not derived ({})", error));
                }
                say(&format!("{}: sources refreshed", scope_label(&scope)));
            }
        }
    }
    Ok(())
}
