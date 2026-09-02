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
