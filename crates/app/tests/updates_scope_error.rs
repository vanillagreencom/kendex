//! One project's unreadable record must not blank the whole Updates read.
//!
//! `overview` folds every registered scope's standing together. Bubbling a
//! scope's failure out of that fold left the page with a generic error and
//! the sidebar with a bare "?" on a machine where every other project's
//! standing was known. The scope is carried as data instead, named, so both
//! surfaces can say which project and send the reader to Problems.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::PathBuf;

use kendex_app::update_check::overview;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    project: Scope,
    lock_path: PathBuf,
}

/// A project tracked by kendex, with a manifest this build reads and no
/// lock on disk yet.
#[allow(clippy::unwrap_used)]
fn fixture(name: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("dev").join(name);
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = {}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA
        ),
    )
    .unwrap();
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        project: Scope::Project { root: root.clone() },
        lock_path: root.join(".kendex-lock.json"),
        _tmp: tmp,
    }
}

/// The control: a project kendex can read contributes no unreadable entry.
#[test]
#[allow(clippy::unwrap_used)]
fn a_readable_project_reports_nothing_unreadable() {
    let f = fixture("app");
    let report = overview(&f.env, &[Scope::Global, f.project.clone()]);
    assert!(report.unreadable.is_empty());
}

/// A lock an older kendex wrote, alongside the personal scope. The personal
/// scope's standing still lands; the project is named with the reason the
/// engine gave, which is what the page shows instead of a bare "?".
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_project_is_named_and_leaves_the_other_scopes_alone() {
    let f = fixture("app");
    fs::write(&f.lock_path, r#"{"version":1,"entries":{}}"#).unwrap();

    let report = overview(&f.env, &[Scope::Global, f.project.clone()]);
    assert_eq!(report.unreadable.len(), 1, "{:?}", report.unreadable);
    let named = &report.unreadable[0];
    assert_eq!(named.scope, f.project);
    assert!(
        named.message.contains("version 1 record"),
        "the reason travels with the scope: {}",
        named.message
    );
}

/// The personal scope has a lock of its own, and `updates_overview` folds
/// it through `all_scopes` alongside every project. A build that refuses it
/// lands the global scope here, which is why the surfaces drawing this list
/// name places rather than projects — "Personal" is not one.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_personal_lock_is_carried_the_same_way() {
    let f = fixture("app");
    let manifest = kendex_core::manifest::manifest_path(&f.env, &Scope::Global);
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = {}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA
        ),
    )
    .unwrap();
    let personal = kendex_core::lock::lock_path(&f.env, &Scope::Global);
    fs::create_dir_all(personal.parent().unwrap()).unwrap();
    fs::write(&personal, r#"{"version":1,"entries":{}}"#).unwrap();

    let report = overview(&f.env, &[Scope::Global, f.project.clone()]);
    assert_eq!(
        report
            .unreadable
            .iter()
            .map(|place| place.scope.clone())
            .collect::<Vec<_>>(),
        vec![Scope::Global],
        "the project reads fine; only the personal scope is named"
    );
}

/// Damaged bytes take the same route, and a second readable project's
/// standing is untouched by the first one's failure.
#[test]
#[allow(clippy::unwrap_used)]
fn only_the_failing_scope_is_listed() {
    let broken = fixture("broken");
    fs::write(&broken.lock_path, "{not json").unwrap();
    let healthy = fixture("fine");

    let report = overview(&broken.env, &[broken.project.clone(), healthy.project]);
    assert_eq!(
        report
            .unreadable
            .iter()
            .map(|place| place.scope.clone())
            .collect::<Vec<_>>(),
        std::slice::from_ref(&broken.project)
    );
}
