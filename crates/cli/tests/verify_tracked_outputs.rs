//! `kendex verify`: a path an installed agent declares as tracked output
//! that the project's repository ignores is a warning row naming the
//! agent, the path and the rule, counted apart on the closing line, and
//! the run stays clean; under `--strict` the same row fails the run. The
//! same declaration in a project that leaves the path tracked makes no
//! row; a declared path git cannot judge fails the run with the scope
//! named as not checked; and an agent no harness in the project takes,
//! Antigravity keeping agents global only, writes nowhere and is held to
//! nothing. The rolling consumer refresh runs its own verify line under
//! `set -e` and passes on a project with the warning.
//!
//! The must-fail controls are `tracked_output_rows` skipping every
//! standing, which leaves the ignored rows without a row; answering
//! `Warnings::Warn` whatever `--strict` asked, which leaves the strict row
//! clean; its fail branch printing a warning line, which leaves the strict
//! row without its failed line; its warning branch counting into
//! `outputs_failed`, which fails the warned run and the consumer refresh;
//! `head` dropping the warning count, which leaves the warned closing line
//! without it; `State::Warning` or `State::Failed` serialized under another
//! name, which leaves the row's wire `state` off its version-1 literal; its error branch dropping the `outputs_failed` count, which
//! leaves the unjudged row clean; the engine recording an agent it placed
//! nowhere, which gives the unplaced row a tracked-output row; and
//! `--strict` added to the verify line of `refresh-consumer.sh`, which
//! fails the consumer refresh.
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
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"{harness}\"]\nmethod = \"copy\"\n[agents.planner]\nsource = \"cat\"\n",
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
    /// One warning row whose detail, and the `warning: ` line on stderr,
    /// carries this text; a clean run whose closing line counts it apart.
    Warned(&'static str),
    /// One failed row whose detail, and the `✗ ` line on stderr, carries
    /// this text and no `warning: ` line; a failed run counting it among
    /// the other rows.
    Failed(&'static str),
    /// No row, and a clean run.
    Tracked,
    /// No row, a failed run, and stderr saying the scope's tracked
    /// outputs were not checked.
    Unjudged,
    /// No row and no tracked-output line: the agent is installed nowhere.
    /// The run fails on its gap, which is not this surface's to judge.
    Unplaced,
}

/// The one tracked-output row a run over an ignored path makes.
#[allow(clippy::unwrap_used)]
fn one_row(rows: &[&Row], state: State, detail: &str) {
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].name, "planner");
    assert_eq!(rows[0].state, state);
    assert!(
        rows[0].detail.as_deref().unwrap().starts_with(detail),
        "{:?}",
        rows[0].detail
    );
}

/// The `state` of every tracked-output row as the JSON spells it, read
/// apart from [`State`] so a renamed variant cannot move the version-1
/// wire value unnoticed.
#[allow(clippy::unwrap_used)]
fn wire_states(stdout: &[u8]) -> Vec<String> {
    let document: serde_json::Value = serde_json::from_slice(stdout).unwrap();
    document["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["kind"] == "tracked-output")
        .map(|row| row["state"].as_str().unwrap().to_owned())
        .collect()
}

const IGNORED: &str = "tracked output docs/plans/<slug>.md is ignored (.gitignore:1:docs/plans/)";

#[test]
#[allow(clippy::unwrap_used)]
fn an_ignored_tracked_output_warns_and_fails_only_under_strict() {
    for (harness, declared, ignore, strict, expected) in [
        (
            "claude",
            "docs/plans/<slug>.md",
            "docs/plans/\n",
            false,
            Expected::Warned(IGNORED),
        ),
        (
            "claude",
            "docs/plans/<slug>.md",
            "docs/plans/\n",
            true,
            Expected::Failed(IGNORED),
        ),
        (
            "claude",
            "docs/plans/<slug>.md",
            "target/\n",
            false,
            Expected::Tracked,
        ),
        (
            "claude",
            "../outside.md",
            "target/\n",
            false,
            Expected::Unjudged,
        ),
        (
            "antigravity",
            "docs/plans/<slug>.md",
            "docs/plans/\n",
            false,
            Expected::Unplaced,
        ),
    ] {
        let (_tmp, home, project) = installed(harness, declared, ignore);
        let mut args = vec!["verify", "--scope", "project", "--json"];
        if strict {
            args.push("--strict");
        }
        let output = kendex(&home, &project, &args);
        let document: Document = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|error| panic!("no document: {error}\n{}", said(&output)));
        let stderr = String::from_utf8_lossy(&output.stderr);
        let rows: Vec<&Row> = document
            .rows
            .iter()
            .filter(|row| row.kind == "tracked-output")
            .collect();
        match expected {
            Expected::Warned(detail) => {
                assert!(output.status.success(), "{declared}: {}", said(&output));
                assert!(document.clean, "{declared}");
                one_row(&rows, State::Warning, detail);
                assert_eq!(wire_states(&output.stdout), ["warning"]);
                assert!(
                    stderr.contains(&format!("warning: agent planner: {detail}")),
                    "{stderr}"
                );
                assert!(stderr.contains("0 failed; 1 warning\n"), "{stderr}");
            }
            Expected::Failed(detail) => {
                assert!(!output.status.success(), "{declared}: {}", said(&output));
                assert!(!document.clean, "{declared}");
                one_row(&rows, State::Failed, detail);
                assert_eq!(wire_states(&output.stdout), ["failed"]);
                assert!(
                    stderr.contains(&format!("✗ agent planner: {detail}")),
                    "{stderr}"
                );
                assert!(!stderr.contains("warning: agent planner"), "{stderr}");
                assert!(
                    stderr.contains("0 failed; 1 other row failed\n"),
                    "{stderr}"
                );
            }
            Expected::Tracked => {
                assert!(output.status.success(), "{declared}: {}", said(&output));
                assert!(document.clean, "{declared}");
                assert_eq!(rows, Vec::<&Row>::new(), "{declared}");
                assert!(!stderr.contains("warning"), "{stderr}");
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

/// The review-gate consumer refresh runs `kendex verify` under `set -e`
/// between its refresh and its commit. Its own verify line, read from the
/// script and run under the same shell options, passes on a project that
/// ignores a declared tracked output.
#[test]
#[allow(clippy::unwrap_used)]
fn a_consumer_refresh_passes_on_an_ignored_tracked_output() {
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../refresh/refresh-consumer.sh");
    let text = std::fs::read_to_string(&script).unwrap();
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with("kendex verify"))
        .collect();
    assert_eq!(lines.len(), 1, "{}: {lines:?}", script.display());
    let (_tmp, home, project) = installed("claude", "docs/plans/<slug>.md", "docs/plans/\n");
    let bin = std::path::Path::new(env!("CARGO_BIN_EXE_kendex"))
        .parent()
        .unwrap();
    let path = std::env::join_paths(std::iter::once(bin.to_path_buf()).chain(
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
    ))
    .unwrap();
    let output = std::process::Command::new("bash")
        .args(["-euo", "pipefail", "-c", lines[0]])
        .current_dir(&project)
        .env_clear()
        .envs(crate::test_util::fixture_env(&home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", path)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{}: {}", lines[0], said(&output));
    assert!(
        stderr.contains(&format!("warning: agent planner: {IGNORED}")),
        "{stderr}"
    );
}
