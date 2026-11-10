use std::collections::BTreeSet;

use super::DesiredState;
use crate::lock::{BundleRef, InstallRef, LockEntry, Reason, RequirerAncestry, RequirerProvenance};
use crate::model::{HarnessId, ItemKind};

fn at(name: &str) -> InstallRef {
    InstallRef {
        source: "cat".into(),
        kind: ItemKind::Skill,
        name: name.into(),
        harness: HarnessId::Codex,
    }
}

fn required_by(name: &str) -> Reason {
    Reason::RequiredBy { by: at(name) }
}

fn member_of(set: &str) -> Reason {
    Reason::MemberOf {
        bundle: BundleRef {
            source: "cat".into(),
            name: set.into(),
        },
    }
}

fn row(name: &str, repo: &str, reasons: &[Reason]) -> RequirerProvenance {
    RequirerProvenance {
        installation: at(name),
        source_repo: repo.into(),
        reasons: reasons.iter().cloned().collect(),
    }
}

fn previous(rows: Vec<RequirerProvenance>) -> LockEntry {
    LockEntry {
        name: "leaf".into(),
        kind: ItemKind::Skill,
        harness: HarnessId::Codex,
        source: "cat".into(),
        source_repo: "./cat".into(),
        source_hash: "abc".into(),
        source_commit: None,
        selector: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        output_style: None,
        reasons: BTreeSet::new(),
        requirer_provenance: Some(RequirerAncestry { rows, held: false }),
        machine: None,
    }
}

/// The snapshot is one row per ancestor of the given edges, as this pass
/// read it; a previous row speaks only for an ancestor this pass did not
/// read, and no rows is `None`, never an empty list.
#[test]
fn ancestry_is_one_row_per_ancestor_as_read_and_none_without_rows() {
    let mut state = DesiredState::default();
    state
        .requirer_provenance
        .insert(at("mid"), row("mid", "./cat", &[required_by("S")]));
    state
        .requirer_provenance
        .insert(at("S"), row("S", "./cat", &[Reason::Requested]));
    let held = previous(vec![
        row("mid", "./cat", &[member_of("crew")]),
        row("old", "./cat", &[member_of("crew")]),
    ]);
    type Case<'a> = (
        &'a [Reason],
        Option<&'a LockEntry>,
        Option<Vec<RequirerProvenance>>,
    );
    let cases: [Case<'_>; 5] = [
        (&[], None, None),
        (&[Reason::Requested, member_of("crew")], Some(&held), None),
        (&[required_by("gone")], None, None),
        (
            &[required_by("mid")],
            Some(&held),
            Some(vec![
                row("S", "./cat", &[Reason::Requested]),
                row("mid", "./cat", &[required_by("S")]),
            ]),
        ),
        (
            &[required_by("old")],
            Some(&held),
            Some(vec![row("old", "./cat", &[member_of("crew")])]),
        ),
    ];
    for (edges, previous, expected) in cases {
        let edges = edges.iter().cloned().collect::<BTreeSet<_>>();
        assert_eq!(state.ancestry(&edges, previous), expected, "{edges:?}");
    }
}

/// A record is read otherwise only where this pass read an edge it or one
/// of its rows lacks: more edges than the read never lose a root, and an
/// installation or ancestor this pass did not read says nothing.
#[test]
fn a_record_is_read_otherwise_only_where_it_lacks_an_edge_read_now() {
    let mut state = DesiredState::default();
    state
        .requirer_provenance
        .insert(at("leaf"), row("leaf", "./cat", &[required_by("mid")]));
    state
        .requirer_provenance
        .insert(at("mid"), row("mid", "./cat", &[required_by("S")]));
    let record = |reasons: &[Reason], rows: Vec<RequirerProvenance>| LockEntry {
        reasons: reasons.iter().cloned().collect(),
        ..previous(rows)
    };
    let cases = [
        (
            "reads as recorded",
            record(
                &[required_by("mid")],
                vec![row("mid", "./cat", &[required_by("S")])],
            ),
            false,
        ),
        (
            "records more than read",
            record(
                &[required_by("mid"), member_of("crew")],
                vec![row("mid", "./cat", &[required_by("S"), member_of("crew")])],
            ),
            false,
        ),
        (
            "own edge read now",
            record(&[member_of("crew")], vec![]),
            true,
        ),
        (
            "a row's edge read now",
            record(
                &[required_by("mid")],
                vec![row("mid", "./cat", &[member_of("crew")])],
            ),
            true,
        ),
        (
            "a row this pass did not read",
            record(
                &[required_by("mid")],
                vec![
                    row("mid", "./cat", &[required_by("S")]),
                    row("old", "./cat", &[member_of("crew")]),
                ],
            ),
            false,
        ),
    ];
    for (case, record, otherwise) in cases {
        assert_eq!(state.read_otherwise(&record), otherwise, "{case}");
    }
    let unread = LockEntry {
        name: "other".into(),
        ..record(&[member_of("crew")], vec![])
    };
    assert!(!state.read_otherwise(&unread), "an installation not read");
}
