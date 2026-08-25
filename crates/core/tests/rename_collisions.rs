//! Rename-generation collisions caught at plan time, and a manifest
//! mutation on an old-name scope saving after the rename prefix.

#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    // Plan ops speak the canonical spelling; the fixture enters canonical
    // space once so op paths compare equal to fixture-derived ones (macOS
    // fronts its temp directories with a `/var` → `/private/var` symlink).
    let home = tmp.path().canonicalize().unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    Fixture {
        env,
        home,
        project,
        _tmp: tmp,
    }
}

const MANIFEST: &str = "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n";

#[test]
#[allow(clippy::unwrap_used)]
fn both_local_source_dirs_refuse_at_plan_time_naming_both() {
    let f = fixture();
    fs::write(f.project.join("vstack.toml"), MANIFEST).unwrap();
    fs::create_dir_all(f.project.join(".vstack-local")).unwrap();
    fs::create_dir_all(f.project.join(".kendex-local")).unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let error = audit(&f.env, &scope).unwrap_err();
    assert!(
        matches!(error, CoreError::BothGenerations { .. }),
        "{error}"
    );
    let text = error.to_string();
    assert!(
        text.contains(".kendex-local") && text.contains(".vstack-local"),
        "{text}"
    );
}

/// Both spellings of the lock refuse before anything is planned, both
/// paths named.
#[test]
#[allow(clippy::unwrap_used)]
fn both_lock_spellings_refuse_at_plan_time_naming_both() {
    let f = fixture();
    fs::write(f.project.join("vstack.toml"), MANIFEST).unwrap();
    fs::write(f.project.join(".vstack-lock.json"), "{\"version\":4}").unwrap();
    fs::write(f.project.join(".kendex-lock.json"), "{\"version\":4}").unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let error = audit(&f.env, &scope).unwrap_err();
    assert!(
        matches!(error, CoreError::BothGenerations { .. }),
        "{error}"
    );
    let text = error.to_string();
    assert!(
        text.contains(".kendex-lock.json") && text.contains(".vstack-lock.json"),
        "{text}"
    );
}

/// A manifest mutation on an old-name project saves after the rename
/// prefix, into kendex.toml — applying leaves exactly one manifest file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_mutation_on_an_old_name_project_saves_after_the_rename() {
    let f = fixture();
    fs::write(f.project.join("vstack.toml"), MANIFEST).unwrap();
    let catalog = f.home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let report =
        kendex_core::source_ops::add_source(&f.env, &scope, "cat", catalog.to_str().unwrap())
            .unwrap();
    let prefix = kendex_core::rename::rename_prefix_len(&report.plan.ops);
    assert!(prefix >= 1, "{:?}", report.plan.ops);
    let (index, path) = report
        .plan
        .ops
        .iter()
        .enumerate()
        .find_map(|(index, op)| match &op.op {
            kendex_core::apply::Op::WriteManifest { path, .. } => Some((index, path.clone())),
            _ => None,
        })
        .unwrap();
    assert!(index >= prefix, "{:?}", report.plan.ops);
    assert_eq!(path, f.project.join("kendex.toml"));

    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!f.project.join("vstack.toml").exists());
    assert!(
        fs::read_to_string(f.project.join("kendex.toml"))
            .unwrap()
            .contains("[sources.cat]")
    );
}
