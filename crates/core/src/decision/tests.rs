//! What a yes covers, and what a plan derived after it adds.

use std::path::{Path, PathBuf};

use super::*;
use crate::apply::{Op, Plan, Pre};
use crate::engine::SetDirection;
use crate::lock::Lock;
use crate::model::{HarnessId, ItemKind, Scope};

fn planned(root: &Path, ops: Vec<Op>) -> EngineReport {
    let planned = ops
        .into_iter()
        .map(|op| PlannedOp {
            description: "write".into(),
            op,
        })
        .collect();
    let scope = Scope::Project {
        root: root.to_owned(),
    };
    EngineReport::observed(Plan::landed(scope, planned).expect("ops inside the scope"))
}

fn file(root: &Path, name: &str, bytes: &str, pre: Pre) -> Op {
    Op::WriteFile {
        path: root.join(name),
        bytes: bytes.as_bytes().to_vec(),
        pre,
    }
}

fn record(root: &Path, lock: Lock) -> Op {
    Op::WriteLock {
        path: root.join("kendex.lock"),
        lock: Box::new(lock),
        pre: Pre::Absent,
    }
}

fn settle(name: &str) -> PiSettle {
    PiSettle {
        name: name.to_owned(),
        change: PiChange::Missing,
    }
}

/// The paths a later plan's added ops land at.
fn added_at(approved: &Approved, later: &EngineReport) -> Vec<PathBuf> {
    approved
        .added(later)
        .consent
        .effects
        .iter()
        .flat_map(|effect| match effect {
            Effect::Op(planned) => planned.op.touched(),
            Effect::Pi(settle) => panic!("a plan adds no settle: {}", settle.name),
        })
        .collect()
}

/// The question lists exactly what it counts: every package the settle
/// lands, then every op the plan writes.
#[test]
fn one_list_supplies_the_question_and_its_count() {
    let temp = tempfile::tempdir().expect("temp dir");
    let root = crate::test_util::rooted(&temp);
    let report = planned(
        &root,
        vec![
            file(&root, "a.md", "a", Pre::Absent),
            record(&root, Lock::default()),
        ],
    );
    for (settles, count) in [(vec![], 2), (vec![settle("pi-hooks")], 3)] {
        let consent = Consent::of(&report, &settles);
        assert_eq!(consent.count(), count);
        assert_eq!(consent.effects.len(), consent.count());
        let pi: Vec<_> = consent
            .effects
            .iter()
            .take_while(|effect| matches!(effect, Effect::Pi(_)))
            .collect();
        assert_eq!(pi.len(), settles.len(), "the settle runs first");
    }
    assert!(Consent::of(&planned(&root, vec![]), &[]).is_empty());
}

/// A plan derived after an approved write is read against the approval by
/// what each op writes and where, never by the words it was drawn with.
#[test]
fn a_later_plan_adds_only_what_the_yes_did_not_cover() {
    let temp = tempfile::tempdir().expect("temp dir");
    let root = crate::test_util::rooted(&temp);
    let moved = Pre::HashIs {
        hash: "moved".to_owned(),
    };
    let mut recorded = Lock::default();
    recorded.version = recorded.version.wrapping_add(1);
    let approved_ops = vec![
        file(&root, "a.md", "a", Pre::Absent),
        record(&root, Lock::default()),
    ];
    // (later plan, the paths it adds, why)
    let rows: Vec<(Vec<Op>, Vec<PathBuf>, &str)> = vec![
        (
            approved_ops.clone(),
            vec![],
            "the same plan again adds nothing",
        ),
        (
            vec![file(&root, "a.md", "a", moved.clone())],
            vec![],
            "a precondition an earlier write moved is no new change",
        ),
        (
            vec![],
            vec![],
            "writing less than was approved adds nothing",
        ),
        (
            vec![record(&root, recorded)],
            vec![],
            "the record is bound by where it is written",
        ),
        (
            vec![file(&root, "a.md", "other bytes", Pre::Absent)],
            vec![root.join("a.md")],
            "the same position with other bytes is a change nobody approved",
        ),
        (
            vec![file(&root, "b.md", "a", Pre::Absent)],
            vec![root.join("b.md")],
            "a position nobody approved",
        ),
        (
            vec![Op::WriteExecutable {
                path: root.join("a.md"),
                bytes: b"a".to_vec(),
                pre: Pre::Absent,
            }],
            vec![root.join("a.md")],
            "another kind of write at an approved position",
        ),
    ];
    let before = planned(&root, approved_ops.clone());
    let approved = Approved::of(&before, &Consent::of(&before, &[settle("pi-hooks")]));
    for (later, expected, why) in rows {
        let later = planned(&root, later);
        assert_eq!(added_at(&approved, &later), expected, "{why}");
    }
}

/// An install or removal the approved plan did not name is said beside the
/// further question, whatever ops carry it.
#[test]
fn a_later_set_change_is_named() {
    let temp = tempfile::tempdir().expect("temp dir");
    let root = crate::test_util::rooted(&temp);
    let change = |name: &str| SetChange {
        kind: ItemKind::Hook,
        name: name.to_owned(),
        harness: HarnessId::Pi,
        direction: SetDirection::Add,
        reason: "declared".to_owned(),
    };
    let mut before = planned(&root, vec![]);
    before.set_changes = vec![change("guard")];
    let approved = Approved::of(&before, &Consent::of(&before, &[]));
    let mut later = planned(&root, vec![]);
    later.set_changes = vec![change("guard"), change("lint")];
    let added = approved.added(&later);
    assert_eq!(added.set_changes, vec![&change("lint")]);
    assert!(added.consent.is_empty());
}
