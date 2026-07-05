//! Shared test helpers. Anything that mutates process-global state (env vars,
//! cwd, etc.) lives here so the entire test suite serializes through one lock
//! instead of separate per-module locks racing against each other.

#![cfg(test)]

use std::path::Path;

/// Single global mutex guarding environment mutations across the whole crate.
/// Tests in any module that need to redirect process-global env must go
/// through helpers here.
pub(crate) static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Run `body` with `PI_CODING_AGENT_DIR` set to `pi_dir`, restoring the
/// previous value (or unsetting) afterwards. Tolerates a poisoned lock from a
/// prior panicking test so failures don't cascade across the whole suite.
pub(crate) fn with_pi_dir<R>(pi_dir: &Path, body: impl FnOnce() -> R) -> R {
    with_env_var("PI_CODING_AGENT_DIR", pi_dir, body)
}

/// Run `body` with `CODEX_HOME` set to `codex_home`, restoring the previous
/// value afterwards.
pub(crate) fn with_codex_home<R>(codex_home: &Path, body: impl FnOnce() -> R) -> R {
    with_env_var("CODEX_HOME", codex_home, body)
}

fn with_env_var<R>(key: &str, value: &Path, body: impl FnOnce() -> R) -> R {
    let guard = match ENV_LOCK.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    let prev = std::env::var_os(key);
    unsafe {
        std::env::set_var(key, value);
    }
    let result = body();
    unsafe {
        if let Some(prev) = prev {
            std::env::set_var(key, prev);
        } else {
            std::env::remove_var(key);
        }
    }
    drop(guard);
    result
}
