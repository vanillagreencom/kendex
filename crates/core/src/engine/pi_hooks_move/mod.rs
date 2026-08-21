//! What an older kendex left in the directory name Pi has since reserved.
//!
//! Pi prints a migration warning for any `hooks/` sitting directly beside
//! a root it loads, and halts an interactive start on it. The check is
//! existence only — it never looks inside — and the migration it names,
//! into `extensions/`, is one kendex hooks cannot take: they are shell
//! scripts the `pi-hooks` carrier runs, not Pi extensions. The storage
//! moved under a segment kendex owns (`crate::harness::pi::HOOK_HOME`);
//! the copies an earlier kendex wrote come off disk here, and the
//! directory goes with them — emptying it leaves the warning exactly
//! where it was.
//!
//! Two questions, kept apart. *May kendex take this file* is answered by
//! the lock and the bytes: only a file this scope's lock names, whose
//! hash is what apply last wrote, is ever moved — and a file it cannot
//! prove holds the whole installation, registration included, or holding
//! the bytes would only mean moving what runs them somewhere the person
//! never looked. *Is a replacement coming* is answered by the desired
//! state: a hook nothing asks for any more is retired outright, a hook
//! this pass really did render is retired against that rendering, and a
//! hook still asked for whose replacement this pass did not put in place
//! waits — the one case where holding on is repair rather than
//! abandonment.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::harness::pi;
use crate::lock::{Lock, LockEntry};
use crate::model::{HarnessId, ItemKind, Scope};

use super::config_edits::ConfigEditPlan;
use super::desired::DesiredState;
use super::removal::TrashGuard;
use super::targets::disabled_name;

mod disposal;
mod preflight;
mod retire;

use disposal::{legacy_registration, plan_directory, plan_registry};
pub(super) use preflight::{Preflight, preflight};
use retire::{Retire, retirable};

/// The directory name Pi reserved, and the registry an earlier kendex
/// wrote beside it.
const LEGACY_DIR: &str = "hooks";
const LEGACY_REGISTRY: &str = "hooks.json";

/// Everything the move writes into: the plan's ops behind the one trash
/// guard, the per-file edit collector, and the lines the report carries.
pub(super) struct Sink<'a> {
    pub(super) ops: &'a mut Vec<PlannedOp>,
    pub(super) guard: &'a mut TrashGuard,
    pub(super) config_edits: &'a mut ConfigEditPlan,
    pub(super) notes: &'a mut Vec<String>,
}

/// What sits at a path kendex might take. `Absent` is proven absence —
/// "I could not look" is `Unreadable`, and never licenses a retirement.
enum Found {
    Absent,
    Plain(PathBuf),
    Linked(PathBuf),
    Unreadable(PathBuf, String),
}

/// Why a file kendex's lock names is still not kendex's to move.
enum Held {
    Edited,
    Unprovable,
    Unreadable(String),
}

pub(super) fn plan_move(
    env: &Env,
    scope: &Scope,
    manifest: &crate::manifest::Manifest,
    lock: &Lock,
    state: &DesiredState,
    pre: &Preflight,
    sink: &mut Sink,
) -> Result<()> {
    let root = pi::scope_root(env, scope);
    let dir = root.join(LEGACY_DIR);
    let registry = root.join(LEGACY_REGISTRY);
    // The move retires itself: with neither reserved path there, there is
    // nothing to take and nothing to say — the same answer everything
    // below reaches, reached without stat-ing both names of every hook
    // the lock holds, on this plan and every later one.
    if matches!(look(&dir), Found::Absent) && matches!(look(&registry), Found::Absent) {
        return Ok(());
    }
    // A lock entry is the only claim kendex has here: what it may take is
    // derived from these and nothing else, so a `hooks/` beside this root
    // that none of them names stays whole, and so does a `hooks.json`
    // holding nobody's entries but its own.
    let entries: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    // A link or an unreadable directory is never traversed: `dir.join(..)`
    // resolves through a link, so scanning one would put paths outside the
    // managed scope into the plan. A scope root this process cannot stat
    // through fails earlier, in the registration read, so the unreadable
    // arm is the safe default rather than a state a plan reaches.
    match look(&dir) {
        Found::Linked(path) => {
            sink.notes.push(format!(
                "{} is a link kendex did not create, so nothing under it was touched — move it yourself and pi stops warning",
                path.display()
            ));
            return Ok(());
        }
        // A scope root nothing else touched this pass — no pi hook
        // desired, so no registration to read — reaches this with an
        // ordinary permission failure. Held back, like every other thing
        // this module cannot look at.
        Found::Unreadable(path, error) => {
            sink.notes.push(unreadable_note(&path, &error));
            return Ok(());
        }
        Found::Absent | Found::Plain(_) => {}
    }

    // One line for the whole scope: a registry that cannot give up an
    // entry stops every retirement here, because a script whose
    // registration has to stay would leave that registration naming a
    // path with nothing at it.
    if let Some(block) = &pre.registry_block
        && !entries.is_empty()
    {
        sink.notes.push(block.clone());
    }

    let mut ours: BTreeSet<OsString> = BTreeSet::new();
    let mut take: Vec<(PathBuf, String)> = Vec::new();
    let mut deregister: Vec<(Option<String>, String)> = Vec::new();
    for entry in entries.iter().copied() {
        let found = legacy_files(&dir, &entry.name);
        // A hook whose bytes already sit at the new path has finished
        // moving, so anything wearing its name under the reserved one
        // that kendex cannot claim is a stranger's — never a copy of
        // this installation, and never a reason to re-open the move.
        let claimable = |path: &Path| {
            !pre.moved_on(&entry.name) || claim(entry, path, pre.discards(&entry.name)).is_ok()
        };
        let found: Vec<&Found> = found
            .iter()
            .filter(|found| path_of(found).is_none_or(|path| claimable(path)))
            .collect();
        for path in found.iter().copied().filter_map(path_of) {
            if let Some(name) = path.file_name() {
                ours.insert(name.to_owned());
            }
        }
        // Absence has to be proven before anything is retired: a path
        // kendex could not even stat may still hold a running hook.
        if let Some((path, error)) = found.iter().copied().find_map(unreadable_of) {
            sink.notes.push(unreadable_note(path, error));
            continue;
        }
        let (mine, holds) = claims(entry, &found, &root, pre, sink);
        if holds || pre.registry_block.is_some() {
            continue;
        }
        match retirable(
            env,
            scope,
            entry,
            manifest,
            state,
            sink.ops,
            sink.config_edits,
        ) {
            Retire::Wait => {
                sink.notes.push(format!(
                    "the pi hook {} is declared but its replacement was not written at {} this pass, so its copy under the name pi reserved stays until it is",
                    entry.name,
                    pi::hook_dir(&root).display()
                ));
                continue;
            }
            // The one line that says a hook stopped running this pass.
            // A refresh keeps an orphan's record and its drift row, so
            // without this nobody is told the hook itself went quiet.
            Retire::Unwanted => sink.notes.push(format!(
                "nothing asks for the pi hook {} any more, so its copy under the name pi reserved was taken — it stops running now",
                entry.name
            )),
            Retire::Replaced => {}
        }
        take.extend(mine);
        deregister.push(legacy_registration(entry, scope, &root));
    }

    plan_directory(&dir, &ours, &take, !entries.is_empty(), sink);
    plan_registry(&registry, &deregister, sink)
}

/// A trash op through the plan's one guard, bound to the bytes ownership
/// was proven against — not to whatever is there by the time the op is
/// built. `hash_tree` of a directory covers every child, so the same
/// hash binds membership: a file added to the reserved directory, or an
/// entry added to the registry, between the proof and the apply fails
/// the precondition instead of riding along in the deletion.
///
/// Nothing else in the plan derives a legacy path, so the guard has no
/// overlap to catch today — it is the boundary every Trash op in a plan
/// passes, kept so a future pass that does overlap cannot slip past it.
fn trash(description: String, path: &Path, proven: &str, sink: &mut Sink) {
    sink.guard.extend(
        sink.ops,
        [PlannedOp {
            description,
            op: crate::apply::Op::Trash {
                path: path.to_path_buf(),
                pre: crate::apply::Pre::HashIs {
                    hash: proven.to_owned(),
                },
            },
        }],
    );
}

/// What is at a path, without following a link: `is_file` and `hash_tree`
/// both resolve links, and a link is never one of kendex's own writes.
fn look(path: &Path) -> Found {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => Found::Linked(path.to_path_buf()),
        Ok(_) => Found::Plain(path.to_path_buf()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Found::Absent,
        Err(error) => Found::Unreadable(path.to_path_buf(), error.to_string()),
    }
}

fn path_of(found: &Found) -> Option<&PathBuf> {
    match found {
        Found::Plain(path) | Found::Linked(path) => Some(path),
        Found::Absent | Found::Unreadable(..) => None,
    }
}

fn unreadable_of(found: &Found) -> Option<(&PathBuf, &String)> {
    match found {
        Found::Unreadable(path, error) => Some((path, error)),
        _ => None,
    }
}

/// Both names one hook's bytes can sit under. kendex writes one or the
/// other, but an interrupted toggle can leave the pair; both are claimed
/// and each stands on its own bytes, so the order here carries no meaning
/// and a name the lock accounts for is never reported as a stranger's.
fn legacy_files(dir: &Path, name: &str) -> Vec<Found> {
    let enabled = dir.join(pi::hook_file(name));
    [disabled_name(&enabled), enabled]
        .into_iter()
        .map(|path| look(&path))
        .filter(|found| !matches!(found, Found::Absent))
        .collect()
}

/// Whether the bytes at `path` are the ones apply last wrote there — a
/// record from before `rendered_hash` existed proves nothing, exactly as
/// `removal::edit_holds` reads the same evidence. The hash that proved it
/// comes back out, so the deletion binds to the state ownership was read
/// from rather than to a later one.
fn provenance(entry: &LockEntry, path: &Path) -> std::result::Result<String, Held> {
    let Some(rendered) = entry.rendered_hash.as_ref() else {
        return Err(Held::Unprovable);
    };
    match crate::hash::hash_tree(path) {
        Err(error) => Err(Held::Unreadable(error.to_string())),
        Ok(disk) if &disk == rendered => Ok(disk),
        Ok(_) => Err(Held::Edited),
    }
}

/// What of one hook's copies this pass may take, and whether any of them
/// is not its to take. That question comes before whether anything is
/// coming to replace them: a file that is not kendex's to move keeps its
/// registration too, or holding it back would leave it on disk with
/// nothing running it — the same installation held whole, said per file.
fn claims(
    entry: &LockEntry,
    found: &[&Found],
    root: &Path,
    pre: &Preflight,
    sink: &mut Sink,
) -> (Vec<(PathBuf, String)>, bool) {
    let mut mine = Vec::new();
    let mut holds = false;
    for found in found {
        match found {
            Found::Linked(path) => {
                holds = true;
                sink.notes.push(format!(
                    "{} is a link kendex did not create, so it stayed in the directory pi reserved — move it yourself and pi stops warning",
                    path.display()
                ));
            }
            Found::Plain(path) => match claim(entry, path, pre.discards(&entry.name)) {
                Ok(proven) => mine.push((path.clone(), proven)),
                Err(held) => {
                    holds = true;
                    sink.notes.push(held_note(&held, path, root));
                }
            },
            Found::Absent | Found::Unreadable(..) => {}
        }
    }
    (mine, holds)
}

/// What this pass may take of one file: bytes it can prove it wrote, or
/// bytes the person told it to be rid of — a discard settles a difference
/// it can see, never a file it cannot read at all. The hash that answered
/// comes back out, so the deletion binds to what was read.
fn claim(entry: &LockEntry, path: &Path, discard: bool) -> std::result::Result<String, Held> {
    match provenance(entry, path) {
        Ok(proven) => Ok(proven),
        Err(Held::Edited | Held::Unprovable) if discard => {
            crate::hash::hash_tree(path).map_err(|error| Held::Unreadable(error.to_string()))
        }
        Err(held) => Err(held),
    }
}

/// Why one file stayed under the reserved name, said in its own cause —
/// a file kendex could not read is never reported as one somebody edited.
/// The destination is derived from the file's own name, so the twin a
/// disabled hook keeps its bytes under is not sent to the enabled one.
fn held_note(held: &Held, path: &Path, root: &Path) -> String {
    let new = match path.file_name() {
        Some(file) => pi::hook_dir(root).join(file),
        None => pi::hook_dir(root),
    };
    match held {
        Held::Unreadable(error) => unreadable_note(path, error),
        Held::Unprovable => format!(
            "{} predates the record kendex keeps of what it writes, so it stayed in the directory pi reserved — compare it with {} and delete the old file once you are happy",
            path.display(),
            new.display()
        ),
        Held::Edited => format!(
            "{} was edited on disk, so it stayed in the directory pi reserved — copy your changes into {} and delete the old file",
            path.display(),
            new.display()
        ),
    }
}

fn unreadable_note(path: &Path, error: &str) -> String {
    format!(
        "kendex could not read {} ({error}), so it stayed in the directory pi reserved — fix its permissions or move it aside, then refresh again",
        path.display()
    )
}
