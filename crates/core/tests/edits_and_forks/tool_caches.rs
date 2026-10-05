//! A tool cache in an installed skill render is not an edit. A skill's own
//! Python script leaves `__pycache__` beside the helper it imports, and a
//! skill's source never carries one, so the render was written without it
//! and every run writes it back.

use std::fs;

use super::*;

const CACHED: &str = "helper.cpython-312.pyc";

/// `gh` with a Python helper, installed into the fixture project. Returns
/// the render's root.
#[allow(clippy::unwrap_used)]
fn installed(w: &World) -> PathBuf {
    write_skill(&w.upstream, "gh", "One.");
    fs::create_dir_all(w.upstream.join("skills/gh/scripts")).unwrap();
    fs::write(w.upstream.join("skills/gh/scripts/helper.py"), "pass\n").unwrap();
    commit(&w.upstream, "one");
    declare(w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(w);
    let render = w.home.join("app/.agents/skills/gh");
    assert!(render.join("scripts/helper.py").is_file());
    render
}

#[allow(clippy::unwrap_used)]
fn plant_caches(render: &Path) {
    for cache in ["scripts/__pycache__", ".pytest_cache"] {
        fs::create_dir_all(render.join(cache)).unwrap();
        fs::write(render.join(cache).join(CACHED), b"\x00cache").unwrap();
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_tool_cache_in_a_skill_render_plans_nothing() {
    let w = world();
    let render = installed(&w);
    plant_caches(&render);

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(report.plan.ops.is_empty(), "{:?}", report.plan.ops);
    assert!(
        report.drift.iter().all(|row| row.name != "gh"),
        "{:?}",
        report.drift
    );

    // The control: the same bytes outside a cache directory are an edit.
    fs::write(render.join("scripts").join(CACHED), b"\x00cache").unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    let row = report.drift.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(row.cause, Some(DriftCause::LocalEdit), "{row:?}");
}

/// A newer upstream is written over a cached render rather than held as
/// an edit.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cached_skill_render_takes_a_newer_upstream() {
    let w = world();
    let render = installed(&w);
    plant_caches(&render);

    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    sync_and_apply(&w);
    let skill = fs::read_to_string(render.join("SKILL.md")).unwrap();
    assert!(skill.contains("Two."), "{skill}");
}

/// The plan of the orphan cleanup a refresh runs, once `gh` is no longer
/// declared.
#[allow(clippy::unwrap_used)]
fn orphan_cleanup(w: &World) -> kendex_core::error::Result<kendex_core::engine::EngineReport> {
    declare(w, "");
    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    plan_scope(
        &w.env,
        &w.scope,
        &manifest,
        &lock,
        &PlanOptions {
            remove_orphans: true,
            ..Default::default()
        },
    )
}

/// The orphan cleanup takes a cached render whole: an automatic removal
/// holds only a render that is not the bytes kendex wrote, and a cache
/// does not make it one.
#[test]
#[allow(clippy::unwrap_used)]
fn an_orphan_cleanup_takes_a_cached_skill_render() {
    let w = world();
    let render = installed(&w);
    plant_caches(&render);

    let report = orphan_cleanup(&w).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(!render.exists(), "{}", render.display());
}

/// A `.git` inside a render is a person's repository, not a cache: a newer
/// upstream is held rather than written over the tree, which would delete
/// the repository with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_render_holding_a_repository_is_held_from_a_newer_upstream() {
    let w = world();
    let render = installed(&w);
    fs::create_dir_all(render.join(".git")).unwrap();
    fs::write(render.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();

    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    sync_and_apply(&w);
    assert!(render.join(".git/HEAD").is_file());
    let skill = fs::read_to_string(render.join("SKILL.md")).unwrap();
    assert!(!skill.contains("Two."), "{skill}");
}

/// A `.venv` inside a render is a person's environment, not a cache: the
/// orphan cleanup holds the render, and an interpreter link that no longer
/// resolves does not fail the plan.
#[test]
#[allow(clippy::unwrap_used)]
fn an_orphan_cleanup_holds_a_skill_render_holding_an_environment() {
    let w = world();
    let render = installed(&w);
    fs::create_dir_all(render.join(".venv/bin")).unwrap();
    std::os::unix::fs::symlink("/nonexistent/python3", render.join(".venv/bin/python")).unwrap();

    let report = orphan_cleanup(&w).unwrap();
    assert!(report.plan.ops.is_empty(), "{:?}", report.plan.ops);
}
