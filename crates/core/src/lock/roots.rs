//! Whose the paths in a record are: the root it is read or written
//! against, where a record carried in from another checkout resolves, and
//! the boundary a project's record may claim.
//!
//! Two entry points, one per end, because the order the steps run in is
//! the whole guarantee. A read resolves and then judges: reverse those and
//! every travelled record is refused before it can rebase, which is the
//! bug this module was written to close. A write judges and then stamps.
//! Neither order is a caller's to choose, so neither step is a caller's to
//! call.

use std::path::{Component, Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::paths::canonical;

use super::{LOCK_FILE, Lock};

/// Read a record as this project's: resolve what it states against the
/// root it is being read from, then hold the result to that root.
pub(super) fn read_against(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(reading) = project_root_at(path) else {
        return Ok(());
    };
    resolve(path, &reading, lock)?;
    refuse_foreign_paths(path, &reading, lock)
}

/// Put a record down under this project: hold it to the root being written
/// to, then name that root in it.
///
/// A read can resolve a record another root wrote, because every position
/// in it states a remainder of that root or the record is refused, and a
/// remainder rejoins under the root reading. A write has nothing to
/// resolve: the record handed in is the one that lands, so what a project
/// lock cannot hand out it cannot be made to hold either.
///
/// The root is named at the write rather than where each record is built,
/// because this is the one call that knows the path being written, which
/// is the same knowledge the read checks against. Two answers to one
/// question is how the two ends come apart. It goes down in the one
/// spelling [`project_root_at`] settles on.
pub(super) fn write_under(path: &Path, lock: &mut Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    refuse_foreign_paths(path, &root, lock)?;
    match lock.root.as_deref() {
        // Canonical identity, not spelling: a write reaching this project
        // through a link is still this project's, and the record it
        // carries need not be re-spelled to say so.
        Some(recorded) if same_directory(recorded, &root) => Ok(()),
        Some(recorded) => Err(CoreError::LockFromAnotherProject {
            path: path.to_path_buf(),
            recorded: recorded.to_path_buf(),
            root,
        }),
        None => {
            lock.root = Some(root);
            Ok(())
        }
    }
}

/// The project root whose lock sits at `path`, or `None` where the path is
/// the global lock. The inverse of [`super::lock_path`]: a project scope's lock is
/// written at its root under [`LOCK_FILE`], and the global lock lives under
/// the app's own directory with a name of its own.
///
/// Fixed to one spelling here, once (invariant 17), and handed down from
/// the entry point rather than derived again: everything below compares
/// against this root and one of them rewrites the record around it, so a
/// second derivation is a second answer, and a record can come out holding
/// positions in the caller's spelling under a root field in the resolved
/// one. A spelling that does not resolve is kept as it came in, a first
/// write naming a directory that need not exist yet.
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
/// On the read this runs after [`resolve`], which has rebased every
/// position onto this root or refused the record. What that pass cannot
/// settle is a remainder walking back out: `../elsewhere` states a
/// remainder of the writing root like any other and rejoins like one, so a
/// rebased position can still hold a `..`. This is where the `..` is
/// decided, whichever side of the rebase it arrived on.
fn refuse_foreign_paths(path: &Path, root: &Path, lock: &Lock) -> Result<()> {
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
/// root a write lands in is a directory it is about to write a file into,
/// so it resolves; one that cannot be reached is not the one that can.
fn same_directory(recorded: &Path, root: &Path) -> bool {
    matches!(
        (canonical(recorded), canonical(root)),
        (Ok(recorded), Ok(root)) if recorded == root
    )
}

/// Where one position sits when the record is read here: the reading root
/// plus the part of the position the record actually states.
///
/// Every position kendex writes is names joined onto the scope root
/// (invariant 17), so a genuine record always states a remainder of the
/// root it went down under. A position that states none is not one this
/// record's own project ever wrote, and a position equal to that root
/// states nothing at all — rejoined it would name the reading project's
/// whole directory as a place this scope owns. Both are refused here
/// rather than left to the containment check, which judges the reading
/// root and waves through whatever happens to sit under it, a person's own
/// file among it.
///
/// The last arm is what holds a root the record may state however it
/// likes. `Path::join` drops its base when handed an absolute path, and
/// `strip_prefix` hands back an absolute remainder for one prefix, the
/// empty one — so a record rooted at nothing would carry every position
/// across untouched and call it resolved. Asking where the rejoined path
/// landed refuses that without asking anything of the root itself. A `..`
/// remainder is relative and still starts with the reading root, which is
/// [`refuse_foreign_paths`]'s to judge and not this one's.
fn rejoined(
    path: &Path,
    key: &str,
    recorded: &Path,
    reading: &Path,
    position: &Path,
) -> Result<PathBuf> {
    let claim = || CoreError::LockOutsideProject {
        path: path.to_path_buf(),
        key: key.to_owned(),
        recorded: position.to_path_buf(),
        root: recorded.to_path_buf(),
    };
    let under = position.strip_prefix(recorded).map_err(|_| claim())?;
    if under.as_os_str().is_empty() {
        return Err(claim());
    }
    let here = reading.join(under);
    match here.starts_with(reading) {
        true => Ok(here),
        false => Err(claim()),
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
/// What moves is a provenance under the writing root, which is not the
/// same question as whether the declaration behind it is checkout-relative
/// ([`crate::source`] joins a relative `path` onto the scope root and
/// takes an absolute one as spelled). The two part company both ways. A
/// source declared `path = "../catalog"` names a different directory per
/// checkout, and its provenance sits under no project root, so it is left
/// as written and its entries still read as rebound. A source declared by
/// an absolute path that happens to point inside the writing checkout
/// names the same directory from either, and is rebased off the value its
/// declaration still produces. Nothing here refuses the way [`rejoined`]
/// does, because provenance is compared, never written to.
///
/// An empty remainder is the ordinary case rather than a claim on nothing
/// — a source declared as the project itself — and names the reading root.
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
/// A project's lock travels. kendex keeps it out of git
/// ([`crate::engine::posture`] writes the ignore line), so nothing carries
/// it on its own: it arrives when a tree is copied, and in a linked
/// worktree when the repository's worktree tooling is set to copy it in,
/// which is what `WORKTREE_COPIES` does here. The record that arrives
/// states every position, and the provenance of every source declared
/// inside the project, as an absolute path under the root that wrote it.
/// Read as written those are the other checkout's: refresh reads the
/// positions as the ones this scope owns and takes back what a new render
/// no longer produces, out of that checkout, and every entry reads as
/// rebound to a source that only moved because the checkout did.
///
/// So they are not read as written. The reading root plus the remainder a
/// path states is where the same thing sits here, and every position
/// states a remainder of the writing root or the record is refused
/// ([`rejoined`]) — no position is carried across unresolved, which is
/// what makes this a resolution and not a refusal. Whether what it
/// produces sits inside the reading root is [`refuse_foreign_paths`]'s to
/// say: a remainder can itself walk back out. Provenance is the looser
/// half, and [`resolve_provenance`] says where it stops.
///
/// Two roots leave nothing to resolve against. One the record does not
/// name, so there is no prefix to take off any position. And a reading root
/// that is no place on this machine, since nothing rejoined onto it would
/// be one either and a relative root names a different place per process.
/// The global lock names no root because it has none, each harness owning a
/// directory of its own, and has nothing to resolve against.
fn resolve(path: &Path, reading: &Path, lock: &mut Lock) -> Result<()> {
    let Some(recorded) = lock.root.clone() else {
        return Err(CoreError::LockWithoutProject {
            path: path.to_path_buf(),
        });
    };
    // Spelling, not directory identity, because what the rebase strips off
    // each position is the prefix the record spells. A root that names this
    // same directory in another spelling still has every position to move:
    // a record rooted at `via`, a link to `real`, spells its positions
    // under `via` too, so read at `real` it must strip `via` and rejoin. Ask
    // whether the two roots resolve alike and the strip is skipped while
    // those positions keep the other spelling, and every one of them is
    // then outside the root reading.
    if recorded == reading {
        return Ok(());
    }
    // The root being read against has to be a place, or nothing rejoined
    // onto it is one either and a relative root names a different place per
    // process. What the RECORD names is held to nothing here: every
    // position it states is judged on rejoining, below.
    if !reading.is_absolute() {
        return Err(CoreError::LockFromAnotherProject {
            path: path.to_path_buf(),
            recorded,
            root: reading.to_path_buf(),
        });
    }
    let slashed = PathBuf::from(crate::paths::slashed(&recorded));
    for (key, entry) in &mut lock.entries {
        resolve_provenance(&slashed, reading, &mut entry.source_repo);
        let Some(emitted) = entry.emitted.as_mut() else {
            continue;
        };
        for position in &mut emitted.paths {
            *position = rejoined(path, key, &recorded, reading, position)?;
        }
    }
    // Provenance wherever else the record keeps it. The rule is over what
    // the record states, not over which writer states it.
    for source in lock.sources.values_mut() {
        resolve_provenance(&slashed, reading, &mut source.repo);
    }
    for bundle in lock.bundles.values_mut() {
        resolve_provenance(&slashed, reading, &mut bundle.source_repo);
    }
    // The record is this project's now, and the next write says so. Left
    // naming the writer, every later read would rebase paths that already
    // sit here — off a root this tree has no relation to.
    lock.root = Some(reading.to_path_buf());
    Ok(())
}
