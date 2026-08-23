use clap::Args;

use kendex_core::env::Env;
use kendex_core::model::ItemKind;

use super::engine_common::{confirm_and_execute, print_report};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct PinArgs {
    /// agent | skill | hook | command | mcp-server | pi-extension
    kind: String,
    name: String,
    /// The version to hold at: a tag, branch, or commit
    version: Option<String>,
    /// Follow the source's own revision again
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
}

/// The kinds a user can name on the command line. Plugins declare through
/// their own table and have no source revisions to hold.
pub fn parse_kind(value: &str) -> Result<ItemKind, String> {
    match value {
        "agent" | "agents" | "a" => Ok(ItemKind::Agent),
        "skill" | "skills" | "s" => Ok(ItemKind::Skill),
        "hook" | "hooks" => Ok(ItemKind::Hook),
        "command" | "commands" => Ok(ItemKind::Command),
        "mcp-server" | "mcp" => Ok(ItemKind::McpServer),
        "pi-extension" | "pi" => Ok(ItemKind::PiExtension),
        other => Err(format!(
            "unknown kind '{other}' (agent | skill | hook | command | mcp-server | pi-extension)"
        )),
    }
}

pub fn run(env: &Env, args: PinArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    if args.version.is_none() && !args.follow {
        return Err("name a version to hold at, or pass --follow to track the source".into());
    }
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let report =
        kendex_core::package::set_rev(env, &scope, kind, &args.name, args.version.as_deref())?;
    print_report(env, &report);
    confirm_and_execute(env, &report, args.yes)?;
    match args.version {
        Some(version) => say(&format!(
            "{} '{}' held at {version}",
            kind.name(),
            args.name
        )),
        None => say(&format!(
            "{} '{}' follows its source again",
            kind.name(),
            args.name
        )),
    }
    Ok(())
}
