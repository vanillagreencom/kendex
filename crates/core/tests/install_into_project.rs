//! Installing into a project from a personal subscription is one plan with its
//! subscription: a refused install leaves the project subscribed to nothing.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use kendex_core::{apply, remote, source_ops};

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    // The caller's git environment is dropped: run from a commit hook,
    // GIT_DIR and friends point at the repository being committed to and
    // every command here would act on that one instead of this fixture.
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A git upstream under `<home>/base/<owner>/<repo>` holding one skill,
/// reachable through `KENDEX_GIT_BASE`.
#[allow(clippy::unwrap_used)]
fn upstream(home: &Path, repo: &str) -> PathBuf {
    let dir = home.join("base").join(repo);
    fs::create_dir_all(dir.join("skills/gh")).unwrap();
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    git(&dir, &["init", "--quiet", "-b", "main"]);
    git(&dir, &["add", "-A"]);
    git(&dir, &["commit", "--quiet", "-m", "one"]);
    dir
}

#[allow(clippy::unwrap_used)]
fn fixture() -> (tempfile::TempDir, Env, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    (tmp, env, project)
}

/// A refused install (a package the catalog does not offer) writes nothing;
/// the same call with a real package writes the subscription and the package
/// together.
#[test]
#[allow(clippy::unwrap_used)]
fn installing_into_a_project_is_atomic_with_its_subscription() {
    let (_tmp, env, project) = fixture();
    upstream(env.home.as_path(), "team/tools");
    let report = source_ops::subscribe(&env, &Scope::Global, "team/tools", Some("mkt"))
        .unwrap()
        .report;
    apply::execute(&env, &report.plan).unwrap();
    remote::sync(&env, "team/tools", None).unwrap();
    let project_path = project.join("kendex.toml");

    let refused = source_ops::install_project_from_personal(
        &env,
        &project,
        "mkt",
        &ops::AddRequest {
            skills: vec!["nope".into()],
            ..ops::AddRequest::default()
        },
    );
    assert!(refused.is_err(), "a missing package must be refused");
    assert!(
        !project_path.exists() || !fs::read_to_string(&project_path).unwrap().contains("mkt"),
        "the project must not be left subscribed to a marketplace it installed nothing from"
    );

    let report = source_ops::install_project_from_personal(
        &env,
        &project,
        "mkt",
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap();
    apply::execute(&env, &report.plan).unwrap();
    let manifest = fs::read_to_string(&project_path).unwrap();
    assert!(manifest.contains("[sources.mkt]"), "{manifest}");
    assert!(manifest.contains("[skills.gh]"), "{manifest}");
}
