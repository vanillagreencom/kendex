//! The compiled-in table of accepted findings against the catalog this
//! repository is: the table is what the catalog warrants right now, or
//! the build fails until it is regenerated and the diff reviewed.

use std::path::{Path, PathBuf};

use kendex_core::quality::Allowance;
use kendex_core::source::source_config;
use kendex_core::source_read::SealedSource;

fn committed_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/quality/allowance.toml")
}

/// The table this catalog warrants, in its file form.
#[allow(
    clippy::expect_used,
    reason = "a catalog that will not open or a table that will not serialize is the test's own fixture, and the panic names which"
)]
fn regenerated() -> String {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let sealed = SealedSource::open(&root).expect("the repository opens as a catalog");
    let config = source_config(&sealed, "kendex").expect("its layout reads");
    let table = Allowance::regenerate(&sealed, &config).expect("its packages read");
    let text = table.to_toml().expect("the table serializes");
    assert_eq!(
        Allowance::parse(&text).expect("the table reads back"),
        table,
        "{text}"
    );
    text
}

/// `cargo test` fails whenever the committed table drifts from what the
/// catalog warrants: a finding nobody accepted, a row nothing raises any
/// more, a package whose hash moved. Regenerate with:
/// `cargo test -p kendex-core -- --ignored regenerate_allowance`
#[test]
fn the_committed_table_is_what_the_catalog_warrants() {
    let committed = std::fs::read_to_string(committed_path()).unwrap_or_default();
    assert_eq!(
        committed,
        regenerated(),
        "crates/core/src/quality/allowance.toml is stale — run: cargo test -p kendex-core -- --ignored regenerate_allowance"
    );
}

#[test]
#[ignore = "writes crates/core/src/quality/allowance.toml in place"]
#[allow(
    clippy::expect_used,
    reason = "the write is the test's one effect, and the panic names it"
)]
fn regenerate_allowance() {
    std::fs::write(committed_path(), regenerated()).expect("the table writes");
}
