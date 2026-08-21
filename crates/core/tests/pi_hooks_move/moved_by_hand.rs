//! A registration somebody moved to another listener, in both registries.
//! kendex knows the event it renders a hook under, so a command sitting
//! under a different one is not the registration it wrote — taking it out
//! would stop a hook the person moved, and registering beside it would
//! fire the hook twice.

use std::fs;
use std::os::unix::fs::symlink;

use kendex_core::engine::{DriftState, audit};

use super::{World, about, apply, notes, regressed, world, world_declaring};

/// A command-bodied hook in the layout an earlier kendex wrote. Its
/// record keeps the event it registered — the one shape whose identity
/// has an event to check at all.
#[allow(clippy::unwrap_used)]
fn command_bodied_in_the_legacy_layout() -> World {
    let w = world_declaring(
        "[[custom-hooks]]\nname = \"mine\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./scripts/mine.sh\"\nagents = \"all\"\n",
    );
    apply(&w);
    super::forget_the_move(&w.project.join(".kendex-lock.json"));
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    fs::write(w.dot().join("hooks.json"), registry).unwrap();
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    w
}

/// A catalog is free to change a hook's event, and a hook still waiting
/// to be migrated is then registered under the event the older version
/// installed. The record kept no event for a script-backed hook, so the
/// legacy entry is identified by its command alone — anything else calls
/// an ordinary catalog change tampering and holds an installation the
/// person cannot do anything about.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_that_changed_the_event_still_migrates() {
    let w = regressed();
    let source = w.catalog.join("hooks/guard.sh");
    let text = fs::read_to_string(&source).unwrap();
    let changed = text.replace("# event: PreToolUse", "# event: Stop");
    assert_ne!(changed, text, "the fixture has to change the event");
    fs::write(&source, changed).unwrap();
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains("tool_call"),
        "the installed registration is still under the event it was written with"
    );

    let said = notes(&w);
    assert!(said.is_empty(), "nothing here is anybody's doing: {said:?}");
    apply(&w);

    assert!(
        !w.dot().join("hooks").exists() && !w.dot().join("hooks.json").exists(),
        "the move finished"
    );
    let new = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    assert!(
        new.contains("turn_end") && !new.contains("tool_call"),
        "and what runs the hook is the event the catalog now asks for: {new}"
    );
    // A move that happened is a move with nothing left to do.
    let settled = audit(&w.env, &w.scope()).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
    assert!(settled.drift.is_empty(), "{:?}", settled.drift);
    assert!(settled.notes.is_empty(), "{:?}", settled.notes);
}

/// A command carried twice is one kendex cannot tell its own copy of,
/// however the two are spread across events. Taking the one under the
/// expected event would leave the other running a script that is no
/// longer there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_carried_under_two_events_is_nobodys_to_take() {
    let w = command_bodied_in_the_legacy_layout();
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let group = value["hooks"]["tool_call"][0].clone();
    value["hooks"]["turn_end"] = serde_json::json!([group]);
    let theirs = serde_json::to_string_pretty(&value).unwrap();
    fs::write(&registry, &theirs).unwrap();

    let said = about(&notes(&w), "hooks.json");
    assert!(
        said.iter().any(|note| note.contains("more than once")),
        "the person is told kendex cannot tell the two apart: {said:?}"
    );
    apply(&w);

    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        theirs,
        "neither entry is taken while both carry the same command"
    );
}

/// The same move at the other end: bytes already at the new path, and the
/// registration that runs them moved by hand. Read as migrated, this pass
/// would add its own registration under the event it renders and leave
/// the moved one firing too.
#[test]
#[allow(clippy::unwrap_used)]
fn a_new_registration_moved_to_another_event_is_never_doubled() {
    let w = world();
    apply(&w);
    let script = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    // The layout an older kendex left, still beside the new one — and a
    // lock from before there was any record of a finished move.
    super::forget_the_move(&w.project.join(".kendex-lock.json"));
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/guard.sh"), &script).unwrap();
    fs::write(
        w.dot().join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
    // And the person moved what runs the new copy.
    let moved = registry.replace("tool_call", "turn_end");
    assert_ne!(moved, registry, "the fixture has to move the event");
    fs::write(w.dot().join("kendex/hooks.json"), &moved).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard")
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("fire the hook twice"),
        "the row says what registering again would do: {}",
        row.detail
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap(),
        moved,
        "the registration the person moved is left exactly as they left it"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and the copy under the reserved name holds with it"
    );
}

/// A hold nothing about discarding edits can release must not be reported
/// as one that can. The remedy has to be the one that works, or the
/// person does what kendex told them and nothing changes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_no_discard_can_release_does_not_ask_for_a_discard() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let elsewhere = w.home.join("their-hooks.json");
    fs::rename(&registry, &elsewhere).unwrap();
    symlink(&elsewhere, &registry).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard")
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("registration") && row.detail.contains("hooks.json"),
        "the row names the registration in the way: {}",
        row.detail
    );
    assert!(
        !row.detail.contains("discard"),
        "and does not offer a remedy that cannot work: {}",
        row.detail
    );
    assert!(
        row.cause.is_none(),
        "nor one the app would offer for it: {:?}",
        row.cause
    );
}

/// A matcher is half of where a registration fires. Moved by hand within
/// the recorded event, the entry is still the only one carrying the
/// command, so uniqueness says nothing about it and the event says
/// nothing about it — and taking it would put the manifest's matcher back
/// silently, changing which operations run the person's hook.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_moved_to_another_matcher_is_not_kendexs_to_take() {
    let w = command_bodied_in_the_legacy_layout();
    let registry = w.dot().join("hooks.json");
    let text = fs::read_to_string(&registry).unwrap();
    let moved = text.replace("\"Bash\"", "\"Edit\"");
    assert_ne!(moved, text, "the fixture has to move the matcher");
    fs::write(&registry, &moved).unwrap();

    let said = about(&notes(&w), "hooks.json");
    assert!(
        said.iter().any(|note| note.contains("no longer registers")),
        "the person is told the entry is not where kendex left it: {said:?}"
    );
    apply(&w);

    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        moved,
        "the matcher they chose stays, and so does the entry"
    );
    let new = w.dot().join("kendex/hooks.json");
    assert!(
        !new.exists() || !fs::read_to_string(&new).unwrap().contains("mine.sh"),
        "and nothing put the old matcher back beside it"
    );
}

/// A matcher is a regex, and regexes have colons in them; a command is a
/// path, and paths take colons too. The character that joins the parts
/// for display is legal inside two of them, so identity is answered from
/// the parts a document keys — never from the joined form, whichever end
/// you start at.
#[test]
#[allow(clippy::unwrap_used)]
fn a_colon_inside_a_part_is_not_read_as_the_thing_that_joins_them() {
    for (what, matcher, command) in [
        ("a matcher with a colon", "Bash:.*", "./scripts/mine.sh"),
        ("a command with a colon", "Bash", "./scripts/foo:bar.sh"),
    ] {
        let w = super::world_declaring(&format!(
            "[[custom-hooks]]\nname = \"mine\"\nevent = \"PreToolUse\"\nmatcher = \"{matcher}\"\ncommand = \"{command}\"\nagents = \"all\"\n"
        ));
        apply(&w);
        let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
        assert!(
            registry.contains(matcher) && registry.contains(command),
            "{what}: goes in as it was written: {registry}"
        );

        let report = audit(&w.env, &w.scope()).unwrap();
        assert!(
            report.drift.is_empty(),
            "{what}: nothing was moved, so nothing is held: {:?}",
            report.drift
        );
        assert!(report.notes.is_empty(), "{what}: {:?}", report.notes);
        apply(&w);
        assert_eq!(
            fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap(),
            registry,
            "{what}: and the refresh goes on leaving it exactly as it is"
        );
    }
}

/// The record settles what is under the reserved name and says nothing
/// about the new path. A registration somebody moved there is theirs
/// either way — and which of those two questions gets asked must not turn
/// on whether some unrelated directory happens to exist beside them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_completed_hook_still_holds_over_a_registration_moved_at_the_new_path() {
    for beside in ["nothing else there", "a directory of somebody else's"] {
        let w = world();
        apply(&w);
        let registry = w.dot().join("kendex/hooks.json");
        let moved = fs::read_to_string(&registry)
            .unwrap()
            .replace("tool_call", "turn_end");
        fs::write(&registry, &moved).unwrap();
        if beside != "nothing else there" {
            fs::create_dir_all(w.dot().join("hooks")).unwrap();
            fs::write(w.dot().join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();
        }

        let report = audit(&w.env, &w.scope()).unwrap();
        let row = report
            .drift
            .iter()
            .find(|row| row.name == "guard" && row.state == DriftState::Conflict)
            .unwrap_or_else(|| panic!("{beside}: the hold has to be reported: {:?}", report.drift));
        assert!(
            row.detail.contains("fire the hook twice"),
            "{beside}: {}",
            row.detail
        );
        kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

        assert_eq!(
            fs::read_to_string(&registry).unwrap(),
            moved,
            "{beside}: what they moved is not moved back for them"
        );
    }
}

/// An installation from before kendex recorded what it registered keeps
/// the reading it always had: nothing invents a record for it, and the
/// guard that matters most — a registration somebody moved being doubled
/// by a fresh one — still holds without one.
#[test]
#[allow(clippy::unwrap_used)]
fn an_entry_from_before_the_record_still_holds_over_a_moved_registration() {
    let w = world();
    apply(&w);
    let path = w.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    lock["entries"]["hook:guard:pi"]
        .as_object_mut()
        .unwrap()
        .remove("registration");
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

    let registry = w.dot().join("kendex/hooks.json");
    let moved = fs::read_to_string(&registry)
        .unwrap()
        .replace("tool_call", "turn_end");
    fs::write(&registry, &moved).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "guard" && row.state == DriftState::Conflict),
        "unknown stays unknown, and what is unknown holds: {:?}",
        report.drift
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        moved,
        "so what they moved is left where they moved it"
    );
}

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
