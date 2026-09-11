//! A refresh reaches the marketplace a scope with no manifest already lists.
//!
//! On a fresh machine the personal scope has no manifest file, yet every
//! page reads it as its first write would create it, with the default
//! marketplace subscribed and not downloaded. The refresh has to read the
//! same view, or the remedy every page names leads nowhere: skip a scope
//! whose file is absent and this file is what goes red.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::Command;

use kendex_app::sources::refresh;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::DEFAULT_SOURCE_REPO;
use kendex_core::model::Scope;

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
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// The default marketplace fetched into the mirror by a refresh of a
/// personal scope that has no manifest file at all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_with_no_manifest_refreshes_the_default_marketplace_it_lists() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream = home.join("base").join(DEFAULT_SOURCE_REPO);
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
    assert!(!kendex_core::manifest::manifest_path(&env, &Scope::Global).exists());
    assert_eq!(
        kendex_core::remote::cache_head(&env, DEFAULT_SOURCE_REPO, None),
        None
    );

    let warnings = refresh(&env, &[Scope::Global]).unwrap();

    assert_eq!(warnings, Vec::<String>::new());
    assert!(
        kendex_core::remote::cache_head(&env, DEFAULT_SOURCE_REPO, None).is_some(),
        "the refresh fetched nothing"
    );
    // The refresh reads; it writes no manifest of its own.
    assert!(!kendex_core::manifest::manifest_path(&env, &Scope::Global).exists());
}
