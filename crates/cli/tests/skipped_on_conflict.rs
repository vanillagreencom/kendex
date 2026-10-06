//! How a run with no terminal ends when a package it was asked for is
//! skipped on conflict: an item named, a member of a set named, or a
//! package one of those requires. Automation reads the exit, so a skip
//! of any of those ends on its own status and names each item; a skip of
//! something nobody asked for this run, or of a copy a retired set
//! keeps, leaves the exit as it was.
#![cfg(unix)]

use crate::pty::{Stderr, conversation};
use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

/// The status `kendex_cli`'s `SkippedOnConflict` exits with; the line
/// automation keys on is `skipped-on-conflict=<kind> <name>`, every one
/// spelled alike under an `Error: partial-install skipped=<count>`
/// headline.
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

/// A catalog where `lead` requires `orch`, `orch` requires `review-gate`,
/// the set `gate` carries `review-gate`, and `linear` and `notes` stand
/// alone. `twin` ships the name a switched-off copy is kept under, so
/// every tool refuses to render it.
fn catalog(home: &Path) {
    let catalog = home.join("catalog");
    for (name, dependencies) in [
        ("lead", "dependencies:\n  required: [orch]\n"),
        ("orch", "dependencies:\n  required: [review-gate]\n"),
        ("review-gate", ""),
        ("linear", ""),
        ("notes", ""),
        ("twin", ""),
    ] {
        write(
            &catalog.join(format!("skills/{name}/SKILL.md")),
            &format!(
                "---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nUpstream.\n"
            ),
        );
    }
    write(&catalog.join("skills/twin/SKILL.md.disabled"), "Off.\n");
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

/// The keyed lines a run named, in the order it printed them: a line
/// that opens on the key, as a script anchoring on it reads it.
fn named(printed: &str) -> Vec<String> {
    printed
        .lines()
        .filter_map(|line| line.strip_prefix("skipped-on-conflict="))
        .map(str::to_owned)
        .collect()
}

/// The refusal's headline and the keyed lines under it, exactly as
/// printed, or nothing for a run that printed no headline.
fn refusal(printed: &str, items: usize) -> Vec<&str> {
    printed
        .lines()
        .skip_while(|line| !line.starts_with("Error: partial-install"))
        .take(items + 1)
        .collect()
}

/// The run a row judges: an add naming these items, which prefixes the
/// catalog and the harness itself, or an apply of what the manifest
/// declares.
enum Run {
    Add(&'static [&'static str]),
    Apply,
}

struct Row {
    case: &'static str,
    /// Hand-made files in the way before anything runs.
    in_the_way: &'static [&'static str],
    /// Adds before the one judged, each with the status it ends on.
    before: &'static [(&'static [&'static str], i32)],
    /// Installed skills the person edits once the adds before have run.
    edited: &'static [&'static str],
    /// Skills whose next rendering every tool refuses, from the moment
    /// the adds before have run.
    refused: &'static [&'static str],
    run: Run,
    status: i32,
    names: &'static [&'static str],
    lands: &'static [&'static str],
}

const ORCH: &[&str] = &["--skill", "orch"];
const LINEAR: &[&str] = &["--skill", "linear"];

/// One row per way an item comes to be asked for, and the ways one is
/// not: an empty repository, a skip of a package or set an earlier add
/// declared, and an item held back by the person's own edits. A refused
/// rendering is a skip even where those edits keep the earlier copy.
#[test]
#[allow(clippy::unwrap_used, clippy::too_many_lines)]
fn a_run_with_no_terminal_fails_on_a_skip_of_what_it_was_asked_for() {
    let rows = [
        Row {
            case: "control: empty repository",
            in_the_way: &[],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(ORCH),
            status: 0,
            names: &[],
            lands: &["orch", "review-gate"],
        },
        Row {
            case: "a required dependency of a named skill",
            in_the_way: &["review-gate"],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(ORCH),
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &["orch"],
        },
        Row {
            case: "a dependency two requirements down",
            in_the_way: &["review-gate"],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(&["--skill", "lead"]),
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &["lead", "orch"],
        },
        Row {
            case: "a named skill",
            in_the_way: &["review-gate"],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(&["--skill", "review-gate,linear"]),
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &["linear"],
        },
        Row {
            case: "two named skills",
            in_the_way: &["review-gate", "notes"],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(&["--skill", "review-gate,notes,linear"]),
            status: SKIPPED,
            names: &["skill notes", "skill review-gate"],
            lands: &["linear"],
        },
        Row {
            case: "a named skill every tool refuses to render",
            in_the_way: &[],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(&["--skill", "twin,linear"]),
            status: SKIPPED,
            names: &["skill twin"],
            lands: &["linear"],
        },
        Row {
            case: "a member of a named set",
            in_the_way: &["review-gate"],
            before: &[],
            edited: &[],
            refused: &[],
            run: Run::Add(&["--bundle", "gate"]),
            status: SKIPPED,
            names: &["skill review-gate"],
            lands: &[],
        },
        Row {
            case: "a package an earlier add declared",
            in_the_way: &["notes"],
            before: &[(&["--skill", "notes"], SKIPPED)],
            edited: &[],
            refused: &[],
            run: Run::Add(LINEAR),
            status: 0,
            names: &[],
            lands: &["linear"],
        },
        Row {
            case: "a member of a set an earlier add declared",
            in_the_way: &["review-gate"],
            before: &[(&["--bundle", "gate"], SKIPPED)],
            edited: &[],
            refused: &[],
            run: Run::Add(LINEAR),
            status: 0,
            names: &[],
            lands: &["linear"],
        },
        Row {
            case: "a requirement of a skill an earlier add declared",
            in_the_way: &["review-gate"],
            before: &[(ORCH, SKIPPED)],
            edited: &[],
            refused: &[],
            run: Run::Add(LINEAR),
            status: 0,
            names: &[],
            lands: &["linear", "orch"],
        },
        Row {
            case: "a named skill held back by the person's own edits",
            in_the_way: &[],
            before: &[(LINEAR, 0)],
            edited: &["linear"],
            refused: &[],
            run: Run::Add(LINEAR),
            status: 0,
            names: &[],
            lands: &[],
        },
        Row {
            case: "a declared skill held back by the person's own edits",
            in_the_way: &[],
            before: &[(LINEAR, 0)],
            edited: &["linear"],
            refused: &[],
            run: Run::Apply,
            status: 0,
            names: &[],
            lands: &[],
        },
        Row {
            case: "a named skill refused over the person's own edits",
            in_the_way: &[],
            before: &[(LINEAR, 0)],
            edited: &["linear"],
            refused: &["linear"],
            run: Run::Add(LINEAR),
            status: SKIPPED,
            names: &["skill linear"],
            lands: &[],
        },
        Row {
            case: "a declared skill refused over the person's own edits",
            in_the_way: &[],
            before: &[(LINEAR, 0)],
            edited: &["linear"],
            refused: &["linear"],
            run: Run::Apply,
            status: SKIPPED,
            names: &["skill linear"],
            lands: &[],
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
        for (items, status) in row.before {
            let earlier = add(items);
            assert_eq!(
                earlier.status.code(),
                Some(*status),
                "{}: {}",
                row.case,
                said(&earlier)
            );
        }
        for name in row.edited {
            let installed = project.join(format!(".claude/skills/{name}/SKILL.md"));
            let body = fs::read_to_string(&installed).unwrap();
            fs::write(&installed, format!("{body}Mine.\n")).unwrap();
        }
        for name in row.refused {
            write(
                &catalog.join(format!("skills/{name}/SKILL.md.disabled")),
                "Off.\n",
            );
        }
        let output = match row.run {
            Run::Add(items) => add(items),
            Run::Apply => kendex(&home, &project, &["apply", "--yes", "--leave"]),
        };
        let printed = said(&output);
        assert_eq!(
            output.status.code(),
            Some(row.status),
            "{}: {printed}",
            row.case
        );
        assert_eq!(named(&printed), row.names, "{}: {printed}", row.case);
        let expected: Vec<String> = match row.names.len() {
            0 => Vec::new(),
            count => std::iter::once(format!("Error: partial-install skipped={count}"))
                .chain(
                    row.names
                        .iter()
                        .map(|name| format!("skipped-on-conflict={name}")),
                )
                .collect(),
        };
        assert_eq!(
            refusal(&printed, row.names.len()),
            expected,
            "{}: {printed}",
            row.case
        );
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
        for name in row.edited {
            let body = fs::read_to_string(project.join(format!(".claude/skills/{name}/SKILL.md")));
            assert!(
                body.is_ok_and(|body| body.ends_with("Mine.\n")),
                "{}: the edit to {name} was not kept",
                row.case
            );
        }
    }
}

/// A retired set keeps `linear` on Claude Code while a live set renders
/// it on Codex, and the person edits the kept Claude Code copy. Nothing
/// renders a retired set's copy again, so its conflict skips nothing the
/// run was asked for: an apply of the manifest and an add naming the live
/// set both end on their own status.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_a_retired_set_keeps_is_no_skip_of_a_live_set() {
    for (case, run) in [
        ("apply", Run::Apply),
        ("add the live set", Run::Add(&["--bundle", "live"])),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        catalog(&home);
        let catalog = home.join("catalog");
        let sets = "[bundles.old]\nskills = [\"linear\"]\n[bundles.live]\nskills = [\"linear\"]\n";
        write(&catalog.join("kendex.toml"), sets);
        let project = home.join("dev/app");
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n[bundles.old]\nsource = \"cat\"\nharnesses = [\"claude\"]\n[bundles.live]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
                test_util::source_path(&catalog)
            ),
        );
        let applied = kendex(&home, &project, &["apply", "--yes", "--leave"]);
        assert_eq!(applied.status.code(), Some(0), "{case}: {}", said(&applied));
        assert!(
            installed(&project, "linear"),
            "{case}: the fixture installs linear"
        );

        write(
            &catalog.join("kendex.toml"),
            "[bundles.live]\nskills = [\"linear\"]\n[retired.bundles]\nold = \"\"\n",
        );
        let copy = project.join(".claude/skills/linear/SKILL.md");
        let body = fs::read_to_string(&copy).unwrap();
        fs::write(&copy, format!("{body}Mine.\n")).unwrap();

        let output = match run {
            Run::Apply => kendex(&home, &project, &["apply", "--yes", "--leave"]),
            Run::Add(items) => {
                let mut args = vec!["add", catalog.to_str().unwrap(), "--harness", "codex"];
                args.extend(items);
                args.extend(["--yes", "--leave"]);
                kendex(&home, &project, &args)
            }
        };
        let printed = said(&output);
        assert_eq!(output.status.code(), Some(0), "{case}: {printed}");
        assert_eq!(named(&printed), Vec::<String>::new(), "{case}: {printed}");
        assert!(
            fs::read_to_string(&copy).is_ok_and(|body| body.ends_with("Mine.\n")),
            "{case}: the kept copy was rewritten"
        );
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
