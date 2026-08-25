//! Holding the rest of a scope still while one package comes current.
//!
//! A single-package update is still a whole-scope reconcile — one plan, one
//! transaction, one lock write — but every follower other than the target
//! reads the commit its lock entries record instead of the source's fresh
//! resolution, so nothing else moves version as a side effect. The pin is
//! applied to the declarations before the closure is derived, never after:
//! what a set carries and what a skill requires are read out of the
//! catalog, so a held package's members and dependencies have to be the
//! ones its installed revision names. Deriving the closure at the tip and
//! correcting the bytes afterwards loses every member the catalog has
//! since stopped carrying.
//!
//! The pins are this pass's reading instructions, never intent: they exist
//! only in the planning copy of the manifest, and [`HeldPins::unpin`] takes
//! them back out of any manifest write the plan carries.

use std::collections::BTreeSet;

use crate::lock::{Lock, LockEntry, Reason};
use crate::manifest::Manifest;
use crate::model::ItemKind;

use super::super::expansion::PLANNED_KINDS;

/// What a declaration in the manifest answers for, and therefore what
/// pinning it decides. A bundle is not an installation and has no lock
/// entry of its own; what it is here for is the members it brought in.
///
/// The source is part of the identity, because every reference the lock
/// records carries one. A rebind leaves entries naming a declaration this
/// scope no longer reads, and matched by name alone one package's
/// installations speak for another's: the wrong declaration is exempted
/// from holding and moves, which is the side effect a single-package
/// update exists to remove. An owner whose source no longer matches simply
/// matches no declaration.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Owner {
    Item {
        kind: ItemKind,
        name: String,
        source: String,
    },
    Bundle {
        name: String,
        source: String,
    },
}

/// The declarations one installation is here under, following a dependency
/// up to whatever asked for its parent.
///
/// A dependency reads its own bytes from the catalog its parent was read
/// at, so what has to be pinned to recover it is the declaration that
/// brought the parent in, not anything of its own. `seen` is the cycle
/// guard: two skills may require each other on purpose — and it keys on
/// the source too, so a package installed from two of them is walked once
/// per installation rather than once per name.
///
/// Every reference is followed by the source it records, never by name
/// alone: the edge names which parent, and which bundle, this dependency
/// belongs to.
fn owners_of(
    lock: &Lock,
    entry: &LockEntry,
    seen: &mut BTreeSet<(ItemKind, String, String)>,
) -> BTreeSet<Owner> {
    if !seen.insert((entry.kind, entry.name.clone(), entry.source.clone())) {
        return BTreeSet::new();
    }
    let mut owners = BTreeSet::new();
    for reason in &entry.reasons {
        match reason {
            Reason::Requested => {
                owners.insert(Owner::Item {
                    kind: entry.kind,
                    name: entry.name.clone(),
                    source: entry.source.clone(),
                });
            }
            Reason::MemberOf { bundle } => {
                owners.insert(Owner::Bundle {
                    name: bundle.name.clone(),
                    source: bundle.source.clone(),
                });
            }
            Reason::RequiredBy { by } => {
                // A copy of the guard per parent, not one shared between
                // them. One item is one entry per tool and those entries
                // can carry different reasons — requested for one tool,
                // carried by a set for another — so a shared guard stops at
                // the first and drops every owner the rest would have
                // named. The guard is here to stop a cycle, not to visit a
                // parent once.
                for parent in lock.entries.values().filter(|parent| {
                    parent.kind == by.kind && parent.name == by.name && parent.source == by.source
                }) {
                    owners.extend(owners_of(lock, parent, &mut seen.clone()));
                }
            }
        }
    }
    owners
}

/// The synthetic pins one held plan added — exactly these and nothing else
/// are taken back out, so a revision the user pinned is never touched.
pub(crate) struct HeldPins {
    items: Vec<(ItemKind, String)>,
    bundles: Vec<String>,
}

impl HeldPins {
    /// Remove the synthetic pins from a manifest the plan is about to
    /// write. Every pinned declaration had no `rev` before the hold, so
    /// clearing it restores the declaration exactly.
    pub(crate) fn unpin(&self, manifest: &mut Manifest) {
        for (kind, name) in &self.items {
            if let Some(decl) = manifest.declared_mut(*kind).get_mut(name) {
                decl.rev = None;
            }
        }
        for name in &self.bundles {
            if let Some(decl) = manifest.bundles.get_mut(name) {
                decl.rev = None;
            }
        }
    }
}

/// The manifest a plan reads from: the caller's own, or — under
/// `update_only` — a pinned copy of it, paired with the synthetic pins to
/// strip from any manifest the plan writes.
pub(crate) fn planning_manifest<'a>(
    manifest: &'a Manifest,
    lock: &Lock,
    options: &super::super::PlanOptions,
) -> (std::borrow::Cow<'a, Manifest>, Option<HeldPins>) {
    match &options.update_only {
        Some(target) => {
            let (held, pins) = held_manifest(manifest, lock, target);
            (std::borrow::Cow::Owned(held), Some(pins))
        }
        None => (std::borrow::Cow::Borrowed(manifest), None),
    }
}

/// The manifest a single-package update plans from: the target — and every
/// declaration that accounts for it, because the owner is what carries a
/// derived package's revision — reads fresh, while every other unpinned
/// remote declaration and bundle is pinned at the commit its lock entries
/// agree on. A declaration the lock cannot place — nothing installed,
/// installations disagreeing on their commit, or any one of them recorded
/// against a source this declaration no longer reads from — is left to
/// resolve fresh: a wrong pin would move it somewhere nobody asked for,
/// and fresh is what a whole-scope apply gives it anyway.
fn held_manifest(
    manifest: &Manifest,
    lock: &Lock,
    target: &(ItemKind, String),
) -> (Manifest, HeldPins) {
    let mut exempt: BTreeSet<Owner> = BTreeSet::new();
    // The source the named package reads from now, where it is declared at
    // all. A derived target has no declaration to read one off, and its
    // identity lives only in the lock.
    let reads_from = manifest
        .declared(target.0)
        .get(&target.1)
        .map(|decl| decl.source.clone());
    // The declaration the caller named — never pinned, whatever the lock
    // still records elsewhere.
    if let Some(source) = &reads_from {
        exempt.insert(Owner::Item {
            kind: target.0,
            name: target.1.clone(),
            source: source.clone(),
        });
    }
    // Its installations under that source, and the declarations they came
    // in under. An entry a rebind left behind is an installation of a
    // package this declaration no longer is, and its edges lead to
    // declarations this update has no business unpinning.
    for entry in lock.entries.values().filter(|entry| {
        entry.kind == target.0
            && entry.name == target.1
            && reads_from
                .as_ref()
                .is_none_or(|source| &entry.source == source)
    }) {
        exempt.extend(owners_of(lock, entry, &mut BTreeSet::new()));
    }
    let mut held = manifest.clone();
    let mut pins = HeldPins {
        items: Vec::new(),
        bundles: Vec::new(),
    };
    for kind in PLANNED_KINDS {
        let pinnable: Vec<(String, String)> = held
            .declared(kind)
            .iter()
            .filter(|(name, decl)| {
                decl.rev.is_none()
                    && !exempt.contains(&Owner::Item {
                        kind,
                        name: (*name).clone(),
                        source: decl.source.clone(),
                    })
            })
            .filter_map(|(name, decl)| {
                let repo = source_repo(manifest, &decl.source)?;
                let commit = held_at(lock, &decl.source, repo, |entry| {
                    entry.kind == kind && entry.name == *name
                })?;
                Some((name.clone(), commit))
            })
            .collect();
        for (name, commit) in pinnable {
            if let Some(decl) = held.declared_mut(kind).get_mut(&name) {
                decl.rev = Some(commit);
                pins.items.push((kind, name));
            }
        }
    }
    for (name, decl) in &mut held.bundles {
        let exempted = exempt.contains(&Owner::Bundle {
            name: name.clone(),
            source: decl.source.clone(),
        });
        if decl.rev.is_some() || exempted {
            continue;
        }
        let Some(repo) = source_repo(manifest, &decl.source) else {
            continue;
        };
        let Some(commit) = held_at(lock, &decl.source, repo, |entry| {
            member_of(entry, name, &decl.source)
        }) else {
            continue;
        };
        decl.rev = Some(commit);
        pins.bundles.push(name.clone());
    }
    (held, pins)
}

/// The repository a declared source reads from, or `None` when it has
/// none: only a repo source has revisions, and pinning a path or local
/// source would turn the whole plan into a typed refusal instead of
/// holding anything.
fn source_repo<'a>(manifest: &'a Manifest, source: &str) -> Option<&'a str> {
    manifest.sources.get(source)?.repo.as_deref()
}

/// Whether this installation came from where the declaration reads now.
/// An entry recorded under a different source alias, or under a repository
/// that alias no longer points at, carries a commit out of another
/// history: pinning at it holds the package at content nobody chose, or at
/// a sha the source cannot resolve at all. One such entry is enough to
/// leave the declaration to resolve fresh — the same answer the lock's
/// other cannot-place cases get.
fn from_source(entry: &LockEntry, source: &str, repo: &str) -> bool {
    entry.source == source && crate::repo_move::same_repo(&entry.source_repo, repo)
}

/// The one commit a declaration may be held at, or `None` where holding it
/// would have to invent a revision: no installation, an installation with
/// no commit recorded, two that disagree, or one that came from somewhere
/// this declaration no longer reads.
///
/// Every installation `belongs` names is asked, not only the ones that
/// still match the source. Filtering first reads the survivors as
/// agreement and pins the declaration on their commit, which moves the
/// other copy into a history it was never installed from.
fn held_at(
    lock: &Lock,
    source: &str,
    repo: &str,
    belongs: impl Fn(&LockEntry) -> bool,
) -> Option<String> {
    let mut agreed: Option<String> = None;
    for entry in lock.entries.values().filter(|entry| belongs(entry)) {
        if !from_source(entry, source, repo) {
            return None;
        }
        let commit = entry.source_commit.as_ref()?;
        match &agreed {
            Some(seen) if seen != commit => return None,
            _ => agreed = Some(commit.clone()),
        }
    }
    agreed
}

/// Whether this installation is here as a member of the named bundle — the
/// entries whose recorded commits say where the bundle is held. Matched by
/// source as well as name: a membership recorded against another catalog's
/// set of the same name is not this declaration's evidence.
fn member_of(entry: &LockEntry, bundle: &str, source: &str) -> bool {
    entry.reasons.iter().any(
        |reason| matches!(reason, Reason::MemberOf { bundle: of } if of.name == bundle && of.source == source),
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests;
