//! Project writes in a lane stop before every write, including bootstrap.
//! Each writing verb has an unmarked must-fail control: the refusal assertion
//! rejects that run, and the package lands. Fixtures use orch's marker writer.

use std::fs;
use std::path::Path;
use std::process::Output;

use crate::test_util;
use test_util::lane::{Fixture, snapshot};

#[allow(
    clippy::expect_used,
    reason = "fixture setup and process failures fail the test"
)]
fn world() -> Fixture {
    let fixture = Fixture::new("KEN-2299");
    let catalog = fixture.root.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).expect("catalog directory");
    fs::create_dir(fixture.root.join(".claude")).expect("installed harness");
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Fixture skill\n---\nBody.\n",
    )
    .expect("catalog skill");
    let manifest = format!(
        "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n",
        test_util::source_path(&catalog)
    );
    for root in [&fixture.main, &fixture.linked] {
        fs::write(root.join("kendex.toml"), &manifest).expect("project manifest");
    }
    let env = kendex_core::env::Env::host_rooted(&fixture.root);
    let global = kendex_core::manifest::manifest_path(&env, &kendex_core::model::Scope::Global);
    fs::create_dir_all(global.parent().expect("manifest parent")).expect("global directory");
    fs::write(global, manifest).expect("global manifest");
    fixture
}

#[allow(clippy::expect_used, reason = "a failed CLI launch fails the test")]
fn kendex(fixture: &Fixture, cwd: &Path, args: &[&str]) -> Output {
    fixture
        .command(env!("CARGO_BIN_EXE_kendex"), cwd)
        .args(args)
        .output()
        .expect("kendex runs")
}

fn refusal(output: &Output) -> bool {
    let stderr = String::from_utf8_lossy(&output.stderr);
    output.status.code() == Some(1)
        && output.stdout.is_empty()
        && stderr.lines().count() == 1
        && stderr.starts_with("lane-refresh: item=KEN-2299;")
        && stderr.contains("--lane-refresh")
}

#[test]
#[allow(
    clippy::expect_used,
    reason = "fixture and machine protocol failures fail the test"
)]
fn guard_capability_answers_before_project_checks_and_bootstrap_writes() {
    // The catalog hook consumes this fixed JSON protocol. Its query also
    // works in a marked lane and one inheriting a different checkout's project.
    for location in ["main", "own-lane", "inherited-lane"] {
        let fixture = world();
        fixture.mark();
        if location == "inherited-lane" {
            fs::remove_file(fixture.linked.join("kendex.toml")).expect("inherited declaration");
        }
        let cwd = if location == "main" {
            &fixture.main
        } else {
            &fixture.linked
        };
        let before = snapshot(&fixture.root);
        let output = kendex(&fixture, cwd, &["--worktree-project-write-capability"]);
        assert!(output.status.success(), "capability exit at {location}");
        assert!(output.stderr.is_empty(), "capability stderr at {location}");
        let answer: serde_json::Value =
            serde_json::from_slice(&output.stdout).expect("capability protocol");
        assert_eq!(
            answer,
            serde_json::json!({"worktree_project_write_guard": 1})
        );
        assert_eq!(
            snapshot(&fixture.root),
            before,
            "capability wrote at {location}"
        );
    }
}

#[test]
#[allow(clippy::expect_used, reason = "fixture marker removal must succeed")]
fn every_project_writer_refuses_before_writes_and_its_unmarked_control_lands() {
    for (directory, args) in [
        (
            "",
            vec!["refresh", "--scope", "project", "--yes", "--leave"],
        ),
        ("", vec!["refresh", "--yes", "--leave"]),
        ("", vec!["refresh", "--scope", "all", "--yes", "--leave"]),
        (
            "",
            vec![
                "refresh", "--global", "--scope", "project", "--yes", "--leave",
            ],
        ),
        (
            "",
            vec!["refresh", "--project-path", "../main", "--yes", "--leave"],
        ),
        ("", vec!["apply", "--yes", "--leave"]),
        ("", vec!["apply", "--scope", "all", "--yes", "--leave"]),
        (
            "",
            vec!["updates", "--apply", "--refresh", "--yes", "--leave"],
        ),
        ("vendor", vec!["refresh", "--yes", "--leave"]),
        ("vendor", vec!["apply", "--yes", "--leave"]),
        (
            "vendor",
            vec!["updates", "--apply", "--refresh", "--yes", "--leave"],
        ),
    ] {
        let fixture = world();
        // Git clone produces a nearer repository with no project manifest.
        // The project resolver still selects the enclosing lane's manifest.
        if directory == "vendor" {
            fixture.git(
                &fixture.linked,
                &[
                    "clone",
                    "-q",
                    fixture.main.to_str().expect("fixture path"),
                    directory,
                ],
            );
        }
        let cwd = fixture.linked.join(directory);
        fixture.mark();
        let before = snapshot(&fixture.root);
        let output = kendex(&fixture, &cwd, &args);
        assert!(refusal(&output), "{directory} {args:?}: {output:?}");
        assert_eq!(
            snapshot(&fixture.root),
            before,
            "refused {directory} {args:?} wrote"
        );
        // Removing the real launch marker plants the missing guard input.
        // The very same refusal assertion must turn red for each verb.
        fs::remove_file(&fixture.marker).expect("remove lane marker");
        // A named cross-checkout write also meets the independent worktree
        // rule. Its unmarked control must run in the destination checkout.
        let control_cwd = if args.contains(&"--project-path") {
            &fixture.main
        } else {
            &cwd
        };
        let output = kendex(&fixture, control_cwd, &args);
        assert!(
            !refusal(&output),
            "must-fail control stayed green: {args:?}"
        );
        assert!(output.status.success(), "unmarked {args:?}: {output:?}");
        let written = if args.contains(&"--project-path") {
            &fixture.main
        } else {
            &fixture.linked
        };
        assert!(written.join(".claude/skills/deploy/SKILL.md").is_file());
    }
}

#[test]
#[allow(clippy::expect_used, reason = "fixture paths are valid")]
fn the_explicit_override_lands_for_every_project_writer() {
    for directory in ["", "vendor"] {
        for args in [
            vec![
                "refresh",
                "--scope",
                "project",
                "--yes",
                "--leave",
                "--lane-refresh",
            ],
            vec!["apply", "--yes", "--leave", "--lane-refresh"],
            vec!["updates", "--apply", "--yes", "--leave", "--lane-refresh"],
        ] {
            let fixture = world();
            if directory == "vendor" {
                fixture.git(
                    &fixture.linked,
                    &[
                        "clone",
                        "-q",
                        fixture.main.to_str().expect("fixture path"),
                        "vendor",
                    ],
                );
            }
            fixture.mark();
            let output = kendex(&fixture, &fixture.linked.join(directory), &args);
            assert!(output.status.success(), "override {args:?}: {output:?}");
            assert!(
                fixture
                    .linked
                    .join(".claude/skills/deploy/SKILL.md")
                    .is_file()
            );
        }
    }
}

#[test]
#[allow(clippy::expect_used, reason = "fixture CLI launches must succeed")]
fn global_writes_and_main_checkout_writes_keep_their_existing_paths() {
    for verb in ["refresh", "apply", "updates"] {
        for (target, lane_origin) in [("global", true), ("main", false), ("main", true)] {
            // Windows Known Folder home ignores fixture overrides, so global writes lack isolation.
            if cfg!(windows) && target == "global" {
                continue;
            }
            let fixture = world();
            fixture.mark();
            let mut args = vec![verb, "--yes", "--leave"];
            if verb == "updates" {
                args.push("--apply");
            }
            let cwd = if target == "main" {
                args.extend(["--scope", "project"]);
                &fixture.main
            } else {
                args.push("--global");
                &fixture.linked
            };
            let mut command = fixture.command(env!("CARGO_BIN_EXE_kendex"), cwd);
            if lane_origin {
                command.env("KENDEX_LANE_ORIGIN", &fixture.linked);
            }
            let before = snapshot(&fixture.root);
            let output = command.args(&args).output().expect("kendex runs");
            if target == "main" && lane_origin {
                assert!(refusal(&output), "moved lane {args:?}: {output:?}");
                assert_eq!(snapshot(&fixture.root), before, "moved refusal wrote");
                let output = command
                    .arg("--lane-refresh")
                    .output()
                    .expect("override runs");
                assert!(
                    output.status.success(),
                    "moved override {args:?}: {output:?}"
                );
                assert!(
                    fixture
                        .main
                        .join(".claude/skills/deploy/SKILL.md")
                        .is_file()
                );
                continue;
            }
            assert!(output.status.success(), "{target} {args:?}: {output:?}");
            assert!(
                !String::from_utf8_lossy(&output.stderr).contains("lane-refresh: item="),
                "{target} {args:?}: {output:?}"
            );
            let root = if target == "main" {
                &fixture.main
            } else {
                &fixture.root
            };
            assert!(root.join(".claude/skills/deploy/SKILL.md").is_file());
        }
    }
}

#[cfg(unix)]
#[test]
#[allow(clippy::expect_used, reason = "fixture shell and CLI must run")]
fn a_marked_lane_moving_into_main_keeps_its_origin_and_refuses_before_writes() {
    let fixture = world();
    fixture.mark();
    let before = snapshot(&fixture.root);
    let output = fixture
        .command("/bin/bash", &fixture.linked)
        .env("KENDEX_LANE_ORIGIN", &fixture.linked)
        .args([
            "-c",
            "(cd -- \"$1\" && \"$2\" refresh --scope project --yes --leave)",
            "moved-lane",
        ])
        .arg(&fixture.main)
        .arg(env!("CARGO_BIN_EXE_kendex"))
        .output()
        .expect("moved-to-main refresh runs");
    assert!(refusal(&output), "moved-to-main: {output:?}");
    assert_eq!(snapshot(&fixture.root), before, "moved refusal wrote");
}

#[test]
fn read_only_verbs_and_apply_plan_do_not_take_the_lane_refusal() {
    let fixture = world();
    fixture.mark();
    for (args, code) in [
        (vec!["apply", "--plan"], 0),
        (vec!["updates"], 0),
        (vec!["list", "--scope", "project"], 0),
        (vec!["verify", "--scope", "project"], 1),
        (
            vec!["check", "--scope", "project", "--quiet", "--report-only"],
            0,
        ),
        (vec!["refresh", "--help"], 0),
        (vec!["update", "--help"], 0),
    ] {
        let output = kendex(&fixture, &fixture.linked, &args);
        assert_eq!(output.status.code(), Some(code), "{args:?}: {output:?}");
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains("lane-refresh: item="),
            "{args:?}: {output:?}"
        );
        assert!(!fixture.linked.join(".claude/skills/deploy").exists());
    }
}

#[cfg(unix)]
#[test]
fn a_terminal_refusal_writes_no_first_run_record_or_terms() {
    let fixture = world();
    fixture.mark();
    let before = snapshot(&fixture.root);
    let mut command = fixture.command(env!("CARGO_BIN_EXE_kendex"), &fixture.linked);
    command.args(["refresh", "--scope", "project", "--yes", "--leave"]);
    let output = crate::pty::sent_to_a_terminal(command, b"");
    assert!(refusal(&output), "terminal: {output:?}");
    assert_eq!(snapshot(&fixture.root), before);
}

fn cross_checkout_refusal(output: &Output, caller: &Path, target: &Path) -> bool {
    let stderr = String::from_utf8_lossy(&output.stderr);
    // Repo prints std's canonical path; fixture roots use the Windows
    // reduction in paths::canonical. The caller must name the same directory.
    let reported_caller = stderr
        .split_once("; caller=")
        .and_then(|(_, field)| field.split_once(';'))
        .map(|(path, _)| Path::new(path));
    output.status.code() == Some(1)
        && output.stdout.is_empty()
        && stderr.lines().count() == 1
        && stderr.starts_with(&format!(
            "worktree-project-write: target={};",
            target.display()
        ))
        && reported_caller
            .and_then(|path| kendex_core::paths::canonical(path).ok())
            .zip(kendex_core::paths::canonical(caller).ok())
            .is_some_and(|(actual, expected)| actual == expected)
}

#[test]
#[allow(clippy::expect_used, reason = "fixture setup must succeed")]
#[allow(
    clippy::too_many_lines,
    reason = "one writer table shares its refusal and own/global controls"
)]
fn each_parsed_writer_refuses_an_inherited_other_checkout_and_own_global_controls_pass() {
    use std::io::Write as _;
    use std::time::Instant;
    use test_util::lane::Entry;

    // Direct stderr bypasses libtest capture so CI retains completed rows
    // even if a later row reaches the job's timeout.
    let report = |verb: &str, directory: &str, phase: &str, started: Instant| {
        writeln!(
            std::io::stderr().lock(),
            "lane-refresh-row writer={verb} directory={} phase={phase} elapsed_seconds={:.6}",
            if directory.is_empty() {
                "root"
            } else {
                directory
            },
            started.elapsed().as_secs_f64(),
        )
        .expect("row timing stderr");
    };

    // Claude Code creates linked worktrees below the main checkout's
    // project markers. Without nearer markers, the real project walk
    // selects that main checkout for every writing verb below.
    // The table owns one neutral repository and caller. Every control
    // restores all file bytes, directories, links and permissions before
    // another row can inherit its state.
    let table_started = Instant::now();
    let mut fixture = world();
    let caller = fixture.main.join(".claude/worktrees/caller");
    fs::create_dir_all(caller.parent().expect("caller parent")).expect("worktree directory");
    fs::remove_file(fixture.linked.join("kendex.toml")).expect("remove nearer marker");
    fixture.git(
        &fixture.main,
        &[
            "worktree",
            "move",
            fixture.linked.to_str().expect("fixture path"),
            caller.to_str().expect("fixture path"),
        ],
    );
    fixture.linked = caller.clone();
    for directory in ["vendor", "bare"] {
        // Git produces both nested repository forms once. Complete restoration
        // keeps their project markers absent before every inherited refusal.
        let mut clone = vec!["clone", "-q"];
        if directory == "bare" {
            clone.push("--bare");
        }
        clone.extend([fixture.main.to_str().expect("fixture path"), directory]);
        fixture.git(&caller, &clone);
    }
    let catalog = fixture.root.join("catalog");
    let reference = catalog.to_str().expect("catalog path");
    let env = kendex_core::env::Env::host_rooted(&fixture.root);
    let global = kendex_core::manifest::manifest_path(&env, &kendex_core::model::Scope::Global);
    for manifest in [fixture.main.join("kendex.toml"), global] {
        let contents = fs::read_to_string(&manifest).expect("fixture manifest");
        fs::write(
            &manifest,
            format!(
                "{contents}\n[sources.empty]\n{}\n",
                test_util::source_path(&catalog)
            ),
        )
        .expect("empty source");
    }
    let setup = kendex(
        &fixture,
        &fixture.main,
        &["apply", "--scope", "all", "--yes", "--leave"],
    );
    assert!(setup.status.success(), "writer-table setup: {setup:?}");
    for root in [&fixture.main, &fixture.root] {
        let borrowed = root.join(".claude/skills/borrowed");
        fs::create_dir_all(&borrowed).expect("adopt fixture");
        fs::write(
            borrowed.join("SKILL.md"),
            "---\nname: borrowed\ndescription: Fixture\n---\nBody.\n",
        )
        .expect("adopt bytes");
    }

    let independent = fixture.root.join("independent.git");
    fixture.git(
        &fixture.root,
        &[
            "clone",
            "-q",
            "--bare",
            fixture.main.to_str().expect("fixture path"),
            independent.to_str().expect("fixture path"),
        ],
    );

    // Each allowed writer changes declarations, installed files or
    // home state. Restore the whole owned fixture before its next
    // control so no nearer project or prior write can mask refusal.
    let baseline = snapshot(&fixture.root);
    let permissions: std::collections::BTreeMap<_, _> = baseline
        .iter()
        .filter(|(_, entry)| matches!(entry, Entry::File(_)))
        .map(|(path, _)| {
            (
                path.clone(),
                fs::metadata(fixture.root.join(path))
                    .expect("baseline file metadata")
                    .permissions(),
            )
        })
        .collect();
    let restore = || {
        let current = snapshot(&fixture.root);
        for (relative, entry) in current.iter().rev() {
            if baseline.get(relative) == Some(entry)
                || matches!(
                    (entry, baseline.get(relative)),
                    (Entry::File(_), Some(Entry::File(_)))
                )
            {
                continue;
            }
            let path = fixture.root.join(relative);
            if matches!(entry, Entry::Directory) || (cfg!(windows) && path.is_dir()) {
                fs::remove_dir(&path).expect("remove control directory");
            } else {
                fs::remove_file(&path).expect("remove control file");
            }
        }
        for (relative, entry) in &baseline {
            let path = fixture.root.join(relative);
            match entry {
                Entry::Directory => {
                    fs::create_dir_all(&path).expect("restore fixture directory");
                }
                Entry::File(bytes) => {
                    if current.get(relative) != Some(entry) {
                        fs::write(&path, bytes).expect("restore fixture file");
                    }
                    fs::set_permissions(&path, permissions[relative].clone())
                        .expect("restore file permissions");
                }
                Entry::Link(_) => {
                    assert_eq!(current.get(relative), Some(entry), "fixture link changed");
                }
            }
        }
        assert_eq!(snapshot(&fixture.root), baseline, "control state leaked");
    };
    report("table", "", "setup", table_started);

    for verb in [
        "refresh",
        "apply",
        "add",
        "bare-add",
        "remove",
        "update-pi",
        "updates",
        "pin",
        "fork",
        "adopt",
        "drift-hook",
        "source-add",
        "source-remove",
        "source-enable",
        "source-disable",
        "subscribe",
        "unsubscribe",
    ] {
        for directory in ["", "vendor", "bare"] {
            // Linux and Windows retain every layout; macOS runs each writer
            // at the root to keep this table within the CI time budget.
            if cfg!(target_os = "macos") && !directory.is_empty() {
                continue;
            }
            let row_started = Instant::now();
            report(verb, directory, "start", row_started);
            let inherited = caller.join(directory);
            report(verb, directory, "setup", row_started);
            let args = match verb {
                "refresh" | "apply" => vec![verb, "--yes", "--leave"],
                "add" => vec![
                    "add",
                    reference,
                    "--skill",
                    "deploy",
                    "--yes",
                    "--leave",
                    "--throwaway",
                ],
                "bare-add" => vec![
                    reference,
                    "--skill",
                    "deploy",
                    "--yes",
                    "--leave",
                    "--throwaway",
                ],
                "remove" => vec!["remove", "deploy", "--no-sweep", "--leave"],
                "update-pi" => vec!["update-pi", "--leave"],
                "updates" => vec!["updates", "--apply", "--yes", "--leave"],
                "pin" => vec!["pin", "skill", "deploy", "--follow", "--yes", "--leave"],
                "fork" => vec!["fork", "skill", "deploy", "--leave"],
                "adopt" => vec![
                    "adopt",
                    "skill",
                    "borrowed",
                    "--harness",
                    "claude",
                    "--leave",
                ],
                "drift-hook" => vec!["drift-hook", "--yes", "--leave"],
                "source-add" => vec!["source", "add", "extra", reference, "--leave"],
                "source-remove" => vec!["source", "remove", "empty", "--leave"],
                "source-enable" => vec!["source", "enable", "cat", "--leave"],
                "source-disable" => vec!["source", "disable", "cat", "--leave"],
                "subscribe" => vec![
                    "marketplace",
                    "subscribe",
                    reference,
                    "--name",
                    "extra",
                    "--leave",
                ],
                "unsubscribe" => vec![
                    "marketplace",
                    "unsubscribe",
                    "cat",
                    "--keep-packages",
                    "--leave",
                ],
                _ => unreachable!("writer table"),
            };
            let before = snapshot(&fixture.root);
            let output = kendex(&fixture, &inherited, &args);
            assert!(
                cross_checkout_refusal(&output, &caller, &fixture.main),
                "{verb}: {output:?}"
            );
            assert_eq!(snapshot(&fixture.root), before, "{verb} refusal wrote");

            if directory == "bare" && verb == "refresh" {
                for read in [
                    vec!["list", "--scope", "project"],
                    vec!["apply", "--plan"],
                    vec!["updates"],
                ] {
                    let output = kendex(&fixture, &inherited, &read);
                    assert!(output.status.success(), "bare read {read:?}: {output:?}");
                }
            }

            for control in ["own", "global", "independent"] {
                if (cfg!(windows) && control == "global")
                    || (control == "independent" && directory != "bare")
                {
                    continue;
                }
                let control_started = Instant::now();
                let cwd = if control == "independent" {
                    &independent
                } else {
                    &inherited
                };
                let mut args = args.clone();

                if control == "own" && matches!(verb, "refresh" | "apply" | "updates") {
                    if directory == "bare" {
                        let extra = catalog.join("skills/extra");
                        fs::create_dir_all(&extra).expect("new skill source");
                        fs::write(
                            extra.join("SKILL.md"),
                            "---\nname: extra\ndescription: Fixture\n---\nBody.\n",
                        )
                        .expect("new skill bytes");
                        let manifest = fixture.main.join("kendex.toml");
                        let contents = fs::read_to_string(&manifest).expect("current declaration");
                        fs::write(
                            &manifest,
                            format!("{contents}\n[skills.extra]\nsource=\"cat\"\n"),
                        )
                        .expect("pending project write");
                    }
                    fixture.mark();
                    let before = snapshot(&fixture.root);
                    let output = kendex(&fixture, cwd, &args);
                    assert!(refusal(&output), "marked {directory} {verb}: {output:?}");
                    assert_eq!(
                        snapshot(&fixture.root),
                        before,
                        "marked {verb} refusal wrote"
                    );
                    if directory == "bare" {
                        let mut overridden = args.clone();
                        overridden.push("--lane-refresh");
                        let output = kendex(&fixture, cwd, &overridden);
                        assert!(output.status.success(), "bare override {verb}: {output:?}");
                        assert!(fixture.main.join(".claude/skills/extra/SKILL.md").is_file());
                    }
                    fs::remove_file(&fixture.marker).expect("remove enclosing marker");
                }

                // Change one real guard input: the destination now belongs to
                // the caller, or it is global. The same refusal assertion must
                // turn red, and the real command must complete successfully.
                if matches!(control, "own" | "independent") {
                    for name in ["kendex.toml", ".kendex-lock.json"] {
                        fs::copy(fixture.main.join(name), cwd.join(name)).expect("own declaration");
                    }
                    let install = kendex(
                        &fixture,
                        cwd,
                        &["apply", "--scope", "project", "--yes", "--leave"],
                    );
                    assert!(install.status.success(), "own setup: {install:?}");
                    let borrowed = cwd.join(".claude/skills/borrowed");
                    fs::create_dir_all(&borrowed).expect("own adopt fixture");
                    fs::write(
                        borrowed.join("SKILL.md"),
                        "---\nname: borrowed\ndescription: Fixture\n---\nBody.\n",
                    )
                    .expect("own adopt bytes");
                } else if matches!(verb, "add" | "bare-add") {
                    args.push("--global");
                } else {
                    args.extend(["--scope", "global"]);
                }
                let output = kendex(&fixture, cwd, &args);
                assert!(
                    !cross_checkout_refusal(&output, &caller, &fixture.main),
                    "must-fail {control} {verb}: {output:?}"
                );
                assert!(output.status.success(), "{control} {verb}: {output:?}");
                report(verb, directory, control, control_started);
                let restore_started = Instant::now();
                restore();
                report(verb, directory, "restore", restore_started);
            }
            report(verb, directory, "complete", row_started);
        }
    }
    report("table", "", "complete", table_started);
}

#[test]
#[allow(clippy::expect_used, reason = "fixture paths are valid")]
fn named_cross_checkout_writes_require_the_existing_override() {
    for (directory, verb) in [
        ("", "refresh"),
        ("vendor", "refresh"),
        ("", "apply"),
        ("vendor", "apply"),
        ("", "updates"),
        ("vendor", "updates"),
    ] {
        for scope in ["project", "all"] {
            let fixture = world();
            if directory == "vendor" {
                fixture.git(
                    &fixture.linked,
                    &[
                        "clone",
                        "-q",
                        fixture.main.to_str().expect("fixture path"),
                        "vendor",
                    ],
                );
            }
            let cwd = fixture.linked.join(directory);
            let other = fixture.root.join("other");
            fs::create_dir_all(&other).expect("other project");
            fs::copy(fixture.main.join("kendex.toml"), other.join("kendex.toml"))
                .expect("other declaration");
            let target = other.to_str().expect("other path");
            let mut args = vec![
                verb,
                "--project-path",
                target,
                "--scope",
                scope,
                "--yes",
                "--leave",
                "--throwaway",
            ];
            if verb == "updates" {
                args.push("--apply");
            }
            let before = snapshot(&fixture.root);
            let output = kendex(&fixture, &cwd, &args);
            assert!(
                cross_checkout_refusal(&output, &fixture.linked, &other),
                "{args:?}: {output:?}"
            );
            let equivalent_caller = fixture
                .linked
                .join("..")
                .join(fixture.linked.file_name().expect("caller directory"));
            assert!(
                cross_checkout_refusal(&output, &equivalent_caller, &other),
                "caller identity must accept an equivalent spelling"
            );
            assert!(
                !cross_checkout_refusal(&output, &fixture.main, &other),
                "caller identity must reject another checkout"
            );
            assert_eq!(snapshot(&fixture.root), before, "named refusal wrote");
            // The override is the missing-input control for this refusal.
            args.push("--lane-refresh");
            let output = kendex(&fixture, &cwd, &args);
            assert!(
                !cross_checkout_refusal(&output, &fixture.linked, &other),
                "override control stayed green"
            );
            assert!(output.status.success(), "{args:?}: {output:?}");
            assert!(other.join(".claude/skills/deploy/SKILL.md").is_file());
        }
    }
}
