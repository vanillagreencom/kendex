use clap::Args;

use kendex_core::env::Env;
use kendex_core::package::diff::{FileStatus, LineKind, VersionSel};

use super::pin::parse_kind;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct DiffArgs {
    /// agent | skill | hook | command | mcp-server | pi-extension
    kind: String,
    name: String,
    /// A version (tag, branch, commit) or `installed`
    #[arg(long)]
    from: String,
    /// A version (tag, branch, commit) or `installed` (the default)
    #[arg(long, default_value = "installed")]
    to: String,
    /// Which tool's installed rendering to compare (default claude)
    #[arg(long)]
    harness: Option<String>,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: DiffArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    let harness = match &args.harness {
        Some(value) => Some(
            kendex_core::model::HarnessId::parse(value)
                .ok_or_else(|| format!("unknown harness '{value}'"))?,
        ),
        None => None,
    };
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);
    let side = |selector: &str| -> Result<VersionSel, Box<dyn std::error::Error>> {
        if selector == "installed" {
            return Ok(VersionSel::Installed);
        }
        Ok(VersionSel::Commit(kendex_core::package::resolve_version(
            env, &scope, kind, &args.name, selector,
        )?))
    };
    let from = side(&args.from)?;
    let to = side(&args.to)?;
    let diff = kendex_core::package::diff::package_diff(
        env, &scope, kind, &args.name, &from, &to, harness,
    )?;
    if diff.files.is_empty() {
        say("no changes");
        return Ok(());
    }
    say(&format!(
        "+{} -{}{}",
        diff.total_additions,
        diff.total_deletions,
        if diff.truncated { "  (truncated)" } else { "" }
    ));
    for file in &diff.files {
        let status = match file.status {
            FileStatus::Added => " (added)",
            FileStatus::Removed => " (removed)",
            FileStatus::Modified => "",
            FileStatus::Binary => " (binary)",
            FileStatus::TooLarge => " (too large to show)",
        };
        // The blank line before each heading is said rather than written
        // into the line: a break in a value is a value's break, and only
        // a call is a break of this verb's own.
        say("");
        say(&format!(
            "{}{status}  +{} -{}",
            file.path, file.additions, file.deletions
        ));
        for hunk in &file.hunks {
            say(&hunk.header);
            for line in &hunk.lines {
                let marker = match line.kind {
                    LineKind::Context => ' ',
                    LineKind::Add => '+',
                    LineKind::Remove => '-',
                };
                say(&format!("{marker}{}", line.text));
            }
        }
    }
    Ok(())
}
