//! When the About tab and the Packages table say a catalog and its
//! packages last changed. The dates are git's, so each package answers for
//! its own commit and a catalog kendex keeps no history for answers with
//! nothing.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, about, packages};
use crate::env::{Env, FakeOs};
use crate::model::Scope;
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
fn every_package_answers_with_its_own_commit_not_the_catalog_tip() {
    let (_tmp, env, _upstream) = fixture();
    let rows = packages(&env, &repo()).unwrap();
    let dated = |name: &str| {
        rows.iter()
            .find(|row| row.name == name)
            .unwrap()
            .updated_at
            .clone()
            .unwrap_or_else(|| panic!("{name} has no date"))
    };
    assert!(
        dated("alpha").starts_with("2024-03-04"),
        "alpha: {}",
        dated("alpha")
    );
    assert!(
        dated("beta").starts_with("2025-08-09"),
        "beta: {}",
        dated("beta")
    );
}

#[test]
fn the_catalogs_own_date_is_the_commit_it_is_read_at() {
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

#[test]
fn a_catalog_kendex_keeps_no_history_for_has_no_dates() {
    let (_tmp, env, upstream) = fixture();
    // The same content declared as a directory on disk: nothing fetched
    // it, so there is no mirror to read a date out of and the columns are
    // empty rather than dated from this machine's clock.
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n[sources.here]\npath = \"{}\"\n",
            crate::paths::slashed(&upstream)
        ),
    )
    .unwrap();
    let catalog = Catalog::Subscription {
        scope: Scope::Global,
        source: "here".to_owned(),
    };

    let rows = packages(&env, &catalog).unwrap();
    assert_eq!(rows.len(), 2, "the packages still list");
    assert!(
        rows.iter().all(|row| row.updated_at.is_none()),
        "{:?}",
        rows.iter().map(|row| &row.updated_at).collect::<Vec<_>>()
    );
    assert_eq!(about(&env, &catalog).unwrap().updated_at, None);
}
