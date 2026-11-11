use super::*;
use crate::test_util::rooted;

fn evidence_lock() -> Lock {
    let by = InstallRef {
        source: "catalog\"雪".into(),
        kind: ItemKind::Hook,
        name: "judge".into(),
        harness: HarnessId::Codex,
    };
    let row = RequirerProvenance {
        installation: by.clone(),
        source_repo: "./catalog".into(),
        reasons: BTreeSet::from([Reason::MemberOf {
            bundle: BundleRef {
                source: by.source.clone(),
                name: "crew".into(),
            },
        }]),
    };
    let mut other = row.clone();
    other.source_repo = "./old-catalog".into();
    other.reasons.clear();
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    for (name, ancestry) in [
        ("a", None),
        ("b", Some(RequirerAncestry::default())),
        (
            "c",
            Some(RequirerAncestry {
                rows: vec![],
                held: true,
            }),
        ),
        (
            "d",
            Some(RequirerAncestry {
                rows: vec![row.clone(), other.clone(), row.clone()],
                held: true,
            }),
        ),
        (
            "e",
            Some(RequirerAncestry {
                rows: vec![other, row],
                held: false,
            }),
        ),
    ] {
        let mut installed = entry(None);
        installed.name = name.into();
        installed.machine = None;
        installed
            .reasons
            .insert(Reason::RequiredBy { by: by.clone() });
        installed.requirer_provenance = ancestry;
        lock.entries
            .insert(format!("handwritten-{name}"), installed);
    }
    lock
}

#[test]
fn facts_are_shared_without_merging_recorder_readings() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let path = root.join(LOCK_FILE);
    let lock = evidence_lock();
    save(&path, &lock).unwrap();
    assert_eq!(load(&path).unwrap(), lock);
    let text = std::fs::read_to_string(&path).unwrap();
    assert_eq!(text, committed_text(&path, &lock).unwrap());
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["ancestryRows"].as_object().unwrap().len(), 2);
    assert_eq!(value["reasons"].as_object().unwrap().len(), 3);
    assert_eq!(
        value["installations"].as_object().unwrap().len(),
        lock.entries.len() + 1
    );
    assert!(text.contains('雪'));

    // Noncanonical external tables and duplicate facts are harmless; the
    // next write canonicalizes them, not the read.
    let mut noncanonical = value.clone();
    let (old, fact) = value["installations"]
        .as_object()
        .unwrap()
        .iter()
        .next()
        .unwrap();
    noncanonical["installations"]["alias"] = fact.clone();
    for entry in noncanonical["entries"]
        .as_object_mut()
        .unwrap()
        .values_mut()
    {
        if entry["installation"] == old.as_str() {
            entry["installation"] = "alias".into();
        }
    }
    let decoded = parse_text(&path, &serde_json::to_string(&noncanonical).unwrap()).unwrap();
    assert_eq!(decoded, lock);
    assert_eq!(committed_text(&path, &decoded).unwrap(), text);

    // Partial/truncated records must not turn a missing fact into no
    // ancestry or no reasons. Exercise every reference owner on disk.
    for table in ["installations", "reasons", "ancestryRows"] {
        let mut corrupt = value.clone();
        corrupt[table] = serde_json::json!({});
        assert!(matches!(
            parse_text(&path, &serde_json::to_string(&corrupt).unwrap()),
            Err(CoreError::LockCorrupt { .. })
        ));
    }
}

fn data_lines(text: &str) -> Vec<&str> {
    // JSON's comma on a former last member is separator punctuation, not
    // a rewritten fact or reference. Ignore only that punctuation.
    text.lines()
        .map(|line| line.trim_end_matches(','))
        .collect()
}

#[test]
fn unrelated_added_and_removed_items_leave_existing_lines_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let path = root.join(LOCK_FILE);
    let original = evidence_lock();
    save(&path, &original).unwrap();
    let before = std::fs::read_to_string(&path).unwrap();
    let mut added = original.clone();
    let mut installed = entry(None);
    installed.machine = None;
    installed.name = "new-item".into();
    installed.reasons.insert(Reason::MemberOf {
        bundle: BundleRef {
            source: "new".into(),
            name: "set".into(),
        },
    });
    installed.requirer_provenance = Some(RequirerAncestry {
        held: false,
        rows: vec![RequirerProvenance {
            installation: InstallRef {
                source: "new".into(),
                kind: ItemKind::Skill,
                name: "ancestor".into(),
                harness: HarnessId::Pi,
            },
            source_repo: "./new".into(),
            reasons: BTreeSet::from([Reason::Requested]),
        }],
    });
    added.entries.insert("handwritten-bb".into(), installed);
    save(&path, &added).unwrap();
    let after = std::fs::read_to_string(&path).unwrap();
    let before_value: serde_json::Value = serde_json::from_str(&before).unwrap();
    let after_value: serde_json::Value = serde_json::from_str(&after).unwrap();
    for table in ["installations", "reasons", "ancestryRows", "entries"] {
        for (key, value) in before_value[table].as_object().unwrap() {
            assert_eq!(&after_value[table][key], value, "{table}/{key}");
        }
    }
    // A subsequence, not a set: preserve repeated lines and ordering too.
    let after_lines = data_lines(&after);
    let mut remaining = after_lines.as_slice();
    for line in data_lines(&before) {
        let index = remaining
            .iter()
            .position(|candidate| *candidate == line)
            .expect("an existing line changed");
        remaining = &remaining[index + 1..];
    }
    assert_eq!(load(&path).unwrap(), added);
    added.entries.remove("handwritten-bb");
    save(&path, &added).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
}

#[test]
fn shared_ancestry_costs_entries_plus_distinct_facts_not_their_product() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let path = root.join(LOCK_FILE);
    let mut lock = evidence_lock();
    let shared = lock.entries["handwritten-d"].clone();
    for n in 0..100 {
        let mut installed = shared.clone();
        installed.name = format!("shared-{n}");
        lock.entries.insert(installed.name.clone(), installed);
    }
    let rows = shared.requirer_rows().len();
    let line_budget = lock.entries.len() * 14 + 50;
    let byte_budget = lock.entries.len() * 550 + 3000;
    let within_budget =
        |text: &str| text.lines().count() <= line_budget && text.len() <= byte_budget;
    let compact = committed_text(&path, &lock).unwrap();
    assert!(
        within_budget(&compact),
        "lines={} bytes={}",
        compact.lines().count(),
        compact.len()
    );
    // The original expanded producer is the retained must-fail input for
    // this measuring instrument; it repeats the same three rows per entry.
    let expanded = serde_json::to_string_pretty(&lock).unwrap();
    assert!(rows > 1);
    assert!(!within_budget(&expanded));
    assert_eq!(parse_text(&path, &compact).unwrap(), lock);
}
