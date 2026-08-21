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

pub(super) mod claims;
mod disposal;
mod identity;
mod migrated;
mod preflight;
mod record;
mod registry;
mod retire;

use claims::{claim, claims, provenance};
use disposal::{plan_directory, plan_registry};
use identity::{Identity, Registered, legacy_registration, registered};
pub(crate) use preflight::{Preflight, preflight};
use record::{every_pi_hook, newly_installed, record_finished};
use retire::{Retire, retirable};

/// The directory name Pi reserved. The registry an earlier kendex wrote
/// beside it is `pi::legacy_hook_registry`, which the observation surface
/// reads too.
const LEGACY_DIR: &str = "hooks";

/// Everything the move writes into: the plan's ops behind the one trash
/// guard, the per-file edit collector, and the lines the report carries.
pub(super) struct Sink<'a> {
    pub(super) ops: &'a mut Vec<PlannedOp>,
    pub(super) guard: &'a mut TrashGuard,
    pub(super) config_edits: &'a mut ConfigEditPlan,
    pub(super) notes: &'a mut Vec<String>,
    /// The record this plan writes, where a finished move is written
    /// down.
    pub(super) new_lock: &'a mut Lock,
}

/// What sits at a path kendex might take. `Absent` is proven absence —
/// "I could not look" is `Unreadable`, and never licenses a retirement.
enum Found {
    Absent,
    Plain(PathBuf),
    Linked(PathBuf),
    Unreadable(PathBuf, String),
}

/// Whether the registry an older kendex wrote under the name pi reserved
/// still runs a hook of kendex's in this scope — asked by the Pi
/// observation surface, which reads that registry while the answer is yes.
/// A hook the move is holding back runs from there and from nowhere else,
/// so a surface list that named only the new path would leave the one
/// installation needing attention out of every list and every scan.
///
/// A scope whose lock this build cannot read claims nothing under the
/// reserved name — the same evidence the move itself takes ownership by,
/// and the reading that keeps the legacy path from becoming a second home
/// for pi hooks in scopes kendex never installed one in.
pub(crate) fn legacy_registry_lives(env: &Env, scope: &Scope) -> bool {
    let Ok(crate::lock::LockFile::Current(lock)) =
        crate::lock::load_file(&crate::lock::lock_path(env, scope))
    else {
        return false;
    };
    // Nothing is being rendered here, so a hook's identity is what the
    // record kept and no more — the reading every pass took before one
    // was rendered to compare with.
    preflight(
        env,
        scope,
        &lock,
        &crate::engine::PlanOptions::default(),
        &crate::engine::desired::DesiredState::default(),
    )
    .legacy_registry_lives()
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
    let registry = pi::legacy_hook_registry(&root);
    // A lock entry is the only claim kendex has here: what it may take is
    // derived from these and nothing else, so a `hooks/` beside this root
    // that none of them names stays whole, and so does a `hooks.json`
    // holding nobody's entries but its own.
    let entries: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    // A hook this pass installs for the first time never had anything
    // under the reserved name, so its move is over before it starts.
    // Whatever else is in that directory is somebody else's and says
    // nothing about this one's history — waiting for a pass that finds
    // the directory empty would leave a fresh install reading its own
    // completion off the disk, and a script the person writes at the old
    // name meanwhile would meet that reading instead of this record.
    record_finished(newly_installed(&entries, state), sink);
    // The move retires itself: with neither reserved path there, there is
    // nothing to take and nothing to say — the same answer everything
    // below reaches, reached without stat-ing both names of every hook
    // the lock holds, on this plan and every later one.
    //
    // It is also the plainest reading of a finished move there is —
    // nothing of anybody's is under the reserved name — so it is the
    // reading that gets written down. That covers the two shapes the
    // pass below never sees: an installation this kendex wrote fresh at
    // the new path, and one that moved before there was a record to
    // keep.
    if matches!(look(&dir), Found::Absent) && matches!(look(&registry), Found::Absent) {
        record_finished(every_pi_hook(&entries, state), sink);
        return Ok(());
    }
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
    if let Some(block) = &pre.registry_block {
        sink.notes.push(block.clone());
    }

    let mut ours: BTreeSet<OsString> = BTreeSet::new();
    let mut take: Vec<(PathBuf, String)> = Vec::new();
    let mut deregister: Vec<Identity> = Vec::new();
    let mut finished: BTreeSet<String> = BTreeSet::new();
    for entry in entries.iter().copied() {
        // An installation on record as having left the reserved name is
        // done with it. Whatever wears its name there now — a file, a
        // registration, even a copy spelled byte for byte the way kendex
        // spelled it — is somebody else's, and the question of whose is
        // not asked at all. Asking it is what re-opened finished moves.
        if pre.left_for_good(&entry.name) {
            continue;
        }
        // One line about this hook's own entry, where there is one to
        // say: for a command-bodied hook, which has no file under the
        // reserved name at all, it is the only line there is.
        if let Some(why) = pre.conflict(&entry.name) {
            sink.notes.push(why.clone());
        }
        let found = legacy_files(&dir, &entry.name);
        // Where there is no record — an installation that finished
        // before there was one to write — the reading takes its place,
        // and it is only ever as good as the bytes: a copy this pass can
        // prove it wrote is still its own to take, and one it cannot is
        // a stranger's.
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
        // One gate for both halves of the pass: what the preflight is
        // holding whole keeps everything it has, this pass writes nothing
        // for it and retires nothing of its. The per-file reading is
        // asked as well because it is where the lines about each file
        // come from.
        if holds || pre.hold(&entry.name).is_some() {
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
        // The registration half of the same reading: with nothing of
        // theirs left to claim, the entry beside it is theirs too,
        // however exactly it spells the command kendex used.
        if !pre.moved_on(&entry.name) || !mine.is_empty() {
            deregister.push(legacy_registration(entry, scope, &root));
        }
        take.extend(mine);
        // Everything this hook had under the reserved name is on its way
        // off disk. Said out loud in the lock, so no later pass has to
        // work it out again from bytes that have every right to change.
        finished.insert(entry.name.clone());
    }

    // Only what the plan really takes is called finished: a listing it
    // could not read or a registry it could not edit leaves remains under
    // the reserved name, and recording a move that did not happen would
    // abandon them there.
    let cleared = plan_directory(&dir, &ours, &take, !entries.is_empty(), sink);
    if cleared && plan_registry(&registry, &deregister, sink)? {
        record_finished(finished, sink);
    }
    Ok(())
}

/// A trash op through the plan's one guard, bound to the bytes ownership
/// was proven against — not to whatever is there by the time the op is
/// built. `hash_tree` of a directory covers every child, so the same
/// hash binds membership: a file added to the reserved directory, or an
/// entry added to the registry, between the proof and the apply fails
/// the precondition instead of riding along in the deletion.
///
/// The type is bound with the bytes. Ownership here is proven of a plain
/// file or a plain directory — never a link — so a link that arrives in
/// its place before the apply must fail the op rather than satisfy it by
/// resolving to the same bytes.
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
                pre: crate::apply::Pre::PlainHashIs {
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

/// Whether a path holds bytes kendex could have written there: a regular
/// file, never a link and never a directory somebody left in its place.
/// The one spelling every gate that authorizes a deletion asks through,
/// so no two of them can disagree about what a discard covers.
fn plain_file(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_file())
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

fn unreadable_note(path: &Path, error: &str) -> String {
    format!(
        "kendex could not read {} ({error}), so it stayed in the directory pi reserved — fix its permissions or move it aside, then refresh again",
        path.display()
    )
}
