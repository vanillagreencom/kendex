//! Why a hook's installation holds whole, when it does.
//!
//! Asked of every hook this pass has anything to do with — which is not
//! the same as every hook the lock names, since one being installed for
//! the first time is written just the same — and answered in the order
//! the person would have to fix things in: the scope's own files first,
//! then this hook's entry at the new path, then what is under the name pi
//! reserved.

use std::collections::BTreeMap;

use super::super::desired::DesiredState;
use super::claims::Held;
use super::migrated::{Moved, moved_by_hand};
use super::preflight::{Hold, Preflight};
use super::{Found, legacy_files, look, plain_file, provenance};
use crate::env::Env;
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::Scope;

/// The scope's own two files, and what this pass already knows about
/// them. Read once, before any hook is asked about: whether kendex may
/// write the registry they all share is a property of the file, and no
/// entry set decides whether that question gets asked.
pub(super) struct Places<'a> {
    root: &'a std::path::Path,
    dir: &'a std::path::Path,
    linked: bool,
}

impl<'a> Places<'a> {
    pub(super) fn new(root: &'a std::path::Path, dir: &'a std::path::Path, linked: bool) -> Self {
        Places { root, dir, linked }
    }

    /// The scope's own answer, before any hook's: nothing is written to a
    /// document kendex may not write, whatever else is true of the hook
    /// that would have been written there.
    fn scope_wide(&self) -> Option<Hold> {
        self.linked.then(|| {
            Hold::ByHand(format!(
                "{} is a link kendex did not create, so nothing is written through it — move it aside yourself, then refresh again",
                pi::hook_registry(self.root).display()
            ))
        })
    }
}

/// Why each of this scope's hooks is holding whole, for the ones that
/// are. One place, so the answer cannot depend on which way the pass
/// arrived at it.
///
/// Asked of every hook this pass has anything to do with, which is not
/// the same as every hook the lock names: one being installed for the
/// first time has no record to look up and is written just the same, so
/// a question about the file they all register in has to reach it too.
pub(super) fn held(
    env: &Env,
    scope: &Scope,
    places: &Places,
    ours: &[&LockEntry],
    pre: &Preflight,
    state: &DesiredState,
) -> BTreeMap<String, Hold> {
    let named = ours.iter().map(|entry| (entry.name.clone(), Some(*entry)));
    let fresh = super::newly_installed(ours, state)
        .into_iter()
        .map(|name| (name, None));
    named
        .chain(fresh)
        .filter_map(|(name, entry)| {
            let hold = match entry {
                Some(entry) => places
                    .scope_wide()
                    .or_else(|| holding(env, scope, places, entry, pre, state)),
                // Nothing kendex has installed, so nothing of its own
                // history to ask about — only the scope's answer.
                None => places.scope_wide(),
            };
            hold.map(|hold| (name, hold))
        })
        .collect()
}

/// The hold a registration somebody moved by hand at the new path earns:
/// registering the fresh rendering beside it would leave the hook firing
/// twice, under two events. Asked wherever the question comes up — with
/// the old layout still on disk and with it long gone — from the one
/// place, so the two cannot answer differently.
fn doubled(
    env: &Env,
    scope: &Scope,
    root: &std::path::Path,
    entry: &LockEntry,
    state: &DesiredState,
) -> Option<Hold> {
    let registry = pi::hook_registry(root);
    match moved_by_hand(env, scope, root, entry, state) {
        Moved::No => None,
        Moved::Elsewhere => Some(Hold::ByHand(format!(
            "its registration in {} sits under an event kendex did not put it under — registering it again would fire the hook twice; move it back or take it out",
            registry.display()
        ))),
        Moved::Unreachable => Some(Hold::ByHand(format!(
            "its registration in {} is written in a shape kendex cannot edit — a handler standing directly under its event, rather than inside a matcher group — so refreshing it would add a second entry beside it and the hook would fire twice; move it inside a matcher group, or take it out",
            registry.display()
        ))),
    }
}

/// Why one hook's installation holds whole, when it does — asked of every
/// hook, and answered in the order the person would have to fix things
/// in.
fn holding(
    env: &Env,
    scope: &Scope,
    places: &Places,
    entry: &LockEntry,
    pre: &Preflight,
    state: &DesiredState,
) -> Option<Hold> {
    let (root, dir) = (places.root, places.dir);
    // Asked of every hook, whatever the record says: the record settles
    // the reserved name and says nothing about the new path, where a
    // registration somebody moved would be doubled by the fresh one this
    // pass writes.
    if let Some(hold) = doubled(env, scope, root, entry, state) {
        return Some(hold);
    }
    // Everything below is about the reserved name, which an installation
    // on record as having left it has left for good.
    if pre.moved_on(&entry.name) {
        return None;
    }
    // A directory kendex cannot look inside is one it cannot install
    // beside either: a replacement written there would run alongside
    // whatever is still under the reserved name, and nobody would have
    // been told there are now two.
    if !matches!(look(dir), Found::Absent | Found::Plain(_)) {
        return Some(Hold::ByHand(format!(
            "kendex cannot see inside {}, so nothing is written beside it — fix its permissions, or move it aside, then refresh again",
            dir.display()
        )));
    }
    // A registry that cannot give up an entry holds every hook it might
    // be holding one for — including a command-bodied one, which has no
    // file under the reserved name at all and exists there only as that
    // registration.
    if pre.registry_block.is_some() {
        return Some(Hold::ByHand(format!(
            "its registration under the name pi reserved is not kendex's to change — {} says what is in the way",
            pi::legacy_hook_registry(root).display()
        )));
    }
    // And this hook's own entry, which says nothing about anybody
    // else's: a sibling with a clean identity moves while this one waits.
    if let Some(why) = pre.conflict(&entry.name) {
        return Some(Hold::ByHand(why.clone()));
    }
    let files = legacy_files(dir, &entry.name);
    if files.is_empty() {
        return None;
    }
    let discard = pre.discards(&entry.name);
    files.iter().find_map(|found| match found {
        Found::Plain(path) => match provenance(entry, path) {
            Ok(_) => None,
            // What the person asked to be rid of is not held back at all.
            Err(_) if discard && discardable(path) => None,
            Err(Held::Edited | Held::Unprovable) => Some(Hold::Edits),
            Err(Held::Unreadable(_)) => Some(Hold::ByHand(format!(
                "kendex could not read {}, so that copy is still what runs — fix its permissions, then refresh again",
                path.display()
            ))),
            Err(Held::NotAFile) => Some(Hold::ByHand(format!(
                "{} is not a plain file, so it is nothing kendex can replace — move it aside yourself, then refresh again",
                path.display()
            ))),
        },
        Found::Linked(path) => Some(Hold::ByHand(format!(
            "{} is a link kendex did not create, so that copy is still what runs — move it yourself, then refresh again",
            path.display()
        ))),
        Found::Unreadable(path, error) => Some(Hold::ByHand(format!(
            "kendex could not read {path} ({error}), so that copy is still what runs — fix its permissions, then refresh again",
            path = path.display()
        ))),
        Found::Absent => None,
    })
}

/// Bytes a discard covers: a plain file that is readable. Discarding is
/// permission to replace someone's edits, never permission to guess at a
/// file kendex cannot read at all — and never permission to take a
/// directory tree somebody put where the script was, which `hash_tree`
/// would hash as happily as a file.
fn discardable(path: &std::path::Path) -> bool {
    plain_file(path) && crate::hash::hash_tree(path).is_ok()
}
