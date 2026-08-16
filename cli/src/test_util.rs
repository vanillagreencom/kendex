//! Shared test helpers. Tests that need sandboxed global config paths use
//! thread-local overrides instead of mutating process-global environment.

#![cfg(test)]

use std::cell::RefCell;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::path::{Path, PathBuf};
use std::thread::LocalKey;

thread_local! {
    static PI_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static CODEX_HOME_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static PROJECT_ROOT_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static HOME_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static CONFIG_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

pub(crate) fn pi_dir_override() -> Option<PathBuf> {
    PI_DIR_OVERRIDE.with(|slot| slot.borrow().clone())
}

pub(crate) fn codex_home_override() -> Option<PathBuf> {
    CODEX_HOME_OVERRIDE.with(|slot| slot.borrow().clone())
}

pub(crate) fn project_root_override() -> Option<PathBuf> {
    PROJECT_ROOT_OVERRIDE.with(|slot| slot.borrow().clone())
}

pub(crate) fn home_dir_override() -> Option<PathBuf> {
    HOME_DIR_OVERRIDE.with(|slot| slot.borrow().clone())
}

pub(crate) fn config_dir_override() -> Option<PathBuf> {
    CONFIG_DIR_OVERRIDE.with(|slot| slot.borrow().clone())
}

/// Run `body` with the global Pi dir redirected to `pi_dir` for the current
/// test thread, restoring the previous override afterwards.
pub(crate) fn with_pi_dir<R>(pi_dir: &Path, body: impl FnOnce() -> R) -> R {
    with_path_override(&PI_DIR_OVERRIDE, pi_dir, body)
}

/// Run `body` with the Codex home redirected to `codex_home` for the current
/// test thread, restoring the previous override afterwards.
pub(crate) fn with_codex_home<R>(codex_home: &Path, body: impl FnOnce() -> R) -> R {
    with_path_override(&CODEX_HOME_OVERRIDE, codex_home, body)
}

/// Run `body` with the project root redirected to `project_root` for the
/// current test thread, restoring the previous override afterwards.
pub(crate) fn with_project_root<R>(project_root: &Path, body: impl FnOnce() -> R) -> R {
    with_path_override(&PROJECT_ROOT_OVERRIDE, project_root, body)
}

/// Run `body` with home/config dirs redirected for the current test thread.
pub(crate) fn with_home_and_config<R>(
    home_dir: &Path,
    config_dir: &Path,
    body: impl FnOnce() -> R,
) -> R {
    with_path_override(&HOME_DIR_OVERRIDE, home_dir, || {
        with_path_override(&CONFIG_DIR_OVERRIDE, config_dir, body)
    })
}

fn with_path_override<R>(
    slot: &'static LocalKey<RefCell<Option<PathBuf>>>,
    value: &Path,
    body: impl FnOnce() -> R,
) -> R {
    let result = slot.with(|slot| {
        let previous = slot.replace(Some(value.to_path_buf()));
        let result = catch_unwind(AssertUnwindSafe(body));
        slot.replace(previous);
        result
    });

    match result {
        Ok(value) => value,
        Err(payload) => resume_unwind(payload),
    }
}

/// Run one `#[ignore]`d helper test in a child process — this same test binary,
/// filtered to `helper` — with `env` set and, optionally, a working directory.
///
/// Some properties are about the environment or working directory a process
/// starts with: an inherited `GIT_DIR`, a `GIT_CONFIG_PARAMETERS` injection, a
/// CWD outside any vstack source. Mutating this process's would leak into every
/// test running beside it, several of which spawn git.
///
/// Asserts the helper actually RAN. libtest exits 0 having run nothing when a
/// filter matches no test, so a renamed or moved helper — nothing references it
/// by symbol — would disarm the guard silently and permanently.
pub(crate) fn run_test_helper(
    helper: &str,
    env: &[(&str, &std::ffi::OsStr)],
    current_dir: Option<&Path>,
) {
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command.args([helper, "--exact", "--ignored", "--nocapture"]);
    for (key, value) in env {
        command.env(key, value);
    }
    if let Some(dir) = current_dir {
        command.current_dir(dir);
    }
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{helper} failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(
        stdout.contains("1 passed"),
        "{helper} did not run — the filter matched no test\nstdout:\n{stdout}"
    );
}
