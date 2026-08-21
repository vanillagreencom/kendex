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
//! A record travels with the content it is about. The plan re-reads it out
//! of the source it actually fetched and re-checks it against those bytes,
//! so an author can only settle findings on the exact item they published,
//! and every dismissal they carry is shown to the person installing, named
//! as the author's and with the author's reason. That is a real trust grant
//! to whoever a person subscribes to, and it is the one that makes a
//! committed review worth committing: without it every consumer of a
//! security-adjacent skill re-answers a question its author already
//! answered, with nothing on their machine that could tell them so.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::quality::Finding;
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

pub fn review_key(kind: ItemKind, name: &str) -> String {
    format!("{}:{name}", kind.name())
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

/// The hash a catalog decision binds to: every authored byte of the item.
/// A skill is its collected tree (VCS internals and dependency dirs are not
/// authored content); anything else is one file. `None` where the bytes
/// cannot be read — a decision with nothing to compare against must never
/// read as live.
pub fn content_hash(sealed: &SealedSource, path: &Path) -> Option<String> {
    if sealed.is_dir(path) {
        return Some(crate::hash::hash_files(
            &sealed.collect_skill_tree(path).ok()?,
        ));
    }
    Some(crate::hash::hash_bytes(&sealed.read(path).ok()?))
}

/// The fingerprints this item's record still answers for: its dismissals
/// when the snapshot matches the content in front of us, nothing when the
/// content or the rules have moved on.
pub fn active(review: Option<&SafetyReview>, content_hash: Option<&str>) -> BTreeSet<String> {
    live(review, content_hash).into_keys().collect()
}

/// The same answer with each record's reason and date, for the side that
/// has to say who settled a finding and why.
pub fn live(
    review: Option<&SafetyReview>,
    content_hash: Option<&str>,
) -> BTreeMap<String, Dismissal> {
    let Some(review) = review else {
        return BTreeMap::new();
    };
    match review.stale_why(content_hash) {
        Some(_) => BTreeMap::new(),
        None => review.dismissed.clone(),
    }
}

/// What one item's own catalog has already settled about it, re-checked
/// against the bytes in front of us.
///
/// The record is the author's, and it can only ever speak for the exact
/// content it was committed against: the hash comes from the source being
/// read, never from the file claiming the dismissal. A catalog whose
/// reviews file cannot be read settles nothing — an unreadable claim is not
/// a review, and every finding stays open.
pub fn for_item(
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    item_path: &Path,
) -> BTreeMap<String, Dismissal> {
    let Ok(reviews) = load(sealed) else {
        return BTreeMap::new();
    };
    live(
        reviews.get(&review_key(kind, name)),
        content_hash(sealed, item_path).as_deref(),
    )
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

/// A finding's fingerprint within its item, rooted at the item's catalog
/// path so the same bytes fingerprint the same wherever the catalog is
/// checked out.
pub fn fingerprint(finding: &Finding, item_file: &str) -> String {
    finding.fingerprint(item_file)
}
