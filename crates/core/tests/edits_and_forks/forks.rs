//! The fork operation over the shared edits-and-forks harness.

use std::fs;

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
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

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
    apply::execute(&w.env, &plan, None).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Skill, "gh", "my-gh").unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(text.contains("[skills.my-gh]"), "{text}");
    assert!(text.contains("[forks.skill.my-gh]"));
    assert!(!text.contains("[skills.gh]"));
    assert!(
        w.home
            .join("app/.kendex-local/skills/my-gh/SKILL.md")
            .is_file()
    );
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
            "schema = 5\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n\n[agents.rev]\nsource = \"cat\"\n"
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
    let descriptions: Vec<&str> = plan.ops.iter().map(|op| op.description.as_str()).collect();
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

/// Keeping a package as your own is two steps: the record and the render.
/// If the second never ran — interrupted, or a failure after the first
/// committed — the files are gone and `fork` refuses because the record is
/// already there. The way back has to exist, and the refusal has to name
/// it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_whose_render_never_ran_is_put_back_by_applying() {
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
    apply::execute(&w.env, &plan, None).unwrap();

    // The capture commits on its own: it records the fork and takes the
    // installed rendering away. Until the render step runs, this is what a
    // person is left with, and it is what an interruption leaves behind.
    assert!(
        !skill_file(&w).exists(),
        "the control: the capture leaves nothing rendered"
    );

    // Forking again refuses — the record is already there — and the
    // refusal names the exit that works.
    let refused = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude)
        .expect_err("a recorded fork refuses a second fork");
    let said = refused.to_string();
    assert!(
        said.contains("apply"),
        "the refusal names no way back: {said}"
    );

    // And that exit does put them back, from the copy that was kept.
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        skill_file(&w).exists(),
        "apply did not render the fork back"
    );
    assert!(
        fs::read_to_string(skill_file(&w))
            .unwrap()
            .contains("My fork."),
        "it rendered something other than the copy that was kept"
    );
}
