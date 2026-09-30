//! The launch marker shared by orch and the CLI's project-write refusal.
//!
//! `orch/scripts/lane-marker` documents this filesystem interface. It writes
//! the worktree root into `lane-mail/<ASCII-lowercase item>` under the common
//! git directory. Only the checked-out item branch can identify this lane.

use std::io;
use std::path::Path;

use crate::error::{CoreError, Result};
use crate::guard::{Repo, path_from};
use crate::process::Hardened;

/// The item whose launch marker binds this linked worktree, or no lane.
/// Main checkouts and detached or non-item branches are not lane worktrees.
/// A failed git or marker read is an error, never an unmarked checkout.
pub fn marked_worktree(dir: &Path) -> Result<Option<String>> {
    let Some(repo) = Repo::probe(dir)? else {
        return Ok(None);
    };
    if !repo.is_linked() {
        return Ok(None);
    }
    let output = Hardened::git(&["symbolic-ref", "--quiet", "HEAD"], Some(&repo.worktree)).run()?;
    if output.status.code() == Some(1) {
        return Ok(None);
    }
    if !output.status.success() {
        return Err(CoreError::GitFailed {
            command: "symbolic-ref --quiet HEAD".into(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    let reference = output.stdout.strip_suffix(b"\n").unwrap_or(&output.stdout);
    let branch = reference
        .strip_prefix(b"refs/heads/")
        .ok_or_else(|| CoreError::GitFailed {
            command: "symbolic-ref --quiet HEAD".into(),
            stderr: "HEAD names no local branch".into(),
        })?;
    // lane-marker's item alphabet excludes branch paths. Such a branch has
    // no marker a launcher can produce, rather than a failed marker read.
    if branch.is_empty()
        || matches!(branch, b"." | b"..")
        || !branch
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte))
    {
        return Ok(None);
    }
    let branch: String = branch.iter().copied().map(char::from).collect();
    let directory = repo.common_dir.join("lane-mail");
    if !plain(&directory, Component::Directory)? {
        return Ok(None);
    }
    let marker = directory.join(branch.to_ascii_lowercase());
    if !plain(&marker, Component::File)? {
        return Ok(None);
    }
    let mut bytes = std::fs::read(&marker).map_err(|error| CoreError::io(&marker, error))?;
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    let root = path_from(bytes, "lane marker")?;
    if !root.is_absolute() {
        return Err(CoreError::io(
            &marker,
            io::Error::new(
                io::ErrorKind::InvalidData,
                "lane marker root is not absolute",
            ),
        ));
    }
    let root = crate::paths::canonical(&root).map_err(|error| CoreError::io(&marker, error))?;
    Ok((root == crate::paths::reduced(&repo.worktree)).then_some(branch))
}

enum Component {
    Directory,
    File,
}

fn plain(path: &Path, component: Component) -> Result<bool> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(CoreError::io(path, error)),
    };
    let expected = match component {
        Component::Directory => metadata.is_dir(),
        Component::File => metadata.is_file(),
    };
    if expected {
        return Ok(true);
    }
    Err(CoreError::io(
        path,
        io::Error::new(
            io::ErrorKind::InvalidData,
            "lane marker component is not plain",
        ),
    ))
}
