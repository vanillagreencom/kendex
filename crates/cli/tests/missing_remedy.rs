#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use kendex_core::{engine, env::Env, lock, manifest, model::Scope};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn declaration(name: &str) -> String {
    format!(
        "schema = 6\n[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\n[sources.cat]\npath = \"catalog\"\n[skills.{name}]\nsource = \"cat\"\n"
    )
}

fn cleanup_declaration(name: Option<&str>) -> String {
    let mut text = "schema = 6\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[sources.cat]\npath = \"catalog\"\n".to_owned();
    if let Some(name) = name {
        text.push_str(&format!("[skills.{name}]\nsource = \"cat\"\n"));
    }
    text
}

#[allow(clippy::unwrap_used)]
fn rename_recorded_skill(
    home: &Path,
    project: &Path,
    catalog: &Path,
    manifest_path: &Path,
    lock_path: &Path,
    scope_name: &str,
) {
    fs::rename(
        catalog.join("skills/old-name"),
        catalog.join("skills/new-name"),
    )
    .unwrap();
    fs::write(
        catalog.join("skills/new-name/SKILL.md"),
        "---\nname: new-name\ndescription: Test skill.\n---\n\nUse this skill.\n",
    )
    .unwrap();
    fs::write(manifest_path, declaration("new-name")).unwrap();
    let refreshed = kendex(home, project, &["refresh", "--scope", scope_name, "--yes"]);
    assert!(refreshed.status.success(), "{refreshed:?}");
    assert!(
        lock::load(lock_path)
            .unwrap()
            .entries
            .values()
            .any(|entry| entry.name == "old-name")
    );
}

#[allow(clippy::unwrap_used)]
fn repair_missing(global: bool, renamed: bool) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let env = Env::host_rooted(&home);
    let scope = if global {
        Scope::Global
    } else {
        Scope::Project {
            root: project.clone(),
        }
    };
    let scope_name = if global { "global" } else { "project" };
    let manifest_path = manifest::manifest_path(&env, &scope);
    fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    let catalog = if global { &home } else { &project }.join("catalog");
    fs::create_dir_all(catalog.join("skills/old-name")).unwrap();
    fs::write(
        catalog.join("skills/old-name/SKILL.md"),
        "---\nname: old-name\ndescription: Test skill.\n---\n\nUse this skill.\n",
    )
    .unwrap();
    fs::write(&manifest_path, declaration("old-name")).unwrap();
    let installed = kendex(&home, &project, &["apply", "--scope", scope_name, "--yes"]);
    assert!(installed.status.success(), "{installed:?}");
    let lock_path = lock::lock_path(&env, &scope);
    let recorded = lock::load(&lock_path).unwrap();
    let entries: Vec<_> = recorded
        .entries
        .values()
        .filter(|entry| entry.name == "old-name")
        .collect();
    assert_eq!(entries.len(), 3, "one record per selected harness");
    let paths: BTreeSet<_> = entries
        .into_iter()
        .flat_map(|entry| engine::installed_paths(&env, &scope, entry))
        .collect();
    assert!(!paths.is_empty(), "the install must produce recorded files");
    let bytes = fs::read(&lock_path).unwrap();
    let clean = kendex(
        &home,
        &project,
        &["check", "--scope", scope_name, "--quiet"],
    );
    assert!(clean.status.success(), "{clean:?}");
    assert!(clean.stdout.is_empty(), "{clean:?}");
    assert_eq!(fs::read(&lock_path).unwrap(), bytes);

    if !renamed {
        for path in &paths {
            fs::remove_dir_all(path).unwrap();
        }
    }
    if renamed {
        rename_recorded_skill(
            &home,
            &project,
            &catalog,
            &manifest_path,
            &lock_path,
            scope_name,
        );
    }
    run_missing_remedy(&home, &project, scope_name, &lock_path, renamed);
    let recorded = lock::load(&lock_path).unwrap();
    assert_eq!(
        recorded.entries.values().any(|e| e.name == "old-name"),
        !renamed
    );
    let wanted = if renamed { "new-name" } else { "old-name" };
    let entry = recorded
        .entries
        .values()
        .find(|e| e.name == wanted)
        .unwrap();
    let wanted_paths = engine::installed_paths(&env, &scope, entry);
    assert!(!wanted_paths.is_empty());
    assert!(wanted_paths.iter().all(|path| path.exists()));
    if renamed {
        assert!(paths.iter().all(|path| !path.exists()));
    }
}

#[allow(clippy::unwrap_used)]
fn run_missing_remedy(
    home: &Path,
    project: &Path,
    scope_name: &str,
    lock_path: &Path,
    renamed: bool,
) {
    let bytes = fs::read(lock_path).unwrap();
    let checked = kendex(home, project, &["check", "--scope", scope_name, "--quiet"]);
    assert_eq!(checked.status.code(), Some(1), "{checked:?}");
    assert_eq!(fs::read(lock_path).unwrap(), bytes);
    let text = String::from_utf8(checked.stdout).unwrap();
    let expected = match renamed {
        true => "kendex.toml does not list recorded skill 'old-name' (claude, codex, pi)",
        false => "skill 'old-name' (claude, codex, pi) has no files on disk",
    };
    let matching: Vec<_> = text
        .lines()
        .filter(|line| line.contains(expected))
        .collect();
    assert_eq!(matching.len(), 1, "one package row: {text}");
    let missing = matching[0];
    let command = missing.split_once("fix: kendex ").unwrap().1;
    if renamed {
        assert!(command.starts_with("remove old-name"), "{missing}");
    }
    let mut args: Vec<&str> = command.split_whitespace().collect();
    if matches!(args.first(), Some(&"apply" | &"refresh")) {
        args.push("--yes");
    }
    let repaired = kendex(home, project, &args);
    assert!(repaired.status.success(), "{repaired:?}");

    let checked = kendex(home, project, &["check", "--scope", scope_name, "--quiet"]);
    assert!(checked.status.success(), "{checked:?}");
    assert!(checked.stdout.is_empty(), "{checked:?}");
}

#[allow(clippy::unwrap_used)]
fn repair_cleanup_state(absent_manifest: bool, edited_orphan: bool) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    let catalog = project.join("catalog");
    fs::create_dir_all(catalog.join("skills/old-name")).unwrap();
    fs::write(
        catalog.join("skills/old-name/SKILL.md"),
        "---\nname: old-name\ndescription: Test skill.\n---\n\nUse this skill.\n",
    )
    .unwrap();
    let env = Env::host_rooted(&home);
    let scope = Scope::Project {
        root: project.clone(),
    };
    let manifest_path = manifest::manifest_path(&env, &scope);
    fs::write(&manifest_path, cleanup_declaration(Some("old-name"))).unwrap();
    let installed = kendex(&home, &project, &["apply", "--scope", "project", "--yes"]);
    assert!(installed.status.success(), "{installed:?}");

    let lock_path = lock::lock_path(&env, &scope);
    let record = lock::load(&lock_path).unwrap();
    let entry = record
        .entries
        .values()
        .find(|entry| entry.name == "old-name")
        .unwrap();
    let installed_path = engine::installed_paths(&env, &scope, entry)
        .into_iter()
        .find(|path| path.exists())
        .unwrap();
    if edited_orphan {
        fs::write(installed_path.join("SKILL.md"), "Edited by the user.\n").unwrap();
    }
    if absent_manifest {
        fs::remove_file(&manifest_path).unwrap();
    } else {
        fs::write(&manifest_path, cleanup_declaration(None)).unwrap();
    }

    let checked = kendex(&home, &project, &["check", "--scope", "project", "--quiet"]);
    assert_eq!(checked.status.code(), Some(1), "{checked:?}");
    let text = String::from_utf8(checked.stdout).unwrap();
    let row = text
        .lines()
        .find(|line| line.contains("does not list recorded skill 'old-name'"))
        .unwrap();
    assert!(row.contains("fix: kendex remove old-name"), "{row}");

    let removed = kendex(&home, &project, &["remove", "old-name"]);
    assert!(removed.status.success(), "{removed:?}");
    assert!(!installed_path.exists(), "{removed:?}");
    let record = lock::load(&lock_path).unwrap();
    assert!(
        !record
            .entries
            .values()
            .any(|entry| entry.name == "old-name")
    );
    let checked = kendex(&home, &project, &["check", "--scope", "project", "--quiet"]);
    assert!(checked.status.success(), "{checked:?}");
    assert!(checked.stdout.is_empty(), "{checked:?}");
}

#[test]
fn the_printed_remedy_clears_records_left_after_a_rename() {
    for global in [false, true] {
        repair_missing(global, true);
    }
}

#[test]
fn the_printed_remedy_restores_declared_missing_files() {
    for global in [false, true] {
        repair_missing(global, false);
    }
}

#[test]
fn the_printed_remove_remedy_seeds_an_absent_manifest_and_clears_its_record() {
    repair_cleanup_state(true, false);
}

#[test]
fn the_printed_remove_remedy_confirms_an_edited_orphan_and_clears_its_record() {
    repair_cleanup_state(false, true);
}
