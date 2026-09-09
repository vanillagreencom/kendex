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
    /// The artifact positions one install recorded writing, per harness.
    /// Per harness because a shared tree is written once and read by
    /// several tools: whose installation an observation is, is the tool
    /// that observed it.
    by_artifact: HashMap<(HarnessId, PathBuf), PackageRef>,
    /// The registry entry one hook install recorded writing, named the way
    /// the scan names what it reads back.
    by_registration: HashMap<(HarnessId, String), PackageRef>,
    /// Every declared name recorded for a harness and kind, for the
    /// observations a loader lists under a name of its own.
    declared: HashMap<(HarnessId, ItemKind), Vec<String>>,
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
    let mut by_registration = HashMap::new();
    let mut declared: HashMap<(HarnessId, ItemKind), Vec<String>> = HashMap::new();
    for entry in lock.entries.values() {
        let package = PackageRef {
            kind: entry.kind,
            name: entry.name.clone(),
        };
        for path in crate::engine::owned::installed(env, scope, entry).files {
            by_artifact.insert((entry.harness, resolved(&path)), package.clone());
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
            by_registration.insert(
                (
                    entry.harness,
                    crate::scan::hooks::registration_name(
                        &registration.event,
                        matcher,
                        &registration.command,
                    ),
                ),
                package.clone(),
            );
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
    pub(super) fn of(&self, item: &ObservedItem) -> Option<PackageRef> {
        // An entry inside a config file is not named by the file holding
        // it — every entry of its kind shares that path — so an entry is
        // matched by the registration it was read as and never by where
        // it sits.
        if item.file_state != FileState::ConfigEntry
            && let Some(package) = self.by_artifact.get(&(item.harness, resolved(&item.path)))
        {
            return Some(package.clone());
        }
        if item.kind == ItemKind::Hook
            && let Some(package) = self.by_registration.get(&(item.harness, item.name.clone()))
        {
            return Some(package.clone());
        }
        self.named(item)
    }

    /// The one recorded declaration this observed name answers to, through
    /// the shared naming rule. Several would mean the records do not say
    /// which package this is, so none of them may speak for it.
    fn named(&self, item: &ObservedItem) -> Option<PackageRef> {
        let names = self.declared.get(&(item.harness, item.kind))?;
        let mut found = names
            .iter()
            .filter(|declared| crate::ownership::matches_name(item.kind, declared, &item.name));
        let first = found.next()?;
        found.next().is_none().then(|| PackageRef {
            kind: item.kind,
            name: first.clone(),
        })
    }
}
