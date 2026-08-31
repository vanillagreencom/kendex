//! `kendex check --catalog`: the authoring passes live in
//! `kendex_core::check_catalog`; this prints what they found, as lines or
//! as the versioned JSON envelope a CI step consumes.
//!
//! Exit code is the whole point: 1 when something is broken, and with
//! `--strict`, 1 for structural advisories too. Safety findings are
//! advisory everywhere and never fail the run.

use std::path::Path;

use kendex_core::check_catalog::{CHECK_SCHEMA, CatalogCheck, CheckFinding};
use kendex_core::source_read::SealedSource;

use super::engine_common::{ScoredAt, print_advisory};
use super::{CliResult, answer, say};

pub fn run(catalog: &Path, strict: bool, json: bool) -> CliResult {
    let sealed = SealedSource::open(catalog)?;
    let display = catalog
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "catalog".to_owned());
    let report = kendex_core::check_catalog::check(&sealed, &display)?;
    let failing = report.failing(strict);
    match json {
        true => machine(&report, failing == 0)?,
        false => lines(&report),
    }
    match failing {
        0 => Ok(()),
        count => {
            Err(format!("{count} problem(s) must be fixed before this catalog installs").into())
        }
    }
}

/// The machine envelope. serde_json preserves insertion order, so the
/// written order here is the field order a consumer sees.
fn machine(report: &CatalogCheck, ok: bool) -> CliResult {
    let tally = report.tally();
    answer(&serde_json::to_string_pretty(&serde_json::json!({
        "schema": CHECK_SCHEMA,
        "findings": report.findings().collect::<Vec<CheckFinding>>(),
        "breakage": tally.breakage,
        "safety_findings": tally.findings,
        "ok": ok,
    }))?);
    Ok(())
}

/// One finding and its fix. The line rides beside the path here rather
/// than inside it: `file` is what something opens, and `PATH:LINE` is how a
/// terminal spells a place.
fn say_finding(finding: &kendex_core::check_catalog::CheckFinding) {
    let at = match finding.line {
        Some(line) => format!("{}:{line}", finding.file),
        None => finding.file.clone(),
    };
    say(&format!(
        "[{}] {}: {at}: {}",
        finding.severity, finding.pass, finding.message
    ));
    say(&format!("    fix: {}", finding.fix));
}

/// The structural pass prints first and carries a fix line: a loader that
/// will not hold an item is a thing the author does something about. The
/// safety pass prints as the advisory block every other verb prints, fix
/// lines and all left out — the score decides nothing here either.
fn lines(report: &CatalogCheck) {
    for finding in &report.catalog {
        say_finding(finding);
    }
    for item in &report.items {
        for finding in &item.structural {
            say_finding(finding);
        }
        print_advisory(
            item.kind,
            &item.name,
            ScoredAt::CatalogPath(&item.file),
            &item.advisory,
        );
    }
    let tally = report.tally();
    say(&format!(
        "{} item(s): {} breakage, {} advisory, {} safety finding(s)",
        tally.items, tally.breakage, tally.advisory, tally.findings
    ));
}
