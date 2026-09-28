//! `kendex verify`: a path an installed agent declares as tracked output
//! that the project's repository ignores fails the run, on a row naming
//! the agent, the path and the rule; the same declaration in a project
//! that leaves the path tracked fails nothing; a declared path git cannot
//! judge fails the run with the scope named as not checked; and an agent
//! no harness in the project takes, Antigravity keeping agents global
//! only, writes nowhere and is held to nothing.
//!
//! The must-fail controls are `tracked_output_rows` skipping every
//! standing, which leaves the ignored row clean; dropping its stderr
//! line, which leaves the ignored row's detail only in the document; and
//! its error branch dropping the `outputs_failed` count, which leaves the
//! unjudged row clean; and the engine recording an agent it placed
//! nowhere, which gives the unplaced row a tracked-output row.
#![cfg(unix)]

use std::path::PathBuf;

use kendex_core::attest::{Document, Row, State};

use super::verify_records::{commit, kendex, repository, said, write};
use crate::test_util::{rooted, source_path};

/// A project on `harness` with a planner declaring `declared` installed
/// from a path catalog, its repository ignoring what `ignore` names.
/// Installed and committed.
#[allow(clippy::unwrap_used)]
fn installed(harness: &str, declared: &str, ignore: &str) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    let project = home.join("project");
    write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
    write(
        &catalog.join("agents/planner.md"),
        &format!(
            "---\nname: planner\ndescription: plans\ntracked-outputs: [{declared}]\n---\n\nPlan it.\n"
        ),
    );
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"{harness}\"]\nmethod = \"copy\"\n[agents.planner]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    );
    write(&project.join(".gitignore"), ignore);
    repository(&project);
    let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));
    commit(&project, "installed");
    (tmp, home, project)
}

/// What one verify run must show.
enum Expected {
    /// One failed row whose detail, and the human line on stderr, opens
    /// with this text.
    Ignored(&'static str),
    /// No row, and a clean run.
    Tracked,
    /// No row, a failed run, and stderr saying the scope's tracked
    /// outputs were not checked.
    Unjudged,
    /// No row and no tracked-output line: the agent is installed nowhere.
    /// The run fails on its gap, which is not this surface's to judge.
    Unplaced,
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_ignored_tracked_output_fails_verify_and_a_tracked_one_does_not() {
    for (harness, declared, ignore, expected) in [
        (
            "claude",
            "docs/plans/<slug>.md",
            "docs/plans/\n",
            Expected::Ignored(
                "tracked output docs/plans/<slug>.md is ignored (.gitignore:1:docs/plans/)",
            ),
        ),
        (
            "claude",
            "docs/plans/<slug>.md",
            "target/\n",
            Expected::Tracked,
        ),
        ("claude", "../outside.md", "target/\n", Expected::Unjudged),
        (
            "antigravity",
            "docs/plans/<slug>.md",
            "docs/plans/\n",
            Expected::Unplaced,
        ),
    ] {
        let (_tmp, home, project) = installed(harness, declared, ignore);
        let output = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
        let document: Document = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|error| panic!("no document: {error}\n{}", said(&output)));
        let stderr = String::from_utf8_lossy(&output.stderr);
        let rows: Vec<&Row> = document
            .rows
            .iter()
            .filter(|row| row.kind == "tracked-output")
            .collect();
        match expected {
            Expected::Ignored(detail) => {
                assert!(!output.status.success(), "{declared}: {}", said(&output));
                assert!(!document.clean, "{declared}");
                assert_eq!(rows.len(), 1, "{declared}: {rows:?}");
                assert_eq!(rows[0].name, "planner");
                assert_eq!(rows[0].state, State::Failed);
                assert!(
                    rows[0].detail.as_deref().unwrap().starts_with(detail),
                    "{:?}",
                    rows[0].detail
                );
                assert!(stderr.contains(detail), "{stderr}");
            }
            Expected::Tracked => {
                assert!(output.status.success(), "{declared}: {}", said(&output));
                assert!(document.clean, "{declared}");
                assert_eq!(rows, Vec::<&Row>::new(), "{declared}");
            }
            Expected::Unjudged => {
                assert!(!output.status.success(), "{declared}: {}", said(&output));
                assert!(!document.clean, "{declared}");
                assert_eq!(rows, Vec::<&Row>::new(), "{declared}");
                assert!(stderr.contains("tracked outputs not checked"), "{stderr}");
            }
            Expected::Unplaced => {
                assert_eq!(rows, Vec::<&Row>::new(), "{harness}");
                assert!(!stderr.contains("tracked output"), "{stderr}");
            }
        }
    }
}
