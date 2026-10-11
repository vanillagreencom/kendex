//! Refreshing a manifest's remotes: which catalogs a refresh reaches for,
//! and what an unreachable one does to the call.

use std::fs;

use super::{REPO, fixture};
use crate::manifest;
use crate::model::Scope;
use crate::remote::{
    cache_head, cached, mirror_commit, sync, sync_declared_sources, sync_source, sync_sources,
};

#[test]
fn the_catalog_revision_is_run_scoped_and_declared_revisions_win() {
    for (case, repo, override_rev, declared_rev, expected_tag) in [
        (
            "override",
            manifest::DEFAULT_SOURCE_REPO,
            Some("vN"),
            None,
            Some("vN"),
        ),
        (
            "https override",
            "https://github.com/vanillagreencom/kendex",
            Some("vN"),
            None,
            Some("vN"),
        ),
        (
            "declared",
            manifest::DEFAULT_SOURCE_REPO,
            Some("vN"),
            Some("declared"),
            Some("declared"),
        ),
        ("other repo", REPO, Some("vN"), None, None),
        ("unset", manifest::DEFAULT_SOURCE_REPO, None, None, None),
    ] {
        let mut f = fixture();
        if repo == manifest::DEFAULT_SOURCE_REPO {
            let upstream = f.upstream.parent().unwrap().parent().unwrap().join(repo);
            fs::create_dir_all(upstream.parent().unwrap()).unwrap();
            fs::rename(&f.upstream, &upstream).unwrap();
            f.upstream = upstream;
        }
        let tagged = super::head(&f.upstream);
        super::git(&f.upstream, &["tag", "vN"]);
        super::write_skill(&f.upstream, "declared");
        let declared = super::commit(&f.upstream, "declared");
        super::git(&f.upstream, &["tag", "declared"]);
        super::write_skill(&f.upstream, "head");
        let head = super::commit(&f.upstream, "head");
        assert_ne!(tagged, head, "{case}: fixture tag must precede HEAD");
        let expected = match expected_tag {
            Some("vN") => &tagged,
            Some("declared") => &declared,
            None => &head,
            Some(_) => panic!("unknown fixture tag"),
        };
        let env = match override_rev {
            Some(rev) => f.env.with_var("KENDEX_CATALOG_REV", rev),
            None => f.env,
        };
        if repo.contains("://") {
            // Full URLs bypass host rebasing; this mirror uses the fixture transport.
            let mirror = super::store::mirror_dir(&env, &crate::remote::cache_key(&env, repo));
            super::store::ensure_mirror(&mirror, &format!("file://{}", f.upstream.display()))
                .unwrap();
        }
        let source = manifest::SourceDecl {
            repo: Some(repo.to_owned()),
            path: None,
            rev: declared_rev.map(str::to_owned),
            enabled: true,
        };
        let synced = sync_source(&env, "cat", &source).unwrap();
        assert!(synced.notes.is_empty(), "{case}");
        assert_eq!(
            &sync(&env, repo, declared_rev).unwrap().commit,
            expected,
            "{case}: sync read"
        );
        let resolved = cached(&env, repo, declared_rev).unwrap().unwrap();
        assert_eq!(&resolved.commit, expected, "{case}: cached read");
        assert_eq!(
            mirror_commit(&env, repo, declared_rev).as_ref(),
            Some(expected),
            "{case}: mirror read"
        );
        assert_eq!(
            cache_head(&env, repo, declared_rev),
            Some(expected.chars().take(7).collect()),
            "{case}: displayed commit"
        );
        assert_eq!(source.rev.as_deref(), declared_rev, "{case}: declaration");
    }
}

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
