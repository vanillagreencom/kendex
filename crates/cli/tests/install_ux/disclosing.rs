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
    offer(&world, "commit-guards");
    // One declared write outside `.git`, so the block carries both kinds.
    // The shared claim is about the repository's own directory, and a file
    // that lives in this checkout must not be swept into it.
    let declaration = world.catalog.join("skills/commit-guards/SKILL.md");
    let text = fs::read_to_string(&declaration).unwrap();
    let anchor = "    - \".git/hooks/commit-msg\"\n";
    assert!(text.contains(anchor), "the declaration moved");
    fs::write(
        &declaration,
        text.replace(anchor, &format!("{anchor}    - \".github/x\"\n")),
    )
    .unwrap();
    let spoken = world.try_run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    assert!(spoken.status.success(), "{}", spoke(&spoken));
    let asked = String::from_utf8_lossy(&spoken.stderr).into_owned();
    let composed = String::from_utf8_lossy(&spoken.stdout).into_owned();
    let out = format!("{composed}{asked}");

    // On the channel the question is on. A person who redirects stdout to
    // a file is still asked whether to arm their repository, so the account
    // of what that means has to reach them where the asking does.
    assert!(
        asked.contains("changes how this repository works"),
        "the disclosure was not on the channel that asks:\n{out}"
    );
    assert!(
        !composed.contains("changes how this repository works"),
        "the disclosure went to stdout:\n{out}"
    );

    // What changes, where it writes, what else takes part, how to undo it.
    assert!(out.contains("every commit in this repository"), "{out}");
    assert!(out.contains(".git/hooks/pre-commit"), "{out}");
    assert!(out.contains(".git/hooks/commit-msg"), "{out}");
    assert!(
        out.contains("doc-limits (not installed)"),
        "no companion line:\n{out}"
    );
    assert!(out.contains("to undo:"), "{out}");

    // Marked path by path: a sentence under the whole list would claim the
    // repository shares every file in it, including the checkout-local one.
    assert!(out.contains(".git/hooks/pre-commit  (shared)"), "{out}");
    assert!(
        out.lines()
            .any(|line| line.trim_end().ends_with(".github/x")),
        "the checkout-local path was marked shared:\n{out}"
    );
    assert!(
        out.contains("the paths marked shared are the repository's"),
        "{out}"
    );

    // The refusal names the flag rather than leaving the reader to find it.
    assert!(
        out.contains("not applied: no terminal to ask at"),
        "no refusal:\n{out}"
    );
    assert!(out.contains("--allow-repo-effects"), "{out}");

    // Declining the effect still installs the package.
    assert!(
        world
            .at(".agents/skills/commit-guards/scripts/install-git-hooks")
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
    offer(&world, "commit-guards");
    let out = world.run(&[
        "add",
        "cat",
        "--skill",
        "commit-guards",
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

/// What a person writes into `kendex.toml` to declare the package without
/// an `add`: where it installs to, and the package itself.
const DECLARED_BY_HAND: &str =
    "\n[install]\nharnesses = [\"claude\"]\n\n[skills.commit-guards]\nsource = \"cat\"\n";

/// A declaration written by hand installs through `kendex apply`, and the
/// package it installs gets the same account and the same separate yes an
/// `add` would have given it — the walkthrough belongs to the install, not
/// to the verb that started it.
#[test]
#[allow(clippy::unwrap_used)]
fn apply_discloses_a_hand_declared_package_and_waits_for_its_own_yes() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "commit-guards");
    fs::write(world.at("kendex.toml"), world.manifest() + DECLARED_BY_HAND).unwrap();

    let spoken = world.try_run(&["apply", "-y"]);
    assert!(spoken.status.success(), "{}", spoke(&spoken));
    let out = spoke(&spoken);
    assert!(
        out.contains("changes how this repository works"),
        "apply installed the package without its account:\n{out}"
    );
    assert!(out.contains("--allow-repo-effects"), "{out}");
    assert!(
        world
            .at(".agents/skills/commit-guards/scripts/install-git-hooks")
            .is_file(),
        "the package did not install:\n{out}"
    );
    assert!(
        !world.at(".git/hooks/kendex-guards").exists(),
        "apply armed the hooks with nobody there to say yes:\n{out}"
    );

    // The same flag means yes here too, in a repository that never said it.
    let armed = World::new(&["claude"]);
    armed.declare_catalog();
    offer(&armed, "commit-guards");
    fs::write(armed.at("kendex.toml"), armed.manifest() + DECLARED_BY_HAND).unwrap();
    let out = armed.run(&["apply", "-y", "--allow-repo-effects"]);
    assert!(
        armed.at(".git/hooks/kendex-guards").is_file(),
        "the yes did not arm the hooks:\n{out}"
    );
}

/// Which companions are here is kendex's answer, not the package's: one
/// installed before the declaring package reads as installed in its block.
#[test]
fn a_companion_already_here_reads_as_installed() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    offer(&world, "doc-limits");
    offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "doc-limits", "-y"]);
    let spoken = world.try_run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    let out = spoke(&spoken);
    assert!(spoken.status.success(), "{out}");
    assert!(out.contains("doc-limits (installed)"), "{out}");
    assert!(out.contains("preflight (not installed)"), "{out}");
}
