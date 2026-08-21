use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind, Scope};

/// Current lock version. Versions 1 (v0.1) through 4 still load — the
/// shapes are compatible and the next lock write records the current
/// version. A lock newer than this build refuses to load. Version 3 added
/// `source_commit` and `rendered_hash`; version 4 added `settings-seeds`;
/// version 5 added `left_pi_reserved_name` and a registration's matcher.
/// Each bump is what stops an older build from reading the lock, dropping
/// the newer record on its next write, and erasing evidence — of which
/// bytes are whose, of which comment blocks seeding wrote, or of a move
/// out of the directory pi reserved being over. That last one is why
/// this bump is not optional: a build that dropped the record would read
/// a finished move as unfinished, and reclaim what the person has since
/// put under the reserved name.
pub const LOCK_VERSION: u32 = 5;

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
pub struct Lock {
    pub version: u32,
    #[serde(default)]
    pub entries: BTreeMap<String, LockEntry>,
    /// The commit each declared source resolved to, by source name.
    /// Reproducibility cache, never intent: the manifest says which
    /// revision is wanted, this says which commit that came out as. A lost
    /// lock costs the record, not the pin.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub sources: BTreeMap<String, SourceRev>,
    /// Per `kendex.settings.toml` key: which skill seeded it and the hash
    /// of the comment block seeding last wrote — the proof a later refresh
    /// needs before it may rewrite the comment to a newer template.
    /// Project-scope locks only.
    #[serde(
        default,
        skip_serializing_if = "BTreeMap::is_empty",
        rename = "settings-seeds"
    )]
    pub settings_seeds: BTreeMap<String, SettingsSeed>,
}

/// One seeded settings key's provenance.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SettingsSeed {
    /// The skill whose template owns this key's comment. `None` on records
    /// imported from a v1 ledger that named no owner: those verify — a
    /// hand edit is still told from seeded text — but are never rewritten.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// FNV-1a (v1's algorithm, kept so imported ledgers verify) of the
    /// comment block last written by seeding.
    pub hash: String,
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

/// One installation an edge points at: the counterpart named the way the
/// manifest and the lock name an installation.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct InstallRef {
    /// Declared source name — dependencies stay inside one catalog, so this
    /// is the source both ends share.
    pub source: String,
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub scope: Scope,
}

/// The bundle an installation came in with.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleRef {
    pub source: String,
    pub name: String,
    pub scope: Scope,
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
    /// What was written, when the harness stores this kind as another one.
    /// Removal and refresh read it instead of deriving a path the install
    /// never took.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emitted: Option<EmittedArtifact>,
    /// The registry entry a script-less hook registered (custom hooks: the
    /// person's own command, verbatim). Removal must name that command to
    /// take the entry back out, and it cannot be re-derived once the
    /// manifest entry that carried it is gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration: Option<HookRegistration>,
    /// Pi hooks only: this installation's move out of the directory pi
    /// reserved has finished. A finished move is a fact about the past,
    /// so it is recorded here instead of being re-derived from what is on
    /// disk now — an edit to the new copy, or a catalog that changes the
    /// hook's event, would otherwise re-open a move that is over. Once
    /// this is set, everything under the reserved name is somebody
    /// else's, whatever its bytes or its command happen to be.
    #[serde(default, skip_serializing_if = "is_false")]
    pub left_pi_reserved_name: bool,
    /// Every reason this installation exists. Never empty once written: an
    /// installation nothing can account for would be swept the moment
    /// anything looked at it.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub reasons: BTreeSet<Reason>,
}

fn is_false(value: &bool) -> bool {
    !*value
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
/// terms: a codex command lands as a skill, under a name the user types.
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

/// Where this scope's lock lives right now: the new name, or the old one
/// when only it exists — the rename op moves it (the global lock is
/// `lock.json` in both generations, so only projects have two spellings).
pub fn lock_path(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => env.global_lock_file(),
        Scope::Project { root } => crate::rename::existing_or_new(
            Env::project_lock_file(root),
            root.join(crate::rename::LEGACY_LOCK_FILE),
        ),
    }
}

/// What sits at a lock path. A v1 lock keys entries by bare name and carries
/// a `harnesses` array; v2 keys carry `kind:name:harness` with one `harness`
/// field. The shapes are incompatible — deserializing v1 text straight into
/// [`Lock`] surfaces a raw "missing field" error instead of naming what the
/// file actually is.
#[derive(Debug, Clone, PartialEq)]
pub enum LockFile {
    Absent,
    Legacy { raw: String },
    Current(Lock),
}

/// `"version": 1` alone cannot identify the old product generation: this
/// product's own v0.1 locks also say 1 and load compatibly (see
/// [`LOCK_VERSION`]). The key shape is the discriminator — bare-name keys
/// against v2's always-present `kind:name:harness` separator — and it only
/// applies to files not declaring a version above 1, so a current file with
/// odd keys is diagnosed as corrupt, never mislabeled v1. An empty map
/// matches both shapes and reads as current, the only reading a lost lock
/// or a fresh scope can mean.
fn is_v1(value: &serde_json::Value) -> bool {
    let version = value.get("version").and_then(serde_json::Value::as_i64);
    if version.is_some_and(|v| v > 1) {
        return false;
    }
    value
        .get("entries")
        .and_then(serde_json::Value::as_object)
        .is_some_and(|entries| !entries.is_empty() && entries.keys().all(|k| !k.contains(':')))
}

/// Text-taking wrapper for callers (the CLI's one-shot v1 importer) that
/// have not already parsed the JSON. Unparseable text is not v1 — it is
/// corrupt, and `load_file` names that distinctly.
pub fn is_v1_text(text: &str) -> bool {
    serde_json::from_str(text).is_ok_and(|value| is_v1(&value))
}

pub fn load_file(path: &Path) -> Result<LockFile> {
    crate::rename::refuse_both_generations(path)?;
    let Some(text) = read_if_exists(path)? else {
        return Ok(LockFile::Absent);
    };
    parse_text(path, &text)
}

/// [`load_file`] for text the caller already read — the importer binds its
/// preconditions to the exact bytes it classified, so it must classify the
/// bytes it read rather than a later re-read.
pub fn parse_text(path: &Path, text: &str) -> Result<LockFile> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| CoreError::LockCorrupt {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
    if let Some(version) = value.get("version").and_then(serde_json::Value::as_i64)
        && version > i64::from(LOCK_VERSION)
    {
        return Err(CoreError::SchemaTooNew {
            path: path.to_path_buf(),
            found: version,
        });
    }
    if is_v1(&value) {
        return Ok(LockFile::Legacy {
            raw: text.to_owned(),
        });
    }
    let mut lock: Lock = serde_json::from_value(value).map_err(|e| CoreError::LockCorrupt {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    backfill_requested_reason(&mut lock);
    Ok(LockFile::Current(lock))
}

// A record written before installations carried their reasons: everything
// installed then was installed because it was asked for, which is the only
// reading that cannot invent a dependency nobody declared. The next write
// records it.
fn backfill_requested_reason(lock: &mut Lock) {
    for entry in lock.entries.values_mut() {
        if entry.reasons.is_empty() {
            entry.reasons.insert(Reason::Requested);
        }
    }
}

/// Load for mutation: a v1 lock is a hard error, never a write target — same
/// posture as [`crate::manifest::file::load_for_mutation`]. Callers that only
/// observe (the audit view) use [`load_file`] instead so a v1 lock degrades
/// to a note rather than blocking the read.
pub fn load(path: &Path) -> Result<Lock> {
    match load_file(path)? {
        LockFile::Absent => Ok(Lock {
            version: LOCK_VERSION,
            ..Lock::default()
        }),
        LockFile::Legacy { .. } => Err(CoreError::LegacyLock {
            path: path.to_path_buf(),
        }),
        LockFile::Current(lock) => Ok(lock),
    }
}

pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    let mut text = serde_json::to_string_pretty(lock).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    atomic_write(path, &text)
}

#[cfg(test)]
mod tests;
