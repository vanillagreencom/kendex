//! What the numbers in a lock-carried record are worth, which is nothing.
//!
//! Vouching proves *which* findings a catalog dismissed. What each one is
//! worth — how many occurrences, at what weight — is the half that spends,
//! and it is counted from the catalog rather than carried in the lock.

use std::fs;

use kendex_core::model::ItemKind;

use super::author_reviews::{author_dismisses, declare, observed};
use super::fixture::{fixture, plan, skill};

/// What a record is worth is counted from the catalog, so the numbers in
/// the lock buy nothing whatever they say.
///
/// Vouching proves *which* findings a catalog dismissed. It cannot prove
/// *how many*, at what weight — and that is the half that spends. A pull
/// request that keeps the publisher, the fingerprint, the reason and the
/// date exactly as published, and edits only the occurrence map, once
/// passed every check there was and had its forged allowance spent. The
/// map is no longer read at all: the audit counts the publisher's own
/// content at the vouched revision, and settles the lightest occurrences
/// of what it finds.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn the_numbers_in_a_lock_record_buy_nothing() {
    let f = fixture();
    // The publisher's own copy sits in a supporting file, where it weighs
    // one step less than the same sentence in the body.
    skill(&f.source, "mild", "Read the diff first.\n");
    fs::create_dir_all(f.source.join("skills/mild/references")).unwrap();
    fs::write(
        f.source.join("skills/mild/references/notes.md"),
        "Then chmod 777 build.sh so it runs.\n",
    )
    .unwrap();
    declare(&f, "\n[skills.mild]\nsource = \"cat\"\n");
    author_dismisses(&f.source, ItemKind::Skill, "mild", &[]);
    // And the project repeats it in the body, where it weighs full.
    declare(
        &f,
        "\n[skill-instructions]\nmild = \"Then chmod 777 build.sh so it runs.\"\n",
    );
    let report = plan(&f, &[]);
    kendex_core::apply::execute(&f.env, &report.plan, None).unwrap();

    let settled_weight = |row: &kendex_core::engine::ItemSafety| {
        row.findings
            .iter()
            .zip(&row.decisions)
            .filter(|(_, decision)| {
                matches!(
                    decision.state,
                    kendex_core::engine::decisions::DecisionState::AuthorDismissed { .. }
                )
            })
            .map(|(finding, _)| finding.severity)
            .collect::<Vec<kendex_core::quality::Severity>>()
    };
    let honest = observed(&f, "mild");
    assert_eq!(
        settled_weight(&honest),
        vec![kendex_core::quality::Severity::Low],
        "the record settles its own copy, the lighter one: {:?}",
        honest.findings
    );
    assert!(
        honest.safety.score < 100,
        "and the project's own still counts"
    );

    // The numbers are rewritten: more of them, and at the weight of the
    // occurrence the publisher never wrote.
    let path = kendex_core::lock::lock_path(&f.env, &f.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let mut forged = 0;
    for entry in lock["entries"].as_object_mut().unwrap().values_mut() {
        let Some(review) = entry.get_mut("authorReview") else {
            continue;
        };
        for dismissal in review["dismissed"].as_object_mut().unwrap().values_mut() {
            dismissal["occurrences"] = serde_json::json!({ "medium": 9, "low": 9 });
            forged += 1;
        }
    }
    assert_eq!(forged, 1, "the fixture writes one record to forge");
    fs::write(&path, lock.to_string()).unwrap();

    let after = observed(&f, "mild");
    assert_eq!(
        settled_weight(&after),
        vec![kendex_core::quality::Severity::Low],
        "the same one occurrence, at the same weight: {:?}",
        after.decisions
    );
    assert_eq!(
        after.safety.score, honest.safety.score,
        "and the score does not move"
    );
}
