use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::source_ops;

use super::engine_common::{AfterFailed, apply_report_accounted};
use super::{CliResult, answer, resolve_scopes, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Cell, Span, Status, Style};

#[derive(Subcommand)]
pub enum MarketplaceCommand {
    /// List marketplace subscriptions and package counts
    List {
        /// Print the list as JSON
        #[arg(long)]
        json: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Subscribe to a marketplace: `owner/repo[@rev]`, a git URL, a GitHub
    /// tree URL, a skills.sh package URL, or a local folder
    Subscribe {
        reference: String,
        /// Name for the subscription (default: the last path segment)
        #[arg(long)]
        name: Option<String>,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global (default project)
        #[arg(long)]
        scope: Option<String>,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// Unsubscribe from a marketplace, removing or keeping its packages
    Unsubscribe {
        name: String,
        /// Remove everything installed from it
        #[arg(long, conflicts_with = "keep_packages")]
        remove_packages: bool,
        /// Keep its packages as your own copies
        #[arg(long)]
        keep_packages: bool,
        /// With --remove-packages: discard edits on disk too, instead of refusing
        #[arg(long)]
        discard_edits: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global (default project)
        #[arg(long)]
        scope: Option<String>,
        /// The commit offer's answer, without asking
        #[command(flatten)]
        _commit: crate::commands::commit_offer::CommitFlags,
    },
    /// List packages and bundles from your subscribed marketplaces
    Browse {
        /// The subscription to browse (default: every subscription in scope)
        marketplace: Option<String>,
        /// Print the list as JSON
        #[arg(long)]
        json: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Check a marketplace folder for problems
    Check {
        /// The marketplace directory (default: the current directory)
        dir: Option<std::path::PathBuf>,
    },
    /// Create a marketplace folder with package checks
    New {
        name: String,
        #[arg(long)]
        description: Option<String>,
        /// Defaults to `git config user.name`
        #[arg(long)]
        author: Option<String>,
        /// mit | apache-2.0 | none (default none — valid locally, blocks
        /// submission until chosen)
        #[arg(long)]
        license: Option<String>,
        /// Where to create it (default: `./<name>`)
        #[arg(long)]
        dir: Option<std::path::PathBuf>,
    },
    /// Add an existing marketplace folder to Mine without changing its files
    Use { dir: std::path::PathBuf },
    /// List your own marketplaces and show whether they are ready to share
    Mine {
        /// Print the list as JSON
        #[arg(long)]
        json: bool,
    },
    /// Copy packages from this computer into an authored marketplace. With
    /// no selections, lists every candidate and where its bytes live.
    Import {
        /// The authored marketplace directory to copy into
        target: std::path::PathBuf,
        #[arg(long = "skill")]
        skills: Vec<String>,
        #[arg(long = "agent")]
        agents: Vec<String>,
        #[arg(long = "hook")]
        hooks: Vec<String>,
        #[arg(long = "command")]
        commands: Vec<String>,
        #[arg(long = "mcp")]
        mcp: Vec<String>,
        /// project | global | all (default all) — where candidates come from
        #[arg(long)]
        from_scope: Option<String>,
        /// When one name exists with different bytes in several places:
        /// the hash (prefix) of the origin to copy
        #[arg(long)]
        origin: Option<String>,
        /// Destination name when the original would be refused (one
        /// selection only)
        #[arg(long = "as")]
        rename: Option<String>,
        /// Confirm the shown license of a package from a marketplace
        /// allows republishing
        #[arg(long)]
        confirm_license: bool,
        /// A package from a marketplace with no license found: your
        /// reason for copying
        #[arg(long)]
        license_basis: Option<String>,
        /// Print the packages available to copy as JSON
        #[arg(long)]
        json: bool,
    },
    /// Submit your marketplace to the kendex.ai community directory
    Submit {
        /// The marketplace directory (default: the current directory)
        dir: Option<std::path::PathBuf>,
        /// Check the marketplace and preview its submission without sending it
        #[arg(long)]
        dry_run: bool,
        /// Show the status of everything you have submitted
        #[arg(long)]
        status: bool,
    },
}

fn run_unsubscribe(
    env: &Env,
    name: &str,
    remove_packages: bool,
    keep_packages: bool,
    discard_edits: bool,
    global: bool,
    scope: Option<String>,
) -> CliResult {
    use kendex_core::engine::detach;
    let style = ui::style();
    ui::stderr(&style.header("marketplace unsubscribe", &[Span::Prose(name)]));
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);

    let manifest = kendex_core::engine::ops::manifest_for_mutation(env, &scope)?;
    let closure = detach::closure(env, &scope, name, &manifest)?;

    // Each arm ends once its first write has landed, on how the steps
    // after it went: the unsubscribe is said whatever they did.
    let after: CliResult = match (remove_packages, keep_packages) {
        (false, false) if !closure.items.is_empty() => {
            return Err(format!(
                "'{name}' has {} package(s) installed — pass --remove-packages to remove them or --keep-packages to keep them as your own copies",
                closure.items.len()
            )
            .into());
        }
        // A bare plan: keeping moves tables, and takes no package away.
        // Its re-sync is a second transaction, which can fail with the
        // first one already on disk.
        (_, true) => {
            let plan = detach::source(env, &scope, name)?;
            kendex_core::apply::execute(env, &plan)?;
            detach::resync_kept(env, &scope)
                .map_err(Into::into)
                .and_then(|resync| {
                    ui::stderr(&super::engine_common::warning_lines(
                        &style,
                        &resync.warnings,
                    ));
                    apply_report_accounted(env, &resync, None)
                })
                .and_then(|wrote| wrote.after.map_err(AfterFailed::into_error))
        }
        (_, false) => {
            let report = detach::remove(env, &scope, name, discard_edits)?;
            apply_report_accounted(env, &report, None)?
                .after
                .map_err(AfterFailed::into_error)
        }
    };
    ui::stderr(&unsubscribed(
        &style,
        &scope,
        name,
        closure.items.len(),
        keep_packages,
    ));
    after
}

/// The landed unsubscribe: from what, and how many of its packages went
/// or stayed.
fn unsubscribed(
    style: &Style,
    scope: &kendex_core::model::Scope,
    name: &str,
    packages: usize,
    kept: bool,
) -> Vec<String> {
    let kept = if kept { "kept" } else { "removed" };
    style.report_row(
        Status::Done,
        &[Span::Prose(&format!(
            "{}: unsubscribed from '{name}', {packages} {kept}",
            scope_label(scope),
        ))],
        "",
    )
}

fn run_list(env: &Env, json: bool, global: bool, scope: Option<String>) -> CliResult {
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
    let mut rows = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        rows.extend(source_ops::list_subscriptions(env, &scope)?);
    }
    if json {
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": 1,
            "subscriptions": rows,
        }))?);
        return Ok(());
    }
    let style = ui::style();
    let count = rows.len();
    ui::stderr(&style.header(
        "marketplace list",
        &[Span::Prose(&format!(
            "{count} subscription{}",
            if count == 1 { "" } else { "s" }
        ))],
    ));
    let cells: Vec<Vec<Cell>> = rows.into_iter().map(subscription_cells).collect();
    ui::stdout(&subscriptions(&style, &cells));
    Ok(())
}

/// One subscription's cells. The revision rides with its source and the
/// switch with its count, each with its own spacing, so a plain row stays
/// the line scripts read.
fn subscription_cells(row: source_ops::SubscriptionRow) -> Vec<Cell> {
    let what = row.repo.or(row.path).unwrap_or_default();
    let rev = row.rev.map(|rev| format!(" @ {rev}")).unwrap_or_default();
    let counted = match row.counts {
        Some(counts) => {
            let total: usize = counts.values().sum();
            format!("{total} package(s)")
        }
        None => "not downloaded yet".to_owned(),
    };
    let state = if row.enabled { "" } else { "  (switched off)" };
    vec![
        Cell::default().copy(row.scope.label()),
        row.name.into(),
        Cell::default().copy(what).prose(rev),
        format!("[{counted}]{state}").into(),
    ]
}

fn subscriptions(style: &Style, cells: &[Vec<Cell>]) -> Vec<String> {
    style.report_table(
        "subscriptions",
        &["scope", "name", "from", "packages"],
        cells,
        ui::report::PlainColumns::Joined,
    )
}

fn run_subscribe(
    env: &Env,
    reference: &str,
    name: Option<&str>,
    global: bool,
    scope: Option<String>,
) -> CliResult {
    let style = ui::style();
    ui::stderr(&style.header("marketplace subscribe", &[Span::Prose(reference)]));
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let subscribed = {
        let _reading = ui::spinner("reading the marketplace");
        source_ops::subscribe(env, &scope, reference, name)?
    };
    for note in &subscribed.report.notes {
        ui::stderr(&style.report_row(Status::Notice, &[Span::Prose(note)], ""));
    }
    // The manifest change is accepted once this returns; what fails after
    // it is said under the subscription, never in its place.
    let wrote = apply_report_accounted(env, &subscribed.report, None)?;
    // Subscribing fetches so counts can land; a failure costs the
    // counts, never the subscription.
    if let Ok(Some(manifest)) =
        kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(env, &scope))
        && let Some(decl) = manifest.sources.get(&subscribed.name)
        && let Some(repo) = decl.repo.clone()
        && let Err(error) = {
            let _downloading = ui::spinner("downloading the marketplace");
            kendex_core::remote::sync(env, &repo, decl.rev.as_deref())
        }
    {
        ui::stderr(&style.report_warning(&format!("not downloaded yet ({})", error)));
    }
    ui::stderr(&subscribed_lines(&style, &scope, &subscribed));
    wrote.after.map_err(AfterFailed::into_error)?;
    Ok(())
}

/// The landed subscription, and the package its reference pointed at.
fn subscribed_lines(
    style: &Style,
    scope: &kendex_core::model::Scope,
    subscribed: &source_ops::Subscribed,
) -> Vec<String> {
    let mut lines = style.report_row(
        Status::Done,
        &[Span::Prose(&format!(
            "{}: subscribed to '{}' ({})",
            scope_label(scope),
            subscribed.name,
            subscribed.reference
        ))],
        "",
    );
    if let Some(lead) = &subscribed.lead {
        lines.extend(style.report_row(
            Status::Notice,
            &[Span::Prose("package: "), Span::Command(lead)],
            "",
        ));
    }
    lines
}

pub fn run(env: &Env, command: MarketplaceCommand) -> CliResult {
    match command {
        MarketplaceCommand::List {
            json,
            global,
            scope,
        } => run_list(env, json, global, scope)?,
        MarketplaceCommand::Subscribe {
            reference,
            name,
            global,
            scope,
            ..
        } => run_subscribe(env, &reference, name.as_deref(), global, scope)?,
        MarketplaceCommand::Unsubscribe {
            name,
            remove_packages,
            keep_packages,
            discard_edits,
            global,
            scope,
            ..
        } => run_unsubscribe(
            env,
            &name,
            remove_packages,
            keep_packages,
            discard_edits,
            global,
            scope,
        )?,
        MarketplaceCommand::Browse {
            marketplace,
            json,
            global,
            scope,
        } => super::marketplace_browse::run_browse(env, marketplace, json, global, scope)?,
        MarketplaceCommand::Check { dir } => {
            let dir = match dir {
                Some(dir) => dir,
                None => std::env::current_dir()?,
            };
            let style = ui::style();
            ui::stderr(&style.header(
                "marketplace check",
                &[Span::Command(&dir.display().to_string())],
            ));
            super::check_catalog::run(&dir, true, false)?;
        }
        MarketplaceCommand::New {
            name,
            description,
            author,
            license,
            dir,
        } => super::marketplace_author::new(env, &name, description, author, license, dir)?,
        MarketplaceCommand::Use { dir } => super::marketplace_author::use_existing(env, &dir)?,
        MarketplaceCommand::Mine { json } => super::marketplace_author::mine(env, json)?,
        MarketplaceCommand::Import {
            target,
            skills,
            agents,
            hooks,
            commands,
            mcp,
            from_scope,
            origin,
            rename,
            confirm_license,
            license_basis,
            json,
        } => super::marketplace_author::import(
            env,
            super::marketplace_author::ImportArgs {
                target,
                skills,
                agents,
                hooks,
                commands,
                mcp,
                from_scope,
                origin,
                rename,
                confirm_license,
                license_basis,
                json,
            },
        )?,
        MarketplaceCommand::Submit {
            dir,
            dry_run,
            status,
        } => super::marketplace_author::submit(env, dir, dry_run, status)?,
    }
    Ok(())
}

#[cfg(test)]
mod tests;
