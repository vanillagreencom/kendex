//! Subscribing a scope to a marketplace: reference parsing wired end to
//! end, one repository per scope, tree-URL normalization against real
//! refs, the subscribe-into-project op mutating exactly one scope, and
//! the default marketplace found by repo rather than by name.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest::{DEFAULT_SOURCE_REPO, LEGACY_SOURCE_REPO};
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
fn fixture() -> (tempfile::TempDir, Env, Scope, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    (tmp, env, scope, project)
}

/// The pre-fix heuristic read every URL as a folder path; a full remote
/// URL must declare a repository.
#[test]
#[allow(clippy::unwrap_used)]
fn a_full_url_reference_declares_a_remote_not_a_path() {
    let (_tmp, env, scope, project) = fixture();
    let report = source_ops::add_source(
        &env,
        &scope,
        "cat",
        "https://gitlab.example.com/team/catalog.git",
    )
    .unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(
        manifest.contains("repo = \"https://gitlab.example.com/team/catalog.git\""),
        "{manifest}"
    );
    assert!(!manifest.contains("path = \"https://"), "{manifest}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_skills_sh_url_subscribes_the_repo_and_names_the_package_lead() {
    let (_tmp, env, scope, project) = fixture();
    let subscribed = source_ops::subscribe(
        &env,
        &scope,
        "https://skills.sh/vercel-labs/agent-skills/react-best-practices",
        None,
    )
    .unwrap();
    assert_eq!(subscribed.reference, "vercel-labs/agent-skills");
    assert_eq!(subscribed.lead.as_deref(), Some("react-best-practices"));
    assert_eq!(subscribed.name, "agent-skills");
    apply::execute(&env, &subscribed.report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(
        manifest.contains("repo = \"vercel-labs/agent-skills\""),
        "{manifest}"
    );
}

/// A tree URL subscribes the whole repository, resolves its ref against
/// the mirror's real refs (branch names contain `/`), and surfaces the
/// package path for opening afterwards.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tree_url_subscribes_the_whole_repo_and_surfaces_the_path() {
    let (_tmp, env, scope, project) = fixture();
    let dir = upstream(env.home.as_path(), "o/r");
    git(&dir, &["branch", "feat/x"]);

    let subscribed = source_ops::subscribe(
        &env,
        &scope,
        "https://github.com/o/r/tree/feat/x/skills/gh",
        None,
    )
    .unwrap();
    assert_eq!(subscribed.reference, "o/r");
    assert_eq!(subscribed.rev.as_deref(), Some("feat/x"));
    assert_eq!(subscribed.lead.as_deref(), Some("skills/gh"));
    assert!(
        subscribed
            .report
            .notes
            .iter()
            .any(|note| note.starts_with("Subscribes")
                && note.contains("o/r @ feat/x")
                && note.contains("kendex.toml")),
        "{:?}",
        subscribed.report.notes
    );
    apply::execute(&env, &subscribed.report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("repo = \"o/r\""), "{manifest}");
    assert!(manifest.contains("rev = \"feat/x\""), "{manifest}");
}

/// Two valid split points are never guessed between — the refusal names
/// both, and nothing is written.
#[test]
#[allow(clippy::unwrap_used)]
fn an_ambiguous_tree_ref_is_refused_naming_both_and_writes_nothing() {
    let (_tmp, env, scope, project) = fixture();
    let dir = upstream(env.home.as_path(), "o/r");
    git(&dir, &["branch", "a/b"]);
    git(&dir, &["tag", "a"]);

    let error =
        source_ops::subscribe(&env, &scope, "https://github.com/o/r/tree/a/b", None).unwrap_err();
    let text = error.to_string();
    assert!(text.contains("branch 'a/b'"), "{text}");
    assert!(text.contains("tag 'a'"), "{text}");
    assert!(!project.join("kendex.toml").exists());
}

/// Offline, a tree URL cannot be normalized; the refusal lands before any
/// write instead of a guessed split landing in the manifest.
#[test]
#[allow(clippy::unwrap_used)]
fn an_offline_tree_url_is_refused_before_any_write() {
    let (_tmp, env, scope, project) = fixture();
    let existing = "schema = 5\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n";
    fs::write(project.join("kendex.toml"), existing).unwrap();

    let error = source_ops::subscribe(
        &env,
        &scope,
        "https://github.com/gone/away/tree/main/skills",
        None,
    )
    .unwrap_err();
    assert!(!error.to_string().is_empty());
    assert_eq!(
        fs::read_to_string(project.join("kendex.toml")).unwrap(),
        existing,
        "a refused subscribe must leave the manifest byte-identical"
    );
}

/// One repository per scope, whatever the spelling: `.git`, case, and URL
/// forms are one repo, and the refusal names the existing subscription.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repo_already_subscribed_under_another_alias_is_refused_naming_it() {
    let (_tmp, env, scope, project) = fixture();
    let report = source_ops::add_source(&env, &scope, "first", "o/r").unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let before = fs::read_to_string(project.join("kendex.toml")).unwrap();

    for spelling in [
        "o/r",
        "https://github.com/o/r.git",
        "https://www.github.com/O/R/",
        "git@github.com:o/r.git",
    ] {
        let error = source_ops::subscribe(&env, &scope, spelling, Some("second")).unwrap_err();
        match error {
            CoreError::DuplicateSourceRepo { name, .. } => assert_eq!(name, "first", "{spelling}"),
            other => panic!("{spelling}: expected a duplicate refusal, got {other}"),
        }
    }
    assert_eq!(
        fs::read_to_string(project.join("kendex.toml")).unwrap(),
        before
    );
}

/// §4.1: installing into a project from a personal subscription adds the
/// subscription to the project — exactly one scope mutated, the personal
/// manifest read-only, and the preview naming scope, manifest path, and
/// the source's alias, repo, and revision.
#[test]
#[allow(clippy::unwrap_used)]
fn subscribing_a_project_from_a_personal_subscription_mutates_only_the_project() {
    let (_tmp, env, _scope, project) = fixture();
    let report = source_ops::subscribe(&env, &Scope::Global, "team/tools@v2", Some("mkt"))
        .unwrap()
        .report;
    apply::execute(&env, &report.plan, None).unwrap();
    let personal_path = kendex_core::manifest::manifest_path(&env, &Scope::Global);
    let personal_before = fs::read(&personal_path).unwrap();

    let report = source_ops::subscribe_project_to(&env, &project, "mkt").unwrap();
    let line = report
        .plan
        .ops
        .iter()
        .map(|op| op.description.as_str())
        .find(|description| description.starts_with("Subscribes"))
        .unwrap()
        .to_owned();
    assert!(line.contains(&project.display().to_string()), "{line}");
    assert!(line.contains("'mkt'"), "{line}");
    assert!(line.contains("team/tools @ v2"), "{line}");
    assert!(line.contains("kendex.toml"), "{line}");
    apply::execute(&env, &report.plan, None).unwrap();

    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[sources.mkt]"), "{manifest}");
    assert!(manifest.contains("repo = \"team/tools\""), "{manifest}");
    assert!(manifest.contains("rev = \"v2\""), "{manifest}");
    assert_eq!(
        fs::read(&personal_path).unwrap(),
        personal_before,
        "the personal manifest is read-only input"
    );
}

fn add_gh(
    env: &Env,
    scope: &Scope,
) -> kendex_core::error::Result<kendex_core::engine::EngineReport> {
    ops::add(
        env,
        scope,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
}

/// `--all` with no source named is the one add that still needs a default
/// marketplace — a bare item name searches instead.
fn add_all(
    env: &Env,
    scope: &Scope,
) -> kendex_core::error::Result<kendex_core::engine::EngineReport> {
    ops::add(
        env,
        scope,
        &ops::AddRequest {
            all: true,
            ..ops::AddRequest::default()
        },
    )
}

/// The default marketplace is the subscription whose repo is the default
/// repo — an alias named anything, found by repository.
#[test]
#[allow(clippy::unwrap_used)]
fn a_default_add_lands_on_the_subscription_with_the_default_repo() {
    let (_tmp, env, scope, project) = fixture();
    upstream(env.home.as_path(), DEFAULT_SOURCE_REPO);
    remote::sync(&env, DEFAULT_SOURCE_REPO, None).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.market]\nrepo = \"{DEFAULT_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n"
        ),
    )
    .unwrap();

    let report = add_gh(&env, &scope).unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.gh]"), "{manifest}");
    assert!(manifest.contains("source = \"market\""), "{manifest}");
}

/// The migration can leave one repository subscribed twice; the seeded
/// name wins the tie. A bare item name would search both and refuse the
/// duplicate, so the tie-break is exercised through `--all`.
#[test]
#[allow(clippy::unwrap_used)]
fn two_default_repo_subscriptions_prefer_the_seeded_name() {
    let (_tmp, env, scope, project) = fixture();
    upstream(env.home.as_path(), DEFAULT_SOURCE_REPO);
    remote::sync(&env, DEFAULT_SOURCE_REPO, None).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.kendex]\nrepo = \"{DEFAULT_SOURCE_REPO}\"\n\n[sources.vstack]\nrepo = \"{LEGACY_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n"
        ),
    )
    .unwrap();

    let report = add_all(&env, &scope).unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("source = \"kendex\""), "{manifest}");
}

/// Neither of the two carries the seeded name: refused naming both,
/// never whichever sorts first.
#[test]
#[allow(clippy::unwrap_used)]
fn two_default_repo_subscriptions_neither_seeded_refuse_naming_both() {
    let (_tmp, env, scope, project) = fixture();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.alpha]\nrepo = \"{DEFAULT_SOURCE_REPO}\"\n\n[sources.beta]\nrepo = \"{LEGACY_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n"
        ),
    )
    .unwrap();

    let error = add_all(&env, &scope).unwrap_err();
    match error {
        CoreError::DefaultSourceAmbiguous { names, .. } => {
            assert_eq!(names, vec!["alpha".to_owned(), "beta".to_owned()]);
        }
        other => panic!("expected the ambiguity refusal, got {other}"),
    }
}

/// With nothing subscribed to the default repo there is no fallback at
/// all: `--all` with no source named refuses rather than guessing the one
/// subscription that happens to exist. A bare item name searches instead.
#[test]
#[allow(clippy::unwrap_used)]
fn no_default_subscription_is_a_typed_error_never_a_guess() {
    let (_tmp, env, scope, project) = fixture();
    let other = env.home.join("other");
    fs::create_dir_all(other.join("skills/gh")).unwrap();
    fs::write(other.join("skills/gh/SKILL.md"), "---\nname: gh\n---\nx\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.other]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            other.display()
        ),
    )
    .unwrap();

    let error = add_all(&env, &scope).unwrap_err();
    assert!(
        matches!(error, CoreError::NoDefaultSource { .. }),
        "expected the typed no-default error, got {error}"
    );

    // The same scope's bare name finds its one subscription by searching —
    // no default needed, no download, no guess.
    let report = add_gh(&env, &scope).unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("source = \"other\""), "{manifest}");
}
