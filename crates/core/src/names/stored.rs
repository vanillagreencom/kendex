//! Which entry on the disk a path names. The rules beside this read a
//! string; these two read the directory the string would be written into,
//! because a folding volume hands one directory back under every spelling
//! of its name, and the spelling a caller holds may not be the one stored.

use super::fold;
use crate::error::{CoreError, Result};
use std::path::{Path, PathBuf};

/// `target` spelled the way its parent stores it — the exact name when the
/// parent holds it, a [`folding_sibling`] otherwise, `None` when neither.
/// A folding volume hands one directory back under every spelling of its
/// name, so a path built from a caller's spelling can name a real directory
/// the disk stores under some other string, and a person sent to look at
/// the caller's spelling will not find it there.
///
/// The answer is a read of the parent, and a read that could not be made is
/// not an empty directory. Callers deciding whether a write would land on
/// stored content get the error: an unlistable parent that reads as `None`
/// is a slot reported free while it holds the item the write destroys.
pub fn stored_spelling(target: &Path) -> Result<Option<PathBuf>> {
    let (Some(parent), Some(leaf)) = (target.parent(), target.file_name().and_then(|l| l.to_str()))
    else {
        return Ok(None);
    };
    // A parent that is not there holds nothing, which is an answer. One
    // that is there and will not enumerate is not.
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(CoreError::io(parent, e)),
    };
    let folded = fold(leaf);
    let mut folding = None;
    for entry in entries {
        let name = entry.map_err(|e| CoreError::io(parent, e))?.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name == leaf {
            return Ok(Some(target.to_path_buf()));
        }
        if folding.is_none() && fold(name) == folded {
            folding = Some(parent.join(name));
        }
    }
    Ok(folding)
}

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

#[cfg(test)]
mod tests {
    use super::*;

    /// The step a folding volume turns on: `Data-Science` is what the disk
    /// holds, so that is what a person asking for `data-science` is told,
    /// whatever spelling reached the directory.
    #[test]
    fn a_slot_is_spelled_the_way_its_parent_stores_it() {
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path();
        let asked = parent.join("data-science");
        std::fs::create_dir(parent.join("Data-Science")).unwrap();
        assert_eq!(
            stored_spelling(&asked).unwrap(),
            Some(parent.join("Data-Science"))
        );
        assert_eq!(stored_spelling(&parent.join("handmade")).unwrap(), None);
        // A directory that is not there holds nothing, and saying so is not
        // the swallow below: an adoption into a local source with no kind
        // dir yet has to land.
        assert_eq!(
            stored_spelling(&parent.join("absent/handmade")).unwrap(),
            None
        );

        // A volume keeping the two names apart stores an exact entry, and
        // that is the name a write lands on; one that folds them has the
        // single directory it was created under. The parent answers both.
        let stored = match std::fs::create_dir(&asked) {
            Ok(()) => "data-science",
            Err(_) => "Data-Science",
        };
        assert_eq!(stored_spelling(&asked).unwrap(), Some(parent.join(stored)));
    }

    /// A parent that is searchable but not listable — POSIX mode 0311, or
    /// an ACL — keeps the slot and everything under it reachable while the
    /// scan returns nothing. The error is the answer; `None` here is a slot
    /// reported free while it holds what the caller would write over.
    #[cfg(unix)]
    #[test]
    fn a_parent_that_will_not_enumerate_errors_rather_than_reading_empty() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("skills");
        std::fs::create_dir(&parent).unwrap();
        std::fs::create_dir(parent.join("data-science")).unwrap();
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o311)).unwrap();
        // Root reads any directory whatever its mode, so there the denial
        // under test does not exist and the exact spelling is the answer.
        let denied = std::fs::read_dir(&parent).is_err();
        let asked = stored_spelling(&parent.join("data-science"));
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o755)).unwrap();

        match denied {
            true => assert!(matches!(asked, Err(CoreError::Io { .. })), "{asked:?}"),
            false => assert_eq!(asked.unwrap(), Some(parent.join("data-science"))),
        }
    }
}
