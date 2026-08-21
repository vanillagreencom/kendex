//! Retiring what the move decided it may take: the reserved directory
//! itself, and the entries kendex left in the registry beside it.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::configedit::ConfigEdit;
use crate::error::Result;
use crate::harness::pi;
use crate::lock::LockEntry;
use crate::model::Scope;

use super::{Found, LEGACY_DIR, Sink, look, trash, unreadable_note};

/// The reserved directory, once every file's fate is known: taken whole
/// when everything in it is kendex's to take, file by file when something
/// stays, and taken empty when a finished move left the shell behind.
pub(super) fn plan_directory(
    dir: &Path,
    ours: &BTreeSet<OsString>,
    take: &[(PathBuf, String)],
    claimed: bool,
    sink: &mut Sink,
) {
    if !matches!(look(dir), Found::Plain(_)) {
        return;
    }
    let strangers = match strangers(dir, ours) {
        Ok(strangers) => strangers,
        Err(error) => {
            sink.notes.push(list_note(dir, &error.to_string()));
            return;
        }
    };
    let each = |sink: &mut Sink| {
        for (path, proven) in take {
            trash(
                format!("Move pi hooks out of {}", dir.display()),
                path,
                proven,
                sink,
            );
        }
    };
    if !strangers.is_empty() {
        each(sink);
        // Said whenever kendex still has something under the reserved
        // name — whether this pass moved it or is holding it — because
        // either way the directory, and pi's warning with it, outlive
        // whatever else the person fixes. Once nothing of kendex's is
        // left there the directory is not its to talk about, so it stops
        // saying anything at all.
        if !ours.is_empty() {
            sink.notes.push(format!(
                "{} also holds files kendex did not write ({}) — pi keeps warning about the directory until they are moved or removed by hand",
                dir.display(),
                strangers.join(", ")
            ));
        }
        return;
    }
    // Nothing here is anybody else's, so the whole directory goes when
    // this pass takes everything the lock names in it.
    if !take.is_empty() && take.len() == ours.len() {
        whole(
            format!("Move pi hooks out of {}", dir.display()),
            dir,
            ours,
            sink,
        );
        return;
    }
    // And when it names nothing and the directory is empty — the shell a
    // finished move leaves behind, which pi still warns about and which
    // holds nothing anyone could lose. Said out loud: a directory this
    // scope's hooks no longer sit in is not one kendex can prove it made.
    if claimed && ours.is_empty() {
        whole(
            format!("Remove the empty {} pi warns about", dir.display()),
            dir,
            ours,
            sink,
        );
        sink.notes.push(format!(
            "{} was empty and pi warns about the name, so it was removed — nothing was in it",
            dir.display()
        ));
        return;
    }
    each(sink);
}

/// The whole directory, bound to a hash of everything in it.
///
/// Two properties at once. The hash is taken only after the listing has
/// shown every child is a plain file this pass claims — a link among them
/// is a stranger, and a stranger means the directory is taken file by
/// file instead — so hashing never follows a link out of the directory
/// kendex owns. And the listing is taken again afterwards and has to be
/// unchanged: that, not the order of two reads, is what makes the proof
/// and the binding describe one state. A file arriving at any point
/// either shows up in a listing or changes the hash the apply checks.
fn whole(description: String, dir: &Path, ours: &BTreeSet<OsString>, sink: &mut Sink) {
    // Checked here rather than inferred from the caller: `hash_tree`
    // resolves links, so one child link would walk a tree kendex does not
    // own. The caller only asks about a directory whose every child it
    // claims, and a claimed child is always a plain file — this makes
    // that a check instead of an argument.
    if !every_child_is_a_plain_file(dir) {
        return;
    }
    let proven = match crate::hash::hash_tree(dir) {
        Ok(proven) => proven,
        Err(error) => {
            sink.notes.push(list_note(dir, &error.to_string()));
            return;
        }
    };
    match strangers(dir, ours) {
        // Something arrived while kendex was looking. Nothing is taken
        // this pass; the next one sees it as the stranger it is.
        Ok(again) if !again.is_empty() => {}
        Ok(_) => trash(description, dir, &proven, sink),
        Err(error) => sink.notes.push(list_note(dir, &error.to_string())),
    }
}

/// Whether nothing in this directory is a link, a subdirectory, or
/// anything else that reading it would follow out of the directory.
fn every_child_is_a_plain_file(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().all(|entry| {
        std::fs::symlink_metadata(entry.path()).is_ok_and(|meta| meta.file_type().is_file())
    })
}

fn list_note(dir: &Path, error: &str) -> String {
    format!(
        "kendex could not list {} ({error}), so everything in the directory pi reserved stayed — fix its permissions, then refresh again",
        dir.display()
    )
}

/// The legacy registry: only the entries this scope's lock accounts for
/// come out, and only when one of them is really in the file — a document
/// kendex removed nothing from is never rewritten and never taken, however
/// empty the shape it happens to be in.
pub(super) fn plan_registry(
    registry: &Path,
    deregister: &[(Option<String>, String)],
    sink: &mut Sink,
) -> Result<()> {
    if !matches!(look(registry), Found::Plain(_)) {
        return Ok(());
    }
    let current = match crate::fs::read_if_exists(registry) {
        Ok(text) => text.unwrap_or_default(),
        Err(error) => {
            sink.notes
                .push(unreadable_note(registry, &error.to_string()));
            return Ok(());
        }
    };
    let registered = match crate::scan::hooks::read(registry) {
        Ok(entries) => entries,
        Err(message) => {
            sink.notes.push(format!(
                "{} could not be read ({message}), so it was left alone",
                registry.display()
            ));
            return Ok(());
        }
    };
    let edits: Vec<ConfigEdit> = deregister
        .iter()
        .filter(|(_, command)| {
            registered
                .iter()
                .any(|entry| entry.description.as_deref() == Some(command.as_str()))
        })
        .map(|(event, command)| ConfigEdit::RemoveHook {
            event: event.clone(),
            command: command.clone(),
        })
        .collect();
    if edits.is_empty() {
        return Ok(());
    }
    let mut updated = current.clone();
    for edit in &edits {
        updated = match edit.apply(&updated) {
            Ok(text) => text,
            Err(message) => {
                sink.notes.push(format!(
                    "{} could not be edited ({message}), so it was left alone",
                    registry.display()
                ));
                return Ok(());
            }
        };
    }
    // Compared as JSON, not as text: a file kendex has nothing to remove
    // from must not be rewritten into kendex's own formatting.
    let after = match serde_json::from_str::<serde_json::Value>(&updated) {
        Ok(value) => value,
        // The text came out of `apply`, which serialized it from a value
        // it had just parsed, so this cannot happen — asserted rather than
        // trusted, and still non-fatal in a release build.
        Err(error) => {
            debug_assert!(
                false,
                "{} did not survive its own edits: {error}",
                registry.display()
            );
            sink.notes.push(format!(
                "{} could not be rewritten ({error}), so it was left alone",
                registry.display()
            ));
            return Ok(());
        }
    };
    if after.as_object().is_some_and(|object| object.is_empty()) {
        trash(
            format!("Move the pi hook registry out of {}", registry.display()),
            registry,
            &crate::hash::hash_bytes(current.as_bytes()),
            sink,
        );
        return Ok(());
    }
    for edit in edits {
        sink.config_edits.push(
            registry.to_path_buf(),
            "retire the pi hooks under the name pi reserved".to_owned(),
            edit,
        );
    }
    Ok(())
}

/// The registry entry one hook left behind: a custom hook registered the
/// person's own command and the lock recorded it verbatim, a script-bodied
/// one registered the command the old layout spelled.
pub(super) fn legacy_registration(
    entry: &LockEntry,
    scope: &Scope,
    root: &Path,
) -> (Option<String>, String) {
    match &entry.registration {
        Some(recorded) => (Some(recorded.event.clone()), recorded.command.clone()),
        None => {
            let file = pi::hook_file(&entry.name);
            let command = match scope {
                Scope::Global => {
                    format!("bash \"{}\"", root.join(LEGACY_DIR).join(&file).display())
                }
                Scope::Project { .. } => {
                    format!("bash \"$(git rev-parse --show-toplevel)/.pi/{LEGACY_DIR}/{file}\"")
                }
            };
            (None, command)
        }
    }
}

/// Everything in the reserved directory the lock does not account for.
fn strangers(dir: &Path, ours: &BTreeSet<OsString>) -> std::io::Result<Vec<String>> {
    let mut strangers: Vec<String> = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let name = entry?.file_name();
        if !ours.contains(&name) {
            strangers.push(name.to_string_lossy().into_owned());
        }
    }
    strangers.sort();
    Ok(strangers)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The guarantee that does not depend on the caller: a directory
    /// holding a link is never hashed, so the tree it points at is never
    /// read — even when everything in it is claimed.
    #[test]
    #[cfg(unix)]
    #[allow(clippy::unwrap_used)]
    fn a_directory_holding_a_link_is_never_hashed() {
        let tmp = tempfile::tempdir().unwrap();
        let outside = tmp.path().join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("deep"), "not kendex's\n").unwrap();
        let dir = tmp.path().join("hooks");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("guard.sh"), "#!/bin/sh\n").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("theirs")).unwrap();
        std::fs::set_permissions(
            &outside,
            std::os::unix::fs::PermissionsExt::from_mode(0o000),
        )
        .unwrap();

        assert!(!every_child_is_a_plain_file(&dir));
        // And the caller's own answer, for a directory of plain files.
        std::fs::remove_file(dir.join("theirs")).unwrap();
        assert!(every_child_is_a_plain_file(&dir));
        std::fs::set_permissions(
            &outside,
            std::os::unix::fs::PermissionsExt::from_mode(0o755),
        )
        .unwrap();
    }
}
