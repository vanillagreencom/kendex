use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::fs::{
    copy_file_durable, copy_tree_durable, make_symlink, remove_any, sync_dir, sync_dir_durable,
};

/// Pre-images of everything an apply is about to touch. Restore is
/// idempotent, so a crash mid-rollback recovers by rolling back again.
#[derive(Debug, Serialize, Deserialize)]
pub struct Journal {
    pub entries: Vec<Entry>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Entry {
    pub path: PathBuf,
    pub state: PreState,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum PreState {
    Absent,
    /// Bytes stored under `store/<index>` in the journal dir.
    File {
        store: String,
    },
    /// The link itself, plus the linked-to file's bytes when it resolves —
    /// a write through the link must be undoable at the target too.
    Symlink {
        target: PathBuf,
        store: Option<String>,
    },
    /// Tree copied under `store/<index>/` in the journal dir.
    Dir {
        store: String,
    },
}

pub fn journal_dir_for(base: &Path, scope_key: &str) -> PathBuf {
    base.join(scope_key)
}

/// Record pre-images for every path, then durably write the journal meta.
/// Only after this returns may the apply mutate anything. Durability order
/// matters: store bytes sync before meta.json exists, so a journal with a
/// readable meta always has intact pre-images, and a missing or torn meta
/// proves no mutation ever started.
pub fn write(dir: &Path, paths: &[PathBuf]) -> Result<()> {
    let store = dir.join("store");
    fs::create_dir_all(&store).map_err(|e| CoreError::io(&store, e))?;
    let mut entries = Vec::new();
    for (index, path) in paths.iter().enumerate() {
        let state = if path.is_symlink() {
            let slot_name = index.to_string();
            let resolved_file = path.exists() && path.is_file();
            if resolved_file {
                copy_file_durable(path, &store.join(&slot_name))?;
            }
            PreState::Symlink {
                target: fs::read_link(path).map_err(|e| CoreError::io(path, e))?,
                store: resolved_file.then_some(slot_name),
            }
        } else if path.is_dir() {
            let slot = store.join(index.to_string());
            copy_tree_durable(path, &slot)?;
            PreState::Dir {
                store: index.to_string(),
            }
        } else if path.is_file() {
            let slot = store.join(index.to_string());
            copy_file_durable(path, &slot)?;
            PreState::File {
                store: index.to_string(),
            }
        } else {
            PreState::Absent
        };
        entries.push(Entry {
            path: path.clone(),
            state,
        });
    }
    sync_dir(&store);
    sync_dir(dir);
    let journal = Journal { entries };
    let meta = serde_json::to_string_pretty(&journal).map_err(|e| CoreError::JsonParse {
        path: dir.join("meta.json"),
        message: e.to_string(),
    })?;
    crate::fs::atomic_write_durable(&dir.join("meta.json"), &meta)?;
    Ok(())
}

/// Crash recovery: restore every pre-image a journal an interrupted apply
/// left behind. Nothing on disk says which ops ran, so all of them go
/// back.
pub fn rollback(dir: &Path) -> Result<()> {
    rollback_where(dir, |_| true)
}

/// Restore only the pre-images of paths this transaction actually mutated:
/// a path in `mutated`, or a journaled directory root above one (the top
/// of a chain the transaction created). In-process rollback knows exactly
/// which ops ran; restoring the rest would put the journal's snapshot over
/// bytes a writer outside the transaction landed after the journal was
/// taken — the precondition that stopped the apply refused to overwrite
/// those bytes, so the rollback must not either.
///
/// One exception the filter does not cover: a journaled directory root
/// the transaction created (`PreState::Absent`, above a mutated path) is
/// removed whole, and anything a writer outside the transaction placed
/// beneath it after the journal was taken goes with it — a first install
/// into a fresh `.codex/` while the Codex CLI writes its config there.
/// The restore does not yet verify a root's post-image before removing
/// it.
pub fn rollback_mutated(dir: &Path, mutated: &[PathBuf]) -> Result<()> {
    rollback_where(dir, |path| {
        mutated.iter().any(|m| m == path || m.starts_with(path))
    })
}

fn rollback_where(dir: &Path, restore: impl Fn(&Path) -> bool) -> Result<()> {
    let meta_path = dir.join("meta.json");
    let Some(text) = crate::fs::read_if_exists(&meta_path)? else {
        // Mutation never started (no meta written): nothing to restore.
        return clear(dir);
    };
    let journal: Journal = match serde_json::from_str(&text) {
        Ok(journal) => journal,
        // A meta that will not parse is a torn one. It is written whole
        // and durably before any mutation starts, so a partial one proves
        // the world untouched and the journal safe to discard. One that
        // parses is acted on, and a failure part-way through the restore
        // returns before the `clear` below, leaving it pending.
        Err(_) => return clear(dir),
    };
    let store = dir.join("store");
    for entry in &journal.entries {
        if !restore(&entry.path) {
            continue;
        }
        remove_any(&entry.path)?;
        match &entry.state {
            PreState::Absent => {}
            PreState::File { store: slot } => {
                if let Some(parent) = entry.path.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                copy_file_durable(&store.join(slot), &entry.path)?;
            }
            PreState::Symlink {
                target,
                store: slot,
            } => {
                if let Some(parent) = entry.path.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                make_symlink(target, &entry.path)?;
                // A write may have gone through the link, so the
                // linked-to file's bytes go back too — through the link,
                // which is back where it was.
                if let Some(slot) = slot {
                    copy_file_durable(&store.join(slot), &entry.path)?;
                }
            }
            PreState::Dir { store: slot } => {
                copy_tree_durable(&store.join(slot), &entry.path)?;
            }
        }
    }
    clear(dir)
}

/// Spend a journal: meta.json first, on its own and made durable, then
/// the sweep.
///
/// meta.json is the whole of what makes a journal pending, and this runs
/// on the success path of every apply. `remove_dir_all` is neither atomic
/// nor ordered, and it can simply fail — an unlinkable child, a handle
/// somebody holds — so a sweep that went first could leave meta standing
/// over a half-taken store. The next recovery pass would read that as an
/// interrupted apply and roll back a completed one, deleting each path
/// before it found the pre-image gone. With meta down first, what is left
/// is a leftover directory the next pass sweeps. A sync that fails stops
/// here: the sweep may not run while meta's removal is only in memory.
pub fn clear(dir: &Path) -> Result<()> {
    let meta = dir.join("meta.json");
    match fs::remove_file(&meta) {
        Ok(()) => sync_dir_durable(dir)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(CoreError::io(&meta, e)),
    }
    if dir.exists() {
        fs::remove_dir_all(dir).map_err(|e| CoreError::io(dir, e))?;
    }
    Ok(())
}

pub fn pending(dir: &Path) -> bool {
    dir.join("meta.json").is_file()
}

#[cfg(test)]
mod tests;
