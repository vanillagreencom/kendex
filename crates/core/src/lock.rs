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
/// and either way the way out is to move it aside and apply again.
///
/// The floor is not ceremony. Every field a version introduced is a fact this
/// build reads and an older record does not carry — which bytes are whose,
/// where an installed set sits, why an installation exists — and read as
/// absent each of those is a wrong answer rather than a missing one: a set
/// placeable at nothing comes current on the next update of anything else,
/// and an installation with no reason recorded is swept as one nobody asked
/// for. A bump is what stops an older build reading a newer record and
/// dropping what it did not understand on its next write.
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
///
/// Version 11 is the portable shape: the project record is committed, so
/// nothing in it may name this machine. Every position is spelled as a
/// remainder of the root ([`roots`]), a path source's provenance is its
/// declaration rather than the directory it resolved to, in the
/// dot-marked spelling `crate::source::declared_path_identity` gives it,
/// the root itself is not written, and what only this machine knows — the
/// method an install used and when it was made — lives in
/// [`MachineRecord`], in a file under the project's cache
/// ([`machine_path`]). A version 10 record spells every
/// position absolute, which read as a remainder is a claim outside the
/// project; the version gate refuses it by name instead. For a project the
/// way out is to move it to [`.kendex-lock.v10.json`](VERSION_10_LOCK_FILE)
/// and run `kendex apply`. The old managed ignore rule enables that recovery,
/// and the moved record proves ownership only where its `renderedHash`
/// matches the destination. Every other destination remains a conflict.
///
/// Version 11 gained [`Lock::shims`] without a bump, at two costs to a
/// build that predates the field. That build drops the field when it
/// writes the record again, which leaves a later retirement no record of
/// the shim; where retirement still finds it is
/// `engine::instruction_shims::recorded_shims`'s, and a build that knows
/// the field fails the record row of its `kendex verify` by the shim's
/// name until an apply records it again (`attest::record`). And the older
/// build's own `kendex verify` lays a record that carries the field out
/// again without it, so it fails the record row as not laid out as kendex
/// writes it until the verifying build is one that knows the field.
///
/// Version 11 also gained entry and set selectors without a bump. Older
/// writers drop them, returning those records to legacy hold behavior.
/// Older verification can reject a record carrying them because its
/// serialization omits them. Refresh with a build that knows selectors
/// records them again.
pub const LOCK_VERSION: u32 = 11;

/// The lock file a project scope carries, committed with the renders it
/// records. The global lock is `lock.json` under the app's own directory
/// ([`Env::global_lock_file`]).
pub const LOCK_FILE: &str = ".kendex-lock.json";

/// The read-only ownership proof used by the version 10 project recovery.
pub const VERSION_10_LOCK_FILE: &str = ".kendex-lock.v10.json";

/// This machine's half of a project record, under the cache directory the
/// managed ignore block keeps out of git (`engine::posture`). Beside the
/// global lock the same half sits under the file's own name, that lock
/// having no cache of its own to sit under.
pub const MACHINE_FILE: &str = "lock-local.json";

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
pub struct Lock {
    pub version: u32,
    #[serde(default)]
    pub entries: BTreeMap<String, LockEntry>,
    /// The commit each declared source resolved to, by source name.
    /// Reproducibility cache, never intent: the manifest says which
    /// revision is wanted, this says which commit that came out as. A lost
    /// lock costs the record, not the pin. A locked refresh keeps the
    /// entry of a source its plan read nothing at the source's revision of
    /// (`PlanOptions::keep_source_records`).
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
    /// The instruction shims this scope keeps as a key in a settings
    /// document whose other keys are the person's, written by a pass or
    /// found already in sync while the harness was installed. A key has no
    /// bytes of its own to prove whose it is; how the retirement and the
    /// commit offer read this record is
    /// `engine::instruction_shims::recorded_shims`'s.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub shims: BTreeSet<KeyedShim>,
}

/// One instruction shim written as a key into a document whose other keys
/// are the person's. Where that document sits follows from the scope, as a
/// hook registration's registry does, so the record names no path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum KeyedShim {
    /// `context.fileName` in the project's Gemini settings, naming
    /// `AGENTS.md` beside Gemini's own default file.
    GeminiContextFile,
}

impl KeyedShim {
    /// The shim as the record spells it, for a reader naming it.
    pub fn spelled(self) -> &'static str {
        match self {
            KeyedShim::GeminiContextFile => "gemini-context-file",
        }
    }
}

/// One source's resolution at the last write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SourceRev {
    /// `owner/repo`, a path source's identity from
    /// `crate::source::declared_path_identity`, or `local`.
    pub repo: String,
    /// The selector that produced it, when the manifest names one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev: Option<String>,
    pub commit: String,
}

impl SourceRev {
    /// Whether this entry was written for the source as it is declared
    /// now, at `repo` and `rev`. An entry written for another declaration
    /// says where a different selector came out, and nothing read under
    /// it speaks for this one.
    pub fn written_for(&self, repo: &str, rev: Option<&str>) -> bool {
        self.repo == repo && self.rev.as_deref() == rev
    }
}

/// One installed set's resolution at the last write.
///
/// Where it was read from is part of the record, because a rebind leaves
/// it naming a set this scope does not read: matched by name alone, one
/// catalog's set would say where another catalog's is held.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleRev {
    /// The declared source it was read from.
    pub source: String,
    /// `owner/repo`, a path source's identity, or `local` — the repository
    /// that source pointed at when it was read, spelled as
    /// [`LockEntry::source_repo`] spells it.
    pub source_repo: String,
    /// The declaration this set was read under. Missing on older version
    /// 11 records: unknown, so a locked write keeps the legacy hold until
    /// refresh records known metadata.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selector: Option<DeclaredSelector>,
    pub commit: String,
}

/// The source and package revisions the person declared, before a plan
/// invents any holds. A present value with absent revisions records a
/// follower; an absent value on an entry or set records no such knowledge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredSelector {
    pub source_rev: Option<String>,
    pub rev: Option<String>,
}

impl DeclaredSelector {
    pub(crate) fn of(
        manifest: &crate::manifest::Manifest,
        source: &str,
        rev: Option<&str>,
    ) -> Self {
        Self {
            source_rev: manifest
                .sources
                .get(source)
                .and_then(|decl| decl.rev.clone()),
            rev: rev.map(str::to_owned),
        }
    }
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
    /// Resolved provenance: `owner/repo`, a path source's identity from
    /// `crate::source::declared_path_identity`, or `local`. A path source
    /// is recorded by its declaration and never by the directory it
    /// resolved to here, which is what lets a committed record carry the
    /// durable-provenance rule (invariant 4) to every clone without naming
    /// the checkout that wrote it; the identity's dot mark keeps it out of
    /// the namespace `owner/repo` and the reserved names live in, so the
    /// rule's comparison never matches a path against one of those.
    pub source_repo: String,
    /// Source bytes + the manifest sections that shaped the artifact.
    pub source_hash: String,
    /// The source commit the bytes came from, for remotes. Cache, like the
    /// rest of the lock: losing it costs the Updates page its "current
    /// version" until the next apply records it again. A held plan, which
    /// `verify --at-record` runs, reads a declaration with no revision of
    /// its own at the commit its entries agree on here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_commit: Option<String>,
    /// The declaration these bytes were read under. Missing on older
    /// version 11 records: unknown, never a recorded absent revision.
    /// A locked write keeps its legacy hold until refresh records known
    /// metadata.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selector: Option<DeclaredSelector>,
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
    /// Whole-file positions written by agents, commands, scripted hooks
    /// and skills, including a skill's tree and link. Shared registry keys
    /// are excluded. Removal and refresh read the recorded locations.
    /// Entries without this data are re-recorded by the next apply.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emitted: Option<EmittedArtifact>,
    /// The registry entry this hook registered, as the registry keys it.
    /// Kept for every hook that registers one: what a later pass has to
    /// find is what a previous one wrote, and what the catalog renders
    /// today is a different question — deriving one from the other read a
    /// catalog moving a hook to another event as the person moving it by
    /// hand. A script-less hook is recorded for a second reason: its
    /// command is the person's own and cannot be re-derived once the
    /// manifest entry that carried it is gone. `rendered_hash` is what
    /// tells the two shapes apart — it is set exactly when kendex wrote a
    /// script.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration: Option<HookRegistration>,
    /// Owned response-style block or selection, separate from whole files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_style: Option<OutputStyleRecord>,
    /// Every reason this installation exists. Never empty once written: an
    /// installation nothing can account for would be swept the moment
    /// anything looked at it.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub reasons: BTreeSet<Reason>,
    /// What only this machine knows about the installation. Never written
    /// into the committed record ([`MACHINE_FILE`] holds it), and `None`
    /// where this machine holds nothing about it: a clone whose install was
    /// made elsewhere, or a cache that was cleared. The next apply records
    /// it afresh. Readers that only display machine facts omit them. An
    /// agent fork refuses when it needs the recorded delivery.
    #[serde(skip)]
    pub machine: Option<MachineRecord>,
}

/// The shared position one output-style installation owns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "route", rename_all = "kebab-case")]
pub enum OutputStyleRecord {
    /// Only the named marker block is owned, never the surrounding text.
    Block {
        path: PathBuf,
        marker: String,
        hash: String,
    },
    /// A pre-existing selection remains unowned; an inserted selection is tracked.
    Claude {
        path: PathBuf,
        selection: Option<String>,
    },
}

impl OutputStyleRecord {
    pub(crate) fn path_mut(&mut self) -> &mut PathBuf {
        match self {
            Self::Block { path, .. } | Self::Claude { path, .. } => path,
        }
    }
}

/// The per-machine half of one installation: facts about this apply on
/// this disk, which a committed record must not carry because a teammate's
/// checkout would then carry them too. Cache, like the rest of the lock:
/// losing it costs the app its "installed 3 days ago" until the next
/// apply, and a fork its read of the recorded delivery until then (a fork
/// refuses rather than guess), never the install. The file holding these
/// holds one row per root that wrote through it — a main checkout and its
/// linked worktrees share it through a linked `.cache` — and losing it
/// costs one guard: reconnecting a project to a folder that holds a third
/// project's record is refused on the roots that file names
/// (`settings::relocate`), and a folder whose machine half is gone reads as
/// holding no record at all, which the ordinary confirmation allows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MachineRecord {
    pub method: Method,
    pub installed_at: String,
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

/// The rendered artifact one installation put on disk, in the harness's own
/// terms. Rendered whole files and trees are recorded here; copied Pi packages
/// and shared registry or settings files are excluded. A Codex command
/// records its skill kind and installed name. Project paths are slashed
/// remainders of the root on disk, checked by `lock::roots` at both ends.
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

pub mod branch;
mod file;
mod roots;
pub use file::{
    LockFile, committed_text, load, load_file, machine_path, parse_text, save, stated_roots,
};

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
