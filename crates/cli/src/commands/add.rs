use kendex_core::engine::ops::{self, AddRequest};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::model::Scope;

use super::engine_common::{confirm_and_execute, parse_harnesses, print_report};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

pub struct AddArgs {
    pub source: Option<String>,
    pub global: bool,
    pub harness: Vec<String>,
    pub agent: Vec<String>,
    pub skill: Vec<String>,
    pub bundle: Vec<String>,
    pub optional: Vec<String>,
    pub hook: Vec<String>,
    pub command: Vec<String>,
    pub mcp_server: Vec<String>,
    pub pi_extension: Vec<String>,
    pub copy: bool,
    pub yes: bool,
    pub all: bool,
    pub clobber: bool,
    pub no_auto_skills: bool,
    pub hold: bool,
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

pub fn run(env: &Env, args: AddArgs) -> CliResult {
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
        return super::add_collection::run(env, &scope, &id, args.yes);
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

    let request = AddRequest {
        source: args.source,
        agents,
        skills,
        hooks,
        commands,
        mcp_servers,
        pi_extensions,
        all: args.all,
        harnesses: if args.harness.is_empty() {
            None
        } else {
            Some(parse_harnesses(&args.harness)?)
        },
        copy: args.copy,
        no_auto_skills: args.no_auto_skills,
        optional: split(&args.optional),
        bundles,
        hold: args.hold,
    };
    let report = match ops::add(env, &scope, &request) {
        Err(kendex_core::error::CoreError::SourcePending { .. }) => {
            let manifest = ops::manifest_for_mutation(env, &scope)?;
            for warning in kendex_core::remote::sync_sources(env, &manifest)? {
                say(&format!("warning: {warning}"));
            }
            ops::add(env, &scope, &request)?
        }
        other => other?,
    };
    print_report(env, &report);
    confirm_and_execute(env, &report, args.yes)?;
    say("done");
    Ok(())
}
