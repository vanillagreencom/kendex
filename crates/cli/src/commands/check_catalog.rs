//! `kendex check --catalog`: the authoring passes live in
//! `kendex_core::check_catalog`; this prints what they found, as lines or
//! as the versioned JSON envelope a CI step consumes.
//!
//! Exit code is the whole point: 1 when something is broken, and with
//! `--strict`, 1 for structural advisories too. Safety findings are
//! advisory everywhere and never fail the run.

use std::path::Path;

use kendex_core::check_catalog::{CHECK_SCHEMA, CatalogCheck, CheckFinding};
use kendex_core::decision::Need;
use kendex_core::source_read::SealedSource;

use super::advisory::advisory_lines;
use super::{CliResult, answer};
use crate::ui::{self, Span, Status, Style};

pub fn run(catalog: &Path, strict: bool, json: bool) -> CliResult {
    let sealed = SealedSource::open(catalog)?;
    let display = catalog
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "marketplace".to_owned());
    let report = kendex_core::check_catalog::check(&sealed, &display)?;
    let failing = report.failing(strict);
    match json {
        true => {
            let config = kendex_core::source::source_config(&sealed, &display)?;
            machine(
                &report,
                failing == 0,
                &kendex_core::source::bundles::names(&config),
            )?;
        }
        false => ui::stderr(&lines(&ui::style(), &report, failing)),
    }
    match failing {
        0 => Ok(()),
        count => {
            Err(format!("{count} problem(s) must be fixed before this marketplace installs").into())
        }
    }
}

/// The machine envelope. serde_json preserves insertion order, so the
/// written order here is the field order a consumer sees.
fn machine(report: &CatalogCheck, ok: bool, bundles: &[String]) -> CliResult {
    let tally = report.tally();
    answer(&serde_json::to_string_pretty(&serde_json::json!({
        "schema": CHECK_SCHEMA,
        "findings": report.findings().collect::<Vec<CheckFinding>>(),
        "breakage": tally.breakage,
        "safety_findings": tally.findings,
        "ok": ok,
        "bundles": bundles,
    }))?);
    Ok(())
}

/// One finding and its fix. The line rides beside the path here rather
/// than inside it: `file` is what something opens, and `PATH:LINE` is how a
/// terminal spells a place.
fn finding_lines(style: &Style, finding: &CheckFinding) -> Vec<String> {
    let at = match finding.line {
        Some(line) => format!("{}:{line}", finding.file),
        None => finding.file.clone(),
    };
    let mut lines = style.report_row(
        Status::of(need(finding)),
        &[
            Span::Prose(&format!("[{}] {}: ", finding.severity, finding.pass)),
            Span::Command(&at),
            Span::Prose(&format!(": {}", finding.message)),
        ],
        "",
    );
    lines.extend(style.report_detail(&[Span::Prose("fix: "), Span::Prose(&finding.fix)], "    "));
    lines
}

/// What a structural finding asks of the author: breakage keeps the
/// marketplace from installing, a warning is theirs to weigh, and a note
/// is the check saying what it could not read.
fn need(finding: &CheckFinding) -> Need {
    match (finding.is_breakage(), finding.is_note()) {
        (true, _) => Need::Blocked,
        (false, true) => Need::Notice,
        (false, false) => Need::Decision,
    }
}

/// The structural pass prints first and carries a fix line: a loader that
/// will not hold an item is a thing the author does something about. The
/// safety pass prints a score for every item and a line for every finding,
/// fix lines left out — the score decides nothing here either. The tally
/// closes the run, a failure where `failing` findings fail it.
fn lines(style: &Style, report: &CatalogCheck, failing: usize) -> Vec<String> {
    let mut lines = Vec::new();
    for finding in &report.catalog {
        lines.extend(finding_lines(style, finding));
    }
    for item in &report.items {
        for finding in &item.structural {
            lines.extend(finding_lines(style, finding));
        }
        lines.extend(advisory_lines(
            style,
            item.kind,
            &item.name,
            &item.file,
            &item.advisory,
        ));
    }
    let tally = report.tally();
    let status = match (failing, tally.advisory + tally.findings) {
        (0, 0) => Status::Done,
        (0, _) => Status::of(Need::Decision),
        (_, _) => Status::of(Need::Blocked),
    };
    lines.extend(style.summary(
        status,
        &format!(
            "{} package(s): {} breakage, {} advisory, {} safety finding(s)",
            tally.items, tally.breakage, tally.advisory, tally.findings
        ),
    ));
    lines
}

#[cfg(test)]
mod tests;
