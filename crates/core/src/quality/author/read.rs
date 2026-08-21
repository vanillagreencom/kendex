//! Reading a catalog's committed record for one item, and everything that
//! makes a claim in it fail to hold up.
//!
//! Every check here answers the same question: does this record describe
//! the bytes in front of us, and is every entry in it one an author can
//! honestly make? What the record is then *worth* against the content that
//! finally installs is [`super::Budget::earned`]'s question, not this one.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use super::{AuthorDismissal, AuthorReview, content_hash, review_key};
use crate::model::ItemKind;
use crate::quality::reviews::{DismissReason, SafetyReview};
use crate::source_read::SealedSource;

/// What one item's own catalog has already settled about it, re-checked
/// against the bytes in front of us.
///
/// `reviews` is the source's parsed reviews file, read once per source root.
/// `publisher` is the provenance kendex resolved for this source. What the
/// record is worth against the content that finally installs is decided
/// later, by [`Budget::earned`]; this answers only whether the record
/// describes these bytes and whether its entries are ones an author can
/// honestly make.
pub fn for_item(
    reviews: &BTreeMap<String, SafetyReview>,
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    item_path: &Path,
    publisher: &str,
) -> Read {
    // The lookup first: hashing a skill reads its whole tree, and most
    // items in most catalogs carry no record for that read to answer.
    if !reviews.contains_key(&review_key(kind, name)) {
        return Read::default();
    }
    for_item_read(
        reviews,
        kind,
        name,
        content_hash(sealed, item_path),
        publisher,
    )
}

/// The same read, for a caller that has already computed the item's content
/// hash from bytes it had to read anyway.
pub fn for_item_read(
    reviews: &BTreeMap<String, SafetyReview>,
    kind: ItemKind,
    name: &str,
    hash: Option<String>,
    publisher: &str,
) -> Read {
    let Some(review) = reviews.get(&review_key(kind, name)) else {
        return Read::default();
    };
    // Bytes nobody can read cannot be the bytes somebody reviewed, and a
    // record with nothing to compare itself against never applies — the
    // same rule every other decision answers to. This is also what contains
    // an item whose content refuses to be read at all: the record settles
    // nothing and the pass carries on to the rest of the scope.
    let Some(hash) = hash else {
        return Read {
            review: None,
            refused: BTreeSet::new(),
            stale: Some("this item's bytes cannot be read here".to_owned()),
        };
    };
    if let Some(why) = review.stale_why(Some(&hash)) {
        return Read {
            review: None,
            refused: BTreeSet::new(),
            stale: Some(why),
        };
    }
    let mut dismissed: BTreeMap<String, AuthorDismissal> = BTreeMap::new();
    let mut refused: BTreeSet<String> = BTreeSet::new();
    for (fingerprint, dismissal) in &review.dismissed {
        match honest(fingerprint, dismissal) {
            true => {
                dismissed.insert(
                    fingerprint.clone(),
                    AuthorDismissal {
                        reason: dismissal.reason,
                        dismissed_at: dismissal.dismissed_at.clone(),
                        // Nothing has been rendered yet, so nothing has
                        // been earned yet.
                        occurrences: None,
                    },
                );
            }
            false => {
                refused.insert(fingerprint.clone());
            }
        }
    }
    let review = (!dismissed.is_empty()).then(|| AuthorReview {
        review_hash: hash,
        ruleset: review.ruleset,
        publisher: publisher.to_owned(),
        dismissed,
    });
    Read {
        review,
        refused,
        stale: None,
    }
}

/// What reading one item's record produced: the part that holds up, every
/// entry that did not, and why a record that exists no longer speaks for
/// this content. A record that settles nothing is not the same as no
/// record — the publisher believes they settled something, and nobody
/// learns otherwise unless it is said out loud. Stale is the likeliest of
/// the three: it is what a catalog that edited an item without re-recording
/// produces.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Read {
    pub review: Option<AuthorReview>,
    pub refused: BTreeSet<String>,
    pub stale: Option<String>,
}

/// Whether one entry is something a publisher can honestly claim.
///
/// The key must be a fingerprint this build could have produced, and the
/// timestamp must be a timestamp: both are printed, and both come out of a
/// file a third party writes by hand. `trusted-source` is refused outright
/// — it is a claim about where bytes came from, and only the machine
/// receiving them can answer that.
pub fn honest(fingerprint: &str, dismissal: &crate::quality::reviews::Dismissal) -> bool {
    fingerprint.len() == 16
        && fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
        && dismissal.reason != DismissReason::TrustedSource
        && dismissal.source.is_none()
        && is_timestamp(&dismissal.dismissed_at)
}

/// A bounded instant, spelled the way [`crate::clock::timestamp`] spells
/// one. Not a full RFC 3339 parse — enough that nothing printable-hostile
/// and nothing unbounded reaches a terminal.
pub(super) fn is_timestamp(value: &str) -> bool {
    (16..=40).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'-' | b':' | b'.' | b'+' | b'T' | b'Z'))
}
