//! An in-place skill owns its source bytes. Kendex maintains the links that
//! harnesses need around that tree, but never treats the tree as an install
//! copy that a take-over can move or rewrite.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    project: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    let source = project.join(".agents/skills/deploy");
    fs::create_dir_all(source.join(".venv")).unwrap();
    fs::write(
        source.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship it\n---\nOwned source.\n",
    )
    .unwrap();
    fs::write(source.join(".venv/state"), b"local working state\0\xff").unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\", \"pi\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\n",
    )
    .unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

fn check_text(world: &World) -> String {
    drift::report::render_plain(&drift::report::check(
        &world.env,
        std::slice::from_ref(&world.scope),
    ))
}

#[allow(clippy::unwrap_used)]
fn tree_bytes(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(root: &Path, at: &Path, files: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(at).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(root, &path, files);
            } else {
                files.insert(
                    path.strip_prefix(root).unwrap().to_path_buf(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut files = BTreeMap::new();
    walk(root, root, &mut files);
    files
}

fn trash_is_empty(env: &Env) -> bool {
    match fs::read_dir(env.trash_dir()) {
        Ok(mut entries) => entries.next().is_none(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(error) => panic!("trash could not be read: {error}"),
    }
}

/// The source directory is present, but no harness link or install record
/// exists. This is one package-level missing-render state, not one
/// unmanaged-copy result per harness.
#[test]
fn check_reports_one_missing_render_for_an_unrecorded_in_place_skill() {
    let world = world();

    let text = check_text(&world);

    assert_eq!(
        text.matches("skill 'deploy' has harness links that are not rendered")
            .count(),
        1,
        "{text}"
    );
    assert!(text.contains("fix: kendex refresh"), "{text}");
    assert!(!text.contains("unmanaged copy"), "{text}");
    assert!(!text.contains("--replace-unmanaged"), "{text}");
}

/// The scope-wide take-over flag reaches every declaration. An in-place
/// declaration still plans only its missing links, so excluded dependency
/// directories stay byte-identical and no source byte reaches the trash.
#[test]
#[allow(clippy::unwrap_used)]
fn replace_unmanaged_preserves_an_in_place_source_tree() {
    let world = world();
    let source = world.project.join(".agents/skills/deploy");
    let before = tree_bytes(&source);
    let options = PlanOptions {
        replace_unmanaged: true,
        ..PlanOptions::default()
    };

    let report = plan_apply(&world.env, &world.scope, &options).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();

    assert_eq!(tree_bytes(&source), before);
    assert!(trash_is_empty(&world.env));
    assert!(world.project.join(".claude/skills/deploy").is_symlink());
    assert_eq!(check_text(&world), "");
}
