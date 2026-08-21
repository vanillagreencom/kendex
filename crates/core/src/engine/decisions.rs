//! What has been decided about each finding on an installation, and the
//! token a decision is made with.
//!
//! The rules produce findings; people produce decisions. The two are kept
//! apart — a `Finding` is a pure observation, built before anyone knows
//! which installation it belongs to — and joined here, once the installation,
//! its complete bytes and the records in its scope's manifest are all in
//! hand. Every finding gets a token naming exactly it on exactly this
//! content, and that token is the only thing a dismiss command accepts: the
//! UI never spells a decision key, so it can never spell the wrong one.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::manifest::Manifest;
use crate::model::Scope;
use crate::quality::Finding;
use crate::quality::author::AuthorReview;
use crate::quality::overrides::OverrideState;
use crate::quality::reviews::{DismissReason, DismissalState, dismissal_state};

use super::gate::SHOWN_HASH;

/// What is recorded about one finding, read against the content in front
/// of us now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "state",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum DecisionState {
    /// Nobody has ruled on this finding for this content. `earlier` says why
    /// a previous ruling no longer applies, when there was one.
    Open {
        #[serde(skip_serializing_if = "Option::is_none")]
        earlier: Option<String>,
    },
    /// Judged not to be a problem, for exactly this content.
    Dismissed {
        reason: DismissReason,
        dismissed_at: String,
    },
    /// The catalog that publishes this content committed a review saying
    /// this finding is not a problem, and that review still describes the
    /// exact bytes we fetched. It is reported, not hidden: `publisher` is
    /// the source the record was read from, recorded when it was read, so a
    /// person can weigh whose judgement this is.
    AuthorDismissed {
        reason: DismissReason,
        dismissed_at: String,
        publisher: String,
    },
    /// Covered by an acceptance of the whole item: every finding on it was
    /// read and the item installed anyway.
    Accepted { granted_at: String },
}

/// One finding as a thing a person can rule on. Sits beside the finding it
/// is about — `ItemSafety.decisions[i]` speaks for `ItemSafety.findings[i]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct FindingDecision {
    /// This finding's identity within its item — what a recorded decision
    /// is keyed by, and what tells one occurrence of a finding from another
    /// when the same bytes are read through several tools.
    pub fingerprint: String,
    /// Names exactly this finding on exactly this content. Opaque to the
    /// UI; the only thing a dismiss command accepts. Absent where the
    /// content cannot be read here — there is nothing exact to bind a
    /// decision to, so none can be made.
    pub token: Option<String>,
    pub state: DecisionState,
}

/// The pieces a token binds: a scope, an installation, one finding on it,
/// and the review hash of the content it was found in. Spelled
/// `<kind:name:harness>#<fingerprint>@<review-hash>/<scope>`; a hand-typed
/// one may carry a prefix of the hash, the same way `--allow-unsafe` does.
/// The scope rides along as a short digest so a token minted from one
/// manifest's view can never be written into another's — the same skill in
/// a project and in the personal scope has the same key, bytes and finding,
/// and only the file of record tells them apart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecisionToken {
    pub key: String,
    pub fingerprint: String,
    pub hash: String,
    pub scope: String,
}

/// How much of a scope's digest a token carries.
const SCOPE_TAG: usize = 8;

/// A scope's spelling inside a token: short, stable, and never a path a
/// person has to type.
pub fn scope_tag(scope: &Scope) -> String {
    crate::hash::hash_bytes(scope.canonical().label().as_bytes())[..SCOPE_TAG].to_owned()
}

impl DecisionToken {
    pub fn parse(token: &str) -> crate::error::Result<DecisionToken> {
        let malformed = || crate::error::CoreError::DecisionToken {
            token: token.to_owned(),
        };
        let (rest, tail) = token.rsplit_once('@').ok_or_else(malformed)?;
        let (hash, scope) = tail.split_once('/').ok_or_else(malformed)?;
        let (key, fingerprint) = rest.rsplit_once('#').ok_or_else(malformed)?;
        if key.is_empty()
            || fingerprint.is_empty()
            || hash.len() < SHOWN_HASH
            || scope.len() != SCOPE_TAG
        {
            return Err(malformed());
        }
        Ok(DecisionToken {
            key: key.to_owned(),
            fingerprint: fingerprint.to_owned(),
            hash: hash.to_owned(),
            scope: scope.to_owned(),
        })
    }

    /// Whether this token names the content whose review hash this is.
    pub fn names(&self, review_hash: &str) -> bool {
        review_hash.starts_with(&self.hash)
    }

    /// Whether this token was issued for this scope's manifest.
    pub fn in_scope(&self, scope: &Scope) -> bool {
        self.scope == scope_tag(scope)
    }
}

impl std::fmt::Display for DecisionToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}#{}@{}/{}",
            self.key, self.fingerprint, self.hash, self.scope
        )
    }
}

/// The token as it is printed for a person to type back: the hash cut to
/// the same length the accept flag uses.
pub fn short_token(token: &DecisionToken) -> String {
    DecisionToken {
        hash: token.hash[..SHOWN_HASH.min(token.hash.len())].to_owned(),
        ..token.clone()
    }
    .to_string()
}

/// Everything about one installation that decides what its findings mean:
/// where its records live, what it is, and what has already been ruled on
/// it as a whole.
pub struct Installation<'a> {
    pub manifest: &'a Manifest,
    pub scope: &'a Scope,
    pub key: &'a str,
    /// The item's location, which every finding's fingerprint is relative to.
    pub root: &'a str,
    pub review_hash: Option<&'a str>,
    pub provenance: Option<&'a str>,
    pub override_state: &'a OverrideState,
    /// What the item's publisher already settled about it, and which of
    /// the findings in front of us that record actually paid for — decided
    /// by the scorer, since a record settles as many occurrences as the
    /// publisher's own bytes carried and no more.
    pub author_review: Option<&'a AuthorReview>,
    /// One flag per finding, in the findings' order.
    pub settled: &'a [bool],
    /// Held back by the gate with no live acceptance. Decided by accepting
    /// or removing the item, so its findings get no token: one would be
    /// refused on arrival.
    pub held_back: bool,
}

/// One decision per finding, in the findings' order.
///
/// An active acceptance of the item speaks for every finding on it. Below
/// that, a dismissal speaks for the one finding it names, for as long as the
/// snapshot it sits under still describes these bytes and, for a trusted
/// source, this provenance. Where the review hash is unknown no token can
/// be issued — there is nothing exact to bind a decision to — and every
/// finding is simply open.
pub fn decisions(installation: &Installation<'_>, findings: &[Finding]) -> Vec<FindingDecision> {
    let review = installation.manifest.safety_reviews.get(installation.key);
    let accepted = installation
        .manifest
        .safety_overrides
        .get(installation.key)
        .filter(|_| installation.override_state.unblocks());
    let scope = scope_tag(installation.scope);
    findings
        .iter()
        .enumerate()
        .map(|(index, finding)| {
            let fingerprint = finding.fingerprint();
            let token = installation
                .review_hash
                .filter(|_| !installation.held_back)
                .map(|hash| {
                    DecisionToken {
                        key: installation.key.to_owned(),
                        fingerprint: fingerprint.clone(),
                        hash: hash.to_owned(),
                        scope: scope.clone(),
                    }
                    .to_string()
                });
            let dismissed = review.and_then(|r| r.dismissed.get(&fingerprint).map(|d| (r, d)));
            let by_author = installation
                .settled
                .get(index)
                .filter(|settled| **settled)
                .and(installation.author_review)
                .and_then(|review| {
                    review
                        .dismissed
                        .get(&fingerprint)
                        .map(|dismissal| (review, dismissal))
                });
            let state = match (accepted, dismissed) {
                (Some(recorded), _) => DecisionState::Accepted {
                    granted_at: recorded.granted_at.clone(),
                },
                (None, Some((review, dismissal))) => {
                    match dismissal_state(
                        review,
                        dismissal,
                        installation.review_hash,
                        installation.provenance,
                    ) {
                        DismissalState::Active => DecisionState::Dismissed {
                            reason: dismissal.reason,
                            dismissed_at: dismissal.dismissed_at.clone(),
                        },
                        // The person's own record spoke for bytes that have
                        // moved on. The author's, which was re-checked
                        // against the bytes actually here, still stands.
                        DismissalState::Stale { why } => author_state(by_author)
                            .unwrap_or(DecisionState::Open { earlier: Some(why) }),
                    }
                }
                (None, None) => {
                    author_state(by_author).unwrap_or(DecisionState::Open { earlier: None })
                }
            };
            FindingDecision {
                fingerprint,
                token,
                state,
            }
        })
        .collect()
}

/// The publisher's record as a decision state, when one paid for this
/// finding. Their reason and the name recorded with the record travel with
/// it: this settles nothing on the person's own authority, and a page that
/// said otherwise would be lying about whose judgement is on the line.
fn author_state(
    settled: Option<(&AuthorReview, &crate::quality::author::AuthorDismissal)>,
) -> Option<DecisionState> {
    settled.map(|(review, dismissal)| DecisionState::AuthorDismissed {
        reason: dismissal.reason,
        dismissed_at: dismissal.dismissed_at.clone(),
        publisher: review.publisher.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_round_trips_and_a_short_hash_is_refused() {
        let token = DecisionToken {
            key: "plugin:chrome@openai-bundled:claude".to_owned(),
            fingerprint: "3fa9c2d1e0b4a7c8".to_owned(),
            hash: "abcdefabcdefabcdef".to_owned(),
            scope: scope_tag(&Scope::Global),
        };
        assert_eq!(
            DecisionToken::parse(&token.to_string()).ok(),
            Some(token.clone())
        );
        assert!(token.names("abcdefabcdefabcdef0000"));
        assert!(!token.names("abcdefabcdefabcde"));
        assert!(DecisionToken::parse("plugin:x:claude#3fa9@abc/12345678").is_err());
        assert!(DecisionToken::parse("plugin:x:claude#3fa9@abcdefabcdefabcdef").is_err());
        assert!(DecisionToken::parse("nothing").is_err());
        assert!(token.in_scope(&Scope::Global));
        assert!(!token.in_scope(&Scope::Project {
            root: std::path::PathBuf::from("/x")
        }));
    }
}
