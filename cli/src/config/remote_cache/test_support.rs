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
/// repository, plus the origin URL a real clone records. Enough for the
/// stamp and dueness predicates, which read files and run no git.
pub(super) fn cache_with_git_dir(label: &str) -> PathBuf {
    let dir = cache_root(label);
    write_fake_clone(&dir, "https://github.com/owner/repo.git");
    dir
}

/// A cache under a throwaway HOME, with the origin it was cloned from.
pub(super) struct SandboxedCache {
    pub(super) remote: RemoteSource,
    /// The repository the clone was made from. Deleting it is how a test
    /// makes the fetch fail.
    pub(super) origin: PathBuf,
    /// The string a lock entry would record for this source.
    pub(super) source: String,
}

impl SandboxedCache {
    pub(super) fn dir(&self) -> &Path {
        &self.remote.cache_dir
    }

    pub(super) fn lock(&self) -> LockFile {
        demo_lock(&self.source)
    }

    /// Make every future fetch fail without touching the entry itself.
    pub(super) fn break_origin(&self) {
        std::fs::remove_dir_all(&self.origin).unwrap();
    }
}

/// Run `body` against a REAL clone inside a throwaway HOME's cache root.
///
/// Real, not a `.git` marker: every mutation path proves the entry is
/// vstack's own clone of its source before it runs anything, so a fixture
/// that is not a repository never reaches the code under test at all.
pub(super) fn with_sandboxed_cache<R>(label: &str, body: impl FnOnce(&SandboxedCache) -> R) -> R {
    let root = cache_root(label);
    let config = root.join("config");
    std::fs::create_dir_all(&config).unwrap();
    let origin = root.join("origin");
    init_git_repo(&origin);
    let source = format!("file://{}", origin.display());
    let result = crate::test_util::with_home_and_config(&root, &config, || {
        let remote = RemoteSource::parse(&source)
            .expect("a file:// URL is a supported transport")
            .expect("a file:// URL is remote-shaped");
        crate::refresh_sources::clone_cached_repo(&remote).expect("cloning the fixture origin");
        body(&SandboxedCache {
            remote,
            origin: origin.clone(),
            source: source.clone(),
        })
    });
    let _ = std::fs::remove_dir_all(&root);
    result
}

/// Test-side git, scrubbed exactly as the production commands are: a runner
/// exporting `GIT_DIR` or a `GIT_CONFIG_*` override would otherwise point
/// the fixture at another repository.
pub(super) fn git(repo: &Path, args: &[&str]) {
    let output = crate::refresh_sources::hardened_git_command(repo)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A committed repository at `dir` with `README.md` tracked.
pub(super) fn init_git_repo(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", "main"]);
    git(dir, &["config", "user.email", "test@example.com"]);
    git(dir, &["config", "user.name", "Test"]);
    git(dir, &["config", "commit.gpgsign", "false"]);
    std::fs::write(dir.join("README.md"), "upstream\n").unwrap();
    git(dir, &["add", "README.md"]);
    git(dir, &["commit", "-q", "-m", "init"]);
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
        RemoteCacheProblemKind::Unwritable { .. } | RemoteCacheProblemKind::Refused { .. } => None,
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
