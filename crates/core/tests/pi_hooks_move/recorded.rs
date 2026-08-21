//! The record itself: that a hook's move out of the reserved name is
//! over. Written where completion is proven and nowhere else, carried
//! through everything a later pass does to the installation, and read
//! back instead of worked out again — the reading it replaced un-answered
//! itself whenever anything on disk drifted.

use std::fs;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use super::{World, apply, regressed, world};

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

/// What kendex registered is recorded, so a catalog moving the hook to
/// another event afterwards is read as what it is: the record still names
/// the entry that is there, so nothing is held and the refresh goes
/// through. Worked out from what the catalog renders now instead, the
/// entry kendex itself wrote read as one the person had moved, and no
/// discard could release the hold that followed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_moving_the_event_after_the_move_is_not_a_hand_moved_entry() {
    let w = world();
    apply(&w);
    let registry = w.dot().join("kendex/hooks.json");
    assert!(
        fs::read_to_string(&registry).unwrap().contains("tool_call"),
        "the hook went in under the event the catalog then asked for"
    );

    let source = w.catalog.join("hooks/guard.sh");
    let text = fs::read_to_string(&source).unwrap();
    fs::write(
        &source,
        text.replace("# event: PreToolUse", "# event: Stop"),
    )
    .unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report
            .drift
            .iter()
            .all(|row| row.state != DriftState::Conflict),
        "a catalog is allowed to change an event: {:?}",
        report.drift
    );
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        fs::read_to_string(&registry).unwrap().contains("turn_end"),
        "and the refresh registers what it now asks for"
    );
}
