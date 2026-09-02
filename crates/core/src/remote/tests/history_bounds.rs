//! The record boundary of the history walk: what keeps a catalog from
//! writing one of its own into a filename.
//!
//! Unix only, and only because of the fixture. What this guards is the
//! parser reading git's bytes, which is the same code on every platform —
//! but Windows refuses to CREATE a file whose name carries 0x1E
//! (`InvalidFilename`), so the malicious catalog cannot be authored there
//! through the filesystem. A catalog forged on Unix and cloned to Windows
//! still reaches the same parser; only writing the fixture is the part
//! Windows will not do.
#![cfg(unix)]

use std::fs;

use crate::process::Hardened;
use crate::remote::history;

use super::git;
use super::test_util::rooted;

/// A commit bound past anything these fixtures hold, so what a test proves
/// is never the commit bound. The production one is `browse/updated.rs`.
const MANY: usize = 5_000;

/// Everything staged, committed, and the commit id back.
fn commit_all(repo: &std::path::Path) -> String {
    git(repo, &["add", "-A"]);
    git(
        repo,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            "fixture",
        ],
    );
    let head = Hardened::git(&["rev-parse", "HEAD"], Some(repo))
        .run()
        .unwrap();
    String::from_utf8_lossy(&head.stdout).trim().to_owned()
}

/// A record boundary a catalog can write is a date a catalog can forge.
/// `-z` stops git escaping control characters in a filename, so any
/// printable or control delimiter is one the catalog may put in a name: a
/// file called `x<0x1e>2099-...` used to open a synthetic record whose name
/// list was its sibling, dating that sibling to 2099 and pinning it to the
/// top of a newest-first sort. The boundary is an empty field now, which no
/// path can be.
#[test]
fn a_filename_cannot_open_a_record_and_date_its_neighbour() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = rooted(&tmp);
    for package in ["alpha", "victim"] {
        let home = repo.join("skills").join(package);
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("SKILL.md"), "x").unwrap();
    }
    // The forged record: a record opener, then a date the walk would read.
    let forged = format!("x{}2099-01-01T00:00:00+00:00", '\u{1e}');
    fs::write(repo.join("skills/alpha").join(forged), "x").unwrap();
    git(&repo, &["init", "--quiet", "-b", "main"]);
    let tip = commit_all(&repo);
    let mirror = repo.join(".git");

    let paths = [
        std::path::PathBuf::from("skills/alpha"),
        std::path::PathBuf::from("skills/victim"),
    ];
    let changed = history::last_changed(&mirror, &tip, &paths, MANY).unwrap();
    let victim = changed
        .dates
        .get(std::path::Path::new("skills/victim"))
        .expect("the victim is dated by the commit that really touched it");
    assert!(
        !victim.starts_with("2099"),
        "a filename dated a sibling package: {victim}"
    );
    // Both packages changed in the one commit, so both carry its date.
    assert_eq!(
        changed.dates.get(std::path::Path::new("skills/alpha")),
        Some(victim),
    );
}
