//! A folder subscription's row carries where the folder is, and the
//! identity core folds that directory to, not only what was typed.
//!
//! The Subscribed grid folds declarations into one card by identity, and a
//! folder's identity is the directory it resolves to: a relative
//! declaration under the place that declares it, an absolute one as
//! written. Which spellings count as absolute is the platform's answer,
//! carried here from core so no surface above re-derives it — ship the
//! spelling in this field and this file is what goes red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::Path;

use kendex_app::marketplaces::rows;
use kendex_core::env::{Env, FakeOs};
use kendex_core::library::{Origin, provenance};
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn project(home: &Path, name: &str, source: &str) -> Scope {
    let root = home.join("dev").join(name);
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = {}\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
            source
        ),
    )
    .unwrap();
    Scope::Project { root }
}

/// A project declaring the catalog beside it as `catalog`, with one skill
/// installed from it.
#[allow(clippy::unwrap_used)]
fn installed_project(env: &Env, home: &Path, name: &str) -> Scope {
    let root = home.join("dev").join(name);
    fs::create_dir_all(root.join("catalog/skills/deploy")).unwrap();
    fs::write(
        root.join("catalog/skills/deploy/SKILL.md"),
        format!("---\nname: deploy\ndescription: ship {name}\n---\nRun the deploy.\n"),
    )
    .unwrap();
    let scope = project(home, name, "path = \"catalog\"");
    let Scope::Project { root } = &scope else {
        unreachable!("the fixture builds a project scope")
    };
    let manifest = root.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        format!("{declared}\n[skills.deploy]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let report =
        kendex_core::engine::plan_apply(env, &scope, &kendex_core::engine::PlanOptions::default())
            .unwrap();
    kendex_core::apply::execute(env, &report.plan).unwrap();
    scope
}

/// Two projects declaring the same relative folder name two directories;
/// a project declaring an absolute path names that one. Both read off the
/// row, both distinct from the spelling.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_row_resolves_its_path_against_the_declaring_place() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let shared = home.join("srv").join("catalog");
    fs::create_dir_all(&shared).unwrap();
    let projects = vec![
        project(&home, "alpha", "path = \"catalog\""),
        project(&home, "beta", "path = \"catalog\""),
        project(&home, "gamma", &source_path(&shared)),
    ];
    let env = Env::fake(&home, FakeOs::Linux);

    let listed = rows(&env, &projects).unwrap();
    // The identity is the resolved directory, never the spelling: a
    // bookmark saved from one project's `catalog` is compared on it.
    let resolved: Vec<(Option<&str>, Option<&str>, Option<&str>)> = listed
        .iter()
        .map(|row| {
            (
                row.path.as_deref(),
                row.resolved_path.as_deref(),
                row.repo_identity.as_deref(),
            )
        })
        .collect();
    let under =
        |name: &str| kendex_core::paths::slashed(&home.join("dev").join(name).join("catalog"));
    let (alpha, beta) = (under("alpha"), under("beta"));
    let shared_slashed = kendex_core::paths::slashed(&shared);
    assert_eq!(
        resolved,
        vec![
            (Some("catalog"), Some(alpha.as_str()), Some(alpha.as_str())),
            (Some("catalog"), Some(beta.as_str()), Some(beta.as_str())),
            (
                Some(shared_slashed.as_str()),
                Some(shared_slashed.as_str()),
                Some(shared_slashed.as_str())
            ),
        ]
    );
}

/// Two projects declaring one alias and one relative spelling for two
/// directories: each project's row names its own directory, its install
/// carries the same string, and the other project's install carries a
/// different one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_subscription_row_joins_only_the_installs_from_its_own_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let alpha = installed_project(&env, &home, "alpha");
    let beta = installed_project(&env, &home, "beta");
    let scopes = [alpha.clone(), beta.clone()];

    let listed = rows(&env, &scopes).unwrap();
    let installed = provenance(&env, &scopes).unwrap();

    let under =
        |name: &str| kendex_core::paths::slashed(&home.join("dev").join(name).join("catalog"));
    let provenances: Vec<(Scope, Option<String>)> = listed
        .iter()
        .map(|row| (row.scope.clone(), row.provenance.clone()))
        .collect();
    assert_eq!(
        provenances,
        vec![
            (alpha.canonical(), Some(under("alpha"))),
            (beta.canonical(), Some(under("beta"))),
        ],
        "one identity per directory, never the shared spelling"
    );
    let origins: Vec<(Scope, Origin)> = installed
        .iter()
        .filter(|row| row.name == "deploy")
        .map(|row| (row.scope.clone(), row.origin.clone()))
        .collect();
    let from = |name: &str| Origin::Marketplace {
        source: "cat".to_owned(),
        repo: under(name),
    };
    assert!(
        !origins.is_empty()
            && origins.iter().all(|(scope, origin)| {
                origin
                    == &from(if scope == &alpha.canonical() {
                        "alpha"
                    } else {
                        "beta"
                    })
            }),
        "every install carries its own project's identity: {origins:?}"
    );
}
