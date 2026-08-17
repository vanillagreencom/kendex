//! The quiet rendering and its budgets. Both session adapters relay this text
//! verbatim into an agent's context, so what it may spend — in lines and in
//! bytes — is a property of the renderer, never of how large an inventory
//! happens to be.

use super::*;

#[test]
fn quiet_render_is_empty_for_a_clean_scope_and_names_the_scope_on_drift() {
    let clean = ScopeReport {
        scope: "project",
        installed: 1,
        current: vec![Item::new("alpha", ItemKind::Skill)],
        ..ScopeReport::default()
    };
    let mut out = String::new();
    render_scope(&mut out, &clean, true);
    assert!(
        out.is_empty(),
        "quiet clean scope must print nothing: {out:?}"
    );
    // Control: the verbose render of the same scope is not empty.
    render_scope(&mut out, &clean, false);
    assert!(out.contains("✓ alpha (skill)"));

    let drifted = ScopeReport {
        scope: "global",
        installed: 2,
        outdated: vec![Item::new("alpha", ItemKind::Skill)],
        removed: vec![Item::new("old", ItemKind::Hook)],
        available: vec![AvailableItem {
            name: "beta".into(),
            kind: ItemKind::Skill,
            source: "owner/repo".into(),
        }],
        ..ScopeReport::default()
    };
    let mut out = String::new();
    render_scope(&mut out, &drifted, true);
    assert!(out.starts_with("vstack drift — global scope:"), "{out}");
    assert!(out.contains("`vstack refresh`"), "{out}");
    assert!(out.contains("`vstack remove -g <name>`"), "{out}");
    assert!(
        out.contains("skills (`vstack add -g owner/repo --skill <name>`): beta"),
        "the suggestion must name the source it came from: {out}"
    );
    assert!(
        !out.contains("✓"),
        "quiet render must not list current items"
    );
    assert_eq!(
        out.matches("alpha (skill)").count(),
        1,
        "listed once: {out}"
    );
}

#[test]
fn quiet_report_stays_silent_when_only_suggestions_and_cache_warnings_exist() {
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: false,
        background_refresh_error: None,
        cache_refresh_failures: vec![CacheRefreshFailure {
            source: "owner/repo".into(),
            age_secs: 7200,
            reason: "fetch has been failing for 2h (last attempt 2h ago)".into(),
            persistent: false,
        }],
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 1,
            available: vec![AvailableItem {
                name: "beta".into(),
                kind: ItemKind::Skill,
                source: "owner/repo".into(),
            }],
            ..ScopeReport::default()
        }],
    };
    assert_eq!(report.outcome(), CheckOutcome::Clean);
    assert!(render_report(&report, true).is_empty());
    // Control: verbose output carries both.
    let verbose = render_report(&report, false);
    assert!(verbose.contains("beta"), "{verbose}");
    assert!(verbose.contains("is not up to date"), "{verbose}");
    assert!(verbose.contains("failing for 2h"), "{verbose}");
    // With drift, quiet output carries them alongside.
    let mut drifted = report.clone();
    drifted.drift = true;
    drifted.scopes[0]
        .outdated
        .push(Item::new("alpha", ItemKind::Skill));
    let quiet = render_report(&drifted, true);
    assert!(
        quiet.contains("beta") && quiet.contains("is not up to date"),
        "{quiet}"
    );
}

#[test]
fn the_quiet_report_is_bounded_per_section_while_counts_stay_exact() {
    let many: Vec<Item> = (0..25)
        .map(|i| Item::new(format!("item-{i:02}"), ItemKind::Skill))
        .collect();
    let refs: Vec<MissingSkillRef> = (0..14)
        .map(|i| MissingSkillRef {
            agent: format!("agent-{i:02}"),
            skill: format!("skill-{i:02}"),
        })
        .collect();
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: Vec::new(),
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 25,
            outdated: many.clone(),
            missing_skill_refs: refs,
            source_issues: vec![SourceIssue {
                source: "owner/repo".into(),
                problem: SourceProblem::Discovery {
                    failures: (0..13)
                        .map(|i| format!("asset-{i:02} is unreadable"))
                        .collect(),
                },
            }],
            ..ScopeReport::default()
        }],
    };

    let quiet = render_report(&report, true);
    let item_lines = quiet.matches("(skill)").count();
    assert_eq!(item_lines, QUIET_SECTION_LIMIT, "{quiet}");
    assert!(quiet.contains("25 outdated"), "count stays exact: {quiet}");
    assert!(
        quiet.contains("… and 15 more (run `vstack check` for the full report)"),
        "{quiet}"
    );
    assert_eq!(
        quiet.matches("references skill").count(),
        QUIET_SECTION_LIMIT
    );
    assert!(quiet.contains("… and 4 more"), "{quiet}");
    assert_eq!(quiet.matches("is unreadable").count(), QUIET_SECTION_LIMIT);
    assert!(quiet.contains("… and 3 more"), "{quiet}");
    // Bounded by construction: a section cannot outgrow the cap however
    // large the inventory is.
    assert!(quiet.lines().count() < 45, "{quiet}");

    // Control: the interactive report is still complete.
    let full = render_report(&report, false);
    assert_eq!(full.matches("(skill)").count(), 25, "{full}");
    assert_eq!(full.matches("is unreadable").count(), 13, "{full}");
    assert!(!full.contains("and 15 more"), "{full}");
}

/// Per-section caps bound each section; only this bounds their SUM. A project
/// with dozens of broken sources renders a header plus a detail list per
/// source, and every line of it is relayed verbatim into an agent's context by
/// both session adapters.
#[test]
fn the_whole_quiet_report_is_bounded_and_names_what_it_left_out() {
    let broken_source = |n: usize| SourceIssue {
        source: format!("/sources/{n:02}"),
        problem: SourceProblem::Unreadable {
            entries: (0..4).map(|i| format!("item-{n:02}-{i}")).collect(),
            reasons: (0..4).map(|i| format!("reason {n:02}-{i}")).collect(),
        },
    };
    let scope = |scope: &'static str| ScopeReport {
        scope,
        installed: 40,
        source_issues: (0..20).map(broken_source).collect(),
        available: (0..20)
            .map(|n| AvailableItem {
                name: format!("offer-{n:02}"),
                kind: ItemKind::Skill,
                source: format!("/sources/{n:02}"),
            })
            .collect(),
        ..ScopeReport::default()
    };
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: Vec::new(),
        scopes: vec![scope("project"), scope("global")],
    };

    let quiet = render_report(&report, true);
    // What the per-section caps alone produce: bounded per section, unbounded
    // in total.
    let mut unbudgeted = String::new();
    render_scope(&mut unbudgeted, &report.scopes[0], true);
    render_scope(&mut unbudgeted, &report.scopes[1], true);
    let rendered = quiet.lines().count();
    assert!(
        rendered <= QUIET_REPORT_LINE_BUDGET + 1 && rendered < unbudgeted.lines().count(),
        "the whole quiet report must fit the budget plus its summary, saw {rendered}:\n{quiet}"
    );

    // The summary's count is the truth: what was rendered plus what it names
    // is the whole per-section-capped report.
    let summary = quiet
        .lines()
        .last()
        .expect("a trimmed report closes with its summary");
    let omitted: usize = summary
        .split_whitespace()
        .find_map(|word| word.parse().ok())
        .expect("the summary names a count");
    assert!(
        summary.contains("run `vstack check` for the full report"),
        "the summary must name the way to the full report: {summary}"
    );
    assert_eq!(
        rendered - 1 + omitted,
        unbudgeted.lines().count(),
        "the omitted count must be the real remainder: {quiet}"
    );

    // Drift claims the budget first: with suggestions and drift competing,
    // the drift headers survive and the offers are what goes.
    assert!(quiet.contains("cannot be inventoried"), "{quiet}");
    assert!(
        !quiet.contains("available in source but not installed"),
        "suggestions must give up their lines before drift does: {quiet}"
    );

    // Control: the interactive report of the same thing is complete.
    let full = render_report(&report, false);
    assert_eq!(
        full.matches("cannot be inventoried").count(),
        40,
        "the interactive report is never budgeted"
    );
    assert!(
        full.lines().count() > QUIET_REPORT_LINE_BUDGET * 2,
        "{full}"
    );

    // Control: an ordinary report is byte-identical to the unbudgeted
    // rendering — the budget only ever cuts.
    let small = CheckReport {
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 2,
            outdated: vec![Item::new("alpha", ItemKind::Skill)],
            available: vec![AvailableItem {
                name: "beta".into(),
                kind: ItemKind::Skill,
                source: "owner/repo".into(),
            }],
            ..ScopeReport::default()
        }],
        ..report.clone()
    };
    let mut expected = String::new();
    render_scope(&mut expected, &small.scopes[0], true);
    assert_eq!(render_report(&small, true), expected);
}

/// Item name length is deliberately unrestricted, and the line budget counts
/// LINES: one valid long name joined raw into the suggestion line passed the
/// budget untouched and put an arbitrarily large payload into an agent's
/// context. Every displayed name is bounded, and the whole report is bounded
/// on both axes.
#[test]
fn no_single_line_can_carry_an_unbounded_name_into_the_quiet_report() {
    // Long enough that a raw join is unmistakable, small enough that the byte
    // budget would not have dropped the line anyway: the two bounds are proven
    // one at a time or neither is proven at all.
    let long = "a".repeat(DISPLAY_LIMIT * 5);
    let report = CheckReport {
        version: 1,
        cli_version: "0.0.0",
        cli_hash: "abc",
        drift: true,
        background_refresh_error: None,
        cache_refresh_failures: Vec::new(),
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 1,
            outdated: vec![Item::new("alpha", ItemKind::Skill)],
            available: (0..3)
                .map(|n| AvailableItem {
                    name: format!("{long}-{n:02}"),
                    kind: ItemKind::Skill,
                    source: "owner/repo".into(),
                })
                .collect(),
            ..ScopeReport::default()
        }],
    };

    let quiet = render_report(&report, true);
    assert!(
        !quiet.contains(&long),
        "no name reaches the report at full length: {} bytes",
        quiet.len()
    );
    assert!(
        quiet.len() <= QUIET_REPORT_BYTE_BUDGET + 200,
        "the whole quiet report stays inside the byte budget, saw {} bytes",
        quiet.len()
    );
    assert!(
        quiet.lines().count() <= QUIET_REPORT_LINE_BUDGET + 1,
        "…and inside the line budget: {quiet}"
    );

    // Control: a copy-paste command argument is still complete and quoted so
    // the pasted command runs on the literal name — truncating it would be a
    // command that cannot work.
    let hostile = format!("{} ; rm -rf /", "b".repeat(DISPLAY_LIMIT * 2));
    let refs = |count: usize, skill: &str| CheckReport {
        scopes: vec![ScopeReport {
            scope: "project",
            installed: 1,
            missing_skill_refs: (0..count)
                .map(|n| MissingSkillRef {
                    agent: format!("agent-{n:02}"),
                    skill: skill.to_string(),
                })
                .collect(),
            ..ScopeReport::default()
        }],
        ..report.clone()
    };
    let quiet = render_report(&refs(1, &hostile), true);
    assert!(
        quiet.contains(&format!("'{hostile}'")),
        "the command argument is complete and single-quoted: {quiet}"
    );
    assert_eq!(
        quiet.matches(&hostile).count(),
        1,
        "…while the prose copy of the same name is truncated: {quiet}"
    );

    // …which is exactly why lines alone cannot bound the report: a handful of
    // those lines is well inside the line budget and megabytes of context.
    let huge = "c".repeat(4096);
    let quiet = render_report(&refs(12, &huge), true);
    assert!(
        quiet.lines().count() <= QUIET_SECTION_LIMIT + 3,
        "the line budget alone never trims this: {}",
        quiet.lines().count()
    );
    assert!(
        quiet.len() <= QUIET_REPORT_BYTE_BUDGET + 200,
        "the byte budget does, saw {} bytes",
        quiet.len()
    );
}
