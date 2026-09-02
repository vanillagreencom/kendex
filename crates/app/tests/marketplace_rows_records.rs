//! A subscription row answers for its own scope's records.
//!
//! The Packages tab's trouble line and its Problems link hang on one field:
//! `MarketplaceRow::records_unreadable`, filled per scope as the rows are
//! built. Nothing above it can tell a scope whose lock this build refuses
//! from one it reads, so the join is asserted here — hardcode the field
//! false and this file is what goes red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_app::marketplaces::rows;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    projects: Vec<Scope>,
}

/// A project subscribed to a local catalog offering one skill, with no lock
/// on disk yet — the records read answers "readable" for an absent lock the
/// same way it does for a fresh install.
#[allow(clippy::unwrap_used)]
fn fixture(names: &[&str]) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    let mut projects = Vec::new();
    for name in names {
        let root = home.join("dev").join(name);
        fs::create_dir_all(root.join(".claude")).unwrap();
        fs::write(
            root.join("kendex.toml"),
            format!(
                "schema = {}\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
                kendex_core::manifest::MANIFEST_SCHEMA,
                source_path(&catalog),
            ),
        )
        .unwrap();
        projects.push(Scope::Project { root });
    }
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        projects,
        _tmp: tmp,
    }
}

/// Where a scope's lock lives on disk.
#[allow(clippy::unwrap_used)]
fn lock_of(scope: &Scope) -> PathBuf {
    match scope {
        Scope::Project { root } => root.join(".kendex-lock.json"),
        other => panic!("the fixture only builds project scopes: {other:?}"),
    }
}

/// A lock an older kendex wrote is refused, and the project beside it keeps
/// its own answer: the flag is the scope's, not the query's. Hardcoding the
/// field either way reddens this — it asserts both answers from one read.
#[test]
#[allow(clippy::unwrap_used)]
fn each_scope_answers_for_its_own_records() {
    let f = fixture(&["broken", "fine"]);
    fs::write(lock_of(&f.projects[0]), r#"{"version":1,"entries":{}}"#).unwrap();

    let listed = rows(&f.env, &f.projects).unwrap();
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert_eq!(
        listed
            .iter()
            .map(|row| (row.scope.clone(), row.records_unreadable))
            .collect::<Vec<_>>(),
        vec![
            (f.projects[0].clone(), true),
            (f.projects[1].clone(), false),
        ]
    );
}
