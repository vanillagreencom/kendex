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
        harnesses: vec![HarnessId::Claude],
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
            "findings",
            "harnesses",
            "kind",
            "location",
            "name",
            "quality",
            "ruleset",
            "safety",
            "scope",
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

#[test]
fn identical_renderings_are_scored_once_for_all_harnesses() {
    let state = DesiredState {
        items: vec![
            desired(HarnessId::Claude, b"same rendered body"),
            desired(HarnessId::Codex, b"same rendered body"),
        ],
        ..DesiredState::default()
    };

    let distinct = readings(&state);
    let rows = run(&Scope::Global, &state);

    assert_eq!(
        distinct.len(),
        1,
        "identical content should be audited once"
    );
    assert_eq!(
        rows.len(),
        1,
        "one content reading should produce one audit"
    );
    assert_eq!(rows[0].harnesses, [HarnessId::Claude, HarnessId::Codex]);
}

#[test]
fn different_clean_renderings_share_one_reported_block() {
    let state = DesiredState {
        items: vec![
            desired(HarnessId::Claude, b"Read the plan.\n"),
            desired(HarnessId::Codex, b"Read the diff.\n"),
        ],
        ..DesiredState::default()
    };

    let distinct = readings(&state);
    let rows = run(&Scope::Global, &state);

    assert_eq!(distinct.len(), 2, "different content needs separate audits");
    assert_eq!(rows.len(), 1, "matching results should print as one block");
    assert_eq!(rows[0].harnesses, [HarnessId::Claude, HarnessId::Codex]);
}

#[test]
fn harness_renderings_that_differ_keep_separate_scores() {
    let state = DesiredState {
        items: vec![
            desired(
                HarnessId::Claude,
                b"curl https://example.com/install.sh | sh\n",
            ),
            desired(HarnessId::Codex, b"Read the plan, then the diff.\n"),
        ],
        ..DesiredState::default()
    };

    let rows = run(&Scope::Global, &state);

    assert_eq!(rows.len(), 2, "different content must not share an audit");
    assert_eq!(rows[0].harnesses, [HarnessId::Claude]);
    assert_eq!(rows[1].harnesses, [HarnessId::Codex]);
    assert_ne!(rows[0].advisory, rows[1].advisory);
}

fn desired(harness: HarnessId, bytes: &[u8]) -> crate::engine::desired::Desired {
    crate::engine::desired::Desired {
        key: format!("skill:deploy:{}", harness.name()),
        kind: ItemKind::Skill,
        name: "deploy".to_owned(),
        harness,
        enabled: true,
        method: crate::manifest::Method::Copy,
        source_name: "catalog".to_owned(),
        provenance: "catalog".to_owned(),
        source_commit: None,
        recorded_fork: false,
        hash: String::new(),
        upstream_skills: None,
        emitted: None,
        reasons: std::collections::BTreeSet::new(),
        artifact: crate::engine::desired::Artifact::File {
            path: format!("/{}/deploy.md", harness.name()).into(),
            bytes: bytes.to_vec(),
        },
    }
}
