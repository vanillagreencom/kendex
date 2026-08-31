//! Real commits through the armed shims, against the real package.
//!
//! The checks are the growth-guards package's shell scripts, so these
//! scenarios install this repository's own copy of that package into a
//! throwaway repo and drive it exactly as a consumer would. `kendex` is
//! nowhere in a hook's path once the shims are written — the whole point of
//! the delegation — so that is asserted, not assumed.
//!
//! Split by what is under test: `gating` is the chain judging commits,
//! `arming` is putting it in place, taking it away, and reporting on it.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

mod arming;
mod consent;
mod gating;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn run(home: &Path, cwd: &Path, program: &str, args: &[&str]) -> Output {
    run_with(home, cwd, program, args, &[])
}

/// A process in a clean environment: only HOME, a PATH that finds this
/// build's binary, and whatever `extra` names.
#[allow(clippy::expect_used)]
fn run_with(
    home: &Path,
    cwd: &Path,
    program: &str,
    args: &[&str],
    extra: &[(&str, &str)],
) -> Output {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", path_with_binary())
        .env("GIT_CONFIG_NOSYSTEM", "1");
    for (key, value) in extra {
        command.env(key, value);
    }
    command.output().expect("process runs")
}

#[allow(clippy::expect_used)]
fn path_with_binary() -> String {
    let bin_dir = PathBuf::from(env!("CARGO_BIN_EXE_kendex"))
        .parent()
        .expect("binary has a parent")
        .to_path_buf();
    format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

/// A PATH with no kendex on it, for proving a commit needs none.
fn path_without_binary() -> String {
    std::env::var("PATH").unwrap_or_default()
}

fn git(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    run(home, cwd, "git", args)
}

#[allow(clippy::unwrap_used)]
fn git_ok(home: &Path, cwd: &Path, args: &[&str]) {
    let output = git(home, cwd, args);
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn said(output: &Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

/// Install this repository's own copy of a package the way a person would:
/// offered from a catalog under the fixture home, then installed with
/// `kendex add`.
///
/// A real install, not a copy: it is what writes the machine-scoped record
/// that lets a read verb run the package's scripts, and hand-forging that
/// record would test the forgery rather than the product.
#[allow(clippy::unwrap_used)]
pub fn install_package(home: &Path, root: &Path, skills: &[&str]) {
    let catalog = home.join("catalog");
    let source = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    for skill in skills {
        let offered = catalog.join("skills").join(skill);
        // Seeded once: a test that patched the offer before installing gets
        // the package it wrote, not a fresh copy over the top of it.
        if !offered.exists() {
            copy_tree(&source.join(skill), &offered);
        }
    }
    let manifest = root.join("kendex.toml");
    if !manifest.is_file() {
        std::fs::write(
            &manifest,
            format!("schema = 6\n\n[sources.cat]\n{}\n", source_path(&catalog)),
        )
        .unwrap();
    }
    for skill in skills {
        let out = run_at(home, root, &["add", "cat", "--skill", skill, "-y"]);
        assert!(
            root.join(".agents/skills").join(skill).is_dir(),
            "installing {skill} left no tree: {out}"
        );
    }
}

/// The same files with nothing installing them — a copy that arrived with a
/// clone rather than through an install. The declaration comes along too,
/// because a repository that commits its render ships one.
#[allow(clippy::unwrap_used)]
pub fn install_package_undeclared(root: &Path, skills: &[&str]) {
    let source = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    for skill in skills {
        copy_tree(
            &source.join(skill),
            &root.join(".agents/skills").join(skill),
        );
    }
}

/// `kendex` in the fixture home, asserted to succeed.
#[allow(clippy::unwrap_used)]
pub fn run_at(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let out = run(home, cwd, "kendex", args);
    assert!(out.status.success(), "kendex {args:?}: {}", said(&out));
    said(&out)
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                std::fs::copy(entry.path(), &target).unwrap();
                let mode = std::fs::metadata(entry.path()).unwrap().permissions();
                std::fs::set_permissions(&target, mode).unwrap();
            }
        }
    }
}

#[allow(clippy::unwrap_used)]
fn repo(home: &Path) -> PathBuf {
    // Detection reads this: without a tool directory an install has nowhere
    // to fan out to.
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let root = home.join("proj");
    // `.agents` is the project marker a repository adopting the shared
    // convention already has before kendex ever runs.
    std::fs::create_dir_all(root.join(".agents")).unwrap();
    git_ok(home, &root, &["init", "--quiet", "-b", "main"]);
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);
    std::fs::write(root.join("a.txt"), "hi\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: base"]);
    root
}

/// A repository with the package installed and its shims armed.
#[allow(clippy::unwrap_used)]
fn armed_repo(home: &Path) -> PathBuf {
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));
    root
}
