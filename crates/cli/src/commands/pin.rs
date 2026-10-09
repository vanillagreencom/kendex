use clap::Args;

use kendex_core::env::Env;
use kendex_core::model::ItemKind;

use super::advisory::Listing;
use super::engine_common::{confirm_and_execute, print_report};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct PinArgs {
    #[arg(help = kind_choices())]
    kind: String,
    name: String,
    /// The version to hold at: a tag, branch, or commit
    version: Option<String>,
    /// Follow the marketplace's own version again
    #[arg(long, conflicts_with = "version")]
    follow: bool,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
    /// Skip confirmation prompts
    #[arg(short = 'y', long)]
    yes: bool,
    /// The commit offer's answer, without asking
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

impl PinArgs {
    pub(crate) fn effective_scope(&self) -> Result<ScopeFilter, String> {
        ScopeFilter::resolve(self.scope.as_deref(), self.global, ScopeFilter::Project)
    }
}

fn canonical_kinds() -> impl Iterator<Item = ItemKind> {
    // Plugins declare through their own table and have no source revisions.
    ItemKind::ALL
        .into_iter()
        .filter(|kind| *kind != ItemKind::Plugin)
}

/// Canonical choices shared by kind help and unknown-kind errors.
pub(super) fn kind_choices() -> String {
    canonical_kinds()
        .map(ItemKind::name)
        .collect::<Vec<_>>()
        .join(" | ")
}

/// The kinds a user can name on the command line, including existing aliases.
pub fn parse_kind(value: &str) -> Result<ItemKind, String> {
    if let Some(kind) = canonical_kinds().find(|kind| kind.name() == value) {
        return Ok(kind);
    }
    match value {
        "agents" | "a" => Ok(ItemKind::Agent),
        "skills" | "s" => Ok(ItemKind::Skill),
        "hooks" => Ok(ItemKind::Hook),
        "commands" => Ok(ItemKind::Command),
        "mcp" => Ok(ItemKind::McpServer),
        "pi" => Ok(ItemKind::PiExtension),
        other => Err(format!("unknown kind '{other}' ({})", kind_choices())),
    }
}

/// [`kind_choices`], plus `plugin`: the help of a `--kind` that
/// [`parse_kind_or_plugin`] reads, and its unknown-kind error.
pub(crate) fn kind_or_plugin_choices() -> String {
    format!("{} | {}", kind_choices(), ItemKind::Plugin.name())
}

/// [`parse_kind`], plus `plugin`: the kinds a verb acting on an installed
/// package by name (enable, disable, remove) narrows to.
pub fn parse_kind_or_plugin(value: &str) -> Result<ItemKind, String> {
    match value {
        "plugin" => Ok(ItemKind::Plugin),
        other => parse_kind(other)
            .map_err(|_| format!("unknown kind '{other}' ({})", kind_or_plugin_choices())),
    }
}

pub fn run(env: &Env, args: PinArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    if args.version.is_none() && !args.follow {
        return Err("name a version to hold at, or pass --follow to stop holding it".into());
    }
    let filter = args.effective_scope()?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    // Scoped to the package named, exactly as the app's hold move is: the
    // scope's other followers stay at the commit they are installed from.
    let report = kendex_core::package::set_rev_with(
        env,
        &scope,
        kind,
        &args.name,
        args.version.as_deref(),
        &kendex_core::engine::PlanOptions::for_package(kind, &args.name),
    )?;
    print_report(env, &report, Listing::Every);
    confirm_and_execute(env, &report, args.yes)?;
    match args.version {
        Some(version) => say(&format!(
            "{} '{}' held at {}",
            kind.name(),
            args.name,
            version
        )),
        None => say(&format!(
            "{} '{}' is no longer held at a version",
            kind.name(),
            args.name
        )),
    }
    Ok(())
}
