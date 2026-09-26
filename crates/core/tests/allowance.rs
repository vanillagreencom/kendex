//! The compiled-in table of accepted findings against the catalog this
//! repository is: every row still names a finding the catalog raises, at
//! the text, line and message it has now, or the build fails until the
//! table is refreshed and the diff reviewed.

use std::path::{Path, PathBuf};

use kendex_core::quality::Allowance;
use kendex_core::source::source_config;
use kendex_core::source_read::SealedSource;

fn committed_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/quality/allowance.toml")
}

/// The committed table with every row read again off this catalog, in
/// its file form.
#[allow(
    clippy::expect_used,
    reason = "a catalog that will not open or a table that will not serialize is the test's own fixture, and the panic names which"
)]
fn regenerated() -> String {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let sealed = SealedSource::open(&root).expect("the repository opens as a catalog");
    let config = source_config(&sealed, "kendex").expect("its layout reads");
    let committed =
        Allowance::parse(&std::fs::read_to_string(committed_path()).unwrap_or_default())
            .expect("the committed table reads");
    let table = committed
        .refreshed(&sealed, &config)
        .expect("every accepted finding is still raised");
    let text = table.to_toml().expect("the table serializes");
    assert_eq!(
        Allowance::parse(&text).expect("the table reads back"),
        table,
        "{text}"
    );
    text
}

/// `cargo test` fails whenever a listed finding moved, changed its
/// message, or sits in a file whose text changed, and the refresh itself
/// refuses a listed finding the catalog no longer raises or a file that
/// raises more of that rule than the table lists. Refresh with:
/// `cargo test -p kendex-core -- --ignored regenerate_allowance`
#[test]
fn the_committed_table_is_current_for_every_row_it_holds() {
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
