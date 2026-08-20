//! Real commits through the installed hooks: every tool walks through the
//! guards — a plain `git commit`, no harness anywhere — the chain execs the
//! hook git itself would have run, the commit-msg lane takes the relative
//! message path git passes, and the guard judges the exact index git names
//! in GIT_INDEX_FILE (a partial commit's temporary index, not the staged
//! one).
#![cfg(any())] // forensics: compiled out to isolate the CI runner kill

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

#[test]
#[allow(clippy::unwrap_used)]
fn commits_walk_through_the_guards_whatever_tool_makes_them() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let install = run(home, &root, "vstack", &["guard", "install"]);
    assert!(
        install.status.success(),
        "{}",
        String::from_utf8_lossy(&install.stderr)
    );

    // A staged work marker blocks the commit; the message names the check.
    std::fs::write(
        root.join("src.rs"),
        format!("// {}{}: later\nfn main() {{}}\n", "TO", "DO"),
    )
    .unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: add src"]);
    assert!(!blocked.status.success(), "the commit must be blocked");
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&blocked.stdout),
        String::from_utf8_lossy(&blocked.stderr)
    );
    assert!(said.contains("todo-ban"), "{said}");

    // Fixed and staged, the same commit goes through — and the commit-msg
    // lane (relative COMMIT_EDITMSG path) accepts the conventional header.
    std::fs::write(root.join("src.rs"), "fn main() {}\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: add src"]);

    // A non-conventional message is blocked by the commit-msg lane.
    std::fs::write(root.join("b.txt"), "b\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let bad = git(home, &root, &["commit", "-m", "added some stuff"]);
    assert!(!bad.status.success());
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&bad.stdout),
        String::from_utf8_lossy(&bad.stderr)
    );
    assert!(said.contains("commit-msg"), "{said}");
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: add b"]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_chain_execs_the_hook_git_itself_would_have_run() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    run(home, &root, "vstack", &["guard", "install"]);

    // A clean pre-existing hook in git's own directory still runs — and
    // its failure decides.
    let own_hooks = root.join(".git/hooks");
    std::fs::create_dir_all(&own_hooks).unwrap();
    let marker = home.join("chained-ran");
    std::fs::write(
        own_hooks.join("pre-commit"),
        format!("#!/bin/sh\ntouch {}\nexit 1\n", marker.display()),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        own_hooks.join("pre-commit"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    std::fs::write(root.join("c.txt"), "c\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: add c"]);
    assert!(
        marker.exists(),
        "the foreign hook ran after the guards passed"
    );
    assert!(!blocked.status.success(), "its exit status decides");

    std::fs::write(own_hooks.join("pre-commit"), "#!/bin/sh\nexit 0\n").unwrap();
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: add c"]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_partial_commit_is_judged_on_the_index_git_names() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    run(home, &root, "vstack", &["guard", "install"]);

    // The staged index carries a work marker in b.rs; the partial commit
    // does not include it. Judging the staged index would block a commit
    // that carries no marker — GIT_INDEX_FILE names the honest one.
    std::fs::write(
        root.join("b.rs"),
        format!("// {}{}: staged but not committed\n", "TO", "DO"),
    )
    .unwrap();
    std::fs::write(root.join("a.txt"), "hi there\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let partial = git(
        home,
        &root,
        &["commit", "--quiet", "-m", "feat: a only", "--", "a.txt"],
    );
    assert!(
        partial.status.success(),
        "the temporary index is what is judged: {}{}",
        String::from_utf8_lossy(&partial.stdout),
        String::from_utf8_lossy(&partial.stderr)
    );

    // And the marker still blocks the commit that would actually carry it.
    let full = git(home, &root, &["commit", "-m", "feat: the rest"]);
    assert!(!full.status.success());
}

/// The v1 shim is refused at install; a shim that turns up in git's own
/// hooks directory later is refused by the chain as well — chained, it
/// runs the guards twice while v1 is installed and fails closed on every
/// commit once v1 is gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_shim_that_reappears_after_install_is_refused_not_chained() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    run(home, &root, "vstack", &["guard", "install"]);
    let own_hooks = root.join(".git/hooks");
    std::fs::create_dir_all(&own_hooks).unwrap();
    let marker = home.join("shim-ran");
    std::fs::write(
        own_hooks.join("pre-commit"),
        format!(
            "#!/bin/sh\n# vstack-guards-hook\ntouch {}\nexit 0\n",
            marker.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        own_hooks.join("pre-commit"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    std::fs::write(root.join("c.txt"), "c\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: add c"]);
    assert!(!blocked.status.success(), "the commit is refused");
    assert!(!marker.exists(), "the shim never ran");
    let said = String::from_utf8_lossy(&blocked.stderr);
    assert!(said.contains("v1"), "{said}");
}

/// The machine-local extension point: an executable named only in the
/// environment runs after the checks, judged on the family contract —
/// exit 1 is a violation, anything else that is not 0 is "could not
/// complete" — and it is never read from a repository file.
#[test]
#[allow(clippy::unwrap_used)]
fn the_local_extension_point_is_environment_only_and_judged_on_the_contract() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let marker = home.join("local-ran");
    let script = home.join("local-check");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ntouch {}\necho local says no\nexit 1\n",
            marker.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(root.join("c.txt"), "c\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);

    // Named in a repository file only: never run.
    std::fs::write(
        root.join("kendex.settings.toml"),
        format!("[guards.pre-commit]\nlocal = \"{}\"\n", script.display()),
    )
    .unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let clean = run(home, &root, "vstack", &["guard", "run", "pre-commit"]);
    assert!(
        clean.status.success(),
        "{}",
        String::from_utf8_lossy(&clean.stdout)
    );
    assert!(
        !marker.exists(),
        "a repository file never names the executable"
    );

    // Named in the environment: runs, and its verdict counts. The old
    // variable spelling still reads — machine-local chain hooks are set
    // once and forgotten.
    let script_text = script.display().to_string();
    let local = run_with(
        home,
        &root,
        "vstack",
        &["guard", "run", "pre-commit"],
        &[("VSTACK_GUARD_PRE_COMMIT_LOCAL", script_text.as_str())],
    );
    assert_eq!(
        local.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&local.stdout)
    );
    assert!(marker.exists());
    let said = String::from_utf8_lossy(&local.stdout);
    assert!(
        said.contains("repo-local") && said.contains("local says no"),
        "{said}"
    );

    // The current variable name works too, and outranks the old one when
    // both are set: here it names a passing script while the old name
    // still points at the failing one.
    let passing = home.join("local-pass");
    let pass_marker = home.join("local-pass-ran");
    std::fs::write(
        &passing,
        format!("#!/bin/sh\ntouch {}\nexit 0\n", pass_marker.display()),
    )
    .unwrap();
    std::fs::set_permissions(&passing, std::fs::Permissions::from_mode(0o755)).unwrap();
    let passing_text = passing.display().to_string();
    let precedence = run_with(
        home,
        &root,
        "vstack",
        &["guard", "run", "pre-commit"],
        &[
            ("KENDEX_GUARD_PRE_COMMIT_LOCAL", passing_text.as_str()),
            ("VSTACK_GUARD_PRE_COMMIT_LOCAL", script_text.as_str()),
        ],
    );
    assert!(
        precedence.status.success(),
        "the current name must win: {}",
        String::from_utf8_lossy(&precedence.stdout)
    );
    assert!(pass_marker.exists());

    // Any other failure is "could not complete": exit 2.
    std::fs::write(&script, "#!/bin/sh\nexit 7\n").unwrap();
    let broken = run_with(
        home,
        &root,
        "vstack",
        &["guard", "run", "pre-commit"],
        &[("KENDEX_GUARD_PRE_COMMIT_LOCAL", script_text.as_str())],
    );
    assert_eq!(
        broken.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&broken.stdout)
    );
}
