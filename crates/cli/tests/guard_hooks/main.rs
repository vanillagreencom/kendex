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

mod arming;
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

/// This repository's own growth-guards and size-ratchet, copied into the
/// fixture where a consumer's install would put them. Copied rather than
/// linked so the scripts resolve their siblings through the fixture's own
/// tree, exactly as a committed `.agents/skills` does.
#[allow(clippy::unwrap_used)]
fn install_package(root: &Path, skills: &[&str]) {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    for skill in skills {
        copy_tree(
            &source.join(skill),
            &root.join(".agents/skills").join(skill),
        );
    }
    // A project that installed the package declares it, and that
    // declaration is what lets a read verb run the package's own checker.
    // Copying the files without it would be an undeclared copy — a
    // different scenario, covered on its own.
    declare(root, skills);
}

/// The manifest a `kendex add` of these skills would have written.
#[allow(clippy::unwrap_used)]
pub fn declare(root: &Path, skills: &[&str]) {
    let mut text = String::from("schema = 6\n\n[sources.local]\npath = \".\"\n");
    for skill in skills {
        text.push_str(&format!(
            "\n[skills.{skill}]\nsource = \"local\"\nenabled = true\n"
        ));
    }
    let path = root.join("kendex.toml");
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    match existing.is_empty() {
        true => std::fs::write(&path, text).unwrap(),
        // A second call adds its skills to what the first wrote.
        false => {
            let mut merged = existing;
            for skill in skills {
                if !merged.contains(&format!("[skills.{skill}]")) {
                    merged.push_str(&format!(
                        "\n[skills.{skill}]\nsource = \"local\"\nenabled = true\n"
                    ));
                }
            }
            std::fs::write(&path, merged).unwrap();
        }
    }
}

/// The same files with nothing declaring them — a copy that arrived with a
/// clone rather than through an install.
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
    let root = home.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    git_ok(home, &root, &["init", "--quiet", "-b", "main"]);
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);
    std::fs::write(root.join("a.txt"), "hi\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: base"]);
    root
}

/// A repository under the retired arming: a kendex-hooks directory of the
/// entrypoints that generation wrote, with core.hooksPath pointing at it.
#[allow(clippy::unwrap_used)]
fn retire(home: &Path, root: &Path) -> PathBuf {
    retire_with_leases(home, root, &[root])
}

#[allow(clippy::unwrap_used)]
fn retire_with_leases(home: &Path, root: &Path, leases: &[&Path]) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let retired = root.join(".git/kendex-hooks");
    std::fs::create_dir_all(&retired).unwrap();
    for hook in ["pre-commit", "commit-msg"] {
        let path = retired.join(hook);
        std::fs::write(&path, kendex_core::githooks::entrypoint(hook)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let receipt = kendex_core::githooks::Receipt {
        schema: 1,
        hooks_path: retired.display().to_string(),
        files: ["pre-commit", "commit-msg", "receipt.json"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        leases: leases.iter().map(|p| p.display().to_string()).collect(),
    };
    let mut text = serde_json::to_string_pretty(&receipt).unwrap();
    text.push('\n');
    std::fs::write(retired.join("receipt.json"), text).unwrap();
    git_ok(
        home,
        root,
        &["config", "core.hooksPath", &retired.display().to_string()],
    );
    retired
}

/// A repository with the package installed and its shims armed.
#[allow(clippy::unwrap_used)]
fn armed_repo(home: &Path) -> PathBuf {
    let root = repo(home);
    install_package(&root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));
    root
}
