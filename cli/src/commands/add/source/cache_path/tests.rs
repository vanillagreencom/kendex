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

/// The lease, which this PR is what makes load-bearing. Before it, a
/// cache-path source was in no list vstack fetched, so nothing ever rewrote
/// that entry while `add` read it. Now `check` enumerates it and spawns the
/// detached `cache-refresh` that fetches and `reset --hard`s that exact
/// directory — and a `RefreshOnly` acquire stands down only for a lease that
/// is actually held. The local-directory branch held `CacheLease::none()`, so
/// the refresher saw the path free and could rewrite the tree mid-copy.
///
/// Asserted against the tree `add` READS and the source it RECORDS, which is
/// the pair a later refresher acts on: at an entry root both are the remote's
/// own entry, below one they are the named entry and the path into it.
#[test]
fn add_holds_the_lease_on_the_tree_it_reads() {
    let root = tmproot("add-cache-lease");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);
    std::fs::create_dir_all(origin.join("nested").join("agents")).unwrap();
    publish_skill(&origin.join("nested"), "alpha");
    git(&origin, &["add", "-A"]);
    git(&origin, &["commit", "-q", "-m", "nested"]);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let entry = cache_entry_clone(&origin_url, "legacy_key");
        for (label, source) in [
            ("entry root", entry.to_string_lossy().into_owned()),
            (
                "below the entry",
                entry.join("nested").to_string_lossy().into_owned(),
            ),
        ] {
            let registry = config::SourceRegistry::default();
            let resolved = resolve_source_for_app(
                Some(&source),
                &registry,
                &project_root,
                SourceFetch::for_invocation(Some(&source), false),
            )
            .unwrap_or_else(|err| panic!("{label}: {err:#}"));
            assert!(
                resolved.lease.is_held(),
                "{label}: the tree `add` copies out of must be leased"
            );

            // The entry a later refresher acts on for the source `add`
            // recorded — the same directory `add` is reading right now.
            let read_entry = crate::refresh_sources::remote_cache_entry_for_path(&resolved.dir)
                .expect("the resolved dir is in the cache")
                .0;
            let mut lock = config::LockFile::default();
            lock.add(config::LockEntry {
                name: "alpha".into(),
                kind: config::ItemKind::Skill,
                source: resolved.source.clone(),
                source_repo: None,
                harnesses: vec!["claude-code".into()],
                method: config::InstallMethod::Copy,
                installed_at: "2026-08-18T00:00:00Z".into(),
                source_hash: String::new(),
            });
            let landed = |name: &str| read_entry.join("skills").join(name).exists();

            // Upstream moves and the TTL is off, so the only thing that can
            // stop the refresher is the lease.
            let marker = format!("beta-{}", label.replace(' ', "-"));
            publish_skill(&origin, &marker);
            config::refresh_remote_caches_older_than(&lock, None, config::FetchBound::BACKGROUND);
            assert!(
                !landed(&marker),
                "{label}: a leased tree must not be reset under the install reading it"
            );
            drop(resolved);

            // Control: released, the very same call DOES fetch — so the
            // assertion above is the lease's doing and not the fixture's.
            config::refresh_remote_caches_older_than(&lock, None, config::FetchBound::BACKGROUND);
            assert!(
                landed(&marker),
                "{label}: without the lease the refresher fetches this entry"
            );
        }

        // Control: a local checkout outside the cache leases nothing, because
        // no vstack process rewrites one.
        let outside = root.join("checkout");
        std::fs::create_dir_all(outside.join("agents")).unwrap();
        std::fs::create_dir_all(outside.join("skills")).unwrap();
        let source = outside.to_string_lossy().into_owned();
        let registry = config::SourceRegistry::default();
        let resolved = resolve_source_for_app(
            Some(&source),
            &registry,
            &project_root,
            SourceFetch::for_invocation(Some(&source), false),
        )
        .expect("a local directory resolves");
        assert!(!resolved.lease.is_held());
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The remembered chain must record the tree it READ, not the string it
/// started from. A remembered legacy-key path resolves through the remote its
/// entry clones, which is the CANONICAL entry — so recording the remembered
/// string put one clone in the lock beside a `source_hash` taken against the
/// other, and `check` then passed while `verify` failed on one state.
#[test]
fn a_remembered_cache_path_records_the_tree_the_install_came_from() {
    let root = tmproot("add-remembered-records");
    let origin = root.join("origin");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&origin, &home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let origin_url = origin_repo(&origin);

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        let legacy = cache_entry_clone(&origin_url, "legacy_key");
        let canonical = RemoteSource::parse(&origin_url).unwrap().unwrap();
        // Upstream moves while the legacy clone stays behind: the two trees
        // are now distinguishable, so recording the wrong one is visible.
        publish_skill(&origin, "beta");

        let mut lock = config::LockFile::default();
        lock.add(config::LockEntry {
            name: "alpha".into(),
            kind: config::ItemKind::Skill,
            source: legacy.to_string_lossy().into_owned(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: config::InstallMethod::Copy,
            installed_at: "2026-08-18T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.save(&project_root.join(".vstack-lock.json")).unwrap();

        let registry = config::SourceRegistry::default();
        let resolved = resolve_source_for_app(
            None,
            &registry,
            &project_root,
            SourceFetch::for_invocation(None, false),
        )
        .expect("a remembered cache entry resolves");

        assert_eq!(
            resolved.dir, canonical.cache_dir,
            "the install comes from the entry the remote resolves to"
        );
        assert_eq!(
            resolved.source, origin_url,
            "and the lock must record that same tree, not the remembered path"
        );
        assert_eq!(
            skills_in(&resolved.dir),
            vec!["alpha".to_string(), "beta".to_string()],
            "the recorded source must be the fetched one"
        );
        // The label follows the source, so a fetched remote is not announced
        // as `local:`.
        assert!(
            !resolved.label.starts_with("local:"),
            "a fetched remote must not be labelled local: {}",
            resolved.label
        );
        assert_ne!(
            legacy, canonical.cache_dir,
            "the fixture must be two clones"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// A directory sitting in the cache root with no `.git` is not one of vstack's
/// clones, and `add` must refuse it exactly as every other command does.
/// Falling through to the local-directory shortcut installed it, exit 0, while
/// `check` exited 1 calling the same string absent — and the `vstack add
/// <path>` `check` prescribed re-ran that same no-op forever.
#[test]
fn add_refuses_a_cache_root_directory_that_is_not_a_clone() {
    let root = tmproot("add-cache-not-a-clone");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        // A source layout, so nothing but the missing `.git` can decide this.
        let junk = remote_cache_root().join("junk");
        std::fs::create_dir_all(junk.join("agents")).unwrap();
        std::fs::create_dir_all(junk.join("skills").join("alpha")).unwrap();
        std::fs::write(
            junk.join("skills").join("alpha").join("SKILL.md"),
            "---\nname: alpha\ndescription: alpha\n---\nbody\n",
        )
        .unwrap();
        let source = junk.to_string_lossy().into_owned();
        let registry = config::SourceRegistry::default();
        let resolve = || {
            resolve_source_for_app(
                Some(&source),
                &registry,
                &project_root,
                SourceFetch::for_invocation(Some(&source), false),
            )
        };

        let err = match resolve() {
            Ok(_) => panic!("a cache-root directory with no .git must be refused"),
            Err(err) => format!("{err:#}"),
        };
        assert!(err.contains(&source), "must name the path: {err}");
        assert!(
            err.contains("is not one of its clones"),
            "must give the reason: {err}"
        );

        // Control: the identical layout OUTSIDE the cache is an ordinary local
        // source and still installs — only the location decides this.
        let outside = root.join("checkout");
        std::fs::create_dir_all(outside.join("agents")).unwrap();
        std::fs::create_dir_all(outside.join("skills")).unwrap();
        let source = outside.to_string_lossy().into_owned();
        resolve_source_for_app(
            Some(&source),
            &registry,
            &project_root,
            SourceFetch::for_invocation(Some(&source), false),
        )
        .expect("a local directory outside the cache still resolves");
    });
    let _ = std::fs::remove_dir_all(root);
}

/// What the remembered chain records for a source that is NOT a cache path:
/// the spelling, unchanged. Only the cache branch rewrites what goes in the
/// lock — canonicalizing here too would turn a relative `./src`, which stays
/// supported for a legacy or hand-edited lock, into a machine-specific
/// absolute path in a file that is committed.
#[test]
fn a_remembered_local_source_is_recorded_as_spelled() {
    let root = tmproot("add-remembered-spelling");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&home, &config_dir, &project_root] {
        std::fs::create_dir_all(dir).unwrap();
    }
    // A source the project can name relatively, and a symlink to it.
    let src = project_root.join("src");
    std::fs::create_dir_all(src.join("agents")).unwrap();
    std::fs::create_dir_all(src.join("skills")).unwrap();
    let link = project_root.join("link");
    std::os::unix::fs::symlink(&src, &link).unwrap();

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        crate::test_util::with_project_root(&project_root, || {
            for spelled in ["./src", link.to_string_lossy().as_ref()] {
                let mut lock = config::LockFile::default();
                lock.add(config::LockEntry {
                    name: "alpha".into(),
                    kind: config::ItemKind::Skill,
                    source: spelled.into(),
                    source_repo: None,
                    harnesses: vec!["claude-code".into()],
                    method: config::InstallMethod::Copy,
                    installed_at: "2026-08-18T00:00:00Z".into(),
                    source_hash: String::new(),
                });
                lock.save(&project_root.join(".vstack-lock.json")).unwrap();

                let registry = config::SourceRegistry::default();
                let resolved = resolve_source_for_app(
                    None,
                    &registry,
                    &project_root,
                    SourceFetch::for_invocation(None, false),
                )
                .unwrap_or_else(|err| panic!("{spelled}: {err:#}"));
                assert_eq!(
                    resolved.source, spelled,
                    "a local source must be recorded as the lock spelled it"
                );
            }
        });
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The invariant, on the branch that broke it: a relative recorded source is
/// resolved the way later readers resolve it — against the PROJECT ROOT — so
/// the tree `add` installs from is the tree `refresh`, `check` and `verify`
/// find under that same string.
///
/// Bound to the process CWD instead, running from a subdirectory that happens
/// to hold a same-named source installed one tree and hashed the other, with
/// check and verify both reporting clean and the next refresh silently
/// swapping the installed copy while printing `(changed)` between two equal
/// hashes.
#[test]
fn a_relative_remembered_source_resolves_where_readers_resolve_it() {
    let root = tmproot("add-relative-project-root");
    let home = root.join("home");
    let config_dir = root.join("config");
    let project_root = root.join("project");
    for dir in [&home, &config_dir] {
        std::fs::create_dir_all(dir).unwrap();
    }
    // Two same-named sources: one at the project root, one under a nested CWD.
    let write_source = |dir: &std::path::Path, skill: &str| {
        std::fs::create_dir_all(dir.join("agents")).unwrap();
        let s = dir.join("skills").join(skill);
        std::fs::create_dir_all(&s).unwrap();
        std::fs::write(
            s.join("SKILL.md"),
            format!("---\nname: {skill}\ndescription: {skill}\n---\nbody\n"),
        )
        .unwrap();
    };
    write_source(&project_root.join("src"), "root_variant");
    write_source(&project_root.join("nested").join("src"), "nested_variant");

    crate::test_util::with_home_and_config(&home, &config_dir, || {
        crate::test_util::with_project_root(&project_root, || {
            let mut lock = config::LockFile::default();
            lock.add(config::LockEntry {
                name: "alpha".into(),
                kind: config::ItemKind::Skill,
                source: "./src".into(),
                source_repo: None,
                harnesses: vec!["claude-code".into()],
                method: config::InstallMethod::Copy,
                installed_at: "2026-08-18T00:00:00Z".into(),
                source_hash: String::new(),
            });
            lock.save(&project_root.join(".vstack-lock.json")).unwrap();

            // Resolution runs with the process CWD wherever the harness left
            // it, which is NOT the project root — exactly the divergence.
            let registry = config::SourceRegistry::default();
            let resolved = resolve_source_for_app(
                None,
                &registry,
                &project_root,
                SourceFetch::for_invocation(None, false),
            )
            .expect("a remembered relative source resolves");

            assert_eq!(
                resolved.source, "./src",
                "the spelling is still what gets recorded"
            );
            assert_eq!(
                skills_in(&resolved.dir),
                vec!["root_variant".to_string()],
                "the tree read must be the one readers resolve `./src` to"
            );
            // The invariant itself: what readers find under the recorded
            // string is the tree the install came from.
            let read_back = crate::refresh_sources::resolve_source_path(&resolved.source)
                .expect("readers resolve the recorded string");
            assert!(
                crate::resolve::same_path(&read_back, &resolved.dir),
                "recorded {:?} resolves to {read_back:?}, installed from {:?}",
                resolved.source,
                resolved.dir
            );
        });
    });
    let _ = std::fs::remove_dir_all(root);
}
