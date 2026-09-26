use std::path::Path;

use super::*;
use crate::ui::testing::{ascii, plain, rich, tagged};

const CHOICES: [Choice<'static>; 3] = [
    Choice {
        key: "Enter",
        label: "Set up and re-render",
        recommended: true,
    },
    Choice {
        key: "s",
        label: "Skip",
        recommended: false,
    },
    Choice {
        key: "?",
        label: "Details",
        recommended: false,
    },
];

/// Every component, drawn once in `style` with the same values.
fn drawn(style: &Style) -> Vec<(&'static str, Vec<String>)> {
    let rows = [
        vec!["tidy".to_owned(), "1.2.0".to_owned()],
        vec!["commit-guards".to_owned(), "0.9".to_owned()],
    ];
    vec![
        ("header", style.header("check", "/home/me/dev/app, global")),
        ("section", style.section("stale", 2, Status::Decision)),
        (
            "row",
            style.row(
                Status::Failed,
                "skill tidy",
                Some(Value {
                    copy: "fix: kendex apply",
                    remark: Some("(not from here)"),
                }),
            ),
        ),
        (
            "row bare",
            style.row(Status::Done, "skill tidy [claude]", None),
        ),
        (
            "change",
            style.change("tidy", "1.0.0", "1.2.0", Some("project")),
        ),
        (
            "callout",
            style.callout(
                "commit-guards wants a git hook",
                "it runs before every commit",
                &CHOICES,
            ),
        ),
        ("choices", style.choices(&CHOICES)),
        (
            "link",
            style.link("docs", Target::Url("https://kendex.dev/docs")),
        ),
        (
            "link file",
            style.link(
                "/tmp/a b/SKILL.md",
                Target::File(Path::new("/tmp/a b/SKILL.md")),
            ),
        ),
        ("table", style.table(&["name", "version"], &rows)),
        ("spinner", style.spinner("reading the snapshot", 1)),
        ("progress", style.progress(3, 4, "fetching sources")),
        ("summary", style.summary(Status::Done, "all clear")),
        (
            "details folded",
            style.details("installer output", &["one", "two"], true),
        ),
        (
            "details open",
            style.details("installer output", &["one", "two"], false),
        ),
        ("note", style.note("(package evaluation: 5m ago)")),
    ]
}

/// Each component in the rich rendering, escapes spelled as tags: colour
/// roles, glyphs, the blank line a section, a callout and a summary open
/// with, and the header only a terminal gets.
#[test]
fn each_component_draws_rich() {
    let want: [(&str, &[&str]); 16] = [
        (
            "header",
            &["<1;34>kendex check</>  <90>/home/me/dev/app, global</>"],
        ),
        ("section", &["", "<1;33>stale</>  <90>2</>"]),
        (
            "row",
            &[
                "  <31>✗</> skill tidy",
                "    <36>fix: kendex apply</>",
                "    <90>(not from here)</>",
            ],
        ),
        ("row bare", &["  <32>✓</> skill tidy [claude]"]),
        (
            "change",
            &["  <1>tidy</>  <90>1.0.0</> <34>→</> 1.2.0  <90>[project]</>"],
        ),
        (
            "callout",
            &[
                "",
                "<33>!</> <1>commit-guards wants a git hook</>",
                "  it runs before every commit",
                "  <1;34>[Enter]</> <1>Set up and re-render</><90> · </><34>[s]</> <90>Skip</><90> · </><34>[?]</> <90>Details</>",
            ],
        ),
        (
            "choices",
            &[
                "<1;34>[Enter]</> <1>Set up and re-render</><90> · </><34>[s]</> <90>Skip</><90> · </><34>[?]</> <90>Details</>",
            ],
        ),
        (
            "link",
            &["  <link https://kendex.dev/docs><36>docs</></link>"],
        ),
        (
            "link file",
            &["  <link file:///tmp/a%20b/SKILL.md><36>/tmp/a b/SKILL.md</></link>"],
        ),
        (
            "table",
            &[
                "  <1;90>name</>           <1;90>version</>",
                "  <90>──────────────────────</>",
                "  tidy           1.2.0",
                "  commit-guards  0.9",
            ],
        ),
        ("spinner", &["<34>⠙</> reading the snapshot"]),
        (
            "progress",
            &["<34>━━━━━━━━━━━━━━━</><90>─────</> <90>3/4</> fetching sources"],
        ),
        ("summary", &["", "<32>✓</> <1>all clear</>"]),
        (
            "details folded",
            &["  <90>›</> installer output <90>(2 lines)</>"],
        ),
        (
            "details open",
            &[
                "  <90>›</> installer output",
                "    <90>one</>",
                "    <90>two</>",
            ],
        ),
        ("note", &["<90>(package evaluation: 5m ago)</>"]),
    ];
    pinned(&rich(100), &want);
}

/// Each component in the plain rendering: the grammar scripts read, with
/// no escape, no blank line and no chrome.
#[test]
fn each_component_draws_plain() {
    let want: [(&str, &[&str]); 16] = [
        ("header", &[]),
        ("section", &["stale:"]),
        ("row", &["  skill tidy — fix: kendex apply (not from here)"]),
        ("row bare", &["  skill tidy [claude]"]),
        ("change", &["  tidy  1.0.0 → 1.2.0  [project]"]),
        (
            "callout",
            &[
                "! commit-guards wants a git hook",
                "  it runs before every commit",
                "  [Enter] Set up and re-render · [s] Skip · [?] Details",
            ],
        ),
        (
            "choices",
            &["[Enter] Set up and re-render · [s] Skip · [?] Details"],
        ),
        ("link", &["  docs"]),
        ("link file", &["  /tmp/a b/SKILL.md"]),
        (
            "table",
            &[
                "name           version",
                "tidy           1.2.0",
                "commit-guards  0.9",
            ],
        ),
        ("spinner", &[]),
        ("progress", &[]),
        ("summary", &["all clear"]),
        (
            "details folded",
            &["  installer output", "    one", "    two"],
        ),
        (
            "details open",
            &["  installer output", "    one", "    two"],
        ),
        ("note", &["(package evaluation: 5m ago)"]),
    ];
    pinned(&plain(), &want);
}

/// Without a UTF-8 locale every glyph a component draws is its ASCII
/// fallback, and nothing else on the line changes.
#[test]
fn without_a_utf8_locale_every_glyph_is_ascii() {
    let unicode = drawn(&rich(100));
    let fallback = drawn(&ascii(rich(100)));
    for ((name, wide), (_, narrow)) in unicode.iter().zip(&fallback) {
        for (wide, narrow) in wide.iter().zip(narrow) {
            let text: String = narrow.chars().filter(|c| *c != '\u{1b}').collect();
            assert!(text.is_ascii(), "{name} drew {narrow:?}");
            assert_eq!(
                wide.split('\u{1b}').count(),
                narrow.split('\u{1b}').count(),
                "{name}: the fallback changed more than the glyphs"
            );
        }
    }
}

/// A value off a catalog cannot move the cursor, colour the line or split
/// it: every component escapes what it is handed, and the only escape
/// sequences on a rich line are the component's own.
#[test]
fn a_hostile_value_is_escaped_by_every_component() {
    let hostile = "evil\u{1b}[2J\nname\u{202e}";
    let pick = [Choice {
        key: hostile,
        label: hostile,
        recommended: true,
    }];
    let rows = [vec![hostile.to_owned()]];
    for style in [rich(100), plain()] {
        let drawn = [
            style.header(hostile, hostile),
            style.section(hostile, 1, Status::Notice),
            style.row(
                Status::Notice,
                hostile,
                Some(Value {
                    copy: hostile,
                    remark: Some(hostile),
                }),
            ),
            style.change(hostile, hostile, hostile, Some(hostile)),
            style.callout(hostile, hostile, &pick),
            style.link(hostile, Target::Url(hostile)),
            style.link(hostile, Target::File(Path::new(hostile))),
            style.table(&[hostile], &rows),
            style.spinner(hostile, 0),
            style.progress(1, 2, hostile),
            style.summary(Status::Failed, hostile),
            style.details(hostile, &[hostile], false),
            style.note(hostile),
        ];
        for line in drawn.iter().flatten() {
            assert!(!line.contains('\n'), "a value split a line: {line:?}");
            assert!(
                !line.contains('\u{202e}'),
                "a bidi override survived: {line:?}"
            );
            assert!(
                !line.contains("\u{1b}[2J"),
                "a value's escape survived: {line:?}"
            );
            if style == plain() {
                assert!(!line.contains('\u{1b}'), "plain drew an escape: {line:?}");
            }
        }
    }
}

/// A rich line never passes the width it was drawn at, and the words that
/// wrap hang under the text they continue.
#[test]
fn a_rich_line_wraps_inside_its_width() {
    let long = "unmanaged copy of skill 'commit-guards' at /home/me/dev/app/.claude/skills/commit-guards differs from the package in 2 files";
    let style = rich(40);
    let drawn = [
        style.header("check", long),
        style.row(
            Status::Decision,
            long,
            Some(Value {
                copy: "fix: kendex apply",
                remark: Some(long),
            }),
        ),
        style.callout(long, long, &[]),
        style.summary(Status::Decision, long),
        style.note(long),
    ];
    for lines in &drawn {
        assert!(lines.len() > 2, "{long:?} did not wrap at 40: {lines:?}");
        for line in lines {
            assert!(cells(line) <= 40, "{} cells: {line:?}", cells(line));
        }
    }
    let row = tagged(&drawn[1]);
    assert!(
        row[1..].iter().all(|line| line.starts_with("    ")),
        "a row's continuation left its indent: {row:?}"
    );
}

/// A command wider than the room is still one line: split at a space it
/// reads as a shorter command, the next item's fix, say. The terminal
/// wraps it, and its remark wraps under it as prose.
#[test]
fn a_command_wider_than_the_room_is_drawn_whole() {
    let command = "fix: kendex apply --replace-unmanaged --project-path /home/me/dev/app";
    let drawn = rich(40).row(
        Status::Decision,
        "skill tidy",
        Some(Value {
            copy: command,
            remark: Some("(no --project-path form; the hook refuses this verb here)"),
        }),
    );
    let tagged = tagged(&drawn);
    assert_eq!(tagged[1], format!("    <36>{command}</>"), "{tagged:?}");
    assert!(tagged.len() > 3, "the remark did not wrap: {tagged:?}");
    for line in &drawn[2..] {
        assert!(cells(line) <= 40, "{} cells: {line:?}", cells(line));
    }
}

#[track_caller]
fn pinned(style: &Style, want: &[(&str, &[&str])]) {
    let drawn = drawn(style);
    assert_eq!(drawn.len(), want.len(), "a component has no snapshot");
    for ((name, lines), (wanted, expected)) in drawn.iter().zip(want) {
        assert_eq!(name, wanted);
        assert_eq!(tagged(lines), *expected, "{name}");
    }
}
