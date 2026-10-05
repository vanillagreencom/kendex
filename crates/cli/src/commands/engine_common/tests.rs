use super::*;
use crate::ui::testing::{plain, rich, tagged};
use kendex_core::apply::{Op, Plan, PlannedOp, Pre};
use kendex_core::engine::ItemWarning;
use kendex_core::model::{ItemKind, Scope};

/// These snapshots hold the plain report grammar and its rich counterpart.
/// The producers are the engine's plans and per-item render warnings.
#[test]
#[allow(clippy::expect_used)]
fn clean_changed_blocked_and_warning_reports_keep_their_content() {
    let tmp = tempfile::tempdir().expect("fixture");
    let root = tmp.path().canonicalize().expect("canonical fixture");
    let mut changed = EngineReport::observed(
        Plan::landed(
            Scope::Global,
            vec![PlannedOp {
                description: "Save kendex.toml".into(),
                op: Op::WriteFile {
                    path: root.join("kendex.toml"),
                    bytes: vec![],
                    pre: Pre::Absent,
                },
            }],
        )
        .expect("plan lands"),
    );
    changed.warnings.push(ItemWarning {
        kind: ItemKind::Skill,
        name: "tidy".into(),
        harness: Some(HarnessId::Claude),
        message: "missing description".into(),
        remediation: Some("add a description".into()),
    });
    let empty = EngineReport::observed(Plan::landed(Scope::Global, vec![]).expect("empty plan"));
    let cases = [
        (
            &empty,
            false,
            vec!["nothing to do"],
            vec!["  <36>•</> nothing to do"],
        ),
        (
            &empty,
            true,
            vec!["nothing to do until you settle the conflicts above"],
            vec!["  <36>•</> nothing to do until you settle the conflicts above"],
        ),
        (
            &changed,
            false,
            vec!["plan: 1 change", "  - Save kendex.toml"],
            vec!["  <36>•</> plan: 1 change", "  <36>•</> Save kendex.toml"],
        ),
    ];
    for (report, blocked, want_plain, want_rich) in cases {
        assert_eq!(report_lines(&plain(), report, blocked), want_plain);
        assert_eq!(tagged(&report_lines(&rich(80), report, blocked)), want_rich);
    }
    assert_eq!(
        warning_lines(&plain(), &changed.warnings),
        [
            "warning: tidy (Claude Code): missing description",
            "  fix: add a description",
        ]
    );
    assert_eq!(
        tagged(&warning_lines(&rich(80), &changed.warnings)),
        [
            "  <33>!</> tidy (Claude Code): missing description",
            "    <90>fix: add a description</>",
        ]
    );

    // A message keyed by its own target is the line itself in both looks:
    // the consumer refresh report (KEN-2797) reads `doc-drift-check: ` from
    // the first byte of a `2>&1` capture, so nothing may print before the
    // key, no glyph and no indent included.
    let keyed = "doc-drift-check: retired hook, entry skipped; delete [hooks.doc-drift-check] from kendex.toml";
    let retired = [ItemWarning {
        kind: ItemKind::Hook,
        name: "doc-drift-check".into(),
        harness: None,
        message: keyed.into(),
        remediation: None,
    }];
    assert_eq!(warning_lines(&plain(), &retired), [keyed]);
    assert_eq!(tagged(&warning_lines(&rich(120), &retired)), [keyed]);

    // desired_custom_hooks supplies prose remediation, not a command.
    let remedy = "set agents = \"all\" to make it run for everything, or keep it as instructions";
    changed.warnings[0].remediation = Some(remedy.into());
    assert!(
        warning_lines(&plain(), &changed.warnings)
            .iter()
            .any(|line| line == &format!("  fix: {remedy}"))
    );
    assert!(
        warning_lines(&rich(60), &changed.warnings)
            .iter()
            .all(|line| console::measure_text_width(line) <= 60)
    );
}
