//! The flag sets that are shared or long enough to crowd the verb list:
//! `add`, which the bare `kendex <source>` form reuses flag for flag,
//! `report`, and the explicit project target the whole-scope writing verbs
//! share.

use clap::Args;

use crate::commands;
use crate::commands::add::AddArgs;

/// The add flags — shared by `add` and the bare form, flag for flag.
#[derive(Args)]
pub struct AddFlags {
    /// Install to the user-level scope
    #[arg(short = 'g', long)]
    global: bool,
    /// Target harnesses (comma-separated)
    #[arg(long)]
    harness: Vec<String>,
    /// Target every harness kendex can install to at this scope
    #[arg(long, conflicts_with = "harness")]
    all_harnesses: bool,
    /// Install specific agents (comma-separated)
    #[arg(short = 'a', long)]
    agent: Vec<String>,
    /// Install specific skills (comma-separated)
    #[arg(short = 's', long)]
    skill: Vec<String>,
    /// Install whole bundles the marketplace offers (comma-separated)
    #[arg(short = 'b', long)]
    bundle: Vec<String>,
    /// Also take these optional dependencies (comma-separated)
    #[arg(long = "with")]
    optional: Vec<String>,
    /// Install specific hooks (comma-separated)
    #[arg(long)]
    hook: Vec<String>,
    /// Install one response style
    #[arg(long)]
    output_style: Vec<String>,
    /// Install specific commands (comma-separated)
    #[arg(long)]
    command: Vec<String>,
    /// Install specific MCP servers (comma-separated)
    #[arg(long)]
    mcp_server: Vec<String>,
    /// Install specific Pi extensions (comma-separated)
    #[arg(long, visible_alias = "pi-package")]
    pi_extension: Vec<String>,
    /// Copy instead of symlink
    #[arg(long, conflicts_with = "method")]
    copy: bool,
    /// Delivery: symlink (one shared tree) or copy (a tree per harness)
    #[arg(long, value_parser = ["symlink", "copy"])]
    method: Option<String>,
    /// Skip confirmation prompts
    #[arg(short = 'y', long)]
    yes: bool,
    /// Every package the marketplace offers
    #[arg(long)]
    all: bool,
    /// Allow --global --all when your personal setup already has an install record
    #[arg(long)]
    clobber: bool,
    /// Skip auto-install of skills referenced by selected agents
    #[arg(long)]
    no_auto_skills: bool,
    /// Hold what this installs at the resolved version (manual updates)
    #[arg(long)]
    hold: bool,
    /// Say yes to the repository changes a package declares, and, with
    /// --commit, --push or --pull-request, to setting up a package that
    /// holds the commit
    #[arg(long)]
    allow_repo_effects: bool,
    /// Write a project setting a package here declares, as KEY=VALUE; a key kendex.settings.toml already assigns keeps its value
    #[arg(long, value_name = "KEY=VALUE", value_parser = commands::add::parse_setting)]
    setting: Vec<kendex_core::settings_file::SuppliedSetting>,
    #[command(flatten)]
    throwaway: commands::project::ThrowawayFlag,
}

impl AddFlags {
    pub fn into_args(self, source: Option<String>) -> AddArgs {
        AddArgs {
            source,
            global: self.global,
            harness: self.harness,
            agent: self.agent,
            skill: self.skill,
            bundle: self.bundle,
            optional: self.optional,
            hook: self.hook,
            command: self.command,
            output_style: self.output_style,
            mcp_server: self.mcp_server,
            pi_extension: self.pi_extension,
            all_harnesses: self.all_harnesses,
            copy: self.copy,
            method: self.method,
            yes: self.yes,
            all: self.all,
            clobber: self.clobber,
            no_auto_skills: self.no_auto_skills,
            hold: self.hold,
            allow_repo_effects: self.allow_repo_effects,
            setting: self.setting,
            throwaway: self.throwaway,
            subscription: None,
        }
    }
}

#[derive(Args)]
pub struct ReportFlags {
    /// Report about an installed skill
    #[arg(long)]
    skill: Option<String>,
    /// Report about an installed agent
    #[arg(long)]
    agent: Option<String>,
    /// Report about an installed hook
    #[arg(long)]
    hook: Option<String>,
    /// Report about any installed package by name
    #[arg(long)]
    asset: Option<String>,
    /// Issue title
    #[arg(long)]
    title: String,
    /// Issue body text
    #[arg(long)]
    body: Option<String>,
    /// Read the body from a file
    #[arg(long, conflicts_with = "body")]
    body_file: Option<std::path::PathBuf>,
    #[arg(short = 'g', long)]
    global: bool,
    /// Where to read the package: project or global (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Repository for reports about kendex packages
    #[arg(long)]
    upstream: Option<String>,
    /// Routing label: cli | skills | harness | review-gate | docs | tech-debt
    #[arg(long)]
    area: Option<String>,
    /// Preview the destination and submission arguments without filing an issue
    #[arg(long)]
    dry_run: bool,
}

impl ReportFlags {
    pub fn into_args(self) -> commands::report::ReportArgs {
        commands::report::ReportArgs {
            skill: self.skill,
            agent: self.agent,
            hook: self.hook,
            asset: self.asset,
            title: self.title,
            body: self.body,
            body_file: self.body_file,
            global: self.global,
            scope: self.scope,
            upstream: self.upstream,
            area: self.area,
            dry_run: self.dry_run,
        }
    }
}

/// The explicit project a whole-scope run works on, shared by `refresh`,
/// `apply` and `updates` — written by the first two and by
/// `updates --apply`, and read by the `updates` listing.
///
/// Without it those verbs take the project the command was typed in,
/// which is the behaviour every release before this one had. With it the
/// place is in the command's own words — which is what lets a session
/// that cannot move its shell, and one standing in a linked git worktree,
/// name the checkout it means.
///
/// The flag answering the temporary-path refusal rides here beside the
/// path it answers for, because a named run can put that path on the
/// projects list; [`commands::project::register_target`] owns when it
/// does.
#[derive(Args, Clone, Default)]
pub struct ProjectTargetFlag {
    /// The project this run reads and writes, by path, instead of the one it was typed in
    #[arg(long, value_name = "PATH")]
    project_path: Option<std::path::PathBuf>,
    /// Permit project writes in a marked lane whose item is a refresh
    #[arg(long)]
    pub(crate) lane_refresh: bool,
    /// The temporary-path refusal's answer, for the project --project-path names
    #[command(flatten)]
    pub throwaway: commands::project::ThrowawayFlag,
}

impl ProjectTargetFlag {
    /// The project this run was told to write, where it was told one.
    pub fn path(&self) -> Option<&std::path::Path> {
        self.project_path.as_deref()
    }
}
