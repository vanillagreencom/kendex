use kendex_core::apply::Plan;
use kendex_core::engine::{
    CatalogSource, DriftCause, DriftRow, DriftState, EngineReport, ExcludedHook, ItemSafety,
    SafetyTarget,
};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::quality::{
    AuditResult, Finding, RULESET_VERSION, SafetyScore, Severity, SkippedRule,
};

use super::*;
use crate::commands::advisory::Listing;
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

/// What the rules read past in `release`'s catalog file, cited at `line`.
fn read_past(message: &str, line: u32) -> Finding {
    Finding {
        rule: "rule".to_owned(),
        severity: Severity::High,
        location: "/home/one/.claude/skills/release/SKILL.md".to_owned(),
        line: Some(line),
        message: message.to_owned(),
        remediation: "fix it".to_owned(),
    }
}

/// The owner's refresh, scaled down: forty clean packages, three flagged
/// (one of them rendered for two tools and firing on six lines of one
/// file, one carrying a mention and an accepted finding beside its own),
/// one a rule had nothing to read in, two conflicts, one note class said
/// for three packages alike and once more with other words, and six hook
/// exclusions the catalog declares and nothing contradicts.
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
    let mut release = scored(
        "release",
        HarnessId::Claude,
        &[(Severity::High, "overrides the agent's instructions")],
    );
    release.advisory.mentions = vec![read_past("names --no-verify", 7)];
    release.advisory.accepted = vec![read_past("names rm -rf /", 9)];
    report.safety.push(release);
    report.safety.push(scored(
        "lint",
        HarnessId::Claude,
        &[(Severity::Low, "reads the environment")],
    ));
    let mut unread = scored("unread", HarnessId::Claude, &[]);
    unread.advisory.skipped = vec![SkippedRule {
        rule: "rule".to_owned(),
        reason: "this item ships no script to read".to_owned(),
    }];
    report.safety.push(unread);
    report.drift = vec![in_the_way("blocker-a"), in_the_way("blocker-b")];
    report.notes = ["a", "b", "c"]
        .iter()
        .map(|name| {
            format!(
                "kendex-skill-description-missing: skill={name}\nThe skill has no description.\nAdd one to its frontmatter."
            )
        })
        .chain(std::iter::once(
            "kendex-skill-description-missing: skill=d\nThe skill's description is empty.".to_owned(),
        ))
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

fn drawn(style: &Style, listing: Listing) -> (Vec<String>, Attention) {
    let home = tempfile::tempdir().unwrap_or_else(|error| panic!("a temp home: {error}"));
    attention(
        style,
        &Env::host_rooted(home.path()),
        &owners_refresh(),
        listing,
    )
}

/// A compact report holds what needs the reader and nothing else, in the
/// order they act on it: the two conflicts with their ways out, the three
/// flagged packages (the one rendered for two tools once, its six sites one
/// line naming the first, and no line for the second tool's copy, and
/// nothing of what the rules read past), the package a rule could not read,
/// and the note class said for three packages as one row, its two
/// sentences each a line of their own, beside the fourth that says it in
/// other words. Nothing of the clean forty, and nothing of the six
/// exclusions, and the report says it left detail out.
#[test]
fn a_compact_report_holds_only_what_needs_the_reader() {
    let (lines, attention) = drawn(&plain(), Listing::Attention);
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
            "  skill unread for Claude Code scores 100/100",
            "    not fully checked: 1 rule(s) had nothing to read — this item ships no script to read",
            "notes:",
            "  kendex-skill-description-missing, 3 times: skill=a; skill=b; skill=c",
            "    The skill has no description.",
            "    Add one to its frontmatter.",
            "  kendex-skill-description-missing: skill=d",
            "    The skill's description is empty.",
        ]
    );
    assert_eq!(attention.blocked.len(), 2);
    assert!(attention.folded, "the report left detail out");
}

/// A verbose report draws every package, clean ones included, every site a
/// finding fired at, what the rules read past, every drift row in place of
/// the conflict rows, and the exclusions as one line with the count and
/// each hook's tools. It folds nothing.
#[test]
fn a_verbose_report_draws_every_package_and_the_exclusions() {
    let (lines, attention) = drawn(&plain(), Listing::Verbose);
    let packages: Vec<&String> = lines
        .iter()
        .filter(|line| line.starts_with("  skill ") && line.contains(" scores "))
        .collect();
    assert_eq!(packages.len(), 44, "{lines:#?}");
    let sites: Vec<&String> = lines
        .iter()
        .filter(|line| line.starts_with("    [critical] pipes a download into a shell ("))
        .collect();
    assert_eq!(
        sites.len(),
        6,
        "every site on a line of its own: {lines:#?}"
    );
    for aside in [
        "    named, not run: names --no-verify (skills/release/SKILL.md:7)",
        "    accepted in kendex's own package: names rm -rf / (skills/release/SKILL.md:9)",
    ] {
        assert!(lines.contains(&aside.to_owned()), "{aside:?}: {lines:#?}");
    }
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
    assert!(!attention.folded);
}

/// A compact report that leaves nothing out says so: one flagged package
/// with one finding at one site, and nothing else, draws what a verbose
/// run draws.
#[test]
fn a_compact_report_hiding_nothing_folds_nothing() {
    let plan = Plan::landed(Scope::Global, Vec::new())
        .unwrap_or_else(|error| panic!("an empty global plan lands: {error}"));
    let mut report = EngineReport::observed(plan);
    report.safety = vec![scored(
        "lint",
        HarnessId::Claude,
        &[(Severity::Low, "reads the environment")],
    )];
    let home = tempfile::tempdir().unwrap_or_else(|error| panic!("a temp home: {error}"));
    let (lines, attention) = attention(
        &plain(),
        &Env::host_rooted(home.path()),
        &report,
        Listing::Attention,
    );
    assert!(!lines.is_empty(), "the fixture draws nothing");
    assert!(!attention.folded, "{lines:#?}");
}

/// On a terminal each severity has its own glyph in its own colour, and a
/// clean package its tick: critical, high, low and clean are four marks,
/// and a note a fifth.
#[test]
fn each_severity_draws_its_own_glyph() {
    let (lines, _) = drawn(&rich(100), Listing::Verbose);
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
