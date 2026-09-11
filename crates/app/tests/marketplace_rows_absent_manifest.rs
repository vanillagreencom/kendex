//! A scope with no manifest lists what its first write would create, and
//! only the personal scope's first write carries the default marketplace.
//!
//! The Marketplaces page reads every scope through `rows`. On a fresh
//! machine the personal scope has no manifest yet, and the page must list
//! the default marketplace as subscribed there, since the first write seeds
//! it and a Subscribe would be refused as a duplicate. A project's first
//! write seeds no marketplace, so the cross-scope list carries one default
//! row however many projects have been written — one row per package on
//! the Packages tab. Seed the project too and this file is what goes red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;

use kendex_app::marketplaces::rows;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::{DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO};
use kendex_core::model::Scope;

/// Every row's scope and name, in listing order.
fn listed(env: &Env, scopes: &[Scope]) -> Vec<(Scope, String, Option<String>)> {
    rows(env, scopes)
        .unwrap_or_else(|e| panic!("rows: {e}"))
        .into_iter()
        .map(|row| (row.scope, row.name, row.repo))
        .collect()
}

/// Before anything is written the personal scope already lists the default
/// marketplace and the registered project lists nothing; after the
/// project's first write it lists what it subscribed and the default row
/// is still the personal scope's alone.
#[test]
#[allow(clippy::unwrap_used)]
fn the_default_marketplace_is_one_row_before_and_after_a_projects_first_write() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    let root = home.join("dev").join("app");
    fs::create_dir_all(root.join(".claude")).unwrap();
    let project = Scope::Project { root: root.clone() };
    let env = Env::fake(&home, FakeOs::Linux);
    let scopes = [Scope::Global, project.clone()];
    let default_row = (
        Scope::Global,
        DEFAULT_SOURCE_NAME.to_owned(),
        Some(DEFAULT_SOURCE_REPO.to_owned()),
    );

    assert_eq!(listed(&env, &scopes), vec![default_row.clone()]);

    let report =
        kendex_core::source_ops::add_source(&env, &project, "cat", &catalog.display().to_string())
            .unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    assert!(root.join("kendex.toml").is_file());

    assert_eq!(
        listed(&env, &scopes),
        vec![default_row, (project, "cat".to_owned(), None)]
    );
}
