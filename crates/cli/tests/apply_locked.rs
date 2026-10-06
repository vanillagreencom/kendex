//! `kendex apply` after a hand edit to `kendex.toml`: every package the
//! install record places holds at the commit its lock entry records, as
//! `refresh --locked` renders it, so deleting one package's table changes
//! that package's paths and nothing a catalog that moved on since the
//! install renders. Bringing the catalog current is `kendex refresh`'s.
//!
//! The fixture is `verify_records`'s consumer with the catalog moved past
//! the install by `refresh_locked`'s commit, which changes every kind the
//! consumer renders from it. The control is the plan apply made before
//! this held it: planned at the catalog's tip, the same apply rewrote the
//! moved skill, agent and command beside the hook it removed.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{commit, kendex, said, world, write};

#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_deleted_table_changes_only_that_package() {
    let world = world();
    move_the_catalog(&world);
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    let table = "[hooks.guard]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n";
    assert_eq!(declared.matches(table).count(), 1, "{declared}");
    write(&manifest, &declared.replacen(table, "", 1));
    commit(&world.project, "the guard hook's table deleted");
    let before = record(&world);

    let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));

    assert_eq!(
        changed(&world),
        BTreeSet::from([
            ".kendex-lock.json".to_owned(),
            ".kendex-generated.json".to_owned(),
            ".claude/hooks/guard.sh".to_owned(),
            ".claude/settings.json".to_owned(),
        ]),
        "{}",
        said(&applied)
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
