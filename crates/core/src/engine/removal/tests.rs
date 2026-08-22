//! What the removal passes take, and what they leave for a plan that
//! was not asked about it.

use std::collections::BTreeSet;
use std::fs;

use super::*;
use crate::lock::{EmittedArtifact, LockEntry, Reason};
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind};

/// A command whose generated skill has moved: the lock records where the
/// last install put it, and the desired item names where this one would.
#[allow(clippy::unwrap_used)]
fn moved(old: &std::path::Path, new: &std::path::Path) -> (desired::DesiredState, Lock) {
    let entry = LockEntry {
        // Not what this fixture is about: it never left the reserved name.
        left_pi_reserved_name: false,
        name: "ship".to_owned(),
        kind: ItemKind::Command,
        harness: HarnessId::Codex,
        source: "cat".to_owned(),
        source_repo: String::new(),
        method: Method::Symlink,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "x".to_owned(),
        source_commit: None,
        rendered_hash: Some(crate::hash::hash_tree(old).unwrap()),
        enabled: true,
        upstream_skills: None,
        emitted: Some(EmittedArtifact {
            kind: ItemKind::Skill,
            name: "ship".to_owned(),
            paths: vec![old.to_path_buf()],
        }),
        registration: None,
        reasons: BTreeSet::from([Reason::Requested]),
    };
    let item = desired::Desired {
        key: "command:ship:codex".to_owned(),
        kind: ItemKind::Command,
        name: "ship".to_owned(),
        harness: HarnessId::Codex,
        enabled: true,
        method: Method::Symlink,
        source_name: "cat".to_owned(),
        provenance: String::new(),
        source_commit: None,
        recorded_fork: false,
        // This fixture is about removal, which reads neither.
        author_review: None,
        authored: None,
        hash: "x".to_owned(),
        upstream_skills: None,
        emitted: Some(EmittedArtifact {
            kind: ItemKind::Skill,
            name: "ship__command".to_owned(),
            paths: vec![new.to_path_buf()],
        }),
        reasons: BTreeSet::from([Reason::Requested]),
        artifact: desired::Artifact::Tree {
            canonical: new.to_path_buf(),
            files: vec![],
            link: None,
        },
    };
    let lock = Lock {
        version: crate::lock::LOCK_VERSION,
        entries: [(item.key.clone(), entry)].into(),
        sources: Default::default(),
        settings_seeds: Default::default(),
    };
    (
        desired::DesiredState {
            items: vec![item],
            ..Default::default()
        },
        lock,
    )
}

/// The sweep, for a plan acting on exactly these items — `None` for a plan
/// acting on everything, which is what an unrestricted one does.
#[allow(clippy::unwrap_used)]
fn swept(
    state: &desired::DesiredState,
    lock: &Lock,
    acting: Option<Vec<(ItemKind, String)>>,
) -> usize {
    let state = desired::DesiredState {
        items: state.items.clone(),
        acting: acting.map(|names| names.into_iter().collect()),
        ..Default::default()
    };
    let mut guard = TrashGuard::new(&state.items);
    let mut ops = Vec::new();
    stale_emitted(&state, lock, &mut guard, &mut ops).unwrap();
    ops.len()
}

/// A plan restricted to one package writes nothing for the others, so
/// taking their old paths away would leave them with neither the files
/// they had nor the ones nothing planned.
#[test]
#[allow(clippy::unwrap_used)]
fn a_restricted_plan_sweeps_nothing_for_a_package_it_does_not_name() {
    let tmp = tempfile::tempdir().unwrap();
    let old = tmp.path().join("skills/ship");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("SKILL.md"), "the command's own copy").unwrap();
    let (state, lock) = moved(&old, &tmp.path().join("skills/ship__command"));

    // The control: unrestricted, the path it left is swept.
    assert_eq!(swept(&state, &lock, None), 1);

    assert_eq!(
        swept(
            &state,
            &lock,
            Some(vec![(ItemKind::Skill, "notes".to_owned())]),
        ),
        0,
        "a plan for another package swept this one's path"
    );
    // And named, it is this plan's own work again.
    assert_eq!(
        swept(
            &state,
            &lock,
            Some(vec![(ItemKind::Command, "ship".to_owned())])
        ),
        1
    );
}
