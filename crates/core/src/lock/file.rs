//! Reading and writing a lock: the committed record at a path, this
//! machine's half beside it, and the one version shape that loads. How the
//! committed record spells what sits under the project is
//! [`super::roots`]'s question.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::fs::{atomic_write_no_follow, read_if_exists};

use super::roots::{project_root_at, read_against, write_under};
use super::{LOCK_VERSION, Lock, MACHINE_FILE, MachineRecord};

/// What sits at a lock path. Only the shape this build writes loads: a
/// record from an older generation is damaged as far as this build is
/// concerned, and [`CoreError::LockCorrupt`] names the way out.
#[derive(Debug, Clone, PartialEq)]
pub enum LockFile {
    Absent,
    Current(Lock),
}

/// This machine's half of a record: what it knows about each installation
/// the committed record names, one row per root that wrote through the
/// file.
///
/// One file can be written from several roots. It sits under `.cache`,
/// which is reached through whatever that name resolves to, and the
/// worktree convention this repository ships links a worktree's `.cache`
/// to the main checkout's — so a main checkout and every linked worktree
/// of it write one file, each carrying the committed record of its own
/// branch. A save replaces only the row for the root that wrote it and a
/// read takes only that row, so sharing the file loses nothing: the
/// delivery and the timestamp are per root, and the roots the file names
/// are every checkout that applied through it.
///
/// The root is here and not in the committed record because it is a fact
/// about this checkout: a committed record belongs to every clone alike,
/// and the one question that still needs a root — whether the folder a
/// project is being reconnected to is the folder it left
/// (`settings::relocate`) — is a question about this machine.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MachineState {
    version: u32,
    #[serde(default)]
    written: Vec<WrittenUnder>,
}

/// What one root wrote: its own delivery and timestamp for each
/// installation, keyed as the committed record keys them. `root` is
/// `None` for the global record, which no other record shares a file
/// with.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WrittenUnder {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root: Option<PathBuf>,
    #[serde(default)]
    entries: BTreeMap<String, MachineRecord>,
}

/// Where this machine's half of the record at `lock` sits: under the
/// project's cache directory for a project lock, which the managed ignore
/// block keeps out of git, and beside the global lock, which has no
/// project to hold a cache.
///
/// Joined, never resolved: a `.cache` that is a link is followed, which is
/// how a linked worktree comes to share the main checkout's file
/// ([`MachineState`]). The write is not held to the project root the way
/// every render is (`apply::landing`), so a link at `.cache` sends it
/// wherever the link points; the file holds nothing an install needs and
/// names no other project's files, which is what makes that acceptable
/// where it would not be for a render.
pub fn machine_path(lock: &Path) -> PathBuf {
    match project_root_at(lock) {
        Some(root) => root.join(".cache").join("kendex").join(MACHINE_FILE),
        None => lock.with_file_name(MACHINE_FILE),
    }
}

pub fn load_file(path: &Path) -> Result<LockFile> {
    let Some(text) = read_if_exists(path)? else {
        return Ok(LockFile::Absent);
    };
    parse_text(path, &text).map(LockFile::Current)
}

/// [`load_file`] for text the caller already read — the importer binds its
/// preconditions to the exact bytes it classified, so it must classify the
/// bytes it read rather than a later re-read, and a replay reads a
/// revision's copy of the record through the same refusals the file at
/// `path` gets. This machine's half is read from disk either way: it is
/// not part of what the importer classifies.
pub fn parse_text(path: &Path, text: &str) -> Result<Lock> {
    let mut lock: Lock = parse_versioned(path, text)?;
    read_against(path, &mut lock)?;
    let root = project_root_at(path);
    if let Some(written) = machine_state(path)?
        .and_then(|state| state.written.into_iter().find(|row| row.root == root))
    {
        for (key, record) in written.entries {
            // A record for an installation the committed lock no longer
            // names is a leftover of an earlier apply here, and nothing to
            // read it against.
            if let Some(entry) = lock.entries.get_mut(&key) {
                entry.machine = Some(record);
            }
        }
    }
    Ok(lock)
}

/// The roots this machine's half of the record at the path was written
/// under — one per checkout that applied through the file, which is
/// several where checkouts share a `.cache` ([`MachineState`]) — or none
/// where this machine holds nothing readable about the record. Every
/// refusal a read of the committed record would make is a refusal here,
/// because it is the same read: a root read off a record this build
/// cannot read supports no claim about whose folder it is. A machine half
/// this build cannot read is the same as none ([`machine_state`]).
pub fn stated_roots(path: &Path) -> Result<Vec<PathBuf>> {
    load_file(path)?;
    Ok(machine_state(path)?
        .map(|state| {
            state
                .written
                .into_iter()
                .filter_map(|row| row.root)
                .collect()
        })
        .unwrap_or_default())
}

/// This machine's half, or `None` where this machine holds nothing
/// readable about the record: the file is absent, or it is one this build
/// cannot read — not JSON, or another build's version.
///
/// Read as absent rather than refused. The half is a cache every reader
/// already handles the absence of, the next save writes it whole, and a
/// refusal here would stop an install over a file the install does not
/// need, with a remedy written for the committed record. Two builds
/// writing one file — a linked worktree on a branch that carries another
/// lock version, sharing the main checkout's `.cache` — are the ordinary
/// writer of the other-version case; an interrupted write, of the
/// unparseable one. A read has no channel for a note, so the fallback is
/// silent. A file that cannot be read at all is still the error every
/// read makes of one.
fn machine_state(path: &Path) -> Result<Option<MachineState>> {
    let machine = machine_path(path);
    let Some(text) = read_if_exists(&machine)? else {
        return Ok(None);
    };
    match parse_versioned(&machine, &text) {
        Ok(state) => Ok(Some(state)),
        Err(CoreError::LockCorrupt { .. } | CoreError::SchemaTooNew { .. }) => Ok(None),
        Err(other) => Err(other),
    }
}

/// One record as its file spells it, version-checked and parsed. Both
/// halves go through here, since they are written by one build in one
/// pass; what a refusal means differs per half, and the caller decides
/// it.
fn parse_versioned<T: DeserializeOwned>(path: &Path, text: &str) -> Result<T> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| CoreError::LockCorrupt {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
    let version = value.get("version").and_then(serde_json::Value::as_i64);
    if version.is_some_and(|version| version > i64::from(LOCK_VERSION)) {
        return Err(CoreError::SchemaTooNew {
            path: path.to_path_buf(),
            found: version.unwrap_or_default(),
        });
    }
    // The floor, and the reason there is one: every field a later version
    // introduced is a fact this build reads and an older record simply does not
    // carry — where an installed set sits, why an installation exists, and
    // as of version 11 whether a position is a remainder of the project or
    // a path on the machine that wrote it. Read as absent, each of those
    // is a wrong answer rather than a missing one. Nothing converts the
    // older shape, so nothing plans against it either.
    if version != Some(i64::from(LOCK_VERSION)) {
        return Err(CoreError::LockCorrupt {
            path: path.to_path_buf(),
            message: match version {
                Some(version) => format!(
                    "it is a version {version} record, and this kendex writes version {LOCK_VERSION}"
                ),
                None => "it names no version, so nothing here can say what shape it is".to_owned(),
            },
        });
    }
    serde_json::from_value(value).map_err(|e| CoreError::LockCorrupt {
        path: path.to_path_buf(),
        message: e.to_string(),
    })
}

/// Load the current lock for reads or mutations. An absent lock is an empty
/// current record; a present record this build cannot read is an error.
pub fn load(path: &Path) -> Result<Lock> {
    match load_file(path)? {
        LockFile::Absent => Ok(Lock {
            version: LOCK_VERSION,
            ..Lock::default()
        }),
        LockFile::Current(lock) => Ok(lock),
    }
}

/// Put the record down: the committed half at the path, spelled as a
/// remainder of the project, and this machine's half under the project's
/// cache, with the version stamped on both here.
///
/// The version is a fact about the build that wrote the file, and the read
/// holds every record to exactly this number — two places deciding it is
/// how a writer comes to put down something its own reader refuses.
///
/// The committed half replaces whatever sits at the path rather than
/// being written through a link there. A lock is kendex's own record, the
/// class [`atomic_write_no_follow`] already covers, and not a file a
/// person routed somewhere of their own: a link pointing at another
/// checkout's lock is a copy of the record by another route, and writing
/// through it would land this project's record in that checkout's file.
/// The machine half is reached through whatever `.cache` resolves to
/// ([`machine_path`]) and may be another checkout's file by design; it is
/// written whole, with this root's row replaced and every other root's
/// kept, so what a sharing checkout wrote stays written. A file this
/// build cannot read holds no row worth keeping, and is replaced.
pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    let mut lock = lock.clone();
    lock.version = LOCK_VERSION;
    let root = write_under(path, &mut lock)?;
    write_halves(path, root, &lock)
}

/// The committed half exactly as [`save`] lays it down at `path` for this
/// record: the version stamped, every position spelled as a remainder of
/// the project, the newline the file already uses. What a reader holding
/// a committed record to "as kendex writes it" compares against, so the
/// serialization is not derived a second time.
pub fn committed_text(path: &Path, lock: &Lock) -> Result<String> {
    let mut lock = lock.clone();
    lock.version = LOCK_VERSION;
    write_under(path, &mut lock)?;
    document(path, &lock)
}

fn write_halves(path: &Path, root: Option<PathBuf>, lock: &Lock) -> Result<()> {
    let mut machine = machine_state(path)?.unwrap_or_default();
    machine.version = LOCK_VERSION;
    machine.written.retain(|row| row.root != root);
    machine.written.push(WrittenUnder {
        root,
        entries: lock
            .entries
            .iter()
            .filter_map(|(key, entry)| Some((key.clone(), entry.machine.clone()?)))
            .collect(),
    });
    machine.written.sort_by(|a, b| a.root.cmp(&b.root));
    atomic_write_no_follow(path, &document(path, lock)?)?;
    let beside = machine_path(path);
    atomic_write_no_follow(&beside, &document(&beside, &machine)?)
}

fn document<T: Serialize>(path: &Path, record: &T) -> Result<String> {
    let text = serde_json::to_string_pretty(record).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    let current = read_if_exists(path)?.unwrap_or_default();
    let newline = crate::fs::line_terminator(&current);
    Ok(format!("{}{newline}", text.replace('\n', newline)))
}
