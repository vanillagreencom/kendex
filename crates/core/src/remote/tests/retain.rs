//! What a publish removes: the older snapshots of one repository outside
//! its keep set, and what holds every one of them in place.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::time::{Duration, SystemTime};

use super::{Fixture, REPO, commit, fixture, key_for, write_skill};
use crate::lock::{self, BundleRev, Lock, LockEntry, SourceRev};
use crate::manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::remote::store::{self, DEFAULT_KEEP, KEEP_VAR, Retention};
use crate::remote::{Resolution, sync, sync_sources};

/// Advance upstream by one commit and bring the cache to it.
fn advance(f: &Fixture, body: &str) -> Resolution {
    write_skill(&f.upstream, body);
    commit(&f.upstream, body);
    sync(&f.env, REPO, None).unwrap()
}

/// Whether the cache still serves this commit.
fn held(f: &Fixture, commit: &str) -> bool {
    store::published(&f.env, &key_for(&f.env), commit).is_some()
}

/// Date a snapshot's receipt back by this many seconds. Publishes in one
/// test land within one clock tick, so the order the rule reads off the
/// receipts is set here rather than left to the filesystem's resolution.
fn age(f: &Fixture, commit: &str, seconds: u64) {
    let receipt = store::receipt_path(&f.env, &key_for(&f.env), commit);
    let file = fs::File::options().write(true).open(&receipt).unwrap();
    file.set_modified(SystemTime::now() - Duration::from_secs(seconds))
        .unwrap();
}

fn snapshot_dirs(f: &Fixture) -> BTreeSet<String> {
    let commits = f
        .env
        .source_cache_dir()
        .join("commits")
        .join(key_for(&f.env));
    fs::read_dir(commits)
        .unwrap()
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect()
}

fn keeping(count: &str) -> Fixture {
    let mut f = fixture();
    f.env = f.env.clone().with_var(KEEP_VAR, count);
    f
}

/// The rule by publish time: the count includes the snapshot just
/// published, so with two kept each publish removes the one before the
/// previous, and the older receipt decides which that is.
#[test]
fn the_newest_snapshots_stay_and_the_rest_go() {
    let f = keeping("2");
    let a = sync(&f.env, REPO, None).unwrap();
    assert_eq!(a.retention, Retention::Pruned { removed: 0 });
    age(&f, &a.commit, 300);

    let b = advance(&f, "v2");
    assert_eq!(b.retention, Retention::Pruned { removed: 0 });
    age(&f, &b.commit, 200);

    let c = advance(&f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 1 });
    assert!(!held(&f, &a.commit));
    assert!(held(&f, &b.commit));
    assert!(held(&f, &c.commit));
    assert!(
        !store::receipt_path(&f.env, &key_for(&f.env), &a.commit).exists(),
        "the removed snapshot's receipt is still there"
    );
    assert_eq!(snapshot_dirs(&f), BTreeSet::from([b.commit, c.commit]));
}

/// With the variable unset, the default count applies.
#[test]
fn the_default_count_applies_when_nothing_names_one() {
    let f = fixture();
    let mut commits = vec![sync(&f.env, REPO, None).unwrap().commit];
    for round in 0..DEFAULT_KEEP {
        age(&f, commits.last().unwrap(), 600 - round as u64);
        commits.push(advance(&f, &format!("v{round}")).commit);
    }
    assert!(!held(&f, &commits[0]), "the oldest snapshot survived");
    assert_eq!(
        snapshot_dirs(&f),
        commits[1..].iter().cloned().collect::<BTreeSet<String>>()
    );
}

/// Every commit a registered scope's lock names stays, whichever field
/// names it: a source's resolution in the personal lock, an installation's
/// provenance and a set's resolution in a project's. Nothing else past the
/// count does.
#[test]
fn a_snapshot_a_lock_names_is_never_removed() {
    let f = keeping("0");
    let a = sync(&f.env, REPO, None).unwrap();
    lock::save(
        &lock::lock_path(&f.env, &Scope::Global),
        &Lock {
            sources: BTreeMap::from([(
                "cat".to_owned(),
                SourceRev {
                    repo: REPO.to_owned(),
                    rev: None,
                    commit: a.commit.clone(),
                },
            )]),
            ..Lock::default()
        },
    )
    .unwrap();
    age(&f, &a.commit, 500);

    let b = advance(&f, "v2");
    assert_eq!(b.retention, Retention::Pruned { removed: 0 });
    assert!(held(&f, &a.commit), "the personal lock names this commit");
    age(&f, &b.commit, 400);

    let project = f._tmp.path().join("proj");
    fs::create_dir_all(&project).unwrap();
    crate::settings::register_project(&f.env, &project).unwrap();
    let scope = Scope::Project { root: project };
    let entry = LockEntry {
        name: "gh".to_owned(),
        kind: ItemKind::Skill,
        harness: HarnessId::Claude,
        source: "cat".to_owned(),
        source_repo: REPO.to_owned(),
        source_hash: "h".to_owned(),
        source_commit: Some(b.commit.clone()),
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: BTreeSet::from([lock::Reason::Requested]),
        machine: None,
    };
    let entries = BTreeMap::from([(
        lock::entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        entry,
    )]);
    lock::save(
        &lock::lock_path(&f.env, &scope),
        &Lock {
            entries: entries.clone(),
            ..Lock::default()
        },
    )
    .unwrap();

    let c = advance(&f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 0 });
    assert!(
        held(&f, &b.commit),
        "the project's installation names this commit"
    );
    age(&f, &c.commit, 300);
    lock::save(
        &lock::lock_path(&f.env, &scope),
        &Lock {
            entries,
            bundles: BTreeMap::from([(
                "set".to_owned(),
                BundleRev {
                    source: "cat".to_owned(),
                    source_repo: REPO.to_owned(),
                    commit: c.commit.clone(),
                },
            )]),
            ..Lock::default()
        },
    )
    .unwrap();

    let d = advance(&f, "v4");
    assert_eq!(d.retention, Retention::Pruned { removed: 0 });
    assert!(held(&f, &c.commit), "the project's set names this commit");
    age(&f, &d.commit, 200);
    let e = advance(&f, "v5");
    assert_eq!(e.retention, Retention::Pruned { removed: 1 });
    assert!(!held(&f, &d.commit), "nothing names this commit");
    assert_eq!(
        snapshot_dirs(&f),
        BTreeSet::from([a.commit, b.commit, c.commit, e.commit])
    );
}

/// What one row of the fail-closed table plants in a fixture.
type Plant = fn(&mut Fixture);

/// A keep set that cannot be established removes nothing: whatever stands
/// stays, and the reason is what the publish reports.
#[test]
fn nothing_is_removed_when_the_keep_set_cannot_be_read() {
    let rows: [(&str, Plant, &str); 3] = [
        (
            "a lock this build cannot read",
            |f| {
                let path = lock::lock_path(&f.env, &Scope::Global);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, "{not a record").unwrap();
            },
            "lock file could not be read",
        ),
        (
            "a registry this build cannot read",
            |f| {
                let path = f.env.settings_file();
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, "projects = [").unwrap();
            },
            "settings.toml",
        ),
        (
            "a count that is not a number",
            |f| f.env = f.env.clone().with_var(KEEP_VAR, "many"),
            KEEP_VAR,
        ),
    ];
    for (name, plant, fragment) in rows {
        let mut f = keeping("0");
        let a = sync(&f.env, REPO, None).unwrap();
        age(&f, &a.commit, 300);
        plant(&mut f);

        let b = advance(&f, "v2");
        let Retention::Stopped { removed, reason } = &b.retention else {
            panic!(
                "{name}: removed with the keep set unknown: {:?}",
                b.retention
            );
        };
        assert_eq!(*removed, 0, "{name}");
        assert!(reason.contains(fragment), "{name}: {reason}");
        assert!(held(&f, &a.commit), "{name}: the older snapshot is gone");
    }
}

/// A pass over a manifest's sources counts what it removed for the
/// terminal, and a stopped removal is one of its notes.
#[test]
fn a_sync_pass_reports_what_it_removed_and_what_it_could_not() {
    let mut f = keeping("0");
    let mut manifest = manifest::seed(&Scope::Global, &[]);
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
    manifest.sources.insert(
        "cat".to_owned(),
        manifest::SourceDecl {
            repo: Some(REPO.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    let first = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(first.removed_snapshots, 0);
    assert!(first.notes.is_empty(), "{:?}", first.notes);
    let a = sync(&f.env, REPO, None).unwrap().commit;
    age(&f, &a, 300);

    write_skill(&f.upstream, "v2");
    commit(&f.upstream, "two");
    let second = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(second.removed_snapshots, 1);
    assert!(second.notes.is_empty(), "{:?}", second.notes);

    f.env = f.env.clone().with_var(KEEP_VAR, "many");
    write_skill(&f.upstream, "v3");
    commit(&f.upstream, "three");
    let third = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(third.removed_snapshots, 0);
    assert_eq!(third.notes.len(), 1, "{:?}", third.notes);
    assert!(third.notes[0].contains(KEEP_VAR), "{:?}", third.notes);
}
