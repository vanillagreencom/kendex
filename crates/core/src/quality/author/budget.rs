//! What a publisher's record is worth against the content it landed in.
//!
//! Two questions, kept apart from whether the record describes these bytes
//! at all (`read.rs`): which findings the publisher's own text carries, and
//! — the one derivation every scoring path shares — which of the findings
//! in front of us that pays for.

use std::collections::BTreeSet;

use super::{AuthorReview, Finding, SafetyScore};

/// The findings a publisher's record settles, by fingerprint. Empty settles
/// nothing, which is what every failure here falls back to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Budget(pub(super) BTreeSet<String>);

impl Budget {
    /// What a record has earned against content kendex itself has added to.
    ///
    /// `authored` is the same content the score is about with everything
    /// the publisher did not write taken back out — the project's injected
    /// instructions, and nothing else. Reading there rather than in the
    /// fetched source is the whole point: rendering strips marked blocks
    /// and splits an over-cap body into `references/`, so a record read off
    /// the source settles findings that never install (which is a decision
    /// free to settle somebody else's content) and misses the ones that
    /// moved (which is the publisher's own review failing to apply).
    pub fn earned(review: &AuthorReview, authored: &[Finding]) -> Earned {
        let carried: BTreeSet<String> = authored
            .iter()
            .map(Finding::fingerprint)
            .filter(|fingerprint| review.dismissed.contains_key(fingerprint))
            .collect();
        let unearned = review
            .dismissed
            .keys()
            .filter(|fingerprint| !carried.contains(*fingerprint))
            .cloned()
            .collect();
        Earned {
            budget: Budget(carried),
            unearned,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// A record measured against the content it landed in: what it settles, and
/// every finding it named that this content does not carry. The second half
/// is the only thing that tells a person a review was carried and did not
/// apply — the publisher's own check stays green either way.
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
}

/// Findings scored against a publisher's record: settled where the record
/// names this sentence and the occurrence is the publisher's own, counted
/// otherwise.
///
/// `theirs` says which of these occurrences the publisher's own rendering
/// produced ([`crate::quality::publishers`]), and only those may be
/// settled: a project's injected text lands in the body while the
/// publisher's own copy may have been split out into a supporting file, and
/// settling somebody else's line is how a person comes to read their own
/// text under a publisher's name. `None` where every occurrence is the
/// publisher's: the catalog's own check and the pre-install preview, where
/// nothing has been added to it yet.
pub fn score(findings: &[Finding], budget: &Budget, theirs: Option<&[bool]>) -> Scored {
    let mut settled = Vec::with_capacity(findings.len());
    let mut counted = Vec::new();
    for (at, finding) in findings.iter().enumerate() {
        // A mask that does not reach this far settles nothing here, which
        // is the direction a mistake in it has to fail in.
        let ours = theirs.is_none_or(|mask| mask.get(at).copied().unwrap_or(false));
        match ours && budget.0.contains(&finding.fingerprint()) {
            true => settled.push(true),
            false => {
                settled.push(false);
                counted.push(finding.clone());
            }
        }
    }
    Scored {
        safety: crate::quality::safety(&counted),
        settled,
        counted,
    }
}
