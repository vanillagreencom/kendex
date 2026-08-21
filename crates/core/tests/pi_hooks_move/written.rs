//! What decides to write the record, which is worth exactly what the
//! record is: a completion recorded wrongly cannot be taken back by any
//! later pass, so nothing is written where the move is not proven over.

use std::fs;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use super::{apply, forget_the_move, regressed, undeclare, world};

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

/// "Nothing of mine is under the reserved name" and "this installation is
/// in good order" are different questions, and only the first one is
/// about that directory. An older install whose old layout is already
/// gone, whose registration at the new path somebody moved by hand, must
/// still be held: registering the fresh one beside it fires the hook
/// twice, and writing that down as a finished move makes it permanent.
#[test]
#[allow(clippy::unwrap_used)]
fn a_moved_new_registration_holds_even_with_the_old_layout_gone() {
    let w = world();
    apply(&w);
    assert!(
        !w.dot().join("hooks").exists() && !w.dot().join("hooks.json").exists(),
        "nothing of kendex's is under the reserved name"
    );
    // A record from before there was one to keep, as an install that
    // migrated under an older kendex carries.
    forget_the_move(&w.project.join(".kendex-lock.json"));
    let registry = w.dot().join("kendex/hooks.json");
    let moved = fs::read_to_string(&registry)
        .unwrap()
        .replace("tool_call", "turn_end");
    fs::write(&registry, &moved).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard" && row.state == DriftState::Conflict)
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("fire the hook twice"),
        "and say what registering again would do: {}",
        row.detail
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert_eq!(
        fs::read_to_string(&registry).unwrap(),
        moved,
        "nothing is registered beside the entry they moved"
    );
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"]["hook:guard:pi"]
            .get("leftPiReservedName")
            .is_none(),
        "and a hold is not a finished move: {lock}"
    );
}

/// An edit that ran is not an entry that went. A handler standing
/// directly under its event is a shape the removal reaches past — it
/// succeeds and takes nothing — so the outcome is read back before the
/// script it names is planned for the trash, or the script would go and
/// leave what runs it pointing at nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_the_edit_cannot_reach_holds_its_script() {
    for shape in ["direct", "grouped"] {
        let w = regressed();
        let registry = w.dot().join("hooks.json");
        let mut value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
        let command = value["hooks"]["tool_call"][0]["hooks"][0]["command"].clone();
        if shape == "direct" {
            // The way a person writes one, and a way kendex never does.
            value["hooks"]["tool_call"] = serde_json::json!([{ "command": command }]);
        }
        let theirs = serde_json::to_string_pretty(&value).unwrap();
        fs::write(&registry, &theirs).unwrap();

        let said = super::about(&super::notes(&w), "hooks.json");
        apply(&w);

        if shape == "grouped" {
            assert!(said.is_empty(), "the shape kendex writes moves: {said:?}");
            assert!(!w.dot().join("hooks").exists());
            assert!(!registry.exists());
            continue;
        }
        assert!(
            said.iter().any(|note| note.contains("cannot take it out")),
            "the person is told which document is in the way: {said:?}"
        );
        assert!(
            w.dot().join("hooks/guard.sh").is_file(),
            "the script stays with the registration that names it"
        );
        assert_eq!(
            fs::read_to_string(&registry).unwrap(),
            theirs,
            "and their document is untouched"
        );
        let lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
                .unwrap();
        assert!(
            lock["entries"]["hook:guard:pi"]
                .get("leftPiReservedName")
                .is_none(),
            "and a move that did not happen is not written down: {lock}"
        );
    }
}
