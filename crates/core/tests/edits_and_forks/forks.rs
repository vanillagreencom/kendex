//! The fork operation over the shared edits-and-forks harness.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn fork_keeps_the_name_pauses_updates_and_survives_refresh() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    // The fork's bytes live in the local source and render under the name.
    assert!(
        fs::read_to_string(w.home.join("app/.kendex-local/skills/gh/SKILL.md"))
            .unwrap()
            .contains("My fork.")
    );
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("My fork.")
    );
    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(text.contains("[forks.skill.gh]"), "{text}");
    assert!(text.contains("source = \"local\""));

    // Upstream keeps moving; the fork does not.
    write_skill(&w.upstream, "gh", "Upstream v2.");
    commit(&w.upstream, "two");
    sync_and_apply(&w);
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("My fork.")
    );
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());

    // The updates projection knows it is a fork now, not an update.
    let rows = kendex_core::package::updates::updates(&w.env, &w.scope)
        .unwrap()
        .rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(gh.forked);
    assert!(
        !gh.update_available,
        "a local fork has no remote versions to offer: {gh:?}"
    );
}

/// The edited install being deleted between the plan and the apply aborts
/// it. The capture reads those bytes at plan time and binds its own
/// precondition to where they are going, so the trash op over the edited
/// tree is the only thing holding the plan to the artifact it read. A
/// trash op that answers "already gone, so we are done" belongs to a
/// removal and nowhere else: here it would leave a fork made of bytes the
/// disk does not have.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_install_deleted_after_planning_fails_the_fork() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    fs::remove_dir_all(w.home.join("app/.agents/skills/gh")).unwrap();

    assert!(apply::execute(&w.env, &plan).is_err());
    assert!(
        !w.home.join("app/.kendex-local/skills/gh").exists(),
        "no fork made of bytes the disk no longer has"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn rename_fork_moves_the_declaration_and_refuses_depended_on_names() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(text.contains("[skills.my-gh]"), "{text}");
    assert!(text.contains("[forks.skill.my-gh]"));
    assert!(!text.contains("[skills.gh]"));
    let source = w.home.join("app/.kendex-local/skills/my-gh/SKILL.md");
    assert!(source.is_file());

    // The rename is not done when the files have moved: every tool knows
    // a skill by the name its SKILL.md gives, so a fork still calling
    // itself `gh` installs as a name nobody declared and the loader
    // validators refuse the rendering outright.
    let moved = fs::read_to_string(&source).unwrap();
    assert!(moved.contains("name: my-gh"), "{moved}");
    assert!(
        moved.contains("Mine."),
        "the rename took the fork's own text"
    );

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        !report
            .drift
            .iter()
            .any(|row| row.name == "my-gh" && row.state == DriftState::Conflict),
        "the renamed fork is refused at the next apply: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();
    let installed = fs::read_to_string(w.home.join("app/.agents/skills/my-gh/SKILL.md")).unwrap();
    assert!(installed.contains("name: my-gh"), "{installed}");
}

/// The same for an agent, whose source is one file rather than a tree:
/// Claude and Gemini register an agent under its frontmatter name and
/// their validators refuse a file calling itself something other than the
/// name it installs under, exactly as a skill's does.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_an_agent_fork_leaves_it_answering_to_its_new_name() {
    let w = world();
    write_agent(&w.upstream, "rev", "Review.");
    commit(&w.upstream, "one");
    declare(&w, "[agents.rev]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let rendered = w.home.join("app/.claude/agents/rev.md");
    fs::write(
        &rendered,
        "---\nname: rev\ndescription: mine\n---\nMy review.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "my-rev").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let source = fs::read_to_string(w.home.join("app/.kendex-local/agents/my-rev.md")).unwrap();
    assert!(source.contains("name: my-rev"), "{source}");
    assert!(source.contains("My review."), "{source}");

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        !report
            .drift
            .iter()
            .any(|row| row.name == "my-rev" && row.state == DriftState::Conflict),
        "the renamed agent fork is refused at the next apply: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();
    let installed = fs::read_to_string(w.home.join("app/.claude/agents/my-rev.md")).unwrap();
    assert!(installed.contains("name: my-rev"), "{installed}");
}

/// A fork whose own file cannot carry a name refuses the rename instead of
/// half-doing it: renaming around the problem is exactly how a fork ends
/// up declared under one name and answering to another.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_whose_file_cannot_carry_the_name_refuses_the_rename() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();

    let source = w.home.join("app/.kendex-local/skills/gh/SKILL.md");
    fs::write(&source, "---\nname: gh\nname: gh\n---\nMine.\n").unwrap();
    let refused = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(
        !w.home.join("app/.kendex-local/skills/my-gh").exists(),
        "a refused rename must write nothing"
    );
    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(text.contains("[skills.gh]"), "{text}");
}

/// A fork whose slot is reached through a link is not a fork the rename
/// can move: `fs::rename` carries the link rather than the tree, and every
/// op the plan binds past it — the name-stamping write first of all —
/// then acts on the far end, outside the scope. Refused before a single
/// op is planned, and the tree at the far end is untouched.
/// Built on the world whose home is itself reached through a link, the
/// spelling macOS hands every test: the refusal names the component the
/// sealed reader stopped at, which it probes from the canonicalized root,
/// so an assertion written in the caller's spelling would pass on Linux
/// and fail on the macOS lane alone.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_reached_through_a_link_refuses_the_rename() {
    let w = world_via_link();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();

    // The fork's slot becomes a link to a tree outside the scope.
    let outside = w.home.join("outside/gh");
    fs::create_dir_all(&outside).unwrap();
    let theirs = "---\nname: gh\ndescription: theirs\n---\nTheirs.\n";
    fs::write(outside.join("SKILL.md"), theirs).unwrap();
    let slot = w.home.join("app/.kendex-local/skills/gh");
    fs::remove_dir_all(&slot).unwrap();
    std::os::unix::fs::symlink(&outside, &slot).unwrap();
    let before = manifest_text(&w);

    let refused = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap_err();
    // The reader probes from the canonicalized local-source root, so that
    // is the spelling the refusal names. The root is a real directory; the
    // slot below it is the link, and canonicalizing that would follow it.
    let named = kendex_core::paths::canonical(&w.home.join("app/.kendex-local"))
        .unwrap()
        .join("skills/gh");
    assert!(
        matches!(&refused, CoreError::SourceEscape { path, reason }
            if path == &named && reason.contains("symlink")),
        "the refusal must name the link it stopped at: {refused:?}"
    );
    assert_eq!(
        fs::read_to_string(outside.join("SKILL.md")).unwrap(),
        theirs,
        "the rename wrote through the link, at the far end of it"
    );
    assert!(slot.is_symlink(), "the link itself was moved");
    assert!(!w.home.join("app/.kendex-local/skills/my-gh").exists());
    assert_eq!(manifest_text(&w), before);
}

/// The rename plan binds to the fork's files as they were when it was
/// made. An edit landing on them after planning refuses the move — run
/// anyway, the rename would carry the edit to the target name, where a
/// refusal's rollback could restore the old snapshot over it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_edited_after_the_rename_was_planned_refuses_the_move() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap();
    let source = w.home.join("app/.kendex-local/skills/gh/SKILL.md");
    fs::write(&source, "edited after planning").unwrap();

    let error = apply::execute(&w.env, &plan).unwrap_err();
    assert!(
        matches!(&error, CoreError::RolledBack { cause, .. }
            if matches!(**cause, CoreError::PlanStale { .. })),
        "{error:?}"
    );
    assert_eq!(
        fs::read_to_string(&source).unwrap(),
        "edited after planning"
    );
    assert!(!w.home.join("app/.kendex-local/skills/my-gh").exists());
}

/// A dangling link inside a fork is the person's to keep: the rename
/// carries the fork's files whole, link included, instead of refusing
/// the fork because one entry has no bytes to hash.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_holding_a_dangling_link_still_renames() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let source = w.home.join("app/.kendex-local/skills/gh");
    std::os::unix::fs::symlink("nowhere", source.join("notes")).unwrap();

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let moved = w.home.join("app/.kendex-local/skills/my-gh/notes");
    assert!(moved.is_symlink(), "{moved:?}");
    assert!(!source.exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_codex_agent_is_refused_with_the_fix_named() {
    let w = world();
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: reviewer\n---\nReview.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    // Codex renders agents as TOML, which cannot round-trip as source.
    let error =
        kendex_core::engine::fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Codex)
            .unwrap_err();
    assert!(
        error.to_string().contains("Claude"),
        "the refusal names the fix: {error}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_skill_with_a_symlink_inside_refuses_rather_than_dropping_it() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // A link planted inside the tree is refused, not silently dropped.
    let canonical = w.home.join("app/.agents/skills/gh");
    std::os::unix::fs::symlink("/etc/hostname", canonical.join("link")).unwrap();
    fs::write(
        canonical.join("SKILL.md"),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let error =
        kendex_core::engine::fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude)
            .unwrap_err();
    assert!(
        matches!(error, kendex_core::error::CoreError::ForeignSymlink { .. }),
        "a symlink in the tree is refused, never silently dropped: {error}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_skill_whose_native_link_was_repointed_reads_the_managed_tree() {
    let w = world();
    write_skill(&w.upstream, "gh", "Real content.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // Repoint the native link at a foreign directory. fork must resolve to
    // the managed canonical tree, never read or trash the foreign target.
    let native = w.home.join("app/.claude/skills/gh");
    let foreign = w.home.join("foreign");
    fs::create_dir_all(&foreign).unwrap();
    fs::write(foreign.join("secret.md"), "not part of the package").unwrap();
    let canonical = w.home.join("app/.agents/skills/gh");
    fs::write(
        canonical.join("SKILL.md"),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    fs::remove_file(&native).unwrap();
    std::os::unix::fs::symlink(&foreign, &native).unwrap();

    let plan =
        kendex_core::engine::fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude)
            .unwrap();
    // The captured content is the canonical tree, and nothing trashes the
    // foreign directory.
    let descriptions: Vec<String> = plan.ops.iter().map(|op| op.line()).collect();
    let debug = format!("{:?}", plan.ops);
    assert!(
        !debug.contains("foreign"),
        "the foreign target must never be captured or trashed: {debug}"
    );
    assert!(
        descriptions.iter().any(|d| d.contains("fork")),
        "{descriptions:?}"
    );
    assert!(foreign.join("secret.md").is_file());
}

/// Content that is already the user's own has nothing to fork: a local
/// fork forked again, and a skill declared in place — where a fork would
/// turn the tree of record into a render of a hidden copy.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_the_users_own_content_is_refused() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let err = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(&err, CoreError::AlreadyOwn { name, origin } if name == "gh" && origin == "local"),
        "{err}"
    );

    let here = w.home.join("app/.agents/skills/here");
    fs::create_dir_all(&here).unwrap();
    fs::write(
        here.join("SKILL.md"),
        "---\nname: here\ndescription: mine\n---\nHere.\n",
    )
    .unwrap();
    declare(&w, "[skills.here]\nsource = \"in-place\"\n");
    let before = manifest_text(&w);
    let err = fork::fork(&w.env, &w.scope, ItemKind::Skill, "here", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(&err, CoreError::AlreadyOwn { name, origin } if name == "here" && origin == "in-place"),
        "{err}"
    );
    assert_eq!(manifest_text(&w), before);
    assert!(!w.home.join("app/.kendex-local/skills/here").exists());
}

/// A fork in place captures under the name the item already has, so it
/// never passes the vacancy check that asks a proposed name whether its slot is
/// reachable. `Pre::Absent` refuses a link wearing the item's own name, but
/// a link one component above — the `skills` directory of the local source
/// — leaves the slot absent past it, and the captured tree would land at
/// the far end, outside anything kendex manages. Refused before an op is
/// planned, with nothing written through the link.
/// Built on the world whose home is itself reached through a link, the
/// spelling macOS hands every test: the sealed reader probes from the
/// canonicalized root, so an assertion in the caller's spelling would pass
/// on Linux and fail on the macOS lane alone.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_local_source_reached_through_a_link_refuses_the_fork() {
    let w = world_via_link();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();

    // The component above the slot — not the slot itself — is the link.
    let outside = w.home.join("outside");
    fs::create_dir_all(&outside).unwrap();
    fs::create_dir_all(w.home.join("app/.kendex-local")).unwrap();
    let skills = w.home.join("app/.kendex-local/skills");
    std::os::unix::fs::symlink(&outside, &skills).unwrap();
    let before = manifest_text(&w);

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap_err();
    // The reader probes from the canonicalized local-source root, so that
    // is the spelling the refusal names. The root is a real directory; the
    // component below it is the link, and canonicalizing that would follow
    // it.
    let named = kendex_core::paths::canonical(&w.home.join("app/.kendex-local"))
        .unwrap()
        .join("skills");
    assert!(
        matches!(&refused, CoreError::SourceEscape { path, reason }
            if path == &named && reason.contains("symlink")),
        "the refusal must name the link it stopped at: {refused:?}"
    );
    assert!(
        !outside.join("gh").exists(),
        "the capture wrote through the link, at the far end of it"
    );
    assert!(skills.is_symlink(), "the link itself was replaced");
    assert_eq!(manifest_text(&w), before);
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("Mine."),
        "a refused fork must leave the edited install alone"
    );
}

/// A world with `gh` forked, applied, and then edited in place. Returned
/// with the bytes the person left in the install.
#[allow(clippy::unwrap_used)]
fn edited_fork() -> (World, &'static str) {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    fs::write(
        skill_file(&w),
        "---\nname: gh\ndescription: mine\n---\nMy fork.\n",
    )
    .unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let edited = "---\nname: gh\ndescription: mine\n---\nMy fork, edited.\n";
    fs::write(skill_file(&w), edited).unwrap();
    (w, edited)
}

/// The fork's own source file, which is what its installations render from.
fn fork_source(w: &World) -> PathBuf {
    w.home.join("app/.kendex-local/skills/gh/SKILL.md")
}

/// A fork is already the person's own copy, so editing one settles nothing
/// and decides nothing: the edit becomes the fork's content, and `apply`
/// and the check the Library reads both come back clean and keep saying so.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_to_a_fork_becomes_its_content_and_leaves_apply_and_check_agreeing() {
    let (w, edited) = edited_fork();

    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.drift, Vec::new(), "an edited fork is nothing to fix");
    assert_eq!(
        report
            .fork_edits
            .iter()
            .map(|edit| (edit.kind, edit.name.as_str()))
            .collect::<Vec<_>>(),
        vec![(ItemKind::Skill, "gh")],
    );
    // Until it is taken in, the page says so — a state, with nothing
    // withheld and nothing to answer.
    let gh = fork_row(&w);
    assert!(gh.forked && gh.fork_edited, "{gh:?}");
    assert!(!gh.blocked_by_local_edit && !gh.update_available, "{gh:?}");

    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(skill_file(&w)).unwrap(), edited);
    assert_eq!(
        fs::read_to_string(fork_source(&w)).unwrap(),
        edited,
        "the fork renders from what the person wrote"
    );

    // And it stays settled: the pass after has nothing to plan, nothing to
    // report, and nothing left pending to say on the page.
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.drift, Vec::new());
    assert!(report.fork_edits.is_empty());
    // Nothing to write but the record of the source the absorb wrote. The
    // rendering is what it was, so there is no second render and no second
    // decision — only the hash of a source that moved catching up.
    assert_eq!(
        report
            .plan
            .ops
            .iter()
            .map(|op| op.line())
            .collect::<Vec<_>>(),
        vec!["Update the install record".to_owned()],
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(skill_file(&w)).unwrap(), edited);
    let gh = fork_row(&w);
    assert!(gh.forked && !gh.fork_edited, "{gh:?}");
}

/// What the Updates read says about `gh`.
#[allow(clippy::unwrap_used)]
fn fork_row(w: &World) -> kendex_core::package::updates::UpdateRow {
    kendex_core::package::updates::updates(&w.env, &w.scope)
        .unwrap()
        .rows
        .into_iter()
        .find(|row| row.name == "gh")
        .unwrap()
}

/// The absorbed edit is the fork's content everywhere after, not bytes the
/// record merely tolerates where they stand: a second tool renders it, and
/// a rendering taken off disk is put back as it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_absorbed_fork_edit_is_what_every_later_render_writes() {
    let (w, edited) = edited_fork();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    // Another tool ticked on renders the same package again.
    let path = manifest::manifest_path(&w.env, &w.scope);
    let text = fs::read_to_string(&path).unwrap().replace(
        "harnesses = [\"claude\"]",
        "harnesses = [\"claude\", \"codex\"]",
    );
    fs::write(&path, text).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(skill_file(&w)).unwrap(),
        edited,
        "a second tool renders the fork's content, never the copy it replaced"
    );

    // A rendering taken off disk is written again from the same content.
    fs::remove_dir_all(w.home.join("app/.agents/skills/gh")).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(skill_file(&w)).unwrap(), edited);
}

/// The absorb is for the edit alone. A fork whose source moved too is two
/// changes to one item, which stays the conflict it was — before an edit
/// has been taken in and after.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_edited_on_both_sides_still_conflicts() {
    let (w, _) = edited_fork();
    let both_ways = |w: &World, install: &str, source: &str| {
        fs::write(skill_file(w), install).unwrap();
        fs::write(fork_source(w), source).unwrap();
        let report = audit(&w.env, &w.scope).unwrap();
        let row = report
            .drift
            .iter()
            .find(|row| row.name == "gh")
            .unwrap_or_else(|| panic!("no row: {:?}", report.drift));
        assert_eq!(row.state, DriftState::Conflict);
        assert!(report.fork_edits.is_empty(), "{:?}", report.fork_edits);
        apply::execute(&w.env, &report.plan).unwrap();
        assert_eq!(fs::read_to_string(skill_file(w)).unwrap(), install);
    };

    both_ways(
        &w,
        "---\nname: gh\ndescription: mine\n---\nInstall one.\n",
        "---\nname: gh\ndescription: mine\n---\nSource one.\n",
    );

    // And again through a record an absorb has already settled, which is
    // the ordering the first half cannot reach: a fresh fork, its pending
    // edit taken in, and only then both sides moved. Settling the pair
    // above would not do — the two stay divergent, so the apply between
    // them absorbs nothing.
    let (w, _) = edited_fork();
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.fork_edits.len(), 1, "the absorb this half needs");
    apply::execute(&w.env, &report.plan).unwrap();
    both_ways(
        &w,
        "---\nname: gh\ndescription: mine\n---\nInstall two.\n",
        "---\nname: gh\ndescription: mine\n---\nSource two.\n",
    );
}

/// A sweep takes an absorbed fork's rendering, because a rendering is all
/// it is by then: the content it was made from is in the fork's source,
/// where the next declaration renders it from again.
#[test]
#[allow(clippy::unwrap_used)]
fn a_sweep_of_an_absorbed_fork_leaves_its_content_in_the_source() {
    let (w, edited) = edited_fork();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let path = manifest::manifest_path(&w.env, &w.scope);
    let text = fs::read_to_string(&path)
        .unwrap()
        .replace("[skills.gh]\nsource = \"local\"\n", "");
    fs::write(&path, text).unwrap();
    let report = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(!skill_file(&w).exists());
    assert_eq!(fs::read_to_string(fork_source(&w)).unwrap(), edited);
}

/// One fork rendering per tool, each edited its own way: the absorb speaks
/// only for the rendering whose bytes it took into the source, and the
/// other is held as the edit it is. Nothing is written over either way —
/// recording bytes the source did not take is what would let the next
/// render take them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_edited_differently_in_two_tools_keeps_both_renderings() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let claude = rendered(&w, HarnessId::Claude, "rev");
    let gemini = rendered(&w, HarnessId::Gemini, "rev");
    edit_body(&claude);
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    edit_line(&claude, "My body.", "What Claude's copy says.");
    edit_line(&gemini, "My body.", "What Gemini's copy says.");
    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.cause == Some(DriftCause::LocalEdit)),
        "the rendering the source did not take is still an edit to settle: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        fs::read_to_string(&claude)
            .unwrap()
            .contains("What Claude's copy says."),
    );
    assert!(
        fs::read_to_string(&gemini)
            .unwrap()
            .contains("What Gemini's copy says."),
    );
}

/// A rendering the source parser cannot read back is never taken into the
/// source. Absorbing a codex agent's own format would write it into the
/// local source as the agent's prose, so that rendering keeps the edit
/// hold and the source is left exactly as it was.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_to_a_fork_rendering_the_source_cannot_hold_is_not_absorbed() {
    let w = agent_world(
        "\"claude\", \"codex\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let claude = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&claude);
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let dir = native_dir(&w.env, &w.scope, HarnessId::Codex, ItemKind::Agent).unwrap();
    let codex = fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("rev."))
        })
        .unwrap_or_else(|| panic!("no codex rendering in {dir:?}"));
    let source_before = fs::read_to_string(captured(&w, "rev")).unwrap();
    edit_line(&codex, "My body.", "Edited in codex.");

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.cause == Some(DriftCause::LocalEdit)),
        "{:?}",
        report.drift
    );
    assert!(report.fork_edits.is_empty(), "{:?}", report.fork_edits);
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(captured(&w, "rev")).unwrap(),
        source_before
    );
    assert!(
        fs::read_to_string(&codex)
            .unwrap()
            .contains("Edited in codex.")
    );
}

/// A forked agent carrying the skills its first capture already wrote to
/// kendex.toml absorbs like any other. The carry is what the manifest
/// holds, not work the absorb still owes it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_forked_agent_whose_skills_are_already_recorded_absorbs() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let claude = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&claude);
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(manifest_of(&w).agent_skills.contains_key("rev"));

    edit_line(&claude, "My body.", "Edited again.");
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.drift, Vec::new(), "{:?}", report.drift);
    assert_eq!(report.fork_edits.len(), 1, "{:?}", report.fork_edits);
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        fs::read_to_string(captured(&w, "rev"))
            .unwrap()
            .contains("Edited again.")
    );
}

/// An edit the source form has nowhere to keep is not absorbed. A
/// rendered agent's `description:` has no override table to ride into, so
/// a capture would render back without it and the install and its source
/// would disagree for good. That rendering keeps the edit hold instead.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_the_source_form_cannot_hold_is_not_absorbed() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&file);
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source_before = fs::read_to_string(captured(&w, "rev")).unwrap();
    edit_line(
        &file,
        "description: \"agent rev\"",
        "description: \"my rev\"",
    );

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.cause == Some(DriftCause::LocalEdit)),
        "{:?}",
        report.drift
    );
    assert!(report.fork_edits.is_empty(), "{:?}", report.fork_edits);
    apply::execute(&w.env, &report.plan).unwrap();
    assert_eq!(
        fs::read_to_string(captured(&w, "rev")).unwrap(),
        source_before
    );
    assert!(
        fs::read_to_string(&file).unwrap().contains("my rev"),
        "and the edit is still the person's"
    );
}

/// A fork switched off keeps its bytes under the toggled name, and that is
/// the name an edit to it is read at. An agent renders to one file, so
/// when it is off the name the plan wants does not exist at all: absorbing
/// has to capture the bytes the hash actually came from, or a disabled
/// fork's edit is held forever with nothing able to settle it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_to_a_disabled_fork_is_absorbed_from_the_toggled_name() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&file);
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let path = manifest::manifest_path(&w.env, &w.scope);
    let text = fs::read_to_string(&path)
        .unwrap()
        .replace("[agents.rev]\n", "[agents.rev]\nenabled = false\n");
    fs::write(&path, text).unwrap();
    resettle(&w);

    let off = PathBuf::from(format!("{}.disabled", file.display()));
    assert!(off.is_file(), "the toggled name holds the bytes");
    assert!(!file.exists(), "and the wanted name holds none");
    edit_line(&off, "My body.", "Edited while off.");

    // Switched back on, the plan wants the plain name and nothing is
    // there yet: the edited bytes are still under the toggled one, which
    // is where the hash came from and where the capture has to read.
    let text = fs::read_to_string(&path)
        .unwrap()
        .replace("enabled = false\n", "");
    fs::write(&path, text).unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.fork_edits.len(), 1, "{:?}", report.fork_edits);
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        fs::read_to_string(captured(&w, "rev"))
            .unwrap()
            .contains("Edited while off."),
        "the source holds what was written while it was off"
    );
    // The absorb holds the item, so the switch back on is the next pass's
    // to make — from the source it just wrote.
    resettle(&w);
    assert!(
        fs::read_to_string(&file)
            .unwrap()
            .contains("Edited while off."),
        "and the rendering that comes back on is that same content"
    );
}
