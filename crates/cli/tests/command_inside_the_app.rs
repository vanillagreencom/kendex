//! A `kendex` command a downloadable installer put inside the desktop app
//! is the app's to update, and the built binary has to know it from where
//! it is running: `kendex update` stops with that answer and touches
//! nothing, and no verb writes the first-run record that would tell the
//! app to carry the command across on its own.
//!
//! Asserted against the built binary rather than the judge behind it,
//! because both sites read the running executable's own path, which no
//! call into the library can stand in for. The binary is copied into each
//! layout the installers produce: a macOS bundle's `Contents/MacOS`, and
//! the Windows setup's `bin` beside the app's own executable. The Windows
//! layout is judged by shape and by a sibling with an execute bit, so it is
//! reachable on every unix host, which is where these run.
#![cfg(unix)]

use crate::test_util;
use test_util::{no_record_on_this_runner, rooted};

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// The command copied to `at`, made runnable, under a fixture home whose
/// only feed is a file that is not there: a run that reached the feed
/// fails loudly instead of passing as one that never asked.
#[allow(clippy::expect_used)]
fn run_from(home: &Path, at: &Path, args: &[&str]) -> Output {
    fs::create_dir_all(at.parent().expect("a layout has a directory")).expect("layout created");
    fs::copy(env!("CARGO_BIN_EXE_kendex"), at).expect("the built command copies");
    Command::new(at)
        .current_dir(home)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env(
            "KENDEX_UPDATE_FEED",
            format!("file://{}/no-feed-here.json", home.display()),
        )
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .args(args)
        .output()
        .expect("kendex binary runs")
}

/// The two layouts, each under `root`: the sidecar of a bundle, and the
/// setup's `bin` with the app's executable beside it.
#[allow(clippy::expect_used)]
fn layouts(root: &Path) -> Vec<(&'static str, PathBuf)> {
    let install_dir = root.join("kendex");
    fs::create_dir_all(&install_dir).expect("install dir created");
    let app = install_dir.join("kendex-app.exe");
    fs::write(&app, b"").expect("the app's executable is written");
    fs::set_permissions(&app, fs::Permissions::from_mode(0o755)).expect("made runnable");
    vec![
        (
            "the macOS bundle",
            root.join("kendex.app/Contents/MacOS/kendex"),
        ),
        ("the Windows setup", install_dir.join("bin/kendex")),
    ]
}

/// `kendex update` answers with the app, exits clean, and neither records
/// the command nor reads the feed. A run that fetched would fail on the
/// missing feed, so the clean exit is what proves nothing was asked for.
#[test]
#[allow(clippy::unwrap_used)]
fn update_from_inside_the_app_stops_with_the_app_and_touches_nothing() {
    if no_record_on_this_runner() {
        return;
    }
    for (label, at) in layouts(&rooted(&tempfile::tempdir().unwrap())) {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = kendex_core::env::Env::host_rooted(&home);

        let run = run_from(&home, &at, &["update"]);

        let stdout = String::from_utf8_lossy(&run.stdout);
        assert_eq!(
            run.status.code(),
            Some(0),
            "{label}: {stdout}{}",
            String::from_utf8_lossy(&run.stderr)
        );
        assert!(
            stdout.contains("kendex desktop app"),
            "{label}: the run did not answer with the app: {stdout}"
        );
        assert_eq!(
            kendex_core::command_update::recorded_command(&env),
            None,
            "{label}: a command inside the app was recorded"
        );
    }
}

/// Any verb from inside the app leaves no first-run record, where the
/// same binary anywhere else writes one. The contrast is the control that
/// the fixture reaches the bootstrap at all.
#[test]
#[allow(clippy::unwrap_used)]
fn no_verb_records_a_command_that_sits_inside_the_app() {
    if no_record_on_this_runner() {
        return;
    }
    let root = rooted(&tempfile::tempdir().unwrap());
    for (label, at) in layouts(&root) {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = kendex_core::env::Env::host_rooted(&home);

        run_from(&home, &at, &["--version"]);

        assert_eq!(
            kendex_core::command_update::recorded_command(&env),
            None,
            "{label}: a command inside the app was recorded"
        );
    }

    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home);
    let loose = root.join("bin/kendex");
    run_from(&home, &loose, &["--version"]);
    assert_eq!(
        kendex_core::command_update::recorded_command(&env).map(|record| record.path),
        Some(loose),
        "a command on its own records itself, so the layouts above were what stopped the record"
    );
}
