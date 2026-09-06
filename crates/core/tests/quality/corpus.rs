//! The safety rules over the skills this repository ships, rather than a
//! fixture built to resemble them.
//!
//! `commit-guards` exists to stop the switch that skips a commit's checks,
//! so its README and SKILL.md explain that switch, its hook prints a
//! message naming it, and its tests seed fixture repositories with it;
//! `orch` ships a test that spells the switch which turns permission
//! prompts off. A hand-made imitation of those files would keep passing
//! whatever the rule did next. These read the real trees, so a reading
//! that scores a document's mention of a switch as a use of it fails here,
//! and so does one that stops counting a switch written as code.
//!
//! Line numbers are left out on purpose — editing a skill moves them and
//! says nothing about the rules. What is asserted is the score and every
//! finding's rule, severity and file.

use std::path::{Path, PathBuf};

use kendex_core::model::ItemKind;
use kendex_core::quality::{AuditInput, AuditResult, Severity, audit, observe};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills")
}

/// Every file under a skill in this repository, read as the audit reads an
/// installed tree.
fn shipped(name: &str) -> AuditResult {
    let mut files = Vec::new();
    walk(&root().join(name), Path::new(""), &mut files);
    assert!(!files.is_empty(), "skills/{name} holds no files");
    audit(AuditInput {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        harness: None,
        location: format!("skills/{name}"),
        content: observe::tree_content_from_bytes(&files),
    })
}

#[allow(clippy::unwrap_used)]
fn walk(dir: &Path, rel: &Path, files: &mut Vec<(PathBuf, Vec<u8>)>) {
    let entries = std::fs::read_dir(dir).unwrap_or_else(|why| panic!("{}: {why}", dir.display()));
    for entry in entries {
        let entry = entry.unwrap();
        let path = entry.path();
        let under = rel.join(entry.file_name());
        match path.is_dir() {
            true => walk(&path, &under, files),
            false => files.push((under, std::fs::read(&path).unwrap())),
        }
    }
}

/// What was found, without the line numbers: rule, severity, file.
fn found(result: &AuditResult) -> Vec<(&str, Severity, &str)> {
    result
        .findings
        .iter()
        .map(|finding| {
            (
                finding.rule.as_str(),
                finding.severity,
                finding.location.as_str(),
            )
        })
        .collect()
}

/// The skill whose whole job is stopping the commit hook-bypass switch
/// named it three times in documents — twice in its README, once in its
/// SKILL.md, every one of them inside a code span — and was rated Critical
/// for each. Those three are gone.
///
/// What is left is what the switch is written as code: the two messages
/// its hooks print. A shell string is a switch written into a file a
/// harness loads, and the rule counts it there.
#[test]
fn commit_guards_is_flagged_where_the_switch_stands_as_code() {
    let result = shipped("commit-guards");
    let helper = "skills/commit-guards/scripts/lib/helper-body.sh";
    let hook = "skills/commit-guards/scripts/pre-commit";
    assert_eq!(
        found(&result),
        vec![
            ("safety-bypass", Severity::Critical, helper),
            ("safety-bypass", Severity::Critical, hook),
        ],
        "{:#?}",
        result.findings
    );
    assert_eq!(result.safety.score, 74);
}

/// Six lines of this skill's tests spell `--dangerously-skip-permissions`
/// inside a shell string — the value of a `--launch-flags` argument, or the
/// command line an assertion expects back. Every one of them is the switch
/// written as code in a file a harness loads, and the rule counts it there
/// rather than deciding which program the string reaches.
///
/// That is the cost of the reading, pinned to a real tree: six findings
/// one severity down for a supporting file. A reading that went quiet on
/// them would be reading an argument list again, and this is where that
/// fails.
#[test]
fn orch_is_flagged_where_its_tests_spell_the_permission_switch() {
    let result = shipped("orch");
    let spells = "skills/orch/tests/open-terminal-claude-handoff.sh";
    assert_eq!(
        found(&result),
        vec![("safety-bypass", Severity::High, spells); 6],
        "{:#?}",
        result.findings
    );
    assert_eq!(result.safety.score, 80);
}
