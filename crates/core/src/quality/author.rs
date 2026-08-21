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

use super::reviews::DismissReason;
use super::{Content, Finding, SafetyScore, TreeFile};
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
    /// did not supply: `read::for_item` against the source it just read,
    /// and `engine::observed` against what is on disk. Building a budget
    /// does not ask again — a check whose two sides come from one record is
    /// a check that cannot fail, and one written where it reads as
    /// load-bearing is worse than none.
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

    /// Every fingerprint this record names, for a reading where all of the
    /// content is the publisher's — the authoring check and the pre-install
    /// preview, where nothing else has been added to it yet.
    pub fn whole_budget(&self) -> Budget {
        Budget::whole(self.dismissed.keys().cloned().collect())
    }
}

/// How many occurrences of each finding are already settled. Empty settles
/// nothing, which is what every failure here falls back to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Budget(BTreeMap<String, u32>);

impl Budget {
    /// A decision made against these very bytes, which therefore speaks for
    /// every occurrence in them.
    pub fn whole(fingerprints: BTreeSet<String>) -> Budget {
        Budget(
            fingerprints
                .into_iter()
                .map(|fingerprint| (fingerprint, u32::MAX))
                .collect(),
        )
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
        let mut counts: BTreeMap<String, u32> = BTreeMap::new();
        for finding in authored {
            let fingerprint = finding.fingerprint();
            if review.dismissed.contains_key(&fingerprint) {
                *counts.entry(fingerprint).or_default() += 1;
            }
        }
        let unearned = review
            .dismissed
            .keys()
            .filter(|fingerprint| !counts.contains_key(*fingerprint))
            .cloned()
            .collect();
        Earned {
            budget: Budget(counts),
            unearned,
        }
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

pub fn score(findings: &[Finding], budget: &Budget) -> Scored {
    let mut left = budget.0.clone();
    let mut settled = Vec::with_capacity(findings.len());
    let mut counted = Vec::new();
    for finding in findings {
        let spend = left
            .get_mut(&finding.fingerprint())
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
    content_hash_of(sealed, path, None)
}

/// The same hash from a tree the caller has already read. A skill's bytes
/// are the expensive part of every one of these questions, and scoring, the
/// cache key and this hash are all about one read of them.
pub fn content_hash_of(
    sealed: &SealedSource,
    path: &Path,
    tree: Option<&[(std::path::PathBuf, Vec<u8>)]>,
) -> Option<String> {
    if let Some(tree) = tree {
        return Some(crate::hash::hash_files(tree));
    }
    if sealed.is_dir(path) {
        return Some(crate::hash::hash_files(
            &sealed.collect_skill_tree(path).ok()?,
        ));
    }
    Some(crate::hash::hash_bytes(&sealed.read(path).ok()?))
}

/// The half of this content its publisher wrote: the same bytes the score
/// is about, with the project's own injected instructions taken back out.
///
/// A skill's SKILL.md is the only place they can land, and the block that
/// holds them is exactly recoverable — strip and inject are inverses — so
/// this is a subtraction, never a re-render. What is left is what a
/// publisher's record is allowed to answer for: the split that rendering
/// applied is theirs, because their body is what overflowed; the sentence
/// a project told the tool to add is not.
pub fn authored(content: &Content) -> Content {
    let Content::SkillTree { files } = content else {
        return content.clone();
    };
    Content::SkillTree {
        files: files
            .iter()
            .map(|file| match (file.path.file_name(), &file.text) {
                (Some(name), Some(text)) if name == "SKILL.md" => {
                    let stripped = crate::render::skill::inject_instructions(text, None);
                    TreeFile {
                        path: file.path.clone(),
                        bytes: stripped.len(),
                        text: Some(stripped),
                    }
                }
                _ => file.clone(),
            })
            .collect(),
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
    Ok(Content::SkillTree {
        files: sealed
            .collect_skill_tree(path)?
            .into_iter()
            .map(|(path, bytes)| TreeFile::read(path, &bytes))
            .collect(),
    })
}

mod read;
pub use read::{Read, for_item, for_item_read};

#[cfg(test)]
mod tests;
