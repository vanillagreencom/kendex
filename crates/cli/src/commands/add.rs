use kendex_core::engine::ops::{self, AddRequest};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::model::Scope;

use kendex_core::manifest::Method;

use super::engine_common::{confirm_and_apply, parse_harnesses, print_report};
use super::ledger::{Wrote, say_ledger};
use super::{CliResult, harness_picker, resolve_scopes, warn};
use crate::scope::ScopeFilter;
use crate::ui;

pub struct AddArgs {
    pub source: Option<String>,
    pub global: bool,
    pub harness: Vec<String>,
    pub all_harnesses: bool,
    pub agent: Vec<String>,
    pub skill: Vec<String>,
    pub bundle: Vec<String>,
    pub optional: Vec<String>,
    pub hook: Vec<String>,
    pub command: Vec<String>,
    pub mcp_server: Vec<String>,
    pub pi_extension: Vec<String>,
    pub copy: bool,
    pub method: Option<String>,
    pub yes: bool,
    pub all: bool,
    pub clobber: bool,
    pub no_auto_skills: bool,
    pub hold: bool,
    pub allow_repo_effects: bool,
}

/// Where this install goes and how it is delivered. Flags settle both
/// where they were given; otherwise a terminal is asked and a session
/// without one keeps the scope's own defaults. What the request would
/// declare decides which tools can take it, so the picker and
/// `--all-harnesses` offer only those.
fn settle_targets(
    env: &Env,
    scope: &Scope,
    request: &mut AddRequest,
    args: &AddArgs,
) -> Result<(), Box<dyn std::error::Error>> {
    let kinds = ops::requested_kinds(request);
    request.harnesses = match (args.all_harnesses, args.harness.is_empty()) {
        (true, _) => Some(harness_picker::installable_at(scope, &kinds)),
        (false, false) => Some(parse_harnesses(&args.harness)?),
        (false, true) => None,
    };
    request.method = match (args.copy, args.method.as_deref()) {
        (true, _) | (_, Some("copy")) => Some(Method::Copy),
        (_, Some("symlink")) => Some(Method::Symlink),
        _ => None,
    };
    let chosen = harness_picker::ask(
        env,
        scope,
        &kinds,
        request.harnesses.is_some(),
        request.method,
        args.yes,
    )?;
    request.harnesses = request.harnesses.take().or(chosen.harnesses);
    request.method = chosen.method;
    Ok(())
}

fn split(values: &[String]) -> Vec<String> {
    values
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .collect()
}

pub fn run(env: &Env, mut args: AddArgs) -> CliResult {
    ui::intro("kendex add");
    let filter = if args.global {
        ScopeFilter::Global
    } else {
        ScopeFilter::Project
    };
    let scope = resolve_scopes(env, filter)?.remove(0);

    // A collection link is a whole install of its own: the set the link
    // resolves to, never mixed with item flags.
    if let Some(reference) = &args.source
        && let Ok(kendex_core::source_ref::SourceRef::Collection { id }) =
            kendex_core::source_ref::parse_typed(reference)
    {
        return super::add_collection::run(env, &scope, &id, args.yes, args.allow_repo_effects);
    }

    let agents = split(&args.agent);
    let skills = split(&args.skill);
    let hooks = split(&args.hook);
    let commands = split(&args.command);
    let mcp_servers = split(&args.mcp_server);
    let bundles = split(&args.bundle);
    let pi_extensions = split(&args.pi_extension);
    if args.global
        && !args.all
        && [
            &agents,
            &skills,
            &hooks,
            &commands,
            &mcp_servers,
            &bundles,
            &pi_extensions,
        ]
        .iter()
        .all(|names| names.is_empty())
    {
        return Err(
            "global installs need --all or explicit --agent/--skill/--bundle selections".into(),
        );
    }
    if args.global && args.all && !args.clobber {
        let lock = load_lock(&lock_path(env, &Scope::Global))?;
        if !lock.entries.is_empty() {
            return Err(
                "the global scope already has installs — pass --clobber to redeclare everything"
                    .into(),
            );
        }
    }

    let mut request = AddRequest {
        source: args.source.take(),
        agents,
        skills,
        hooks,
        commands,
        mcp_servers,
        pi_extensions,
        all: args.all,
        harnesses: None,
        method: None,
        no_auto_skills: args.no_auto_skills,
        optional: split(&args.optional),
        bundles,
        hold: args.hold,
    };
    settle_targets(env, &scope, &mut request, &args)?;
    let planned = {
        let _planning = ui::spinner("planning the install");
        ops::add(env, &scope, &request)
    };
    let report = match planned {
        Err(kendex_core::error::CoreError::SourcePending { .. }) => {
            let manifest = ops::manifest_for_mutation(env, &scope)?;
            let synced = {
                let _reading = ui::spinner("reading sources");
                kendex_core::remote::sync_sources(env, &manifest)?
            };
            for warning in synced {
                warn(&format!("warning: {}", warning));
            }
            let _planning = ui::spinner("planning the install");
            ops::add(env, &scope, &request)?
        }
        other => other?,
    };
    write_and_close(env, &scope, &report, args.yes, args.allow_repo_effects)
}

/// The write, the repository-effects account, and the close.
///
/// Disclosed after the write, because the script an effect runs is the one
/// this install just put on disk. That leaves a prompt between the write
/// and the closing line, so the close is handed over rather than written
/// under it: what the run wrote is reported whatever the reader answers.
fn write_and_close(
    env: &Env,
    scope: &Scope,
    report: &kendex_core::engine::EngineReport,
    yes: bool,
    allow_effects: bool,
) -> CliResult {
    let blocked = print_report(env, report);
    let applied = confirm_and_apply(env, report, yes)?;
    super::repo_effects::disclose_and_finish(
        env,
        scope,
        &report.repo_effects,
        allow_effects,
        || {
            // "done" answered whether the process ended, never what it
            // did. The verb is the one that was typed, because the count
            // is of changes and not of packages: a run whose only change
            // is the declaration added something, and installed nothing.
            let count = (!report.plan.is_empty()).then_some(applied);
            say_ledger(
                scope,
                Wrote {
                    verb: "added",
                    count,
                },
                &blocked,
                &report.safety,
            );
        },
    )
}
