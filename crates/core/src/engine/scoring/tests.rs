use super::*;
use crate::quality::RULESET_VERSION;

/// The app and the CLI read a scored row's advisory fields beside the
/// row's own, at the top level. `AuditResult` is flattened to put them
/// there, and nothing in Rust holds that: nesting the payload under an
/// `advisory` key, or dropping a field from it, still compiles and still
/// passes every test that reads `row.advisory`. This is the wire itself.
#[test]
fn a_scored_row_serves_its_advisory_fields_at_the_top_level() {
    let row = ItemSafety {
        kind: ItemKind::Skill,
        name: "gh".to_owned(),
        harness: HarnessId::Claude,
        scope: Scope::Global,
        location: "skills/gh".to_owned(),
        advisory: crate::quality::sample::populated(),
    };

    let json = serde_json::to_value(&row).expect("a scored row serializes");
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
            "findings", "harness", "kind", "location", "name", "quality", "ruleset", "safety",
            "scope", "skipped"
        ],
        "{json}"
    );
    assert_eq!(json["safety"]["score"], 75, "{json}");
    assert_eq!(json["quality"]["score"], 60, "{json}");
    assert_eq!(json["ruleset"], RULESET_VERSION, "{json}");
    assert_eq!(json["findings"][0]["rule"], "rce", "{json}");
    assert_eq!(json["skipped"][0]["rule"], "secret-material", "{json}");
}
