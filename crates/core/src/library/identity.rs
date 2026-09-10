//! Which package one observed installation belongs to.
//!
//! A harness stores a package in the shape it can load, which is not always
//! the shape it was declared in: a Cursor hook is an advisory `.mdc` rule
//! the rules surface reads as an agent, an OpenCode hook is a prefixed
//! instruction file, a native hook registration is named for the event and
//! command it registered, and a Codex command is a skill tree. Each of
//! those is one installation of one package, and every one of them is
//! resolved here off what the install recorded writing — never off a
//! display name, a script basename or a shortened spelling, which say
//! nothing about who wrote the file.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::lock::Lock;
use crate::model::{FileState, HarnessId, ItemKind, ObservedItem, Scope};

/// Which record established a package, by the key its lock entry is held
/// under. The package says WHAT an installation is; this says which record
/// said so, and a record belongs to one tool.
pub(super) type Claim = (PackageRef, String);

/// The package one installation belongs to: the kind and name its
/// declaration carries, which is the identity the manifest, the records
/// and every mutation speak.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageRef {
    pub kind: ItemKind,
    pub name: String,
}

/// One scope's recorded installations, indexed by what each of them put on
/// this machine — the evidence an observation is matched against.
pub(super) struct Recorded {
    /// The artifact positions one install recorded writing, by position.
    ///
    /// By position and not by the tool that observed it: ownership is a
    /// property of the path (invariant 6). One shared tree is written once
    /// and scanned again for every tool that reads it, so keying this per
    /// harness would answer for the writer's observation and leave every
    /// other reader's looking like a stranger's file.
    ///
    /// `None` where two records claim one position: the records do not say
    /// which package it is, and neither may speak for it.
    by_artifact: HashMap<PathBuf, Option<Claim>>,
    /// The registry entry one hook install recorded writing, named the way
    /// the scan names what it reads back, with the command it recorded.
    /// The name reduces a command to its stem, which two different scripts
    /// can share, so the whole command is kept and compared.
    by_registration: HashMap<(HarnessId, String), Option<Registered>>,
    /// Every declared name recorded for a harness and kind, for the
    /// observations that have no artifact position of their own.
    declared: HashMap<(HarnessId, ItemKind), Vec<String>>,
}

/// One recorded registration: the package, and the command it went in
/// with, whole.
#[derive(Clone)]
struct Registered {
    claim: Claim,
    command: String,
}

/// Record one package's claim on a position. Two records claiming one
/// position for DIFFERENT packages leave it unclaimed: the records do not
/// say which package it is, and crediting either would be a guess.
///
/// Agreeing on the package is not that ambiguity. One install of a shared
/// surface writes the files once and records an entry per harness member,
/// every one of them naming the same paths, so a position is normally
/// claimed once per member. Those records agree on what the file is —
/// which is the whole question here — and the standing claim stands. It
/// answers for the origin too, because entries that name one package at
/// one scope came from one install and so carry one source.
fn claim(by_artifact: &mut HashMap<PathBuf, Option<Claim>>, at: PathBuf, held: &Claim) {
    match by_artifact.get(&at) {
        Some(Some(known)) if known.0 == held.0 => {}
        Some(_) => {
            by_artifact.insert(at, None);
        }
        None => {
            by_artifact.insert(at, Some(held.clone()));
        }
    }
}

/// Read a path in the one spelling comparisons meet it in. A recorded
/// position and an observed one are the same file or they are not; a path
/// that no longer resolves keeps what it was given, which can then only
/// match another spelling of itself.
fn resolved(path: &Path) -> PathBuf {
    crate::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Index one scope's records. The positions come from the same reading of
/// a record that removal and refresh use, so what a package is credited
/// with here is exactly what taking it back out would touch.
pub(super) fn index(env: &Env, scope: &Scope, lock: &Lock) -> Recorded {
    let mut by_artifact = HashMap::new();
    let mut by_registration: HashMap<(HarnessId, String), Option<Registered>> = HashMap::new();
    let mut declared: HashMap<(HarnessId, ItemKind), Vec<String>> = HashMap::new();
    for entry in lock.entries.values() {
        let held: Claim = (
            PackageRef {
                kind: entry.kind,
                name: entry.name.clone(),
            },
            crate::lock::entry_key(entry.kind, &entry.name, entry.harness),
        );
        for path in crate::engine::owned::installed(env, scope, entry).files {
            // Both spellings, because a switched-off artifact is observed
            // under the name the rename gave it while the record still
            // names the position the install wrote. Indexed under the one
            // helper removal reads it back through, so what is credited
            // here and what would be taken away cannot diverge.
            for position in [
                resolved(&crate::engine::disabled_name(&path)),
                resolved(&path),
            ] {
                claim(&mut by_artifact, position, &held);
            }
        }
        if entry.kind == ItemKind::Hook
            && let Some(registration) = &entry.registration
            // A record that does not say which matcher it went in under
            // cannot name the entry it wrote: the registry keys an entry
            // by its matcher, and guessing one would credit this package
            // with somebody else's registration. Left unresolved, the
            // observation keeps its own identity and says so.
            && let Some(matcher) = &registration.matcher
        {
            let key = (
                entry.harness,
                crate::scan::hooks::registration_name(
                    &registration.event,
                    matcher,
                    &registration.command,
                ),
            );
            let entry_held = Registered {
                claim: held.clone(),
                command: registration.command.clone(),
            };
            match by_registration.get(&key) {
                // Same rule as a position: one package recorded twice
                // under one registration is that package, and only a
                // second package makes the entry ambiguous.
                Some(Some(known))
                    if known.claim.0 == entry_held.claim.0
                        && known.command == entry_held.command => {}
                Some(_) => {
                    by_registration.insert(key, None);
                }
                None => {
                    by_registration.insert(key, Some(entry_held));
                }
            }
        }
        declared
            .entry((entry.harness, entry.kind))
            .or_default()
            .push(entry.name.clone());
    }
    Recorded {
        by_artifact,
        by_registration,
        declared,
    }
}

impl Recorded {
    /// The package this observation belongs to, or `None` where the
    /// records establish none.
    ///
    /// Ranked by how directly the evidence names the observation: the
    /// position an install recorded writing, then the registry entry it
    /// recorded writing, then a recorded name the observing loader lists
    /// this item under. Nothing below that: an unrecorded observation is
    /// this reader's own and stays its own, because a name two packages
    /// happen to share is not evidence that either wrote the file.
    pub(super) fn of(&self, item: &ObservedItem) -> Option<Claim> {
        // An observation with a position of its own is answered by that
        // position and nothing else: a file where no record claims one is
        // somebody else's, whatever it is called.
        if !Self::positionless(item) {
            return self
                .by_artifact
                .get(&resolved(&item.path))
                .cloned()
                .flatten();
        }
        // An entry inside a config file is not named by the file holding
        // it — every entry of its kind shares that path — so a hook entry
        // is matched by the registration it was read as.
        if item.kind == ItemKind::Hook
            && let Some(held) = self.by_registration.get(&(item.harness, item.name.clone()))
        {
            // The name a registration is read under carries only the
            // command's stem, and two unrelated scripts can share one. The
            // record kept the whole command and the scan read the whole
            // command back, so those are what is compared.
            return held
                .as_ref()
                .filter(|held| item.description.as_deref() == Some(held.command.as_str()))
                .map(|held| held.claim.clone());
        }
        self.named(item)
    }

    /// Whether this observation has no artifact position a record could
    /// claim: an entry inside a shared config file, and a kind whose
    /// records own no path of their own.
    fn positionless(item: &ObservedItem) -> bool {
        item.file_state == FileState::ConfigEntry || item.kind == ItemKind::PiExtension
    }

    /// The one recorded declaration this observed name answers to, through
    /// the shared naming rule. Several would mean the records do not say
    /// which package this is, so none of them may speak for it.
    ///
    /// Reached only where there is no position to ask instead. A name is
    /// not evidence about a file, so a path nothing claims never falls
    /// through to here.
    fn named(&self, item: &ObservedItem) -> Option<Claim> {
        let names = self.declared.get(&(item.harness, item.kind))?;
        let mut found = names
            .iter()
            .filter(|declared| crate::ownership::matches_name(item.kind, declared, &item.name));
        let first = found.next()?;
        found.next().is_none().then(|| {
            (
                PackageRef {
                    kind: item.kind,
                    name: first.clone(),
                },
                crate::lock::entry_key(item.kind, first, item.harness),
            )
        })
    }
}
