//! `kendex remove`: taking one package away changes that package and what
//! only it pulled in, and holds every other package at the commit its lock
//! entry records, as `refresh --locked` renders it. A catalog that moved on
//! since the install is not brought current by a removal.
//!
//! The fixture is `verify_records`'s consumer with the catalog moved past
//! the install by `refresh_locked`'s commit, which changes every kind the
//! consumer renders from it. The control is the plan a removal made before
//! this held it: planned at the catalog's tip, the same remove rewrote the
//! moved skill, agent and command and moved the record's catalog commit.
#![cfg(unix)]

use std::collections::BTreeSet;

use super::refresh_locked::{changed, move_the_catalog, record};
use super::toggle_locked::{listed, rewrite_the_catalog};
use super::verify_records::{git, kendex, said, world};

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_holds_every_other_package_at_its_recorded_commit() {
    let world = world();
    move_the_catalog(&world);
    let before = record(&world);

    let removed = kendex(
        &world.home,
        &world.project,
        &[
            "remove", "guard", "--scope", "project", "--sweep", "--leave",
        ],
    );
    assert!(removed.status.success(), "{}", said(&removed));

    assert_eq!(
        changed(&world),
        BTreeSet::from([
            "kendex.toml".to_owned(),
            ".kendex-lock.json".to_owned(),
            ".kendex-generated.json".to_owned(),
            ".claude/hooks/guard.sh".to_owned(),
            ".claude/settings.json".to_owned(),
        ]),
        "{}",
        said(&removed)
    );
    let after = record(&world);
    assert_eq!(after["sources"], before["sources"]);
    assert_eq!(after["bundles"], before["bundles"]);
    let others = |record: &serde_json::Value| {
        record["entries"]
            .as_object()
            .unwrap()
            .iter()
            .filter(|(_, entry)| !(entry["kind"] == "hook" && entry["name"] == "guard"))
            .map(|(key, entry)| (key.clone(), entry.clone()))
            .collect::<Vec<_>>()
    };
    assert_eq!(others(&after), others(&before));
    assert!(
        !after["entries"]
            .as_object()
            .unwrap()
            .values()
            .any(|entry| entry["kind"] == "hook" && entry["name"] == "guard"),
        "{after}"
    );
}

/// Where the catalog's history was rewritten past the install and this
/// machine's mirror never held the recorded commit, a removal reads every
/// other package at the catalog's current commit rather than skipping it:
/// skipped, its renders dropped out of the generated-paths inventory.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_reads_a_package_whose_recorded_commit_is_gone_at_the_tip() {
    let world = world();
    rewrite_the_catalog(&world);
    let before = listed(&world);

    let removed = kendex(
        &world.home,
        &world.project,
        &[
            "remove", "guard", "--scope", "project", "--sweep", "--leave",
        ],
    );
    assert!(removed.status.success(), "{}", said(&removed));

    let after = listed(&world);
    let unlisted: Vec<_> = before
        .difference(&after)
        .filter(|path| !path.contains("guard"))
        .collect();
    assert!(
        unlisted.is_empty(),
        "de-listed {unlisted:?}\n{}",
        said(&removed)
    );
    let head = git(&world.catalog, &["rev-parse", "HEAD"]);
    let record = record(&world);
    for name in ["second", "review"] {
        let entry = record["entries"]
            .as_object()
            .unwrap()
            .values()
            .find(|entry| entry["name"] == name)
            .unwrap();
        assert_eq!(entry["sourceCommit"], head.trim(), "{name}: {entry}");
    }
}
