pub use super::blocked::{conflict_detail, print_conflicts, print_exits};
use std::io::{IsTerminal, Write};

use kendex_core::engine::{DriftRow, DriftState, EngineReport};
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

/// What the plan declined to do, in its own words. A note is the only
/// channel some passes have — the reserved-name move says here which file
/// it left alone and why — so a verb that prints nothing else about the
/// plan still prints these.
pub fn print_notes(report: &EngineReport) {
    for note in &report.notes {
        say(&format!("note: {note}"));
    }
}

pub fn print_report(env: &Env, report: &EngineReport) {
    print_notes(report);
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
    let blocked = print_conflicts(env, report);
    if report.plan.is_empty() {
        // "nothing to do" directly under a conflict reads as "and nothing
        // you can do" — the run has plenty to do, once the reader picks.
        say(match blocked {
            true => "nothing to do until you settle the conflicts above",
            false => "nothing to do",
        });
        return;
    }
    say("plan:");
    for op in &report.plan.ops {
        say(&format!("  - {}", op.description));
    }
}

/// Content in a managed folder that no declaration and no lock claims.
/// apply leaves it exactly where it is (invariant 6) — which is why it has
/// to be said here: seen in `list` and nowhere else, it reads as checked
/// and passing rather than as never looked at.
pub fn print_unmanaged(drift: &[DriftRow]) {
    use kendex_core::names::shown;
    let rows: Vec<&DriftRow> = drift
        .iter()
        .filter(|row| row.state == DriftState::Unmanaged)
        .collect();
    if rows.is_empty() {
        return;
    }
    say(&format!(
        "not managed: {} item{} kendex did not install and does not touch",
        rows.len(),
        if rows.len() == 1 { "" } else { "s" }
    ));
    for row in rows.iter().take(UNMANAGED_SHOWN) {
        // Names and paths read off a tree kendex did not write: printed as
        // what they are, never as the escape sequences they might hold.
        say(&format!(
            "  - {} {} [{}] {}",
            row.kind.name(),
            shown(&row.name),
            row.harness.display_name(),
            shown(&row.detail)
        ));
    }
    if rows.len() > UNMANAGED_SHOWN {
        say(&format!("  … and {} more", rows.len() - UNMANAGED_SHOWN));
    }
}

/// Enough to recognise what is there without burying the plan above it.
const UNMANAGED_SHOWN: usize = 10;

/// What the safety rules found in the content this plan would write —
/// advisory, printed beside the plan.
pub fn print_safety(report: &EngineReport) {
    let mut rows: Vec<&kendex_core::engine::ItemSafety> = report.safety.iter().collect();
    rows.sort_by_key(|row| row.advisory.safety.score);
    for row in rows {
        print_advisory(&subject(row), &row.advisory);
    }
}

/// How a planned or installed row names the package it scored. Read off
/// a catalog kendex did not write, so the name is printed as what it is.
fn subject(row: &kendex_core::engine::ItemSafety) -> String {
    format!(
        "{} {} for {}",
        row.kind.name(),
        kendex_core::names::shown(&row.name),
        row.harness.display_name()
    )
}

/// One package's advisory result, in the one shape every verb that scores
/// content prints it: the score, then each finding on a line of its own —
/// severity in words, what the rule matched, and where it fired as
/// subtext. No fix line and no prompt: the score is advisory, and a
/// finding says what was matched, not what to do about it.
///
/// The score line prints for a clean package too. The contract is a score
/// beside every package; a clean one going silent would make "scored 100"
/// and "never scored" read alike.
///
/// Severity leads the finding as a word, never as a colour: the line has
/// to carry it for a reader who has no colour, and this printer emits
/// none. Messages and locations come off files kendex did not write, so
/// each is printed as what it is rather than as an escape sequence the
/// terminal would act on; `subject` is escaped by its caller.
pub fn print_advisory(subject: &str, advisory: &kendex_core::quality::AuditResult) {
    use kendex_core::names::shown;
    say(&format!(
        "safety: {subject} scores {}/100",
        advisory.safety.score
    ));
    for finding in &advisory.findings {
        // A finding whose rule reads a config entry rather than a file has
        // no place to name; the claim still prints, without empty parens.
        let at = match finding.location.is_empty() {
            true => String::new(),
            false => format!(" ({})", shown(&finding.location)),
        };
        say(&format!(
            "  [{}] {}{at}",
            finding.severity.name(),
            shown(&finding.message)
        ));
    }
    print_skipped(advisory);
}

/// The rules that apply to this kind and had no bytes to read here.
fn print_skipped(advisory: &kendex_core::quality::AuditResult) {
    let Some(first) = advisory.skipped.first() else {
        return;
    };
    say(&format!(
        "  not fully checked: {} rule(s) had nothing to read — {}",
        advisory.skipped.len(),
        kendex_core::names::shown(&first.reason)
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
