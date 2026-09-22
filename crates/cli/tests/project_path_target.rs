//! `--project-path`: the project a whole-scope write lands in, named in
//! the command rather than walked up to from the working directory.
//!
//! The walk answers for the directory a command was typed in, which an
//! agent session cannot move, and which a linked git worktree's guard
//! refuses to write through at all. These run the real binary from a
//! directory that is not the destination and then read the destination.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("TMPDIR", std::env::temp_dir())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

#[allow(clippy::expect_used)]
fn run(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let output = kendex(home, cwd, args);
    assert!(
        output.status.success(),
        "kendex {args:?} failed:\n{}",
        said(&output)
    );
    said(&output)
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// The registry as the settings file holds it — what a second program,
/// the app included, sees after a run here.
#[allow(clippy::unwrap_used)]
fn registered(home: &Path) -> Vec<PathBuf> {
    let path = kendex_core::env::Env::host_rooted(home).settings_file();
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let document: toml::Table = text.parse().unwrap();
    let Some(projects) = document.get("projects") else {
        return Vec::new();
    };
    projects
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| PathBuf::from(entry.as_str().unwrap()))
        .collect()
}

/// A fixture home with one tool on the machine and a catalog offering one
/// skill, plus an elsewhere to type commands in that is no project.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    fs::create_dir_all(home.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: the deploy skill\n---\nBody.\n",
    );
    let elsewhere = home.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    (tmp, home, catalog, elsewhere)
}

/// The manifest a project keeps of its own, naming the fixture catalog.
fn declare(root: &Path, catalog: &Path) {
    write(
        &root.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    );
}

fn installed(root: &Path) -> PathBuf {
    root.join(".claude/skills/deploy/SKILL.md")
}

/// The destination is the path the command names, and nothing about the
/// directory the command was typed in reaches the run.
///
/// The inverse is the second half: the same command with no target, typed
/// in the same place, does not write the named project.
#[test]
#[allow(clippy::unwrap_used)]
fn the_named_project_is_written_and_the_directory_typed_in_is_not() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    run(
        &home,
        &elsewhere,
        &["apply", "--project-path", project.to_str().unwrap(), "-y"],
    );

    assert!(
        installed(&project).is_file(),
        "the named project is written"
    );
    assert!(
        !elsewhere.join(".claude").exists(),
        "the folder the command was typed in stays untouched"
    );
    assert!(
        registered(&home).contains(&project),
        "and the named project is on the projects list: {:?}",
        registered(&home)
    );
}

/// A path that is no kendex project root is refused before anything is
/// planned, and a path inside a project names the root it should have had.
///
/// Both refusals matter for the same reason: a write aimed at a folder
/// that is not the root lands in the project above it, which is the very
/// thing naming a destination exists to stop.
#[test]
#[allow(clippy::unwrap_used)]
fn a_path_that_is_not_a_project_root_is_refused() {
    let (_tmp, home, catalog, elsewhere) = world();
    let bare = home.join("bare");
    fs::create_dir_all(&bare).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join("src")).unwrap();
    declare(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &["apply", "--project-path", bare.to_str().unwrap(), "-y"],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("is not a kendex project"),
        "{}",
        said(&refused)
    );
    assert!(!bare.join(".claude").exists(), "nothing was written there");
    assert!(
        !registered(&home).contains(&bare),
        "and nothing was registered"
    );

    let inside = project.join("src");
    let refused = kendex(
        &home,
        &elsewhere,
        &["apply", "--project-path", inside.to_str().unwrap(), "-y"],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("not a project root of its own"),
        "{}",
        said(&refused)
    );
    assert!(
        !installed(&project).is_file(),
        "and the project above it was not written either"
    );
}

/// The two destinations are different places, so a run naming both is
/// refused rather than given one of them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_named_project_and_the_personal_scope_together_are_refused() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &[
            "apply",
            "--project-path",
            project.to_str().unwrap(),
            "--global",
            "-y",
        ],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("--project-path names a project"),
        "{}",
        said(&refused)
    );
    assert!(!installed(&project).is_file());
}

/// A linked git worktree carrying a manifest of its own is a project in
/// its own right: it is the destination a command may name, it renders
/// from its own declarations, and the checkout it was added from is
/// untouched by the run.
///
/// This is the case the flag exists for. An agent session rooted in the
/// worktree cannot move its shell into the main checkout, and the
/// worktree guard refuses a project-scope write that names no target.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_worktree_with_its_own_manifest_is_a_project_a_command_can_name() {
    let (_tmp, home, catalog, elsewhere) = world();
    let main = home.join("dev/app");
    fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "--quiet", "-b", "main"]);
    write(&main.join("README.md"), "main\n");
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "--quiet", "-m", "one"]);
    let worktree = home.join("lanes/one");
    git(
        &main,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "lane",
            worktree.to_str().unwrap(),
        ],
    );
    declare(&worktree, &catalog);

    run(
        &home,
        &elsewhere,
        &["apply", "--project-path", worktree.to_str().unwrap(), "-y"],
    );

    assert!(
        installed(&worktree).is_file(),
        "the worktree renders from its own manifest"
    );
    assert!(
        !installed(&main).is_file(),
        "and the checkout it was added from is not written"
    );

    // The list names it for what it is: two entries under one repository
    // are not readable as a pair from their paths.
    let listed = run(&home, &elsewhere, &["project", "list"]);
    let row = listed
        .lines()
        .find(|line| line.starts_with(worktree.to_str().unwrap()))
        .unwrap_or_else(|| panic!("no row for the worktree:\n{listed}"));
    assert!(
        row.contains(&format!("(worktree of {})", main.display())),
        "{row}"
    );
}
