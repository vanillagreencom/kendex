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
    take: &[PathBuf],
    claimed: bool,
    sink: &mut Sink,
) {
    if !matches!(look(dir), Found::Plain(_)) {
        return;
    }
    let strangers = match strangers(dir, ours) {
        Ok(strangers) => strangers,
        Err(error) => {
            sink.notes.push(format!(
                "kendex could not list {} ({error}), so everything in the directory pi reserved stayed — fix its permissions, then refresh again",
                dir.display()
            ));
            return;
        }
    };
    if !strangers.is_empty() {
        for path in take {
            trash(
                format!("Move pi hooks out of {}", dir.display()),
                path,
                sink,
            );
        }
        if !take.is_empty() {
            sink.notes.push(format!(
                "{} also holds files kendex did not write ({}) — pi keeps warning about the directory until they are moved or removed by hand",
                dir.display(),
                strangers.join(", ")
            ));
        }
        return;
    }
    // Nothing here is anybody else's. The whole directory goes when this
    // pass takes everything the lock names in it — and when it names
    // nothing and the directory is empty, which is what a finished move
    // leaves behind and pi still warns about. An empty directory holds
    // nothing anyone could lose.
    if (!take.is_empty() && take.len() == ours.len()) || (claimed && ours.is_empty()) {
        trash(format!("Move pi hooks out of {}", dir.display()), dir, sink);
        return;
    }
    for path in take {
        trash(
            format!("Move pi hooks out of {}", dir.display()),
            path,
            sink,
        );
    }
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
