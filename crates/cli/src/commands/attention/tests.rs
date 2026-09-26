use kendex_core::apply::Plan;
use kendex_core::engine::{
    CatalogSource, DriftCause, DriftRow, DriftState, EngineReport, ExcludedHook, ItemSafety,
    SafetyTarget,
};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::quality::{AuditResult, Finding, RULESET_VERSION, SafetyScore, Severity};

use super::*;
use crate::ui::testing::{plain, rich, tagged};

/// One skill's reading for one tool, carrying `findings` at a line each of
/// its catalog file.
fn scored(name: &str, harness: HarnessId, findings: &[(Severity, &str)]) -> ItemSafety {
    let root = format!("/home/one/.{}/skills/{name}", harness.name());
    let deducted: u32 = findings
        .iter()
        .map(|(severity, _)| severity.deduction())
        .sum();
    ItemSafety {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        targets: vec![SafetyTarget {
            harness,
            location: root.clone(),
        }],
        scope: Scope::Global,
        source: Some(CatalogSource {
            path: format!("skills/{name}"),
            verbatim: true,
            tree: true,
        }),
        advisory: AuditResult {
            findings: findings
                .iter()
                .zip(1..)
                .map(|((severity, message), line)| Finding {
                    rule: "rule".to_owned(),
                    severity: *severity,
                    location: format!("{root}/SKILL.md"),
                    line: Some(line),
                    message: (*message).to_owned(),
                    remediation: "fix it".to_owned(),
                })
                .collect(),
            mentions: Vec::new(),
            accepted: Vec::new(),
            skipped: Vec::new(),
            safety: SafetyScore {
                score: 100u32.saturating_sub(deducted),
                deductions: Vec::new(),
            },
            quality: None,
            ruleset: RULESET_VERSION,
        },
    }
}

/// Files kendex did not write where `name` would install for Claude Code.
fn in_the_way(name: &str) -> DriftRow {
    DriftRow {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        harness: HarnessId::Claude,
        scope: Scope::Global,
        state: DriftState::Conflict,
        detail: format!("/home/one/.claude/skills/{name}"),
        cause: Some(DriftCause::UnmanagedContent),
        compared: None,
        also_in_the_way: Vec::new(),
    }
}

const PIPES: &str = "pipes a download into a shell";

/// The owner's refresh, scaled down: forty clean packages, three flagged
/// (one of them rendered for two tools and firing on six lines of one
/// file), two conflicts, one note class said for three packages alike, and
/// six hook exclusions the catalog declares and nothing contradicts.
fn owners_refresh() -> EngineReport {
    let plan = Plan::landed(Scope::Global, Vec::new())
        .unwrap_or_else(|error| panic!("an empty global plan lands: {error}"));
    let mut report = EngineReport::observed(plan);
    report.safety = (0..40)
        .map(|n| scored(&format!("clean-{n:02}"), HarnessId::Claude, &[]))
        .collect();
    for harness in [HarnessId::Claude, HarnessId::Codex] {
        report
            .safety
            .push(scored("deploy", harness, &[(Severity::Critical, PIPES); 6]));
    }
    report.safety.push(scored(
        "release",
        HarnessId::Claude,
        &[(Severity::High, "overrides the agent's instructions")],
    ));
    report.safety.push(scored(
        "lint",
        HarnessId::Claude,
        &[(Severity::Low, "reads the environment")],
    ));
    report.drift = vec![in_the_way("blocker-a"), in_the_way("blocker-b")];
    report.notes = ["a", "b", "c"]
        .iter()
        .map(|name| {
            format!(
                "kendex-skill-description-missing: skill={name}\nThe skill has no description.\nAdd one to its frontmatter."
            )
        })
        .collect();
    report.excluded_hooks = [
        ("reviewer-read-only", HarnessId::Codex),
        ("reviewer-stop-check", HarnessId::Codex),
        ("reviewer-stop-check", HarnessId::Pi),
        ("session-drift-check", HarnessId::Pi),
        ("task-completed-check", HarnessId::Codex),
        ("task-completed-check", HarnessId::Pi),
    ]
    .iter()
    .map(|(name, harness)| ExcludedHook {
        name: (*name).to_owned(),
        harness: *harness,
    })
    .collect();
    report
}

fn drawn(style: &Style, verbose: bool) -> (Vec<String>, Attention) {
    let home = tempfile::tempdir().unwrap_or_else(|error| panic!("a temp home: {error}"));
    attention(
        style,
        &Env::host_rooted(home.path()),
        &owners_refresh(),
        verbose,
    )
}

/// A compact report holds what needs the reader and nothing else, in the
/// order they act on it: the two conflicts with their ways out, the three
/// flagged packages (the one rendered for two tools once, its six sites one
/// line naming the first, and no line for the second tool's copy), and the
/// note class said for three packages as one row, its two sentences each
/// a line of their own. Nothing of the clean forty, and nothing of the six
/// exclusions, which the fold counts for the ledger.
#[test]
fn a_compact_report_holds_only_what_needs_the_reader() {
    let (lines, attention) = drawn(&plain(), false);
    assert_eq!(
        lines,
        [
            "conflicts:",
            "  skill blocker-a for Claude Code: /home/one/.claude/skills/blocker-a already holds files kendex did not write",
            "    to keep those files: move them somewhere else first",
            "  skill blocker-b for Claude Code: /home/one/.claude/skills/blocker-b already holds files kendex did not write",
            "    to keep those files: move them somewhere else first",
            "  to install the packages this place lists instead: kendex apply --replace-unmanaged --global",
            "safety:",
            "  skill deploy for Claude Code, Codex scores 0/100",
            "    [critical] pipes a download into a shell at 6 sites (skills/deploy/SKILL.md:1)",
            "  skill release for Claude Code scores 85/100",
            "    [high] overrides the agent's instructions (skills/release/SKILL.md:1)",
            "  skill lint for Claude Code scores 97/100",
            "    [low] reads the environment (skills/lint/SKILL.md:1)",
            "notes:",
            "  kendex-skill-description-missing, 3 times: skill=a; skill=b; skill=c",
            "    The skill has no description.",
            "    Add one to its frontmatter.",
        ]
    );
    assert_eq!(attention.blocked.len(), 2);
    assert_eq!(
        attention.folded,
        40 + 6,
        "the clean forty and six exclusions"
    );
}

/// A verbose report draws every package, clean ones included, every drift
/// row in place of the conflict rows, and the exclusions as one line with
/// the count and each hook's tools. It folds nothing.
#[test]
fn a_verbose_report_draws_every_package_and_the_exclusions() {
    let (lines, attention) = drawn(&plain(), true);
    let packages: Vec<&String> = lines
        .iter()
        .filter(|line| line.starts_with("  skill ") && line.contains(" scores "))
        .collect();
    assert_eq!(packages.len(), 43, "{lines:#?}");
    for clean in 0..40 {
        let line = format!("  skill clean-{clean:02} for Claude Code scores 100/100");
        assert!(lines.contains(&line), "{line:?} missing: {lines:#?}");
    }
    assert!(lines.contains(&"drift:".to_owned()), "{lines:#?}");
    assert!(
        lines.contains(
            &"  4 hooks not written for the tools their own harnesses line leaves out: reviewer-read-only (codex), reviewer-stop-check (codex, pi), session-drift-check (pi), task-completed-check (codex, pi)"
                .to_owned()
        ),
        "{lines:#?}"
    );
    assert_eq!(attention.folded, 0);
}

/// On a terminal each severity has its own glyph in its own colour, and a
/// clean package its tick: critical, high, low and clean are four marks,
/// and a note a fifth.
#[test]
fn each_severity_draws_its_own_glyph() {
    let (lines, _) = drawn(&rich(100), true);
    let tagged = tagged(&lines);
    for mark in [
        "  <31>◉</> skill deploy",
        "    <31>◉</> [critical]",
        "  <33>◐</> skill release",
        "    <33>◐</> [high]",
        "  <90>○</> skill lint",
        "    <90>○</> [low]",
        "  <32>✓</> skill clean-00",
        "  <36>•</> kendex-skill-description-missing",
    ] {
        assert!(
            tagged.iter().any(|line| line.starts_with(mark)),
            "no line opens with {mark:?}: {tagged:#?}"
        );
    }
}
