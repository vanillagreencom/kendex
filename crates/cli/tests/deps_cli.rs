//! Changing *what is installed* from the command line: a refresh that would
//! add or drop something asks first, and so does a removal that would leave
//! things behind. With no terminal to ask, both stop before writing and name
//! the flag that answers them.
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
fn skill(home: &Path, name: &str, dependencies: &str) {
    let dir = home.join("catalog/skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: the {name} skill\n{dependencies}---\nBody.\n"),
    )
    .unwrap();
}

/// A project with `dev` installed, which requires `github`.
#[allow(clippy::unwrap_used)]
fn project(tmp: &tempfile::TempDir) -> std::path::PathBuf {
    let home = tmp.path();
    fs::create_dir_all(home.join(".claude/skills")).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    skill(home, "dev", "dependencies:\n  required: [github]\n");
    skill(home, "github", "");
    skill(home, "linear", "");

    let output = kendex(
        home,
        &project,
        &[
            "add",
            home.join("catalog").to_str().unwrap(),
            "--skill",
            "dev",
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
    assert!(project.join(".claude/skills/dev").exists());
    assert!(
        project.join(".claude/skills/github").exists(),
        "the dependency was not installed"
    );
    project
}

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_regenerates_freely_but_asks_before_changing_what_is_installed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project(&tmp);

    // Same set, new content: nothing to ask about.
    skill(home, "github", "");
    fs::write(
        home.join("catalog/skills/github/SKILL.md"),
        "---\nname: github\ndescription: the github skill\n---\nNewer body.\n",
    )
    .unwrap();
    let output = kendex(home, &project, &["refresh"]);
    assert!(output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("refreshed"), "{said}");
    assert!(
        fs::read_to_string(project.join(".claude/skills/github/SKILL.md"))
            .unwrap()
            .contains("Newer body")
    );

    // A new dependency upstream changes the set, so with no terminal to ask
    // and no --yes, the refresh refuses before it writes.
    skill(home, "dev", "dependencies:\n  required: [github, linear]\n");
    let output = kendex(home, &project, &["refresh"]);
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("this changes what is installed"), "{said}");
    assert!(said.contains("install skill linear"), "{said}");
    assert!(said.contains("required by the skill dev"), "{said}");
    assert!(said.contains("--yes"), "{said}");
    assert!(!project.join(".claude/skills/linear").exists());

    let output = kendex(home, &project, &["refresh", "--yes"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/skills/linear").exists());

    // And the same in the other direction, when upstream stops needing it.
    skill(home, "dev", "dependencies:\n  required: [github]\n");
    let output = kendex(home, &project, &["refresh"]);
    assert!(!output.status.success());
    assert!(project.join(".claude/skills/linear").exists());
    let output = kendex(home, &project, &["refresh", "-y"]);
    assert!(output.status.success());
    assert!(!project.join(".claude/skills/linear").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn removing_the_last_dependent_asks_about_what_it_leaves_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project(&tmp);

    let output = kendex(home, &project, &["remove", "dev"]);
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("skill github"), "{said}");
    assert!(said.contains("--sweep"), "{said}");
    assert!(said.contains("--no-sweep"), "{said}");
    assert!(
        project.join(".claude/skills/dev").exists(),
        "the removal wrote before it asked"
    );

    let output = kendex(home, &project, &["remove", "dev", "--no-sweep"]);
    assert!(output.status.success());
    assert!(!project.join(".claude/skills/dev").exists());
    assert!(project.join(".claude/skills/github").exists());

    let output = kendex(home, &project, &["remove", "github"]);
    assert!(output.status.success());
    assert!(!project.join(".claude/skills/github").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn sweeping_takes_the_leftovers_and_a_held_back_dependency_says_so() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = project(&tmp);

    // Removing the dependency alone holds it back and says what still wants
    // it; nothing brings it back.
    let output = kendex(home, &project, &["remove", "github"]);
    assert!(output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("missing required dependency"), "{said}");
    assert!(!project.join(".claude/skills/github").exists());
    let output = kendex(home, &project, &["refresh", "--yes"]);
    assert!(output.status.success());
    assert!(!project.join(".claude/skills/github").exists());
    assert!(
        fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .contains("skill = [\"github\"]")
    );

    // Asking for it again outranks the removal. Named source: with none, the
    // default catalog is consulted, and this suite must not reach the network.
    let output = kendex(
        home,
        &project,
        &[
            "add",
            home.join("catalog").to_str().unwrap(),
            "--skill",
            "github",
            "--harness",
            "claude",
            "-y",
        ],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/skills/github").exists());

    let output = kendex(home, &project, &["remove", "dev", "--sweep"]);
    assert!(output.status.success());
    // github was asked for by name, so a sweep still leaves it.
    assert!(project.join(".claude/skills/github").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_optional_dependency_is_taken_only_when_it_is_asked_for() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    fs::create_dir_all(home.join(".claude/skills")).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    skill(
        home,
        "dev",
        "dependencies:\n  required: [github]\n  optional: [linear]\n",
    );
    skill(home, "github", "");
    skill(home, "linear", "");

    let catalog = home.join("catalog");
    let add = |args: &[&str]| {
        let mut all = vec![
            "add",
            catalog.to_str().unwrap(),
            "--harness",
            "claude",
            "-y",
        ];
        all.extend_from_slice(args);
        kendex(home, &project, &all)
    };

    // A name nothing offers is an error, and it changes nothing.
    let output = add(&["--skill", "dev", "--with", "nonesuch"]);
    assert!(!output.status.success());
    let said = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(said.contains("nonesuch"), "{said}");
    assert!(!project.join("kendex.toml").exists());

    let output = add(&["--skill", "dev", "--with", "linear"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(project.join(".claude/skills/linear").exists());
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[optional-dependencies]"), "{manifest}");
    assert!(manifest.contains("dev = [\"linear\"]"), "{manifest}");
    // The choice, not its consequence: the extra is never declared.
    assert!(!manifest.contains("[skills.linear]"), "{manifest}");

    let output = kendex(home, &project, &["refresh"]);
    assert!(output.status.success());
    assert!(project.join(".claude/skills/linear").exists());
}
