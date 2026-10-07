use std::fs;

use super::{Broken, MirrorRef, SourceUrl, broken_links};
use crate::model::ItemKind;
use crate::source_read::SealedSource;

const SOURCE: &str = "https://github.com/acme/cat/blob";

/// The links of the `review` skill of a catalog whose source is
/// `acme/cat` with branches `main` and `feat/x`, with `link` written into
/// its `file`: each broken one's line and why.
#[allow(clippy::unwrap_used)]
fn broken(file: &str, link: &str) -> Vec<(u32, Broken)> {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let skill = root.join("skills/review");
    for dir in ["tests", "references", "scripts"] {
        fs::create_dir_all(skill.join(dir)).unwrap();
    }
    let head = "---\nname: review\ndescription: reviews\n---\nBody.\n";
    fs::write(skill.join("SKILL.md"), head).unwrap();
    fs::write(
        skill.join("DEVELOPMENT.md"),
        "# Review\n\n## The lane\n\n## Café\n",
    )
    .unwrap();
    fs::write(skill.join("tests/run.sh"), "true\n").unwrap();
    fs::write(skill.join("references/guide.md"), "# Guide\n").unwrap();
    fs::write(skill.join("references/Quick start.md"), "# Quick\n").unwrap();
    fs::create_dir_all(skill.join("references/notes.md")).unwrap();
    let text = match file {
        "SKILL.md" => format!("{head}{link}\n"),
        _ => format!("{link}\n"),
    };
    fs::write(skill.join(file), text).unwrap();
    let source = SourceUrl {
        blob: "github.com/acme/cat/blob/".to_owned(),
        refs: ["refs/heads/main", "refs/heads/feat/x"]
            .into_iter()
            .filter_map(MirrorRef::from_full)
            .collect(),
    };
    let sealed = SealedSource::open(&root).unwrap();
    let content = super::super::content(&sealed, ItemKind::Skill, &skill).unwrap();
    broken_links(&sealed, Some(&source), "skills/review", &content)
        .unwrap()
        .into_iter()
        .map(|link| {
            assert_eq!(link.at, format!("skills/review/{file}"), "{link:?}");
            (link.line, link.broken)
        })
        .collect()
}

fn missing(path: &str) -> Option<Broken> {
    Some(Broken::Missing(path.to_owned()))
}

/// Each row: the file of the skill the link sits in, the link, and why it
/// is broken, `None` where it is not. A link in `SKILL.md` sits on line 6,
/// one anywhere else on line 1.
#[test]
fn a_relative_link_into_what_the_render_drops_is_broken() {
    let rows: Vec<(&str, String, Option<Broken>)> = vec![
        // Relative links into what the render drops, from the top, from
        // deeper in the tree, and spelled with an escape.
        (
            "SKILL.md",
            "[dev](DEVELOPMENT.md#the-lane)".into(),
            Some(Broken::Dropped("DEVELOPMENT.md")),
        ),
        (
            "references/guide.md",
            "[t](../tests/run.sh)".into(),
            Some(Broken::Dropped("tests")),
        ),
        (
            "SKILL.md",
            "[d](%44EVELOPMENT.md)".into(),
            Some(Broken::Dropped("DEVELOPMENT.md")),
        ),
        // A rendered target, and a `tests` below the top level.
        ("SKILL.md", "[g](references/guide.md)".into(), None),
        ("SKILL.md", "[f](references/tests/case.md)".into(), None),
    ];
    judge(rows);
}

/// The catalog's source URL is judged against the checkout, through the
/// host, the ref and the escapes it is written with. Rows as above.
#[test]
fn a_source_url_is_judged_as_the_file_it_names() {
    let dev = format!("{SOURCE}/main/skills/review/DEVELOPMENT.md");
    let gone = "skills/review/tests/gone.sh";
    let rows: Vec<(&str, String, Option<Broken>)> = vec![
        // The catalog's source URL: an existing file and heading, a
        // renamed heading, a removed test file in prose and in a script's
        // plain text, and a file that is there.
        ("SKILL.md", format!("See {dev}#the-lane."), None),
        (
            "SKILL.md",
            format!("[dev]({dev}#the-old-lane)"),
            Some(Broken::NoHeading {
                path: "skills/review/DEVELOPMENT.md".into(),
                anchor: "the-old-lane".into(),
            }),
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/main/{gone}."),
            missing(gone),
        ),
        (
            "scripts/run",
            format!("echo 'proof: {SOURCE}/main/{gone}'"),
            missing(gone),
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/main/skills/review/tests/run.sh."),
            None,
        ),
        // The host: another case, a bare mention, `www.`; and a longer
        // host, a subdomain and another repository, none of them read.
        (
            "SKILL.md",
            format!("See https://github.com/Acme/Cat/blob/main/{gone}"),
            missing(gone),
        ),
        (
            "SKILL.md",
            format!("See github.com/acme/cat/blob/main/{gone}"),
            missing(gone),
        ),
        (
            "SKILL.md",
            format!("See https://www.github.com/acme/cat/blob/main/{gone}"),
            missing(gone),
        ),
        (
            "SKILL.md",
            format!("See https://notgithub.com/acme/cat/blob/main/{gone}"),
            None,
        ),
        (
            "SKILL.md",
            format!("See https://gist.github.com/acme/cat/blob/main/{gone}"),
            None,
        ),
        (
            "SKILL.md",
            format!("See https://github.com/other/cat/blob/main/{gone}"),
            None,
        ),
        // The ref: a branch holding `/` ends where the checkout's branch
        // does, and a commit the checkout names no ref for is one segment.
        (
            "SKILL.md",
            format!("See {SOURCE}/feat/x/skills/review/DEVELOPMENT.md#the-lane"),
            None,
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/feat/x/skills/review/gone.md"),
            missing("skills/review/gone.md"),
        ),
        (
            "SKILL.md",
            format!("See {SOURCE}/0123abcd/skills/review/tests/run.sh"),
            None,
        ),
        // A directory spelled like a markdown file is there, and has no
        // headings to judge an anchor against.
        (
            "SKILL.md",
            format!("See {SOURCE}/main/skills/review/references/notes.md#intro"),
            None,
        ),
        // Escapes in the path and the anchor are decoded once.
        (
            "SKILL.md",
            format!("See {SOURCE}/main/skills/review/references/Quick%20start.md"),
            None,
        ),
        ("SKILL.md", format!("See {dev}#caf%C3%A9"), None),
        (
            "SKILL.md",
            format!("See {dev}#caf%C3%A8"),
            Some(Broken::NoHeading {
                path: "skills/review/DEVELOPMENT.md".into(),
                anchor: "caf%C3%A8".into(),
            }),
        ),
    ];
    judge(rows);
}

fn judge(rows: Vec<(&str, String, Option<Broken>)>) {
    for (file, link, expected) in rows {
        let line = match file {
            "SKILL.md" => 6,
            _ => 1,
        };
        assert_eq!(
            broken(file, &link),
            expected
                .into_iter()
                .map(|why| (line, why))
                .collect::<Vec<_>>(),
            "{link}"
        );
    }
}
