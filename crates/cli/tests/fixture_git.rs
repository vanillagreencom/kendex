//! Git discovery stays inside fixtures even when their allocator is in Git.

use std::fs;
use std::process::Command;

use crate::test_util::{fixture_env, git, rooted};

#[test]
#[allow(
    clippy::unwrap_used,
    reason = "fixture setup and Git launch must succeed"
)]
fn discovery_rejects_the_ancestor_and_keeps_the_fixture_repository() {
    let tmp = tempfile::tempdir().unwrap();
    let ancestor = rooted(&tmp);
    git(&ancestor, &["init", "--quiet"]);
    let allocation = ancestor.join("temporary allocations");
    fs::create_dir(&allocation).unwrap();

    for (name, repository) in [("plain", None), ("owned", Some("project"))] {
        let fixture = tempfile::tempdir_in(&allocation).unwrap();
        let home = rooted(&fixture);
        let project = home.join("project");
        let cwd = project.join("nested");
        fs::create_dir_all(&cwd).unwrap();
        if repository.is_some() {
            git(&project, &["init", "--quiet"]);
        }
        let output = Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .current_dir(&cwd)
            .env_clear()
            .envs(fixture_env(&home))
            .env("PATH", std::env::var_os("PATH").unwrap())
            .output()
            .unwrap();
        match repository {
            None => assert_eq!(output.status.code(), Some(128), "{name}: {output:?}"),
            Some(relative) => {
                assert!(output.status.success(), "{name}: {output:?}");
                let found =
                    std::path::PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
                assert_eq!(
                    kendex_core::paths::canonical(&found).unwrap(),
                    home.join(relative),
                    "{name}"
                );
            }
        }
    }
}
