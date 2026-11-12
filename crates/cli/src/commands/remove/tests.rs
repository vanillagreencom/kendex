use super::*;
use crate::ui::testing::{asked, plain, rich, tagged};
use console::Key as Pressed;
use kendex_core::apply::{Description, Plan, Pre};
use kendex_core::engine::{Disowned, KeptInstall, SetChange};
use kendex_core::model::{HarnessId, ItemKind};

#[allow(clippy::expect_used)]
fn trash(root: &std::path::Path, name: &str) -> PlannedOp {
    PlannedOp {
        description: format!("Trash skill {name}'s files").into(),
        op: Op::Trash {
            path: root.join(name),
            pre: Pre::Absent,
            absent_is_done: false,
        },
    }
}

/// A bundle removal's preview and what it wrote, in both renderings: the
/// declaration it drops, the one it keeps removed, each install it takes
/// with its reason and each it keeps with what still wants it, then the
/// writes under `changes:`, a section rich. The plain lines are the ones
/// scripts read today; with the declaration kept, the removal's reason is
/// left off.
#[test]
#[allow(clippy::expect_used)]
fn a_removal_says_what_it_drops_takes_and_keeps_then_what_it_wrote() {
    let tmp = tempfile::tempdir().expect("fixture");
    let root = tmp.path().canonicalize().expect("canonical fixture");
    let mut report = EngineReport::observed(
        Plan::landed(Scope::Global, vec![trash(&root, "alpha")]).expect("plan lands"),
    );
    report.disowned = Some(Disowned {
        dropped: vec![DroppedDeclaration::Bundle {
            name: "starter".into(),
        }],
        suppressed: vec![(ItemKind::Skill, "github".into())],
    });
    report.set_changes.push(SetChange {
        kind: ItemKind::Skill,
        name: "alpha".into(),
        harness: HarnessId::Claude,
        direction: SetDirection::Remove,
        reason: "part of the starter bundle".into(),
    });
    report.kept.push(KeptInstall {
        kind: ItemKind::Skill,
        name: "beta".into(),
        harness: HarnessId::Claude,
        reason: "asked for".into(),
    });
    let draw = |style: &Style, mode: Removal| {
        let mut lines = split_lines(style, &report, mode, "kendex.toml");
        lines.extend(changes_lines(style, &report.plan.ops));
        lines
    };
    let disown = Removal::Disown {
        sweep: Some(false),
        kind: None,
    };
    let rows: [(Removal, &[&str], &[&str]); 2] = [
        (
            disown,
            &[
                "dropping bundle starter from kendex.toml",
                "keeping skill github removed: [suppressed] in kendex.toml",
                "removing skill alpha for Claude Code — part of the starter bundle",
                "keeping skill beta for Claude Code — asked for",
                "changes:",
                "  - Trash skill alpha's files",
            ],
            &[
                "  <36>•</> dropping bundle starter from kendex.toml",
                "  <36>•</> keeping skill github removed: [suppressed] in kendex.toml",
                "  <36>•</> removing skill alpha for Claude Code — part of the starter bundle",
                "  <36>•</> keeping skill beta for Claude Code — asked for",
                "",
                "<1;32>changes</>  <90>1</>",
                "  <32>✓</> Trash skill alpha's files",
            ],
        ),
        (
            Removal::KeepDeclaration,
            &[
                "dropping bundle starter from kendex.toml",
                "keeping skill github removed: [suppressed] in kendex.toml",
                "removing skill alpha for Claude Code",
                "keeping skill beta for Claude Code — asked for",
                "changes:",
                "  - Trash skill alpha's files",
            ],
            &[
                "  <36>•</> dropping bundle starter from kendex.toml",
                "  <36>•</> keeping skill github removed: [suppressed] in kendex.toml",
                "  <36>•</> removing skill alpha for Claude Code",
                "  <36>•</> keeping skill beta for Claude Code — asked for",
                "",
                "<1;32>changes</>  <90>1</>",
                "  <32>✓</> Trash skill alpha's files",
            ],
        ),
    ];
    for (mode, want_plain, want_rich) in rows {
        assert_eq!(draw(&plain(), mode), want_plain);
        assert_eq!(tagged(&draw(&rich(80), mode)), want_rich);
    }
}

/// A written op keeps its landed path whole on a rich terminal, a path
/// with a space included, where prose around it wraps; plain is the one
/// `  - ` line scripts read.
#[test]
fn a_written_op_keeps_its_path_whole() {
    let root = std::path::Path::new("/home/a/My Projects/app/.claude/skills");
    // The join takes the platform's separator, which the drawn path keeps.
    let path = root.join("alpha");
    let shown = path.display().to_string();
    let op = PlannedOp {
        description: Description::around("Trash skill alpha's files at ", ""),
        op: Op::Trash {
            path,
            pre: Pre::Absent,
            absent_is_done: false,
        },
    };
    assert_eq!(
        changes_lines(&plain(), std::slice::from_ref(&op)),
        [
            "changes:".to_owned(),
            format!("  - Trash skill alpha's files at {shown}"),
        ]
    );
    assert_eq!(
        tagged(&changes_lines(&rich(60), &[op])),
        [
            String::new(),
            "<1;32>changes</>  <90>1</>".to_owned(),
            "  <32>✓</> Trash skill alpha's files at".to_owned(),
            format!("    {shown}"),
        ]
    );
}

/// The sweep is a decision: what it takes, how many more changes a yes
/// writes and the flags that answer it, each added change, then the keys.
/// `s` takes the leftovers and Enter keeps them, as `--no-sweep` does.
#[test]
#[allow(clippy::expect_used)]
fn the_sweep_asks_with_the_changes_a_yes_adds() {
    let tmp = tempfile::tempdir().expect("fixture");
    let root = tmp.path().canonicalize().expect("canonical fixture");
    let added = Consent {
        effects: vec![Effect::Op(trash(&root, "github"))],
    };
    let rows: [(Style, Pressed, bool, &[&str]); 2] = [
        (
            plain(),
            Pressed::Char('s'),
            true,
            &[
                "! also remove skill github, which nothing needs anymore?",
                "  This adds 1 change. To skip this question, use --sweep or --no-sweep.",
                "  - Trash skill github's files",
                "  [s] remove too · [Enter] keep",
                "  › remove too",
            ],
        ),
        (
            rich(80),
            Pressed::Enter,
            false,
            &[
                "",
                "<33>!</> <1>also remove skill github, which nothing needs anymore?</>",
                "  This adds 1 change. To skip this question, use --sweep or --no-sweep.",
                "  <36>•</> Trash skill github's files",
                "  <34>[s]</> <90>remove too</><90> · </><1;34>[Enter]</> <1>keep</>",
                "  <34>›</> <1>keep</>",
            ],
        ),
    ];
    for (style, key, swept, want) in rows {
        let mut drawn = sweep_question(&style, &["skill github".to_owned()], &added);
        let (keys, answer) = asked(&style, &SWEEP, &[key]);
        drawn.extend(keys);
        assert_eq!(answer.ok(), Some(swept));
        assert_eq!(tagged(&drawn), want);
    }
}
