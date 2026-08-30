//! That the record the desktop app reads is written by running this
//! command, whichever verb was run.
//!
//! Asserted against the built binary rather than the function behind it:
//! the defect was never that the write was wrong, it was that nothing
//! called it outside `kendex update`, and a test that calls the seam
//! itself would have passed throughout.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

/// An install made before the record existed has none, and its owner has
/// no reason to reach for `update` rather than any other verb. Whichever
/// they run, the app can carry the command across afterwards.
///
/// `verify` is the verb here because it is the one with nothing to do with
/// updating: a record written by that run is a record written by any run.
#[test]
#[allow(clippy::unwrap_used)]
fn any_verb_records_the_command_an_install_never_recorded() {
    let tmp = tempfile::tempdir().unwrap();
    // The canonical root, and the same one handed to the run: a resolver
    // asked about a different spelling of that directory reads an empty one.
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        None,
        "the fixture starts with a record, so this proves nothing"
    );

    kendex(&home, &["verify"]);

    let recorded = kendex_core::command_update::recorded_command(&env)
        .unwrap_or_else(|| panic!("no record at {}", env.installed_command_file().display()));
    assert_eq!(
        recorded.path,
        std::fs::canonicalize(env!("CARGO_BIN_EXE_kendex")).unwrap(),
        "the record names a file other than the one that ran"
    );
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(env!("CARGO_BIN_EXE_kendex")).unwrap()),
        "the record names bytes other than the ones that ran"
    );
}

/// The record a person's install already has is not taken off it by a
/// second kendex they happen to run once. Left unguarded, the app would
/// carry across the copy nobody uses and leave the one they do.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_does_not_take_the_record_off_another_install() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let theirs = home.join("bin/kendex");
    fs::create_dir_all(theirs.parent().unwrap()).unwrap();
    fs::write(&theirs, b"the kendex install.sh put here").unwrap();
    kendex_core::command_update::record_installed(&env, &theirs).unwrap();

    kendex(&home, &["verify"]);

    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(theirs),
        "a run repointed a record it did not write"
    );
}
