//! `discover::any_dir` walks what its own rustdoc says it walks.
//!
//! Every claim there is load-bearing for `guard::stranded`, which asks the
//! walk whether any copy of the growth-guards package is left in the work
//! tree before calling a marker in the hook files a leftover. A wrong no
//! tells someone to delete the shims a neighbouring project is arming, so
//! each rule the walk states is pinned here rather than inferred from the
//! one caller: that it stops at no project, caps no depth, and prunes
//! hidden directories, `SKIP_DIRS` and symlinked directories.
//!
//! `crates/cli/tests/guard_hooks/arming.rs` covers the verdict this feeds;
//! these are the walk's own terms, which a refactor routing it back through
//! the capped project walk would break with that test still green.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::discover::any_dir;

/// A package copy as `anywhere` looks for it: a skills root under the
/// directory being asked about.
const PACKAGE: &str = ".agents/skills/growth-guards";

#[allow(clippy::unwrap_used)]
fn tree(dirs: &[&str]) -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    for dir in dirs {
        fs::create_dir_all(tmp.path().join(dir)).unwrap();
    }
    tmp
}

fn carries(dir: &Path) -> bool {
    dir.join(PACKAGE).is_dir()
}

/// The walk over a whole tree, asserted to have seen all of it. A test
/// about which directories are reached has nothing to say if part of the
/// tree could not be read.
#[allow(clippy::unwrap_used)]
fn found(tmp: &tempfile::TempDir, carries: &mut dyn FnMut(&Path) -> bool) -> bool {
    any_dir(tmp.path(), carries).unwrap()
}

/// "It has no depth cap, because a copy at depth six is a copy." The walk
/// this replaced stopped at `MAX_DEPTH` of 5.
#[test]
fn a_copy_at_depth_six_is_found() {
    let tmp = tree(&[&format!("one/two/three/four/five/six/{PACKAGE}")]);
    assert!(found(&tmp, &mut carries));
}

/// "It does not stop at a project": a repository whose own root carries a
/// harness marker is a project to the discovery walk, which would stop
/// there and never reach the nested project that armed the hooks.
#[test]
fn a_project_marker_at_the_root_does_not_stop_the_walk() {
    let tmp = tree(&[".claude/skills", &format!("apps/web/{PACKAGE}")]);
    assert!(found(&tmp, &mut carries));
}

/// "The same pruning as the project walk — hidden directories, the build
/// and dependency trees in `SKIP_DIRS`". A copy behind one of those is not
/// what the shared shims run, so it must not answer for them.
#[test]
fn a_copy_behind_a_pruned_directory_is_not_found() {
    for pruned in [
        "node_modules",
        "target",
        ".git",
        "dist",
        "build",
        ".venv",
        ".cache",
        ".kendex-local",
    ] {
        let tmp = tree(&[&format!("{pruned}/nested/{PACKAGE}")]);
        assert!(
            !found(&tmp, &mut carries),
            "walked into {pruned}, which the pruning rules exclude"
        );
    }
}

/// "Symlinked directories" are pruned, which is the only thing keeping the
/// uncapped walk finite. A link back at an ancestor would otherwise recurse
/// until the stack ran out.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_symlink_to_an_ancestor_is_not_descended() {
    let tmp = tree(&["a/b"]);
    std::os::unix::fs::symlink(tmp.path(), tmp.path().join("a/up")).unwrap();

    let mut asked: Vec<PathBuf> = Vec::new();
    let hit = any_dir(tmp.path(), &mut |dir| {
        asked.push(dir.to_path_buf());
        false
    })
    .unwrap();

    assert!(!hit);
    // Three real directories and no fourth: the link was never entered, so
    // the walk terminated instead of circling through it.
    asked.sort();
    let mut want = vec![
        tmp.path().to_path_buf(),
        tmp.path().join("a"),
        tmp.path().join("a/b"),
    ];
    want.sort();
    assert_eq!(asked, want);
}

/// "A part of the domain that could not be traversed is reported, never
/// counted as empty." A directory the walk cannot open is not a directory
/// with nothing in it, and `guard::stranded` turns "nothing anywhere" into
/// advice to delete a repository's hook files.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_that_cannot_be_read_is_not_an_absence() {
    let Some(tmp) = with_a_locked_dir() else {
        return;
    };
    let error = any_dir(tmp.path(), &mut carries)
        .expect_err("an unreadable directory read as a tree holding no copy");
    unlock(&tmp);
    assert!(
        error.to_string().contains("locked"),
        "the failure does not name the directory: {error}"
    );
}

/// "A hit still wins": the walk carries the failure along instead of
/// stopping on it, so a copy in a readable part of the tree is found
/// whatever else could not be read. Anything less would report a repository
/// that plainly carries the package as one whose state is unknown.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_beside_an_unreadable_directory_is_still_found() {
    let Some(tmp) = with_a_locked_dir() else {
        return;
    };
    fs::create_dir_all(tmp.path().join("readable").join(PACKAGE)).unwrap();
    let hit = any_dir(tmp.path(), &mut carries);
    unlock(&tmp);
    assert!(
        hit.unwrap(),
        "a readable copy was lost to an unreadable peer"
    );
}

/// A tree with one directory this process cannot open, or `None` where the
/// permission bits do not stop this process — running as root, where there
/// is no unreadable directory to build.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn with_a_locked_dir() -> Option<tempfile::TempDir> {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tree(&["locked/nested"]);
    let locked = tmp.path().join("locked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    match fs::read_dir(&locked).is_err() {
        true => Some(tmp),
        false => {
            unlock(&tmp);
            None
        }
    }
}

/// Readable again, so the temporary directory can be removed.
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn unlock(tmp: &tempfile::TempDir) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(tmp.path().join("locked"), fs::Permissions::from_mode(0o755)).unwrap();
}
