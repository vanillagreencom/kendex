//! What kendex cannot act on at the new path, whichever way it is going.
//!
//! An entry answering to the record is not the same as an entry kendex's
//! own edits reach: a handler written directly under its event reads back
//! as exactly what the record names, while an upsert steps over it and a
//! removal steps over it too. So does a link where the registry goes.
//! Everything here holds instead, and says which shape is in the way.

use std::fs;
use std::os::unix::fs::symlink;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use super::{apply, world};

/// A handler standing directly under its event is a shape kendex reads
/// and never writes: the entry answers to the record, so it looks like
/// kendex's own to keep up to date, while the edit that would keep it
/// current steps straight over it and puts a second one beside it. Both
/// would then fire, and a later removal would take the script and leave
/// the person's handler pointing at nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_the_edit_cannot_reach_at_the_new_path_holds() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let command = value["hooks"]["tool_call"][0]["hooks"][0]["command"].clone();
    // The way a person writes one, under the very event kendex used.
    value["hooks"]["tool_call"] = serde_json::json!([{ "command": command }]);
    let theirs = serde_json::to_string_pretty(&value).unwrap();
    fs::write(&registry, &theirs).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard" && row.state == DriftState::Conflict)
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("cannot edit") && row.detail.contains("fire twice"),
        "and say what refreshing would do: {}",
        row.detail
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        theirs,
        "nothing is registered beside what they wrote"
    );
    assert!(
        w.dot().join("kendex/hooks/guard.sh").is_file(),
        "and the script their handler names stays with it"
    );
}

/// The same shape, in the direction that destroys something. With
/// nothing declaring the hook there is no rendering to simulate, and the
/// removal steps over a handler written directly under its event exactly
/// as a refresh does — so the script would go, and the record with it,
/// while what runs it stayed behind with nothing left to find it by.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_the_edit_cannot_reach_keeps_its_script_through_a_removal() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    let script = w.dot().join("kendex/hooks/guard.sh");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let command = value["hooks"]["tool_call"][0]["hooks"][0]["command"].clone();
    value["hooks"]["tool_call"] = serde_json::json!([{ "command": command }]);
    let theirs = serde_json::to_string_pretty(&value).unwrap();
    fs::write(&registry, &theirs).unwrap();
    super::undeclare(&w);

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            remove_orphans: true,
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "guard" && row.detail.contains("cannot edit")),
        "the person is told which shape is in the way: {:?}",
        report.drift
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        script.is_file(),
        "the script stays with the entry that still runs it"
    );
    assert_eq!(fs::read_to_string(&registry).unwrap(), theirs);
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"].get("hook:guard:pi").is_some(),
        "and the record, which is the only thing that could find them later: {lock}"
    );
}

/// A link where the new registry goes is a file kendex did not make, and
/// editing through one writes outside the directory it manages.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_new_registry_is_never_written_through() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    let theirs = w.home.join("their-hooks.json");
    fs::rename(&registry, &theirs).unwrap();
    symlink(&theirs, &registry).unwrap();
    let before = fs::read_to_string(&theirs).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard" && row.state == DriftState::Conflict)
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("is a link kendex did not create"),
        "and name what is in the way: {}",
        row.detail
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(&theirs).unwrap(),
        before,
        "the file at the other end is untouched"
    );
    assert!(registry.is_symlink(), "and the link is still theirs");
}
