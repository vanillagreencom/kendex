//! The two halves of "is a replacement coming", pinned one at a time. A
//! hook's script and its registration each answer for themselves, and
//! either one missing keeps the old copy running.

use std::fs;

use kendex_core::engine::{PlanOptions, audit, plan_apply};
use kendex_core::model::ItemKind;

use super::{World, apply, notes, regress, regressed, world};

/// Installed at the new paths, then regressed — with the pieces of the
/// new layout handed back so a test can put exactly one of them in place.
#[allow(clippy::unwrap_used)]
fn half_migrated() -> (World, String, String) {
    let w = world();
    apply(&w);
    let script = fs::read_to_string(w.dot().join("kendex/hooks/guard.sh")).unwrap();
    let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
    regress(&w, "guard.sh");
    fs::remove_dir_all(w.dot().join("kendex")).unwrap();
    fs::create_dir_all(w.dot().join("kendex/hooks")).unwrap();
    (w, script, registry)
}

/// The registration is in place and only the script is missing: an edited
/// file at the new path is a conflict this pass writes nothing over, so
/// the copy that is still running stays.
#[test]
#[allow(clippy::unwrap_used)]
fn the_script_alone_can_hold_the_move() {
    let (w, _, registry) = half_migrated();
    fs::write(w.dot().join("kendex/hooks.json"), registry).unwrap();
    fs::write(
        w.dot().join("kendex/hooks/guard.sh"),
        "#!/bin/sh\n# not what kendex renders\nexit 0\n",
    )
    .unwrap();

    assert!(
        notes(&w)
            .iter()
            .any(|note| note.contains("was not written at")),
        "{:?}",
        notes(&w)
    );
    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "no script was written this pass, so the running copy stays"
    );
    assert!(w.dot().join("hooks.json").is_file());
}

/// The script is in place and only the registration is missing: a
/// registry kendex cannot edit blocks the registration, and a hook with
/// no registration anywhere would not run at all.
#[test]
#[allow(clippy::unwrap_used)]
fn the_registration_alone_can_hold_the_move() {
    let (w, script, _) = half_migrated();
    fs::write(w.dot().join("kendex/hooks/guard.sh"), script).unwrap();
    fs::write(w.dot().join("kendex/hooks.json"), "{ not json").unwrap();

    assert!(
        notes(&w)
            .iter()
            .any(|note| note.contains("was not written at")),
        "{:?}",
        notes(&w)
    );
    apply(&w);

    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "nothing registered the new script, so the registered one stays"
    );
    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "and it keeps the registration that runs it"
    );
}

/// Both halves in place is what completes the move — the control that
/// says the two tests above are held by their own gate and not by the
/// fixture being broken in some other way.
#[test]
#[allow(clippy::unwrap_used)]
fn both_halves_in_place_complete_the_move() {
    let (w, script, registry) = half_migrated();
    fs::write(w.dot().join("kendex/hooks/guard.sh"), script).unwrap();
    fs::write(w.dot().join("kendex/hooks.json"), registry).unwrap();

    let report = audit(&w.env, &w.scope()).unwrap();
    assert!(report.notes.is_empty(), "{:?}", report.notes);
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(!w.dot().join("hooks").exists());
    assert!(!w.dot().join("hooks.json").exists());
}

/// The remedy kendex prints has to work. Applying with edits discarded
/// finishes the move in that same pass: the reserved directory goes, one
/// registration is left, and the next audit has nothing to say.
#[test]
#[allow(clippy::unwrap_used)]
fn discarding_edits_finishes_the_move_in_one_pass() {
    for options in [
        PlanOptions {
            overwrite_edited: true,
            ..PlanOptions::default()
        },
        PlanOptions {
            overwrite_edited_names: Some(vec![(ItemKind::Hook, "guard".to_owned())]),
            ..PlanOptions::default()
        },
    ] {
        let w = regressed();
        let edited = w.dot().join("hooks/guard.sh");
        fs::write(&edited, "#!/bin/sh\n# mine\nexit 0\n").unwrap();

        let report = plan_apply(&w.env, &w.scope(), &options).unwrap();
        kendex_core::apply::execute(&w.env, &report.plan).unwrap();

        assert!(!w.dot().join("hooks").exists(), "the move finished");
        assert!(!w.dot().join("hooks.json").exists());
        assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
        let registry = fs::read_to_string(w.dot().join("kendex/hooks.json")).unwrap();
        assert!(registry.contains("kendex/hooks/guard.sh"), "{registry}");

        // One registration, and nothing left to say about it.
        let after = audit(&w.env, &w.scope()).unwrap();
        assert!(after.plan.ops.is_empty(), "{:?}", after.plan.ops);
        assert!(after.notes.is_empty(), "{:?}", after.notes);
        assert!(after.drift.is_empty(), "{:?}", after.drift);
    }
}

/// A clean copy at the new path is not a finished migration while the
/// old registration is still the one that runs: the edited copy has to
/// keep running until the person says otherwise, or their edits would
/// quietly stop being what executes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_copy_at_the_new_path_is_not_a_finished_move() {
    let (w, script, _) = half_migrated();
    fs::write(w.dot().join("kendex/hooks/guard.sh"), script).unwrap();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();

    let said = notes(&w);
    assert!(
        said.iter().any(|note| note.contains("was edited on disk")),
        "{said:?}"
    );
    apply(&w);

    assert!(
        fs::read_to_string(w.dot().join("hooks.json"))
            .unwrap()
            .contains(".pi/hooks/guard.sh"),
        "the edited copy is still what runs"
    );
    let new = w.dot().join("kendex/hooks.json");
    assert!(
        !new.exists() || !fs::read_to_string(&new).unwrap().contains("guard.sh"),
        "and nothing took execution from it"
    );
}

/// Discarding edits is permission to replace bytes kendex wrote at a file
/// path, and a removal is permission to be rid of them. A directory
/// somebody put there is neither — `hash_tree` would hash the whole tree
/// as happily as a file, so the gates have to ask what is at the path and
/// not only whether it can be read. The installation holds whole, as it
/// does for every other copy kendex cannot claim.
#[test]
#[allow(clippy::unwrap_used)]
fn a_directory_where_the_script_was_is_never_taken() {
    for (asked, options) in [
        (
            "edits discarded",
            PlanOptions {
                overwrite_edited: true,
                ..PlanOptions::default()
            },
        ),
        (
            "removed by name",
            PlanOptions {
                remove_orphans: true,
                removal_filter_typed: Some(vec![(ItemKind::Hook, "guard".to_owned())]),
                ..PlanOptions::default()
            },
        ),
    ] {
        let w = regressed();
        let theirs = w.dot().join("hooks/guard.sh");
        fs::remove_file(&theirs).unwrap();
        fs::create_dir(&theirs).unwrap();
        fs::write(theirs.join("notes.md"), "mine\n").unwrap();

        let report = plan_apply(&w.env, &w.scope(), &options).unwrap();
        assert!(
            report
                .notes
                .iter()
                .any(|note| note.contains("guard.sh") && note.contains("not a plain file")),
            "{asked}: the person is told what is in the way: {:?}",
            report.notes
        );
        kendex_core::apply::execute(&w.env, &report.plan).unwrap();

        assert_eq!(
            fs::read_to_string(theirs.join("notes.md")).unwrap(),
            "mine\n",
            "{asked}: a directory of theirs is never what a discard takes"
        );
        assert!(
            !w.dot().join("kendex/hooks/guard.sh").exists(),
            "{asked}: and nothing takes over from a copy kendex cannot claim"
        );
        assert!(
            fs::read_to_string(w.dot().join("hooks.json"))
                .unwrap()
                .contains(".pi/hooks/guard.sh"),
            "{asked}: what runs the hook stays with it"
        );
        let lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
                .unwrap();
        assert!(
            lock["entries"].get("hook:guard:pi").is_some(),
            "{asked}: the record is the only thing that can claim the path later: {lock}"
        );
    }
}
