//! Reading and writing a lock file: what sits at a path, where a record
//! carried in from another checkout resolves, the boundary a project's
//! record may claim, and the one version shape that loads.

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
/// reaching past it is a position this scope may not touch. Refresh and
/// removal read those paths as the ones this scope owns and take back what
/// a new render no longer produces, which past the root is somebody else's
/// files. So the record is refused, naming the path, at both ends: no read
/// hands one out and no write puts one down.
///
/// On the read this is the floor under
/// [`resolve_against_reading_root`], which has already rebased every
/// position a travelled record stated as a remainder of its own root. What
/// reaches here is what had no remainder to rebase — a claim on another
/// tree outright, or one walking back out through `..`.
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

/// Where a travelled record's positions sit, read from the project reading
/// it rather than from the one that wrote it.
///
/// A project's lock travels. `git worktree` seeds each linked checkout with
/// a copy, and so does anyone who copies a tree; the record that arrives
/// names every position as an absolute path under the root that wrote it.
/// Read as written those are the other checkout's files, and refresh reads
/// them as the positions this scope owns and takes back the ones a new
/// render no longer produces — out of that checkout.
///
/// So they are not read as written. A record names the root it went down
/// under, which makes each position that root plus a remainder, and the
/// remainder is the part the record actually states: where the same
/// position sits here is the reading root plus that remainder. The rebase
/// is total, so nothing it produces leaves the reading root and a travelled
/// record cannot reach another tree whatever it was carrying — the reason
/// this is a resolution and not a refusal.
///
/// A position the writing root does not contain has no remainder to rebase
/// and nothing here may invent one, so it is left as it stands for
/// [`refuse_foreign_paths`] to judge against the reading root.
///
/// A record naming no project is refused rather than adopted: with no root
/// to rebase off, reading its positions as this project's is exactly the
/// guess the refusal exists to stop.
///
/// The global lock has no single root — each harness owns a directory of
/// its own — so it records none and has nothing to resolve against.
fn resolve_against_reading_root(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    let Some(recorded) = lock.root.as_deref() else {
        return Err(CoreError::LockWithoutProject {
            path: path.to_path_buf(),
        });
    };
    if same_directory(recorded, root) {
        return Ok(());
    }
    let recorded = recorded.to_path_buf();
    for entry in lock.entries.values_mut() {
        let Some(emitted) = entry.emitted.as_mut() else {
            continue;
        };
        for position in &mut emitted.paths {
            if let Ok(remainder) = position.strip_prefix(&recorded) {
                *position = root.join(remainder);
            }
        }
    }
    // The record is this project's now, and the next write says so. Left
    // naming the writer, every later read would rebase paths that already
    // sit here — off a root this tree has no relation to.
    lock.root = Some(canonical(root).unwrap_or_else(|_| root.to_path_buf()));
    Ok(())
}

/// The write end of the same question: which project a record may be put
/// down naming.
///
/// A read resolves a foreign root because it can — every position rebases
/// onto the reading root and none can escape it. A write has nothing to
/// resolve: the record handed in is the one that lands, and a project lock
/// that cannot hand out another project's name must not be made to hold it
/// either.
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
    let mut lock: Lock = serde_json::from_value(value).map_err(|e| CoreError::LockCorrupt {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    resolve_against_reading_root(path, &mut lock)?;
    refuse_foreign_paths(path, &lock)?;
    Ok(LockFile::Current(lock))
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
