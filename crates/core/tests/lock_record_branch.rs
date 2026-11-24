//! Which checkouts may write a project's committed install record (D007):
//! the default branch, the one `refs/remotes/origin/HEAD` names or `main`
//! where the clone records none, and a project outside Git. Every other
//! checkout of a Git repository, a detached HEAD and a linked worktree on
//! a branch among them, leaves the record as its branch holds it.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::lock::branch::{OffBranch, Recording, recording};
use kendex_core::model::Scope;
use kendex_core::process::Hardened;

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A repository on `main` with one commit, under a fresh temporary root.
#[allow(clippy::unwrap_used)]
fn repository() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("app");
    fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "--quiet", "-b", "main"]);
    git(&root, &["config", "gc.auto", "0"]);
    git(&root, &["config", "maintenance.auto", "false"]);
    git(
        &root,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "one",
        ],
    );
    (tmp, root)
}

fn project(root: &Path) -> Scope {
    Scope::Project {
        root: root.to_path_buf(),
    }
}

fn off(head: Option<&str>, records_on: &str) -> Recording {
    Recording::Elsewhere(OffBranch {
        head: head.map(str::to_owned),
        records_on: records_on.to_owned(),
    })
}

/// One row per checkout shape: what is done to a fresh repository on
/// `main`, the directory the project is read at, and the answer.
#[test]
#[allow(clippy::unwrap_used)]
fn each_checkout_shape_answers_where_the_record_is_written() {
    type Shape = fn(&Path) -> PathBuf;
    let rows: [(&str, Shape, Recording); 7] = [
        (
            "the default branch",
            |root| root.to_path_buf(),
            Recording::Here,
        ),
        (
            "a branch in the checkout",
            |root| {
                git(root, &["switch", "--quiet", "-c", "lane"]);
                root.to_path_buf()
            },
            off(Some("lane"), "main"),
        ),
        (
            "a detached HEAD on the default branch's commit",
            |root| {
                git(root, &["switch", "--quiet", "--detach"]);
                root.to_path_buf()
            },
            off(None, "main"),
        ),
        (
            "a linked worktree on a branch",
            |root| {
                let linked = root.with_file_name("lane");
                git(
                    root,
                    &[
                        "worktree",
                        "add",
                        "--quiet",
                        "-b",
                        "lane",
                        linked.to_str().unwrap(),
                    ],
                );
                linked
            },
            off(Some("lane"), "main"),
        ),
        (
            "the branch the remote HEAD names",
            |root| {
                git(root, &["switch", "--quiet", "-c", "trunk"]);
                git(root, &["update-ref", "refs/remotes/origin/trunk", "HEAD"]);
                git(
                    root,
                    &[
                        "symbolic-ref",
                        "refs/remotes/origin/HEAD",
                        "refs/remotes/origin/trunk",
                    ],
                );
                root.to_path_buf()
            },
            Recording::Here,
        ),
        (
            "main where the remote HEAD names another branch",
            |root| {
                git(root, &["update-ref", "refs/remotes/origin/trunk", "HEAD"]);
                git(
                    root,
                    &[
                        "symbolic-ref",
                        "refs/remotes/origin/HEAD",
                        "refs/remotes/origin/trunk",
                    ],
                );
                root.to_path_buf()
            },
            off(Some("main"), "trunk"),
        ),
        (
            "a subdirectory of a checkout on a branch",
            |root| {
                git(root, &["switch", "--quiet", "-c", "lane"]);
                let below = root.join("tools/app");
                fs::create_dir_all(&below).unwrap();
                below
            },
            off(Some("lane"), "main"),
        ),
    ];
    for (shape, arrange, expected) in rows {
        let (_tmp, root) = repository();
        let at = arrange(&root);
        assert_eq!(recording(&project(&at)).unwrap(), expected, "{shape}");
    }
}

/// The two places D001's settle keeps: a project outside Git, and the
/// global scope, whose record is not committed.
#[test]
#[allow(clippy::unwrap_used)]
fn outside_git_and_the_global_scope_record_here() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    assert_eq!(recording(&project(&home)).unwrap(), Recording::Here);
    assert_eq!(recording(&Scope::Global).unwrap(), Recording::Here);
}

/// A remote HEAD pointing at no branch of `origin` names no branch the
/// record could be written on, so the answer is an error, never the
/// write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remote_head_naming_no_remote_branch_is_refused() {
    let (_tmp, root) = repository();
    git(
        &root,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/heads/main",
        ],
    );
    let answer = recording(&project(&root));
    assert!(
        matches!(answer, Err(kendex_core::error::CoreError::GitFailed { .. })),
        "{answer:?}"
    );
}
