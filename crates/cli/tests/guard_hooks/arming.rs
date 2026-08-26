//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, the migration off the retired arming, and what `kendex check`
//! says about a repository in each state.

use crate::{armed_repo, install_package, install_package_undeclared, repo, run, said};

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
    install_package(home, &root, &["growth-guards"]);
    run(home, &root, "kendex", &["guard", "install"]);

    let out = run(home, &root, "kendex", &["guard", "uninstall"]);
    assert!(out.status.success(), "{}", said(&out));
    assert!(!root.join(".git/hooks/kendex-guards").exists());
    let hook = std::fs::read_to_string(&existing).unwrap();
    assert!(hook.contains("echo theirs ran"), "{hook}");
    assert!(!hook.contains("kendex-guards-hook"), "{hook}");
}

/// `kendex check` folds in the installer's own armed verdict: unarmed is
/// drift the reader can act on, armed says nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reports_whether_the_shims_are_armed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    let unarmed = run(home, &root, "kendex", &["check"]);
    assert_eq!(unarmed.status.code(), Some(1), "{}", said(&unarmed));
    assert!(
        said(&unarmed).contains("commit hooks"),
        "{}",
        said(&unarmed)
    );
    assert!(said(&unarmed).contains("not armed"), "{}", said(&unarmed));

    run(home, &root, "kendex", &["guard", "install"]);
    let armed = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&armed).contains("commit hooks"),
        "an armed repo has nothing to report: {}",
        said(&armed)
    );
}

/// Disarming with the package already gone is exit 2, not a clean removal:
/// its shims may still be there, failing closed on every commit.
#[test]
#[allow(clippy::unwrap_used)]
fn disarming_without_the_package_is_a_refusal_that_names_the_shims() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    let out = run(home, &root, "kendex", &["guard", "uninstall"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("kendex-guards"), "{}", said(&out));
}

/// `kendex check` sees the same stale shims: a repository whose package was
/// removed before disarming blocks every commit, and a check that called
/// that clean would be the one report nobody could act on.
#[test]
#[allow(clippy::unwrap_used)]
fn check_names_shims_left_without_a_package() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("commit hooks"), "{}", said(&out));
    assert!(
        said(&out).contains("carries the package's shims"),
        "{}",
        said(&out)
    );
}

/// Outside any repository there is no verdict to give. A git that could not
/// run is a different answer: the check says so rather than reading as
/// clean.
#[test]
#[allow(clippy::unwrap_used)]
fn check_is_silent_outside_a_repository_and_loud_when_it_cannot_look() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let plain = home.join("plain");
    std::fs::create_dir_all(&plain).unwrap();

    let out = run(home, &plain, "kendex", &["check"]);
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));
}

/// A repository git refuses to read is a check that could not be taken, not
/// an absent one. Dubious ownership is git's own exit 128, the same status a
/// missing repository gives, so only git's wording tells them apart.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repository_git_refuses_is_could_not_check_not_silence() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    // A config git cannot parse: exit 128 with a complaint that is not
    // "not a git repository".
    std::fs::write(root.join(".git/config"), "[core\nbroken\n").unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(!said(&out).is_empty(), "the failure is reported");
}

/// A repository with nothing of the package's in it says nothing, declared
/// or not — there is no shim to inspect and no gate expected.
#[test]
#[allow(clippy::unwrap_used)]
fn check_is_silent_about_an_undeclared_package_that_armed_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package_undeclared(&root, &["growth-guards"]);

    let out = run(home, &root, "kendex", &["check"]);
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));
}

/// `kendex check` reads the hook files and never runs anything out of the
/// repository — a clone's status must not execute its author's code.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reads_the_hooks_and_runs_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    // Unarmed, with the package installed: reported, read natively.
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("not armed"), "{}", said(&out));

    // Armed for real, then the installer swapped for one that proves
    // whether anything ran it. Armed is the interesting case: that is when
    // a check tempted to ask the package would ask.
    arm_by_hand(&root);
    let marker = home.join("checker-ran");
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(
        &installer,
        format!("#!/usr/bin/env bash\ntouch {}\nexit 0\n", marker.display()),
    )
    .unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));
    assert!(!marker.exists(), "check ran the repository's script");
}

/// A verdict about hooks is a verdict about what git runs.
///
/// git runs hooks by name, and nothing is named `kendex-guards` — so a
/// helper left behind on its own blocks no commit. Neither does a file that
/// merely mentions the marker, nor a hook without its execute bit, which
/// git skips in silence.
#[test]
#[allow(clippy::unwrap_used)]
fn only_a_hook_git_would_run_counts_as_armed() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let hooks = root.join(".git/hooks");

    std::fs::write(hooks.join("kendex-guards"), "#!/bin/sh\nexit 0\n").unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        said(&out).contains("not armed"),
        "a lone helper arms nothing: {}",
        said(&out)
    );

    let hook = hooks.join("pre-commit");
    std::fs::write(
        &hook,
        "#!/bin/sh\n# kendex-guards-hook once lived here\nexit 0\n",
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        said(&out).contains("not armed"),
        "a comment is not a delegating hook: {}",
        said(&out)
    );

    // The real shapes. The planted helper and hook are not ones the
    // installer will overwrite — it refuses a helper it did not write — so
    // they go first.
    std::fs::remove_file(hooks.join("kendex-guards")).unwrap();
    std::fs::remove_file(&hook).unwrap();
    arm_by_hand(&root);
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&out).contains("commit hooks"),
        "armed: {}",
        said(&out)
    );

    // git skips a hook it cannot execute, in silence, so that lane is not
    // armed however intact its content looks.
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o644)).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(
        said(&out).contains("pre-commit is not executable"),
        "the unexecutable lane is the one named: {}",
        said(&out)
    );
}

/// The interpreter decides whether a hook's body runs at all, so it is
/// judged by full path and nothing else.
///
/// `#!/bin/sh -n` reads the guard line and executes none of it: a hook that
/// looks perfectly armed and gates no commit. `#!/usr/bin/env bash`
/// resolves through PATH, so what runs is whatever PATH says today. Neither
/// is unarmed — they may gate fine — so both are cannot-tell.
#[test]
#[allow(clippy::unwrap_used)]
fn an_interpreter_this_cannot_vouch_for_is_cannot_tell() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    arm_by_hand(&root);

    // Armed: nothing to report.
    let out = run(home, &root, "kendex", &["check"]);
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));

    let hook = root.join(".git/hooks/pre-commit");
    let armed = std::fs::read_to_string(&hook).unwrap();
    for shebang in ["#!/bin/sh -n", "#!/usr/bin/env bash", "#!/opt/weird/sh"] {
        let rest: Vec<&str> = armed.lines().skip(1).collect();
        std::fs::write(&hook, format!("{shebang}\n{}\n", rest.join("\n"))).unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        let out = run(home, &root, "kendex", &["check"]);
        assert_eq!(
            out.status.code(),
            Some(2),
            "{shebang} should be cannot-tell: {}",
            said(&out)
        );
        assert!(
            said(&out).contains("cannot be verified"),
            "{shebang}: {}",
            said(&out)
        );
    }
}

/// Arm through the package's own installer.
///
/// Not a hand-written approximation: the check compares against the exact
/// bytes that installer writes, so a fixture that guesses at them is
/// testing the guess. This is the same call `kendex guard install` makes.
#[allow(clippy::unwrap_used)]
fn arm_by_hand(root: &std::path::Path) {
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let out = std::process::Command::new(&installer)
        .args(["--repo", &root.to_string_lossy()])
        // Run from the fixture: git's own environment reaches this child,
        // and a test binary invoked from another checkout would otherwise
        // hand it that repository.
        .current_dir(root)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "install-git-hooks: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}
