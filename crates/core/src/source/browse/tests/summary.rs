//! A subscription's own summary: the arm every already-subscribed
//! marketplace page reads for its header.

use super::super::{SubscriptionRef, summary};
use super::{cat, project, skill, sources_decl};

#[test]
fn a_subscription_summary_answers_with_itself_and_counts_its_offer() {
    let tmp = tempfile::tempdir().unwrap();
    let catalog = tmp.path().join("catalog");
    skill(&catalog, "skills", "gh", "body");
    skill(&catalog, "skills", "extra", "body");
    let (env, scope) = project(tmp.path(), &sources_decl(&catalog));

    let report = summary(&env, &cat(&scope)).unwrap();
    assert_eq!(
        report.subscription,
        Some(SubscriptionRef {
            scope: scope.clone(),
            source: "cat".to_owned(),
        })
    );
    assert_eq!(report.provenance, catalog.display().to_string());
    assert_eq!(report.commit, None);
    assert_eq!(report.warning, None);
    assert_eq!(report.counts.get("skill"), Some(&2));
    assert_eq!(report.counts.len(), 1);
}
