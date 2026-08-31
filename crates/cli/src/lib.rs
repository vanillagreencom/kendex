mod commands;
mod dispatch_args;
use dispatch_args::{check, remove};
mod flags;
mod scope;
mod ui;

use std::process::ExitCode;

use clap::{Parser, Subcommand};
use kendex_core::command_update::record_first_run;
use kendex_core::env::Env;
use kendex_core::install_channel::{Host, HostProbe};

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
        /// Take the files away and leave kendex.toml untouched; refresh installs what it declares again
        #[arg(long, conflicts_with_all = ["sweep", "no_sweep"])]
        keep_declaration: bool,
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
    Apply(commands::apply_cmd::ApplyArgs),
    /// Record an observed item into the manifest (content moves to the
    /// local source)
    Adopt {
        /// agent | skill | hook
        kind: String,
        name: String,
        /// The tool whose files to keep; repeat it to keep one item for
        /// several tools in a single pass, which is what a folder they
        /// share needs
        #[arg(long)]
        harness: Vec<String>,
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
    /// Drift status for this machine (exit 0 clean / 1 drift or not yet
    /// evaluated / 2 could not check), or authoring validation over a
    /// catalog directory with --catalog
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
        /// Machine-readable summary (schema 2)
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
    /// Where the first version stands against the second under SemVer
    /// precedence: newer, same, or older
    #[command(name = "version-compare")]
    VersionCompare(commands::version_compare::VersionCompareArgs),
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
    // Ahead of the parse. `--version` and `--help` are answered by clap and
    // never reach dispatch, and they are what a person runs when the app's
    // card has just told them their command is behind — which is exactly
    // the install this record is missing from.
    if let Ok(env) = Env::detect() {
        bootstrap_the_command_record(&env);
    }
    let cli = Cli::parse();
    // The machine check's whole contract is its exit code: 1 means "drift,
    // report on stdout". A failure before the check could run — settings
    // unreadable, scope unresolvable — must exit 2 (could not check), or
    // the session hook reads the empty report as a clean machine.
    let machine_check = matches!(&cli.command, Some(Command::Check { catalog: None, .. }));
    match run(cli) {
        Ok(code) => {
            ui::finish();
            code
        }
        Err(e) => {
            // The last line of the run, and the one that closes the frame
            // a terminal opened: whatever was still being said is drawn
            // above it rather than swallowed by the exit.
            match (machine_check, ui::cancelled(e.as_ref())) {
                // The check's exit code is its whole contract, and a run
                // that ended before it could answer is "could not check"
                // however it ended.
                (true, _) => {
                    ui::outro_refusal(e.as_ref());
                    ExitCode::from(2)
                }
                // 130 is what a shell reports for a run its user killed,
                // and scripts key on it. A plain prompt lets SIGINT do
                // that itself; the framed one traps Ctrl-C in raw mode and
                // hands back an interrupted read instead, so the code has
                // to be restored here or the framing would have quietly
                // turned every cancel into an ordinary failure.
                (false, true) => {
                    ui::outro_fail("cancelled");
                    ExitCode::from(130)
                }
                (false, false) => {
                    ui::outro_refusal(e.as_ref());
                    ExitCode::FAILURE
                }
            }
        }
    }
}

/// Tell the desktop app which file the `kendex` command is, once, from
/// whichever verb a person happens to run first.
///
/// An install made before this record existed has none, so the app finds a
/// command it cannot prove is kendex's, updates alone, and never gains a
/// record of its own — the app writes one only where it already had one to
/// match. Any run of this binary settles it, because the path a process is
/// running from is the one thing no search by name can establish.
///
/// Run before the arguments are parsed, because clap answers `--version`
/// and `--help` itself and exits without reaching dispatch. Those are the
/// two a person reaches for when the app's card says their command is
/// behind, so a bootstrap that skipped them would miss the run most likely
/// to be the first one.
///
/// Nothing is said when it fails. This is opportunistic and every run pays
/// for it; the command that needs the record is `kendex update`, and that
/// one records the binary itself and reports when it cannot.
fn bootstrap_the_command_record(env: &Env) {
    let Ok(running) = std::env::current_exe() else {
        return;
    };
    let _ = record_first_run(env, &Host.resolve(&running));
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
        Command::Pin(args) => commands::pin::run(&env, args)?,
        Command::Versions(args) => commands::versions::run(&env, args)?,
        Command::Updates(args) => commands::updates_cmd::run(&env, args)?,
        Command::Remove {
            names,
            global,
            scope,
            sweep,
            no_sweep,
            keep_declaration,
        } => remove(
            &env,
            names,
            global,
            scope,
            sweep,
            no_sweep,
            keep_declaration,
        )?,
        Command::Refresh(args) => commands::refresh::run_args(&env, args)?,
        Command::Verify {
            names,
            global,
            scope,
        } => {
            let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
            return commands::verify::run(&env, names, filter);
        }
        Command::Apply(args) => commands::apply_cmd::run(&env, args)?,
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
        Command::Guard(guard_command) => return commands::guard_cmd::run(guard_command),
        Command::Report(flags) => commands::report::run(&env, flags.into_args())?,
        Command::Source(source_command) => {
            let filter = ScopeFilter::resolve(None, false, ScopeFilter::Project)?;
            commands::source_cmd::run(&env, source_command, filter)?;
        }
        Command::Marketplace(command) => commands::marketplace_cmd::run(&env, command)?,
        Command::Index { dir, json } => commands::index_cmd::run(dir, json)?,
        Command::Init { name, kind } => commands::init::run(name, kind)?,
        Command::Update { force } => commands::update::run(&env, force)?,
        Command::VersionCompare(args) => commands::version_compare::run(args)?,
    }
    Ok(ExitCode::SUCCESS)
}
