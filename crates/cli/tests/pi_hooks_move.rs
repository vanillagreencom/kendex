//! `refresh` is the verb the changelog sends people to for the pi
//! reserved-name move, so it is the verb that has to say what the move
//! declined to do — a file left where it is, and the warning still coming.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_says_which_file_it_left_under_the_name_pi_reserved() {
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

    // Back to the layout an earlier kendex wrote, with the script edited
    // so the move has to leave it — and say so.
    let dot = project.join(".pi");
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
