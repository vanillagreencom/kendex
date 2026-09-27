use super::screen;
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
