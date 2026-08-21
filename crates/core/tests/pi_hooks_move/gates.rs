//! The two halves of "is a replacement coming", pinned one at a time. A
//! hook's script and its registration each answer for themselves, and
//! either one missing keeps the old copy running.

use std::fs;

use kendex_core::engine::audit;

use super::{World, apply, notes, regress, world};

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
