use std::io::{IsTerminal, Write};

use kendex_core::apply::Op;
use kendex_core::engine::{EngineReport, ops};
use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

/// `sweep` is the answer to "and the things only these items needed?" —
/// `None` means nobody has answered yet.
pub fn run(env: &Env, names: Vec<String>, filter: ScopeFilter, sweep: Option<bool>) -> CliResult {
    if names.is_empty() {
        say("usage: kendex remove <name>… [--scope project|global|all]");
        return Ok(());
    }
    let mut removed_any = false;
    for scope in resolve_scopes(env, filter)? {
        let report = match ops::remove(env, &scope, &names, None, sweep.unwrap_or(false)) {
            Ok(report) => report,
            // A scope without a v2 manifest has nothing of ours to remove.
            Err(error) if super::engine_common::is_legacy(&error) => continue,
            Err(error) => return Err(error.into()),
        };
        let report = match answer(env, &scope, &names, report, sweep)? {
            Some(report) => report,
            None => continue,
        };
        // What still wants a removed item says so now, not on the next audit.
        for warning in &report.warnings {
            say(&format!("warning: {}: {}", warning.name, warning.message));
        }
        if takes_anything(&report) {
            removed_any = true;
            say_split(&report);
            take_away(env, &report)?;
        }
    }
    if !removed_any {
        say("Nothing removed");
    }
    Ok(())
}

/// `--keep-declaration`: the files go, kendex.toml stays as it is, and the
/// next refresh installs the items again. Nothing to ask about a sweep —
/// what these items pull in is wanted back with them — and nothing to warn
/// about: whatever needed them gets them back the same way.
pub fn uninstall(env: &Env, names: Vec<String>, filter: ScopeFilter) -> CliResult {
    if names.is_empty() {
        say("usage: kendex remove <name>… --keep-declaration [--scope project|global|all]");
        return Ok(());
    }
    let mut removed_any = false;
    for scope in resolve_scopes(env, filter)? {
        let report = match ops::uninstall(env, &scope, &names) {
            Ok(report) => report,
            Err(error) if super::engine_common::is_legacy(&error) => continue,
            Err(error) => return Err(error.into()),
        };
        if !takes_anything(&report) {
            continue;
        }
        removed_any = true;
        // The planner's reasons read as disowning ("no longer declared
        // here"); here the declaration stays, so only the kept rows carry
        // theirs.
        for change in &report.set_changes {
            if change.direction == kendex_core::engine::SetDirection::Remove {
                say(&format!(
                    "removing {} {} for {}",
                    change.kind.name(),
                    change.name,
                    change.harness.display_name()
                ));
            }
        }
        say_kept(&report);
        take_away(env, &report)?;
        say(&format!(
            "{}: still declared in kendex.toml; refresh installs it again",
            scope.label()
        ));
    }
    if !removed_any {
        say("Nothing removed");
    }
    Ok(())
}

/// Whether the plan takes anything off disk; one that does not is not run.
fn takes_anything(report: &EngineReport) -> bool {
    report
        .plan
        .ops
        .iter()
        .any(|op| matches!(op.op, Op::Trash { .. } | Op::WriteLock { .. }))
}

fn take_away(env: &Env, report: &EngineReport) -> CliResult {
    kendex_core::apply::execute(env, &report.plan, None)?;
    for op in &report.plan.ops {
        say(&format!("  - {}", op.description));
    }
    Ok(())
}

/// What the removal decided. Taking a bundle away takes some of what it
/// carried and leaves the rest, so both halves are said out loud, each with
/// what accounts for it — otherwise the user is left guessing which members
/// survived and why.
fn say_split(report: &EngineReport) {
    for change in &report.set_changes {
        if change.direction == kendex_core::engine::SetDirection::Remove {
            say(&format!(
                "removing {} {} for {} — {}",
                change.kind.name(),
                change.name,
                change.harness.display_name(),
                change.reason
            ));
        }
    }
    say_kept(report);
}

fn say_kept(report: &EngineReport) {
    for kept in &report.kept {
        say(&format!(
            "keeping {} {} for {} — {}",
            kept.kind.name(),
            kept.name,
            kept.harness.display_name(),
            kept.reason
        ));
    }
}

/// Removing the last thing that needed something leaves it behind. Asking is
/// the whole point of the step, so with nobody to ask — no terminal and no
/// flag — the removal stops before it writes anything, naming the flags that
/// answer it.
fn answer(
    env: &Env,
    scope: &Scope,
    names: &[String],
    report: EngineReport,
    sweep: Option<bool>,
) -> Result<Option<EngineReport>, Box<dyn std::error::Error>> {
    if sweep.is_some() || report.sweepable.is_empty() {
        return Ok(Some(report));
    }
    let leftovers: Vec<String> = report
        .sweepable
        .iter()
        .map(|change| format!("{} {}", change.kind.name(), change.name))
        .collect();
    if !std::io::stdin().is_terminal() {
        return Err(format!(
            "removing this leaves {} behind that nothing needs anymore — pass --sweep to remove them too, or --no-sweep to keep them",
            leftovers.join(", ")
        )
        .into());
    }
    let _ = write!(
        std::io::stderr(),
        "also remove {}, which nothing needs anymore? [y/N] ",
        leftovers.join(", ")
    );
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    match matches!(answer.trim(), "y" | "Y" | "yes") {
        true => Ok(Some(ops::remove(env, scope, names, None, true)?)),
        false => Ok(Some(report)),
    }
}
