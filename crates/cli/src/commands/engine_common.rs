use std::io::{IsTerminal, Write};

use kendex_core::engine::EngineReport;
use kendex_core::engine::decisions::DecisionState;
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::model::HarnessId;

use super::{CliResult, say};

pub fn parse_harnesses(values: &[String]) -> Result<Vec<HarnessId>, String> {
    values
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| HarnessId::parse(v).ok_or(format!("unknown harness '{v}'")))
        .collect()
}

pub fn print_report(report: &EngineReport) {
    for note in &report.notes {
        say(&format!("note: {note}"));
    }
    for warning in &report.warnings {
        let target = match warning.harness {
            Some(harness) => format!("{} ({})", warning.name, harness.display_name()),
            None => warning.name.clone(),
        };
        say(&format!("warning: {target}: {}", warning.message));
        if let Some(fix) = &warning.remediation {
            say(&format!("  fix: {fix}"));
        }
    }
    print_safety(report);
    print_conflicts(report);
    if report.plan.is_empty() {
        say("nothing to do");
        return;
    }
    say("plan:");
    for op in &report.plan.ops {
        say(&format!("  - {}", op.description));
    }
}

/// What this apply cannot write and why. A conflict plans no op, so
/// without this the run ends on "nothing to do" while the thing the user
/// asked for sits blocked with the reason never printed.
///
/// Every conflict is printed, held-back items included. Their rows are not
/// the safety section said twice: they carry what happens to the copy
/// already installed — moved to the trash, or kept because the user's
/// edits are in it and still standing in the way of the accepted content.
pub fn print_conflicts(report: &EngineReport) {
    for row in &report.drift {
        if row.state != kendex_core::engine::DriftState::Conflict {
            continue;
        }
        say(&format!(
            "conflict: {} {} for {}: {}",
            row.kind.name(),
            row.name,
            row.harness.display_name(),
            row.detail
        ));
    }
}

/// What the safety rules found in the content this plan would write. Held
/// back items come first: they are the ones nothing will install.
///
/// A row with no findings is still printed when some rule could not run,
/// because "nothing was found" and "nothing could be looked at" are
/// different answers and only one of them is a pass.
pub fn print_safety(report: &EngineReport) {
    print_safety_rows(report, |row| {
        !row.findings.is_empty() || !row.skipped.is_empty()
    });
}

/// Only what nothing will install. A refresh regenerates what is declared
/// and says nothing about advisory findings, but an item it silently
/// declines to write is a different thing and has to be said.
pub fn print_held_back(report: &EngineReport) {
    print_safety_rows(report, |row| row.blocked());
}

fn print_safety_rows(
    report: &EngineReport,
    wanted: impl Fn(&kendex_core::engine::ItemSafety) -> bool,
) {
    let mut rows: Vec<&kendex_core::engine::ItemSafety> =
        report.safety.iter().filter(|row| wanted(row)).collect();
    rows.sort_by_key(|row| (!row.blocked(), row.safety.score));
    for row in rows {
        let held = match row.blocked() {
            true => " — held back, nothing will be installed",
            false => "",
        };
        say(&format!(
            "safety: {} {} for {} scores {}/100{held}",
            row.kind.name(),
            row.name,
            row.harness.display_name(),
            row.safety.score
        ));
        for (finding, decision) in row.findings.iter().zip(&row.decisions) {
            say(&format!(
                "  [{}] {}: {}",
                finding.severity.name(),
                finding.location,
                finding.message
            ));
            // A finding the publisher already ruled on is still printed, and
            // has to say so: a score of 100 beside seven criticals with no
            // word about who settled them reads as a bug in the checker.
            match &decision.state {
                DecisionState::AuthorDismissed {
                    reason,
                    dismissed_at,
                    source,
                } => say(&format!(
                    "    {source} reviewed this {dismissed_at} and recorded it as {} — it is reported, and does not count",
                    reason.name()
                )),
                _ => say(&format!("    fix: {}", finding.remediation)),
            }
        }
        print_skipped(row);
        if let Some(review_hash) = &row.review_hash
            && row.blocked()
        {
            say(&format!(
                "    to install it anyway, review the findings above and re-run with --allow-unsafe {}",
                kendex_core::engine::allow_unsafe_flag(&row.name, review_hash)
            ));
        }
    }
}

/// The rules that apply to this kind and had no bytes to read here.
fn print_skipped(row: &kendex_core::engine::ItemSafety) {
    let Some(first) = row.skipped.first() else {
        return;
    };
    say(&format!(
        "  not fully checked: {} rule(s) had nothing to read — {}",
        row.skipped.len(),
        first.reason
    ));
}

/// Prompted apply: `--yes` skips the prompt; a non-tty without `--yes`
/// refuses rather than guessing.
pub fn confirm_and_execute(env: &Env, report: &EngineReport, yes: bool) -> CliResult {
    if report.plan.is_empty() {
        return Ok(());
    }
    if !yes {
        if !std::io::stdin().is_terminal() {
            return Err("refusing to apply without --yes in a non-interactive session".into());
        }
        let _ = write!(std::io::stderr(), "apply? [y/N] ");
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !matches!(answer.trim(), "y" | "Y" | "yes") {
            return Err("apply cancelled".into());
        }
    }
    let outcome = kendex_core::apply::execute(env, &report.plan, None)?;
    say(&format!("applied {} change(s)", outcome.applied));
    Ok(())
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

pub fn is_legacy(error: &CoreError) -> bool {
    matches!(
        error,
        CoreError::LegacyManifest { .. } | CoreError::LegacyLock { .. }
    )
}
