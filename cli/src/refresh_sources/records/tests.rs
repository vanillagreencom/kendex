//! Resolving a lock's worth of sources into the records every consumer
//! reads from: which directory each recorded source is, which refusals must
//! not be substituted for one, and which entry may fall back to another
//! source at all.

use super::super::tests::tmpdir;
use super::*;
use crate::config::{InstallMethod, ItemKind, LockEntry};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The resolution alone. Every source these tests resolve is a local
/// directory or an absent remote, so the lease is always
/// [`CacheLease::none`]; a leased remote is the fetch module's own subject.
/// [`resolve_single_source_with`]'s sibling, same reasoning: these sources
/// are recorded local paths.
fn resolve_recorded_source_resolution(source: &str) -> SourceResolution {
    let leased = super::resolve_recorded_source_resolution(source);
    assert!(
        !leased.lease.is_held(),
        "a local resolution holds no cache lease"
    );
    leased.resolution
}

fn resolve_single_source_with(
    source: &str,
    update_remote: bool,
    require_vstack_source: bool,
) -> SourceResolution {
    let leased = super::resolve_single_source_with(source, update_remote, require_vstack_source);
    assert!(
        !leased.lease.is_held(),
        "a local resolution holds no cache lease"
    );
    leased.resolution
}

pub(in crate::refresh_sources) fn make_vstack_source(root: &Path, name: &str) -> PathBuf {
    let source = root.join(name);
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("skills")).unwrap();
    source
}

pub(crate) fn lock_entry(name: &str, source: &str) -> LockEntry {
    LockEntry {
        name: name.into(),
        kind: ItemKind::Agent,
        source: source.into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

#[test]
fn resolve_single_source_accepts_absolute_vstack_source() {
    let root = tmpdir("absolute");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();

    assert_eq!(
        resolve_single_source_with(&source.to_string_lossy(), true, true),
        SourceResolution::Resolved(source.clone())
    );
    assert_eq!(
        resolve_single_source_with(&root.to_string_lossy(), true, true),
        SourceResolution::Absent
    );

    let _ = std::fs::remove_dir_all(root);
}

/// `vstack add <SOURCE>` accepts any directory holding the asset, so a lock
/// entry may record one that the discovery heuristic rejects — a dot-named
/// dir, or one carrying only `skills/`. Dropping it here is what made
/// refresh fall back to the majority source and stop propagating edits.
#[test]
fn resolve_source_records_keeps_a_source_the_layout_heuristic_rejects() {
    let root = tmpdir("recorded-alternate");
    let alternate = root.join(".agents");
    std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
    assert!(
        !crate::resolve::is_vstack_source(&alternate),
        "fixture must exercise the heuristic-rejected case"
    );
    assert_eq!(
        resolve_single_source_with(&alternate.to_string_lossy(), true, true),
        SourceResolution::Absent
    );

    assert_eq!(
        resolve_recorded_source_resolution(&alternate.to_string_lossy()),
        SourceResolution::Resolved(alternate.clone())
    );

    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", &alternate.to_string_lossy()));
    let records = resolve_source_records(&lock).sources;

    assert_eq!(
        records.iter().map(|r| r.root.clone()).collect::<Vec<_>>(),
        vec![alternate]
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn resolve_source_records_resolves_relative_sources_from_project_root() {
    let root = tmpdir("recorded-relative");
    let project = root.join("project");
    let relative_source = project.join("vendor").join("vstack");
    std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();

    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", "./vendor/vstack"));

    let records = crate::test_util::with_project_root(&project, || {
        assert_eq!(
            resolve_recorded_source_resolution("./vendor/vstack"),
            SourceResolution::Resolved(std::fs::canonicalize(&relative_source).unwrap())
        );
        assert!(recorded_source_exists("./vendor/vstack"));
        resolve_source_records(&lock).sources
    });

    assert_eq!(records.len(), 1);
    assert_eq!(
        records[0].root,
        std::fs::canonicalize(&relative_source).unwrap()
    );
    assert_eq!(records[0].aliases, vec!["./vendor/vstack".to_string()]);

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn resolve_source_records_records_remote_shorthand_repo_identity() {
    let root = tmpdir("remote-identity");
    let source = make_vstack_source(&root, "source");
    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", "vanillagreencom/vstack"));

    let records = resolve_source_records_with(&lock, |source_name| {
        if source_name == "vanillagreencom/vstack" {
            SourceResolution::Resolved(source.clone())
        } else {
            SourceResolution::Absent
        }
        .into()
    })
    .sources;

    assert_eq!(records.len(), 1);
    assert_eq!(
        records[0].source_repo.as_deref(),
        Some("vanillagreencom/vstack")
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn resolve_source_records_does_not_infer_identity_from_local_layout() {
    let root = tmpdir("local-layout-identity");
    let source = make_vstack_source(&root, "source");
    let mut lock = config::LockFile::default();
    lock.add(lock_entry("demo", &source.to_string_lossy()));

    let records = resolve_source_records(&lock).sources;

    assert_eq!(records.len(), 1);
    assert_eq!(records[0].source_repo, None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn relative_parent_source_uses_current_worktree_lexical_neighbor() {
    let root = tmpdir("recorded-relative-parent");
    let main_project = root.join("dev").join("consumer");
    let main_checkout_neighbor = root.join("dev").join("vstack");
    let linked_worktree = root
        .join("dev")
        .join(".worktrees")
        .join("consumer")
        .join("issue-1");
    let worktree_neighbor = root
        .join("dev")
        .join(".worktrees")
        .join("consumer")
        .join("vstack");
    std::fs::create_dir_all(&main_project).unwrap();
    std::fs::create_dir_all(main_checkout_neighbor.join("skills/demo")).unwrap();
    std::fs::create_dir_all(&linked_worktree).unwrap();
    std::fs::create_dir_all(worktree_neighbor.join("skills/demo")).unwrap();

    let resolved = crate::test_util::with_project_root(&linked_worktree, || {
        resolve_recorded_source_resolution("../vstack")
    });

    assert_eq!(
        resolved,
        SourceResolution::Resolved(std::fs::canonicalize(&worktree_neighbor).unwrap()),
        "copied relative lock sources are resolved from the current worktree root"
    );
    assert_ne!(
        resolved,
        SourceResolution::Resolved(std::fs::canonicalize(&main_checkout_neighbor).unwrap()),
        "../vstack must not silently keep pointing at the main checkout after a lock is copied"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn recorded_remote_shorthand_does_not_bind_to_project_local_shadow_dir() {
    let root = tmpdir("remote-shadow");
    let project = root.join("project");
    let shadow = project.join("owner").join("repo");
    std::fs::create_dir_all(&shadow).unwrap();

    crate::test_util::with_project_root(&project, || {
        assert!(resolve_recorded_local_source("owner/repo").is_none());
        assert_ne!(
            resolve_recorded_source_resolution("owner/repo"),
            SourceResolution::Resolved(shadow.clone())
        );
        // The shorthand names a remote, so it is a source of its own —
        // never one whose entry may be reinstalled from somewhere else.
        assert!(recorded_source_exists("owner/repo"));
    });

    let _ = std::fs::remove_dir_all(root);
}

/// An entry that recorded a real source — live or vanished — must never be
/// silently rebound to the sole other loaded source; that reinstalled it
/// from a repo it was never installed from (a same-named asset there
/// replaced the real one). A vanished source is reported missing instead.
#[test]
fn refresh_source_for_entry_never_rebinds_a_recorded_source() {
    let root = tmpdir("no-rebind");
    let alternate = root.join(".agents");
    std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
    let only_source = make_vstack_source(&root, "other");
    let sources = vec![RefreshSource::from_root(&only_source)];

    let live = lock_entry("demo", &alternate.to_string_lossy());
    assert!(
        refresh_source_for_entry(&sources, &live).is_none(),
        "an entry whose recorded source exists must not bind to a different source"
    );

    let vanished = lock_entry("demo", &root.join("deleted-repo").to_string_lossy());
    assert!(
        refresh_source_for_entry(&sources, &vanished).is_none(),
        "a recorded absolute source that vanished must not bind to a different source"
    );

    let uncached_remote = lock_entry("demo", "owner/repo");
    assert!(
        refresh_source_for_entry(&sources, &uncached_remote).is_none(),
        "a recorded remote that did not resolve must not bind to a local source"
    );

    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let vanished_relative = lock_entry("demo", "./vendor/gone");
    crate::test_util::with_project_root(&project, || {
        assert!(
            refresh_source_for_entry(&sources, &vanished_relative).is_none(),
            "a recorded relative source that vanished must not bind to a different source"
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

/// The fallback exists for locks that recorded no usable source at all:
/// an empty source (disk recovery into an empty lock) or a bare
/// placeholder token (pre-1.0 hash/reconcile paths). Even those bind only
/// while exactly one source is loaded and the token names no live
/// project-relative directory.
#[test]
fn refresh_source_for_entry_falls_back_only_for_legacy_placeholder_sources() {
    let root = tmpdir("legacy-placeholder");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let only_source = make_vstack_source(&root, "other");
    let sources = vec![RefreshSource::from_root(&only_source)];

    crate::test_util::with_project_root(&project, || {
        for placeholder in ["", "source"] {
            assert_eq!(
                refresh_source_for_entry(&sources, &lock_entry("demo", placeholder))
                    .map(|s| s.root.clone()),
                Some(only_source.clone()),
                "legacy placeholder {placeholder:?} keeps the single-source fallback"
            );
        }

        std::fs::create_dir_all(project.join("source")).unwrap();
        assert!(
            refresh_source_for_entry(&sources, &lock_entry("demo", "source")).is_none(),
            "a bare token that names a live project-relative dir is a real source"
        );

        for legacy in ["", "  ", "local"] {
            assert!(
                may_rebind_to_fallback_source(legacy),
                "{legacy:?} is a legacy placeholder"
            );
        }
        for recorded in [
            "/gone/checkout",
            "~/gone",
            ".",
            "./gone",
            "../gone",
            "owner/repo",
            "https://github.com/owner/repo.git",
            "git@github.com:owner/repo.git",
        ] {
            assert!(
                !may_rebind_to_fallback_source(recorded),
                "{recorded:?} is a recorded source, never rebound"
            );
        }
    });

    let second = make_vstack_source(&root, "second");
    let two_sources = vec![
        RefreshSource::from_root(&only_source),
        RefreshSource::from_root(&second),
    ];
    assert!(
        refresh_source_for_entry(&two_sources, &lock_entry("demo", "")).is_none(),
        "no fallback when more than one source is loaded"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_source_for_entry_does_not_fallback_for_live_relative_source() {
    let root = tmpdir("relative-no-rebind");
    let project = root.join("project");
    let relative_source = project.join("vendor").join("vstack");
    std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();
    let only_source = make_vstack_source(&root, "other");
    let sources = vec![RefreshSource::from_root(&only_source)];
    let live_relative = lock_entry("demo", "./vendor/vstack");

    crate::test_util::with_project_root(&project, || {
        assert!(
            refresh_source_for_entry(&sources, &live_relative).is_none(),
            "a live relative source must not rebind to the sole loaded source"
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn resolve_source_records_calls_resolver_once_per_unique_lock_source() {
    let root = tmpdir("resolver-count");
    let source_a = root.join("source-a");
    let source_b = root.join("source-b");
    let mut lock = config::LockFile::default();
    lock.add(lock_entry("rust", "owner/repo"));
    lock.add(LockEntry {
        name: "dev".into(),
        kind: ItemKind::Skill,
        source: "owner/repo".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(lock_entry("scout", "other/repo"));

    let counts: RefCell<HashMap<String, usize>> = RefCell::new(HashMap::new());
    let records = resolve_source_records_with(&lock, |source| {
        *counts.borrow_mut().entry(source.to_string()).or_default() += 1;
        match source {
            "owner/repo" => SourceResolution::Resolved(source_a.clone()),
            "other/repo" => SourceResolution::Resolved(source_b.clone()),
            _ => SourceResolution::Absent,
        }
        .into()
    })
    .sources;

    assert_eq!(records.len(), 2);
    assert_eq!(counts.borrow().get("owner/repo"), Some(&1));
    assert_eq!(counts.borrow().get("other/repo"), Some(&1));

    let _ = std::fs::remove_dir_all(root);
}
