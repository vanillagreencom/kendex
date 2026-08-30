//! What a copy of a whole file remembers about the file it came from.
//!
//! Most writes load, change one thing, and save in one breath — a stale
//! copy cannot reach them. A whole-file surface is different: it hands a
//! person the entire file, waits while they work, and writes all of it
//! back, so an older copy can land on top of a newer file and silently
//! undo whatever else wrote it. The base is the defence: the hash of the
//! exact bytes the copy was read from, sent back with the write, refused
//! when the file on disk is no longer those bytes.

use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::Pre;
use crate::error::{CoreError, Result};
use crate::fs::read_if_exists;

/// The base of one whole-file copy.
///
/// There is one way to derive one — [`Base::of`], over the bytes it
/// describes — because the failure this exists to prevent is a base paired
/// with content nobody read together. A base taken by a read separate from
/// the content it answers for describes a different moment: a writer
/// landing between the two hands the caller old content under the new
/// file's name, and the write that follows is accepted over that writer.
/// Nothing here takes a path and hands back a base, deliberately — a path
/// is not the bytes, and reading them apart is how the two come adrift.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(transparent)]
pub struct Base(Option<String>);

impl Base {
    /// The base of exactly these bytes.
    pub fn of(text: &str) -> Base {
        Base(Some(crate::hash::hash_bytes(text.as_bytes())))
    }

    /// Nothing was there, which is an answer a copy can hold: a write
    /// carrying it says "there was no file", and is refused if there is
    /// one now.
    pub fn absent() -> Base {
        Base(None)
    }

    /// What a caller in another process says its copy came from.
    ///
    /// The bytes are behind an IPC boundary, so they cannot be read here
    /// and this is the one base not derived from content in hand. It is
    /// never trusted: its only use is to be compared with a base this
    /// process derived, and anything but equal refuses.
    pub fn claimed(value: Option<String>) -> Base {
        Base(value)
    }

    /// The precondition a write binds to for a document kendex will not
    /// write *through* — one whose own path is what it may touch.
    ///
    /// [`Pre::HashIs`] hashes what the path reaches, following a link, so
    /// a file swapped for a link to matching bytes passes it and the write
    /// lands at the other end. Checking for a link before planning cannot
    /// close that: a check before a write is a race by construction, and
    /// the refusal has to travel with the operation instead.
    pub fn plain_pre(&self) -> Pre {
        match &self.0 {
            Some(hash) => Pre::PlainHashIs { hash: hash.clone() },
            None => Pre::Absent,
        }
    }

    /// Refuse this claim unless the file's current base is exactly it.
    /// The current base is compared and dropped, never handed back — a
    /// caller holding it would be holding a base for content it never
    /// read, which is the pairing this type exists to keep unspellable.
    pub fn verify(&self, path: &Path) -> Result<()> {
        let now = match read_if_exists(path)? {
            Some(text) => Base::of(&text),
            None => Base::absent(),
        };
        match now == *self {
            true => Ok(()),
            false => Err(CoreError::PlanStale {
                path: path.to_path_buf(),
            }),
        }
    }
}

/// The precondition a write against this base binds to: the same
/// comparison [`Base::verify`] makes, re-made by the apply immediately
/// before the bytes go down — so a file that moves between the check and
/// the write is refused with the same answer, not overwritten.
impl From<&Base> for Pre {
    fn from(base: &Base) -> Pre {
        match &base.0 {
            Some(hash) => Pre::HashIs { hash: hash.clone() },
            None => Pre::Absent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `Pre::HashIs` compares `hash_tree` of the path; a base is
    /// `hash_bytes` of the text. The two must be the same function of a
    /// lone file's bytes, or every bound write would refuse a file its
    /// own check just accepted.
    #[test]
    fn a_base_matches_the_tree_hash_of_the_file_it_describes() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        std::fs::write(&path, "schema = 2\n").unwrap();

        assert_eq!(
            Pre::from(&Base::of("schema = 2\n")),
            Pre::HashIs {
                hash: crate::hash::hash_tree(&path).unwrap()
            }
        );
    }

    /// The race the plain precondition exists to lose: between the plan
    /// and the write, the file becomes a link to a file with the same
    /// bytes. `HashIs` follows it and passes, so the write would land
    /// outside the place kendex was asked to manage.
    #[test]
    #[cfg(unix)]
    fn a_link_carrying_the_same_bytes_passes_the_following_check_and_fails_the_plain_one() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.settings.toml");
        let elsewhere = tmp.path().join("elsewhere.toml");
        std::fs::write(&path, "[env]\n").unwrap();
        let held = Base::of("[env]\n");

        assert!(Pre::from(&held).check_for_test(&path).is_ok());
        assert!(held.plain_pre().check_for_test(&path).is_ok());

        std::fs::write(&elsewhere, "[env]\n").unwrap();
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &path).unwrap();

        assert!(
            Pre::from(&held).check_for_test(&path).is_ok(),
            "a following precondition cannot tell the link from the file"
        );
        assert!(held.plain_pre().check_for_test(&path).is_err());
    }

    #[test]
    fn a_copy_of_the_current_file_verifies_and_a_stale_one_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");
        std::fs::write(&path, "schema = 2\n").unwrap();

        let held = Base::of("schema = 2\n");
        assert!(held.verify(&path).is_ok());

        std::fs::write(&path, "schema = 2\nzoom = 150\n").unwrap();
        assert!(matches!(
            held.verify(&path),
            Err(CoreError::PlanStale { path: at }) if at == path
        ));
    }

    #[test]
    fn an_absent_claim_verifies_only_while_nothing_is_there() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("kendex.toml");

        assert!(Base::absent().verify(&path).is_ok());

        std::fs::write(&path, "schema = 2\n").unwrap();
        assert!(Base::absent().verify(&path).is_err());
        // And the reverse: a copy of a file that has since been deleted.
        std::fs::remove_file(&path).unwrap();
        assert!(Base::of("schema = 2\n").verify(&path).is_err());
    }
}
