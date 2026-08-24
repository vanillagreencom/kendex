//! A lint tool the commit-time guards run sees no git redirect the parent
//! inherited. Under a git hook the parent carries `GIT_INDEX_FILE` and
//! friends, and a build script or formatter reading them would judge the
//! hook's temporary index instead of the caller's repository.
#![cfg(unix)]

use kendex_core::process::Hardened;

const INNER: &str = "KENDEX_TEST_LINT_ENV_INNER";

/// The redirect has to come from the parent's environment, which a test
/// cannot set beside its siblings without racing them. The outer run
/// re-enters this test binary with the variables set and judges the
/// inner run's verdict.
#[test]
#[allow(clippy::unwrap_used)]
fn a_lint_tool_sees_no_inherited_git_redirect() {
    if std::env::var_os(INNER).is_none() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "a_lint_tool_sees_no_inherited_git_redirect",
                "--nocapture",
            ])
            .env(INNER, "1")
            .env("GIT_DIR", "/nowhere/.git")
            .env("GIT_WORK_TREE", "/nowhere")
            .env("GIT_INDEX_FILE", "/nowhere/index.tmp")
            .status()
            .unwrap();
        assert!(
            status.success(),
            "the inner run failed; see its output above"
        );
        return;
    }
    // The inner run only proves anything if the redirect is really set
    // on this side of the spawn.
    assert!(std::env::var_os("GIT_INDEX_FILE").is_some());

    let tmp = tempfile::tempdir().unwrap();
    let tool = tmp.path().join("tool");
    std::fs::write(&tool, "#!/bin/sh\nenv > env.log\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();

    let output = Hardened::lint_tool(&tool, &[], tmp.path()).run().unwrap();
    assert!(output.status.success());
    let env = std::fs::read_to_string(tmp.path().join("env.log")).unwrap();
    for variable in ["GIT_DIR=", "GIT_WORK_TREE=", "GIT_INDEX_FILE="] {
        assert!(
            !env.contains(variable),
            "{variable} reached the tool:\n{env}"
        );
    }
    assert!(env.contains("GIT_TERMINAL_PROMPT=0"), "{env}");
}
