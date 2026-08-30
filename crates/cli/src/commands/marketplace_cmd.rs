use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::names::shown;
use kendex_core::source_ops;

use super::engine_common::apply_report;
use super::{CliResult, out, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;

#[derive(Subcommand)]
pub enum MarketplaceCommand {
    /// Subscriptions per scope, with package counts once fetched
    List {
        /// Machine-readable rows (schema 1)
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
    },
    /// Unsubscribe from a marketplace, removing or keeping its packages
    Unsubscribe {
        name: String,
        /// Uninstall everything installed from it
        #[arg(long, conflicts_with = "keep_packages")]
        remove_packages: bool,
        /// Keep its packages as your own local forks
        #[arg(long)]
        keep_packages: bool,
        /// With --remove-packages: discard hand edits too, instead of refusing
        #[arg(long)]
        discard_edits: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global (default project)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Packages and curated sets a subscription offers
    Browse {
        /// The subscription to browse (default: every subscription in scope)
        marketplace: Option<String>,
        /// Machine-readable rows (schema 1)
        #[arg(long)]
        json: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Validate a marketplace directory — the alias of
    /// `check --catalog --strict`
    Check {
        /// The marketplace directory (default: the current directory)
        dir: Option<std::path::PathBuf>,
    },
    /// Create a marketplace: a folder with kendex.toml, README, the check
    /// workflow and a licence, initialised as a git repository
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
    /// Register a folder you already have under Mine, read as-is — zero
    /// bytes inside it change
    Use { dir: std::path::PathBuf },
    /// The marketplaces you author, with their local readiness
    Mine {
        /// Machine-readable rows (schema 2)
        #[arg(long)]
        json: bool,
    },
    /// Copy packages from this machine into an authored marketplace. With
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
        /// Confirm the shown licence of a marketplace-origin package
        /// permits republishing
        #[arg(long)]
        confirm_license: bool,
        /// Marketplace-origin with no detectable licence: your stated
        /// basis for copying
        #[arg(long)]
        license_basis: Option<String>,
        /// Machine-readable candidate list (schema 1)
        #[arg(long)]
        json: bool,
    },
    /// Submit an authored marketplace to the kendex.ai community
    /// directory (needs `kendex login`); prints the preflight first
    Submit {
        /// The marketplace directory (default: the current directory)
        dir: Option<std::path::PathBuf>,
        /// Print the preflight and what would be sent, then stop
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
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);

    let manifest = kendex_core::engine::ops::manifest_for_mutation(env, &scope)?;
    let closure = detach::closure(env, &scope, name, &manifest)?;

    // Nothing installed: a plain confirm, whichever flag (or none) was passed.
    if closure.items.is_empty() {
        let report = kendex_core::source_ops::remove_source(env, &scope, name)?;
        apply_report(env, &report)?;
        say(&format!(
            "{}: unsubscribed from '{name}'",
            scope_label(&scope)
        ));
        return Ok(());
    }

    match (remove_packages, keep_packages) {
        (false, false) => {
            return Err(format!(
                "'{name}' has {} package(s) installed — pass --remove-packages to uninstall them or --keep-packages to keep them as your own",
                closure.items.len()
            )
            .into());
        }
        // A bare plan: keeping moves tables, and takes no package away.
        (_, true) => {
            let plan = detach::source(env, &scope, name)?;
            kendex_core::apply::execute(env, &plan, None)?;
        }
        (true, _) => {
            let report = detach::remove(env, &scope, name, discard_edits)?;
            apply_report(env, &report)?;
        }
    }
    if keep_packages {
        // Keeping moved the catalog's mapping tables into the manifest, so
        // the install records are re-synced here — otherwise every kept
        // agent would read as drifted until the next refresh.
        let resync = kendex_core::engine::plan_apply(
            env,
            &scope,
            &kendex_core::engine::PlanOptions::default(),
        )?;
        apply_report(env, &resync)?;
    }
    let kept = if keep_packages { "kept" } else { "removed" };
    say(&format!(
        "{}: unsubscribed from '{name}', {} {kept}",
        scope_label(&scope),
        closure.items.len()
    ));
    Ok(())
}

fn run_list(env: &Env, json: bool, global: bool, scope: Option<String>) -> CliResult {
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
    let mut rows = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        rows.extend(source_ops::list_subscriptions(env, &scope)?);
    }
    if json {
        out(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": 1,
            "subscriptions": rows,
        }))?);
        return Ok(());
    }
    for row in rows {
        let what = row.repo.or(row.path).unwrap_or_default();
        let rev = row.rev.map(|rev| format!(" @ {rev}")).unwrap_or_default();
        let counted = match row.counts {
            Some(counts) => {
                let total: usize = counts.values().sum();
                format!("{total} package(s)")
            }
            None => "not fetched yet".to_owned(),
        };
        let state = if row.enabled { "" } else { "  (disabled)" };
        out(&format!(
            "{}  {}  {what}{rev}  [{counted}]{state}",
            row.scope.label(),
            row.name,
        ));
    }
    Ok(())
}

fn run_subscribe(
    env: &Env,
    reference: &str,
    name: Option<&str>,
    global: bool,
    scope: Option<String>,
) -> CliResult {
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let subscribed = source_ops::subscribe(env, &scope, reference, name)?;
    for note in &subscribed.report.notes {
        say(note);
    }
    apply_report(env, &subscribed.report)?;
    // Subscribing fetches so counts can land; a failure costs the
    // counts, never the subscription.
    if let Ok(Some(manifest)) =
        kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(env, &scope))
        && let Some(decl) = manifest.sources.get(&subscribed.name)
        && let Some(repo) = decl.repo.clone()
        && let Err(error) = kendex_core::remote::sync(env, &repo, decl.rev.as_deref())
    {
        say(&format!(
            "warning: not fetched yet ({})",
            shown(&error.to_string())
        ));
    }
    say(&format!(
        "{}: subscribed to '{}' ({})",
        scope_label(&scope),
        shown(&subscribed.name),
        shown(&subscribed.reference)
    ));
    if let Some(lead) = subscribed.lead {
        say(&format!("package: {}", shown(&lead)));
    }
    Ok(())
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
        } => run_subscribe(env, &reference, name.as_deref(), global, scope)?,
        MarketplaceCommand::Unsubscribe {
            name,
            remove_packages,
            keep_packages,
            discard_edits,
            global,
            scope,
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
