//! What a package's publisher already decided about its own findings, and
//! what that decision is worth on somebody else's machine.
//!
//! The authoring side of the record — the file, the tokens, the writer —
//! lives in [`crate::check_catalog::dismissals`]. This is the neutral half:
//! the shape a decision travels in, how it is read out of a source, and the
//! one derivation of "a settled finding is reported and does not count",
//! which the authoring check, the gate, the audit and browsing all share.
//!
//! Three things bound what a publisher's record can do, because it arrives
//! from content kendex does not control:
//!
//! - It binds to bytes. The reader recomputes the hash from the source in
//!   front of it and compares; nothing is taken on the record's own word.
//! - It settles only what the publisher wrote. Rendering adds content they
//!   never did — a project's `[skill-instructions]`, an agent's launch and
//!   additional instructions, its project-configured hooks — so a decision
//!   settles only the occurrences the publisher's own text produced in
//!   what actually installs. Which those are is [`Budget::earned`]'s
//!   question, asked of the item rendered from the publisher's inputs
//!   alone: the renderer is asked what it produces without the project's
//!   contributions rather than being read backwards for markers, so
//!   nothing in the project's own text can be mistaken for the
//!   publisher's. The project's own occurrence stays counted.
//! - It carries only the reasons an author can honestly give. A
//!   `trusted-source` dismissal is a claim about where bytes came from,
//!   which only the installer's own machine can check; the writer refuses
//!   to record one, and the reader drops one anyway, because the file is
//!   committed TOML anybody can hand-write.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use super::reviews::{DismissReason, SafetyReview};
use super::{Content, Finding, SafetyScore};
use crate::error::Result;
use crate::model::ItemKind;
use crate::source_read::SealedSource;

/// One finding the publisher settled.
// Written into the lock, which is JSON in camelCase throughout; the
// authoring file's own kebab-case shape is `reviews::Dismissal`, and these
// are two different records that happen to rhyme.

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AuthorDismissal {
    pub reason: DismissReason,
    pub dismissed_at: String,
}

/// A publisher's decisions about one item, as they travel to an install.
///
/// Every field here is read back out of a lock a pull request can edit, so
/// none of them may reach the score on this record's own word. What bounds
/// each one, in full — a field added without an answer in this list is a
/// field somebody will forge:
///
/// - `review_hash`: only ever compared against a hash the reader computes
///   from the bytes in front of it, so it can disqualify the record and
///   never grant anything ([`AuthorReview::stale_why`]).
/// - `ruleset`: compared against this build's, and against the one the
///   catalog published.
/// - `publisher`: printable ([`crate::names::shown`]), has to be the
///   provenance the manifest subscribes this item to, and the catalog there
///   has to publish this record. It buys nothing arithmetically.
/// - `dismissed` keys: shaped like fingerprints this build could have
///   written ([`honest`]), and published by that catalog for this
///   item. Whether each settles anything here is derived from the content
///   in front of us ([`Budget::earned`]), never carried on this record's
///   own word.
/// - `dismissed[_].reason` and `.dismissed_at`: printed, and have to match
///   what the catalog published.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AuthorReview {
    /// The bytes this speaks for: the source content at plan time, the
    /// installed content once the lock records it.
    pub review_hash: String,
    pub ruleset: u32,
    /// Who committed it, as kendex itself resolved the source — never a
    /// name the record supplied for itself.
    pub publisher: String,
    pub dismissed: BTreeMap<String, AuthorDismissal>,
}

impl AuthorReview {
    /// Whether this still describes the content in front of us: the same
    /// bytes, judged by the same rules.
    ///
    /// Asked exactly once per reading, by whoever holds a hash the record
    /// did not supply: `for_item` against the source it just read,
    /// and `engine::observed` against what is on disk. Building a budget
    /// does not ask again — a check whose two sides come from one record is
    /// a check that cannot fail, and one written where it reads as
    /// load-bearing is worse than none.
    pub fn stale_why(&self, review_hash: Option<&str>) -> Option<String> {
        super::overrides::snapshot_stale(&self.review_hash, self.ruleset, review_hash)
    }

    /// Every fingerprint this record names, for a reading where all of the
    /// content is the publisher's — the authoring check and the pre-install
    /// preview, where nothing else has been added to it yet.
    pub fn whole_budget(&self) -> Budget {
        Budget(self.dismissed.keys().cloned().collect())
    }
}

/// The record's key within a reviews file: `kind:name` — no harness,
/// because authoring judges the source item, not any one installation.
pub fn review_key(kind: ItemKind, name: &str) -> String {
    format!("{}:{name}", kind.name())
}

/// The hash a publisher's decision binds to: every authored byte of the
/// item, plus every publisher input the item's rendering reads from
/// somewhere other than the item. A skill is its collected tree (VCS
/// internals and dependency dirs are not authored content); anything else
/// is one file. `None` where the bytes cannot be read — a decision with
/// nothing to compare against must never read as live.
///
/// `inputs` is [`crate::source::SourceConfig::rendering_inputs`]: the
/// catalog's own control file has tables an agent renders from, and a
/// record bound to the item's bytes alone stays live while those change
/// under it. The contract every other part of this states — edit the item
/// and the record goes stale — has to mean every input the reviewed
/// rendering had, or it is a contract about only some of them.
pub fn content_hash(sealed: &SealedSource, path: &Path, inputs: &str) -> Option<String> {
    content_hash_of(sealed, path, None, inputs)
}

/// The same hash from a tree the caller has already read. A skill's bytes
/// are the expensive part of every one of these questions, and scoring, the
/// cache key and this hash are all about one read of them.
pub fn content_hash_of(
    sealed: &SealedSource,
    path: &Path,
    tree: Option<&[(std::path::PathBuf, Vec<u8>)]>,
    inputs: &str,
) -> Option<String> {
    let bytes = match tree {
        Some(tree) => crate::hash::hash_files(tree),
        None if sealed.is_dir(path) => {
            crate::hash::hash_files(&sealed.collect_skill_tree(path).ok()?)
        }
        None => crate::hash::hash_bytes(&sealed.read(path).ok()?),
    };
    // Nothing folded in where there is nothing to fold: an item whose
    // rendering reads no catalog configuration hashes exactly as it always
    // did, so no record for one goes stale over this.
    match inputs.is_empty() {
        true => Some(bytes),
        false => Some(crate::hash::hash_bytes(
            format!("{bytes}\n{inputs}").as_bytes(),
        )),
    }
}

/// A skill's whole tree; anything else is one file. A repo-root skill's
/// tree is the repository itself, whose VCS internals and dependency dirs
/// are not content.
pub fn content(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Result<Content> {
    if kind != ItemKind::Skill {
        return Ok(Content::Document {
            text: sealed.read_to_string(path)?,
        });
    }
    if !sealed.is_dir(path) {
        return Ok(Content::Unread {
            why: "a skill is a directory holding SKILL.md",
        });
    }
    // Through the same constructor every install-side reading uses, over
    // the same whole tree, so a token this check mints names content the
    // gate and the audit will read back.
    Ok(super::observe::tree_content_from_bytes(
        &sealed.collect_skill_tree(path)?,
    ))
}

// Reading a catalog's committed record for one item, and everything that
// makes a claim in it fail to hold up.
//
// Every check here answers the same question: does this record describe
// the bytes in front of us, and is every entry in it one an author can
// honestly make? What the record is then *worth* against the content that
// finally installs is [`Budget::earned`]'s question, not this one.

/// What one item's own catalog has already settled about it, re-checked
/// against the bytes in front of us.
///
/// `reviews` is the source's parsed reviews file, read once per source root.
/// `publisher` is the provenance kendex resolved for this source, and
/// `inputs` what its control file contributes to this item's rendering. What the
/// record is worth against the content that finally installs is decided
/// later, by [`Budget::earned`]; this answers only whether the record
/// describes these bytes and whether its entries are ones an author can
/// honestly make.
#[allow(clippy::too_many_arguments)]
pub fn for_item(
    reviews: &BTreeMap<String, SafetyReview>,
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    item_path: &Path,
    publisher: &str,
    inputs: &str,
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
        content_hash(sealed, item_path, inputs),
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
    one(kind, reviews.get(&review_key(kind, name)), hash, publisher)
}

/// The one reader. Every path to a publisher's record — the authoring
/// check, the pre-install preview, the plan — comes through here, so none
/// of them can honour a record another refuses.
pub fn one(
    kind: ItemKind,
    review: Option<&SafetyReview>,
    hash: Option<String>,
    publisher: &str,
) -> Read {
    let Some(review) = review else {
        return Read::default();
    };
    // A hook is scored from the script a plan writes and from the shared
    // settings file its registration lands in once installed — two readings
    // of different bytes, by design. A record can bind to one or the other
    // and never both, so no reading of one is honoured anywhere: refused
    // here, in the one reader every path goes through, rather than at each
    // of them, so the authoring check, the preview and the install cannot
    // answer differently.
    if kind == ItemKind::Hook {
        return Read {
            review: None,
            refused: review.dismissed.keys().cloned().collect(),
            stale: None,
        };
    }
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
        // Printed beside the finding, and resolved from a repository name
        // this project's own manifest supplies — a file, like every other,
        // whose text reaches a terminal.
        publisher: crate::names::shown(publisher),
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
fn is_timestamp(value: &str) -> bool {
    value.len() <= 40 && crate::clock::looks_like_instant(value)
}

// What a publisher's record is worth against the content it landed in.
//
// Two questions, kept apart from whether the record describes these bytes
// at all ([`one`]): which findings the publisher's own text carries, and
// — the one derivation every scoring path shares — which of the findings
// in front of us that pays for.

/// The findings a publisher's record settles, by fingerprint. Empty settles
/// nothing, which is what every failure here falls back to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Budget(BTreeSet<String>);

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

#[cfg(test)]
mod tests;
