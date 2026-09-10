//! The project card's package checks: what the checks would write, and
//! switching them on.
//!
//! Every answer here is read from the machine — the planner for the files
//! and the tools, the scope's own drift for what is registered — because
//! the surface asking says these things to a person before and after a
//! write, and a claim it made up is a claim they cannot check.

use kendex_core::drift::hook;
use kendex_core::drift::setup::SetupPlan;
use kendex_core::engine::{EngineReport, PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

/// What switching the checks on at this scope would write, from the plan
/// that would write it. Reads only; a preview installs nothing.
///
/// Refuses a registered project whose folder is not there, so a card left
/// standing from before a move cannot open an offer to rebuild it.
#[tauri::command(async)]
#[specta::specta]
pub fn package_check_plan(scope: Scope) -> Result<SetupPlan, String> {
    let env = env()?;
    kendex_core::drift::setup::setup_plan(&env, &scope).map_err(|e| e.to_string())
}

/// Why the setup did not finish in this action.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum SetupHeld {
    /// The project had changes waiting that this yes did not cover. The
    /// script and the declaration landed; the registration goes in when
    /// those changes do. Nothing here says that will succeed — the same
    /// positions can refuse then too.
    OtherChanges { count: u32 },
    /// Positions in this project that nothing can settle on its own. Said
    /// as the audit says them, so the reader gets the position rather than
    /// a verdict about it.
    Conflicts { detail: Vec<String> },
}

/// Where the checks stand after the action.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SetupResult {
    /// Every tool the declaration names is registered. Read from the
    /// scope's drift, never from what a write returned: an installer's
    /// answer says a plan ran, not that every promised target is live.
    pub complete: bool,
    /// Why it is not, when it is not. Which tools are covered and which
    /// are not is the card's to say from the scan that follows this;
    /// this is the part no read of the machine can recover afterwards.
    pub held: Option<SetupHeld>,
}

/// Switch the session-start package check on for a scope: the script into
/// the scope's local source, the declaration into its manifest, then the
/// ordinary apply renders it into each tool.
///
/// The person approved the check and nothing else, so the rendering apply
/// runs only when the scope had no other pending work. With work waiting,
/// the declaration lands and the registration waits with it — which is
/// what the confirmation says before it is pressed, and what the answer
/// says afterwards.
#[tauri::command(async)]
#[specta::specta]
pub fn enable_package_checks(scope: Scope) -> Result<SetupResult, String> {
    let env = env()?;
    let options = PlanOptions::default();
    // What is waiting here that the checks did not ask for, read through
    // the judge the confirmation showed its count from: with work waiting,
    // this action writes the declaration and leaves the render to whoever
    // applies that work.
    let before = kendex_core::drift::setup::pending_without_checks(&env, &scope)
        .map_err(|e| e.to_string())?;
    let pending = !before.plan.is_empty();
    // Refuses a folder that went away since the confirmation opened, and
    // binds the same check into the plan the apply runs.
    let plan = hook::install_plan(&env, &scope).map_err(|e| e.to_string())?;
    kendex_core::apply::execute(&env, &plan).map_err(|e| e.to_string())?;
    if pending {
        let held = held_by(&before);
        return stand(&env, &scope, &options, Some(held));
    }
    let report = plan_apply(&env, &scope, &options).map_err(|e| e.to_string())?;
    // Through the one executor, like every other report. Nothing was
    // pending when this started, so the lock this plan writes is the one
    // the scope already carries and no package leaves with it — which is
    // what makes it safe to run a whole-scope plan off a yes given about
    // the checks.
    crate::repo_effects::write_nothing_leaving(&env, &report)?;
    stand(&env, &scope, &options, None)
}

/// What is holding the setup, read off the plan that was already waiting:
/// a position nothing can settle outranks a count of ordinary changes,
/// because applying them is what a person would try next and that is the
/// thing an unsettled position refuses.
fn held_by(before: &EngineReport) -> SetupHeld {
    let detail = kendex_core::drift::setup::conflicts(before);
    if detail.is_empty() {
        return SetupHeld::OtherChanges {
            // A count of rows a person reads, not an index.
            count: u32::try_from(before.plan.ops.len()).unwrap_or(u32::MAX),
        };
    }
    SetupHeld::Conflicts { detail }
}

/// Where the checks stand now: the scope planned again, and every tool the
/// declaration names read off that plan's drift. A tool with a row saying
/// its registration is missing, stale or blocked is not registered; one
/// with no row is.
fn stand(
    env: &Env,
    scope: &Scope,
    options: &PlanOptions,
    held: Option<SetupHeld>,
) -> Result<SetupResult, String> {
    let report = plan_apply(env, scope, options).map_err(|e| e.to_string())?;
    let registered = kendex_core::drift::setup::every_target_registered(env, scope, &report)
        .map_err(|e| e.to_string())?;
    Ok(SetupResult {
        complete: registered && held.is_none(),
        held,
    })
}
