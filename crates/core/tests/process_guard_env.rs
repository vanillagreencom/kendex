//! What the two delegated-script constructors do with git's environment.
//!
//! `guard_hook` is the one child this crate launches that must NOT be
//! scrubbed. It is a git hook body: `git commit` exports `GIT_INDEX_FILE`
//! naming the temporary index of the commit being made, and a chain that
//! could not see it would judge the wrong snapshot and pass a commit nobody
//! checked.
//!
//! `guard_script` is its opposite and runs the package's management scripts
//! — arming, disarming, reporting. Those run git themselves against the
//! repository they were pointed at, and an inherited redirect outranks that
//! on the command line: it would write hooks into one repository while
//! reporting about another. The two are pinned side by side, because the
//! only thing separating them is which constructor a call site picked.
#![cfg(unix)]

use kendex_core::process::Hardened;
use std::sync::{Mutex, OnceLock};

const INNER: &str = "KENDEX_TEST_GUARD_ENV_INNER";
static SCRIPT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn script_lock() -> std::sync::MutexGuard<'static, ()> {
    SCRIPT_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The redirect has to come from the parent's environment, which a test
/// cannot set beside its siblings without racing them. The outer run
/// re-enters this test binary with the variables set and judges the
/// inner run's verdict.
#[test]
#[allow(clippy::unwrap_used)]
fn a_guard_hook_sees_the_index_git_named() {
    // A fork can inherit a sibling test's script write descriptor until exec.
    let _guard = script_lock();
    if std::env::var_os(INNER).is_none() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "a_guard_hook_sees_the_index_git_named",
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
    let script = tmp.path().join("pre-commit");
    std::fs::write(&script, "#!/bin/sh\nenv > env.log\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let output = Hardened::guard_hook(&script, Vec::new(), tmp.path())
        .run()
        .unwrap();
    assert!(output.status.success());
    let env = std::fs::read_to_string(tmp.path().join("env.log")).unwrap();
    for variable in [
        "GIT_DIR=/nowhere/.git",
        "GIT_WORK_TREE=/nowhere",
        "GIT_INDEX_FILE=/nowhere/index.tmp",
    ] {
        assert!(
            env.contains(variable),
            "{variable} did not reach the hook body:\n{env}"
        );
    }

    // The management scripts are not hook bodies and get the scrub, so an
    // inherited redirect cannot send an installer at another repository.
    std::fs::remove_file(tmp.path().join("env.log")).unwrap();
    let output = Hardened::guard_script(&script, Vec::new(), tmp.path())
        .run()
        .unwrap();
    assert!(output.status.success());
    let env = std::fs::read_to_string(tmp.path().join("env.log")).unwrap();
    for variable in ["GIT_DIR=", "GIT_WORK_TREE=", "GIT_INDEX_FILE="] {
        assert!(
            !env.contains(variable),
            "{variable} reached the management script:\n{env}"
        );
    }
}

/// The chain's own words come back whole, on both streams, with the
/// package's exit status relayed rather than reinterpreted.
#[test]
#[allow(clippy::unwrap_used)]
fn a_guard_hook_relays_its_verdict() {
    let _guard = script_lock();
    let tmp = tempfile::tempdir().unwrap();
    let script = tmp.path().join("pre-commit");
    std::fs::write(
        &script,
        "#!/bin/sh\necho 'todo-ban FAIL'\necho 'note on stderr' >&2\nexit 1\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let output = Hardened::guard_hook(&script, Vec::new(), tmp.path())
        .run()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stdout).contains("todo-ban FAIL"));
    assert!(String::from_utf8_lossy(&output.stderr).contains("note on stderr"));
}
