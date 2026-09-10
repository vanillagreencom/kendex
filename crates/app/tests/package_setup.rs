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

use kendex_core::repo_effects::SetupState;

/// The evidence commit-guards declares, and the file its installer leaves.
const EVIDENCE: &str = ".git/hooks/kendex-guards";

fn state(f: &Fixture, name: &str) -> SetupState {
    kendex_app::repo_effects::setup(&f.env, &f.scope, name)
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

    let read = kendex_app::repo_effects::setup(&f.env, &f.scope, "deploy")
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
    let helper = f.project.join(EVIDENCE);
    assert!(!helper.exists(), "the install armed the repository");

    // Installed, and nothing local has set it up. Said without running the
    // package's check at all.
    assert_eq!(state(&f, "commit-guards"), SetupState::NotActive);

    // The window's yes, through the one command that runs a declared
    // installer.
    kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared)
        .unwrap_or_else(|error| panic!("apply: {error}"));
    assert!(helper.is_file(), "the installer wrote no helper");
    assert_eq!(state(&f, "commit-guards"), SetupState::Active);

    // Armed here and broken since: the evidence stands and the package's
    // own check says the shims are gone. Not "never set up", which the
    // evidence disproves.
    fs::remove_file(f.project.join(".git/hooks/pre-commit")).unwrap();
    assert_eq!(state(&f, "commit-guards"), SetupState::NeedsRepair);

    // Repair is the same run, and the state is read off the repository
    // again rather than taken from its exit.
    kendex_app::repo_effects::apply(&f.env, &f.scope, &offer.declared)
        .unwrap_or_else(|error| panic!("repair: {error}"));
    assert_eq!(state(&f, "commit-guards"), SetupState::Active);
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

    let read = kendex_app::repo_effects::setup(&f.env, &f.scope, "commit-guards")
        .unwrap_or_else(|error| panic!("setup: {error}"));

    let shown = read.disclosure.unwrap_or_else(|| panic!("no disclosure"));
    assert_eq!(shown.declared, offer.declared);
    assert_eq!(shown.summary, offer.summary);
    assert_eq!(shown.writes, offer.writes);
}

/// Opening a package's page must not run a script the checkout supplies.
///
/// The whole trust rule, planted rather than argued: the package is
/// installed and its `--check` is on disk and executable, exactly as a
/// clone would carry it, and nothing local has armed the repository. The
/// status is taken and the checker leaves no trace, because it was never
/// run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_status_on_an_unarmed_checkout_runs_none_of_its_scripts() {
    let f = fixture();
    install_skills(&f, &["commit-guards"], None);
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

    assert_eq!(state(&f, "commit-guards"), SetupState::NotActive);

    assert!(
        !ran.exists(),
        "the checkout's script ran without a local act licensing it"
    );
}
