//! External-command declarations through the real installer and check JSON.
//! The keyed records identify command requirements in the check JSON.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use crate::test_util;
use crate::test_util::rooted;

#[allow(clippy::unwrap_used)]
fn setup(home: &Path, declarations: &str) -> PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    crate::deps_cli::skill(home, "external", declarations);
    project
}

#[allow(clippy::unwrap_used)]
fn run(home: &Path, project: &Path, args: &[&str], bin: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(project)
        .env_clear()
        .envs(test_util::fixture_env(home));
    let mut path = std::env::var_os("PATH").unwrap_or_default();
    if let Some(bin) = bin {
        path = std::env::join_paths(
            std::iter::once(bin.to_owned()).chain(std::env::split_paths(&path)),
        )
        .unwrap();
    }
    command.env("PATH", path).output().unwrap()
}

#[allow(clippy::unwrap_used)]
fn install(home: &Path, project: &Path, bin: Option<&Path>) -> Output {
    run(
        home,
        project,
        &[
            "add",
            home.join("catalog").to_str().unwrap(),
            "--skill",
            "external",
            "--harness",
            "claude,codex",
            "-y",
        ],
        bin,
    )
}

#[allow(clippy::unwrap_used)]
fn command_lines(output: &Output) -> Vec<serde_json::Value> {
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    report["sections"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|section| section["title"] == "external commands")
        .flat_map(|section| section["lines"].as_array().unwrap().iter().cloned())
        .collect()
}

#[test]
#[allow(clippy::unwrap_used)]
fn install_and_check_report_required_and_optional_commands_once() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = setup(
        &home,
        "dependencies:\n  commands:\n    - command: git\n      purpose: Read repository history\n    - command: kendex-fixture-missing-required\n      purpose: Render pages\n      packages: {npm: page-render, brew: page-render-cli}\n    - command: kendex-fixture-missing-optional\n      purpose: Read credentials\n      optional: true\n",
    );
    let installed = install(&home, &project, None);
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    assert!(project.join(".claude/skills/external/SKILL.md").is_file());
    // The check JSON preserves the install's keyed command records.
    let diagnostic = String::from_utf8_lossy(&installed.stderr);
    assert_eq!(
        diagnostic
            .matches("kendex-command-missing: command=kendex-fixture-missing-required")
            .count(),
        1
    );
    assert_eq!(
        diagnostic
            .matches("kendex-command-missing: command=kendex-fixture-missing-optional")
            .count(),
        1
    );
    let checked = run(
        &home,
        &project,
        &["check", "--scope", "project", "--json", "--report-only"],
        None,
    );
    assert_eq!(checked.status.code(), Some(1));
    let lines = command_lines(&checked);
    assert_eq!(lines.len(), 2);
    let required = lines.iter().find(|line| line["class"] == "drift").unwrap();
    let text = required["text"].as_str().unwrap();
    for value in [
        "command=kendex-fixture-missing-required",
        "skill=external",
        "purpose=Render pages",
        "brew=page-render-cli",
        "npm=page-render",
    ] {
        assert!(text.contains(value));
    }
    assert_eq!(
        lines
            .iter()
            .filter(|line| line["class"] == "notice")
            .count(),
        1
    );
    assert_eq!(
        lines
            .iter()
            .filter(|line| line["text"].as_str().unwrap().contains("command=git "))
            .count(),
        0
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn invalid_command_rows_refuse_installation() {
    for declarations in [
        "dependencies:\n  commands:\n    - purpose: Render pages\n",
        "dependencies:\n  commands:\n    - command: git\n",
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = setup(&home, declarations);
        let installed = install(&home, &project, None);
        assert!(!installed.status.success());
        assert!(!project.join(".claude/skills/external/SKILL.md").exists());
        let diagnostic = String::from_utf8_lossy(&installed.stderr);
        assert!(diagnostic.contains("kendex-command-declaration-invalid: skill=external row=1"));
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn version_floors_and_path_changes_use_live_command_answers() {
    for (script, optional, floor, class) in [
        ("printf 'tool 1.1.0\\n'", false, true, Some("drift")),
        ("printf 'tool 1.2.0\\n'", false, true, None),
        ("printf 'tool 1.10.0\\n'", false, true, None),
        (
            "printf 'version unavailable\\n'",
            false,
            true,
            Some("notice"),
        ),
        ("exit 1", false, true, Some("notice")),
        ("printf 'tool 1.1.0\\n' >&2", false, true, Some("drift")),
        ("printf 'tool 1.1.0\\n'", true, true, Some("notice")),
        ("touch \"$0.probed\"", false, false, None),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let declarations = format!(
            "dependencies:\n  commands:\n    - command: kendex-fixture-version\n      purpose: Render pages\n      optional: {optional}\n{}",
            if floor { "      floor: '1.2'\n" } else { "" }
        );
        let project = setup(&home, &declarations);
        let bin = home.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let executable = bin.join("kendex-fixture-version");
        fs::write(&executable, format!("#!/bin/sh\n{script}\n")).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(install(&home, &project, Some(&bin)).status.success());
        let checked = run(
            &home,
            &project,
            &["check", "--scope", "project", "--json", "--report-only"],
            Some(&bin),
        );
        let lines = command_lines(&checked);
        assert_eq!(
            lines
                .iter()
                .map(|line| line["class"].as_str().unwrap())
                .collect::<Vec<_>>(),
            class.into_iter().collect::<Vec<_>>()
        );
        assert_eq!(
            checked.status.code(),
            Some(if class == Some("drift") { 1 } else { 0 })
        );
        assert!(!executable.with_extension("probed").exists());
        // Removing the command after installation is the missing-command
        // control. It must change check even when the install record is clean.
        fs::remove_file(&executable).unwrap();
        let checked = run(
            &home,
            &project,
            &["check", "--scope", "project", "--json", "--report-only"],
            Some(&bin),
        );
        let lines = command_lines(&checked);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0]["class"], if optional { "notice" } else { "drift" });
        assert_eq!(checked.status.code(), Some(if optional { 0 } else { 1 }));
        assert!(
            lines[0]["text"]
                .as_str()
                .unwrap()
                .starts_with("kendex-command-missing:")
        );
    }
}
