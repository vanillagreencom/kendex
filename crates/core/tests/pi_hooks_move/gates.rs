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
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

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
        kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

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
