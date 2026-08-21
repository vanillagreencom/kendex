//! What the reserved name holds once the move is done. Nothing there is
//! kendex's any more — not a file, not a directory, and not a registry
//! entry spelling the command kendex used to write — so a person putting
//! their own hook back where the old one lived keeps every piece of it.

use std::fs;

use kendex_core::engine::{PlanOptions, audit, plan_apply};

use super::{World, apply, regressed, world};

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

/// The record of a finished move, and the three ways the reading it
/// replaced used to un-answer itself. Whatever changes afterwards — the
/// new copy edited, the catalog's event changed, the old path filled
/// with bytes spelled exactly the way kendex spelled them — the move
/// stays finished and none of it is claimed, discard or no discard.
#[test]
#[allow(clippy::unwrap_used)]
fn a_finished_move_is_recorded_and_never_re_opened() {
    #[allow(clippy::type_complexity)]
    let drifts: [(&str, &dyn Fn(&World)); 3] = [
        ("the new copy is edited", &|w| {
            fs::write(
                w.dot().join("kendex/hooks/guard.sh"),
                "#!/bin/sh\n# mine\nexit 0\n",
            )
            .unwrap()
        }),
        ("the catalog changes the event", &|w| {
            let source = w.catalog.join("hooks/guard.sh");
            let text = fs::read_to_string(&source).unwrap();
            fs::write(
                &source,
                text.replace("# event: PreToolUse", "# event: Stop"),
            )
            .unwrap()
        }),
        ("nothing else changes", &|_| {}),
    ];
    for (drift, spoil) in drifts {
        let w = regressed();
        let theirs = fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap();
        apply(&w);

        let lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
                .unwrap();
        assert_eq!(
            lock["entries"]["hook:guard:pi"]["leftPiReservedName"],
            serde_json::json!(true),
            "{drift}: the finished move is written down: {lock}"
        );
        spoil(&w);

        // Byte for byte what kendex used to keep there, which is the one
        // shape an ownership question answers "mine" to.
        fs::create_dir_all(w.dot().join("hooks")).unwrap();
        fs::write(w.dot().join("hooks/guard.sh"), &theirs).unwrap();

        let report = plan_apply(
            &w.env,
            &w.scope(),
            &PlanOptions {
                remove_orphans: true,
                sweep_unneeded: true,
                overwrite_edited: true,
                ..PlanOptions::default()
            },
        )
        .unwrap();
        kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

        assert_eq!(
            fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap(),
            theirs,
            "{drift}: what they put back under the reserved name is theirs"
        );
    }
}

/// A hook installed fresh was never under the reserved name at all, which
/// is the same fact by another road — and it is written down on the pass
/// that installs it, not the one after, because the person can reach for
/// that directory before any second pass.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_install_has_left_the_reserved_name_too() {
    let w = world();
    apply(&w);

    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert_eq!(
        lock["entries"]["hook:guard:pi"]["leftPiReservedName"],
        serde_json::json!(true),
        "the first pass writes it: {lock}"
    );

    // Their own hook, at the name an older kendex used, spelled the way
    // kendex spells one.
    let theirs = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/guard.sh"), &theirs).unwrap();

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            overwrite_edited: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap(),
        theirs,
        "and nothing kendex does afterwards reaches into that directory"
    );
}
