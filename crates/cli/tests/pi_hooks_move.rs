//! `refresh` is the verb the changelog sends people to for the pi
//! reserved-name move, so it is the verb that has to say what the move
//! declined to do — a file left where it is, and the warning still coming.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// Drop the record that the move is over, the way a lock written before
/// there was one to keep carries it: a fixture that puts files back under
/// the reserved name is pretending to be an older kendex, and an older
/// kendex wrote no such record.
#[allow(clippy::unwrap_used)]
fn forget_the_move(project: &Path) {
    let path = project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    for entry in lock["entries"].as_object_mut().into_iter().flatten() {
        entry
            .1
            .as_object_mut()
            .unwrap()
            .remove("leftPiReservedName");
    }
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
}

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

/// A project with one pi hook installed at the new paths, and the home
/// every `kendex` call in the test runs against.
#[allow(clippy::unwrap_used)]
fn installed() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/bin/sh\n# ---\n# name: guard\n# event: PreToolUse\n# description: a guard\n# harnesses: [pi]\n# ---\nexit 0\n",
    )
    .unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"pi\"]\n\n[hooks.guard]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    assert!(
        kendex(&home, &project, &["refresh", "-y"]).status.success(),
        "the first refresh installs at the new paths"
    );
    (tmp, home, project)
}

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_says_which_file_it_left_under_the_name_pi_reserved() {
    let (_tmp, home, project) = installed();

    // Back to the layout an earlier kendex wrote, with the script edited
    // so the move has to leave it — and say so.
    let dot = project.join(".pi");
    forget_the_move(&project);
    fs::create_dir_all(dot.join("hooks")).unwrap();
    fs::rename(
        dot.join("kendex/hooks/guard.sh"),
        dot.join("hooks/guard.sh"),
    )
    .unwrap();
    let registry = fs::read_to_string(dot.join("kendex/hooks.json")).unwrap();
    fs::write(
        dot.join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
    fs::remove_dir_all(dot.join("kendex")).unwrap();
    fs::write(dot.join("hooks/guard.sh"), "#!/bin/sh\n# mine\nexit 0\n").unwrap();

    let output = kendex(&home, &project, &["refresh", "-y"]);
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{said}");
    assert!(
        said.contains("was edited on disk"),
        "refresh must say which file it left behind: {said}"
    );
    assert!(dot.join("hooks/guard.sh").is_file());
}

#[test]
#[allow(clippy::unwrap_used)]
fn remove_by_name_takes_a_held_hook_out_of_the_reserved_directory() {
    let (_tmp, home, project) = installed();

    // Back to the old layout, with the script edited so it is held.
    let dot = project.join(".pi");
    forget_the_move(&project);
    fs::create_dir_all(dot.join("hooks")).unwrap();
    fs::rename(
        dot.join("kendex/hooks/guard.sh"),
        dot.join("hooks/guard.sh"),
    )
    .unwrap();
    let registry = fs::read_to_string(dot.join("kendex/hooks.json")).unwrap();
    fs::write(
        dot.join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
    fs::remove_dir_all(dot.join("kendex")).unwrap();
    fs::write(dot.join("hooks/guard.sh"), "#!/bin/sh\n# mine\nexit 0\n").unwrap();

    let output = kendex(&home, &project, &["remove", "guard"]);
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{said}");

    assert!(
        !dot.join("hooks").exists(),
        "a removal the person typed leaves nothing running: {said}"
    );
    assert!(!dot.join("hooks.json").exists(), "{said}");
    let lock = fs::read_to_string(project.join(".kendex-lock.json")).unwrap();
    assert!(!lock.contains("hook:guard:pi"), "{lock}");
}

/// The same promise at the new path. A registration the person moved to
/// another listener holds an install, because writing the fresh one beside
/// it would fire the hook twice — but nothing is written for a hook they
/// typed the name of, and holding it would leave what they asked to be rid
/// of installed for good.
#[test]
#[allow(clippy::unwrap_used)]
fn remove_by_name_takes_a_hook_whose_registration_was_moved() {
    let (_tmp, home, project) = installed();
    let dot = project.join(".pi");
    let registry = dot.join("kendex/hooks.json");
    let installed = fs::read_to_string(&registry).unwrap();
    let moved = installed.replace("tool_call", "turn_end");
    assert_ne!(moved, installed, "the fixture has to move the listener");
    fs::write(&registry, &moved).unwrap();

    let output = kendex(&home, &project, &["remove", "guard"]);
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{said}");

    assert!(
        !dot.join("kendex/hooks/guard.sh").exists(),
        "the script goes: {said}"
    );
    let after = fs::read_to_string(&registry).unwrap();
    assert!(
        !after.contains("guard.sh"),
        "and so does the entry, wherever they moved it: {after}"
    );
    let lock = fs::read_to_string(project.join(".kendex-lock.json")).unwrap();
    assert!(!lock.contains("hook:guard:pi"), "{lock}");

    let output = kendex(&home, &project, &["refresh", "-y"]);
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{said}");
    assert!(
        !fs::read_to_string(&registry).unwrap().contains("guard.sh"),
        "and the refresh after it has nothing to put back: {said}"
    );
}
