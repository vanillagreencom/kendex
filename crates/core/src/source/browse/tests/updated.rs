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
use crate::remote::history;

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

/// A repository can be a catalog and a codebase at once — kendex's own is.
/// The About tab says when the CATALOG last changed, so a commit that
/// touched no package must not move it.
#[test]
fn a_commit_touching_no_package_does_not_move_the_catalogs_date() {
    let (_tmp, env, upstream) = fixture();
    fs::create_dir_all(upstream.join("crates/app")).unwrap();
    fs::write(upstream.join("crates/app/main.rs"), "fn main() {}\n").unwrap();
    commit_at(&upstream, "codebase only", "2026-07-07T07:07:07+00:00");

    let read = about(&env, &repo()).unwrap();
    assert!(
        read.updated_at
            .as_deref()
            .is_some_and(|date| date.starts_with("2025-08-09")),
        "the catalog is dated by its newest package, not the tip: {:?}",
        read.updated_at
    );
}

/// git C-quotes a non-ASCII path under `core.quotePath`, which is on unless
/// the host's gitconfig turns it off. A parsed quoted name matches nothing
/// the walk asked for, so the package loses its date on one machine and
/// keeps it on another.
#[test]
fn a_package_whose_name_is_not_ascii_is_still_dated() {
    let (_tmp, env, upstream) = fixture();
    write_skill(&upstream, "café");
    commit_at(&upstream, "cafe", "2026-02-02T02:02:02+00:00");

    let rows = packages(&env, &repo()).unwrap();
    let dated = rows
        .iter()
        .find(|row| row.name == "café")
        .unwrap_or_else(|| panic!("café is not offered: {:?}", rows.len()));
    assert!(
        dated
            .updated_at
            .as_deref()
            .is_some_and(|date| date.starts_with("2026-02-02")),
        "{:?}",
        dated.updated_at
    );
}

/// The walk's bound is the caller's, and what it costs is stated: a package
/// whose newest commit lies past it has no date at all, never an older
/// commit's.
#[test]
fn a_package_past_the_walks_bound_has_no_date_rather_than_an_older_one() {
    let (_tmp, env, _upstream) = fixture();
    // Browse once so the store holds the repository, then read the same
    // mirror the browse path reads.
    packages(&env, &repo()).unwrap();
    let resolution = crate::remote::cached(&env, REPO, None).unwrap().unwrap();
    let mirror = crate::remote::store::mirror_dir(&env, &crate::remote::cache_key(&env, REPO));
    let paths = [PathBuf::from("skills/alpha"), PathBuf::from("skills/beta")];

    let whole = history::last_changed(&mirror, &resolution.commit, &paths, 5_000).unwrap();
    assert_eq!(whole.dates.len(), 2, "both are reachable without a bound");
    assert!(
        whole
            .newest
            .as_deref()
            .is_some_and(|date| date.starts_with("2025-08-09")),
        "the newest comes from the walk's order: {:?}",
        whole.newest
    );

    let bounded = history::last_changed(&mirror, &resolution.commit, &paths, 1).unwrap();
    assert_eq!(
        bounded.dates.keys().collect::<Vec<_>>(),
        vec![&PathBuf::from("skills/beta")],
        "only the package the one commit touched"
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

/// A repository that is one skill AND carries a `skills/` tree: the root
/// skill strips to the empty path, which as a pathspec matches every path
/// in the repository. It is dated from the repository's tip instead, and
/// never spends the shared walk's bound on commits that touched no package.
#[test]
fn a_root_skill_takes_the_repository_tip_and_its_neighbour_keeps_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("base/owner/rooted");
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    write_skill(&upstream, "helper");
    commit_at(&upstream, "helper", "2024-01-01T00:00:00+00:00");
    fs::write(
        upstream.join("SKILL.md"),
        "---\nname: root\ndescription: lives at the root\n---\nbody\n",
    )
    .unwrap();
    commit_at(&upstream, "root skill", "2026-06-06T06:06:06+00:00");
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let catalog = Catalog::Repo {
        repo: "owner/rooted".to_owned(),
    };

    let rows = packages(&env, &catalog).unwrap();
    let dated = |name: &str| {
        rows.iter()
            .find(|row| row.name == name)
            .unwrap_or_else(|| panic!("{name} is not offered"))
            .updated_at
            .clone()
            .unwrap_or_else(|| panic!("{name} has no date"))
    };
    assert!(dated("root").starts_with("2026-06-06"), "{}", dated("root"));
    assert!(
        dated("helper").starts_with("2024-01-01"),
        "{}",
        dated("helper")
    );
}

/// A repository can carry a root `SKILL.md` beside `skills/` — `discover`
/// adds one whenever the file is there, with no guard requiring the rest of
/// the discovery to be empty — and then be a codebase as well.
///
/// The catalog's date is the newest change to a package with a path of its
/// own. The root item has no such path: the only date anyone could ask for
/// on its behalf is the repository's tip, and letting that speak for the
/// catalog is what would move the About tab's Last updated for a commit
/// under `crates/`. So neither the tip NOR the commit that added the root
/// skill moves this catalog's date — only `skills/helper` does.
#[test]
fn a_mixed_catalog_is_not_dated_by_a_commit_that_touched_no_package() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("base/owner/mixed");
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    write_skill(&upstream, "helper");
    commit_at(&upstream, "helper", "2024-01-01T00:00:00+00:00");
    fs::write(
        upstream.join("SKILL.md"),
        "---\nname: root\ndescription: lives at the root\n---\nbody\n",
    )
    .unwrap();
    commit_at(&upstream, "root skill", "2025-05-05T00:00:00+00:00");
    // Neither package's path; the newest commit in the repository.
    fs::create_dir_all(upstream.join("crates/app")).unwrap();
    fs::write(upstream.join("crates/app/main.rs"), "fn main() {}\n").unwrap();
    commit_at(&upstream, "codebase only", "2026-07-07T07:07:07+00:00");
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let catalog = Catalog::Repo {
        repo: "owner/mixed".to_owned(),
    };

    let read = about(&env, &catalog).unwrap();
    assert!(
        read.updated_at
            .as_deref()
            .is_some_and(|date| date.starts_with("2024-01-01")),
        "the catalog is dated by its newest pathed package, not the tip \
         and not the root item that has no path: {:?}",
        read.updated_at
    );

    // The root item itself still takes the tip: its own tree IS the
    // repository, so the codebase commit really did change it. What the
    // fix stops is that date speaking for the whole catalog.
    let rows = packages(&env, &catalog).unwrap();
    let dated = |name: &str| {
        rows.iter()
            .find(|row| row.name == name)
            .unwrap_or_else(|| panic!("{name} is not offered"))
            .updated_at
            .clone()
            .unwrap_or_else(|| panic!("{name} has no date"))
    };
    assert!(dated("root").starts_with("2026-07-07"), "{}", dated("root"));
    assert!(
        dated("helper").starts_with("2024-01-01"),
        "{}",
        dated("helper")
    );
}

/// The other side of that branch: a catalog that really is just the one
/// root skill. The repository IS the catalog, so its tip is the answer and
/// there is no narrower path to prefer.
#[test]
fn a_catalog_that_is_only_a_root_skill_takes_the_repository_tip() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("base/owner/onlyroot");
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    fs::write(
        upstream.join("SKILL.md"),
        "---\nname: root\ndescription: lives at the root\n---\nbody\n",
    )
    .unwrap();
    commit_at(&upstream, "root skill", "2024-01-01T00:00:00+00:00");
    fs::write(upstream.join("notes.md"), "kept\n").unwrap();
    commit_at(&upstream, "anything at all", "2026-07-07T07:07:07+00:00");
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let catalog = Catalog::Repo {
        repo: "owner/onlyroot".to_owned(),
    };

    let read = about(&env, &catalog).unwrap();
    assert!(
        read.updated_at
            .as_deref()
            .is_some_and(|date| date.starts_with("2026-07-07")),
        "every commit in a one-skill repository changed the skill: {:?}",
        read.updated_at
    );
}
