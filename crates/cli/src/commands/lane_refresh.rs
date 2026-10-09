//! Refuse project writes before first-run recording, prompts or fetches.

use kendex_core::env::Env;
use kendex_core::guard::Repo;
use kendex_core::model::Scope;

use super::marketplace_cmd::MarketplaceCommand;
use super::{CliResult, install_destination, resolve_scopes, resolve_scopes_at};
use crate::flags::ProjectTargetFlag;
use crate::scope::ScopeFilter;
use crate::{Cli, Command};

/// `block-worktree-refresh` parses this fixed response before an advisory.
/// It requires the parsed project-write check even when its catalog updated first.
pub(crate) const CAPABILITY: &str = "{\"worktree_project_write_guard\":1}";

/// Check the parsed command before any CLI bootstrap writes.
pub(crate) fn check(cli: &Cli) -> CliResult {
    match check_project_writes(cli) {
        Ok(None) => Ok(()),
        Ok(Some(refusal)) => Err(refusal.into()),
        Err(error) => Err(format!("lane-refresh: check-failed={error}").into()),
    }
}

fn check_project_writes(cli: &Cli) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let env = Env::detect()?;
    check_project_writes_in(cli, &env)
}

fn check_project_writes_in(
    cli: &Cli,
    env: &Env,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let WritingScopes {
        scopes,
        lane_target,
    } = writing_scopes(cli, env)?;
    // The explicit refresh-lane override applies to both project-write
    // restrictions on the three whole-scope commands that accept it.
    if lane_target.is_some_and(|target| target.lane_refresh) {
        return Ok(None);
    }
    let projects: Vec<_> = scopes
        .iter()
        .filter_map(|scope| match scope {
            Scope::Project { root } => Some(root),
            Scope::Global => None,
        })
        .collect();
    if projects.is_empty() {
        return Ok(None);
    }
    let cwd = env
        .cwd()
        .ok_or("cannot locate the command's working directory")?;
    let cwd = kendex_core::paths::canonical(cwd)?;
    let caller = Repo::enclosing_linked(&cwd)?;
    // Preserve the separate refresh-lane rule, including a clone enclosed
    // by a marked lane and named targets outside that lane.
    let marker = |repo: Option<&Repo>| match repo {
        Some(repo) => kendex_core::lane::marked_repo(repo),
        None => Ok(None),
    };
    let lane_refusal = |item| {
        Some(format!(
            "lane-refresh: item={item}; project writes belong in the repository rolling refresh pull request; pass --lane-refresh for a refresh lane"
        ))
    };
    if lane_target.is_some()
        && let Some(item) = marker(caller.as_ref())?
    {
        return Ok(lane_refusal(item));
    }
    if lane_target.is_none() && caller.is_none() {
        return Ok(None);
    }
    // Retain enclosure answers only for this invocation. Canonical folder
    // identity, rather than a shared repository identity, permits reuse.
    let mut destinations = Vec::new();
    let mut resolved = Vec::new();
    for root in &projects {
        let physical = kendex_core::paths::canonical(root)?;
        let index = if physical == cwd {
            None
        } else if let Some(index) = destinations.iter().position(|(path, _)| path == &physical) {
            Some(index)
        } else {
            let destination = Repo::enclosing_linked(&physical)?;
            if lane_target.is_some()
                && let Some(item) = marker(destination.as_ref())?
            {
                return Ok(lane_refusal(item));
            }
            let index = destinations.len();
            destinations.push((physical, destination));
            Some(index)
        };
        resolved.push((root, index));
    }
    if let Some(caller) = caller {
        for (root, index) in resolved {
            let destination = match index {
                None => Some(&caller),
                Some(index) => destinations[index].1.as_ref(),
            };
            if destination.map(|repo| &repo.worktree) != Some(&caller.worktree) {
                return Ok(Some(format!(
                    "worktree-project-write: target={}; caller={}; run from the target checkout for this project write",
                    root.display(),
                    caller.worktree.display()
                )));
            }
        }
    }
    Ok(None)
}

struct WritingScopes<'a> {
    scopes: Vec<Scope>,
    lane_target: Option<&'a ProjectTargetFlag>,
}

// Resolve through each verb's real destination rule. Verbs that remove(0)
// write only their first resolved scope; preview and source-fetch paths
// do not write project customizations.
#[allow(
    clippy::too_many_lines,
    reason = "the exhaustive parsed-command destination match stays in one place"
)]
fn writing_scopes<'a>(
    cli: &'a Cli,
    env: &Env,
) -> Result<WritingScopes<'a>, Box<dyn std::error::Error>> {
    let Some(command) = &cli.command else {
        return match &cli.source {
            Some(_) => Ok(WritingScopes {
                scopes: add_scope(env, cli.add_flags.is_global())?,
                lane_target: None,
            }),
            None => Ok(WritingScopes {
                scopes: Vec::new(),
                lane_target: None,
            }),
        };
    };
    let (scopes, target) = match command {
        Command::Refresh(args) => (
            resolve_scopes_at(env, args.effective_scope()?, args.target.path())?,
            Some(&args.target),
        ),
        Command::Apply(args) if !args.plan => (
            resolve_scopes_at(env, args.effective_scope()?, args.target.path())?,
            Some(&args.target),
        ),
        Command::Updates(args) if args.apply => (
            resolve_scopes_at(env, args.effective_scope()?, args.target.path())?,
            Some(&args.target),
        ),
        Command::Add { flags, .. } => (add_scope(env, flags.is_global())?, None),
        Command::Remove { global, scope, .. } | Command::DriftHook { global, scope, .. } => (
            resolve_scopes(
                env,
                ScopeFilter::resolve(scope.as_deref(), *global, ScopeFilter::Project)?,
            )?,
            None,
        ),
        Command::Adopt { global, scope, .. } => (
            first_scope(
                env,
                ScopeFilter::resolve(scope.as_deref(), *global, ScopeFilter::Project)?,
            )?,
            None,
        ),
        Command::Pin(args) => (first_scope(env, args.effective_scope()?)?, None),
        Command::Fork(args) => (first_scope(env, args.effective_scope()?)?, None),
        Command::UpdatePi {
            check: false,
            scope,
            ..
        } => (
            resolve_scopes(
                env,
                ScopeFilter::resolve(scope.as_deref(), false, ScopeFilter::All)?,
            )?,
            None,
        ),
        Command::Source(args) if args.writes_project() => {
            (resolve_scopes(env, args.effective_scope()?)?, None)
        }
        Command::Marketplace(
            MarketplaceCommand::Subscribe { global, scope, .. }
            | MarketplaceCommand::Unsubscribe { global, scope, .. },
        ) => (
            first_scope(
                env,
                ScopeFilter::resolve(scope.as_deref(), *global, ScopeFilter::Project)?,
            )?,
            None,
        ),
        Command::Apply(_)
        | Command::Updates(_)
        | Command::Diff(_)
        | Command::Show(_)
        | Command::Versions(_)
        | Command::Enable(_)
        | Command::Disable(_)
        | Command::Verify { .. }
        | Command::Project(_)
        | Command::Template(_)
        | Command::Bookmark(_)
        | Command::List { .. }
        | Command::Check(_)
        | Command::Guard(_)
        | Command::GeneratedPaths
        | Command::BotInstructionsRender
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
        | Command::UpdatePi { .. } => {
            return Ok(WritingScopes {
                scopes: Vec::new(),
                lane_target: None,
            });
        }
    };
    Ok(WritingScopes {
        scopes,
        lane_target: target,
    })
}

fn first_scope(env: &Env, filter: ScopeFilter) -> Result<Vec<Scope>, String> {
    Ok(resolve_scopes(env, filter)?.into_iter().take(1).collect())
}

fn add_scope(env: &Env, global: bool) -> Result<Vec<Scope>, Box<dyn std::error::Error>> {
    if global {
        return Ok(vec![Scope::Global]);
    }
    // This asks the install owner for the prospective destination without
    // prompting. The actual add still asks before creating a new project.
    Ok(vec![install_destination(env, true)?])
}

#[cfg(test)]
mod tests;
