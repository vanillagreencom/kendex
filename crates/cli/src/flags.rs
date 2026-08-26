//! The two flag sets that are shared or long enough to crowd the verb
//! list: `add`, which the bare `kendex <source>` form reuses flag for
//! flag, and `report`.

use clap::Args;

use crate::commands;
use crate::commands::add::AddArgs;

/// The v1 add surface — shared by `add` and the bare form, flag for flag.
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
    /// Install whole bundles the source offers (comma-separated)
    #[arg(short = 'b', long)]
    bundle: Vec<String>,
    /// Also take these optional dependencies (comma-separated)
    #[arg(long = "with")]
    optional: Vec<String>,
    /// Install specific hooks (comma-separated)
    #[arg(long)]
    hook: Vec<String>,
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
    /// All items to all harnesses
    #[arg(long)]
    all: bool,
    /// Allow --global --all over a non-empty global lock
    #[arg(long)]
    clobber: bool,
    /// Skip auto-install of skills referenced by selected agents
    #[arg(long)]
    no_auto_skills: bool,
    /// Hold what this installs at today's version (manual updates)
    #[arg(long)]
    hold: bool,
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
    /// Any installed asset by name, kind auto-detected
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
    /// project | global (default project; all rejected)
    #[arg(long)]
    scope: Option<String>,
    /// Upstream repo for kendex-owned issues
    #[arg(long)]
    upstream: Option<String>,
    /// Routing label: cli | skills | harness | review-gate | docs | tech-debt
    #[arg(long)]
    area: Option<String>,
    /// Print the decision and exact gh command; file nothing
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
