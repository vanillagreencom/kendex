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
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n",
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
        let output = kendex(&fixture, &cwd, &args);
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
fn the_explicit_override_lands_for_every_project_writer() {
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
        fixture.mark();
        let output = kendex(&fixture, &fixture.linked, &args);
        assert!(output.status.success(), "override {args:?}: {output:?}");
        assert!(
            fixture
                .linked
                .join(".claude/skills/deploy/SKILL.md")
                .is_file()
        );
    }
}

#[test]
fn global_writes_and_main_checkout_writes_keep_their_existing_paths() {
    for verb in ["refresh", "apply", "updates"] {
        for target in ["global", "main"] {
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
            let output = kendex(&fixture, cwd, &args);
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
