//! Refreshing a manifest's remotes: which catalogs a refresh reaches for,
//! and what an unreachable one does to the call.

use std::fs;

use super::{REPO, fixture};
use crate::env::Env;
use crate::error::CoreError;
use crate::manifest;
use crate::model::Scope;
use crate::remote::{
    Synced, cache_head, cached, mirror_commit, sync, sync_declared_sources, sync_record_sources,
    sync_source, sync_sources,
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

/// A refresh of one scope, as the full route takes it (lenient) and as the
/// review preparation takes it (strict).
type Refresh = fn(&Env, &Scope, &manifest::Manifest) -> crate::error::Result<Synced>;

const REFRESHES: [(&str, Refresh); 2] = [
    ("lenient", |env, scope, manifest| {
        Ok(sync_declared_sources(env, scope, manifest))
    }),
    ("strict", sync_record_sources),
];

/// A refresh fetches what this scope installs from, not every catalog the
/// manifest happens to name. A seeded manifest always carries the default
/// catalog, so fetching all of them lets a repository nobody installed from
/// fail — or merely slow — every refresh. Both refreshes read an item's and
/// a bundle's source.
#[test]
fn a_refresh_skips_a_catalog_nothing_installs_from() {
    for user in ["item", "bundle"] {
        for (refresh, run) in REFRESHES {
            let case = format!("{refresh} {user}");
            // Each pair gets its own cache, so only its own fetch can fill it.
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
            let users = match user {
                "item" => &mut manifest.skills,
                _ => &mut manifest.bundles,
            };
            users.insert("gh".to_owned(), manifest::ItemDecl::from_source("cat"));

            let synced = run(&f.env, &Scope::Global, &manifest);
            assert!(
                synced.as_ref().is_ok_and(|s| s.notes.is_empty()),
                "{case}: {synced:?}"
            );
            assert_eq!(
                cache_head(&f.env, REPO, None).map(|h| h.len()),
                Some(7),
                "{case}"
            );
            assert!(
                sync_sources(&f.env, &manifest).is_err(),
                "{case}: the unused catalog is still reachable, so this proves nothing"
            );
        }
    }
}

/// What the global scope's install record holds before a refresh.
enum Record {
    Absent,
    Names(&'static [&'static str]),
    Unreadable,
}

/// Lay the global scope's record down as `record` says. A named source's
/// entry carries a commit no mirror holds: the selection reads names only.
fn write_record(env: &Env, record: &Record) {
    let path = crate::lock::lock_path(env, &Scope::Global);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    match record {
        Record::Absent => {}
        Record::Names(names) => {
            let lock = crate::lock::Lock {
                sources: names
                    .iter()
                    .map(|name| {
                        let entry = crate::lock::SourceRev {
                            repo: format!("owner/{name}"),
                            rev: None,
                            commit: "0".repeat(40),
                        };
                        ((*name).to_owned(), entry)
                    })
                    .collect(),
                ..crate::lock::Lock::default()
            };
            crate::lock::save(&path, &lock).unwrap();
        }
        Record::Unreadable => fs::write(&path, "not a record").unwrap(),
    }
}

/// A reachable upstream served as `owner/<name>`, beside the fixture's own.
fn second_upstream(f: &super::Fixture, name: &str) {
    let upstream = f.upstream.parent().unwrap().join(name);
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    super::write_skill(&upstream, name);
    super::git(&upstream, &["init", "--quiet", "-b", "main"]);
    super::commit(&upstream, name);
}

/// The record pass reads every enabled repository source, so a refresh
/// also fetches the ones the scope's install record names, used or not,
/// and leaves a reachable subscription the record does not carry alone.
/// No record, or one this build cannot read, adds none and refuses
/// nothing. Both refreshes take the one selection.
#[test]
fn a_refresh_also_fetches_the_sources_the_record_names() {
    let rows: [(&str, Record, bool, bool); 5] = [
        ("recorded", Record::Names(&["cat", "spare"]), true, true),
        (
            "recorded, switched off",
            Record::Names(&["cat", "spare"]),
            false,
            false,
        ),
        ("unrecorded", Record::Names(&["cat"]), true, false),
        ("no record", Record::Absent, true, false),
        ("unreadable record", Record::Unreadable, true, false),
    ];
    for (row, record, spare_enabled, spare_fetched) in rows {
        for (refresh, run) in REFRESHES {
            let case = format!("{refresh} {row}");
            let f = fixture();
            for name in ["spare", "extra"] {
                second_upstream(&f, name);
            }
            let mut manifest = one_catalog_in_use(REPO, None);
            for (name, enabled) in [("spare", spare_enabled), ("extra", true)] {
                manifest.sources.insert(
                    name.to_owned(),
                    manifest::SourceDecl {
                        repo: Some(format!("owner/{name}")),
                        path: None,
                        rev: None,
                        enabled,
                    },
                );
            }
            write_record(&f.env, &record);

            // Snapshot retention notes an unreadable record on its own.
            let synced = run(&f.env, &Scope::Global, &manifest);
            assert!(synced.is_ok(), "{case}: {synced:?}");
            assert!(cache_head(&f.env, REPO, None).is_some(), "{case}: in use");
            assert_eq!(
                cache_head(&f.env, "owner/spare", None).is_some(),
                spare_fetched,
                "{case}: spare"
            );
            assert_eq!(
                cache_head(&f.env, "owner/extra", None),
                None,
                "{case}: extra"
            );
        }
    }
}

/// One catalog, `cat`, that one installed skill comes from.
fn one_catalog_in_use(repo: &str, rev: Option<&str>) -> manifest::Manifest {
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
    manifest.sources.insert(
        "cat".to_owned(),
        manifest::SourceDecl {
            repo: Some(repo.to_owned()),
            path: None,
            rev: rev.map(str::to_owned),
            enabled: true,
        },
    );
    manifest
        .skills
        .insert("gh".to_owned(), manifest::ItemDecl::from_source("cat"));
    manifest
}

/// The strict refresh narrows which sources it reaches for, not what a
/// failure of one of them means: each stays the error the all-source
/// refresh returns, for a source in use and for one only the record names.
#[test]
fn a_strict_refresh_keeps_each_resolution_failure() {
    type Expected = fn(&CoreError) -> bool;
    let unknown_pin = "0".repeat(40);
    let rows: [(&str, &str, Option<&str>, Expected); 2] = [
        ("never fetched", "owner/gone", None, |e| {
            matches!(e, CoreError::GitFailed { .. })
        }),
        ("unavailable pin", REPO, Some(&unknown_pin), |e| {
            matches!(e, CoreError::PinUnavailable { .. })
        }),
    ];
    for (row, repo, rev, expected) in rows {
        for used in [true, false] {
            let case = format!("{row}, used: {used}");
            let f = fixture();
            let mut manifest = one_catalog_in_use(repo, rev);
            if !used {
                manifest.skills.clear();
                write_record(&f.env, &Record::Names(&["cat"]));
            }
            let result = sync_record_sources(&f.env, &Scope::Global, &manifest);
            assert!(result.as_ref().is_err_and(expected), "{case}: {result:?}");
        }
    }
}

/// A catalog out of reach must not strand the items that came from every
/// other catalog: the reachable ones still resolve and the failure is
/// reported rather than thrown, whether a package uses the unreachable one
/// or only the record names it.
#[test]
fn a_refresh_reports_an_unreachable_catalog_and_resolves_the_rest() {
    for gone_used in [true, false] {
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
            if name == "cat" || gone_used {
                manifest.skills.insert(
                    format!("from-{name}"),
                    manifest::ItemDecl::from_source(name),
                );
            }
        }
        manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
        if !gone_used {
            write_record(&f.env, &Record::Names(&["cat", "gone"]));
        }

        let notes = sync_declared_sources(&f.env, &Scope::Global, &manifest).notes;
        assert_eq!(notes.len(), 1, "used: {gone_used}: {notes:?}");
        assert!(notes[0].contains("gone"), "used: {gone_used}: {notes:?}");
        // The reachable catalog resolved despite the other one failing first.
        assert_eq!(cache_head(&f.env, REPO, None).unwrap().len(), 7);
    }
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
    let synced = sync_declared_sources(&f.env, &Scope::Global, &manifest);
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
