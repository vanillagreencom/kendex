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

/// The same link, before there is any hook to have a history. Whether
/// kendex may write that document is the scope's question and not a lock
/// entry's, so the first install has to meet it too — reached only
/// through the entries the lock already names, it never would.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_new_registry_holds_the_first_install_too() {
    let w = world();
    let registry = w.dot().join("kendex/hooks.json");
    let theirs = w.home.join("their-hooks.json");
    fs::create_dir_all(w.dot().join("kendex")).unwrap();
    fs::write(&theirs, "{\"hooks\":{}}\n").unwrap();
    symlink(&theirs, &registry).unwrap();

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
    assert!(
        !format!("{:?}", report.plan.ops).contains("kendex/hooks.json"),
        "nothing is planned against it: {:?}",
        report.plan.ops
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(&theirs).unwrap(),
        "{\"hooks\":{}}\n",
        "the file at the other end is untouched"
    );
    assert!(registry.is_symlink(), "and the link is still theirs");
}

/// The plan proves the registry is a plain file; the op has to carry that
/// proof, or the window between them is one a link fits through. Same
/// bytes at the other end satisfies a hash, and the write follows the
/// link straight out of the directory kendex manages.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_that_became_a_link_after_planning_is_not_written_through() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    // A catalog change, so this pass has an edit to make in that file.
    let source = w.catalog.join("hooks/guard.sh");
    let text = fs::read_to_string(&source).unwrap();
    fs::write(
        &source,
        text.replace("# event: PreToolUse", "# event: Stop"),
    )
    .unwrap();
    let report = audit(&w.env, &w.scope()).unwrap();

    // Between the plan and the apply, the same bytes behind a link.
    let theirs = w.home.join("their-hooks.json");
    let bytes = fs::read_to_string(&registry).unwrap();
    fs::write(&theirs, &bytes).unwrap();
    fs::remove_file(&registry).unwrap();
    std::os::unix::fs::symlink(&theirs, &registry).unwrap();

    let ran = kendex_core::apply::execute(&w.env, &report.plan, None);
    assert!(
        ran.is_err(),
        "the apply aborts on a path that is no longer what was proven"
    );
    assert_eq!(
        fs::read_to_string(&theirs).unwrap(),
        bytes,
        "and the file at the other end is untouched"
    );
}

/// What else runs a command says nothing about whether kendex's own edit
/// lands. Counted across the document, a registration somebody adds under
/// a matcher of their own makes every later refresh hold kendex's
/// perfectly reachable entry — their setup is legitimate and kendex
/// freezes itself over it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_second_entry_of_their_own_does_not_hold_kendexs() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let command = value["hooks"]["tool_call"][0]["hooks"][0]["command"].clone();
    // Theirs, same command, a matcher they chose.
    value["hooks"]["tool_call"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "edit",
            "hooks": [{ "type": "command", "command": command }]
        }));
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    // One pass to write the file in kendex's own hand, since the fixture
    // wrote it in serde's; what matters is what the pass after that says.
    apply(&w);
    let settled = audit(&w.env, &w.scope()).unwrap();
    assert!(
        settled.drift.is_empty(),
        "nothing of kendex's is in anybody's way: {:?}",
        settled.drift
    );
    assert!(settled.notes.is_empty(), "{:?}", settled.notes);
    let after = fs::read_to_string(&registry).unwrap();
    assert!(
        after.contains("\"edit\""),
        "and what they registered is still theirs: {after}"
    );
}
