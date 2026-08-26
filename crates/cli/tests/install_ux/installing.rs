//! Fresh installs: which tools a package fans out to, how it is delivered,
//! and what a second run of the same command does.

use crate::{World, link_text, read, tree};

/// Symlink delivery, the default: one real tree in the shared home and a
/// link from the only tool that does not read it, spelled relative so the
/// pair is committable.
#[test]
fn a_symlink_install_fans_out_from_one_shared_tree() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    let shared = world.at(".agents/skills/deploy");
    assert!(shared.is_dir() && !shared.is_symlink());
    assert!(read(&shared.join("SKILL.md")).contains("Run the deploy."));
    assert!(read(&shared.join("reference.md")).contains("The long version."));

    let claude = world.at(".claude/skills/deploy");
    assert_eq!(link_text(&claude), "../../.agents/skills/deploy");
    assert!(read(&claude.join("SKILL.md")).contains("Run the deploy."));

    // Codex reads the shared tree itself, so nothing is written for it.
    assert!(!world.at(".codex/skills").exists());
}

/// Copy delivery: a real tree per tool, no links anywhere.
#[test]
fn a_copy_install_gives_every_tool_its_own_tree() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "--method", "copy", "-y"]);

    let claude = world.at(".claude/skills/deploy");
    assert!(claude.is_dir() && !claude.is_symlink());
    assert!(read(&claude.join("SKILL.md")).contains("Run the deploy."));
    assert!(read(&world.at(".agents/skills/deploy/SKILL.md")).contains("Run the deploy."));
    assert!(
        world.manifest().contains("method = \"copy\""),
        "{}",
        world.manifest()
    );
}

/// `--harness` picks the fan-out without a terminal, and the choice is
/// written down so every later refresh honours it.
#[test]
fn an_explicit_harness_list_is_the_install_and_is_persisted() {
    let world = World::new(&["claude", "codex", "gemini"]);
    world.declare_catalog();
    world.run(&[
        "add",
        "cat",
        "--skill",
        "deploy",
        "--harness",
        "claude",
        "-y",
    ]);

    let manifest = world.manifest();
    assert!(manifest.contains("harnesses = [\"claude\"]"), "{manifest}");
    assert!(world.at(".claude/skills/deploy").is_symlink());
    assert!(world.at(".agents/skills/deploy").is_dir());
}

/// An explicit choice answers the question detection would have asked, so
/// it must not widen the scope's own defaults under it — every other item
/// there would redeploy to a tool nobody named on this run.
#[test]
fn an_explicit_choice_does_not_widen_the_scope_defaults() {
    let world = World::new(&["claude", "codex", "gemini"]);
    world.declare_catalog();
    world.run(&[
        "add",
        "cat",
        "--skill",
        "deploy",
        "--harness",
        "claude",
        "-y",
    ]);

    let manifest = world.manifest();
    let defaults = manifest
        .lines()
        .find(|line| line.starts_with("harnesses = "))
        .unwrap_or_default();
    assert!(!defaults.contains("codex"), "{manifest}");
    assert!(!defaults.contains("gemini"), "{manifest}");
    assert!(!world.at(".codex").exists());
}

/// Every supported tool at once, whether or not it is on this machine.
#[test]
fn all_harnesses_targets_every_tool_that_installs_here() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "--all-harnesses", "-y"]);

    let manifest = world.manifest();
    for harness in [
        "claude", "codex", "cursor", "gemini", "opencode", "copilot", "pi",
    ] {
        assert!(
            manifest.contains(harness),
            "{harness} missing from {manifest}"
        );
    }
}

/// Success has to mean bytes landed somewhere. An emptied selection, and a
/// selection of tools that take none of what is being installed, are both
/// refused before the manifest is touched.
#[test]
fn an_install_that_would_land_nowhere_is_refused() {
    let world = World::new(&["claude"]);
    world.declare_catalog();

    let nowhere = world.try_run(&["add", "cat", "--skill", "deploy", "--harness", "", "-y"]);
    let said = crate::said(&nowhere);
    assert!(!nowhere.status.success(), "{said}");
    assert!(said.contains("nothing would be installed"), "{said}");

    // Cursor takes skills but no MCP servers, so naming it for one is a
    // request that would plan nothing.
    let wrong = world.try_run(&[
        "add",
        "cat",
        "--mcp-server",
        "gh",
        "--harness",
        "cursor",
        "-y",
    ]);
    let said = crate::said(&wrong);
    assert!(!wrong.status.success(), "{said}");
    assert!(said.contains("nothing would be installed"), "{said}");

    // Nothing was written on the way past either refusal.
    assert!(!world.manifest().contains("deploy"), "{}", world.manifest());
    assert!(!world.at(".kendex-lock.json").exists());
}

/// A copy delivery is a tree only that tool reads, so Cursor's goes in
/// `.cursor/skills` — never into the shared tree it also reads, which every
/// other tool would then pick up as a second copy.
#[test]
fn a_copy_delivery_for_cursor_writes_its_own_directory() {
    let world = World::new(&["cursor"]);
    world.declare_catalog();
    world.run(&[
        "add",
        "cat",
        "--skill",
        "deploy",
        "--harness",
        "cursor",
        "--method",
        "copy",
        "-y",
    ]);

    assert!(world.at(".cursor/skills/deploy/SKILL.md").is_file());
    assert!(!world.at(".agents/skills/deploy").exists());
}

/// The delivery is made even when the tool's own directory does not exist
/// yet — the bug class the Vercel installer shipped, where a successful
/// install left the tool seeing nothing.
#[test]
fn a_tool_with_no_directory_yet_still_gets_its_link() {
    let world = World::new(&[]);
    world.declare_catalog();
    assert!(!world.at(".claude").exists());
    world.run(&[
        "add",
        "cat",
        "--skill",
        "deploy",
        "--harness",
        "claude",
        "-y",
    ]);
    assert!(world.at(".claude/skills/deploy").is_symlink());
}

/// A second refresh over a settled scope writes nothing and says so.
#[test]
fn refresh_is_idempotent() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    let before = tree(&world.project);

    world.run(&["refresh", "-y"]);
    assert_eq!(tree(&world.project), before);
    world.run(&["refresh", "-y"]);
    assert_eq!(tree(&world.project), before);
    assert!(world.try_run(&["check"]).status.success());
}

/// The lock is this machine's ledger, so kendex keeps it out of the
/// repository — and touches nothing else in the ignore file.
#[test]
fn the_install_ledger_is_the_only_thing_kendex_ignores() {
    let world = World::new(&["claude"]);
    crate::write(&world.at(".gitignore"), "target/\n");
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    let ignore = read(&world.at(".gitignore"));
    assert!(ignore.starts_with("target/\n"), "{ignore}");
    let rules: Vec<&str> = ignore
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();
    assert_eq!(rules, ["target/", "/.kendex-lock.json"], "{ignore}");

    // Said once: a refresh over a scope that already has the line writes
    // no second copy of it.
    world.run(&["refresh", "-y"]);
    assert_eq!(read(&world.at(".gitignore")), ignore);
}

/// git reads its ignore rules last-match-wins, so a negation below an
/// ignore leaves the lock tracked and the block still has to be written.
#[test]
fn a_negation_below_the_ignore_is_not_coverage() {
    let world = World::new(&["claude"]);
    crate::write(
        &world.at(".gitignore"),
        "/.kendex-lock.json\n!/.kendex-lock.json\n",
    );
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    let ignore = read(&world.at(".gitignore"));
    let rules: Vec<&str> = ignore
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();
    assert_eq!(rules.last(), Some(&"/.kendex-lock.json"), "{ignore}");
}

/// An install that cannot be shared is worth saying out loud rather than
/// discovering on a teammate's first clone.
#[test]
fn ignoring_the_shared_tree_is_reported() {
    let world = World::new(&["claude"]);
    crate::write(&world.at(".gitignore"), ".agents/\n");
    world.declare_catalog();
    let said = world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    assert!(said.contains(".agents"), "{said}");
    assert!(said.contains("clones"), "{said}");
}
