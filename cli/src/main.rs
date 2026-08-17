mod agent;
mod catalog;
mod commands;
mod config;
mod display;
mod extra;
mod frontmatter;
mod ghostty_apply;
mod git_hooks;
mod harness;
mod hook;
mod installer;
mod json_config;
mod mapping;
mod path_safety;
mod pi_extension;
mod project_config;
mod project_settings;
mod refresh_sources;
mod resolve;
mod scope;
mod skill;
#[cfg(test)]
mod test_util;
mod tui;
mod vscode_apply;
mod vsix;

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

    /// Apply an extra package, currently theme packs (dry-run supported)
    Apply {
        /// Extra name discovered from the current vstack source
        extra_name: String,
        /// Theme id to apply (defaults to the extra's default theme)
        #[arg(long)]
        theme: Option<String>,
        /// Comma-separated target subset (default: all detected declared targets)
        #[arg(long)]
        target: Option<String>,
        /// User/global scope; app theme config is user-level by default
        #[arg(long)]
        global: bool,
        /// Print planned changes without writing files
        #[arg(long)]
        dry_run: bool,
        /// Do not install Ghostty custom-shader lines or shader files
        #[arg(long)]
        no_ghostty_shaders: bool,
        /// Skip confirmation prompt before mutations
        #[arg(short, long)]
        yes: bool,
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

    /// Check installation status: outdated, removed upstream, orphaned,
    /// missing, and available-but-not-installed items. Defaults to all
    /// scopes. Exit 0 = clean, 1 = drift found, 2 = check could not run.
    Check {
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// project | global | all (default: all)
        #[arg(long)]
        scope: Option<String>,
        /// Print the report as JSON on stdout.
        #[arg(long)]
        json: bool,
        /// Print nothing when there is no drift; drop the per-item listing.
        #[arg(short, long)]
        quiet: bool,
        /// No network: skip the CLI version lookup and the remote source
        /// cache fetch (which otherwise runs at most once per TTL).
        #[arg(long)]
        offline: bool,
        /// Do not report items available in a source but not installed.
        #[arg(long)]
        no_available: bool,
    },

    /// Plumbing: refresh the remote source caches this scope's locks name,
    /// bounded, and exit. `check` spawns this detached so a session start
    /// never waits on the network; run it by hand only to force the fetch
    /// `check` would have backgrounded.
    #[command(hide = true)]
    CacheRefresh {
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
    /// install scope. Also re-applies vstack.toml customizations to agents and
    /// canonical project-owned skills, even when a skill has no lock entry.
    /// Defaults to all applicable scopes.
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

    /// Scaffold a new agent, skill, or hook template in a vstack source repo.
    /// Run from the repo root; writes to ./agents/, ./skills/, or ./hooks/.
    Init {
        name: Option<String>,
        /// What to scaffold: agent | skill | hook
        #[arg(long)]
        kind: Option<String>,
    },

    /// File a workflow-error issue for an installed asset, routing it to the
    /// correct repo based on ownership: vstack-owned assets go upstream; assets
    /// that are project-local (the safe default) go to THIS repo's issue
    /// tracker. Ownership is resolved from installed provenance frontmatter
    /// (skills/agents that declare it) and the project lock's recorded source —
    /// not guessed; assets without provenance fall back to the lock source, and
    /// anything unproven defaults to local. Non-interactive: use --dry-run to
    /// preview.
    Report {
        /// Report about an installed skill by name.
        #[arg(long)]
        skill: Option<String>,
        /// Report about an installed agent by name.
        #[arg(long)]
        agent: Option<String>,
        /// Report about an installed hook by name.
        #[arg(long)]
        hook: Option<String>,
        /// Report about any installed asset by name (kind auto-detected).
        #[arg(long)]
        asset: Option<String>,
        /// Issue title.
        #[arg(long)]
        title: String,
        /// Issue body text (mutually exclusive with --body-file).
        #[arg(long)]
        body: Option<String>,
        /// Read the issue body from a file (mutually exclusive with --body).
        #[arg(long)]
        body_file: Option<std::path::PathBuf>,
        /// Shortcut for `--scope global`.
        #[arg(short, long)]
        global: bool,
        /// Ownership-resolution scope: project | global (default: project).
        #[arg(long)]
        scope: Option<String>,
        /// Upstream repo for vstack-owned issues (default: vanillagreencom/vstack).
        #[arg(long)]
        upstream: Option<String>,
        /// Surface for the flat routing label on vstack-owned issues:
        /// cli | skills | harness | review-gate | docs | tech-debt. Derived from
        /// the asset selector when omitted.
        #[arg(long)]
        area: Option<String>,
        /// Print the ownership decision, target repo, and exact gh command
        /// without filing anything.
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
        Some(Commands::Apply {
            extra_name,
            theme,
            target,
            global,
            dry_run,
            no_ghostty_shaders,
            yes,
        }) => commands::apply::run(
            extra_name,
            theme,
            target,
            global,
            dry_run,
            yes,
            !no_ghostty_shaders,
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
        Some(Commands::CacheRefresh { scope }) => {
            let scope =
                scope::ScopeFilter::resolve(scope.as_deref(), false, scope::ScopeFilter::All)?;
            for &global in scope.globals() {
                let lock =
                    config::LockFile::load(&config::lock_file_path(global)).unwrap_or_default();
                // The detached refresher, and the ONE caller for which a
                // guard held elsewhere is a success: somebody else is already
                // doing this job.
                config::refresh_remote_caches_older_than(
                    &lock,
                    Some(config::REMOTE_CACHE_TTL),
                    config::FetchBound::BACKGROUND,
                );
            }
            Ok(())
        }
        Some(Commands::Check {
            global,
            scope,
            json,
            quiet,
            offline,
            no_available,
        }) => {
            // Exit codes are the hook contract: 0 clean, 1 drift, 2 the
            // check itself failed. `?` would fold failure into 1.
            let outcome =
                scope::ScopeFilter::resolve(scope.as_deref(), global, scope::ScopeFilter::All)
                    .and_then(|scope| {
                        commands::check::run(
                            scope,
                            commands::check::CheckOptions {
                                json,
                                quiet,
                                offline,
                                no_available,
                            },
                        )
                    });
            match outcome {
                Ok(commands::check::CheckOutcome::Clean) => Ok(()),
                Ok(commands::check::CheckOutcome::Drift) => std::process::exit(1),
                Err(err) => {
                    eprintln!("Error: {err:#}");
                    std::process::exit(2);
                }
            }
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
        Some(Commands::Init { name, kind }) => {
            commands::init::run(name.as_deref(), kind.as_deref())
        }
        Some(Commands::Report {
            skill,
            agent,
            hook,
            asset,
            title,
            body,
            body_file,
            global,
            scope,
            upstream,
            area,
            dry_run,
        }) => commands::report::run(commands::report::ReportArgs {
            skill,
            agent,
            hook,
            asset,
            title,
            body,
            body_file,
            global,
            scope,
            upstream,
            area,
            dry_run,
        }),
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
