//! Refreshing a manifest's remotes: which catalogs a refresh reaches for,
//! and what an unreachable one does to the call.

use std::fs;

use super::{REPO, fixture};
use crate::manifest;
use crate::model::Scope;
use crate::remote::{cache_head, sync_declared_sources, sync_sources};

/// Every enabled remote in a manifest resolves; a never-cached one that
/// cannot be reached fails the whole call rather than half-resolving.
#[test]
fn sync_sources_reports_warnings_and_fails_on_the_unreachable() {
    let f = fixture();
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    manifest.sources.insert(
        "cat".to_owned(),
        manifest::SourceDecl {
            repo: Some(REPO.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
    assert!(sync_sources(&f.env, &manifest).unwrap().notes.is_empty());
    assert_eq!(cache_head(&f.env, REPO, None).unwrap().len(), 7);

    fs::remove_dir_all(&f.upstream).unwrap();
    assert_eq!(sync_sources(&f.env, &manifest).unwrap().notes.len(), 1);

    manifest.sources.get_mut("cat").unwrap().repo = Some("owner/gone".to_owned());
    assert!(sync_sources(&f.env, &manifest).is_err());
}

/// A refresh fetches what this scope installs from, not every catalog the
/// manifest happens to name. A seeded manifest always carries the default
/// catalog, so fetching all of them lets a repository nobody installed from
/// fail — or merely slow — every refresh.
#[test]
fn a_refresh_skips_a_catalog_nothing_installs_from() {
    let f = fixture();
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    manifest.sources.insert(
        "cat".to_owned(),
        manifest::SourceDecl {
            repo: Some(REPO.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    // The seeded default is unreachable and nothing declares anything from it.
    manifest
        .sources
        .get_mut(manifest::DEFAULT_SOURCE_NAME)
        .unwrap()
        .repo = Some("owner/gone".to_owned());
    manifest
        .skills
        .insert("gh".to_owned(), manifest::ItemDecl::from_source("cat"));

    assert!(
        sync_sources(&f.env, &manifest).is_err(),
        "the unused catalog is still reachable, so this proves nothing"
    );
    assert!(sync_declared_sources(&f.env, &manifest).notes.is_empty());
    assert_eq!(cache_head(&f.env, REPO, None).unwrap().len(), 7);
}

/// A catalog out of reach must not strand the items that came from every
/// other catalog: the reachable ones still resolve and the failure is
/// reported rather than thrown.
#[test]
fn a_refresh_reports_an_unreachable_catalog_and_resolves_the_rest() {
    let f = fixture();
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    for (name, repo) in [("cat", REPO), ("gone", "owner/gone")] {
        manifest.sources.insert(
            name.to_owned(),
            manifest::SourceDecl {
                repo: Some(repo.to_owned()),
                path: None,
                rev: None,
                enabled: true,
            },
        );
        manifest.skills.insert(
            format!("from-{name}"),
            manifest::ItemDecl::from_source(name),
        );
    }
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);

    let notes = sync_declared_sources(&f.env, &manifest).notes;
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("gone"), "{notes:?}");
    // The reachable catalog resolved despite the other one failing first.
    assert_eq!(cache_head(&f.env, REPO, None).unwrap().len(), 7);
}

/// A lock held through the foreground bound is one source failure. The
/// packages behind it do not repeat the same timing failure as pending rows.
#[test]
fn a_busy_source_is_one_failure_instead_of_one_pending_note_per_package() {
    let f = fixture();
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    manifest.sources.insert(
        "cat".to_owned(),
        manifest::SourceDecl {
            repo: Some(REPO.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
    for name in ["one", "two"] {
        manifest
            .skills
            .insert(name.to_owned(), manifest::ItemDecl::from_source("cat"));
    }
    let guard = super::store::lock_repo(&f.env, &super::key_for(&f.env), super::REPO).unwrap();
    let synced = sync_declared_sources(&f.env, &manifest);
    drop(guard);

    assert_eq!(synced.failures.len(), 1, "{:?}", synced.failures);
    assert!(synced.failures[0].contains("run the command again"));
    let mut notes = vec![
        "one: source 'cat' (owner/repo) not fetched yet — skipped".to_owned(),
        "other: source 'dog' (owner/dog) not fetched yet — skipped".to_owned(),
    ];
    synced.suppress_busy_pending(&mut notes);
    assert_eq!(
        notes,
        ["other: source 'dog' (owner/dog) not fetched yet — skipped"]
    );
}
