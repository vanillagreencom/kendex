//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, the migration off the retired arming, and what `kendex check`
//! says about a repository in each state.

use crate::{install_package, install_package_undeclared, repo, run, said};

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

/// Outside any repository there is no verdict to give.
///
/// The project has to DECLARE the package for this to mean anything: a
/// scope that does not is skipped before the question is asked, so a
/// fixture without a lock passes whatever the answer would have been. That
/// is what this test used to do.
///
/// And there is nothing to say here. "Not armed, run `kendex guard
/// install`" is advice that cannot be taken — the installer exits 2 outside
/// a work tree — so a scope with no repository would carry it every
/// session, for ever.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_project_outside_a_repository_has_no_hook_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    // Same project, minus the repository: the declaration stays, so the
    // fold is reached and has to decide what to say about it.
    std::fs::remove_dir_all(root.join(".git")).unwrap();

    let out = said(&run(home, &root, "kendex", &["check"]));
    assert!(
        !out.contains("commit hooks"),
        "a project with no repository was told to arm hooks: {out}"
    );
}

/// A repository whose configuration cannot be read is a check that could
/// not be taken, and never a clean one.
///
/// What this reaches is the probe: git answers 128 for a broken
/// `.git/config` and says nothing about repositories, so `Repo::probe`
/// reports could-not-tell before the hooks path is ever asked for.
///
/// `hooks_redirected`'s own refusal to read any non-1 status as "unset" is
/// defence behind that, and deliberately not pinned here: every way to
/// break the config breaks the probe first, so an isolated trigger would
/// have to be a race. It is written to fail closed because the cost of
/// being wrong is a clean armed verdict about a repository whose effective
/// hooks path was never established.
#[test]
#[allow(clippy::unwrap_used)]
fn a_configuration_git_cannot_read_is_not_an_armed_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: armed is the silent verdict.
    let clean = said(&run(home, &root, "kendex", &["check"]));
    assert!(!clean.contains("commit hooks"), "{clean}");

    // Now git cannot read the file that says where hooks come from. The
    // shims are untouched and still carry their marker, so nothing but the
    // unreadable config separates this from the run above.
    let config = root.join(".git/config");
    let saved = std::fs::read_to_string(&config).unwrap();
    std::fs::write(&config, "[core\n").unwrap();
    let out = said(&run(home, &root, "kendex", &["check"]));
    std::fs::write(&config, saved).unwrap();

    assert!(
        out.contains("commit hooks"),
        "an unreadable configuration read as armed: {out}"
    );
    assert!(
        !out.contains("guard install"),
        "could-not-read was reported as drift with a remedy: {out}"
    );
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

/// `kendex guard check` is the package's own `--check`, relayed.
///
/// The verb exists so a person can have the full vocabulary — armed,
/// drifted, dormant, unverifiable — without kendex owning a second opinion
/// about what those words mean. So what is pinned here is delegation: the
/// package's words come through, and its exit code is the verb's.
#[test]
#[allow(clippy::unwrap_used)]
fn the_check_verb_relays_the_packages_own_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);

    let unarmed = run(home, &root, "kendex", &["guard", "check"]);
    assert_eq!(unarmed.status.code(), Some(1), "{}", said(&unarmed));
    assert!(
        said(&unarmed).contains("growth-guards git hooks:"),
        "the package's own words did not come through: {}",
        said(&unarmed)
    );

    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));
    let checked = run(home, &root, "kendex", &["guard", "check"]);
    assert_eq!(checked.status.code(), Some(0), "{}", said(&checked));
    assert!(said(&checked).contains("armed"), "{}", said(&checked));
}

/// A hook git will not run is not an armed repository.
///
/// The marker says this package armed the file; the execute bit says git
/// will execute it. Git skips a hook without one in silence, so a marker in
/// a file it ignores describes a gate that is not there — and every reader
/// of the marker stands aside for it.
///
/// Executability is git's own rule about hook files, not this package's
/// about their contents, which is why asking it is not the grammar this
/// crate deliberately no longer has.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_git_will_not_run_is_not_armed() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: armed is the silent verdict.
    let clean = said(&run(home, &root, "kendex", &["check"]));
    assert!(!clean.contains("commit hooks"), "{clean}");

    // The marker stays; only the bit git reads goes.
    let hook = root.join(".git/hooks/pre-commit");
    assert!(
        std::fs::read_to_string(&hook)
            .unwrap()
            .contains("kendex-guards-hook")
    );
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o644)).unwrap();

    let out = said(&run(home, &root, "kendex", &["check"]));
    assert!(
        out.contains("commit hooks"),
        "a hook git will not run still read armed: {out}"
    );
}

/// The search roots kendex walks are the ones the package walks.
///
/// Two lists of the same directories in two languages, and the last pair of
/// those drifted for nine review rounds. This one survives because the
/// verbs have to find the copy an armed repository runs: a kendex that
/// looked somewhere the package does not would report on a package no
/// commit ever reaches.
///
/// It reads `lib/skill-roots.sh`, which is the shell side's only definition
/// — the installer, the helper baked into `.git/hooks` and the pre-commit
/// chain all take it from there. When there were four, this pin read one of
/// them and the other three went stale behind it.
///
/// Token equality, not a parse. The shell list is one space-separated
/// string by construction, and comparing them as sets would pass a pair
/// that searched the same places in a different order.
#[test]
#[allow(clippy::unwrap_used)]
fn the_search_roots_match_the_installers_own_list() {
    let definition = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills/growth-guards/scripts/lib/skill-roots.sh")
        .canonicalize()
        .unwrap();
    let text = std::fs::read_to_string(&definition).unwrap();
    let line = text
        .lines()
        .find_map(|line| line.strip_prefix("GG_SKILL_ROOTS=\""))
        .and_then(|rest| rest.strip_suffix('"'))
        .expect("the package declares GG_SKILL_ROOTS as one quoted string");
    let theirs: Vec<&str> = line.split_whitespace().collect();
    assert_eq!(
        theirs,
        kendex_core::guard::SEARCH_ROOTS,
        "the installer searches {theirs:?} and kendex searches {:?}",
        kendex_core::guard::SEARCH_ROOTS
    );
}
