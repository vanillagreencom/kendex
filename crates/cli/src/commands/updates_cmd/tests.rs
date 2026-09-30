use super::{UpdatesArgs, run_with, screen};
use crate::ui::testing::{plain, rich, tagged};
use crate::width::visible_width;
use kendex_core::engine::ItemWarning;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package::updates::{UpdateRow, UpdatesReport, VersionRef};

fn row() -> UpdateRow {
    UpdateRow {
        scope: Scope::Global,
        kind: ItemKind::Skill,
        name: "tidy".into(),
        source: "cat".into(),
        repo: "owner/catalog".into(),
        repo_identity: "owner/catalog".into(),
        current: Some(VersionRef {
            commit: "1111111".into(),
            label: Some("v1".into()),
            date: None,
        }),
        latest: Some(VersionRef {
            commit: "2222222".into(),
            label: Some("v2".into()),
            date: None,
        }),
        update_available: true,
        pinned: false,
        hold_owner: None,
        ignored: false,
        blocked_by_local_edit: false,
        files_missing: false,
        edited_harnesses: vec![],
        forkable_harness: None,
        can_discard: true,
        can_take_latest: true,
        derived: false,
        required_by: vec![],
        forked: false,
        fork_edited: false,
        mixed: false,
        removed_upstream: false,
        no_per_package_update: None,
    }
}

#[test]
fn listing_evaluates_once_and_records_the_supplied_report() -> super::CliResult {
    use kendex_core::drift::snapshot::{PackageSnapshot, SnapshotFile, load};
    use kendex_core::env::{Env, FakeOs};

    let tmp = tempfile::tempdir()?;
    let root = crate::test_util::rooted(&tmp);
    let env = Env::fake(&root, FakeOs::Linux);
    let report = UpdatesReport {
        rows: vec![UpdateRow {
            pinned: true,
            ignored: true,
            blocked_by_local_edit: true,
            mixed: true,
            removed_upstream: true,
            forked: true,
            ..row()
        }],
        warnings: vec![ItemWarning {
            kind: ItemKind::Skill,
            name: "tidy".into(),
            harness: None,
            message: "unreadable source".into(),
            remediation: None,
        }],
        unreadable: vec![],
        last_fetched: None,
    };
    let mut evaluations = 0;
    run_with(
        &env,
        UpdatesArgs {
            command: None,
            refresh: false,
            apply: false,
            global: true,
            scope: None,
            yes: false,
            target: Default::default(),
            _commit: Default::default(),
        },
        |_, scope| {
            assert_eq!(scope, &Scope::Global);
            evaluations += 1;
            Ok(report)
        },
    )?;
    assert_eq!(evaluations, 1);
    let SnapshotFile::Current(snapshot) = load(&env, &Scope::Global) else {
        panic!("the listing must record its report");
    };
    assert_eq!(
        snapshot.packages,
        vec![PackageSnapshot {
            kind: ItemKind::Skill,
            name: "tidy".into(),
            source: "cat".into(),
            repo: "owner/catalog".into(),
            refs_state: None,
            update_available: true,
            removed_upstream: true,
            held: true,
            ignored: true,
            edited: true,
            mixed: true,
            forked: true,
        }]
    );
    assert_eq!(snapshot.unreadable, ["skill tidy: unreadable source"]);
    Ok(())
}

#[test]
fn inspection_updates_snapshots() {
    let report = UpdatesReport {
        rows: vec![
            row(),
            UpdateRow {
                name: "held".into(),
                pinned: true,
                ignored: true,
                ..row()
            },
            UpdateRow {
                name: "edited".into(),
                blocked_by_local_edit: true,
                ..row()
            },
        ],
        warnings: vec![ItemWarning {
            kind: ItemKind::Skill,
            name: "tidy".into(),
            harness: None,
            message: "its source is unreadable".into(),
            remediation: None,
        }],
        unreadable: vec![],
        last_fetched: None,
    };
    assert_eq!(
        screen(&plain(), &report),
        [
            "global  skill tidy  v1 -> v2",
            "global  skill held  v1 -> v2  [held, ignored]",
            "global  skill edited  v1 -> v2  [edited on disk — keep it as your own copy, or discard the edits]",
            "warning: skill tidy: its source is unreadable",
        ]
    );
    assert_eq!(
        tagged(&screen(&rich(80), &report)),
        [
            "  <1>skill tidy</>  <90>v1</> <34>→</> v2  <90>[global]</>",
            "  <1>skill held</>  <90>v1</> <34>→</> v2  <90>[global]</>",
            "    <33>!</> held",
            "    <33>!</> ignored",
            "  <1>skill edited</>  <90>v1</> <34>→</> v2  <90>[global]</>",
            "    <31>✗</> edited on disk — keep it as your own copy, or discard the edits",
            "  <33>!</> skill tidy: its source is unreadable",
        ]
    );
    // A warning with nothing to update is the whole report: no summary
    // follows it.
    let warned = UpdatesReport {
        rows: vec![UpdateRow {
            update_available: false,
            ..row()
        }],
        ..report
    };
    assert_eq!(
        screen(&plain(), &warned),
        ["warning: skill tidy: its source is unreadable"]
    );
    let clean = UpdatesReport {
        warnings: vec![],
        ..warned
    };
    assert_eq!(
        screen(&plain(), &clean),
        ["everything is on its latest version"]
    );
    assert_eq!(
        tagged(&screen(&rich(80), &clean)),
        ["", "<32>✓</> <1>everything is on its latest version</>"]
    );
}

#[test]
fn inspection_updates_wraps_scope_and_notes() {
    let report = UpdatesReport {
        rows: vec![UpdateRow {
            scope: Scope::Project {
                root: format!("/{}", "long-path-".repeat(12)).into(),
            },
            name: "long-name-".repeat(12),
            blocked_by_local_edit: true,
            ..row()
        }],
        warnings: vec![],
        unreadable: vec![],
        last_fetched: None,
    };
    let lines = screen(&rich(80), &report);
    assert!(
        lines.iter().all(|line| visible_width(line) <= 80),
        "{lines:?}"
    );
    assert!(
        screen(&plain(), &report)
            .iter()
            .any(|line| visible_width(line) > 80)
    );
}
