//! The links pass of the authoring check: a link in a file the render ships
//! is resolved through the render mapping, and a URL into the catalog's own
//! source is judged against the checkout like the relative link it stands
//! for. Before the pass, every row's finding was a silent pass: that is the
//! must-fail control of each `Some` row.

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

const SOURCE: &str = "https://github.com/acme/cat/blob/main";

/// The check of a catalog checkout whose `origin` is `acme/cat`, holding
/// one `review` skill with a `DEVELOPMENT.md` and a test, and `link`
/// written into its `file`; with the line `link` is on.
#[allow(clippy::unwrap_used)]
fn checked(file: &str, link: &str) -> (CatalogCheck, u32) {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    git(&root, &["init", "-q"]);
    git(
        &root,
        &["remote", "add", "origin", "https://github.com/acme/cat.git"],
    );
    let skill = root.join("skills/review");
    for dir in ["tests", "references", "scripts"] {
        fs::create_dir_all(skill.join(dir)).unwrap();
    }
    let head = "---\nname: review\ndescription: reviews\n---\nBody.\n";
    fs::write(skill.join("SKILL.md"), head).unwrap();
    fs::write(skill.join("DEVELOPMENT.md"), "# Review\n\n## The lane\n").unwrap();
    fs::write(skill.join("tests/run.sh"), "true\n").unwrap();
    fs::write(skill.join("references/guide.md"), "# Guide\n").unwrap();
    let (text, line) = match file {
        "SKILL.md" => (format!("{head}{link}\n"), 6),
        _ => (format!("{link}\n"), 1),
    };
    fs::write(skill.join(file), text).unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    (check(&sealed, "cat").unwrap(), line)
}

/// Each row: the file of the `review` skill the link sits in, the link,
/// and the entry or path the finding must name, `None` where nothing is
/// wrong.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shipped_link_is_judged_through_the_render_mapping() {
    let dev = format!("{SOURCE}/skills/review/DEVELOPMENT.md");
    let rows: Vec<(&str, String, Option<&str>)> = vec![
        // Relative links to what the render drops, from the top and from
        // deeper in the tree.
        (
            "SKILL.md",
            "[dev](DEVELOPMENT.md#the-lane)".into(),
            Some("DEVELOPMENT.md"),
        ),
        (
            "references/guide.md",
            "[t](../tests/run.sh)".into(),
            Some("tests"),
        ),
        // A rendered target, and a `tests` that is not the top level.
        ("SKILL.md", "[g](references/guide.md)".into(), None),
        ("SKILL.md", "[f](references/tests/case.md)".into(), None),
        // The catalog's own source URL: an existing file and heading, a
        // renamed heading, a removed test file, from prose and from a
        // script's plain text.
        ("SKILL.md", format!("See {dev}#the-lane."), None),
        (
            "SKILL.md",
            format!("[dev]({dev}#the-old-lane)"),
            Some("the-old-lane"),
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/skills/review/tests/gone.sh."),
            Some("skills/review/tests/gone.sh"),
        ),
        (
            "scripts/run",
            format!("echo 'proof: {SOURCE}/skills/review/tests/gone.sh'"),
            Some("skills/review/tests/gone.sh"),
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/skills/review/tests/run.sh."),
            None,
        ),
        // A repository spelling its owner in another case is the same one.
        (
            "SKILL.md",
            "See https://github.com/Acme/Cat/blob/main/skills/review/tests/gone.sh".into(),
            Some("skills/review/tests/gone.sh"),
        ),
        // Another repository's URL is not read.
        (
            "SKILL.md",
            "See https://github.com/other/cat/blob/main/skills/review/tests/gone.sh".into(),
            None,
        ),
    ];
    for (file, link, expected) in rows {
        let (report, line) = checked(file, &link);
        let found: Vec<_> = report
            .findings()
            .filter(|finding| finding.pass == LINKS_PASS)
            .collect();
        match expected {
            Some(named) => {
                assert_eq!(found.len(), 1, "{link}: {found:?}");
                assert_eq!(
                    (
                        found[0].file.as_str(),
                        found[0].line,
                        found[0].kind,
                        found[0].name.as_str(),
                        found[0].severity,
                    ),
                    (
                        format!("skills/review/{file}").as_str(),
                        Some(line),
                        "skill",
                        "review",
                        "warning"
                    ),
                    "{link}"
                );
                assert!(found[0].message.contains(named), "{link}: {found:?}");
                assert_eq!(
                    (report.failing(false), report.failing(true)),
                    (0, 1),
                    "{link}"
                );
            }
            None => assert_eq!(found, Vec::new(), "{link}"),
        }
    }
}
