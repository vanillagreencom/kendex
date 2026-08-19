//! Minting a cache entry, and the destinations that must be refused first.
//!
//! Refusing before the clone is what keeps a local fact — a directory in the
//! way — from being reported as a failure to reach the remote.

use crate::refresh_sources::tests::{git, git_stdout, init_git_repo, remote_at, tmpdir};
use crate::refresh_sources::*;

/// `git clone` follows a symlink at its destination, so the clone path had
/// to prove the entry is vstack's own directory before running git — every
/// other write path already does.
#[cfg(unix)]
#[test]
fn clone_refuses_a_cache_entry_that_is_not_an_empty_directory_of_its_own() {
    let root = tmpdir("clone-destination");
    let origin = root.join("origin");
    init_git_repo(&origin);
    let outside = root.join("user-checkout");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("precious.txt"), "precious\n").unwrap();
    let home = root.join("home");

    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let remote = remote_at(&remote_cache_root().join("owner_repo"), &origin);
        std::fs::create_dir_all(remote.cache_dir.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&outside, &remote.cache_dir).unwrap();

        let err = clone_cached_repo(&remote).unwrap_err().to_string();
        assert!(
            err.contains("not a directory vstack can clone into"),
            "{err}"
        );
        assert!(
            !outside.join(".git").exists(),
            "the clone was written into the link target"
        );
        assert_eq!(
            std::fs::read_to_string(outside.join("precious.txt")).unwrap(),
            "precious\n"
        );
        std::fs::remove_file(&remote.cache_dir).unwrap();

        // A directory holding someone else's files is refused too; an
        // empty one is what a fresh clone lands in.
        std::fs::create_dir_all(&remote.cache_dir).unwrap();
        std::fs::write(remote.cache_dir.join("stray.txt"), "x\n").unwrap();
        let err = clone_cached_repo(&remote).unwrap_err().to_string();
        // The same diagnosis the path spelling gives for the same state, and
        // the same instruction — not an access failure, which is why `add`
        // raises this outside its private-repo hint.
        assert!(err.contains("is not one of vstack's clones"), "{err}");
        assert!(err.contains("Remove its cache entry"), "{err}");
        assert!(!err.contains("gh auth login"), "{err}");
        std::fs::remove_file(remote.cache_dir.join("stray.txt")).unwrap();
        drop(clone_cached_repo(&remote).unwrap());
        assert!(remote.cache_dir.join(".git").is_dir());
    });
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn clone_cached_repo_makes_a_shallow_clone_in_the_cache_root() {
    let root = tmpdir("clone");
    let origin = root.join("origin");
    init_git_repo(&origin);
    std::fs::write(origin.join("README.md"), "second\n").unwrap();
    git(&origin, &["commit", "-q", "-am", "second"]);
    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        let cache = remote_cache_root().join("owner_repo");
        assert!(!cache.exists());
        drop(clone_cached_repo(&remote_at(&cache, &origin)).unwrap());
        assert_eq!(
            std::fs::read_to_string(cache.join("README.md")).unwrap(),
            "second\n"
        );
        assert_eq!(
            git_stdout(&cache, &["rev-parse", "--is-shallow-repository"]),
            "true"
        );
        // The fresh clone is owned and updatable.
        drop(update_cached_repo(&remote_at(&cache, &origin)).unwrap());
    });
    let _ = std::fs::remove_dir_all(root);
}
