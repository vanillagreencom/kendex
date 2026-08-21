//! Whose way a hold is in. The document itself may be one kendex cannot
//! edit, which is in the way of every hook needing an edit in it; one
//! hook's own entry may be one kendex cannot pick out, which is in that
//! hook's way and nobody else's; and a hook on record as finished is in
//! nobody's way at all.

use std::fs;
use std::os::unix::fs::symlink;

use super::{about, apply, notes, world};

/// Evidence about one hook's entry is evidence about that entry. A
/// sibling whose own registration is exactly where its record says has
/// nothing to do with it, and waits for nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn one_hooks_ambiguous_entry_does_not_hold_its_siblings() {
    let w = world();
    super::declare_second_hook(&w);
    apply(&w);
    super::regress(&w, "guard.sh");
    super::regress(&w, "other.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    // The same command twice, under a second matcher somebody added: one
    // of the two is kendex's and neither says which.
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    let group = value["hooks"]["tool_call"][0].clone();
    value["hooks"]["tool_call"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "matcher": "edit",
            "hooks": group["hooks"].clone(),
        }));
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    let said = about(&notes(&w), "guard.sh");
    assert!(
        said.iter().any(|note| note.contains("more than once")),
        "the hook whose entry cannot be told apart is named: {said:?}"
    );
    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "the ambiguous one stays with the entry nobody can pick out"
    );
    assert!(
        !w.dot().join("hooks/other.sh").exists(),
        "and the one whose entry is exactly where its record says moves"
    );
    assert!(w.dot().join("kendex/hooks/other.sh").is_file());
}

/// The other half: when the document itself cannot be edited, every hook
/// that needs an edit in it waits — the obstacle is the file, not any one
/// entry.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_nothing_can_be_taken_out_of_holds_every_hook() {
    let w = world();
    super::declare_second_hook(&w);
    apply(&w);
    super::regress(&w, "guard.sh");
    super::regress(&w, "other.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    let registry = w.dot().join("hooks.json");
    let elsewhere = w.home.join("their-hooks.json");
    fs::rename(&registry, &elsewhere).unwrap();
    symlink(&elsewhere, &registry).unwrap();

    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file() && w.dot().join("hooks/other.sh").is_file(),
        "neither hook gives up its script while its registration has to stay"
    );
}

/// A hook on record as finished has no registration of kendex's under the
/// reserved name to be in anybody's way with: what wears its command
/// there is the person's. Left in the reckoning, it would keep a document
/// kendex cannot edit "in the way" of a sibling that still has to move,
/// for ever.
#[test]
#[allow(clippy::unwrap_used)]
fn a_finished_hook_does_not_keep_the_registry_in_anybodys_way() {
    let w = super::world_declaring(
        "[hooks.guard]\nsource = \"cat\"\n\n[hooks.other]\nsource = \"cat\"\nenabled = false\n",
    );
    fs::write(
        w.catalog.join("hooks/other.sh"),
        "#!/bin/sh\n# ---\n# name: other\n# event: Stop\n# description: another guard\n# harnesses: [pi]\n# ---\nexit 0\n",
    )
    .unwrap();
    apply(&w);
    let disabled = w.dot().join("kendex/hooks/other.sh.disabled");
    assert!(disabled.is_file(), "the second hook registers nothing");

    // Only the second hook is still on its way out; the first is done,
    // and what wears its old command now is the person's own.
    let path = w.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    lock["entries"]["hook:other:pi"]
        .as_object_mut()
        .unwrap()
        .remove("leftPiReservedName");
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::rename(&disabled, w.dot().join("hooks/other.sh.disabled")).unwrap();
    // Their own document, in a shape kendex's editor cannot rewrite, and
    // their own registration of the command kendex used to spell.
    let theirs = "// mine\n{\"hooks\":{\"tool_call\":[{\"hooks\":[{\"command\":\"bash \\\"$(git rev-parse --show-toplevel)/.pi/hooks/guard.sh\\\"\"}]}]}}\n"
        .to_owned();
    fs::write(w.dot().join("hooks.json"), &theirs).unwrap();

    apply(&w);

    assert!(
        !w.dot().join("hooks/other.sh.disabled").exists(),
        "the hook that still had to move moved"
    );
    assert!(w.dot().join("kendex/hooks/other.sh.disabled").is_file());
    assert_eq!(
        fs::read_to_string(w.dot().join("hooks.json")).unwrap(),
        theirs,
        "and their document is left exactly as it was"
    );
}
