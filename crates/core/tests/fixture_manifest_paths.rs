//! The control on the helper every manifest fixture writes its source path
//! with. A fixture that picks TOML's delimiters itself has been wrong twice
//! — a Windows separator is the escape character a basic string reads, and
//! an apostrophe closes a literal string — so what the helper renders has to
//! parse back to the path it was handed, for the characters a real home
//! directory holds.

use std::path::{Path, PathBuf};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

#[allow(clippy::unwrap_used)]
fn round_trip(path: &Path) -> String {
    let manifest = format!("schema = 6\n\n[sources.cat]\n{}\n", source_path(path));
    let parsed: toml::Table = toml::from_str(&manifest)
        .unwrap_or_else(|e| panic!("{} did not parse: {e}\n{manifest}", path.display()));
    parsed["sources"]["cat"]["path"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// An apostrophe is ordinary in a home directory — the CLI suite installs
/// under `o'brien` on purpose — and a backslash is how half the hosts this
/// runs on spell a separator. Neither may reach TOML as a delimiter.
#[test]
#[allow(clippy::unwrap_used)]
fn a_path_holding_either_toml_delimiter_parses_back_to_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let real = root.join("o'brien").join("catalog");
    std::fs::create_dir_all(&real).unwrap();
    assert_eq!(round_trip(&real), real.display().to_string());

    for spelling in [
        r"C:\Users\RUNNER~1\AppData\Local\Temp\catalog",
        r"C:\Users\o'brien\catalog",
        r"C:\it's\a'''trap\catalog",
        "/home/o'brien/catalog",
    ] {
        let path = PathBuf::from(spelling);
        assert_eq!(round_trip(&path), spelling);
    }
}
