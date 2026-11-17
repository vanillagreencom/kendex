//! What a terminal gets from the verbs drawn with the design system's
//! components: no frame, verdict rows grouped, and the closing line last.

use super::*;

/// Verification draws adjacent verdict rows with no frame between them.
#[test]
#[allow(clippy::unwrap_used)]
fn one_line_verdicts_are_drawn_as_one_group() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let project = blocked_project(home);
    // A row to verify has to be installed first; the blocked item stays
    // blocked and the two that install are the clean rows.
    kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    );
    let pretty = said(&kendex(
        home,
        &project,
        "pretty",
        &["verify", "--scope", "project"],
    ));
    let ticks: Vec<&str> = pretty
        .lines()
        .filter(|line| line.contains("skill tidy ["))
        .collect();
    assert_eq!(ticks.len(), 2, "the fixture needs two clean rows: {pretty}");
    assert!(
        ticks
            .iter()
            .all(|line| line.starts_with("  ") && line.contains('✓')),
        "a verdict is not a component row: {ticks:?}\n{pretty}"
    );
}

/// JSON stays on stdout while the human verification summary uses components.
#[test]
fn verify_json_keeps_its_human_summary_out_of_stdout() {
    let output = nothing_declared(&["verify", "--json", "--scope", "project"]);
    let printed = said(&output);
    assert!(
        printed.contains("nothing installed"),
        "the fixture no longer reaches the case: {printed}"
    );
    assert!(
        printed.contains('✓') && !printed.contains('└'),
        "the summary is not a component: {printed}"
    );
    let document: serde_json::Value = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("invalid JSON: {error}"));
    assert_eq!(document["clean"], true);
}

/// The closing line is genuinely last, even when the work after the
/// writes has something to say. The snapshot pass runs once every scope
/// is written and can warn; emitted from inside the scope loop, the
/// ledger would be drawn as an ordinary block and the run would end on
/// that warning and a bare corner instead of on its outcome.
#[test]
#[allow(clippy::unwrap_used)]
fn a_warning_after_the_writes_lands_above_the_closing_ledger() {
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = &rooted(&tmp);
        let project = home.join("dev/app");
        blocked_project_at(home, &project);
        // A file where the snapshot's directory belongs, so deriving it
        // fails and the pass after the writes has a warning to print.
        let drift = Env::host_rooted(home.clone()).drift_dir();
        fs::create_dir_all(drift.parent().unwrap()).unwrap();
        fs::write(&drift, "not a directory\n").unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["refresh", "-y", "--scope", "project"],
        ));
        assert!(
            printed.contains("snapshot not derived"),
            "the fixture no longer reaches the case ({ui}): {printed}"
        );
        let lines: Vec<&str> = printed.lines().filter(|line| !line.is_empty()).collect();
        let warned = lines
            .iter()
            .position(|line| line.contains("snapshot not derived"))
            .unwrap();
        let closed = lines
            .iter()
            .rposition(|line| line.contains("refreshed"))
            .unwrap();
        assert!(
            warned < closed,
            "the warning landed under the closing line ({ui}): {printed}"
        );
    }
}
