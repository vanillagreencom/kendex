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
//!   speaks for as many occurrences of a finding as the publisher's own
//!   text carries in what actually installs, and no more. That number is
//!   [`Budget::earned`]'s, counted against the item rendered from the
//!   publisher's inputs alone: the renderer is asked what it produces
//!   without the project's contributions rather than being read backwards
//!   for markers, so nothing in the project's own text can be mistaken for
//!   the publisher's. The extra occurrence is a different question and
//!   stays counted.
//! - It carries only the reasons an author can honestly give. A
//!   `trusted-source` dismissal is a claim about where bytes came from,
//!   which only the installer's own machine can check; the writer refuses
//!   to record one, and the reader drops one anyway, because the file is
//!   committed TOML anybody can hand-write.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use super::reviews::DismissReason;
use super::{Content, Finding, SafetyScore, Severity};
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
    /// How many occurrences of this finding the publisher's own text
    /// carries in what was installed, by the weight each one was read at.
    /// Written by the apply that measured it, so the audit reads the answer
    /// rather than deriving it a second time and risking a different one.
    /// Empty on a record that has not been measured yet — the catalog's own
    /// read, before any rendering.
    ///
    /// By weight, not a single number, because a number is spendable on
    /// anything. Findings are scored highest severity first, so a bare
    /// count settles the heaviest matching occurrence whoever wrote it: a
    /// project that injects the publisher's own sentence into the body,
    /// where it weighs Critical, spends the budget a publisher earned for
    /// their own copy in a supporting file, where it weighs High — and the
    /// blocker disappears. The weight is what tells the two apart, because
    /// it is exactly what the renderer's placement decided.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub occurrences: BTreeMap<Severity, u32>,
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

    /// Whether every entry in this record is one kendex itself could have
    /// written. The lock is a project file a pull request can edit, so a
    /// record read back out of it is untrusted input exactly as the
    /// catalog's own file is — and `publisher` and `dismissed_at` are
    /// printed. `counted` is how many findings are actually in front of us:
    /// a record cannot claim to have measured more occurrences than exist.
    pub fn is_honest(&self, counted: usize) -> bool {
        // The total is added up, never wrapped into one. A record claiming
        // more per weight than a total can hold has a total nothing here
        // can check, and adding it up anyway reads as a small number — the
        // record then passes the bound it was meant to fail, and its
        // per-weight allowance is honoured in full out of a file a pull
        // request can edit. A wrapping add would also answer differently
        // with overflow checks on than off, which is two builds disagreeing
        // about what is honest.
        let bounded = |occurrences: &BTreeMap<Severity, u32>| {
            occurrences
                .values()
                .try_fold(0u32, |total, count| total.checked_add(*count))
                .is_some_and(|claimed| {
                    usize::try_from(claimed).is_ok_and(|claimed| claimed <= counted)
                })
        };
        crate::names::shown(&self.publisher) == self.publisher
            && self.dismissed.iter().all(|(fingerprint, dismissal)| {
                bounded(&dismissal.occurrences)
                    && read::honest(
                        fingerprint,
                        &crate::quality::reviews::Dismissal {
                            reason: dismissal.reason,
                            dismissed_at: dismissal.dismissed_at.clone(),
                            source: None,
                        },
                    )
            })
    }

    /// The budget an apply already measured and wrote down. Valid exactly
    /// while the record is live, since a live record proves the bytes are
    /// the ones that apply wrote.
    pub fn recorded_budget(&self) -> Budget {
        Budget(
            self.dismissed
                .iter()
                .flat_map(|(fingerprint, dismissal)| {
                    dismissal
                        .occurrences
                        .iter()
                        .map(|(severity, count)| ((fingerprint.clone(), *severity), *count))
                })
                .collect(),
        )
    }

    /// The same record carrying what it earned, for the lock to keep.
    pub fn measured(&self, budget: &Budget) -> AuthorReview {
        AuthorReview {
            dismissed: self
                .dismissed
                .iter()
                .map(|(fingerprint, dismissal)| {
                    (
                        fingerprint.clone(),
                        AuthorDismissal {
                            occurrences: budget.of(fingerprint),
                            ..dismissal.clone()
                        },
                    )
                })
                .collect(),
            ..self.clone()
        }
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
    // Through the same budgeted constructor every install-side reading
    // uses. A check that read further would report findings — and mint
    // tokens for them — in content no gate or audit can ever see, leaving
    // the record permanently unearned and the warning about it
    // unfollowable.
    Ok(Content::SkillTree {
        files: super::observe::tree_files_from_bytes(&sealed.collect_skill_tree(path)?),
    })
}

/// Whether this item carries more than any install will read of it. The
/// budget bounds what is scored, never what a decision covers, so an item
/// past it is one whose tail nobody has judged — which is a thing to say,
/// not a thing to score.
pub fn past_budget(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Option<(usize, usize)> {
    if kind != ItemKind::Skill || !sealed.is_dir(path) {
        return None;
    }
    let files = sealed.collect_skill_tree(path).ok()?;
    let read = super::observe::tree_files_from_bytes(&files);
    let whole: usize = files.iter().map(|(_, bytes)| bytes.len()).sum();
    let scanned: usize = read.iter().map(|file| file.bytes).sum();
    (read.len() < files.len() || scanned < whole).then_some((scanned, whole))
}

mod budget;
mod read;
pub use budget::{Budget, Earned, Scored, score};
pub use read::{Read, for_item, for_item_read, honest, one};

#[cfg(test)]
mod tests;
