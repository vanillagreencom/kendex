//! Committed authoring decisions about a catalog's own safety findings.
//!
//! The safety gate holds a catalog item back until a person reviews it. For
//! an installed item that person is the installer, and their decision lands
//! in the scope's manifest. For a catalog's own CI the reviewer is the
//! maintainer, and this file is where their decision lives:
//! `kendex-reviews.toml` at the catalog root, committed and reviewed like
//! any other change.
//!
//! The record has exactly the shape an install-side dismissal has
//! ([`crate::quality::reviews`]): one snapshot per item binding the
//! complete content bytes and the rule set, with each dismissed finding's
//! fingerprint beneath it. Editing the item makes every record for it
//! stale and the hold comes back — a dismissal can never grow into a
//! standing exemption. Dismissed findings are still reported; they stop
//! counting, not existing.
//!
//! A record travels with the content it is about, which is what makes a
//! committed review worth committing: without it every consumer of a
//! security-adjacent skill re-answers a question its author already
//! answered, with nothing on their machine that could tell them so. What
//! that record is worth on somebody else's machine — the checks it has to
//! survive, and the one it can never make — is
//! [`crate::quality::author`]. This file is the authoring side: the file
//! format, the writer, and the token vocabulary.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::quality::Finding;
use crate::quality::author::{Budget, review_key};
use crate::quality::reviews::{DismissReason, Dismissal, SafetyReview};
use crate::source_read::SealedSource;

pub const REVIEWS_FILE: &str = "kendex-reviews.toml";

/// The file's one table: records keyed `kind:name` — no harness, because
/// authoring judges the source item, not any one installation of it.
#[derive(Debug, Default, Serialize, Deserialize)]
struct ReviewsFile {
    #[serde(default)]
    reviews: BTreeMap<String, SafetyReview>,
}

/// Every committed review record, or an empty map where the catalog has
/// none. A file that exists but cannot be parsed is an error, not an empty
/// map: silently ignoring it would drop the maintainer's decisions and
/// re-block the catalog with no word about why.
pub fn load(sealed: &SealedSource) -> Result<BTreeMap<String, SafetyReview>> {
    let path = sealed.root().join(REVIEWS_FILE);
    let Some(text) = sealed.read_if_exists(&path)? else {
        return Ok(BTreeMap::new());
    };
    let parsed: ReviewsFile = toml::from_str(&text).map_err(|e| CoreError::TomlParse {
        path: path.clone(),
        message: e.to_string(),
    })?;
    Ok(parsed.reviews)
}

/// The fingerprints this item's record still answers for: its dismissals
/// when the snapshot matches the content in front of us, nothing when the
/// content or the rules have moved on. The catalog's own check made these
/// decisions against these very bytes, so each covers every occurrence.
pub fn active(review: Option<&SafetyReview>, content_hash: Option<&str>) -> Budget {
    let Some(review) = review.filter(|r| r.stale_why(content_hash).is_none()) else {
        return Budget::default();
    };
    // The same entries an install would honour, and no others. A record the
    // installer refuses is one this check must refuse too, or a
    // maintainer's CI goes green while their consumers are held back over
    // it, with nothing on either side explaining the disagreement.
    Budget::whole(
        review
            .dismissed
            .iter()
            .filter(|(fingerprint, dismissal)| {
                crate::quality::author::honest(fingerprint, dismissal)
            })
            .map(|(fingerprint, _)| fingerprint.clone())
            .collect(),
    )
}

/// Every entry in this record an install would refuse: the reasons only the
/// receiving machine can answer for, and anything whose shape says it was
/// not written by `dismiss --catalog`.
pub fn refused(review: Option<&SafetyReview>) -> Vec<String> {
    review
        .into_iter()
        .flat_map(|review| review.dismissed.iter())
        .filter(|(fingerprint, dismissal)| !crate::quality::author::honest(fingerprint, dismissal))
        .map(|(fingerprint, _)| fingerprint.clone())
        .collect()
}

/// Record that these findings on this content are not problems. The same
/// snapshot rules as an install-side dismissal: a record for other content
/// is replaced whole, because what it says was reviewed is gone.
pub fn record(
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    content_hash: &str,
    findings: &[(String, DismissReason)],
) -> Result<()> {
    let path = sealed.root().join(REVIEWS_FILE);
    let mut reviews = load(sealed)?;
    let review = reviews
        .entry(review_key(kind, name))
        .and_modify(|review| {
            if review.stale_why(Some(content_hash)).is_some() {
                *review = SafetyReview::of(content_hash);
            }
        })
        .or_insert_with(|| SafetyReview::of(content_hash));
    let now = crate::clock::timestamp();
    for (fingerprint, reason) in findings {
        review.dismissed.insert(
            fingerprint.clone(),
            Dismissal {
                reason: *reason,
                dismissed_at: now.clone(),
                source: None,
            },
        );
    }
    let text =
        toml::to_string_pretty(&ReviewsFile { reviews }).map_err(|e| CoreError::TomlParse {
            path: path.clone(),
            message: e.to_string(),
        })?;
    std::fs::write(&path, text).map_err(|e| CoreError::io(&path, e))?;
    Ok(())
}

/// The token a finding is dismissed by: `kind:name#fingerprint`, printed by
/// `check --catalog` and taken by `dismiss --catalog`.
pub fn token(kind: ItemKind, name: &str, finding_fingerprint: &str) -> String {
    format!("{}#{finding_fingerprint}", review_key(kind, name))
}

/// The item and fingerprint a token names, or `None` where it does not
/// parse as one.
pub fn parse_token(token: &str) -> Option<(ItemKind, &str, &str)> {
    let (key, fingerprint) = token.split_once('#')?;
    let (kind, name) = key.split_once(':')?;
    let kind = ItemKind::ALL.into_iter().find(|k| k.name() == kind)?;
    (!name.is_empty() && !fingerprint.is_empty()).then_some((kind, name, fingerprint))
}

/// A finding's fingerprint within its item.
pub fn fingerprint(finding: &Finding) -> String {
    finding.fingerprint()
}
