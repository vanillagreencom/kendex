pub use super::advisory::{ScoredAt, print_advisory, print_safety};
pub use super::blocked::{print_conflicts, print_drift};

use kendex_core::engine::{DriftRow, DriftState, EngineReport};
use kendex_core::env::Env;
use kendex_core::model::HarnessId;

use std::io::IsTerminal;

use super::{CliResult, note, say, warn};
use crate::ui;

pub fn parse_harnesses(values: &[String]) -> Result<Vec<HarnessId>, String> {
    values
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| HarnessId::parse(v).ok_or(format!("unknown harness '{v}'")))
        .collect()
}

/// What the plan declined to do, in its own words. A note is the only
/// channel some passes have — the settings seed and the git posture say
/// here what they found — so a verb that prints nothing else about the
/// plan still prints these.
pub fn print_notes(report: &EngineReport) {
    for line in &report.notes {
        note(&format!("note: {}", line));
    }
}

/// The whole plan on a terminal, and back to the caller the items it
/// refused — one derivation, so a closing count and the conflict lines it
/// sends the reader to are one reading of one set of rows.
pub fn print_report(env: &Env, report: &EngineReport) -> Vec<super::offers::Blocked> {
    print_notes(report);
    for warning in &report.warnings {
        let target = match warning.harness {
            Some(harness) => format!("{} ({})", warning.name, harness.display_name()),
            None => warning.name.clone(),
        };
        warn(&format!("warning: {target}: {}", warning.message));
        if let Some(fix) = &warning.remediation {
            say(&format!("  fix: {}", fix));
        }
    }
    print_safety(report);
    let blocked = print_conflicts(env, report);
    if report.plan.is_empty() {
        // "nothing to do" directly under a conflict reads as "and nothing
        // you can do" — the run has plenty to do, once the reader picks.
        say(match blocked.is_empty() {
            false => "nothing to do until you settle the conflicts above",
            true => "nothing to do",
        });
        return blocked;
    }
    let ops = report.plan.ops.len();
    // The op list is what the confirm below is an answer to: a reader
    // asked to approve a count was never shown what it covers.
    say(&format!("plan: {} change{}", ops, plural(ops)));
    for op in &report.plan.ops {
        say(&format!("  - {}", op.line()));
    }
    blocked
}

fn plural(n: usize) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}

/// Content in a managed folder that no declaration and no lock claims.
/// apply leaves it exactly where it is (invariant 6) — which is why it has
/// to be said here: seen in `list` and nowhere else, it reads as checked
/// and passing rather than as never looked at.
pub fn print_unmanaged(drift: &[DriftRow]) {
    let rows: Vec<&DriftRow> = drift
        .iter()
        .filter(|row| row.state == DriftState::Unmanaged)
        .collect();
    if rows.is_empty() {
        return;
    }
    // A footnote, not one more verdict: said in its own voice so it does
    // not join the block of rows above it.
    note(&format!(
        "not managed: {} item{} kendex did not install and does not touch",
        rows.len(),
        if rows.len() == 1 { "" } else { "s" }
    ));
    for row in rows.iter().take(UNMANAGED_SHOWN) {
        say(&format!(
            "  - {} {} [{}] {}",
            row.kind.name(),
            row.name,
            row.harness.display_name(),
            row.detail
        ));
    }
    if rows.len() > UNMANAGED_SHOWN {
        say(&format!("  … and {} more", rows.len() - UNMANAGED_SHOWN));
    }
}

/// Enough to recognise what is there without burying the plan above it.
const UNMANAGED_SHOWN: usize = 10;

/// Prompted apply: `--yes` skips the prompt; a non-tty without `--yes`
/// refuses rather than guessing.
pub fn confirm_and_execute(env: &Env, report: &EngineReport, yes: bool) -> CliResult {
    // Nothing to write is not a write of nothing: the caller has already
    // said "nothing to do", and a completion line under it reads as a run
    // that finished something.
    if report.plan.is_empty() {
        return Ok(());
    }
    let applied = confirm_and_apply(env, report, yes)?;
    say(&format!("applied {applied} change(s)"));
    Ok(())
}

/// The same prompt and the same write, handing back what it wrote instead
/// of announcing it — for a verb that closes on a summary of its own.
pub fn confirm_and_apply(
    env: &Env,
    report: &EngineReport,
    yes: bool,
) -> Result<usize, Box<dyn std::error::Error>> {
    if report.plan.is_empty() {
        return Ok(0);
    }
    // The count is the consequence: an answer given to a bare "apply?" is
    // an answer to the verb's name rather than to what it writes.
    let ops = report.plan.ops.len();
    ask_before_writing(&format!("apply {ops} change{}?", plural(ops)), yes)?;
    let _writing = ui::spinner("writing");
    apply_report(env, report)
}

/// Execute a report's plan — the one way a CLI verb holding an
/// `EngineReport` writes it.
///
/// A plan can take a package away whatever the verb — `remove`, a manifest
/// edited by hand and applied, a sweep, an unsubscribe that drops its
/// packages — and the package's declared uninstaller has to run while the
/// scripts it names are still on disk. Executing `report.plan` directly
/// skips that, so no verb does: every report goes through here, and only a
/// bare `Plan` with no report behind it, which by construction drops no
/// package, is executed on its own.
pub fn apply_report(env: &Env, report: &EngineReport) -> Result<usize, Box<dyn std::error::Error>> {
    super::repo_effects::undo(&report.plan.scope, report)?;
    Ok(kendex_core::apply::execute(env, &report.plan)?.applied)
}

/// The answer every verb needs before it writes, asked one way. `--yes`
/// skips it; a run with nobody to ask refuses before its first write
/// rather than guessing, and says which flag would have answered it.
pub fn ask_before_writing(question: &str, yes: bool) -> CliResult {
    if yes {
        return Ok(());
    }
    if !std::io::stdin().is_terminal() {
        return Err("refusing to apply without --yes in a non-interactive session".into());
    }
    match ui::confirm(question)? {
        true => Ok(()),
        false => Err("apply cancelled".into()),
    }
}

/// A refresh failure per v1: any per-item failure or a locked item missing
/// from its source is a hard error.
pub fn refresh_failures(report: &EngineReport) -> Vec<String> {
    report
        .notes
        .iter()
        .filter(|n| {
            n.contains("not found in source")
                || n.contains("missing at")
                || n.contains("not fetched yet")
                || n.contains("refused catalog read")
        })
        .cloned()
        .collect()
}
