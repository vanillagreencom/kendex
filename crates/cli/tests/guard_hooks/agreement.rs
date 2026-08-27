//! The two check engines, over one set of repositories.
//!
//! kendex reads hook files natively and the package reads them in shell, and
//! the shell one is the engine of record — it runs on a machine that never
//! installed kendex. Two implementations of one grammar drift, and this is
//! how that drift was found every time: a fix landed on one side, the other
//! kept the bug, and a review round later somebody noticed.
//!
//! So neither is described here. Each fixture is a repository in a state
//! that has been got wrong at least once, and the pin is that both engines
//! say the same thing about it. What that thing is belongs to the suites
//! that test each engine; agreeing is what belongs here.

use std::path::{Path, PathBuf};

use crate::{git_ok, install_package, repo, run, run_with, said};

/// What a check says, coarse enough to compare across two engines that word
/// their findings differently and fine enough that no drift hides inside a
/// bucket.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Verdict {
    Armed,
    NotArmed,
    CannotTell,
}

/// The package's own answer: its exit codes ARE the contract.
#[allow(clippy::unwrap_used)]
fn package_says(home: &Path, root: &Path) -> Verdict {
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let out = run_with(
        home,
        root,
        installer.to_str().unwrap(),
        &["--repo", root.to_str().unwrap(), "--check"],
        &[],
    );
    match out.status.code() {
        Some(0) => Verdict::Armed,
        Some(1) => Verdict::NotArmed,
        _ => Verdict::CannotTell,
    }
}

/// kendex's answer, read out of what it reports rather than its exit code:
/// `check` covers more than hooks, and only the hook lines are this pin's
/// business.
fn kendex_says(home: &Path, root: &Path) -> Verdict {
    let out = said(&run(home, root, "kendex", &["check"]));
    let hooks: Vec<&str> = out
        .lines()
        .filter(|line| line.contains("commit hooks"))
        .collect();
    if hooks.is_empty() {
        return Verdict::Armed;
    }
    let text = hooks.join(" ");
    match text.contains("cannot be verified") || text.contains("could not") {
        true => Verdict::CannotTell,
        false => Verdict::NotArmed,
    }
}

#[allow(clippy::unwrap_used)]
fn armed_fixture(home: &Path) -> PathBuf {
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));
    root
}

fn scripts(root: &Path) -> PathBuf {
    root.join(".agents/skills/growth-guards/scripts")
}

#[allow(clippy::unwrap_used)]
fn unexecutable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644)).unwrap();
}

/// Every state below has been reported as armed by one engine while the
/// other knew better, or would have been before the fix that landed with
/// this test. The pin is agreement, in whichever direction is right.
#[test]
#[allow(clippy::unwrap_used)]
fn both_engines_agree_about_every_repository() {
    let cases: Vec<(&str, fn(&Path, &Path))> = vec![
        // Nothing touched: the control. Without it a predicate that answered
        // the same wrong thing on both sides would still pass every row.
        ("armed", |_home, _root| {}),
        // A delegated lane the helper cannot run. The helper is still ours
        // byte for byte, so only asking about the lanes catches it.
        ("lane-missing", |_home, root| {
            std::fs::remove_file(scripts(root).join("commit-msg")).unwrap();
        }),
        ("lane-unexecutable", |_home, root| {
            unexecutable(&scripts(root).join("pre-commit"));
        }),
        // Hooks switched off, where git reports `./` and both engines could
        // measure the repository root in place of a directory git ignores.
        ("hooks-off", |home, root| {
            git_ok(home, root, &["config", "core.hooksPath", ""]);
        }),
        // The default directory named explicitly, in a spelling that only
        // matches after folding.
        ("default-traversed", |home, root| {
            let value = root.join(".git/refs/../hooks").display().to_string();
            git_ok(home, root, &["config", "core.hooksPath", &value]);
        }),
        // A hook someone wired by hand, which only the redirected-directory
        // grammar accepts.
        ("hand-wired", |home, root| {
            use std::os::unix::fs::PermissionsExt;
            let dir = root.join("customhooks");
            std::fs::create_dir_all(&dir).unwrap();
            let s = scripts(root);
            std::fs::write(
                dir.join("pre-commit"),
                format!("#!/bin/sh\nexec {}/pre-commit\n", s.display()),
            )
            .unwrap();
            std::fs::write(
                dir.join("commit-msg"),
                format!("#!/bin/sh\nexec {}/commit-msg \"$1\"\n", s.display()),
            )
            .unwrap();
            for lane in ["pre-commit", "commit-msg"] {
                std::fs::set_permissions(dir.join(lane), std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            git_ok(home, root, &["config", "core.hooksPath", "customhooks"]);
        }),
        // A hand-wired command word carrying one backslash: the shell drops
        // it and runs a different path, so neither engine may call this
        // armed on the strength of the spelling.
        ("hand-wired-escaped", |home, root| {
            use std::os::unix::fs::PermissionsExt;
            let dir = root.join("customhooks");
            std::fs::create_dir_all(&dir).unwrap();
            let s = scripts(root);
            std::fs::write(
                dir.join("pre-commit"),
                format!("#!/bin/sh\nexec {}/pre\\-commit\n", s.display()),
            )
            .unwrap();
            std::fs::write(
                dir.join("commit-msg"),
                format!("#!/bin/sh\nexec {}/commit-msg \"$1\"\n", s.display()),
            )
            .unwrap();
            for lane in ["pre-commit", "commit-msg"] {
                std::fs::set_permissions(dir.join(lane), std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            git_ok(home, root, &["config", "core.hooksPath", "customhooks"]);
        }),
    ];

    let mut disagreed = Vec::new();
    for (name, arrange) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let root = armed_fixture(home);
        arrange(home, &root);
        let package = package_says(home, &root);
        let native = kendex_says(home, &root);
        if package != native {
            disagreed.push(format!(
                "{name}: package says {package:?}, kendex says {native:?}"
            ));
        }
    }
    assert!(
        disagreed.is_empty(),
        "the two check engines disagree, so one of them is wrong:\n  {}",
        disagreed.join("\n  ")
    );
}
