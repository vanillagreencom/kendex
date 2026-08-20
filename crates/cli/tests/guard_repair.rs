//! A repo the vstack-named binary armed keeps committing through the
//! alias, and `kendex guard repair` rewrites its entrypoints to call
//! kendex — in place: the `vstack-hooks` directory, `core.hooksPath`,
//! and the receipt all stay where the old install put them.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::githooks;

/// A process in a clean environment whose PATH carries this build's
/// binary under both names — old entrypoints call `vstack`, new ones
/// call `kendex`, and the alias cycle serves both.
#[allow(clippy::expect_used)]
fn run(home: &Path, cwd: &Path, program: &str, args: &[&str]) -> Output {
    let built = PathBuf::from(env!("CARGO_BIN_EXE_kendex"));
    let bin_dir = built.parent().expect("binary has a parent").to_path_buf();
    Command::new(program)
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
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("process runs")
}

fn git(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    run(home, cwd, "git", args)
}

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
fn repair_upgrades_an_old_generation_install_without_moving_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let hooks_dir = root.join(".git/vstack-hooks");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    use std::os::unix::fs::PermissionsExt;
    for hook in githooks::HOOKS {
        let path = hooks_dir.join(hook);
        std::fs::write(&path, githooks::old_entrypoint(hook)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let receipt = githooks::Receipt {
        schema: 1,
        hooks_path: hooks_dir.display().to_string(),
        files: githooks::HOOKS
            .iter()
            .map(|name| (*name).to_owned())
            .chain(std::iter::once("receipt.json".to_owned()))
            .collect(),
        leases: [root.canonicalize().unwrap().display().to_string()].into(),
    };
    std::fs::write(
        hooks_dir.join("receipt.json"),
        serde_json::to_string_pretty(&receipt).unwrap(),
    )
    .unwrap();
    let hooks_path = hooks_dir.display().to_string();
    git_ok(home, &root, &["config", "core.hooksPath", &hooks_path]);

    // The old entrypoints still gate commits: the alias answers for them.
    std::fs::write(root.join("b.txt"), "b\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let bad = git(home, &root, &["commit", "-m", "not conventional"]);
    assert!(
        !bad.status.success(),
        "the old-generation hook still gates: {bad:?}"
    );
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: add b"]);

    let repaired = run(home, &root, "kendex", &["guard", "repair"]);
    assert!(
        repaired.status.success(),
        "stdout: {} stderr: {}",
        String::from_utf8_lossy(&repaired.stdout),
        String::from_utf8_lossy(&repaired.stderr)
    );
    for hook in githooks::HOOKS {
        assert_eq!(
            std::fs::read_to_string(hooks_dir.join(hook)).unwrap(),
            githooks::entrypoint(hook),
            "{hook} rewritten to call kendex"
        );
    }
    assert_eq!(
        String::from_utf8_lossy(&git(home, &root, &["config", "--get", "core.hooksPath"]).stdout)
            .trim(),
        hooks_path,
        "core.hooksPath still names the old directory"
    );

    // And commits keep flowing through the rewritten entrypoints.
    std::fs::write(root.join("c.txt"), "c\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let bad = git(home, &root, &["commit", "-m", "still not conventional"]);
    assert!(!bad.status.success(), "the rewritten hook gates");
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: add c"]);
}
