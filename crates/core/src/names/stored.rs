//! Which entry on the disk a path names. The rules beside this read a
//! string; this one reads the directory the string would be written into,
//! because a folding volume hands one directory back under every spelling
//! of its name, and the spelling a caller holds may not be the one stored.

use super::fold;
use std::path::{Path, PathBuf};

/// An entry beside `target` whose name folds to the target's leaf without
/// being that exact leaf — the neighbour a case- or composition-folding
/// filesystem would hand the same file to. The one reading of "does a
/// sibling occupy this slot", shared by every preflight that scans a
/// directory before writing into it.
pub fn folding_sibling(target: &Path) -> Option<PathBuf> {
    let parent = target.parent()?;
    let leaf = target.file_name()?.to_str()?;
    let folded = fold(leaf);
    for entry in std::fs::read_dir(parent).ok()?.flatten() {
        let sibling = entry.file_name();
        let Some(sibling) = sibling.to_str() else {
            continue;
        };
        if sibling != leaf && fold(sibling) == folded {
            return Some(parent.join(sibling));
        }
    }
    None
}
