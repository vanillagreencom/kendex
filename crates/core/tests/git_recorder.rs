//! The recorder forwards to the Git selected by the parent, with that
//! installation's helpers available even in the isolated child.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;

use crate::test_util::{git_recorded_test, reexecute_test, rooted};

#[test]
#[allow(clippy::unwrap_used)]
fn recorder_forwards_to_parent_path_git_and_its_helpers() {
    const FUNCTION: &str = "recorder_forwards_to_parent_path_git_and_its_helpers";
    const PARENT: &str = "KENDEX_TEST_RECORDER_PARENT";
    if std::env::var_os(PARENT).is_some() {
        assert!(git_recorded_test(module_path!(), FUNCTION).is_none());
        return;
    }
    if std::env::var_os("KENDEX_TEST_HISTORY_INNER").is_some() {
        let trace = git_recorded_test(module_path!(), FUNCTION).unwrap();
        let output = std::process::Command::new("git")
            .arg("--version")
            .env_clear()
            .envs(
                [
                    "PATH",
                    "KENDEX_TEST_HISTORY_GIT",
                    "KENDEX_TEST_HISTORY_TRACE",
                ]
                .map(|key| (key, std::env::var_os(key).unwrap())),
            )
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert_eq!(output.stdout, b"fixture-git-helper:--version\n");
        assert_eq!(std::fs::read(trace).unwrap(), b"--version\0\0");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let bin = root.join("Git installation's bin");
    std::fs::create_dir(&bin).unwrap();
    for (name, script) in [
        ("git", "#!/bin/sh\nexec fixture-git-helper \"$@\"\n"),
        (
            "fixture-git-helper",
            "#!/bin/sh\n\
             printf '%s\\0' \"$@\" > \"$0.forwarded\" || exit 1\n\
             printf 'fixture-git-helper:%s\\n' \"$@\"\n",
        ),
    ] {
        let executable = bin.join(name);
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let output = reexecute_test(
        module_path!(),
        FUNCTION,
        &[(PARENT, "1"), ("PATH", bin.to_str().unwrap())],
    )
    .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        std::fs::read(bin.join("fixture-git-helper.forwarded")).unwrap(),
        b"--version\0"
    );
}
