use super::*;

/// A package's advisory fields sit at the same top-level paths a scored
/// installation serves them at, so one reader in the app answers for both
/// pages. Flatten is what puts them there and the Rust type says nothing
/// about it, so the row is serialized here and read as JSON.
#[test]
fn an_offered_package_serves_its_advisory_fields_at_the_top_level() {
    let row = PackageSafety {
        kind: ItemKind::Skill,
        name: "gh".to_owned(),
        advisory: crate::quality::sample::populated(),
        notes: vec!["the tail of this skill was not read".to_owned()],
        content_hash: "b3a19f04c7d2e851".to_owned(),
        from_cache: true,
    };

    let json = serde_json::to_value(&row).expect("a package row serializes");
    let mut keys: Vec<&str> = json
        .as_object()
        .expect("a row is a JSON object")
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "contentHash",
            "findings",
            "fromCache",
            "kind",
            "name",
            "notes",
            "quality",
            "ruleset",
            "safety",
            "skipped"
        ],
        "{json}"
    );
    assert_eq!(json["safety"]["score"], 75, "{json}");
    assert_eq!(json["quality"]["score"], 60, "{json}");
    assert_eq!(json["ruleset"], RULESET_VERSION, "{json}");
    assert_eq!(json["findings"][0]["rule"], "rce", "{json}");
    assert_eq!(json["skipped"][0]["rule"], "secret-material", "{json}");
}

/// The cache record flattens the same payload, which is what keeps its
/// keys where they were before the payload became one type: an old record
/// still reads back, so the change costs nobody a re-score.
#[test]
fn a_cache_record_keeps_the_payload_at_the_top_level_too() {
    let record = CachedScore {
        format: CACHE_FORMAT,
        content_hash: "b3a19f04c7d2e851".to_owned(),
        discovery: DISCOVERY_VERSION,
        advisory: crate::quality::sample::populated(),
    };

    let json = serde_json::to_value(&record).expect("a cache record serializes");
    let mut keys: Vec<&str> = json
        .as_object()
        .expect("a record is a JSON object")
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "contentHash",
            "discovery",
            "findings",
            "format",
            "quality",
            "ruleset",
            "safety",
            "skipped"
        ],
        "{json}"
    );
    let read: CachedScore = serde_json::from_value(json).expect("and reads back");
    assert_eq!(read, record);
}
