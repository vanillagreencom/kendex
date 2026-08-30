use std::io::IsTerminal;

use super::ledger::{Wrote, say_ledger};
use super::{CliResult, note, resolve_scopes, say, scope_label, warn};
use crate::scope::ScopeFilter;
use crate::ui;
use kendex_core::apply::Op;
use kendex_core::engine::{EngineReport, ops};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::names::shown;

/// What a removal does with the declaration.
#[derive(Clone, Copy)]
pub enum Removal {
    /// Drop it. `sweep` is the answer to "and the things only these items
    /// needed?" — `None` means nobody has answered yet.
    Disown { sweep: Option<bool> },
    /// Keep it: the files go, kendex.toml stays as it is, and the next
    /// refresh installs what it declares again. Nothing to ask about a
    /// sweep — what these items pull in is wanted back with them.
    KeepDeclaration,
}

pub fn run(env: &Env, names: Vec<String>, filter: ScopeFilter, mode: Removal) -> CliResult {
    if names.is_empty() {
        say("usage: kendex remove <name>… [--keep-declaration] [--scope project|global|all]");
        return Ok(());
    }
    ui::intro("kendex remove");
    let mut removed_any = false;
    let mut skipped: Vec<String> = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        let planned = {
            let _planning = ui::spinner(&format!("planning {}", scope_label(&scope)));
            match mode {
                Removal::Disown { sweep } => {
                    ops::remove(env, &scope, &names, None, sweep.unwrap_or(false))
                }
                Removal::KeepDeclaration => ops::uninstall(env, &scope, &names),
            }
        };
        let report = match planned {
            Ok(report) => report,
            // A scope whose files this build cannot read has nothing of
            // ours this run could account for. Skipped and named, so the
            // scopes after it are still visited — aborting here would
            // leave them untouched with nothing saying so — and collected,
            // so the run still fails: the person asked for a removal that
            // did not happen everywhere they asked for it.
            Err(error) if error.is_unreadable_record() => {
                warn(&format!(
                    "skipped {}: {}",
                    scope_label(&scope),
                    shown(&error.to_string())
                ));
                skipped.push(scope_label(&scope));
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        let report = match mode {
            Removal::Disown { sweep } => answer(env, &scope, &names, report, sweep)?,
            Removal::KeepDeclaration => report,
        };
        // What still wants a removed item says so now, not on the next
        // audit. Kept declared, a dependency's "kept removed" is true only
        // until the refresh the closing line names; the warning carries no
        // type to tell it from the rest, so it prints with them.
        for warning in &report.warnings {
            warn(&format!(
                "warning: {}: {}",
                shown(&warning.name),
                shown(&warning.message)
            ));
        }
        if !takes_anything(&report) {
            continue;
        }
        removed_any = true;
        say_split(&report, mode);
        let applied = {
            let _removing = ui::spinner("removing");
            super::engine_common::apply_report(env, &report)?
        };
        // What the run did, not what the verb is called: a removal whose
        // plan reconciles a declaration writes as well as trashes, and a
        // list of writes under the word "removed" says the wrong thing.
        say("changes:");
        for op in &report.plan.ops {
            say(&format!("  - {}", shown(&op.line())));
        }
        if matches!(mode, Removal::KeepDeclaration) {
            say(&format!(
                "{}: kendex.toml unchanged; refresh installs what it declares again",
                scope_label(&scope)
            ));
        }
        // A removal refuses nothing and prints no scores, so it hands
        // over neither: the ledger's parts are read off blocks the caller
        // printed, and this one closes on its count alone.
        say_ledger(
            &scope,
            Wrote {
                verb: "removed",
                count: Some(applied),
            },
            &[],
            &[],
        );
    }
    // A run that could read nothing removed nothing for a reason, and
    // "Nothing removed" on its own reads as "there was nothing to remove".
    if !removed_any && skipped.is_empty() {
        ui::ledger("Nothing removed", &[]);
    }
    if !skipped.is_empty() {
        return Err(format!(
            "could not read {} scope(s): {}",
            skipped.len(),
            skipped.join(", ")
        )
        .into());
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

/// What the removal decided. Taking a bundle away takes some of what it
/// carried and leaves the rest, so both halves are said out loud, each with
/// what accounts for it — otherwise the user is left guessing which members
/// survived and why. The planner's reason for a removal reads as disowning
/// ("no longer declared here"), so with the declaration kept only the kept
/// rows carry theirs.
fn say_split(report: &EngineReport, mode: Removal) {
    for change in &report.set_changes {
        if change.direction == kendex_core::engine::SetDirection::Remove {
            let reason = match mode {
                Removal::Disown { .. } => format!(" — {}", change.reason),
                Removal::KeepDeclaration => String::new(),
            };
            note(&format!(
                "removing {} {} for {}{reason}",
                change.kind.name(),
                shown(&change.name),
                change.harness.display_name()
            ));
        }
    }
    for kept in &report.kept {
        note(&format!(
            "keeping {} {} for {} — {}",
            kept.kind.name(),
            shown(&kept.name),
            kept.harness.display_name(),
            shown(&kept.reason)
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
) -> Result<EngineReport, Box<dyn std::error::Error>> {
    if sweep.is_some() || report.sweepable.is_empty() {
        return Ok(report);
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
    let asked = ui::confirm(&format!(
        "also remove {}, which nothing needs anymore?",
        leftovers.join(", ")
    ))?;
    match asked {
        true => Ok(ops::remove(env, scope, names, None, true)?),
        false => Ok(report),
    }
}
