//! Installing the commit guards, end to end on a throwaway repository.
//!
//! The package is the engine, so these run its real scripts: the fixture
//! catalog carries this repository's own copy of growth-guards, and the
//! journey is the one a consumer takes — add the package, arm the hooks,
//! commit the posture, clone it somewhere else, arm there, commit again.
//! The clone is where the design is proved or not: its gate has to work
//! with no kendex on PATH at all.

use std::fs;
use std::path::Path;

use crate::{World, git, read, said};

/// This repository's own copy of a package, dropped into the fixture
/// catalog where `kendex add` will find it.
#[allow(clippy::unwrap_used)]
fn offer(world: &World, skill: &str) {
    let source = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    copy_tree(
        &source.join(skill),
        &world.catalog.join("skills").join(skill),
    );
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                fs::copy(entry.path(), &target).unwrap();
                let mode = fs::metadata(entry.path()).unwrap().permissions();
                fs::set_permissions(&target, mode).unwrap();
            }
        }
    }
}

/// git in a directory, with a PATH that holds no kendex — the state a
/// teammate's machine is in.
#[allow(clippy::unwrap_used)]
fn git_without_kendex(dir: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .unwrap()
}

fn spoke(output: &std::process::Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

/// Installing the package puts its scripts in the committed tree, arming
/// writes shims that point at that tree, and a clone of the result gates
/// commits once armed there — with no kendex binary in the picture.
#[test]
#[allow(clippy::unwrap_used)]
fn the_guards_travel_with_the_repository_and_gate_a_clone() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "growth-guards");
    world.run(&["add", "cat", "--skill", "growth-guards", "-y"]);

    // The scripts land in the tree a commit carries.
    let scripts = world.at(".agents/skills/growth-guards/scripts");
    assert!(scripts.join("pre-commit").is_file());
    assert!(read(&scripts.join("install-git-hooks")).contains("install-git-hooks"));

    // Arming writes shims, never core.hooksPath.
    let armed = world.run(&["guard", "install"]);
    assert!(
        armed.contains("armed") || armed.contains("hooks"),
        "{armed}"
    );
    assert!(world.at(".git/hooks/kendex-guards").is_file());
    let hooks_path = git_without_kendex(&world.project, &["config", "--get", "core.hooksPath"]);
    assert_eq!(
        hooks_path.status.code(),
        Some(1),
        "core.hooksPath is untouched"
    );

    world.commit_all("feat: install the commit guards");

    let clone = world.tmp.path().join("elsewhere/fresh-checkout");
    fs::create_dir_all(clone.parent().unwrap()).unwrap();
    git(
        &world.project,
        &["clone", "--quiet", ".", &clone.display().to_string()],
    );

    // A clone carries the scripts and no hooks: git never clones those.
    assert!(
        clone
            .join(".agents/skills/growth-guards/scripts/pre-commit")
            .is_file()
    );
    assert!(!clone.join(".git/hooks/kendex-guards").exists());

    // Arming in the clone is the one act that needs a tool. After it, the
    // gate is committed shell and git, and nothing else.
    crate::run(&world.home, &clone, &["guard", "install"]);
    fs::write(clone.join("late.rs"), "// TO".to_owned() + "DO: not yet\n").unwrap();
    git_without_kendex(&clone, &["add", "-A"]);
    let blocked = git_without_kendex(&clone, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", spoke(&blocked));
    assert!(spoke(&blocked).contains("todo-ban"), "{}", spoke(&blocked));
}

/// Removing the package leaves no shim behind. A shim whose scripts are
/// gone fails closed on every commit, so disarming has to happen while the
/// package is still there to disarm with.
#[test]
#[allow(clippy::unwrap_used)]
fn disarming_before_removal_leaves_the_repository_committable() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "growth-guards");
    world.run(&["add", "cat", "--skill", "growth-guards", "-y"]);
    world.run(&["guard", "install"]);
    assert!(world.at(".git/hooks/kendex-guards").is_file());

    world.run(&["guard", "uninstall"]);
    assert!(!world.at(".git/hooks/kendex-guards").exists());
    let hook = world.at(".git/hooks/pre-commit");
    assert!(
        !hook.exists() || !read(&hook).contains("kendex-guards-hook"),
        "the delegating line is gone"
    );

    world.run(&["remove", "growth-guards"]);
    fs::write(world.at("late.txt"), "fine\n").unwrap();
    git_without_kendex(&world.project, &["add", "-A"]);
    let ok = git_without_kendex(&world.project, &["commit", "-m", "feat: after removal"]);
    assert!(ok.status.success(), "{}", spoke(&ok));
}

/// `kendex check` names an unarmed repository, in the package's own words,
/// and says nothing once it is armed.
#[test]
#[allow(clippy::unwrap_used)]
fn check_names_an_unarmed_repository() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "growth-guards");
    world.run(&["add", "cat", "--skill", "growth-guards", "-y"]);

    let unarmed = said(&world.try_run(&["check"]));
    assert!(unarmed.contains("commit hooks"), "{unarmed}");

    world.run(&["guard", "install"]);
    let armed = said(&world.try_run(&["check"]));
    assert!(!armed.contains("commit hooks"), "{armed}");
}
