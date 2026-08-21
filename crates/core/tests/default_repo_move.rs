//! The default catalog moved repositories (vanillagreencom/vstack →
//! vanillagreencom/kendex). A scope still naming the old repository gets
//! one migration write per file — manifest and lock — the first time it is
//! planned, never a per-package conflict; and what the old spelling
//! fetched keeps serving the scope offline.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::engine::{DriftState, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{Lock, LockEntry, Reason, SourceRev};
use kendex_core::manifest::{LEGACY_SOURCE_REPO, Method};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::repo_move::MOVE_DESCRIPTION;
use kendex_core::{apply, remote};

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

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    /// The commit the old-spelling upstream served before it went away.
    commit: String,
}

/// A scope installed entirely before the repository move: the manifest, the
/// lock, and the source cache all carry the old repo spelling — and the
/// upstream is gone, so everything after setup runs offline.
#[allow(clippy::unwrap_used)]
fn pre_move_fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let upstream = home.join("base").join(LEGACY_SOURCE_REPO);
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "-A"]);
    git(&upstream, &["commit", "--quiet", "-m", "one"]);
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    // Seed the cache exactly as a pre-move version left it: mirror and
    // checkout under the old spelling's own key. Today's resolvers derive
    // one key for both spellings, so they could never write this state.
    let url = remote::clone_url(&env, LEGACY_SOURCE_REPO);
    let old_key = remote::store::repo_key(&url);
    let mirror = remote::store::mirror_dir(&env, &old_key);
    remote::store::ensure_mirror(&mirror, &url).unwrap();
    let commit = remote::store::resolve_ref(&mirror, "HEAD").unwrap();
    remote::store::publish(&env, &old_key, &mirror, &commit).unwrap();
    fs::remove_dir_all(home.join("base")).unwrap();

    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.vstack]\nrepo = \"{LEGACY_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"vstack\"\n\n[forks.skill.zed]\nsource = \"vstack\"\nrepo = \"{LEGACY_SOURCE_REPO}\"\nforked-at = \"2026-01-01T00:00:00Z\"\n"
        ),
    )
    .unwrap();
    let lock = Lock {
        version: kendex_core::lock::LOCK_VERSION,
        entries: [(
            "skill:gh:claude".to_owned(),
            LockEntry {
                name: "gh".to_owned(),
                kind: ItemKind::Skill,
                harness: HarnessId::Claude,
                source: "vstack".to_owned(),
                source_repo: LEGACY_SOURCE_REPO.to_owned(),
                method: Method::Symlink,
                installed_at: "2026-01-01T00:00:00Z".to_owned(),
                source_hash: "pre-move".to_owned(),
                source_commit: Some(commit.clone()),
                rendered_hash: None,
                enabled: true,
                upstream_skills: None,
                emitted: None,
                registration: None,
                reasons: BTreeSet::from([Reason::Requested]),
                author_review: None,
            },
        )]
        .into(),
        sources: [(
            "vstack".to_owned(),
            SourceRev {
                repo: LEGACY_SOURCE_REPO.to_owned(),
                rev: None,
                commit: commit.clone(),
            },
        )]
        .into(),
        ..Lock::default()
    };
    kendex_core::lock::save(&project.join(".kendex-lock.json"), &lock).unwrap();
    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        commit,
        _tmp: tmp,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pre_move_scope_gets_one_migration_write_per_file_and_no_conflicts() {
    let f = pre_move_fixture();

    let report = audit(&f.env, &f.scope).unwrap();
    let conflicts: Vec<_> = report
        .drift
        .iter()
        .filter(|row| row.state == DriftState::Conflict)
        .collect();
    assert!(conflicts.is_empty(), "{conflicts:?}");
    let moves = report
        .plan
        .ops
        .iter()
        .filter(|op| op.description == MOVE_DESCRIPTION)
        .count();
    assert_eq!(moves, 1, "{:?}", report.plan.ops);

    apply::execute(&f.env, &report.plan, None).unwrap();

    let manifest = fs::read_to_string(f.project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains(LEGACY_SOURCE_REPO), "{manifest}");
    // The source keeps its declared name; only the repository moves — the
    // fork's provenance included.
    assert!(manifest.contains("[sources.vstack]"), "{manifest}");
    assert!(manifest.contains("vanillagreencom/kendex"), "{manifest}");
    assert!(manifest.contains("[forks.skill.zed]"), "{manifest}");
    let lock = fs::read_to_string(f.project.join(".kendex-lock.json")).unwrap();
    assert!(!lock.contains(LEGACY_SOURCE_REPO), "{lock}");
    assert!(lock.contains("vanillagreencom/kendex"), "{lock}");
    // The install itself converged offline: the old spelling's cache
    // served the moved repository's content.
    assert!(f.project.join(".claude/skills/gh").is_symlink());
    assert!(lock.contains(&f.commit), "{lock}");

    let after = audit(&f.env, &f.scope).unwrap();
    assert!(after.drift.is_empty(), "{:?}", after.drift);
    assert!(
        after.plan.ops.is_empty(),
        "{:?}",
        after
            .plan
            .ops
            .iter()
            .map(|op| &op.description)
            .collect::<Vec<_>>()
    );
}

/// Planning migrates in memory and resolves the new spelling, which adopts
/// the old spelling's cache — but nothing has been applied, so the
/// manifest on disk still says the old repository. Every surface reading
/// that manifest must find the adopted cache, offline: both spellings
/// derive one cache key.
#[test]
#[allow(clippy::unwrap_used)]
fn the_old_spelling_resolves_from_the_adopted_cache() {
    let f = pre_move_fixture();
    audit(&f.env, &f.scope).unwrap();

    let resolution = remote::cached(&f.env, LEGACY_SOURCE_REPO, None).unwrap();
    assert_eq!(resolution.map(|r| r.commit), Some(f.commit.clone()));

    let kendex_core::manifest::ManifestFile::Current(manifest) =
        kendex_core::manifest::load(&kendex_core::manifest::manifest_path(&f.env, &f.scope))
            .unwrap()
    else {
        panic!("the on-disk manifest should still parse");
    };
    let state = kendex_core::source::resolve(&f.env, &f.scope, "vstack", &manifest).unwrap();
    let kendex_core::source::SourceState::Ready(ready) = state else {
        panic!("the old spelling must read the adopted cache, got {state:?}");
    };
    assert_eq!(ready.commit.as_deref(), Some(f.commit.as_str()));
}

/// The migration write is the intended edit and nothing else: a manifest
/// full of comments and hand formatting keeps every byte except the repo
/// strings that moved.
#[test]
#[allow(clippy::unwrap_used)]
fn the_migration_write_keeps_every_byte_except_the_repo_strings() {
    let f = pre_move_fixture();
    let commented = format!(
        "# my notes live here\nschema = 5\n\n[sources.vstack]\nrepo   =   \"{LEGACY_SOURCE_REPO}\"   # pinned by hand\n\n[install]\nharnesses = [\"claude\"] # claude only\nmethod = \"symlink\"\n\n\n[skills.gh]\nsource = \"vstack\"\n# trailing thoughts\n\n[forks.skill.zed]\nsource = \"vstack\"\nrepo = \"{LEGACY_SOURCE_REPO}\"\nforked-at = \"2026-01-01T00:00:00Z\"\n"
    );
    fs::write(f.project.join("kendex.toml"), &commented).unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let after = fs::read_to_string(f.project.join("kendex.toml")).unwrap();
    assert_eq!(
        after,
        commented.replace(LEGACY_SOURCE_REPO, "vanillagreencom/kendex")
    );
}

/// A mute recorded before the move names the old repository; the migration
/// rewrites the manifest but never touches settings, so the mute must keep
/// matching by what it names.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pre_move_mute_still_silences_after_the_migration() {
    let f = pre_move_fixture();
    kendex_core::package::updates::set_ignored(
        &f.env,
        &f.scope,
        ItemKind::Skill,
        "gh",
        LEGACY_SOURCE_REPO,
        true,
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let updates = kendex_core::package::updates::updates(&f.env, &f.scope).unwrap();
    let gh = updates.rows.iter().find(|row| row.name == "gh").unwrap();
    assert_eq!(gh.repo, "vanillagreencom/kendex");
    assert!(gh.ignored, "the pre-move mute must survive the migration");
}

/// A default add (no source argument) on a scope seeded before the product
/// rename: the source is found by its repository — the legacy spelling
/// canonicalizes to the default repo — never by its name and never by
/// whichever source happens to sort first.
#[test]
#[allow(clippy::unwrap_used)]
fn a_default_add_finds_the_default_subscription_by_repo() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let upstream = home.join("base").join("vanillagreencom/kendex");
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "-A"]);
    git(&upstream, &["commit", "--quiet", "-m", "one"]);
    let base = format!("file://{}", home.join("base").display());
    let env = Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    remote::sync(&env, LEGACY_SOURCE_REPO, None).unwrap();

    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    // Sorts before "vstack": under a sort-first fallback the default add
    // would land here and miss the skill.
    let another = home.join("another");
    fs::create_dir_all(another.join("skills/other")).unwrap();
    fs::write(
        another.join("skills/other/SKILL.md"),
        "---\nname: other\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.another]\npath = \"{}\"\n\n[sources.vstack]\nrepo = \"{LEGACY_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            another.display()
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = ops::add(
        &env,
        &scope,
        &ops::AddRequest {
            skills: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap();
    apply::execute(&env, &report.plan, None).unwrap();
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[skills.gh]"), "{manifest}");
    assert!(manifest.contains("source = \"vstack\""), "{manifest}");
}

/// A scope that predates both renames — old file names AND the old repo —
/// gets both migrations in one plan: the generation rename first, then the
/// repository move, whose manifest write lands at the renamed path.
#[test]
#[allow(clippy::unwrap_used)]
fn an_old_name_scope_with_the_old_repo_renames_first_then_moves() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(
        project.join("vstack.toml"),
        format!(
            "schema = 5\n\n[sources.vstack]\nrepo = \"{LEGACY_SOURCE_REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n"
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    let descriptions: Vec<&str> = report
        .plan
        .ops
        .iter()
        .map(|op| op.description.as_str())
        .collect();
    assert!(
        descriptions[0].starts_with("Rename to kendex"),
        "{descriptions:?}"
    );
    let rename = descriptions
        .iter()
        .position(|d| d.starts_with("Rename to kendex"))
        .unwrap();
    let moved = descriptions
        .iter()
        .position(|d| *d == MOVE_DESCRIPTION)
        .unwrap();
    assert!(rename < moved, "{descriptions:?}");

    apply::execute(&env, &report.plan, None).unwrap();
    assert!(!project.join("vstack.toml").exists());
    let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    assert!(!manifest.contains(LEGACY_SOURCE_REPO), "{manifest}");
    assert!(manifest.contains("vanillagreencom/kendex"), "{manifest}");
}
