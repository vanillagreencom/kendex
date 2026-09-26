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
use kendex_core::quality::{AuditInput, AuditResult, Content, Publisher, Severity, audit, observe};

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
        publisher: Publisher::Kendex,
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
    found_in(&result.findings)
}

fn found_in(findings: &[kendex_core::quality::Finding]) -> Vec<(&str, Severity, &str)> {
    findings
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
/// spells it in its README and SKILL.md inside code spans, in the comment
/// explaining each refusal, and in the message each lane prints when it
/// refuses — the helper's `echo`, and the commit chain's and push lane's
/// `gg_message`, which its library defines and whose body only prints.
/// Every one of those is the package naming the switch, and the audit
/// reads them as mentions: the score is clean, and the mentions are what
/// a verbose reading shows.
#[test]
fn commit_guards_scans_clean_and_names_the_switch_only_where_it_names_it() {
    let result = shipped("commit-guards");
    assert_eq!(found(&result), vec![], "{:#?}", result.findings);
    assert_eq!(result.safety.score, 100);
    let helper = "skills/commit-guards/scripts/lib/helper-body.sh";
    let commit = "skills/commit-guards/scripts/pre-commit";
    let push = "skills/commit-guards/scripts/pre-push";
    let mentioned: Vec<(&str, &str)> = result
        .mentions
        .iter()
        .map(|mention| (mention.rule.as_str(), mention.location.as_str()))
        .filter(|(_, location)| !location.ends_with(".md"))
        .collect();
    assert_eq!(
        mentioned,
        vec![
            ("safety-bypass", helper),
            ("safety-bypass", commit),
            ("safety-bypass", push),
        ],
        "{:#?}",
        result.mentions
    );
}

/// A guard hook is one script that spells the operand it refuses in the
/// comments explaining the refusal. Read as a hook's registration and
/// script, each scans clean.
#[test]
fn the_guard_hooks_scan_clean() {
    for hook in ["block-unsafe-rm.sh", "pre-commit-check.sh"] {
        let path = root().join("../hooks").join(hook);
        let script = std::fs::read_to_string(&path)
            .unwrap_or_else(|why| panic!("{}: {why}", path.display()));
        let result = audit(AuditInput {
            kind: ItemKind::Hook,
            name: hook.to_owned(),
            harness: None,
            publisher: Publisher::Kendex,
            location: format!("hooks/{hook}"),
            content: Content::Hook {
                event: "PreToolUse".to_owned(),
                matcher: Some("Bash".to_owned()),
                command: format!("bash hooks/{hook}"),
                values: None,
                script: Some(script),
            },
        });
        assert_eq!(found(&result), vec![], "{hook}: {:#?}", result.findings);
        assert!(!result.mentions.is_empty(), "{hook} names what it refuses");
    }
}

/// Thirty lines of this skill spell `--dangerously-skip-permissions`.
/// One is a row of the launch table's source, which a lane launch really
/// runs: the one Critical finding, which kendex's own table accepts for
/// exactly those bytes and a verbose reading still lists. The launch
/// table's comment naming the switch is a mention.
///
/// The other twenty-eight are in the open-terminal, oversee-succeed and
/// overseer-watch tests, which hand the launch lines they check to their
/// stubs and assertions: a string a test assigns or prints, and an
/// argument of a function the tests define, on the line that names the
/// function or a line continuing it. Each is a mention, and the
/// skill scores clean. A reading that counted them again would be reading
/// a test's data as a command, and this is where that fails; so does a
/// table that lets an edit to the launcher keep its acceptance
/// (`allowance.rs::a_finding_is_accepted_only_for_kendex_at_the_exact_text_the_table_names`).
#[test]
fn orch_reads_its_fixtures_as_mentions_and_its_launcher_row_is_accepted() {
    let result = shipped("orch");
    let lane_launch = "skills/orch/scripts/lib/lane-launch.sh";
    let open_terminal = "skills/orch/tests/open-terminal-claude-handoff.sh";
    let oversee_succeed = "skills/orch/tests/oversee_succeed.sh";
    let overseer_watch = "skills/orch/tests/oversee_watch_overseer.sh";
    assert_eq!(found(&result), vec![], "{:#?}", result.findings);
    assert_eq!(result.safety.score, 100);
    assert_eq!(
        found_in(&result.accepted),
        vec![("safety-bypass", Severity::Critical, lane_launch)],
        "{:#?}",
        result.accepted
    );
    let mentioned = |location: &str| {
        result
            .mentions
            .iter()
            .filter(|mention| mention.location == location)
            .map(|mention| (mention.rule.as_str(), mention.line))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        mentioned(lane_launch),
        vec![("safety-bypass", Some(97))],
        "{:#?}",
        result.mentions
    );
    for (fixture, lines) in [
        (open_terminal, 6),
        (oversee_succeed, 20),
        (overseer_watch, 2),
    ] {
        let rules: Vec<&str> = mentioned(fixture)
            .into_iter()
            .map(|(rule, _)| rule)
            .collect();
        assert_eq!(
            rules,
            vec!["safety-bypass"; lines],
            "{fixture}: {:#?}",
            result.mentions
        );
    }
    let elsewhere: Vec<&str> = result
        .mentions
        .iter()
        .map(|mention| mention.location.as_str())
        .filter(|location| !location.ends_with(".md"))
        .filter(|location| {
            ![lane_launch, open_terminal, oversee_succeed, overseer_watch].contains(location)
        })
        .collect();
    assert_eq!(elsewhere, Vec::<&str>::new(), "{:#?}", result.mentions);
}

/// The iced-rs keyboard reference spells a Cyrillic letter inside the code
/// block of its `to_latin` example, the letter the example is about; the
/// review-gate decline corpus holds a reason written in Russian, the text
/// a test feeds the gate; and the harness-ci workflow library defines a
/// function named `gh_eval`. None of them is the package disguising or
/// running anything, so none is a finding, and the rows kendex's own table
/// accepts in review-gate and harness-ci cost the score nothing.
#[test]
fn a_quoted_letter_a_corpus_and_a_function_named_for_eval_are_not_findings() {
    for name in ["iced-rs", "review-gate", "harness-ci"] {
        let result = shipped(name);
        assert_eq!(found(&result), vec![], "{name}: {:#?}", result.findings);
        assert_eq!(result.safety.score, 100, "{name}");
    }
}
