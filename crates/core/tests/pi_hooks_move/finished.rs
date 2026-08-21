//! What the reserved name holds once the move is done. Nothing there is
//! kendex's any more — not a file, not a directory, and not a registry
//! entry spelling the command kendex used to write — so a person putting
//! their own hook back where the old one lived keeps every piece of it.

use std::fs;

use kendex_core::engine::audit;

use super::{apply, regressed};

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

/// What a person puts under the reserved name after the move has finished
/// is theirs, registration included. The registry can outlive the move by
/// holding somebody else's entries, and a command spelled exactly as the
/// one kendex used to register proves nothing once kendex has nothing
/// there to claim: taking it would leave their script running nowhere.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_written_after_the_move_is_theirs_too() {
    let w = regressed();
    let registry = w.dot().join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    // Somebody else's entry, so the registry outlives the move.
    value["hooks"]["session_start"] = serde_json::json!([{
        "hooks": [{ "type": "command", "command": "echo theirs" }]
    }]);
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();
    apply(&w);
    assert!(!w.dot().join("hooks").exists(), "the move finished");

    // And now the person writes their own hook where kendex used to keep
    // one, registered with the command kendex used to spell.
    let theirs = w.dot().join("hooks/guard.sh");
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(&theirs, "#!/bin/sh\n# mine\nexit 0\n").unwrap();
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    value["hooks"]["tool_call"] = serde_json::json!([{
        "hooks": [{
            "type": "command",
            "command": "bash \"$(git rev-parse --show-toplevel)/.pi/hooks/guard.sh\"",
        }]
    }]);
    let mine = serde_json::to_string_pretty(&value).unwrap();
    fs::write(&registry, &mine).unwrap();

    for pass in 1..=2 {
        apply(&w);
        assert_eq!(
            fs::read_to_string(&registry).unwrap(),
            mine,
            "pass {pass}: their registration is not kendex's to take"
        );
        assert_eq!(
            fs::read_to_string(&theirs).unwrap(),
            "#!/bin/sh\n# mine\nexit 0\n",
            "pass {pass}: and neither is the script it names"
        );
    }
}
