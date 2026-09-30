//! Refuse lane writes before first-run recording, prompts or source fetches.
//! The CLI refusal key is `lane-refresh: item=<branch>`; the override flag is
//! `--lane-refresh`. The refusal always occupies one stderr line.

use clap::ArgMatches;
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::{CliResult, resolve_scopes_at};
use crate::scope::ScopeFilter;

/// Check clap's resolved verb and flags before any CLI bootstrap writes.
pub(crate) fn check(matches: &ArgMatches) -> CliResult {
    match project_lane(matches) {
        Ok(None) => Ok(()),
        Ok(Some(item)) => Err(format!(
            "lane-refresh: item={item}; project writes belong in the repository rolling refresh pull request; pass --lane-refresh for a refresh lane"
        ).into()),
        Err(error) => Err(format!("lane-refresh: check-failed={error}").into()),
    }
}

fn project_lane(matches: &ArgMatches) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let Some((verb, args)) = matches.subcommand() else {
        return Ok(None);
    };
    // These names and argument IDs come from the CLI's clap declarations.
    // `update` installs kendex itself, not a project; package updates write
    // through `updates --apply`. A plan or listing keeps its existing path.
    let default = match verb {
        "refresh" => ScopeFilter::All,
        "apply" if !args.get_flag("plan") => ScopeFilter::Project,
        "updates" if args.get_flag("apply") => ScopeFilter::Project,
        _ => return Ok(None),
    };
    if args.get_flag("lane_refresh") {
        return Ok(None);
    }
    let filter = ScopeFilter::resolve(
        args.get_one::<String>("scope").map(String::as_str),
        args.get_flag("global"),
        default,
    );
    if matches!(filter, Ok(ScopeFilter::Global)) {
        return Ok(None);
    }
    let env = Env::detect()?;
    let cwd = env
        .cwd()
        .ok_or("cannot locate the command's working directory")?;
    let Some(item) = kendex_core::lane::marked_worktree(cwd)? else {
        return Ok(None);
    };
    let scopes = resolve_scopes_at(
        &env,
        filter?,
        args.get_one::<std::path::PathBuf>("project_path")
            .map(std::path::PathBuf::as_path),
    )?;
    if !scopes
        .iter()
        .any(|scope| matches!(scope, Scope::Project { .. }))
    {
        return Ok(None);
    }
    Ok(Some(item))
}
