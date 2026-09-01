//! Whose the paths in a record are: the root it is read or written
//! against, where a record carried in from another checkout resolves, and
//! the boundary a project's record may claim.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::paths::canonical;

use super::{LOCK_FILE, Lock};

/// The project root whose lock sits at `path`, or `None` where the path is
/// the global lock. The inverse of [`super::lock_path`]: a project scope's lock is
/// written at its root under [`LOCK_FILE`], and the global lock lives under
/// the app's own directory with a name of its own.
///
/// Fixed to one spelling here, once (invariant 17). Everything below
/// compares against this root and one of them rewrites the record around
/// it, so derived twice it is two answers — a record holding positions in
/// the caller's spelling under a root field in the resolved one. A
/// spelling that does not resolve is kept as it came in: a first write
/// names a directory that need not exist yet, and [`same_directory`]
/// resolves both sides itself.
fn project_root_at(path: &Path) -> Option<PathBuf> {
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
/// position onto this root or refused the record. What reaches here is a
/// remainder that walks back out through `..`.
///
/// The global lock has no single root — each harness owns a directory of its
/// own — so it has no boundary to check.
pub(super) fn refuse_foreign_paths(path: &Path, lock: &Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    match outside_the_project(&root, lock) {
        None => Ok(()),
        Some((key, recorded)) => Err(CoreError::LockOutsideProject {
            path: path.to_path_buf(),
            key,
            recorded,
            root,
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

/// The position an entry recorded, stated as the part of it the record
/// actually says: what sits under the root it went down under.
///
/// Every position kendex writes is names joined onto the scope root
/// (invariant 17), so a genuine record always states one. A position that
/// states none is not one this record's own project ever wrote, and a
/// position equal to the root states nothing at all — rejoined it would
/// name the reading project's whole directory as a place this scope owns.
/// Both are refused here rather than left to the containment check, which
/// judges the reading root and waves through whatever happens to sit
/// under it — a person's own file among it.
fn remainder<'a>(path: &Path, key: &str, root: &Path, position: &'a Path) -> Result<&'a Path> {
    let claim = || CoreError::LockOutsideProject {
        path: path.to_path_buf(),
        key: key.to_owned(),
        recorded: position.to_path_buf(),
        root: root.to_path_buf(),
    };
    let under = position.strip_prefix(root).map_err(|_| claim())?;
    match under.as_os_str().is_empty() {
        true => Err(claim()),
        false => Ok(under),
    }
}

/// One recorded provenance, resolved the way a position is.
///
/// Provenance is `owner/repo`, `local`, `in-place` — or, for a source
/// declared by path, the directory that path resolved to. A catalog
/// declared inside the project is therefore an absolute path under the
/// writing root, and read anywhere else it names the other checkout: the
/// durable-provenance rule compares it for equality against what the
/// declaration resolves to now, so every entry reads as rebound to a
/// source nobody moved.
///
/// Only a path under the writing root moves, and nothing here refuses the
/// way [`remainder`] does: a catalog outside the project is the same
/// directory from either checkout and already spells itself the same, and
/// `owner/repo` and the two bare names are not paths at all. An empty
/// remainder is the ordinary case rather than a claim on nothing — a
/// source declared as the project itself — and names the reading root.
/// `root` arrives slashed, the spelling provenance is written in
/// ([`crate::paths::slashed`]); a prefix in the other separator would
/// match nothing on Windows.
fn resolve_provenance(root: &Path, reading: &Path, provenance: &mut String) {
    let Ok(under) = Path::new(provenance.as_str()).strip_prefix(root) else {
        return;
    };
    // Joined only where there is something to join. `Path::join` on an
    // empty remainder puts a separator down and nothing after it, and a
    // root with a trailing separator is a second spelling of itself —
    // which is the whole failure this resolution exists to end, since
    // provenance is judged by string equality.
    *provenance = match under.as_os_str().is_empty() {
        true => crate::paths::slashed(reading),
        false => crate::paths::slashed(&reading.join(under)),
    };
}

/// Where a travelled record's paths point, read from the project reading
/// it rather than from the one that wrote it.
///
/// A project's lock travels. `git worktree` seeds each linked checkout
/// with a copy, and so does anyone who copies a tree; the record that
/// arrives states every position and every path-source provenance as an
/// absolute path under the root that wrote it. Read as written those are
/// the other checkout's: refresh reads the positions as the ones this
/// scope owns and takes back what a new render no longer produces, out of
/// that checkout, and every entry reads as rebound to a source that only
/// moved because the checkout did.
///
/// So they are not read as written. The reading root plus the remainder a
/// path states is where the same thing sits here, and positions rebase
/// totally or the record is refused ([`remainder`]) — so nothing this
/// produces leaves the reading root, which is what makes this a resolution
/// and not a refusal.
///
/// Two roots leave nothing to state a remainder against, and reading the
/// paths as this project's anyway is exactly the guess the refusal exists
/// to stop: one the record does not name, and one that is no path on this
/// machine — a relative root names a different place per process, and
/// nothing rejoined onto it would be a place either. The global lock names
/// no root because it has none, each harness owning a directory of its
/// own, and has nothing to resolve against.
pub(super) fn resolve_against_reading_root(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(reading) = project_root_at(path) else {
        return Ok(());
    };
    let Some(recorded) = lock.root.as_deref() else {
        return Err(CoreError::LockWithoutProject {
            path: path.to_path_buf(),
        });
    };
    if same_directory(recorded, &reading) {
        return Ok(());
    }
    if !reading.is_absolute() {
        return Err(CoreError::LockFromAnotherProject {
            path: path.to_path_buf(),
            recorded: recorded.to_path_buf(),
            root: reading,
        });
    }
    let recorded = recorded.to_path_buf();
    let slashed = PathBuf::from(crate::paths::slashed(&recorded));
    for (key, entry) in &mut lock.entries {
        resolve_provenance(&slashed, &reading, &mut entry.source_repo);
        let Some(emitted) = entry.emitted.as_mut() else {
            continue;
        };
        for position in &mut emitted.paths {
            *position = reading.join(remainder(path, key, &recorded, position)?);
        }
    }
    // Provenance wherever else the record keeps it. Neither of these
    // carries a path today — a resolution recording a commit is a
    // repository's — and the rule is over what the record states, not over
    // which writer states it.
    for source in lock.sources.values_mut() {
        resolve_provenance(&slashed, &reading, &mut source.repo);
    }
    for bundle in lock.bundles.values_mut() {
        resolve_provenance(&slashed, &reading, &mut bundle.source_repo);
    }
    // The record is this project's now, and the next write says so. Left
    // naming the writer, every later read would rebase paths that already
    // sit here — off a root this tree has no relation to.
    lock.root = Some(reading);
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
    match same_directory(recorded, &root) {
        true => Ok(()),
        false => Err(CoreError::LockFromAnotherProject {
            path: path.to_path_buf(),
            recorded: recorded.to_path_buf(),
            root,
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
/// The root goes down in the one spelling [`project_root_at`] settles on.
pub(super) fn stamp_project(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    if lock.root.is_some() {
        return refuse_another_project(path, lock);
    }
    lock.root = Some(root);
    Ok(())
}
