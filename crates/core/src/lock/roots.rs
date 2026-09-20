//! How a committed record spells where things sit under the project:
//! every position is a remainder of the root, and the root itself is
//! never written.
//!
//! A project's lock is committed with the renders it records, so it is
//! read in every clone of the project — at another path, on another
//! machine, in a linked worktree — and every one of them is the record's
//! own project. Read as an absolute path a position would be the writing
//! checkout's: refresh reads `emitted.paths` as the positions this scope
//! owns and takes back what a fresh render does not produce, out of that
//! other tree. So a position is written as the part of it that is about
//! the installation rather than about the checkout, and rejoins onto the
//! root reading it. Provenance needs no spelling of its own: a path
//! source's provenance is its declaration in the marked spelling
//! `crate::source::declared_path_identity` gives it, which every clone
//! shares, and never a directory on the machine that wrote the record.
//!
//! Two entry points, one per end. The read rejoins and refuses what does
//! not rejoin: a remainder that is not one — absolute, empty, walking out
//! through `..` — is a claim on something outside this project. The write
//! refuses the same claim before spelling it, so what a project lock
//! cannot hand out it cannot be made to hold either.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::paths::{canonical, slashed};

use super::{LOCK_FILE, Lock};

/// Read a record as this project's: every remainder it states rejoins onto
/// the root it is being read from, and one that is no remainder refuses
/// the record.
pub(super) fn read_against(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    for (key, entry) in &mut lock.entries {
        let Some(emitted) = entry.emitted.as_mut() else {
            continue;
        };
        for position in &mut emitted.paths {
            *position = rejoined(path, key, &root, position)?;
        }
    }
    Ok(())
}

/// Put a record down under this project: every position becomes the
/// remainder it states of the root being written to, and one that states
/// none refuses the write. Hands back that root, in the one spelling
/// [`project_root_at`] settles on, for the machine half to name; `None`
/// for the global lock, which has no single root.
pub(super) fn write_under(path: &Path, lock: &mut Lock) -> Result<Option<PathBuf>> {
    let Some(root) = project_root_at(path) else {
        return Ok(None);
    };
    for (key, entry) in &mut lock.entries {
        let Some(emitted) = entry.emitted.as_mut() else {
            continue;
        };
        for position in &mut emitted.paths {
            *position = remainder(path, key, &root, position)?;
        }
    }
    Ok(Some(root))
}

/// The project root whose lock sits at `path`, or `None` where the path is
/// the global lock. The inverse of [`super::lock_path`]: a project scope's
/// lock is written at its root under [`LOCK_FILE`], and the global lock
/// lives under the app's own directory with a name of its own.
///
/// Fixed to one spelling here, once (invariant 17), and handed down from
/// the entry point rather than derived again: everything below joins onto
/// or strips off this root, so a second derivation is a second answer, and
/// a record can come out holding positions in the caller's spelling under
/// a machine record naming the resolved one. A spelling that does not
/// resolve is kept as it came in, a first write naming a directory that
/// need not exist yet.
pub(super) fn project_root_at(path: &Path) -> Option<PathBuf> {
    if path.file_name()? != LOCK_FILE {
        return None;
    }
    // A relatively named lock sits in the current directory, which is what
    // it has to answer as: the empty prefix `parent` gives back is one
    // every path starts with, and containment would wave anything through.
    let root = match path.parent() {
        Some(root) if !root.as_os_str().is_empty() => root,
        _ => Path::new("."),
    };
    Some(canonical(root).unwrap_or_else(|_| root.to_path_buf()))
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

/// The position as the committed record spells it: the part of it under
/// the root, slashed.
///
/// A project scope installs only inside its own root, so a position
/// reaching past it is one this scope may not touch, and a position equal
/// to the root states nothing at all — rejoined it would name the reading
/// project's whole directory as a place this scope owns. Both are refused
/// here, naming the position, before anything is written: what this judges
/// is the record kendex is about to put down, and the read side judges the
/// one it finds.
fn remainder(path: &Path, key: &str, root: &Path, position: &Path) -> Result<PathBuf> {
    let claim = || CoreError::LockOutsideProject {
        path: path.to_path_buf(),
        key: key.to_owned(),
        recorded: position.to_path_buf(),
        root: root.to_path_buf(),
    };
    if reaches_outside(root, position) {
        return Err(claim());
    }
    let under = position.strip_prefix(root).map_err(|_| claim())?;
    if under.as_os_str().is_empty() {
        return Err(claim());
    }
    Ok(PathBuf::from(slashed(under)))
}

/// Where one recorded position sits when the record is read here: the
/// reading root plus the remainder the record states.
///
/// Held to what a remainder is rather than to the spellings kendex's own
/// writes keep, because what this judges is a record kendex may not have
/// written. A remainder is made of plain names: one that is absolute
/// names another tree outright, one that walks through `..` or `.`
/// resolves to somewhere the containment check would wave through, and an
/// empty one is the root itself. Each is refused naming the position and
/// the root it was read against. The rejoin goes component by component,
/// so the slashed spelling the record keeps comes out in this machine's
/// own.
fn rejoined(path: &Path, key: &str, root: &Path, position: &Path) -> Result<PathBuf> {
    let claim = || CoreError::LockOutsideProject {
        path: path.to_path_buf(),
        key: key.to_owned(),
        recorded: position.to_path_buf(),
        root: root.to_path_buf(),
    };
    let mut parts = position.components().peekable();
    if parts.peek().is_none() {
        return Err(claim());
    }
    let mut here = root.to_path_buf();
    for part in parts {
        match part {
            Component::Normal(name) => here.push(name),
            Component::Prefix(_)
            | Component::RootDir
            | Component::CurDir
            | Component::ParentDir => {
                return Err(claim());
            }
        }
    }
    Ok(here)
}
