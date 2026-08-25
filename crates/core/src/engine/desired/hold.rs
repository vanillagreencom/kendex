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
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Owner {
    Item(ItemKind, String),
    Bundle(String),
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
/// agree on. A declaration the lock cannot place (nothing installed, or
/// installations disagreeing on their commit) is left to resolve fresh: a
/// wrong pin would move it somewhere nobody asked for, and fresh is what a
/// whole-scope apply gives it anyway.
fn held_manifest(
    manifest: &Manifest,
    lock: &Lock,
    target: &(ItemKind, String),
) -> (Manifest, HeldPins) {
    let mut exempt: BTreeSet<Owner> = BTreeSet::new();
    exempt.insert(Owner::Item(target.0, target.1.clone()));
    for entry in lock
        .entries
        .values()
        .filter(|entry| entry.kind == target.0 && entry.name == target.1)
    {
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
                    && !exempt.contains(&Owner::Item(kind, (*name).clone()))
                    && repo_sourced(manifest, &decl.source)
            })
            .filter_map(|(name, _)| {
                agreed_commit(lock, |entry| entry.kind == kind && entry.name == *name)
                    .map(|commit| (name.clone(), commit))
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
        if decl.rev.is_some()
            || exempt.contains(&Owner::Bundle(name.clone()))
            || !repo_sourced(manifest, &decl.source)
        {
            continue;
        }
        let Some(commit) = agreed_commit(lock, |entry| member_of(entry, name)) else {
            continue;
        };
        decl.rev = Some(commit);
        pins.bundles.push(name.clone());
    }
    (held, pins)
}

/// Whether a source can be read at a pinned commit at all: only a repo
/// source has revisions, and pinning a path or local source would turn the
/// whole plan into a typed refusal instead of holding anything.
fn repo_sourced(manifest: &Manifest, source: &str) -> bool {
    manifest
        .sources
        .get(source)
        .is_some_and(|decl| decl.repo.is_some())
}

/// The one commit every matching lock entry records, or `None` when there
/// is no entry, an entry has no commit, or two entries disagree — the cases
/// where holding would have to invent a revision.
fn agreed_commit(lock: &Lock, matches: impl Fn(&crate::lock::LockEntry) -> bool) -> Option<String> {
    let mut agreed: Option<String> = None;
    for entry in lock.entries.values().filter(|entry| matches(entry)) {
        let commit = entry.source_commit.as_ref()?;
        match &agreed {
            Some(seen) if seen != commit => return None,
            _ => agreed = Some(commit.clone()),
        }
    }
    agreed
}

/// Whether this installation is here as a member of the named bundle — the
/// entries whose recorded commits say where the bundle is held.
fn member_of(entry: &crate::lock::LockEntry, bundle: &str) -> bool {
    entry
        .reasons
        .iter()
        .any(|reason| matches!(reason, Reason::MemberOf { bundle: of } if of.name == bundle))
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::lock::{BundleRef, LockEntry};
    use crate::manifest::{ItemDecl, SourceDecl};
    use crate::model::{HarnessId, Scope};

    fn manifest_with(items: &[(&str, Option<&str>)], bundles: &[&str]) -> Manifest {
        let mut manifest = Manifest::default();
        manifest.sources.insert(
            "cat".to_owned(),
            SourceDecl {
                repo: Some("owner/catalog".to_owned()),
                enabled: true,
                ..SourceDecl::default()
            },
        );
        for (name, rev) in items {
            let mut decl = ItemDecl::from_source("cat");
            decl.rev = rev.map(str::to_owned);
            manifest
                .declared_mut(ItemKind::Skill)
                .insert((*name).to_owned(), decl);
        }
        for name in bundles {
            manifest
                .bundles
                .insert((*name).to_owned(), ItemDecl::from_source("cat"));
        }
        manifest
    }

    fn entry(name: &str, commit: Option<&str>, reasons: &[Reason]) -> LockEntry {
        LockEntry {
            name: name.to_owned(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "cat".to_owned(),
            source_repo: "owner/catalog".to_owned(),
            method: crate::manifest::Method::Copy,
            installed_at: "2026-01-01T00:00:00Z".to_owned(),
            source_hash: "x".to_owned(),
            source_commit: commit.map(str::to_owned),
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: None,
            registration: None,
            left_pi_reserved_name: false,
            reasons: reasons.iter().cloned().collect(),
        }
    }

    fn lock_with(entries: &[(&str, LockEntry)]) -> Lock {
        let mut lock = Lock::default();
        for (key, entry) in entries {
            lock.entries.insert((*key).to_owned(), entry.clone());
        }
        lock
    }

    #[test]
    fn siblings_pin_at_their_commit_and_the_target_stays_free() {
        let manifest = manifest_with(&[("a", None), ("b", None), ("held", Some("fff"))], &[]);
        let lock = lock_with(&[
            (
                "skill:a:claude",
                entry("a", Some("aaa"), &[Reason::Requested]),
            ),
            (
                "skill:b:claude",
                entry("b", Some("bbb"), &[Reason::Requested]),
            ),
        ]);

        let (held, pins) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
        let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
        assert_eq!(rev("a"), None, "the target resolves fresh");
        assert_eq!(rev("b"), Some("bbb".to_owned()), "the sibling holds");
        assert_eq!(rev("held"), Some("fff".to_owned()), "a user pin is kept");

        let mut written = held.clone();
        pins.unpin(&mut written);
        assert_eq!(
            written, manifest,
            "unpinning restores the manifest exactly — a written manifest never carries a synthetic hold"
        );
    }

    #[test]
    fn a_derived_targets_bundle_is_exempt_and_a_stranger_bundle_holds() {
        let manifest = manifest_with(&[], &["kit", "other"]);
        let of = |bundle: &str| Reason::MemberOf {
            bundle: BundleRef {
                source: "cat".to_owned(),
                name: bundle.to_owned(),
                scope: Scope::Global,
            },
        };
        let lock = lock_with(&[
            ("skill:m1:claude", entry("m1", Some("aaa"), &[of("kit")])),
            ("skill:o1:claude", entry("o1", Some("bbb"), &[of("other")])),
        ]);

        let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "m1".to_owned()));
        assert_eq!(
            held.bundles["kit"].rev, None,
            "the bundle carrying the target owns its revision, so it resolves fresh"
        );
        assert_eq!(
            held.bundles["other"].rev,
            Some("bbb".to_owned()),
            "a bundle the target has nothing to do with holds at its members' commit"
        );
    }

    #[test]
    fn a_lock_that_cannot_place_a_package_pins_nothing_for_it() {
        let manifest = manifest_with(&[("a", None), ("fresh", None), ("mixed", None)], &[]);
        let lock = lock_with(&[
            (
                "skill:a:claude",
                entry("a", Some("aaa"), &[Reason::Requested]),
            ),
            (
                "skill:mixed:claude",
                entry("mixed", Some("aaa"), &[Reason::Requested]),
            ),
            (
                "skill:mixed:codex",
                entry("mixed", Some("bbb"), &[Reason::Requested]),
            ),
        ]);

        let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
        let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
        assert_eq!(rev("fresh"), None, "nothing installed, nothing to hold at");
        assert_eq!(rev("mixed"), None, "disagreeing installs invent no pin");
    }
}
