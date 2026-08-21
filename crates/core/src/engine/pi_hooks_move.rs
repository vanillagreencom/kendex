//! What an older kendex left in the directory name Pi has since reserved.
//!
//! Pi prints a migration warning for any `hooks/` sitting directly beside
//! a root it loads. The check is existence only — it never looks inside —
//! and the migration it names, into `extensions/`, is one kendex hooks
//! cannot take: they are shell scripts the `pi-hooks` carrier runs, not Pi
//! extensions. The storage moved under a segment kendex owns
//! (`crate::harness::pi::HOOK_HOME`); the copies an earlier kendex wrote
//! come off disk here, and the directory goes with them — emptying it
//! leaves the warning exactly where it was.
//!
//! Nothing moves on the strength of a path alone. Every file taken is one
//! the lock names and whose bytes hash to what apply last wrote there, and
//! every registry entry taken is one this scope's lock accounts for. A
//! stranger's file, a link kendex did not make, bytes it cannot prove or
//! cannot read, and a hook whose replacement this plan did not write all
//! stay exactly where they are, each with a line saying why.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::error::Result;
use crate::harness::pi;
use crate::lock::{Lock, LockEntry};
use crate::model::{HarnessId, ItemKind, Scope};

use super::config_edits::ConfigEditPlan;
use super::removal::{self, TrashGuard};
use super::targets::disabled_name;

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

/// What the legacy copy of one hook turned out to be.
enum Found {
    None,
    Plain(PathBuf),
    Linked(PathBuf),
}

/// Whether the bytes under the reserved name are ones kendex can prove it
/// wrote — the only ones it may take.
enum Bytes {
    Ours,
    Edited,
    Unprovable,
    Unreadable(String),
}

pub(super) fn plan_move(env: &Env, scope: &Scope, lock: &Lock, sink: &mut Sink) -> Result<()> {
    let root = pi::scope_root(env, scope);
    let dir = root.join(LEGACY_DIR);
    let registry = root.join(LEGACY_REGISTRY);
    // The move retires itself: with neither reserved path there, there is
    // nothing to take and nothing to say, on this plan or any later one.
    if !present(&dir) && !present(&registry) {
        return Ok(());
    }
    // A lock entry is the only claim kendex has on anything here: what it
    // may take is derived from these and nothing else, so a `hooks/`
    // beside this root that none of them names stays whole, and so does a
    // `hooks.json` holding nobody's entries but its own.
    let entries: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Hook && entry.harness == HarnessId::Pi)
        .collect();
    // Nothing to retire in the registry is its own kind of ready: a hook
    // installed disabled registered nothing, so there is no legacy entry
    // waiting on a replacement.
    let registry_ready = !present(&registry) || replacement_registry_ready(&root, sink);

    // What the lock accounts for under the reserved name, and the subset
    // this plan may take: an edited or unreadable copy is one of ours and
    // is not a stranger, but it is not ours to move either.
    let mut ours: BTreeSet<OsString> = BTreeSet::new();
    let mut take: Vec<PathBuf> = Vec::new();
    let mut deregister: Vec<(Option<String>, String)> = Vec::new();
    for entry in entries {
        let found = legacy_script(&dir, &entry.name);
        if let Found::Plain(path) | Found::Linked(path) = &found
            && let Some(name) = path.file_name()
        {
            ours.insert(name.to_owned());
        }
        // Retiring a working hook before its replacement exists would
        // disable it: a declaration whose source could not be resolved
        // this pass keeps its lock entry and plans no write, and the old
        // copy is all that is running.
        let script_ready = match &found {
            Found::None => true,
            _ => replacement_script_ready(&root, &entry.name, sink.ops),
        };
        if !(registry_ready && script_ready) {
            sink.notes.push(format!(
                "the pi hook {} was not written at {} this pass, so its copy under the name pi reserved stays until it is",
                entry.name,
                pi::hook_dir(&root).display()
            ));
            continue;
        }
        match found {
            Found::Linked(path) => {
                sink.notes.push(format!(
                    "{} is a link kendex did not create, so it stayed in the directory pi reserved — move it yourself and pi stops warning",
                    path.display()
                ));
                continue;
            }
            Found::Plain(path) => match provenance(entry, &path) {
                Bytes::Ours => take.push(path),
                other => {
                    sink.notes
                        .push(held_note(&other, &path, &root, &entry.name));
                    continue;
                }
            },
            Found::None => {}
        }
        deregister.push(legacy_registration(entry, scope, &root));
    }

    plan_directory(&dir, &ours, &take, sink);
    plan_registry(&registry, &deregister, sink)
}

/// The reserved directory, once every file's fate is known: taken whole
/// when everything in it is kendex's to take, file by file otherwise —
/// and never touched at all when this plan takes nothing out of it.
fn plan_directory(dir: &Path, ours: &BTreeSet<OsString>, take: &[PathBuf], sink: &mut Sink) {
    if take.is_empty() {
        return;
    }
    if std::fs::symlink_metadata(dir).is_ok_and(|meta| meta.file_type().is_symlink()) {
        sink.notes.push(format!(
            "{} is a link kendex did not create, so nothing under it was touched — move it yourself and pi stops warning",
            dir.display()
        ));
        return;
    }
    let strangers = match strangers(dir, ours) {
        Ok(strangers) => strangers,
        Err(error) => {
            sink.notes.push(format!(
                "{} could not be read ({error}), so it stayed as it is",
                dir.display()
            ));
            return;
        }
    };
    let all_ours = ours.len() == take.len();
    if strangers.is_empty() && all_ours {
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
    if !strangers.is_empty() {
        sink.notes.push(format!(
            "{} also holds files kendex did not write ({}) — pi keeps warning about the directory until they are moved or removed by hand",
            dir.display(),
            strangers.join(", ")
        ));
    }
}

/// The legacy registry: only the entries this scope's lock accounts for
/// come out. The file goes to the trash when that leaves nothing at all —
/// a registry still holding somebody's own hook is edited, never taken.
fn plan_registry(
    registry: &Path,
    deregister: &[(Option<String>, String)],
    sink: &mut Sink,
) -> Result<()> {
    if deregister.is_empty() {
        return Ok(());
    }
    if !present(registry) {
        return Ok(());
    }
    if std::fs::symlink_metadata(registry).is_ok_and(|meta| meta.file_type().is_symlink()) {
        sink.notes.push(format!(
            "{} is a link kendex did not create, so it was left alone",
            registry.display()
        ));
        return Ok(());
    }
    let current = crate::fs::read_if_exists(registry)?.unwrap_or_default();
    let edits: Vec<ConfigEdit> = deregister
        .iter()
        .map(|(event, command)| ConfigEdit::RemoveHook {
            event: event.clone(),
            command: command.clone(),
        })
        .collect();
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
    let parsed = |text: &str| match text.trim().is_empty() {
        true => Ok(serde_json::Value::Object(serde_json::Map::new())),
        false => serde_json::from_str::<serde_json::Value>(text),
    };
    let (Ok(before), Ok(after)) = (parsed(&current), parsed(&updated)) else {
        return Ok(());
    };
    if before == after {
        return Ok(());
    }
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

/// A trash op through the plan's one guard. A path that cannot be hashed
/// is one this plan leaves alone: the whole audit must not fail over a
/// legacy file somebody removed while it ran.
fn trash(description: String, path: &Path, sink: &mut Sink) {
    match removal::trash(description, path.to_path_buf()) {
        Ok(op) => sink.guard.extend(sink.ops, [op]),
        Err(error) => sink.notes.push(format!(
            "{} could not be read ({error}), so it stayed as it is",
            path.display()
        )),
    }
}

/// The legacy copy of one hook: the enabled name, or the disabled one it
/// keeps its bytes under. Read through symlink metadata — `is_file` and
/// `hash_tree` both follow links, and a link is never kendex's own write.
fn legacy_script(dir: &Path, name: &str) -> Found {
    let enabled = dir.join(pi::hook_file(name));
    for path in [disabled_name(&enabled), enabled.clone()] {
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            return Found::Linked(path);
        }
        if meta.is_file() {
            return Found::Plain(path);
        }
    }
    Found::None
}

/// Whether the bytes at `path` are the ones apply last wrote there. A
/// record from before `rendered_hash` existed proves nothing, exactly as
/// `removal::edit_holds` reads the same evidence.
fn provenance(entry: &LockEntry, path: &Path) -> Bytes {
    let Some(rendered) = &entry.rendered_hash else {
        return Bytes::Unprovable;
    };
    match crate::hash::hash_tree(path) {
        Err(error) => Bytes::Unreadable(error.to_string()),
        Ok(disk) if &disk == rendered => Bytes::Ours,
        Ok(_) => Bytes::Edited,
    }
}

/// Why one file stayed under the reserved name, said in its own cause —
/// a file kendex could not read is never reported as one somebody edited.
fn held_note(bytes: &Bytes, path: &Path, root: &Path, name: &str) -> String {
    let new = pi::hook_path(root, name);
    match bytes {
        Bytes::Unreadable(error) => format!(
            "kendex could not read {} ({error}), so it stayed in the directory pi reserved — fix its permissions or move it aside, then refresh again",
            path.display()
        ),
        Bytes::Unprovable => format!(
            "{} predates the record kendex keeps of what it writes, so it stayed in the directory pi reserved — compare it with {} and delete the old file once you are happy",
            path.display(),
            new.display()
        ),
        Bytes::Ours | Bytes::Edited => format!(
            "{} was edited on disk, so it stayed in the directory pi reserved — copy your changes into {} and delete the old file",
            path.display(),
            new.display()
        ),
    }
}

/// The registry entry one hook left behind: a custom hook registered the
/// person's own command and the lock recorded it verbatim, a script-bodied
/// one registered the command the old layout spelled.
fn legacy_registration(entry: &LockEntry, scope: &Scope, root: &Path) -> (Option<String>, String) {
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

/// Whether this hook's replacement is already on disk or lands in this
/// same plan — the only states in which retiring the old copy leaves the
/// hook running.
fn replacement_script_ready(root: &Path, name: &str, ops: &[PlannedOp]) -> bool {
    let path = pi::hook_path(root, name);
    [disabled_name(&path), path].iter().any(|path| {
        path.is_file()
            || ops.iter().any(|planned| match &planned.op {
                Op::WriteFile { path: written, .. } => written == path,
                Op::Rename { to, .. } => to == path,
                _ => false,
            })
    })
}

/// The same question for the registry the carrier reads.
fn replacement_registry_ready(root: &Path, sink: &Sink) -> bool {
    let path = pi::hook_registry(root);
    path.is_file() || sink.config_edits.by_file.contains_key(&path)
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

/// Whether anything at all sits at this path, a link included — what Pi's
/// own `existsSync` check answers.
fn present(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}
