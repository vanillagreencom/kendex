//! The guard's machine-local env overrides across the product rename:
//! the old spelling still reads, and the current one wins.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn run(home: &Path, cwd: &Path, program: &str, args: &[&str]) -> Output {
    run_with(home, cwd, program, args, &[])
}

/// A process in a clean environment: only HOME, a PATH that finds this
/// build's binary under both its names (`kendex` and the `vstack` alias
/// — consuming repos live through exactly this alias cycle), and
/// whatever `extra` names — the machine-local knobs a test wants to
/// turn.
#[allow(clippy::expect_used)]
fn run_with(
    home: &Path,
    cwd: &Path,
    program: &str,
    args: &[&str],
    extra: &[(&str, &str)],
) -> Output {
    let bin_dir = PathBuf::from(env!("CARGO_BIN_EXE_kendex"))
        .parent()
        .expect("binary has a parent")
        .to_path_buf();
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env(
            "PATH",
            format!(
                "{}:{}",
                bin_dir.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("GIT_CONFIG_NOSYSTEM", "1");
    for (key, value) in extra {
        command.env(key, value);
    }
    command.output().expect("process runs")
}

#[allow(clippy::unwrap_used)]
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

/// The per-check env overrides survive the product rename: the old
/// variable spelling still reads — machine-local knobs are set once and
/// forgotten — and the current one wins when both are set.
#[test]
#[allow(clippy::unwrap_used)]
fn guard_env_overrides_read_both_spellings_and_the_new_one_wins() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    std::fs::write(root.join("src.rs"), format!("// {}{}: later\n", "TO", "DO")).unwrap();
    git_ok(home, &root, &["add", "-A"]);

    let blocked = run(home, &root, "vstack", &["guard", "run", "pre-commit"]);
    assert_eq!(
        blocked.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&blocked.stdout)
    );

    let old_name = run_with(
        home,
        &root,
        "vstack",
        &["guard", "run", "pre-commit"],
        &[("VSTACK_GUARDS_TODO_BAN_ENABLED", "false")],
    );
    assert!(
        old_name.status.success(),
        "the old spelling must still read: {}",
        String::from_utf8_lossy(&old_name.stdout)
    );

    let both = run_with(
        home,
        &root,
        "vstack",
        &["guard", "run", "pre-commit"],
        &[
            ("KENDEX_GUARDS_TODO_BAN_ENABLED", "false"),
            ("VSTACK_GUARDS_TODO_BAN_ENABLED", "true"),
        ],
    );
    assert!(
        both.status.success(),
        "the current name must win: {}",
        String::from_utf8_lossy(&both.stdout)
    );
}
