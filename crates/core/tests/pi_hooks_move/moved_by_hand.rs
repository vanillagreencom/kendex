//! A registration somebody moved to another listener, in both registries.
//! kendex knows the event it renders a hook under, so a command sitting
//! under a different one is not the registration it wrote — taking it out
//! would stop a hook the person moved, and registering beside it would
//! fire the hook twice.

use std::fs;
use std::os::unix::fs::symlink;

use kendex_core::engine::audit;

use super::{about, apply, notes, regressed, world};

/// Moving the event of a script-backed hook is the common shape: the lock
/// records no registration for one, so the event has to be derived from
/// what this pass renders, or the identity is the command alone and a
/// moved entry reads as kendex's own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_registration_moved_to_another_event_is_not_kendexs_to_take() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let text = fs::read_to_string(&registry).unwrap();
    let moved = text.replace("tool_call", "turn_end");
    assert_ne!(moved, text, "the fixture has to move the event");
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
        "what is there now is not kendex's to take"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and the script that entry names stays with it"
    );
    let new = w.dot().join("kendex/hooks.json");
    assert!(
        !new.exists() || !fs::read_to_string(&new).unwrap().contains("guard.sh"),
        "nothing was registered alongside it, or the hook would fire twice"
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
