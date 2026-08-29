use std::path::PathBuf;

/// Derives the canonical root once, before fixture paths reach code that may
/// resolve symlinks itself.
#[allow(clippy::expect_used)]
pub fn rooted(tmp: &tempfile::TempDir) -> PathBuf {
    tmp.path()
        .canonicalize()
        .expect("fixture root canonicalizes")
}
