//! A registration somebody moved to another listener, in both registries.
//! kendex knows the event it renders a hook under, so a command sitting
//! under a different one is not the registration it wrote — taking it out
//! would stop a hook the person moved, and registering beside it would
//! fire the hook twice.

use std::fs;
use std::os::unix::fs::symlink;

use kendex_core::engine::audit;

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
    // The layout an older kendex left, still beside the new one.
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
