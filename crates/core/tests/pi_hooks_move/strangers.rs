//! What kendex may not take out of the directory Pi reserved: a file it
//! did not write, a directory it has nothing left in, and a registry
//! holding somebody's own hook.

use std::fs;

use kendex_core::engine::audit;
use kendex_core::model::Scope;

use super::{about, apply, notes, regressed, world};

#[test]
#[allow(clippy::unwrap_used)]
fn a_file_kendex_did_not_write_keeps_the_reserved_directory_alive() {
    let w = regressed();
    let stranger = w.dot().join("hooks/theirs.sh");
    fs::write(&stranger, "#!/bin/sh\nexit 0\n").unwrap();

    assert_eq!(about(&notes(&w), "theirs.sh").len(), 1);
    apply(&w);

    assert!(stranger.is_file(), "a stranger's file is never taken");
    assert!(!w.dot().join("hooks/guard.sh").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
}

/// Once kendex holds nothing under the reserved name, a directory someone
/// else puts there later is none of its business — and earns no line.
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_appearing_after_the_move_says_nothing() {
    let w = regressed();
    apply(&w);
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(w.dot().join("hooks/theirs.sh").is_file());
}

/// An empty `hooks/` holds nothing kendex can claim, so the whole-
/// directory take must not fire on it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_empty_reserved_directory_nobody_claimed_survives() {
    let w = world();
    apply(&w);
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks.json"), "{\"hooks\":{}}\n").unwrap();

    apply(&w);
    assert!(w.dot().join("hooks").is_dir());
    assert_eq!(
        fs::read_to_string(w.dot().join("hooks.json")).unwrap(),
        "{\"hooks\":{}}\n",
        "a file kendex has nothing to remove from is not even reformatted"
    );
}

/// The registry is the one file kendex shares: a hook somebody wrote by
/// hand keeps its entry, and the file keeps its place.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_registry_entry_survives_the_move() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    value["hooks"]["turn_end"] = serde_json::json!([{
        "hooks": [{ "type": "command", "command": "echo theirs" }]
    }]);
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();

    apply(&w);

    let text = fs::read_to_string(&registry).unwrap();
    assert!(text.contains("echo theirs"), "{text}");
    assert!(
        !text.contains(".pi/hooks/guard.sh"),
        "only kendex's own entry comes out: {text}"
    );
}

/// The same promise at the global scope, where the reserved names sit
/// beside `~/.pi/agent`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_registry_kendex_never_wrote_to_is_left_alone() {
    let w = world();
    let agent = w.home.join(".pi/agent");
    fs::create_dir_all(agent.join("hooks")).unwrap();
    fs::write(agent.join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();
    fs::write(
        agent.join("hooks.json"),
        "{\"hooks\":{\"turn_end\":[{\"hooks\":[{\"command\":\"echo theirs\"}]}]}}\n",
    )
    .unwrap();
    let manifest = w.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"pi\"]\n\n[hooks.guard]\nsource = \"cat\"\n",
            w.catalog.display()
        ),
    )
    .unwrap();

    // Twice: the first apply is what writes the lock the move reads.
    for _ in 0..2 {
        let report = audit(&w.env, &Scope::Global).unwrap();
        kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    }

    assert!(agent.join("hooks/theirs.sh").is_file());
    assert!(
        fs::read_to_string(agent.join("hooks.json"))
            .unwrap()
            .contains("echo theirs")
    );
    assert!(agent.join("kendex/hooks/guard.sh").is_file());
}
