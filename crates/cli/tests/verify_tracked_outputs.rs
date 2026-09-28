//! `kendex verify`: a path an installed agent declares as tracked output
//! that the project's repository ignores fails the run, on a row naming
//! the agent, the path and the rule, and the same declaration in a project
//! that leaves the path tracked fails nothing.
//!
//! The must-fail control is `tracked_output_rows` skipping every standing:
//! the ignored row then prints nothing and the run closes clean.
#![cfg(unix)]

use std::path::PathBuf;

use kendex_core::attest::{Document, State};

use super::verify_records::{commit, kendex, repository, said, write};
use crate::test_util::{rooted, source_path};

const PLANNER: &str = "---\nname: planner\ndescription: plans\ntracked-outputs: [docs/plans/<slug>.md]\n---\n\nPlan it.\n";

/// A project with the planner installed from a path catalog, its
/// repository ignoring what `ignore` names. Installed and committed.
#[allow(clippy::unwrap_used)]
fn installed(ignore: &str) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    let project = home.join("project");
    write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
    write(&catalog.join("agents/planner.md"), PLANNER);
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[agents.planner]\nsource = \"cat\"\n",
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

#[test]
#[allow(clippy::unwrap_used)]
fn an_ignored_tracked_output_fails_verify_and_a_tracked_one_does_not() {
    for (ignore, expected) in [
        (
            "docs/plans/\n",
            Some("tracked output docs/plans/<slug>.md is ignored (.gitignore:1:docs/plans/)"),
        ),
        ("target/\n", None),
    ] {
        let (_tmp, home, project) = installed(ignore);
        let output = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
        let document: Document = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|error| panic!("no document: {error}\n{}", said(&output)));
        let rows: Vec<_> = document
            .rows
            .iter()
            .filter(|row| row.kind == "tracked-output")
            .collect();
        match expected {
            Some(detail) => {
                assert!(!output.status.success(), "{ignore:?}: {}", said(&output));
                assert!(!document.clean, "{ignore:?}");
                assert_eq!(rows.len(), 1, "{ignore:?}: {rows:?}");
                assert_eq!(rows[0].name, "planner");
                assert_eq!(rows[0].state, State::Failed);
                assert!(
                    rows[0].detail.as_deref().unwrap().starts_with(detail),
                    "{:?}",
                    rows[0].detail
                );
                assert!(said(&output).contains(detail), "{}", said(&output));
            }
            None => {
                assert!(output.status.success(), "{ignore:?}: {}", said(&output));
                assert!(document.clean, "{ignore:?}");
                assert_eq!(rows, Vec::<&kendex_core::attest::Row>::new(), "{ignore:?}");
            }
        }
    }
}
