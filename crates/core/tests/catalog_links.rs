//! The links pass of the authoring check, through `check`: a broken link
//! in a file the render ships is an advisory naming that file and line,
//! and a URL into the catalog's own source splits its ref at a branch the
//! checkout holds. Why each link is broken is the unit rows' to assert
//! (`check_catalog::links::tests`).

use std::fs;
use std::path::Path;

use kendex_core::check_catalog::{CatalogCheck, LINKS_PASS, check};
use kendex_core::source_read::SealedSource;

use crate::test_util;
use test_util::rooted;

/// git in a fixture, with the caller's git environment dropped: run from a
/// commit hook, `GIT_DIR` and friends point at the repository being
/// committed to.
#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?} failed");
}

/// The check of a catalog checkout whose `origin` is `acme/cat` and which
/// holds branches `main` and `feat/x`, locally and as origin's, offering
/// one `review` skill with a `DEVELOPMENT.md`, and `link` on line 6 of its
/// `SKILL.md`.
#[allow(clippy::unwrap_used)]
fn checked(link: &str) -> CatalogCheck {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    git(&root, &["init", "-q"]);
    git(
        &root,
        &["remote", "add", "origin", "https://github.com/acme/cat.git"],
    );
    git(&root, &["commit", "-q", "--allow-empty", "-m", "start"]);
    git(&root, &["branch", "-M", "main"]);
    git(&root, &["branch", "feat/x"]);
    // A clone also holds each branch as origin's.
    for name in ["main", "feat/x"] {
        git(
            &root,
            &["update-ref", &format!("refs/remotes/origin/{name}"), "HEAD"],
        );
    }
    let skill = root.join("skills/review");
    fs::create_dir_all(&skill).unwrap();
    let head = "---\nname: review\ndescription: reviews\n---\nBody.\n";
    fs::write(skill.join("SKILL.md"), format!("{head}{link}\n")).unwrap();
    fs::write(skill.join("DEVELOPMENT.md"), "# Review\n\n## The lane\n").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    check(&sealed, "cat").unwrap()
}

/// Each row: a link, and whether it is broken. The `feat/x` rows hold the
/// checkout's own branches to where the ref ends: read as the one segment
/// `feat`, the existing file is `x/skills/...`, which is not there.
#[test]
fn a_broken_shipped_link_is_an_advisory_at_its_line() {
    let source = "https://github.com/acme/cat/blob";
    for (link, broken) in [
        ("[dev](DEVELOPMENT.md)".to_owned(), true),
        (format!("{source}/main/skills/review/tests/gone.sh"), true),
        (
            format!("{source}/feat/x/skills/review/DEVELOPMENT.md#the-lane"),
            false,
        ),
        (
            format!("{source}/feat/x/skills/review/DEVELOPMENT.md#the-old-lane"),
            true,
        ),
    ] {
        let report = checked(&link);
        let found: Vec<_> = report
            .findings()
            .filter(|finding| finding.pass == LINKS_PASS)
            .map(|finding| {
                (
                    finding.file,
                    finding.line,
                    finding.kind,
                    finding.name,
                    finding.severity,
                )
            })
            .collect();
        let expected: Vec<_> = broken
            .then(|| {
                (
                    "skills/review/SKILL.md".to_owned(),
                    Some(6),
                    "skill",
                    "review".to_owned(),
                    "warning",
                )
            })
            .into_iter()
            .collect();
        assert_eq!(found, expected, "{link}");
        assert_eq!(
            (report.failing(false), report.failing(true)),
            (0, usize::from(broken)),
            "{link}"
        );
    }
}
