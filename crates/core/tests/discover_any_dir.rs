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

/// "It has no depth cap, because a copy at depth six is a copy." The walk
/// this replaced stopped at `MAX_DEPTH` of 5.
#[test]
fn a_copy_at_depth_six_is_found() {
    let tmp = tree(&[&format!("one/two/three/four/five/six/{PACKAGE}")]);
    assert!(any_dir(tmp.path(), &mut carries));
}

/// "It does not stop at a project": a repository whose own root carries a
/// harness marker is a project to the discovery walk, which would stop
/// there and never reach the nested project that armed the hooks.
#[test]
fn a_project_marker_at_the_root_does_not_stop_the_walk() {
    let tmp = tree(&[".claude/skills", &format!("apps/web/{PACKAGE}")]);
    assert!(any_dir(tmp.path(), &mut carries));
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
            !any_dir(tmp.path(), &mut carries),
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
    let found = any_dir(tmp.path(), &mut |dir| {
        asked.push(dir.to_path_buf());
        false
    });

    assert!(!found);
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
