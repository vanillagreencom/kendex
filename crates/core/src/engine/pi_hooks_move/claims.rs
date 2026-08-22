//! Which of one hook's copies under the reserved name this pass may
//! take, and why one of them is not its to take.
//!
//! Both gates a deletion passes ask the same question in the same words:
//! `provenance` here, which the move goes through, and the preflight's
//! `discardable`, which decides whether a hold is released. Neither is
//! satisfied by anything but a plain file, so they cannot disagree about
//! what a discard covers.

use std::path::{Path, PathBuf};

use crate::harness::pi;
use crate::lock::LockEntry;

use super::{Found, Preflight, Sink, plain_file, unreadable_note};

/// Why a file kendex's lock names is still not kendex's to move.
pub(super) enum Held {
    Edited,
    Unprovable,
    Unreadable(String),
    /// Something that is not a file at all sits where the script does.
    NotAFile,
}

/// Whether the bytes at `path` are the ones apply last wrote there — a
/// record from before `rendered_hash` existed proves nothing, exactly as
/// `removal::edit_holds` reads the same evidence. The hash that proved it
/// comes back out, so the deletion binds to the state ownership was read
/// from rather than to a later one.
pub(super) fn provenance(entry: &LockEntry, path: &Path) -> std::result::Result<String, Held> {
    // Asked before the hash, because `hash_tree` answers for a directory
    // too: a tree somebody put where the script was would otherwise read
    // as an edit, and an edit is something a discard may take.
    if !plain_file(path) {
        return Err(Held::NotAFile);
    }
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
pub(super) fn claims(
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
                    "{} is a link kendex did not create, so it stays in the directory pi reserved — move it yourself and pi stops warning",
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
pub(super) fn claim(
    entry: &LockEntry,
    path: &Path,
    discard: bool,
) -> std::result::Result<String, Held> {
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
        Held::NotAFile => format!(
            "{} is not a plain file, so it is nothing kendex wrote there and it stays in the directory pi reserved — move it aside yourself, then refresh again",
            path.display()
        ),
        Held::Unprovable => format!(
            "{} predates the record kendex keeps of what it writes, so it stays in the directory pi reserved — compare it with {} and delete the old file once you are happy",
            path.display(),
            new.display()
        ),
        Held::Edited => format!(
            "{} was edited on disk, so it stays in the directory pi reserved — copy your changes into {} and delete the old file",
            path.display(),
            new.display()
        ),
    }
}
