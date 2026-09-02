//! The advisory safety score.
//!
//! `100 − Σ deductions`, floor 0. The first finding from a rule costs its
//! full severity; every repeat of that rule costs one point, so a file with
//! forty `curl | sh` lines does not score the same as one with a single
//! line, and neither does a single mistake bury the score under its own
//! echo. Every deduction names the rule and the place it fired.
//!
//! Repeats stop counting once they have cost as much as the first hit did.
//! Past that point they have said all they can say — that the pattern is
//! pervasive rather than incidental: the kendex `github` skill reads
//! `.env.local` on forty lines because that is the skill's entire job.
//!
//! The score and its findings inform; nothing anywhere refuses an install
//! over them.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{Finding, Severity};

/// One rule firing once, and what it cost.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Deduction {
    pub rule: String,
    pub location: String,
    pub severity: Severity,
    pub points: u32,
    /// A later hit from a rule that has already been counted in full.
    pub repeat: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SafetyScore {
    pub score: u32,
    pub deductions: Vec<Deduction>,
}

pub fn safety(findings: &[Finding]) -> SafetyScore {
    // Per rule: what the first hit cost, and what its repeats have cost so
    // far. Findings arrive worst-first, so the first hit sets the cap.
    let mut spent: BTreeMap<&str, (u32, u32)> = BTreeMap::new();
    let mut score: i64 = 100;
    let mut deductions = Vec::new();
    for finding in findings {
        let full = finding.severity.deduction();
        let (repeat, points) = match spent.get_mut(finding.rule.as_str()) {
            None => {
                spent.insert(finding.rule.as_str(), (full, 0));
                (false, full)
            }
            Some((cap, repeats)) => {
                let point = u32::from(*repeats < *cap);
                *repeats += point;
                (true, point)
            }
        };
        score -= i64::from(points);
        deductions.push(Deduction {
            rule: finding.rule.clone(),
            location: finding.location.clone(),
            severity: finding.severity,
            points,
            repeat,
        });
    }
    SafetyScore {
        score: score.max(0).unsigned_abs() as u32,
        deductions,
    }
}
