use clap::{Args, Subcommand};
use kendex_core::env::Env;
use kendex_core::{remote, source_ops};

use super::engine_common::apply_report;
use super::{CliResult, out, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct SourceArgs {
    #[arg(short = 'g', long, global = true)]
    global: bool,
    /// project | global | all (default project)
    #[arg(long, global = true)]
    scope: Option<String>,
    #[command(subcommand)]
    command: SourceCommand,
}

#[derive(Subcommand)]
pub enum SourceCommand {
    /// List the marketplaces this place installs from, and which are switched off
    List,
    /// Add a marketplace: `owner/repo[@rev]`, a git URL, or a local path
    Add {
        name: String,
        reference: String,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// Remove a marketplace (refused while packages still come from it)
    Remove {
        name: String,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// Switch a marketplace back on here and restore the packages installed
    /// from it
    Enable {
        name: String,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// Switch a marketplace off here: the packages installed from it switch
    /// off, nothing is deleted, and switching it back on puts them back
    Disable {
        name: String,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// Check marketplaces for updates
    Refresh {
        /// Only check marketplaces not checked recently, then record which
        /// installed files changed — the background job check starts
        #[arg(long)]
        stale: bool,
    },
}

pub fn run(env: &Env, args: SourceArgs) -> CliResult {
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let command = args.command;
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
                    let state = if row.enabled { "" } else { "  (switched off)" };
                    let head = row
                        .head
                        .as_deref()
                        .map(|h| format!("  @{h}"))
                        .unwrap_or_default();
                    out(&format!(
                        "{}  {}  {}{head}{state}  [{} package(s)]",
                        scope.label(),
                        row.name,
                        row.reference,
                        row.declared_items.len()
                    ));
                }
            }
            SourceCommand::Add {
                name, reference, ..
            } => {
                let report = source_ops::add_source(env, &scope, name, reference)?;
                apply_report(env, &report)?;
                say(&format!(
                    "{}: added marketplace '{name}'",
                    scope_label(&scope)
                ));
            }
            SourceCommand::Remove { name, .. } => {
                let report = source_ops::remove_source(env, &scope, name)?;
                apply_report(env, &report)?;
                say(&format!(
                    "{}: removed marketplace '{name}'",
                    scope_label(&scope)
                ));
            }
            SourceCommand::Enable { name, .. } | SourceCommand::Disable { name, .. } => {
                let enabled = matches!(command, SourceCommand::Enable { .. });
                let report = source_ops::toggle_source(env, &scope, name, enabled)?;
                apply_report(env, &report)?;
                say(&format!(
                    "{}: marketplace '{name}' {}",
                    scope_label(&scope),
                    if enabled {
                        "switched on"
                    } else {
                        "switched off"
                    }
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
                super::engine_common::print_synced(&remote::sync_sources(env, &manifest)?);
                // The fetches above stamped every mirror; the snapshot makes
                // the fresh verdicts what the next session check reads.
                if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
                    say(&format!("warning: snapshot not derived ({})", error));
                }
                say(&format!(
                    "{}: marketplaces checked for updates",
                    scope_label(&scope)
                ));
            }
        }
    }
    Ok(())
}
