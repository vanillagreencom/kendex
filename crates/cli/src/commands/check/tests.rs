use kendex_core::drift::report::{
    CheckReport, CheckStatus, Class, Line, Remedy, Section, page, render_full, render_plain,
};

use super::{screen, verdict};
use crate::ui::testing::{plain, rich, tagged};

fn line(class: Class, text: &str, remedy: Option<Remedy>) -> Line {
    Line {
        class,
        text: text.to_owned(),
        remedy,
    }
}

fn section(title: &str, lines: Vec<Line>) -> Section {
    Section {
        title: title.to_owned(),
        lines,
    }
}

/// A changed package, a blocked one, a decision between two directions, a
/// verdict still owed and a scope that could not be read: every kind of
/// row the check draws.
fn every_kind() -> CheckReport {
    CheckReport {
        status: CheckStatus::Unknown,
        sections: vec![
            section(
                "stale",
                vec![line(
                    Class::Drift,
                    "skill tidy: the source moved to 1.2.0",
                    Some(Remedy::Refresh { global: false }),
                )],
            ),
            section(
                "blocked by files already there",
                vec![line(
                    Class::Drift,
                    "unmanaged copy of skill 'commit-guards' at .claude/skills/commit-guards",
                    Some(Remedy::ReplaceUnmanaged { global: false }),
                )],
            ),
            section(
                "edited by hand",
                vec![line(
                    Class::Drift,
                    "agent reviewer: 1 file differs from its render",
                    Some(Remedy::Plan { global: false }),
                )],
            ),
            section(
                "source comparison needed",
                vec![line(Class::Unevaluated, "skill docs-writing", None)],
            ),
            section(
                "could not check",
                vec![line(
                    Class::Unknown,
                    "global: the install record is unreadable",
                    None,
                )],
            ),
        ],
        snapshot_age_secs: Some(300),
        project_target: None,
        deep_pass_owed: false,
    }
}

fn clean() -> CheckReport {
    CheckReport {
        status: CheckStatus::Clean,
        sections: Vec::new(),
        snapshot_age_secs: Some(300),
        project_target: None,
        deep_pass_owed: false,
    }
}

fn many(count: usize) -> CheckReport {
    CheckReport {
        status: CheckStatus::Drift,
        sections: vec![section(
            "stale",
            (0..count)
                .map(|n| line(Class::Drift, &format!("item-{n}"), None))
                .collect(),
        )],
        snapshot_age_secs: None,
        project_target: None,
        deep_pass_owed: false,
    }
}

/// The pilot on a terminal: the header, a section per kind with its count
/// and the colour of its most serious row, a row per item with its remedy
/// under it, the age and the next step as footnotes, and the verdict.
#[test]
fn the_check_draws_every_kind_of_row_rich() {
    let drawn = screen(&rich(100), &every_kind(), "/home/me/dev/app");
    assert_eq!(
        tagged(&drawn.head),
        ["<1;34>kendex check</>  <90>/home/me/dev/app</>"]
    );
    assert_eq!(
        tagged(&drawn.report),
        [
            "",
            "<1;33>stale</>  <90>1</>",
            "  <33>!</> skill tidy: the source moved to 1.2.0",
            "    <36>fix: kendex refresh</>",
            "",
            "<1;33>blocked by files already there</>  <90>1</>",
            "  <33>!</> unmanaged copy of skill 'commit-guards' at .claude/skills/commit-guards",
            "    <36>fix: kendex apply --replace-unmanaged</>",
            "",
            "<1;33>edited by hand</>  <90>1</>",
            "  <33>!</> agent reviewer: 1 file differs from its render",
            "    <36>see: kendex apply --plan</>",
            "",
            "<1;36>source comparison needed</>  <90>1</>",
            "  <36>•</> skill docs-writing",
            "",
            "<1;31>could not check</>  <90>1</>",
            "  <31>✗</> global: the install record is unreadable",
            "<90>(package evaluation: 5m ago)</>",
            "<90>Next: kendex refresh --scope project --yes in this checkout to refresh project packages.</>",
        ]
    );
    assert_eq!(
        tagged(&drawn.verdict),
        [
            "",
            "<31>✗</> <1>5 items need attention — see the lines above</>"
        ]
    );
}

/// The same run in the plain rendering: no header, and the report and the
/// verdict as the lines a script has always read.
#[test]
fn the_check_draws_every_kind_of_row_plain() {
    let drawn = screen(&plain(), &every_kind(), "/home/me/dev/app");
    assert!(drawn.head.is_empty(), "{:?}", drawn.head);
    assert_eq!(
        drawn.report,
        [
            "stale:",
            "  skill tidy: the source moved to 1.2.0 — fix: kendex refresh",
            "blocked by files already there:",
            "  unmanaged copy of skill 'commit-guards' at .claude/skills/commit-guards — fix: kendex apply --replace-unmanaged",
            "edited by hand:",
            "  agent reviewer: 1 file differs from its render — see: kendex apply --plan",
            "source comparison needed:",
            "  skill docs-writing",
            "could not check:",
            "  global: the install record is unreadable",
            "(package evaluation: 5m ago)",
            "Next: kendex refresh --scope project --yes in this checkout to refresh project packages.",
        ]
    );
    assert_eq!(
        drawn.verdict,
        ["5 items need attention — see the lines above"]
    );
}

/// A clean check draws no report, not even the age of a verdict nobody is
/// shown, and closes on the all-clear.
#[test]
fn a_clean_check_draws_only_the_all_clear() {
    let rich_run = screen(&rich(100), &clean(), "global");
    assert!(rich_run.report.is_empty(), "{:?}", rich_run.report);
    assert_eq!(
        tagged(&rich_run.verdict),
        [
            "",
            "<32>✓</> <1>all clear — every install matches its source</>"
        ]
    );
    let plain_run = screen(&plain(), &clean(), "global");
    assert!(plain_run.report.is_empty(), "{:?}", plain_run.report);
    assert_eq!(
        plain_run.verdict,
        ["all clear — every install matches its source"]
    );
}

/// The plain report is core's complete rendering line for line, so a
/// script reading `kendex check` reads what it always has, and the two
/// cannot disagree about which item offers which command.
#[test]
fn the_plain_report_is_the_complete_rendering() {
    for report in [every_kind(), clean(), many(12)] {
        let drawn = screen(&plain(), &report, "here").report;
        let complete = render_full(&report);
        assert_eq!(drawn, complete.lines().collect::<Vec<_>>());
    }
}

/// The verdict counts the rows the reader was shown, and points at them
/// as what to run only where every one of them carries a remedy.
#[test]
fn the_verdict_counts_the_rows_it_closes() {
    let rows: [(CheckReport, &str); 3] = [
        (clean(), "all clear — every install matches its source"),
        (many(1), "1 item needs attention — see the lines above"),
        (every_kind(), "5 items need attention — see the lines above"),
    ];
    for (report, want) in rows {
        assert_eq!(verdict(&page(&report)), want);
    }
    let mut remedied = many(2);
    for line in &mut remedied.sections[0].lines {
        line.remedy = Some(Remedy::Apply { global: false });
    }
    assert_eq!(
        verdict(&page(&remedied)),
        "2 items need attention — each line above says what to run"
    );
}

/// An explicit check draws every item; the session hook's bounded report
/// stays inside its budget and points at the explicit one.
#[test]
fn an_explicit_check_draws_every_item_while_the_session_hook_stays_bounded() {
    let report = many(12);
    let hook = render_plain(&report);
    assert!(hook.contains("see: kendex check"), "{hook}");
    assert!(!hook.contains("item-11"), "{hook}");

    let explicit = screen(&plain(), &report, "here").report.join("\n");
    assert!(explicit.contains("item-11"), "{explicit}");
    assert!(!explicit.contains("more — see:"), "{explicit}");
}
