//! Installing and uninstalling a curated set from the command line: one flag
//! declares the set, and taking it away says which members go, which stay,
//! and what accounts for each.
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
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A catalog offering one set of two skills and an agent.
#[allow(clippy::unwrap_used)]
fn catalog(home: &Path) -> std::path::PathBuf {
    let catalog = home.join("catalog");
    for name in ["alpha", "beta"] {
        write(
            &catalog,
            &format!("skills/{name}/SKILL.md"),
            &format!("---\nname: {name}\ndescription: the {name} skill\n---\nBody.\n"),
        );
    }
    write(
        &catalog,
        "agents/writer.md",
        "---\nname: writer\ndescription: writes things\n---\n\nWrite.\n",
    );
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"alpha\", \"beta\"]\nagents = [\"writer\"]\n",
    );
    catalog
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_installs_whole_and_uninstalls_with_the_split_said_out_loud() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join(".claude/skills")).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = catalog(home);

    // One flag declares the set, and `beta` is also asked for by name.
    let output = kendex(
        home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "starter",
            "--skill",
            "beta",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(
        output.status.success(),
        "add failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/skills/alpha").exists());
    assert!(project.join(".claude/skills/beta").exists());
    assert!(project.join(".claude/agents/writer.md").exists());

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[bundles.starter]"), "{manifest}");
    assert!(!manifest.contains("[skills.alpha]"), "{manifest}");
    assert!(manifest.contains("[skills.beta]"), "{manifest}");

    // Taking the set away says what goes and what stays, with the reason.
    let output = kendex(home, &project, &["remove", "starter"]);
    assert!(
        output.status.success(),
        "remove failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(
        said.contains("removing skill alpha") && said.contains("part of the starter bundle"),
        "{said}"
    );
    assert!(said.contains("removing agent writer"), "{said}");
    assert!(
        said.contains("keeping skill beta") && said.contains("asked for"),
        "{said}"
    );

    assert!(!project.join(".claude/skills/alpha").exists());
    assert!(!project.join(".claude/agents/writer.md").exists());
    assert!(
        project.join(".claude/skills/beta").exists(),
        "a member the user asked for went with the set"
    );
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains("[bundles.starter]"), "{manifest}");
}

/// A name no catalog offers a set under is an error that changes nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_the_catalog_lacks_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = catalog(home);

    let output = kendex(
        home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "nonesuch",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("no bundle called 'nonesuch'"), "{said}");
    assert!(!project.join("kendex.toml").exists());
}
