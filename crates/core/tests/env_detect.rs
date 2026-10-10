use crate::test_util::{exact_test, fixture_env, rooted};
use kendex_core::env::{Env, sandboxed};
use std::path::PathBuf;
use std::process::Command;

/// Portable installs and CLI fixtures must select their roots before OS
/// discovery. The child has conflicting OS variables and no inherited env.
#[test]
#[allow(clippy::unwrap_used)]
fn an_explicit_root_outranks_os_directories() {
    const INNER: &str = "KENDEX_TEST_ROOT_OVERRIDE";
    if std::env::var_os(INNER).is_some() {
        let home = PathBuf::from(std::env::var_os("KENDEX_REAL_HOME").unwrap());
        let expected = Env::host_rooted(&home);
        let detected = Env::detect().unwrap();
        assert_eq!(detected.home, home);
        assert_eq!(detected.real_home(), home);
        assert_eq!(detected.settings_file(), expected.settings_file());
        assert_eq!(
            detected.app_update_cache_file(),
            expected.app_update_cache_file()
        );
        assert_eq!(
            detected.installed_command_file(),
            expected.installed_command_file()
        );
        assert_eq!(detected.cwd(), Some(home.as_path()));
        assert_eq!(detected.temp_dir(), expected.temp_dir());
        assert_eq!(detected.var("CODEX_HOME"), Some("explicit-codex-root"));
        assert!(!sandboxed());
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let home = root.join("portable home");
    std::fs::create_dir(&home).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            &exact_test(module_path!(), "an_explicit_root_outranks_os_directories"),
            "--nocapture",
        ])
        .current_dir(&home)
        .env_clear()
        .envs(fixture_env(&home))
        .env("HOME", root.join("other-home"))
        .env("KENDEX_REAL_HOME", &home)
        .env("XDG_CONFIG_HOME", root.join("other-config"))
        .env("XDG_CACHE_HOME", root.join("other-cache"))
        .env("XDG_DATA_HOME", root.join("other-data"))
        .env("USERPROFILE", root.join("other-profile"))
        .env("APPDATA", root.join("other-roaming"))
        .env("LOCALAPPDATA", root.join("other-local"))
        .env("CODEX_HOME", "explicit-codex-root")
        .env(INNER, "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("1 passed"),
        "{output:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn fixture_data_and_trash_stay_inside_each_home() {
    const INNER: &str = "KENDEX_TEST_FIXTURE_TRASH";
    if std::env::var_os(INNER).is_some() {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap());
        let detected = Env::detect().unwrap();
        assert!(detected.installed_command_file().starts_with(&home));
        assert!(detected.trash_dir().starts_with(&home));
        return;
    }

    let fixtures = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let launch = |home: &std::path::Path, system: bool| {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                &exact_test(
                    module_path!(),
                    "fixture_data_and_trash_stay_inside_each_home",
                ),
            ])
            .env_clear()
            .envs(fixture_env(home))
            .env("XDG_DATA_HOME", home.parent().unwrap())
            .env(INNER, "1");
        if system {
            command.env("KENDEX_REAL_HOME", "1");
        }
        command.spawn().unwrap()
    };
    let mut children = fixtures
        .each_ref()
        .map(|fixture| launch(&rooted(fixture), false));
    for child in &mut children {
        assert!(child.wait().unwrap().success());
    }
    // The previous system-home opt-in must fail the same containment checks.
    assert!(
        !launch(&rooted(&fixtures[0]), true)
            .wait()
            .unwrap()
            .success()
    );
}
