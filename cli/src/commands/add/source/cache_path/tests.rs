//! `add` given a source that names a path inside vstack's own cache.
//!
//! The cache is TTL-managed state, so such a path must be fetched, leased and
//! proved vstack's own before a byte is read out of it — the same treatment a
//! URL gets. Reading it as a plain local directory installed whatever bytes
//! happened to be sitting there: `add` printed `(updated)` while writing a
//! revision behind upstream and leaving the cache untouched, and the very
//! `vstack add` that `check` prescribes for a refused entry exited 0 having
//! installed from the entry `check` had just refused.

use crate::commands::add::fetch_policy_tests::{origin_repo, publish_skill, tmproot};
use crate::commands::add::source::{SourceFetch, resolve_source_for_app};
use crate::config;
use crate::refresh_sources::{RemoteSource, remote_cache_root};
use std::path::{Path, PathBuf};

fn git(repo: &Path, args: &[&str]) {
    let output = crate::refresh_sources::hardened_git_command(repo)
        .args(args)
        .output()
        .expect("git is required to run this regression test");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn skills_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = crate::catalog::discover_skills(dir)
        .unwrap()
        .into_iter()
        .map(|skill| skill.name)
        .collect();
    names.sort();
    names
}

/// A clone of `origin` sitting at a cache entry named `key`, and the lock
/// source string `vstack add <that directory>` writes for it.
fn cache_entry_clone(origin_url: &str, key: &str) -> PathBuf {
    let root = remote_cache_root();
    std::fs::create_dir_all(&root).unwrap();
    let entry = root.join(key);
    git(&root, &["clone", "-q", origin_url, entry.to_str().unwrap()]);
    entry
}

/// The defect: `add` served the cache entry's own bytes. It must fetch, and
/// what it records must be the remote rather than one machine's clone of it.
#[test]
fn add_from_a_cache_entry_path_installs_the_fetched_revision() {
    let root = tmproot("add-cache-entry");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let entry = cache_entry_clone(&origin_url, "legacy_key");
        let source = entry.to_string_lossy().into_owned();
        publish_skill(&origin, "beta");
        assert_eq!(
            skills_in(&entry),
            vec!["alpha".to_string()],
            "the fixture must start behind, or the fetch below proves nothing"
        );

        let registry = config::SourceRegistry::default();
        let resolved = resolve_source_for_app(
            Some(&source),
            &registry,
            &project_root,
            SourceFetch::for_invocation(Some(&source), false),
        )
        .expect("a cache entry naming a fetchable remote resolves");

        assert_eq!(
            skills_in(&resolved.dir),
            vec!["alpha".to_string(), "beta".to_string()],
            "add must install the fetched revision, not the entry's own bytes"
        );
        assert_eq!(
            resolved.source, origin_url,
            "the recorded source must be the remote, not one machine's clone"
        );
        // Control: the ordinary remote path reaches the same clone, so
        // nothing here invented a second directory for one repository.
        assert_eq!(
            resolved.dir,
            RemoteSource::parse(&origin_url).unwrap().unwrap().cache_dir
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The second reproduction: no source named, so `add` falls back to what the
/// project's lock RECORDS — a cache-entry path. It printed `(updated)` while
/// installing the stale revision and leaving the cache untouched.
#[test]
fn add_from_a_remembered_cache_entry_path_installs_the_fetched_revision() {
    let root = tmproot("add-remembered-cache-entry");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let entry = cache_entry_clone(&origin_url, "legacy_key");
        let source = entry.to_string_lossy().into_owned();
        publish_skill(&origin, "beta");

        // Recorded the way an earlier install left it. Not the registry: it
        // refuses to remember a source under the temp directory this fixture
        // lives in, so a registry-based fixture would silently fall through to
        // the CWD walk and test nothing.
        let mut lock = config::LockFile::default();
        lock.add(config::LockEntry {
            name: "alpha".into(),
            kind: config::ItemKind::Skill,
            source: source.clone(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: config::InstallMethod::Copy,
            installed_at: "2026-08-18T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.save(&project_root.join(".vstack-lock.json")).unwrap();
        assert_eq!(
            crate::resolve::source_from_project_lock(&project_root).as_deref(),
            Some(source.as_str()),
            "the fixture must exercise the remembered-source chain"
        );

        let registry = config::SourceRegistry::default();
        let resolved = resolve_source_for_app(
            None,
            &registry,
            &project_root,
            SourceFetch::for_invocation(None, false),
        )
        .expect("a remembered cache entry resolves");

        assert_eq!(
            skills_in(&resolved.dir),
            vec!["alpha".to_string(), "beta".to_string()],
            "a remembered cache path must be fetched like any other remote"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A path BELOW an entry cannot be spelled as a remote, so the entry is
/// fetched and leased and the subdirectory is read inside the tree that fetch
/// left behind — never served from whatever was sitting there.
#[test]
fn add_from_a_path_below_a_cache_entry_installs_the_fetched_subdirectory() {
    let root = tmproot("add-cache-subdir");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);
    publish_skill(&origin.join("nested"), "alpha");
    git(&origin, &["add", "-A"]);
    git(&origin, &["commit", "-q", "-m", "nested"]);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let entry = cache_entry_clone(&origin_url, "legacy_key");
        let sub = entry.join("nested");
        publish_skill(&origin.join("nested"), "beta");
        git(&origin, &["add", "-A"]);
        git(&origin, &["commit", "-q", "-m", "nested beta"]);
        assert_eq!(skills_in(&sub), vec!["alpha".to_string()]);

        let source = sub.to_string_lossy().into_owned();
        let registry = config::SourceRegistry::default();
        let resolved = resolve_source_for_app(
            Some(&source),
            &registry,
            &project_root,
            SourceFetch::for_invocation(Some(&source), false),
        )
        .expect("a subdirectory of a cache entry resolves");

        assert_eq!(
            skills_in(&resolved.dir),
            vec!["alpha".to_string(), "beta".to_string()],
            "the entry must be fetched before its subdirectory is read"
        );
        assert_eq!(resolved.dir, sub);
    });
    let _ = std::fs::remove_dir_all(root);
}

/// `check` exits 1 on an entry whose remote cannot be established and tells
/// the user to re-add it. That `add` must not exit 0 having installed from the
/// entry `check` just refused.
#[test]
fn add_refuses_a_cache_entry_whose_remote_cannot_be_established() {
    let root = tmproot("add-cache-refused");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let entry = cache_entry_clone(&origin_url, "legacy_key");
        let source = entry.to_string_lossy().into_owned();
        let registry = config::SourceRegistry::default();
        let resolve = |registry: &config::SourceRegistry| {
            resolve_source_for_app(
                Some(&source),
                registry,
                &project_root,
                SourceFetch::for_invocation(Some(&source), false),
            )
        };

        // Control: with a usable origin this fixture resolves, so the refusal
        // below is the origin's doing and not the fixture's.
        resolve(&registry).expect("the fixture must resolve while its origin is usable");

        git(&entry, &["remote", "set-url", "origin", "/somewhere/local"]);
        let err = match resolve(&registry) {
            Ok(_) => panic!("an entry naming no fetchable remote must be refused"),
            Err(err) => format!("{err:#}"),
        };
        assert!(err.contains(&source), "must name the entry: {err}");
        assert!(
            err.contains("is not a remote vstack can fetch"),
            "must give the reason: {err}"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// Control: only a path INSIDE the cache changes branch. An ordinary local
/// checkout — including one whose name merely sits beside the cache — installs
/// from itself and is recorded as itself, exactly as before.
#[test]
fn add_from_a_local_directory_outside_the_cache_is_unchanged() {
    let root = tmproot("add-local-control");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    let outside = root.join("checkout");
    for dir in [&home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&outside);
    let _ = origin_url;

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        // A sibling of the cache root, not a child of it.
        let sibling = remote_cache_root().parent().unwrap().join("cache-sibling");
        std::fs::create_dir_all(&sibling).unwrap();
        for candidate in [&outside, &sibling] {
            let source = candidate.to_string_lossy().into_owned();
            let registry = config::SourceRegistry::default();
            let resolved = resolve_source_for_app(
                Some(&source),
                &registry,
                &project_root,
                SourceFetch::for_invocation(Some(&source), false),
            )
            .expect("a local directory resolves as itself");
            let canonical = std::fs::canonicalize(candidate).unwrap();
            assert_eq!(resolved.dir, canonical);
            assert_eq!(resolved.source, canonical.display().to_string());
            assert!(!resolved.lease.is_held());
        }
    });
    let _ = std::fs::remove_dir_all(root);
}
