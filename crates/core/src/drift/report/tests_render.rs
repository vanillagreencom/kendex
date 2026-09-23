//! Rendering: budgets that count their own overflow lines, identifiers
//! validated at the command position, and foreign text scrubbed.

use super::tests::{
    env_in, manifest_with_remote, package, project_scope, snapshot_with, write_manifest,
};
use super::text::{FOREIGN_CHARS, RELAYED_CHARS, shown};
use super::*;
use crate::drift::snapshot::PackageSnapshot;

#[test]
fn section_budget_counts_its_overflow_line_inside_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    let packages: Vec<PackageSnapshot> = (0..14)
        .map(|i| PackageSnapshot {
            update_available: true,
            ..package(&format!("pkg-{i:02}"))
        })
        .collect();
    snapshot_with(&env, &scope, packages);

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    let section_lines: Vec<&str> = text
        .lines()
        .skip_while(|line| *line != "stale:")
        .skip(1)
        .take_while(|line| line.starts_with("  "))
        .collect();
    assert_eq!(section_lines.len(), SECTION_ITEMS, "{text}");
    assert_eq!(
        *section_lines.last().unwrap(),
        "  … 5 more — see: kendex check"
    );
}

#[test]
fn report_budget_counts_its_truncation_line_and_never_cuts_a_line() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    // Every section overflowing plus long names pushes past both caps.
    let mut packages = Vec::new();
    for i in 0..14 {
        let long = format!("very-long-package-name-{i:02}-{}", "x".repeat(150));
        packages.push(PackageSnapshot {
            update_available: true,
            ..package(&long)
        });
        packages.push(PackageSnapshot {
            edited: true,
            ..package(&format!("edited-{long}"))
        });
        packages.push(PackageSnapshot {
            mixed: true,
            ..package(&format!("mixed-{long}"))
        });
    }
    snapshot_with(&env, &scope, packages);

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines.len() <= REPORT_LINES, "{} lines", lines.len());
    assert!(text.len() <= REPORT_BYTES, "{} bytes", text.len());
    assert!(
        lines.last().unwrap().starts_with("… report truncated ("),
        "{text}"
    );
    // No line was cut mid-way: every remedy that rendered is complete.
    for line in &lines {
        if line.contains("fix: kendex fork") {
            assert!(
                line.trim_end()
                    .ends_with(|c: char| c == 'x' || c.is_ascii_digit()),
                "truncated command arguments in {line:?}"
            );
        }
    }
}

/// Every remedy against a project the command has to name, and the same
/// remedies against one it does not.
///
/// A project scope is ordinarily the directory a command is typed in, and
/// the command carries no destination at all. Where it is a linked git
/// worktree the destination has to be in the words, and only `refresh`,
/// `apply` and `updates --apply` have a flag for it. The other four keep
/// their command and are marked as running somewhere else: a reader left
/// with the drift line and no remedy has nothing to act on.
#[test]
fn a_named_project_reaches_the_verbs_that_take_it_and_sends_the_rest_elsewhere() {
    let target = std::path::Path::new("/w/lane");
    let here = |command: &str| Some(Fix::Here(command.to_owned()));
    let elsewhere = |command: &str| Some(Fix::Elsewhere(command.to_owned()));
    let rows: [(&str, Remedy, Option<Fix>, Option<Fix>); 8] = [
        (
            "apply",
            Remedy::Apply { global: false },
            here("kendex apply"),
            here("kendex apply --project-path '/w/lane'"),
        ),
        (
            "apply --replace-unmanaged",
            Remedy::ReplaceUnmanaged { global: false },
            here("kendex apply --replace-unmanaged"),
            here("kendex apply --replace-unmanaged --project-path '/w/lane'"),
        ),
        (
            "refresh",
            Remedy::Refresh { global: false },
            here("kendex refresh"),
            here("kendex refresh --project-path '/w/lane'"),
        ),
        (
            "apply --plan",
            Remedy::Plan { global: false },
            here("kendex apply --plan"),
            here("kendex apply --plan --project-path '/w/lane'"),
        ),
        (
            "update-pi, which has no such flag",
            Remedy::UpdatePi { global: false },
            here("kendex update-pi --scope project"),
            elsewhere("kendex update-pi --scope project"),
        ),
        (
            "remove, which has none either",
            Remedy::Remove {
                name: "gh".into(),
                global: false,
            },
            here("kendex remove gh"),
            elsewhere("kendex remove gh"),
        ),
        (
            "add, which has none either",
            Remedy::Add {
                kind: ItemKind::Skill,
                name: "gh".into(),
                global: false,
            },
            here("kendex add --skill gh"),
            elsewhere("kendex add --skill gh"),
        ),
        (
            "fork, which has none either",
            Remedy::Fork {
                kind: ItemKind::Skill,
                name: "gh".into(),
                global: false,
            },
            here("kendex fork skill gh"),
            elsewhere("kendex fork skill gh"),
        ),
    ];
    for (label, remedy, unnamed, named) in rows {
        assert_eq!(remedy.render(None), unnamed, "{label}, unnamed");
        assert_eq!(remedy.render(Some(target)), named, "{label}, named");
    }
    // The personal scope is one place on the machine and is never named by
    // path, so a target in hand changes nothing about it.
    assert_eq!(
        Remedy::Apply { global: true }.render(Some(target)),
        here("kendex apply --global")
    );
    // A path is whatever the filesystem allowed, and this is a command
    // position: the quoting is what keeps it one word.
    assert_eq!(
        Remedy::Refresh { global: false }.render(Some(std::path::Path::new("/w/my lane"))),
        here("kendex refresh --project-path '/w/my lane'")
    );
}

/// What the reader is handed, through the renderer rather than the
/// remedy: a verb that takes the name carries it, and one that does not
/// keeps its command, marked with why it will not run here.
///
/// Asserted here and not only on `render`, because the reader never sees
/// `render`: a suppression the renderer swallowed would be a line with no
/// fix at all, which is what this shape exists to prevent.
#[test]
fn a_rendered_report_keeps_a_fix_on_every_line_that_had_one() {
    let line = |text: &str, remedy: Remedy| Line {
        class: Class::Drift,
        text: text.to_owned(),
        remedy: Some(remedy),
    };
    let report = CheckReport {
        status: CheckStatus::Drift,
        sections: vec![Section {
            title: "stale".to_owned(),
            lines: vec![
                line(
                    "'orch' does not match its source",
                    Remedy::Apply { global: false },
                ),
                line(
                    "'orch' was edited on disk",
                    Remedy::Fork {
                        kind: ItemKind::Skill,
                        name: "orch".into(),
                        global: false,
                    },
                ),
                line(
                    "'dev' is no longer offered by its source",
                    Remedy::Remove {
                        name: "dev".into(),
                        global: false,
                    },
                ),
                line(
                    "agent 'one' references skill 'gh' which is not declared",
                    Remedy::Add {
                        kind: ItemKind::Skill,
                        name: "gh".into(),
                        global: false,
                    },
                ),
            ],
        }],
        project_target: Some(std::path::PathBuf::from("/w/lane")),
        ..check_report()
    };

    let text = render_plain(&report);
    assert!(
        text.contains("— fix: kendex apply --project-path '/w/lane'\n"),
        "{text}"
    );
    for command in [
        "kendex fork skill orch",
        "kendex remove dev",
        "kendex add --skill gh",
    ] {
        assert!(
            text.contains(&format!(
                "— fix: {command} (no --project-path form; the block-worktree-refresh hook refuses this verb inside a linked worktree)"
            )),
            "{command} missing its marker: {text}"
        );
    }
}

#[test]
fn an_unsafe_identifier_drops_the_remedy_not_the_line() {
    let remedy = Remedy::Remove {
        name: "evil; rm -rf /".into(),
        global: false,
    };
    assert_eq!(remedy.render(None), None);
    let fine = Remedy::Remove {
        name: "gh".into(),
        global: true,
    };
    assert_eq!(
        fine.render(None),
        Some(Fix::Here("kendex remove gh --global".to_owned()))
    );
    assert_eq!(
        Remedy::Add {
            kind: ItemKind::Skill,
            name: "-flag".into(),
            global: false
        }
        .render(None),
        None,
        "a name shaped like an option never reaches a command position"
    );
}

#[test]
fn a_manual_move_quotes_paths_for_the_platform_shell() {
    let posix = Remedy::MoveAside {
        from: "/tmp/it's/extensions/pkg".into(),
        to: "/tmp/it's".into(),
        windows: false,
    };
    assert_eq!(
        posix.render(None),
        Some(Fix::Here(
            "mv -i '/tmp/it'\\''s/extensions/pkg' '/tmp/it'\\''s'".to_owned()
        ))
    );

    let powershell = Remedy::MoveAside {
        from: r"C:\Users\Pat's\extensions\pkg".into(),
        to: r"C:\Users\Pat's".into(),
        windows: true,
    };
    assert_eq!(
        powershell.render(None),
        Some(Fix::Here(
            "Move-Item -LiteralPath 'C:\\Users\\Pat''s\\extensions\\pkg' -Destination 'C:\\Users\\Pat''s' -Confirm"
                .to_owned()
        ))
    );

    let control = Remedy::MoveAside {
        from: "/tmp/bad\nname".into(),
        to: "/tmp".into(),
        windows: false,
    };
    assert_eq!(control.render(None), None);
}

#[test]
fn control_characters_and_secrets_never_reach_the_report() {
    let cleaned =
        shown("evil\x1b[2Jname with sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345 inside");
    assert!(!cleaned.contains('\x1b'), "{cleaned}");
    assert!(
        !cleaned.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"),
        "{cleaned}"
    );
}

#[test]
fn a_manifest_this_build_cannot_read_reads_as_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let manifest_path = crate::manifest::manifest_path(&env, &scope);
    std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    // No schema key: the v1 shape.
    std::fs::write(&manifest_path, "[agents.orch]\nsource = \"kendex\"\n").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    let said = render_plain(&report);
    assert!(said.contains("no schema"), "{said}");
    assert!(said.contains("install fresh"), "{said}");
}

/// A folded line kendex composed itself is spelled whole.
///
/// The `commit hooks` leftover line exists to name the hook files a person
/// must edit by hand. It ran past the foreign-text cut on macOS, where the
/// temp root resolves through `/private/var`, and named the first file and
/// half the second — advice about files it then declined to name. Length
/// is not what makes a line foreign, so a longer path must not bring the
/// cut back.
#[test]
fn a_line_kendex_composed_is_named_in_full() {
    let deep = format!("/private/var/folders/{}/proj/.git/hooks", "d".repeat(200));
    let text = format!(
        "commit-guards armed the commit hooks, so every commit fails until {deep}/pre-commit, {deep}/commit-msg are dealt with"
    );
    let mut report = check_report();
    fold(&mut report, "commit hooks", Class::Drift, Text::Own(text));

    let rendered = render_plain(&report);
    assert!(
        rendered.contains(&format!("{deep}/commit-msg")),
        "the second file lost its name:\n{rendered}"
    );
    assert_eq!(report.status, CheckStatus::Drift);
}

/// What kendex composed still cannot carry a control character or a
/// credential: a path is read off a disk, and a newline in one would forge
/// a second report line.
#[test]
fn a_composed_line_is_scrubbed_even_though_it_is_not_cut() {
    let mut report = check_report();
    fold(
        &mut report,
        "commit hooks",
        Class::Drift,
        Text::Own(
            "hooks at /repo/\x1b[2J\nevil with sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345 inside"
                .to_owned(),
        ),
    );

    let line = &report.sections[0].lines[0].text;
    assert!(!line.contains('\x1b') && !line.contains('\n'), "{line}");
    assert!(
        !line.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"),
        "{line}"
    );
}

/// A foreign fragment keeps its cut. Nothing outside bounds how much an
/// error or a source's own name may say, so `shown` does.
///
/// Asked of `shown` directly rather than through a folded line: `scope`
/// composes lines around it, and nothing hands it a whole line.
///
/// The length is written out rather than taken from the constant. Compared
/// against `FOREIGN_CHARS` both sides moved together, so the cut could be
/// loosened to 1000 or tightened to 10 with this still green — the shape
/// this file has already been caught in once.
#[test]
fn a_foreign_fragment_is_still_cut_at_the_bound() {
    assert_eq!(shown(&"e".repeat(4000)).chars().count(), 300);
    assert_eq!(FOREIGN_CHARS, 300, "the bound moved; this test decides it");
}

/// A relayed line past the bound is REPLACED, never trimmed.
///
/// The distinction the third variant exists for. A fragment may be cut,
/// because a line is composed around it and turns on the prose; a relayed
/// verdict carries its remedy at its own end, so a trim hands the reader a
/// sentence that reads finished and is missing the half worth having. Past
/// the bound they get kendex saying so and naming who to ask.
///
/// The class and the status are the delegating caller's and are untouched:
/// this decides what a line SAYS, never what the run exited.
#[test]
fn a_relayed_line_past_the_bound_is_replaced_rather_than_cut() {
    let mut report = check_report();
    // A fixed length, not one derived from the constant: a payload sized
    // against `RELAYED_CHARS` grows with it, so raising the bound left this
    // green and the bound unproven. 4000 is the same absolute size the
    // fragment bound is pinned at below.
    let payload = "the commit-guards installer said something very long. ".repeat(75);
    assert_eq!(payload.chars().count(), 4050);
    assert!(
        payload.chars().count() > RELAYED_CHARS,
        "the bound is now looser than this fixture can reach: {RELAYED_CHARS}"
    );
    fold(
        &mut report,
        "commit hooks",
        Class::Drift,
        Text::Relayed {
            producer: "the commit-guards installer".to_owned(),
            line: payload.clone(),
        },
    );

    let line = &report.sections[0].lines[0].text;
    assert!(
        line.contains("too long to show here"),
        "the reader is not told what happened: {line}"
    );
    assert!(
        line.contains("the commit-guards installer"),
        "the reader is not told who to ask: {line}"
    );
    // Not one character of it, so no reader can act on a fragment of a
    // sentence that was never shown to them whole.
    assert!(
        !line.contains("said something very long"),
        "the payload was carried after all: {line}"
    );
    assert!(
        line.chars().count() < RELAYED_CHARS,
        "the replacement is a sentence, not a trim: {} characters",
        line.chars().count()
    );
    assert_eq!(report.status, CheckStatus::Drift);
    assert_eq!(report.status.exit_code(), 1);
    assert_eq!(report.sections[0].lines[0].class, Class::Drift);
}

/// And within the bound it is carried whole, which is the case the bound
/// exists to protect.
///
/// A verdict of the length a delegated script actually writes arrives
/// whole, remedy and all. A cap set low enough to catch one would trade
/// the defect this variant closed for the one it replaced.
#[test]
fn a_relayed_line_within_the_bound_keeps_its_every_word() {
    let mut report = check_report();
    let verdict = format!(
        "commit-guards git hooks: NOT armed — {} ({}); run 'kendex guard install' to re-arm",
        "helper kendex-guards was not written by this installer, ".repeat(4),
        "/a/path".repeat(20)
    );
    assert!(verdict.chars().count() > FOREIGN_CHARS, "past the cut");
    assert!(verdict.chars().count() < RELAYED_CHARS, "inside the bound");
    fold(
        &mut report,
        "commit hooks",
        Class::Unknown,
        Text::Relayed {
            producer: "the commit-guards installer".to_owned(),
            line: verdict.clone(),
        },
    );

    assert_eq!(report.sections[0].lines[0].text, verdict);
    assert_eq!(report.status, CheckStatus::Unknown);
    assert_eq!(report.status.exit_code(), 2);
}

/// A clean report to fold a verdict into — what `check` returns for a
/// scope with nothing to say.
fn check_report() -> CheckReport {
    CheckReport {
        status: CheckStatus::Clean,
        sections: Vec::new(),
        snapshot_age_secs: None,
        project_target: None,
        deep_pass_owed: false,
    }
}
