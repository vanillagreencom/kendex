//! What kendex did not write, it does not touch — through every install
//! path.

use crate::{World, read, tree};

fn plant_version_10_lock(world: &World) {
    let lock = world.at(".kendex-lock.json");
    let current = kendex_core::lock::LOCK_VERSION;
    let older = read(&lock).replace(
        &format!("\"version\": {current}"),
        &format!("\"version\": {}", current - 1),
    );
    assert_ne!(older, read(&lock), "the fixture must rewrite the version");
    crate::write(&lock, &older);
}

fn plant_version_10_state(world: &World) {
    plant_version_10_lock(world);
    let ignore = world.at(".gitignore");
    let legacy = read(&ignore).replace(
        "# kendex:local-state begin\n",
        "# kendex:local-state begin\n/.kendex-lock.json\n",
    );
    assert_ne!(legacy, read(&ignore), "the fixture must plant the old rule");
    crate::write(&ignore, &legacy);
}

#[allow(clippy::expect_used)]
fn move_old_lock_aside(world: &World) {
    std::fs::rename(
        world.at(".kendex-lock.json"),
        world.at(".kendex-lock.v10.json"),
    )
    .expect("version 10 lock moves aside for recovery");
}

fn declare_script_hook(world: &World, event: &str, matcher: &str) {
    crate::write(&world.catalog.join("kendex.toml"), "[catalog]\n");
    crate::write(
        &world.catalog.join("hooks/guard.sh"),
        &format!(
            "#!/bin/sh\n# ---\n# name: guard\n# event: {event}\n# matcher: {matcher}\n\
             # description: guards commands\n# ---\nexit 0\n"
        ),
    );
    crate::write(
        &world.at("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\n\
             method = \"copy\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            crate::test_util::source_path(&world.catalog)
        ),
    );
}

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

/// A verb that needs the lock stops at its parse error. Reading it as an
/// empty scope or skipping it would hide why the requested work did not run.
#[test]
fn a_scope_whose_lock_cannot_be_read_fails_at_the_read() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);

    // A record version this build does not read.
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

    for args in [&["remove", "deploy"][..], &["apply", "--plan"][..]] {
        let out = world.try_run(args);
        let said = crate::said(&out);
        assert!(
            !out.status.success(),
            "work that did not happen must not exit 0: {said}"
        );
        assert!(
            said.contains(".kendex-lock.v10.json") && said.contains("kendex apply"),
            "the parse error names the recovery path: {said}"
        );
        assert!(
            !said.contains("skipped") && !said.contains("could not read"),
            "the parse error must propagate directly: {said}"
        );
    }
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

#[allow(clippy::unwrap_used)]
fn declares_two_sources(world: &World, waiting_source: &str) {
    crate::write(
        &world.at("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[sources.waiting]\n{waiting_source}\n\n\
             [install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n\
             [skills.deploy]\nsource = \"cat\"\n\n[skills.wait]\nsource = \"waiting\"\n",
            crate::test_util::source_path(&world.catalog)
        ),
    );
}

/// The version 10 recovery is one complete sequence: the refusal names the
/// sidecar name and command, a normal apply updates the render whose bytes
/// match that record, removes the old managed ignore rule, and reports a
/// clone-local rule that still hides the new record. Once that local rule is
/// removed, check is clean.
#[test]
#[allow(clippy::unwrap_used)]
fn version_10_lock_recovery_completes_with_normal_apply() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.commit_all("version 10 install");
    crate::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_state(&world);

    let refused = world.try_run(&["apply", "--plan"]);
    let said = crate::said(&refused);
    assert!(!refused.status.success(), "{said}");
    assert!(
        said.contains(".kendex-lock.v10.json") && said.contains("kendex apply"),
        "the refusal must name the complete recovery: {said}"
    );

    move_old_lock_aside(&world);
    let exclude = world.at(".git/info/exclude");
    let mut exclude_text = read(&exclude);
    exclude_text.push_str("/.kendex-lock.json\n");
    crate::write(&exclude, &exclude_text);
    let applied = world.run(&["apply", "-y"]);
    assert!(
        applied.contains(&exclude.display().to_string())
            && applied.contains("ignores .kendex-lock.json"),
        "the apply must name the clone-local rule: {applied}"
    );
    assert!(
        read(&world.at(".agents/skills/deploy/SKILL.md")).contains("updated deploy"),
        "the stale render must be replaced"
    );
    assert!(
        !read(&world.at(".gitignore")).contains(".kendex-lock.json"),
        "the managed ignore block must stop hiding the record"
    );

    crate::write(&exclude, &exclude_text.replace("/.kendex-lock.json\n", ""));
    world.run(&["check"]);
    for (path, expected, reason) in [
        (
            ".kendex-lock.v10.json",
            Some(0),
            "the machine-specific recovery record must stay ignored",
        ),
        (
            ".kendex-lock.json",
            Some(1),
            "the portable current lock must be visible to Git",
        ),
    ] {
        let ignored = crate::git_output(&world.project, &["check-ignore", "--no-index", path]);
        assert_eq!(ignored.status.code(), expected, "{reason}");
    }
}

/// A pending source can make the first recovery apply partial. The current
/// lock and the refreshed ignore block then stop carrying the original
/// one-shot conditions, so the sidecar itself must keep proving ownership of
/// the declaration that the retry can finally read.
#[test]
#[allow(clippy::unwrap_used)]
fn version_10_recovery_continues_after_a_partial_apply() {
    let world = World::new(&["claude"]);
    let waiting = world.home.join("waiting-catalog");
    crate::write(
        &waiting.join("skills/wait/SKILL.md"),
        "---\nname: wait\ndescription: wait for the source\n---\nRun the wait.\n",
    );
    let ready = crate::test_util::source_path(&waiting);
    declares_two_sources(&world, &ready);
    world.run(&["apply", "-y"]);
    world.commit_all("version 10 two-source install");

    crate::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    crate::write(
        &waiting.join("skills/wait/SKILL.md"),
        "---\nname: wait\ndescription: wait for the source\n---\nRun the updated wait.\n",
    );
    declares_two_sources(&world, "repo = \"owner/pending\"");
    plant_version_10_state(&world);
    move_old_lock_aside(&world);

    let first = world.run(&["apply", "-y"]);
    assert!(first.contains("not fetched yet"), "{first}");
    let partial = kendex_core::lock::load(&world.at(".kendex-lock.json")).unwrap();
    assert!(
        partial.entries.values().any(|entry| entry.name == "deploy"),
        "the first apply did not record its recovered entry: {partial:?}"
    );
    assert!(
        partial.entries.values().all(|entry| entry.name != "wait"),
        "the pending entry was recorded before its source resolved: {partial:?}"
    );
    assert!(
        !read(&world.at(".gitignore")).contains("/.kendex-lock.json"),
        "the first apply must remove the legacy ignore rule"
    );

    let deploy = world.at(".agents/skills/deploy/SKILL.md");
    let recovered = read(&deploy);
    crate::write(&deploy, "person's edit after the partial recovery\n");
    let held = crate::said(&world.try_run(&["apply", "--plan"]));
    assert!(held.contains("conflict: skill deploy"), "{held}");
    crate::write(&deploy, &recovered);

    declares_two_sources(&world, &ready);
    world.run(&["apply", "-y"]);
    assert!(
        read(&world.at(".agents/skills/wait/SKILL.md")).contains("updated wait"),
        "the retry must recover the remaining sidecar-proven render"
    );
}

/// A project outside Git has no managed ignore block. The moved record is
/// still a complete per-entry ownership proof, so normal recovery works there
/// with the same hash boundary.
#[test]
#[allow(clippy::unwrap_used)]
fn version_10_recovery_works_outside_git() {
    let world = World::new(&["claude"]);
    std::fs::remove_dir_all(world.at(".git")).unwrap();
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    assert!(
        !world.at(".gitignore").exists(),
        "a non-Git project must not get a Git marker"
    );
    crate::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_lock(&world);
    move_old_lock_aside(&world);

    world.run(&["apply", "-y"]);
    assert!(
        read(&world.at(".agents/skills/deploy/SKILL.md")).contains("updated deploy"),
        "the non-Git recovery must replace the sidecar-proven render"
    );
}

/// The old record's rendered hash is the ownership boundary during version
/// 10 recovery. Even a committed hand edit stays a conflict when its bytes
/// do not match that record.
#[test]
fn version_10_recovery_keeps_a_hand_edited_render_as_a_conflict() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.commit_all("version 10 install");
    let rendered = world.at(".agents/skills/deploy/SKILL.md");
    crate::write(&rendered, "person's edit\n");
    crate::git(&world.project, &["add", ".agents/skills/deploy/SKILL.md"]);
    crate::git(&world.project, &["commit", "-m", "committed hand edit"]);
    crate::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_state(&world);
    move_old_lock_aside(&world);

    let planned = crate::said(&world.try_run(&["apply", "--plan"]));
    assert!(planned.contains("conflict: skill deploy"), "{planned}");
    assert_eq!(read(&rendered), "person's edit\n");
}

/// A saved script-backed registration names the exact old entry. Recovery
/// retires it through the normal reconciliation before it writes the new
/// event and matcher, so the hook cannot run twice.
#[test]
fn version_10_hook_recovery_retires_the_saved_registration() {
    let world = World::new(&["claude"]);
    declare_script_hook(&world, "PreToolUse", "Bash");
    world.run(&["apply", "-y"]);
    plant_version_10_state(&world);
    move_old_lock_aside(&world);
    declare_script_hook(&world, "PostToolUse", "Edit");

    world.run(&["apply", "-y"]);

    let settings = read(&world.at(".claude/settings.json"));
    assert!(!settings.contains("PreToolUse"), "{settings}");
    assert!(settings.contains("PostToolUse"), "{settings}");
    assert!(settings.contains("Edit"), "{settings}");
    assert_eq!(settings.matches("guard.sh").count(), 1, "{settings}");
}

/// The registration identity is usable only after the script bytes prove
/// ownership. An edited script blocks both its replacement and any registry
/// change, leaving the person's old entry intact.
#[test]
fn version_10_hook_recovery_keeps_an_edited_script_and_registration() {
    let world = World::new(&["claude"]);
    declare_script_hook(&world, "PreToolUse", "Bash");
    world.run(&["apply", "-y"]);
    plant_version_10_state(&world);
    move_old_lock_aside(&world);
    let script = world.at(".claude/hooks/guard.sh");
    crate::write(&script, "#!/bin/sh\necho person's edit\n");
    declare_script_hook(&world, "PostToolUse", "Edit");

    let planned = crate::said(&world.try_run(&["apply", "--plan"]));

    assert!(planned.contains("conflict: hook guard"), "{planned}");
    assert_eq!(read(&script), "#!/bin/sh\necho person's edit\n");
    let settings = read(&world.at(".claude/settings.json"));
    assert!(settings.contains("PreToolUse"), "{settings}");
    assert!(!settings.contains("PostToolUse"), "{settings}");
    assert_eq!(settings.matches("guard.sh").count(), 1, "{settings}");
}
