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

#[allow(clippy::unwrap_used)]
fn assert_install_categories(home: &Path, project: &Path) {
    let env = kendex_core::env::Env::fake(
        home,
        if cfg!(target_os = "macos") {
            kendex_core::env::FakeOs::Mac
        } else {
            kendex_core::env::FakeOs::Linux
        },
    );
    let scope = kendex_core::model::Scope::Project {
        root: project.to_owned(),
    };
    let assessed = kendex_core::engine::ops::add(
        &env,
        &scope,
        &kendex_core::engine::ops::AddRequest {
            source: Some(home.join("catalog").to_str().unwrap().to_owned()),
            skills: vec!["external".to_owned()],
            harnesses: Some(vec![
                kendex_core::model::HarnessId::Claude,
                kendex_core::model::HarnessId::Codex,
            ]),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(assessed.warnings.len(), 1);
    assert_eq!(
        assessed.warnings[0].kind,
        kendex_core::model::ItemKind::Skill
    );
    assert_eq!(assessed.warnings[0].name, "external");
    for value in [
        "command=kendex-fixture-missing-required",
        "purpose=Render pages",
        "brew=page-render-cli",
        "npm=page-render",
    ] {
        assert!(assessed.warnings[0].message.contains(value));
    }
    let notices = assessed
        .notes
        .iter()
        .filter(|note| note.starts_with("kendex-command-missing:"))
        .collect::<Vec<_>>();
    assert_eq!(notices.len(), 1);
    assert!(notices[0].contains("command=kendex-fixture-missing-optional"));
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
    assert_install_categories(&home, &project);
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
        let arguments = if floor {
            "[ \"$#\" -eq 1 ] && [ \"$1\" = --version ] || exit 64\n"
        } else {
            ""
        };
        fs::write(&executable, format!("#!/bin/sh\n{arguments}{script}\n")).unwrap();
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

#[test]
#[allow(clippy::unwrap_used)]
fn check_assesses_recorded_and_unrecorded_copies_once() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let declarations = "dependencies:\n  commands:\n    - command: kendex-fixture-counted-version\n      purpose: Render pages\n      floor: '2.0'\n";
    let project = setup(&home, declarations);
    crate::deps_cli::skill(&home, "unrecorded", declarations);
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let executable = bin.join("kendex-fixture-counted-version");
    fs::write(&executable, "#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = --version ] || exit 64\nprintf 'probe\\n' >> \"$0.probes\"\nprintf 'tool 1.0.0\\n'\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    let installed = run(
        &home,
        &project,
        &[
            "add",
            home.join("catalog").to_str().unwrap(),
            "--skill",
            "external",
            "--skill",
            "unrecorded",
            "--harness",
            "claude,codex",
            "-y",
        ],
        Some(&bin),
    );
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    let path = project.join(".kendex-lock.json");
    let mut lock: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    lock["entries"]
        .as_object_mut()
        .unwrap()
        .retain(|_, entry| entry["name"] != "unrecorded");
    fs::write(&path, serde_json::to_vec_pretty(&lock).unwrap()).unwrap();
    let probes = executable.with_extension("probes");
    fs::write(&probes, "").unwrap();
    let checked = run(
        &home,
        &project,
        &["check", "--scope", "project", "--json"],
        Some(&bin),
    );
    assert_eq!(checked.status.code(), Some(1));
    let lines = command_lines(&checked);
    assert_eq!(lines.len(), 2);
    assert!(lines.iter().all(|line| line["class"] == "drift"));
    assert_eq!(fs::read_to_string(&probes).unwrap().lines().count(), 2);
    let recorded = kendex_core::lock::load(&path).unwrap();
    assert!(
        recorded
            .entries
            .values()
            .any(|entry| entry.name == "unrecorded")
    );
}

#[allow(clippy::unwrap_used)]
fn command_source_fixture(home: &Path) -> (PathBuf, PathBuf) {
    let project = setup(
        home,
        "dependencies:\n  commands:\n    - command: kendex-fixture-source-missing\n      purpose: Render pages\n    - command: kendex-fixture-source-version\n      purpose: Read pages\n      floor: '2.0'\n",
    );
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let executable = bin.join("kendex-fixture-source-version");
    fs::write(&executable, "#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = --version ] || exit 64\nprintf 'probe\\n' >> \"$0.probes\"\nprintf 'tool 1.0.0\\n'\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    let output = run(
        home,
        &project,
        &[
            "add",
            home.join("catalog").to_str().unwrap(),
            "--skill",
            "external",
            "--harness",
            "claude,codex",
            "--method",
            "copy",
            "-y",
        ],
        Some(&bin),
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    fs::write(executable.with_extension("probes"), "").unwrap();
    (project, bin)
}

#[allow(clippy::unwrap_used)]
fn assert_command_source_result(
    home: &Path,
    project: &Path,
    bin: &Path,
    present: bool,
    unreadable: bool,
) {
    let path = project.join(".kendex-lock.json");
    let before = fs::read(&path).ok();
    let checked = run(
        home,
        project,
        &["check", "--scope", "project", "--json", "--report-only"],
        Some(bin),
    );
    let lines = command_lines(&checked);
    assert_eq!(lines.len(), if present { 2 } else { 0 });
    assert!(lines.iter().all(|line| line["class"] == "drift"));
    if present {
        assert!(lines.iter().any(|line| {
            line["text"]
                .as_str()
                .unwrap()
                .contains("command=kendex-fixture-source-missing")
        }));
    }
    let report: serde_json::Value = serde_json::from_slice(&checked.stdout).unwrap();
    let unknown = report["sections"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|section| section["lines"].as_array().unwrap())
        .filter(|line| line["class"] == "unknown")
        .count();
    assert_eq!(unknown, usize::from(unreadable));
    if unreadable {
        assert_eq!(report["status"], "unknown");
    }
    let probes = fs::read_to_string(bin.join("kendex-fixture-source-version.probes")).unwrap();
    assert_eq!(probes.lines().count(), usize::from(present));
    assert_eq!(fs::read(&path).ok(), before);
}

#[allow(clippy::unwrap_used)]
fn command_source_cell(form: &str, record: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (project, bin) = command_source_fixture(&home);
    let path = project.join(".kendex-lock.json");
    if form == "occupied" {
        let mut lock: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        lock["entries"] = serde_json::json!({});
        fs::write(&path, serde_json::to_vec(&lock).unwrap()).unwrap();
    } else if form == "absent" {
        let lock = kendex_core::lock::load(&path).unwrap();
        for output in lock
            .entries
            .values()
            .filter_map(|entry| entry.emitted.as_ref())
            .flat_map(|artifact| &artifact.paths)
        {
            if output.is_dir() {
                fs::remove_dir_all(output).unwrap();
            }
        }
    } else {
        assert_eq!(form, "owned");
    }
    match record {
        "current" => {}
        "absent" => fs::remove_file(&path).unwrap(),
        "unreadable" => fs::write(&path, b"invalid record").unwrap(),
        _ => panic!("unknown fixture record state"),
    }
    assert_command_source_result(
        &home,
        &project,
        &bin,
        form != "absent",
        record == "unreadable",
    );
}

macro_rules! command_source_cells {
    ($($name:ident => ($form:literal, $record:literal)),+ $(,)?) => { $(
        #[test]
        fn $name() { command_source_cell($form, $record); }
    )+ };
}
command_source_cells! {
    owned_current => ("owned", "current"),
    owned_absent => ("owned", "absent"),
    owned_unreadable => ("owned", "unreadable"),
    occupied_current => ("occupied", "current"),
    occupied_absent => ("occupied", "absent"),
    occupied_unreadable => ("occupied", "unreadable"),
    absent_current => ("absent", "current"),
    absent_absent => ("absent", "absent"),
    absent_unreadable => ("absent", "unreadable"),
}

#[test]
#[allow(clippy::unwrap_used)]
fn selected_command_source_read_failure_stays_unknown_once() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (project, bin) = command_source_fixture(&home);
    // Claude sorts first. Its unreadable live declaration must not be replaced
    // by the valid Codex copy's answer for the same skill.
    fs::remove_file(project.join(".claude/skills/external/SKILL.md")).unwrap();
    let checked = run(
        &home,
        &project,
        &["check", "--scope", "project", "--json", "--report-only"],
        Some(&bin),
    );
    assert!(command_lines(&checked).is_empty());
    let report: serde_json::Value = serde_json::from_slice(&checked.stdout).unwrap();
    assert_eq!(report["status"], "unknown");
    assert_eq!(
        report["sections"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|section| section["lines"].as_array().unwrap())
            .filter(|line| line["class"] == "unknown")
            .count(),
        1
    );
    assert!(
        fs::read_to_string(bin.join("kendex-fixture-source-version.probes"))
            .unwrap()
            .is_empty()
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn occupied_command_sources_obey_declaration_enablement() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (project, bin) = command_source_fixture(&home);
    let path = project.join(".kendex-lock.json");
    let mut lock: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let source = lock["entries"]
        .as_object()
        .unwrap()
        .values()
        .next()
        .unwrap()["source"]
        .as_str()
        .unwrap()
        .to_owned();
    lock["entries"] = serde_json::json!({});
    fs::write(path, serde_json::to_vec(&lock).unwrap()).unwrap();
    let path = project.join("kendex.toml");
    let mut manifest: toml::Value = toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let mut declaration = toml::map::Map::new();
    declaration.insert("source".into(), toml::Value::String(source));
    declaration.insert("enabled".into(), toml::Value::Boolean(false));
    declaration.insert("method".into(), toml::Value::String("copy".into()));
    declaration.insert(
        "harnesses".into(),
        toml::Value::Array(vec![
            toml::Value::String("claude".into()),
            toml::Value::String("codex".into()),
        ]),
    );
    let mut skills = toml::map::Map::new();
    skills.insert("external".into(), toml::Value::Table(declaration));
    manifest
        .as_table_mut()
        .unwrap()
        .insert("skills".into(), toml::Value::Table(skills));
    fs::write(&path, toml::to_string(&manifest).unwrap()).unwrap();
    let env = kendex_core::env::Env::host_rooted(&home);
    let scope = kendex_core::model::Scope::Project {
        root: project.clone(),
    };
    let manifest = kendex_core::manifest::load_current(&path).unwrap().unwrap();
    let lock = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert!(kendex_core::engine::declared_over_existing_files(&env, &scope, &manifest, &lock).values().any(|copy| copy.kind == kendex_core::model::ItemKind::Skill && copy.name == "external"));
    assert_command_source_result(&home, &project, &bin, false, false);
}

#[test]
#[allow(clippy::unwrap_used)]
fn recorded_command_sources_survive_an_unreadable_manifest() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (project, bin) = command_source_fixture(&home);
    fs::write(project.join("kendex.toml"), b"[invalid manifest").unwrap();
    assert_command_source_result(&home, &project, &bin, true, true);
}
