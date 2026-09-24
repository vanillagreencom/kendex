use kendex_core::drift::hook;
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::engine_common::{confirm_and_execute, print_safety};
use super::{CliResult, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;

pub fn run(env: &Env, filter: ScopeFilter, yes: bool) -> CliResult {
    for scope in resolve_scopes(env, filter)? {
        install(env, &scope, yes)?;
    }
    Ok(())
}

/// Install the session-start drift hook: the script lands in the scope's
/// local source, the manifest declares it, and the ordinary refresh apply
/// renders it into the harnesses that execute hooks. Two confirmations at
/// most — the declaration, then the render — both skipped by `--yes`.
pub fn install(env: &Env, scope: &Scope, yes: bool) -> CliResult {
    let plan = hook::install_plan(env, scope)?;
    if plan.is_empty() {
        say(&format!(
            "{}: package checks already listed and current",
            scope_label(scope)
        ));
    } else {
        say(&format!("{}: listing package checks", scope_label(scope)));
        for op in &plan.ops {
            say(&format!("  - {}", op.line()));
        }
        let report = kendex_core::engine::EngineReport::observed(plan);
        confirm_and_execute(env, &report, yes)?;
    }
    // Render what was just declared — the same refresh any declaration
    // gets, previewed and confirmed the same way.
    let report =
        kendex_core::engine::plan_apply(env, scope, &kendex_core::engine::PlanOptions::default())?;
    if !report.plan.is_empty() {
        for op in &report.plan.ops {
            say(&format!("  - {}", op.line()));
        }
        print_safety(&report, false);
        confirm_and_execute(env, &report, yes)?;
    }
    say(&format!("{}: package checks installed", scope_label(scope)));
    Ok(())
}
