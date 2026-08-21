//! Rebuilding the plan that produced what is on disk.
//!
//! Split out of `desired.rs`: this is the audit's question rather than an
//! apply's, and it is the one place a lock's word chooses anything — which
//! revision to rebuild from, never what the answer is.

use std::collections::{BTreeMap, BTreeSet};

use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry, Reason};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};

use super::super::expansion::PLANNED_KINDS;
use super::{Desired, desired_state};

/// The revision each installation is recorded at, keyed by the
/// installation: one item, one tool.
type Installed = BTreeMap<(ItemKind, String, HarnessId), Option<String>>;

/// What a declaration in the manifest answers for, and therefore what
/// pinning it decides. A bundle is not an installation and has no lock
/// entry of its own; what it is here for is the members it brought in.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Owner {
    Item(ItemKind, String),
    Bundle(String),
}

/// The revisions each declaration has to be read at to account for
/// everything it put on disk.
type Governed = BTreeMap<Owner, BTreeSet<Option<String>>>;

/// The plan that produced what is on disk: every installation rebuilt at
/// the revision its own lock entry names, rather than at the one the
/// declaration tracks now.
///
/// This is what an audit compares against. Reading the *current* revision
/// would call a clean install unreviewed the moment upstream moved, which
/// happens to every following installation between an upstream push and the
/// next refresh. What is wanted is the world the apply built, rebuilt.
///
/// The revision is applied *before* the closure is derived, not after it.
/// What a set carries and what a skill requires are read out of the catalog
/// like anything else, so deriving the closure at the revision the catalog
/// sits at now and correcting the bytes afterwards loses every installation
/// the catalog has since stopped carrying: a member dropped from a set
/// upstream is simply absent from the plan, and the still-installed bytes
/// its publisher reviewed answer to nothing. Pinning first rebuilds the
/// membership the apply saw, which is recoverable from the lock as it
/// already stands — the revision is recorded per installation, and which
/// declaration brought each one in is recorded beside it.
///
/// Per installation and not per declaration, because the lock legitimately
/// holds one revision per installation: refresh an item installed for
/// several tools and one tool's new rendering can be held back while
/// another's applies, leaving the two at different commits. So a
/// declaration is read once per revision anything it accounts for sits at,
/// and each pass keeps only the installations that came out at the revision
/// they are recorded at. One revision is the ordinary case and costs one
/// pass.
///
/// The commit each entry names is the lock's word, and the lock is a file
/// this project commits — but nothing is taken on that word. It chooses
/// which revision to rebuild from, and the rebuild then has to equal the
/// bytes on disk. Naming another commit produces another artifact, which is
/// not what is installed, and the record it carried settles nothing.
///
/// A path source has no revision to name, so it is read as it is now: a
/// local catalog that edits an item has moved the content its records were
/// about, and saying so is the same answer every other edit gets.
pub fn desired_as_installed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Result<Vec<Desired>> {
    let installed = installed_at(lock);
    let governed = governed_by(lock);
    let passes = governed
        .values()
        .map(BTreeSet::len)
        .max()
        .unwrap_or(1)
        .max(1);
    let mut built: Vec<Desired> = Vec::new();
    for pass in 0..passes {
        for item in desired_state(env, scope, &pinned_to(manifest, &governed, pass), lock)?.items {
            let already = built.iter().any(|kept| {
                (kept.kind, &kept.name, kept.harness) == (item.kind, &item.name, item.harness)
            });
            if !already && as_installed(&installed, &item) {
                built.push(item);
            }
        }
    }
    Ok(built)
}

/// The revision every installation the lock records sits at.
fn installed_at(lock: &Lock) -> Installed {
    lock.entries
        .values()
        .map(|entry| {
            (
                (entry.kind, entry.name.clone(), entry.harness),
                entry.source_commit.clone(),
            )
        })
        .collect()
}

/// Which declaration accounts for each installation, and the revisions each
/// of those has to be read at.
///
/// An installation can be accounted for by more than one — declared by name
/// and carried by a set at once — and every one of them is recorded, since
/// reading a declaration at a revision nothing needs costs a pass and never
/// an answer.
fn governed_by(lock: &Lock) -> Governed {
    let mut governed: Governed = BTreeMap::new();
    for entry in lock.entries.values() {
        for owner in owners_of(lock, entry, &mut BTreeSet::new()) {
            governed
                .entry(owner)
                .or_default()
                .insert(entry.source_commit.clone());
        }
    }
    governed
}

/// The declarations one installation is here under, following a dependency
/// up to whatever asked for its parent.
///
/// A dependency reads its own bytes from the catalog its parent was read
/// at, so what has to be pinned to recover it is the declaration that
/// brought the parent in, not anything of its own. `seen` is the cycle
/// guard: two skills may require each other on purpose.
fn owners_of(
    lock: &Lock,
    entry: &LockEntry,
    seen: &mut BTreeSet<(ItemKind, String)>,
) -> BTreeSet<Owner> {
    if !seen.insert((entry.kind, entry.name.clone())) {
        return BTreeSet::new();
    }
    let mut owners = BTreeSet::new();
    for reason in &entry.reasons {
        match reason {
            Reason::Requested => {
                owners.insert(Owner::Item(entry.kind, entry.name.clone()));
            }
            Reason::MemberOf { bundle } => {
                owners.insert(Owner::Bundle(bundle.name.clone()));
            }
            Reason::RequiredBy { by } => {
                // A copy of the guard per parent, not one shared between
                // them. One item is one entry per tool and those entries
                // can carry different reasons — requested for one tool,
                // carried by a set for another — so a shared guard stops at
                // the first and drops every owner the rest would have
                // named. The guard is here to stop a cycle, not to visit a
                // parent once.
                for parent in lock
                    .entries
                    .values()
                    .filter(|parent| parent.kind == by.kind && parent.name == by.name)
                {
                    owners.extend(owners_of(lock, parent, &mut seen.clone()));
                }
            }
        }
    }
    owners
}

/// The manifest as this pass reads it: every declaration at the `pass`th
/// revision anything it accounts for is installed at, and left alone where
/// there is no `pass`th one.
///
/// Sets are pinned beside items because a set's membership is read out of
/// its catalog: pinning only what the user named by hand leaves every
/// member and every dependency to be derived from wherever the source has
/// moved to.
fn pinned_to(manifest: &Manifest, governed: &Governed, pass: usize) -> Manifest {
    let mut pinned = manifest.clone();
    let at = |owner: Owner| -> Option<Option<String>> {
        governed.get(&owner)?.iter().nth(pass).cloned()
    };
    for kind in PLANNED_KINDS {
        for (name, decl) in pinned.declared_mut(kind) {
            if let Some(commit) = at(Owner::Item(kind, name.clone())) {
                decl.rev = commit.or_else(|| decl.rev.clone());
            }
        }
    }
    for (name, decl) in &mut pinned.bundles {
        if let Some(commit) = at(Owner::Bundle(name.clone())) {
            decl.rev = commit.or_else(|| decl.rev.clone());
        }
    }
    pinned
}

/// Whether this planned installation is the one the lock records: the same
/// item on the same tool, out of the same commit.
///
/// The passes are attempts. A declaration read at one revision plans a
/// whole closure, and only the part of it that came out where the lock says
/// it is belongs to this rebuild — the rest is another pass's, or nobody's.
/// An installation the lock does not record at all is kept as planned:
/// there is nothing to disagree with, and something on disk that no entry
/// accounts for is the scanner's question rather than this one's.
fn as_installed(installed: &Installed, item: &Desired) -> bool {
    match installed.get(&(item.kind, item.name.clone(), item.harness)) {
        Some(commit) => *commit == item.source_commit,
        None => true,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::lock::{BundleRef, InstallRef};

    fn entry(name: &str, harness: HarnessId, commit: &str, reasons: &[Reason]) -> LockEntry {
        LockEntry {
            name: name.to_owned(),
            kind: ItemKind::Skill,
            harness,
            source: "cat".to_owned(),
            source_repo: "owner/repo".to_owned(),
            method: crate::manifest::Method::Copy,
            installed_at: "2026-01-01T00:00:00Z".to_owned(),
            source_hash: "x".to_owned(),
            source_commit: Some(commit.to_owned()),
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: None,
            registration: None,
            reasons: reasons.iter().cloned().collect(),
        }
    }

    /// One item's installations can be here for different reasons, and a
    /// dependency of it has to be recoverable through every one of them.
    ///
    /// The cycle guard is there to stop a pair of skills that require each
    /// other from walking forever. Sharing it between a parent's own
    /// installations makes it prune siblings instead: the first entry is
    /// walked, the rest are skipped, and every owner they would have named
    /// is dropped — so the declaration that has to be read at the
    /// dependency's revision never is, and a review of the bytes on disk is
    /// rejected.
    #[test]
    fn a_parent_reached_twice_names_the_owners_of_both() {
        let by = InstallRef {
            source: "cat".to_owned(),
            kind: ItemKind::Skill,
            name: "parent".to_owned(),
            harness: HarnessId::Claude,
            scope: Scope::Global,
        };
        let bundle = BundleRef {
            source: "cat".to_owned(),
            name: "kit".to_owned(),
            scope: Scope::Global,
        };
        let mut lock = Lock::default();
        for (key, entry) in [
            (
                "skill:parent:claude",
                entry("parent", HarnessId::Claude, "aaa", &[Reason::Requested]),
            ),
            (
                "skill:parent:codex",
                entry(
                    "parent",
                    HarnessId::Codex,
                    "bbb",
                    &[Reason::MemberOf {
                        bundle: bundle.clone(),
                    }],
                ),
            ),
            (
                "skill:dep:codex",
                entry("dep", HarnessId::Codex, "ccc", &[Reason::RequiredBy { by }]),
            ),
        ] {
            lock.entries.insert(key.to_owned(), entry);
        }

        let governed = governed_by(&lock);
        let owned = |owner: Owner| governed.get(&owner).cloned().unwrap_or_default();
        let held = owned(Owner::Item(ItemKind::Skill, "parent".to_owned()));
        assert!(
            held.contains(&Some("ccc".to_owned())),
            "the declaration reads at the dependency's revision: {held:?}"
        );
        let carried = owned(Owner::Bundle("kit".to_owned()));
        assert!(
            carried.contains(&Some("ccc".to_owned())),
            "and so does the set, which is the other way to reach the same parent: {carried:?}"
        );
    }
}
