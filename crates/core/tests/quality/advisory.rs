//! The score is advisory end to end: a plan carries the rows, and nothing
//! refuses an install over them.

use kendex_core::apply;
use kendex_core::quality::Severity;

use super::fixture::{fixture, installed, plan};

/// A critical finding is reported on the row and installs anyway — the
/// exact content the old gate held back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_critical_finding_is_reported_and_installs_anyway() {
    let f = fixture();
    let report = plan(&f);

    let hostile = report
        .safety
        .iter()
        .find(|row| row.name == "hostile")
        .unwrap();
    assert_eq!(hostile.advisory.safety.score, 75);
    assert!(
        hostile
            .advisory
            .findings
            .iter()
            .any(|finding| finding.severity == Severity::Critical),
        "{:?}",
        hostile.advisory.findings
    );
    assert!(
        hostile.advisory.quality.is_some(),
        "a skill has authored prose"
    );

    let clean = report
        .safety
        .iter()
        .find(|row| row.name == "clean")
        .unwrap();
    assert_eq!(clean.advisory.safety.score, 100);

    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "hostile"), "advisory means it installs");
    assert!(installed(&f, "clean"));
}

/// The audit reads the same rows back off disk, every installation
/// scored — the clean one is a row with nothing found, not a missing row.
#[test]
#[allow(clippy::unwrap_used)]
fn the_audit_reports_every_installed_row() {
    let f = fixture();
    let report = plan(&f);
    apply::execute(&f.env, &report.plan).unwrap();

    let rows = kendex_core::engine::observed_rows(&f.env, &f.scope).unwrap();
    let hostile = rows.iter().find(|row| row.name == "hostile").unwrap();
    assert_eq!(hostile.advisory.safety.score, 75);
    let clean = rows.iter().find(|row| row.name == "clean").unwrap();
    assert_eq!(clean.advisory.safety.score, 100);
    assert!(
        clean.advisory.findings.is_empty(),
        "{:?}",
        clean.advisory.findings
    );
    assert!(
        clean.advisory.skipped.is_empty(),
        "{:?}",
        clean.advisory.skipped
    );
}
