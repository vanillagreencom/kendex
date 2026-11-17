use kendex_core::check_catalog::CheckedItem;
use kendex_core::model::ItemKind;
use kendex_core::quality::{
    AuditResult, Finding, RULESET_VERSION, SafetyScore, Severity, SkippedRule,
};

use super::*;
use crate::ui::testing::{plain, rich, tagged};

fn structural(severity: &'static str, file: &str, line: Option<u32>) -> CheckFinding {
    CheckFinding {
        file: file.to_owned(),
        line,
        kind: "skill",
        name: "review".to_owned(),
        pass: "claude".to_owned(),
        severity,
        rule: None,
        message: format!("{severity} message"),
        fix: format!("{severity} fix"),
    }
}

fn advisory(findings: &[(Severity, &str)], skipped: bool) -> AuditResult {
    AuditResult {
        findings: findings
            .iter()
            .map(|(severity, message)| Finding {
                rule: "rule".to_owned(),
                severity: *severity,
                location: "skills/review/SKILL.md".to_owned(),
                line: Some(3),
                message: (*message).to_owned(),
                remediation: "fix it".to_owned(),
            })
            .collect(),
        mentions: Vec::new(),
        accepted: Vec::new(),
        skipped: match skipped {
            true => vec![SkippedRule {
                rule: "network".to_owned(),
                reason: "no scripts to read".to_owned(),
            }],
            false => Vec::new(),
        },
        safety: SafetyScore {
            score: 100u32.saturating_sub(findings.len() as u32 * 10),
            deductions: Vec::new(),
        },
        quality: None,
        ruleset: RULESET_VERSION,
    }
}

/// A catalog with breakage, a warning, a note, a safety finding, an unread
/// rule and a clean item: each block in the order a script reads it.
fn checked() -> CatalogCheck {
    CatalogCheck {
        catalog: vec![structural("error", "kendex.toml", Some(4))],
        items: vec![
            CheckedItem {
                kind: ItemKind::Skill,
                name: "review".to_owned(),
                file: "skills/review".to_owned(),
                structural: vec![
                    structural("warning", "skills/review/SKILL.md", None),
                    structural("note", "skills/review/extra", None),
                ],
                advisory: advisory(&[(Severity::High, "runs curl")], true),
            },
            CheckedItem {
                kind: ItemKind::Agent,
                name: "helper".to_owned(),
                file: String::new(),
                structural: Vec::new(),
                advisory: advisory(&[], false),
            },
        ],
    }
}

#[test]
fn catalog_check_plain_keeps_the_script_lines() {
    let lines = lines(&plain(), &checked(), 1);
    let expected_prefix = [
        "[error] claude: kendex.toml:4: error message",
        "    fix: error fix",
        "[warning] claude: skills/review/SKILL.md: warning message",
        "    fix: warning fix",
        "[note] claude: skills/review/extra: note message",
        "    fix: note fix",
        "safety: skill review at skills/review scores 90/100",
    ];
    assert_eq!(
        lines[..expected_prefix.len()],
        expected_prefix,
        "{lines:#?}"
    );
    let rest = &lines[expected_prefix.len()..];
    assert!(rest[0].starts_with("  [high] runs curl"), "{rest:#?}");
    assert!(
        rest[1].starts_with("  not fully checked: 1 rule(s)"),
        "{rest:#?}"
    );
    assert_eq!(
        rest[2..],
        [
            "safety: agent helper scores 100/100",
            "2 package(s): 1 breakage, 1 advisory, 1 safety finding(s)",
        ]
    );
}

#[test]
fn catalog_check_rich_snapshot() {
    let drawn = tagged(&lines(&rich(100), &checked(), 1));
    assert_eq!(
        drawn[..4],
        [
            "  <31>✗</> [error] claude: kendex.toml:4: error message",
            "    <90>fix: error fix</>",
            "  <33>!</> [warning] claude: skills/review/SKILL.md: warning message",
            "    <90>fix: warning fix</>",
        ],
        "{drawn:#?}"
    );
    assert_eq!(
        drawn[6], "  <33>◐</> safety: skill review at skills/review scores 90/100",
        "{drawn:#?}"
    );
    assert!(
        drawn[7].starts_with("    <90>[high] runs curl"),
        "{drawn:#?}"
    );
    assert_eq!(
        drawn[9..],
        [
            "  <32>✓</> safety: agent helper scores 100/100",
            "",
            "<31>✗</> <1>2 package(s): 1 breakage, 1 advisory, 1 safety finding(s)</>",
        ],
        "{drawn:#?}"
    );
}

/// The tally closes on what the run's exit says: a failure where findings
/// fail it, a decision where only advisories remain, done when clean.
#[test]
fn catalog_check_tally_status() {
    let advisory_only = CatalogCheck {
        catalog: vec![structural("warning", "kendex.toml", None)],
        items: Vec::new(),
    };
    let cases = [
        (CatalogCheck::default(), 0, "<32>✓</>"),
        (advisory_only.clone(), 0, "<33>!</>"),
        (advisory_only, 1, "<31>✗</>"),
    ];
    for (report, failing, glyph) in cases {
        let drawn = tagged(&lines(&rich(100), &report, failing));
        let last = drawn.last().map(String::as_str).unwrap_or_default();
        assert!(last.starts_with(glyph), "{failing}: {drawn:#?}");
    }
}
