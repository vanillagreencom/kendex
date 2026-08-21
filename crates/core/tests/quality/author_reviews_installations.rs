//! One item installed for several tools is several installations, and each
//! answers for itself.
//!
//! The unit of every answer in the audit is the installation, not the item:
//! one row, one lock entry, one revision, one record, one decision. An
//! answer keyed by the item alone is handed to every tool that installed
//! it, which is how an acceptance leaks across tools and a token records a
//! click against an installation nobody was looking at.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::decisions::DecisionState;

use super::author_reviews::{declare, observed_rows};
use super::fixture::{fixture, plan, skill};

/// An installation is the unit of every answer: one row, one lock entry,
/// one record, one decision.
///
/// The same item installed for two tools is two installations, and every
/// answer about one has to name that one. A reading that keys its answers
/// by the item alone hands whichever installation it kept to both rows —
/// so an acceptance recorded for one tool reads as applying to the other,
/// and the token a person clicks records against an installation they were
/// not looking at.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn each_tool_answers_for_its_own_installation() {
    let f = fixture();
    skill(&f.source, "mild", "Then chmod 777 build.sh so it runs.\n");
    declare(&f, "\n[skills.mild]\nsource = \"cat\"\n");
    let path = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&path).unwrap().replace(
        "harnesses = [\"claude\"]",
        "harnesses = [\"claude\", \"codex\"]",
    );
    fs::write(&path, text).unwrap();
    let report = plan(&f, &[]);
    apply::execute(&f.env, &report.plan, None).unwrap();

    let rows = observed_rows(&f, "mild");
    assert!(rows.len() > 1, "two tools install it");
    for row in &rows {
        for decision in &row.decisions {
            let token = decision.token.as_deref().expect("the content is readable");
            assert!(
                token.starts_with(&format!("skill:mild:{}#", row.harness.name())),
                "{} is offered a token for its own installation: {token}",
                row.harness.name()
            );
        }
    }

    // One tool's acceptance is one tool's. The other has decided nothing.
    let accepted = &rows[0];
    let minted = kendex_core::quality::overrides::mint(
        accepted.review_hash.as_deref().expect("readable"),
        &accepted.findings,
        None,
    );
    let text = format!(
        "{}\n[safety-overrides.\"skill:mild:{}\"]\nreview-hash = \"{}\"\nruleset = {}\nfindings = [{}]\ngranted-at = \"{}\"\n",
        fs::read_to_string(&path).unwrap(),
        accepted.harness.name(),
        minted.review_hash,
        minted.ruleset,
        minted
            .findings
            .iter()
            .map(|print| format!("\"{print}\""))
            .collect::<Vec<String>>()
            .join(", "),
        minted.granted_at,
    );
    fs::write(&path, text).unwrap();

    for row in observed_rows(&f, "mild") {
        let accepted_here = row
            .decisions
            .iter()
            .any(|decision| matches!(decision.state, DecisionState::Accepted { .. }));
        assert_eq!(
            accepted_here,
            row.harness == accepted.harness,
            "{} reads its own acceptance and nobody else's: {:?}",
            row.harness.name(),
            row.decisions
        );
    }
}
