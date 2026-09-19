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
/// the committed record names, keyed as that record keys them, and the
/// root it was written under.
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root: Option<PathBuf>,
    #[serde(default)]
    entries: BTreeMap<String, MachineRecord>,
}

/// Where this machine's half of the record at `lock` sits: under the
/// project's cache directory for a project lock, which the managed ignore
/// block keeps out of git, and beside the global lock, which has no
/// project to hold a cache.
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
    parse_text(path, &text)
}

/// [`load_file`] for text the caller already read — the importer binds its
/// preconditions to the exact bytes it classified, so it must classify the
/// bytes it read rather than a later re-read. This machine's half is read
/// from disk either way: it is not part of what the importer classifies.
pub fn parse_text(path: &Path, text: &str) -> Result<LockFile> {
    let mut lock: Lock = parse_versioned(path, text)?;
    read_against(path, &mut lock)?;
    if let Some(state) = machine_state(path)? {
        for (key, record) in state.entries {
            // A record for an installation the committed lock no longer
            // names is a leftover of an earlier apply here, and nothing to
            // read it against.
            if let Some(entry) = lock.entries.get_mut(&key) {
                entry.machine = Some(record);
            }
        }
    }
    Ok(LockFile::Current(lock))
}

/// The root this machine's half of the record states, or `None` where this
/// machine holds nothing about the record at the path. Every refusal a
/// read of the committed record would make is a refusal here, because it
/// is the same read: a root read off a record this build cannot read
/// supports no claim about whose folder it is.
pub fn stated_root(path: &Path) -> Result<Option<PathBuf>> {
    load_file(path)?;
    Ok(machine_state(path)?.and_then(|state| state.root))
}

fn machine_state(path: &Path) -> Result<Option<MachineState>> {
    let machine = machine_path(path);
    let Some(text) = read_if_exists(&machine)? else {
        return Ok(None);
    };
    Ok(Some(parse_versioned(&machine, &text)?))
}

/// One record as its file spells it, version-checked and parsed. Both
/// halves go through here: they are written by one build in one pass, and
/// a half from another generation is refused by the same rule.
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
/// remainder of the project, and this machine's half beside it, with the
/// version stamped on both here.
///
/// The version is a fact about the build that wrote the file, and the read
/// holds every record to exactly this number — two places deciding it is
/// how a writer comes to put down something its own reader refuses.
///
/// The bytes replace whatever sits at each path rather than being written
/// through a link there. A lock is kendex's own record, the class
/// [`atomic_write_no_follow`] already covers, and not a file a person
/// routed somewhere of their own: a link pointing at another checkout's
/// lock is a copy of the record by another route, and writing through it
/// would land this project's record in that checkout's file.
pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    let mut lock = lock.clone();
    lock.version = LOCK_VERSION;
    let root = write_under(path, &mut lock)?;
    let machine = MachineState {
        version: LOCK_VERSION,
        root,
        entries: lock
            .entries
            .iter()
            .filter_map(|(key, entry)| Some((key.clone(), entry.machine.clone()?)))
            .collect(),
    };
    atomic_write_no_follow(path, &document(path, &lock)?)?;
    let beside = machine_path(path);
    atomic_write_no_follow(&beside, &document(&beside, &machine)?)
}

fn document<T: Serialize>(path: &Path, record: &T) -> Result<String> {
    let mut text = serde_json::to_string_pretty(record).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    Ok(text)
}
