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

/// Whether this runner can observe the record `kendex` writes for the
/// command it installed.
///
/// A run acting as root writes none, so a case that drives the writers —
/// through the entry points, or through the built binary — has nothing to
/// look at on a runner that is already root, which a root dev container
/// is. Those cases say so and stop, rather than asserting against a record
/// that was never written: several would otherwise pass, holding for a
/// write that was refused instead of for the run that was meant to make
/// it.
///
/// The uid comes from the syscall rather than from the guard that reads
/// it. Asked the other way round, a build whose guard answered a constant
/// would talk these cases out of running on the very runner that would
/// have caught it.
#[cfg(unix)]
#[allow(
    dead_code,
    clippy::print_stderr,
    reason = "every test binary includes this whole module and uses the part it needs; a skipped case has to say so"
)]
pub fn no_record_on_this_runner() -> bool {
    let root = rustix::process::geteuid().is_root();
    if root {
        eprintln!("skipped: a run acting as root writes no record");
    }
    root
}

/// Windows has no uid to read and none of the elevation the guard turns
/// on, so every such case runs there.
#[cfg(not(unix))]
#[allow(
    dead_code,
    reason = "every test binary includes this whole module and uses the part it needs"
)]
pub fn no_record_on_this_runner() -> bool {
    false
}
