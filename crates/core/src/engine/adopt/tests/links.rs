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
use crate::test_util::rooted;
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
    // cleared, so nothing is left pointing at where it came from.
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

/// The same folder at the scope it belongs to is a sharing layout, not a
/// refusal. `~/.agents/skills/<name>` is where a global install lands and
/// where a person building this by hand puts the real folder, because
/// Claude Code reads no shared tree and has to link at one. Adoption is
/// the exit that keeps it; refusing would leave Replace, which sets the
/// person's own folder aside into the trash.
#[cfg(unix)]
#[test]
fn a_global_link_into_the_shared_tree_adopts() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let shared = env.global_skills_dir().join("gh");
    fs::create_dir_all(&shared).unwrap();
    fs::write(
        shared.join("SKILL.md"),
        "---\nname: gh\ndescription: written by hand\n---\nTheirs.\n",
    )
    .unwrap();
    fs::create_dir_all(env.home.join(".claude/skills")).unwrap();
    std::os::unix::fs::symlink(&shared, env.home.join(".claude/skills/gh")).unwrap();

    let plan = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "gh",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    // Global scope captures into the local source rather than in place, so
    // the folder itself goes and the link that read it is cleared.
    assert!(!shared.exists());
    assert!(!env.home.join(".claude/skills/gh").is_symlink());

    // The follow-up apply restores the sharing from kendex's copy: the tree
    // back in the shared place, Claude Code reading it through its link.
    let report = crate::engine::audit(&env, &Scope::Global).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    assert!(shared.join("SKILL.md").is_file());
    let through_claude = fs::read_to_string(env.home.join(".claude/skills/gh/SKILL.md")).unwrap();
    assert!(through_claude.contains("Theirs."));
    assert_eq!(
        crate::engine::audit(&env, &Scope::Global).unwrap().drift,
        vec![]
    );
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

    let failed = crate::apply::execute(&env, &plan).unwrap_err();
    assert!(
        matches!(
            &failed,
            CoreError::RolledBack { cause, .. }
                if matches!(&**cause, CoreError::PlanStale { path } if path == &shared)
        ),
        "{failed:?}"
    );
    assert!(
        shared.join("SKILL.md").is_file(),
        "the folder stays where it was"
    );
    assert!(project.join(".claude/skills/browser").is_symlink());
}

/// One row per link adoption may not follow, each leaving the link and
/// what it points at exactly where they were and nothing in the trash. A
/// folder that is not a skill at all: the marker is the boundary — no
/// SKILL.md, no adopt. A project link reaching the global shared tree:
/// what sits there is a global install, which the project's lock cannot
/// see, and capturing it under another name would steal it. A global link
/// at one name pointing at another name's folder in the shared tree, and
/// a project link at one name into its shared tree at another: each names
/// a second skill that already has a home, and adopting through it would
/// capture that folder under this name and move the original, taking the
/// second skill's content with it. Only this skill's own place in the
/// shared tree is the finished shape, which
/// `a_global_link_into_the_shared_tree_adopts` and
/// `a_link_at_this_items_own_home_is_adopted` keep.
#[cfg(unix)]
#[test]
fn a_link_into_a_folder_that_is_not_this_skills_own_refuses() {
    /// The link a tool holds, the folder it points at, and a file in
    /// that folder with the bytes it must still hold.
    type Plant = fn(&Env, &Path) -> (PathBuf, PathBuf, PathBuf, &'static str);
    let rows: [(&str, bool, Plant); 4] = [
        ("a folder without the marker", false, |_, project| {
            let elsewhere = project.parent().unwrap().join("documents");
            fs::create_dir_all(&elsewhere).unwrap();
            fs::write(elsewhere.join("notes.txt"), "private").unwrap();
            let link = project.join(".claude/skills/documents");
            (
                link,
                elsewhere.clone(),
                elsewhere.join("notes.txt"),
                "private",
            )
        }),
        (
            "a project link into the global tree",
            false,
            |env, project| {
                let managed = env.global_skills_dir().join("other");
                fs::create_dir_all(&managed).unwrap();
                fs::write(managed.join("SKILL.md"), "Managed.\n").unwrap();
                let link = project.join(".claude/skills/stolen");
                (
                    link,
                    managed.clone(),
                    managed.join("SKILL.md"),
                    "Managed.\n",
                )
            },
        ),
        (
            "a global link across names in the shared tree",
            true,
            |env, home| {
                let other = env.global_skills_dir().join("other");
                fs::create_dir_all(&other).unwrap();
                fs::write(other.join("SKILL.md"), "Theirs.\n").unwrap();
                let link = home.join(".claude/skills/alias");
                (link, other.clone(), other.join("SKILL.md"), "Theirs.\n")
            },
        ),
        (
            "a project link into its shared tree at another name",
            false,
            |_, project| {
                let other = project.join(".agents/skills/browser");
                fs::create_dir_all(&other).unwrap();
                fs::write(other.join("SKILL.md"), "Theirs.\n").unwrap();
                let link = project.join(".claude/skills/handmade");
                (link, other.clone(), other.join("SKILL.md"), "Theirs.\n")
            },
        ),
    ];
    for (label, global, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let (scope, root) = match global {
            true => (Scope::Global, home.clone()),
            false => {
                let project = home.join("app");
                (
                    Scope::Project {
                        root: project.clone(),
                    },
                    project,
                )
            }
        };
        let (link, target, kept, body) = plant(&env, &root);
        fs::create_dir_all(link.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let name = link.file_name().unwrap().to_str().unwrap();

        let refused = adopt(&env, &scope, ItemKind::Skill, name, &[HarnessId::Claude]).unwrap_err();

        match &refused {
            CoreError::ForeignSymlink {
                target: at,
                points_to,
            } => {
                assert_eq!(at, &link, "{label}");
                assert_eq!(points_to, &target, "{label}");
            }
            other => panic!("{label}: expected the foreign-symlink refusal, got {other:?}"),
        }
        assert!(link.is_symlink(), "{label}");
        assert_eq!(fs::read_to_string(&kept).unwrap(), body, "{label}");
        assert!(trash_is_empty(&env), "{label}");
    }
}

/// One row per name that is not a name, refused before a path is derived
/// and captured and trashed nothing, with the offer a surface would draw
/// saying the same thing. An absolute name: `PathBuf::join` throws away
/// the root it is joined onto, so the position adoption reads becomes the
/// absolute path itself — a directory outside every kendex root. A
/// `..`-shaped name climbs out of the tool's skills directory: the old
/// join put the position at `.claude/notes`, one step above where skills
/// live. The refusal carries the name and the reason `names::item_problem`
/// gives, whose rows are pinned in `names.rs`.
#[test]
fn a_name_that_is_not_a_name_captures_and_trashes_nothing() {
    /// The folder the name would have reached, and the name as asked.
    type Plant = fn(&Path, &Path) -> (PathBuf, String);
    let rows: [(&str, Plant); 2] = [
        ("an absolute name", |tmp, _| {
            let outside = tmp.join("elsewhere/notes");
            (outside.clone(), outside.to_str().unwrap().to_owned())
        }),
        ("a traversal name", |_, project| {
            (project.join(".claude/notes"), "../notes".to_owned())
        }),
    ];
    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let (reached, name) = plant(&home, &project);
        fs::create_dir_all(&reached).unwrap();
        fs::write(reached.join("SKILL.md"), "not an item kendex was given").unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();

        let refused =
            adopt(&env, &scope, ItemKind::Skill, &name, &[HarnessId::Claude]).unwrap_err();

        match &refused {
            CoreError::AdoptNameUnusable { name: shown, .. } => {
                assert_eq!(shown, &crate::names::shown(&name), "{label}");
            }
            other => panic!("{label}: expected the unusable-name refusal, got {other:?}"),
        }
        assert!(reached.join("SKILL.md").is_file(), "{label}");
        assert!(!project.join(".kendex-local").exists(), "{label}");
        assert!(trash_is_empty(&env), "{label}");
        assert!(
            !can_keep_for(&env, &scope, ItemKind::Skill, &name, HarnessId::Claude),
            "{label}"
        );
    }
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
