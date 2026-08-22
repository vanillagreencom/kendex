mod commands;
mod dispatch_args;
use dispatch_args::{check, remove};
mod flags;
mod scope;

use std::io::Write;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use kendex_core::env::Env;

use commands::project::ProjectCommand;
use flags::{AddFlags, ReportFlags};
use scope::ScopeFilter;

#[derive(Parser)]
#[command(
    name = "kendex",
    version,
    about = "Skills, agents, hooks. Cross-harness."
)]
struct Cli {
    /// Bare form: `kendex <source> [flags]` maps to `add`.
    source: Option<String>,
    #[command(flatten)]
    add_flags: AddFlags,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Install agents, skills, and more from a source
    Add {
        /// GitHub `owner/repo` or local path
        source: Option<String>,
        #[command(flatten)]
        flags: AddFlags,
    },
    /// What changed between two versions of a package
    Diff(commands::diff_cmd::DiffArgs),
    /// A package's files, one file, its readme, or its provenance
    Show(commands::show::ShowArgs),
    /// Keep an edited install as your own local package
    Fork(commands::fork_cmd::ForkArgs),
    /// Put one package's declared content back over the edits made to its
    /// installed files — one package, never the whole scope
    #[command(name = "discard-edits")]
    DiscardEdits(commands::discard_cmd::DiscardArgs),
    /// Hold an item at a version, or let it follow its source again
    Pin(commands::pin::PinArgs),
    /// The versions a package's source offers
    Versions(commands::versions::VersionsArgs),
    /// Which packages have newer versions, and per-package notification
    Updates(commands::updates_cmd::UpdatesArgs),
    /// Remove installed items
    Remove {
        names: Vec<String>,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default project)
        #[arg(long)]
        scope: Option<String>,
        /// Also remove what nothing needs anymore
        #[arg(long)]
        sweep: bool,
        /// Keep what nothing needs anymore
        #[arg(long, conflicts_with = "sweep")]
        no_sweep: bool,
    },
    /// Regenerate every declared installation from its source
    Refresh(commands::refresh::RefreshArgs),
    /// Check installs against the lock; non-zero exit on drift
    Verify {
        names: Vec<String>,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Make disk match declaration, orphan cleanup included
    Apply {
        /// Print the plan and change nothing
        #[arg(long)]
        plan: bool,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default project)
        #[arg(long)]
        scope: Option<String>,
        #[arg(short = 'y', long)]
        yes: bool,
        /// Install an item despite its safety findings, as `name@hash` using
        /// the hash printed beside them — a bare name does not grant
        #[arg(long = "allow-unsafe")]
        allow_unsafe: Vec<String>,
        /// Overwrite installations you edited by hand
        #[arg(long)]
        discard_edits: bool,
    },
    /// What the safety check found in installed content, with the token
    /// each finding is dismissed by
    Findings(commands::findings::FindingsArgs),
    /// Record that a finding is not a problem, by its token
    Dismiss(commands::decisions_cmd::DismissArgs),
    /// Every recorded safety decision — acceptances and dismissals — and
    /// whether each still applies; take one back with --revoke
    Decisions(commands::decisions_cmd::DecisionsArgs),
    /// Record an observed item into the manifest (content moves to the
    /// local source)
    Adopt {
        /// agent | skill
        kind: String,
        name: String,
        #[arg(long)]
        harness: Option<String>,
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global (default project)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Register, list, and discover kendex-enabled projects
    #[command(subcommand)]
    Project(ProjectCommand),
    /// List everything observed on this machine
    #[command(alias = "ls")]
    List {
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
        /// Filter by harness id
        #[arg(long)]
        harness: Option<String>,
    },
    /// Drift status for this machine (exit 0 clean / 1 drift / 2 could not
    /// check), or authoring validation over a catalog directory with
    /// --catalog
    Check {
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
        /// Machine-readable report
        #[arg(long)]
        json: bool,
        /// Bounded plain-text report, silent when clean (the session hook)
        #[arg(short = 'q', long)]
        quiet: bool,
        /// Validate this catalog directory instead of this machine
        #[arg(long)]
        catalog: Option<std::path::PathBuf>,
        /// With --catalog, also fail on advisories
        #[arg(long)]
        strict: bool,
    },
    /// Install the session-start drift report hook for a scope
    #[command(name = "drift-hook")]
    DriftHook {
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global (default project)
        #[arg(long)]
        scope: Option<String>,
        /// Skip confirmation prompts
        #[arg(short = 'y', long)]
        yes: bool,
    },
    /// Commit-time quality guards and the git hooks that run them
    #[command(subcommand)]
    Guard(commands::guard_cmd::GuardCommand),
    /// File an issue about an installed asset, routed by ownership
    Report(ReportFlags),
    /// Migrate v1 manifests and locks to v2 (originals go to the trash)
    Import {
        #[arg(short = 'g', long)]
        global: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
    /// Declare, toggle, and refresh sources
    #[command(subcommand)]
    Source(commands::source_cmd::SourceCommand),
    /// Subscribe to marketplaces and list subscriptions
    #[command(subcommand)]
    Marketplace(commands::marketplace_cmd::MarketplaceCommand),
    /// Sign in to kendex.ai (a code, a browser tab, done)
    Login,
    /// Sign out and revoke this machine's kendex.ai credential
    Logout,
    /// Emit the summary of a marketplace directory the community directory
    /// consumes (default: the current directory)
    Index {
        dir: Option<std::path::PathBuf>,
        /// Machine-readable summary (schema 1)
        #[arg(long)]
        json: bool,
    },
    /// Scaffold a new catalog item in the current directory
    Init {
        name: Option<String>,
        /// agent | skill | hook
        #[arg(long)]
        kind: Option<String>,
    },
    /// Self-update from the release feed
    Update {
        /// Reinstall even when the version matches
        #[arg(short = 'f', long)]
        force: bool,
    },
    /// Update Pi extension packages
    #[command(name = "update-pi")]
    UpdatePi {
        /// Print the plan and change nothing
        #[arg(short = 'c', long)]
        check: bool,
        /// project | global | all (default all)
        #[arg(long)]
        scope: Option<String>,
    },
}

/// Sanity for this machine, or for a catalog directory. They answer
/// different questions — what is installed here, versus what this content
/// would do anywhere — and only the second one belongs in a repository's CI.
#[allow(clippy::too_many_arguments)]
pub fn main() -> ExitCode {
    let cli = Cli::parse();
    // The machine check's whole contract is its exit code: 1 means "drift,
    // report on stdout". A failure before the check could run — settings
    // unreadable, scope unresolvable — must exit 2 (could not check), or
    // the session hook reads the empty report as a clean machine.
    let machine_check = matches!(&cli.command, Some(Command::Check { catalog: None, .. }));
    match run(cli) {
        Ok(code) => code,
        Err(e) => {
            let _ = writeln!(std::io::stderr(), "Error: {e}");
            match machine_check {
                true => ExitCode::from(2),
                false => ExitCode::FAILURE,
            }
        }
    }
}

/// Before any command reads the new-name dirs: running against absent
/// dirs while the old ones still hold the state would fork it in two, so
/// a failed move stops the command here. What could not move is said out
/// loud instead of sitting silently forever.
fn move_global_dirs(env: &Env) -> Result<(), Box<dyn std::error::Error>> {
    let moved = kendex_core::rename::migrate_global_dirs(env)?;
    for line in &moved.leftovers {
        let _ = writeln!(std::io::stderr(), "{line}");
    }
    Ok(())
}

/// The bare form: `kendex <source> [flags]` maps to `add`.
fn bare_add(
    env: &Env,
    source: Option<String>,
    flags: AddFlags,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    if source.is_none() {
        return Err("nothing to do — pass a source to add, or a subcommand".into());
    }
    commands::add::run(env, flags.into_args(source))?;
    Ok(ExitCode::SUCCESS)
}

fn run(cli: Cli) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let env = Env::detect()?;
    move_global_dirs(&env)?;
    let Some(command) = cli.command else {
        return bare_add(&env, cli.source, cli.add_flags);
    };
    match command {
        Command::Add { source, flags } => commands::add::run(&env, flags.into_args(source))?,
        Command::Login => commands::login::login()?,
        Command::Logout => commands::login::logout()?,
        Command::Diff(args) => commands::diff_cmd::run(&env, args)?,
        Command::Show(args) => commands::show::run(&env, args)?,
        Command::Fork(args) => commands::fork_cmd::run(&env, args)?,
        Command::DiscardEdits(args) => commands::discard_cmd::run(&env, args)?,
        Command::Pin(args) => commands::pin::run(&env, args)?,
        Command::Versions(args) => commands::versions::run(&env, args)?,
        Command::Updates(args) => commands::updates_cmd::run(&env, args)?,
        Command::Remove {
            names,
            global,
            scope,
            sweep,
            no_sweep,
        } => remove(&env, names, global, scope, sweep, no_sweep)?,
        Command::Refresh(args) => commands::refresh::run_args(&env, args)?,
        Command::Verify {
            names,
            global,
            scope,
        } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            return commands::verify::run(&env, names, filter);
        }
        Command::Apply {
            plan,
            global,
            scope,
            yes,
            allow_unsafe,
            discard_edits,
        } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
            commands::apply_cmd::run(&env, filter, plan, yes, allow_unsafe, discard_edits)?;
        }
        Command::Findings(args) => commands::findings::findings(&env, args)?,
        Command::Dismiss(args) => commands::decisions_cmd::dismiss_cmd(&env, args)?,
        Command::Decisions(args) => commands::decisions_cmd::decisions(&env, args)?,
        Command::Adopt {
            kind,
            name,
            harness,
            global,
            scope,
        } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
            commands::adopt::run(&env, kind, name, harness, filter)?;
        }
        Command::Project(cmd) => commands::project::run(&env, cmd)?,
        Command::List {
            global,
            scope,
            harness,
        } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            commands::list::run(&env, filter, harness)?;
        }
        Command::Check {
            global,
            scope,
            json,
            quiet,
            catalog,
            strict,
        } => return check(&env, global, scope, json, quiet, catalog, strict),
        Command::DriftHook { global, scope, yes } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::Project)?;
            commands::drift_hook::run(&env, filter, yes)?;
        }
        Command::UpdatePi { check, scope } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), false, ScopeFilter::All)?;
            commands::update_pi::run(&env, filter, check)?;
        }
        Command::Guard(guard_command) => return commands::guard_cmd::run(&env, guard_command),
        Command::Report(flags) => commands::report::run(&env, flags.into_args())?,
        Command::Import { global, scope } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            commands::import::run(&env, filter)?;
        }
        Command::Source(source_command) => {
            let filter = ScopeFilter::resolve(None, false, ScopeFilter::Project)?;
            commands::source_cmd::run(&env, source_command, filter)?;
        }
        Command::Marketplace(command) => commands::marketplace_cmd::run(&env, command)?,
        Command::Index { dir, json } => commands::index_cmd::run(dir, json)?,
        Command::Init { name, kind } => commands::init::run(name, kind)?,
        Command::Update { force } => commands::update::run(force)?,
    }
    Ok(ExitCode::SUCCESS)
}
