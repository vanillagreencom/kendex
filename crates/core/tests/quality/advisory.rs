//! The score is advisory end to end: a plan carries the rows, and nothing
//! refuses an install over them.

use kendex_core::apply;
use kendex_core::model::HarnessId;
use kendex_core::quality::Severity;

use super::fixture::{fixture, fixture_with_two_harnesses, installed, plan};

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

    let rows: Vec<_> = kendex_core::engine::observed_rows(&f.env, &f.scope)
        .unwrap()
        .into_iter()
        .filter(|row| matches!(row.name.as_str(), "clean" | "hostile"))
        .collect();
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

#[test]
#[allow(clippy::unwrap_used)]
fn installed_rows_name_the_harness_and_location_the_scanner_found() {
    let f = fixture_with_two_harnesses();
    let report = plan(&f);
    apply::execute(&f.env, &report.plan).unwrap();

    let rows: Vec<_> = kendex_core::engine::observed_rows(&f.env, &f.scope)
        .unwrap()
        .into_iter()
        .filter(|row| matches!(row.name.as_str(), "clean" | "hostile"))
        .collect();
    assert_eq!(
        rows.len(),
        2 * HarnessId::ALL.len(),
        "the scanner should return each harness that reads the installs"
    );
    for harness in HarnessId::ALL {
        let harness_dir = if harness == HarnessId::Claude {
            ".claude"
        } else {
            ".agents"
        };
        for name in ["clean", "hostile"] {
            let row = rows
                .iter()
                .find(|row| row.name == name && row.targets[0].harness == harness)
                .unwrap();
            assert_eq!(row.targets.len(), 1);
            assert!(row.targets[0].location.contains(harness_dir), "{row:?}");
        }
    }
}
