#![allow(dead_code)]

mod agent;
mod commands;
mod config;
mod extra;
mod frontmatter;
mod harness;
mod hook;
mod installer;
mod mapping;
mod pi_extension;
mod project_config;
mod resolve;
mod scope;
mod skill;
#[cfg(test)]
mod test_util;
mod tui;

use anyhow::Result;
use clap::{Parser, Subcommand};

const REPO: &str = "vanillagreencom/vstack";
const GIT_HASH: &str = env!("VSTACK_GIT_HASH");

fn const_format() -> &'static str {
    use std::sync::OnceLock;
    static VERSION: OnceLock<String> = OnceLock::new();
    VERSION.get_or_init(|| format!("{} ({})", env!("CARGO_PKG_VERSION"), GIT_HASH))
}

#[derive(Parser)]
#[command(
    name = "vstack",
    version = const_format(),
    about = "Skills, agents, hooks. Cross-harness."
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    // Top-level flags that map to `add` when no subcommand given
    /// Source: GitHub repo (owner/repo) or local path
    source: Option<String>,

    /// Install to user-level directory instead of project
    #[arg(short, long)]
    global: bool,

    /// Target specific harnesses (comma-separated): claude,cursor,opencode,codex,pi
    #[arg(long, value_delimiter = ',')]
    harness: Option<Vec<String>>,

    /// Install specific agents by name (comma-separated)
    #[arg(short, long, value_delimiter = ',')]
    agent: Option<Vec<String>>,

    /// Install specific skills by name (comma-separated)
    #[arg(short, long, value_delimiter = ',')]
    skill: Option<Vec<String>>,

    /// Install specific hooks by name (comma-separated)
    #[arg(long, value_delimiter = ',')]
    hook: Option<Vec<String>>,

    /// Install specific Pi extensions by name (comma-separated)
    #[arg(long, value_delimiter = ',', visible_alias = "pi-package")]
    pi_extension: Option<Vec<String>>,

    /// Copy files instead of symlinking
    #[arg(long)]
    copy: bool,

    /// Skip confirmation prompts
    #[arg(short, long)]
    yes: bool,

    /// Install all items to all harnesses
    #[arg(long)]
    all: bool,

    /// Allow `--global --all` to clobber an existing non-empty global lock.
    /// Without this, vstack refuses to dump the entire source catalog over
    /// an existing global install, which is almost always a mistake (use
    /// `vstack refresh -g` to re-sync, or filter with --pi-extension/--skill
    /// /etc. to install one item).
    #[arg(long)]
    clobber: bool,

    /// Skip auto-installation of skills referenced by selected agents.
    /// By default `vstack add` walks each selected agent's `agent-skills`
    /// plus `role-skills` plus transitive dependencies and includes any
    /// missing skills in the install pass so `.agents/skills/<name>/` is
    /// never empty of skills the agent's frontmatter references.
    #[arg(long)]
    no_auto_skills: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Install agents, skills, hooks, and Pi packages from a vstack source
    Add {
        source: Option<String>,
        #[arg(short, long)]
        global: bool,
        /// Target specific harnesses (comma-separated): claude,cursor,opencode,codex,pi
        #[arg(long, value_delimiter = ',')]
        harness: Option<Vec<String>>,
        /// Install specific agents by name (comma-separated)
        #[arg(short, long, value_delimiter = ',')]
        agent: Option<Vec<String>>,
        /// Install specific skills by name (comma-separated)
        #[arg(short, long, value_delimiter = ',')]
        skill: Option<Vec<String>>,
        /// Install specific hooks by name (comma-separated)
        #[arg(long, value_delimiter = ',')]
        hook: Option<Vec<String>>,
        /// Install specific Pi extensions by name (comma-separated)
        #[arg(long, value_delimiter = ',', visible_alias = "pi-package")]
        pi_extension: Option<Vec<String>>,
        #[arg(long)]
        copy: bool,
        #[arg(short, long)]
        yes: bool,
        #[arg(long)]
        all: bool,
        /// Allow `--global --all` to clobber an existing non-empty global lock.
        #[arg(long)]
        clobber: bool,
        /// Skip auto-installation of skills referenced by selected agents.
        #[arg(long)]
        no_auto_skills: bool,
    },

    /// Remove installed agents, skills, hooks, or Pi packages
    Remove {
        names: Vec<String>,
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: project)
        #[arg(long)]
        scope: Option<String>,
    },

    /// List installed agents, skills, hooks, and Pi packages.
    /// Defaults to all scopes.
    #[command(alias = "ls")]
    List {
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: all)
        #[arg(long)]
        scope: Option<String>,
        /// Filter listing by harness id (claude, cursor, opencode, codex, pi)
        #[arg(long)]
        harness: Option<String>,
    },

    /// Check installation status (outdated, orphaned, missing).
    /// Defaults to all scopes.
    Check {
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: all)
        #[arg(long)]
        scope: Option<String>,
    },

    /// Self-update the vstack CLI binary from GitHub releases. Does NOT
    /// update installed packages — use `vstack refresh` for local source
    /// edits or `vstack update-pi` for Pi package version bumps.
    Update {
        /// Force reinstall even if version matches
        #[arg(short, long)]
        force: bool,
    },

    /// Reinstall all locked items (agents, skills, hooks, Pi packages) from
    /// current source. Use after editing source files to push changes to the
    /// install scope. Also re-applies vstack.toml customizations to agents.
    /// Defaults to all scopes that have a lock file.
    Refresh {
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: all)
        #[arg(long)]
        scope: Option<String>,
        /// Print per-item hash old→new and changed/unchanged status.
        #[arg(short, long)]
        verbose: bool,
    },

    /// Verify the live install matches its source on disk: confirms the
    /// lock hash still matches the source, and (for Pi packages) that the
    /// installed package directory bytes match the source directory bytes.
    /// Use after `refresh` to confirm changes propagated, or before
    /// declaring an extension change "done".
    Verify {
        /// Optional names to filter (default: all installed items).
        names: Vec<String>,
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: all)
        #[arg(long)]
        scope: Option<String>,
    },

    /// Update installed Pi extensions from their source repos and npm.
    /// Walks the per-scope source index plus settings.json npm: entries,
    /// reports stale packages, and (without --check) reinstalls them.
    UpdatePi {
        /// Show plan only; do not modify anything.
        #[arg(short, long)]
        check: bool,
        /// Restrict to one scope: all (default), global, project.
        #[arg(long)]
        scope: Option<String>,
    },

    /// Flightdeck maintenance helpers.
    Flightdeck {
        #[command(subcommand)]
        command: FlightdeckCommands,
    },

    /// Scaffold a new agent, skill, or hook template in a vstack source repo.
    /// Run from the repo root; writes to ./agents/, ./skills/, or ./hooks/.
    Init {
        name: Option<String>,
        /// What to scaffold: agent | skill | hook
        #[arg(long)]
        kind: Option<String>,
    },
}

#[derive(Subcommand)]
enum FlightdeckCommands {
    /// Safely tighten legacy run-store permissions after the vstack#227 upgrade.
    MigratePermissions {
        /// Which run store to migrate: user, project (FLIGHTDECK_RUN_STORE_ROOT), or all.
        #[arg(long, value_enum, default_value_t = commands::flightdeck::PermissionScope::All)]
        scope: commands::flightdeck::PermissionScope,
        /// Print planned chmod operations without changing files.
        #[arg(long)]
        dry_run: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Add {
            source,
            global,
            harness,
            agent,
            skill,
            hook,
            pi_extension,
            copy,
            yes,
            all,
            clobber,
            no_auto_skills,
        }) => commands::add::run(
            source,
            global,
            harness,
            agent,
            skill,
            hook,
            pi_extension,
            copy,
            yes,
            all,
            clobber,
            no_auto_skills,
        ),
        Some(Commands::Remove {
            names,
            global,
            scope,
        }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::Project)?;
            commands::remove::run(&names, scope)
        }
        Some(Commands::List {
            global,
            scope,
            harness,
        }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::All)?;
            commands::list::run(scope, harness.as_deref())
        }
        Some(Commands::Check { global, scope }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::All)?;
            commands::check::run(scope)
        }
        Some(Commands::Update { force }) => commands::update::run(force),
        Some(Commands::Refresh {
            global,
            scope,
            verbose,
        }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::All)?;
            commands::refresh::run(scope, verbose)
        }
        Some(Commands::Verify {
            names,
            global,
            scope,
        }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::All)?;
            commands::verify::run(scope, &names)
        }
        Some(Commands::UpdatePi { check, scope }) => commands::update_pi::run(check, scope),
        Some(Commands::Flightdeck { command }) => match command {
            FlightdeckCommands::MigratePermissions { scope, dry_run } => {
                commands::flightdeck::migrate_permissions(scope, dry_run)
            }
        },
        Some(Commands::Init { name, kind }) => {
            commands::init::run(name.as_deref(), kind.as_deref())
        }
        // No subcommand → default to add
        None => commands::add::run(
            cli.source,
            cli.global,
            cli.harness,
            cli.agent,
            cli.skill,
            cli.hook,
            cli.pi_extension,
            cli.copy,
            cli.yes,
            cli.all,
            cli.clobber,
            cli.no_auto_skills,
        ),
    }
}
