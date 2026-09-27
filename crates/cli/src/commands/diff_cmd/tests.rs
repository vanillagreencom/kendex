use super::{FileStatus, LineKind, PackageDiff, screen};
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;
use kendex_core::package::diff::{FileDiff, Hunk, Line};

#[test]
fn inspection_diff_wraps_long_changed_lines() {
    let diff = PackageDiff {
        files: vec![FileDiff {
            path: "long-file-name-".repeat(10),
            status: FileStatus::Added,
            additions: 1,
            deletions: 0,
            lossy: false,
            hunks: vec![Hunk {
                header: "@@ -0,0 +1 @@".into(),
                lines: vec![Line {
                    kind: LineKind::Add,
                    text: "a long changed line ".repeat(10),
                    old_no: None,
                    new_no: Some(1),
                }],
            }],
        }],
        total_additions: 1,
        total_deletions: 0,
        truncated: false,
    };
    let lines = screen(&rich(80), &diff);
    assert!(
        lines.iter().all(|line| visible_width(line) <= 80),
        "{lines:?}"
    );
    assert!(
        screen(&plain(), &diff)
            .iter()
            .any(|line| visible_width(line) > 80)
    );
}

#[test]
fn inspection_diff_snapshots() {
    let diff = PackageDiff {
        files: vec![
            FileDiff {
                path: "SKILL.md".into(),
                status: FileStatus::Modified,
                additions: 1,
                deletions: 1,
                lossy: false,
                hunks: vec![Hunk {
                    header: "@@ -1 +1 @@".into(),
                    lines: vec![
                        Line {
                            kind: LineKind::Remove,
                            text: "old".into(),
                            old_no: Some(1),
                            new_no: None,
                        },
                        Line {
                            kind: LineKind::Add,
                            text: "new".into(),
                            old_no: None,
                            new_no: Some(1),
                        },
                        Line {
                            kind: LineKind::Remove,
                            text: "  - nested  item".into(),
                            old_no: Some(2),
                            new_no: None,
                        },
                        Line {
                            kind: LineKind::Context,
                            text: "    fn foo()  bar".into(),
                            old_no: Some(3),
                            new_no: Some(2),
                        },
                    ],
                }],
            },
            FileDiff {
                path: "large.bin".into(),
                status: FileStatus::TooLarge,
                additions: 0,
                deletions: 0,
                lossy: false,
                hunks: vec![],
            },
        ],
        total_additions: 1,
        total_deletions: 1,
        truncated: true,
    };
    assert_eq!(
        screen(&plain(), &diff),
        [
            "+1 -1  (truncated)",
            "",
            "SKILL.md  +1 -1",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            "-  - nested  item",
            "     fn foo()  bar",
            "",
            "large.bin (too large to show)  +0 -0"
        ]
    );
    // A diff line keeps its indentation and its runs of spaces rich: the
    // text after the glyph is the plain line.
    assert_eq!(
        tagged(&screen(&rich(80), &diff)),
        [
            "",
            "<1;36>changes</>  <90>2</>",
            "  <36>•</> SKILL.md +1 -1",
            "    <90>@@ -1 +1 @@</>",
            "    <33>!</> -old",
            "    <32>✓</> +new",
            "    <33>!</> -  - nested  item",
            "    <90>     fn foo()  bar</>",
            "  <36>•</> large.bin (too large to show) +0 -0",
            "",
            "<36>•</> <1>+1 -1 (truncated)</>"
        ]
    );
    let clean = PackageDiff {
        files: vec![],
        total_additions: 0,
        total_deletions: 0,
        truncated: false,
    };
    assert_eq!(screen(&plain(), &clean), ["no changes"]);
    assert_eq!(
        tagged(&screen(&rich(80), &clean)),
        ["", "<32>✓</> <1>no changes</>"]
    );
}
