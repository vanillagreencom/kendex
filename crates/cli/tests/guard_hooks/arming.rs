//! Putting the gate in place, taking it away, and reporting on it — the
//! verbs, and what `kendex check` says about a repository in each state.
//!
//! Two things are asserted, and the line between them is the rule. Where
//! the package answers, what is asserted is relay: its own sentence and its
//! own exit code, never a kendex paraphrase. Where it cannot be reached —
//! nothing local armed the repository, the render is gone, a directory
//! would not open — kendex says only what it read off local state and names
//! `kendex guard check`, and what is asserted is that it claims no more.

use crate::test_util::{rooted, source_path};

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

/// `kendex check` reports an unarmed repository and says nothing about an
/// armed one.
///
/// Unarmed is a verdict kendex composes itself, because nothing has
/// licensed it to ask the package: no helper in the hooks directory means
/// nothing local armed it. What it may therefore SAY is only what it read —
/// `kendex guard install` is not named, because under a configured
/// `core.hooksPath` the installer stands down and writes nothing, and a
/// remedy that cannot be taken would then be offered every session for
/// ever. The package is invited instead. Once a helper is there the package
/// answers, and an armed repository has nothing to report.
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
        said(&unarmed).contains("holds no kendex-guards helper"),
        "it names the one file it looked for: {}",
        said(&unarmed)
    );
    assert!(
        said(&unarmed).contains("kendex guard check"),
        "it hands the reading back to the package: {}",
        said(&unarmed)
    );
    assert!(
        !said(&unarmed).contains("kendex guard install"),
        "it names a remedy that can stand down: {}",
        said(&unarmed)
    );

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
    // The whole sentence, not a phrase near its front. This fixture's line
    // is short enough that no bound would have cut it, so what this pins is
    // provenance — every word came from the package — and not the bounding.
    // Where the bounding is pinned is
    // `the_packages_exit_two_is_could_not_check_and_its_sentence_survives_whole`,
    // which asserts its own line outruns the fragment cut before relying on
    // it, and `tests_render::a_relayed_line_past_the_bound_is_replaced_rather_than_cut`.
    assert!(
        text.contains(&sentence),
        "the package's own sentence was not relayed whole:\n{text}\nit said: {sentence}"
    );
}

/// The package's exit codes become the report's classes, exit 2 included.
///
/// `core.hooksPath` set to a directory is the everyday exit 2: every husky
/// or `.githooks` repository is in it, and the package stands down there
/// rather than grade a directory it does not write. Read as "not armed"
/// that would be drift with a remedy — `kendex guard install`, which stands
/// down too — offered every session for a state nobody has measured.
///
/// The verdict is compared against what `kendex guard check` printed rather
/// than against a phrase, because a phrase near the front of the sentence
/// survives a relay that keeps only the front of it. That this line is long
/// enough for the distinction to matter is asserted below rather than
/// stated here: the package's wording and this fixture's hooksPath value
/// both move, and a hand-counted length goes stale when either does.
#[test]
#[allow(clippy::unwrap_used)]
fn the_packages_exit_two_is_could_not_check_and_its_sentence_survives_whole() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: exit 1 from the package is drift, and `kendex check`
    // exits 1 with it.
    let helper = root.join(".git/hooks/kendex-guards");
    let genuine = std::fs::read(&helper).unwrap();
    std::fs::write(&helper, b"#!/bin/sh\nexit 0\n").unwrap();
    let drifted = run(home, &root, "kendex", &["check"]);
    assert_eq!(
        drifted.status.code(),
        Some(1),
        "the package's exit 1 is drift: {}",
        said(&drifted)
    );
    std::fs::write(&helper, &genuine).unwrap();

    // A configured hooks path: the package answers 2, and so does kendex.
    git_ok(home, &root, &["config", "core.hooksPath", ".githooks"]);
    let theirs = run(home, &root, "kendex", &["guard", "check"]);
    assert_eq!(theirs.status.code(), Some(2), "{}", said(&theirs));
    let sentence = String::from_utf8_lossy(&theirs.stdout).trim().to_owned();
    assert!(
        sentence.chars().count() > 300,
        "this fixture only pins the relay while its sentence outruns the \
         fragment bound: {} characters",
        sentence.chars().count()
    );

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "the package's exit 2 was not could-not-check: {}",
        said(&out)
    );
    let text = said(&out);
    assert!(
        text.contains(&sentence),
        "the package's sentence did not survive whole:\n{text}\nit said: {sentence}"
    );
}

/// A script that died before it reached `--check` is a check that could not
/// be taken, and its report line still says something.
///
/// The package promises a summary line on stdout only once `--check` runs.
/// `set -euo pipefail` is armed above its five `source` lines, so a library
/// file that is missing or unreadable ends it at exit 1 with stdout empty —
/// the same status its "not armed" verdict carries. Classed by the exit
/// code alone that reads as drift, and the reader gets `commit hooks:`
/// followed by a blank line: a verdict nobody took, printed as one that was
/// taken, with nothing in it to act on.
///
/// `bind` asks only that `scripts/install-git-hooks` exist and be
/// executable, so a truncated sync reaches this on its own.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installer_that_could_not_run_is_never_relayed_as_a_verdict() {
    let tmp = tempfile::tempdir().unwrap();
    // Deep on purpose: the shell names an absolute path, so the composed
    // line has to outrun the fragment bound for the assertion at the foot
    // of this test to be about anything.
    let home = &rooted(&tmp)
        .join("a-directory-named-to-outrun-the-three-hundred-character-fragment-bound");
    std::fs::create_dir_all(home).unwrap();
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: armed and whole is silence, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));

    // One library file gone. Nothing else changes, and the entry point is
    // still there and still executable, so the search finds it.
    let lib = root.join(".agents/skills/growth-guards/scripts/lib/hook-check.sh");
    std::fs::remove_file(&lib).unwrap();
    assert!(
        root.join(".agents/skills/growth-guards/scripts/install-git-hooks")
            .is_file()
    );

    let out = run(home, &root, "kendex", &["check"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "a script that never ran was reported as a verdict: {}",
        said(&out)
    );
    let text = said(&out);
    assert!(text.contains("commit hooks"), "{text}");
    // Whatever the line says, it is not empty: the report must not print a
    // heading with nothing under it.
    let line = text
        .lines()
        .find(|line| line.starts_with("  "))
        .unwrap_or_else(|| panic!("the report carries an indented line:\n{text}"));
    assert!(
        line.trim().chars().count() > 20,
        "the report line carries nothing to act on: {line:?}\n{text}"
    );
    assert!(
        line.contains("could not be checked"),
        "the line does not say what happened: {line:?}"
    );
    // The package's own diagnosis is at the END of that line, which is
    // where a fragment bound would take it: the composed sentence alone
    // runs past 110 characters before the shell's message begins, and the
    // shell names an absolute path.
    let (_, complaint) = line
        .split_once("its own words were: ")
        .unwrap_or_else(|| panic!("the package's own words are relayed:\n{text}"));
    assert!(
        line.chars().count() > 300,
        "this fixture only pins the bound while its line outruns it: {} characters",
        line.chars().count()
    );
    assert!(
        complaint.contains("hook-check.sh"),
        "the diagnosis was cut off the end of the line: {line:?}"
    );
}

/// A package this project declared, armed, and no longer renders is drift
/// with a remedy that fits it.
///
/// The lock records the package and the search finds no copy: a state to
/// fix, not one nobody could measure. The line says those two and stops,
/// because predicting that every commit fails is an inference off one stat
/// on the helper, and the lane files that would settle it are not read
/// here. The fix is a render: the lock already records the package, so
/// `kendex add` would be advice about a state the reader is not in, which
/// is what the resolver's own refusal says when nothing tells it the lock
/// has already spoken.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_package_with_no_render_is_drift_naming_the_render() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The render goes; the lock and the shims stay. Every skills root,
    // because an install fans out to each tool directory the project has.
    for base in kendex_core::guard::SEARCH_ROOTS {
        let copy = root.join(base).join(kendex_core::guard::SKILL);
        match copy.is_symlink() {
            true => std::fs::remove_file(&copy).unwrap(),
            false if copy.exists() => std::fs::remove_dir_all(&copy).unwrap(),
            false => {}
        }
    }

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert_eq!(
        out.status.code(),
        Some(1),
        "a state with a remedy was reported as one nobody could measure: {text}"
    );
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        text.contains("kendex refresh"),
        "the remedy does not name the render: {text}"
    );
    assert!(
        !text.contains("kendex add"),
        "it names an install the lock already records: {text}"
    );
    assert!(
        !text.contains("every commit"),
        "it predicts commit behaviour nothing here measured: {text}"
    );
}

/// An installer that exits 0 without a verdict is not a clean repository.
///
/// The package writes its summary only once `--check` runs, so a script cut
/// short says nothing and carries whatever status the shell last set —
/// truncated at a clean `}` boundary that is exit 0. Read exit-first, the
/// fold reported `all clear` about a repository it never looked at, on the
/// one line whose own module doc says a check reporting all clear while
/// nothing gates commits is worse than no check.
///
/// The cut is at a real boundary of the real script rather than a stub, so
/// what is pinned is the state a truncated sync actually leaves.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installer_that_exits_zero_with_no_verdict_is_not_all_clear() {
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: whole and armed is silence, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));

    // Cut at the last `}` that closes a function before the script's own
    // work begins. Every earlier boundary behaves the same way; this one is
    // asserted to be a clean parse that says nothing.
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    let whole = std::fs::read_to_string(&installer).unwrap();
    let cut: Vec<&str> = whole.lines().take(57).collect();
    std::fs::write(&installer, format!("{}\n", cut.join("\n"))).unwrap();
    let direct = std::process::Command::new(&installer)
        .args(["--repo", &root.to_string_lossy()])
        .current_dir(&root)
        .output()
        .unwrap();
    assert_eq!(
        (direct.status.code(), direct.stdout.len()),
        (Some(0), 0),
        "the fixture is an exit 0 with no verdict, not a syntax error: {}",
        String::from_utf8_lossy(&direct.stderr)
    );

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert_eq!(
        out.status.code(),
        Some(2),
        "a repository nobody checked was reported clean: {text}"
    );
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        text.contains("no verdict"),
        "the line does not say what happened: {text}"
    );
}

/// The session-start bound is actually applied, and a wedged script costs
/// one line rather than the whole report.
///
/// Three guards sit on this bound and each closes a different way of
/// losing it. `run_installer` takes a `Duration` and not an `Option`, so a
/// lane cannot reach the process default by saying nothing.
/// `guard_timeout_budget` reads the hook's frontmatter, so the number
/// cannot drift past the budget. Neither notices `check_repo` naming a
/// different `Duration`: swapping `CHECK_TIMEOUT` for `DEFAULT_TIMEOUT`
/// compiles, and the session-start `--check` then runs for 120 seconds
/// inside a hook the harness gives 20 — the whole drift report lost to the
/// harness's own kill. This is what notices.
///
/// One test, because it costs the bound in wall clock. The assertion is
/// not the discriminating one: a bound that fired relays `no result after
/// 10s` and a `sleep` that ran to completion relays an exit with no
/// verdict, so the wall clock only has to separate 10 seconds from 60.
///
/// Two shapes, because the direct child is not the only thing that can hold
/// the run open. The second exits at once and leaves a descendant on the
/// pipes, which is the shape that read `check_repo` as finished and then
/// blocked in collection for the full minute, outliving the bound and the
/// hook budget both.
#[test]
#[allow(clippy::unwrap_used)]
fn a_wedged_installer_gives_up_inside_the_session_start_bound() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    // Armed for real, so the fold gets past the consent gate and reaches
    // the script.
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    for script in [
        "#!/usr/bin/env bash\nsleep 60\n",
        "#!/usr/bin/env bash\nsleep 60 &\nexit 0\n",
    ] {
        std::fs::write(&installer, script).unwrap();
        std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();

        let started = std::time::Instant::now();
        let out = run(home, &root, "kendex", &["check"]);
        let elapsed = started.elapsed();
        let text = said(&out);

        assert!(
            elapsed < std::time::Duration::from_secs(50),
            "the bound was not applied to {script:?} — the run took {elapsed:?}, \
             which is the script finishing rather than the check giving up:\n{text}"
        );
        assert_eq!(
            out.status.code(),
            Some(2),
            "a check that could not be taken was not reported as one, for {script:?}: {text}"
        );
        assert!(text.contains("commit hooks"), "{script:?}: {text}");
        assert!(
            text.contains("no result after"),
            "the line does not name the timeout, for {script:?}: {text}"
        );
    }
}

/// The session-start output bound is applied, and an installer that writes
/// past it is a check that could not be taken.
///
/// The sibling of the timeout above, for the other resource the unattended
/// call cannot bound by itself. `check_repo` runs a script the checkout
/// supplies, and the reader holds what it writes until it exits — so a
/// script looping on output grows the kendex process for the whole ten
/// seconds unless something refuses first.
///
/// The fixture exits 0 with a non-empty stdout, which is the arm that would
/// otherwise report `all clear`: uncapped, this run is a clean verdict
/// about a repository whose 200 KiB of output kendex swallowed whole. So
/// the assertion below reds the moment `CHECK_OUTPUT_CAP` stops reaching
/// the process layer, rather than passing on some other refusal.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installer_that_outruns_the_session_start_output_bound_is_not_all_clear() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = &rooted(&tmp);
    let root = repo(home);
    install_package(home, &root, &["growth-guards"]);
    // Armed for real, so the fold gets past the consent gate and reaches
    // the script.
    let armed = run(home, &root, "kendex", &["guard", "install"]);
    assert!(armed.status.success(), "{}", said(&armed));

    // The control: whole and armed is silence, exit 0.
    let clean = run(home, &root, "kendex", &["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", said(&clean));

    // 200 x 1 KiB, past the 64 KiB bound, written a line at a time and
    // ending in the exit a clean verdict carries.
    let installer = root.join(".agents/skills/growth-guards/scripts/install-git-hooks");
    std::fs::write(
        &installer,
        "#!/usr/bin/env bash\nline=$(printf 'x%.0s' {1..1023})\n\
         for _ in {1..200}; do printf '%s\\n' \"$line\"; done\nexit 0\n",
    )
    .unwrap();
    std::fs::set_permissions(&installer, std::fs::Permissions::from_mode(0o755)).unwrap();

    let out = run(home, &root, "kendex", &["check"]);
    let text = said(&out);
    assert_eq!(
        out.status.code(),
        Some(2),
        "output past the bound was reported as a clean check: {text}"
    );
    assert!(text.contains("commit hooks"), "{text}");
    assert!(
        text.contains("output exceeded"),
        "the line does not name the bound that fired: {text}"
    );
}
