//! The one sealed API for reading catalog content. Foreign catalogs are
//! adversarial input: every read resolves against the canonical source
//! root, refuses to look through symlinks (a hostile catalog must not pull
//! host files into rendered artifacts or recurse forever), and carries
//! depth, count, and byte budgets. Raw `fs` calls over catalog paths are
//! banned by the guard — this module is the only door.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_TREE_DEPTH: usize = 16;
const MAX_DIR_ENTRIES: usize = 4096;

/// How large a tree kendex will hold in memory at once.
#[derive(Debug, Clone, Copy)]
pub(crate) struct TreeBound {
    pub(crate) files: usize,
    pub(crate) bytes: u64,
}

/// The one bound every reader of a skill's bytes stops at — the sealed
/// catalog walk below, the audit's walk over installed content, and the
/// rendered tree the install gate and the browse preview score. Rendering
/// can make a tree larger than the catalog's own copy, so the bound is
/// asked of what a surface is about to read rather than only of the source.
pub(crate) const TREE_BOUND: TreeBound = TreeBound {
    files: 2048,
    bytes: 64 * 1024 * 1024,
};

impl TreeBound {
    /// Whether a tree of this many files and bytes is past it. Asked with
    /// the totals a tree *would* have once one more file is in it, so a
    /// walk refuses the file that crosses the bound rather than the one
    /// after it.
    pub(crate) fn past(self, files: usize, bytes: u64) -> bool {
        files > self.files || bytes > self.bytes
    }
}

/// A canonical catalog root and the only reader over it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedSource {
    root: PathBuf,
    /// The spelling the caller opened the root under, kept beside the
    /// canonical one: on macOS the standard temp locations reach their
    /// directories through a `/var` → `/private/var` symlink, so paths a
    /// caller builds from its own spelling would otherwise read as outside
    /// the canonicalized root. Only the ROOT may differ this way — every
    /// component below it still walks the symlink refusal.
    given: PathBuf,
}

impl SealedSource {
    pub fn open(root: &Path) -> Result<SealedSource> {
        let given = root.to_path_buf();
        let root = root.canonicalize().map_err(|e| CoreError::io(root, e))?;
        if !root.is_dir() {
            return Err(CoreError::SourceEscape {
                path: root,
                reason: "the source root is not a directory".to_owned(),
            });
        }
        Ok(SealedSource { root, given })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The containment check every read goes through: the path must sit
    /// beneath the root — under either spelling of it — and no component
    /// below the root may be a symlink.
    fn contained(&self, path: &Path) -> Result<()> {
        let rel = path
            .strip_prefix(&self.root)
            .or_else(|_| path.strip_prefix(&self.given))
            .map_err(|_| CoreError::SourceEscape {
                path: path.to_path_buf(),
                reason: "outside the source root".to_owned(),
            })?;
        let mut probe = self.root.clone();
        for component in rel.components() {
            match component {
                std::path::Component::Normal(name) => probe.push(name),
                _ => {
                    return Err(CoreError::SourceEscape {
                        path: path.to_path_buf(),
                        reason: "path traversal in a catalog path".to_owned(),
                    });
                }
            }
            let meta = match fs::symlink_metadata(&probe) {
                Ok(meta) => meta,
                // Absent is fine — existence checks answer false later.
                Err(_) => return Ok(()),
            };
            if meta.file_type().is_symlink() {
                return Err(CoreError::SourceEscape {
                    path: probe,
                    reason: "symlink in a catalog — refusing to read through it".to_owned(),
                });
            }
        }
        Ok(())
    }

    pub fn is_file(&self, path: &Path) -> bool {
        self.contained(path).is_ok() && path.is_file()
    }

    pub fn is_dir(&self, path: &Path) -> bool {
        self.contained(path).is_ok() && path.is_dir()
    }

    pub fn read(&self, path: &Path) -> Result<Vec<u8>> {
        self.contained(path)?;
        let meta = fs::symlink_metadata(path).map_err(|e| CoreError::io(path, e))?;
        if meta.len() > MAX_FILE_BYTES {
            return Err(CoreError::SourceEscape {
                path: path.to_path_buf(),
                reason: format!(
                    "file is {} bytes — the catalog limit is {MAX_FILE_BYTES}",
                    meta.len()
                ),
            });
        }
        fs::read(path).map_err(|e| CoreError::io(path, e))
    }

    pub fn read_to_string(&self, path: &Path) -> Result<String> {
        let bytes = self.read(path)?;
        String::from_utf8(bytes).map_err(|_| CoreError::SourceEscape {
            path: path.to_path_buf(),
            reason: "not valid UTF-8".to_owned(),
        })
    }

    /// `None` means genuinely absent. A path that exists but fails
    /// containment (a symlinked config, say) errors loudly — treating it
    /// as absent would silently drop a catalog's layout tables.
    pub fn read_if_exists(&self, path: &Path) -> Result<Option<String>> {
        self.contained(path)?;
        if !path.is_file() {
            return Ok(None);
        }
        self.read_to_string(path).map(Some)
    }

    /// Entries of a directory, bounded and sorted. Symlinked entries are
    /// listed too — reading through one is what fails, loudly.
    pub fn list_dir(&self, dir: &Path) -> Result<Vec<PathBuf>> {
        self.contained(dir)?;
        let mut entries: Vec<PathBuf> = Vec::new();
        for entry in fs::read_dir(dir)
            .map_err(|e| CoreError::io(dir, e))?
            .flatten()
        {
            entries.push(entry.path());
            // The bound holds while collecting — a million-entry directory
            // must not get a million-entry allocation first. A directory of
            // exactly the limit is within it; the entry after that is not.
            if entries.len() > MAX_DIR_ENTRIES {
                return Err(CoreError::SourceEscape {
                    path: dir.to_path_buf(),
                    reason: format!("more than {MAX_DIR_ENTRIES} entries in one catalog directory"),
                });
            }
        }
        entries.sort();
        Ok(entries)
    }

    /// Every file under `dir` as (relative path, bytes), the bounded walk
    /// behind skill trees and package copies. `skip` prunes directory names
    /// that are never content (dependency trees, VCS internals).
    pub fn collect_tree(&self, dir: &Path, skip: &[&str]) -> Result<Vec<(PathBuf, Vec<u8>)>> {
        let mut files = Vec::new();
        let mut total: u64 = 0;
        self.collect_into(dir, Path::new(""), skip, 0, &mut total, &mut files)?;
        files.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(files)
    }

    /// The tree of one skill, skipping VCS internals and dependency dirs when
    /// the skill *is* the whole repository. A repo-root skill's tree is the
    /// repository itself, whose `.git`, `node_modules` and build dirs are not
    /// content — reading them would score, publish, and install bytes the skill
    /// never authored (a `.git/config` carries credentials). Every reader of a
    /// skill's bytes — render, browse safety, catalog check — goes through here
    /// so the three never disagree on what the skill contains.
    pub fn collect_skill_tree(&self, dir: &Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
        // Either spelling of the root is the root: the repo-root exclusions
        // must hold however the caller reached it.
        let skip: &[&str] = match dir == self.root || dir == self.given {
            true => &[".git", "node_modules", "target", "dist", "build", ".venv"],
            false => &[],
        };
        self.collect_tree(dir, skip)
    }

    fn collect_into(
        &self,
        dir: &Path,
        rel: &Path,
        skip: &[&str],
        depth: usize,
        total: &mut u64,
        files: &mut Vec<(PathBuf, Vec<u8>)>,
    ) -> Result<()> {
        if depth > MAX_TREE_DEPTH {
            return Err(CoreError::SourceEscape {
                path: dir.to_path_buf(),
                reason: format!("catalog tree nests deeper than {MAX_TREE_DEPTH} levels"),
            });
        }
        for path in self.list_dir(dir)? {
            let Some(name) = path.file_name() else {
                continue;
            };
            if skip.contains(&name.to_string_lossy().as_ref()) {
                continue;
            }
            let rel = rel.join(name);
            // Containment (symlink refusal) runs inside read/list_dir.
            let meta = fs::symlink_metadata(&path).map_err(|e| CoreError::io(&path, e))?;
            if meta.file_type().is_symlink() {
                return Err(CoreError::SourceEscape {
                    path,
                    reason: "symlink in a catalog — refusing to read through it".to_owned(),
                });
            }
            if meta.is_dir() {
                self.collect_into(&path, &rel, skip, depth + 1, total, files)?;
            } else {
                let bytes = self.read(&path)?;
                *total += bytes.len() as u64;
                if TREE_BOUND.past(files.len() + 1, *total) {
                    return Err(CoreError::SourceEscape {
                        path,
                        reason: format!(
                            "catalog tree exceeds the {}-file / {}-byte budget",
                            TREE_BOUND.files, TREE_BOUND.bytes
                        ),
                    });
                }
                files.push((rel, bytes));
            }
        }
        Ok(())
    }

    /// Content hash of a catalog file or tree, matching `hash::hash_tree`'s
    /// construction — but through the sealed walk, so a symlinked catalog
    /// cannot feed host bytes into an installation hash.
    pub fn hash_tree(&self, path: &Path) -> Result<String> {
        if self.is_dir(path) {
            return Ok(crate::hash::hash_files(&self.collect_tree(path, &[])?));
        }
        Ok(crate::hash::hash_bytes(&self.read(path)?))
    }
}

#[cfg(test)]
mod tests;
