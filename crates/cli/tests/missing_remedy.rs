#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

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
    let declaration = |name| {
        format!(
            "schema = 6\n[install]\nharnesses = [\"claude\"]\n[sources.cat]\npath = \"catalog\"\n[skills.{name}]\nsource = \"cat\"\n"
        )
    };
    fs::write(&manifest_path, declaration("old-name")).unwrap();
    let installed = kendex(&home, &project, &["apply", "--scope", scope_name, "--yes"]);
    assert!(installed.status.success(), "{installed:?}");
    let lock_path = lock::lock_path(&env, &scope);
    let recorded = lock::load(&lock_path).unwrap();
    let entry = recorded
        .entries
        .values()
        .find(|e| e.name == "old-name")
        .unwrap();
    let paths = engine::installed_paths(&env, &scope, entry);
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

    for path in &paths {
        fs::remove_dir_all(path).unwrap();
    }
    if renamed {
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
        fs::write(&manifest_path, declaration("new-name")).unwrap();
        let refreshed = kendex(
            &home,
            &project,
            &["refresh", "--scope", scope_name, "--yes"],
        );
        assert!(refreshed.status.success(), "{refreshed:?}");
        assert!(
            lock::load(&lock_path)
                .unwrap()
                .entries
                .values()
                .any(|e| e.name == "old-name")
        );
    }
    run_missing_remedy(&home, &project, scope_name, &lock_path);
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
fn run_missing_remedy(home: &Path, project: &Path, scope_name: &str, lock_path: &Path) {
    let bytes = fs::read(lock_path).unwrap();
    let checked = kendex(home, project, &["check", "--scope", scope_name, "--quiet"]);
    assert_eq!(checked.status.code(), Some(1), "{checked:?}");
    assert_eq!(fs::read(lock_path).unwrap(), bytes);
    let text = String::from_utf8(checked.stdout).unwrap();
    let missing = text
        .lines()
        .find(|line| line.contains("'old-name' has no files on disk"))
        .unwrap();
    let command = missing.split_once("fix: kendex ").unwrap().1;
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
