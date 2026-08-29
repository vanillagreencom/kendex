use std::path::{Path, PathBuf};

/// Owns a temporary directory while exposing only its canonical root.
pub struct RootedTempDir {
    _dir: tempfile::TempDir,
    root: PathBuf,
}

impl RootedTempDir {
    /// Creates a temporary directory and resolves its root once.
    pub fn new() -> std::io::Result<Self> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().canonicalize()?;
        Ok(Self { _dir: dir, root })
    }

    /// The canonical fixture root.
    pub fn path(&self) -> &Path {
        &self.root
    }
}

impl AsRef<Path> for RootedTempDir {
    fn as_ref(&self) -> &Path {
        self.path()
    }
}
