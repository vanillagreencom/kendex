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
    assert_eq!(*section_lines.last().unwrap(), "  … and 5 more");
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

#[test]
fn an_unsafe_identifier_drops_the_remedy_not_the_line() {
    let remedy = Remedy::Remove {
        name: "evil; rm -rf /".into(),
        global: false,
    };
    assert_eq!(remedy.render(), None);
    let fine = Remedy::Remove {
        name: "gh".into(),
        global: true,
    };
    assert_eq!(fine.render().as_deref(), Some("kendex remove gh --global"));
    assert_eq!(
        Remedy::Add {
            kind: ItemKind::Skill,
            name: "-flag".into(),
            global: false
        }
        .render(),
        None,
        "a name shaped like an option never reaches a command position"
    );
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
fn v1_manifest_reads_as_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let manifest_path = crate::manifest::manifest_path(&env, &scope);
    std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    // No schema key: the v1 shape.
    std::fs::write(&manifest_path, "[agents.orch]\nsource = \"kendex\"\n").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert!(render_plain(&report).contains("v1 manifest"));
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
        "growth-guards armed the commit hooks, so every commit fails until {deep}/pre-commit, {deep}/commit-msg are dealt with"
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
/// composes lines around it, and the variant that used to hand it a whole
/// line is gone.
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
    let payload = "the growth-guards installer said something very long. ".repeat(75);
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
            producer: "the growth-guards installer".to_owned(),
            line: payload.clone(),
        },
    );

    let line = &report.sections[0].lines[0].text;
    assert!(
        line.contains("too long to show here"),
        "the reader is not told what happened: {line}"
    );
    assert!(
        line.contains("the growth-guards installer"),
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
        "growth-guards git hooks: NOT armed — {} ({}); run 'kendex guard install' to re-arm",
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
            producer: "the growth-guards installer".to_owned(),
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
    }
}
