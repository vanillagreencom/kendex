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
const MAX_TREE_FILES: usize = 2048;
const MAX_TREE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_TREE_DEPTH: usize = 16;
const MAX_DIR_ENTRIES: usize = 4096;

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
        let skip: &[&str] = match dir == self.root() {
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
                if files.len() >= MAX_TREE_FILES || *total > MAX_TREE_BYTES {
                    return Err(CoreError::SourceEscape {
                        path,
                        reason: format!(
                            "catalog tree exceeds the {MAX_TREE_FILES}-file / {MAX_TREE_BYTES}-byte budget"
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
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, SealedSource) {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("catalog");
        std::fs::create_dir_all(root.join("skills/gh")).expect("mkdir");
        std::fs::write(root.join("skills/gh/SKILL.md"), "---\nname: gh\n---\n").expect("write");
        std::fs::write(tmp.path().join("secret.txt"), "host secret").expect("write");
        let sealed = SealedSource::open(&root).expect("open");
        (tmp, sealed)
    }

    #[test]
    fn reads_inside_the_root_and_refuses_escapes() {
        let (tmp, sealed) = fixture();
        let inside = sealed.root().join("skills/gh/SKILL.md");
        assert!(sealed.is_file(&inside));
        assert!(sealed.read_to_string(&inside).is_ok());

        let outside = tmp.path().join("secret.txt");
        assert!(!sealed.is_file(&outside));
        assert!(matches!(
            sealed.read(&outside),
            Err(CoreError::SourceEscape { .. })
        ));
        let dotted = sealed.root().join("skills/../../secret.txt");
        assert!(matches!(
            sealed.read(&dotted),
            Err(CoreError::SourceEscape { .. })
        ));
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_refused_through_every_read_path() {
        let (tmp, sealed) = fixture();
        let secret = tmp.path().join("secret.txt");
        std::os::unix::fs::symlink(&secret, sealed.root().join("skills/gh/leak.md"))
            .expect("symlink");
        let leak = sealed.root().join("skills/gh/leak.md");
        assert!(!sealed.is_file(&leak));
        assert!(matches!(
            sealed.read(&leak),
            Err(CoreError::SourceEscape { .. })
        ));
        assert!(matches!(
            sealed.collect_tree(&sealed.root().join("skills/gh"), &[]),
            Err(CoreError::SourceEscape { .. })
        ));
        assert!(matches!(
            sealed.hash_tree(&sealed.root().join("skills/gh")),
            Err(CoreError::SourceEscape { .. })
        ));

        // A symlinked directory cannot recurse forever either.
        std::fs::remove_file(&leak).expect("rm");
        std::os::unix::fs::symlink(sealed.root(), sealed.root().join("skills/gh/loop"))
            .expect("symlink");
        assert!(matches!(
            sealed.collect_tree(sealed.root(), &[]),
            Err(CoreError::SourceEscape { .. })
        ));
    }

    #[test]
    fn tree_budgets_bound_hostile_catalogs() {
        let (_tmp, sealed) = fixture();
        let mut nested = sealed.root().join("skills/deep");
        for _ in 0..(MAX_TREE_DEPTH + 2) {
            nested = nested.join("d");
        }
        std::fs::create_dir_all(&nested).expect("mkdir");
        std::fs::write(nested.join("f"), "x").expect("write");
        assert!(matches!(
            sealed.collect_tree(&sealed.root().join("skills/deep"), &[]),
            Err(CoreError::SourceEscape { .. })
        ));
    }

    /// The bound is a ceiling, not a wall one short of it: a directory
    /// holding exactly the limit is inside it and must still read.
    #[test]
    fn the_directory_bound_admits_exactly_the_limit() {
        let (_tmp, sealed) = fixture();
        let dir = sealed.root().join("many");
        std::fs::create_dir_all(&dir).expect("mkdir");
        for n in 0..MAX_DIR_ENTRIES {
            std::fs::write(dir.join(format!("f{n}")), "x").expect("write");
        }
        assert_eq!(sealed.list_dir(&dir).expect("list").len(), MAX_DIR_ENTRIES);

        std::fs::write(dir.join("one-too-many"), "x").expect("write");
        assert!(matches!(
            sealed.list_dir(&dir),
            Err(CoreError::SourceEscape { .. })
        ));
    }

    /// A skill that is the whole repository excludes VCS internals and
    /// dependency dirs — the same bytes render, browse safety, and catalog
    /// check must all agree on. A `.git/config` carrying credentials must
    /// never reach the installed tree.
    #[test]
    fn a_repo_root_skill_excludes_vcs_and_dependency_dirs() {
        let (_tmp, sealed) = fixture();
        std::fs::create_dir_all(sealed.root().join(".git")).expect("mkdir");
        std::fs::write(sealed.root().join(".git/config"), "token").expect("write");
        std::fs::create_dir_all(sealed.root().join("node_modules/dep")).expect("mkdir");
        std::fs::write(sealed.root().join("node_modules/dep/i.js"), "x").expect("write");
        std::fs::write(sealed.root().join("SKILL.md"), "# skill").expect("write");

        let files = sealed.collect_skill_tree(sealed.root()).expect("tree");
        let names: Vec<_> = files
            .iter()
            .map(|(p, _)| p.to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&"SKILL.md".to_owned()));
        assert!(!names.iter().any(|n| n.starts_with(".git/")));
        assert!(!names.iter().any(|n| n.starts_with("node_modules/")));
    }

    /// A skill nested below the root is scored on all of its own bytes — the
    /// vendor-dir skip is a repo-root concession, not a general filter that
    /// would let a nested skill hide content from the safety scan.
    #[test]
    fn a_nested_skill_keeps_every_one_of_its_files() {
        let (_tmp, sealed) = fixture();
        let dir = sealed.root().join("skills/gh");
        std::fs::create_dir_all(dir.join("node_modules")).expect("mkdir");
        std::fs::write(dir.join("node_modules/i.js"), "x").expect("write");
        std::fs::write(dir.join("SKILL.md"), "# gh").expect("write");

        let files = sealed.collect_skill_tree(&dir).expect("tree");
        assert_eq!(files.len(), 2);
    }

    #[test]
    fn skipped_names_are_pruned_from_trees() {
        let (_tmp, sealed) = fixture();
        let pkg = sealed.root().join("pkg");
        std::fs::create_dir_all(pkg.join("node_modules/dep")).expect("mkdir");
        std::fs::write(pkg.join("node_modules/dep/i.js"), "x").expect("write");
        std::fs::write(pkg.join("index.js"), "y").expect("write");
        let files = sealed.collect_tree(&pkg, &["node_modules"]).expect("tree");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].0, PathBuf::from("index.js"));
    }
}
