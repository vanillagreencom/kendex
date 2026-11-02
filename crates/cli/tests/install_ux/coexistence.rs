//! What kendex did not write, it does not touch — through every install
//! path.

use super::{World, read, tree};

fn plant_version_10_lock(world: &World) {
    let lock = world.at(".kendex-lock.json");
    let current = kendex_core::lock::LOCK_VERSION;
    let older = read(&lock).replace(
        &format!("\"version\": {current}"),
        &format!("\"version\": {}", current - 1),
    );
    assert_ne!(older, read(&lock), "the fixture must rewrite the version");
    super::write(&lock, &older);
}

fn plant_version_10_state(world: &World) {
    plant_version_10_lock(world);
    let ignore = world.at(".gitignore");
    let legacy = read(&ignore).replace(
        "# kendex:local-state begin\n",
        "# kendex:local-state begin\n/.kendex-lock.json\n",
    );
    assert_ne!(legacy, read(&ignore), "the fixture must plant the old rule");
    super::write(&ignore, &legacy);
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
    super::write(&world.catalog.join("kendex.toml"), "[catalog]\n");
    super::write(
        &world.catalog.join("hooks/guard.sh"),
        &format!(
            "#!/bin/sh\n# ---\n# name: guard\n# event: {event}\n# matcher: {matcher}\n\
             # description: guards commands\n# ---\nexit 0\n"
        ),
    );
    super::write(
        &world.at("kendex.toml"),
        &format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\n\
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
        super::write(&world.at(rel), text);
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
    super::write(
        &world.at(".claude/skills/hand-made/SKILL.md"),
        "---\nname: hand-made\ndescription: mine\n---\nMine.\n",
    );
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    let said = super::said(&world.try_run(&["verify"]));
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
    super::write(
        &world.at(".claude/settings.json"),
        r#"{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "./scripts/mine.sh"}]}]}, "env": {"KEEP": "1"}}"#,
    );
    super::write(&world.at("scripts/mine.sh"), "#!/bin/sh\nexit 0\n");
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
/// A preview of the apply that recovers the record writes nothing either.
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
    super::write(&lock, &older);

    let out = world.try_run(&["remove", "deploy"]);
    let said = super::said(&out);
    assert!(
        !out.status.success(),
        "work that did not happen must not exit 0: {said}"
    );
    assert_eq!(
        refused_version_10_lines(&out),
        1,
        "fleet reads the refusal by its key: {said}"
    );
    assert!(
        !said.contains("skipped") && !said.contains("could not read"),
        "the parse error must propagate directly: {said}"
    );
    world.run(&["apply", "--plan"]);
    assert!(!world.at(".kendex-lock.v10.json").exists());
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
    super::write(
        &world.at("kendex.toml"),
        &format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[sources.waiting]\n{waiting_source}\n\n\
             [install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n\
             [skills.deploy]\nsource = \"cat\"\n\n[skills.wait]\nsource = \"waiting\"\n",
            crate::test_util::source_path(&world.catalog)
        ),
    );
}

/// The `lock-version-refused` lines a run printed for a version 10 record:
/// the key fleet's lane lock migration reads.
fn refused_version_10_lines(output: &std::process::Output) -> usize {
    String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter(|line| line.contains("lock-version-refused found=10"))
        .count()
}

/// Every `finish-with=` value a run printed: the one completion a program
/// reads, said in the conflicts section and the closing ledger alike.
fn finish_with(output: &std::process::Output) -> Vec<String> {
    super::said(output)
        .lines()
        .filter_map(|line| line.split_once("finish-with=").map(|(_, rest)| rest))
        .map(|rest| rest.split(" — ").next().unwrap_or(rest).trim().to_owned())
        .collect()
}

/// The owner's first project: a refresh recovers a version 10 record with
/// no hand move. It updates the render whose bytes match that record,
/// keeps the old record aside and ignored, removes the old managed ignore
/// rule, and reports a clone-local rule that still hides the new record.
/// Once that local rule is removed, check is clean.
#[test]
#[allow(clippy::unwrap_used)]
fn version_10_lock_recovery_completes_with_one_refresh() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.commit_all("version 10 install");
    super::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_state(&world);
    let older = read(&world.at(".kendex-lock.json"));

    let exclude = world.at(".git/info/exclude");
    let mut exclude_text = read(&exclude);
    exclude_text.push_str("/.kendex-lock.json\n");
    super::write(&exclude, &exclude_text);
    let applied = world.run(&["refresh", "--yes"]);
    kendex_core::lock::load(&world.at(".kendex-lock.json")).unwrap();
    assert_eq!(read(&world.at(".kendex-lock.v10.json")), older);
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

    super::write(&exclude, &exclude_text.replace("/.kendex-lock.json\n", ""));
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
        let ignored = super::git_output(&world.project, &["check-ignore", "--no-index", path]);
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
    super::write(
        &waiting.join("skills/wait/SKILL.md"),
        "---\nname: wait\ndescription: wait for the source\n---\nRun the wait.\n",
    );
    let ready = crate::test_util::source_path(&waiting);
    declares_two_sources(&world, &ready);
    world.run(&["apply", "-y"]);
    world.commit_all("version 10 two-source install");

    super::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    super::write(
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
    super::write(&deploy, "person's edit after the partial recovery\n");
    let held = super::said(&world.try_run(&["apply", "--plan"]));
    assert!(held.contains("conflicts:\n  skill deploy"), "{held}");
    super::write(&deploy, &recovered);

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
    super::write(
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
    super::write(&rendered, "person's edit\n");
    super::git(&world.project, &["add", ".agents/skills/deploy/SKILL.md"]);
    super::git(&world.project, &["commit", "-m", "committed hand edit"]);
    super::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_state(&world);

    let refreshed = super::said(&world.try_run(&["refresh", "--yes"]));
    assert!(
        refreshed.contains("conflicts:\n  skill deploy"),
        "{refreshed}"
    );
    assert_eq!(read(&rendered), "person's edit\n");
    kendex_core::lock::load(&world.at(".kendex-lock.json")).unwrap_or_else(|error| {
        panic!("the rest of the scope recovers beside the conflict: {error}")
    });
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
    let script = world.at(".claude/hooks/guard.sh");
    super::write(&script, "#!/bin/sh\necho person's edit\n");
    let neighbour = world.at(".claude/skills/hand-made/SKILL.md");
    super::write(
        &neighbour,
        "---\nname: hand-made\ndescription: mine\n---\nMine.\n",
    );
    declare_script_hook(&world, "PostToolUse", "Edit");

    let refreshed = super::said(&world.try_run(&["refresh", "--yes"]));

    assert!(
        refreshed.contains("conflicts:\n  hook guard"),
        "{refreshed}"
    );
    assert_eq!(read(&script), "#!/bin/sh\necho person's edit\n");
    assert_eq!(
        read(&neighbour),
        "---\nname: hand-made\ndescription: mine\n---\nMine.\n"
    );
    let settings = read(&world.at(".claude/settings.json"));
    assert!(settings.contains("PreToolUse"), "{settings}");
    assert!(!settings.contains("PostToolUse"), "{settings}");
    assert_eq!(settings.matches("guard.sh").count(), 1, "{settings}");
}

/// The `replace-unmanaged` remedies `check --json` printed, each as its
/// `allowRepoEffects` value: the remedy a program reads off the check.
#[allow(clippy::unwrap_used)]
fn replace_remedies(output: &std::process::Output) -> Vec<bool> {
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    report["sections"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|section| section["lines"].as_array().into_iter().flatten())
        .filter(|line| line["remedy"]["verb"] == "replace-unmanaged")
        .map(|line| line["remedy"]["allowRepoEffects"] == true)
        .collect()
}

/// The owner's second project: a version 10 record beside a render whose
/// bytes no longer match it, and a package declaring a repository effect
/// held behind that conflict. One refresh recovers the rest and names one
/// completion, carrying the repository-effect permission; the conflicts
/// section, the closing ledger and `check --json` name the same action,
/// and nothing prints a pasteable take-over. The session report names the
/// take-over without the permission a person gives. Running the named
/// action leaves the check clean.
#[test]
#[allow(clippy::unwrap_used)]
fn version_10_recovery_names_one_completion_with_its_repository_effect() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    super::guarding::offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    world.run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    world.commit_all("version 10 install");
    super::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    let held = world.at(".agents/skills/commit-guards/SKILL.md");
    super::write(
        &held,
        &format!("{}\na drifted committed line\n", read(&held)),
    );
    plant_version_10_state(&world);

    let refreshed = world.try_run(&["refresh", "--yes"]);
    let said = super::said(&refreshed);
    assert!(refreshed.status.success(), "{said}");
    assert!(
        read(&world.at(".agents/skills/deploy/SKILL.md")).contains("updated deploy"),
        "the proven render is replaced: {said}"
    );
    assert!(read(&held).contains("a drifted committed line"), "{said}");
    let named = finish_with(&refreshed);
    assert!(named.len() >= 2, "the section and the ledger: {said}");
    assert!(
        named
            .iter()
            .all(|value| value == "apply replace-unmanaged allow-repo-effects"),
        "{named:?}"
    );
    assert!(!said.contains("--replace-unmanaged"), "{said}");

    // Named from elsewhere, the completion names the project too.
    let project = world.project.display().to_string();
    let named = super::kendex(
        &world.home,
        &world.home,
        &[
            "refresh",
            "--yes",
            "--throwaway",
            "--project-path",
            &project,
        ],
    );
    let finish = finish_with(&named);
    assert!(!finish.is_empty(), "{}", super::said(&named));
    let want = format!("apply replace-unmanaged allow-repo-effects project={project}");
    assert!(finish.iter().all(|value| *value == want), "{finish:?}");

    let json = world.try_run(&["check", "--json"]);
    assert_eq!(replace_remedies(&json), [true], "{}", super::said(&json));
    let person = super::said(&world.try_run(&["check"]));
    assert!(
        person.contains("kendex apply --replace-unmanaged --allow-repo-effects"),
        "{person}"
    );
    let session = super::said(&world.try_run(&["check", "--quiet"]));
    assert!(
        session.contains("kendex apply --replace-unmanaged"),
        "{session}"
    );
    assert!(!session.contains("--allow-repo-effects"), "{session}");

    world.run(&["apply", "--replace-unmanaged", "--allow-repo-effects", "-y"]);
    assert!(world.at(".git/hooks/kendex-guards").is_file());
    let clean = world.try_run(&["check"]);
    assert_eq!(clean.status.code(), Some(0), "{}", super::said(&clean));
}

/// The recovery's move is a write like any other: a run with no terminal
/// and no `--yes` refuses before it, leaving the record where it was.
#[test]
fn a_version_10_recovery_with_nobody_to_ask_writes_nothing() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    plant_version_10_state(&world);
    let older = read(&world.at(".kendex-lock.json"));

    let refused = world.try_run(&["refresh"]);
    assert!(!refused.status.success(), "{}", super::said(&refused));
    assert_eq!(read(&world.at(".kendex-lock.json")), older);
    assert!(!world.at(".kendex-lock.v10.json").exists());
}

/// A package the version 10 record already carried is no package the
/// recovery installs: its repository effect is neither disclosed nor run
/// again, even under `--allow-repo-effects`.
#[test]
fn a_version_10_recovery_runs_no_installer_for_a_carried_package() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    super::guarding::offer(&world, "commit-guards");
    world.run(&["add", "cat", "--skill", "commit-guards", "-y"]);
    world.commit_all("version 10 install");
    plant_version_10_state(&world);

    let applied = world.try_run(&["apply", "--yes", "--allow-repo-effects"]);
    let said = super::said(&applied);
    assert!(applied.status.success(), "{said}");
    assert!(world.at(".kendex-lock.v10.json").is_file(), "{said}");
    assert!(!world.at(".git/hooks/kendex-guards").exists(), "{said}");
    assert!(
        !said.contains("changes how this repository works"),
        "{said}"
    );
}

/// The check names a version 10 record's fix, the refresh, as drift with a
/// remedy rather than a scope it could not check, and still hands fleet its
/// keyed refusal. Every other verb that reads the record keeps refusing.
#[test]
#[allow(clippy::unwrap_used)]
fn the_check_names_a_refresh_for_a_version_10_record() {
    let world = World::new(&["claude"]);
    world.declare_catalog();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    plant_version_10_state(&world);

    let checked = world.try_run(&["check"]);
    assert_eq!(checked.status.code(), Some(1), "{}", super::said(&checked));
    assert_eq!(refused_version_10_lines(&checked), 1);
    let json = world.try_run(&["check", "--json"]);
    let report: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let verbs: Vec<&serde_json::Value> = report["sections"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|section| section["lines"].as_array().into_iter().flatten())
        .map(|line| &line["remedy"]["verb"])
        .collect();
    assert!(verbs.iter().any(|verb| *verb == "refresh"), "{verbs:?}");

    let removed = world.try_run(&["remove", "deploy"]);
    assert!(!removed.status.success());
    assert_eq!(refused_version_10_lines(&removed), 1);
}

/// A committed project holding the skill `deploy` and the declared Pi
/// package `pi-widgets` at version 1, both installed and recorded.
fn pi_widgets_installed() -> World {
    let world = World::new(&["claude"]);
    super::git(&world.project, &["config", "user.email", "t@t"]);
    super::git(&world.project, &["config", "user.name", "t"]);
    world.declare_catalog();
    write_pi_widgets(&world, "1.0.0");
    std::fs::create_dir_all(world.at(".pi")).ok();
    world.run(&["add", "cat", "--skill", "deploy", "-y"]);
    super::write(
        &world.at("kendex.toml"),
        &format!(
            "{}\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
            read(&world.at("kendex.toml"))
        ),
    );
    world.run(&["refresh", "--yes", "--leave"]);
    world.commit_all("version 10 install");
    world
}

/// The catalog's `pi-widgets` package at `version`.
fn write_pi_widgets(world: &World, version: &str) {
    let package = world.catalog.join("pi-extensions/pi-widgets");
    super::write(
        &package.join("package.json"),
        &format!(
            "{{\n  \"name\": \"pi-widgets\",\n  \"version\": \"{version}\",\n  \"pi\": {{ \"extensions\": [\"index.js\"] }}\n}}\n"
        ),
    );
    super::write(
        &package.join("index.js"),
        &format!("export const version = \"{version}\";\n"),
    );
}

/// A recovering refresh writes twice in one scope: the recovery, then the
/// Pi settlement the recovered record lets it read, which records the
/// package the recovery could not. The run's one commit offer comes after
/// the last of them, so a commit chosen up front carries everything the
/// run changed and leaves the tree clean.
#[test]
#[allow(clippy::unwrap_used)]
fn a_version_10_recovery_commits_once_after_its_pi_settlement() {
    let world = pi_widgets_installed();
    super::write(
        &world.catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the updated deploy.\n",
    );
    plant_version_10_state(&world);
    world.commit_all("the record a version 10 build left");
    let commits = super::git(&world.project, &["rev-list", "--count", "HEAD"]);

    let refreshed = world.try_run(&["refresh", "--yes", "--commit"]);
    let said = super::said(&refreshed);
    assert!(refreshed.status.success(), "{said}");
    let recovered = kendex_core::lock::load(&world.at(".kendex-lock.json")).unwrap();
    assert!(
        recovered.entries.contains_key("pi-extension:pi-widgets:pi"),
        "the settlement ran after the recovery: {said}"
    );
    assert_eq!(
        super::git(&world.project, &["status", "--porcelain"]),
        "",
        "{said}"
    );
    let after: u32 = super::git(&world.project, &["rev-list", "--count", "HEAD"])
        .parse()
        .unwrap_or_default();
    let before: u32 = commits.parse().unwrap_or_default();
    assert_eq!(after, before + 1, "{said}");
}

/// A version 10 build installed `pi-widgets`, and its source moved on
/// since. The recovered record has no entry for the package, so the old
/// record's byte proof decides: a copy that is still exactly what that
/// record says kendex installed is settled by the same refresh, under its
/// consent, and check is clean after it; a copy edited by hand is not
/// proved, so the refresh leaves its bytes as they are and fails on it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_version_10_recovery_settles_a_proved_pi_copy_whose_source_moved() {
    let edited = "export const version = \"mine\";\n";
    for (case, edit, settles) in [
        ("unedited", None, true),
        ("hand-edited", Some(edited), false),
    ] {
        let world = pi_widgets_installed();
        let installed = world.at(".pi/packages/pi-widgets/index.js");
        if let Some(edit) = edit {
            super::write(&installed, edit);
        }
        write_pi_widgets(&world, "2.0.0");
        plant_version_10_state(&world);
        world.commit_all("the record a version 10 build left");

        let refreshed = world.try_run(&["refresh", "--yes"]);
        let said = super::said(&refreshed);
        assert_eq!(refreshed.status.success(), settles, "{case}: {said}");
        let recovered = kendex_core::lock::load(&world.at(".kendex-lock.json"))
            .unwrap_or_else(|error| panic!("{case}: the record recovers either way: {error}"));
        assert_eq!(
            recovered.entries.contains_key("pi-extension:pi-widgets:pi"),
            settles,
            "{case}: {said}"
        );
        let expected = match edit {
            Some(edit) => edit.to_owned(),
            None => read(&world.catalog.join("pi-extensions/pi-widgets/index.js")),
        };
        assert_eq!(read(&installed), expected, "{case}: {said}");
        let checked = world.try_run(&["check"]);
        assert_eq!(
            checked.status.code(),
            Some(if settles { 0 } else { 1 }),
            "{case}: {}",
            super::said(&checked)
        );
    }
}
