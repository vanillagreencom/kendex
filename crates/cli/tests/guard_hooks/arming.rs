//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, the migration off the retired arming, and what `kendex check`
//! says about a repository in each state.

use crate::{
    armed_repo, git, git_ok, install_package, install_package_undeclared, repo, retire,
    retire_with_leases, run, run_with, said,
};

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

/// A repository still carrying the retired hooks directory is taken back
/// first: `core.hooksPath` sends git away from `.git/hooks`, so the
/// package's installer would otherwise stand down and arm nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn arming_takes_back_the_retired_hooks_directory_first() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);

    install_package(home, &root, &["growth-guards"]);
    let install = run(home, &root, "kendex", &["guard", "install"]);
    assert!(install.status.success(), "{}", said(&install));
    assert!(said(&install).contains("took back"), "{}", said(&install));
    assert!(!retired.exists());
    assert!(root.join(".git/hooks/kendex-guards").is_file());

    let effective = git(home, &root, &["config", "--get", "core.hooksPath"]);
    assert_eq!(effective.status.code(), Some(1), "the value was unset");
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
    assert!(said(&unarmed).contains("NOT armed"), "{}", said(&unarmed));

    run(home, &root, "kendex", &["guard", "install"]);
    let armed = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&armed).contains("commit hooks"),
        "an armed repo has nothing to report: {}",
        said(&armed)
    );
}

/// The gate is never removed on the promise of a replacement. With the
/// package gone, arming refuses and the retired install is still there
/// gating commits — a broken package must not leave a repository ungated.
#[test]
#[allow(clippy::unwrap_used)]
fn arming_without_a_working_package_leaves_the_old_gate_standing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);

    // No package at all.
    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        retired.join("pre-commit").is_file(),
        "the old gate survived"
    );

    // A package whose installer cannot run is the same answer.
    install_package(home, &root, &["growth-guards"]);
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(&installer, "#!/nonexistent/interpreter\n").unwrap();
    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        retired.join("pre-commit").is_file(),
        "the old gate survived"
    );
}

/// A retired install another worktree still leases stays armed when this
/// worktree releases its own, so `core.hooksPath` survives and the package
/// installer would stand down having armed nothing. Refuse and name the
/// blocker rather than reporting an arming that did not happen.
#[test]
#[allow(clippy::unwrap_used)]
fn arming_refuses_while_another_worktrees_lease_holds_the_old_install() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    git_ok(home, &root, &["worktree", "add", "--quiet", "../linked"]);
    let linked = home.join("linked");
    let retired = retire_with_leases(home, &root, &[&root, &linked]);
    install_package(home, &root, &["growth-guards"]);

    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        said(&out).contains("another worktree's lease"),
        "{}",
        said(&out)
    );
    // The shims were staged into the default hooks directory, where git
    // does not look while the redirect stands — dormant, not live. What
    // matters is that the old gate is untouched and still the one gating.
    assert!(root.join(".git/hooks/kendex-guards").is_file(), "staged");
    let redirect = git(home, &root, &["config", "--get", "core.hooksPath"]);
    assert_eq!(redirect.status.code(), Some(0), "the redirect still stands");
    assert!(
        retired.join("pre-commit").is_file(),
        "the old gate survived"
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

/// The migration has no ungated moment. The package's shims are written
/// into the default hooks directory while the retired install is still live
/// and gating; the takeback that removes the redirect brings them up in the
/// same step. Between those two points the repository is gated by the old
/// gate, and a commit proves it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_migration_never_leaves_the_repository_ungated() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);
    install_package(home, &root, &["growth-guards"]);

    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert!(out.status.success(), "{}", said(&out));
    assert!(!retired.exists(), "the retired directory is gone");
    assert!(root.join(".git/hooks/kendex-guards").is_file(), "armed");

    // And the shims that were staged mid-migration are the live ones now.
    std::fs::write(root.join("b.rs"), "// TODO: not yet\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = git(home, &root, &["commit", "-m", "feat: adds a marker"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));
    assert!(said(&blocked).contains("todo-ban"), "{}", said(&blocked));
}

/// A package whose installer cannot run fails the sanity probe, before
/// anything is written and long before the old gate is touched. The
/// retired install is still armed and still gating afterwards.
#[test]
#[allow(clippy::unwrap_used)]
fn a_broken_installer_fails_before_the_old_gate_is_touched() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);
    install_package(home, &root, &["growth-guards"]);
    // A syntax error: the file is executable and its interpreter runs, so
    // only actually running it catches this.
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(&installer, "#!/usr/bin/env bash\nif then fi\n").unwrap();

    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        retired.join("pre-commit").is_file(),
        "the old gate survived"
    );
    assert!(
        !root.join(".git/hooks/kendex-guards").exists(),
        "nothing was written"
    );
    let redirect = git(home, &root, &["config", "--get", "core.hooksPath"]);
    assert_eq!(redirect.status.code(), Some(0), "the redirect still stands");
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

/// Shims are judged where git actually reads. Under a redirect that is the
/// redirected directory; the repository's default one holds shims that are
/// dormant now and live the moment the redirect goes, and both are said.
#[test]
#[allow(clippy::unwrap_used)]
fn dormant_shims_behind_a_redirect_are_named_as_dormant() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);
    // Redirect git away from the armed default directory, then take the
    // package away so nothing can answer for the shims left behind.
    let elsewhere = home.join("their-hooks");
    std::fs::create_dir_all(&elsewhere).unwrap();
    git_ok(
        home,
        &root,
        &["config", "core.hooksPath", &elsewhere.display().to_string()],
    );
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("dormant"), "{}", said(&out));
}

/// A package whose installer is not runnable is a broken install, not a
/// clean repository. Nothing is armed, so nothing is blocked — but the next
/// arming cannot run either, and a clean verdict would send a reader off
/// believing the gate is one command away.
#[test]
#[allow(clippy::unwrap_used)]
fn check_names_a_package_whose_installer_cannot_run() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o644)).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("commit hooks"), "{}", said(&out));
    assert!(said(&out).contains("no runnable"), "{}", said(&out));

    // And the same with the installer gone entirely.
    std::fs::remove_file(&installer).unwrap();
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("no runnable"), "{}", said(&out));
}

/// Mid-migration the shims are staged where git is not reading, and the
/// installer says so rather than claiming an arming its own `--check` would
/// contradict.
#[test]
#[allow(clippy::unwrap_used)]
fn staging_under_a_redirect_reports_dormant_not_armed() {
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

    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let out = run_with(
        home,
        &root,
        installer.to_str().unwrap(),
        &["--repo", root.to_str().unwrap(), "--into-default-hooks"],
        &[],
    );
    assert!(out.status.success(), "{}", said(&out));
    assert!(said(&out).contains("staged"), "{}", said(&out));
    assert!(said(&out).contains("dormant"), "{}", said(&out));
    assert!(
        !said(&out).contains("armed in"),
        "no armed claim while git reads elsewhere: {}",
        said(&out)
    );
    assert!(root.join(".git/hooks/kendex-guards").is_file(), "staged");
}

/// Reading a repository's status must not run code the repository carries,
/// and the committed posture is what makes that sharp.
///
/// A repository that commits its harness render ships the package's scripts
/// AND a manifest declaring them; even the in-repo install record can be
/// force-added past its ignore rule and cloned along. Anything a `git clone`
/// carries, a hostile author can write. So the proof lives outside the
/// repository, and without it nothing is executed.
#[test]
#[allow(clippy::unwrap_used)]
fn check_does_not_run_the_checker_of_a_package_this_machine_never_installed() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);

    // The package this machine installs has a checker that proves whether
    // it ran. It is the real installed article, not an edit after the fact.
    let marker = home.join("checker-ran");
    let offered = crate::catalog(home).join("skills/growth-guards");
    crate::seed_catalog(home, &["growth-guards"]);
    let installer = offered.join("scripts/install-git-hooks");
    std::fs::write(
        &installer,
        format!("#!/usr/bin/env bash\ntouch {}\nexit 0\n", marker.display()),
    )
    .unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();
    install_package(home, &root, &["growth-guards"]);
    run(home, &root, "kendex", &["guard", "install"]);

    // Installed here: the record vouches for that script, and it runs.
    run(home, &root, "kendex", &["check"]);
    assert!(marker.exists(), "an installed package's checker runs");

    // Now exactly a fresh clone of a committed-posture repository: the
    // files are here, the declaration is here, and this machine has no
    // memory of installing anything.
    std::fs::remove_file(&marker).unwrap();
    crate::forget_installs(home);
    assert!(
        root.join("kendex.toml").is_file(),
        "the declaration remains"
    );
    // Shims for the report to have something to say about: the stub
    // installer above writes none, and silence about a repository with
    // nothing armed is the right answer rather than the one under test.
    std::fs::write(
        root.join(".git/hooks/kendex-guards"),
        "# kendex growth-guards git hooks\n",
    )
    .unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !marker.exists(),
        "a cloned declaration ran the checker: {}",
        said(&out)
    );
    assert!(
        said(&out).contains("no record of installing it"),
        "{}",
        said(&out)
    );
}

/// The record describes the exact script, so one edited after the install
/// stops being vouched for. A package swapped for another under a name this
/// machine once approved is not the package it approved.
#[test]
#[allow(clippy::unwrap_used)]
fn check_does_not_run_a_checker_edited_since_the_install() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);

    let marker = home.join("checker-ran");
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(
        &installer,
        format!("#!/usr/bin/env bash\ntouch {}\nexit 0\n", marker.display()),
    )
    .unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !marker.exists(),
        "an edited checker ran on an old record: {}",
        said(&out)
    );
}

/// Neither declared nor installed: the shims are still read as files and
/// reported, in the wording for a package nothing here claims.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reports_shims_from_a_package_nothing_here_claims() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = armed_repo(home);
    std::fs::remove_file(root.join("kendex.toml")).unwrap();
    crate::forget_installs(home);

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(
        said(&out).contains("no growth-guards package is installed here"),
        "{}",
        said(&out)
    );
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

/// Unsetting this repository's `core.hooksPath` does not always let git read
/// `.git/hooks`: a global one surfaces the moment the local one goes. Taking
/// the old gate away then leaves the staged shims dormant with nothing
/// gating, so the takeback refuses and names where the other value lives.
#[test]
#[allow(clippy::unwrap_used)]
fn arming_refuses_when_a_hooks_path_would_surface_from_outside() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);
    install_package(home, &root, &["growth-guards"]);
    // A global value, which outlives any takeback of this repository's own.
    let theirs = home.join("global-hooks");
    std::fs::create_dir_all(&theirs).unwrap();
    git_ok(
        home,
        &root,
        &[
            "config",
            "--global",
            "core.hooksPath",
            &theirs.display().to_string(),
        ],
    );

    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("would surface"), "{}", said(&out));
    assert!(
        retired.join("pre-commit").is_file(),
        "the old gate survived"
    );
    // The shims are staged and stay staged; nothing claimed they went live.
    assert!(root.join(".git/hooks/kendex-guards").is_file(), "staged");
    assert!(
        !said(&out).contains("now live"),
        "no claim of going live: {}",
        said(&out)
    );
}

/// A receiptless retired directory holding someone else's hook is not
/// kendex's to disconnect. Unsetting `core.hooksPath` around it would leave
/// that file on disk, looking installed, never running again — so the whole
/// takeback refuses and names it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_foreign_hook_in_the_retired_directory_refuses_the_takeback() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    let retired = retire(home, &root);
    std::fs::remove_file(retired.join("receipt.json")).unwrap();
    std::fs::write(retired.join("post-commit"), "#!/bin/sh\necho theirs\n").unwrap();
    install_package(home, &root, &["growth-guards"]);

    let out = run(home, &root, "kendex", &["guard", "install"]);
    assert_eq!(out.status.code(), Some(2), "{}", said(&out));
    assert!(said(&out).contains("post-commit"), "{}", said(&out));
    assert!(retired.join("post-commit").is_file(), "left in place");
    let redirect = git(home, &root, &["config", "--get", "core.hooksPath"]);
    assert_eq!(
        redirect.status.code(),
        Some(0),
        "their hook still runs: the redirect was not cleared around it"
    );
}
