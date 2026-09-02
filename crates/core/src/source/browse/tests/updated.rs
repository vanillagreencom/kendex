//! When the About tab and the Packages table say a catalog and its
//! packages last changed. The dates are git's, so each package answers for
//! its own commit and a catalog kendex keeps no history for answers with
//! nothing.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, about};
use crate::env::{Env, FakeOs};
use crate::process::Hardened;

use super::repo::git;
use super::test_util::rooted;

const REPO: &str = "owner/dated";

/// A commit whose committer date is fixed, so a test can tell one commit's
/// date from another's inside the same second.
fn commit_at(dir: &Path, message: &str, when: &str) {
    git(dir, &["add", "-A"]);
    let output = Hardened::git(
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "--date",
            when,
            "-m",
            message,
        ],
        Some(dir),
    )
    .env("GIT_COMMITTER_DATE", when)
    .run()
    .unwrap();
    assert!(output.status.success(), "commit {message}");
}

fn write_skill(root: &Path, name: &str) {
    let home = root.join("skills").join(name);
    fs::create_dir_all(&home).unwrap();
    fs::write(
        home.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: does {name} things\n---\nbody\n"),
    )
    .unwrap();
}

/// An upstream repository with two skills committed a year apart.
fn fixture() -> (tempfile::TempDir, Env, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("base").join(REPO);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    write_skill(&upstream, "alpha");
    commit_at(&upstream, "alpha", "2024-03-04T05:06:07+00:00");
    write_skill(&upstream, "beta");
    commit_at(&upstream, "beta", "2025-08-09T10:11:12+00:00");
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    (tmp, env, upstream)
}

fn repo() -> Catalog {
    Catalog::Repo {
        repo: REPO.to_owned(),
    }
}

#[test]
fn the_catalogs_own_date_is_the_newest_commit_that_touched_a_package() {
    let (_tmp, env, _upstream) = fixture();
    let read = about(&env, &repo()).unwrap();
    assert!(
        read.updated_at
            .as_deref()
            .is_some_and(|date| date.starts_with("2025-08-09")),
        "{:?}",
        read.updated_at
    );
}
