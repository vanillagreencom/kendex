//! Which entry on the disk a path names. The rules beside this read a
//! string; this one reads the directory the string would be written into,
//! because a folding volume hands one directory back under every spelling
//! of its name, and the spelling a caller holds may not be the one stored.

use super::fold;
use crate::error::{CoreError, Result};
use std::path::{Path, PathBuf};

/// An entry beside `target` whose name folds to the target's leaf without
/// being that exact leaf — the neighbour a case- or composition-folding
/// filesystem would hand the same file to. The one reading of "does a
/// sibling occupy this slot", shared by every preflight that scans a
/// directory before writing into it.
///
/// A parent that will not enumerate is an error, never an answer of "no
/// sibling". A directory can be searchable without being listable — mode
/// 0311, or an ACL — where a probe for the leaf itself finds nothing while
/// the fold scan sees nothing either, and a caller reading that as a free
/// slot writes into one the planner then refuses for both names. A parent
/// that holds no entries to fold against is a different matter and an
/// answer: absent, said two ways, as no such name and as a name built
/// under a file.
pub fn folding_sibling(target: &Path) -> Result<Option<PathBuf>> {
    let (Some(parent), Some(leaf)) = (target.parent(), target.file_name().and_then(|l| l.to_str()))
    else {
        return Ok(None);
    };
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(e) if crate::fs::absent(&e) => return Ok(None),
        Err(e) => return Err(CoreError::io(parent, e)),
    };
    let folded = fold(leaf);
    for entry in entries {
        let sibling = entry.map_err(|e| CoreError::io(parent, e))?.file_name();
        let Some(sibling) = sibling.to_str() else {
            continue;
        };
        if sibling != leaf && fold(sibling) == folded {
            return Ok(Some(parent.join(sibling)));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A parent that will not enumerate is an error, never "no sibling".
    /// A directory can be searchable without being listable — POSIX mode
    /// 0311, or an ACL — where a probe for the leaf itself finds nothing
    /// while the fold scan sees nothing either. Read as a free slot, a
    /// caller writes onto a folding volume's existing entry. An absent
    /// parent is a different answer and stays one.
    #[cfg(unix)]
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_parent_that_will_not_enumerate_errors_rather_than_reading_free() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("skills");
        std::fs::create_dir_all(parent.join("Data-Science")).unwrap();
        let asked = parent.join("data-science");
        assert_eq!(
            folding_sibling(&asked).unwrap(),
            Some(parent.join("Data-Science"))
        );
        assert_eq!(folding_sibling(&parent.join("handmade")).unwrap(), None);
        assert_eq!(
            folding_sibling(&tmp.path().join("absent/handmade")).unwrap(),
            None
        );
        // Absent said the other way: a name built under a file. That is a
        // parent holding no entries, not a parent refusing to list them.
        std::fs::write(tmp.path().join("plain"), "x").unwrap();
        assert_eq!(
            folding_sibling(&tmp.path().join("plain/handmade")).unwrap(),
            None
        );

        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o311)).unwrap();
        // Root lists any directory whatever its mode, so there the denial
        // under test does not exist and the neighbour is simply found.
        let denied = !rustix::process::geteuid().is_root();
        let refused = folding_sibling(&asked);
        std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o755)).unwrap();

        match denied {
            true => assert!(matches!(refused, Err(CoreError::Io { .. })), "{refused:?}"),
            false => assert_eq!(refused.unwrap(), Some(parent.join("Data-Science"))),
        }
    }
}
