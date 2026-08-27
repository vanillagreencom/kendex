//! What a package says it does to the repository, and the separate yes.
//!
//! Split from `guarding`, which is about the gate itself once it is armed.
//! These are about the account a person is given before they arm it, and
//! about what that yes covers.

use std::fs;

use super::World;
use super::guarding::{git_without_kendex, offer, spoke};

/// The block a person reads before anything is armed, and the refusal that
/// follows when there is nobody there to read it.
///
/// The files a package installs land in folders kendex owns and are undone
/// by removing it. Arming git hooks is not that: it changes what happens on
/// every commit, for everyone who commits, and `apply? [y/N]` never asked
/// about that. A scripted install and a CI run both arrive with no
/// terminal, and arming their hooks because nobody was present to decline
/// is the one outcome this must never have.
#[test]
#[allow(clippy::unwrap_used)]
fn the_repository_effect_is_disclosed_and_not_applied_without_a_yes() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "growth-guards");
    let out = world.run(&["add", "cat", "--skill", "growth-guards", "-y"]);

    // What changes, where it writes, what else takes part, how to undo it.
    assert!(
        out.contains("changes how this repository works"),
        "no disclosure header:\n{out}"
    );
    assert!(out.contains("every commit in this repository"), "{out}");
    assert!(out.contains(".git/hooks/pre-commit"), "{out}");
    assert!(out.contains(".git/hooks/commit-msg"), "{out}");
    assert!(out.contains("size-ratchet"), "no companion line:\n{out}");
    assert!(out.contains("to undo:"), "{out}");

    // The refusal names the flag rather than leaving the reader to find it.
    assert!(
        out.contains("not applied: no terminal to ask at"),
        "no refusal:\n{out}"
    );
    assert!(out.contains("--allow-repo-effects"), "{out}");

    // Declining the effect still installs the package.
    assert!(
        world
            .at(".agents/skills/growth-guards/scripts/install-git-hooks")
            .is_file(),
        "the package did not install:\n{out}"
    );
    assert!(
        !world.at(".git/hooks/kendex-guards").exists(),
        "the hooks were armed anyway:\n{out}"
    );

    // The control: a commit the armed chain would block goes through, so
    // the assertion above is about a repository nothing is gating rather
    // than about a file git was never going to run.
    fs::write(world.at("b.rs"), "// TO".to_owned() + "DO: not yet\n").unwrap();
    let commit = git_without_kendex(&world.project, &["add", "-A"]);
    assert!(commit.status.success(), "{}", spoke(&commit));
    let commit = git_without_kendex(&world.project, &["commit", "-m", "chore: unguarded"]);
    assert!(
        commit.status.success(),
        "something gated an unarmed repository:\n{}",
        spoke(&commit)
    );
}

/// Saying yes arms the repository, and no later run inherits that yes.
///
/// `kendex refresh` repairs the files a package installs, by hand and in
/// the background. If it also armed hooks, a repository someone
/// deliberately disarmed would arm itself again behind them. Arming is the
/// invocation that says so — this one, or `kendex guard install`.
#[test]
#[allow(clippy::unwrap_used)]
fn the_yes_to_a_repository_effect_is_spent_where_it_is_given() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "growth-guards");
    let out = world.run(&[
        "add",
        "cat",
        "--skill",
        "growth-guards",
        "-y",
        "--allow-repo-effects",
    ]);
    assert!(
        world.at(".git/hooks/kendex-guards").is_file(),
        "the yes did not arm the hooks:\n{out}"
    );

    // Armed means gating, with no kendex in the picture.
    fs::write(world.at("b.rs"), "// TO".to_owned() + "DO: not yet\n").unwrap();
    let staged = git_without_kendex(&world.project, &["add", "-A"]);
    assert!(staged.status.success(), "{}", spoke(&staged));
    let blocked = git_without_kendex(&world.project, &["commit", "-m", "chore: marked"]);
    assert!(
        !blocked.status.success(),
        "the armed chain passed a banned marker:\n{}",
        spoke(&blocked)
    );

    // Disarm, then refresh. Nothing kendex stored says to arm again,
    // because the yes above was never written down.
    let disarmed = world.run(&["guard", "uninstall"]);
    assert!(
        !world.at(".git/hooks/kendex-guards").exists(),
        "uninstall left the helper:\n{disarmed}"
    );
    let refreshed = world.run(&["refresh"]);
    assert!(
        !world.at(".git/hooks/kendex-guards").exists(),
        "refresh re-armed a repository that was disarmed:\n{refreshed}"
    );

    // And the commit that was blocked passes now, so the disarm was real
    // and survived the refresh.
    let passes = git_without_kendex(&world.project, &["commit", "-m", "chore: marked"]);
    assert!(
        passes.status.success(),
        "a disarmed repository still gated:\n{}",
        spoke(&passes)
    );
}
