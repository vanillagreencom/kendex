use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind, Scope};

/// Current lock version, the number every write stamps, and the only one
/// a read accepts. Nothing converts a record from another format: an older
/// one is refused as damaged and a newer one as written by a newer build,
/// and either way the way out is to move it aside and install fresh.
///
/// The floor is not ceremony. Every field a version added is a fact this
/// build reads and an older record does not carry — which bytes are whose,
/// where an installed set sits, why an installation exists, which project
/// wrote the record — and read as absent each of those is a wrong answer
/// rather than a missing one: a set placeable at nothing comes current on
/// the next update of anything else, an installation with no reason
/// recorded is swept as one nobody asked for, and a lock naming no project
/// would refresh a nested checkout's files as this project's and write the
/// record back with nothing left to catch it. A bump is what stops an
/// older build reading a newer record and dropping what it did not
/// understand on its next write.
///
/// Version 9 dropped the record a pi hook's move out of the directory pi
/// reserved once left behind. Dropping a field bumps for the same reason
/// adding one does, and for a sharper one there: the build that still
/// looks for that record would find it absent, read the default as "this
/// install never left the reserved name", and go looking under a directory
/// the person now owns. Against version 9 it refuses instead.
///
/// Version 10 is that shape without the ledger naming which skill seeded
/// each `kendex.settings.toml` key and what the comment block seeding last
/// wrote hashed to. Absence is a write here rather than a stale read: the
/// build that still looks for that ledger finds none, takes it for a
/// project nothing has seeded yet, and writes the template comments back
/// over the keys the person deleted — the one thing the ledger's removal
/// was for. Against version 10 it refuses the record instead.
pub const LOCK_VERSION: u32 = 10;

/// The lock file a project scope carries. The global lock is `lock.json`
/// under the app's own directory ([`Env::global_lock_file`]).
pub const LOCK_FILE: &str = ".kendex-lock.json";

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
pub struct Lock {
    pub version: u32,
    /// The project root this record was written under.
    ///
    /// Every position an entry records is an absolute path under this
    /// root, so this is what makes each one readable as a remainder — the
    /// part of it that is about the installation rather than about the
    /// checkout. The record travels with a copied tree, and into a linked
    /// worktree wherever worktree tooling is set to copy it in; read from
    /// another root, each position resolves onto the root reading it
    /// instead.
    ///
    /// `None` on the global lock, which has no single root — each harness
    /// owns a directory of its own. `None` on a project lock is a record
    /// from a build that did not write it down: it parses so the read can
    /// refuse it by name, because with no root there is no remainder to
    /// read out of a position and nothing may guess one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
    #[serde(default)]
    pub entries: BTreeMap<String, LockEntry>,
    /// The commit each declared source resolved to, by source name.
    /// Reproducibility cache, never intent: the manifest says which
    /// revision is wanted, this says which commit that came out as. A lost
    /// lock costs the record, not the pin.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub sources: BTreeMap<String, SourceRev>,
    /// The commit each installed set was read at, by the name the manifest
    /// installs it under. The same cache as `sources` and never intent: a
    /// set has no installation of its own, so without this the only
    /// account of where it sits is whatever its members happen to record —
    /// and a member the person declared moves off that commit on its own.
    /// A lock written before this was recorded simply has none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub bundles: BTreeMap<String, BundleRev>,
}

/// One source's resolution at the last write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SourceRev {
    /// `owner/repo`, a canonical path, or `local`.
    pub repo: String,
    /// The selector that produced it, when the manifest names one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    pub commit: String,
}

/// One installed set's resolution at the last write.
///
/// Where it was read from is part of the record, because a rebind leaves
/// it naming a set this scope no longer reads: matched by name alone, one
/// catalog's set would say where another catalog's is held.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleRev {
    /// The declared source it was read from.
    pub source: String,
    /// `owner/repo`, a canonical path, or `local` — the repository that
    /// source pointed at when it was read.
    pub source_repo: String,
    pub commit: String,
}

/// One installation an edge points at: the counterpart named the way the
/// manifest and the lock name an installation. Both ends sit in the scope
/// whose lock holds the record, so the scope is the file's, not the
/// reference's.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct InstallRef {
    /// Declared source name — dependencies stay inside one catalog, so this
    /// is the source both ends share.
    pub source: String,
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
}

/// The bundle an installation came in with.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleRef {
    pub source: String,
    pub name: String,
}

/// Why one installation exists. An installation holds a *set* of these — the
/// user asked for it, two bundles carry it, three items require it — and
/// each is a structured value, never a sentence to parse back.
///
/// The set is a cache, not intent: the manifest records the choices (what
/// was requested, which optional dependencies were taken, what is kept
/// removed) and the plan derives the closure again from those choices plus
/// the catalogs. A lost lock therefore loses nothing.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(tag = "reason", rename_all = "kebab-case")]
pub enum Reason {
    /// The user asked for this item by name.
    Requested,
    /// Another installed item declares it as a dependency.
    RequiredBy { by: InstallRef },
    /// An installed bundle carries it as a member.
    MemberOf { bundle: BundleRef },
}

/// One installation the engine wrote: item × harness within this scope's
/// lock file. Provenance is durable — a recorded source is never silently
/// rebound (invariant 4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct LockEntry {
    pub name: String,
    pub kind: ItemKind,
    pub harness: HarnessId,
    /// Declared source name at install time.
    pub source: String,
    /// Resolved provenance: `owner/repo`, a canonical path, or `local`.
    pub source_repo: String,
    pub method: Method,
    pub installed_at: String,
    /// Source bytes + the manifest sections that shaped the artifact.
    pub source_hash: String,
    /// The source commit the bytes came from, for remotes. Cache, like the
    /// rest of the lock: losing it costs the Updates page its "current
    /// version" until the next apply records it again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_commit: Option<String>,
    /// What the apply wrote to disk (file/tree artifacts only) — the anchor
    /// that tells a later pass whether the disk moved because upstream did
    /// or because the user edited it. Absent on pre-upgrade entries; the
    /// next apply backfills it, and until then an ambiguous divergence is
    /// reported as a conflict, never overwritten.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rendered_hash: Option<String>,
    pub enabled: bool,
    /// Agents only: the source's skill set at last sync, so upstream
    /// additions merge in while user removals stay durable — deterministic
    /// across cache loss and machines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream_skills: Option<Vec<String>>,
    /// Where the artifact landed: a command a harness stores as another
    /// kind, a skill's tree plus the link where the tool reads it through
    /// one. Removal and refresh read it instead of deriving a path the
    /// install never took.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emitted: Option<EmittedArtifact>,
    /// The registry entry this hook registered, as the registry keys it.
    /// Kept for every hook that registers one: what a later pass has to
    /// find is what an earlier one wrote, and what the catalog renders
    /// today is a different question — deriving one from the other read a
    /// catalog moving a hook to another event as the person moving it by
    /// hand. A script-less hook is recorded for a second reason: its
    /// command is the person's own and cannot be re-derived once the
    /// manifest entry that carried it is gone. `rendered_hash` is what
    /// tells the two shapes apart — it is set exactly when kendex wrote a
    /// script.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration: Option<HookRegistration>,
    /// Every reason this installation exists. Never empty once written: an
    /// installation nothing can account for would be swept the moment
    /// anything looked at it.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub reasons: BTreeSet<Reason>,
}

/// One hook entry as a harness's registry keys it: event plus command.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct HookRegistration {
    pub event: String,
    pub command: String,
    /// The matcher the entry was written under, spelled the way a
    /// registry spells it — `*` where the hook names none. `None` is a
    /// record from before this was kept: unknown, never "none", so a
    /// matcher somebody changed by hand is not read off a record that
    /// never held one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matcher: Option<String>,
}

/// The artifact one installation actually put on disk, in the harness's own
/// terms: a codex command lands as a skill, under a name the user types; a
/// skill lands as one tree, plus the link where the tool reads it through one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct EmittedArtifact {
    pub kind: ItemKind,
    pub name: String,
    pub paths: Vec<PathBuf>,
}

pub fn entry_key(kind: ItemKind, name: &str, harness: HarnessId) -> String {
    format!("{}:{name}:{}", kind.name(), harness.name())
}

/// The installation a key names, or `None` where the key does not parse —
/// a hand-edited record is still listed under its own spelling and can
/// still be taken back, it just cannot be typed.
pub fn parse_entry_key(key: &str) -> Option<(ItemKind, &str, HarnessId)> {
    let (kind, rest) = key.split_once(':')?;
    let (name, harness) = rest.rsplit_once(':')?;
    let kind = ItemKind::ALL.iter().copied().find(|k| k.name() == kind)?;
    Some((kind, name, HarnessId::parse(harness)?))
}

/// The skills a lock carries, by name. A lock row is per harness, so a
/// skill fanned out to three tools has three rows and one name here — the
/// shape every question about "is this package in the scope" wants.
pub fn skill_names(lock: &Lock) -> std::collections::BTreeSet<String> {
    lock.entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Skill)
        .map(|entry| entry.name.clone())
        .collect()
}

mod file;
mod roots;
pub use file::{LockFile, load, load_file, parse_text, save};

/// Where this scope's lock lives. Off the canonical root, like every
/// scope-path derivation (`manifest::manifest_path`): the path must
/// compare equal to the ones the engine's plan speaks, whatever spelling
/// the scope arrived under.
pub fn lock_path(env: &Env, scope: &Scope) -> PathBuf {
    match &scope.canonical() {
        Scope::Global => env.global_lock_file(),
        Scope::Project { root } => Env::project_lock_file(root),
    }
}

#[cfg(test)]
mod tests;
