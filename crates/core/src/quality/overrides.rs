//! Recorded decisions to install something the gate blocked.
//!
//! An override is not permission to install an item; it is permission to
//! install *this content*, with *these findings*, judged by *these rules*.
//! It binds to all three plus the installation it was granted for, and the
//! moment any of them moves it stops applying and the block comes back.
//! Nothing here can grow into a standing exemption, which is the failure
//! mode every "allow this once" switch eventually has.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{Finding, RULESET_VERSION};

/// One recorded review. The key it is stored under is the installation:
/// kind, name and harness, inside the scope whose manifest holds it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct SafetyOverride {
    /// Hash of the complete bytes that were reviewed. Empty on a record
    /// written before decisions bound to those bytes: such a record proves
    /// nothing about what is installed now, so it reads as stale and the
    /// content has to be reviewed again.
    #[serde(default)]
    pub review_hash: String,
    /// The rule set that produced the findings below.
    pub ruleset: u32,
    /// Fingerprints of the exact findings that were reviewed, sorted.
    pub findings: Vec<String>,
    pub granted_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// Whether a recorded override still speaks for what is in front of us.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum OverrideState {
    /// Nothing recorded for this installation.
    Absent,
    /// Recorded, and still describing exactly this.
    Active,
    /// Recorded, but what it was granted against has changed since.
    Stale { why: String },
}

impl OverrideState {
    pub fn unblocks(&self) -> bool {
        matches!(self, OverrideState::Active)
    }
}

/// The fingerprints of a finding set, in the one order two sets can be
/// compared in. `root` is the item's location, stripped from each print so
/// two readings of the same bytes at different paths compare equal.
pub fn fingerprints(findings: &[Finding]) -> Vec<String> {
    let mut prints: Vec<String> = findings.iter().map(Finding::fingerprint).collect();
    prints.sort();
    prints.dedup();
    prints
}

/// Record a review of exactly this content and these findings.
pub fn mint(review_hash: &str, findings: &[Finding], note: Option<String>) -> SafetyOverride {
    SafetyOverride {
        review_hash: review_hash.to_owned(),
        ruleset: RULESET_VERSION,
        findings: fingerprints(findings),
        granted_at: crate::clock::timestamp(),
        note,
    }
}

/// Why a decision made against `recorded_hash` under `recorded_ruleset` no
/// longer speaks for the content in front of us — or `None` while it still
/// does. Every decision binds the same two things, so every decision goes
/// stale the same way. Bytes nobody can read cannot be the bytes somebody
/// reviewed: a record with nothing to compare itself against never applies,
/// the same rule that reports an artifact kendex cannot compare as
/// uncompared rather than as passing.
pub fn snapshot_stale(
    recorded_hash: &str,
    recorded_ruleset: u32,
    review_hash: Option<&str>,
) -> Option<String> {
    let Some(review_hash) = review_hash else {
        return Some("the content it was made for cannot be read here, so nothing proves it is still what was reviewed".to_owned());
    };
    if recorded_hash != review_hash {
        return Some("the content changed since it was reviewed".to_owned());
    }
    if recorded_ruleset != RULESET_VERSION {
        return Some(format!(
            "the safety rules changed since it was reviewed (reviewed under rule set {recorded_ruleset}, now {RULESET_VERSION})"
        ));
    }
    None
}

/// What a recorded override means for the content in front of us now.
pub fn state(
    recorded: Option<&SafetyOverride>,
    review_hash: Option<&str>,
    findings: &[Finding],
) -> OverrideState {
    let Some(recorded) = recorded else {
        return OverrideState::Absent;
    };
    if let Some(why) = snapshot_stale(&recorded.review_hash, recorded.ruleset, review_hash) {
        return OverrideState::Stale { why };
    }
    if recorded.findings != fingerprints(findings) {
        return OverrideState::Stale {
            why: "different problems were found than the ones that were reviewed".to_owned(),
        };
    }
    OverrideState::Active
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quality::Severity;

    fn finding() -> Finding {
        Finding {
            rule: "safety-bypass".to_owned(),
            severity: Severity::Critical,
            location: "s/SKILL.md:69".to_owned(),
            message: "`--no-verify` skips the checks a commit runs".to_owned(),
            remediation: "leave the check in place".to_owned(),
        }
    }

    /// A record made under an older rule set says so, and says it first.
    /// The alternative is the lie the rule-set version exists to prevent:
    /// the same problems, re-identified, reported as "different problems
    /// were found than the ones that were reviewed".
    #[test]
    fn a_record_from_an_older_rule_set_reads_as_rules_changed() {
        let findings = [finding()];
        let recorded = SafetyOverride {
            review_hash: "same-bytes".to_owned(),
            ruleset: RULESET_VERSION - 1,
            findings: vec!["an identity that build produced".to_owned()],
            granted_at: "2026-01-01T00:00:00Z".to_owned(),
            note: None,
        };
        match state(Some(&recorded), Some("same-bytes"), &findings) {
            OverrideState::Stale { why } => {
                assert!(why.contains("safety rules changed"), "{why}");
                assert!(!why.contains("different problems"), "{why}");
            }
            other => panic!("expected stale, got {other:?}"),
        }
    }
}
