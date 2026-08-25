use super::*;
use crate::engine::audit;
use crate::env::FakeOs;

#[test]
fn adopting_a_handmade_skill_moves_merges_and_round_trips() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(
        project.join(".claude/skills/handmade/SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
    )
    .unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    // Content lives in the local source; the original is trashed.
    assert!(
        project
            .join(".kendex-local/skills/handmade/SKILL.md")
            .is_file()
    );
    assert!(!project.join(".claude/skills/handmade").exists());

    // Follow-up apply renders the managed replacement, drift-clean.
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
    let link = project.join(".claude/skills/handmade");
    assert!(link.is_symlink());
    let rendered = fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md")).unwrap();
    assert!(rendered.contains("My content."));
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// The local source already had a copy: it is trashed, never overwritten
/// in place, so nothing adoption replaces is gone for good.
#[test]
fn an_earlier_local_copy_goes_to_the_trash_not_under_the_new_one() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let earlier = project.join(".kendex-local/skills/handmade");
    fs::create_dir_all(&earlier).unwrap();
    fs::write(earlier.join("SKILL.md"), "earlier").unwrap();
    fs::write(earlier.join("notes.md"), "kept only here").unwrap();
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(project.join(".claude/skills/handmade/SKILL.md"), "observed").unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(earlier.join("SKILL.md")).unwrap(),
        "observed"
    );
    assert!(!earlier.join("notes.md").exists());
    let trashed: Vec<_> = fs::read_dir(env.trash_dir()).unwrap().flatten().collect();
    assert!(trashed.iter().any(|e| e.path().join("notes.md").is_file()));
}

/// The [install] defaults name more tools than the one the item was
/// adopted from: the declaration pins to what was actually observed, so
/// the follow-up apply never installs it somewhere the user never put it.
#[test]
fn adoption_binds_only_the_harnesses_that_had_the_item() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
    fs::write(
        project.join(".claude/skills/handmade/SKILL.md"),
        "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
    )
    .unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.handmade]"));
    assert!(
        manifest.contains("harnesses = [\"claude\"]"),
        "the declaration must pin to the adopted harness alone:\n{manifest}"
    );

    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
    assert!(project.join(".claude/skills/handmade").is_symlink());
    assert!(!project.join(".opencode/skills/handmade").exists());
}

#[test]
fn foreign_symlinks_are_conflicts_never_clobbered() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let elsewhere = tmp.path().join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/linked")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "linked",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(project.join(".claude/skills/linked").is_symlink());
}

/// The shared-folder case this path exists for: two tools read one
/// folder through links. Adopting captures the folder's content, and
/// after the follow-up apply every tool still resolves to real files —
/// the sharing survives with kendex's copy as canonical.
#[test]
fn a_shared_skill_folder_adopts_the_target_and_keeps_every_tool_reading() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let shared = tmp.path().join("shared/browser");
    fs::create_dir_all(&shared).unwrap();
    fs::write(
        shared.join("SKILL.md"),
        "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    fs::create_dir_all(project.join(".agents/skills")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".agents/skills/browser")).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "browser",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();

    // Content captured; the folder and every link that read it cleared.
    assert!(
        project
            .join(".kendex-local/skills/browser/SKILL.md")
            .is_file()
    );
    assert!(!shared.exists());
    assert!(!project.join(".claude/skills/browser").is_symlink());
    assert!(!project.join(".agents/skills/browser").is_symlink());

    // The follow-up apply restores the sharing from kendex's copy.
    let report = crate::engine::audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();
    let through_claude =
        fs::read_to_string(project.join(".claude/skills/browser/SKILL.md")).unwrap();
    assert!(through_claude.contains("Shared content."));
    let through_agents =
        fs::read_to_string(project.join(".agents/skills/browser/SKILL.md")).unwrap();
    assert!(through_agents.contains("Shared content."));
    let after = crate::engine::audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// "Somewhere kendex has no business touching": a folder that is not a
/// skill at all. The marker is the boundary — no SKILL.md, no adopt.
#[test]
fn a_link_at_a_folder_without_the_marker_still_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let elsewhere = tmp.path().join("documents");
    fs::create_dir_all(&elsewhere).unwrap();
    fs::write(elsewhere.join("notes.txt"), "private").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/documents")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "documents",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(project.join(".claude/skills/documents").is_symlink());
    assert!(elsewhere.join("notes.txt").is_file());
}

/// A link the user repointed into kendex's own store is not theirs to
/// adopt: capturing a managed tree under another name would steal it.
#[test]
fn a_link_into_kendexs_own_trees_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let managed = env.rendered_skills_dir().join("other");
    fs::create_dir_all(&managed).unwrap();
    fs::write(
        managed.join("SKILL.md"),
        "---\nname: other\ndescription: managed elsewhere\n---\nManaged.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&managed, project.join(".claude/skills/stolen")).unwrap();

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "stolen",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::ForeignSymlink { .. }));
    assert!(managed.join("SKILL.md").is_file());
}

/// The folder changing between the plan and the apply aborts the whole
/// transaction: the trash op is bound to the bytes that were captured,
/// so a stale snapshot can never become "the backup".
#[test]
fn a_target_that_changed_after_planning_fails_the_apply() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let shared = tmp.path().join("shared/browser");
    fs::create_dir_all(&shared).unwrap();
    fs::write(
        shared.join("SKILL.md"),
        "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "browser",
        &[HarnessId::Claude],
    )
    .unwrap();
    fs::write(shared.join("SKILL.md"), "changed under the plan").unwrap();

    assert!(crate::apply::execute(&env, &plan, None).is_err());
    assert!(
        shared.join("SKILL.md").is_file(),
        "the folder stays where it was"
    );
    assert!(project.join(".claude/skills/browser").is_symlink());
}

/// A folder bigger than any real skill is refused before anything is
/// planned, naming the budget, instead of being captured wholesale.
#[test]
fn an_oversized_target_is_refused_out_loud() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("huge");
    fs::create_dir_all(&dir).unwrap();
    for i in 0..(MAX_CAPTURE_FILES + 1) {
        fs::write(dir.join(format!("f{i}")), "x").unwrap();
    }
    let error = read_tree(&dir).unwrap_err();
    assert!(error.to_string().contains("bigger than adopt"), "{error}");
}
