//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, and what `kendex check` says about a repository in each state.
//!
//! One verdict, one voice. `kendex guard check` and the commit-hook line of
//! `kendex check` are the same call to the package's `--check`, so what is
//! asserted here is relay: the package's own sentence and its own exit
//! code, not a kendex paraphrase of either.

use crate::test_util::source_path;

use crate::{git_ok, install_package, install_package_undeclared, repo, run, said};

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
///
/// The sentence is the package's, word for word — `NOT armed`, in its
/// capitals — because kendex composes none of it.
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
    assert!(
        said(&unarmed).contains("growth-guards git hooks:"),
        "the package's own words did not come through: {}",
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
/// The probe is what stands between a scope and the package's `--check`,
/// so a repository it cannot read never reaches the installer at all: the
/// report says the check could not be taken, with no remedy attached to a
/// state nobody has diagnosed.
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

/// `kendex guard check` is the package's own `--check`, relayed.
///
/// The verb exists so a person can have the full vocabulary — armed,
/// drifted, unverifiable — without kendex owning a second opinion
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
/// The guard line says this package armed the file; the execute bit says
/// git will execute it. Git skips a hook without one in silence, so a
/// guard line in a file it ignores describes a gate that is not there.
/// The package's `--check` asks both, and `kendex check` asks nothing:
/// it prints what came back.
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

/// An item named growth-guards that is not the skill is not consent.
///
/// The lock is keyed by more than a name — an agent may legally be called
/// `growth-guards` — and reading any enabled entry of that name as "this
/// project asked for commit hooks" reports drift at a project that never
/// did, every session, with no way to make it stop short of renaming
/// somebody else's agent.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_of_the_same_name_is_not_consent_to_commit_hooks() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    // A project that declares an AGENT called growth-guards and no skill.
    let agents = home.join("catalog/agents");
    std::fs::create_dir_all(&agents).unwrap();
    std::fs::write(
        agents.join("growth-guards.md"),
        "---\nname: growth-guards\ndescription: an agent, not the skill\n\
         model: opus\nrole: engineer\n---\nbody\n",
    )
    .unwrap();
    std::fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n",
            source_path(&home.join("catalog"))
        ),
    )
    .unwrap();
    let added = run(
        home,
        &root,
        "kendex",
        &["add", "cat", "--agent", "growth-guards", "-y"],
    );
    assert!(added.status.success(), "{}", said(&added));

    let out = said(&run(home, &root, "kendex", &["check"]));
    assert!(
        !out.contains("commit hooks"),
        "an agent of that name was read as consent to commit hooks: {out}"
    );
}

/// The package's two streams stay two streams.
///
/// Its contract is one summary line on stdout and its warnings on stderr
/// (`install-git-hooks --help`), and a caller piping `kendex guard` is
/// reading for that one line. Relaying both to stdout handed them a
/// `::warning::` stream to filter out.
///
/// `core.hooksPath` set is the case that prints both: the install stands
/// down with a warning and still says what it did.
#[test]
#[allow(clippy::unwrap_used)]
fn each_of_the_packages_streams_is_relayed_on_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    git_ok(home, &root, &["config", "core.hooksPath", ".githooks"]);

    let out = run(home, &root, "kendex", &["guard", "install"]);
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();

    assert!(
        stdout.contains("growth-guards git hooks:"),
        "the summary line belongs on stdout: {stdout:?} {stderr:?}"
    );
    assert!(
        !stdout.contains("::warning::"),
        "a warning reached the stream a caller pipes: {stdout:?}"
    );
    assert!(
        stderr.contains("::warning::"),
        "the warning belongs on stderr: {stderr:?}"
    );
    // One line, so a caller can read it without filtering.
    assert_eq!(
        stdout.lines().count(),
        1,
        "stdout is the summary and nothing else: {stdout:?}"
    );
}

/// A repository the package calls foreign is reported in the package's own
/// sentence, under the package's own exit code.
///
/// The whole delegation, end to end. kendex used to answer this from the
/// hook bytes with a grammar of its own, and the two grammars disagreed
/// about which files count as this package's for as long as both existed.
/// So the helper here is one the installer refuses to own — an executable
/// file of the right name carrying none of its marker, which is exactly
/// what the uninstaller preserves and the checker declines to vouch for —
/// and what `kendex check` prints is the line `install-git-hooks --check`
/// wrote about it.
#[test]
#[allow(clippy::unwrap_used)]
fn check_relays_the_packages_words_about_a_foreign_hook() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: armed is the silent verdict, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));
    assert!(!said(&clean).contains("commit hooks"), "{}", said(&clean));

    // Somebody else's file, of the helper's name. The lanes still delegate
    // to it, so this is a repository whose commits run a script the package
    // never wrote.
    let helper = root.join(".git/hooks/kendex-guards");
    std::fs::write(&helper, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();

    // What the package says, asked directly.
    let theirs = run(home, &root, "kendex", &["guard", "check"]);
    assert_eq!(theirs.status.code(), Some(1), "{}", said(&theirs));
    let sentence = String::from_utf8_lossy(&theirs.stdout).trim().to_owned();
    assert!(
        sentence.contains("was not written by this installer"),
        "{sentence}"
    );

    // And the same words, and the same verdict, out of `kendex check`.
    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(
        out.status.code(),
        Some(1),
        "the package's exit was not relayed: {}",
        said(&out)
    );
    let text = said(&out);
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        text.contains("was not written by this installer"),
        "the package's own sentence was not relayed:\n{text}\nit said: {sentence}"
    );
}
