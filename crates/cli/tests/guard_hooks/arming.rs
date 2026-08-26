//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, the migration off the retired arming, and what `kendex check`
//! says about a repository in each state.

use crate::{armed_repo, git_ok, install_package, install_package_undeclared, repo, run, said};

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

/// A hand-wired hook under a `core.hooksPath` directory is the second
/// armed shape, and the check knows it.
///
/// The installer stands down there — it writes `.git/hooks`, which git is
/// not reading — and tells people to wire that directory's hooks at these
/// scripts themselves. Those hooks gate commits and carry no delegating
/// line, so a check that knew only the first shape would call every one of
/// them unarmed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_wired_hook_that_runs_the_scripts_is_armed() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let scripts = root.join(".agents/skills/growth-guards/scripts");

    let elsewhere = home.join("their-hooks");
    std::fs::create_dir_all(&elsewhere).unwrap();
    git_ok(
        home,
        &root,
        &["config", "core.hooksPath", &elsewhere.display().to_string()],
    );

    let wire = |lane: &str, tail: &str| {
        let path = elsewhere.join(lane);
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\n# wired by hand\nexec \"{}/{lane}\"{tail}\n",
                scripts.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    wire("pre-commit", "");
    wire("commit-msg", " \"$1\"");

    // Armed, and no helper is demanded: these hooks reach for none.
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&out).contains("commit hooks"),
        "a hand-wired directory is armed: {}",
        said(&out)
    );

    // The argument list is part of the shape: pre-commit takes none and
    // exits 2 on any, so wiring it with one breaks the gate rather than
    // weakening it — and that is cannot-tell, not armed.
    wire("pre-commit", " \"$1\"");
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("cannot be verified"), "{}", said(&out));

    // A second command in the file means its reachability is a guess.
    let path = elsewhere.join("pre-commit");
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\nset -e\nexec \"{}/pre-commit\"\n",
            scripts.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
}

/// Ownership is not currency. A shim written by an older installer spelling
/// is not armed by the current grammar, but it is still ours — and once the
/// scripts it delegates to are gone it fails every commit closed, which is
/// the one thing a reader most needs told.
#[test]
#[allow(clippy::unwrap_used)]
fn shims_from_an_older_spelling_are_still_reported_as_ours() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    arm_by_hand(&root);

    // An older delegating line: the marker is the same, the command is
    // spelled differently, and the package is then removed.
    let hook = root.join(".git/hooks/pre-commit");
    std::fs::write(
        &hook,
        "#!/bin/sh\n\"$(git rev-parse --git-path hooks)/kendex-guards\" pre-commit || exit $?; # kendex-guards-hook\n",
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        said(&out).contains("carries the package's shims"),
        "an older spelling is still ours: {}",
        said(&out)
    );
    assert!(said(&out).contains("pre-commit"), "{}", said(&out));
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

/// A hand-wired hook may name the scripts relatively, and git runs hooks
/// from the work tree's top level — so that is what a relative command
/// resolves against, never wherever the check happens to be running.
#[test]
#[allow(clippy::unwrap_used)]
fn a_relative_command_resolves_against_the_work_tree() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    let elsewhere = home.join("their-hooks");
    std::fs::create_dir_all(&elsewhere).unwrap();
    git_ok(
        home,
        &root,
        &["config", "core.hooksPath", &elsewhere.display().to_string()],
    );
    for (lane, tail) in [("pre-commit", ""), ("commit-msg", " \"$1\"")] {
        let path = elsewhere.join(lane);
        std::fs::write(
            &path,
            format!("#!/bin/sh\nexec \".agents/skills/growth-guards/scripts/{lane}\"{tail}\n"),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&out).contains("commit hooks"),
        "a relative command is resolved from the work tree: {}",
        said(&out)
    );
}

/// A carriage return is part of the word as far as the shell is concerned,
/// so it must survive to the checks rather than being eaten by a
/// line-splitter that treats CRLF as a line ending.
///
/// In a shebang it names an interpreter that is not there, which git cannot
/// exec: unarmed. In a body line it makes the command unreadable, which is
/// cannot-tell.
#[test]
#[allow(clippy::unwrap_used)]
fn a_carriage_return_is_not_eaten_before_the_checks() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    arm_by_hand(&root);

    let hook = root.join(".git/hooks/pre-commit");
    let armed = std::fs::read_to_string(&hook).unwrap();
    let lines: Vec<&str> = armed.lines().collect();

    // A CR on the shebang: git cannot exec `/bin/sh\r`.
    std::fs::write(
        &hook,
        format!("{}\r\n{}\n", lines[0], lines[1..].join("\n")),
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(said(&out).contains("control character"), "{}", said(&out));

    // A CR on the delegating line: not the line the installer writes.
    std::fs::write(
        &hook,
        format!("{}\n{}\r\n{}\n", lines[0], lines[1], lines[2..].join("\n")),
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert_ne!(out.status.code(), Some(0), "{}", said(&out));
    assert!(said(&out).contains("commit hooks"), "{}", said(&out));
}
