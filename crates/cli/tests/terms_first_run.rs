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

#[path = "support/pty.rs"]
mod pty;
#[path = "../../test_util.rs"]
mod test_util;

use std::path::Path;
use std::process::Command;

use kendex_core::env::Env;
use kendex_core::legal::LEGAL;
use test_util::rooted;

fn command_with(home: &Path, arg: &str) -> Command {
    let mut run = Command::new(env!("CARGO_BIN_EXE_kendex"));
    run.current_dir(home)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .arg(arg);
    run
}

/// `list` is the ordinary verb the cases below run: it has nothing to do
/// with the terms, so a line printed there is a line printed by any run.
fn command(home: &Path) -> Command {
    command_with(home, "list")
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

/// Whether a run at a terminal says it, by what the record already holds.
/// Nothing on record is the first run: it says it once and records the
/// version, so the next run finds the current record and says nothing. A
/// record from an older version is asked again and moves up, because the
/// record carries a version so a later one can ask. A current record is the
/// acceptance working, not the line being broken: the run is silent and the
/// date already there is not moved by it. One row per prior record.
#[test]
fn a_terminal_is_told_once_per_version_of_the_terms() {
    type Row = (
        &'static str,
        Option<(u32, &'static str)>,
        bool,
        Option<&'static str>,
    );
    let rows: [Row; 3] = [
        ("nothing on record", None, true, None),
        (
            "an older version on record",
            Some((LEGAL.version - 1, "2020-01-01T00:00:00Z")),
            true,
            None,
        ),
        (
            "the current version on record",
            Some((LEGAL.version, "2026-09-06T00:00:00Z")),
            false,
            Some("2026-09-06T00:00:00Z"),
        ),
    ];
    for (what, prior, says, date_kept) in rows {
        let tmp = tempfile::tempdir().expect("a home to run in");
        // The canonical root, and the same spelling handed to the run: a
        // settings path read back under another spelling reads an empty file.
        let home = rooted(&tmp);
        if let Some((version, accepted_at)) = prior {
            write_settings(&home, version, accepted_at);
        }

        let sent = on_a_terminal(&home);

        assert_eq!(sent.contains(LEGAL.terms_url), says, "{what}: {sent:?}");
        assert_eq!(sent.contains(LEGAL.privacy_url), says, "{what}: {sent:?}");
        let record = recorded(&home).unwrap_or_else(|| panic!("{what}: nothing recorded"));
        assert_eq!(record.version, LEGAL.version, "{what}");
        if let Some(date) = date_kept {
            assert_eq!(record.accepted_at, date, "{what}: the date was moved");
        }
        if says {
            // The next run finds the record and says nothing.
            let again = on_a_terminal(&home);
            assert!(
                !again.contains(LEGAL.terms_url),
                "{what}, second run: {again:?}"
            );
            assert_eq!(
                recorded(&home),
                Some(record),
                "{what}: the second run moved the record"
            );
        }
    }
}

/// The forms clap answers itself, which is why this runs before the parse:
/// `--version` and `--help` never reach dispatch, and either is as likely
/// to be someone's first run as any verb.
#[test]
fn the_forms_clap_answers_itself_say_it_too() {
    for form in ["--version", "--help"] {
        let tmp = tempfile::tempdir().expect("a home to run in");
        let home = rooted(&tmp);
        let sent = pty::sent_to_a_terminal(command_with(&home, form));
        assert!(sent.contains(LEGAL.terms_url), "{form}: {sent:?}");
        assert_eq!(
            recorded(&home).map(|record| record.version),
            Some(LEGAL.version),
            "{form}"
        );
    }
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
    assert_eq!(
        recorded(&home).map(|record| record.version),
        Some(LEGAL.version)
    );
}
