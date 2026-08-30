//! Reading and writing a lock file: what sits at a path, the boundary a
//! project's record may claim, and the one version shape that loads.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::paths::canonical;

use super::{LOCK_FILE, LOCK_VERSION, Lock};

/// The project root whose lock sits at `path`, or `None` where the path is
/// the global lock. The inverse of [`super::lock_path`]: a project scope's lock is
/// written at its root under [`LOCK_FILE`], and the global lock lives under
/// the app's own directory with a name of its own.
fn project_root_at(path: &Path) -> Option<&Path> {
    if path.file_name()? != LOCK_FILE {
        return None;
    }
    // A relatively named lock sits in the current directory, which is what
    // it has to answer as: the empty prefix `parent` gives back is one
    // every path starts with, and containment would wave anything through.
    match path.parent() {
        Some(root) if !root.as_os_str().is_empty() => Some(root),
        _ => Some(Path::new(".")),
    }
}

/// Whether `path` reaches out of `root`.
///
/// Two ways it can. It can name somewhere else outright, which
/// `Path::starts_with` catches. Or it can start under `root` and walk back
/// out: `starts_with` matches component against component and resolves
/// nothing, so `<root>/../elsewhere` reads as inside while every operation
/// on it lands outside.
///
/// A `..` is refused rather than resolved. Nothing kendex writes carries
/// one — an emitted path is names joined onto a root [`super::lock_path`]
/// already resolved (invariant 17) — so there is no reading of one to
/// recover, and refusing does not turn on getting normalization right.
fn reaches_outside(root: &Path, path: &Path) -> bool {
    !path.starts_with(root) || path.components().any(|part| part == Component::ParentDir)
}

/// The first position a lock claims outside `root`, with the entry claiming
/// it.
///
/// Held to [`reaches_outside`] rather than to the spellings kendex's own
/// writes keep: what this judges is a record kendex may not have written,
/// which is the whole reason it is here.
fn outside_the_project(root: &Path, lock: &Lock) -> Option<(String, PathBuf)> {
    lock.entries.iter().find_map(|(key, entry)| {
        let outside = entry
            .emitted
            .as_ref()?
            .paths
            .iter()
            .find(|path| reaches_outside(root, path))?;
        Some((key.clone(), outside.clone()))
    })
}

/// A project scope installs only inside its own root, so `emitted.paths`
/// reaching past it is not a record this project ever wrote — a lock carried
/// along with a copied checkout is one that does. Refresh and removal read
/// those paths as the positions this scope owns and take back the ones a new
/// render no longer produces, which in another tree is somebody else's
/// files. So the record is refused, naming the path, at both ends: no read
/// hands one out and no write puts one down.
///
/// The global lock has no single root — each harness owns a directory of its
/// own — so it has no boundary to check.
fn refuse_foreign_paths(path: &Path, lock: &Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    match outside_the_project(root, lock) {
        None => Ok(()),
        Some((key, recorded)) => Err(CoreError::LockOutsideProject {
            path: path.to_path_buf(),
            key,
            recorded,
            root: root.to_path_buf(),
        }),
    }
}

/// Whether `recorded` and `root` name the same directory.
///
/// Canonically at both ends ([`canonical`]), because neither side arrives
/// holding the one spelling (invariant 17): macOS fronts its temp
/// directories through `/var -> /private/var`, so a root compared as text
/// does not equal itself.
///
/// A spelling that resolves to nothing is not this project's root. The
/// root reading a lock is the directory that lock was just read out of, so
/// it resolves; one that cannot be reached is not the one that can.
fn same_directory(recorded: &Path, root: &Path) -> bool {
    matches!(
        (canonical(recorded), canonical(root)),
        (Ok(recorded), Ok(root)) if recorded == root
    )
}

/// Which project wrote this record, held against the project reading it.
///
/// [`refuse_foreign_paths`] establishes containment, and containment is not
/// ownership: a second checkout nested below this root sits inside it, so
/// every path a lock carried out of that checkout names is inside too.
/// Refresh reads those as positions this project owns and takes back the
/// ones a new render no longer produces — out of the nested tree. Only the
/// root that wrote the record settles it, so the record says which.
///
/// A record naming no project is refused rather than adopted: nothing here
/// knows who wrote it, and reading it as this project's is exactly the
/// guess the refusal exists to stop.
///
/// The global lock has no single root, so it records none and there is
/// nothing to hold it to.
fn refuse_another_project(path: &Path, lock: &Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    let Some(recorded) = lock.root.as_deref() else {
        return Err(CoreError::LockWithoutProject {
            path: path.to_path_buf(),
        });
    };
    match same_directory(recorded, root) {
        true => Ok(()),
        false => Err(CoreError::LockFromAnotherProject {
            path: path.to_path_buf(),
            recorded: recorded.to_path_buf(),
            root: root.to_path_buf(),
        }),
    }
}

/// Name the project this record is written under, refusing one that
/// already names another.
///
/// Stamped at the write rather than where each record is built: this is the
/// one call that knows the path being written, which is the same knowledge
/// the read checks against — two answers to one question is how the two
/// ends come apart. What a project lock cannot hand out it cannot be made
/// to hold, so a record naming another root is refused here too.
///
/// The root goes down canonical where it resolves and as spelled where it
/// does not — a first write reaches here before the directory it names
/// exists. Nothing turns on which: [`same_directory`] resolves both sides.
fn stamp_project(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    if lock.root.is_some() {
        return refuse_another_project(path, lock);
    }
    lock.root = Some(canonical(root).unwrap_or_else(|_| root.to_path_buf()));
    Ok(())
}

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
    // added is a fact this build reads and an older record simply does not
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
    let lock: Lock = serde_json::from_value(value).map_err(|e| CoreError::LockCorrupt {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    refuse_foreign_paths(path, &lock)?;
    refuse_another_project(path, &lock)?;
    Ok(LockFile::Current(lock))
}

/// Load for mutation. An absent lock is a fresh scope; anything this build
/// cannot read has already been refused by [`parse_text`].
pub fn load(path: &Path) -> Result<Lock> {
    match load_file(path)? {
        LockFile::Absent => Ok(Lock {
            version: LOCK_VERSION,
            ..Lock::default()
        }),
        LockFile::Current(lock) => Ok(lock),
    }
}

/// The scope's lock for a read that only annotates rows — the counterpart
/// of [`crate::manifest::observed`], absorbing the same class for the same
/// reason. The record says where an installation came from; a scope whose
/// record this build cannot read answers for none of its own, and takes
/// no other scope's rows down with it.
pub fn observed(path: &Path) -> Result<Lock> {
    match load_file(path) {
        Ok(LockFile::Current(lock)) => Ok(lock),
        Ok(LockFile::Absent) => Ok(Lock::default()),
        Err(error) if error.is_unreadable_record() => Ok(Lock::default()),
        Err(error) => Err(error),
    }
}

pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    refuse_foreign_paths(path, lock)?;
    let mut lock = lock.clone();
    // Stamped at the write, like the root beside it. The version is a fact
    // about the build that wrote the file, and the read holds every record
    // to exactly this number — two places deciding it is how a writer
    // comes to put down something its own reader refuses.
    lock.version = LOCK_VERSION;
    stamp_project(path, &mut lock)?;
    let mut text = serde_json::to_string_pretty(&lock).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    atomic_write(path, &text)
}
