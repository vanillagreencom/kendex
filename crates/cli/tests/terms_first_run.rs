//! The one line a first run says about the terms, and the record that
//! stops it saying it again.
//!
//! Asserted against the built binary rather than the function behind it:
//! the line has to reach a person running a verb, and a test that called
//! the seam would pass while the wiring in `main` said nothing.
//!
//! `list` is the verb throughout because it has nothing to do with the
//! terms — a line printed there is a line printed by any run.
#![cfg(unix)]

#[path = "pty.rs"]
mod pty;
#[path = "../../test_util.rs"]
mod test_util;

use std::path::Path;
use std::process::Command;

use kendex_core::env::Env;
use kendex_core::legal::LEGAL;
use test_util::rooted;

fn command(home: &Path) -> Command {
    let mut run = Command::new(env!("CARGO_BIN_EXE_kendex"));
    run.current_dir(home)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .arg("list");
    run
}

/// What a person at a terminal is sent.
fn on_a_terminal(home: &Path) -> String {
    pty::sent_to_a_terminal(command(home))
}

/// What a pipe is sent — a script, a session hook, another program.
#[allow(clippy::expect_used)]
fn through_a_pipe(home: &Path) -> String {
    let run = command(home).output().expect("kendex binary runs");
    String::from_utf8_lossy(&run.stderr).into_owned()
}

#[allow(clippy::expect_used)]
fn recorded(home: &Path) -> Option<kendex_core::legal::TermsAcceptance> {
    kendex_core::settings::load(&Env::host_rooted(home))
        .expect("settings read")
        .terms
}

#[allow(clippy::expect_used)]
fn write_settings(home: &Path, version: u32, accepted_at: &str) {
    let path = Env::host_rooted(home).settings_file();
    std::fs::create_dir_all(path.parent().expect("settings file has a parent"))
        .expect("settings directory");
    std::fs::write(
        path,
        format!("schema = 1\n\n[terms]\nversion = {version}\naccepted-at = \"{accepted_at}\"\n"),
    )
    .expect("settings written");
}

/// The first run says it and records the version; the second says nothing
/// and leaves the record where it is.
#[test]
fn the_first_run_says_it_once_and_records_the_version() {
    let tmp = tempfile::tempdir().expect("a home to run in");
    // The canonical root, and the same spelling handed to the run: a
    // settings path read back under another spelling reads an empty file.
    let home = rooted(&tmp);

    let first = on_a_terminal(&home);
    assert!(first.contains(LEGAL.terms_url), "first run: {first:?}");
    assert!(first.contains(LEGAL.privacy_url), "first run: {first:?}");
    let record = recorded(&home).expect("the first run records");
    assert_eq!(record.version, LEGAL.version);

    let second = on_a_terminal(&home);
    assert!(!second.contains(LEGAL.terms_url), "second run: {second:?}");
    assert_eq!(recorded(&home), Some(record));
}

/// The record carries a version so a later one can ask again. A machine
/// holding an older acceptance is told, and its record moves up.
#[test]
fn a_record_from_an_older_version_is_asked_again() {
    let tmp = tempfile::tempdir().expect("a home to run in");
    // The canonical root, and the same spelling handed to the run: a
    // settings path read back under another spelling reads an empty file.
    let home = rooted(&tmp);
    write_settings(&home, LEGAL.version - 1, "2020-01-01T00:00:00Z");

    let sent = on_a_terminal(&home);
    assert!(sent.contains(LEGAL.terms_url), "{sent:?}");
    assert_eq!(
        recorded(&home).map(|record| record.version),
        Some(LEGAL.version)
    );
}

/// Saying nothing is the acceptance working, not the line being broken:
/// with the current version on record the run is silent, and the date
/// already there is not moved by it.
#[test]
fn a_current_record_is_not_asked_again() {
    let tmp = tempfile::tempdir().expect("a home to run in");
    // The canonical root, and the same spelling handed to the run: a
    // settings path read back under another spelling reads an empty file.
    let home = rooted(&tmp);
    write_settings(&home, LEGAL.version, "2026-09-06T00:00:00Z");

    let sent = on_a_terminal(&home);
    assert!(!sent.contains(LEGAL.terms_url), "{sent:?}");
    assert_eq!(
        recorded(&home).map(|record| record.accepted_at),
        Some("2026-09-06T00:00:00Z".to_owned())
    );
}

/// A pipe has no reader. `kendex check`'s whole contract with the session
/// hooks is an exit code over a quiet stderr, so a notice written there
/// would be read as the check having something to say — and the person
/// whose first runs all went through a script is still asked the first
/// time they are at a terminal, which is why nothing is recorded either.
#[test]
fn a_run_nobody_is_watching_says_nothing_and_records_nothing() {
    let tmp = tempfile::tempdir().expect("a home to run in");
    // The canonical root, and the same spelling handed to the run: a
    // settings path read back under another spelling reads an empty file.
    let home = rooted(&tmp);

    let piped = through_a_pipe(&home);
    assert!(!piped.contains(LEGAL.terms_url), "{piped:?}");
    assert_eq!(recorded(&home), None);

    let sent = on_a_terminal(&home);
    assert!(sent.contains(LEGAL.terms_url), "{sent:?}");
    assert!(recorded(&home).is_some());
}
