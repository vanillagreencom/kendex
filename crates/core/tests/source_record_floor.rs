//! A refresh reads a declaration no older than the commit the scope's
//! record already names for it. A run that selects an older revision, a
//! release's catalog revision over a record a main build wrote, keeps that
//! record, and the check that holds the head's record to the base's passes.
#![cfg(unix)]

use crate::test_util::{git, rooted};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::attest::{self, Reading};
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{Lock, load as load_lock, lock_path};
use kendex_core::manifest::DEFAULT_SOURCE_REPO;
use kendex_core::model::Scope;
use kendex_core::remote;

/// The default catalog's history: `v9`, the release a release build
/// selects, and one commit on `main` past it, which a main build reads.
struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    root: PathBuf,
    scope: Scope,
    release: String,
    main: String,
}

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, body: &str) {
    let dir = catalog.join("skills/deploy");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: deploy\ndescription: ship it\n---\n{body}\n"),
    )
    .unwrap();
}

fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "--quiet", "-m", message]);
    git(dir, &["rev-parse", "HEAD"]).trim().to_owned()
}

/// A project on `main` declaring one skill from the default catalog,
/// refreshed by a main build and committed: its base record names `main`.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("git").join(DEFAULT_SOURCE_REPO);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    skill(&upstream, "As released.");
    let release = commit(&upstream, "release");
    git(&upstream, &["tag", "v9"]);
    skill(&upstream, "As on main.");
    let main = commit(&upstream, "past the release");

    let root = home.join("app");
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = 7\n\n[sources.kendex]\nrepo = \"{DEFAULT_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"kendex\"\n"
        ),
    )
    .unwrap();
    git(&root, &["init", "--quiet", "-b", "main"]);
    let env = Env::fake(&home, FakeOs::Linux).with_var(
        "KENDEX_GIT_BASE",
        &format!("file://{}", home.join("git").display()),
    );
    let world = World {
        scope: Scope::Project { root: root.clone() },
        env,
        root,
        release,
        main,
        _tmp: tmp,
    };
    refresh(&world.env, &world.scope);
    assert_eq!(record(&world).sources["kendex"].commit, world.main);
    commit(&world.root, "main build refresh");
    world
}

/// What `kendex refresh` does to one scope: sync the declared sources,
/// plan every catalog at its current revision, and apply.
#[allow(clippy::unwrap_used)]
fn refresh(env: &Env, scope: &Scope) {
    let manifest = kendex_core::engine::ops::manifest_for_reading(env, scope).unwrap();
    let synced = remote::sync_declared_sources(env, &manifest);
    assert!(synced.failures.is_empty(), "{:?}", synced.failures);
    let options = PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::current()
    };
    let report = plan_apply(env, scope, &options).unwrap();
    apply::execute(env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn record(world: &World) -> Lock {
    load_lock(&lock_path(&world.env, &world.scope)).unwrap()
}

/// What `verify --at-record --base HEAD` holds the record to: the
/// record's own standing, with the base revision's record as the floor.
#[allow(clippy::unwrap_used)]
fn base_check(env: &Env, world: &World) -> Vec<String> {
    let report = plan_apply(env, &world.scope, &Reading::Recorded.plan_options()).unwrap();
    let floor = attest::floor_at(&world.root, "HEAD");
    attest::record(env, &world.scope, &record(world), &report, &floor)
        .unwrap()
        .unwrap()
        .problems
}

/// Every commit the record names for the default catalog: the source's
/// and each entry's.
fn recorded_commits(lock: &Lock) -> Vec<Option<String>> {
    std::iter::once(Some(lock.sources["kendex"].commit.clone()))
        .chain(
            lock.entries
                .values()
                .map(|entry| entry.source_commit.clone()),
        )
        .collect()
}

/// A release refresh over a record a main build wrote keeps the main
/// commit for the source and every entry, and the base check passes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_release_refresh_keeps_the_newer_record_a_main_build_wrote() {
    let _diagnostic = crate::diagnostic::Span::begin(concat!(
        module_path!(),
        "::a_release_refresh_keeps_the_newer_record_a_main_build_wrote"
    ));
    let world = world();
    let release_env = world.env.clone().with_var("KENDEX_CATALOG_REV", "v9");
    assert_eq!(
        remote::mirror_commit(&release_env, DEFAULT_SOURCE_REPO, None),
        Some(world.release.clone()),
        "the release run selects the older commit"
    );

    refresh(&release_env, &world.scope);

    let lock = record(&world);
    assert!(!lock.entries.is_empty());
    for commit in recorded_commits(&lock) {
        assert_eq!(commit.as_deref(), Some(world.main.as_str()));
    }
    assert_eq!(base_check(&release_env, &world), Vec::<String>::new());
}

/// The control: with no record and no renders in the worktree, the release
/// refresh installs at the release commit, and the same base check refuses
/// a commit that moved behind the base record's.
#[test]
#[allow(clippy::unwrap_used)]
fn without_the_newer_record_the_release_write_is_refused_by_the_base_check() {
    let _diagnostic = crate::diagnostic::Span::begin(concat!(
        module_path!(),
        "::without_the_newer_record_the_release_write_is_refused_by_the_base_check"
    ));
    let world = world();
    let release_env = world.env.clone().with_var("KENDEX_CATALOG_REV", "v9");
    fs::remove_file(lock_path(&world.env, &world.scope)).unwrap();
    fs::remove_dir_all(world.root.join(".claude/skills")).unwrap();

    refresh(&release_env, &world.scope);

    let lock = record(&world);
    for commit in recorded_commits(&lock) {
        assert_eq!(commit.as_deref(), Some(world.release.as_str()));
    }
    let problems = base_check(&release_env, &world);
    assert!(
        problems
            .iter()
            .any(|problem| problem.contains(&world.release) && problem.contains(&world.main)),
        "{problems:?}"
    );
}
