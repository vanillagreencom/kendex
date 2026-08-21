use super::*;

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
            name: "github".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "vstack".into(),
            source_repo: "vanillagreencom/vstack".into(),
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
                        source: "vstack".into(),
                        kind: ItemKind::Skill,
                        name: "dev".into(),
                        harness: HarnessId::Claude,
                        scope: Scope::Global,
                    },
                },
                Reason::MemberOf {
                    bundle: BundleRef {
                        source: "vstack".into(),
                        name: "starter".into(),
                        scope: Scope::Global,
                    },
                },
            ]),
        },
    );
    save(&path, &lock).unwrap();
    assert_eq!(load(&path).unwrap(), lock);
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
        r#"{"version":2,"entries":{"skill:gh:claude":{"name":"gh","kind":"skill","harness":"claude","source":"vstack","sourceRepo":"vanillagreencom/vstack","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true}}}"#,
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
        r#"{"version":1,"entries":{"gh":{"name":"gh","kind":"skill","source":"vstack","source_repo":"vanillagreencom/vstack","harnesses":["claude-code"],"method":"symlink","installed_at":"2026-01-01T00:00:00Z","source_hash":"abc"}}}"#,
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
/// silently misread or corrupted by an older build.
#[test]
fn a_newer_lock_refuses_to_load() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(&path, r#"{"version":99,"entries":{}}"#).unwrap();
    assert!(matches!(
        load_file(&path),
        Err(CoreError::SchemaTooNew { found: 99, .. })
    ));
    assert!(matches!(
        load(&path),
        Err(CoreError::SchemaTooNew { found: 99, .. })
    ));
}

/// Both spellings of the lock in one root refuse to load — whichever one
/// is asked for — and the error names both files.
#[test]
fn both_lock_spellings_in_one_root_refuse_to_load_naming_both() {
    let tmp = tempfile::tempdir().unwrap();
    let new = tmp.path().join(".kendex-lock.json");
    let old = tmp.path().join(".vstack-lock.json");
    std::fs::write(&new, r#"{"version":4,"entries":{}}"#).unwrap();
    std::fs::write(&old, r#"{"version":4,"entries":{}}"#).unwrap();
    for path in [&new, &old] {
        let error = load_file(path).unwrap_err();
        assert!(
            matches!(error, CoreError::BothGenerations { .. }),
            "{error}"
        );
        let text = error.to_string();
        assert!(
            text.contains(".kendex-lock.json") && text.contains(".vstack-lock.json"),
            "{text}"
        );
    }
}

/// An empty `entries` map is indistinguishable between v1 and v2 — it
/// reads as v2, since that is the only reading a fresh scope can mean.
#[test]
fn an_empty_lock_reads_as_current() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".kendex-lock.json");
    std::fs::write(&path, r#"{"version":1,"entries":{}}"#).unwrap();
    assert!(matches!(load_file(&path).unwrap(), LockFile::Current(_)));
}
