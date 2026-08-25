//! Capturing a folder on disk as bytes: the walk that turns a real
//! directory into the files a plan writes, and the budget that stops a
//! link at somebody's home directory becoming a memory problem. Adoption
//! keeps an unmanaged tree with it, a fork keeps an edited one, and the
//! package diff reads an installed one; none of them needs the others
//! open to read it.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

/// Far beyond any real skill, but a hard stop before a link at a huge
/// folder turns a capture into a memory problem. Fail-loud: the error
/// names the file that broke the budget.
const MAX_CAPTURE_FILES: usize = 2000;
const MAX_CAPTURE_BYTES: u64 = 100 * 1024 * 1024;

pub(crate) fn read_tree(root: &Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    fn walk(
        dir: &Path,
        rel: &Path,
        files: &mut Vec<(PathBuf, Vec<u8>)>,
        bytes: &mut u64,
    ) -> Result<()> {
        for entry in fs::read_dir(dir).map_err(|e| CoreError::io(dir, e))? {
            // A per-entry read error is not silently skipped: dropping it
            // would capture an incomplete tree and then trash the
            // original, losing content the caller asked to keep.
            let entry = entry.map_err(|e| CoreError::io(dir, e))?;
            let path = entry.path();
            let Some(name) = path.file_name() else {
                continue;
            };
            let rel = rel.join(name);
            // A link is not plain content: following it would read whatever
            // it points at into the capture under this tree's name. Rather
            // than silently drop it (and then trash the original), refuse —
            // nothing the user asked to keep is lost without a word.
            if path.is_symlink() {
                return Err(CoreError::ForeignSymlink {
                    points_to: fs::read_link(&path).unwrap_or_default(),
                    target: path,
                });
            }
            if path.is_dir() {
                walk(&path, &rel, files, bytes)?;
                continue;
            }
            // A FIFO would block the read forever and a device is not
            // content; capturing arbitrary user folders means saying so
            // instead of hanging.
            let shape = fs::symlink_metadata(&path).map_err(|e| CoreError::io(&path, e))?;
            if !shape.is_file() {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other("not a regular file — adopt captures plain files only"),
                ));
            }
            // The budget is spent on what was read, never on what the
            // metadata said: a file that grows between the two would leave
            // every file after it a budget that no longer exists, and the
            // bound would hold only for a tree that sat still. So the
            // reader is capped and the total counts the bytes it returned.
            let room = MAX_CAPTURE_BYTES.saturating_sub(*bytes);
            let mut body = Vec::new();
            fs::File::open(&path)
                .and_then(|file| {
                    use std::io::Read;
                    file.take(room + 1).read_to_end(&mut body)
                })
                .map_err(|e| CoreError::io(&path, e))?;
            *bytes += body.len() as u64;
            if files.len() >= MAX_CAPTURE_FILES || body.len() as u64 > room {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other(format!(
                        "this folder is bigger than adopt will capture (over {MAX_CAPTURE_FILES} files or {} MB)",
                        MAX_CAPTURE_BYTES / (1024 * 1024)
                    )),
                ));
            }
            files.push((rel, body));
        }
        Ok(())
    }
    let mut files = Vec::new();
    let mut bytes = 0;
    walk(root, Path::new(""), &mut files, &mut bytes)?;
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A folder bigger than any real skill is refused before anything is
    /// planned, naming the budget, instead of being captured wholesale.
    #[test]
    fn an_oversized_folder_is_refused_out_loud() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("huge");
        fs::create_dir_all(&dir).unwrap();
        for i in 0..(MAX_CAPTURE_FILES + 1) {
            fs::write(dir.join(format!("f{i}")), "x").unwrap();
        }
        let error = read_tree(&dir).unwrap_err();
        assert!(error.to_string().contains("bigger than adopt"), "{error}");
    }
}
