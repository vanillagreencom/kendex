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

fn hash_entry(hasher: &mut Sha256, path: &Path, rel: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(path).map_err(|e| CoreError::io(path, e))?;
    let name = rel.to_string_lossy();
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
