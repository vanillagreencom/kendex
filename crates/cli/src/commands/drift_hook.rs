use kendex_core::drift::hook;
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::engine_common::confirm_and_execute;
use super::{CliResult, resolve_scopes, say};
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
            "{}: drift hook already declared and current",
            scope.label()
        ));
    } else {
        say(&format!("{}: declaring the drift hook", scope.label()));
        for op in &plan.ops {
            say(&format!("  - {}", op.description));
        }
        let report = kendex_core::engine::EngineReport {
            drift: Vec::new(),
            plan,
            notes: Vec::new(),
            warnings: Vec::new(),
            set_changes: Vec::new(),
            sweepable: Vec::new(),
            kept: Vec::new(),
            safety: Vec::new(),
            unmeasured: Default::default(),
            rendered: Default::default(),
            // This plan is written here rather than by the engine, and it
            // is about the hook declaration alone — no package's content
            // is being put back, so there is nothing to account for.
            acting: Default::default(),
        };
        confirm_and_execute(env, &report, yes)?;
    }
    // Render what was just declared — the same refresh any declaration
    // gets, previewed and confirmed the same way.
    let report =
        kendex_core::engine::plan_apply(env, scope, &kendex_core::engine::PlanOptions::default())?;
    if !report.plan.is_empty() {
        for op in &report.plan.ops {
            say(&format!("  - {}", op.description));
        }
        confirm_and_execute(env, &report, yes)?;
    }
    say(&format!("{}: drift hook installed", scope.label()));
    Ok(())
}
