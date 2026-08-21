use std::io::{IsTerminal, Write};

use kendex_core::engine::decisions::DecisionState;
use kendex_core::engine::{DriftCause, DriftRow, DriftState, EngineReport};
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

pub fn print_report(env: &Env, report: &EngineReport) {
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

/// What this apply cannot write and why. A conflict plans no op, so
/// without this the run ends on "nothing to do" while the thing the user
/// asked for sits blocked with the reason never printed.
///
/// Every conflict is printed, held-back items included. Their rows are not
/// the safety section said twice: they carry what happens to the copy
/// already installed — moved to the trash, or kept because the user's
/// edits are in it and still standing in the way of the accepted content.
pub fn print_conflicts(env: &Env, report: &EngineReport) -> bool {
    let rows: Vec<&DriftRow> = report
        .drift
        .iter()
        .filter(|row| row.state == DriftState::Conflict)
        .collect();
    let mut replaceable = false;
    for (index, row) in rows.iter().enumerate() {
        say(&format!(
            "conflict: {} {} for {}: {}",
            row.kind.name(),
            kendex_core::names::shown(&row.name),
            row.harness.display_name(),
            conflict_detail(row)
        ));
        let Some(cause) = row.cause.filter(|cause| cause.in_the_way()) else {
            continue;
        };
        replaceable |= cause.can_replace();
        // One remedy per item, said under the last of the rows that have a
        // way out: keeping an item's files is a single move covering every
        // tool it is blocked for, and run once per tool it lands each
        // tool's copy on top of the last. Only those rows count towards
        // which is last — an item can also be edited under another tool,
        // and waiting for a row that will never print the offer loses it
        // altogether.
        let blocked = |other: &&&DriftRow| {
            other.kind == row.kind
                && other.name == row.name
                && other.cause.is_some_and(DriftCause::in_the_way)
        };
        if rows[index + 1..].iter().any(|later| blocked(&later)) {
            continue;
        }
        let item: Vec<&DriftRow> = rows.iter().filter(blocked).copied().collect();
        say(&format!("  to keep those files: {}", keep_exit(env, &item)));
    }
    let any = !rows.is_empty();
    if replaceable {
        // Once, not per row: the half that names the item differs line by
        // line and belongs on the row; the flag is the same for all of them,
        // and forty copies of it bury the paths that differ. Indented with
        // them all the same — at column 0 it reads as a heading over the
        // plan that follows, which is the plan that runs without it.
        say("  to install what kendex.toml asks for instead: kendex apply --replace-unmanaged");
    }
    any
}

/// What a conflict row says on a terminal. A row whose files were already
/// there carries the path alone — the cause is what says the rest, and only
/// a surface knows how to word it — so the sentence is written here.
pub fn conflict_detail(row: &DriftRow) -> String {
    let detail = kendex_core::names::shown(&row.detail);
    match row.cause {
        Some(DriftCause::UnmanagedContent | DriftCause::UnmanagedWrongShape) => {
            format!("{detail} already holds files kendex did not write")
        }
        // The path here is the folder the link points at, not the link:
        // that folder is the thing the reader has to decide about.
        Some(DriftCause::SharedLink) => {
            format!("{detail} is a folder kendex did not write, read through a shortcut")
        }
        _ => detail,
    }
}

/// The way out that keeps the files, spelled as the command that takes it —
/// printed to be read once and typed, so it carries the program name.
///
/// Every tool it names is one adoption can actually act through: it works
/// at a tool's own place and nowhere else, so a tool with nothing there —
/// a folder its neighbours reach by a shortcut, say — would error the
/// moment the reader followed the offer. Adoption cannot take every kind
/// either, nor a folder where one file goes or a file where a folder goes;
/// and a name a shell would read as more than one argument is never
/// printed as one, since a name may legally hold a space or a semicolon
/// and copied into a terminal that is somebody else's command. Wherever
/// nothing can be offered the files are still the reader's to keep, by
/// moving them out of the way themselves.
fn keep_exit(env: &Env, item: &[&DriftRow]) -> String {
    let mut tools: Vec<HarnessId> = Vec::new();
    for row in item {
        let keepable = row.cause.is_some_and(DriftCause::can_keep)
            && kendex_core::engine::adopt::can_keep_for(
                env,
                &row.scope,
                row.kind,
                &row.name,
                row.harness,
            );
        if keepable && !tools.contains(&row.harness) {
            tools.push(row.harness);
        }
    }
    let Some(row) = item.first() else {
        return "move them somewhere else first".to_owned();
    };
    if tools.is_empty() || !kendex_core::names::plain_argument(&row.name) {
        return "move them somewhere else first".to_owned();
    }
    let named: String = tools
        .iter()
        .map(|harness| format!(" --harness {}", harness.name()))
        .collect();
    format!("kendex adopt {} {}{named}", row.kind.name(), row.name)
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
        for (index, finding) in row.findings.iter().enumerate() {
            say(&format!(
                "  [{}] {}: {}",
                finding.severity.name(),
                finding.location,
                finding.message
            ));
            // A finding the publisher already ruled on is still printed, and
            // has to say so: a score of 100 beside seven findings with no
            // word about who settled them reads as a bug in the checker.
            //
            // `decisions[i]` speaks for `findings[i]`. If it does not, that
            // is a defect in the engine and this is the one surface whose
            // whole job is to show every finding — so it says so out loud
            // rather than dropping the line, which is what zipping the two
            // would have done.
            match row.decisions.get(index).map(|decision| &decision.state) {
                Some(DecisionState::AuthorDismissed {
                    reason,
                    dismissed_at,
                    publisher,
                }) => say(&format!(
                    "    {} reviewed this {} and recorded it as {} — it is reported, and does not count",
                    kendex_core::names::shown(publisher),
                    kendex_core::names::shown(dismissed_at),
                    reason.name()
                )),
                Some(_) => say(&format!("    fix: {}", finding.remediation)),
                None => say(&format!(
                    "    fix: {} (no decision recorded beside this finding — please report this)",
                    finding.remediation
                )),
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
