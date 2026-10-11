//! A successful CLI run with redirected stderr keeps the registry notice quiet.

use std::fs;
use std::process::Command;

use crate::test_util::{fixture_env, rooted};
use kendex_core::env::Env;
use kendex_core::settings::AppSettings;

#[cfg(unix)]
#[test]
#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn a_terminal_notice_follows_success_and_the_latest_disk_schema() {
    use crate::pty;

    let tmp = tempfile::tempdir().expect("fixture home");
    let home = rooted(&tmp);
    let env = Env::host_rooted(&home);
    let project = home.join("older");
    fs::create_dir(&project).expect("registered project");
    let manifest = Env::project_manifest_file(&project);
    fs::write(&manifest, "schema = 6\n").expect("older manifest");
    let settings = AppSettings {
        projects: vec![project],
        ..Default::default()
    };
    fs::create_dir_all(env.settings_file().parent().expect("settings parent"))
        .expect("settings directory");
    fs::write(
        env.settings_file(),
        toml::to_string(&settings).expect("settings serialize"),
    )
    .expect("settings fixture");
    let rows: &[(&[&str], bool, bool)] = &[
        (&["list"], true, true),
        (&["list"], true, true),
        (&["show", "skill", "missing", "--global"], false, false),
        (&["--help"], true, false),
        (&["--version"], true, false),
    ];
    for (args, success, notice) in rows {
        let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
        command
            .args(*args)
            .current_dir(&home)
            .env_clear()
            .envs(fixture_env(&home))
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("KENDEX_UI", "plain");
        let output = pty::sent_to_a_terminal(command, b"");
        assert_eq!(output.status.success(), *success, "{args:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            stderr.contains("older kendex.toml"),
            *notice && !kendex_core::privilege::acting_as_root(),
            "{args:?}"
        );
    }
    fs::create_dir_all(env.global_manifest_file().parent().expect("global parent"))
        .expect("global directory");
    fs::write(env.global_manifest_file(), "schema = 8\n").expect("unreadable global schema");
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(["check", "--scope", "global", "--report-only", "--quiet"])
        .current_dir(&home)
        .env_clear()
        .envs(fixture_env(&home))
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain");
    let output = pty::sent_to_a_terminal(command, b"");
    assert!(!output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("older kendex.toml"));
    fs::remove_file(env.global_manifest_file()).expect("remove refused global fixture");
    fs::write(&manifest, "schema = 7\n").expect("upgraded manifest");
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .arg("list")
        .current_dir(&home)
        .env_clear()
        .envs(fixture_env(&home))
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain");
    let output = pty::sent_to_a_terminal(command, b"");
    assert!(output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("older kendex.toml"));
}

#[test]
#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn redirected_stderr_has_no_outdated_project_notice() {
    let tmp = tempfile::tempdir().expect("fixture home");
    let home = rooted(&tmp);
    let env = Env::host_rooted(&home);
    let project = home.join("older");
    fs::create_dir(&project).expect("registered project");
    fs::write(Env::project_manifest_file(&project), "schema = 6\n").expect("older manifest");
    let settings = AppSettings {
        projects: vec![project.clone()],
        ..Default::default()
    };
    fs::create_dir_all(env.settings_file().parent().expect("settings parent"))
        .expect("settings directory");
    fs::write(
        env.settings_file(),
        toml::to_string(&settings).expect("settings serialize"),
    )
    .expect("settings fixture");
    assert_eq!(
        kendex_core::manifest::outdated_projects(&env),
        vec![project]
    );

    let output = Command::new(env!("CARGO_BIN_EXE_kendex"))
        .arg("list")
        .current_dir(&home)
        .env_clear()
        .envs(fixture_env(&home))
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("KENDEX_UI", "plain")
        .output()
        .expect("CLI runs");
    assert!(output.status.success());
    // KEN-3682 explicitly requires silence for this human notice on a pipe.
    assert!(!String::from_utf8_lossy(&output.stderr).contains("older kendex.toml"));
}
