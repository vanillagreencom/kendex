//! The project card's package checks: what the checks would write, and
//! switching them on.
//!
//! Every answer here is read from the machine — the planner for the files
//! and the tools, the scope's own drift for what is registered — because
//! the surface asking says these things to a person before and after a
//! write, and a claim it made up is a claim they cannot check.

use kendex_core::apply::Plan;
use kendex_core::drift::hook;
use kendex_core::drift::setup::SetupPlan;
use kendex_core::engine::{EngineReport, PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};
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
    /// Positions at the check's own destinations that nothing can settle
    /// on its own. These stop the registration itself, which is what
    /// tells them from the unsettled positions the confirmation lists
    /// beside its file disclosure.
    Conflicts { detail: Vec<String> },
    /// The scope was read back after the write and these tools still have
    /// no registration in place, with nothing else here saying why. The
    /// answer of last resort, so that an incomplete setup can never
    /// report itself without a reason.
    NotRegistered { harnesses: Vec<HarnessId> },
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
        let held = held_by(&before.plan);
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

/// What is holding the setup on the path that leaves the render for
/// later: the work this project already had, which is the whole of why
/// the render did not run.
///
/// Not the unsettled positions that plan also carries. Those hold up
/// their own items, and the check sits at none of them — saying they hold
/// the registration is the false attribution the confirmation's own copy
/// had to drop.
///
/// Handed the pending work alone rather than the whole report, so the
/// misattribution is unrepresentable here: the drift rows are not in
/// reach, and no later edit can reach for them without changing what this
/// function is asked.
fn held_by(pending: &Plan) -> SetupHeld {
    SetupHeld::OtherChanges {
        // A count of rows a person reads, not an index.
        count: u32::try_from(pending.ops.len()).unwrap_or(u32::MAX),
    }
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
    let waiting = kendex_core::drift::setup::targets_waiting(env, scope, &report)
        .map_err(|e| e.to_string())?;
    // Complete is the absence of a reason, never a separate judgement:
    // an incomplete setup that carries no reason is the state the issue
    // exists to remove, so the two cannot come apart.
    let held = held.or_else(|| reason_for(&report, waiting));
    Ok(SetupResult {
        complete: held.is_none(),
        held,
    })
}

/// Why the checks are not running here, read back from the scope after
/// the write. `None` only when every tool the check runs in has its
/// registration in place.
///
/// A position the render could not settle at one of the check's own
/// destinations is the specific answer and outranks the general one: it
/// names what a person can go and look at.
fn reason_for(report: &EngineReport, waiting: Vec<HarnessId>) -> Option<SetupHeld> {
    if waiting.is_empty() {
        return None;
    }
    let detail = kendex_core::drift::setup::check_conflicts(report);
    match detail.is_empty() {
        false => Some(SetupHeld::Conflicts { detail }),
        true => Some(SetupHeld::NotRegistered { harnesses: waiting }),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use kendex_core::apply::{Description, Op, PlannedOp, Pre};
    use kendex_core::engine::{DeclarationStatus, DriftRow, DriftState, GeneratedPaths};
    use kendex_core::model::ItemKind;

    use super::*;

    /// A plan carrying `ops` writes, which is what the person's own
    /// waiting work looks like to this decision.
    fn pending(ops: usize) -> Plan {
        let ops = (0..ops)
            .map(|n| PlannedOp {
                description: Description::from("write"),
                op: Op::WriteFile {
                    path: PathBuf::from(format!("/kendex-no-such-root/waiting-{n}")),
                    bytes: Vec::new(),
                    pre: Pre::Absent,
                },
            })
            .collect();
        Plan::landed(kendex_core::model::Scope::Global, ops)
            .unwrap_or_else(|error| panic!("a global plan lands: {error}"))
    }

    /// A scope read back after the write, carrying `drift` and nothing
    /// waiting.
    fn read_back(drift: Vec<DriftRow>) -> EngineReport {
        EngineReport {
            declaration_status: DeclarationStatus::Complete,
            drift,
            plan: pending(0),
            notes: Vec::new(),
            warnings: Vec::new(),
            set_changes: Vec::new(),
            sweepable: Vec::new(),
            kept: Vec::new(),
            safety: Vec::new(),
            repo_effects: Vec::new(),
            repo_effects_leaving: Vec::new(),
            instruction_shims: Vec::new(),
            fork_edits: Vec::new(),
            generated: GeneratedPaths::default(),
        }
    }

    /// A position at one of the check's own destinations that the render
    /// could not settle.
    fn in_the_way() -> DriftRow {
        DriftRow {
            kind: ItemKind::Hook,
            name: hook::HOOK_NAME.to_owned(),
            harness: HarnessId::Claude,
            scope: kendex_core::model::Scope::Global,
            state: DriftState::Conflict,
            detail: SETTLE_THIS.to_owned(),
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        }
    }

    const SETTLE_THIS: &str = "/kendex-no-such-root/.claude/settings.json";

    /// Complete is the absence of a reason. Every setup the read-back
    /// finds short of running carries one, and the position at the
    /// check's own destination is the specific answer where there is one:
    /// a row reading Setup incomplete with nothing to act on is the state
    /// this issue exists to remove.
    #[test]
    fn an_incomplete_setup_always_says_why() {
        assert!(
            reason_for(&read_back(Vec::new()), Vec::new()).is_none(),
            "a fully registered scope was given a reason"
        );

        match reason_for(&read_back(Vec::new()), vec![HarnessId::Pi]) {
            Some(SetupHeld::NotRegistered { harnesses }) => {
                assert_eq!(harnesses, vec![HarnessId::Pi]);
            }
            None | Some(SetupHeld::Conflicts { .. }) | Some(SetupHeld::OtherChanges { .. }) => {
                panic!("a tool with no registration and no other answer went unexplained")
            }
        }

        match reason_for(&read_back(vec![in_the_way()]), vec![HarnessId::Claude]) {
            Some(SetupHeld::Conflicts { detail }) => assert_eq!(detail, vec![SETTLE_THIS]),
            None | Some(SetupHeld::NotRegistered { .. }) | Some(SetupHeld::OtherChanges { .. }) => {
                panic!("the position in the way of the check was not the reason given")
            }
        }
    }

    /// The hold on the pending path is the work this project already had.
    /// An unsettled position elsewhere in the same scope holds up its own
    /// item and never the registration — the branch's own core test proves
    /// the render lands past one — so naming it here would send a person
    /// to settle positions that were never in the way and hide the changes
    /// that were.
    #[test]
    fn the_hold_is_the_work_this_project_already_had() {
        match held_by(&pending(2)) {
            SetupHeld::OtherChanges { count } => assert_eq!(count, 2),
            SetupHeld::Conflicts { .. } | SetupHeld::NotRegistered { .. } => {
                panic!("the hold named something other than the work already waiting")
            }
        }
    }
}
