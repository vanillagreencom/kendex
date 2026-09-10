//! Reading and writing a lock file: what sits at a path, and the one
//! version shape that loads. Whose the paths in it are is
//! [`super::roots`]'s question.

use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::fs::{atomic_write_no_follow, read_if_exists};

use super::roots::{read_against, write_under};
use super::{LOCK_VERSION, Lock};

/// What sits at a lock path. Only the shape this build writes loads: a
/// record from an older generation is damaged as far as this build is
/// concerned, and [`CoreError::LockCorrupt`] names the way out.
#[derive(Debug, Clone, PartialEq)]
pub enum LockFile {
    Absent,
    Current(Lock),
}

pub fn load_file(path: &Path) -> Result<LockFile> {
    let Some(text) = read_if_exists(path)? else {
        return Ok(LockFile::Absent);
    };
    parse_text(path, &text)
}

/// [`load_file`] for text the caller already read — the importer binds its
/// preconditions to the exact bytes it classified, so it must classify the
/// bytes it read rather than a later re-read.
pub fn parse_text(path: &Path, text: &str) -> Result<LockFile> {
    let mut lock = parse_unresolved(path, text)?;
    read_against(path, &mut lock)?;
    Ok(LockFile::Current(lock))
}

/// The root a record states, as written — before [`super::roots`] resolves
/// it onto the root reading it. `None` where there is no record at the
/// path.
///
/// Whose folder this is is exactly the difference the resolution removes:
/// a record that travelled here states the root it was written under, and
/// after the read every record names the root it was read from. So the
/// stated root is taken before the resolution, and the resolution still
/// runs — every refusal a read of this record would make is a refusal
/// here, because it is the same read.
pub fn stated_root(path: &Path) -> Result<Option<PathBuf>> {
    let Some(text) = read_if_exists(path)? else {
        return Ok(None);
    };
    let mut lock = parse_unresolved(path, &text)?;
    let stated = lock.root.clone();
    read_against(path, &mut lock)?;
    Ok(stated)
}

/// The record as the file spells it, version-checked and parsed, with
/// every path still stating the root it was written under.
fn parse_unresolved(path: &Path, text: &str) -> Result<Lock> {
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
    // carry — where an installed set sits, which project wrote the record,
    // why an installation exists. Read as absent, each of those is a wrong
    // answer rather than a missing one: a set placeable at nothing comes
    // current on the next update of anything else, and an installation with
    // no reason recorded is swept as one nobody asked for. Nothing converts
    // the older shape, so nothing plans against it either.
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

/// Put the record down, with the version and the root it belongs to
/// stamped on it here.
///
/// The version is a fact about the build that wrote the file, and the read
/// holds every record to exactly this number — two places deciding it is
/// how a writer comes to put down something its own reader refuses.
///
/// The bytes replace whatever sits at the path rather than being written
/// through a link there. A lock is kendex's own record, the class
/// [`atomic_write_no_follow`] already covers, and not a file a person
/// routed somewhere of their own: a link pointing at another checkout's
/// lock is a copy of the record by another route, and writing through it
/// would land this project's resolved record in that checkout's file.
pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    let mut lock = lock.clone();
    lock.version = LOCK_VERSION;
    write_under(path, &mut lock)?;
    let mut text = serde_json::to_string_pretty(&lock).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    atomic_write_no_follow(path, &text)
}
