//! Fixtures shared by the remote-cache tests in this module tree.

use super::*;
use crate::config::{InstallMethod, ItemKind, LockEntry};
use std::time::Duration;

pub(super) fn cache_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vstack-cache-ttl-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

/// A directory shaped like a cached clone: a `.git` that is NOT a
/// repository (so any fetch fails fast) plus the origin URL a real clone
/// records, which is what identifies the cache.
pub(super) fn cache_with_git_dir(label: &str) -> PathBuf {
    let dir = cache_root(label);
    write_fake_clone(&dir, "https://github.com/owner/repo.git");
    dir
}

/// Run `body` against a cache inside a throwaway HOME's cache root — the
/// only place a fetch is allowed to touch, so anything that mutates has
/// to be exercised here.
pub(super) fn with_sandboxed_cache<R>(label: &str, body: impl FnOnce(&Path) -> R) -> R {
    let root = cache_root(label);
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    let result = crate::test_util::with_home_and_config(&root, &config, || {
        let dir = remote_cache_dir("owner/repo").expect("shorthand is a remote source");
        write_fake_clone(&dir, "https://github.com/owner/repo.git");
        body(&dir)
    });
    let _ = std::fs::remove_dir_all(&root);
    result
}

pub(super) fn write_fake_clone(dir: &Path, origin: &str) {
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    std::fs::write(
        dir.join(".git").join("config"),
        format!("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = {origin}\n"),
    )
    .unwrap();
}

pub(super) fn failing_for(dir: &Path) -> Option<Duration> {
    match remote_cache_problem(dir)? {
        RemoteCacheProblemKind::Failing { failing_for, .. } => Some(failing_for),
        RemoteCacheProblemKind::Unwritable { .. } => None,
    }
}

pub(super) fn is_root() -> bool {
    #[cfg(unix)]
    // SAFETY: `geteuid` reads the calling process's effective uid; it
    // takes no arguments, touches no memory, and cannot fail.
    unsafe {
        libc::geteuid() == 0
    }
    #[cfg(not(unix))]
    false
}

pub(super) fn demo_lock(source: &str) -> LockFile {
    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "demo".into(),
        kind: ItemKind::Skill,
        source: source.into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-08-15T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock
}

/// The lock-takeover helper the non-unix guard is built from. It is
/// exercised here, on the platform CI actually runs, because a branch
/// nobody compiles is a branch nobody can trust — the previous non-unix
/// guard shipped dead for exactly that reason.
/// Backdate the lock's mtime so the staleness gate is open.
pub(super) fn backdate_lock(lock: &Path) {
    std::fs::File::options()
        .write(true)
        .open(lock)
        .unwrap()
        .set_modified(std::time::SystemTime::now() - Duration::from_secs(3600))
        .unwrap();
}

/// A pid that provably belonged to a process that has exited: spawn a
/// child, wait for it, use its pid. (Reuse in the microseconds before the
/// assertion is astronomically unlikely and would only flip the test
/// toward the CONSERVATIVE outcome.)
pub(super) fn dead_pid() -> u32 {
    let child = std::process::Command::new("true")
        .spawn()
        .expect("spawning /usr/bin/true");
    let pid = child.id();
    let mut child = child;
    child.wait().unwrap();
    pid
}
