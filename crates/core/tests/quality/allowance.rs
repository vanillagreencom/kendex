//! What kendex's table of accepted findings sets aside, and what puts a
//! finding back: one table over the ways a reading can differ from the
//! row that accepted it.

use std::path::PathBuf;

use kendex_core::hash::hash_bytes;
use kendex_core::model::ItemKind;
use kendex_core::quality::{
    Accepted, AcceptedFile, Allowance, AllowedPackage, AuditInput, AuditResult, Content,
    RULESET_VERSION, audit_with, observe,
};

const SCRIPT: &str = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\n";
const SWITCH: &str = "`--dangerously-skip-permissions` turns off permission prompts";
const SKILL_MD: &str = "---\nname: launch\ndescription: launches a lane\n---\n\nLaunch it.\n";

/// The table that accepts the switch on line 2 of the fixture's script.
fn accepting(kind: ItemKind, name: &str, path: &str, text: &str) -> Allowance {
    Allowance {
        ruleset: RULESET_VERSION,
        packages: vec![AllowedPackage {
            kind,
            name: name.to_owned(),
            source_hash: "unread".to_owned(),
            files: vec![AcceptedFile {
                path: path.to_owned(),
                hash: hash_bytes(text.as_bytes()),
                accepted: vec![Accepted {
                    rule: "safety-bypass".to_owned(),
                    line: Some(2),
                    message: SWITCH.to_owned(),
                }],
            }],
        }],
    }
}

fn skill(script: &str, allowance: &Allowance) -> AuditResult {
    audit_with(
        AuditInput {
            kind: ItemKind::Skill,
            name: "launch".to_owned(),
            harness: None,
            location: "skills/launch".to_owned(),
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

/// One row of the shape table: its name, the script, the table, the
/// lines flagged and the lines accepted.
type Row<'a> = (&'a str, &'a str, Allowance, &'a [u32], &'a [u32]);

fn placed(findings: &[kendex_core::quality::Finding]) -> Placed<'_> {
    findings
        .iter()
        .map(|finding| (finding.location.as_str(), finding.line))
        .collect()
}

/// The table with its one row changed.
fn row_edited(edit: impl FnOnce(&mut Accepted)) -> Allowance {
    let mut table = accepting(ItemKind::Skill, "launch", "scripts/launch.sh", SCRIPT);
    edit(&mut table.packages[0].files[0].accepted[0]);
    table
}

/// One row per way the reading can differ from the row that accepted it,
/// each with the lines flagged and the lines accepted in the script.
/// Every difference is a finding again; only the exact text, package,
/// rule set and row are accepted.
#[test]
fn a_finding_is_accepted_only_for_the_exact_text_the_table_names() {
    let at = "skills/launch/scripts/launch.sh";
    let edited = "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions # now\n";
    let two =
        "#!/usr/bin/env bash\nclaude --dangerously-skip-permissions\ngit commit --no-verify\n";
    let base = || accepting(ItemKind::Skill, "launch", "scripts/launch.sh", SCRIPT);
    let rows: Vec<Row<'_>> = vec![
        ("as recorded", SCRIPT, base(), &[], &[2]),
        ("the file edited", edited, base(), &[2], &[]),
        (
            "a second finding in the accepted file",
            two,
            accepting(ItemKind::Skill, "launch", "scripts/launch.sh", two),
            &[3],
            &[2],
        ),
        (
            "another rule set",
            SCRIPT,
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
            accepting(ItemKind::Skill, "launcher", "scripts/launch.sh", SCRIPT),
            &[2],
            &[],
        ),
        (
            "another kind",
            SCRIPT,
            accepting(ItemKind::Command, "launch", "scripts/launch.sh", SCRIPT),
            &[2],
            &[],
        ),
        (
            "another path",
            SCRIPT,
            accepting(ItemKind::Skill, "launch", "launch.sh", SCRIPT),
            &[2],
            &[],
        ),
        (
            "another line",
            SCRIPT,
            row_edited(|row| row.line = Some(1)),
            &[2],
            &[],
        ),
        (
            "another message",
            SCRIPT,
            row_edited(|row| row.message = "`--no-verify` skips".to_owned()),
            &[2],
            &[],
        ),
        ("no table", SCRIPT, Allowance::default(), &[2], &[]),
    ];
    for (row, script, allowance, flagged, accepted) in rows {
        let result = skill(script, &allowance);
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

/// A package that is one file is named by the empty path: the file is
/// the package, and the table has nothing inside it to name.
#[test]
fn a_one_file_package_is_accepted_at_the_empty_path() {
    let text = "---\ndescription: ship it\n---\nclaude --dangerously-skip-permissions\n";
    let input = || AuditInput {
        kind: ItemKind::Command,
        name: "ship".to_owned(),
        harness: None,
        location: "commands/ship.md".to_owned(),
        content: Content::Document {
            text: text.to_owned(),
        },
    };
    let mut table = accepting(ItemKind::Command, "ship", "", text);
    table.packages[0].files[0].accepted[0].line = Some(4);
    let result = audit_with(input(), &table);
    assert_eq!(placed(&result.findings), vec![], "{:#?}", result.findings);
    assert_eq!(
        placed(&result.accepted),
        vec![("commands/ship.md", Some(4))],
        "{:#?}",
        result.accepted
    );
    table.packages[0].files[0].path = "ship.md".to_owned();
    let result = audit_with(input(), &table);
    assert_eq!(
        placed(&result.findings),
        vec![("commands/ship.md", Some(4))],
        "{:#?}",
        result.findings
    );
}

/// The table round-trips through its file form, header included, so what
/// the regeneration writes is what the build reads back.
#[test]
#[allow(clippy::unwrap_used)]
fn the_table_reads_back_as_written() {
    let table = accepting(ItemKind::Skill, "launch", "scripts/launch.sh", SCRIPT);
    let text = table.to_toml().unwrap();
    assert!(text.starts_with("# Findings kendex accepts"), "{text}");
    assert_eq!(Allowance::parse(&text).unwrap(), table, "{text}");
    assert!(
        Allowance::parse("ruleset = 6\n[[package]]\nkind = \"skill\"\nname = \"x\"\nsource-hash = \"h\"\nextra = 1\n").is_err(),
        "a key the reader does not read is refused, never dropped"
    );
}
