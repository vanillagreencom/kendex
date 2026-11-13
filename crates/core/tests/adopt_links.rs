//! Adopting a skill keeps what its links meant: every position the named
//! tools hold it at is read into the shared tree the store fixes, the
//! positions must agree on those targets, and a relocation converts the
//! tree where it stands before the move carries it whole.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::test_util::rooted;

use kendex_core::engine::adopt::{adopt, can_keep_all};
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, ManifestFile, SkillLinks};
use kendex_core::model::{HarnessId, ItemKind, Scope};

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn skill(body: &str) -> String {
    format!("---\nname: ship\ndescription: ship\n---\n{body}\n")
}

#[allow(clippy::unwrap_used)]
fn links_of(env: &Env, scope: &Scope) -> Option<SkillLinks> {
    match manifest::load(&manifest::manifest_path(env, scope)).unwrap() {
        ManifestFile::Current(manifest) => manifest.skills["ship"].links,
        ManifestFile::Absent => panic!("no manifest"),
    }
}

/// The file the first `[m](...)` link in `tree/SKILL.md` reaches.
#[allow(clippy::unwrap_used)]
fn reached(tree: &Path) -> PathBuf {
    let text = fs::read_to_string(tree.join("SKILL.md")).unwrap();
    let spelled = text
        .lines()
        .find_map(|line| line.strip_prefix("[m](")?.strip_suffix(')'))
        .unwrap();
    fs::canonicalize(fs::canonicalize(tree).unwrap().join(spelled)).unwrap()
}

/// Global adoption reads each held position into `~/.agents/skills/ship`,
/// wherever the local store sits. Copies whose links reach the same files
/// capture once, converted and tagged; copies holding equal bytes at two
/// depths reach two files and are a choice the reader makes.
#[test]
#[allow(clippy::unwrap_used)]
fn global_adoption_keeps_what_every_position_meant() {
    // (row, tool positions and the link each holds, keeps)
    type Row<'a> = (&'a str, Vec<(HarnessId, &'a str)>, bool);
    let rows: Vec<Row<'_>> = vec![
        (
            "Claude alone, depth three",
            vec![(HarnessId::Claude, "../../../memory/x.md")],
            true,
        ),
        (
            "Pi alone, depth four",
            vec![(HarnessId::Pi, "../../../../memory/x.md")],
            true,
        ),
        (
            "equal bytes at depth three and four",
            vec![
                (HarnessId::Claude, "../../../memory/x.md"),
                (HarnessId::Pi, "../../../memory/x.md"),
            ],
            false,
        ),
        (
            "each spelled for its own depth",
            vec![
                (HarnessId::Claude, "../../../memory/x.md"),
                (HarnessId::Pi, "../../../../memory/x.md"),
            ],
            true,
        ),
    ];
    for (row, held, keeps) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let scope = Scope::Global;
        put(&home.join("memory/x.md"), "Memory.\n");
        put(&home.join(".pi/memory/x.md"), "Pi memory.\n");
        let harnesses: Vec<HarnessId> = held.iter().map(|(harness, _)| *harness).collect();
        let names = harnesses
            .iter()
            .map(|harness| format!("{:?}", harness.name()))
            .collect::<Vec<_>>()
            .join(", ");
        put(
            &env.global_manifest_file(),
            &format!("schema = 8\n[install]\nharnesses = [{names}]\nmethod = \"symlink\"\n"),
        );
        let mut first = None;
        for (harness, link) in &held {
            let dir =
                kendex_core::engine::desired::own_dir(&env, &scope, *harness, ItemKind::Skill)
                    .unwrap()
                    .join("ship");
            put(
                &dir.join("SKILL.md"),
                &skill(&format!("[m]({link})\n[r](reference.md)")),
            );
            put(&dir.join("reference.md"), "Reference.\n");
            first.get_or_insert_with(|| reached(&dir));
        }
        let target = first.unwrap();
        assert_eq!(
            can_keep_all(&env, &scope, ItemKind::Skill, "ship", &harnesses),
            keeps,
            "{row}"
        );
        let adopted = adopt(&env, &scope, ItemKind::Skill, "ship", &harnesses);
        let plan = match (adopted, keeps) {
            (Ok(plan), true) => plan,
            (Err(CoreError::AdoptedCopiesDiffer { .. }), false) => continue,
            (Ok(_), false) => panic!("{row}: positions that disagree were captured once"),
            (Err(error), _) => panic!("{row}: {error}"),
        };
        assert!(plan.warnings.is_empty(), "{row}: {:?}", plan.warnings);
        kendex_core::apply::execute(&env, &plan).unwrap();
        assert_eq!(
            links_of(&env, &scope),
            Some(SkillLinks::SharedTree),
            "{row}"
        );
        let report = audit(&env, &scope).unwrap();
        kendex_core::apply::execute(&env, &report.plan).unwrap();
        let shared = env.global_skills_dir().join("ship");
        assert_eq!(reached(&shared), target, "{row}");
        assert_eq!(
            fs::read_to_string(shared.join("reference.md")).unwrap(),
            "Reference.\n",
            "{row}"
        );
    }
}

/// A folder several tools share by hand is captured from where it really
/// stands, so a link beside it keeps reaching the same file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shared_folder_is_read_from_where_it_stands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let folder = home.join("dotfiles/ship");
    put(&folder.join("SKILL.md"), &skill("[m](../notes/x.md)"));
    put(&home.join("dotfiles/notes/x.md"), "Notes.\n");
    let claude =
        kendex_core::engine::desired::native_dir(&env, &scope, HarnessId::Claude, ItemKind::Skill)
            .unwrap()
            .join("ship");
    fs::create_dir_all(claude.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&folder, &claude).unwrap();
    put(
        &env.global_manifest_file(),
        "schema = 8\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
    );
    let plan = adopt(&env, &scope, ItemKind::Skill, "ship", &[HarnessId::Claude]).unwrap();
    kendex_core::apply::execute(&env, &plan).unwrap();
    let report = audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    assert_eq!(links_of(&env, &scope), Some(SkillLinks::SharedTree));
    assert_eq!(
        reached(&env.global_skills_dir().join("ship")),
        fs::canonicalize(home.join("dotfiles/notes/x.md")).unwrap()
    );
}

/// A project relocation compares every held copy by what it reads from the
/// home, and a link file inside the tree by what it reaches from where it
/// stands. Copies that read different files are refused before anything
/// moves; copies holding the same link files agree in whatever order the
/// directory lists them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_relocation_keeps_both_copies_only_where_they_read_the_same_files() {
    // (row, SKILL.md body, link files per copy as (name, target), keeps)
    type Links<'a> = [Vec<(&'a str, &'a str)>; 2];
    type Row<'a> = (&'a str, &'a str, Links<'a>, bool);
    let rows: Vec<Row<'_>> = vec![
        (
            "text links read different files",
            "[m](../../agents/x.md)",
            [vec![], vec![]],
            false,
        ),
        (
            "same-named link files spelled for different files",
            "[r](reference.md)",
            [
                vec![("fixture", "../../fixtures/a.md")],
                vec![("fixture", "../../fixtures/b.md")],
            ],
            false,
        ),
        (
            "one relative link copied to two depths",
            "[r](reference.md)",
            [
                vec![("assets", "../../assets")],
                vec![("assets", "../../assets")],
            ],
            false,
        ),
        (
            "the same links inside each tree, made in either order",
            "[r](reference.md)",
            [
                vec![("alias", "reference.md"), ("entry", "SKILL.md")],
                vec![("entry", "SKILL.md"), ("alias", "reference.md")],
            ],
            true,
        ),
    ];
    for (row, body, links, keeps) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        put(
            &project.join("kendex.toml"),
            "schema = 8\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n",
        );
        for (dir, links) in [".agents/skills/ship", ".claude/skills/ship"]
            .iter()
            .zip(&links)
        {
            let tree = project.join(dir);
            put(&tree.join("SKILL.md"), &skill(body));
            put(&tree.join("reference.md"), "Reference.\n");
            for (name, target) in links {
                std::os::unix::fs::symlink(target, tree.join(name)).unwrap();
            }
        }
        let both = [HarnessId::Claude, HarnessId::Codex];
        assert_eq!(
            can_keep_all(&env, &scope, ItemKind::Skill, "ship", &both),
            keeps,
            "{row}"
        );
        match (adopt(&env, &scope, ItemKind::Skill, "ship", &both), keeps) {
            (Err(CoreError::AdoptedCopiesDiffer { .. }), false) => {
                assert!(
                    project.join(".claude/skills/ship/SKILL.md").is_file(),
                    "{row}"
                );
            }
            (Ok(_), true) => {}
            (Ok(_), false) => panic!("{row}: copies that read different files were kept as one"),
            (Err(error), _) => panic!("{row}: {error}"),
        }
    }
}

/// Relocating a folder linked at the home converts its links where it
/// stands and moves it whole: the executable bit and the empty directory
/// ride the rename, and a write that fails later in the same plan puts the
/// folder, its bytes and the link back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_relocation_converts_in_place_and_keeps_the_rename() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("app");
    let scope = Scope::Project {
        root: project.clone(),
    };
    let manifest = "schema = 8\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n";
    put(&project.join("kendex.toml"), manifest);
    let folder = project.join("shared/ship");
    let authored = skill("[m](../notes/x.md)");
    put(&folder.join("SKILL.md"), &authored);
    put(&project.join("shared/notes/x.md"), "Notes.\n");
    put(&folder.join("run.sh"), "#!/bin/sh\n");
    fs::set_permissions(folder.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::create_dir_all(folder.join("empty")).unwrap();
    let at_home = project.join(".agents/skills/ship");
    fs::create_dir_all(at_home.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&folder, &at_home).unwrap();
    let target = fs::canonicalize(project.join("shared/notes/x.md")).unwrap();

    // A plan whose last write meets a changed manifest rolls back whole.
    let stale = adopt(&env, &scope, ItemKind::Skill, "ship", &[HarnessId::Codex]).unwrap();
    put(
        &project.join("kendex.toml"),
        &format!("{manifest}# edited\n"),
    );
    assert!(kendex_core::apply::execute(&env, &stale).is_err());
    assert!(at_home.is_symlink());
    assert_eq!(
        fs::read_to_string(folder.join("SKILL.md")).unwrap(),
        authored
    );
    put(&project.join("kendex.toml"), manifest);

    let plan = adopt(&env, &scope, ItemKind::Skill, "ship", &[HarnessId::Codex]).unwrap();
    assert!(plan.warnings.is_empty(), "{:?}", plan.warnings);
    kendex_core::apply::execute(&env, &plan).unwrap();
    assert!(!at_home.is_symlink() && at_home.is_dir());
    assert!(!folder.exists());
    assert_eq!(reached(&at_home), target);
    assert_eq!(
        fs::metadata(at_home.join("run.sh"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o755
    );
    assert!(at_home.join("empty").is_dir());
    assert_eq!(links_of(&env, &scope), Some(SkillLinks::SharedTree));
}
