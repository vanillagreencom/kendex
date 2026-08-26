//! The shapes kendex recognises are the shapes the installer writes.
//!
//! `crates/core/src/guard/grammar.rs` reproduces the helper body and the
//! delegating line so a read-only check can recognise them without running
//! anything. The installer generates and verifies its own helper through one
//! function precisely so a checker cannot drift from the writer — and this
//! reproduction is exactly the second copy that warning is about.
//!
//! So the copies are compared against the real thing: the actual
//! `install-git-hooks` arms a throwaway repository, and what it wrote is
//! compared byte for byte with what the Rust side would have expected. Edit
//! the shell and this fails here, immediately, with both strings.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                std::fs::copy(entry.path(), &target).unwrap();
                let mode = std::fs::metadata(entry.path()).unwrap().permissions();
                std::fs::set_permissions(&target, mode).unwrap();
            }
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn grammar_matches_the_installer() {
    let tmp = tempfile::tempdir().unwrap();
    // An apostrophe in the path, because the helper escapes one and the
    // escaping is part of the bytes being compared.
    let root = tmp.path().join("o'brien/proj");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "--quiet", "-b", "main"]);

    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills/growth-guards")
        .canonicalize()
        .unwrap();
    let package = root.join(".agents/skills/growth-guards");
    copy_tree(&source, &package);
    let scripts = package.join("scripts");

    let out = Command::new(scripts.join("install-git-hooks"))
        .args(["--repo", &root.to_string_lossy()])
        // git's environment reaches this child: a test binary invoked from
        // another checkout would otherwise hand it that repository.
        .current_dir(&root)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "install-git-hooks: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );

    // The helper, byte for byte.
    let written = std::fs::read_to_string(root.join(".git/hooks/kendex-guards")).unwrap();
    let expected = kendex_core::guard::expected_helper_body(&scripts.to_string_lossy());
    assert_eq!(
        written, expected,
        "the installer's helper and kendex's copy of it have drifted apart"
    );

    // Each delegating line, byte for byte, at the position the check reads.
    for lane in ["pre-commit", "commit-msg"] {
        let hook = std::fs::read_to_string(root.join(".git/hooks").join(lane)).unwrap();
        let second = hook.lines().nth(1).unwrap_or_default();
        assert_eq!(
            second,
            kendex_core::guard::expected_call_line(lane),
            "the {lane} delegating line and kendex's copy of it have drifted apart"
        );
    }

    // And the whole point: kendex reads that repository as armed.
    assert!(
        kendex_core::guard::armed(&root, true).unwrap().is_none(),
        "a repository the real installer just armed must read as armed"
    );
}
