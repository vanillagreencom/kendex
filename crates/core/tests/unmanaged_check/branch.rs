//! The branch rule a check run by hand keeps (D007): the committed record
//! is written only where `lock::branch` answers that it may be, and a
//! branch that cannot be read is no licence to write it.

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::drift::{self, copies::CheckMode};
use kendex_core::engine::audit;
use kendex_core::process::Hardened;

use super::world;

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A clone carrying renders and no record, whose remote HEAD names no
/// branch of `origin`: which branch records the lock cannot be read, so
/// the proven copies are not recorded and the report says the record
/// could not be written. The control is the same clone with the remote
/// HEAD taken out, on `main`, where the check records.
#[test]
#[allow(clippy::unwrap_used)]
fn a_branch_that_cannot_be_read_records_nothing() {
    let w = world();
    let planned = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &planned.plan).unwrap();
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    fs::remove_file(&lock_path).unwrap();
    let root = w.home.join("app");
    git(&root, &["init", "--quiet", "-b", "main"]);
    git(
        &root,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/heads/main",
        ],
    );

    let check = || {
        drift::report::render_plain(
            &drift::report::check(&w.env, std::slice::from_ref(&w.scope), CheckMode::Settle),
            kendex_core::drift::report::Verbosity::Verbose,
        )
    };
    let text = check();
    assert!(!lock_path.exists(), "the record was written: {text}");
    assert!(
        text.contains("files matching their source could not be recorded as installed:"),
        "{text}"
    );

    git(
        &root,
        &["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"],
    );
    assert_eq!(check(), "", "the control records");
    assert!(lock_path.exists(), "the control writes the record");
}
