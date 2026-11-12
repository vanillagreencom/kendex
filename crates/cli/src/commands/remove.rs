use super::engine_common::{answerable, apply_report_accounted, warning_lines};
use super::ledger::{Folded, Wrote, say_ledger};
use super::{CliResult, resolve_scopes, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Choice, Key, Span, Status, Style};
use kendex_core::apply::{Op, PlannedOp};
use kendex_core::decision::{Approved, Consent, Effect};
use kendex_core::engine::{DroppedDeclaration, EngineReport, SetDirection, ops};
use kendex_core::env::Env;
use kendex_core::manifest::manifest_file_name;
use kendex_core::model::Scope;

/// What a removal does with the declaration.
#[derive(Clone, Copy)]
pub enum Removal {
    /// Drop it. `sweep` is the answer to "and the things only these items
    /// needed?" — `None` means nobody has answered yet. `kind` narrows each
    /// name to that kind; `None` takes every kind the name declares.
    Disown {
        sweep: Option<bool>,
        kind: Option<kendex_core::model::ItemKind>,
    },
    /// Keep it: the files go, kendex.toml stays as it is, and the next
    /// refresh installs what it declares again. Nothing to ask about a
    /// sweep — what these items pull in is wanted back with them.
    KeepDeclaration,
}

const USAGE: &str =
    "usage: kendex remove <name>… [--kind KIND] [--keep-declaration] [--scope project|global|all]";

/// The answer to the sweep question: `s` takes what nothing needs anymore
/// with the removal, and the default keeps it, as `--no-sweep` does.
const SWEEP: [(Choice<'static>, bool); 2] = [
    (
        Choice {
            key: Key::Char('s'),
            label: "remove them too",
        },
        true,
    ),
    (
        Choice {
            key: Key::Enter,
            label: "keep them",
        },
        false,
    ),
];

pub fn run(env: &Env, names: Vec<String>, filter: ScopeFilter, mode: Removal) -> CliResult {
    let style = ui::style();
    if names.is_empty() {
        ui::stderr(&style.report_row(Status::Notice, &[Span::Command(USAGE)], ""));
        return Ok(());
    }
    let scopes = resolve_scopes(env, filter)?;
    let prepared: Vec<_> = scopes
        .iter()
        .map(|scope| match mode {
            Removal::Disown { sweep, kind } => {
                ops::prepare_remove(env, scope, &names, kind, sweep.unwrap_or(false))
            }
            Removal::KeepDeclaration => ops::prepare_uninstall(env, scope, &names),
        })
        .collect();
    for removal in prepared.iter().flatten() {
        if let Err(error) = removal.check_catalog_compatibility(env)
            && error.is_catalog_compatibility()
        {
            return Err(error.into());
        }
    }
    let planned = plan_scopes(env, &scopes, prepared);
    refuse_an_unanswerable_sweep(&planned, mode)?;
    // Each scope's closing line is held until every scope is written and
    // the trash pass has run, so the pass's own line never lands under a
    // line the run already closed on. A scope that fails, or a cancel at
    // its question, stops the scopes after it and never the finishing of
    // the ones before it: what they wrote is on disk and owed its closing
    // line, and the error leaves once that line is said.
    let mut closing: Vec<(Scope, usize)> = Vec::new();
    let mut stopped: Option<Box<dyn std::error::Error>> = None;
    for (scope, planned) in scopes.into_iter().zip(planned) {
        match planned.and_then(|planned| remove_scope(env, &style, &scope, planned, mode)) {
            Ok(Removed::Nothing) => {}
            Ok(Removed::Wrote(applied)) => closing.push((scope, applied)),
            Ok(Removed::WroteThenStopped(applied, error)) => {
                closing.push((scope, applied));
                stopped = Some(error);
                break;
            }
            Err(error) => {
                stopped = Some(error);
                break;
            }
        }
    }
    super::engine_common::tidy_trash(env);
    if closing.is_empty() && stopped.is_none() {
        ui::ledger("Nothing removed", &[]);
    }
    for (scope, applied) in closing {
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
            Folded::None,
        );
    }
    match stopped {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

/// One scope's removal as planned before any scope writes: the captured
/// inputs a sweep answer plans again from, and their plan.
struct Planned {
    prepared: ops::PreparedRemoval,
    report: EngineReport,
}

type Planning = Result<Planned, Box<dyn std::error::Error>>;

/// Every scope planned from its captured inputs before the first write, so
/// a question nobody is there to answer stops the run before any scope
/// writes. Planning stops at the first scope that fails, as the writes
/// after it would: the scopes before it still write.
fn plan_scopes(
    env: &Env,
    scopes: &[Scope],
    prepared: Vec<kendex_core::error::Result<ops::PreparedRemoval>>,
) -> Vec<Planning> {
    let mut planned = Vec::new();
    for (scope, prepared) in scopes.iter().zip(prepared) {
        let planning = prepared.map_err(Into::into).and_then(|prepared| {
            let report = {
                let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
                prepared.plan(env)
            }?;
            Ok(Planned { prepared, report })
        });
        let failed = planning.is_err();
        planned.push(planning);
        if failed {
            break;
        }
    }
    planned
}

/// Removing the last thing that needed something leaves it behind. Asking
/// is the whole point of the step, so with nobody to ask and no flag the
/// removal stops before any scope writes, naming the flags that answer it.
fn refuse_an_unanswerable_sweep(planned: &[Planning], mode: Removal) -> CliResult {
    if !matches!(mode, Removal::Disown { sweep: None, .. }) || answerable(false) {
        return Ok(());
    }
    let leftovers: Vec<String> = planned
        .iter()
        .flatten()
        .flat_map(|planned| leftover_names(&planned.report))
        .collect();
    if leftovers.is_empty() {
        return Ok(());
    }
    Err(format!(
        "removing this leaves {} behind that nothing needs anymore — pass --sweep to remove them too, or --no-sweep to keep them",
        leftovers.join(", ")
    )
    .into())
}

fn leftover_names(report: &EngineReport) -> Vec<String> {
    report
        .sweepable
        .iter()
        .map(|change| format!("{} {}", change.kind.name(), change.name))
        .collect()
}

/// What one scope's removal came to.
enum Removed {
    /// The plan takes nothing off disk.
    Nothing,
    /// The count of what it wrote.
    Wrote(usize),
    /// It wrote, and a step after the write failed: the write stands and
    /// is counted, and the run stops on the error.
    WroteThenStopped(usize, Box<dyn std::error::Error>),
}

/// One scope's removal: answered, written and said.
fn remove_scope(
    env: &Env,
    style: &Style,
    scope: &Scope,
    planned: Planned,
    mode: Removal,
) -> Result<Removed, Box<dyn std::error::Error>> {
    let Planned { prepared, report } = planned;
    let report = match mode {
        Removal::Disown { sweep, .. } => answer(env, style, &prepared, report, sweep)?,
        Removal::KeepDeclaration => report,
    };
    // What still wants a removed item says so now, not on the next
    // audit. Kept declared, a dependency's "kept removed" is true only
    // until the refresh the closing line names; the warning carries no
    // type to tell it from the rest, so it prints with them.
    ui::stderr(&warning_lines(style, &report.warnings));
    if !takes_anything(&report) {
        return Ok(Removed::Nothing);
    }
    let file = manifest_file_name(env, scope);
    ui::stderr(&split_lines(style, &report, mode, &file));
    // The write's own wait is drawn where it writes: a wait drawn around
    // this call would still tick under the commit offer's question.
    let wrote = apply_report_accounted(env, &report, None)?;
    ui::stderr(&changes_lines(style, &report.plan.ops));
    if matches!(mode, Removal::KeepDeclaration) {
        ui::stderr(&style.report_row(
            Status::Notice,
            &[Span::Prose(&format!(
                "{}: {file} unchanged; refresh installs what it declares again",
                scope_label(scope)
            ))],
            "",
        ));
    }
    Ok(match wrote.after {
        Ok(()) => Removed::Wrote(wrote.applied),
        Err(after) => Removed::WroteThenStopped(wrote.applied, after.into_error()),
    })
}

/// What the run did, not what the verb is called: a removal whose plan
/// reconciles a declaration writes as well as trashes, and a list of
/// writes under the word "removed" says the wrong thing.
fn changes_lines(style: &Style, ops: &[PlannedOp]) -> Vec<String> {
    let mut lines = style.report_row(Status::Done, &[Span::Prose("changes:")], "");
    for op in ops {
        lines.extend(style.report_row(Status::Done, &[Span::Prose(&op.line())], "  - "));
    }
    lines
}

/// Whether the plan takes anything off disk or changes kendex.toml for
/// the removal; one that does not is not run. A declaration refresh never
/// installed, or a dependency already off disk, has no file to take, so
/// the change to kendex.toml is the removal. A manifest save alone counts
/// for nothing: the planner makes one of its own (an agent alias renamed)
/// whatever the names are.
fn takes_anything(report: &EngineReport) -> bool {
    report.disowned.is_some()
        || report.plan.ops.iter().any(|op| {
            matches!(
                op.op,
                Op::Trash { .. } | Op::PiRemove { .. } | Op::WriteLock { .. }
            )
        })
}

/// What the removal decided: the declarations it drops from kendex.toml
/// and the removals it writes down there, then what it takes and keeps.
/// Taking a bundle away takes some of what it carried and leaves the rest,
/// so both halves are said out loud, each with what accounts for it —
/// otherwise the user is left guessing which members survived and why.
/// The planner's reason for a removal reads as disowning ("the declaration
/// does not include it"), so with the declaration kept only the kept rows
/// carry theirs.
fn split_lines(style: &Style, report: &EngineReport, mode: Removal, file: &str) -> Vec<String> {
    let mut said: Vec<String> = Vec::new();
    if let Some(disowned) = &report.disowned {
        for dropped in &disowned.dropped {
            let declared = match dropped {
                DroppedDeclaration::Item { kind, name } => format!("{} {name}", kind.name()),
                DroppedDeclaration::Bundle { name } => format!("bundle {name}"),
            };
            said.push(format!("dropping {declared} from {file}"));
        }
        for (kind, name) in &disowned.suppressed {
            said.push(format!(
                "keeping {} {name} removed: [suppressed] in {file}",
                kind.name()
            ));
        }
    }
    for change in &report.set_changes {
        if change.direction == SetDirection::Remove {
            let reason = match mode {
                Removal::Disown { .. } => format!(" — {}", change.reason),
                Removal::KeepDeclaration => String::new(),
            };
            said.push(format!(
                "removing {} {} for {}{reason}",
                change.kind.name(),
                change.name,
                change.harness.display_name()
            ));
        }
    }
    for kept in &report.kept {
        said.push(format!(
            "keeping {} {} for {} — {}",
            kept.kind.name(),
            kept.name,
            kept.harness.display_name(),
            kept.reason
        ));
    }
    said.iter()
        .flat_map(|line| style.report_row(Status::Notice, &[Span::Prose(line)], ""))
        .collect()
}

/// The answer to the sweep, where nobody gave one. The question names the
/// changes a yes adds to this plan, read off the plan that sweeps, so the
/// yes writes exactly what it was shown. A sweep that adds nothing is not
/// asked about. `run` refused before any write where nobody can answer.
fn answer(
    env: &Env,
    style: &Style,
    prepared: &ops::PreparedRemoval,
    report: EngineReport,
    sweep: Option<bool>,
) -> Result<EngineReport, Box<dyn std::error::Error>> {
    if sweep.is_some() || report.sweepable.is_empty() {
        return Ok(report);
    }
    let sweeping = prepared.plan_sweeping(env)?;
    let question = {
        let added = Approved::of(&report, &Consent::of(&report, &[])).added(&sweeping);
        match added.consent.is_empty() {
            true => return Ok(report),
            false => sweep_question(style, &leftover_names(&report), &added.consent),
        }
    };
    ui::stderr(&question);
    match ui::choose(&SWEEP)? {
        true => Ok(sweeping),
        false => Ok(report),
    }
}

/// The sweep as a decision: what it would take, how many changes that is
/// and the flags that answer it unasked, then each change a yes adds. The
/// keys are drawn under it by the question itself.
fn sweep_question(style: &Style, leftovers: &[String], added: &Consent) -> Vec<String> {
    let count = added.count();
    let mut lines = style.callout(
        &format!(
            "also remove {}, which nothing needs anymore?",
            leftovers.join(", ")
        ),
        Some(&format!(
            "{count} more change{}; --sweep or --no-sweep answers this without asking",
            match count {
                1 => "",
                _ => "s",
            }
        )),
        &[],
    );
    for effect in &added.effects {
        lines.extend(match effect {
            Effect::Op(planned) => style.plan_row(planned),
            Effect::Pi(settle) => {
                style.report_row(Status::Decision, &[Span::Prose(&settle.name)], "  - ")
            }
        });
    }
    lines
}

#[cfg(test)]
mod tests;
