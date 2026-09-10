//! What the window is told about one package's setup in one project.
//!
//! The real commit-guards package, its real installer and its real
//! `--check`. Nothing here is stubbed, because the whole claim is that
//! kendex locates and runs what a package declares and relays what the
//! package said: a fixture with a script of its own would prove that about
//! the fixture.
#![cfg(unix)]

#[path = "repo_effects/fixture.rs"]
mod fixture;
use fixture::*;

use kendex_core::repo_effects::{Ask, SetupState};

/// The helper commit-guards' installer writes, and the file every other
/// tool that arms git hooks does not write.
const HELPER: &str = ".git/hooks/kendex-guards";

fn state(f: &Fixture, name: &str, ask: Ask) -> SetupState {
    kendex_app::repo_effects::setup(&f.env, &f.scope, name, ask)
        .unwrap_or_else(|error| panic!("setup {name}: {error}"))
        .status
        .state
}

/// A package that says nothing about the repository has no setup to
/// report, and the window is told exactly that rather than an error or a
/// guess — the tab draws no row for it.
#[test]
fn a_package_that_changes_nothing_has_no_setup() {
    let f = fixture();
    install_skills(&f, &["deploy"], None);

    let read = kendex_app::repo_effects::setup(&f.env, &f.scope, "deploy", Ask::Surface)
        .unwrap_or_else(|error| panic!("setup: {error}"));

    assert_eq!(read.status.state, SetupState::NotDeclared);
    assert!(read.disclosure.is_none());
}

/// The states a real installed package moves through, in the order a
/// person moves it through them: installed and unarmed, armed, and armed
/// then broken by hand.
///
/// One test rather than three, because the transitions are the claim: a
/// status read from a retained answer, or one that never re-read the
/// repository, would pass each state on its own and fail here.
#[test]
#[allow(clippy::unwrap_used)]
fn setup_is_read_off_the_repository_each_time_it_is_asked() {
    let f = fixture();
    let installed = install_skills(&f, &["commit-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    let helper = f.project.join(HELPER);
    assert!(!helper.exists(), "the install armed the repository");

    // Installed, and kendex has no record of setting it up. Said without
    // running the package's check at all.
    assert_eq!(
        state(&f, "commit-guards", Ask::Surface),
        SetupState::NotActive
    );

    // The window's yes, through the one command that runs a declared
    // installer.
    kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared)
        .unwrap_or_else(|error| panic!("apply: {error}"));
    assert!(helper.is_file(), "the installer wrote no helper");
    assert_eq!(state(&f, "commit-guards", Ask::Surface), SetupState::Active);

    // Armed here and broken since: kendex's record stands and the
    // package's own check says the shims are gone. Not "never set up",
    // which the record disproves.
    fs::remove_file(f.project.join(".git/hooks/pre-commit")).unwrap();
    assert_eq!(
        state(&f, "commit-guards", Ask::Surface),
        SetupState::NeedsRepair
    );

    // Repair is the same run, and the state is read off the repository
    // again rather than taken from its exit.
    kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared)
        .unwrap_or_else(|error| panic!("repair: {error}"));
    assert_eq!(state(&f, "commit-guards", Ask::Surface), SetupState::Active);
}

/// The block the Set up button opens is the one an install would have
/// shown: the same disclosure, carrying the same declaration, so one
/// dialog asks the question wherever it arose.
#[test]
fn the_setup_block_is_the_install_s_own_disclosure() {
    let f = fixture();
    let installed = install_skills(&f, &["commit-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };

    let read = kendex_app::repo_effects::setup(&f.env, &f.scope, "commit-guards", Ask::Surface)
        .unwrap_or_else(|error| panic!("setup: {error}"));

    let shown = read.disclosure.unwrap_or_else(|| panic!("no disclosure"));
    assert_eq!(shown.declared, offer.declared);
    assert_eq!(shown.summary, offer.summary);
    assert_eq!(shown.writes, offer.writes);
}

/// Opening a package's page must not run a script the checkout supplies,
/// and no file the repository happens to hold may license one.
///
/// The whole trust rule, planted rather than argued. Every path the
/// package declares is on disk, exactly as a repository armed by another
/// tool or by a hostile clone's own installer would carry them, and its
/// `--check` is executable. kendex never armed this effect here, so
/// nothing runs.
///
/// The declared paths are planted because a licence read off one of them
/// would pass here. Only a record kendex wrote itself is one. The set is
/// read off the declaration the install loaded, so a path added to it is
/// planted too, and the plant is checked against that declaration.
#[test]
#[allow(clippy::unwrap_used)]
fn no_file_the_repository_holds_licenses_the_checkout_s_scripts() {
    let f = fixture();
    let installed = install_skills(&f, &["commit-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };
    // The package's own checker, replaced with one that records having
    // run. A clone's scripts are whatever its author wrote.
    let checker = f
        .project
        .join(".agents/skills/commit-guards/scripts/install-git-hooks");
    let ran = f.project.join("ran");
    fs::write(
        &checker,
        format!("#!/bin/sh\n: >'{}'\nexit 0\n", ran.display()),
    )
    .unwrap();
    fs::set_permissions(&checker, fs::Permissions::from_mode(0o755)).unwrap();
    // Every path the declaration lists, present and looking armed. The
    // declaration's own repo-relative paths, under the project, rather
    // than the disclosure's absolute lines: the claim is about what the
    // package declares, and it must still name the helper, or the plant
    // is empty and this proves nothing.
    let declared = &offer.declared.effects.writes;
    assert!(
        declared.iter().any(|written| written == HELPER),
        "the declaration no longer names the helper: {declared:?}"
    );
    for written in declared {
        let path = f.project.join(written);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "#!/bin/sh\n").unwrap();
    }
    for written in declared {
        assert!(
            f.project.join(written).is_file(),
            "declared path not planted: {written}"
        );
    }

    assert_eq!(
        state(&f, "commit-guards", Ask::Surface),
        SetupState::NotActive
    );

    assert!(
        !ran.exists(),
        "the checkout's script ran off a file kendex did not write"
    );
}

/// Somebody asking is its own licence, which is what makes a repository
/// armed at a terminal — or by hand — reportable at all.
///
/// The same fixture as the trust case above: no record of kendex arming
/// anything, and the package's own scripts on disk. A surface gets no
/// check; a person pressing the control that asks gets the package's real
/// answer.
#[test]
#[allow(clippy::unwrap_used)]
fn a_person_asking_reaches_a_repository_kendex_did_not_arm() {
    let f = fixture();
    install_skills(&f, &["commit-guards"], None);
    // Armed the way a terminal arms it, straight through the package's own
    // installer, with nothing of kendex's recorded.
    let report = kendex_core::repo_effects::run_script(
        &f.scope,
        &f.project.join(".agents/skills/commit-guards"),
        "scripts/install-git-hooks",
    )
    .unwrap_or_else(|error| panic!("arm by hand: {error}"));
    assert_eq!(report.code, 0, "{report:?}");
    assert!(f.project.join(HELPER).is_file());

    assert_eq!(
        state(&f, "commit-guards", Ask::Surface),
        SetupState::NotActive,
        "a page drawing itself has no licence here"
    );
    assert_eq!(
        state(&f, "commit-guards", Ask::Person),
        SetupState::Active,
        "somebody asking gets the package's own answer"
    );
}

/// `kendex guard install` and the window's yes mean one thing: a
/// repository armed at the terminal reports as armed on the page, without
/// anybody having to ask the package again.
#[test]
fn the_terminal_s_arming_is_the_window_s_arming() {
    let f = fixture();
    install_skills(&f, &["commit-guards"], None);

    let report = kendex_core::guard::install(&f.project)
        .unwrap_or_else(|error| panic!("guard install: {error}"));
    assert_eq!(report.code, 0, "{report:?}");

    assert_eq!(state(&f, "commit-guards", Ask::Surface), SetupState::Active);

    let report = kendex_core::guard::uninstall(&f.project)
        .unwrap_or_else(|error| panic!("guard uninstall: {error}"));
    assert_eq!(report.code, 0, "{report:?}");

    // Disarmed, and the record with it: a record left behind would licence
    // a check of an effect nothing here armed.
    assert_eq!(
        state(&f, "commit-guards", Ask::Surface),
        SetupState::NotActive
    );
}

/// A personal install changes no repository, so there is nothing there to
/// be set up and no state to report — never a read that failed.
#[test]
fn the_personal_place_has_no_repository_to_set_up() {
    let f = fixture();
    let installed = install_skills(&f, &["commit-guards"], None);
    let [offer] = installed.repo_effects.shown.as_slice() else {
        panic!("one offer: {:?}", installed.repo_effects);
    };

    let status = kendex_core::repo_effects::status(
        &kendex_core::model::Scope::Global,
        &offer.declared,
        Ask::Person,
    );

    assert_eq!(status.state, SetupState::NotARepository);
    assert!(status.said.is_empty(), "{:?}", status.said);
    assert!(!status.can_apply);
    assert!(!status.can_check);
}
