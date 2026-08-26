//! Real commits through the armed shims, against the real package.
//!
//! The checks are the growth-guards package's shell scripts, so these
//! scenarios install this repository's own copy of that package into a
//! throwaway repo and drive it exactly as a consumer would: `kendex guard
//! install` arms, a plain `git commit` walks through the chain with no
//! harness anywhere, and `kendex` is nowhere in the hook's path once the
//! shims are written. That last part is the whole point of the delegation
//! — a teammate without the binary still commits through the same gate —
//! so it is asserted, not assumed.
#![cfg(unix)]

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

/// A repository with the package installed and its shims armed.
#[allow(clippy::unwrap_used)]
fn armed_repo(home: &Path) -> PathBuf {
    let root = repo(home);
    install_package(&root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));
    root
}

/// The shims are armed, a plain `git commit` runs the package's chain, and
/// a violation the package defines blocks the commit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plain_commit_walks_through_the_packages_chain() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    assert!(root.join(".git/hooks/kendex-guards").is_file());
    let hook = std::fs::read_to_string(root.join(".git/hooks/pre-commit")).unwrap();
    assert!(hook.contains("kendex-guards-hook"), "{hook}");

    std::fs::write(root.join("b.rs"), "// TODO: not yet\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success());
    let text = said(&blocked);
    assert!(text.contains("todo-ban"), "{text}");
}

/// The gate needs no kendex binary. Once the shims are written, git runs
/// committed shell and nothing else — which is what makes a clone of a
/// repository gate commits on a machine that never installed kendex.
#[test]
#[allow(clippy::unwrap_used)]
fn the_armed_gate_still_blocks_with_no_kendex_on_path() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    std::fs::write(root.join("b.rs"), "// FIXME: later\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = run_with(
        home,
        &root,
        "git",
        &["commit", "-m", "feat: adds a marker"],
        &[("PATH", &path_without_binary())],
    );
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));
}

/// The commit-msg lane runs too, on the message file git hands the hook.
#[test]
#[allow(clippy::unwrap_used)]
fn the_message_gate_judges_what_git_passes_the_hook() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    std::fs::write(root.join("b.txt"), "fine\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "not conventional at all"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));

    let ok = git(home, &root, &["commit", "-m", "feat: conventional"]);
    assert!(ok.status.success(), "{}", said(&ok));
}

/// An existing hook keeps its content and its exit status: the package's
/// line goes first and falls through to whatever was already there.
#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_hook_keeps_its_content_and_its_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let existing = root.join(".git/hooks/pre-commit");
    std::fs::write(&existing, "#!/bin/sh\necho theirs ran\nexit 3\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&existing, std::fs::Permissions::from_mode(0o755)).unwrap();

    install_package(&root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));

    let hook = std::fs::read_to_string(&existing).unwrap();
    assert!(hook.contains("echo theirs ran"), "{hook}");
    assert!(hook.contains("kendex-guards-hook"), "{hook}");

    std::fs::write(root.join("b.txt"), "fine\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    // The chain passes, so the existing hook is what git hears from — and
    // its nonzero is what stops the commit. git reports a failed hook as
    // its own exit 1 whatever the hook returned, so the proof the hook
    // decided is that a clean chain still blocked, in its words.
    let blocked = git(home, &root, &["commit", "-m", "feat: clean"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("theirs ran"), "{}", said(&blocked));
    assert!(
        said(&blocked).contains("pre-commit: OK"),
        "the chain itself was clean: {}",
        said(&blocked)
    );
}

/// Disarming removes only the helper and the package's own marked line;
/// the hook someone else wrote survives it.
#[test]
#[allow(clippy::unwrap_used)]
fn disarming_leaves_a_pre_existing_hook_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let existing = root.join(".git/hooks/pre-commit");
    std::fs::write(&existing, "#!/bin/sh\necho theirs ran\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&existing, std::fs::Permissions::from_mode(0o755)).unwrap();
    install_package(&root, &["growth-guards"]);
    run(home, &root, "kendex", &["guard", "install"]);

    let out = run(home, &root, "kendex", &["guard", "uninstall"]);
    assert!(out.status.success(), "{}", said(&out));
    assert!(!root.join(".git/hooks/kendex-guards").exists());
    let hook = std::fs::read_to_string(&existing).unwrap();
    assert!(hook.contains("echo theirs ran"), "{hook}");
    assert!(!hook.contains("kendex-guards-hook"), "{hook}");
}

/// A repository still carrying the retired hooks directory is taken back
/// first: `core.hooksPath` sends git away from `.git/hooks`, so the
/// package's installer would otherwise stand down and arm nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn arming_takes_back_the_retired_hooks_directory_first() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = root.join(".git/kendex-hooks");
    std::fs::create_dir_all(&retired).unwrap();
    use std::os::unix::fs::PermissionsExt;
    for hook in ["pre-commit", "commit-msg"] {
        let path = retired.join(hook);
        std::fs::write(&path, kendex_core::githooks::entrypoint(hook)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    git_ok(
        home,
        &root,
        &["config", "core.hooksPath", &retired.display().to_string()],
    );

    install_package(&root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));
    assert!(said(&install).contains("took back"), "{}", said(&install));
    assert!(!retired.exists());
    assert!(root.join(".git/hooks/kendex-guards").is_file());

    let effective = git(home, &root, &["config", "--get", "core.hooksPath"]);
    assert_eq!(effective.status.code(), Some(1), "the value was unset");
}

/// The stand-in gate, for a repository where nothing has been armed. With
/// no package installed there is nothing to run, and a gate that cannot run
/// refuses rather than passing the commit.
#[test]
#[allow(clippy::unwrap_used)]
fn the_stand_in_gate_refuses_where_the_package_is_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);

    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("growth-guards"), "{}", said(&out));
}

/// With the package installed but no shim armed, the stand-in gate runs the
/// same chain the shim would have.
#[test]
#[allow(clippy::unwrap_used)]
fn the_stand_in_gate_runs_the_same_chain_the_shim_would() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(&root, &["growth-guards"]);
    std::fs::write(root.join("b.rs"), "// TODO: not yet\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);

    let out = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("todo-ban"), "{}", said(&out));
}

/// A sibling gate the work tree carries joins the chain, and one it does
/// not carry is an announced skip rather than a silently missing check.
#[test]
#[allow(clippy::unwrap_used)]
fn sibling_gates_join_the_chain_and_absent_ones_announce_themselves() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(&root, &["growth-guards"]);

    let without = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        said(&without).contains("size-ratchet not installed"),
        "{}",
        said(&without)
    );

    install_package(&root, &["size-ratchet"]);
    let with = run(home, &root, "kendex", &["guard", "run", "pre-commit"]);
    assert!(
        said(&with).contains("=== pre-commit: size-ratchet"),
        "{}",
        said(&with)
    );
    assert!(
        !said(&with).contains("size-ratchet not installed"),
        "{}",
        said(&with)
    );
}

/// `kendex check` folds in the installer's own armed verdict: unarmed is
/// drift the reader can act on, armed says nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reports_whether_the_shims_are_armed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(&root, &["growth-guards"]);

    let unarmed = run(home, &root, "kendex", &["check"]);
    assert_eq!(unarmed.status.code(), Some(1), "{}", said(&unarmed));
    assert!(
        said(&unarmed).contains("commit hooks"),
        "{}",
        said(&unarmed)
    );
    assert!(said(&unarmed).contains("NOT armed"), "{}", said(&unarmed));

    run(home, &root, "kendex", &["guard", "install"]);
    let armed = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&armed).contains("commit hooks"),
        "an armed repo has nothing to report: {}",
        said(&armed)
    );
}
