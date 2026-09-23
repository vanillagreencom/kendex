//! An in-place skill owns its source bytes. Kendex maintains the links that
//! harnesses need around that tree, but never treats the tree as an install
//! copy that a take-over can move or rewrite.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::{PlanOptions, ops, plan_apply};
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
fn set_manifest(world: &World, harnesses: &str, enabled: bool) {
    fs::write(
        world.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\nenabled = {enabled}\n"
        ),
    )
    .unwrap();
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

#[allow(clippy::unwrap_used)]
fn assert_unreadable_parent_is_unknown(world: &World, parent: &Path) {
    fs::set_permissions(parent, fs::Permissions::from_mode(0o000)).unwrap();
    let checked = drift::report::check(&world.env, std::slice::from_ref(&world.scope));
    let text = drift::report::render_plain(&checked);
    fs::set_permissions(parent, fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{text}"
    );
    assert!(text.contains("could not check:\n"), "{text}");
    assert!(
        !text.contains("harness links that are not rendered"),
        "{text}"
    );
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

/// Apply records only the harness positions that kendex creates. An
/// explicit removal therefore removes those positions and keeps the source.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_an_applied_in_place_skill_preserves_its_source_tree() {
    let world = world();
    let source = world.project.join(".agents/skills/deploy");
    let before = tree_bytes(&source);
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();

    let lock_path = kendex_core::lock::lock_path(&world.env, &world.scope);
    let lock = kendex_core::lock::load(&lock_path).unwrap();
    assert!(lock.entries.values().all(|entry| {
        entry
            .emitted
            .as_ref()
            .is_none_or(|emitted| !emitted.paths.contains(&source))
    }));

    let report = ops::remove(
        &world.env,
        &world.scope,
        &["deploy".to_owned()],
        None,
        false,
    )
    .unwrap();
    apply::execute(&world.env, &report.plan).unwrap();

    assert_eq!(tree_bytes(&source), before);
    assert!(!world.project.join(".claude/skills/deploy").exists());
}

/// Existing records can name the source as emitted content. Removal reads
/// that record through the current ownership rule and keeps the source.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_legacy_in_place_record_preserves_its_source_tree() {
    let world = world();
    let source = world.project.join(".agents/skills/deploy");
    let before = tree_bytes(&source);
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&world.env, &world.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    lock.entries
        .get_mut("skill:deploy:codex")
        .unwrap()
        .emitted
        .as_mut()
        .unwrap()
        .paths
        .push(source.clone());
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let report = ops::remove(
        &world.env,
        &world.scope,
        &["deploy".to_owned()],
        None,
        false,
    )
    .unwrap();
    apply::execute(&world.env, &report.plan).unwrap();

    assert_eq!(tree_bytes(&source), before);
}

/// A record for one target does not prove that a newly declared target has
/// its link. Check reports the missing link once for the skill.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reports_a_missing_link_for_a_new_target_harness() {
    let world = world();
    fs::write(
        world.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\n",
    )
    .unwrap();
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();
    fs::write(
        world.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n\n[skills.deploy]\nsource = \"in-place\"\n",
    )
    .unwrap();

    let text = check_text(&world);

    assert_eq!(
        text.matches("skill 'deploy' has harness links that are not rendered")
            .count(),
        1,
        "{text}"
    );
    assert!(text.contains("fix: kendex refresh"), "{text}");
}

/// Switching off a live source refuses the install and removes managed
/// links. It does not rename the authored entry point inside the source.
#[test]
#[allow(clippy::unwrap_used)]
fn disabling_an_applied_in_place_skill_preserves_its_source() {
    let world = world();
    let source = world.project.join(".agents/skills/deploy");
    let before = tree_bytes(&source);
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();
    set_manifest(&world, "\"claude\", \"codex\", \"pi\"", false);

    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    assert!(report.drift.iter().any(|row| {
        row.name == "deploy" && row.state == kendex_core::engine::DriftState::Conflict
    }));
    apply::execute(&world.env, &report.plan).unwrap();

    assert_eq!(tree_bytes(&source), before);
    assert!(!world.project.join(".claude/skills/deploy").exists());
    let lock_path = kendex_core::lock::lock_path(&world.env, &world.scope);
    let lock = kendex_core::lock::load(&lock_path).unwrap();
    assert!(lock.entries.values().all(|entry| entry.name != "deploy"));
    let text = check_text(&world);
    assert!(text.contains("cannot be switched off"), "{text}");
    assert!(!text.contains("fix:"), "{text}");
}

/// A shared-directory install owns no delivery path. Its source still has
/// to exist for the shallow check to report the scope as clean.
#[test]
#[allow(clippy::unwrap_used)]
fn check_reports_a_missing_pathless_in_place_source() {
    let world = world();
    set_manifest(&world, "\"codex\"", true);
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();
    fs::remove_dir_all(world.project.join(".agents/skills/deploy")).unwrap();

    let text = check_text(&world);

    assert_eq!(
        text.matches("skill 'deploy' source is missing").count(),
        1,
        "{text}"
    );
    assert!(!text.contains("fix:"), "{text}");
}

/// A command read from the in-place catalog is still a generated install.
/// Codex reads commands as skill trees, so apply must write that tree even
/// though its destination is also the shared skill directory.
#[test]
#[allow(clippy::unwrap_used)]
fn an_in_place_command_still_renders_its_codex_skill_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("app");
    fs::create_dir_all(project.join(".agents/commands")).unwrap();
    fs::write(
        project.join(".agents/commands/ship.md"),
        "---\ndescription: Ship the branch\n---\n\nRun the release checklist.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n\n[commands.ship]\nsource = \"in-place\"\n",
    )
    .unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Project {
        root: project.clone(),
    };

    let report = plan_apply(&env, &scope, &PlanOptions::default()).unwrap();
    apply::execute(&env, &report.plan).unwrap();

    let rendered = fs::read_to_string(project.join(".agents/skills/ship/SKILL.md")).unwrap();
    assert!(
        rendered.contains("Run the release checklist."),
        "{rendered}"
    );
}

/// A source that cannot be inspected is an unknown state. It is not a
/// clean check and it cannot support a missing-link remedy.
#[test]
#[allow(clippy::unwrap_used)]
fn an_inaccessible_in_place_source_is_could_not_check() {
    let world = world();
    set_manifest(&world, "\"codex\"", true);
    let report = plan_apply(&world.env, &world.scope, &PlanOptions::default()).unwrap();
    apply::execute(&world.env, &report.plan).unwrap();
    assert_unreadable_parent_is_unknown(&world, &world.project.join(".agents/skills/deploy"));
}

/// An unreadable harness parent cannot prove that its link is absent.
/// The report must keep the file-status error instead of prescribing refresh.
#[test]
#[allow(clippy::unwrap_used)]
fn an_inaccessible_harness_parent_is_could_not_check() {
    let world = world();
    let parent = world.project.join(".claude");
    fs::create_dir_all(&parent).unwrap();
    assert_unreadable_parent_is_unknown(&world, &parent);
}
