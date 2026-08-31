use clap::Args;

use kendex_core::engine::audit;
use kendex_core::env::Env;
use kendex_core::model::HarnessId;

use super::engine_common::{apply_report, print_safety};
use super::pin::parse_kind;
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

#[derive(Args)]
pub struct ForkArgs {
    /// agent | skill
    kind: String,
    name: String,
    /// Rename an existing fork to this name instead of forking
    #[arg(long)]
    rename: Option<String>,
    /// Which tool's rendering holds the edit (agents; default claude)
    #[arg(long)]
    harness: Option<String>,
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global (default project)
    #[arg(long)]
    scope: Option<String>,
}

pub fn run(env: &Env, args: ForkArgs) -> CliResult {
    let kind = parse_kind(&args.kind)?;
    let harness = match &args.harness {
        Some(value) => {
            HarnessId::parse(value).ok_or_else(|| format!("unknown harness '{value}'"))?
        }
        None => HarnessId::Claude,
    };
    let filter = ScopeFilter::resolve(args.scope.as_deref(), args.global, ScopeFilter::Project)?;
    let scope = resolve_scopes(env, filter)?.remove(0);

    let plan = match &args.rename {
        Some(new) => kendex_core::engine::fork::rename_fork(env, &scope, kind, &args.name, new)?,
        None => kendex_core::engine::fork::fork(env, &scope, kind, &args.name, harness)?,
    };
    for op in &plan.ops {
        say(&format!("  - {}", op.line()));
    }
    kendex_core::apply::execute(env, &plan)?;

    // Second transaction renders the fork (or the renamed fork) in place.
    // A rename leaves the old name's artifacts and lock entries behind as
    // orphans, so its follow-up removes them by name — otherwise the tool
    // ends up with both names installed.
    let report = match &args.rename {
        Some(_) => kendex_core::engine::plan_scope(
            env,
            &scope,
            &kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
                env, &scope,
            ))?
            .ok_or("no manifest")?,
            &kendex_core::lock::load(&kendex_core::lock::lock_path(env, &scope))?,
            &kendex_core::engine::PlanOptions {
                remove_orphans: true,
                removal_filter: Some(vec![(None, args.name.clone())]),
                ..Default::default()
            },
        )?,
        None => audit(env, &scope)?,
    };
    print_safety(&report);
    apply_report(env, &report)?;
    match args.rename {
        Some(new) => say(&format!("fork renamed to {}", new)),
        None => say(&format!(
            "{} '{}' is yours now — a local fork, updates paused",
            kind.name(),
            args.name
        )),
    }
    Ok(())
}
