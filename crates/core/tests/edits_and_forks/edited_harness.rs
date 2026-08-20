//! Which rendering an edit lives in: a fork captures one tool's bytes, so
//! the update row has to name the tool whose copy was changed.

use std::fs;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_agent_names_the_rendering_that_was_edited() {
    let w = world();
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nAgent body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    fs::create_dir_all(w.home.join("app/.opencode")).unwrap();
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let claude = w.home.join("app/.claude/agents/rev.md");
    let opencode = w.home.join("app/.opencode/agents/rev.md");
    assert!(claude.is_file() && opencode.is_file());

    fs::write(&opencode, "my opencode edit").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(
        row.edited_harnesses,
        vec![HarnessId::Opencode],
        "the fork must capture the rendering that was edited, not the first one"
    );
    assert_eq!(
        row.forkable_harness, None,
        "an opencode agent cannot be read back as source, so nothing is offered"
    );
    assert_eq!(
        row.repo_identity,
        kendex_core::repo_move::canonical(&row.repo)
    );

    // Edit Claude's copy too: that one round-trips, so it is the fork.
    fs::write(&claude, "my claude edit").unwrap();
    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
        .unwrap();
    assert_eq!(row.forkable_harness, Some(HarnessId::Claude));
}

/// "Use new version" on a held, edited place: the hold moves to the new
/// commit and the edits go in the same apply — two steps would restore
/// the old held copy first and leave the update pending.
#[test]
#[allow(clippy::unwrap_used)]
fn discarding_edits_can_move_a_hold_in_the_same_apply() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    // Run from a commit hook, GIT_DIR and friends point at the repository
    // being committed to; dropped, so HEAD is the fixture's.
    let one = String::from_utf8(
        std::process::Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(&w.upstream)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .env_remove("GIT_OBJECT_DIRECTORY")
            .env_remove("GIT_PREFIX")
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{}\"\n", one.trim()),
    );
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    fs::write(skill_file(&w), "my edited version").unwrap();
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = kendex_core::package::set_rev_with(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        Some("main"),
        &PlanOptions {
            overwrite_edited_names: Some(vec![(ItemKind::Skill, "gh".to_owned())]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(fs::read_to_string(skill_file(&w)).unwrap().contains("Two."));
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}
