//! Edit protection across the enable/disable boundary.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_made_while_disabled_survives_being_re_enabled() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    // Agents render to a File artifact with a `.disabled` sibling — the
    // path that would otherwise be missed.
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: reviewer\n---\nReview carefully.\n",
    )
    .unwrap();
    commit(&w.upstream, "agent");
    declare(&w, "[agents.rev]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // Turn it off, then edit the disabled file, then turn it back on.
    let toggled = manifest::manifest_path(&w.env, &w.scope);
    fs::write(
        &toggled,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\nenabled = false\n"
        ),
    )
    .unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    let disabled = w.home.join("app/.claude/agents/rev.md.disabled");
    assert!(disabled.is_file(), "disabled agent keeps its bytes");
    fs::write(&disabled, "my edited disabled agent").unwrap();

    fs::write(
        &toggled,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "rev").unwrap();
    assert_eq!(
        row.cause,
        Some(DriftCause::LocalEdit),
        "an edit made while off is still an edit: {row:?}"
    );
    apply::execute(&w.env, &report.plan).unwrap();
    let enabled = w.home.join("app/.claude/agents/rev.md");
    let content = fs::read_to_string(&enabled)
        .or_else(|_| fs::read_to_string(&disabled))
        .unwrap();
    assert_eq!(content, "my edited disabled agent");
}

/// The re-enable toggle binds to the disabled file as it was when the
/// plan was made. An edit landing after planning refuses the move: run
/// anyway, the rename would put the edit at the enabled name for the
/// install op behind it — planned against the unedited bytes — to
/// overwrite.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_landing_after_the_enable_was_planned_refuses_the_toggle() {
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
    let manifest_with = |item: &str| {
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{item}"
        )
    };
    fs::write(&path, manifest_with("[agents.rev]\nsource = \"cat\"\n")).unwrap();
    sync_and_apply(&w);

    fs::write(
        &path,
        manifest_with("[agents.rev]\nsource = \"cat\"\nenabled = false\n"),
    )
    .unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    let disabled = w.home.join("app/.claude/agents/rev.md.disabled");
    assert!(disabled.is_file());

    fs::write(&path, manifest_with("[agents.rev]\nsource = \"cat\"\n")).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| op.line().contains("Turn rev on")),
        "{:?}",
        report.plan.ops
    );
    fs::write(&disabled, "edited after planning").unwrap();

    let error = apply::execute(&w.env, &report.plan).unwrap_err();
    assert!(
        matches!(&error, CoreError::RolledBack { cause, .. }
            if matches!(**cause, CoreError::PlanStale { .. })),
        "{error:?}"
    );
    assert_eq!(
        fs::read_to_string(&disabled).unwrap(),
        "edited after planning"
    );
    assert!(!w.home.join("app/.claude/agents/rev.md").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn upstream_changing_while_disabled_is_not_a_false_edit() {
    let w = world();
    let dir = w.upstream.join("agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: reviewer\n---\nReview v1.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    // Declared disabled from the start.
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\nenabled = false\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    assert!(w.home.join("app/.claude/agents/rev.md.disabled").is_file());

    // Upstream moves; the item stays disabled and untouched on disk.
    fs::write(
        dir.join("rev.md"),
        "---\nname: rev\ndescription: reviewer\n---\nReview v2.\n",
    )
    .unwrap();
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "rev");
    assert!(
        row.is_none_or(
            |row| row.cause != Some(DriftCause::LocalEdit) && row.cause != Some(DriftCause::Both)
        ),
        "a disabled item nobody touched must not read as edited: {row:?}"
    );
}

/// A disabled skill renders its SKILL.md under the `.disabled` name; an
/// edit made to it forks in source form, so the local source is a skill
/// discovery can read and the declaration's `enabled` keeps it off.
#[test]
#[allow(clippy::unwrap_used)]
fn a_disabled_skills_edit_forks_in_source_form() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\nenabled = false\n");
    sync_and_apply(&w);
    let disabled = w.home.join("app/.agents/skills/gh/SKILL.md.disabled");
    assert!(disabled.is_file(), "disabled skill keeps its bytes");
    fs::write(
        &disabled,
        "---\nname: gh\ndescription: mine\n---\nMy edit.\n",
    )
    .unwrap();

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(row.forkable_harness, Some(HarnessId::Claude));

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let local = w.home.join("app/.kendex-local/skills/gh");
    assert!(
        local.join("SKILL.md").is_file(),
        "the fork is in source form"
    );
    assert!(!local.join("SKILL.md.disabled").exists());
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
    assert!(
        fs::read_to_string(&disabled).unwrap().contains("My edit."),
        "the fork renders disabled, with the edit"
    );
}

/// A world with `rev` declared off and its `.disabled` rendering edited —
/// the shape whose fork destination carries the `.disabled` name too.
#[allow(clippy::unwrap_used)]
fn disabled_edited_agent_world() -> World {
    let w = world();
    write_agent(&w.upstream, "rev", "Agent body.");
    commit(&w.upstream, "one");
    declare(&w, "[agents.rev]\nsource = \"cat\"\nenabled = false\n");
    sync_and_apply(&w);
    let rendered = w.home.join("app/.claude/agents/rev.md.disabled");
    assert!(rendered.is_file(), "a disabled agent keeps its bytes");
    fs::write(
        &rendered,
        "---\nname: rev\ndescription: mine\n---\nMy agent.\n",
    )
    .unwrap();
    w
}

fn beside_rev_edited(w: &World) -> Result<apply::Plan, CoreError> {
    fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-edited",
        None,
    )
}

/// A disabled declaration renders its agent under the `.disabled` name, so
/// that is the destination the install-beside preflight has to prove
/// vacant: an unmanaged file there would make the render pass refuse after
/// the fork was already recorded.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_refuses_an_occupant_of_a_disabled_agents_destination() {
    let w = disabled_edited_agent_world();
    let occupied = w.home.join("app/.claude/agents/rev-edited.md.disabled");
    fs::write(&occupied, "not kendex's").unwrap();
    let before = manifest_text(&w);

    let refused = beside_rev_edited(&w).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert_eq!(manifest_text(&w), before);
    assert_eq!(fs::read_to_string(&occupied).unwrap(), "not kendex's");
    assert!(
        !w.home
            .join("app/.kendex-local/agents/rev-edited.md")
            .exists()
    );
    assert!(
        fs::read_to_string(w.home.join("app/.claude/agents/rev.md.disabled"))
            .unwrap()
            .contains("My agent."),
        "the edited copy is untouched"
    );
}

/// The enabled name is not where a disabled declaration renders, so a
/// stranger sitting there is no reason to refuse the fork.
#[test]
#[allow(clippy::unwrap_used)]
fn fork_beside_ignores_the_enabled_path_for_a_disabled_agent() {
    let w = disabled_edited_agent_world();
    let stray = w.home.join("app/.claude/agents/rev-edited.md");
    fs::write(&stray, "not in the way").unwrap();

    let plan = beside_rev_edited(&w).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let own = fs::read_to_string(w.home.join("app/.kendex-local/agents/rev-edited.md")).unwrap();
    assert!(
        own.contains("name: rev-edited") && own.contains("My agent."),
        "{own}"
    );
    assert!(manifest_text(&w).contains("[forks.agent.rev-edited]"));
    assert_eq!(fs::read_to_string(&stray).unwrap(), "not in the way");
}

/// A tree carrying both `SKILL.md` and `SKILL.md.disabled` has two claims
/// on one source file: the row offers no fork, and `fork` refuses without
/// touching anything.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tree_with_both_skill_files_is_not_forkable() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    let tree = w.home.join("app/.agents/skills/gh");
    fs::write(
        tree.join("SKILL.md"),
        "---\nname: gh\ndescription: mine\n---\nMy edit.\n",
    )
    .unwrap();
    fs::write(tree.join("SKILL.md.disabled"), "stray disabled copy").unwrap();

    let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
        .unwrap();
    assert!(row.blocked_by_local_edit);
    assert_eq!(row.forkable_harness, None, "{row:?}");

    let refused = fork::fork(&w.env, &w.scope, ItemKind::Skill, "gh", HarnessId::Claude);
    assert!(
        matches!(refused, Err(CoreError::ForkAmbiguous { .. })),
        "{refused:?}"
    );
    assert!(
        fs::read_to_string(tree.join("SKILL.md"))
            .unwrap()
            .contains("My edit.")
    );
    assert_eq!(
        fs::read_to_string(tree.join("SKILL.md.disabled")).unwrap(),
        "stray disabled copy"
    );
    assert!(!w.home.join("app/.kendex-local/skills/gh").exists());
}
