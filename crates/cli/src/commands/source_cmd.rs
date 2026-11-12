use clap::{Args, Subcommand};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::{remote, source_ops};
use source_ops::SourceChange;

use super::engine_common::{AfterFailed, apply_report_accounted};
use super::{CliResult, resolve_scopes, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Cell, Span, Status, Style};

#[derive(Args)]
pub struct SourceArgs {
    #[arg(short = 'g', long, global = true)]
    global: bool,
    /// project | global | all (default project; all for refresh --stale)
    #[arg(long, global = true)]
    scope: Option<String>,
    #[command(subcommand)]
    command: SourceCommand,
}

impl SourceArgs {
    pub(crate) fn effective_scope(&self) -> Result<ScopeFilter, String> {
        ScopeFilter::resolve(self.scope.as_deref(), self.global, ScopeFilter::Project)
    }

    pub(crate) fn writes_project(&self) -> bool {
        match self.command {
            SourceCommand::Add { .. }
            | SourceCommand::Remove { .. }
            | SourceCommand::Enable { .. }
            | SourceCommand::Disable { .. } => true,
            SourceCommand::List | SourceCommand::Refresh { .. } => false,
        }
    }
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
        /// Only check the marketplaces installed packages come from and the
        /// ones the install record names; one of them that was never fetched
        /// and cannot be reached fails the run
        #[arg(long, conflicts_with = "stale")]
        in_use: bool,
    },
}

pub fn run(env: &Env, args: SourceArgs) -> CliResult {
    let filter = args.effective_scope()?;
    let style = ui::style();
    match &args.command {
        // The stale refresh serves the session check, which reads project
        // AND global — a project-scoped default here would leave global
        // mirrors stale forever (and die outright when run outside a
        // project).
        SourceCommand::Refresh { stale: true, .. } => {
            let stale = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::All)?;
            let scopes = resolve_scopes(env, stale)?;
            for note in kendex_core::drift::refresh::refresh_stale(env, &scopes) {
                ui::stderr(&style.report_row(Status::Notice, &[Span::Prose(&note)], "note: "));
            }
            Ok(())
        }
        SourceCommand::Refresh {
            stale: false,
            in_use,
        } => refresh(env, &style, resolve_scopes(env, filter)?, *in_use),
        SourceCommand::List => list(env, &style, &resolve_scopes(env, filter)?),
        SourceCommand::Add {
            name, reference, ..
        } => write_changes(env, &style, filter, SourceChange::Add { name, reference }),
        SourceCommand::Remove { name, .. } => {
            write_changes(env, &style, filter, SourceChange::Remove { name })
        }
        SourceCommand::Enable { name, .. } => write_changes(
            env,
            &style,
            filter,
            SourceChange::SetEnabled {
                name,
                enabled: true,
            },
        ),
        SourceCommand::Disable { name, .. } => write_changes(
            env,
            &style,
            filter,
            SourceChange::SetEnabled {
                name,
                enabled: false,
            },
        ),
    }
}

/// The scopes a listing or a refresh covers, as its header names them.
fn scope_labels(scopes: &[Scope]) -> String {
    scopes
        .iter()
        .map(Scope::label)
        .collect::<Vec<_>>()
        .join(", ")
}

/// Checks each scope's marketplaces for updates, then derives the snapshot
/// the next session check reads.
fn refresh(env: &Env, style: &Style, scopes: Vec<Scope>, in_use: bool) -> CliResult {
    ui::stderr(&style.header("source refresh", &scope_labels(&scopes)));
    for scope in scopes {
        // An absent manifest reads as its seed, as everywhere else: a
        // personal scope that never wrote one still subscribes to the
        // default marketplace, which a refresh must download.
        let manifest = kendex_core::engine::ops::manifest_for_mutation(env, &scope)?;
        let synced = {
            let _checking = ui::spinner(&format!("{}: checking marketplaces", scope_label(&scope)));
            match in_use {
                true => remote::sync_record_sources(env, &scope, &manifest)?,
                false => remote::sync_sources(env, &manifest)?,
            }
        };
        super::engine_common::print_synced(&synced);
        // The fetches above stamped their mirrors; the snapshot makes the
        // fresh verdicts what the next session check reads.
        if let Err(error) = kendex_core::drift::snapshot::record(env, &scope) {
            ui::stderr(&style.report_warning(&format!("snapshot not derived ({})", error)));
        }
        ui::stderr(&style.report_row(
            Status::Done,
            &[Span::Prose(&format!(
                "{}: marketplaces checked for updates",
                scope_label(&scope)
            ))],
            "",
        ));
    }
    Ok(())
}

/// Every scope's marketplaces in one table. A scope that cannot be read
/// ends the listing after the rows read before it are drawn.
fn list(env: &Env, style: &Style, scopes: &[Scope]) -> CliResult {
    ui::stderr(&style.header("source list", &scope_labels(scopes)));
    let mut rows = Vec::new();
    let mut unread = None;
    for scope in scopes {
        match source_ops::list_sources(env, scope) {
            Ok(listed) => rows.extend(listed.iter().map(|row| listed_row(scope, row))),
            Err(error) => {
                unread = Some(error);
                break;
            }
        }
    }
    ui::stdout(&listing(style, &rows));
    match unread {
        Some(error) => Err(error.into()),
        None => Ok(()),
    }
}

/// One marketplace's cells. The revision and the switch ride in the third
/// cell with their own spacing, so a plain row stays the line scripts read.
fn listed_row(scope: &Scope, row: &source_ops::SourceRow) -> Vec<Cell> {
    let head = row
        .head
        .as_deref()
        .map(|head| format!("  @{head}"))
        .unwrap_or_default();
    let state = match row.enabled {
        true => "",
        false => "  (switched off)",
    };
    vec![
        Cell::default().copy(scope.label()),
        row.name.clone().into(),
        Cell::default()
            .copy(row.reference.clone())
            .prose(format!("{head}{state}")),
        format!("[{} package(s)]", row.declared_items.len()).into(),
    ]
}

fn listing(style: &Style, rows: &[Vec<Cell>]) -> Vec<String> {
    style.report_table(
        "marketplaces",
        &["scope", "name", "from", "packages"],
        rows,
        ui::report::PlainColumns::Joined,
    )
}

fn write_changes(
    env: &Env,
    style: &Style,
    filter: ScopeFilter,
    change: SourceChange<'_>,
) -> CliResult {
    let scopes = resolve_scopes(env, filter)?;
    let (verb, name) = match change {
        SourceChange::Add { name, .. } => ("source add", name),
        SourceChange::Remove { name } => ("source remove", name),
        SourceChange::SetEnabled {
            name,
            enabled: true,
        } => ("source enable", name),
        SourceChange::SetEnabled {
            name,
            enabled: false,
        } => ("source disable", name),
    };
    ui::stderr(&style.header(verb, name));
    let prepared: Vec<_> = scopes
        .iter()
        .map(|scope| source_ops::prepare_source_change(env, scope, change))
        .collect();
    for prepared in prepared.iter().flatten() {
        if let Err(error) = prepared.check_catalog_compatibility(env)
            && error.is_catalog_compatibility()
        {
            return Err(error.into());
        }
    }
    for (scope, prepared) in scopes.into_iter().zip(prepared) {
        let wrote = apply_report_accounted(env, &prepared?.plan(env)?, None)?;
        // The edit is on disk once the write returns: it is said before a
        // failed step after it, which the run then ends on.
        ui::stderr(&style.report_row(Status::Done, &[Span::Prose(&written(change, &scope))], ""));
        wrote.after.map_err(AfterFailed::into_error)?;
    }
    Ok(())
}

/// What a landed subscription edit did in one scope.
fn written(change: SourceChange<'_>, scope: &Scope) -> String {
    let scope = scope_label(scope);
    match change {
        SourceChange::Add { name, .. } => format!("{scope}: added marketplace '{name}'"),
        SourceChange::Remove { name } => format!("{scope}: removed marketplace '{name}'"),
        SourceChange::SetEnabled {
            name,
            enabled: true,
        } => format!("{scope}: marketplace '{name}' switched on"),
        SourceChange::SetEnabled {
            name,
            enabled: false,
        } => format!("{scope}: marketplace '{name}' switched off"),
    }
}

#[cfg(test)]
mod tests;
