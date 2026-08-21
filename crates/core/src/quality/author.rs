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
//! - It settles only what the publisher's own bytes said. Rendering can add
//!   content the publisher never wrote — a project's `[skill-instructions]`
//!   are injected straight into SKILL.md — so a decision speaks for as many
//!   occurrences of a finding as the source carried, and no more. The extra
//!   occurrence is a different question and stays counted.
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
use super::{Finding, SafetyScore, TreeFile};
use crate::error::Result;
use crate::model::ItemKind;
use crate::source_read::SealedSource;

/// One finding the publisher settled, and how far that reaches.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct AuthorDismissal {
    pub reason: DismissReason,
    pub dismissed_at: String,
    /// How many times the publisher's own bytes carried this finding. The
    /// budget a reader spends: past it, an occurrence is content the
    /// publisher never reviewed.
    pub occurrences: usize,
}

/// A publisher's decisions about one item, as they travel to an install.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
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
    pub fn stale_why(&self, review_hash: Option<&str>) -> Option<String> {
        super::overrides::snapshot_stale(&self.review_hash, self.ruleset, review_hash)
    }

    /// The same record bound to different bytes — what the lock stores once
    /// the apply knows what it wrote.
    pub fn rebound(&self, review_hash: String) -> AuthorReview {
        AuthorReview {
            review_hash,
            ..self.clone()
        }
    }

    /// How many occurrences of each fingerprint this record answers for,
    /// once it has been checked against the content in front of us.
    pub fn budget(review: Option<&AuthorReview>, review_hash: Option<&str>) -> Budget {
        let Some(review) = review.filter(|r| r.stale_why(review_hash).is_none()) else {
            return Budget::default();
        };
        Budget(
            review
                .dismissed
                .iter()
                .map(|(fingerprint, d)| (fingerprint.clone(), d.occurrences))
                .collect(),
        )
    }
}

/// How many occurrences of each finding are already settled. Empty settles
/// nothing, which is what every failure here falls back to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Budget(BTreeMap<String, usize>);

impl Budget {
    /// A decision made against these very bytes, which therefore speaks for
    /// every occurrence in them — what the authoring check has.
    pub fn whole(fingerprints: BTreeSet<String>) -> Budget {
        Budget(
            fingerprints
                .into_iter()
                .map(|fingerprint| (fingerprint, usize::MAX))
                .collect(),
        )
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
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

pub fn score(findings: &[Finding], root: &str, budget: &Budget) -> Scored {
    let mut left = budget.0.clone();
    let mut settled = Vec::with_capacity(findings.len());
    let mut counted = Vec::new();
    for finding in findings {
        let spend = left
            .get_mut(&finding.fingerprint(root))
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
    let unmatched = budget
        .0
        .iter()
        .filter(|(fingerprint, allowed)| left.get(*fingerprint) == Some(allowed))
        .map(|(fingerprint, _)| fingerprint.clone())
        .collect();
    Scored {
        safety: super::safety(&counted),
        settled,
        counted,
        unmatched,
    }
}

/// What one item's own catalog has already settled about it, re-checked
/// against the bytes in front of us and against what those bytes say.
///
/// `reviews` is the source's parsed reviews file, read once per source.
/// `publisher` is the provenance kendex resolved for this source. `None`
/// where the catalog settled nothing that survives the checks — which is
/// the same answer as a catalog that reviewed nothing, and deliberately so:
/// every one of these is a claim that failed to hold up, and a claim that
/// does not hold up settles nothing.
pub fn for_item(
    reviews: &BTreeMap<String, SafetyReview>,
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    item_path: &Path,
    publisher: &str,
) -> Result<Read> {
    let Some(review) = reviews.get(&review_key(kind, name)) else {
        return Ok(Read::default());
    };
    let Some(hash) = content_hash(sealed, item_path) else {
        return Ok(Read::default());
    };
    if review.stale_why(Some(&hash)).is_some() {
        return Ok(Read::default());
    }
    let (claimed, mut refused): (Vec<_>, BTreeSet<String>) = (
        review
            .dismissed
            .iter()
            .filter(|(fingerprint, dismissal)| honest(fingerprint, dismissal))
            .collect(),
        review
            .dismissed
            .iter()
            .filter(|(fingerprint, dismissal)| !honest(fingerprint, dismissal))
            .map(|(fingerprint, _)| fingerprint.clone())
            .collect(),
    );
    if claimed.is_empty() {
        return Ok(Read {
            review: None,
            refused,
        });
    }
    let occurrences = source_occurrences(sealed, kind, name, item_path)?;
    let mut dismissed: BTreeMap<String, AuthorDismissal> = BTreeMap::new();
    for (fingerprint, dismissal) in claimed {
        match occurrences.get(fingerprint).copied() {
            Some(count) => {
                dismissed.insert(
                    fingerprint.clone(),
                    AuthorDismissal {
                        reason: dismissal.reason,
                        dismissed_at: dismissal.dismissed_at.clone(),
                        occurrences: count,
                    },
                );
            }
            None => {
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
    Ok(Read { review, refused })
}

/// What reading one item's record produced: the part that holds up, and
/// every entry that did not. A record naming a finding this content does
/// not carry, or making a claim an author cannot make, is not the same as
/// no record — the publisher believes they settled something, and nobody
/// learns otherwise unless it is said out loud.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Read {
    pub review: Option<AuthorReview>,
    pub refused: BTreeSet<String>,
}

/// Whether one entry is something a publisher can honestly claim.
///
/// The key must be a fingerprint this build could have produced, and the
/// timestamp must be a timestamp: both are printed, and both come out of a
/// file a third party writes by hand. `trusted-source` is refused outright
/// — it is a claim about where bytes came from, and only the machine
/// receiving them can answer that.
fn honest(fingerprint: &str, dismissal: &crate::quality::reviews::Dismissal) -> bool {
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
    (16..=40).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'-' | b':' | b'.' | b'+' | b'T' | b'Z'))
}

/// How many times each finding occurs in the bytes the publisher authored.
/// Read from the source, before any rendering added to it: that is the only
/// content their decision was ever about.
fn source_occurrences(
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    item_path: &Path,
) -> Result<BTreeMap<String, usize>> {
    let file = item_path
        .strip_prefix(sealed.root())
        .unwrap_or(item_path)
        .display()
        .to_string();
    let result = super::audit(super::AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location: file.clone(),
        content: content(sealed, kind, item_path)?,
    });
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for finding in &result.findings {
        *counts.entry(finding.fingerprint(&file)).or_default() += 1;
    }
    Ok(counts)
}

/// The record's key within a reviews file: `kind:name` — no harness,
/// because authoring judges the source item, not any one installation.
pub fn review_key(kind: ItemKind, name: &str) -> String {
    format!("{}:{name}", kind.name())
}

/// The hash a publisher's decision binds to: every authored byte of the
/// item. A skill is its collected tree (VCS internals and dependency dirs
/// are not authored content); anything else is one file. `None` where the
/// bytes cannot be read — a decision with nothing to compare against must
/// never read as live.
pub fn content_hash(sealed: &SealedSource, path: &Path) -> Option<String> {
    if sealed.is_dir(path) {
        return Some(crate::hash::hash_files(
            &sealed.collect_skill_tree(path).ok()?,
        ));
    }
    Some(crate::hash::hash_bytes(&sealed.read(path).ok()?))
}

/// A skill's whole tree; anything else is one file. A repo-root skill's
/// tree is the repository itself, whose VCS internals and dependency dirs
/// are not content.
pub fn content(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Result<super::Content> {
    if kind != ItemKind::Skill {
        return Ok(super::Content::Document {
            text: sealed.read_to_string(path)?,
        });
    }
    if !sealed.is_dir(path) {
        return Ok(super::Content::Unread {
            why: "a skill is a directory holding SKILL.md",
        });
    }
    Ok(super::Content::SkillTree {
        files: sealed
            .collect_skill_tree(path)?
            .into_iter()
            .map(|(path, bytes)| TreeFile::read(path, &bytes))
            .collect(),
    })
}

#[cfg(test)]
mod tests;
