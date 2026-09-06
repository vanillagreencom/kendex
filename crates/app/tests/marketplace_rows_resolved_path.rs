//! A folder subscription's row carries where the folder is, not only what
//! was typed.
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
    let resolved: Vec<(Option<&str>, Option<&str>)> = listed
        .iter()
        .map(|row| (row.path.as_deref(), row.resolved_path.as_deref()))
        .collect();
    let under =
        |name: &str| kendex_core::paths::slashed(&home.join("dev").join(name).join("catalog"));
    let shared_slashed = kendex_core::paths::slashed(&shared);
    assert_eq!(
        resolved,
        vec![
            (Some("catalog"), Some(under("alpha").as_str())),
            (Some("catalog"), Some(under("beta").as_str())),
            (Some(shared_slashed.as_str()), Some(shared_slashed.as_str())),
        ]
    );
}
