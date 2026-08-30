//! What kendex did not write, it does not touch — through every path the
//! install work added.

use crate::{World, read, tree};

/// A neighbour in each directory kendex writes into, surviving the whole
/// install → refresh → remove round trip byte for byte.
#[test]
fn unmanaged_neighbours_survive_install_refresh_and_remove() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    let neighbours = [
        (
            ".claude/skills/hand-made/SKILL.md",
            "---\nname: hand-made\ndescription: mine\n---\nMine.\n",
        ),
        (
            ".agents/skills/theirs/SKILL.md",
            "---\nname: theirs\ndescription: theirs\n---\nTheirs.\n",
        ),
        (".claude/settings.json", "{\"env\": {\"MINE\": \"1\"}}\n"),
    ];
    for (rel, text) in neighbours {
        crate::write(&world.at(rel), text);
    }
    let before: Vec<String> = neighbours
        .iter()
        .map(|(rel, _)| read(&world.at(rel)))
        .collect();

    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.run(&["refresh", "-y"]);
    world.run(&["remove", "deploy"]);

    for ((rel, _), was) in neighbours.iter().zip(before) {
        assert_eq!(read(&world.at(rel)), was, "{rel} changed");
    }
}

/// Undeclared content is reported, so it can be managed on purpose rather
/// than discovered by a tool quietly taking it.
#[test]
fn unmanaged_content_is_reported_not_taken() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(
        &world.at(".claude/skills/hand-made/SKILL.md"),
        "---\nname: hand-made\ndescription: mine\n---\nMine.\n",
    );
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    let said = crate::said(&world.try_run(&["verify"]));
    assert!(said.contains("hand-made"), "{said}");
    assert!(said.contains("not managed"), "{said}");
    assert!(read(&world.at(".claude/skills/hand-made/SKILL.md")).contains("Mine."));
}

/// A foreign hook registration in the same settings file kendex writes its
/// own into: the file gains an entry, and loses nothing.
#[test]
fn a_foreign_hook_registration_is_left_alone() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    crate::write(
        &world.at(".claude/settings.json"),
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "./scripts/mine.sh"}]}]}, "env": {"KEEP": "1"}}"#,
    );
    crate::write(&world.at("scripts/mine.sh"), "#!/bin/sh\nexit 0\n");
    let before = read(&world.at(".claude/settings.json"));

    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    let after = read(&world.at(".claude/settings.json"));
    assert!(after.contains("./scripts/mine.sh"), "{after}");
    assert!(after.contains("KEEP"), "{after}");
    assert_eq!(before.contains("kendex"), after.contains("kendex"));
}

/// A copy install put its tree in each tool's own directory, so that is
/// what removal has to take back — reading the shared tree's path instead
/// would leave the copy behind with nothing recording it.
#[test]
fn removing_a_copy_install_takes_back_the_per_tool_trees() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "--method", "copy", "-y"]);
    assert!(world.at(".claude/skills/deploy/SKILL.md").is_file());

    world.run(&["remove", "deploy"]);
    assert!(!world.at(".claude/skills/deploy").exists());
    assert!(!world.at(".agents/skills/deploy").exists());
}

/// Removing an item takes back exactly what the install wrote.
#[test]
fn removing_an_item_leaves_the_project_as_it_was() {
    let world = World::new(&["claude", "codex"]);
    world.declare_catalog();
    let before = tree(&world.project);
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.run(&["remove", "deploy"]);

    let after = tree(&world.project);
    let added: Vec<&String> = after.iter().filter(|path| !before.contains(path)).collect();
    for path in &added {
        // What is left is kendex's own bookkeeping and the empty shells of
        // the directories it wrote into — never a copy of the item.
        assert!(
            !path.contains("deploy"),
            "removal left {path} behind:\n{after:?}"
        );
    }
}

/// A scope whose lock this build cannot read is skipped and named, and the
/// run still fails. Skipped, so `remove` visits every scope the filter
/// names rather than leaving the rest untouched with nothing saying so;
/// failed, because exit 0 with the item still installed says the removal
/// happened. `refresh` walks its scopes the same way.
#[test]
fn a_scope_whose_lock_cannot_be_read_is_skipped_and_named() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    // The record an older kendex left: this build reads no such version.
    let lock = world.at(".kendex-lock.json");
    let current = kendex_core::lock::LOCK_VERSION;
    let older = read(&lock).replace(
        &format!("\"version\": {current}"),
        &format!("\"version\": {}", current - 1),
    );
    assert_ne!(
        older,
        read(&lock),
        "the version line must be the one rewritten"
    );
    crate::write(&lock, &older);

    let out = world.try_run(&["remove", "deploy"]);
    let said = crate::said(&out);
    assert!(
        !out.status.success(),
        "a removal that did not happen must not exit 0: {said}"
    );
    assert!(
        said.contains("skipped"),
        "the scope is named as skipped: {said}"
    );
    assert!(
        said.contains("install fresh"),
        "naming why, in the words the refusal uses: {said}"
    );
    assert!(
        said.contains("could not read 1 scope"),
        "and the run closes on what it could not do: {said}"
    );
    assert!(
        !said.contains("Nothing removed"),
        "which is not the same as there being nothing to remove: {said}"
    );
    assert_eq!(
        read(&lock),
        older,
        "the file it could not read is left alone"
    );
    assert!(
        world.at(".claude/skills/deploy").exists(),
        "and the item it could not account for is still installed"
    );
}
