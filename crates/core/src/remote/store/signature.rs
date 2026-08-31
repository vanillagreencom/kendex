//! The content hash a publish receipt vouches for.
//!
//! A tree hashed as sorted path plus kind plus content, so a checkout
//! somebody edited stops matching the receipt beside it and is rebuilt
//! from the mirror rather than read as if it were the commit.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::{CoreError, Result};

/// SHA-256 over a tree as sorted path + kind + content. Symlinks hash their
/// target text, never what it points at: a catalog may ship a link that
/// dangles here, and reading through it would either fail or pull in bytes
/// from the host.
pub fn tree_signature(root: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    hash_entry(&mut hasher, root, Path::new(""))?;
    let mut out = String::new();
    for byte in hasher.finalize() {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    Ok(out)
}

/// The name a path contributes to the hash, with `/` between components on
/// every platform.
///
/// `PathBuf::join` writes the platform's separator, so the path grown while
/// walking a tree spells `skills/gh/SKILL.md` on Unix and `skills\gh\SKILL.md`
/// on Windows. Hashing that directly gives one tree two signatures by
/// platform, which is precisely the difference the signature exists to
/// detect rather than to introduce.
fn hashed_name(rel: &Path) -> String {
    rel.iter()
        .map(|part| part.to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn hash_entry(hasher: &mut Sha256, path: &Path, rel: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(path).map_err(|e| CoreError::io(path, e))?;
    let name = hashed_name(rel);
    if meta.is_symlink() {
        let target = fs::read_link(path).map_err(|e| CoreError::io(path, e))?;
        hasher.update(b"l\0");
        hasher.update(name.as_bytes());
        hasher.update([0]);
        hasher.update(target.to_string_lossy().as_bytes());
        hasher.update([0]);
    } else if meta.is_dir() {
        hasher.update(b"d\0");
        hasher.update(name.as_bytes());
        hasher.update([0]);
        let mut entries: Vec<PathBuf> = fs::read_dir(path)
            .map_err(|e| CoreError::io(path, e))?
            .flatten()
            .map(|entry| entry.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(file_name) = entry.file_name() else {
                continue;
            };
            hash_entry(hasher, &entry, &rel.join(file_name))?;
        }
    } else {
        hasher.update(b"f\0");
        hasher.update(name.as_bytes());
        hasher.update([0]);
        hasher.update([executable(&meta)]);
        hasher.update(&fs::read(path).map_err(|e| CoreError::io(path, e))?);
        hasher.update([0]);
    }
    Ok(())
}

/// The one permission bit git records, and the one a hook script needs.
#[cfg(unix)]
fn executable(meta: &fs::Metadata) -> u8 {
    use std::os::unix::fs::PermissionsExt;
    u8::from(meta.permissions().mode() & 0o100 != 0)
}

#[cfg(not(unix))]
fn executable(_meta: &fs::Metadata) -> u8 {
    0
}

#[cfg(test)]
mod tests {
    use super::hashed_name;
    use std::path::{Path, PathBuf};

    /// Grown the way `hash_entry` grows it, and spelled the way every
    /// platform has to spell it. On Windows `join` writes a backslash, so
    /// this is the assertion that reds there if the separator reaches the
    /// hash; on Unix it is the statement that nothing else does either.
    #[test]
    fn a_hashed_name_joins_its_components_with_a_forward_slash() {
        let rel = PathBuf::new().join("skills").join("gh").join("SKILL.md");
        assert_eq!(hashed_name(&rel), "skills/gh/SKILL.md");
        assert_eq!(hashed_name(Path::new("")), "");
    }
}
