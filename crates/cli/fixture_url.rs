//! The one `file://` URL builder the CLI's fixtures share. Kept beside
//! `src/` so cargo does not build it as a test target of its own, and
//! separate from `crates/test_util.rs` because it needs the `url`
//! dev-dependency that only this crate carries — and named for what it
//! holds, so neither include can resolve to the other file by accident.

use std::path::Path;

/// A `file://` URL for a host path, built by something that knows the
/// grammar. Substituting separators is not enough: a path is allowed
/// characters a URL reserves, so a home directory holding a space or a
/// `#` would produce a URL that curl reads as a different address, or as
/// no address at all.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "every test binary includes this whole module and uses the part it needs; a fixture path is absolute"
)]
pub fn file_url(path: &Path) -> String {
    url::Url::from_file_path(path)
        .expect("a fixture path is absolute")
        .to_string()
}
