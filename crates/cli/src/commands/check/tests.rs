use kendex_core::drift::report::{
    CheckReport, CheckStatus, Class, Line, Remedy, Section, Sentence, page, render_plain,
};

use super::{screen, verdict};
use crate::ui::testing::{plain, rich, tagged};

fn line(class: Class, text: &str, remedy: Option<Remedy>) -> Line {
    Line {
        class,
        text: text.to_owned().into(),
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
/// row the check draws. The last section mixes classes the way
/// `fold_commit_hooks` folds them, a drift line above one that could not
/// be checked.
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
            section(
                "commit hooks",
                vec![
                    line(Class::Drift, "pre-commit is not armed", None),
                    line(Class::Unknown, "commit-msg could not be read", None),
                ],
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
            "<1;33>source comparison needed</>  <90>1</>",
            "  <36>•</> skill docs-writing",
            "",
            "<1;31>could not check</>  <90>1</>",
            "  <31>✗</> global: the install record is unreadable",
            "",
            "<1;31>commit hooks</>  <90>2</>",
            "  <33>!</> pre-commit is not armed",
            "  <31>✗</> commit-msg could not be read",
            "<90>(package evaluation: 5m ago)</>",
            "<90>Next: kendex refresh --scope project --yes in this checkout to refresh project packages.</>",
        ]
    );
    assert_eq!(
        tagged(&drawn.verdict),
        [
            "",
            "<31>✗</> <1>7 items need attention — see the lines above</>"
        ]
    );
}

/// At 40 columns the next step's sentence wraps and its command does not:
/// `kendex refresh --scope project --yes` moves to a line of its own rather
/// than leaving `--scope project --yes` to read as a second command.
#[test]
fn a_narrow_terminal_keeps_the_next_steps_command_whole() {
    let drawn = screen(&rich(40), &every_kind(), "here");
    let at = drawn
        .report
        .iter()
        .position(|line| line.contains("Next:"))
        .unwrap_or_else(|| panic!("no next step: {:?}", drawn.report));
    assert_eq!(
        tagged(&drawn.report[at..]),
        [
            "<90>Next:</>",
            "<90>kendex refresh --scope project --yes in</>",
            "<90>this checkout to refresh project</>",
            "<90>packages.</>",
        ]
    );
}

/// A command inside an item's own text, the backup a stale drift hook
/// line names, is drawn whole on a line of its own when it is wider than
/// the room, while the prose around it wraps; plain keeps the line as the
/// joined text.
#[test]
fn a_command_in_an_item_is_never_broken() {
    let script = "/home/me/dev/app/.claude/hooks/kendex-drift-check.sh";
    let backup = format!("cp -i {script} {script}.backup");
    let text = Sentence::default()
        .prose("the session drift hook script is from an older kendex; backup first if needed: ")
        .command(&backup);
    let report = CheckReport {
        status: CheckStatus::Drift,
        sections: vec![section(
            "stale",
            vec![Line {
                class: Class::Drift,
                text: text.clone(),
                remedy: None,
            }],
        )],
        snapshot_age_secs: None,
        project_target: None,
        deep_pass_owed: false,
    };
    let rows = tagged(&screen(&rich(80), &report, "here").report);
    assert_eq!(
        rows,
        [
            "",
            "<1;33>stale</>  <90>1</>",
            "  <33>!</> the session drift hook script is from an older kendex; backup first if",
            "    needed:",
            &format!("    {backup}"),
        ]
    );
    assert_eq!(
        screen(&plain(), &report, "here").report,
        ["stale:".to_owned(), format!("  {text}")]
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
            "commit hooks:",
            "  pre-commit is not armed",
            "  commit-msg could not be read",
            "(package evaluation: 5m ago)",
            "Next: kendex refresh --scope project --yes in this checkout to refresh project packages.",
        ]
    );
    assert_eq!(
        drawn.verdict,
        ["7 items need attention — see the lines above"]
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

/// A check that found drift and nothing it could not check closes on a
/// decision, not a failure.
#[test]
fn a_drift_check_closes_on_a_decision() {
    let drawn = screen(&rich(100), &many(2), "here");
    assert_eq!(
        tagged(&drawn.verdict),
        [
            "",
            "<33>!</> <1>2 items need attention — see the lines above</>"
        ]
    );
}

/// The verdict counts the rows the reader was shown, and points at them
/// as what to run only where every one of them carries a remedy.
#[test]
fn the_verdict_counts_the_rows_it_closes() {
    let rows: [(CheckReport, &str); 3] = [
        (clean(), "all clear — every install matches its source"),
        (many(1), "1 item needs attention — see the lines above"),
        (every_kind(), "7 items need attention — see the lines above"),
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
