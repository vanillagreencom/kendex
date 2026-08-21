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
        "schema = 5\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n",
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

/// A project asking for one item for two tools, with files already at
/// both places. Handed over one tool at a time, the second capture wrote
/// over the first in the local source and the declaration stayed pinned
/// to the first tool — so the second tool kept files nothing managed and
/// the first tool's copy was gone. One plan takes both.
#[test]
fn every_tool_the_item_sits_at_is_kept_in_one_pass() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 5\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n",
    )
    .unwrap();
    let body = "---\nname: handmade\ndescription: mine\n---\nMy content.\n";
    for dir in [".claude/skills/handmade", ".agents/skills/handmade"] {
        fs::create_dir_all(project.join(dir)).unwrap();
        fs::write(project.join(dir).join("SKILL.md"), body).unwrap();
    }

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude, HarnessId::Codex],
    )
    .unwrap();
    crate::apply::execute(&env, &plan, None).unwrap();
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan, None).unwrap();

    for dir in [".claude/skills/handmade", ".agents/skills/handmade"] {
        let installed = fs::read_to_string(project.join(dir).join("SKILL.md")).unwrap_or_default();
        assert!(
            installed.contains("My content."),
            "{dir} was left with files nothing manages"
        );
    }
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![], "one tool is still waiting");
}

/// The tools hold different files under one name, and there is one
/// place in the local source to put them. Picking one would send the
/// other to the trash without asking, so the choice goes back to the
/// reader and nothing moves.
#[test]
fn tools_holding_different_files_are_a_choice_not_a_merge() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 5\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n",
    )
    .unwrap();
    for (dir, text) in [
        (".claude/skills/handmade", "what Claude Code had"),
        (".agents/skills/handmade", "what Codex had"),
    ] {
        fs::create_dir_all(project.join(dir)).unwrap();
        fs::write(
            project.join(dir).join("SKILL.md"),
            format!("---\nname: handmade\ndescription: mine\n---\n{text}\n"),
        )
        .unwrap();
    }

    let error = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude, HarnessId::Codex],
    )
    .unwrap_err();
    assert!(
        matches!(error, CoreError::AdoptedCopiesDiffer { .. }),
        "{error}"
    );
    assert!(
        fs::read_to_string(project.join(".claude/skills/handmade/SKILL.md"))
            .unwrap()
            .contains("what Claude Code had")
    );
    assert!(
        fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md"))
            .unwrap()
            .contains("what Codex had")
    );
    assert!(!project.join(".kendex-local/skills/handmade").exists());
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
