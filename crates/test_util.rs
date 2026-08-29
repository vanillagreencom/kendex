use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Derives the canonical root once, before fixture paths reach code that may
/// resolve symlinks itself. Through the same rule production uses, so a
/// fixture root and the root the binary reports back are one spelling.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "every test binary includes this whole module and uses the part it needs; the expect is a fixture precondition"
)]
pub fn rooted(tmp: &tempfile::TempDir) -> PathBuf {
    kendex_core::paths::canonical(tmp.path()).expect("fixture root canonicalizes")
}

/// The `path = …` line of a source declaration, written by the TOML
/// serializer rather than by the fixture.
///
/// A fixture that picks the delimiter has to be right about every
/// character a host path can hold, and both delimiters lose: a Windows
/// separator is the escape character a basic string reads, so `C:\Users`
/// is a parse error, and a literal string has no escape at all, so an
/// apostrophe in a home directory closes it early. The serializer knows
/// which form fits the value it was handed, and the next character
/// nobody has thought of is its problem rather than a fixture's.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "every test binary includes this whole module and uses the part it needs; a string always serializes"
)]
pub fn source_path(path: &Path) -> String {
    toml::to_string(&BTreeMap::from([("path", path.display().to_string())]))
        .expect("a string serializes as TOML")
        .trim_end()
        .to_owned()
}
