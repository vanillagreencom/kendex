//! How a run with no terminal ends when a package it was asked for is
//! skipped on conflict: an item named, a member of a set named, or a
//! package one of those requires. Automation reads the exit, so a skip
//! of any of those ends on its own status and names each item; a skip of
//! something nobody asked for this run leaves the exit as it was.
#![cfg(unix)]

use crate::pty::{Stderr, conversation};
use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

/// The status `kendex_cli`'s `SkippedOnConflict` exits with; the line
/// automation keys on is `skipped-on-conflict=<kind> <name>`.
const SKIPPED: i32 = 3;

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A catalog where `orch` requires `review-gate`, the set `gate` carries
/// `review-gate`, and `linear` and `notes` stand alone.
fn catalog(home: &Path) {
    let catalog = home.join("catalog");
    for (name, dependencies) in [
        ("orch", "dependencies:\n  required: [review-gate]\n"),
        ("review-gate", ""),
        ("linear", ""),
        ("notes", ""),
    ] {
        write(
            &catalog.join(format!("skills/{name}/SKILL.md")),
            &format!(
                "---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nUpstream.\n"
            ),
        );
    }
    write(
        &catalog.join("kendex.toml"),
        "[bundles.gate]\ndescription = \"the gate set\"\nskills = [\"review-gate\"]\n",
    );
}

/// Files kendex did not write in the folder Claude Code's skills are
/// shared through, where `name` installs.
fn unmanaged(project: &Path, name: &str) {
    write(
        &project.join(format!(".agents/skills/{name}/SKILL.md")),
        &format!("---\nname: {name}\ndescription: mine\n---\nWritten by hand.\n"),
    );
}

fn installed(project: &Path, name: &str) -> bool {
    fs::read_to_string(project.join(format!(".claude/skills/{name}/SKILL.md")))
        .is_ok_and(|body| body.contains("Upstream."))
}

/// Whether the hand-made files in the way are still there, untouched.
fn kept(project: &Path, name: &str) -> bool {
    fs::read_to_string(project.join(format!(".agents/skills/{name}/SKILL.md")))
        .is_ok_and(|body| body.contains("Written by hand."))
}

/// The keyed lines a run named, in the order it printed them.
fn named(printed: &str) -> Vec<String> {
    printed
        .lines()
        .filter_map(|line| {
            line.split_once("skipped-on-conflict=")
                .map(|(_, item)| item.to_owned())
        })
        .collect()
}

struct Row {
    case: &'static str,
    /// Hand-made files in the way before anything runs.
    in_the_way: &'static [&'static str],
    /// Runs before the one judged, each skipping what it names.
    before: &'static [&'static [&'static str]],
    run: &'static [&'static str],
    status: i32,
    names: &'static [&'static str],
    lands: &'static [&'static str],
}

const ORCH: &[&str] = &["--skill", "orch"];

/// One row per way an item comes to be asked for, and the two that are
/// not: an empty repository, and a skip of a package an earlier add
/// declared. `add` rows prefix the catalog and the harness themselves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_with_no_terminal_fails_on_a_skip_of_what_it_was_asked_for() {
    let rows = [
        Row {
            case: "control: empty repository",
            in_the_way: &[],
            before: &[],
            run: ORCH,
            status: 0,
            names: &[],
            lands: &["orch", "review-gate"],
        },
        Row {
            case: "a required dependency of a named skill",
            in_the_way: &["review-gate"],
            before: &[],
            run: ORCH,
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &["orch"],
        },
        Row {
            case: "a named skill",
            in_the_way: &["review-gate"],
            before: &[],
            run: &["--skill", "review-gate,linear"],
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &["linear"],
        },
        Row {
            case: "a member of a named set",
            in_the_way: &["review-gate"],
            before: &[],
            run: &["--bundle", "gate"],
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &[],
        },
        Row {
            case: "a package an earlier add declared",
            in_the_way: &["notes"],
            before: &[&["--skill", "notes"]],
            run: &["--skill", "linear"],
            status: 0,
            names: &[],
            lands: &["linear"],
        },
    ];
    for row in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        catalog(&home);
        let project = home.join("dev/app");
        fs::create_dir_all(project.join(".claude")).unwrap();
        for name in row.in_the_way {
            unmanaged(&project, name);
        }
        let catalog = home.join("catalog");
        let add = |items: &[&str]| {
            let mut args = vec!["add", catalog.to_str().unwrap(), "--harness", "claude"];
            args.extend(items);
            args.extend(["--yes", "--leave"]);
            kendex(&home, &project, &args)
        };
        for items in row.before {
            let earlier = add(items);
            assert_eq!(
                earlier.status.code(),
                Some(SKIPPED),
                "{}: {}",
                row.case,
                said(&earlier)
            );
        }
        let output = add(row.run);
        let printed = said(&output);
        assert_eq!(
            output.status.code(),
            Some(row.status),
            "{}: {printed}",
            row.case
        );
        assert_eq!(named(&printed), row.names, "{}: {printed}", row.case);
        for name in row.lands {
            assert!(
                installed(&project, name),
                "{}: {name} not installed",
                row.case
            );
        }
        for name in row.in_the_way {
            assert!(kept(&project, name), "{}: {name} was taken over", row.case);
        }
    }
}

/// `apply` judges what the manifest declares the same way, and the add
/// that failed on the skip saved the manifest, so the take-over that
/// settles it is `apply --replace-unmanaged`.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_fails_on_the_same_skip_and_the_take_over_settles_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    catalog(&home);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    unmanaged(&project, "review-gate");
    let catalog = home.join("catalog");
    let args = [
        "add",
        catalog.to_str().unwrap(),
        "--harness",
        "claude",
        "--skill",
        "orch",
        "--yes",
        "--leave",
    ];
    let added = kendex(&home, &project, &args);
    assert_eq!(added.status.code(), Some(SKIPPED), "{}", said(&added));

    let applied = kendex(&home, &project, &["apply", "--yes", "--leave"]);
    let printed = said(&applied);
    assert_eq!(applied.status.code(), Some(SKIPPED), "{printed}");
    assert_eq!(named(&printed), ["skill review-gate"], "{printed}");

    let taken = kendex(
        &home,
        &project,
        &["apply", "--yes", "--leave", "--replace-unmanaged"],
    );
    assert_eq!(taken.status.code(), Some(0), "{}", said(&taken));
    assert!(installed(&project, "review-gate"));
    assert!(installed(&project, "orch"));
}

/// The same skip with a terminal on stdin: a person reads the ledger and
/// the conflict lines, and the run's exit is what it was before.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_at_a_terminal_ends_as_it_did() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    catalog(&home);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    unmanaged(&project, "review-gate");
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args([
            "add",
            home.join("catalog").to_str().unwrap(),
            "--harness",
            "claude",
            "--skill",
            "orch",
            "--yes",
            "--leave",
        ])
        .current_dir(&project)
        .env_clear()
        .envs(test_util::fixture_env(&home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off");
    let output = conversation(command, &[], Stderr::Pipe);
    let printed = said(&output);
    assert_eq!(output.status.code(), Some(0), "{printed}");
    assert_eq!(named(&printed), Vec::<String>::new(), "{printed}");
    assert!(installed(&project, "orch"));
    assert!(kept(&project, "review-gate"));
}
