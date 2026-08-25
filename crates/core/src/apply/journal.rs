use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};
use crate::fs::{copy_tree, make_symlink, remove_any, sync_dir, sync_file, sync_tree};

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
            let slot = store.join(&slot_name);
            let resolved_file = path.exists() && path.is_file();
            if resolved_file {
                fs::copy(path, &slot).map_err(|e| CoreError::io(path, e))?;
                sync_file(&slot)?;
            }
            PreState::Symlink {
                target: fs::read_link(path).map_err(|e| CoreError::io(path, e))?,
                store: resolved_file.then_some(slot_name),
            }
        } else if path.is_dir() {
            let slot = store.join(index.to_string());
            copy_tree(path, &slot)?;
            sync_tree(&slot)?;
            PreState::Dir {
                store: index.to_string(),
            }
        } else if path.is_file() {
            let slot = store.join(index.to_string());
            fs::copy(path, &slot).map_err(|e| CoreError::io(path, e))?;
            sync_file(&slot)?;
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

/// Where a filtered restore persists its filter before touching anything.
/// Crash recovery must re-run the same filter, not widen to every
/// snapshot: the paths the filter excludes hold bytes a writer outside
/// the transaction landed, the very bytes whose refusal triggered the
/// restore.
fn restore_set_path(dir: &Path) -> PathBuf {
    dir.join("restore.json")
}

/// Crash recovery: restore pre-images for a journal an interrupted apply
/// left behind. An interrupted filtered restore persisted its restore set
/// first, so recovery re-runs exactly that filter; with no persisted set,
/// nothing can know which ops ran and every pre-image is restored.
pub fn rollback(dir: &Path) -> Result<()> {
    if let Some(text) = crate::fs::read_if_exists(&restore_set_path(dir))? {
        // The file's presence proves a filtered restore was in flight, so
        // some journaled paths hold bytes the filter protects. It is
        // written atomically — complete or absent, never torn — so content
        // that does not parse is outside interference, and widening to the
        // full restore would destroy exactly those protected bytes. Refuse
        // instead, leaving the journal pending for inspection.
        let mutated: Vec<PathBuf> =
            serde_json::from_str(&text).map_err(|e| CoreError::JsonParse {
                path: restore_set_path(dir),
                message: e.to_string(),
            })?;
        return rollback_filtered(dir, &mutated);
    }
    rollback_where(dir, |_| true)
}

/// Restore only the pre-images of paths this transaction actually mutated:
/// a path in `mutated`, or a journaled directory root above one (the top
/// of a chain the transaction created). In-process rollback knows exactly
/// which ops ran; restoring the rest would put the journal's snapshot over
/// bytes a writer outside the transaction landed after the journal was
/// taken — the precondition that stopped the apply refused to overwrite
/// those bytes, so the rollback must not either. The restore set is made
/// durable before the first path is touched, so a crash mid-restore
/// recovers with the same filter instead of falling back to a full
/// restore that would destroy those protected bytes after all.
pub fn rollback_mutated(dir: &Path, mutated: &[PathBuf]) -> Result<()> {
    // The persisted set is a crash guard for the restore below, never a
    // gate in front of it. When this write fails (ENOSPC can fail the op
    // and then fail this write to the same volume), the restore must still
    // run: completed, it clears the journal and needs no filter afterwards,
    // while skipping it would leave the journal pending for a recovery
    // that, finding no set, restores every snapshot — the loss the filter
    // exists to prevent. Only a crash between a failed persist and the end
    // of the restore still reaches that full recovery.
    let persisted = persist_restore_set(dir, mutated);
    match (rollback_filtered(dir, mutated), persisted) {
        (Ok(()), _) => Ok(()),
        (Err(restore), Ok(())) => Err(restore),
        // Both failed: the journal is pending with no filter on disk, so
        // the recovery that clears it will restore every snapshot. Named
        // together — the restore error alone reads as a retry of the same
        // filtered restore, which is not what recovery will run.
        (Err(restore), Err(persist)) => Err(CoreError::RestoreSetLost {
            restore: Box::new(restore),
            persist: Box::new(persist),
        }),
    }
}

fn persist_restore_set(dir: &Path, mutated: &[PathBuf]) -> Result<()> {
    let path = restore_set_path(dir);
    let json = serde_json::to_string_pretty(mutated).map_err(|e| CoreError::JsonParse {
        path: path.clone(),
        message: e.to_string(),
    })?;
    crate::fs::atomic_write_durable(&path, &json)
}

fn rollback_filtered(dir: &Path, mutated: &[PathBuf]) -> Result<()> {
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
        // A torn meta can only mean the crash hit before the durable meta
        // write completed — and mutations only start after it completes, so
        // the world is untouched and the journal is safe to discard.
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
                fs::copy(store.join(slot), &entry.path)
                    .map_err(|e| CoreError::io(&entry.path, e))?;
                sync_file(&entry.path)?;
            }
            PreState::Symlink {
                target,
                store: slot,
            } => {
                if let Some(parent) = entry.path.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                make_symlink(target, &entry.path)?;
                // A write may have gone through the link: restore the
                // linked-to file's bytes too.
                if let Some(slot) = slot {
                    fs::copy(store.join(slot), &entry.path)
                        .map_err(|e| CoreError::io(&entry.path, e))?;
                    sync_file(&entry.path)?;
                }
            }
            PreState::Dir { store: slot } => {
                copy_tree(&store.join(slot), &entry.path)?;
                sync_tree(&entry.path)?;
            }
        }
    }
    clear(dir)
}

pub fn clear(dir: &Path) -> Result<()> {
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
