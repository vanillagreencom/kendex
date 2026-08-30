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

/// `--version` and `--help` never reach dispatch — clap answers them and
/// exits — and they are what a person runs when the card says their command
/// is behind. A bootstrap behind the parse would miss the run most likely to
/// be their first.
#[test]
#[allow(clippy::unwrap_used)]
fn the_forms_clap_answers_itself_record_the_command_too() {
    for form in ["--version", "--help"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = kendex_core::env::Env::host_rooted(&home);

        kendex(&home, &[form]);

        assert!(
            kendex_core::command_update::recorded_command(&env).is_some(),
            "{form} left the command unrecorded at {}",
            env.installed_command_file().display()
        );
    }
}

/// Whether a record is already there is the filesystem's answer, not a
/// read's. The distinguishing case is a record this build cannot parse:
/// `recorded_command` reads it as absent, so a first run that decided by
/// reading would write over it, and two copies starting together would
/// both decide the same way and leave the record naming whichever finished
/// last. Refusing the name that is taken cannot do that.
///
/// The unparseable record itself stays; `kendex update` rewrites it,
/// because that is the run replacing the bytes. Until then the app reads
/// no record and refuses the command, which is the safe direction.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_already_there_is_not_written_over_by_a_first_run() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let file = env.installed_command_file();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "half a record").unwrap();
    assert_eq!(
        kendex_core::command_update::recorded_command(&env),
        None,
        "the fixture parses, so a read could tell it was there and this proves nothing"
    );
    let ours = home.join("ours/kendex");
    fs::create_dir_all(ours.parent().unwrap()).unwrap();
    fs::write(&ours, b"the kendex that ran").unwrap();

    kendex_core::command_update::record_first_run(&env, &ours).unwrap();

    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        "half a record",
        "a first run wrote over a record that was already there"
    );

    // And nothing was read to reach that answer. Every run comes through
    // here, `--version` and `--help` among them, so the steady state has
    // to cost a look at one name — not a read and a hash of the whole
    // executable. A running path that is not there at all says so: the
    // read that would have failed never happens.
    kendex_core::command_update::record_first_run(&env, &home.join("no/such/kendex")).unwrap();
    assert!(
        !home.join("no/such/kendex").exists(),
        "the fixture exists, so this proves nothing"
    );
}

/// Concurrent first runs leave one whole record and nothing beside it.
///
/// Not a proof of the ordering — two threads rarely land inside the window
/// that would show it, and a version deciding by reading passes this too.
/// What it does hold is the staging: the file each writer prepares has to
/// be its own, and a name built from the process id alone is not, which is
/// how the pair came to overwrite each other's staged copy the first time
/// this ran.
#[test]
#[allow(clippy::unwrap_used)]
fn concurrent_first_runs_leave_one_whole_record() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let theirs = home.join("theirs/kendex");
    let second = home.join("second/kendex");
    for (path, bytes) in [
        (&theirs, b"the kendex they installed".as_slice()),
        (&second, b"a second copy of kendex".as_slice()),
    ] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    let both = std::thread::scope(|scope| {
        let a = scope.spawn(|| kendex_core::command_update::record_first_run(&env, &theirs));
        let b = scope.spawn(|| kendex_core::command_update::record_first_run(&env, &second));
        (a.join().unwrap(), b.join().unwrap())
    });
    assert!(both.0.is_ok() && both.1.is_ok(), "{both:?}");

    // Whichever won, the record names one of them whole and nothing was
    // left staged beside it.
    let recorded = kendex_core::command_update::recorded_command(&env).unwrap();
    assert!(
        recorded.path == theirs || recorded.path == second,
        "the record names {}",
        recorded.path.display()
    );
    assert_eq!(
        recorded.digest,
        kendex_core::hash::sha256_hex(&fs::read(&recorded.path).unwrap()),
        "the record names bytes other than the ones at the path it names"
    );
    let beside: Vec<_> = fs::read_dir(env.installed_command_file().parent().unwrap())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
        .filter(|name| name.to_string_lossy().starts_with("installed-command."))
        .collect();
    assert!(beside.is_empty(), "staged files left behind: {beside:?}");
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
