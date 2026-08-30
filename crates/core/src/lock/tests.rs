use std::path::Path;

use super::*;
use crate::error::CoreError;

#[test]
fn lock_round_trips_and_missing_file_is_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    assert_eq!(load(&path).unwrap().entries.len(), 0);

    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "github", HarnessId::Claude),
        LockEntry {
            registration: None,
            left_pi_reserved_name: false,
            name: "github".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "kendex".into(),
            source_repo: "vanillagreencom/kendex".into(),
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
            source_hash: "abc".into(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: None,
            reasons: BTreeSet::from([
                Reason::Requested,
                Reason::RequiredBy {
                    by: InstallRef {
                        source: "kendex".into(),
                        kind: ItemKind::Skill,
                        name: "dev".into(),
                        harness: HarnessId::Claude,
                    },
                },
                Reason::MemberOf {
                    bundle: BundleRef {
                        source: "kendex".into(),
                        name: "starter".into(),
                    },
                },
            ]),
        },
    );
    save(&path, &lock).unwrap();
    let loaded = load(&path).unwrap();
    assert_eq!(
        loaded.root,
        Some(tmp.path().canonicalize().unwrap()),
        "the write names the project it went down under"
    );
    assert_eq!(
        Lock {
            root: None,
            ..loaded
        },
        lock
    );
    assert!(std::fs::read_to_string(&path).unwrap().ends_with('\n'));
}

/// A record from before installations carried reasons reads back as one
/// the user asked for — the only reading that invents nothing.
#[test]
fn entries_without_reasons_read_as_requested() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(
        &path,
        format!(
            r#"{{"version":2,"root":{},"entries":{{"skill:gh:claude":{{"name":"gh","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true}}}}}}"#,
            json(tmp.path())
        ),
    )
    .unwrap();
    let lock = load(&path).unwrap();
    let entry = &lock.entries["skill:gh:claude"];
    assert_eq!(entry.reasons, BTreeSet::from([Reason::Requested]));
}

#[test]
fn timestamps_are_iso8601() {
    let ts = crate::clock::timestamp();
    assert_eq!(ts.len(), 20);
    assert!(ts.ends_with('Z'));
    assert!(ts.starts_with("20"));
}

/// A v1 lock (bare-name keys, a `harnesses` array, no singular
/// `harness`) must read as a recognized legacy shape, never as a raw
/// serde "missing field" error.
#[test]
fn a_v1_lock_reads_as_legacy_not_a_parse_error() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(
        &path,
        r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"kendex","source_repo":"vanillagreencom/kendex","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#,
    )
    .unwrap();
    assert!(matches!(load_file(&path).unwrap(), LockFile::Legacy { .. }));
    assert!(matches!(load(&path), Err(CoreError::LegacyLock { .. })));
}

/// Malformed JSON is reported as a damaged lock, distinct from the v1
/// and future-version cases.
#[test]
fn unparseable_json_is_reported_as_corrupt() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(&path, "{not json").unwrap();
    assert!(matches!(
        load_file(&path),
        Err(CoreError::LockCorrupt { .. })
    ));
    assert!(matches!(load(&path), Err(CoreError::LockCorrupt { .. })));
}

/// A lock a future kendex wrote refuses to load rather than being
/// silently misread or corrupted by an older build. That refusal is what
/// every bump buys, so it is held at exactly one version above this
/// build's — the version the next bump hands to the build before it — and
/// against a record this project could otherwise adopt, leaving the
/// version as the only thing refusing it.
#[test]
fn a_newer_lock_refuses_to_load() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    let ahead = i64::from(LOCK_VERSION) + 1;
    std::fs::write(
        &path,
        format!(
            r#"{{"version":{ahead},"root":{},"entries":{{}}}}"#,
            json(tmp.path())
        ),
    )
    .unwrap();
    let refused = load_file(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::SchemaTooNew { found, .. } if found == ahead),
        "{refused}"
    );
    let refused = load(&path).unwrap_err();
    assert!(
        matches!(refused, CoreError::SchemaTooNew { found, .. } if found == ahead),
        "{refused}"
    );
}

/// An empty `entries` map is indistinguishable between v1 and v2 — it
/// reads as v2, since that is the only reading a fresh scope can mean.
#[test]
fn an_empty_lock_reads_as_current() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(
        &path,
        format!(
            r#"{{"version":1,"root":{},"entries":{{}}}}"#,
            json(tmp.path())
        ),
    )
    .unwrap();
    assert!(matches!(load_file(&path).unwrap(), LockFile::Current(_)));
}

/// A path as JSON data rather than text spliced into a literal: a
/// backslash in one is an escape JSON has to be told about.
fn json(path: &Path) -> String {
    serde_json::to_string(&path.display().to_string()).unwrap()
}

/// A record whose `emitted.paths` reach outside the project holding it, as
/// written by hand under `key` — the shape a lock copied from another
/// checkout has. `wrote_it` is the project the record names as its own;
/// `None` writes the field out, which is what the global lock holds.
fn recording(path: &Path, key: &str, emitted: &Path, wrote_it: Option<&Path>) {
    std::fs::write(
        path,
        format!(
            r#"{{"version":{LOCK_VERSION},{}"entries":{{"{key}":{{"name":"gh","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"vanillagreencom/kendex","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true,"emitted":{{"kind":"skill","name":"gh","paths":[{}]}}}}}}}}"#,
            wrote_it.map_or(String::new(), |root| format!(
                r#""root":{},"#,
                json(root)
            )),
            // A path is data here, not text spliced into the literal: a
            // backslash in it is an escape JSON has to be told about.
            json(emitted)
        ),
    )
    .unwrap();
}

/// Containment cannot answer whose record this is: a checkout nested below
/// this root sits inside it, so every path a lock carried out of that
/// checkout names passes the boundary. The record says which root wrote it,
/// and the refusal names both so the reader can see which is which.
#[test]
fn a_project_lock_another_project_wrote_is_refused_naming_both() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    let nested = root.join("vendor/thing");
    std::fs::create_dir_all(&nested).unwrap();
    let path = root.join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &nested.join(".agents/skills/gh"),
        Some(&nested),
    );

    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockFromAnotherProject { recorded, root: reading, .. }
                if recorded == &nested && reading == &root
        ),
        "{refused:?}"
    );
}

/// A record naming no project is refused rather than adopted: nothing knows
/// who wrote it, and reading it as this project's is the guess the refusal
/// exists to stop.
#[test]
fn a_project_lock_naming_no_project_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    recording(
        &path,
        "skill:gh:claude",
        &root.join(".agents/skills/gh"),
        None,
    );

    assert!(matches!(
        load(&path),
        Err(CoreError::LockWithoutProject { .. })
    ));
}

/// A root has one spelling (invariant 17), and neither end holds it: the
/// record goes down canonical while a caller may name the same directory
/// through a link — which is the spelling macOS hands every temp path,
/// `/var` fronting `/private/var`. Compared as text a root does not equal
/// itself, and every project reached that way loses its own lock.
#[test]
#[cfg(unix)]
fn a_project_lock_read_through_a_linked_spelling_of_its_root_is_still_its_own() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let via = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &via).unwrap();

    let lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    save(&via.join(LOCK_FILE), &lock).unwrap();

    assert_eq!(
        load(&via.join(LOCK_FILE)).unwrap().root,
        Some(real.clone()),
        "the write records the directory, not the way in"
    );
    load(&real.join(LOCK_FILE)).expect("its own root, spelled directly");
    load(&via.join(LOCK_FILE)).expect("its own root, spelled through the link");
}

/// The write end of the ownership rule: what a project lock cannot hand out
/// it cannot be made to hold.
#[test]
fn a_project_lock_is_never_written_naming_another_project() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    let nested = root.join("vendor/thing");
    std::fs::create_dir_all(&nested).unwrap();
    let path = root.join(LOCK_FILE);

    let lock = Lock {
        version: LOCK_VERSION,
        root: Some(nested),
        ..Lock::default()
    };

    assert!(matches!(
        save(&path, &lock),
        Err(CoreError::LockFromAnotherProject { .. })
    ));
    assert!(!path.exists(), "and nothing is left at the path");
}

/// A project lock may claim only what sits under its own root: the paths a
/// refresh reads back are the ones it takes off disk, and past the root
/// those belong to another project.
#[test]
fn a_project_lock_claiming_another_tree_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, Some(&root));

    let refused = load(&path).unwrap_err();
    assert!(
        matches!(
            &refused,
            CoreError::LockOutsideProject { key, recorded, .. }
                if key == "skill:gh:claude" && recorded == &elsewhere
        ),
        "{refused:?}"
    );

    recording(
        &path,
        "skill:gh:claude",
        &root.join(".agents/skills/gh"),
        Some(&root),
    );
    assert_eq!(load(&path).unwrap().entries.len(), 1, "its own root loads");
}

/// The record is refused at the writing end too: what a project lock cannot
/// hand out it cannot be made to hold.
#[test]
fn a_project_lock_is_never_written_claiming_another_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("here");
    std::fs::create_dir(&root).unwrap();
    let path = root.join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");

    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        LockEntry {
            registration: None,
            left_pi_reserved_name: false,
            name: "gh".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "kendex".into(),
            source_repo: "vanillagreencom/kendex".into(),
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
            source_hash: "abc".into(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: Some(EmittedArtifact {
                kind: ItemKind::Skill,
                name: "gh".into(),
                paths: vec![elsewhere.clone()],
            }),
            reasons: BTreeSet::from([Reason::Requested]),
        },
    );

    assert!(matches!(
        save(&path, &lock),
        Err(CoreError::LockOutsideProject { .. })
    ));
    assert!(!path.exists(), "and nothing is left at the path");
}

/// A lock named relatively is the current directory's, and nothing absolute
/// is under that. Read as the empty prefix `Path::parent` gives back, every
/// path would pass.
#[test]
fn a_relatively_named_project_lock_still_has_a_boundary() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(LOCK_FILE);
    let elsewhere = tmp.path().join("there/.agents/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, Some(tmp.path()));
    let text = std::fs::read_to_string(&path).unwrap();

    assert!(matches!(
        parse_text(Path::new(LOCK_FILE), &text),
        Err(CoreError::LockOutsideProject { .. })
    ));
}

/// The global lock has no single root — each harness owns a directory of
/// its own, and none of them is under the app directory the lock sits in.
#[test]
fn the_global_lock_records_paths_outside_its_own_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let app = tmp.path().join("config/kendex");
    std::fs::create_dir_all(&app).unwrap();
    let path = app.join("lock.json");
    // A harness directory, which is nowhere near the app's own.
    let elsewhere = tmp.path().join("home/.claude/skills/gh");
    recording(&path, "skill:gh:claude", &elsewhere, None);
    assert_eq!(load(&path).unwrap().entries.len(), 1);
}
