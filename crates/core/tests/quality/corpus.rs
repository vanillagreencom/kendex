//! The safety rules over the skills this repository ships, rather than a
//! fixture built to resemble them.
//!
//! `growth-guards` exists to stop the switch that skips a commit's checks,
//! so its README explains that switch, its hook prints a message naming it,
//! and its tests seed fixture repositories with it; `orch` ships a test
//! that spells the switch which turns permission prompts off. A hand-made
//! imitation of those files would keep passing whatever the rule did next.
//! These read the real trees, so a reading that scores a warning about a
//! switch as a use of it fails here.
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

/// Eight lines of this skill's tests hand `--dangerously-skip-permissions`
/// to a stub as the value of a `--launch-flags` argument, or assert that
/// the captured command line carries it. Every one of them is inside a
/// quotation, so none of them is the skill turning permission prompts off.
#[test]
fn orch_is_clean_where_it_only_spells_the_permission_switch() {
    let result = shipped("orch");
    assert_eq!(found(&result), Vec::new(), "{:#?}", result.findings);
    assert_eq!(result.safety.score, 100);
}

/// The skill whose whole job is stopping `git commit --no-verify` said the
/// switch five times in prose, in a hook's message and in a `case` arm, and
/// was rated Critical for each. What is left is the three lines of its own
/// tests that hand the switch to git to seed a fixture repository: those
/// run it, and a rule that stopped reading them would have nothing left to
/// say about the switch at all.
#[test]
fn growth_guards_is_flagged_only_where_it_runs_the_switch() {
    let result = shipped("growth-guards");
    let ran = "skills/growth-guards/tests/commit-msg.test.sh";
    assert_eq!(
        found(&result),
        vec![
            ("safety-bypass", Severity::High, ran),
            ("safety-bypass", Severity::High, ran),
            ("safety-bypass", Severity::High, ran),
        ],
        "{:#?}",
        result.findings
    );
    assert_eq!(result.safety.score, 83);
}
