//! Holding the rest of a scope still while the packages someone named
//! come current.
//!
//! A targeted update is still a whole-scope reconcile — one plan, one
//! transaction, one lock write — but every follower other than the targets
//! reads the commit its lock entries record instead of the source's fresh
//! resolution, so nothing else moves version as a side effect. One target
//! or five is the same pass: a place's whole "Update all" reconciles once,
//! with each row's exemptions worked out on that row's own terms. The pin is
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
//!
//! A Pi extension is held with the planned kinds. The scope plan does not
//! install one, but it compares the carrier package against the
//! declaration it reads, and a held pass compares it at the recorded
//! commit like every other follower.

use std::collections::{BTreeMap, BTreeSet};

use crate::env::Env;
use crate::error::{CoreError, Result};

use crate::lock::{Lock, LockEntry, Reason};
use crate::manifest::Manifest;
use crate::model::ItemKind;

use super::super::expansion::PLANNED_KINDS;
use super::super::report_types::{Held, HeldPin, Reach, Targets};

/// What a declaration in the manifest answers for, and therefore what
/// pinning it decides. A bundle is not an installation and has no lock
/// entry of its own; what it is here for is the members it brought in.
///
/// The source is part of the identity, because every reference the lock
/// records carries one. A rebind leaves entries naming a declaration this
/// scope does not read, and matched by name alone one package's
/// installations speak for another's: the wrong declaration is exempted
/// from holding and moves, which is the side effect a single-package
/// update exists to remove. An owner whose source does not match simply
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
///
/// `carriers` says whether the sets that carry this installation own it.
/// They do not where it has a declaration of its own to read: held still,
/// such a set keeps its other members where they are, and the target moves
/// on its own declaration. A parent walked to from here is another matter
/// and always names its sets — it carries their revision onto what it
/// requires, so a set that owns a parent has to read fresh whatever the
/// target's own declaration says.
fn owners_of(
    lock: &Lock,
    entry: &LockEntry,
    seen: &mut BTreeSet<(ItemKind, String, String)>,
    carriers: bool,
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
            Reason::MemberOf { bundle } if carriers => {
                owners.insert(Owner::Bundle {
                    name: bundle.name.clone(),
                    source: bundle.source.clone(),
                });
            }
            Reason::MemberOf { .. } => {}
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
                    owners.extend(owners_of(lock, parent, &mut seen.clone(), true));
                }
            }
        }
    }
    owners
}

/// The synthetic pins one held plan wrote — exactly these and nothing else
/// are taken back out, so a revision the user pinned is never touched.
pub(crate) struct HeldPins {
    pins: Vec<HeldPin>,
}

impl HeldPins {
    /// Whether the revision this declaration now reads is one this pass
    /// invented. A member of a set consults it to tell a hold the person
    /// chose from a hold that only exists to keep the rest of the scope
    /// still — the first is theirs to reconcile, the second is not.
    pub(crate) fn invented_item(&self, kind: ItemKind, name: &str) -> bool {
        self.pins.iter().any(|pin| {
            matches!(&pin.held, Held::Item { kind: of_kind, name: of_name }
                if *of_kind == kind && of_name == name)
        })
    }

    /// [`HeldPins::invented_item`] for a set's own declaration.
    pub(crate) fn invented_bundle(&self, name: &str) -> bool {
        self.pins
            .iter()
            .any(|pin| matches!(&pin.held, Held::Set { name: of_name } if of_name == name))
    }

    /// Every pin this plan invented, with the commit it read.
    pub(crate) fn pins(&self) -> &[HeldPin] {
        &self.pins
    }

    /// Remove the synthetic pins from a manifest the plan is about to
    /// write. Every pinned declaration had no `rev` before the hold, so
    /// clearing it restores the declaration exactly.
    pub(crate) fn unpin(&self, manifest: &mut Manifest) {
        for pin in &self.pins {
            let decl = match &pin.held {
                Held::Item { kind, name } => manifest.declared_mut(*kind).get_mut(name),
                Held::Set { name } => manifest.bundles.get_mut(name),
            };
            if let Some(decl) = decl {
                decl.rev = None;
            }
        }
    }
}

impl HeldPin {
    /// The commit `lock` records for this pin's declaration, read as a
    /// held plan reads it: `None` where that record could not place it.
    pub(crate) fn recorded_in(&self, lock: &Lock) -> Option<String> {
        match &self.held {
            Held::Item { kind, name } => held_at(lock, *kind, name, &self.source, &self.repo),
            Held::Set { name } => held_commit(lock, name, &self.source, &self.repo),
        }
    }
}

/// The manifest a plan run with `options` against `lock` reads from: the
/// caller's own, or — under `update_only` — a pinned copy of it with each
/// pin at a commit gone from its source released ([`release_unserved`]),
/// paired with the synthetic pins to strip from any manifest the plan
/// writes. The scope plan, the closure and the Pi settle each read through
/// this one rule, so none of them holds a declaration the others read
/// fresh.
pub(crate) fn held_planning<'a>(
    env: &Env,
    manifest: &'a Manifest,
    lock: &Lock,
    options: &super::super::PlanOptions,
) -> Result<(std::borrow::Cow<'a, Manifest>, Option<HeldPins>)> {
    let (mut planning, mut pins) = planning_manifest(manifest, lock, options);
    if let Some(pins) = pins.as_mut() {
        release_unserved(env, options, planning.to_mut(), pins)?;
    }
    Ok((planning, pins))
}

/// The caller's manifest, or — under `update_only` — a pinned copy of it,
/// paired with the synthetic pins.
fn planning_manifest<'a>(
    manifest: &'a Manifest,
    lock: &Lock,
    options: &super::super::PlanOptions,
) -> (std::borrow::Cow<'a, Manifest>, Option<HeldPins>) {
    match &options.update_only {
        Some(targets) => {
            let (held, pins) = held_manifest(manifest, lock, targets, options.keep_source_records);
            (std::borrow::Cow::Owned(held), Some(pins))
        }
        None => (std::borrow::Cow::Borrowed(manifest), None),
    }
}

/// Under a write that keeps the record
/// ([`super::super::PlanOptions::keep_source_records`]), take back each pin
/// at a commit gone from its source's history, so its declaration resolves
/// fresh: one more case the record cannot place. Held there it would read
/// nothing and be skipped, and the write that skipped it would de-list what
/// it renders. A commit this machine has merely not fetched yet, the lock a
/// teammate committed against a newer catalog, is fetched and stays held;
/// read fresh against a stale mirror it would undo their update. Adds also
/// keep the record and release unserved pins. A hold that does not keep
/// source records keeps every pin, so `verify --at-record` still reports
/// what the record names.
fn release_unserved(
    env: &Env,
    options: &super::super::PlanOptions,
    held: &mut Manifest,
    pins: &mut HeldPins,
) -> Result<()> {
    if !options.keep_source_records {
        return Ok(());
    }
    release(
        held,
        pins,
        |repo, commit| crate::remote::serves(env, repo, commit),
        |repo| crate::remote::fetch_mirror(env, repo),
    )
}

/// [`release_unserved`] against the cache reads it is handed: `serves`
/// answers whether a commit can be read here, `fetch` brings a repository's
/// mirror current. Each commit is asked about once, and again once after
/// its repository is fetched; each repository holding a commit `serves`
/// refuses is fetched once, and a pin still refused after that is gone. A
/// fetch that fails proves nothing about what upstream holds, so the write
/// is refused and every pin stays. A pin on a switched-off source is read
/// by nothing this pass, as the resolvers skip it, so it is neither asked
/// about nor fetched for, and stays.
fn release(
    held: &mut Manifest,
    pins: &mut HeldPins,
    serves: impl Fn(&str, &str) -> bool,
    mut fetch: impl FnMut(&str) -> Result<()>,
) -> Result<()> {
    let mut served: BTreeMap<(String, String), bool> = BTreeMap::new();
    let mut fetching: BTreeMap<String, String> = BTreeMap::new();
    for pin in &pins.pins {
        if !held
            .sources
            .get(&pin.source)
            .is_some_and(|decl| decl.enabled)
        {
            continue;
        }
        let commit = (pin.repo.clone(), pin.commit.clone());
        if !*served
            .entry(commit)
            .or_insert_with(|| serves(&pin.repo, &pin.commit))
        {
            fetching
                .entry(pin.repo.clone())
                .or_insert_with(|| pin.source.clone());
        }
    }
    for (repo, source) in &fetching {
        if fetch(repo).is_err() {
            return Err(CoreError::SourcePending {
                name: source.clone(),
            });
        }
    }
    for ((repo, commit), readable) in &mut served {
        if !*readable && fetching.contains_key(repo) {
            *readable = serves(repo, commit);
        }
    }
    let (kept, gone) = std::mem::take(&mut pins.pins).into_iter().partition(|pin| {
        served
            .get(&(pin.repo.clone(), pin.commit.clone()))
            .copied()
            .unwrap_or(true)
    });
    HeldPins { pins: gone }.unpin(held);
    pins.pins = kept;
    Ok(())
}

/// The manifest a single-package update plans from: the targets read
/// fresh, and under [`Reach::Carriers`] so does whatever carries their
/// revisions — the parent of a dependency always, and the sets that carry a
/// target itself only where it has no declaration of its own to read. Under
/// [`Reach::Declared`] the targets alone read fresh. Every other unpinned
/// declaration is pinned at the commit its lock entries agree on, and
/// every unpinned set at the commit the record says it came out as.
///
/// Several targets are one union of exemptions, never several passes:
/// each is walked on its own terms — its own source, its own answer to
/// whether the sets that carry it own it — and what the walks agree to
/// leave unpinned is left unpinned. Every reading downstream of this is
/// stated per declaration against the pins, so the union changes which
/// declarations are pinned and nothing about how one is read.
///
/// A declaration the lock cannot place — nothing installed, installations
/// disagreeing on their commit, any one of them recorded against a
/// source this declaration does not read from, or, under a write that
/// keeps the record (`keeps_records`,
/// [`super::super::PlanOptions::keep_source_records`]), a source declared
/// at another repository or revision than the record's account of it was
/// written for — is left to resolve fresh: a wrong pin would move it
/// somewhere nobody asked for, and fresh is what a whole-scope apply gives
/// it anyway.
/// A write that keeps records also releases an entry or set whose own
/// selector differs or is unknown. A source record may already describe
/// the new selector while an edit conflict kept an older item record.
fn held_manifest(
    manifest: &Manifest,
    lock: &Lock,
    targets: &Targets,
    keeps_records: bool,
) -> (Manifest, HeldPins) {
    let mut exempt: BTreeSet<Owner> = BTreeSet::new();
    for target in &targets.declarations {
        exempt.extend(exempted_by(manifest, lock, target, targets.reach));
    }
    let mut held = manifest.clone();
    let mut pins = HeldPins { pins: Vec::new() };
    for kind in PLANNED_KINDS.into_iter().chain([ItemKind::PiExtension]) {
        let pinnable: Vec<(String, String, String, String)> = held
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
                let repo = held_repo(manifest, lock, &decl.source, keeps_records)?;
                if keeps_records {
                    let selector = crate::lock::DeclaredSelector::of(
                        manifest,
                        &decl.source,
                        decl.rev.as_deref(),
                    );
                    if lock.entries.values().any(|entry| {
                        entry.kind == kind
                            && entry.name == *name
                            && entry.selector.as_ref() != Some(&selector)
                    }) {
                        return None;
                    }
                }
                let commit = held_at(lock, kind, name, &decl.source, repo)?;
                Some((name.clone(), decl.source.clone(), repo.to_owned(), commit))
            })
            .collect();
        for (name, source, repo, commit) in pinnable {
            if let Some(decl) = held.declared_mut(kind).get_mut(&name) {
                decl.rev = Some(commit.clone());
                pins.pins.push(HeldPin {
                    held: Held::Item { kind, name },
                    source,
                    repo,
                    commit,
                });
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
        let Some(repo) = held_repo(manifest, lock, &decl.source, keeps_records) else {
            continue;
        };
        if keeps_records
            && lock.bundles.get(name).is_none_or(|recorded| {
                recorded.selector.as_ref()
                    != Some(&crate::lock::DeclaredSelector::of(
                        manifest,
                        &decl.source,
                        decl.rev.as_deref(),
                    ))
            })
        {
            continue;
        }
        let Some(commit) = held_commit(lock, name, &decl.source, repo) else {
            continue;
        };
        decl.rev = Some(commit.clone());
        pins.pins.push(HeldPin {
            held: Held::Set { name: name.clone() },
            source: decl.source.clone(),
            repo: repo.to_owned(),
            commit,
        });
    }
    (held, pins)
}

/// The declarations one target leaves unpinned: its own, and, for an item
/// under [`Reach::Carriers`], the ones that carry its revision. A set
/// carries its members' revisions itself, so a set target leaves only its
/// own declaration unpinned.
///
/// Asked per target, because the answer is the target's own. Whether the
/// sets that carry it own it turns on whether this package has a
/// declaration to read instead, and two targets in one pass can answer
/// that differently — a declared one keeps its sets held while a derived
/// one beside it cannot move at all unless they read fresh. Asked once
/// for the pass, one target's answer would decide for the other.
fn exempted_by(manifest: &Manifest, lock: &Lock, target: &Held, reach: Reach) -> BTreeSet<Owner> {
    let target = match target {
        Held::Item { kind, name } => (*kind, name.clone()),
        Held::Set { name } => {
            return manifest
                .bundles
                .get(name)
                .map(|decl| Owner::Bundle {
                    name: name.clone(),
                    source: decl.source.clone(),
                })
                .into_iter()
                .collect();
        }
    };
    let target = &target;
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
    match reach {
        Reach::Declared => return exempt,
        Reach::Carriers => {}
    }
    // Its installations under that source, and the declarations they came
    // in under. An entry a rebind left behind is an installation of a
    // package this declaration is not, and its edges lead to
    // declarations this update has no business unpinning.
    for entry in lock.entries.values().filter(|entry| {
        entry.kind == target.0
            && entry.name == target.1
            && reads_from
                .as_ref()
                .is_none_or(|source| &entry.source == source)
    }) {
        exempt.extend(owners_of(
            lock,
            entry,
            &mut BTreeSet::new(),
            reads_from.is_none(),
        ));
    }
    exempt
}

/// Native callbacks read declarations at the agreed installed commit, including
/// explicit tracking revisions. This is an in-memory reading copy, never a write.
pub(crate) fn installed_manifest(manifest: &Manifest, lock: &Lock) -> Manifest {
    let mut installed = manifest.clone();
    for kind in PLANNED_KINDS {
        for (name, decl) in installed.declared_mut(kind) {
            if let Some(repo) = source_repo(manifest, &decl.source)
                && let Some(commit) = held_at(lock, kind, name, &decl.source, repo)
            {
                decl.rev = Some(commit);
            }
        }
    }
    for (name, decl) in &mut installed.bundles {
        if let Some(repo) = source_repo(manifest, &decl.source)
            && let Some(commit) = held_commit(lock, name, &decl.source, repo)
        {
            decl.rev = Some(commit);
        }
    }
    installed
}

/// The repository a declared source reads from, or `None` when it has
/// none: only a repo source has revisions, and pinning a path or local
/// source would turn the whole plan into a typed refusal instead of
/// holding anything.
fn source_repo<'a>(manifest: &'a Manifest, source: &str) -> Option<&'a str> {
    manifest.sources.get(source)?.repo.as_deref()
}

/// [`source_repo`] for a held plan: `None` also, under a write that keeps
/// the record (`keeps_records`), where the record's account of the source
/// was written for another repository or revision than it is declared at
/// now. Every commit under such a source was read at a selector the person
/// has since replaced, and a write that held at one would keep the record's
/// source entry with it, so no such write would ever apply the edit. After
/// a revision edit any other hold, `verify --at-record`'s reading included,
/// keeps the record as it stands; a single-package update writes the
/// source's entry unchanged too (`record_readings`), so an unrelated edit
/// stays pending for the next write that keeps the record. An add keeps
/// followers and leaves their source edit pending, while
/// `verify --at-record` reads the source at the revision declared now.
/// After a repository edit the record installed nothing from the
/// repository declared now, so [`held_at`] and [`held_commit`] place no
/// follower under any hold, and a single-package update records
/// the rebind at once. A source with no account is held to its entries
/// alone.
fn held_repo<'a>(
    manifest: &'a Manifest,
    lock: &Lock,
    source: &str,
    keeps_records: bool,
) -> Option<&'a str> {
    let repo = source_repo(manifest, source)?;
    if !keeps_records {
        return Some(repo);
    }
    let rev = manifest.sources.get(source)?.rev.as_deref();
    lock.sources
        .get(source)
        .is_none_or(|recorded| recorded.written_for(repo, rev))
        .then_some(repo)
}

/// Whether this installation came from where the declaration reads now.
/// An entry recorded under a different source alias, or under a repository
/// that alias does not point at, carries a commit out of another
/// history: pinning at it holds the package at content nobody chose, or at
/// a sha the source cannot resolve at all. One such entry is enough to
/// leave the declaration to resolve fresh — the same answer the lock's
/// other cannot-place cases get.
fn from_source(entry: &LockEntry, source: &str, repo: &str) -> bool {
    entry.source == source && entry.source_repo == repo
}

/// The one commit a declaration may be held at, or `None` where holding it
/// would have to invent a revision: no installation, an installation with
/// no commit recorded, two that disagree, or one that came from somewhere
/// this declaration does not read.
///
/// Every installation of this item is asked, not only the ones that still
/// match the source. Filtering first reads the survivors as agreement and
/// pins the declaration on their commit, which moves the other copy into a
/// history it was never installed from.
fn held_at(lock: &Lock, kind: ItemKind, name: &str, source: &str, repo: &str) -> Option<String> {
    let mut agreed: Option<String> = None;
    for entry in lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
    {
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

/// Where a set is held: the commit the record says it came out as.
///
/// A set has no installation of its own, so this is the only account of
/// where it sits that survives its members moving. Read back only where
/// the declaration still reads from what the record names — a rebind
/// leaves it describing a set this scope does not install.
fn held_commit(lock: &Lock, bundle: &str, source: &str, repo: &str) -> Option<String> {
    let recorded = lock.bundles.get(bundle)?;
    (recorded.source == source && recorded.source_repo == repo).then(|| recorded.commit.clone())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests;
