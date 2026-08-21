//! The three answers to "is a replacement coming". A hook nobody declares
//! any more is retired outright — leaving it would keep a removed hook
//! firing and pi warning forever. A hook switched off is retired and
//! deregistered. Only a declaration this pass could not resolve waits, and
//! it completes as soon as the source is back.

use std::fs;

use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};

use std::os::unix::fs::PermissionsExt;

use super::{World, about, apply, forget_rendered_hash, notes, regressed, undeclare};

#[allow(clippy::unwrap_used)]
fn apply_with(w: &World, options: &PlanOptions) {
    let report = plan_apply(&w.env, &w.scope(), options).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
}

/// What `kendex refresh` runs.
fn refresh() -> PlanOptions {
    PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

/// What `kendex apply` and the app run.
fn reconcile() -> PlanOptions {
    PlanOptions {
        remove_orphans: true,
        sweep_unneeded: true,
        ..PlanOptions::default()
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_nobody_declares_takes_its_old_copy_with_it_on_refresh() {
    let w = regressed();
    undeclare(&w);
    // With the catalog gone too, nothing can say why it was ever here —
    // and it was asked for by name, so that is answer enough.
    fs::remove_dir_all(&w.catalog).unwrap();

    apply_with(&w, &refresh());

    assert!(
        !w.dot().join("hooks").exists(),
        "a removed hook must not keep the reserved directory alive"
    );
    assert!(
        !w.dot().join("hooks.json").exists(),
        "nor its registration: the hook the user removed would keep firing"
    );
    assert!(
        !w.dot().join("kendex/hooks/guard.sh").exists(),
        "and nothing was rendered at the new path either — it is undeclared"
    );
}

/// The orphan sweep drops the lock entry in the same pass, so this is the
/// last plan that could ever claim the old files.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_nobody_declares_takes_its_old_copy_with_it_on_reconcile() {
    let w = regressed();
    undeclare(&w);

    apply_with(&w, &reconcile());

    assert!(!w.dot().join("hooks").exists());
    assert!(!w.dot().join("hooks.json").exists());
    assert!(!w.dot().join("kendex/hooks/guard.sh").exists());
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(
        lock["entries"].get("hook:guard:pi").is_none(),
        "the record goes with the files, not before them: {lock}"
    );
}

/// Switching a hook off registers nothing, so nothing at the new path
/// proves the move — but the old registration must still come out, or the
/// hook the user switched off keeps running.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_switched_off_is_deregistered_from_the_old_registry() {
    let w = regressed();
    let manifest = w.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    fs::write(
        &manifest,
        text.replace("[hooks.guard]\n", "[hooks.guard]\nenabled = false\n"),
    )
    .unwrap();

    apply(&w);

    assert!(
        !w.dot().join("hooks").exists(),
        "the reserved directory goes with the hook that was in it"
    );
    assert!(!w.dot().join("hooks.json").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh.disabled").is_file());
}

/// The hold is repair, not abandonment: the move completes the moment the
/// declaration can be rendered again.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_move_completes_once_the_source_is_back() {
    let w = regressed();
    let script = w.catalog.join("hooks/guard.sh");
    let body = fs::read_to_string(&script).unwrap();
    fs::remove_file(&script).unwrap();

    apply(&w);
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "an unrenderable declaration keeps the hook it is still running"
    );

    fs::write(&script, body).unwrap();
    apply(&w);

    assert!(!w.dot().join("hooks").exists());
    assert!(!w.dot().join("hooks.json").exists());
    assert!(w.dot().join("kendex/hooks/guard.sh").is_file());
    assert!(audit(&w.env, &w.scope()).unwrap().notes.is_empty());
}

/// A finished move cannot be re-opened by a stranger wearing the hook's
/// name: the installation lives at the new path now, and upstream
/// updates have to keep landing on it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_same_named_stranger_does_not_freeze_a_finished_move() {
    let w = regressed();
    apply(&w);
    assert!(!w.dot().join("hooks").exists());
    fs::create_dir_all(w.dot().join("hooks")).unwrap();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# somebody else's\n",
    )
    .unwrap();
    let script = w.catalog.join("hooks/guard.sh");
    let body = fs::read_to_string(&script).unwrap();
    fs::write(&script, body.replace("exit 0", "exit 1")).unwrap();

    apply(&w);

    assert!(
        fs::read_to_string(w.dot().join("kendex/hooks/guard.sh"))
            .unwrap()
            .contains("exit 1"),
        "the update still lands on the installation that moved"
    );
    assert!(
        w.dot().join("hooks/guard.sh").is_file(),
        "and the stranger's file is nobody's to take"
    );
    assert!(
        about(&notes(&w), "hooks/guard.sh").is_empty(),
        "nor is it reported as a copy of this hook: {:?}",
        notes(&w)
    );
}

/// The one line that says a hook stopped running: a refresh keeps an
/// orphan's record, so without it nothing reports the change.
#[test]
#[allow(clippy::unwrap_used)]
fn retiring_an_orphans_copy_says_the_hook_stopped_running() {
    let w = regressed();
    undeclare(&w);

    let report = plan_apply(&w.env, &w.scope(), &refresh()).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("nothing asks for the pi hook guard")
                && note.contains("stops running")),
        "{:?}",
        report.notes
    );
}

/// The orphan sweep derives its paths from the lock, and this hook's
/// path moved: a file already sitting at the new one was never written
/// by that record, so an automatic removal must not take it — the rule
/// every other kind already follows.
#[test]
#[allow(clippy::unwrap_used)]
fn an_orphan_sweep_does_not_take_a_stranger_at_the_new_path() {
    let w = regressed();
    undeclare(&w);
    let new = w.dot().join("kendex/hooks/guard.sh");
    fs::create_dir_all(new.parent().unwrap()).unwrap();
    fs::write(&new, "#!/bin/sh\n# somebody else's\n").unwrap();

    apply_with(&w, &reconcile());

    assert_eq!(
        fs::read_to_string(&new).unwrap(),
        "#!/bin/sh\n# somebody else's\n",
        "a sweep nobody named takes only what it can prove it wrote"
    );
}

/// A hold says the old installation is still live and still kendex's to
/// account for, so the record that can claim it must survive the sweep
/// that runs in the same pass — or nothing can ever finish the move.
#[test]
#[allow(clippy::unwrap_used)]
fn an_undeclared_held_hook_keeps_its_record_through_the_orphan_sweep() {
    #[allow(clippy::type_complexity)]
    let causes: [(&str, &dyn Fn(&World, &std::path::Path)); 3] = [
        ("edited", &|_, path| {
            fs::write(path, "#!/bin/sh\n# mine\nexit 0\n").unwrap()
        }),
        ("unprovable", &|w, _| forget_rendered_hash(w)),
        ("unreadable", &|_, path| {
            fs::set_permissions(path, fs::Permissions::from_mode(0o000)).unwrap()
        }),
    ];
    for (cause, spoil) in causes {
        let w = regressed();
        undeclare(&w);
        let script = w.dot().join("hooks/guard.sh");
        spoil(&w, &script);

        apply_with(&w, &reconcile());

        let lock: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
                .unwrap();
        assert!(
            lock["entries"].get("hook:guard:pi").is_some(),
            "{cause}: the record is the only thing that can claim those files later: {lock}"
        );
        assert!(script.exists(), "{cause}: the copy stays");
        assert!(
            fs::read_to_string(w.dot().join("hooks.json"))
                .unwrap()
                .contains(".pi/hooks/guard.sh"),
            "{cause}: and it is still registered, so it is still running"
        );
        fs::set_permissions(&script, fs::Permissions::from_mode(0o644)).unwrap();

        // And a later pass can still finish what this one held.
        apply_with(
            &w,
            &PlanOptions {
                remove_orphans: true,
                sweep_unneeded: true,
                overwrite_edited: true,
                ..PlanOptions::default()
            },
        );
        assert!(
            !w.dot().join("hooks").exists(),
            "{cause}: discarding the edits finishes the move"
        );
        assert!(!w.dot().join("hooks.json").exists());
    }
}

/// A removal the person typed is the one case where they have already
/// said they mean to take these bytes. It finishes the move rather than
/// leaving the hook running with its declaration gone.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_held_hook_by_name_takes_it() {
    let w = regressed();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();
    undeclare(&w);

    apply_with(
        &w,
        &PlanOptions {
            remove_orphans: true,
            removal_filter: Some(vec!["guard".to_owned()]),
            ..PlanOptions::default()
        },
    );

    assert!(
        !w.dot().join("hooks").exists(),
        "the copy the person asked to be rid of goes"
    );
    assert!(
        !w.dot().join("hooks.json").exists(),
        "and so does what runs it"
    );
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    assert!(lock["entries"].get("hook:guard:pi").is_none(), "{lock}");
}

/// The row an orphan's hold produces says the same thing the declared
/// one does, cause for cause. A link is not an edit, and telling somebody
/// to discard edits over one sends them round a loop that changes
/// nothing and explains nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hold_no_discard_can_release_reads_the_same_when_nothing_asks_for_it() {
    let w = regressed();
    undeclare(&w);
    let registry = w.dot().join("hooks.json");
    let elsewhere = w.home.join("their-hooks.json");
    fs::rename(&registry, &elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, &registry).unwrap();

    let report = plan_apply(&w.env, &w.scope(), &reconcile()).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.name == "guard" && row.state == DriftState::Conflict)
        .unwrap_or_else(|| panic!("the hold has to be reported: {:?}", report.drift));
    assert!(
        row.detail.contains("registration") && row.detail.contains("hooks.json"),
        "the row names what is in the way: {}",
        row.detail
    );
    assert!(
        !row.detail.contains("discard"),
        "and not a remedy that cannot work: {}",
        row.detail
    );
    assert!(row.cause.is_none(), "nor a cause for one: {:?}", row.cause);
}
