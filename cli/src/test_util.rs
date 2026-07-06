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
