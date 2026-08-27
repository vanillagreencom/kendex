//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, the migration off the retired arming, and what `kendex check`
//! says about a repository in each state.

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

/// Shims that outlived their package are named, file by file.
///
/// The state the install record cannot see: the package is in no lock and
/// under no skills directory, so the drift report has nothing to compare
/// and `guard check` has no installer to ask — while every commit execs a
/// script that is gone. The marker in the hook files is the whole test.
#[test]
#[allow(clippy::unwrap_used)]
fn check_names_the_shims_a_removed_package_left_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    std::fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    install_package_undeclared(&root, &["growth-guards"]);
    arm_by_hand(&root);
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    // The state is real: nothing can be committed here.
    std::fs::write(root.join("b.txt"), "later\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    let blocked = crate::git(home, &root, &["commit", "-m", "feat: stranded"]);
    assert!(!blocked.status.success(), "{}", said(&blocked));

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    let text = said(&out);
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        text.contains("installed in no project of this repository"),
        "{text}"
    );
    let hooks = root.canonicalize().unwrap().join(".git/hooks");
    for file in ["pre-commit", "commit-msg", "kendex-guards"] {
        assert!(
            text.contains(&hooks.join(file).display().to_string()),
            "{file} was not named:\n{text}"
        );
    }
    assert!(
        !text.contains("guard install"),
        "a leftover was reported as an unarmed install:\n{text}"
    );

    // With hooks redirected git reads none of these, so no commit fails
    // and nothing is claimed about one.
    git_ok(home, &root, &["config", "core.hooksPath", ".husky"]);
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&out).contains("commit hooks"),
        "a redirected repository was reported as failing every commit:\n{}",
        said(&out)
    );

    // A file of the helper's name beside hooks that carry no marker execs
    // on no commit: the installer leaves such a file alone, and so does
    // the report.
    git_ok(home, &root, &["config", "--unset", "core.hooksPath"]);
    for lane in ["pre-commit", "commit-msg"] {
        std::fs::write(root.join(".git/hooks").join(lane), "#!/bin/sh\nexit 0\n").unwrap();
    }
    assert!(root.join(".git/hooks/kendex-guards").is_file());
    let out = run(home, &root, "kendex", &["check"]);
    assert!(
        !said(&out).contains("commit hooks"),
        "a lone helper with unmarked hooks was reported as stranded:\n{}",
        said(&out)
    );
}

/// One repository, two kendex projects, one hooks directory. The project
/// without the package is gated by the one that armed it — not stranded —
/// and the advice to delete the shims would have disarmed its neighbour.
///
/// The repository root is itself a project, which is the ordinary shape: a
/// `.claude/CLAUDE.md` at the top marks it as one. A search that stops at
/// the first project it meets stops there and never sees `apps/api`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_neighbouring_project_carrying_the_package_is_not_a_leftover() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let root = home.join("mono");
    let api = root.join("apps/api");
    let web = root.join("apps/web");
    std::fs::create_dir_all(root.join(".claude")).unwrap();
    std::fs::write(root.join(".claude/CLAUDE.md"), "the monorepo\n").unwrap();
    std::fs::create_dir_all(api.join(".agents")).unwrap();
    std::fs::create_dir_all(web.join(".agents")).unwrap();
    git_ok(home, &root, &["init", "--quiet", "-b", "main"]);
    git_ok(home, &root, &["config", "user.email", "t@t"]);
    git_ok(home, &root, &["config", "user.name", "t"]);
    std::fs::write(root.join("a.txt"), "hi\n").unwrap();
    git_ok(home, &root, &["add", "-A"]);
    git_ok(home, &root, &["commit", "--quiet", "-m", "feat: base"]);
    install_package(home, &api, &["growth-guards"]);
    let armed = run(home, &api, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));
    std::fs::write(web.join("kendex.toml"), "schema = 6\n").unwrap();

    for from in [&web, &root] {
        let out = run(home, from, "kendex", &["check"]);
        assert!(
            !said(&out).contains("commit hooks"),
            "a gated repository was reported as stranded from {}:\n{}",
            from.display(),
            said(&out)
        );
        assert_eq!(out.status.code(), Some(0), "{}", said(&out));
    }

    // The control: a commit from the project without the package runs the
    // neighbour's chain and passes.
    std::fs::write(web.join("b.txt"), "fine\n").unwrap();
    git_ok(home, &web, &["add", "-A"]);
    git_ok(home, &web, &["commit", "--quiet", "-m", "feat: from web"]);
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
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n",
            home.join("catalog").display()
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

/// A copy in a SIBLING work tree gates this one, and is not a leftover.
///
/// `.git/hooks` lives in the common git directory, so one copy of it runs
/// for every work tree attached to that directory — not just this one and
/// the main checkout. A search that looks only at those two calls the
/// shared shims stranded from any third work tree and tells the reader to
/// delete files the sibling's copy is still using, on a repository where
/// every commit is gated perfectly well.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_in_a_sibling_work_tree_is_not_a_leftover() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    git_ok(home, &root, &["worktree", "add", "--quiet", "../armer"]);
    git_ok(home, &root, &["worktree", "add", "--quiet", "../reader"]);
    let armer = home.join("armer");
    let reader = home.join("reader");

    // The package is installed and armed in one linked work tree. Neither
    // the main checkout nor the other work tree carries a copy.
    std::fs::create_dir_all(armer.join(".agents")).unwrap();
    install_package(home, &armer, &["growth-guards"]);
    let armed = run(home, &armer, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The reader is a project of its own with no copy and no record of one
    // — everything the diagnosis sees short of the sibling.
    std::fs::create_dir_all(reader.join(".agents")).unwrap();
    std::fs::write(reader.join("kendex.toml"), "schema = 6\n").unwrap();
    assert!(!root.join(".agents/skills/growth-guards").exists());
    assert!(!reader.join(".agents/skills/growth-guards").exists());

    let out = run(home, &reader, "kendex", &["check"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "the sibling's copy went unfound: {}",
        said(&out)
    );
    assert!(!said(&out).contains("commit hooks"), "{}", said(&out));

    // The must-fail control: with every copy gone the shims really are
    // stranded, and the same reader says so by file. Every skills root and
    // links as well as trees, because an install fans out to each tool
    // directory the work tree has and links the rest at the first.
    for base in kendex_core::guard::SEARCH_ROOTS {
        let copy = armer.join(base).join(kendex_core::guard::SKILL);
        match copy.is_symlink() {
            true => std::fs::remove_file(&copy).unwrap(),
            false if copy.exists() => std::fs::remove_dir_all(&copy).unwrap(),
            false => {}
        }
    }
    let out = run(home, &reader, "kendex", &["check"]);
    assert_eq!(out.status.code(), Some(1), "{}", said(&out));
    let text = said(&out);
    assert!(
        text.contains("installed in no project of this repository"),
        "{text}"
    );
    let hooks = root.canonicalize().unwrap().join(".git/hooks");
    for file in ["pre-commit", "commit-msg", "kendex-guards"] {
        assert!(
            text.contains(&hooks.join(file).display().to_string()),
            "{file} was not named:\n{text}"
        );
    }
}

/// A search domain that could not be read in full is a verdict that could
/// not be taken, never a leftover.
///
/// "No copy anywhere" is the premise behind advice to delete a
/// repository's hook files. A directory the walk cannot open holds an
/// unknown number of copies, so folding it into "nothing here" makes the
/// destructive half of the diagnosis fire on a repository nobody has
/// looked at.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_search_domain_it_cannot_read_is_could_not_check_not_a_leftover() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = repo(home);
    std::fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    install_package_undeclared(&root, &["growth-guards"]);
    arm_by_hand(&root);
    std::fs::remove_dir_all(root.join(".agents/skills/growth-guards")).unwrap();

    // The control: with the whole tree readable, this is the drift verdict
    // that names the files to delete.
    let out = said(&run(home, &root, "kendex", &["check"]));
    assert!(
        out.contains("installed in no project of this repository"),
        "{out}"
    );

    // One directory of the domain, unopenable. Nothing else changes.
    let locked = root.join("locked");
    std::fs::create_dir(&locked).unwrap();
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
    assert!(
        !text.contains("installed in no project of this repository"),
        "an unreadable directory read as a repository with no copy:\n{text}"
    );
    assert!(
        text.contains(&locked.display().to_string()),
        "the directory it could not read is not named:\n{text}"
    );
}
