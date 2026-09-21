//! What a publish removes: the older snapshots of one repository outside
//! its keep set, and what holds every one of them in place.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::time::{Duration, SystemTime};

use super::{Fixture, REPO, commit, fixture, git, key_for, write_skill};
use crate::lock::{self, BundleRev, Lock, LockEntry, SourceRev};
use crate::manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::remote::store::{self, KEEP_VAR, Retention};
use crate::remote::{Resolution, Synced, sync, sync_sources};

/// The same machine in its next invocation: what the last one held is
/// released.
fn next_invocation(f: &mut Fixture) {
    f.env = f.env.next_invocation();
}

/// A project the registry does not know, with a manifest on disk
/// declaring `cat` as [`REPO`] and a lock recording `cat` at `commit`:
/// a clone carrying its committed record, never registered here.
fn unregistered_clone(f: &Fixture, commit: &str) -> Scope {
    let project = f._tmp.path().join("clone");
    fs::create_dir_all(&project).unwrap();
    let scope = Scope::Project { root: project };
    manifest::save(
        &manifest::manifest_path(&f.env, &scope),
        &declaring(&scope, &[("cat", REPO)]),
    )
    .unwrap();
    lock::save(
        &lock::lock_path(&f.env, &scope),
        &Lock {
            sources: BTreeMap::from([(
                "cat".to_owned(),
                SourceRev {
                    repo: REPO.to_owned(),
                    rev: None,
                    commit: commit.to_owned(),
                },
            )]),
            ..Lock::default()
        },
    )
    .unwrap();
    scope
}

/// Advance upstream by one commit and bring the cache to it in a new
/// invocation, the way one refresh follows another.
fn advance(f: &mut Fixture, body: &str) -> Resolution {
    next_invocation(f);
    advance_here(f, body)
}

/// [`advance`] within the invocation already running.
fn advance_here(f: &Fixture, body: &str) -> Resolution {
    write_skill(&f.upstream, body);
    commit(&f.upstream, body);
    sync(&f.env, REPO, None).unwrap()
}

/// Whether the cache still holds this snapshot. Read off the directory,
/// not through `store::published`, which would hand the checkout to the
/// invocation and so hold it.
fn held(f: &Fixture, commit: &str) -> bool {
    store::checkout_dir(&f.env, &key_for(&f.env), commit).is_dir()
}

/// Date a snapshot's receipt back by this many seconds. Publishes in one
/// test land within one clock tick, so the order the rule reads off the
/// receipts is set here rather than left to the filesystem's resolution.
fn age(f: &Fixture, commit: &str, seconds: u64) {
    date(f, commit, SystemTime::now() - Duration::from_secs(seconds));
}

/// Set a snapshot's receipt to exactly this publish time.
fn date(f: &Fixture, commit: &str, published_at: SystemTime) {
    let receipt = store::receipt_path(&f.env, &key_for(&f.env), commit);
    let file = fs::File::options().write(true).open(&receipt).unwrap();
    file.set_modified(published_at).unwrap();
}

/// A manifest declaring these repositories as enabled sources, under the
/// names given, and nothing else.
fn declaring(scope: &Scope, sources: &[(&str, &str)]) -> manifest::Manifest {
    let mut manifest = manifest::seed(scope, &[]);
    manifest.sources.remove(manifest::DEFAULT_SOURCE_NAME);
    for (name, repo) in sources {
        manifest.sources.insert(
            (*name).to_owned(),
            manifest::SourceDecl {
                repo: Some((*repo).to_owned()),
                path: None,
                rev: None,
                enabled: true,
            },
        );
    }
    manifest
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
    let mut f = keeping("2");
    let a = sync(&f.env, REPO, None).unwrap();
    assert_eq!(a.retention, Retention::Pruned { removed: 0 });
    age(&f, &a.commit, 300);

    let b = advance(&mut f, "v2");
    assert_eq!(b.retention, Retention::Pruned { removed: 0 });
    age(&f, &b.commit, 200);
    // What package safety scored for the snapshot about to go.
    let safety = store::safety_cache_dir(&f.env, &key_for(&f.env), &a.commit);
    fs::create_dir_all(&safety).unwrap();
    fs::write(safety.join("gh.json"), "{}").unwrap();

    let c = advance(&mut f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 1 });
    assert!(!held(&f, &a.commit));
    assert!(held(&f, &b.commit));
    assert!(held(&f, &c.commit));
    assert!(
        !store::receipt_path(&f.env, &key_for(&f.env), &a.commit).exists(),
        "the removed snapshot's receipt is still there"
    );
    assert!(
        !safety.exists(),
        "the removed snapshot's safety cache is still there"
    );
    assert_eq!(snapshot_dirs(&f), BTreeSet::from([b.commit, c.commit]));
}

/// With the variable unset, or exported empty the way a shell profile or
/// a job neutralises one, the default count applies: three, the number
/// `changelog.d/fixed/KEN-1629.md` and `docs/architecture/sources.md`
/// promise, so `DEFAULT_KEEP` is not read here.
#[test]
fn the_default_count_applies_when_nothing_names_one() {
    for named in [None, Some(""), Some("  ")] {
        let mut f = match named {
            None => fixture(),
            Some(value) => keeping(value),
        };
        let mut commits = vec![sync(&f.env, REPO, None).unwrap().commit];
        for round in 0..3 {
            age(&f, commits.last().unwrap(), 600 - round as u64);
            let published = advance(&mut f, &format!("v{round}"));
            assert!(
                matches!(published.retention, Retention::Pruned { .. }),
                "{named:?}: {:?}",
                published.retention
            );
            commits.push(published.commit);
        }
        assert!(
            !held(&f, &commits[0]),
            "{named:?}: the oldest snapshot survived"
        );
        assert_eq!(
            snapshot_dirs(&f),
            commits[1..].iter().cloned().collect::<BTreeSet<String>>(),
            "{named:?}"
        );
    }
}

/// A checkout with no receipt is one nothing vouches for: a removal that
/// stopped after the receipt went, or a tree left by hand. It ranks
/// oldest, so it is the first to go, before any snapshot a receipt dates.
#[test]
fn a_checkout_without_a_receipt_goes_before_any_dated_one() {
    let mut f = keeping("2");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 300);
    let orphan = "0123456789abcdef0123456789abcdef01234567";
    fs::create_dir_all(store::checkout_dir(&f.env, &key_for(&f.env), orphan)).unwrap();

    let b = advance(&mut f, "v2");
    assert_eq!(b.retention, Retention::Pruned { removed: 1 });
    assert_eq!(snapshot_dirs(&f), BTreeSet::from([a.commit, b.commit]));
}

/// Two receipts in one clock tick order by commit id, so the same
/// directory reads the same way on every pass: of two tied snapshots the
/// higher id ranks newer, and the lower one is the one past the count.
#[test]
fn tied_receipts_order_by_commit_id() {
    let mut f = keeping("2");
    let a = sync(&f.env, REPO, None).unwrap();
    let b = advance(&mut f, "v2");
    let tick = SystemTime::now() - Duration::from_secs(300);
    date(&f, &a.commit, tick);
    date(&f, &b.commit, tick);
    let (lower, higher) = match a.commit < b.commit {
        true => (a.commit, b.commit),
        false => (b.commit, a.commit),
    };

    let c = advance(&mut f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 1 });
    assert_eq!(
        snapshot_dirs(&f),
        BTreeSet::from([higher, c.commit]),
        "{lower} should be gone"
    );
}

/// A removal that fails part way reports what it did remove and why it
/// stopped, naming the snapshot it stopped on; the sync pass carries both
/// the count and the note. Not run as root, which removes a read-only
/// directory like any other.
#[cfg(unix)]
#[test]
fn a_removal_that_stops_part_way_reports_the_count_and_the_reason() {
    use std::os::unix::fs::PermissionsExt;
    if crate::privilege::acting_as_root() {
        return;
    }
    // Three snapshots accumulate under a wide count, then one publish
    // under a count of zero has all three to remove.
    let mut f = keeping("5");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 500);
    let b = advance(&mut f, "v2");
    age(&f, &b.commit, 400);
    let c = advance(&mut f, "v3");
    age(&f, &c.commit, 300);
    // Removal runs newest first: c goes, b cannot, a is never reached.
    let stuck = store::checkout_dir(&f.env, &key_for(&f.env), &b.commit);
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o555)).unwrap();
    f.env = f.env.clone().with_var(KEEP_VAR, "0");

    let d = advance(&mut f, "v4");
    fs::set_permissions(&stuck, fs::Permissions::from_mode(0o755)).unwrap();
    let Retention::Stopped { removed, reason } = &d.retention else {
        panic!("{:?}", d.retention);
    };
    assert_eq!(*removed, 1);
    assert!(reason.contains(&stuck.display().to_string()), "{reason}");
    assert!(!held(&f, &c.commit), "the first removal went through");
    assert!(held(&f, &a.commit), "removal stopped before the oldest");

    let synced = Synced::of(REPO, d);
    assert_eq!(synced.removed_snapshots, 1);
    assert_eq!(synced.notes.len(), 1, "{:?}", synced.notes);
    assert!(synced.notes[0].contains(REPO), "{:?}", synced.notes);
}

/// Resolving a source for a scope, with no sync of that scope before it,
/// stands the invocation in it the same way: the manifest the resolve
/// reads is named first. The resolve hands out the tip, not the commit
/// the lock names, so only the standing scope's lock keeps that one.
#[test]
fn a_resolve_alone_stands_in_its_scope() {
    let mut f = keeping("5");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 500);
    let b = advance_here(&f, "v2");
    age(&f, &b.commit, 400);
    let scope = unregistered_clone(&f, &a.commit);

    next_invocation(&mut f);
    f.env = f.env.clone().with_var(KEEP_VAR, "0");
    let manifest = crate::engine::ops::manifest_for_reading(&f.env, &scope).unwrap();
    let resolved = crate::source::resolve(&f.env, &scope, "cat", &manifest).unwrap();
    let crate::source::SourceState::Ready(ready) = resolved else {
        panic!("{resolved:?}");
    };
    assert_eq!(ready.commit.as_deref(), Some(b.commit.as_str()));

    let c = advance_here(&f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 0 });
    assert!(held(&f, &a.commit), "the clone's lock names this commit");
}

/// A checkout the store handed this invocation stays for the rest of it,
/// whatever it publishes after: a plan resolves one pin after another and
/// reads every root once the last has landed. The next invocation holds
/// nothing, and the same publish takes it.
#[test]
fn a_checkout_this_invocation_was_handed_is_never_removed() {
    let mut f = keeping("0");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 500);

    next_invocation(&mut f);
    assert!(store::published(&f.env, &key_for(&f.env), &a.commit).is_some());
    let b = advance_here(&f, "v2");
    assert_eq!(b.retention, Retention::Pruned { removed: 0 });
    age(&f, &b.commit, 400);
    let c = advance_here(&f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 0 });
    assert!(held(&f, &a.commit), "handed out this invocation");
    assert!(held(&f, &b.commit), "published this invocation");
    age(&f, &c.commit, 300);

    let d = advance(&mut f, "v4");
    assert_eq!(d.retention, Retention::Pruned { removed: 3 });
    assert_eq!(snapshot_dirs(&f), BTreeSet::from([d.commit]));
}

/// A scope this invocation stands in protects what its lock names,
/// whether or not the registry knows the scope: a cloned project is used
/// through the CLI's walk-up without ever being registered, and reading
/// its manifest is what stands the invocation in it. An invocation that
/// stands elsewhere does not read that lock.
#[test]
fn the_lock_of_a_scope_this_invocation_stands_in_holds_its_commits() {
    let mut f = keeping("0");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 500);
    let scope = unregistered_clone(&f, &a.commit);

    next_invocation(&mut f);
    write_skill(&f.upstream, "v2");
    commit(&f.upstream, "two");
    let manifest = crate::engine::ops::manifest_for_reading(&f.env, &scope).unwrap();
    let synced = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(synced.removed_snapshots, 0, "{:?}", synced.notes);
    assert!(held(&f, &a.commit), "the clone's lock names this commit");

    // Standing in the personal scope alone, whose lock names nothing here,
    // the clone's commit goes with the one the last pass published.
    let c = advance(&mut f, "v3");
    assert_eq!(c.retention, Retention::Pruned { removed: 2 });
    assert_eq!(snapshot_dirs(&f), BTreeSet::from([c.commit]));
}

/// Every commit a registered scope's lock names stays, whichever field
/// names it: a source's resolution in the personal lock, an installation's
/// provenance and a set's resolution in a project's. Nothing else past the
/// count does.
#[test]
fn a_snapshot_a_lock_names_is_never_removed() {
    let mut f = keeping("0");
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

    let b = advance(&mut f, "v2");
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

    let c = advance(&mut f, "v3");
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

    let d = advance(&mut f, "v4");
    assert_eq!(d.retention, Retention::Pruned { removed: 0 });
    assert!(held(&f, &c.commit), "the project's set names this commit");
    age(&f, &d.commit, 200);
    let e = advance(&mut f, "v5");
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
        next_invocation(&mut f);
        plant(&mut f);

        let b = advance_here(&f, "v2");
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

/// A removal that stopped is retried by the next publish for that
/// repository, not by the next refresh: one over an unchanged HEAD
/// publishes nothing, so it judges nothing, reports nothing, and leaves
/// what stands standing even once the keep set reads again.
#[test]
fn a_refresh_that_publishes_nothing_retries_no_stopped_removal() {
    let mut f = keeping("0");
    let a = sync(&f.env, REPO, None).unwrap();
    age(&f, &a.commit, 300);
    next_invocation(&mut f);
    f.env = f.env.clone().with_var(KEEP_VAR, "many");
    let b = advance_here(&f, "v2");
    assert!(
        matches!(b.retention, Retention::Stopped { .. }),
        "{:?}",
        b.retention
    );
    let standing = snapshot_dirs(&f);
    assert!(standing.contains(&a.commit), "{standing:?}");

    next_invocation(&mut f);
    f.env = f.env.clone().with_var(KEEP_VAR, "0");
    let again = sync(&f.env, REPO, None).unwrap();
    assert_eq!(again.commit, b.commit);
    assert_eq!(again.retention, Retention::Untouched);
    assert_eq!(snapshot_dirs(&f), standing);
}

/// A pass over a manifest's sources counts what it removed across every
/// source for the terminal, and a stopped removal is one of its notes.
#[test]
fn a_sync_pass_reports_what_it_removed_and_what_it_could_not() {
    let mut f = keeping("0");
    let other_repo = "owner/other";
    let other = f._tmp.path().join("base").join(other_repo);
    fs::create_dir_all(other.join("skills/gh")).unwrap();
    write_skill(&other, "other v1");
    git(&other, &["init", "--quiet", "-b", "main"]);
    commit(&other, "one");
    let manifest = declaring(&Scope::Global, &[("cat", REPO), ("other", other_repo)]);
    let first = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(first.removed_snapshots, 0);
    assert!(first.notes.is_empty(), "{:?}", first.notes);
    let a = sync(&f.env, REPO, None).unwrap().commit;
    age(&f, &a, 300);
    let other_a = sync(&f.env, other_repo, None).unwrap();
    let other_receipt = store::receipt_path(
        &f.env,
        &store::repo_key(&crate::remote::clone_url(&f.env, other_repo)),
        &other_a.commit,
    );
    fs::File::options()
        .write(true)
        .open(other_receipt)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(300))
        .unwrap();

    next_invocation(&mut f);
    write_skill(&f.upstream, "v2");
    commit(&f.upstream, "two");
    write_skill(&other, "other v2");
    commit(&other, "two");
    let second = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(second.removed_snapshots, 2, "one per source");
    assert!(second.notes.is_empty(), "{:?}", second.notes);

    next_invocation(&mut f);
    f.env = f.env.clone().with_var(KEEP_VAR, "many");
    write_skill(&f.upstream, "v3");
    commit(&f.upstream, "three");
    let third = sync_sources(&f.env, &manifest).unwrap();
    assert_eq!(third.removed_snapshots, 0);
    assert_eq!(third.notes.len(), 1, "{:?}", third.notes);
    assert!(third.notes[0].contains(KEEP_VAR), "{:?}", third.notes);
}
