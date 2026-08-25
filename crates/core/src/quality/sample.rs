//! One populated advisory payload, shared by the tests that pin how the
//! embedders put it on the wire. It lives here rather than beside either
//! of them because both have to assert the same five fields: two builders
//! could drift apart and each still pass.

use super::{
    AuditResult, Deduction, Finding, QualityScore, RULESET_VERSION, SafetyScore, Severity,
    SkippedRule,
};

/// One of everything. Every field carries something, so a field that stops
/// reaching the wire shows up as a key that is gone — an all-default
/// payload would serialize to keys that look the same either way.
pub(crate) fn populated() -> AuditResult {
    AuditResult {
        findings: vec![Finding {
            rule: "rce".to_owned(),
            severity: Severity::Critical,
            location: "SKILL.md:12".to_owned(),
            message: "this line pipes a download straight into a shell".to_owned(),
            remediation: "download it to a file and run it as its own step".to_owned(),
        }],
        skipped: vec![SkippedRule {
            rule: "secret-material".to_owned(),
            reason: "this item ships no script to read".to_owned(),
        }],
        safety: SafetyScore {
            score: 75,
            deductions: vec![Deduction {
                rule: "rce".to_owned(),
                location: "SKILL.md:12".to_owned(),
                severity: Severity::Critical,
                points: 25,
                repeat: false,
            }],
        },
        quality: Some(QualityScore {
            score: 60,
            dimensions: Vec::new(),
            anti_patterns: Vec::new(),
            penalty_percent: 100,
        }),
        ruleset: RULESET_VERSION,
    }
}
