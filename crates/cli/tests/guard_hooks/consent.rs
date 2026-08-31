//! What may run, and what kendex may say when nothing may.
//!
//! `kendex check` launches a script out of a checkout, unattended, at every
//! session start. These are the fixtures that hold the line it launches it
//! behind — a helper in the hooks directory, which git clones for nobody —
//! and the fixtures that hold kendex to saying only what it read wherever
//! that line stops it.
//!
//! Every marker-file control here is a security boundary's only proof, so
//! each has its positive half beside it: a control that cannot fail has
//! stopped controlling, and this file has already had one.

use crate::test_util::rooted;

use crate::{git_ok, install_package, install_package_undeclared, repo, run, said};

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

/// An installer that says whether anything ran it, in place of the real one.
///
/// The marker path is SINGLE-QUOTED into the script, and the script fails
/// loudly rather than exiting 0 regardless. Both matter, and neither was
/// true when this helper was written: an unquoted temporary path holding a
/// space made `touch` create two files of other names, the `exit 0` after
/// it hid the failure, and the two tests that prove kendex executes nothing
/// then passed whether or not the installer had run. A control for a
/// security boundary that cannot fail is worse than no control.
///
/// `spaced_fixture` is what keeps that honest: every caller builds its
/// fixture under a directory whose name contains a space, so the quoting is
/// exercised on every run rather than on a machine whose temp directory
/// happens to have one.
#[allow(clippy::unwrap_used)]
fn installer_that_announces_itself(root: &std::path::Path, marker: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(
        &installer,
        format!(
            "#!/usr/bin/env bash\ntouch {} || exit 9\nexit 0\n",
            shell_quoted(marker)
        ),
    )
    .unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A path as one shell word, whatever it holds.
#[allow(clippy::unwrap_used)]
fn shell_quoted(path: &std::path::Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

/// A fixture root whose path contains a space.
///
/// Every fixture that writes a shell script gets one, so a quoting defect
/// is a red test here rather than a control that quietly stops controlling.
#[allow(clippy::unwrap_used)]
fn spaced_fixture() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("kendex fixture ")
        .tempdir()
        .unwrap()
}

/// A clone nobody armed executes none of its own code, however loudly it
/// declares this package.
///
/// The whole trust boundary in one fixture. `.kendex-lock.json` sits under
/// the work tree, so a repository can ship one declaring growth-guards as
/// an enabled skill — that is what a real install leaves behind, and what
/// anyone can commit. The hooks directory is the other half, and git clones
/// it for nobody: with no helper in it, nothing here has been licensed, and
/// `kendex check` must reach its verdict from local state alone.
///
/// The marker file is the assertion. A report that merely reads right can
/// be produced by a script that already ran.
#[test]
#[allow(clippy::unwrap_used)]
fn check_runs_nothing_out_of_a_repository_nobody_armed() {
    let tmp = spaced_fixture();
    let home = &rooted(&tmp);
    let root = repo(home);
    // A real install: the lock genuinely declares the package. Nothing is
    // armed, which is the state a fresh clone of such a repository is in.
    install_package(home, &root, &["growth-guards"]);
    assert!(
        !root.join(".git/hooks/kendex-guards").exists(),
        "the fixture is unarmed"
    );
    let marker = home.join("installer-ran");
    installer_that_announces_itself(&root, &marker);

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !marker.exists(),
        "check ran a script out of a repository nobody armed: {}",
        said(&out)
    );
    // And it still says the useful thing, from local state alone.
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(
        said(&out).contains("holds no kendex-guards helper"),
        "{}",
        said(&out)
    );
}

/// An armed repository that declares nothing executes nothing either.
///
/// The other half of the gate, and the one whose failure would be silent:
/// here the package's `--check` would exit 0, so a regression that dropped
/// the declaration test would relay a clean verdict and look exactly like a
/// pass. Only the marker file tells the two apart.
#[test]
#[allow(clippy::unwrap_used)]
fn check_runs_nothing_where_no_project_declared_the_package() {
    let tmp = spaced_fixture();
    let home = &rooted(&tmp);
    let root = repo(home);
    std::fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    install_package_undeclared(&root, &["growth-guards"]);
    arm_by_hand(&root);
    assert!(
        root.join(".git/hooks/kendex-guards").is_file(),
        "the fixture is armed"
    );
    let marker = home.join("installer-ran");
    installer_that_announces_itself(&root, &marker);

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !marker.exists(),
        "check ran the package for a project that never declared it: {}",
        said(&out)
    );
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));
}

/// The positive half of the execution controls: consent given, the
/// announcing installer runs, and the marker is there.
///
/// Without this, the two no-execution tests above rest on a marker file
/// nothing has shown can be written at all — which is exactly how they came
/// to pass vacuously once before, under a fixture path holding a space.
/// Same helper, same spaced root, opposite expectation.
#[test]
#[allow(clippy::unwrap_used)]
fn the_execution_control_writes_its_marker_when_consent_is_given() {
    let tmp = spaced_fixture();
    let home = &rooted(&tmp);
    assert!(
        home.to_string_lossy().contains(' '),
        "the fixture root exercises the quoting: {}",
        home.display()
    );
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    // Consent: the real installer arms the repository, so the helper is
    // there and `kendex check` is licensed to run what it finds.
    arm_by_hand(&root);
    let marker = home.join("installer-ran");
    installer_that_announces_itself(&root, &marker);

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        marker.is_file(),
        "the control cannot detect an installer that ran: {}",
        said(&out)
    );
}

/// A configured hooks path leaves no helper to find, and kendex must not
/// then prescribe the install that stands down there.
///
/// The package refuses to write behind a `core.hooksPath`, so this
/// repository has no helper for the same reason it has no shims. Naming
/// `kendex guard install` here offered a remedy that prints `skipped`,
/// exits 0, writes nothing, and leaves the next check byte-identical — the
/// same line every session with no way to make it stop.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unarmable_repository_is_never_told_to_run_an_install_that_stands_down() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    git_ok(home, &root, &["config", "core.hooksPath", ".githooks"]);

    // The remedy the old line named, run: it stands down and writes nothing.
    let arming = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(arming.status.code(), Some(0), "{}", said(&arming));
    assert!(said(&arming).contains("skipped"), "{}", said(&arming));
    assert!(!root.join(".git/hooks/kendex-guards").exists());

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        !text.contains("kendex guard install"),
        "a remedy that stands down here was prescribed: {text}"
    );
    assert!(
        text.contains("kendex guard check"),
        "the package is not invited to say why: {text}"
    );
}

/// Exit 0 carrying words that are not a verdict is not a clean repository.
///
/// The sibling of the truncated-installer case in `arming`, and the half
/// of it a guard testing for EMPTY stdout could not see. A script that
/// stopped mid-sync after printing something of its own exits 0 with
/// stdout that is not the package's summary, and reading the exit code
/// first reported `all clear` about hooks nobody had looked at.
///
/// The stub prints and exits rather than being a cut of the real script,
/// because what is under test is the shape of what reached stdout: a
/// truncation that happens to print is one way to get here and the arm has
/// to hold for any of them.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn exit_zero_with_words_that_are_not_a_verdict_is_not_all_clear() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: whole and armed is silence, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));

    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(&installer, "#!/usr/bin/env bash\necho loading\nexit 0\n").unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert_eq!(
        out.status.code(),
        Some(2),
        "a repository nobody checked was reported clean: {text}"
    );
    let line = commit_hooks_line(&text);
    assert!(
        line.contains("no verdict"),
        "the line does not say what happened: {line}"
    );
    assert!(
        line.contains("loading"),
        "what the installer did say is not carried: {line}"
    );
}

/// A verdict pointing at stderr arrives with the stderr it points at.
///
/// The same setting as the case above, from the other side of it: armed
/// first, so the helper that licenses the run is already in place, and
/// `core.hooksPath` set after. The package answers exit 2 with a summary
/// line saying git's report of where the setting comes from is on stderr,
/// and `hooks_path_origins` writes those origins and the one remedy there.
/// Relaying the summary by itself printed the pointer and not the thing it
/// points at, on the one report a reader gets at session start.
///
/// Asserted on the single folded line, because both halves travel as one
/// and the bound measures them together.
#[test]
#[allow(clippy::unwrap_used)]
fn a_verdict_that_points_at_stderr_arrives_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));
    assert!(root.join(".git/hooks/kendex-guards").exists());
    git_ok(home, &root, &["config", "core.hooksPath", ".githooks"]);

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert_eq!(out.status.code(), Some(2), "{text}");
    let line = commit_hooks_line(&text);
    assert!(
        line.contains("is on stderr"),
        "the fixture stopped being the pointer case: {line}"
    );
    assert!(
        line.contains("Clear the setting at its source"),
        "the verdict names a report kendex did not print: {line}"
    );
}

/// A hooks directory that cannot be read is a check that could not be
/// taken, never a claim about an armed repository.
///
/// The repository below IS armed — helper and both lanes written by the
/// package's own installer — and only the directory's mode changes. Read as
/// a boolean, the `EACCES` from the helper probe was the same `false` as a
/// plain absence, so kendex announced that nothing had armed a repository
/// whose commits were gated perfectly well.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_hooks_directory_is_could_not_check_not_a_not_armed_claim() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: armed and readable is silence, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));

    let hooks = root.join(".git/hooks");
    assert!(
        hooks.join("kendex-guards").is_file(),
        "the fixture is armed"
    );
    std::fs::set_permissions(&hooks, std::fs::Permissions::from_mode(0o000)).unwrap();
    if std::fs::read_dir(&hooks).is_ok() {
        // Permission bits do not stop this process — running as root, where
        // there is no unreadable directory to build.
        std::fs::set_permissions(&hooks, std::fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }
    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    let code = out.status.code();
    std::fs::set_permissions(&hooks, std::fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(code, Some(2), "could-not-check was not reported: {text}");
    assert!(
        !text.contains("holds no kendex-guards helper"),
        "an unreadable directory read as an unarmed repository: {text}"
    );
    assert!(
        text.contains("could not be checked"),
        "the line does not say the check could not be taken: {text}"
    );
}

/// A skills directory that will not open is a search that did not happen,
/// never evidence that nothing is rendered.
///
/// "The package is declared and its scripts are not there" is a definite
/// claim with a definite remedy, and the only thing that supports it is
/// every candidate answering `NotFound`. A directory the search could not
/// enter holds an unknown number of copies, so folding it into "nothing
/// here" prescribes `kendex refresh` for a repository nobody looked at —
/// the same shape as reading `EACCES` off the hooks directory as unarmed.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_skills_directory_it_cannot_read_is_could_not_check_not_a_missing_render() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The render goes, which is the state whose remedy is an apply. The
    // lock still declares the package and the shims are still armed, so
    // the fold reaches the search.
    for base in kendex_core::guard::SEARCH_ROOTS {
        let copy = root.join(base).join(kendex_core::guard::SKILL);
        match copy.is_symlink() {
            true => std::fs::remove_file(&copy).unwrap(),
            false if copy.exists() => std::fs::remove_dir_all(&copy).unwrap(),
            false => {}
        }
    }
    // The control: with every root readable, this is the missing-render
    // verdict and its remedy.
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    assert!(
        commit_hooks_line(&said(&out)).contains("kendex refresh"),
        "{}",
        said(&out)
    );

    // One searched root, unopenable. Nothing else changes.
    let locked = root.join(".agents/skills");
    std::fs::create_dir_all(&locked).unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    if std::fs::read_dir(&locked).is_ok() {
        // Permission bits do not stop this process — running as root, where
        // there is no unreadable directory to build.
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }
    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    let code = out.status.code();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(code, Some(2), "could-not-check was not reported: {text}");
    // The commit-hooks line only. The drift report's own missing-on-disk
    // section names the same remedy for the deleted render, and that line
    // is true — what must not appear is a claim about the hooks made off a
    // search that never happened.
    let line = commit_hooks_line(&text);
    assert!(
        !line.contains("kendex refresh"),
        "an unreadable directory was reported as a repository with no render: {line}"
    );
    assert!(
        line.contains("could not be checked"),
        "the line does not say the check could not be taken: {line}"
    );
}

/// The one indented line under the report's `commit hooks:` heading.
#[allow(clippy::expect_used)]
fn commit_hooks_line(text: &str) -> String {
    text.lines()
        .skip_while(|line| !line.starts_with("commit hooks:"))
        .nth(1)
        .expect("the report carries a commit hooks line")
        .to_owned()
}
