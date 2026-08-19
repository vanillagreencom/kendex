//! What the report TYPES answer about themselves — chiefly which fields make a
//! scope count as drift, which is the exit code's whole basis.

use super::*;
use crate::config::ItemKind;

#[test]
fn has_drift_is_true_for_each_field_alone_and_available_is_not_drift() {
    let one = || vec![Item::new("x", ItemKind::Skill)];
    let cases: Vec<(&str, ScopeReport)> = vec![
        (
            "outdated",
            ScopeReport {
                outdated: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "removed",
            ScopeReport {
                removed: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "orphaned",
            ScopeReport {
                orphaned: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "phantom",
            ScopeReport {
                phantom: one(),
                ..ScopeReport::default()
            },
        ),
        (
            "missing_skill_refs",
            ScopeReport {
                missing_skill_refs: vec![MissingSkillRef {
                    agent: "a".into(),
                    skill: "s".into(),
                }],
                ..ScopeReport::default()
            },
        ),
        (
            "source_issues",
            ScopeReport {
                source_issues: vec![SourceIssue {
                    source: "owner/repo".into(),
                    problem: SourceProblem::Unresolvable {
                        entries: vec!["x".into()],
                        reason: "source not found".into(),
                        restore: Some("owner/repo".into()),
                    },
                }],
                ..ScopeReport::default()
            },
        ),
        (
            "invalid_names",
            ScopeReport {
                invalid_names: one(),
                ..ScopeReport::default()
            },
        ),
    ];
    for (field, report) in &cases {
        assert!(report.has_drift(), "{field} alone must be drift");
    }
    assert!(!ScopeReport::default().has_drift(), "all-empty control");
    let suggestion = ScopeReport {
        available: vec![AvailableItem {
            name: "beta".into(),
            kind: ItemKind::Skill,
            source: "owner/repo".into(),
        }],
        ..ScopeReport::default()
    };
    assert!(
        !suggestion.has_drift(),
        "available alone is a suggestion, never drift"
    );
}
