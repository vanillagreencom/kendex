use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};

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

fn sync_file(path: &Path) -> Result<()> {
    fs::File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|e| CoreError::io(path, e))
}

/// Directory fsync is a no-op on platforms where directories cannot be
/// opened (Windows); rename durability there rides on the volume flush.
fn sync_dir(path: &Path) {
    #[cfg(unix)]
    if let Ok(dir) = fs::File::open(path) {
        let _ = dir.sync_all();
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn sync_tree(root: &Path) -> Result<()> {
    if root.is_file() {
        return sync_file(root);
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            sync_tree(&entry.path())?;
        }
        sync_dir(root);
    }
    Ok(())
}

/// Restore every pre-image. Used both for in-process rollback after a
/// mid-mutation failure and for crash recovery on the next run, where
/// nothing can know which ops ran.
pub fn rollback(dir: &Path) -> Result<()> {
    rollback_where(dir, |_| true)
}

/// Restore only the pre-images of paths this transaction actually mutated:
/// a path in `mutated`, or a journaled directory root above one (the top
/// of a chain the transaction created). In-process rollback knows exactly
/// which ops ran; restoring the rest would put the journal's snapshot over
/// bytes a writer outside the transaction landed after the journal was
/// taken — the precondition that stopped the apply refused to overwrite
/// those bytes, so the rollback must not either. A crash between this
/// restore and the journal clearing still recovers with the full
/// [`rollback`], which cannot make that distinction.
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

pub fn remove_any(path: &Path) -> Result<()> {
    if path.is_symlink() || path.is_file() {
        fs::remove_file(path).map_err(|e| CoreError::io(path, e))?;
    } else if path.is_dir() {
        fs::remove_dir_all(path).map_err(|e| CoreError::io(path, e))?;
    }
    Ok(())
}

pub fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    fs::create_dir_all(to).map_err(|e| CoreError::io(to, e))?;
    for entry in fs::read_dir(from)
        .map_err(|e| CoreError::io(from, e))?
        .flatten()
    {
        let source = entry.path();
        let Some(name) = source.file_name() else {
            continue;
        };
        let dest = to.join(name);
        if source.is_symlink() {
            let target = fs::read_link(&source).map_err(|e| CoreError::io(&source, e))?;
            make_symlink(&target, &dest)?;
        } else if source.is_dir() {
            copy_tree(&source, &dest)?;
        } else {
            fs::copy(&source, &dest).map_err(|e| CoreError::io(&source, e))?;
        }
    }
    Ok(())
}

#[cfg(unix)]
pub fn make_symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link).map_err(|e| CoreError::io(link, e))
}

#[cfg(windows)]
pub fn make_symlink(target: &Path, link: &Path) -> Result<()> {
    if target.is_dir() {
        std::os::windows::fs::symlink_dir(target, link).map_err(|e| CoreError::io(link, e))
    } else {
        std::os::windows::fs::symlink_file(target, link).map_err(|e| CoreError::io(link, e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The filtered restore is what keeps a refused apply from destroying
    /// the very bytes the refusal protected: a path whose op never ran
    /// keeps whatever a writer outside the transaction put there after the
    /// journal was taken.
    #[test]
    fn a_filtered_rollback_leaves_unmutated_paths_as_the_world_left_them() {
        let tmp = tempfile::tempdir().unwrap();
        let work = tmp.path().join("work");
        fs::create_dir_all(&work).unwrap();
        let a = work.join("a.md");
        let b = work.join("kendex.toml");
        fs::write(&a, "a0").unwrap();
        fs::write(&b, "b0").unwrap();

        let journal_dir = tmp.path().join("journal/global");
        write(&journal_dir, &[a.clone(), b.clone()]).unwrap();
        // The transaction mutates `a`; a writer outside it lands on `b`
        // before `b`'s own op refuses its precondition.
        fs::write(&a, "a1").unwrap();
        fs::write(&b, "external edit").unwrap();

        rollback_mutated(&journal_dir, std::slice::from_ref(&a)).unwrap();

        assert_eq!(fs::read_to_string(&a).unwrap(), "a0");
        assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
        assert!(!pending(&journal_dir));
    }

    /// A journaled directory root above a mutated path is part of the
    /// transaction's footprint: the chain it created comes down with the
    /// rollback even though only the leaf is named as mutated.
    #[test]
    fn a_filtered_rollback_still_removes_the_chain_above_a_mutated_path() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("work/.codex");
        let leaf = root.join("skills/x.md");

        let journal_dir = tmp.path().join("journal/global");
        write(&journal_dir, &[leaf.clone(), root.clone()]).unwrap();
        fs::create_dir_all(leaf.parent().unwrap()).unwrap();
        fs::write(&leaf, "installed").unwrap();

        rollback_mutated(&journal_dir, std::slice::from_ref(&leaf)).unwrap();

        assert!(!root.exists());
    }

    #[test]
    fn rollback_restores_files_dirs_symlinks_and_absence() {
        let tmp = tempfile::tempdir().unwrap();
        let work = tmp.path().join("work");
        fs::create_dir_all(work.join("tree/sub")).unwrap();
        fs::write(work.join("file.md"), "original").unwrap();
        fs::write(work.join("tree/sub/x"), "x").unwrap();
        make_symlink(Path::new("/nowhere"), &work.join("link")).unwrap();
        let absent = work.join("was-absent");

        let journal_dir = tmp.path().join("journal/global");
        write(
            &journal_dir,
            &[
                work.join("file.md"),
                work.join("tree"),
                work.join("link"),
                absent.clone(),
            ],
        )
        .unwrap();

        fs::write(work.join("file.md"), "clobbered").unwrap();
        fs::remove_dir_all(work.join("tree")).unwrap();
        fs::remove_file(work.join("link")).unwrap();
        fs::write(&absent, "should vanish").unwrap();

        rollback(&journal_dir).unwrap();

        assert_eq!(
            fs::read_to_string(work.join("file.md")).unwrap(),
            "original"
        );
        assert_eq!(fs::read_to_string(work.join("tree/sub/x")).unwrap(), "x");
        assert_eq!(
            fs::read_link(work.join("link")).unwrap(),
            Path::new("/nowhere")
        );
        assert!(!absent.exists());
        assert!(!pending(&journal_dir));
    }
}
