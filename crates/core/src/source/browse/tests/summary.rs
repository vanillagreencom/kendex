//! A subscription's own summary: the arm every already-subscribed
//! marketplace page reads for its header.

use super::super::{SubscriptionRef, summary};
use super::{cat, project, skill, sources_decl};

#[test]
fn a_subscription_summary_answers_with_itself_and_counts_its_offer() {
    let tmp = tempfile::tempdir().unwrap();
    // Provenance speaks the canonical spelling `resolve` fixes where a
    // declared path enters, so the fixture enters canonical space once —
    // macOS reaches its temp directories through a `/var` → `/private/var`
    // symlink, and a declared spelling would compare unequal to it.
    let root = crate::paths::canonical(tmp.path()).unwrap();
    let catalog = root.join("catalog");
    skill(&catalog, "skills", "gh", "body");
    skill(&catalog, "skills", "extra", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let report = summary(&env, &cat(&scope)).unwrap();
    assert_eq!(
        report.subscription,
        Some(SubscriptionRef {
            scope: scope.clone(),
            source: "cat".to_owned(),
        })
    );
    assert_eq!(report.provenance, crate::paths::slashed(&catalog));
    assert_eq!(report.repo_key, None, "a path is no GitHub repository");
    assert_eq!(report.repo_identity, None, "a path is no repository at all");
    assert_eq!(report.commit, None);
    assert_eq!(report.warning, None);
    assert_eq!(report.counts.get("skill"), Some(&2));
    assert_eq!(report.counts.len(), 1);
}
