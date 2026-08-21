//! What a publisher's record is worth against the content it landed in.
//!
//! Two questions, kept apart from whether the record describes these bytes
//! at all (`read.rs`): how many occurrences of each finding the publisher's
//! own text carries, and — the one derivation every scoring path shares —
//! which of the findings in front of us that pays for.

use std::collections::{BTreeMap, BTreeSet};

use super::{AuthorReview, Finding, SafetyScore, Severity};

/// How many occurrences of each finding are already settled, by the weight
/// each was read at. Empty settles nothing, which is what every failure
/// here falls back to.
///
/// Keyed by weight and not by fingerprint alone, so what the publisher
/// earned for a sentence in one place cannot be spent on the same sentence
/// somewhere heavier. See [`super::AuthorDismissal::occurrences`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Budget(pub(super) BTreeMap<(String, Severity), u32>);

impl Budget {
    /// A decision made against these very bytes, which therefore speaks for
    /// every occurrence in them, wherever it sits and whatever it weighs.
    pub fn whole(fingerprints: BTreeSet<String>) -> Budget {
        Budget(
            fingerprints
                .into_iter()
                .flat_map(|fingerprint| {
                    Severity::ALL
                        .into_iter()
                        .map(move |severity| ((fingerprint.clone(), severity), u32::MAX))
                })
                .collect(),
        )
    }

    /// What this record earned for one finding, by weight — the shape the
    /// lock keeps.
    pub(super) fn of(&self, fingerprint: &str) -> BTreeMap<Severity, u32> {
        self.0
            .iter()
            .filter(|((named, _), _)| named == fingerprint)
            .map(|((_, severity), count)| (*severity, *count))
            .collect()
    }

    /// Every occurrence this budget still has to spend on one finding.
    fn left_for(&self, fingerprint: &str) -> u32 {
        self.0
            .iter()
            .filter(|((named, _), _)| named == fingerprint)
            .fold(0u32, |left, (_, count)| left.saturating_add(*count))
    }

    /// What a record has earned against content kendex itself has added to.
    ///
    /// `authored` is the same content the score is about with everything
    /// the publisher did not write taken back out — the project's injected
    /// instructions, and nothing else. Counting there rather than in the
    /// fetched source is the whole point: rendering strips marked blocks
    /// and splits an over-cap body into `references/`, so a count taken
    /// from the source pays for occurrences that never install (which is
    /// budget free to settle somebody else's content) and misses the ones
    /// that moved (which is the publisher's own review failing to apply).
    pub fn earned(review: &AuthorReview, authored: &[Finding]) -> Earned {
        let mut counts: BTreeMap<(String, Severity), u32> = BTreeMap::new();
        for finding in authored {
            let fingerprint = finding.fingerprint();
            if review.dismissed.contains_key(&fingerprint) {
                *counts.entry((fingerprint, finding.severity)).or_default() += 1;
            }
        }
        let budget = Budget(counts);
        let unearned = review
            .dismissed
            .keys()
            .filter(|fingerprint| budget.left_for(fingerprint) == 0)
            .cloned()
            .collect();
        Earned { budget, unearned }
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// A record measured against the content it landed in: what it can spend,
/// and every finding it named that this content does not carry. The second
/// half is the only thing that tells a person a review was carried and did
/// not apply — the publisher's own check stays green either way.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Earned {
    pub budget: Budget,
    pub unearned: BTreeSet<String>,
}

/// Findings split into what still counts and what is settled, with the
/// score the counted half earns.
///
/// The one derivation of "a settled finding is reported and does not
/// count". Every caller that scores content someone may have already ruled
/// on comes through here, so none of them can spell the rule differently.
#[derive(Debug, Clone, PartialEq)]
pub struct Scored {
    /// One flag per finding, in the findings' own order.
    pub settled: Vec<bool>,
    pub counted: Vec<Finding>,
    pub safety: SafetyScore,
    /// Fingerprints the record named that nothing here carried. A record
    /// that matched nothing is not the same as no record, and the caller
    /// has to be able to say so.
    pub unmatched: BTreeSet<String>,
}

/// Findings scored against a publisher's budget: settled where the record
/// paid for an occurrence of exactly this sentence at exactly this weight,
/// counted otherwise.
///
/// Weight is part of the match, not a tiebreak. Findings arrive heaviest
/// first, so matching on the sentence alone spends the budget on whichever
/// occurrence sorted first — which is the heaviest, which is the one most
/// likely to be somebody else's, since the project's text lands in the body
/// while the publisher's own copy may have been split out into a supporting
/// file and lowered. Bounding what the budget is *earned* from was never
/// enough on its own: what it may be *spent* on has to be bounded too.
pub fn score(findings: &[Finding], budget: &Budget) -> Scored {
    let mut left = budget.0.clone();
    let mut settled = Vec::with_capacity(findings.len());
    let mut counted = Vec::new();
    for finding in findings {
        let spend = left
            .get_mut(&(finding.fingerprint(), finding.severity))
            .filter(|remaining| **remaining > 0);
        match spend {
            Some(remaining) => {
                *remaining = remaining.saturating_sub(1);
                settled.push(true);
            }
            None => {
                settled.push(false);
                counted.push(finding.clone());
            }
        }
    }
    // A finding is unmatched when nothing was spent on it at any weight:
    // one occurrence settled somewhere is a record that applied.
    let spent_on: BTreeSet<&str> = budget
        .0
        .keys()
        .filter(|key| left.get(*key) != budget.0.get(*key))
        .map(|(fingerprint, _)| fingerprint.as_str())
        .collect();
    let unmatched = budget
        .0
        .keys()
        .map(|(fingerprint, _)| fingerprint)
        .filter(|fingerprint| !spent_on.contains(fingerprint.as_str()))
        .cloned()
        .collect();
    Scored {
        safety: crate::quality::safety(&counted),
        settled,
        counted,
        unmatched,
    }
}
