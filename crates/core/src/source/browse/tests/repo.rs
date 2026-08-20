//! Browsing a repository before anyone subscribes to it: the same reads a
//! subscription gets, off the same store, with the join judged against the
//! personal scope.

use std::fs;
use std::path::{Path, PathBuf};

use super::super::{Catalog, InstallState, package_preview, package_safety, packages, summary};
use crate::env::{Env, FakeOs};
use crate::error::CoreError;
use crate::model::{ItemKind, Scope};
use crate::process::Hardened;

const REPO: &str = "owner/repo";

fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

fn commit(dir: &Path, message: &str) {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
}

/// An upstream repository reachable as `owner/repo` that nothing
/// subscribes to, holding one skill that scores below 100.
fn fixture() -> (tempfile::TempDir, Env, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let upstream = tmp.path().join("base/owner/repo");
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: does gh things\n---\nchmod 777 /tmp/x\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    commit(&upstream, "one");
    let base = format!("file://{}", tmp.path().join("base").display());
    let env = Env::fake(tmp.path(), FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    (tmp, env, upstream)
}

fn repo() -> Catalog {
    Catalog::Repo {
        repo: REPO.to_owned(),
    }
}

#[test]
fn a_repository_is_browsed_without_a_subscription_and_its_fetch_feeds_the_store() {
    let (_tmp, env, _upstream) = fixture();
    assert!(crate::remote::cached(&env, REPO, None).unwrap().is_none());

    let rows = packages(&env, &repo()).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name, "gh");
    assert_eq!(rows[0].state, InstallState::Available);
    assert_eq!(rows[0].description.as_deref(), Some("does gh things"));

    // The read fetched into the store a subscription would use.
    assert!(crate::remote::cached(&env, REPO, None).unwrap().is_some());
}

#[test]
fn the_summary_counts_and_names_the_head_and_knows_no_subscription() {
    let (_tmp, env, _upstream) = fixture();
    let first = summary(&env, &repo()).unwrap();
    assert_eq!(first.provenance, REPO);
    assert!(first.commit.is_some());
    assert_eq!(first.counts.get("skill"), Some(&1));
    assert_eq!(
        first.counts.len(),
        1,
        "kinds with nothing offered are not rows"
    );
    assert_eq!(first.subscription, None);
    assert_eq!(first.warning, None);
}

#[test]
fn a_readable_subscription_to_the_same_repository_is_found_and_an_unfetched_one_passed_over() {
    let (_tmp, env, _upstream) = fixture();
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    // Spelled as a URL, the declaration keys a different store entry that
    // nothing has fetched: switching onto it would empty the page.
    fs::write(
        &manifest,
        "schema = 5\n[sources.tools]\nrepo = \"https://github.com/owner/repo.git\"\n",
    )
    .unwrap();
    assert_eq!(summary(&env, &repo()).unwrap().subscription, None);

    fs::write(
        &manifest,
        format!("schema = 5\n[sources.tools]\nrepo = \"{REPO}\"\n"),
    )
    .unwrap();
    let found = summary(&env, &repo()).unwrap().subscription.unwrap();
    assert_eq!(found.scope, Scope::Global);
    assert_eq!(found.source, "tools");
}

#[test]
fn a_name_installed_from_anywhere_else_is_a_collision_and_never_installed_here() {
    let (_tmp, env, _upstream) = fixture();
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        "schema = 5\n[sources.other]\npath = \"/elsewhere\"\n[skills.gh]\nsource = \"other\"\n",
    )
    .unwrap();
    // Installed too, from that other source: a blind browse owns no
    // installation, so this is still a clash and never "Installed".
    let mut lock = crate::lock::Lock {
        version: crate::lock::LOCK_VERSION,
        ..Default::default()
    };
    lock.entries.insert(
        crate::lock::entry_key(ItemKind::Skill, "gh", crate::model::HarnessId::Claude),
        super::lock_entry(ItemKind::Skill, "gh", "other"),
    );
    crate::lock::save(&crate::lock::lock_path(&env, &Scope::Global), &lock).unwrap();

    let rows = packages(&env, &repo()).unwrap();
    assert_eq!(rows[0].state, InstallState::Available);
    assert_eq!(rows[0].collision.as_deref(), Some("other"));
}

#[test]
fn a_subscription_that_is_turned_off_is_passed_over_and_the_repository_still_reads() {
    let (_tmp, env, _upstream) = fixture();
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!("schema = 5\n[sources.cat]\nrepo = \"{REPO}\"\nenabled = false\n"),
    )
    .unwrap();

    let first = summary(&env, &repo()).unwrap();
    assert_eq!(first.subscription, None);
    assert_eq!(packages(&env, &repo()).unwrap().len(), 1);
}

#[test]
fn a_listing_never_picks_the_transport() {
    let (_tmp, env, _upstream) = fixture();
    let spelled = Catalog::Repo {
        repo: format!("ssh://git@github.com/{REPO}"),
    };
    let first = summary(&env, &spelled).unwrap();
    // Fetched as the shorthand — over https in production — under the one
    // key the shorthand, the safety cache and Subscribe all share.
    assert_eq!(first.provenance, REPO);
    assert!(crate::remote::cached(&env, REPO, None).unwrap().is_some());
    assert_ne!(
        crate::remote::cache_key(&env, &format!("ssh://git@github.com/{REPO}")),
        crate::remote::cache_key(&env, REPO),
        "the two spellings would otherwise be two downloads"
    );
}

#[test]
fn a_repository_that_does_not_exist_says_the_fetch_failed_not_a_pin() {
    let (_tmp, env, _upstream) = fixture();
    let error = summary(
        &env,
        &Catalog::Repo {
            repo: "owner/missing".to_owned(),
        },
    )
    .unwrap_err();
    assert!(matches!(error, CoreError::FetchFailed { .. }), "{error}");
    let text = error.to_string();
    assert!(
        !text.contains("pinned") && !text.contains("cached"),
        "{text}"
    );
}

#[test]
fn only_a_github_repository_is_browsable_blind() {
    let (_tmp, env, _upstream) = fixture();
    let refused = packages(
        &env,
        &Catalog::Repo {
            repo: "git@gitlab.com:owner/repo.git".to_owned(),
        },
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::NotBrowsable { .. }),
        "{refused}"
    );
}

#[test]
fn preview_and_safety_read_the_repository_and_the_score_is_shared_with_a_later_subscription() {
    let (_tmp, env, _upstream) = fixture();
    let preview = package_preview(&env, &repo(), ItemKind::Skill, "gh").unwrap();
    assert!(
        preview
            .readme
            .as_deref()
            .unwrap()
            .contains("chmod 777 /tmp/x"),
        "{:?}",
        preview.readme
    );
    assert_eq!(preview.files.len(), 1);

    let scored = package_safety(&env, &repo(), ItemKind::Skill, "gh").unwrap();
    assert!(!scored.from_cache);
    assert!(scored.safety.score < 100);

    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!("schema = 5\n[sources.cat]\nrepo = \"{REPO}\"\n"),
    )
    .unwrap();
    let subscribed = package_safety(
        &env,
        &Catalog::Subscription {
            scope: Scope::Global,
            source: "cat".to_owned(),
        },
        ItemKind::Skill,
        "gh",
    )
    .unwrap();
    assert!(subscribed.from_cache);
    assert_eq!(subscribed.safety, scored.safety);
}

#[test]
fn an_unreachable_upstream_serves_the_store_with_a_warning() {
    let (_tmp, env, upstream) = fixture();
    summary(&env, &repo()).unwrap();
    fs::remove_dir_all(&upstream).unwrap();

    let again = summary(&env, &repo()).unwrap();
    assert_eq!(again.counts.get("skill"), Some(&1));
    assert!(
        again.warning.is_some(),
        "a failed refresh is said, not hidden"
    );
}
