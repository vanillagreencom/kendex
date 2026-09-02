//! What the history walk does at its bounds: the byte cap that guards
//! against a repository choosing to print megabytes of filenames.

use std::fs;

use crate::process::Hardened;
use crate::remote::history;

use super::git;
use super::test_util::rooted;

/// A repository whose `--name-only` output for one pathspec is over the
/// module's 1 MB cap: 5,100 long-named files under one directory, in one
/// commit. Cheap to build — the cost is one `git add`, not one commit per
/// file.
fn oversized() -> (tempfile::TempDir, std::path::PathBuf, String) {
    let tmp = tempfile::tempdir().unwrap();
    let repo = rooted(&tmp);
    let big = repo.join("skills/big");
    fs::create_dir_all(&big).unwrap();
    let filler = "n".repeat(180);
    for index in 0..5_100u32 {
        fs::write(big.join(format!("{index:05}-{filler}.md")), "x").unwrap();
    }
    git(&repo, &["init", "--quiet", "-b", "main"]);
    git(&repo, &["add", "-A"]);
    git(
        &repo,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            "big",
        ],
    );
    let head = Hardened::git(&["rev-parse", "HEAD"], Some(&repo))
        .run()
        .unwrap();
    let tip = String::from_utf8_lossy(&head.stdout).trim().to_owned();
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

    let refused = history::last_changed(&mirror, &tip, &paths, 5_000);
    assert!(
        refused.is_err(),
        "over-cap output must not answer: {:?}",
        refused.map(|changed| changed.dates.len())
    );

    // The same mirror answers for a pathspec whose output fits, so the
    // refusal is the cap talking and not a broken fixture.
    let small = [std::path::PathBuf::from("skills/big/00000")];
    assert!(history::last_changed(&mirror, &tip, &small, 5_000).is_ok());
}
