//! The record itself: that a hook's move out of the reserved name is
//! over. Written where completion is proven and nowhere else, carried
//! through everything a later pass does to the installation, and read
//! back instead of worked out again — the reading it replaced un-answered
//! itself whenever anything on disk drifted.

use std::fs;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use super::{World, apply, forget_the_move, regressed, undeclare, world};

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

/// The record is only as good as what decides to write it, and a wrong
/// "finished" cannot be taken back by any later pass. A new registration
/// standing beside a live old one is not a finished move, however much of
/// the new layout is in place: the old copy is still firing, so the hold
/// stands and nothing is written down.
#[test]
#[allow(clippy::unwrap_used)]
fn a_live_old_registration_is_not_a_finished_move() {
    let w = world();
    apply(&w);
    let script = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    forget_the_move(&w.project.join(".kendex-lock.json"));
    // Both registries live, and the copy under the reserved name edited.
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();
    fs::write(
        w.dot().join("hooks.json"),
        registry.replace(".pi/kendex/hooks/", ".pi/hooks/"),
    )
    .unwrap();
    assert!(script.contains("exit 0"), "the new copy is kendex's own");

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("was edited on disk")),
        "the edit hold still applies: {:?}",
        report.notes
    );
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "guard" && row.state == DriftState::Conflict),
        "and it is reported: {:?}",
        report.drift
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap(),
        "#!/bin/sh\n# mine\nexit 0\n",
        "their edited copy stays, and it is still what runs"
    );
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"]["hook:guard:pi"]
            .get("leftPiReservedName")
            .is_none(),
        "and a move that did not finish is not written down as finished: {lock}"
    );
}

/// Somebody else's files under the reserved name say nothing about a hook
/// that was never there. A first install beside them has finished by
/// definition, and has to be written down as such on that pass — or the
/// reading takes over, and a script the person writes at the old name
/// with the bytes kendex happens to render is read as kendex's own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_install_beside_somebody_elses_files_is_finished() {
    let w = world();
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/theirs.sh"), "#!/bin/sh\nexit 0\n").unwrap();
    fs::write(
        w.dot().join("hooks.json"),
        "{\"hooks\":{\"turn_end\":[{\"hooks\":[{\"command\":\"echo theirs\"}]}]}}\n",
    )
    .unwrap();

    apply(&w);

    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert_eq!(
        lock["entries"]["hook:guard:pi"]["leftPiReservedName"],
        serde_json::json!(true),
        "the hook was never under the reserved name: {lock}"
    );

    // And now they write their own hook there, spelled the way kendex
    // spells one.
    let theirs = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
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
        "which is theirs, and stays theirs"
    );
    assert!(w.dot().join("hooks/theirs.sh").is_file());
}

/// A hook installed disabled registers nothing anywhere, and that
/// absence is the installation, not a move half done. Read the other way
/// — with the record dropped, as a lock written before there was one
/// carries it — a disabled hook would be migrating for ever, and would
/// hold on the first file anybody put under the reserved name wearing
/// its name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_disabled_hook_finishes_without_a_registration_to_stand_on() {
    let w = super::world_declaring("[hooks.guard]\nsource = \"cat\"\nenabled = false\n");
    apply(&w);
    assert!(w.dot().join("kendex/hooks/guard.sh.disabled").is_file());
    assert!(
        !w.dot().join("kendex/hooks.json").exists(),
        "a disabled hook registers nothing, which is the whole point"
    );
    forget_the_move(&w.project.join(".kendex-lock.json"));

    // Somebody else's file, wearing the name kendex's copy used to have.
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(w.dot().join("hooks/guard.sh"), "#!/bin/sh\n# theirs\n").unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(
        report.notes.is_empty(),
        "the move is over; a stranger's file is not kendex's to wait on: {:?}",
        report.notes
    );
    assert!(report.drift.is_empty(), "{:?}", report.drift);
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert_eq!(
        fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap(),
        "#!/bin/sh\n# theirs\n"
    );
}

/// A hook nothing declares any more still finishes moving — its copy is
/// retired, which is the whole of what it had under the reserved name.
/// Its record is carried forward from the old one after the move has run,
/// so the completion has to be written where every entry that will exist
/// already does, or the pass earns a fact it then throws away.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_nothing_declares_keeps_the_completion_it_earned() {
    let w = regressed();
    let theirs = fs::read_to_string(w.dot().join("hooks/guard.sh")).unwrap();
    undeclare(&w);

    let report = plan_apply(
        &w.env,
        &w.scope(),
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        !w.dot().join("hooks").exists(),
        "the copy nothing asks for is retired"
    );

    let path = w.project.join(".kendex-lock.json");
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(
        lock["entries"]["hook:guard:pi"]["leftPiReservedName"],
        serde_json::json!(true),
        "and the record it earned survives being carried forward: {lock}"
    );

    // What they put back there afterwards is theirs, bytes and all.
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
        theirs
    );
}

/// The record is only durable if a build that cannot honour it refuses
/// the file rather than dropping the field on its next write — and then
/// reading a finished move as unfinished, which is where it reclaims what
/// the person has since put under the reserved name. That refusal is the
/// schema version's job, so the version has to move when the evidence
/// does.
#[test]
#[allow(clippy::unwrap_used)]
fn the_record_travels_with_a_version_an_older_build_refuses() {
    /// The last lock version that knew nothing of a finished pi move. A
    /// build at this version refuses anything above it.
    const BEFORE_THE_RECORD: u64 = 4;

    let w = world();
    apply(&w);

    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert_eq!(
        lock["entries"]["hook:guard:pi"]["leftPiReservedName"],
        serde_json::json!(true),
        "the evidence is in the file: {lock}"
    );
    assert!(
        lock["version"].as_u64().unwrap() > BEFORE_THE_RECORD,
        "and the file says so loudly enough to be refused: {lock}"
    );
}
