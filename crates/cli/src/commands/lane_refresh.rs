//! Refuse lane writes before first-run recording, prompts or source fetches.
//! The CLI refusal key is `lane-refresh: item=<branch>`; the override flag is
//! `--lane-refresh`. The refusal always occupies one stderr line.

use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::{CliResult, resolve_scopes_at};
use crate::scope::ScopeFilter;
use crate::{Cli, Command};

/// Check the parsed command before any CLI bootstrap writes.
pub(crate) fn check(cli: &Cli) -> CliResult {
    match project_lane(cli) {
        Ok(None) => Ok(()),
        Ok(Some(item)) => Err(format!(
            "lane-refresh: item={item}; project writes belong in the repository rolling refresh pull request; pass --lane-refresh for a refresh lane"
        ).into()),
        Err(error) => Err(format!("lane-refresh: check-failed={error}").into()),
    }
}

fn project_lane(cli: &Cli) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let Some(command) = &cli.command else {
        return Ok(None);
    };
    let (filter, target) = match command {
        Command::Refresh(args) => (args.effective_scope(), &args.target),
        Command::Apply(args) if !args.plan => (args.effective_scope(), &args.target),
        Command::Updates(args) if args.apply => (args.effective_scope(), &args.target),
        // `update` installs kendex itself. Package updates write through
        // `updates --apply`; plans and listings keep their existing paths.
        Command::Apply(_)
        | Command::Updates(_)
        | Command::Add { .. }
        | Command::Diff(_)
        | Command::Show(_)
        | Command::Fork(_)
        | Command::Pin(_)
        | Command::Versions(_)
        | Command::Remove { .. }
        | Command::Enable(_)
        | Command::Disable(_)
        | Command::Verify { .. }
        | Command::Adopt { .. }
        | Command::Project(_)
        | Command::Template(_)
        | Command::Bookmark(_)
        | Command::List { .. }
        | Command::Check(_)
        | Command::DriftHook { .. }
        | Command::Guard(_)
        | Command::GeneratedPaths
        | Command::Report(_)
        | Command::Source(_)
        | Command::Marketplace(_)
        | Command::Trash(_)
        | Command::Login
        | Command::Logout
        | Command::Index { .. }
        | Command::Init { .. }
        | Command::Update { .. }
        | Command::VersionCompare(_)
        | Command::HarnessPaths
        | Command::HooksOff(_)
        | Command::TierModel(_)
        | Command::ReleaseMainBuild(_)
        | Command::UpdatePi { .. } => return Ok(None),
    };
    if target.lane_refresh {
        return Ok(None);
    }
    if matches!(filter, Ok(ScopeFilter::Global)) {
        return Ok(None);
    }
    let env = Env::detect()?;
    let cwd = env
        .cwd()
        .ok_or("cannot locate the command's working directory")?;
    let scopes = resolve_scopes_at(&env, filter?, target.path())?;
    let Some(root) = scopes.iter().find_map(|scope| match scope {
        Scope::Project { root } => Some(root),
        Scope::Global => None,
    }) else {
        return Ok(None);
    };
    // Named targets do not bypass a marked caller. Git clone can put an
    // unmarked checkout inside a lane whose manifest the resolver selects.
    match kendex_core::lane::marked_worktree(cwd)? {
        Some(item) => Ok(Some(item)),
        None => Ok(kendex_core::lane::marked_worktree(root)?),
    }
}
