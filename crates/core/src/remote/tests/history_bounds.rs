//! What the history walk does at its edges: the byte cap that guards
//! against a repository choosing to print megabytes of filenames, and the
//! record boundary that keeps a catalog from writing one of its own.

use std::fs;

use crate::process::Hardened;
use crate::remote::history;

use super::git;
use super::test_util::rooted;

/// A commit bound past anything these fixtures hold, so what a test proves
/// is never the commit bound. The production one is `browse/updated.rs`.
const MANY: usize = 5_000;

/// The name of one of [`oversized`]'s files, so a test can ask for a path
/// the fixture really wrote rather than one that logs nothing.
fn big_file(index: u32) -> std::path::PathBuf {
    std::path::PathBuf::from(format!("skills/big/{index:05}-{}.md", "n".repeat(180)))
}

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

/// A repository whose `--name-only` output for one pathspec is over the
/// module's 1 MB cap: 5,100 long-named files under one directory, in one
/// commit. Cheap to build — the cost is one `git add`, not one commit per
/// file.
fn oversized() -> (tempfile::TempDir, std::path::PathBuf, String) {
    let tmp = tempfile::tempdir().unwrap();
    let repo = rooted(&tmp);
    let big = repo.join("skills/big");
    fs::create_dir_all(&big).unwrap();
    for index in 0..5_100u32 {
        fs::write(repo.join(big_file(index)), "x").unwrap();
    }
    git(&repo, &["init", "--quiet", "-b", "main"]);
    let tip = commit_all(&repo);
    (tmp, repo.join(".git"), tip)
}

// `--name-only` is what arms this: the pathspec-filtered walk prints one
// line per changed file, so how much a read costs is the repository's
// choice, not the bound's. The cap has to stop the read rather than trim
// what was already buffered, and a read that could not complete under it is
// a refusal — never a truncated stream parsed as if it were whole.
#[test]
fn a_walk_whose_output_runs_past_the_cap_is_refused_not_truncated() {
    let (_tmp, mirror, tip) = oversized();
    let paths = [std::path::PathBuf::from("skills/big")];

    let refused = history::last_changed(&mirror, &tip, &paths, MANY);
    assert!(
        refused.is_err(),
        "over-cap output must not answer: {:?}",
        refused.map(|changed| changed.dates.len())
    );

    // The same mirror ANSWERS for a pathspec whose output fits, so the
    // refusal above is the cap talking and not a broken fixture. Naming a
    // path the fixture never wrote would pass this on an empty walk, which
    // says nothing about reading output back.
    let one = [big_file(0)];
    let under = history::last_changed(&mirror, &tip, &one, MANY).unwrap();
    assert_eq!(under.dates.len(), 1, "{:?}", under.dates);
    assert!(under.newest.is_some());
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
    assert!(changed.newest.is_some_and(|date| !date.starts_with("2099")));
}
