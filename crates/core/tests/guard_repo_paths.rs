//! A repository is found by the bytes of its path, not by a rendering of
//! them.
//!
//! Both of these are names a person can create and git handles without
//! complaint. Reading git's answer as text broke them in different ways, and
//! neither failed loudly: one made every guard verb report a path that does
//! not exist, and the other silently named a different repository.
#![cfg(unix)]

use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

use kendex_core::guard::Repo;

#[allow(clippy::expect_used)]
fn git(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        // A fixture HOME so a real global config — a `core.hooksPath`, a
        // template dir — cannot reach these repositories. The child is git,
        // not kendex, but the flag is what says this HOME is deliberate.
        .env("HOME", dir)
        .env("KENDEX_REAL_HOME", "1")
        // The redirects, scrubbed for the reason this crate scrubs them
        // everywhere else: an inherited GIT_DIR outranks `current_dir`, so
        // `git init` here would initialize whatever repository it names.
        // This is the same defect the guard verbs are hardened against, and
        // a test that reaches for git deserves the same care.
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_CONFIG_GLOBAL")
        .env_remove("GIT_CONFIG_COUNT")
        .status()
        .expect("git runs");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

#[allow(clippy::expect_used)]
fn repo_named(parent: &Path, name: OsString) -> PathBuf {
    let root = parent.join(name);
    std::fs::create_dir_all(&root).expect("the fixture directory is creatable");
    git(&root, &["init", "-q"]);
    root
}

/// A checkout whose name is not UTF-8.
///
/// `from_utf8_lossy` turns those bytes into U+FFFD, which is a different
/// filename — so `canonicalize` failed and every verb reported a path
/// nobody has, for a repository that is perfectly fine.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_checkout_whose_name_is_not_utf8_is_found() {
    let tmp = tempfile::tempdir().unwrap();
    // 0xFF is not valid UTF-8 in any position.
    let root = repo_named(tmp.path(), OsString::from_vec(b"caf\xffe".to_vec()));

    let repo = Repo::at(&root).expect("the repository is found by its bytes");
    assert_eq!(repo.worktree, root.canonicalize().unwrap());
    assert_eq!(repo.common_dir, root.join(".git").canonicalize().unwrap());
}

/// A checkout whose name contains a newline.
///
/// Two paths asked in one `rev-parse` came back as two lines, so this name
/// put a line break inside the first answer and the second was read out of
/// the middle of it — naming a directory that is not this repository's.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_checkout_whose_name_contains_a_newline_is_found() {
    let tmp = tempfile::tempdir().unwrap();
    let root = repo_named(tmp.path(), OsString::from_vec(b"two\nlines".to_vec()));

    let repo = Repo::at(&root).expect("the repository is found");
    assert_eq!(repo.worktree, root.canonicalize().unwrap());
    assert_eq!(
        repo.common_dir,
        root.join(".git").canonicalize().unwrap(),
        "the common dir was read out of the wrong line"
    );
}

/// The control: an ordinary name resolves the same way, so the two above
/// are pinning the bytes rather than a path that happens to work.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn an_ordinary_checkout_resolves_the_same_way() {
    let tmp = tempfile::tempdir().unwrap();
    let root = repo_named(tmp.path(), OsString::from("plain"));

    let repo = Repo::at(&root).expect("the repository is found");
    assert_eq!(repo.worktree, root.canonicalize().unwrap());
    assert_eq!(repo.common_dir, root.join(".git").canonicalize().unwrap());
}
