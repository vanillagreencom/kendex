//! Adoption through a link: the boundary that decides what a link may be
//! adopted through, and what each refusal leaves exactly where it was.
//!
//! Every test that builds a link carries `#[cfg(unix)]` — the layout it
//! sets up needs a symlink, and a test can only make one where the
//! platform does not put a privilege in front of it. The name rules below
//! that never build one run everywhere.

use super::super::*;
use crate::engine::audit;
use crate::env::FakeOs;
use std::fs;

use super::trash_is_empty;

/// The shared-folder case this path exists for: two tools read one
/// folder through links. Adopting captures the folder's content, and
/// after the follow-up apply every tool still resolves to real files —
/// the sharing survives with kendex's copy as canonical.
#[cfg(unix)]
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
    crate::apply::execute(&env, &plan).unwrap();

    // The folder moved into the shared tree and every link that read it was
    // cleared, so nothing is left pointing at where it used to be.
    assert!(project.join(".agents/skills/browser/SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(!shared.exists());
    assert!(!project.join(".claude/skills/browser").is_symlink());
    assert!(!project.join(".agents/skills/browser").is_symlink());

    // The follow-up apply restores the sharing from kendex's copy.
    let report = crate::engine::audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
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
#[cfg(unix)]
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
#[cfg(unix)]
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
#[cfg(unix)]
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

    assert!(crate::apply::execute(&env, &plan).is_err());
    assert!(
        shared.join("SKILL.md").is_file(),
        "the folder stays where it was"
    );
    assert!(project.join(".claude/skills/browser").is_symlink());
}

/// An absolute name is not a name. `PathBuf::join` throws away the root it
/// is joined onto, so the position adoption reads becomes the absolute
/// path itself — a directory outside every kendex root, captured into the
/// local source and then trashed. Refused before a path is derived.
#[test]
fn an_absolute_name_captures_and_trashes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let outside = tmp.path().join("elsewhere/notes");
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("SKILL.md"), "somebody else's files").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        outside.to_str().unwrap(),
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(outside.join("SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(trash_is_empty(&env));
    // The offer a surface would draw says the same thing.
    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        outside.to_str().unwrap(),
        HarnessId::Claude
    ));
}

/// A `..`-shaped name climbs out of the tool's skills directory: the old
/// join put the position at `.claude/notes`, one step above where skills
/// live, and the capture would have moved and trashed it.
#[test]
fn a_traversal_name_captures_and_trashes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let climbed = project.join(".claude/notes");
    fs::create_dir_all(&climbed).unwrap();
    fs::write(climbed.join("SKILL.md"), "not an item kendex was given").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "../notes",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::AdoptNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(climbed.join("SKILL.md").is_file());
    assert!(!project.join(".kendex-local").exists());
    assert!(trash_is_empty(&env));
    assert!(!can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "../notes",
        HarnessId::Claude
    ));
}

/// A namespaced skill sits at the tool's rendered spelling — one directory
/// called `plugin__item`, never nested directories — while the logical
/// name stays the manifest's and the local source's. Looking under
/// `.claude/skills/data-science/eda` would find nothing and report a skill
/// that is plainly there as absent.
#[test]
fn a_namespaced_skill_is_adopted_at_its_rendered_position() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let rendered = project.join(".claude/skills/data-science__eda");
    fs::create_dir_all(&rendered).unwrap();
    fs::write(
        rendered.join("SKILL.md"),
        "---\nname: eda\ndescription: explore data\n---\nMy content.\n",
    )
    .unwrap();

    assert!(can_keep_for(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        HarnessId::Claude
    ));
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    // A namespaced name keeps the capture: the shared tree would store it
    // under a flattened leaf the name cannot be looked up by, so it is not
    // a tree that can be its own source.
    assert!(
        project
            .join(".kendex-local/skills/data-science/eda/SKILL.md")
            .is_file()
    );
    assert!(!rendered.exists());
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("data-science/eda"), "{manifest}");

    // The follow-up apply puts it back where the tool reads it, and the
    // scope is drift-clean.
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    assert!(rendered.exists(), "the tool reads it at its rendered name");
    assert!(!project.join(".claude/skills/data-science").exists());
    let after = audit(&env, &scope).unwrap();
    assert_eq!(after.drift, vec![]);
}

/// A link at one name pointing into the shared tree at another names a
/// second skill that already has a home. Adopting through it would rename
/// that one under this name, taking its content with it.
#[cfg(unix)]
#[test]
fn a_link_into_the_shared_tree_at_another_name_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let other = project.join(".agents/skills/browser");
    fs::create_dir_all(&other).unwrap();
    fs::write(other.join("SKILL.md"), "---\nname: browser\n---\nTheirs.\n").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&other, project.join(".claude/skills/handmade")).unwrap();

    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::ForeignSymlink { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(other.join("SKILL.md")).unwrap(),
        "---\nname: browser\n---\nTheirs.\n"
    );
    assert!(trash_is_empty(&env));
}

/// The same link pointing at this item's own home is the finished shape —
/// a skill already in the shared tree that tools read through links.
#[cfg(unix)]
#[test]
fn a_link_at_this_items_own_home_is_adopted() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let home = project.join(".agents/skills/handmade");
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("SKILL.md"), "---\nname: handmade\n---\nMine.\n").unwrap();
    fs::create_dir_all(project.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&home, project.join(".claude/skills/handmade")).unwrap();

    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();
    assert!(home.join("SKILL.md").is_file());
    let report = audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    assert!(project.join(".claude/skills/handmade").is_symlink());
    assert_eq!(audit(&env, &scope).unwrap().drift, vec![]);
}
